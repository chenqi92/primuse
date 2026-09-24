import AVFoundation
import Foundation
import Observation
import PrimuseKit
#if canImport(BackgroundAssets)
import BackgroundAssets
import System
#endif

/// Where the AI vocal model comes from. It is an Apple-hosted, on-demand
/// Background Assets pack (iOS / macOS 26.4 and later), so the app binary
/// does not carry it. Debug builds can point at a local copy instead.
enum KaraokeVocalModel {
    static let assetPackID = "KaraokeVocalModel"
    /// Compiled model directory inside the pack.
    static let modelDirectory = "HTDemucsVocals.mlmodelc"
    /// A file that is always inside the compiled model, used to locate it:
    /// the pack API resolves files, not directories.
    static let anchorFile = "HTDemucsVocals.mlmodelc/coremldata.bin"
    /// Separated stems are cached per model build; bump when the model changes.
    static let cacheVersion = "htdemucs4-fp16-v1"
    /// Shown before the download: the compressed pack is about 80 MB.
    static let approximateDownloadBytes: Int64 = 80_000_000

    #if DEBUG
    /// `PRIMUSE_KARAOKE_MODEL` lets development and build-host runs use a
    /// local `.mlmodelc` / `.mlpackage` without App Store hosting.
    static var debugOverrideURL: URL? {
        ProcessInfo.processInfo.environment["PRIMUSE_KARAOKE_MODEL"].map { URL(fileURLWithPath: $0) }
    }
    #endif

    static var isSystemSupported: Bool {
        #if DEBUG
        if debugOverrideURL != nil { return true }
        #endif
        if #available(iOS 26.4, macOS 26.4, *) { return true }
        return false
    }

    /// The model if it is already on this device.
    static func localModelURL() -> URL? {
        #if DEBUG
        if let url = debugOverrideURL { return url }
        #endif
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, *),
           AssetPackManager.shared.assetPackIsAvailableLocally(withID: assetPackID),
           let anchor = try? AssetPackManager.shared.url(for: FilePath(anchorFile)) {
            return anchor.deletingLastPathComponent()
        }
        #endif
        return nil
    }

    /// Downloads the pack if needed; `progress` receives 0...1.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let url = localModelURL() { return url }
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, *) {
            let manager = AssetPackManager.shared
            let pack = try await manager.assetPack(withID: assetPackID)
            let watcher = Task {
                for await update in manager.statusUpdates(forAssetPackWithID: assetPackID) {
                    if case .downloading(_, let fraction) = update {
                        progress(fraction.fractionCompleted)
                    }
                }
            }
            defer { watcher.cancel() }
            try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            if let url = localModelURL() { return url }
        }
        #endif
        throw KaraokeSeparationError.modelUnavailable
    }

    static func remove() async {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, *) {
            try? await AssetPackManager.shared.remove(assetPackWithID: assetPackID)
        }
        #endif
    }
}

enum KaraokeSeparationError: Error {
    case modelUnavailable
    case unreadableAudio
    case tooLong
}

/// Separates songs' vocals with the AI model and keeps the results.
/// Shared by every karaoke session so a separation started for one visit to
/// the stage is still there on the next.
@MainActor
@Observable
final class KaraokeSeparationService {
    static let shared = KaraokeSeparationService()

    enum ModelState: Equatable {
        case unsupportedSystem
        case notDownloaded
        case downloading(Double)
        case ready
        case failed
    }

    enum SongState: Equatable {
        case idle
        case separating(Double)
        case ready
        /// The file cannot be decoded here or is too long; the classic
        /// remover still works.
        case unsupported
        case failed
    }

    private(set) var modelState: ModelState
    private(set) var songStates: [String: SongState] = [:]
    @ObservationIgnored private var separator: KaraokeVocalSeparator?
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    /// Songs longer than this are not separated: the whole song is held in
    /// memory while the model runs.
    nonisolated static let maximumDuration: TimeInterval = 15 * 60
    nonisolated static let modelSampleRate = KaraokeDemucsLayout.standard.sampleRate

    private init() {
        if !KaraokeVocalModel.isSystemSupported {
            modelState = .unsupportedSystem
        } else {
            modelState = KaraokeVocalModel.localModelURL() == nil ? .notDownloaded : .ready
        }
    }

    // MARK: Model

    func downloadModel() {
        guard modelState == .notDownloaded || modelState == .failed, downloadTask == nil else { return }
        modelState = .downloading(0)
        // The service lives for the whole process, so strong captures are fine.
        downloadTask = Task { @MainActor in
            do {
                _ = try await KaraokeVocalModel.download { fraction in
                    Task { @MainActor in
                        guard case .downloading = self.modelState else { return }
                        self.modelState = .downloading(fraction)
                    }
                }
                self.modelState = .ready
            } catch {
                plog("⚠️ Karaoke: vocal model download failed: \(error.localizedDescription)")
                self.modelState = .failed
            }
            self.downloadTask = nil
        }
    }

    func removeModel() async {
        separator = nil
        await KaraokeVocalModel.remove()
        modelState = KaraokeVocalModel.isSystemSupported ? .notDownloaded : .unsupportedSystem
    }

    // MARK: Songs

    func state(for song: Song) -> SongState {
        if let state = songStates[song.id] { return state }
        return FileManager.default.fileExists(atPath: Self.stemURL(for: song).path) ? .ready : .idle
    }

    /// Starts separating `song` unless it is cached or already running.
    func prepare(_ song: Song, sourceManager: SourceManager) {
        guard modelState == .ready, jobs[song.id] == nil else { return }
        switch state(for: song) {
        case .ready, .separating, .unsupported: return
        case .idle, .failed: break
        }
        if song.duration > Self.maximumDuration {
            songStates[song.id] = .unsupported
            return
        }
        songStates[song.id] = .separating(0)
        let destination = Self.stemURL(for: song)
        jobs[song.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let separator = try await self.loadSeparator()
                let localURL = try await sourceManager.auxiliaryConnector(for: song).localURL(for: song.filePath)
                let audio = try await Self.decodeForModel(
                    url: localURL,
                    start: song.cueStartTime,
                    end: song.cueEndTime
                )
                let songID = song.id
                let stem = try await separator.separateVocals(left: audio.left, right: audio.right) { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .separating = self.songStates[songID] else { return }
                        self.songStates[songID] = .separating(fraction)
                    }
                }
                try await Self.write(stem: stem, to: destination)
                self.songStates[song.id] = .ready
            } catch KaraokeSeparationError.unreadableAudio {
                self.songStates[song.id] = .unsupported
            } catch KaraokeSeparationError.tooLong {
                self.songStates[song.id] = .unsupported
            } catch is CancellationError {
                self.songStates[song.id] = nil
            } catch {
                plog("⚠️ Karaoke: separation failed for \(song.id.prefix(8)): \(error.localizedDescription)")
                self.songStates[song.id] = .failed
            }
            self.jobs[song.id] = nil
        }
    }

    func cancel(_ songID: String) {
        jobs[songID]?.cancel()
    }

    /// The cached stem resampled to the playback graph's rate.
    func loadStem(for song: Song, graphSampleRate: Double) async -> KaraokeStemTrack? {
        let url = Self.stemURL(for: song)
        return await Task.detached(priority: .userInitiated) { () -> KaraokeStemTrack? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let stem = KaraokeStemFile.decode(data) else { return nil }
            if abs(stem.header.sampleRate - graphSampleRate) < 0.5 {
                return KaraokeStemTrack(left: stem.left, right: stem.right, sampleRate: graphSampleRate)
            }
            guard let resampled = Self.resample(
                left: stem.left,
                right: stem.right,
                from: stem.header.sampleRate,
                to: graphSampleRate
            ) else { return nil }
            return KaraokeStemTrack(left: resampled.left, right: resampled.right, sampleRate: graphSampleRate)
        }.value
    }

    // MARK: Cache

    nonisolated static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KaraokeStems", isDirectory: true)
    }

    /// Keyed by song, file identity and model build, so an edited file or a
    /// new model never reuses a stale stem.
    nonisolated static func stemURL(for song: Song) -> URL {
        let modified = song.lastModified.map { Int($0.timeIntervalSince1970) } ?? 0
        let cue = song.cueStartTime.map { "-c\(Int($0 * 1000))" } ?? ""
        let name = "\(song.id)-\(song.fileSize)-\(modified)\(cue)-\(KaraokeVocalModel.cacheVersion).kvst"
        return cacheDirectory.appendingPathComponent(name)
    }

    func cacheSizeBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clearCache() {
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        songStates.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    // MARK: Work

    /// Compiling and loading the model takes a second or two; never on the
    /// main thread.
    private func loadSeparator() async throws -> KaraokeVocalSeparator {
        if let separator { return separator }
        guard let url = KaraokeVocalModel.localModelURL() else { throw KaraokeSeparationError.modelUnavailable }
        let created = try await Task.detached(priority: .userInitiated) {
            try KaraokeVocalSeparator(modelURL: url)
        }.value
        separator = created
        return created
    }

    private nonisolated static func write(stem: KaraokeVocalSeparator.Stem, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            let data = KaraokeStemFile.encode(left: stem.left, right: stem.right, sampleRate: modelSampleRate)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// Decodes the song (or its CUE slice) to 44.1 kHz stereo.
    private nonisolated static func decodeForModel(
        url: URL,
        start: TimeInterval?,
        end: TimeInterval?
    ) async throws -> (left: [Float], right: [Float]) {
        try await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: url) else { throw KaraokeSeparationError.unreadableAudio }
            let format = file.processingFormat
            let rate = format.sampleRate
            let firstFrame = AVAudioFramePosition(((start ?? 0) * rate).rounded())
            let lastFrame = end.map { AVAudioFramePosition(($0 * rate).rounded()) } ?? file.length
            let frameCount = max(0, min(file.length, lastFrame) - firstFrame)
            guard frameCount > 0 else { throw KaraokeSeparationError.unreadableAudio }
            guard Double(frameCount) / rate <= maximumDuration else { throw KaraokeSeparationError.tooLong }
            file.framePosition = firstFrame
            guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                throw KaraokeSeparationError.unreadableAudio
            }
            try file.read(into: source, frameCount: AVAudioFrameCount(frameCount))
            guard let channels = source.floatChannelData else { throw KaraokeSeparationError.unreadableAudio }
            let count = Int(source.frameLength)
            var left = Array(UnsafeBufferPointer(start: channels[0], count: count))
            var right: [Float]
            if format.channelCount >= 2 {
                right = Array(UnsafeBufferPointer(start: channels[1], count: count))
                if format.channelCount > 2 {
                    // Fold the centre into both sides; surrounds are ignored.
                    let centre = Array(UnsafeBufferPointer(start: channels[2], count: count))
                    for i in 0..<count {
                        left[i] += 0.707 * centre[i]
                        right[i] += 0.707 * centre[i]
                    }
                }
            } else {
                right = left
            }
            if abs(rate - modelSampleRate) < 0.5 { return (left, right) }
            guard let resampled = resample(left: left, right: right, from: rate, to: modelSampleRate) else {
                throw KaraokeSeparationError.unreadableAudio
            }
            return resampled
        }.value
    }

    /// Whole-buffer stereo sample-rate conversion.
    private nonisolated static func resample(
        left: [Float],
        right: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> (left: [Float], right: [Float])? {
        guard let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2),
              let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 2),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(left.count)) else {
            return nil
        }
        input.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { input.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
        let capacity = AVAudioFrameCount(Double(left.count) * targetRate / sourceRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        let pending = PendingBuffer(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = pending.take() else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channels = output.floatChannelData else { return nil }
        let count = Int(output.frameLength)
        return (
            Array(UnsafeBufferPointer(start: channels[0], count: count)),
            Array(UnsafeBufferPointer(start: channels[1], count: count))
        )
    }

    private final class PendingBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}
