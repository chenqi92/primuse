#if os(iOS) || os(macOS)
import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
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
    func resolve(_ sourceIDs: Set<String>) -> [String: [LocalBookmarkStore.ResolvedReference]] {
        var result: [String: [LocalBookmarkStore.ResolvedReference]] = [:]
        for sourceID in sourceIDs.sorted() {
            if let references = LocalBookmarkStore.resolveReferences(sourceID: sourceID, refreshStaleBookmarks: false),
               !references.isEmpty {
                result[sourceID] = references
            }
        }
        return result
    }
}

/// Keeps user-selected local references synchronized while the application is
/// running. File presenter callbacks cover coordinated changes made by Files,
/// Finder and File Provider extensions; a foreground reconciliation covers the
/// interval where iOS requires presenters to be unregistered in the background.
@MainActor
final class LocalReferenceRefreshService {
    private let sourcesStore: SourcesStore
    private let sourceManager: SourceManager
    private let library: MusicLibrary
    private let scanService: ScanService
    private let scraperService: MusicScraperService

    private var presentersBySourceID: [String: [LocalReferenceFilePresenter]] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    private let resolutionWorker = LocalReferenceResolutionWorker()
    private var presenterReconciliationTask: Task<Void, Never>?
    private var presenterRevision: UInt64 = 0
    private var pendingPresenterSourceIDs: Set<String> = []
    private var needsForegroundReconciliation = false
    private var isPresenting = false
    private var hasStarted = false

    init(
        sourcesStore: SourcesStore,
        sourceManager: SourceManager,
        library: MusicLibrary,
        scanService: ScanService,
        scraperService: MusicScraperService
    ) {
        self.sourcesStore = sourcesStore
        self.sourceManager = sourceManager
        self.library = library
        self.scanService = scanService
        self.scraperService = scraperService
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
                self?.activate(reconcileAfterInactiveInterval: true)
            }
        })
        guard UIApplication.shared.applicationState != .background else { return }
        #endif

        activate(reconcileAfterInactiveInterval: true)
    }

    private func activate(reconcileAfterInactiveInterval: Bool) {
        guard !isPresenting else {
            if reconcileAfterInactiveInterval {
                scheduleForegroundReconciliation()
            }
            return
        }
        isPresenting = true
        needsForegroundReconciliation = reconcileAfterInactiveInterval
        reconcilePresenters()
    }

    private func deactivate() {
        guard isPresenting else { return }
        isPresenting = false
        presenterRevision &+= 1
        for task in refreshTasks.values {
            task.cancel()
        }
        refreshTasks.removeAll()
        unregisterAllPresenters()
    }

    private func reconcilePresenters() {
        guard isPresenting else { return }

        let monitoredSourceIDs = LocalReferenceRefreshPolicy.monitoredSourceIDs(
            in: sourcesStore.sources,
            bookmarkedSourceIDs: LocalBookmarkStore.storedSourceIDs
        )
        let unmonitoredSourceIDs = refreshTasks.keys.filter {
            !monitoredSourceIDs.contains($0)
        }
        for sourceID in unmonitoredSourceIDs {
            refreshTasks.removeValue(forKey: sourceID)?.cancel()
        }

        presenterRevision &+= 1
        pendingPresenterSourceIDs = monitoredSourceIDs
        for sourceID in Set(presentersBySourceID.keys).subtracting(monitoredSourceIDs) {
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
                let referencesBySource = await resolutionWorker.resolve(pendingPresenterSourceIDs)
                guard isPresenting else { return }
                guard revision == presenterRevision else { continue }
                unregisterAllPresenters()
                for (sourceID, references) in referencesBySource {
                    presentersBySourceID[sourceID] = references.map { reference in
                        let presenter = LocalReferenceFilePresenter(url: reference.url) { [weak self] in
                            Task { @MainActor in self?.scheduleRefresh(sourceID: sourceID) }
                        }
                        NSFileCoordinator.addFilePresenter(presenter)
                        return presenter
                    }
                }
                if needsForegroundReconciliation {
                    needsForegroundReconciliation = false
                    scheduleForegroundReconciliation()
                }
                return
            }
        }
    }

    private func unregisterAllPresenters() {
        for presenter in presentersBySourceID.values.joined() {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presentersBySourceID.removeAll()
    }

    private func scheduleForegroundReconciliation() {
        for sourceID in presentersBySourceID.keys {
            scheduleRefresh(
                sourceID: sourceID,
                delay: LocalReferenceRefreshPolicy.foregroundReconciliationDelay
            )
        }
    }

    private func scheduleRefresh(
        sourceID: String,
        delay: TimeInterval = LocalReferenceRefreshPolicy.changeDebounce
    ) {
        guard isPresenting, presentersBySourceID[sourceID] != nil else { return }
        refreshTasks[sourceID]?.cancel()
        refreshTasks[sourceID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.isPresenting else { return }
            self.refreshTasks[sourceID] = nil
            self.refreshWhenIdle(sourceID: sourceID)
        }
    }

    private func refreshWhenIdle(sourceID: String) {
        guard let source = sourcesStore.source(id: sourceID),
              source.type == .local,
              source.isEnabled,
              !source.isDeleted,
              presentersBySourceID[sourceID] != nil else {
            return
        }
        if scanService.scanStates[sourceID]?.isScanning == true {
            scheduleRefresh(
                sourceID: sourceID,
                delay: LocalReferenceRefreshPolicy.busyRetryDelay
            )
            return
        }

        scanService.scanSource(
            source,
            snapshotExecutionContext: .foregroundResume,
            sourceManager: sourceManager,
            library: library,
            sourceStore: sourcesStore,
            scraperService: scraperService
        )
    }
}

private final class LocalReferenceFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemOperationQueue: OperationQueue

    private let onChange: @Sendable () -> Void
    private let urlLock = NSLock()
    private var currentURL: URL
    private let securityScopedURL: URL
    private let usesSecurityScope: Bool

    var presentedItemURL: URL? {
        urlLock.lock()
        defer { urlLock.unlock() }
        return currentURL
    }

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
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
        onChange()
    }

    func presentedItemDidMove(to newURL: URL) {
        urlLock.lock()
        currentURL = newURL
        urlLock.unlock()
        onChange()
    }

    func accommodatePresentedItemDeletion(
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        onChange()
        completionHandler(nil)
    }

    func presentedSubitemDidAppear(at url: URL) {
        onChange()
    }

    func presentedSubitemDidChange(at url: URL) {
        onChange()
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        onChange()
    }

    func accommodatePresentedSubitemDeletion(
        at url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        onChange()
        completionHandler(nil)
    }
}
#endif
