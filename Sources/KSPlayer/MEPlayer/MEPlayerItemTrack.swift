//
//  Decoder.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//
import AVFoundation
import CoreMedia
import Libavformat

protocol PlayerItemTrackProtocol: CapacityProtocol, AnyObject {
    init(mediaType: AVFoundation.AVMediaType, frameCapacity: UInt8, options: KSOptions)
    // 是否无缝循环
    var isLoopModel: Bool { get set }
    var isEndOfFile: Bool { get set }
    var delegate: CodecCapacityDelegate? { get set }
    func decode()
    func seek(time: TimeInterval)
    func putPacket(packet: Packet)
//    func getOutputRender<Frame: ObjectQueueItem>(where predicate: ((Frame) -> Bool)?) -> Frame?
    func shutdown()
}

class SyncPlayerItemTrack<Frame: MEFrame>: PlayerItemTrackProtocol, CustomStringConvertible {
    var seekTime = 0.0
    fileprivate let options: KSOptions
    fileprivate var decoderMap = [Int32: DecodeProtocol]()
    fileprivate var state = MECodecState.idle {
        didSet {
            if state == .finished {
                seekTime = 0
            }
        }
    }

    /// The packets given to the decoder since the last keyframe, that keyframe first. Only
    /// kept for video, and only with `KSOptions.isVideoDecoderRebuildable`; touched on the
    /// decoding thread alone. See `suspendDecoding()`.
    private var gop = [Packet]()
    private var gopBytes = 0
    /// False from the moment a GOP outgrows what is worth keeping until the next keyframe.
    private var gopIsWhole = false
    /// `gop.count`, readable from any thread.
    private(set) var gopPacketCount = 0
    /// Where the newest frame handed on ends, in seconds: what a rebuilt decoder must not
    /// produce a second time.
    private var deliveredUntil = 0.0
    /// Guards the state below, which is set on the main thread and read while decoding.
    private let rebuildLock = NSCondition()
    private var isDecodingSuspended = false
    private var decoderIsLost = false
    /// From the moment the decoding thread takes up a lost decoder until the new one stands
    /// where the old one stood.
    private var isCatchingUp = false
    /// Whether a thread is there to rebuild a lost decoder without being given a packet first.
    private var isDecodeThreadRunning = false
    /// Who waits for that. See `resumeDecoding(whenReady:)`.
    private var catchUpHandlers = [() -> Void]()
    /// True while the kept packets are fed again, and when the first frame got through in
    /// the course of it. Touched on the decoding thread alone.
    private var isReplaying = false
    private var caughtUpAt = 0.0
    fileprivate var keepsGOP: Bool {
        mediaType == .video && options.isVideoDecoderRebuildable
    }

    var isEndOfFile: Bool = false
    var packetCount: Int { 0 }
    let description: String
    weak var delegate: CodecCapacityDelegate?
    let mediaType: AVFoundation.AVMediaType
    let outputRenderQueue: CircularBuffer<Frame>
    var isLoopModel = false
    var frameCount: Int { outputRenderQueue.count }
    var frameMaxCount: Int {
        outputRenderQueue.maxCount
    }

    var fps: Float {
        outputRenderQueue.fps
    }

    required init(mediaType: AVFoundation.AVMediaType, frameCapacity: UInt8, options: KSOptions) {
        self.options = options
        self.mediaType = mediaType
        description = mediaType.rawValue
        // 默认缓存队列大小跟帧率挂钩,经测试除以4，最优
        if mediaType == .audio {
            outputRenderQueue = CircularBuffer(initialCapacity: Int(frameCapacity), expanding: false)
        } else if mediaType == .video {
            outputRenderQueue = CircularBuffer(initialCapacity: Int(frameCapacity), sorted: true, expanding: false)
        } else {
            // 有的图片字幕不按顺序来输出，所以要排序下。
            outputRenderQueue = CircularBuffer(initialCapacity: Int(frameCapacity), sorted: true)
        }
    }

    func decode() {
        isEndOfFile = false
        state = .decoding
    }

    func seek(time: TimeInterval) {
        if options.isAccurateSeek {
            seekTime = time
        } else {
            seekTime = 0
        }
        isEndOfFile = false
        state = .flush
        outputRenderQueue.flush()
        isLoopModel = false
        wakeDecoding()
    }

    func putPacket(packet: Packet) {
        if state == .flush {
            decoderMap.values.forEach { $0.doFlushCodec() }
            forgetGOP()
            state = .decoding
        }
        if state == .decoding {
            doDecode(packet: packet)
        }
    }

    func getOutputRender(where predicate: ((Frame, Int) -> Bool)?) -> Frame? {
        let outputFecthRender = outputRenderQueue.pop(where: predicate)
        if outputFecthRender == nil {
            if state == .finished, frameCount == 0 {
                delegate?.codecDidFinished(track: self)
            }
        }
        return outputFecthRender
    }

    func shutdown() {
        if state == .idle {
            return
        }
        state = .closed
        outputRenderQueue.shutdown()
        wakeDecoding()
    }

    // MARK: Rebuilding the decoder

    /// Nothing more is given to the decoder until `resumeDecoding()`.
    ///
    /// For the app's time in the background. A hardware decoder works through a session that
    /// the system takes away there, and everything the decoder had built up goes with it: the
    /// frames a GOP's later pictures are predicted from. Back in the foreground the next
    /// packets cannot be decoded — the picture stands still until the next keyframe comes
    /// round, while the sound runs on. Seconds, in a stream with long GOPs.
    ///
    /// So the track keeps the packets of the GOP it is in (`gop`). When decoding resumes the
    /// old decoder is thrown away, a new one is fed those packets again, and the frames that
    /// had already been handed on are discarded as they come out a second time. Decoding then
    /// carries on with the packet it had stopped at, and not a frame is missing.
    ///
    /// Holding the decoder back in the meantime is part of it. A packet it is given while it
    /// has no session is a packet lost, and with enough of them the GOP kept here is no longer
    /// the one playback stands in.
    ///
    /// Feeding the packets again takes time: a few milliseconds each, and a GOP can hold
    /// hundreds. The frames queued before the app left cover less than a second of that.
    /// Playback started any sooner runs out of picture while the sound goes on, and then
    /// drops frames to catch up with it. So whoever starts playback waits for the decoder
    /// first (`resumeDecoding(whenReady:)`).
    func suspendDecoding() {
        guard keepsGOP else { return }
        rebuildLock.lock()
        isDecodingSuspended = true
        rebuildLock.unlock()
        KSLog("[video] decoding suspended, \(gopPacketCount) packets kept since the last keyframe")
    }

    /// Decoding carries on, with a new decoder. See `suspendDecoding()`.
    ///
    /// - Parameter handler: called on the main queue, never from inside this call, once the
    ///   new decoder has produced everything the old one had handed on: from then on the
    ///   picture keeps up with playback. Called straight away when no decoder is being
    ///   rebuilt, or when no thread is there to rebuild it before the next packet arrives.
    func resumeDecoding(whenReady handler: (() -> Void)? = nil) {
        rebuildLock.lock()
        let wasSuspended = isDecodingSuspended
        isDecodingSuspended = false
        if wasSuspended {
            decoderIsLost = true
        }
        let isAwaited = (decoderIsLost || isCatchingUp) && isDecodeThreadRunning
        if let handler, isAwaited {
            catchUpHandlers.append(handler)
        }
        rebuildLock.broadcast()
        rebuildLock.unlock()
        if let handler, !isAwaited {
            DispatchQueue.main.async(execute: handler)
        }
        if wasSuspended {
            KSLog("[video] decoding resumed, the decoder is rebuilt now")
            // Wherever the decoding thread is parked — most likely in `push`, waiting for
            // the render queue to empty by half — it is let out: nothing empties that queue
            // while playback waits for the decoder.
            wakeDecodeThread()
        }
    }

    /// Lets the decoding thread out of whatever queue it is waiting on. `decoderIsLost` has
    /// been set by then, and neither queue is waited on again while it stands.
    fileprivate func wakeDecodeThread() {
        outputRenderQueue.wake()
    }

    /// Blocks the decoding thread while decoding is suspended. A seek or a shutdown ends the
    /// wait: both change `state`, and the caller looks at it again afterwards.
    fileprivate func waitWhileSuspended() {
        rebuildLock.lock()
        while isDecodingSuspended, state == .decoding {
            rebuildLock.wait()
        }
        rebuildLock.unlock()
    }

    private func wakeDecoding() {
        rebuildLock.lock()
        rebuildLock.broadcast()
        rebuildLock.unlock()
    }

    private var isSuspended: Bool {
        rebuildLock.lock()
        defer { rebuildLock.unlock() }
        return isDecodingSuspended
    }

    /// Whether the decoder has been lost and not been taken up yet. What it gives out until
    /// then is not passed on: the new decoder produces it again.
    fileprivate var hasLostDecoder: Bool {
        rebuildLock.lock()
        defer { rebuildLock.unlock() }
        return decoderIsLost
    }

    fileprivate func decodeThreadDidBegin() {
        rebuildLock.lock()
        isDecodeThreadRunning = true
        rebuildLock.unlock()
    }

    fileprivate func decodeThreadDidEnd() {
        finishCatchUp(isThreadEnding: true)
    }

    /// Tells whoever is waiting that the picture keeps up from here on.
    ///
    /// Not while the decoder has been lost once more in the meantime: the rebuild that
    /// follows answers them. A thread that ends rebuilds nothing more and answers at once.
    private func finishCatchUp(isThreadEnding: Bool = false) {
        rebuildLock.lock()
        if isThreadEnding {
            isDecodeThreadRunning = false
        } else if decoderIsLost {
            rebuildLock.unlock()
            return
        }
        isCatchingUp = false
        let handlers = catchUpHandlers
        catchUpHandlers.removeAll()
        rebuildLock.unlock()
        handlers.forEach { DispatchQueue.main.async(execute: $0) }
    }

    /// The decoder has been flushed or is gone: what was kept for it means nothing any more.
    fileprivate func forgetGOP() {
        gop.removeAll(keepingCapacity: true)
        gopBytes = 0
        gopIsWhole = false
        gopPacketCount = 0
        deliveredUntil = 0
    }

    private func remember(_ packet: Packet) {
        if let first = gop.first, first.assetTrack !== packet.assetTrack {
            // Another video track: its decoder starts from its own keyframe.
            gop.removeAll(keepingCapacity: true)
            gopBytes = 0
            gopIsWhole = false
        }
        if packet.isKeyFrame {
            gop.removeAll(keepingCapacity: true)
            gopBytes = 0
            gopIsWhole = true
        }
        if gopIsWhole {
            gop.append(packet)
            gopBytes += Int(packet.size)
            // A GOP this long is not worth holding on to. A rebuild inside it waits for the
            // next keyframe, as every rebuild used to.
            if gop.count > 1800 || gopBytes > 64 << 20 {
                gop.removeAll()
                gopBytes = 0
                gopIsWhole = false
            }
        }
        gopPacketCount = gop.count
    }

    fileprivate func rebuildDecoderIfLost() {
        var hasRebuilt = false
        // Again, if it was lost once more while the packets were being fed.
        while takeLostDecoder() {
            rebuildDecoder()
            hasRebuilt = true
        }
        if hasRebuilt {
            finishCatchUp()
        }
    }

    private func takeLostDecoder() -> Bool {
        rebuildLock.lock()
        defer { rebuildLock.unlock() }
        guard decoderIsLost else { return false }
        decoderIsLost = false
        isCatchingUp = true
        return true
    }

    private func rebuildDecoder() {
        let closed = CACurrentMediaTime()
        decoderMap.values.forEach { $0.shutdown() }
        decoderMap.removeAll()
        guard let assetTrack = gop.first?.assetTrack else {
            KSLog("[video] decoder rebuilt with nothing to replay, the picture resumes at the next keyframe")
            return
        }
        // What the old decoder had produced is in the render queue or has been shown. The
        // accurate-seek filter drops everything up to there as it comes out again.
        if deliveredUntil > 0 {
            seekTime = max(seekTime, deliveredUntil + 0.001)
            let decoder = makeDecode(assetTrack: assetTrack)
            (decoder as? FFmpegDecode)?.captionsResumeAfter = deliveredUntil
            decoderMap[assetTrack.trackID] = decoder
        }
        let began = CACurrentMediaTime()
        var replayed = 0
        var halfway = 0.0
        var slowest = (number: 0, seconds: 0.0)
        isReplaying = true
        caughtUpAt = 0
        for packet in gop {
            // Suspended again: the session these packets go to is being taken away.
            guard state == .decoding, !isSuspended else { break }
            let started = CACurrentMediaTime()
            feed(packet)
            replayed += 1
            // Once a frame has got through, the time goes into waiting for room in the
            // render queue, not into decoding.
            guard caughtUpAt == 0 else { continue }
            let ended = CACurrentMediaTime()
            if ended - started > slowest.seconds {
                slowest = (replayed, ended - started)
            }
            if replayed == (gop.count + 1) / 2 {
                halfway = ended - began
            }
        }
        isReplaying = false
        // Where the time goes is not the same every time: on one return the same stream took
        // six times as long per packet as on the five before it.
        let duration = (caughtUpAt > 0 ? caughtUpAt : CACurrentMediaTime()) - began
        let timing = String(format: "old decoder replaced in %.0f ms, half replayed after %.0f ms, slowest packet no. %d with %.0f ms",
                            (began - closed) * 1000, halfway * 1000, slowest.number, slowest.seconds * 1000)
        KSLog("[video] decoder rebuilt, \(replayed) of \(gop.count) packets replayed in \(Int(duration * 1000)) ms (\(timing)), frames resume after \(String(format: "%.3f", deliveredUntil))")
    }

    private var lastPacketBytes = Int32(0)
    private var lastPacketSeconds = Double(-1)
    var bitrate = Double(0)
    fileprivate func doDecode(packet: Packet) {
        if keepsGOP {
            rebuildDecoderIfLost()
            // Before it is decoded: a packet the decoder fails on is one a rebuild has to
            // replay as well.
            remember(packet)
        }
        if packet.isKeyFrame, packet.assetTrack.mediaType != .subtitle {
            let seconds = packet.seconds
            let diff = seconds - lastPacketSeconds
            if lastPacketSeconds < 0 || diff < 0 {
                bitrate = 0
                lastPacketBytes = 0
                lastPacketSeconds = seconds
            } else if diff > 1 {
                bitrate = Double(lastPacketBytes) / diff
                lastPacketBytes = 0
                lastPacketSeconds = seconds
            }
        }
        lastPacketBytes += packet.size
        feed(packet)
        if options.decodeAudioTime == 0, mediaType == .audio {
            options.decodeAudioTime = CACurrentMediaTime()
        }
        if options.decodeVideoTime == 0, mediaType == .video {
            options.decodeVideoTime = CACurrentMediaTime()
        }
    }

    /// Gives one packet to its decoder and passes on what comes out.
    private func feed(_ packet: Packet) {
        let decoder = decoderMap.value(for: packet.assetTrack.trackID, default: makeDecode(assetTrack: packet.assetTrack))
//        var startTime = CACurrentMediaTime()
        decoder.decodeFrame(from: packet) { [weak self] result in
            guard let self else {
                return
            }
            do {
//                if packet.assetTrack.mediaType == .video {
//                    print("[video] decode time: \(CACurrentMediaTime()-startTime)")
//                    startTime = CACurrentMediaTime()
//                }
                let frame = try result.get()
                if self.state == .flush || self.state == .closed {
                    return
                }
                if self.seekTime > 0 {
                    let timestamp = frame.timestamp + frame.duration
//                    KSLog("seektime \(self.seekTime), frame \(frame.seconds), mediaType \(packet.assetTrack.mediaType)")
                    if timestamp <= 0 || frame.timebase.cmtime(for: timestamp).seconds < self.seekTime {
                        return
                    } else {
                        self.seekTime = 0.0
                    }
                }
                if let frame = frame as? Frame {
                    if self.keepsGOP {
                        // The first frame the old decoder had not handed on: the new one has
                        // caught up. Said before the wait below — with playback waiting for
                        // exactly this, a full queue would otherwise never empty.
                        if self.isReplaying {
                            if self.caughtUpAt == 0 {
                                self.caughtUpAt = CACurrentMediaTime()
                            }
                            self.finishCatchUp()
                        }
                        // The thread can have been let out of `push` with the queue still
                        // full (`resumeDecoding()`).
                        self.outputRenderQueue.waitForSpace(unless: { self.hasLostDecoder })
                        if self.state == .flush || self.state == .closed {
                            return
                        }
                        // Not handed on, so not counted as delivered: it comes out again
                        // when the packets are replayed.
                        if self.hasLostDecoder {
                            return
                        }
                        self.deliveredUntil = frame.timebase.cmtime(for: frame.timestamp + frame.duration).seconds
                        self.outputRenderQueue.push(frame, waitUnless: { self.hasLostDecoder })
                    } else {
                        self.outputRenderQueue.push(frame)
                    }
                    self.outputRenderQueue.fps = packet.assetTrack.nominalFrameRate
                }
            } catch {
                KSLog("Decoder did Failed : \(error)")
                if decoder is VideoToolboxDecode {
                    decoder.shutdown()
                    self.decoderMap[packet.assetTrack.trackID] = FFmpegDecode(assetTrack: packet.assetTrack, options: self.options)
                    KSLog("VideoCodec switch to software decompression")
                    self.feed(packet)
                } else {
                    self.state = .failed
                }
            }
        }
    }
}

final class AsyncPlayerItemTrack<Frame: MEFrame>: SyncPlayerItemTrack<Frame> {
    private let operationQueue = OperationQueue()
    private var decodeOperation: BlockOperation!
    // 无缝播放使用的PacketQueue
    private var loopPacketQueue: CircularBuffer<Packet>?
    var packetQueue = CircularBuffer<Packet>()
    override var packetCount: Int { packetQueue.count }
    override var isLoopModel: Bool {
        didSet {
            if isLoopModel {
                loopPacketQueue = CircularBuffer<Packet>()
                isEndOfFile = true
            } else {
                if let loopPacketQueue {
                    packetQueue.shutdown()
                    packetQueue = loopPacketQueue
                    self.loopPacketQueue = nil
                    if decodeOperation.isFinished {
                        decode()
                    }
                }
            }
        }
    }

    required init(mediaType: AVFoundation.AVMediaType, frameCapacity: UInt8, options: KSOptions) {
        super.init(mediaType: mediaType, frameCapacity: frameCapacity, options: options)
        operationQueue.name = "KSPlayer_" + mediaType.rawValue
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInteractive
    }

    override func putPacket(packet: Packet) {
        if isLoopModel {
            loopPacketQueue?.push(packet)
        } else {
            packetQueue.push(packet)
        }
    }

    override func decode() {
        isEndOfFile = false
        guard operationQueue.operationCount == 0 else { return }
        decodeOperation = BlockOperation { [weak self] in
            guard let self else { return }
            Thread.current.name = self.operationQueue.name
            Thread.current.stackSize = KSOptions.stackSize
            self.decodeThread()
        }
        decodeOperation.queuePriority = .veryHigh
        decodeOperation.qualityOfService = .userInteractive
        operationQueue.addOperation(decodeOperation)
    }

    private func decodeThread() {
        state = .decoding
        isEndOfFile = false
        decoderMap.values.forEach { $0.decode() }
        decodeThreadDidBegin()
        outerLoop: while !decodeOperation.isCancelled {
            switch state {
            case .idle:
                break outerLoop
            case .finished, .closed, .failed:
                decoderMap.values.forEach { $0.shutdown() }
                decoderMap.removeAll()
                forgetGOP()
                break outerLoop
            case .flush:
                decoderMap.values.forEach { $0.doFlushCodec() }
                forgetGOP()
                state = .decoding
            case .decoding:
                if keepsGOP {
                    waitWhileSuspended()
                    // Here as well as before each packet: someone may be waiting for the
                    // new decoder, and the next packet can be a long time coming.
                    if state == .decoding {
                        autoreleasepool {
                            rebuildDecoderIfLost()
                        }
                    }
                    // A seek or a shutdown in the meantime comes first: the next packet to
                    // arrive may already belong to where the seek went.
                    guard state == .decoding else {
                        continue
                    }
                }
                if isEndOfFile, packetQueue.count == 0 {
                    state = .finished
                } else {
                    guard let packet = nextPacket(), state != .flush, state != .closed else {
                        continue
                    }
                    waitWhileSuspended()
                    // A seek or a shutdown during the wait: the packet belongs to what was left.
                    guard state == .decoding else {
                        continue
                    }
                    autoreleasepool {
                        doDecode(packet: packet)
                    }
                }
            }
        }
        // Nobody rebuilds a decoder from here on.
        decodeThreadDidEnd()
    }

    private func nextPacket() -> Packet? {
        guard keepsGOP else {
            return packetQueue.pop(wait: true)
        }
        // A decoder lost while the queue is empty is not left waiting for a packet.
        return packetQueue.pop(wait: true, waitUnless: { self.hasLostDecoder })
    }

    override fileprivate func wakeDecodeThread() {
        super.wakeDecodeThread()
        packetQueue.wake()
    }

    override func seek(time: TimeInterval) {
        if decodeOperation.isFinished {
            decode()
        }
        packetQueue.flush()
        super.seek(time: time)
        loopPacketQueue = nil
    }

    override func shutdown() {
        if state == .idle {
            return
        }
        super.shutdown()
        packetQueue.shutdown()
    }
}

public extension Dictionary {
    mutating func value(for key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        if let value = self[key] {
            return value
        } else {
            let value = defaultValue()
            self[key] = value
            return value
        }
    }
}

protocol DecodeProtocol {
    func decode()
    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void)
    func doFlushCodec()
    func shutdown()
}

extension SyncPlayerItemTrack {
    func makeDecode(assetTrack: FFmpegAssetTrack) -> DecodeProtocol {
        autoreleasepool {
            if mediaType == .subtitle {
                return SubtitleDecode(assetTrack: assetTrack, options: options)
            } else {
                if mediaType == .video, options.asynchronousDecompression, options.hardwareDecode,
                   let session = DecompressionSession(assetTrack: assetTrack, options: options)
                {
                    return VideoToolboxDecode(options: options, session: session)
                } else {
                    return FFmpegDecode(assetTrack: assetTrack, options: options)
                }
            }
        }
    }
}
