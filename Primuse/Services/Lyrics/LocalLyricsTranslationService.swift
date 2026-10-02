import CoreML
import Foundation
import Observation
import PrimuseKit
#if canImport(BackgroundAssets)
import BackgroundAssets
import System
#endif
#if os(macOS)
import Security
#endif

/// Where the offline lyric translation model comes from. It is an
/// Apple-hosted, on-demand Background Assets pack (26.4 and later) holding a
/// `translation-model.json`, one compiled Core ML model and one SentencePiece
/// vocabulary per direction. Debug builds can point at a local copy.
enum LocalLyricsTranslationModel {
    enum Pack: String, CaseIterable, Hashable, Sendable, Identifiable {
        case persian, cjk

        var id: String { rawValue }
        var assetPackID: String { self == .persian ? "LyricsTranslationModel" : "LyricsTranslationCJKModel" }
        var manifestFile: String { self == .persian ? "translation-model.json" : "cjk/translation-model.json" }
        var approximateDownloadBytes: Int64 { self == .persian ? 33_000_000 : 329_000_000 }
        var pairsKey: String { self == .persian ? "lyrics_translation_local_pairs" : "lyrics_translation_local_cjk_pairs" }
        var footerKey: String { self == .persian ? "lyrics_translation_local_footer" : "lyrics_translation_local_cjk_footer" }
        var directions: [LocalLyricTranslationPolicy.Direction] {
            self == .persian ? LocalLyricTranslationPolicy.persianDirections : LocalLyricTranslationPolicy.cjkDirections
        }

        static func containing(_ direction: LocalLyricTranslationPolicy.Direction) -> Pack {
            LocalLyricTranslationPolicy.persianDirections.contains(direction) ? .persian : .cjk
        }
    }

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
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *) {
            return BackgroundAssetsPrerequisites.isSatisfied
        }
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

        func targetVocabularyURL(for direction: LocalLyricTranslationPolicy.Direction) -> URL? {
            guard let path = manifest.entry(for: direction)?.targetVocabulary else { return nil }
            return files[path]
        }
    }

    /// The model if it is on this device and complete. Returns nil when the
    /// pack is missing, was purged by the system, or has an unknown layout.
    static func locate(_ pack: Pack) -> Located? {
        guard let manifestURL = fileURL(pack.manifestFile, pack: pack),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = LocalLyricTranslationManifest.decode(data, requiredDirections: pack.directions) else {
            return nil
        }
        var files: [String: URL] = [:]
        for path in manifest.requiredFiles {
            guard let url = fileURL(path, pack: pack),
                  FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            files[path] = url
        }
        return Located(manifest: manifest, files: files)
    }

    private static func fileURL(_ path: String, pack: Pack) -> URL? {
        #if DEBUG
        if let directory = debugOverrideDirectory {
            return directory.appendingPathComponent(path)
        }
        #endif
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *),
           BackgroundAssetsPrerequisites.isSatisfied,
           AssetPackManager.shared.assetPackIsAvailableLocally(withID: pack.assetPackID) {
            return try? AssetPackManager.shared.url(for: FilePath(path))
        }
        #endif
        return nil
    }

    /// Downloads the pack if needed; `progress` receives 0...1.
    static func download(_ modelPack: Pack, progress: @escaping @Sendable (Double) -> Void) async throws -> Located {
        if let located = locate(modelPack) { return located }
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *), BackgroundAssetsPrerequisites.isSatisfied {
            let manager = AssetPackManager.shared
            let pack = try await manager.assetPack(withID: modelPack.assetPackID)
            let watcher = Task {
                for await update in manager.statusUpdates(forAssetPackWithID: modelPack.assetPackID) {
                    if case .downloading(_, let fraction) = update {
                        progress(fraction.fractionCompleted)
                    }
                }
            }
            defer { watcher.cancel() }
            try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            if let located = locate(modelPack) { return located }
        }
        #endif
        throw LocalLyricsTranslationError.modelUnavailable
    }

    static func remove(_ pack: Pack) async {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *), BackgroundAssetsPrerequisites.isSatisfied {
            try? await AssetPackManager.shared.remove(assetPackWithID: pack.assetPackID)
        }
        #endif
    }
}

/// `AssetPackManager.shared` 在前提不满足时直接 fatalError 而不是抛错: 进程没有
/// team ID (未签名、「Sign to Run Locally」的 Mac 构建)、Info.plist 缺
/// `BAAppGroupID`、主 bundle 没有 ID。Mac 上打开歌词设置就因此闪退。碰它之前
/// 先自查, 不满足就当作这台设备用不了 Apple 托管的模型包。
///
/// 还有一条查不了: 系统守护进程对 app 的校验 ("The app couldn’t be validated")。
/// macOS 27.0 上同样的开发签名构建在编译机通过、在另一台 Mac 上失败, 条件由
/// 守护进程决定, app 这边预判不了。开发签名的构建本来也拿不到 Apple 托管的包 (开发期只能走 ba-serve 或
/// `PRIMUSE_LYRICS_TRANSLATION_MODEL`), 所以 Mac 上开发签名一律不碰;
/// Debug 下设 `PRIMUSE_ASSET_PACKS=1` 可放开来联调。
enum BackgroundAssetsPrerequisites {
    static let isSatisfied: Bool = evaluate()

    private static func evaluate() -> Bool {
        #if os(macOS)
        // 先看签名: 没有 team ID 时连 App Group 都不去碰, 免得非沙盒构建弹授权框。
        guard let signing = signingInformation(),
              let teamID = signing[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else {
            plog("⚠️ BackgroundAssets: process has no team ID, asset packs disabled")
            return false
        }
        let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        if entitlements?["com.apple.security.get-task-allow"] as? Bool == true {
            #if DEBUG
            let optedIn = ProcessInfo.processInfo.environment["PRIMUSE_ASSET_PACKS"] == "1"
            #else
            let optedIn = false
            #endif
            guard optedIn else {
                plog("⚠️ BackgroundAssets: development-signed build, asset packs disabled")
                return false
            }
        }
        #endif
        #if targetEnvironment(simulator)
        // 模拟器里的构建没有开发团队(未签名或本地签名), AssetPackManager 一取就终止进程,
        // Apple 托管的包在这里本来也拿不到; Debug 下设 `PRIMUSE_ASSET_PACKS=1` 可放开来联调。
        #if DEBUG
        let simulatorOptedIn = ProcessInfo.processInfo.environment["PRIMUSE_ASSET_PACKS"] == "1"
        #else
        let simulatorOptedIn = false
        #endif
        guard simulatorOptedIn else {
            plog("⚠️ BackgroundAssets: simulator build, asset packs disabled")
            return false
        }
        #endif
        let bundle = Bundle.main
        guard bundle.bundleIdentifier?.isEmpty == false,
              let groupID = bundle.object(forInfoDictionaryKey: "BAAppGroupID") as? String,
              !groupID.isEmpty,
              UserDefaults(suiteName: groupID) != nil else {
            plog("⚠️ BackgroundAssets: bundle ID or BAAppGroupID unavailable, asset packs disabled")
            return false
        }
        return true
    }

    #if os(macOS)
    private static func signingInformation() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
            &information
        ) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }
    #endif
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

    typealias Pack = LocalLyricsTranslationModel.Pack
    private(set) var requestedPack: Pack = .persian
    private var states: [Pack: ModelState] = [:]
    private var failureReasons: [Pack: String] = [:]
    var modelState: ModelState { modelState(for: requestedPack) }
    var modelFailureReason: String? { modelFailureReason(for: requestedPack) }
    private(set) var modelRevision: UInt = 0 {
        didSet { NotificationCenter.default.post(name: .localLyricsTranslationModelChanged, object: nil) }
    }
    @ObservationIgnored private var locatedPacks: [Pack: LocalLyricsTranslationModel.Located] = [:]
    @ObservationIgnored private var downloadTasks: [Pack: Task<Void, Never>] = [:]
    @ObservationIgnored private let runner = LocalLyricsTranslationRunner()

    private init() {
        for pack in Pack.allCases {
            if !LocalLyricsTranslationModel.isSystemSupported {
                states[pack] = .unsupportedSystem
            } else if let located = LocalLyricsTranslationModel.locate(pack) {
                locatedPacks[pack] = located
                states[pack] = .ready
            } else {
                states[pack] = .notDownloaded
            }
        }
    }

    func modelState(for pack: Pack) -> ModelState { states[pack] ?? .unsupportedSystem }
    func modelFailureReason(for pack: Pack) -> String? { failureReasons[pack] }
    var isModelReady: Bool { modelState == .ready }

    func refreshAvailability() {
        for pack in Pack.allCases {
            let state = modelState(for: pack)
            guard state == .ready || state == .notDownloaded else { continue }
            let current = LocalLyricsTranslationModel.locate(pack)
            if current == nil, state == .ready {
                locatedPacks[pack] = nil
                states[pack] = .notDownloaded
                modelRevision &+= 1
                Task { await runner.unload() }
            } else if let current, state == .notDownloaded {
                locatedPacks[pack] = current
                states[pack] = .ready
                modelRevision &+= 1
            }
        }
    }

    func downloadModel(_ selectedPack: Pack? = nil) {
        let pack = selectedPack ?? requestedPack
        let state = modelState(for: pack)
        guard state == .notDownloaded || state == .failed, downloadTasks[pack] == nil else { return }
        states[pack] = .downloading(0)
        failureReasons[pack] = nil
        downloadTasks[pack] = Task { @MainActor in
            do {
                let located = try await LocalLyricsTranslationModel.download(pack) { fraction in
                    Task { @MainActor in
                        guard case .downloading = self.modelState(for: pack) else { return }
                        self.states[pack] = .downloading(fraction)
                    }
                }
                self.locatedPacks[pack] = located
                self.states[pack] = .ready
                self.modelRevision &+= 1
                plog("🌐 LocalTranslation: model ready version=\(located.manifest.version)")
            } catch {
                let nsError = error as NSError
                let channel = Bundle.main.distributionChannel
                plog("⚠️ LocalTranslation: model download failed channel=\(channel.rawValue) domain=\(nsError.domain) code=\(nsError.code): \(String(describing: error))")
                self.failureReasons[pack] = channel == .development
                    ? String(localized: "karaoke_ai_download_dev_build")
                    : String(format: String(localized: "karaoke_ai_download_failed_format"), error.localizedDescription)
                self.states[pack] = .failed
            }
            self.downloadTasks[pack] = nil
        }
    }

    func removeModel(_ pack: Pack = .persian) async {
        guard downloadTasks[pack] == nil else { return }
        locatedPacks[pack] = nil
        await runner.unload()
        await LocalLyricsTranslationModel.remove(pack)
        states[pack] = LocalLyricsTranslationModel.isSystemSupported ? .notDownloaded : .unsupportedSystem
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
            if case .unsupported = route {
                route = LocalLyricTranslationPolicy.route(
                    sourceLanguageCode: group.sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode,
                    allowsSystemPivot: false
                )
            }
            switch route {
            case .unsupported:
                outcome.unsupportedGroups.append(group)
                plog("🌐 LocalTranslation: unsupported pair \(group.sourceLanguageCode ?? "auto") -> \(targetLanguageCode)")
                continue
            default:
                break
            }
            let directions = route.localDirections
            let packs = directions.map(Pack.containing)
            if let missing = packs.first(where: { locatedPacks[$0] == nil }) {
                requestedPack = missing
                outcome.groupsNeedingModel.append(group)
                continue
            }
            let versions = directions.compactMap { direction in
                locatedPacks[Pack.containing(direction)].map { $0.manifest.version }
            }.joined(separator: "+")
            let provider = LyricsTranslationCache.ProviderNamespace.local(modelVersion: versions)
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
                    var result: String? = input
                    for direction in directions {
                        guard isCurrent(), !Task.isCancelled else { return outcome }
                        guard let value = result, let located = locatedPacks[Pack.containing(direction)] else {
                            throw LocalLyricsTranslationError.modelUnavailable
                        }
                        result = try await runner.translate(value, direction: direction, located: located)
                        if result == nil { break }
                    }
                    results.append(result)
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
                if packs.contains(where: { LocalLyricsTranslationModel.locate($0) == nil }) {
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
        case .local, .localPivot, .unsupported:
            return route
        }
    }
}

/// Loads model directions on first use off the main actor and lets them go
/// after a quiet period, so the model does not stay in memory during long
/// listening sessions.
private actor LocalLyricsTranslationRunner {
    private struct ModelKey: Hashable {
        let version: String
        let direction: LocalLyricTranslationPolicy.Direction
    }
    private var directions: [ModelKey: LocalLyricsTranslationDirection] = [:]
    private var recency: [ModelKey] = []
    private var unloadTask: Task<Void, Never>?
    private static let idleUnloadDelay: Duration = .seconds(90)

    func translate(
        _ text: String,
        direction: LocalLyricTranslationPolicy.Direction,
        located: LocalLyricsTranslationModel.Located
    ) throws -> String? {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        let key = ModelKey(version: located.manifest.version, direction: direction)
        recency.removeAll { $0 == key }
        recency.append(key)
        let model: LocalLyricsTranslationDirection
        if let loaded = directions[key] {
            model = loaded
        } else {
            guard #available(iOS 18.0, macOS 15.0, tvOS 18.0, *),
                  let modelURL = located.modelURL(for: direction),
                  let vocabularyURL = located.vocabularyURL(for: direction) else {
                throw LocalLyricsTranslationError.modelUnavailable
            }
            let started = Date()
            if recency.count > 2 {
                directions[recency.removeFirst()] = nil
            }
            model = try LocalLyricsTranslationDirection(
                compiledModelURL: modelURL,
                vocabularyURL: vocabularyURL,
                targetVocabularyURL: located.targetVocabularyURL(for: direction)
            )
            directions[key] = model
            plog("🌐 LocalTranslation: loaded \(direction.source)->\(direction.target) in \(Int(Date().timeIntervalSince(started) * 1_000))ms")
        }
        return try model.translate(text)
    }

    func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        directions = [:]
        recency = []
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
