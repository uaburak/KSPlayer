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
            // Only a clock that is already tied to the media may be driven directly. While an
            // anchor is still owed the rate is applied together with it; setting it here would
            // start the timebase from wherever it happens to stand. See `Anchor`.
            if !isPaused, isClockAnchored {
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
    /// The rate is legitimately 0 while playing but not yet anchored (see `Anchor`), so
    /// deriving "paused" from it would stop `request()` from ever enqueueing the first
    /// sample — and the clock would then never start at all.
    private var isPlaying = false
    var isPaused: Bool { !isPlaying }

    /// How the timebase relates to the media.
    ///
    /// The clock must never be started from a fabricated time. Starting the synchronizer at
    /// `.zero`, or at a stale `currentTime()` left over from before a flush, leaves it
    /// free-running at wall-clock rate while the media sits somewhere else entirely.
    /// Everything downstream syncs to this clock, so the video track ends up chasing a target
    /// it can never reach — dropping, then flushing, then seeking frames indefinitely — while
    /// the audio samples are timestamped outside the window the renderer will play and fall
    /// silent.
    private enum Anchor {
        /// Nothing has been enqueued since the last flush. The clock is stopped and tied to
        /// nothing; the first buffer to arrive claims it.
        case loose
        /// A buffer has been enqueued and its timestamp claimed, but the clock has not been
        /// started from it yet: the hop to the main thread is still in flight, or it arrived
        /// to find playback paused. Whoever starts the clock next starts it from this time.
        case claimed(CMTime)
        /// The clock stands at real media time, running or paused.
        case applied
    }

    /// Guards `anchor`, `anchorGeneration` and `pausedTime`: they are written from the main
    /// thread, from the serialization queue and — through `flush` on a route change — from
    /// whichever thread the audio session posts its notifications on.
    private let anchorLock = NSLock()
    private var anchor = Anchor.loose
    /// Moved on by every flush and by every anchor claim. A scheduled anchor carries the value
    /// it was claimed with and is dropped if the counter has moved by the time it reaches the
    /// main thread; a buffer carries the value it was fetched under and is dropped if a flush
    /// has moved the counter by the time it is enqueued.
    private var anchorGeneration = 0

    /// Where the clock stood when playback was paused. See `pause`.
    private var pausedTime: CMTime?
    /// Last value seen by the periodic observer, to spot backward corrections.
    private var lastObservedTime: CMTime?

    private var isClockAnchored: Bool {
        anchorLock.lock()
        defer { anchorLock.unlock() }
        if case .applied = anchor {
            return true
        }
        return false
    }

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
        anchorLock.lock()
        let anchor = self.anchor
        let pausedTime = self.pausedTime
        self.pausedTime = nil
        if case .claimed = anchor {
            self.anchor = .applied
        }
        anchorLock.unlock()
        switch anchor {
        case .applied:
            // Resuming while the timebase is still tied to real media: carry on from where it
            // stopped.
            let time = pausedTime ?? synchronizer.currentTime()
            KSLog("[audio] resume clock at \(time.seconds), settled value was \(synchronizer.currentTime().seconds)")
            start(at: time)
        case let .claimed(time):
            // The first buffer after a flush was enqueued while playback was paused, so its
            // anchor was claimed but never applied — `applyAnchor` only starts a clock that is
            // meant to be running. The timebase still holds whatever it held before the flush;
            // resuming from that would be starting the clock from a stale time. The claimed
            // timestamp is where the renderer's contents actually begin.
            start(at: time)
        case .loose:
            // Leave the clock stopped: `request()` starts it from the first sample it actually
            // enqueues.
            break
        }
        renderer.requestMediaDataWhenReady(on: serializationQueue) { [weak self] in
            guard let self else {
                return
            }
            self.request()
        }
        periodicTimeObserver = synchronizer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.01), queue: .main) { [weak self] time in
            guard let self, self.isClockAnchored else {
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

    /// Starts the clock at a real media time and tells the consumers at once.
    ///
    /// KSClock extrapolates from the wall clock since its last update, and nothing updates it
    /// while the clock is stopped, so it reports a time the whole pause duration ahead of
    /// reality until the first periodic observer callback lands. The video track syncs to that,
    /// believes it is far behind and drops frames — a visible stall the moment playback
    /// resumes. Pushing the time through here closes that window.
    private func start(at time: CMTime) {
        lastObservedTime = nil
        synchronizer.setRate(playbackRate, time: time)
        renderSource?.setAudio(time: time, position: -1)
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
        //
        // Only a clock that stands at media time has a position worth keeping. While the
        // anchor is merely claimed the timebase still holds its pre-flush value.
        anchorLock.lock()
        if case .applied = anchor {
            pausedTime = synchronizer.currentTime()
        } else {
            pausedTime = nil
        }
        anchorLock.unlock()
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
        // Under the lock, so that a buffer enqueued concurrently is either wholly before this
        // flush — and thrown away with the rest, together with any anchor it claimed — or
        // wholly after it, and then turned away by the bump below if it was fetched earlier.
        anchorLock.lock()
        renderer.flush()
        anchor = .loose
        anchorGeneration &+= 1
        pausedTime = nil
        anchorLock.unlock()
    }

    private func request() {
        while renderer.isReadyForMoreMediaData, !isPaused {
            // Taken before the frames are fetched: a flush between here and the enqueue means
            // they belong to the position the media has just left.
            anchorLock.lock()
            let generation = anchorGeneration
            anchorLock.unlock()
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
                enqueue(sampleBuffer, fetchedAt: generation)
                #if !os(macOS)
                if AVAudioSession.sharedInstance().preferredInputNumberOfChannels != channelCount {
                    try? AVAudioSession.sharedInstance().setPreferredOutputNumberOfChannels(Int(channelCount))
                }
                #endif
            }
        }
    }

    /// Enqueues one buffer and, while the timebase is still loose, claims the anchor for it.
    ///
    /// Everything happens under `anchorLock`, which `flush` takes as well. That makes the
    /// ordering between the two total: a buffer is either flushed away along with the claim it
    /// made, or it arrives after the flush and is judged against the new generation.
    ///
    /// - Parameter generation: `anchorGeneration` as it stood before the frames were fetched.
    private func enqueue(_ sampleBuffer: CMSampleBuffer, fetchedAt generation: Int) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        anchorLock.lock()
        // The frames were pulled out of the track before a flush that has since emptied the
        // renderer. They carry the old position's timestamps; enqueueing them now would hand
        // the freshly loosened clock an anchor from before the seek — the very thing the flush
        // was there to prevent. The next iteration fetches from the new position.
        guard anchorGeneration == generation else {
            anchorLock.unlock()
            return
        }
        renderer.enqueue(sampleBuffer)
        // Only a loose timebase is owed an anchor, and only a usable timestamp can be one: an
        // unusable one claims nothing and the next buffer gets to try again.
        guard case .loose = anchor, time.isValid, time.isNumeric else {
            anchorLock.unlock()
            return
        }
        anchor = .claimed(time)
        anchorGeneration &+= 1
        let claim = anchorGeneration
        anchorLock.unlock()
        runOnMainThread { [weak self] in
            self?.applyAnchor(claimedAt: claim)
        }
    }

    /// Starts the clock from the claimed timestamp, provided the claim still stands.
    ///
    /// Two things can have happened during the hop to the main thread. A flush: the buffer
    /// that carried the timestamp is gone and the generation has moved, so the claim is void
    /// and the first buffer of the new position makes a fresh one. Or a pause: the claim is
    /// still good but the clock is not meant to run, so it is left standing for `play()`.
    private func applyAnchor(claimedAt generation: Int) {
        anchorLock.lock()
        guard anchorGeneration == generation, case let .claimed(time) = anchor, isPlaying else {
            anchorLock.unlock()
            return
        }
        anchor = .applied
        anchorLock.unlock()
        start(at: time)
    }
}
