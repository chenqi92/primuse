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

        var errorDescription: String? {
            switch self {
            case .permissionDenied: String(localized: "local_reference_permission_missing")
            case .originalSelectionRequired: String(localized: "delete_source_original_selection")
            }
        }
    }

    struct ResolvedReference: Sendable {
        let virtualPathComponent: String?
        let url: URL
        let isDirectory: Bool

        func sourcePath(for item: URL, root: URL? = nil) -> String? {
            func relative(_ base: String, _ path: String) -> String? {
                let prefix = virtualPathComponent.map { "/" + $0 } ?? ""
                if path == base { return prefix.isEmpty ? "/" : prefix }
                let directory = base.hasSuffix("/") ? base : base + "/"
                guard isDirectory, path.hasPrefix(directory) else { return nil }
                return prefix + "/" + path.dropFirst(directory.count)
            }
            let base = root ?? url
            return relative(base.standardizedFileURL.path, item.standardizedFileURL.path)
                ?? relative(base.resolvingSymlinksInPath().path, item.resolvingSymlinksInPath().path)
        }
    }

    private struct StoredReference: Codable {
        let virtualPathComponent: String?
        let bookmarkData: Data
        let isDirectory: Bool
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

    static func supportsSidecarWriting(sourceID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: referencesKey(for: sourceID)) else { return true }
        return (try? JSONDecoder().decode([StoredReference].self, from: data))?.allSatisfy(\.isDirectory) == true
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
                    isDirectory: original.isDirectory
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
                guard let result = resolve(reference.bookmarkData) else { return [] }
                resolved.append(ResolvedReference(
                    virtualPathComponent: reference.virtualPathComponent,
                    url: result.url,
                    isDirectory: reference.isDirectory
                ))
                if refreshStaleBookmarks, result.isStale, let bookmark = try? makeBookmark(for: result.url) {
                    refreshed[index] = StoredReference(
                        virtualPathComponent: reference.virtualPathComponent,
                        bookmarkData: bookmark,
                        isDirectory: reference.isDirectory
                    )
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
    case item(String)
    case removed(String)
    case directory(String)
    case directoryHint(String)
    case verify(songID: String)

    static func parent(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).deletingLastPathComponent
    }
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
        #endif

        activate()
    }

    private func activate() {
        guard !isPresenting else { return }
        isPresenting = true
        reconcilePresenters()
        if let song = currentSong() { verifyWhenVisible(song) }
    }

    private func deactivate() {
        guard isPresenting else { return }
        isPresenting = false
        presenterRevision &+= 1
        for task in refreshTasks.values {
            task.cancel()
        }
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
                        Task { @MainActor in self?.enqueue(change, sourceID: sourceID) }
                    }
                    presentersBySourceID[sourceID] = references.map { reference in
                        let presenter = LocalReferenceFilePresenter(reference: reference, onChange: changed)
                        NSFileCoordinator.addFilePresenter(presenter)
                        return presenter
                    }
                    #if os(macOS)
                    eventStreams[sourceID] = MacLocalReferenceEvents(references: references) { [weak self] changes in
                        Task { @MainActor in self?.enqueue(changes, sourceID: sourceID) }
                    }
                    #endif
                    schedulePending(sourceID)
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
    }

    func verifyWhenVisible(_ song: Song) {
        guard !song.isCueTrack, !song.isDiscImageTrack, !song.isStreamDescriptor else { return }
        enqueue(.verify(songID: song.id), sourceID: song.sourceID)
    }

    private func enqueue(_ change: LocalReferenceChange, sourceID: String) {
        enqueue([change], sourceID: sourceID)
    }

    private func enqueue(_ changes: Set<LocalReferenceChange>, sourceID: String) {
        guard isPresenting, pendingPresenterSourceIDs.contains(sourceID) else { return }
        pendingChanges[sourceID, default: []].formUnion(changes)
        schedulePending(sourceID)
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
                processingChanges[sourceID] = changes
                await refresh(changes, source: source)
                if !Task.isCancelled { processingChanges[sourceID] = nil }
            }
            if !Task.isCancelled { refreshTasks[sourceID] = nil }
        }
    }

    private func refresh(_ changes: Set<LocalReferenceChange>, source: MusicSource) async {
        guard let local = sourceManager.connector(for: source) as? LocalFileSource else { return }
        var files: [String: Bool] = [:] // song ID → a file notification requires reading even if attributes match
        var directories: Set<String> = []
        var hints: Set<String> = []
        var exactPaths: Set<String> = []
        let index = scanService.libraryFolderSyncIndex(for: source.id)
        for change in changes {
            switch change {
            case .verify(let id): if files[id] == nil { files[id] = false }
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
                let ids = entry?.songIDs ?? [LocalFileSource.generateID(sourceID: source.id, path: path)]
                // A rename into a known destination can be an editor's atomic save.
                if ids.count == 1, let id = ids.first, let song = library.storedSong(id: id),
                   song.sourceID == source.id, song.filePath == path,
                   !song.isCueTrack, !song.isDiscImageTrack, !song.isStreamDescriptor {
                    if case .removed = change, (try? await local.localURL(for: path)) == nil {
                        directories.insert(LocalReferenceChange.parent(of: path))
                        continue
                    }
                    files[id] = true
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
            if songs.count == 1 { library.replaceSong(songs[0]) } else { library.replaceSongs(songs) }
            NotificationCenter.default.post(name: .primuseSongContentChanged, object: nil, userInfo: ["songs": songs])
        }
        for (offset, file) in files.enumerated() {
            let (id, notified) = file
            guard canContinue(source.id), !scanService.hasActiveScans, !offset.isMultiple(of: 16) || fileWorkAllowed() else {
                if !Task.isCancelled { pendingChanges[source.id, default: []].formUnion(changes) }
                return
            }
            guard let previous = library.storedSong(id: id), previous.sourceID == source.id,
                  let updated = try? await local.refreshedLocalSong(previous, notified: notified),
                  !Task.isCancelled else { continue }
            updates.append((previous, updated))
            if updates.count == 32, canContinue(source.id), !scanService.hasActiveScans { publishUpdates() }
        }
        guard canContinue(source.id), !scanService.hasActiveScans else {
            if !Task.isCancelled { pendingChanges[source.id, default: []].formUnion(changes) }
            return
        }
        publishUpdates()
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
        currentURL = newURL
        urlLock.unlock()
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
/// One file-events stream covers the selected trees, including nested albums.
final class MacLocalReferenceEvents {
    private final class Handler {
        let references: [LocalBookmarkStore.ResolvedReference]
        let directories: [LocalBookmarkStore.ResolvedReference]
        var filesByPath: [String: [LocalBookmarkStore.ResolvedReference]] = [:]
        let send: @Sendable (Set<LocalReferenceChange>) -> Void

        init(_ references: [LocalBookmarkStore.ResolvedReference], send: @escaping @Sendable (Set<LocalReferenceChange>) -> Void) {
            self.references = references
            directories = references.filter(\.isDirectory)
            self.send = send
            for file in references where !file.isDirectory {
                for key in Set([file.url.standardizedFileURL.path, file.url.resolvingSymlinksInPath().path]) {
                    filesByPath[key, default: []].append(file)
                }
            }
        }

        func collect(path: String, flags: FSEventStreamEventFlags, into changes: inout Set<LocalReferenceChange>) {
            if flags & UInt32(kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped) != 0 {
                for reference in references {
                    guard let root = reference.sourcePath(for: reference.url) else { continue }
                    changes.insert(reference.isDirectory ? .directory(root) : .item(root))
                }
                return
            }
            let url = URL(fileURLWithPath: path, isDirectory: flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0)
            for reference in directories + (filesByPath[path] ?? []) {
                guard let relative = reference.sourcePath(for: url) else { continue }
                if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                    changes.insert(reference.isDirectory ? .directory(relative) : .item(relative))
                } else if flags & UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0 {
                    if !url.lastPathComponent.hasPrefix(".") {
                        changes.insert(url.hasDirectoryPath ? .directory(LocalReferenceChange.parent(of: relative)) : .removed(relative))
                    }
                } else if flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified
                    | kFSEventStreamEventFlagItemInodeMetaMod) != 0, !url.lastPathComponent.hasPrefix(".") {
                    changes.insert(url.hasDirectoryPath ? .directoryHint(relative) : .item(relative))
                }
            }
        }
    }

    private let stream: FSEventStreamRef

    init?(references: [LocalBookmarkStore.ResolvedReference], onChange: @escaping @Sendable (Set<LocalReferenceChange>) -> Void) {
        let handler = Handler(references, send: onChange)
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
