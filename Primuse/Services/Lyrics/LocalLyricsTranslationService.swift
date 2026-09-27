import CoreML
import Foundation
import Observation
import PrimuseKit
#if canImport(BackgroundAssets)
import BackgroundAssets
import System
#endif

/// Where the offline lyric translation model comes from. It is an
/// Apple-hosted, on-demand Background Assets pack (26.4 and later) holding a
/// `translation-model.json`, one compiled Core ML model and one SentencePiece
/// vocabulary per direction. Debug builds can point at a local copy.
enum LocalLyricsTranslationModel {
    static let assetPackID = "LyricsTranslationModel"
    static let manifestFile = "translation-model.json"
    /// Shown before the download (compressed pack size).
    static let approximateDownloadBytes: Int64 = 33_000_000

    #if DEBUG
    /// `PRIMUSE_LYRICS_TRANSLATION_MODEL` points development and build-host
    /// runs at a directory laid out like the pack, skipping App Store hosting.
    static var debugOverrideDirectory: URL? {
        ProcessInfo.processInfo.environment["PRIMUSE_LYRICS_TRANSLATION_MODEL"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #endif

    static var isSystemSupported: Bool {
        #if DEBUG
        if debugOverrideDirectory != nil { return true }
        #endif
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *) { return true }
        return false
    }

    /// The pack's files on this device, after the manifest and every file it
    /// needs were found.
    struct Located: Sendable {
        let manifest: LocalLyricTranslationManifest
        fileprivate let files: [String: URL]

        func modelURL(for direction: LocalLyricTranslationPolicy.Direction) -> URL? {
            guard let entry = manifest.entry(for: direction) else { return nil }
            return files["\(entry.model)/\(LocalLyricTranslationManifest.compiledModelAnchor)"]?
                .deletingLastPathComponent()
        }

        func vocabularyURL(for direction: LocalLyricTranslationPolicy.Direction) -> URL? {
            guard let entry = manifest.entry(for: direction) else { return nil }
            return files[entry.vocabulary]
        }
    }

    /// The model if it is on this device and complete. Returns nil when the
    /// pack is missing, was purged by the system, or has an unknown layout.
    static func locate() -> Located? {
        guard let manifestURL = fileURL(manifestFile),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = LocalLyricTranslationManifest.decode(data) else {
            return nil
        }
        var files: [String: URL] = [:]
        for path in manifest.requiredFiles {
            guard let url = fileURL(path),
                  FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            files[path] = url
        }
        return Located(manifest: manifest, files: files)
    }

    private static func fileURL(_ path: String) -> URL? {
        #if DEBUG
        if let directory = debugOverrideDirectory {
            return directory.appendingPathComponent(path)
        }
        #endif
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *),
           AssetPackManager.shared.assetPackIsAvailableLocally(withID: assetPackID) {
            return try? AssetPackManager.shared.url(for: FilePath(path))
        }
        #endif
        return nil
    }

    /// Downloads the pack if needed; `progress` receives 0...1.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws -> Located {
        if let located = locate() { return located }
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *) {
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
            if let located = locate() { return located }
        }
        #endif
        throw LocalLyricsTranslationError.modelUnavailable
    }

    static func remove() async {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *) {
            try? await AssetPackManager.shared.remove(assetPackWithID: assetPackID)
        }
        #endif
    }
}

enum LocalLyricsTranslationError: Error {
    case modelUnavailable
}

extension Notification.Name {
    /// The offline translation model was downloaded, removed or purged.
    static let localLyricsTranslationModelChanged = Notification.Name("primuse.lyrics.localTranslationModelChanged")
}

/// Apple Translation used only with language packs already on the device, to
/// bridge other languages to and from English around the offline model.
protocol LyricsInstalledSystemTranslating: Sendable {
    func isInstalled(from source: String, to target: String) async -> Bool
    /// One result per input, nil where the system produced nothing.
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String?]
}

/// Result of translating language groups with the offline model.
struct LocalLyricsTranslationOutcome: Sendable {
    var translatedCount = 0
    /// Groups the model and its English bridge cannot translate.
    var unsupportedGroups: [LyricTranslationGroup] = []
    /// Groups that need the model, which is not on this device.
    var groupsNeedingModel: [LyricTranslationGroup] = []
    var failed = false
}

/// Owns the offline lyric translation model: download state for the UI, and
/// translation of lyric groups the system translator does not support.
@MainActor
@Observable
final class LocalLyricsTranslationService {
    static let shared = LocalLyricsTranslationService()

    enum ModelState: Equatable {
        case unsupportedSystem
        case notDownloaded
        case downloading(Double)
        case ready
        case failed
    }

    private(set) var modelState: ModelState
    /// Why the last download failed, shown under the retry button.
    private(set) var modelFailureReason: String?
    /// Changes whenever the model becomes usable or goes away, so lyric
    /// views can re-run translation.
    private(set) var modelRevision: UInt = 0 {
        didSet { NotificationCenter.default.post(name: .localLyricsTranslationModelChanged, object: nil) }
    }
    @ObservationIgnored private var located: LocalLyricsTranslationModel.Located?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private let runner = LocalLyricsTranslationRunner()

    private init() {
        if !LocalLyricsTranslationModel.isSystemSupported {
            modelState = .unsupportedSystem
        } else if let located = LocalLyricsTranslationModel.locate() {
            self.located = located
            modelState = .ready
        } else {
            modelState = .notDownloaded
        }
    }

    var isModelReady: Bool { modelState == .ready }

    /// Re-checks the pack, which the system may purge while the app is not
    /// running or in the background.
    func refreshAvailability() {
        guard modelState == .ready || modelState == .notDownloaded else { return }
        let current = LocalLyricsTranslationModel.locate()
        if current == nil, modelState == .ready {
            located = nil
            modelState = .notDownloaded
            modelRevision &+= 1
            Task { await runner.unload() }
        } else if let current, modelState == .notDownloaded {
            located = current
            modelState = .ready
            modelRevision &+= 1
        }
    }

    func downloadModel() {
        guard modelState == .notDownloaded || modelState == .failed, downloadTask == nil else { return }
        modelState = .downloading(0)
        modelFailureReason = nil
        downloadTask = Task { @MainActor in
            do {
                let located = try await LocalLyricsTranslationModel.download { fraction in
                    Task { @MainActor in
                        guard case .downloading = self.modelState else { return }
                        self.modelState = .downloading(fraction)
                    }
                }
                self.located = located
                self.modelState = .ready
                self.modelRevision &+= 1
                plog("🌐 LocalTranslation: model ready version=\(located.manifest.version)")
            } catch {
                let nsError = error as NSError
                let channel = Bundle.main.distributionChannel
                plog("⚠️ LocalTranslation: model download failed channel=\(channel.rawValue) domain=\(nsError.domain) code=\(nsError.code): \(String(describing: error))")
                // Hosted packs only download in TestFlight and App Store builds.
                self.modelFailureReason = channel == .development
                    ? String(localized: "karaoke_ai_download_dev_build")
                    : String(format: String(localized: "karaoke_ai_download_failed_format"), error.localizedDescription)
                self.modelState = .failed
            }
            self.downloadTask = nil
        }
    }

    func removeModel() async {
        located = nil
        await runner.unload()
        await LocalLyricsTranslationModel.remove()
        modelState = LocalLyricsTranslationModel.isSystemSupported ? .notDownloaded : .unsupportedSystem
        modelRevision &+= 1
    }

    // MARK: Translation

    /// Translates groups the system translator does not handle. Cached
    /// results are applied first; every new line is reported through
    /// `onTranslation` as soon as it is ready and cached under this model
    /// build. `isCurrent` is checked between lines so a song change or a new
    /// target language stops the work without applying stale results.
    func translate(
        groups: [LyricTranslationGroup],
        targetLanguageCode: String,
        systemTranslator: (any LyricsInstalledSystemTranslating)?,
        isCurrent: @escaping @MainActor () -> Bool,
        onTranslation: @MainActor (String, String) -> Void
    ) async -> LocalLyricsTranslationOutcome {
        var outcome = LocalLyricsTranslationOutcome()
        let cache = LyricsTranslationCache.shared
        for group in groups {
            guard isCurrent(), !Task.isCancelled else { return outcome }
            var route = LocalLyricTranslationPolicy.route(
                sourceLanguageCode: group.sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                allowsSystemPivot: systemTranslator != nil
            )
            if let systemTranslator {
                route = await Self.confirmingInstalledBridge(route, systemTranslator: systemTranslator)
                guard isCurrent(), !Task.isCancelled else { return outcome }
            }
            let direction: LocalLyricTranslationPolicy.Direction
            switch route {
            case .unsupported:
                outcome.unsupportedGroups.append(group)
                plog("🌐 LocalTranslation: unsupported pair \(group.sourceLanguageCode ?? "auto") -> \(targetLanguageCode)")
                continue
            case .local(let value), .systemThenLocal(_, let value), .localThenSystem(let value, _):
                direction = value
            }
            guard let located else {
                outcome.groupsNeedingModel.append(group)
                continue
            }
            let provider = LyricsTranslationCache.ProviderNamespace.local(modelVersion: located.manifest.version)
            var pending: [LyricTranslationCandidate] = []
            for candidate in group.candidates {
                if let cached = cache.translation(
                    for: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: targetLanguageCode,
                    provider: provider
                ) {
                    onTranslation(candidate.id, cached)
                    outcome.translatedCount += 1
                } else {
                    pending.append(candidate)
                }
            }
            guard !pending.isEmpty else { continue }

            do {
                var inputs = pending.map(\.text)
                if case .systemThenLocal(let systemSource, _) = route, let systemTranslator {
                    let bridged = try await systemTranslator.translate(
                        inputs,
                        from: systemSource,
                        to: LocalLyricTranslationPolicy.englishIdentity
                    )
                    inputs = zip(inputs, bridged).map { $1 ?? $0 }
                    guard isCurrent(), !Task.isCancelled else { return outcome }
                }
                var results: [String?] = []
                for input in inputs {
                    guard isCurrent(), !Task.isCancelled else { return outcome }
                    results.append(try await runner.translate(input, direction: direction, located: located))
                }
                if case .localThenSystem(_, let systemTarget) = route, let systemTranslator {
                    let english = results.map { $0 ?? "" }
                    let bridged = try await systemTranslator.translate(
                        english,
                        from: LocalLyricTranslationPolicy.englishIdentity,
                        to: systemTarget
                    )
                    results = zip(results, bridged).map { original, final in original == nil ? nil : final }
                }
                guard isCurrent(), !Task.isCancelled else { return outcome }
                var pairs: [(source: String, sourceLang: String?, translated: String)] = []
                for (candidate, result) in zip(pending, results) {
                    guard let result,
                          let accepted = LocalLyricTranslationPolicy.acceptedTranslation(
                              source: candidate.text,
                              translated: result
                          ) else { continue }
                    onTranslation(candidate.id, accepted)
                    pairs.append((candidate.text, group.sourceLanguageCode, accepted))
                    outcome.translatedCount += 1
                }
                cache.bulkSet(pairs, targetLang: targetLanguageCode, provider: provider)
            } catch {
                outcome.failed = true
                plog("⚠️ LocalTranslation: \(group.sourceLanguageCode ?? "auto") -> \(targetLanguageCode) failed: \(String(describing: error))")
                if LocalLyricsTranslationModel.locate() == nil {
                    // The system purged the pack while it was in use.
                    refreshAvailability()
                }
            }
        }
        return outcome
    }

    /// A bridge through English only counts when that system language pack
    /// is already installed: nothing is downloaded or sent anywhere without
    /// the person asking.
    private static func confirmingInstalledBridge(
        _ route: LocalLyricTranslationPolicy.Route,
        systemTranslator: any LyricsInstalledSystemTranslating
    ) async -> LocalLyricTranslationPolicy.Route {
        switch route {
        case .systemThenLocal(let source, _):
            return await systemTranslator.isInstalled(from: source, to: LocalLyricTranslationPolicy.englishIdentity)
                ? route : .unsupported
        case .localThenSystem(_, let target):
            return await systemTranslator.isInstalled(from: LocalLyricTranslationPolicy.englishIdentity, to: target)
                ? route : .unsupported
        case .local, .unsupported:
            return route
        }
    }
}

/// Loads model directions on first use off the main actor and lets them go
/// after a quiet period, so the model does not stay in memory during long
/// listening sessions.
private actor LocalLyricsTranslationRunner {
    private var directions: [LocalLyricTranslationPolicy.Direction: LocalLyricsTranslationDirection] = [:]
    private var loadedVersion: String?
    private var unloadTask: Task<Void, Never>?
    private static let idleUnloadDelay: Duration = .seconds(90)

    func translate(
        _ text: String,
        direction: LocalLyricTranslationPolicy.Direction,
        located: LocalLyricsTranslationModel.Located
    ) throws -> String? {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        if loadedVersion != located.manifest.version {
            directions = [:]
            loadedVersion = located.manifest.version
        }
        let model: LocalLyricsTranslationDirection
        if let loaded = directions[direction] {
            model = loaded
        } else {
            guard #available(iOS 18.0, macOS 15.0, tvOS 18.0, *),
                  let modelURL = located.modelURL(for: direction),
                  let vocabularyURL = located.vocabularyURL(for: direction) else {
                throw LocalLyricsTranslationError.modelUnavailable
            }
            let started = Date()
            model = try LocalLyricsTranslationDirection(compiledModelURL: modelURL, vocabularyURL: vocabularyURL)
            directions[direction] = model
            plog("🌐 LocalTranslation: loaded \(direction.source)->\(direction.target) in \(Int(Date().timeIntervalSince(started) * 1_000))ms")
        }
        return try model.translate(text)
    }

    func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        directions = [:]
        loadedVersion = nil
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
