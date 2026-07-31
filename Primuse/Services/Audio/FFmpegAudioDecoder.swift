@preconcurrency import AVFoundation
import Foundation

private final class FFmpegOperationRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pendingResult: Result<Value, any Error>?
    private var didResolve = false
    private var didStart = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard !didResolve else {
            lock.unlock()
            return false
        }
        didResolve = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    /// Resolves from the watchdog/cancellation side. The side effect runs while
    /// the race lock is held, so a worker that has already started cannot report
    /// itself available between the control-plane win and opening the circuit.
    @discardableResult
    func resolveFromControl(
        _ result: Result<Value, any Error>,
        onStarted: () -> Void
    ) -> Bool {
        lock.lock()
        guard !didResolve else {
            lock.unlock()
            return false
        }
        didResolve = true
        if didStart { onStarted() }
        let continuation = continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResolve else { return false }
        didStart = true
        return true
    }

}

/// A serial execution lane with a token-owned circuit breaker. Playback and
/// metadata probing use separate lanes so an optional whole-file duration scan
/// can never starve realtime packet reads. Each lane can retain at most one
/// uninterruptible vnode call while its circuit rejects all later work.
private final class FFmpegBlockingLane: @unchecked Sendable {
    let name: String
    let queue: DispatchQueue
    private let lock = NSLock()
    private var unavailableToken: UUID?

    init(label: String, qos: DispatchQoS) {
        name = label.hasSuffix("probe-worker") ? "probe" : "playback"
        queue = DispatchQueue(label: label, qos: qos)
    }

    var isUnavailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unavailableToken != nil
    }

    @discardableResult
    func markUnavailable(for token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard unavailableToken == nil else { return false }
        unavailableToken = token
        return true
    }

    @discardableResult
    func markAvailable(for token: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard unavailableToken == token else { return false }
        unavailableToken = nil
        return true
    }
}

private struct FFmpegReadSnapshot: Sendable {
    let buffer: AVAudioPCMBuffer?
    let presentationTime: TimeInterval
    let hasPresentationTime: Bool
}

private struct FFmpegFileInfoSnapshot: Sendable {
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let bitDepth: Int
    let bitRateKbps: Int
    let codecName: String
}

/// Runs all potentially blocking FFmpeg calls on a private serial queue. The
/// bridge's AVIO interrupt callback normally aborts stalled I/O first; this
/// outer deadline is the control-plane fallback for a dead mounted filesystem
/// whose vnode read never returns to FFmpeg to poll that callback.
private final class FFmpegBridgeWorker: @unchecked Sendable {
    enum LaneKind {
        case playback
        case probe
    }

    private static let bridgeIOTimeout: TimeInterval = 15
    private static let outerOperationTimeout: TimeInterval = 16
    private static let watchdogQueue = DispatchQueue(
        label: "com.welape.yuanyin.ffmpeg-watchdog",
        qos: .userInitiated
    )
    /// Current/gapless decoders share one process-wide lane. If a dead vnode
    /// traps read(2), later playback sessions fail immediately instead of
    /// leaking another blocked thread per skipped track.
    private static let playbackLane = FFmpegBlockingLane(
        label: "com.welape.yuanyin.ffmpeg-worker",
        qos: .userInitiated
    )
    /// Metadata/content probing is isolated from realtime packet reads, but is
    /// independently serial and circuit-bounded for the same dead-mount case.
    private static let probeLane = FFmpegBlockingLane(
        label: "com.welape.yuanyin.ffmpeg-probe-worker",
        qos: .utility
    )
    private let lane: FFmpegBlockingLane
    private let lock = NSLock()
    private let watchdog: DispatchSourceTimer
    private var bridge: FFmpegDecoderBridge?
    private var isCancelled = false
    private var nextOperationID: UInt64 = 0
    private var activeOperationID: UInt64?
    private var activeDeadlineNanos: UInt64 = 0
    private var activeTimeoutHandler: (@Sendable () -> Void)?

    init(laneKind: LaneKind = .playback) {
        lane = laneKind == .playback ? Self.playbackLane : Self.probeLane
        let timer = DispatchSource.makeTimerSource(queue: Self.watchdogQueue)
        watchdog = timer
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.fireTimeoutIfNeeded() }
        timer.resume()
    }

    deinit { watchdog.cancel() }

    func open(_ url: URL) async throws -> TimeInterval {
        try await performBlocking {
            let bridge = try FFmpegDecoderBridge(
                url: url,
                ioTimeout: Self.bridgeIOTimeout
            )
            guard self.install(bridge) else { throw CancellationError() }
            return bridge.fileInfo.duration
        }
    }

    func probe(_ url: URL) async throws -> FFmpegFileInfoSnapshot {
        try await performBlocking {
            let info = try FFmpegDecoderBridge.probeURL(url)
            return FFmpegFileInfoSnapshot(
                duration: info.duration,
                sampleRate: info.sampleRate,
                channelCount: info.channelCount,
                bitDepth: info.bitDepth,
                bitRateKbps: info.bitRateKbps,
                codecName: info.codecName
            )
        }
    }

    func canDecode(_ url: URL) async throws -> Bool {
        try await performBlocking {
            try FFmpegDecoderBridge.decodeSupport(for: url).boolValue
        }
    }

    func containsDTSSync(_ url: URL) async throws -> Bool {
        try await performBlocking {
            try FFmpegDecoderBridge.dtsSyncResult(for: url).boolValue
        }
    }

    func seek(to time: TimeInterval) async throws {
        try await performBlocking {
            let bridge = try self.requireBridge()
            _ = try bridge.seek(toTime: time)
        }
    }

    func readNextBuffer() async throws -> FFmpegReadSnapshot {
        try await performBlocking {
            let result = try self.requireBridge().readNextBuffer()
            return FFmpegReadSnapshot(
                buffer: result.buffer,
                presentationTime: result.presentationTime,
                hasPresentationTime: result.hasPresentationTime
            )
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let bridge = bridge
        lock.unlock()
        bridge?.cancel()
    }

    private func install(_ bridge: FFmpegDecoderBridge) -> Bool {
        lock.lock()
        if isCancelled {
            lock.unlock()
            bridge.cancel()
            return false
        }
        self.bridge = bridge
        lock.unlock()
        return true
    }

    private func requireBridge() throws -> FFmpegDecoderBridge {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, let bridge else { throw CancellationError() }
        return bridge
    }

    private func performBlocking<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        guard !lane.isUnavailable else { throw URLError(.timedOut) }
        let race = FFmpegOperationRace<Value>()
        let operationToken = UUID()
        let operationID = registerTimeout { [weak self, lane] in
            if race.resolveFromControl(.failure(URLError(.timedOut)), onStarted: {
                if lane.markUnavailable(for: operationToken) {
                    plog("FFmpeg \(lane.name) I/O operation exceeded 16s; opening circuit until the blocked worker returns")
                }
            }) {
                self?.cancel()
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                lane.queue.async { [self, lane] in
                    // Queue wait is bounded too, but once this operation owns
                    // the lane it receives a fresh full I/O budget. Otherwise
                    // a healthy request queued behind a 15-second cooperative
                    // timeout would start with only about one second remaining.
                    // If the queue-wait deadline already won, its handler is
                    // about to resolve the continuation. Do not start the
                    // operation in that narrow handoff window: doing so would
                    // make the stale timeout look like an in-flight I/O stall
                    // and unnecessarily open the lane circuit.
                    guard refreshTimeout(for: operationID) else { return }
                    guard race.begin() else {
                        finishTimeout(for: operationID)
                        return
                    }
                    let result = Result { try operation() }
                    finishTimeout(for: operationID)
                    race.resolve(result)
                    if lane.markAvailable(for: operationToken) {
                        plog("FFmpeg \(lane.name) I/O worker returned; closing circuit")
                    }
                }
            }
        } onCancel: {
            self.finishTimeout(for: operationID)
            if race.resolveFromControl(.failure(CancellationError()), onStarted: {
                if self.lane.markUnavailable(for: operationToken) {
                    plog("FFmpeg \(self.lane.name) I/O operation was cancelled while blocked; opening circuit until the worker returns")
                }
            }) {
                self.cancel()
            }
        }
    }

    private func registerTimeout(
        _ handler: @escaping @Sendable () -> Void
    ) -> UInt64 {
        lock.lock()
        nextOperationID &+= 1
        let operationID = nextOperationID
        activeOperationID = operationID
        let timeoutNanos = UInt64(Self.outerOperationTimeout * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        activeDeadlineNanos = now > UInt64.max - timeoutNanos
            ? UInt64.max : now + timeoutNanos
        activeTimeoutHandler = handler
        lock.unlock()
        return operationID
    }

    private func finishTimeout(for operationID: UInt64) {
        lock.lock()
        if activeOperationID == operationID {
            activeOperationID = nil
            activeDeadlineNanos = 0
            activeTimeoutHandler = nil
        }
        lock.unlock()
    }

    private func refreshTimeout(for operationID: UInt64) -> Bool {
        lock.lock()
        guard activeOperationID == operationID else {
            lock.unlock()
            return false
        }
        let timeoutNanos = UInt64(Self.outerOperationTimeout * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        activeDeadlineNanos = now > UInt64.max - timeoutNanos
            ? UInt64.max : now + timeoutNanos
        lock.unlock()
        return true
    }

    private func fireTimeoutIfNeeded() {
        lock.lock()
        guard activeOperationID != nil,
              activeDeadlineNanos > 0,
              DispatchTime.now().uptimeNanoseconds >= activeDeadlineNanos else {
            lock.unlock()
            return
        }
        activeOperationID = nil
        activeDeadlineNanos = 0
        let handler = activeTimeoutHandler
        activeTimeoutHandler = nil
        lock.unlock()
        handler?()
    }
}

private final class FFmpegInputBufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        defer { buffer = nil }
        return buffer
    }
}

/// Broad compatibility fallback built on the LGPL-only FFmpeg runtime.
/// SFBAudioEngine remains the first choice for formats it supports; this
/// decoder covers DTS/DTS-HD, DTS-CD WAV, Dolby, WMA/ATRAC and other formats,
/// and also acts as the content-probing last resort for mislabeled files.
final class FFmpegAudioDecoder: PrimuseAudioDecoder {
    static let preferredExtensions: Set<String> = [
        "aac", "dts", "dtshd", "ac3", "eac3", "ec3", "mlp", "truehd", "thd",
        "wma", "asf", "xma", "oma", "aa3", "at3", "atrac", "amr",
        "awb", "tak", "tta", "wv", "ape", "mpc", "mpp", "shn", "spx",
        "qoa", "dsf", "dff", "dtswav"
    ]

    func canDecode(url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        // This synchronous protocol hook must never touch a potentially dead
        // mounted filesystem. Content sniffing is routed through the bounded
        // async probe lane by playback, scanning and download call sites.
        return Self.preferredExtensions.contains(ext)
    }

    func canDecodeAsync(url: URL) async throws -> Bool {
        guard url.isFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        if Self.preferredExtensions.contains(ext) { return true }
        let worker = FFmpegBridgeWorker(laneKind: .probe)
        if ext == "wav" {
            return try await worker.containsDTSSync(url)
        }
        return try await worker.canDecode(url)
    }

    static func dataContainsDTSSync(_ data: Data) -> Bool {
        FFmpegDecoderBridge.dataContainsDTSSync(data)
    }

    func fileInfo(for url: URL) async throws -> AudioFileInfo {
        let info = try await FFmpegBridgeWorker(laneKind: .probe).probe(url)
        return AudioFileInfo(
            duration: info.duration,
            sampleRate: info.sampleRate,
            channelCount: info.channelCount,
            bitDepth: info.bitDepth > 0 ? info.bitDepth : nil,
            bitRate: info.bitRateKbps > 0 ? info.bitRateKbps : nil,
            format: info.codecName.uppercased()
        )
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat
    ) -> AudioBufferStream {
        decode(
            from: url,
            outputFormat: outputFormat,
            startingAt: nil,
            onResolveSourceLength: nil
        )
    }

    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AudioBufferStream {
        decode(
            from: url,
            outputFormat: outputFormat,
            startingAt: nil,
            onResolveSourceLength: onResolveSourceLength
        )
    }

    /// Opens one decoder session and performs a demuxer-level seek before
    /// yielding PCM. This avoids decoding an entire album image from frame zero.
    func decode(
        from url: URL,
        outputFormat: AVAudioFormat,
        startingAt startTime: TimeInterval?,
        onResolveSourceLength: (@Sendable (TimeInterval) -> Void)?
    ) -> AudioBufferStream {
        AudioBufferStreamFactory.make { continuation in
            let worker = FFmpegBridgeWorker()
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let duration = try await worker.open(url)
                    if duration > 0 { onResolveSourceLength?(duration) }
                    if let startTime, startTime > 0 {
                        try await worker.seek(to: startTime)
                    }

                    var converter: AVAudioConverter?
                    var converterSourceFormat: AVAudioFormat?
                    var exactSeekTarget = startTime.flatMap { $0 > 0 ? $0 : nil }
                    while !Task.isCancelled {
                        let result = try await worker.readNextBuffer()
                        guard var sourceBuffer = result.buffer else { break }
                        if sourceBuffer.frameLength == 0 { continue }
                        if let target = exactSeekTarget,
                           result.hasPresentationTime,
                           sourceBuffer.format.sampleRate > 0 {
                            let bufferStart = result.presentationTime
                            let bufferEnd = bufferStart
                                + Double(sourceBuffer.frameLength) / sourceBuffer.format.sampleRate
                            if bufferEnd <= target {
                                continue
                            }
                            if bufferStart < target {
                                let skip = AVAudioFrameCount(
                                    ((target - bufferStart) * sourceBuffer.format.sampleRate)
                                        .rounded(.down)
                                )
                                if skip < sourceBuffer.frameLength {
                                    sourceBuffer = try Self.slice(
                                        sourceBuffer,
                                        skipping: skip
                                    )
                                }
                            }
                            exactSeekTarget = nil
                        } else if exactSeekTarget != nil {
                            // A demuxer without timestamps can still perform
                            // its native seek; it just cannot be sample-trimmed.
                            exactSeekTarget = nil
                        }

                        if let existingConverter = converter,
                           converterSourceFormat != sourceBuffer.format {
                            for output in try Self.drain(
                                converter: existingConverter,
                                outputFormat: outputFormat
                            ) {
                                try await AudioBufferStreamFactory.yieldWithBackpressure(
                                    output,
                                    to: continuation
                                )
                            }
                            converter = nil
                            converterSourceFormat = nil
                        }

                        let outputBuffer: AVAudioPCMBuffer
                        if sourceBuffer.format == outputFormat {
                            outputBuffer = sourceBuffer
                        } else {
                            if converter == nil || converterSourceFormat != sourceBuffer.format {
                                guard let newConverter = AVAudioConverter(
                                    from: sourceBuffer.format,
                                    to: outputFormat
                                ) else {
                                    throw AudioDecoderError.converterCreationFailed
                                }
                                converter = newConverter
                                converterSourceFormat = sourceBuffer.format
                            }
                            guard let converter else {
                                throw AudioDecoderError.converterCreationFailed
                            }
                            outputBuffer = try Self.convert(
                                sourceBuffer,
                                to: outputFormat,
                                using: converter
                            )
                        }
                        if outputBuffer.frameLength > 0 {
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                outputBuffer,
                                to: continuation
                            )
                        }
                    }
                    if let converter {
                        for output in try Self.drain(
                            converter: converter,
                            outputFormat: outputFormat
                        ) {
                            try await AudioBufferStreamFactory.yieldWithBackpressure(
                                output,
                                to: continuation
                            )
                        }
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                task.cancel()
            }
        }
    }

    private static func convert(
        _ source: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(1, capacity)
        ) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let input = FFmpegInputBufferBox(source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if let buffer = input.take() {
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        if let conversionError { throw conversionError }
        if status == .error {
            throw AudioDecoderError.decodingFailed("FFmpeg PCM conversion failed")
        }
        return output
    }

    private static func drain(
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) throws -> [AVAudioPCMBuffer] {
        var drained: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 8192
            ) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            if status == .error {
                throw AudioDecoderError.decodingFailed("FFmpeg PCM converter drain failed")
            }
            if output.frameLength > 0 { drained.append(output) }
            if status == .endOfStream || output.frameLength == 0 { return drained }
        }
    }

    private static func slice(
        _ source: AVAudioPCMBuffer,
        skipping: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let count = source.frameLength - skipping
        guard count > 0,
              let destination = AVAudioPCMBuffer(
                  pcmFormat: source.format,
                  frameCapacity: count
              ) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        destination.frameLength = count
        let bytesPerFrame = Int(
            source.format.streamDescription.pointee.mBytesPerFrame
        )
        guard bytesPerFrame > 0 else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        let sourceOffset = Int(skipping) * bytesPerFrame
        let byteCount = Int(count) * bytesPerFrame
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  sourceOffset + byteCount
                    <= Int(sourceBuffers[index].mDataByteSize) else {
                throw AudioDecoderError.bufferAllocationFailed
            }
            memcpy(
                destinationData,
                sourceData.advanced(by: sourceOffset),
                byteCount
            )
        }
        return destination
    }
}
