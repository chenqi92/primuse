import AVFoundation
import Foundation
import PrimuseKit

/// 把 AI 分离好的伴奏或人声写成一首 WAV 或 M4A(#362),分享出去或存到「文件」里当一首单独的歌用。
///
/// 人声直接取缓存里的人声轨;伴奏把原曲按分离时同一种解码重新解一遍,再减去人声轨
/// (`KaraokeStemExportPolicy`)。只认分离好的歌:分离要整首跑一遍模型,在卡拉OK舞台上做。
enum KaraokeStemExporter {
    enum Phase: Equatable, Sendable {
        case fetchingAudio
        case writing
    }

    enum Failure: LocalizedError {
        case notSeparated
        case unreadableAudio

        var errorDescription: String? {
            switch self {
            case .notSeparated: String(localized: "karaoke_export_error_not_separated")
            case .unreadableAudio: String(localized: "clip_export_error_unreadable")
            }
        }
    }

    /// 这部分在菜单里和文件名里的叫法。
    static func label(for part: KaraokeStemExportPolicy.Part) -> String {
        switch part {
        case .instrumental: String(localized: "karaoke_export_part_instrumental")
        case .vocals: String(localized: "karaoke_export_part_vocals")
        }
    }

    /// 菜单里各格式的叫法。
    static func title(for format: KaraokeStemExportPolicy.Format) -> String {
        switch format {
        case .wav: String(localized: "karaoke_export_format_wav")
        case .m4a: String(localized: "karaoke_export_format_m4a")
        }
    }

    /// 写出 `song` 的伴奏或人声,返回临时目录里的文件。
    @MainActor
    static func export(
        song: Song,
        part: KaraokeStemExportPolicy.Part,
        format: KaraokeStemExportPolicy.Format,
        sourceManager: SourceManager,
        onPhase: @escaping @MainActor (Phase) -> Void
    ) async throws -> URL {
        let separation = KaraokeSeparationService.shared
        guard separation.state(for: song) == .ready else { throw Failure.notSeparated }
        AudioClipExporter.removeStaleExports()
        let sampleRate = KaraokeSeparationService.modelSampleRate
        onPhase(part == .instrumental ? .fetchingAudio : .writing)
        guard let vocals = await separation.loadStemSamples(for: song, graphSampleRate: sampleRate) else {
            throw Failure.notSeparated
        }
        try Task.checkCancellation()
        var left = vocals.left
        var right = vocals.right
        if part == .instrumental {
            let file = try await KaraokeSeparationService.sourceAudioFile(for: song, sourceManager: sourceManager)
            let mix: (left: [Float], right: [Float])
            do {
                mix = try await KaraokeSeparationService.decodeForModel(
                    file: file,
                    start: song.cueStartTime,
                    end: song.cueEndTime
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.unreadableAudio
            }
            try Task.checkCancellation()
            onPhase(.writing)
            (left, right) = await Task.detached(priority: .userInitiated) {
                var mixLeft = mix.left
                var mixRight = mix.right
                KaraokeStemExportPolicy.subtractVocals(vocals.left, from: &mixLeft)
                KaraokeStemExportPolicy.subtractVocals(vocals.right, from: &mixRight)
                return (mixLeft, mixRight)
            }.value
        }
        try Task.checkCancellation()
        let fileName = KaraokeStemExportPolicy.fileName(
            title: song.title,
            artist: song.artistName,
            partLabel: label(for: part),
            format: format
        )
        let channels = (left, right)
        return try await Task.detached(priority: .userInitiated) {
            try write(left: channels.0, right: channels.1, sampleRate: sampleRate, format: format, fileName: fileName)
        }.value
    }

    private static func write(
        left: [Float],
        right: [Float],
        sampleRate: Double,
        format: KaraokeStemExportPolicy.Format,
        fileName: String
    ) throws -> URL {
        let frames = min(left.count, right.count)
        guard frames > 0 else { throw Failure.unreadableAudio }
        let directory = AudioClipExporter.exportDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        var keepsFile = false
        defer { if !keepsFile { try? FileManager.default.removeItem(at: directory) } }

        do {
            let output = try makeOutputFile(at: destination, sampleRate: sampleRate, format: format)
            defer { output.close() }
            let chunkFrames = 32_768
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: output.processingFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ), let target = buffer.floatChannelData else { throw Failure.unreadableAudio }
            var offset = 0
            while offset < frames {
                try Task.checkCancellation()
                let count = min(chunkFrames, frames - offset)
                left.withUnsafeBufferPointer { target[0].update(from: $0.baseAddress! + offset, count: count) }
                right.withUnsafeBufferPointer { target[1].update(from: $0.baseAddress! + offset, count: count) }
                buffer.frameLength = AVAudioFrameCount(count)
                try output.write(from: buffer)
                offset += count
            }
        }

        // 写进去的要读得回来,长度对得上才交出去。
        let expected = Double(frames) / sampleRate
        let check = try AVAudioFile(forReading: destination)
        let encoded = check.fileFormat.sampleRate > 0 ? Double(check.length) / check.fileFormat.sampleRate : 0
        guard AudioClipExportPolicy.writtenLengthIsComplete(expected: expected, actual: encoded) else {
            plog(String(format: "🎤 Karaoke: stem export encoded %.2fs of %.2fs", encoded, expected))
            throw Failure.unreadableAudio
        }
        keepsFile = true
        plog(String(format: "🎤 Karaoke: exported %@ (%.1fs)", fileName, encoded))
        return destination
    }

    private static func makeOutputFile(
        at url: URL,
        sampleRate: Double,
        format: KaraokeStemExportPolicy.Format
    ) throws -> AVAudioFile {
        switch format {
        case .m4a:
            return try AudioClipExporter.makeOutputFile(at: url, sampleRate: sampleRate, channelCount: 2)
        case .wav:
            // 文件里是 16 位整数,写入时由浮点转过去。
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }
    }
}
