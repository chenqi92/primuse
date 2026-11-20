@preconcurrency import AVFoundation
import Foundation
import Observation
import PrimuseKit

// 有声内容的「智能速度」和「语音增强」(REQ-174)。
//
// 智能速度挂在本机解码流的最后一站(`SmartSpeedStream`),只给有声内容、只在开关打开时挂;拿掉的帧
// 由播放节点登记处(`PlayerNodeRegistry`)记成节点时间线上的接缝,`AudioEngine.currentTime` 补回来,
// 进度、锁屏、续播位置、字幕、章节、跳转都照文件时间。走系统播放器的(视频播客)、Apple Music、
// 投屏不经过这条解码流,不生效。
//
// 语音增强不加节点:效果链里的均衡和压缩器在有声内容时换成说话用的设定,两者各自有不咔哒的过渡。

private final class SmartSpeedIteratorBox: @unchecked Sendable {
    private var iterator: AudioBufferStream.AsyncIterator

    init(_ iterator: AudioBufferStream.AsyncIterator) {
        self.iterator = iterator
    }

    func next() async throws -> AVAudioPCMBuffer? {
        try await iterator.next()
    }
}

/// 缩短有声内容里过长停顿的流。必须是排进节点前的最后一站:它交出的缓冲带着接缝登记,
/// 后面再切片、拷贝就对不上了。
enum SmartSpeedStream {
    /// - Parameter passthroughFrames: 开头这么多帧原样交出、不参与判定。跳转时解码器没能
    ///   自己定位、要按整块跳过前面那段的,跳过的计数得照原始帧算。
    static func shorteningPauses(
        _ source: AudioBufferStream,
        policy: SmartSpeedPolicy = .standard,
        passthroughFrames: Int64 = 0,
        registry: PlayerNodeRegistry
    ) -> AudioBufferStream {
        let iteratorBox = SmartSpeedIteratorBox(source.makeAsyncIterator())
        return AudioBufferStreamFactory.make { continuation in
            let task = Task {
                var shortener: SmartSpeedSilenceShortener?
                var shortenerFormat: AVAudioFormat?
                var passthroughRemaining = passthroughFrames

                func yieldBuffer(_ buffer: AVAudioPCMBuffer) async throws {
                    try await AudioBufferStreamFactory.yieldWithBackpressure(buffer, to: continuation)
                }

                func yieldChunk(_ chunk: SmartSpeedChunk, format: AVAudioFormat) async throws {
                    guard chunk.frameCount > 0 else { return }
                    let buffer = try makeBuffer(from: chunk, format: format)
                    registry.annotateSmartSpeedCuts(chunk.cuts, for: buffer)
                    try await yieldBuffer(buffer)
                }

                /// 格式变了或换成处理不了的格式:压着的部分先交出。
                func flush() async throws {
                    guard var current = shortener, let format = shortenerFormat else { return }
                    shortener = nil
                    shortenerFormat = nil
                    try await yieldChunk(current.finish(), format: format)
                }

                do {
                    while let buffer = try await iteratorBox.next() {
                        try Task.checkCancellation()
                        let frameCount = Int(buffer.frameLength)
                        guard frameCount > 0 else { continue }
                        if passthroughRemaining > 0 {
                            passthroughRemaining -= Int64(frameCount)
                            try await yieldBuffer(buffer)
                            continue
                        }
                        let format = buffer.format
                        guard canShorten(format), let data = buffer.floatChannelData else {
                            try await flush()
                            try await yieldBuffer(buffer)
                            continue
                        }
                        if let previous = shortenerFormat, previous != format {
                            try await flush()
                        }
                        var current = shortener ?? SmartSpeedSilenceShortener(
                            policy: policy,
                            sampleRate: format.sampleRate,
                            channelCount: Int(format.channelCount)
                        )
                        // 先放手再改,内部的数组不必写时复制。
                        shortener = nil
                        let channels = (0..<Int(format.channelCount)).map {
                            UnsafeBufferPointer(start: UnsafePointer(data[$0]), count: frameCount)
                        }
                        let chunk = current.process(channels: channels)
                        shortener = current
                        shortenerFormat = format
                        try await yieldChunk(chunk, format: format)
                    }
                    try await flush()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 效果链的格式:32 位浮点、非交错。别的格式(高保真直通、DSD)原样放过。
    private static func canShorten(_ format: AVAudioFormat) -> Bool {
        format.commonFormat == .pcmFormatFloat32
            && !format.isInterleaved
            && format.channelCount > 0
            && format.sampleRate > 0
    }

    private static func makeBuffer(from chunk: SmartSpeedChunk, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = chunk.frameCount
        guard frameCount > 0,
              let capacity = AVAudioFrameCount(exactly: frameCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let destination = buffer.floatChannelData else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        buffer.frameLength = capacity
        let channelCount = min(Int(format.channelCount), chunk.channels.count)
        for channel in 0..<channelCount {
            chunk.channels[channel].withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                destination[channel].update(from: base, count: min(source.count, frameCount))
            }
        }
        return buffer
    }
}

/// 「已节省时间」:智能速度一共替你省下的收听时间,存在本机。
@MainActor
@Observable
final class SpokenWordSmartSpeedSavings {
    static let shared = SpokenWordSmartSpeedSavings()

    private(set) var totalSeconds: TimeInterval
    @ObservationIgnored private var unsavedSeconds: TimeInterval = 0
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "primuse_spoken_word_smart_speed_saved_seconds"
    /// 攒够这么多再写盘,不每一拍都写。
    private static let persistInterval: TimeInterval = 15

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.key)
        totalSeconds = stored.isFinite && stored > 0 ? stored : 0
    }

    func add(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        totalSeconds += seconds
        unsavedSeconds += seconds
        if unsavedSeconds >= Self.persistInterval { persist() }
    }

    func persist() {
        guard unsavedSeconds > 0 else { return }
        defaults.set(totalSeconds, forKey: Self.key)
        unsavedSeconds = 0
    }

    /// 设置里显示的「已节省」:几小时几分,不到一分钟显示秒。
    var formattedTotal: String {
        let seconds = Int64(totalSeconds.rounded(.down))
        let style: Duration.UnitsFormatStyle
        if seconds >= 3_600 {
            style = .units(allowed: [.hours, .minutes], width: .abbreviated)
        } else if seconds >= 60 {
            style = .units(allowed: [.minutes], width: .abbreviated)
        } else {
            style = .units(allowed: [.seconds], width: .abbreviated, zeroValueUnits: .show(length: 1))
        }
        return Duration.seconds(seconds).formatted(style)
    }
}

extension AudioPlayerService {
    // MARK: - Smart speed

    /// 本机解码流排进节点前的最后一站:有声内容、开关打开时缩短长停顿,否则原样返回。
    func smartSpeedProcessed(
        _ stream: AudioBufferStream,
        for song: Song,
        passthroughFrames: Int64 = 0
    ) -> AudioBufferStream {
        guard playbackSettings.spokenWordSmartSpeedEnabled,
              SpokenWordStore.shared.isSpokenWord(song) else { return stream }
        return SmartSpeedStream.shorteningPauses(
            stream,
            passthroughFrames: max(0, passthroughFrames),
            registry: audioEngine.nodeRegistry
        )
    }

    /// 播放时钟每一拍:把新拿掉的停顿记进「已节省」;锁屏、车机按发布的速度自己往前推进度,
    /// 拿掉的累计超过一秒就重发一次,免得那边越走越落后。
    func recordSmartSpeedProgress() {
        guard currentItemIsSpokenWord, !isCrossfading, !isSystemMediaPlaybackActive else { return }
        let skipped = audioEngine.primarySmartSpeedSkippedDuration
        let saved = smartSpeedSavingsMeter.record(skipped: skipped, rate: Double(requestedPlaybackRate))
        if saved > 0 {
            SpokenWordSmartSpeedSavings.shared.add(saved)
        }
        if skipped < smartSpeedNowPlayingBaseline {
            // 跳转、换条目后从零重新算。
            smartSpeedNowPlayingBaseline = skipped
        } else if skipped - smartSpeedNowPlayingBaseline >= Self.smartSpeedNowPlayingDriftLimit {
            smartSpeedNowPlayingBaseline = skipped
            updateNowPlayingInfo()
        }
    }

    static let smartSpeedNowPlayingDriftLimit: TimeInterval = 1

    /// 播放位置减去智能速度拿掉的部分:这一段实际放到了哪里。只用来判断「刚开播、还在开头」。
    var spokenWordHeardPosition: TimeInterval {
        guard !isSystemMediaPlaybackActive else { return currentTime }
        return max(0, currentTime - audioEngine.primarySmartSpeedSkippedDuration)
    }

    // MARK: - Voice boost

    /// 有声内容在放、语音增强打开时,均衡和压缩器换成说话用的设定;其余时候照用户自己的设置。
    func applySpokenWordVoiceBoost() {
        let active = currentItemIsSpokenWord && playbackSettings.spokenWordVoiceBoostEnabled
        audioEffectsService.voiceBoostActive = active
        equalizerService.voiceBoostActive = active
    }

    // MARK: - Settings

    /// 两个开关改了马上生效:语音增强直接切;智能速度要换一条解码流,有声内容正在本机放时
    /// 在原位重建一次(和换输出模式一样)。
    func observeSpokenWordListeningAids() {
        let smartSpeedEnabled = playbackSettings.spokenWordSmartSpeedEnabled
        withObservationTracking {
            _ = playbackSettings.spokenWordSmartSpeedEnabled
            _ = playbackSettings.spokenWordVoiceBoostEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySpokenWordVoiceBoost()
                if self.playbackSettings.spokenWordSmartSpeedEnabled != smartSpeedEnabled,
                   self.currentItemIsSpokenWord,
                   !self.isCastingMode,
                   self.canRebuildOutputPipelineForSettingsChange {
                    self.seek(to: self.currentTime, startPlaying: self.isPlaying)
                }
                self.observeSpokenWordListeningAids()
            }
        }
    }
}
