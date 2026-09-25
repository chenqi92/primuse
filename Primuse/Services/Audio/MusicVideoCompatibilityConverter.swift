@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import Observation
import PrimuseKit
import VideoToolbox

/// What the now-playing screens show while a music video that AVPlayer
/// cannot open is fetched and rewritten. The video replaces the artwork once
/// it plays, so until then the artwork carries this state.
@MainActor
@Observable
final class MusicVideoPreparationStatus {
    static let shared = MusicVideoPreparationStatus()

    private(set) var songID: String?
    /// nil while the original is still being fetched; 0...1 while rewriting.
    private(set) var fraction: Double?

    func begin(songID: String) {
        self.songID = songID
        fraction = nil
    }

    func update(songID: String, fraction: Double) {
        guard self.songID == songID else { return }
        self.fraction = min(max(fraction, 0), 1)
    }

    func finish(songID: String) {
        guard self.songID == songID else { return }
        self.songID = nil
        fraction = nil
    }

    /// The line to show for `songID`, or nil when it is not being prepared.
    func label(for songID: String?) -> String? {
        guard let songID, songID == self.songID else { return nil }
        guard let fraction else { return String(localized: "music_video_preparing") }
        return String(
            format: String(localized: "music_video_preparing_percent"),
            Int((fraction * 100).rounded(.down))
        )
    }
}

/// Makes music videos AVPlayer cannot open (MKV, WebM, AVI, FLV, WMV,
/// MPEG-PS/TS, RMVB, OGV, 3GP) playable by rewriting them into an MP4 the
/// first time they play. Streams AVPlayer decodes are copied, which takes
/// seconds; the rest are re-encoded (H.264 by VideoToolbox, AAC). Results
/// live in a size-capped cache keyed by where the video came from, so a
/// second play starts at once and does not download the original again.
actor MusicVideoCompatibilityConverter {
    static let shared = MusicVideoCompatibilityConverter()

    private let directory: URL
    private let byteBudget: Int64
    private var running: [String: Task<URL, Error>] = [:]

    init(
        directory: URL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicVideoCompatibility", isDirectory: true),
        byteBudget: Int64 = {
            #if os(tvOS)
            MusicVideoCompatibilityPolicy.tvCacheByteBudget
            #else
            MusicVideoCompatibilityPolicy.cacheByteBudget
            #endif
        }()
    ) {
        self.directory = directory
        self.byteBudget = byteBudget
    }

    /// The rewritten video for `identity` if an earlier play produced it.
    /// Callers check this before fetching the original.
    func cachedURL(identity: String) -> URL? {
        let url = outputURL(identity: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// Rewrites the local file `input` (the complete original) and returns
    /// the cached MP4. `identity` names the original independently of where
    /// it was downloaded to: source, path, size.
    func playableURL(
        for input: URL,
        identity: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let cached = cachedURL(identity: identity) { return cached }
        let output = outputURL(identity: identity)
        if let task = running[identity] { return try await task.value }
        // One music video plays at a time, and the player does not cancel the
        // start of a song the listener skipped. A new request supersedes the
        // rest; otherwise it would queue behind their conversions.
        for (other, task) in running where other != identity {
            task.cancel()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let task = Task.detached(priority: .userInitiated) {
            try await Self.convert(input: input, output: output, progress: progress)
        }
        running[identity] = task
        defer { running[identity] = nil }
        let url = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        touch(url)
        evictIfNeeded(keeping: url.lastPathComponent)
        return url
    }

    /// Stable, filesystem-safe cache identity for a music video.
    nonisolated static func identity(sourceID: String, path: String, fileSize: Int64) -> String {
        "\(sourceID)\u{1F}\(path)\u{1F}\(max(0, fileSize))"
    }

    private func outputURL(identity: String) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("mp4")
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private func evictIfNeeded(keeping kept: String) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return }
        let finished = files.filter {
            $0.pathExtension == "mp4" && !$0.lastPathComponent.hasSuffix(Self.partialSuffix)
        }
        let entries = finished.compactMap { url -> MusicVideoCompatibilityPolicy.CacheEntry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return MusicVideoCompatibilityPolicy.CacheEntry(
                name: url.lastPathComponent,
                byteCount: Int64(values.fileSize ?? 0),
                lastAccess: values.contentModificationDate ?? .distantPast
            )
        }
        for name in MusicVideoCompatibilityPolicy.evictionVictims(entries, budget: byteBudget, keeping: kept) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Conversion

    private static let conversionQueue = DispatchQueue(
        label: "com.welape.primuse.music-video-conversion",
        qos: .userInitiated
    )

    private static let platform: MusicVideoCompatibilityPolicy.Platform = {
        #if os(macOS)
        let decodesProRes = true
        #else
        let decodesProRes = false
        #endif
        return MusicVideoCompatibilityPolicy.Platform(
            decodesAV1: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1),
            decodesProRes: decodesProRes
        )
    }()

    /// AVFoundation picks the container by extension, so the file being
    /// written keeps `.mp4` last.
    private static let partialSuffix = ".partial.mp4"

    /// The ObjC converter is used from one conversion queue at a time;
    /// `cancel()` is its only thread-safe entry and the reason for the box.
    private final class ConverterBox: @unchecked Sendable {
        let converter: FFmpegMusicVideoConverter
        init(_ converter: FFmpegMusicVideoConverter) { self.converter = converter }
    }

    private static func convert(
        input: URL,
        output: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        let partial = output.deletingPathExtension()
            .appendingPathExtension(String(partialSuffix.dropFirst()))
        try? FileManager.default.removeItem(at: partial)
        let started = Date()
        let box = ConverterBox(FFmpegMusicVideoConverter(inputURL: input, outputURL: partial))
        let converter = box.converter
        converter.shouldCopyStream = { stream in
            MusicVideoCompatibilityPolicy.canCopy(
                MusicVideoCompatibilityPolicy.Stream(
                    kind: stream.kind == .video ? .video : .audio,
                    codecName: stream.codecName,
                    profile: stream.profile,
                    bitDepth: stream.bitDepth,
                    chroma420: stream.chroma420
                ),
                on: platform
            )
        }
        try await run(box, forcingTranscode: false, progress: progress)
        // A copied stream AVFoundation will not take (the muxer accepted it)
        // gets one more pass with everything re-encoded.
        if converter.copiedAnyStream, await !isPlayable(partial) {
            plog("🎞️ MV rewrite: copied streams not playable (\(converter.summary)); re-encoding")
            try await run(box, forcingTranscode: true, progress: progress)
        }
        guard await isPlayable(partial) else {
            try? FileManager.default.removeItem(at: partial)
            plog("🎞️ MV rewrite: output not playable (\(converter.summary))")
            throw MusicVideoCompatibilityError.unplayable(converter.summary)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        plog(String(
            format: "🎞️ MV rewrite: %@ → mp4 in %.1fs (%@)",
            input.pathExtension, Date().timeIntervalSince(started), converter.summary
        ))
        return output
    }

    private static func run(
        _ box: ConverterBox,
        forcingTranscode: Bool,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                conversionQueue.async {
                    do {
                        try box.converter.convert(forcingTranscode: forcingTranscode, progress: progress)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.converter.cancel()
        }
        try Task.checkCancellation()
    }

    /// Opens the MP4 the way playback will and decodes the first sample of
    /// every track. `isPlayable` alone is not enough: an MP3 track inside MP4
    /// reports playable and then decodes to nothing.
    private static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let tracks = try? await asset.load(.tracks),
              !tracks.isEmpty,
              let reader = try? AVAssetReader(asset: asset) else { return false }
        var outputs: [AVAssetReaderTrackOutput] = []
        for track in tracks {
            let settings: [String: Any]
            switch track.mediaType {
            case .video:
                settings = [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ]
            case .audio:
                settings = [AVFormatIDKey: kAudioFormatLinearPCM]
            default:
                continue
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            outputs.append(output)
        }
        guard !outputs.isEmpty, reader.startReading() else { return false }
        defer { reader.cancelReading() }
        for output in outputs {
            guard let sample = output.copyNextSampleBuffer(),
                  CMSampleBufferGetNumSamples(sample) > 0 else { return false }
        }
        return true
    }
}

/// The stream summary stays in the log (`plog` in `convert`); the listener
/// sees a plain sentence.
enum MusicVideoCompatibilityError: LocalizedError {
    case unplayable(String)

    var errorDescription: String? {
        switch self {
        case .unplayable: String(localized: "music_video_rewrite_failed")
        }
    }
}
