import AVFoundation
import CoreML
import Foundation
import Observation
import PrimuseKit
#if canImport(BackgroundAssets)
import BackgroundAssets
import System
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Where the AI vocal model comes from. It is an Apple-hosted, on-demand
/// Background Assets pack (iOS / macOS / tvOS 26.4 and later), so the app binary
/// does not carry it. Debug builds can point at a local copy instead.
enum KaraokeVocalModel {
    static let assetPackID = "KaraokeVocalModel"
    /// Compiled model directory inside the pack.
    static let modelDirectory = "HTDemucsVocals.mlmodelc"
    /// What Core ML reads first from a compiled ML program.
    static let requiredModelFiles = ["coremldata.bin", "model.mil"]
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
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *) {
            return BackgroundAssetsPrerequisites.isSatisfied
        }
        return false
    }

    /// Whether the pack is on this device.
    static func isAvailableLocally() -> Bool {
        #if DEBUG
        if debugOverrideURL != nil { return true }
        #endif
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *), BackgroundAssetsPrerequisites.isSatisfied {
            return AssetPackManager.shared.assetPackIsAvailableLocally(withID: assetPackID)
        }
        #endif
        return false
    }

    /// The compiled model on this device. The pack API is asked for the
    /// model directory itself: only a requested directory is merged whole,
    /// and the parent of one file inside the model need not hold the rest.
    /// Core ML then finds `coremldata.bin` but no `model.mil` and fails with
    /// "Error in reading the MIL network". Merging takes a moment, so this
    /// never runs on the main thread.
    static func resolveModelURL() throws -> URL {
        #if DEBUG
        if let url = debugOverrideURL { return url }
        #endif
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *),
           BackgroundAssetsPrerequisites.isSatisfied,
           AssetPackManager.shared.assetPackIsAvailableLocally(withID: assetPackID) {
            let url = try AssetPackManager.shared.url(for: FilePath(modelDirectory))
            let fileManager = FileManager.default
            let missing = requiredModelFiles.filter {
                !fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
            }
            guard missing.isEmpty else {
                let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
                plog("⚠️ Karaoke: vocal model incomplete missing=\(missing) contents=\(contents.sorted())")
                throw KaraokeSeparationError.modelIncomplete
            }
            return url
        }
        #endif
        throw KaraokeSeparationError.modelUnavailable
    }

    /// Downloads the pack if needed; `progress` receives 0...1.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isAvailableLocally() { return }
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *), BackgroundAssetsPrerequisites.isSatisfied {
            let manager = AssetPackManager.shared
            let pack = try await AppleHostedAssetPackResolver.assetPack(withID: assetPackID, manager: manager)
            let watcher = Task {
                for await update in manager.statusUpdates(forAssetPackWithID: assetPackID) {
                    if case .downloading(_, let fraction) = update {
                        progress(fraction.fractionCompleted)
                    }
                }
            }
            defer { watcher.cancel() }
            try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            if isAvailableLocally() { return }
        }
        #endif
        throw KaraokeSeparationError.modelUnavailable
    }

    static func remove() async {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *), BackgroundAssetsPrerequisites.isSatisfied {
            try? await AssetPackManager.shared.remove(assetPackWithID: assetPackID)
        }
        #endif
    }
}

/// Workaround for a load that takes the whole app down. The first time a
/// system version loads the model, Core ML compiles it for this device into
/// its own cache; on an Apple TV (tvOS 27.0) writing the GPU part of that
/// compile hit a Metal assertion (`MPSGraphPackage` during
/// `MLModel(contentsOf:)`), which aborts the process and cannot be caught.
/// A load still marked as running when an earlier process ended is taken
/// to be that abort: from then on, until the system is updated, the model
/// runs on the CPU only, which never builds the GPU part.
///
/// Apple TV skips the GPU altogether. Every GPU load seen there aborted
/// (1.11.3 (101) and 1.11.5 (106), tvOS 27.0), and none ever returned, so
/// the mark above only meant one crash per Apple TV and system version.
enum KaraokeModelLoadGuard {
    private static let pendingKey = "karaokeModelLoadPending"
    private static let cpuOnlySystemKey = "karaokeModelCPUOnlySystem"
    /// Tells a mark this process left from one an earlier process left.
    private static let processToken = UUID().uuidString

    /// Whether the model runs on the CPU only on this system, for the
    /// stage to say why separating is slow. Settles a mark an earlier
    /// process left first, so the answer is right from launch, before the
    /// next load.
    static func runsOnCPUOnly() -> Bool {
        #if os(tvOS)
        return true
        #else
        let defaults = UserDefaults.standard
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        if let pending = defaults.dictionary(forKey: pendingKey) as? [String: String],
           pending["system"] == system,
           pending["process"] != processToken,
           defaults.string(forKey: cpuOnlySystemKey) != system {
            defaults.set(system, forKey: cpuOnlySystemKey)
            plog("⚠️ Karaoke: the vocal model load on \(system) never returned last time; loading it on the CPU only until the system is updated")
        }
        return defaults.string(forKey: cpuOnlySystemKey) == system
        #endif
    }

    /// Marks a load as running and returns the compute units it may use.
    static func beginLoad() -> MLComputeUnits {
        #if os(tvOS)
        return .cpuOnly
        #else
        let cpuOnly = runsOnCPUOnly()
        UserDefaults.standard.set(
            ["system": ProcessInfo.processInfo.operatingSystemVersionString, "process": processToken],
            forKey: pendingKey
        )
        return cpuOnly ? .cpuOnly : .cpuAndGPU
        #endif
    }

    /// The load returned, with the model or with an error.
    static func endLoad() {
        let defaults = UserDefaults.standard
        guard (defaults.dictionary(forKey: pendingKey) as? [String: String])?["process"] == processToken else { return }
        defaults.removeObject(forKey: pendingKey)
    }
}

enum KaraokeSeparationError: LocalizedError {
    case modelUnavailable
    /// The pack is on the device but the compiled model in it is not whole.
    case modelIncomplete
    case unreadableAudio
    case tooLong

    var errorDescription: String? {
        switch self {
        case .modelIncomplete: String(localized: "karaoke_ai_model_incomplete")
        case .modelUnavailable, .unreadableAudio, .tooLong: nil
        }
    }
}

/// A borrowed source file or a download owned solely by this separation job.
struct KaraokeAudioFile: Sendable {
    let url: URL
    var removeAfterDecoding = false
}

struct KaraokeModelAudioFile: Sendable {
    let url: URL
    let frames: Int
}

@MainActor
final class KaraokePreparationGate {
    private var active: UUID?
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire(_ id: UUID) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if active == nil {
                    active = id
                    continuation.resume()
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiting(id) }
        }
        do { try Task.checkCancellation() }
        catch { release(id); throw error }
    }

    func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            active = next.0
            next.1.resume()
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
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
        case preparing
        case separating(Double)
        case ready
        /// The file cannot be decoded here or is too long; the classic
        /// remover still works.
        case unsupported
        case failed
    }

    /// Why a song's separation is standing still for the moment.
    enum HoldReason: Equatable {
        /// The device is hot; the GPU at full load would heat it further.
        case cooling
        /// The app is in the background, where Metal refuses GPU work and
        /// the prediction fails outright instead of running on the CPU.
        case background
    }

    private(set) var modelState: ModelState
    /// Why the last model download failed, shown under the retry button.
    private(set) var modelFailureReason: String?
    /// Songs whose separation is paused, and why.
    private(set) var holdReasons: [String: HoldReason] = [:]
    /// Songs whose separation waits for the device to cool down.
    var coolingSongIDs: Set<String> {
        Set(holdReasons.filter { $0.value == .cooling }.keys)
    }
    private(set) var songStates: [String: SongState] = [:]
    /// Why a song's last separation failed, shown next to its retry button.
    private(set) var songFailureReasons: [String: String] = [:]
    /// The model runs on the CPU only on this system (see
    /// `KaraokeModelLoadGuard`): separating takes much longer, and the
    /// stage says why.
    private(set) var runsModelOnCPU = KaraokeModelLoadGuard.runsOnCPUOnly()
    @ObservationIgnored private var separator: KaraokeVocalSeparator?
    /// The model load under way. Another song (or another visit to the
    /// stage) waits for it instead of starting a second one: cancelling a
    /// separation does not stop the detached load, and two loads would
    /// compile the same model into Core ML's cache at the same time.
    @ObservationIgnored private var separatorLoad: Task<KaraokeVocalSeparator, Error>?
    /// The pack on this device is missing part of the model: the next
    /// download removes it first instead of finding it "already there".
    @ObservationIgnored private var replacesModelOnDownload = false
    @ObservationIgnored private var jobs: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobIDs: [String: UUID] = [:]
    @ObservationIgnored private let preparationGate = KaraokePreparationGate()
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var onsetCache: [String: [KaraokeOnset]] = [:]

    /// Bounds the work and temporary disk space for one separation.
    nonisolated static let maximumDuration: TimeInterval = 15 * 60
    nonisolated static let modelSampleRate = KaraokeDemucsLayout.standard.sampleRate

    private init() {
        if !KaraokeVocalModel.isSystemSupported {
            modelState = .unsupportedSystem
        } else {
            modelState = KaraokeVocalModel.isAvailableLocally() ? .ready : .notDownloaded
        }
    }

    // MARK: Model

    func downloadModel() {
        guard modelState == .notDownloaded || modelState == .failed, downloadTask == nil else { return }
        modelState = .downloading(0)
        modelFailureReason = nil
        // The service lives for the whole process, so strong captures are fine.
        downloadTask = Task { @MainActor in
            do {
                if self.replacesModelOnDownload {
                    self.separator = nil
                    self.separatorLoad = nil
                    await KaraokeVocalModel.remove()
                    self.replacesModelOnDownload = false
                }
                try await KaraokeVocalModel.download { fraction in
                    Task { @MainActor in
                        guard case .downloading = self.modelState else { return }
                        self.modelState = .downloading(fraction)
                    }
                }
                self.modelState = .ready
            } catch {
                let nsError = error as NSError
                let channel = Bundle.main.distributionChannel
                plog("⚠️ Karaoke: vocal model download failed channel=\(channel.rawValue) domain=\(nsError.domain) code=\(nsError.code): \(String(describing: error))")
                // App Store 托管的资源包只有 TestFlight 与 App Store 版本能下，Xcode 装的包
                // 必然失败；直接说明，免得对着「重试」一遍遍点。
                self.modelFailureReason = channel == .development
                    ? String(localized: "karaoke_ai_download_dev_build")
                    : String(format: String(localized: "karaoke_ai_download_failed_format"), error.localizedDescription)
                self.modelState = .failed
            }
            self.downloadTask = nil
        }
    }

    func removeModel() async {
        separator = nil
        separatorLoad = nil
        await KaraokeVocalModel.remove()
        modelState = KaraokeVocalModel.isSystemSupported ? .notDownloaded : .unsupportedSystem
    }

    // MARK: Songs

    func state(for song: Song) -> SongState {
        if let state = songStates[song.id] { return state }
        return FileManager.default.fileExists(atPath: Self.stemURL(for: song).path) ? .ready : .idle
    }

    /// Starts separating `song` unless it is cached or already running.
    #if !os(tvOS)
    func prepare(_ song: Song, sourceManager: SourceManager) {
        prepare(song) {
            try await Self.sourceAudioFile(for: song, sourceManager: sourceManager)
        }
    }

    /// The song's own file, the one its stem was separated from. Exporting
    /// the instrumental decodes it the same way again.
    static func sourceAudioFile(for song: Song, sourceManager: SourceManager) async throws -> KaraokeAudioFile {
        if let cached = await sourceManager.cachedURLForBackgroundRead(for: song) {
            try Task.checkCancellation()
            return KaraokeAudioFile(url: cached)
        }
        let connector = try await sourceManager.auxiliaryConnector(for: song)
        if let processor = connector as? any TemporaryAudioProcessingConnector {
            return KaraokeAudioFile(
                url: try await processor.temporaryAudioProcessingURL(for: song.filePath),
                removeAfterDecoding: true
            )
        }
        let startedAt = Date()
        let url = try await connector.localURL(for: song.filePath)
        // 分离完只用伴奏文件。专为这次分离整首下载的原文件解码完就删,
        // 不留在连接器缓存里; 播放等别处先下好的那份照旧留着。
        return KaraokeAudioFile(
            url: url,
            removeAfterDecoding: SourceManager.isOneOffSourceDownload(
                url,
                sourceID: song.sourceID,
                downloadedSince: startedAt
            )
        )
    }
    #endif

    func prepare(_ song: Song, audioFile: @escaping @MainActor () async throws -> KaraokeAudioFile) {
        guard modelState == .ready, jobs[song.id] == nil else { return }
        switch state(for: song) {
        case .ready, .preparing, .separating, .unsupported: return
        case .idle, .failed: break
        }
        if song.duration > Self.maximumDuration {
            songStates[song.id] = .unsupported
            return
        }
        let jobID = UUID()
        jobIDs[song.id] = jobID
        songStates[song.id] = .preparing
        songFailureReasons[song.id] = nil
        let destination = Self.stemURL(for: song)
        let startedAt = Date()
        let logID = String(song.id.prefix(8))
        plog("🎤 Karaoke: separating \(logID)…")
        jobs[song.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.jobIDs[song.id] == jobID {
                    self.jobs[song.id] = nil
                    self.jobIDs[song.id] = nil
                    self.holdReasons[song.id] = nil
                }
            }
            do {
                try await self.preparationGate.acquire(jobID)
                defer { self.preparationGate.release(jobID) }
                try Task.checkCancellation()
                plog("🎤 Karaoke: \(logID) stage=queue ready elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
                let modelStartedAt = Date()
                plog("🎤 Karaoke: \(logID) stage=model begin")
                try await self.holdWhileUnavailable(song.id)
                let separator = try await self.loadSeparator()
                plog("🎤 Karaoke: \(logID) stage=model ready elapsed=\(String(format: "%.2f", Date().timeIntervalSince(modelStartedAt)))s")
                try Task.checkCancellation()
                let audioStartedAt = Date()
                plog("🎤 Karaoke: \(logID) stage=audio begin")
                let file = try await audioFile()
                plog("🎤 Karaoke: \(logID) stage=audio ready elapsed=\(String(format: "%.2f", Date().timeIntervalSince(audioStartedAt)))s ownership=\(file.removeAfterDecoding ? "temporary" : "borrowed")")
                let decodeStartedAt = Date()
                plog("🎤 Karaoke: \(logID) stage=decode begin")
                let audio = try await Self.decodeModelAudioFile(
                    file: file, start: song.cueStartTime, end: song.cueEndTime
                )
                defer { try? FileManager.default.removeItem(at: audio.url) }
                plog("🎤 Karaoke: \(logID) stage=decode ready elapsed=\(String(format: "%.2f", Date().timeIntervalSince(decodeStartedAt)))s audio=\(String(format: "%.2f", Double(audio.frames) / Self.modelSampleRate))s")
                try Task.checkCancellation()
                guard self.jobIDs[song.id] == jobID else { throw CancellationError() }
                self.songStates[song.id] = .separating(0)
                let songID = song.id
                let inferenceStartedAt = Date()
                plog("🎤 Karaoke: \(logID) stage=inference begin")
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporaryStem = destination.deletingLastPathComponent()
                    .appendingPathComponent("\(jobID.uuidString).partial")
                defer { try? FileManager.default.removeItem(at: temporaryStem) }
                try await separator.separateVocals(
                    file: audio, outputURL: temporaryStem, songID: songID,
                    progress: { fraction in
                        Task { @MainActor [weak self] in
                            guard let self, self.jobIDs[songID] == jobID,
                                  case .separating = self.songStates[songID] else { return }
                            self.songStates[songID] = .separating(fraction)
                        }
                    },
                    hold: { [weak self] in
                        try await self?.holdWhileUnavailable(songID)
                    }
                )
                plog("🎤 Karaoke: \(logID) stage=inference ready elapsed=\(String(format: "%.2f", Date().timeIntervalSince(inferenceStartedAt)))s")
                try Task.checkCancellation()
                guard self.jobIDs[song.id] == jobID else { throw CancellationError() }
                let writeStartedAt = Date()
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryStem)
                } else {
                    try FileManager.default.moveItem(at: temporaryStem, to: destination)
                }
                plog("🎤 Karaoke: \(logID) stage=write ready elapsed=\(String(format: "%.2f", Date().timeIntervalSince(writeStartedAt)))s")
                self.songStates[song.id] = .ready
                plog("🎤 Karaoke: separated \(logID)… in \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s")
            } catch {
                guard self.jobIDs[song.id] == jobID else { return }
                switch error {
                case is CancellationError:
                    self.songStates[song.id] = nil
                case KaraokeSeparationError.unreadableAudio, KaraokeSeparationError.tooLong:
                    self.songStates[song.id] = .unsupported
                case KaraokeSeparationError.modelIncomplete:
                    self.songStates[song.id] = nil
                    self.replacesModelOnDownload = true
                    self.modelFailureReason = KaraokeSeparationError.modelIncomplete.localizedDescription
                    self.modelState = .failed
                default:
                    let nsError = error as NSError
                    plog("⚠️ Karaoke: separation failed for \(logID) domain=\(nsError.domain) code=\(nsError.code): \(String(describing: error))")
                    self.songFailureReasons[song.id] = error.localizedDescription
                    self.songStates[song.id] = .failed
                }
            }
        }
    }

    /// Returns once the model may run: not while the device is hot, and on
    /// iOS not while the app is in the background. Checked before the model
    /// is loaded and before every segment.
    private func holdWhileUnavailable(_ songID: String) async throws {
        while let reason = Self.holdReason() {
            if holdReasons[songID] != reason {
                holdReasons[songID] = reason
                plog("🎤 Karaoke: separation paused (\(reason)) \(songID.prefix(8))")
            }
            try await Task.sleep(for: .seconds(reason == .cooling ? 3 : 1))
        }
        if holdReasons.removeValue(forKey: songID) != nil {
            plog("🎤 Karaoke: separation resumed \(songID.prefix(8))")
        }
    }

    private static func holdReason() -> HoldReason? {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return .cooling }
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .background { return .background }
        #endif
        return nil
    }

    func cancel(_ songID: String) {
        jobs[songID]?.cancel()
    }

    func discardStem(for song: Song) {
        guard jobs[song.id] == nil else { return }
        try? FileManager.default.removeItem(at: Self.stemURL(for: song))
        songStates[song.id] = nil
        songFailureReasons[song.id] = nil
        onsetCache[song.id] = nil
    }

    /// The cached stem resampled to the playback graph's rate.
    #if !os(tvOS)
    func loadStem(for song: Song, graphSampleRate: Double) async -> KaraokeStemTrack? {
        let url = Self.stemURL(for: song)
        let task = Task.detached(priority: .userInitiated) { () -> KaraokeStemTrack? in
            do {
                let reader = try KaraokeStemPCMReader(url: url)
                guard graphSampleRate.isFinite, graphSampleRate > 0 else { return nil }
                let capacity = Int(ceil(Double(reader.frames) * graphSampleRate / reader.sampleRate)) + 4096
                return try KaraokeStemTrack(sampleRate: graphSampleRate, frameCapacity: capacity) { storage in
                    var offset = 0
                    return try Self.readStemPCM(reader, sampleRate: graphSampleRate) { left, right, count in
                        guard offset + count <= capacity else { throw KaraokeSeparationError.unreadableAudio }
                        for index in 0..<count {
                            storage[(offset + index) * 2] = Int16(max(-32_768, min(32_767, (left[index] * 32_767).rounded())))
                            storage[(offset + index) * 2 + 1] = Int16(max(-32_768, min(32_767, (right[index] * 32_767).rounded())))
                        }
                        offset += count
                    }
                }
            } catch { return nil }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    #endif

    func loadStemSamples(for song: Song, graphSampleRate: Double) async -> (left: [Float], right: [Float])? {
        let url = Self.stemURL(for: song)
        let task = Task.detached(priority: .userInitiated) { () -> (left: [Float], right: [Float])? in
            do {
                let reader = try KaraokeStemPCMReader(url: url)
                guard graphSampleRate.isFinite, graphSampleRate > 0 else { return nil }
                let capacity = Int(ceil(Double(reader.frames) * graphSampleRate / reader.sampleRate)) + 4096
                var left: [Float] = [], right: [Float] = []
                left.reserveCapacity(capacity)
                right.reserveCapacity(capacity)
                _ = try Self.readStemPCM(reader, sampleRate: graphSampleRate) { l, r, count in
                    left.append(contentsOf: UnsafeBufferPointer(start: l, count: count))
                    right.append(contentsOf: UnsafeBufferPointer(start: r, count: count))
                }
                return (left, right)
            } catch { return nil }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func readStemPCM(
        _ reader: KaraokeStemPCMReader,
        sampleRate: Double,
        consume: (UnsafePointer<Float>, UnsafePointer<Float>, Int) throws -> Void
    ) throws -> Int {
        var written = 0
        func emit(_ buffer: AVAudioPCMBuffer) throws {
            try Task.checkCancellation()
            guard let channels = buffer.floatChannelData else { throw KaraokeSeparationError.unreadableAudio }
            try consume(channels[0], channels[1], Int(buffer.frameLength))
            written += Int(buffer.frameLength)
        }
        if abs(reader.sampleRate - sampleRate) < 0.5 {
            while let buffer = try reader.read(frames: 8192) { try emit(buffer) }
        } else {
            guard let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
                  let converter = AVAudioConverter(from: reader.format, to: target),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
                throw KaraokeSeparationError.unreadableAudio
            }
            var emptyPasses = 0
            while true {
                try Task.checkCancellation()
                output.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { count, inputStatus in
                    do {
                        guard let buffer = try reader.read(frames: count) else {
                            inputStatus.pointee = .endOfStream
                            return nil
                        }
                        inputStatus.pointee = .haveData
                        return buffer
                    } catch {
                        reader.failure = error
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if let failure = reader.failure { throw failure }
                if let conversionError { throw conversionError }
                guard status != .error else { throw KaraokeSeparationError.unreadableAudio }
                if output.frameLength > 0 {
                    try emit(output)
                    emptyPasses = 0
                } else { emptyPasses += 1 }
                if status == .endOfStream { break }
                guard emptyPasses < 3 else { throw KaraokeSeparationError.unreadableAudio }
            }
        }
        return written
    }

    /// Syllable onsets of a separated song's vocal, for timing line-level
    /// lyrics word by word. Computed once per song and kept in memory.
    func onsets(for song: Song) async -> [KaraokeOnset]? {
        if let cached = onsetCache[song.id] { return cached }
        guard state(for: song) == .ready else { return nil }
        let url = Self.stemURL(for: song)
        let onsets = await Task.detached(priority: .utility) { () -> [KaraokeOnset]? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let stem = KaraokeStemFile.decodeMono(data) else { return nil }
            return KaraokeOnsetDetector.onsets(in: stem.samples, sampleRate: stem.header.sampleRate)
        }.value
        if let onsets {
            if onsetCache.count > 20 { onsetCache.removeAll() }
            onsetCache[song.id] = onsets
        }
        return onsets
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
        jobIDs.removeAll()
        songStates.removeAll()
        songFailureReasons.removeAll()
        holdReasons.removeAll()
        onsetCache.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
    }

    // MARK: Work

    /// Locating, compiling and loading the model takes a second or two;
    /// never on the main thread.
    private func loadSeparator() async throws -> KaraokeVocalSeparator {
        if let separator { return separator }
        let load = separatorLoad ?? startLoadingSeparator()
        separatorLoad = load
        do {
            let created = try await load.value
            // Not kept when the model was removed meanwhile.
            if separatorLoad == load {
                separatorLoad = nil
                separator = created
            }
            return created
        } catch {
            if separatorLoad == load { separatorLoad = nil }
            throw error
        }
    }

    private func startLoadingSeparator() -> Task<KaraokeVocalSeparator, Error> {
        let computeUnits = KaraokeModelLoadGuard.beginLoad()
        runsModelOnCPU = computeUnits == .cpuOnly
        let unitsName = computeUnits == .cpuOnly ? "cpuOnly" : "cpuAndGPU"
        plog("🎤 Karaoke: loading vocal model units=\(unitsName)")
        return Task.detached(priority: .userInitiated) {
            defer { KaraokeModelLoadGuard.endLoad() }
            let startedAt = Date()
            let separator = try KaraokeVocalSeparator(
                modelURL: KaraokeVocalModel.resolveModelURL(),
                computeUnits: computeUnits
            )
            plog("🎤 Karaoke: vocal model loaded units=\(unitsName) in \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s")
            return separator
        }
    }

    /// Apple's FLAC parser rejects a file carrying a metadata block of the
    /// forbidden type 127, which libFLAC plays past. Such a file is read with
    /// that block retagged as padding: in place when it is this job's own
    /// download, from a copy when it is borrowed.
    private nonisolated static func openForDecoding(
        _ file: KaraokeAudioFile
    ) -> (audioFile: AVAudioFile, repairedCopy: URL?)? {
        if let audioFile = try? AVAudioFile(forReading: file.url) { return (audioFile, nil) }
        guard let headers = try? FLACForbiddenBlockRepair.forbiddenHeaderOffsets(inFileAt: file.url),
              !headers.isEmpty else { return nil }
        var target = file.url
        var repairedCopy: URL?
        if !file.removeAfterDecoding {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("karaoke-flac-\(UUID().uuidString).flac")
            guard (try? FileManager.default.copyItem(at: file.url, to: copy)) != nil else { return nil }
            target = copy
            repairedCopy = copy
        }
        guard (try? FLACForbiddenBlockRepair.repairFile(at: target)) == true,
              let audioFile = try? AVAudioFile(forReading: target) else {
            if let repairedCopy { try? FileManager.default.removeItem(at: repairedCopy) }
            return nil
        }
        plog("🎤 Karaoke: FLAC metadata block type 127 at \(headers) retagged as padding before decoding")
        return (audioFile, repairedCopy)
    }

    nonisolated static func decodeModelAudioFile(
        file: KaraokeAudioFile,
        start: TimeInterval?,
        end: TimeInterval?
    ) async throws -> KaraokeModelAudioFile {
        defer {
            if file.removeAfterDecoding { try? FileManager.default.removeItem(at: file.url) }
        }
        try Task.checkCancellation()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("karaoke-model-audio-\(UUID().uuidString).caf")
        let task = Task.detached(priority: .utility) {
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
            try Task.checkCancellation()
            guard let opened = openForDecoding(file) else { throw KaraokeSeparationError.unreadableAudio }
            defer {
                if let repairedCopy = opened.repairedCopy { try? FileManager.default.removeItem(at: repairedCopy) }
            }
            let sourceFile = opened.audioFile
            let rate = sourceFile.processingFormat.sampleRate
            let firstFrame = AVAudioFramePosition(((start ?? 0) * rate).rounded())
            let lastFrame = end.map { AVAudioFramePosition(($0 * rate).rounded()) } ?? sourceFile.length
            let frames = max(0, min(sourceFile.length, lastFrame) - firstFrame)
            guard firstFrame >= 0, frames > 0 else { throw KaraokeSeparationError.unreadableAudio }
            guard Double(frames) / rate <= maximumDuration else { throw KaraokeSeparationError.tooLong }
            sourceFile.framePosition = firstFrame
            let reader = try KaraokeModelAudioReader(file: sourceFile, remaining: frames)
            guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: modelSampleRate, channels: 2) else {
                throw KaraokeSeparationError.unreadableAudio
            }
            let outputFile = try AVAudioFile(forWriting: destination, settings: targetFormat.settings)
            var written = 0
            if abs(rate - modelSampleRate) < 0.5 {
                while let buffer = try reader.read(frames: 8192) {
                    try Task.checkCancellation()
                    try outputFile.write(from: buffer)
                    written += Int(buffer.frameLength)
                }
            } else {
                guard let converter = AVAudioConverter(from: reader.stereoFormat, to: targetFormat),
                      let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) else {
                    throw KaraokeSeparationError.unreadableAudio
                }
                var emptyPasses = 0
                while true {
                    try Task.checkCancellation()
                    output.frameLength = 0
                    var conversionError: NSError?
                    let status = converter.convert(to: output, error: &conversionError) { count, inputStatus in
                        do {
                            guard let buffer = try reader.read(frames: count) else {
                                inputStatus.pointee = .endOfStream
                                return nil
                            }
                            inputStatus.pointee = .haveData
                            return buffer
                        } catch {
                            reader.failure = error
                            inputStatus.pointee = .endOfStream
                            return nil
                        }
                    }
                    if let failure = reader.failure { throw failure }
                    if let conversionError { throw conversionError }
                    guard status != .error else { throw KaraokeSeparationError.unreadableAudio }
                    if output.frameLength > 0 {
                        try outputFile.write(from: output)
                        written += Int(output.frameLength)
                        emptyPasses = 0
                    } else {
                        emptyPasses += 1
                    }
                    if status == .endOfStream { break }
                    guard emptyPasses < 3 else { throw KaraokeSeparationError.unreadableAudio }
                }
            }
            try Task.checkCancellation()
            guard written > 0 else { throw KaraokeSeparationError.unreadableAudio }
            completed = true
            return KaraokeModelAudioFile(url: destination, frames: written)
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            return result
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Full-buffer access remains for stem export; separation reads the prepared file by segment.
    nonisolated static func decodeForModel(
        file: KaraokeAudioFile,
        start: TimeInterval?,
        end: TimeInterval?
    ) async throws -> (left: [Float], right: [Float]) {
        let prepared = try await decodeModelAudioFile(file: file, start: start, end: end)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: prepared.url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(prepared.frames)) else {
                throw KaraokeSeparationError.unreadableAudio
            }
            try file.read(into: buffer)
            try Task.checkCancellation()
            guard let channels = buffer.floatChannelData else { throw KaraokeSeparationError.unreadableAudio }
            return (
                left: Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))),
                right: Array(UnsafeBufferPointer(start: channels[1], count: Int(buffer.frameLength)))
            )
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

}

private final class KaraokeModelAudioReader: @unchecked Sendable {
    let stereoFormat: AVAudioFormat
    var failure: Error?
    private let file: AVAudioFile
    private let input: AVAudioPCMBuffer
    private let stereo: AVAudioPCMBuffer
    private var remaining: AVAudioFramePosition

    init(file: AVAudioFile, remaining: AVAudioFramePosition) throws {
        self.file = file
        self.remaining = remaining
        guard let format = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 2),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let stereo = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw KaraokeSeparationError.unreadableAudio
        }
        stereoFormat = format
        self.input = input
        self.stereo = stereo
    }

    func read(frames requested: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        try Task.checkCancellation()
        guard remaining > 0 else { return nil }
        let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(min(8192, requested))))
        guard count > 0 else { throw KaraokeSeparationError.unreadableAudio }
        try file.read(into: input, frameCount: count)
        guard input.frameLength > 0, let channels = input.floatChannelData,
              let output = stereo.floatChannelData else { throw KaraokeSeparationError.unreadableAudio }
        remaining -= AVAudioFramePosition(input.frameLength)
        stereo.frameLength = input.frameLength
        let right = input.format.channelCount >= 2 ? channels[1] : channels[0]
        for index in 0..<Int(input.frameLength) {
            let center: Float = input.format.channelCount > 2 ? channels[2][index] * 0.707 : 0
            output[0][index] = channels[0][index] + center
            output[1][index] = right[index] + center
        }
        return stereo
    }
}

private final class KaraokeStemPCMReader: @unchecked Sendable {
    let format: AVAudioFormat
    let frames: Int
    let sampleRate: Double
    var failure: Error?
    private let data: Data
    private let buffer: AVAudioPCMBuffer
    private var offset = 0

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let header = KaraokeStemFile.header(of: data), header.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: header.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw KaraokeSeparationError.unreadableAudio
        }
        self.data = data
        self.format = format
        self.buffer = buffer
        frames = header.frames
        sampleRate = header.sampleRate
    }

    func read(frames requested: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        try Task.checkCancellation()
        guard offset < frames else { return nil }
        let count = min(frames - offset, Int(min(8192, requested)))
        guard count > 0, let samples = KaraokeStemFile.decodeFrames(data, range: offset..<(offset + count)),
              let channels = buffer.floatChannelData else { throw KaraokeSeparationError.unreadableAudio }
        samples.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: count) }
        samples.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: count) }
        buffer.frameLength = AVAudioFrameCount(count)
        offset += count
        return buffer
    }
}
