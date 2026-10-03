import AVFoundation
import Darwin
import Foundation
import PrimuseKit

/// 离线缓存里的精简副本: 原文件缓存名加 `.compact.m4a`, 扩展属性里记着
/// 它是从多大的原文件转出来的。判定与命名在 `OfflineDownloadQualityPolicy`。
enum OfflineCompactArtifact {
    static func url(forCanonical canonical: URL) -> URL {
        URL(fileURLWithPath: canonical.path + OfflineDownloadQualityPolicy.compactFileSuffix)
    }

    /// 播放层用它认出「这是转换后的副本」: 那时 `Song` 上的格式、采样率描述的
    /// 是原文件, 不是手上这份 AAC。
    static func isCompactURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasSuffix(OfflineDownloadQualityPolicy.compactFileSuffix)
    }

    /// 副本可以代表这首歌: 文件在, 且记录的原文件大小与资料库现在的大小对得上。
    /// `preservesExisting` 时(保留旧版本等新版本下完)只看文件在不在。
    static func isUsable(
        at url: URL,
        expectedOriginalByteCount: Int64,
        preservesExisting: Bool
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if preservesExisting { return true }
        guard let record = readRecord(at: url) else { return false }
        return record.matches(expectedOriginalByteCount: expectedOriginalByteCount)
    }

    static func readRecord(at url: URL) -> OfflineCompactArtifactRecord? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = getxattr(
            url.path,
            OfflineDownloadQualityPolicy.compactRecordAttributeName,
            &buffer,
            buffer.count,
            0,
            0
        )
        guard count > 0, count <= buffer.count else { return nil }
        return OfflineCompactArtifactRecord(
            serialized: String(decoding: buffer.prefix(count), as: UTF8.self)
        )
    }

    /// 把校验过的临时文件装到副本位置并写上记录。记录写不上就不留副本 ——
    /// 没有记录的副本永远不会被认, 只会白占空间。
    static func install(
        staging: URL,
        at destination: URL,
        record: OfflineCompactArtifactRecord
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        let value = Array(record.serialized.utf8)
        let status = value.withUnsafeBytes { bytes in
            setxattr(
                destination.path,
                OfflineDownloadQualityPolicy.compactRecordAttributeName,
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        guard status == 0 else {
            let code = errno
            try? fileManager.removeItem(at: destination)
            throw OfflineAudioCompactor.CompactionError.recordUnavailable(code)
        }
    }
}

/// 把离线缓存里的原文件在本机转成 AAC。
///
/// 只负责「原文件 → 校验过的临时 m4a」; 安装副本、删原文件与记账由
/// `SourceManager` 在持有这组缓存文件的锁时完成。解码沿用播放用的两套
/// 解码器, 所以能播的格式都能转。
enum OfflineAudioCompactor {
    struct Output: Sendable {
        /// 临时目录里的 m4a, 调用方负责装好或删掉。
        let url: URL
        let byteCount: Int64
        let record: OfflineCompactArtifactRecord
        let encodedBitRate: Int
    }

    /// 只进日志, 不给用户看: 转换失败时原文件照常保留, 界面上没有任何变化。
    enum CompactionError: Error, CustomStringConvertible {
        case multichannelSource(Int)
        case unknownDuration
        case incompleteOutput(expected: Double, actual: Double)
        case notSmaller(original: Int64, compact: Int64)
        case recordUnavailable(Int32)

        var description: String {
            switch self {
            case .multichannelSource(let channels):
                return "multichannel source (\(channels) ch) is kept as is"
            case .unknownDuration:
                return "source duration unknown"
            case .incompleteOutput(let expected, let actual):
                return String(format: "incomplete output %.1fs of %.1fs", actual, expected)
            case .notSmaller(let original, let compact):
                return "compact copy \(compact / 1024)KB is not smaller than original \(original / 1024)KB"
            case .recordUnavailable(let code):
                return "extended attribute unavailable (errno \(code))"
            }
        }
    }

    static func stagingDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_offline_compact", isDirectory: true)
    }

    /// - Parameters:
    ///   - expectedDuration: 资料库里的时长, 解码器报不出时长时用它校验。
    ///     整轨 CUE 的分轨传 nil —— 它只是映像里的一段。
    static func encode(
        original: URL,
        originalByteCount: Int64,
        targetKbps: Int,
        expectedDuration: TimeInterval?
    ) async throws -> Output {
        let routed = await FileFormatRouter.decoder(for: original)
        var decoders: [any PrimuseAudioDecoder] = [routed]
        // SFB 的 DSD 转 PCM 只支持 DSD64, 播放时更高的码率也是交给 FFmpeg。
        let ffmpeg = FFmpegAudioDecoder()
        if routed is NativeAudioDecoder, ffmpeg.canDecode(url: original) {
            decoders.append(ffmpeg)
        }
        var lastError: Error = CompactionError.unknownDuration
        for decoder in decoders {
            try Task.checkCancellation()
            do {
                return try await encode(
                    original: original,
                    originalByteCount: originalByteCount,
                    decoder: decoder,
                    targetKbps: targetKbps,
                    expectedDuration: expectedDuration
                )
            } catch let error as CompactionError {
                switch error {
                case .multichannelSource, .notSmaller:
                    // 换个解码器结论也一样。
                    throw error
                case .unknownDuration, .incompleteOutput, .recordUnavailable:
                    lastError = error
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    private static func encode(
        original: URL,
        originalByteCount: Int64,
        decoder: any PrimuseAudioDecoder,
        targetKbps: Int,
        expectedDuration: TimeInterval?
    ) async throws -> Output {
        let info = try await decoder.fileInfo(for: original)
        guard let channelCount = OfflineDownloadQualityPolicy.encoderChannelCount(
            sourceChannelCount: info.channelCount
        ) else {
            throw CompactionError.multichannelSource(info.channelCount)
        }
        let sourceDuration = info.duration > 0 ? info.duration : (expectedDuration ?? 0)
        guard sourceDuration > 0 else { throw CompactionError.unknownDuration }

        let sampleRate = OfflineDownloadQualityPolicy.encoderSampleRate(
            sourceSampleRate: info.sampleRate
        )
        let bitRate = OfflineDownloadQualityPolicy.encoderBitRate(
            targetKbps: targetKbps,
            channelCount: channelCount,
            applicableBitRates: applicableBitRates(sampleRate: sampleRate, channelCount: channelCount)
        )

        let directory = stagingDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // AVAudioFile 按扩展名决定容器, 临时文件必须以 .m4a 结尾。
        let staging = directory.appendingPathComponent(UUID().uuidString + ".m4a")
        var keepsStaging = false
        defer {
            if !keepsStaging { try? FileManager.default.removeItem(at: staging) }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        var writtenFrames: AVAudioFramePosition = 0
        do {
            let file = try AVAudioFile(
                forWriting: staging,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            defer { file.close() }
            let stream = decoder.decode(from: original, outputFormat: file.processingFormat)
            for try await buffer in stream {
                try Task.checkCancellation()
                guard buffer.frameLength > 0 else { continue }
                try file.write(from: buffer)
                writtenFrames += AVAudioFramePosition(buffer.frameLength)
            }
        }
        try Task.checkCancellation()

        // 解码器碰到坏文件可能提前结束而不报错: 写进去的长度要对得上原文件,
        // 读回来的长度要对得上写进去的。
        let writtenDuration = Double(writtenFrames) / sampleRate
        guard OfflineDownloadQualityPolicy.durationIsComplete(
            expectedDuration: sourceDuration,
            actualDuration: writtenDuration
        ) else {
            throw CompactionError.incompleteOutput(expected: sourceDuration, actual: writtenDuration)
        }
        let check = try AVAudioFile(forReading: staging)
        let encodedDuration = check.fileFormat.sampleRate > 0
            ? Double(check.length) / check.fileFormat.sampleRate
            : 0
        guard OfflineDownloadQualityPolicy.durationIsComplete(
            expectedDuration: writtenDuration,
            actualDuration: encodedDuration
        ) else {
            throw CompactionError.incompleteOutput(expected: writtenDuration, actual: encodedDuration)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard OfflineDownloadQualityPolicy.compactIsWorthKeeping(
            originalByteCount: originalByteCount,
            compactByteCount: byteCount
        ) else {
            throw CompactionError.notSmaller(original: originalByteCount, compact: byteCount)
        }
        keepsStaging = true
        return Output(
            url: staging,
            byteCount: byteCount,
            record: OfflineCompactArtifactRecord(
                originalByteCount: originalByteCount,
                bitRateKbps: targetKbps
            ),
            encodedBitRate: bitRate
        )
    }

    /// AAC 编码器对这组采样率 / 声道数接受的码率。请求一个不在列表里的码率时
    /// 创建文件就会失败(单声道最高 256 kbps)。
    private static func applicableBitRates(sampleRate: Double, channelCount: Int) -> [Int] {
        guard let pcm = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        ) else { return [] }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aac = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: pcm, to: aac) else { return [] }
        return (converter.applicableEncodeBitRates ?? []).map(\.intValue)
    }

    /// 上次被打断留下的临时文件。
    static func removeStaleStagingFiles(olderThan age: TimeInterval = 3600) {
        let directory = stagingDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
