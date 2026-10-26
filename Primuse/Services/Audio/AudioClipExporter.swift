import AVFoundation
import Foundation
import PrimuseKit

/// 把一首歌的一段写成 M4A(「铃声与导出」)。
///
/// 解码沿用播放用的两套解码器,能播的格式都能导出;歌曲不在这台设备上时先经音乐源
/// 取一份整首。窗口、淡入淡出、输出格式与文件名的规则在 `AudioClipExportPolicy`。
enum AudioClipExporter {
    enum Phase: Equatable, Sendable {
        case fetchingAudio
        case writing
    }

    enum Failure: LocalizedError {
        case audioUnavailable
        case unreadableAudio
        case tooShort

        var errorDescription: String? {
            switch self {
            case .audioUnavailable: String(localized: "clip_export_error_unavailable")
            case .unreadableAudio: String(localized: "clip_export_error_unreadable")
            case .tooShort: String(localized: "clip_export_error_too_short")
            }
        }
    }

    /// 整首歌在这台设备上的一份文件。`isTemporary` 的是为这一次取来的,用完删掉。
    struct WholeFile: Sendable {
        let url: URL
        let isTemporary: Bool

        func discard() {
            guard isTemporary else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 已经在这台设备上的整首:本机源自己的文件,或完整的缓存副本(原文件优先,
    /// 其次是离线精简副本)。不下载、不拿播放租约。
    @MainActor
    static func onDeviceFile(for song: Song, sourceManager: SourceManager) async -> URL? {
        if let local = await sourceManager.directLocalFileURL(for: song),
           FileManager.default.isReadableFile(atPath: local.path) {
            return local
        }
        guard sourceManager.hasUsableCachedAudioForPlayback(song) else { return nil }
        return sourceManager.cachedPlaybackURL(for: song)
    }

    /// 整首歌的一份文件:在这台设备上的直接用,否则经音乐源取一份(和听歌识词同一条路)。
    @MainActor
    static func wholeFile(for song: Song, sourceManager: SourceManager) async throws -> WholeFile {
        if let onDevice = await onDeviceFile(for: song, sourceManager: sourceManager) {
            return WholeFile(url: onDevice, isTemporary: false)
        }
        let resolved: URL
        do {
            resolved = try await sourceManager.resolveFullDownloadSourceURL(for: song)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.audioUnavailable
        }
        if resolved.isFileURL {
            guard FileManager.default.isReadableFile(atPath: resolved.path) else { throw Failure.audioUnavailable }
            return WholeFile(url: resolved, isTemporary: false)
        }
        let fileExtension = resolved.pathExtension.isEmpty
            ? song.fileFormat.rawValue.lowercased()
            : resolved.pathExtension
        return WholeFile(url: try await download(resolved, fileExtension: fileExtension), isTemporary: true)
    }

    /// 写出 `song` 的 [start, end] 这一段(歌曲自己的时间轴,CUE 分轨从它在映像里的起点算),
    /// 返回临时目录里的 M4A,文件名就是铃声在设置里显示的名字。
    @MainActor
    static func export(
        song: Song,
        start: TimeInterval,
        end: TimeInterval,
        purpose: AudioClipExportPolicy.Purpose,
        appliesFades: Bool,
        sourceManager: SourceManager,
        onPhase: @escaping @MainActor (Phase) -> Void
    ) async throws -> URL {
        let whole = song.withoutAppliedPlaybackRange
        guard let window = AudioClipExportPolicy.exportedWindow(
            start: start,
            end: end,
            songDuration: whole.duration,
            purpose: purpose
        ) else { throw Failure.tooShort }
        removeStaleExports()
        onPhase(.fetchingAudio)
        let file = try await wholeFile(for: whole, sourceManager: sourceManager)
        defer { file.discard() }
        try Task.checkCancellation()
        onPhase(.writing)
        let fileName = AudioClipExportPolicy.fileName(title: whole.title, artist: whole.artistName)
        let mediaStart = (whole.cueStartTime ?? 0) + window.start
        let length = window.end - window.start
        let fades = appliesFades ? AudioClipExportPolicy.fades(forLength: length) : .off
        let source = file.url
        return try await Task.detached(priority: .userInitiated) {
            try await write(
                source: source,
                mediaStart: mediaStart,
                length: length,
                fades: fades,
                fileName: fileName
            )
        }.value
    }

    // MARK: - Writing

    private static func write(
        source: URL,
        mediaStart: TimeInterval,
        length: TimeInterval,
        fades: AudioClipExportPolicy.Fades,
        fileName: String
    ) async throws -> URL {
        let routed = await FileFormatRouter.decoder(for: source)
        var decoders: [any PrimuseAudioDecoder] = [routed]
        // SFB 读不了的(DSD128 以上等)交给 FFmpeg,和离线精简副本同一个顺序。
        let ffmpeg = FFmpegAudioDecoder()
        if routed is NativeAudioDecoder, ffmpeg.canDecode(url: source) {
            decoders.append(ffmpeg)
        }
        var lastError: Error = Failure.unreadableAudio
        for decoder in decoders {
            try Task.checkCancellation()
            do {
                return try await write(
                    source: source,
                    decoder: decoder,
                    mediaStart: mediaStart,
                    length: length,
                    fades: fades,
                    fileName: fileName
                )
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                plog("✂️ Clip export: \(type(of: decoder)) failed: \(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError is Failure ? lastError : Failure.unreadableAudio
    }

    private static func write(
        source: URL,
        decoder: any PrimuseAudioDecoder,
        mediaStart: TimeInterval,
        length: TimeInterval,
        fades: AudioClipExportPolicy.Fades,
        fileName: String
    ) async throws -> URL {
        let info = try await decoder.fileInfo(for: source)
        let sampleRate = AudioClipExportPolicy.outputSampleRate(sourceSampleRate: info.sampleRate)
        let channelCount = AudioClipExportPolicy.outputChannelCount(sourceChannelCount: info.channelCount)
        let directory = exportDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // AVAudioFile 按扩展名决定容器。
        let destination = directory.appendingPathComponent(fileName)
        var keepsFile = false
        defer { if !keepsFile { try? FileManager.default.removeItem(at: directory) } }

        let expectedFrames = AVAudioFramePosition((length * sampleRate).rounded())
        var writtenFrames: AVAudioFramePosition = 0
        do {
            let output = try makeOutputFile(at: destination, sampleRate: sampleRate, channelCount: channelCount)
            defer { output.close() }
            let format = output.processingFormat
            // 能从起点直接开解的解码器从起点开;别的从头解、丢掉起点之前的。
            var framesToSkip: AVAudioFramePosition = 0
            let stream: AudioBufferStream
            let startTime: TimeInterval? = mediaStart > 0 ? mediaStart : nil
            if let native = decoder as? NativeAudioDecoder {
                stream = native.decode(from: source, outputFormat: format, startingAt: startTime, onResolveSourceLength: nil)
            } else if let ffmpeg = decoder as? FFmpegAudioDecoder {
                stream = ffmpeg.decode(from: source, outputFormat: format, startingAt: startTime, onResolveSourceLength: nil)
            } else {
                stream = decoder.decode(from: source, outputFormat: format)
                framesToSkip = AVAudioFramePosition((mediaStart * sampleRate).rounded())
            }
            for try await buffer in stream {
                try Task.checkCancellation()
                var offset = AVAudioFrameCount(0)
                if framesToSkip > 0 {
                    let skipped = min(AVAudioFramePosition(buffer.frameLength), framesToSkip)
                    framesToSkip -= skipped
                    offset = AVAudioFrameCount(skipped)
                }
                let available = AVAudioFramePosition(buffer.frameLength) - AVAudioFramePosition(offset)
                let take = min(available, expectedFrames - writtenFrames)
                guard take > 0 else {
                    if writtenFrames >= expectedFrames { break }
                    continue
                }
                guard let chunk = slice(buffer, from: offset, count: AVAudioFrameCount(take)) else {
                    throw Failure.unreadableAudio
                }
                applyFades(fades, to: chunk, startingAt: writtenFrames, sampleRate: sampleRate, length: length)
                try output.write(from: chunk)
                writtenFrames += take
                if writtenFrames >= expectedFrames { break }
            }
        }
        try Task.checkCancellation()

        // 解码器碰到坏文件可能提前结束而不报错:写进去的、读回来的都要对得上这一段的长度。
        let writtenLength = Double(writtenFrames) / sampleRate
        guard AudioClipExportPolicy.writtenLengthIsComplete(expected: length, actual: writtenLength) else {
            plog(String(format: "✂️ Clip export: wrote %.2fs of %.2fs", writtenLength, length))
            throw Failure.unreadableAudio
        }
        let check = try AVAudioFile(forReading: destination)
        let encodedLength = check.fileFormat.sampleRate > 0 ? Double(check.length) / check.fileFormat.sampleRate : 0
        guard AudioClipExportPolicy.writtenLengthIsComplete(expected: writtenLength, actual: encodedLength) else {
            plog(String(format: "✂️ Clip export: encoded %.2fs of %.2fs", encodedLength, writtenLength))
            throw Failure.unreadableAudio
        }
        keepsFile = true
        plog(String(format: "✂️ Clip export: %.1fs at %.0f Hz × %d via %@", encodedLength, sampleRate, channelCount,
                    String(describing: type(of: decoder))))
        return destination
    }

    /// 编码器在某些采样率下不收某些码率,从高往低试。
    static func makeOutputFile(at url: URL, sampleRate: Double, channelCount: Int) throws -> AVAudioFile {
        var lastError: Error = Failure.unreadableAudio
        for bitRate in AudioClipExportPolicy.bitRateCandidates(channelCount: channelCount) {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: bitRate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            do {
                return try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: url)
            }
        }
        throw lastError
    }

    /// `buffer` 从 `offset` 起的 `count` 帧;整块都要时原样返回。
    private static func slice(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if offset == 0, count == buffer.frameLength { return buffer }
        guard let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let target = copy.floatChannelData else { return nil }
        let channels = Int(buffer.format.channelCount)
        for channel in 0..<channels {
            target[channel].update(from: source[channel].advanced(by: Int(offset)), count: Int(count))
        }
        copy.frameLength = count
        return copy
    }

    private static func applyFades(
        _ fades: AudioClipExportPolicy.Fades,
        to buffer: AVAudioPCMBuffer,
        startingAt firstFrame: AVAudioFramePosition,
        sampleRate: Double,
        length: TimeInterval
    ) {
        guard fades != .off, let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let fadeInEnd = fades.fadeIn
        let fadeOutStart = length - fades.fadeOut
        let blockStart = Double(firstFrame) / sampleRate
        let blockEnd = Double(firstFrame + AVAudioFramePosition(frameCount)) / sampleRate
        // 中间那一大段增益都是 1,不用逐帧算。
        guard blockStart < fadeInEnd || blockEnd > fadeOutStart else { return }
        for frame in 0..<frameCount {
            let time = Double(firstFrame + AVAudioFramePosition(frame)) / sampleRate
            guard time < fadeInEnd || time > fadeOutStart else { continue }
            let gain = AudioClipExportPolicy.gain(at: time, length: length, fades: fades)
            for channel in 0..<channelCount {
                channels[channel][frame] *= gain
            }
        }
    }

    // MARK: - Files

    static func exportDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Primuse-ClipExport", isDirectory: true)
    }

    /// 上一次导出留下的文件。刚导出的可能还在分享面板里用着,留一小时。
    static func removeStaleExports(olderThan age: TimeInterval = 3600) {
        let directory = exportDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    private nonisolated static func download(_ url: URL, fileExtension: String) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Failure.audioUnavailable }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(from: url)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Failure.audioUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.audioUnavailable
        }
        let directory = exportDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory
            .appendingPathComponent("source-" + UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
