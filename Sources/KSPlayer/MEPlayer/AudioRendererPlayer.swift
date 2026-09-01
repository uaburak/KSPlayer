//
//  AudioRendererPlayer.swift
//  KSPlayer
//
//  Created by kintan on 2022/12/2.
//

import AVFoundation
import Foundation

public class AudioRendererPlayer: AudioOutput {
    public var playbackRate: Float = 1 {
        didSet {
            if !isPaused {
                synchronizer.rate = playbackRate
            }
        }
    }

    public var volume: Float {
        get {
            renderer.volume
        }
        set {
            renderer.volume = newValue
        }
    }

    public var isMuted: Bool {
        get {
            renderer.isMuted
        }
        set {
            renderer.isMuted = newValue
        }
    }

    public weak var renderSource: OutputRenderSourceDelegate?
    private var periodicTimeObserver: Any?
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let serializationQueue = DispatchQueue(label: "ks.player.serialization.queue")
    /// Transport intent, not the timebase rate.
    ///
    /// The rate is legitimately 0 while playing but not yet anchored (see `anchor`), so
    /// deriving "paused" from it would stop `request()` from ever enqueueing the first
    /// sample — and the clock would then never start at all.
    private var isPlaying = false
    var isPaused: Bool { !isPlaying }

    /// Whether the timebase is tied to a real media timestamp.
    private var isAnchored = false

    /// Where the clock stood when playback was paused. See `pause`.
    private var pausedTime: CMTime?
    /// Last value seen by the periodic observer, to spot backward corrections.
    private var lastObservedTime: CMTime?

    public required init() {
        synchronizer.addRenderer(renderer)
        if #available(macOS 11.3, iOS 14.5, tvOS 14.5, *) {
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        }
//        if #available(tvOS 15.0, iOS 15.0, macOS 12.0, *) {
//            renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
//        }
    }

    public func prepare(audioFormat: AVAudioFormat) {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(Int(audioFormat.channelCount))
        KSLog("[audio] set preferredOutputNumberOfChannels: \(audioFormat.channelCount)")
        #endif
    }

    public func play() {
        guard !isPlaying else {
            return
        }
        isPlaying = true
        // Resuming while the timebase is still tied to real media: carry on from where it
        // stopped. Otherwise leave the clock stopped — `request()` starts it from the first
        // sample it actually enqueues. Never start it from a guessed time; see `anchor`.
        if isAnchored {
            let time = pausedTime ?? synchronizer.currentTime()
            pausedTime = nil
            KSLog("[audio] resume clock at \(time.seconds), settled value was \(synchronizer.currentTime().seconds)")
            lastObservedTime = nil
            synchronizer.setRate(playbackRate, time: time)
            // Push the time through at once. KSClock extrapolates from the wall clock since
            // its last update, and nothing updates it while paused, so it reports a time the
            // whole pause duration ahead of reality until the first periodic observer
            // callback lands. The video track syncs to that, believes it is far behind and
            // drops frames — a visible stall the moment playback resumes.
            renderSource?.setAudio(time: time, position: -1)
        }
        renderer.requestMediaDataWhenReady(on: serializationQueue) { [weak self] in
            guard let self else {
                return
            }
            self.request()
        }
        periodicTimeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.01), queue: .main) { [weak self] time in
            guard let self, self.isAnchored else {
                return
            }
            // A timebase that steps backwards is a correction, not playback. Everything
            // downstream treats this clock as monotonic, so a step back lands on the video
            // track as "suddenly far ahead" and freezes the picture until the clock catches
            // up again. Nothing else in the pipeline records that it happened.
            if let last = self.lastObservedTime, time < last {
                let backwards = (last - time).seconds
                if backwards > 0.05 {
                    KSLog("[audio] clock stepped back \(backwards) from \(last.seconds) to \(time.seconds)")
                }
            }
            self.lastObservedTime = time
            self.renderSource?.setAudio(time: time, position: -1)
        }
    }

    public func pause() {
        isPlaying = false
        // Read the clock before stopping it. Dropping the rate to 0 discards the audio that
        // was scheduled but never heard, and the timebase settles back to what the renderer
        // actually played out. On a high latency output that is a long way behind where
        // playback had reached — an AirPlay speaker holds most of a second. Resuming from
        // the settled value puts the clock behind the video track, which then holds its next
        // frame until the clock crawls back up to it: a freeze exactly as long as the output
        // latency, every single time playback resumes.
        pausedTime = isAnchored ? synchronizer.currentTime() : nil
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        if let periodicTimeObserver {
            synchronizer.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
    }

    public func flush() {
        // Stop the clock too. A flush means the media moved (a seek, a track change), and a
        // timebase left running would keep advancing from the old position while the renderer
        // is empty. Samples enqueued afterwards carry the new position's timestamps, so they
        // land outside the window the renderer will play — silence — and every consumer
        // syncing to this clock drifts along with it.
        synchronizer.rate = 0
        renderer.flush()
        isAnchored = false
        pausedTime = nil
    }

    private func request() {
        while renderer.isReadyForMoreMediaData, !isPaused {
            guard var render = renderSource?.getAudioOutputRender() else {
                break
            }
            var array = [render]
            let loopCount = Int32(render.audioFormat.sampleRate) / 20 / Int32(render.numberOfSamples) - 2
            if loopCount > 0 {
                for _ in 0 ..< loopCount {
                    if let render = renderSource?.getAudioOutputRender() {
                        array.append(render)
                    }
                }
            }
            if array.count > 1 {
                render = AudioFrame(array: array)
            }
            if let sampleBuffer = render.toCMSampleBuffer() {
                let channelCount = render.audioFormat.channelCount
                renderer.audioTimePitchAlgorithm = channelCount > 2 ? .spectral : .timeDomain
                renderer.enqueue(sampleBuffer)
                if !isAnchored {
                    anchor(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                }
                #if !os(macOS)
                if AVAudioSession.sharedInstance().preferredInputNumberOfChannels != channelCount {
                    try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(Int(channelCount))
                }
                #endif
            }
        }
    }

    /// Ties the timebase to a real media timestamp.
    ///
    /// The clock must never be started from a fabricated time. Starting the synchronizer at
    /// `.zero`, or at a stale `currentTime()` left over from before a flush, leaves it
    /// free-running at wall-clock rate while the media sits somewhere else entirely.
    /// Everything downstream syncs to this clock, so the video track ends up chasing a target
    /// it can never reach — dropping, then flushing, then seeking frames indefinitely — while
    /// the audio samples are timestamped outside the window the renderer will play and fall
    /// silent.
    private func anchor(at time: CMTime) {
        guard time.isValid, time.isNumeric else {
            return
        }
        isAnchored = true
        runOnMainThread { [weak self] in
            guard let self, self.isPlaying else {
                return
            }
            self.synchronizer.setRate(self.playbackRate, time: time)
            self.renderSource?.setAudio(time: time, position: -1)
        }
    }
}
