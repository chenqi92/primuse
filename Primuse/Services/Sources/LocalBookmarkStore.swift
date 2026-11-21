#if os(iOS) || os(macOS)
import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import CoreServices
#endif

/// Persists security-scoped bookmarks for user-chosen local files and folders.
/// Bookmark blobs remain device-local and are keyed by source ID, so local
/// sources can be reopened after launch without leaking filesystem access into
/// CloudKit source records.
enum LocalBookmarkStore {
    private enum StoreError: LocalizedError {
        case permissionDenied
        case originalSelectionRequired
        case folderDoesNotContainFile

        var errorDescription: String? {
            switch self {
            case .permissionDenied: String(localized: "local_reference_permission_missing")
            case .originalSelectionRequired: String(localized: "delete_source_original_selection")
            case .folderDoesNotContainFile: String(localized: "save_location_grant_wrong_folder")
            }
        }
    }

    struct ResolvedReference: Sendable {
        let virtualPathComponent: String?
        let url: URL
        let isDirectory: Bool
        /// 单独添加的文件另外授权过的所在文件夹:有了它才能在文件旁边写歌词文件、封面文件。
        var folderURL: URL? = nil

        /// Paths are compared through `LocalFileWatchPath`, so `/private`,
        /// Data-volume, Unicode-form and letter-case spellings of the same
        /// location match. Symlinked roots fall back to resolved paths.
        func sourcePath(for item: URL, root: URL? = nil) -> String? {
            let base = root ?? url
            if let suffix = LocalFileWatchPath.relativePath(of: item.standardizedFileURL.path, under: base.standardizedFileURL.path),
               let path = sourcePath(forRelative: suffix) {
                return path
            }
            return LocalFileWatchPath.relativePath(
                of: item.resolvingSymlinksInPath().path, under: base.resolvingSymlinksInPath().path
            ).flatMap { suffix in sourcePath(forRelative: suffix) }
        }

        /// Source path of an item `suffix` below this reference ("" = the reference itself).
        func sourcePath(forRelative suffix: String) -> String? {
            let prefix = virtualPathComponent.map { "/" + $0 } ?? ""
            if suffix.isEmpty { return prefix.isEmpty ? "/" : prefix }
            guard isDirectory else { return nil }
            return prefix + "/" + suffix
        }
    }

    private struct StoredReference: Codable {
        let virtualPathComponent: String?
        let bookmarkData: Data
        let isDirectory: Bool
        /// 单独添加的文件所在文件夹的授权,用户在保存歌词时另外给的。旧记录里没有。
        var folderBookmarkData: Data? = nil
        /// 授权文件夹时记下的文件名:文件自己的书签解不开时,从文件夹里按名字找回它。
        var fileName: String? = nil
    }

    private static let mutationLock = NSLock()

    private static func store(_ data: Data, forKey key: String) {
        mutationLock.withLock { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func refresh(_ data: Data, replacing original: Data, forKey key: String) {
        mutationLock.withLock {
            guard UserDefaults.standard.data(forKey: key) == original else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func hasReferences(sourceID: String) -> Bool {
        UserDefaults.standard.data(forKey: referencesKey(for: sourceID)) != nil
            || UserDefaults.standard.data(forKey: legacyKey(for: sourceID)) != nil
    }

    /// 整个源都能在歌曲旁边写文件:选的都是文件夹,或者单独添加的文件都另外授权过所在文件夹。
    static func supportsSidecarWriting(sourceID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: referencesKey(for: sourceID)) else { return true }
        return (try? JSONDecoder().decode([StoredReference].self, from: data))?.allSatisfy {
            $0.isDirectory || $0.folderBookmarkData != nil
        } == true
    }

    /// 选的都是文件夹。只有这时才能在源里改目录结构(改名、移动、删文件夹);
    /// 单独添加的文件补授权了所在文件夹,也只是能在它旁边写歌词、封面文件。
    static func referencesAreAllDirectories(sourceID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: referencesKey(for: sourceID)) else { return true }
        return (try? JSONDecoder().decode([StoredReference].self, from: data))?.allSatisfy(\.isDirectory) == true
    }

    /// 单独添加的文件被改写之后重新生成它的书签。原地改写不换文件,书签照样能用,这里只是保险;
    /// 生成不了就保留原来的。
    static func refreshFileBookmark(sourceID: String, fileURL: URL) {
        let key = referencesKey(for: sourceID)
        let target = comparablePath(fileURL)
        guard let bookmark = try? makeBookmark(for: fileURL) else {
            plog("⚠️ Local reference bookmark refresh failed source=\(sourceID.prefix(8))")
            return
        }
        mutationLock.withLock {
            guard let encoded = UserDefaults.standard.data(forKey: key),
                  var stored = try? JSONDecoder().decode([StoredReference].self, from: encoded),
                  let index = stored.indices.first(where: { index in
                      !stored[index].isDirectory
                          && resolve(stored[index].bookmarkData).map { comparablePath($0.url) } == target
                  }) else { return }
            stored[index] = StoredReference(
                virtualPathComponent: stored[index].virtualPathComponent,
                bookmarkData: bookmark,
                isDirectory: false,
                folderBookmarkData: stored[index].folderBookmarkData,
                fileName: fileURL.lastPathComponent
            )
            if let data = try? JSONEncoder().encode(stored) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    /// 给单独添加的文件补上所在文件夹的授权。`folderURL` 来自文件夹选择器;源里所有放在这个文件夹
    /// (含子文件夹)里的单独文件都用上它。返回用上了的文件数;一个都不在里面时报错,什么都不改。
    @discardableResult
    static func grantFolderAccess(sourceID: String, folderURL: URL) throws -> Int {
        let key = referencesKey(for: sourceID)
        let folderPath = comparablePath(folderURL)
        let folderPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let bookmark = try makeBookmark(for: folderURL)
        let granted: Int = try mutationLock.withLock {
            guard let encoded = UserDefaults.standard.data(forKey: key) else {
                throw StoreError.folderDoesNotContainFile
            }
            var stored = try JSONDecoder().decode([StoredReference].self, from: encoded)
            var matching: [(index: Int, fileName: String)] = []
            for index in stored.indices where !stored[index].isDirectory {
                guard let fileURL = resolve(stored[index].bookmarkData)?.url,
                      comparablePath(fileURL).hasPrefix(folderPrefix) else { continue }
                matching.append((index, fileURL.lastPathComponent))
            }
            guard !matching.isEmpty else { throw StoreError.folderDoesNotContainFile }
            for match in matching {
                stored[match.index].folderBookmarkData = bookmark
                stored[match.index].fileName = match.fileName
            }
            UserDefaults.standard.set(try JSONEncoder().encode(stored), forKey: key)
            return matching.count
        }
        plog("📁 Local reference folder access granted source=\(sourceID.prefix(8)) files=\(granted)")
        return granted
    }

    /// 比较两个本机路径用:解开符号链接(`/private/var` 与 `/var`),统一成组合形式的 Unicode。
    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
    }

    private static let legacyKeyPrefix = "primuse.localBookmark."
    private static let referencesKeyPrefix = "primuse.localBookmarks.v1."

    private static func legacyKey(for sourceID: String) -> String {
        legacyKeyPrefix + sourceID
    }

    private static func referencesKey(for sourceID: String) -> String {
        referencesKeyPrefix + sourceID
    }

    /// Retains the existing one-folder representation used by macOS sources.
    static func save(sourceID: String, url: URL) throws {
        let data = try makeBookmark(for: url)
        store(data, forKey: legacyKey(for: sourceID))
    }

    /// Regrant access without changing a source's identity or the virtual paths
    /// already stored on its songs. Selecting a different disk must not redirect
    /// a pending delete onto similarly named files there.
    static func reauthorize(source: MusicSource, urls: [URL]) throws {
        if let encoded = UserDefaults.standard.data(forKey: referencesKey(for: source.id)) {
            var stored = try JSONDecoder().decode([StoredReference].self, from: encoded)
            let originalPaths = stored.map { reference in
                resolve(reference.bookmarkData)?.url.standardizedFileURL.path
                    ?? (stored.count == 1 ? source.basePath : nil) ?? ""
            }
            guard let indices = reauthorizationIndices(
                originalPaths: originalPaths,
                selectedPaths: urls.map { $0.standardizedFileURL.path }
            ) else { throw StoreError.originalSelectionRequired }
            for (url, index) in zip(urls, indices) {
                let original = stored[index]
                stored[index] = StoredReference(
                    virtualPathComponent: original.virtualPathComponent,
                    bookmarkData: try makeBookmark(for: url),
                    isDirectory: original.isDirectory,
                    folderBookmarkData: original.folderBookmarkData,
                    fileName: original.fileName
                )
            }
            store(try JSONEncoder().encode(stored), forKey: referencesKey(for: source.id))
        } else {
            let originalPath = UserDefaults.standard.data(forKey: legacyKey(for: source.id))
                .flatMap { resolve($0)?.url.standardizedFileURL.path } ?? source.basePath ?? ""
            guard urls.count == 1,
                  reauthorizationIndices(originalPaths: [originalPath], selectedPaths: urls.map { $0.standardizedFileURL.path }) != nil
            else { throw StoreError.originalSelectionRequired }
            try save(sourceID: source.id, url: urls[0])
        }
    }

    static func reauthorizationIndices(originalPaths: [String], selectedPaths: [String]) -> [Int]? {
        guard !selectedPaths.isEmpty,
              Set(selectedPaths).count == selectedPaths.count,
              Set(originalPaths).count == originalPaths.count else { return nil }
        var indices: [Int] = []
        for path in selectedPaths {
            guard !path.isEmpty, let index = originalPaths.firstIndex(of: path) else { return nil }
            indices.append(index)
        }
        return indices
    }

    /// Persists one logical local source backed by one or more picker URLs.
    /// A single folder exposes its contents at `/` for compatibility with the
    /// existing local connector. Multiple roots and individual files receive
    /// stable virtual path components so song paths remain unambiguous.
    static func saveReferences(
        sourceID: String,
        urls: [URL],
        treatingAsDirectories: Bool? = nil
    ) throws {
        guard !urls.isEmpty else { return }

        var usedComponents = Set<String>()
        var references: [StoredReference] = []
        references.reserveCapacity(urls.count)
        for url in urls {
            let reference = try withSecurityScope(url) {
                let isDirectory: Bool
                if let treatingAsDirectories {
                    isDirectory = treatingAsDirectories
                } else {
                    isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey])
                        .isDirectory ?? false
                }
                let virtualPathComponent = urls.count == 1 && isDirectory
                    ? nil
                    : uniqueVirtualPathComponent(for: url, used: &usedComponents)
                return StoredReference(
                    virtualPathComponent: virtualPathComponent,
                    bookmarkData: try url.bookmarkData(
                        options: bookmarkCreationOptions,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ),
                    isDirectory: isDirectory
                )
            }
            references.append(reference)
        }

        let encoded = try JSONEncoder().encode(references)
        mutationLock.withLock {
            UserDefaults.standard.set(encoded, forKey: referencesKey(for: sourceID))
            UserDefaults.standard.removeObject(forKey: legacyKey(for: sourceID))
        }
    }

    /// `nil` means this source has no bookmark record. An empty array means a
    /// record exists but at least one reference could not be resolved; callers
    /// must fail the whole source rather than scanning a partial root set and
    /// pruning songs that are merely temporarily inaccessible.
    static func resolveReferences(sourceID: String, refreshStaleBookmarks: Bool = true) -> [ResolvedReference]? {
        if let encoded = UserDefaults.standard.data(forKey: referencesKey(for: sourceID)) {
            guard let stored = try? JSONDecoder().decode([StoredReference].self, from: encoded),
                  !stored.isEmpty else { return [] }
            var resolved: [ResolvedReference] = []
            resolved.reserveCapacity(stored.count)
            var refreshed = stored
            var didRefresh = false

            for (index, reference) in stored.enumerated() {
                // 补授权的文件夹解不开(被移走、删了)只是少了旁边写文件的能力,不拖垮整个源。
                let folder = reference.folderBookmarkData.flatMap { resolve($0) }
                guard let result = resolve(reference.bookmarkData)
                        ?? recoveredFileReference(reference, folder: folder?.url) else { return [] }
                resolved.append(ResolvedReference(
                    virtualPathComponent: reference.virtualPathComponent,
                    url: result.url,
                    isDirectory: reference.isDirectory,
                    folderURL: folder?.url
                ))
                if refreshStaleBookmarks, result.isStale, let bookmark = try? makeBookmark(for: result.url) {
                    refreshed[index] = StoredReference(
                        virtualPathComponent: reference.virtualPathComponent,
                        bookmarkData: bookmark,
                        isDirectory: reference.isDirectory,
                        folderBookmarkData: refreshed[index].folderBookmarkData,
                        fileName: refreshed[index].fileName
                    )
                    didRefresh = true
                }
                if refreshStaleBookmarks, let folder, folder.isStale,
                   let bookmark = try? makeBookmark(for: folder.url) {
                    refreshed[index].folderBookmarkData = bookmark
                    didRefresh = true
                }
            }
            if didRefresh, let data = try? JSONEncoder().encode(refreshed) {
                refresh(data, replacing: encoded, forKey: referencesKey(for: sourceID))
            }
            return resolved
        }

        guard let data = UserDefaults.standard.data(forKey: legacyKey(for: sourceID)) else {
            return nil
        }
        guard let result = resolve(data) else { return [] }
        if refreshStaleBookmarks, result.isStale, let refreshed = try? makeBookmark(for: result.url) {
            refresh(refreshed, replacing: data, forKey: legacyKey(for: sourceID))
        }
        return [ResolvedReference(
            virtualPathComponent: nil,
            url: result.url,
            isDirectory: true
        )]
    }

    /// The picked folder's own name when the source is a single folder shown
    /// at `/`; nil for several picked items or files.
    static func rootFolderName(sourceID: String) -> String? {
        guard let references = resolveReferences(sourceID: sourceID, refreshStaleBookmarks: false),
              references.count == 1, let only = references.first,
              only.virtualPathComponent == nil, only.isDirectory else { return nil }
        let name = only.url.lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    /// Source IDs represented by device-local bookmarks. This registry is
    /// derived from the stored keys so it cannot drift from bookmark deletion.
    static var storedSourceIDs: Set<String> {
        Set(UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key in
            if key.hasPrefix(referencesKeyPrefix) {
                return String(key.dropFirst(referencesKeyPrefix.count))
            }
            if key.hasPrefix(legacyKeyPrefix) {
                return String(key.dropFirst(legacyKeyPrefix.count))
            }
            return nil
        })
    }

    static func remove(sourceID: String) {
        mutationLock.withLock {
            UserDefaults.standard.removeObject(forKey: referencesKey(for: sourceID))
            UserDefaults.standard.removeObject(forKey: legacyKey(for: sourceID))
        }
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        try withSecurityScope(url) {
            try url.bookmarkData(
                options: bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        #endif
    }

    private static func withSecurityScope<T>(
        _ url: URL,
        operation: () throws -> T
    ) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        guard accessed else { throw StoreError.permissionDenied }
        defer { url.stopAccessingSecurityScopedResource() }
        return try operation()
    }

    /// 单独添加的文件自己的书签解不开(比如被别的工具整个换掉了),但授权过它所在的文件夹:
    /// 按记下的文件名在文件夹里找回它,当成要刷新的书签处理。找不到才算这条引用丢了。
    private static func recoveredFileReference(
        _ reference: StoredReference,
        folder: URL?
    ) -> (url: URL, isStale: Bool)? {
        guard !reference.isDirectory, let folder, let fileName = reference.fileName, !fileName.isEmpty else {
            return nil
        }
        let candidate = folder.appendingPathComponent(fileName)
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        plog("📁 Local reference recovered through its granted folder name=\(fileName)")
        return (candidate, true)
    }

    private static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        return (url, stale)
    }

    private static func uniqueVirtualPathComponent(
        for url: URL,
        used: inout Set<String>
    ) -> String {
        let raw = url.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.isEmpty ? "Local Item" : raw
        var candidate = base
        var suffix = 2
        while !used.insert(candidate.lowercased()).inserted {
            candidate = "\(base) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        [.minimalBookmark]
        #endif
    }

    static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope, .withoutUI, .withoutMounting]
        #else
        [.withoutImplicitStartAccessing, .withoutUI, .withoutMounting]
        #endif
    }
}

private actor LocalReferenceResolutionWorker {
    func resolve(_ sourceIDs: Set<String>, fallbackRoots: [String: URL]) -> [String: [LocalBookmarkStore.ResolvedReference]] {
        var result: [String: [LocalBookmarkStore.ResolvedReference]] = [:]
        for sourceID in sourceIDs.sorted() {
            if let references = LocalBookmarkStore.resolveReferences(sourceID: sourceID, refreshStaleBookmarks: false),
               !references.isEmpty {
                result[sourceID] = references
            } else if !LocalBookmarkStore.hasReferences(sourceID: sourceID), let root = fallbackRoots[sourceID] {
                result[sourceID] = [.init(virtualPathComponent: nil, url: root, isDirectory: true)]
            }
        }
        return result
    }
}

enum LocalReferenceChange: Hashable, Sendable {
    /// The file's content changed: read it even if size and dates match.
    case item(String)
    case removed(String)
    case directory(String)
    case directoryHint(String)
    /// Compare a known song's file with the library; read only when it differs.
    case check(String)
    case verify(songID: String)
    /// Retry of a content change that could not be read yet.
    case reread(songID: String)

    static func parent(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).deletingLastPathComponent
    }
}

/// Where a batch of changes came from, for the diagnostic log.
enum LocalFileWatchTrigger: String, Sendable {
    case fileEvents = "fsevents"
    case presenter
    case visible
    case activation
    case retry
}

/// Keeps user-selected local references synchronized while the application is
/// running. File presenter callbacks cover coordinated changes made by Files,
/// Finder and File Provider extensions. The source refresh coordinator handles
/// foreground reconciliation using the user's selected interval.
@MainActor
final class LocalReferenceRefreshService {
    private let sourcesStore: SourcesStore
    private let sourceManager: SourceManager
    private let library: MusicLibrary
    private let scanService: ScanService
    private let scraperService: MusicScraperService
    private let automaticRefreshEnabled: (String) -> Bool
    private let automaticWorkAllowed: () -> Bool
    private let fileWorkAllowed: () -> Bool
    private let currentSong: () -> Song?

    private var presentersBySourceID: [String: [LocalReferenceFilePresenter]] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var pendingChanges: [String: Set<LocalReferenceChange>] = [:]
    private var processingChanges: [String: Set<LocalReferenceChange>] = [:]
    #if os(macOS)
    private var eventStreams: [String: MacLocalReferenceEvents] = [:]
    #endif
    private var observerTokens: [NSObjectProtocol] = []
    private let resolutionWorker = LocalReferenceResolutionWorker()
    private var presenterReconciliationTask: Task<Void, Never>?
    private var presenterRevision: UInt64 = 0
    private var pendingPresenterSourceIDs: Set<String> = []
    private var fallbackRoots: [String: URL] = [:]
    private var isPresenting = false
    private var hasStarted = false
    private var pendingTriggers: [String: Set<LocalFileWatchTrigger>] = [:]
    /// Song ID → reads already deferred for the current change.
    private var retryAttempts: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    /// Source ID → source paths of individually added files.
    private var individualFilePaths: [String: [String]] = [:]
    private var lastIndividualFileCheck: Date?
    private var checksIndividualFilesAfterRegistration = false

    /// What the watcher has done since launch; read by the diagnostics tests.
    struct Activity: Equatable {
        var reread = 0
        var unchanged = 0
        var ownWrite = 0
        var deferred = 0
    }

    private(set) var activity = Activity()
    var retryingSongIDs: Set<String> { Set(retryAttempts.keys) }

    init(
        sourcesStore: SourcesStore,
        sourceManager: SourceManager,
        library: MusicLibrary,
        scanService: ScanService,
        scraperService: MusicScraperService,
        currentSong: @escaping () -> Song? = { nil },
        fileWorkAllowed: (() -> Bool)? = nil,
        automaticRefreshEnabled: @escaping (String) -> Bool,
        automaticWorkAllowed: @escaping () -> Bool
    ) {
        self.sourcesStore = sourcesStore
        self.sourceManager = sourceManager
        self.library = library
        self.scanService = scanService
        self.scraperService = scraperService
        self.currentSong = currentSong
        self.automaticRefreshEnabled = automaticRefreshEnabled
        self.automaticWorkAllowed = automaticWorkAllowed
        self.fileWorkAllowed = fileWorkAllowed ?? automaticWorkAllowed
    }

    func refreshPreferences() {
        reconcilePresenters()
    }

    func stop() {
        deactivate()
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens.removeAll()
        pendingChanges.removeAll()
        pendingTriggers.removeAll()
        hasStarted = false
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: .primuseSourcesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconcilePresenters()
            }
        })

        #if os(iOS)
        observerTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.deactivate()
            }
        })
        observerTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.activate()
            }
        })
        guard UIApplication.shared.applicationState != .background else { return }
        #elseif os(macOS)
        // The Mac keeps watching while inactive. Coming back to the app is
        // when someone looks at songs that may have changed on another
        // device, so individually added files (whose folders the app may not
        // be allowed to watch) are compared once more.
        observerTokens.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applicationDidBecomeActive()
            }
        })
        #endif

        activate()
    }

    #if os(macOS)
    private func applicationDidBecomeActive() {
        checkIndividuallyAddedFiles(force: false)
        if let song = currentSong() { verifyWhenVisible(song, via: .activation) }
    }
    #endif

    private func activate() {
        guard !isPresenting else { return }
        isPresenting = true
        checksIndividualFilesAfterRegistration = true
        reconcilePresenters()
        if let song = currentSong() { verifyWhenVisible(song, via: .activation) }
    }

    private func deactivate() {
        guard isPresenting else { return }
        isPresenting = false
        presenterRevision &+= 1
        for task in refreshTasks.values {
            task.cancel()
        }
        for task in retryTasks.values {
            task.cancel()
        }
        retryTasks.removeAll()
        retryAttempts.removeAll()
        for (sourceID, changes) in processingChanges {
            pendingChanges[sourceID, default: []].formUnion(changes)
        }
        processingChanges.removeAll()
        refreshTasks.removeAll()
        unregisterAllPresenters()
    }

    private func reconcilePresenters() {
        guard isPresenting else { return }

        let bookmarked = LocalBookmarkStore.storedSourceIDs
        fallbackRoots.removeAll()
        for source in sourcesStore.sources where source.type == .local && !bookmarked.contains(source.id) {
            #if os(iOS)
            if LocalImportService.isManagedSource(source) { fallbackRoots[source.id] = LocalImportService.musicDirectory }
            #elseif os(macOS)
            if let path = source.basePath, path.hasPrefix("/") {
                fallbackRoots[source.id] = URL(fileURLWithPath: path, isDirectory: true)
            }
            #endif
        }
        let monitoredSourceIDs = LocalReferenceRefreshPolicy.monitoredSourceIDs(
            in: sourcesStore.sources,
            bookmarkedSourceIDs: bookmarked,
            additionalRootSourceIDs: Set(fallbackRoots.keys),
            automaticRefreshEnabledSourceIDs: Set(sourcesStore.sources.compactMap {
                automaticRefreshEnabled($0.id) ? $0.id : nil
            })
        )
        let unmonitoredSourceIDs = refreshTasks.keys.filter {
            !monitoredSourceIDs.contains($0)
        }
        for sourceID in unmonitoredSourceIDs {
            refreshTasks.removeValue(forKey: sourceID)?.cancel()
            processingChanges[sourceID] = nil
        }
        pendingChanges = pendingChanges.filter { monitoredSourceIDs.contains($0.key) }

        presenterRevision &+= 1
        pendingPresenterSourceIDs = monitoredSourceIDs
        for sourceID in Set(presentersBySourceID.keys).subtracting(monitoredSourceIDs) {
            #if os(macOS)
            eventStreams[sourceID] = nil
            #endif
            for presenter in presentersBySourceID.removeValue(forKey: sourceID) ?? [] {
                NSFileCoordinator.removeFilePresenter(presenter)
            }
        }
        guard presenterReconciliationTask == nil else { return }
        presenterReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { presenterReconciliationTask = nil }
            // Coalesce changes while a single off-main resolution is in flight.
            // A removed source or an inactive scene must never regain presenters.
            while isPresenting {
                let revision = presenterRevision
                let referencesBySource = await resolutionWorker.resolve(pendingPresenterSourceIDs, fallbackRoots: fallbackRoots)
                guard isPresenting else { return }
                guard revision == presenterRevision else { continue }
                unregisterAllPresenters()
                for (sourceID, references) in referencesBySource {
                    let changed: @Sendable (LocalReferenceChange) -> Void = { [weak self] change in
                        Task { @MainActor in self?.enqueue([change], sourceID: sourceID, via: .presenter) }
                    }
                    presentersBySourceID[sourceID] = references.map { reference in
                        let presenter = LocalReferenceFilePresenter(reference: reference, onChange: changed)
                        NSFileCoordinator.addFilePresenter(presenter)
                        return presenter
                    }
                    individualFilePaths[sourceID] = references.filter { !$0.isDirectory }
                        .compactMap { $0.sourcePath(forRelative: "") }
                    #if os(macOS)
                    let label = "source=\(sourceID.prefix(8))"
                    let stream = MacLocalReferenceEvents(references: references, label: label) { [weak self] changes in
                        Task { @MainActor in self?.enqueue(changes, sourceID: sourceID, via: .fileEvents) }
                    }
                    eventStreams[sourceID] = stream
                    let folders = references.filter(\.isDirectory).count
                    plog("LocalFileWatch stream \(label) folders=\(folders) files=\(references.count - folders) started=\(stream != nil)")
                    #endif
                    schedulePending(sourceID)
                }
                if checksIndividualFilesAfterRegistration {
                    checksIndividualFilesAfterRegistration = false
                    checkIndividuallyAddedFiles(force: true)
                }
                return
            }
        }
    }

    private func unregisterAllPresenters() {
        #if os(macOS)
        eventStreams.removeAll()
        #endif
        for presenter in presentersBySourceID.values.joined() {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presentersBySourceID.removeAll()
        individualFilePaths.removeAll()
    }

    func verifyWhenVisible(_ song: Song) {
        verifyWhenVisible(song, via: .visible)
    }

    private func verifyWhenVisible(_ song: Song, via trigger: LocalFileWatchTrigger) {
        guard !song.isCueTrack, !song.isDiscImageTrack, !song.isStreamDescriptor else { return }
        enqueue([.verify(songID: song.id)], sourceID: song.sourceID, via: trigger)
    }

    /// Individually added files are few, and their parent folders may be
    /// outside what the sandbox lets the app watch; comparing their size and
    /// dates is cheap.
    private func checkIndividuallyAddedFiles(force: Bool) {
        guard isPresenting else { return }
        let now = Date()
        if !force, let last = lastIndividualFileCheck,
           now.timeIntervalSince(last) < LocalFileWatchSchedule.individualFileCheckInterval { return }
        lastIndividualFileCheck = now
        for (sourceID, paths) in individualFilePaths where !paths.isEmpty {
            enqueue(Set(paths.map { LocalReferenceChange.check($0) }), sourceID: sourceID, via: .activation)
        }
    }

    private func enqueue(_ changes: Set<LocalReferenceChange>, sourceID: String, via trigger: LocalFileWatchTrigger) {
        guard isPresenting, pendingPresenterSourceIDs.contains(sourceID) else { return }
        pendingChanges[sourceID, default: []].formUnion(changes)
        pendingTriggers[sourceID, default: []].insert(trigger)
        schedulePending(sourceID)
    }

    /// Puts unfinished work back after an interruption.
    private func requeue(_ changes: Set<LocalReferenceChange>, triggers: Set<LocalFileWatchTrigger>, sourceID: String) {
        guard !Task.isCancelled else { return }
        pendingChanges[sourceID, default: []].formUnion(changes)
        pendingTriggers[sourceID, default: []].formUnion(triggers)
    }

    /// Returns false when the policy gives up on this song for now.
    private func scheduleRetry(songID: String, sourceID: String, notified: Bool, reason: LocalFileReadDeferral) -> Bool {
        let attempt = (retryAttempts[songID] ?? 0) + 1
        let source8 = String(sourceID.prefix(8))
        let song8 = String(songID.prefix(8))
        guard let delay = LocalFileRefreshRetryPolicy.delay(for: reason, attempt: attempt, notified: notified) else {
            retryAttempts[songID] = nil
            if notified {
                plog("LocalFileWatch deferred source=\(source8) song=\(song8) reason=\(reason.rawValue) attempt=\(attempt) retry=none")
            }
            return false
        }
        retryAttempts[songID] = attempt
        retryTasks[songID]?.cancel()
        retryTasks[songID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            retryTasks[songID] = nil
            let change: LocalReferenceChange = notified ? .reread(songID: songID) : .verify(songID: songID)
            enqueue([change], sourceID: sourceID, via: .retry)
        }
        plog("LocalFileWatch deferred source=\(source8) song=\(song8) reason=\(reason.rawValue) attempt=\(attempt) retryIn=\(Int(delay))s")
        return true
    }

    private func schedulePending(_ sourceID: String) {
        guard presentersBySourceID[sourceID] != nil, refreshTasks[sourceID] == nil,
              pendingChanges[sourceID]?.isEmpty == false else { return }
        refreshTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(LocalReferenceRefreshPolicy.changeDebounce))
            var retryDelay = LocalReferenceRefreshPolicy.busyRetryDelay
            while !Task.isCancelled, isPresenting, let source = sourcesStore.source(id: sourceID),
                  source.isEnabled, !source.isDeleted, automaticRefreshEnabled(sourceID),
                  pendingChanges[sourceID]?.isEmpty == false {
                let foldersOnly = pendingChanges[sourceID]?.allSatisfy { change in
                    switch change {
                    case .directory, .directoryHint: true
                    default: false
                    }
                } == true
                if !library.isReady || scanService.hasActiveScans || !(foldersOnly ? automaticWorkAllowed() : fileWorkAllowed()) {
                    try? await Task.sleep(for: .seconds(retryDelay))
                    retryDelay = min(30, retryDelay * 2)
                    continue
                }
                retryDelay = LocalReferenceRefreshPolicy.busyRetryDelay
                let changes = pendingChanges.removeValue(forKey: sourceID) ?? []
                let triggers = pendingTriggers.removeValue(forKey: sourceID) ?? []
                processingChanges[sourceID] = changes
                await refresh(changes, source: source, triggers: triggers)
                if !Task.isCancelled { processingChanges[sourceID] = nil }
            }
            if !Task.isCancelled { refreshTasks[sourceID] = nil }
        }
    }

    private func refresh(_ changes: Set<LocalReferenceChange>, source: MusicSource, triggers: Set<LocalFileWatchTrigger>) async {
        guard let local = sourceManager.connector(for: source) as? LocalFileSource else { return }
        var files: [String: Bool] = [:] // song ID → a file notification requires reading even if attributes match
        var directories: Set<String> = []
        var hints: Set<String> = []
        var exactPaths: Set<String> = []
        var summary = Activity()
        let via = triggers.map(\.rawValue).sorted().joined(separator: ",")
        let index = scanService.libraryFolderSyncIndex(for: source.id)
        /// The one plain song stored at `path`, if any.
        func knownSong(at path: String, entry: SourceSyncIndexedItem?) -> Song? {
            let ids = entry?.songIDs ?? [LocalFileSource.generateID(sourceID: source.id, path: path)]
            guard ids.count == 1, let id = ids.first, let song = library.storedSong(id: id),
                  song.sourceID == source.id, song.filePath == path,
                  !song.isCueTrack, !song.isDiscImageTrack, !song.isStreamDescriptor else { return nil }
            return song
        }
        for change in changes {
            switch change {
            case .verify(let id): if files[id] == nil { files[id] = false }
            case .reread(let id): files[id] = true
            case .check(let path):
                let entry = index[path] ?? index["path:" + path.lowercased()]
                guard let song = knownSong(at: path, entry: entry) else { continue }
                exactPaths.insert(path)
                if files[song.id] == nil { files[song.id] = false }
            case .directory(let path):
                directories.insert(path)
                exactPaths.insert(path)
            case .directoryHint(let path): hints.insert(path)
            case .item(let path), .removed(let path):
                let entry = index[path] ?? index["path:" + path.lowercased()]
                let ext = (path as NSString).pathExtension.lowercased()
                guard path == "/" || entry != nil || PrimuseConstants.supportedAudioExtensions.contains(ext)
                    || PrimuseConstants.sidecarFileExtensions.contains(ext)
                    || PrimuseConstants.supportedMusicVideoExtensions.contains(ext)
                    || PrimuseConstants.supportedStreamDescriptorExtensions.contains(ext) else { continue }
                exactPaths.insert(path)
                if let song = knownSong(at: path, entry: entry) {
                    // A rename onto a known path is usually an atomic save; the
                    // read tells a replaced file from a deleted one.
                    files[song.id] = true
                } else if await local.isOwnWrite(path) {
                    // A cover or lyrics file this app just wrote beside a song.
                    summary.ownWrite += 1
                } else {
                    directories.insert(LocalReferenceChange.parent(of: path))
                }
            }
        }
        // Some providers accompany an exact child event with a generic root callback.
        for hint in hints where !exactPaths.contains(where: { SourceDirectorySelectionPolicy.covers(hint, $0, for: .local) }) {
            directories.insert(hint)
        }
        var updates: [(previous: Song, updated: Song)] = []
        var applied = 0
        func publishUpdates() {
            let songs = updates.compactMap { previous, updated -> Song? in
                guard let live = library.storedSong(id: previous.id), live.sourceID == source.id,
                      live.filePath == previous.filePath, live.revision == previous.revision,
                      live.fileSize == previous.fileSize else { return nil }
                var merged = SongUserMetadataPolicy.preservingUserEdits(from: live, in: updated)
                merged.lyricsText = live.lyricsText
                return library.matchesStoredSong(merged) ? nil : merged
            }
            updates.removeAll(keepingCapacity: true)
            guard !songs.isEmpty else { return }
            applied += songs.count
            if songs.count == 1 { library.replaceSong(songs[0]) } else { library.replaceSongs(songs) }
            NotificationCenter.default.post(name: .primuseSongContentChanged, object: nil, userInfo: ["songs": songs])
        }
        let source8 = String(source.id.prefix(8))
        for (offset, file) in files.enumerated() {
            let (id, notified) = file
            guard canContinue(source.id), !scanService.hasActiveScans, !offset.isMultiple(of: 16) || fileWorkAllowed() else {
                requeue(changes, triggers: triggers, sourceID: source.id)
                return
            }
            guard let previous = library.storedSong(id: id), previous.sourceID == source.id,
                  let outcome = try? await local.refreshLocalSong(previous, notified: notified),
                  !Task.isCancelled else { continue }
            switch outcome {
            case .updated(let updated):
                retryAttempts[id] = nil
                summary.reread += 1
                updates.append((previous, updated))
                let identity = LocalFileWatchLog.identityChange(
                    beforeSize: previous.fileSize, beforeModified: previous.lastModified, beforeRevision: previous.revision,
                    afterSize: updated.fileSize, afterModified: updated.lastModified, afterRevision: updated.revision
                )
                let fields = LocalFileWatchLog.changedFields(from: previous, to: updated)
                plog("LocalFileWatch reread source=\(source8) song=\(id.prefix(8)) via=\(via) notified=\(notified) "
                    + "\(identity) changed=\(fields.isEmpty ? "none" : fields.joined(separator: ",")) "
                    + "userEdited=\(previous.userMetadataEditedAt != nil)")
                if updates.count == 32, canContinue(source.id), !scanService.hasActiveScans { publishUpdates() }
            case .unchanged:
                retryAttempts[id] = nil
                summary.unchanged += 1
            case .ownWrite:
                retryAttempts[id] = nil
                summary.ownWrite += 1
            case .deferred(let reason):
                // A visible row whose file is only a placeholder stays quiet.
                if scheduleRetry(songID: id, sourceID: source.id, notified: notified, reason: reason) || notified {
                    summary.deferred += 1
                } else {
                    summary.unchanged += 1
                }
                if notified, reason == .missing, retryAttempts[id] == nil {
                    // Still gone after the grace period: the folder scan prunes it.
                    directories.insert(LocalReferenceChange.parent(of: previous.filePath))
                }
            }
        }
        activity.reread += summary.reread
        activity.unchanged += summary.unchanged
        activity.ownWrite += summary.ownWrite
        activity.deferred += summary.deferred
        guard canContinue(source.id), !scanService.hasActiveScans else {
            requeue(changes, triggers: triggers, sourceID: source.id)
            return
        }
        publishUpdates()
        if summary.reread + summary.ownWrite + summary.deferred > 0 || !directories.isEmpty {
            plog("LocalFileWatch batch source=\(source8) via=\(via) files=\(files.count) reread=\(summary.reread) "
                + "applied=\(applied) unchanged=\(summary.unchanged) ownWrite=\(summary.ownWrite) "
                + "deferred=\(summary.deferred) folders=\(directories.count)")
        }
        for path in directories.sorted() where !directories.contains(where: { $0 != path && SourceDirectorySelectionPolicy.covers($0, path, for: .local) }) {
            guard canContinue(source.id), !scanService.hasActiveScans, automaticWorkAllowed() else {
                if !Task.isCancelled { pendingChanges[source.id, default: []].insert(.directory(path)) }
                continue
            }
            if scanService.scanSource(source, snapshotExecutionContext: .foregroundResume,
                                      sourceManager: sourceManager, library: library, sourceStore: sourcesStore,
                                      scraperService: scraperService, folderRescan: .init(directoryCandidates: [path]),
                                      requestsContinuedProcessing: false,
                                      automaticRefreshIsAllowed: { [weak self] in
                                          self?.canContinue(source.id) == true && self?.automaticWorkAllowed() == true
                                      }) {
                await scanService.waitForActiveScansToComplete()
            }
        }
    }

    private func canContinue(_ sourceID: String) -> Bool {
        !Task.isCancelled && isPresenting && pendingPresenterSourceIDs.contains(sourceID) && automaticRefreshEnabled(sourceID)
    }
}

private final class LocalReferenceFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemOperationQueue: OperationQueue

    private let reference: LocalBookmarkStore.ResolvedReference
    private let onChange: @Sendable (LocalReferenceChange) -> Void
    private let urlLock = NSLock()
    private var currentURL: URL
    private let securityScopedURL: URL
    private let usesSecurityScope: Bool

    var presentedItemURL: URL? {
        urlLock.lock()
        defer { urlLock.unlock() }
        return currentURL
    }

    init(reference: LocalBookmarkStore.ResolvedReference, onChange: @escaping @Sendable (LocalReferenceChange) -> Void) {
        self.reference = reference
        let url = reference.url
        self.onChange = onChange
        self.currentURL = url
        self.securityScopedURL = url
        self.usesSecurityScope = url.startAccessingSecurityScopedResource()
        let queue = OperationQueue()
        queue.name = "com.welape.yuanyin.local-reference-presenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.presentedItemOperationQueue = queue
        super.init()
    }

    deinit {
        if usesSecurityScope {
            securityScopedURL.stopAccessingSecurityScopedResource()
        }
    }

    func presentedItemDidChange() {
        guard let url = presentedItemURL, let path = reference.sourcePath(for: url, root: url) else { return }
        onChange(reference.isDirectory ? .directoryHint(path) : .item(path))
    }

    var observedPresentedItemUbiquityAttributes: Set<URLResourceKey> {
        reference.isDirectory ? [] : [.ubiquitousItemDownloadingStatusKey]
    }

    func presentedItemDidChangeUbiquityAttributes(_ attributes: Set<URLResourceKey>) {
        if attributes.contains(.ubiquitousItemDownloadingStatusKey) { presentedItemDidChange() }
    }

    func presentedItemDidGain(_ version: NSFileVersion) { presentedItemDidChange() }
    func presentedItemDidResolveConflict(_ version: NSFileVersion) { presentedItemDidChange() }

    func presentedItemDidMove(to newURL: URL) {
        urlLock.lock()
        let oldURL = currentURL
        currentURL = newURL
        urlLock.unlock()
        if !reference.isDirectory {
            // A file presenter follows the file object. When a provider moves
            // the old version aside and puts a new one at the original path,
            // this presenter stops hearing about the original path; the Mac
            // event stream and the activation check still cover it.
            let sameFolder = LocalFileWatchPath.key(oldURL.deletingLastPathComponent().path)
                == LocalFileWatchPath.key(newURL.deletingLastPathComponent().path)
            plog("LocalFileWatch presenter followed a move kind=file sameFolder=\(sameFolder)")
        }
        presentedItemDidChange()
    }

    func accommodatePresentedItemDeletion(
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        if let url = presentedItemURL, let path = reference.sourcePath(for: url, root: url) {
            onChange(.removed(path))
        }
        completionHandler(nil)
    }

    func presentedSubitemDidAppear(at url: URL) {
        presentedSubitemDidChange(at: url)
    }

    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { presentedSubitemDidChange(at: url) }
    func presentedSubitem(at url: URL, didResolveConflict version: NSFileVersion) { presentedSubitemDidChange(at: url) }

    func presentedSubitemDidChange(at url: URL) {
        guard let path = reference.sourcePath(for: url, root: presentedItemURL) else { return }
        if url.hasDirectoryPath {
            onChange(.directoryHint(path))
        } else if !url.lastPathComponent.hasPrefix(".") {
            onChange(.item(path))
        }
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        reportRemoval(oldURL)
        presentedSubitemDidAppear(at: newURL)
    }

    func accommodatePresentedSubitemDeletion(
        at url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        reportRemoval(url)
        completionHandler(nil)
    }

    private func reportRemoval(_ url: URL) {
        guard !url.lastPathComponent.hasPrefix("."), let path = reference.sourcePath(for: url, root: presentedItemURL) else { return }
        onChange(url.hasDirectoryPath ? .directory(LocalReferenceChange.parent(of: path)) : .removed(path))
    }
}

#if os(macOS)
/// Finder and tag editors can write directly without an NSFileCoordinator.
/// One file-events stream covers the selected trees, including nested albums;
/// individually added files are watched through their parent folders.
final class MacLocalReferenceEvents {
    /// Runs on the stream's serial queue only.
    private final class Handler {
        private struct FolderIdentity: Equatable {
            let device: Int32
            let inode: UInt64
        }

        let send: @Sendable (Set<LocalReferenceChange>) -> Void
        private let label: String
        private let references: [LocalBookmarkStore.ResolvedReference]
        private let directories: [LocalBookmarkStore.ResolvedReference]
        private let files: [LocalBookmarkStore.ResolvedReference]
        // Filled on the event queue: resolving symlinks touches the disk.
        private var isPrepared = false
        private var directoryRoots: [[String]] = []
        private var filesByKey: [String: [Int]] = [:]
        private var filesByFoldedKey: [String: [Int]] = [:]
        private var filesByFoldedName: [String: [Int]] = [:]
        private var filesByFoldedParent: [String: [Int]] = [:]
        private var fileParentPaths: [String] = []
        private var parentIdentities: [Int: FolderIdentity?] = [:]
        private var reportedUnmatched = false
        private var reportedIdentityMatch = false

        init(_ references: [LocalBookmarkStore.ResolvedReference], label: String,
             send: @escaping @Sendable (Set<LocalReferenceChange>) -> Void) {
            self.references = references
            self.label = label
            self.send = send
            directories = references.filter(\.isDirectory)
            files = references.filter { !$0.isDirectory }
        }

        private static func spellings(of url: URL) -> [String] {
            let standardized = url.standardizedFileURL.path
            let resolved = url.resolvingSymlinksInPath().path
            return standardized == resolved ? [standardized] : [standardized, resolved]
        }

        private static func foldedName(_ name: String) -> String {
            name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        }

        private func prepareIfNeeded() {
            guard !isPrepared else { return }
            isPrepared = true
            directoryRoots = directories.map { Self.spellings(of: $0.url) }
            var parents: Set<String> = []
            for (index, file) in files.enumerated() {
                let spellings = Self.spellings(of: file.url)
                for key in Set(spellings.map(LocalFileWatchPath.key)) { filesByKey[key, default: []].append(index) }
                for key in Set(spellings.map(LocalFileWatchPath.caseFoldedKey)) { filesByFoldedKey[key, default: []].append(index) }
                let parentSpellings = spellings.map { ($0 as NSString).deletingLastPathComponent }
                for key in Set(parentSpellings.map(LocalFileWatchPath.caseFoldedKey)) {
                    filesByFoldedParent[key, default: []].append(index)
                }
                parents.formUnion(parentSpellings)
                filesByFoldedName[Self.foldedName(file.url.lastPathComponent), default: []].append(index)
            }
            fileParentPaths = parents.sorted()
        }

        func collect(path: String, flags raw: FSEventStreamEventFlags, into changes: inout Set<LocalReferenceChange>) {
            prepareIfNeeded()
            let flags = Self.flags(raw)
            if flags.contains(.eventsDropped) {
                for reference in references {
                    guard let root = reference.sourcePath(forRelative: "") else { continue }
                    changes.insert(reference.isDirectory ? .directory(root) : .item(root))
                }
                return
            }
            let name = (path as NSString).lastPathComponent
            var matches: [(reference: LocalBookmarkStore.ResolvedReference, path: String)] = []
            for (index, reference) in directories.enumerated() {
                for root in directoryRoots[index] {
                    guard let suffix = LocalFileWatchPath.relativePath(of: path, under: root),
                          let sourcePath = reference.sourcePath(forRelative: suffix) else { continue }
                    matches.append((reference: reference, path: sourcePath))
                    break
                }
            }
            if !flags.contains(.isDirectory) {
                for index in matchingFiles(path: path, name: name) {
                    guard let sourcePath = files[index].sourcePath(forRelative: "") else { continue }
                    matches.append((reference: files[index], path: sourcePath))
                }
            }
            if flags.contains(.mustRescan), let held = filesByFoldedParent[LocalFileWatchPath.caseFoldedKey(path)] {
                // The folder holding individually added files moved or overflowed.
                for index in Set(held) {
                    guard let sourcePath = files[index].sourcePath(forRelative: "") else { continue }
                    changes.insert(.check(sourcePath))
                }
            }
            guard !matches.isEmpty else {
                noteUnmatched(path: path, name: name)
                return
            }
            var exists: Bool?
            let disposition = LocalFileEventClassifier.disposition(for: flags, name: name) {
                if let exists { return exists }
                let found = FileManager.default.fileExists(atPath: path)
                exists = found
                return found
            }
            for (reference, relative) in matches {
                switch disposition {
                case .ignore, .rescanAll: continue
                case .rescanItem: changes.insert(reference.isDirectory ? .directory(relative) : .item(relative))
                case .fileContentChanged: changes.insert(.item(relative))
                case .fileAttributesChanged: changes.insert(.check(relative))
                case .fileRemoved: changes.insert(.removed(relative))
                case .folderContentsChanged: changes.insert(.directoryHint(relative))
                case .folderMoved: changes.insert(.directory(LocalReferenceChange.parent(of: relative)))
                }
            }
        }

        /// Exact spelling first, then letter case, then the same name in the
        /// same folder compared by the folder's identity, which also covers
        /// spellings the keys do not know about.
        private func matchingFiles(path: String, name: String) -> [Int] {
            guard !files.isEmpty else { return [] }
            if let hits = filesByKey[LocalFileWatchPath.key(path)] { return hits }
            if let hits = filesByFoldedKey[LocalFileWatchPath.caseFoldedKey(path)] { return hits }
            guard let candidates = filesByFoldedName[Self.foldedName(name)],
                  let folder = Self.folderIdentity((path as NSString).deletingLastPathComponent) else { return [] }
            let hits = candidates.filter { parentIdentity(of: $0) == folder }
            if !hits.isEmpty, !reportedIdentityMatch {
                reportedIdentityMatch = true
                plog("LocalFileWatch matched an individually added file by folder identity \(label) form=\(LocalFileWatchPath.aliasForm(path))")
            }
            return hits
        }

        private func parentIdentity(of index: Int) -> FolderIdentity? {
            if let cached = parentIdentities[index] { return cached }
            let identity = Self.folderIdentity(files[index].url.deletingLastPathComponent().path)
            parentIdentities[index] = .some(identity)
            return identity
        }

        private static func folderIdentity(_ path: String) -> FolderIdentity? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return FolderIdentity(device: info.st_dev, inode: UInt64(info.st_ino))
        }

        /// Logs once per stream when an event under the watched folders
        /// matched nothing, which means its spelling was not recognised.
        private func noteUnmatched(path: String, name: String) {
            guard !reportedUnmatched, !name.hasPrefix(".") else { return }
            // Neighbours of individually added files are expected here.
            guard !fileParentPaths.contains(where: { LocalFileWatchPath.relativePath(of: path, under: $0) != nil }) else { return }
            reportedUnmatched = true
            plog("LocalFileWatch unmatched event \(label) form=\(LocalFileWatchPath.aliasForm(path)) "
                + "folders=\(directories.count) files=\(files.count)")
        }

        private static func flags(_ raw: FSEventStreamEventFlags) -> LocalFileEventFlags {
            func has<Flag: BinaryInteger>(_ flag: Flag) -> Bool {
                raw & FSEventStreamEventFlags(truncatingIfNeeded: flag) != 0
            }
            var flags: LocalFileEventFlags = []
            if has(kFSEventStreamEventFlagKernelDropped) || has(kFSEventStreamEventFlagUserDropped) { flags.insert(.eventsDropped) }
            if has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged) { flags.insert(.mustRescan) }
            if has(kFSEventStreamEventFlagItemIsDir) { flags.insert(.isDirectory) }
            if has(kFSEventStreamEventFlagItemCreated) { flags.insert(.created) }
            if has(kFSEventStreamEventFlagItemRemoved) { flags.insert(.removed) }
            if has(kFSEventStreamEventFlagItemRenamed) { flags.insert(.renamed) }
            if has(kFSEventStreamEventFlagItemModified) { flags.insert(.modified) }
            if has(kFSEventStreamEventFlagItemInodeMetaMod) { flags.insert(.inodeMetadataChanged) }
            if has(kFSEventStreamEventFlagItemXattrMod) { flags.insert(.extendedAttributesChanged) }
            if has(kFSEventStreamEventFlagItemCloned) { flags.insert(.cloned) }
            return flags
        }
    }

    private let stream: FSEventStreamRef

    init?(references: [LocalBookmarkStore.ResolvedReference], label: String = "",
          onChange: @escaping @Sendable (Set<LocalReferenceChange>) -> Void) {
        let handler = Handler(references, label: label, send: onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { info in
                if let info { _ = Unmanaged<Handler>.fromOpaque(info).retain() }
                return info
            }, release: { info in
                if let info { Unmanaged<Handler>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let paths = Array(Set(references.map { $0.isDirectory ? $0.url.path : $0.url.deletingLastPathComponent().path })) as CFArray
        guard let stream = withExtendedLifetime(handler, {
            FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
                guard let info else { return }
                let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
                let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var changes: Set<LocalReferenceChange> = []
                for index in 0..<count {
                    handler.collect(path: String(cString: paths[index]), flags: flags[index], into: &changes)
                }
                if !changes.isEmpty { handler.send(changes) }
            }, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        }) else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.primuse.local-file-events", qos: .utility))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#endif
#endif
