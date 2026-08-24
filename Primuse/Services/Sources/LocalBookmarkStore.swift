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

        var errorDescription: String? {
            String(localized: "local_reference_permission_missing")
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
        UserDefaults.standard.set(data, forKey: legacyKey(for: sourceID))
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
        UserDefaults.standard.set(encoded, forKey: referencesKey(for: sourceID))
        UserDefaults.standard.removeObject(forKey: legacyKey(for: sourceID))
    }

    /// `nil` means this source has no bookmark record. An empty array means a
    /// record exists but at least one reference could not be resolved; callers
    /// must fail the whole source rather than scanning a partial root set and
    /// pruning songs that are merely temporarily inaccessible.
    static func resolveReferences(sourceID: String) -> [ResolvedReference]? {
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
                if result.isStale, let bookmark = try? makeBookmark(for: result.url) {
                    refreshed[index] = StoredReference(
                        virtualPathComponent: reference.virtualPathComponent,
                        bookmarkData: bookmark,
                        isDirectory: reference.isDirectory
                    )
                    didRefresh = true
                }
            }
            if didRefresh, let data = try? JSONEncoder().encode(refreshed) {
                UserDefaults.standard.set(data, forKey: referencesKey(for: sourceID))
            }
            return resolved
        }

        guard let data = UserDefaults.standard.data(forKey: legacyKey(for: sourceID)) else {
            return nil
        }
        guard let result = resolve(data) else { return [] }
        if result.isStale, let refreshed = try? makeBookmark(for: result.url) {
            UserDefaults.standard.set(refreshed, forKey: legacyKey(for: sourceID))
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
        UserDefaults.standard.removeObject(forKey: referencesKey(for: sourceID))
        UserDefaults.standard.removeObject(forKey: legacyKey(for: sourceID))
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

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        [.withoutImplicitStartAccessing]
        #endif
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
        reconcilePresenters()
        if reconcileAfterInactiveInterval {
            scheduleForegroundReconciliation()
        }
    }

    private func deactivate() {
        guard isPresenting else { return }
        isPresenting = false
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

        unregisterAllPresenters()
        for sourceID in monitoredSourceIDs.sorted() {
            guard let references = LocalBookmarkStore.resolveReferences(sourceID: sourceID),
                  !references.isEmpty else { continue }
            presentersBySourceID[sourceID] = references.map { reference in
                let presenter = LocalReferenceFilePresenter(url: reference.url) { [weak self] in
                    Task { @MainActor in
                        self?.scheduleRefresh(sourceID: sourceID)
                    }
                }
                NSFileCoordinator.addFilePresenter(presenter)
                return presenter
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
