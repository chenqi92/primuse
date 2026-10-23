import UniformTypeIdentifiers

// Library and artwork dependencies are fixtures; the service, planner and
// Core Spotlight writes/queries are production code and the real framework.
struct Song: Sendable {
    let id: String
    var title: String
    var albumTitle: String? = "Smoke album"
    var coverArtFileName: String?
    var dateAdded = Date()
    func displayArtistName(configuration: ArtistNameConfiguration) -> String? { "Smoke artist" }
}
struct Album: Sendable { let id: String; let title: String; var artistName: String? }
struct Artist: Sendable { let id: String; let name: String }
struct Playlist: Sendable { let id: String; let name: String }
struct ArtistNameConfiguration: Sendable { let cacheSignature = "smoke" }

@MainActor
final class MusicLibrary {
    static let likedSongsPlaylistID = "liked"
    var isReady = true
    var visibleSongs = [Song(id: "one", title: "Green spotlight smoke")]
    var visibleAlbums = [Album(id: "one", title: "Smoke album")]
    var visibleArtists = [Artist(id: "one", name: "Smoke artist")]
    var playlists = [Playlist(id: "one", name: "Smoke playlist")]
    var recentPlaybackSongIDsForSync: [String] = []
    let artistNameConfiguration = ArtistNameConfiguration()
    func songCount(forPlaylist id: String) -> Int { 1 }
    func songIDs(forPlaylist id: String) -> [String] { ["one"] }
    func onReady(_ work: @escaping @MainActor () -> Void) { work() }
}

enum MetadataAssetStore {
    static let shared = MetadataAssetStoreFixture()
}
struct MetadataAssetStoreFixture: Sendable {
    func coverContentIdentifier(named: String) -> String? { nil }
    func readCoverData(named: String) -> Data? { nil }
}
enum ArtworkImageCompatibility {
    static func hasRedundantJPEGSampling(_ data: Data) -> Bool { false }
}
enum SmokeStorage {
    static let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixture")
    static let defaultsName = "org.primuse.tests.spotlight-index-smoke.state"
    static let controlDomain = "org.primuse.tests.spotlight-index-smoke.control"
}
extension FileManager {
    func primuseDirectoryURL(for directory: SearchPathDirectory) -> URL { SmokeStorage.root }
}
enum LibraryMaintenanceDefaults {
    nonisolated(unsafe) static let store = UserDefaults(suiteName: SmokeStorage.defaultsName)!
    static func migrating(_ keys: [String]) -> UserDefaults { store }
}
@MainActor
final class AppServices {
    static let shared = AppServices()
    var spotlightIndex = SpotlightIndexService()
}
@MainActor
final class SmokeScanService {
    var backgroundPlaybackActive = true
    func setBackgroundPlaybackActive(_ value: Bool) { backgroundPlaybackActive = value }
}
@MainActor
func playbackPaused(musicLibrary: MusicLibrary, scanService: SmokeScanService) {
    /* PRODUCTION_PLAYBACK_PAUSE */
}

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
}
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw SmokeFailure(description: message) }
}

private final class QueryRows: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: String] = [:]
    func append(_ items: [CSSearchableItem]) {
        lock.lock()
        defer { lock.unlock() }
        for item in items { rows[item.uniqueIdentifier] = item.attributeSet.title ?? "" }
    }
    func result() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }
}

extension SpotlightIndexService {
    private static func indexedRows() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            let context = CSSearchQueryContext()
            context.fetchAttributes = ["title"]
            let query = CSSearchQuery(queryString: "title == \"*\"", queryContext: context)
            let rows = QueryRows()
            query.foundItemsHandler = { rows.append($0) }
            query.completionHandler = { error in
                _ = query
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: rows.result()) }
            }
            query.start()
        }
    }

    private static func expectRows(_ expected: [String: String], label: String) async throws {
        var actual: [String: String] = [:]
        for _ in 0..<30 {
            actual = try await indexedRows()
            if actual == expected {
                print("PASS: \(label)")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SmokeFailure(description: "\(label): expected \(expected), got \(actual)")
    }

    private func waitForCompletion() async throws {
        for _ in 0..<150 {
            if workPhase == .idle && !Self.isSynchronizationPending { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SmokeFailure(description: "Pending synchronization did not finish")
    }

    static func runRegression() async throws {
        try require(Bundle.main.bundleIdentifier == "org.primuse.tests.spotlight-index-smoke", "Unexpected probe bundle")
        try require(CSSearchableIndex.isIndexingAvailable(), "Core Spotlight unavailable")
        defaults.removePersistentDomain(forName: SmokeStorage.defaultsName)
        try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: kSpotlightDomains + [SmokeStorage.controlDomain])
        let library = MusicLibrary()
        let service = SpotlightIndexService()
        AppServices.shared.spotlightIndex = service
        defer { service.suspendSynchronization() }
        try FileManager.default.createDirectory(at: service.manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Unrelated control"
        let control = CSSearchableItem(uniqueIdentifier: "control", domainIdentifier: SmokeStorage.controlDomain, attributeSet: attributes)
        let staleAttributes = CSSearchableItemAttributeSet(contentType: .audio)
        staleAttributes.title = "Stale library song"
        let stale = CSSearchableItem(uniqueIdentifier: "song:stale", domainIdentifier: kSongDomain, attributeSet: staleAttributes)
        try await CSSearchableIndex.default().indexSearchableItems([control, stale])
        try await expectRows(["control": "Unrelated control", "song:stale": "Stale library song"], label: "legacy fixture and unrelated control are searchable before rebuilding")
        // A v0 manifest forces the same recovery path even when validating an
        // older service source that has not yet received the migration fix.
        try saveManifest(SpotlightIndexManifest(schemaVersion: 0, signaturesByIdentifier: [:]), to: service.manifestURL)
        let succeeded = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library),
            manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL
        )
        try require(succeeded, "Full rebuild failed")
        var expected = ["control": "Unrelated control", "song:one": "Green spotlight smoke",
                        "album:one": "Smoke album", "artist:one": "Smoke artist", "playlist:one": "Smoke playlist"]
        try await expectRows(expected, label: "full rebuild preserves all four content kinds and removes only stale library items")

        // Recreate a clean v1 manifest whose system items were already erased.
        let prepared = prepareSnapshot(service.makeLibrarySnapshot(library: library))!
        let legacy = SpotlightIndexManifest(schemaVersion: 1,
            signaturesByIdentifier: Dictionary(uniqueKeysWithValues: prepared.records.map { ($0.identifier, $0.signature) }))
        try saveManifest(legacy, to: service.manifestURL)
        let index = CSSearchableIndex(name: kSpotlightIndexName)
        try await deleteDomains(kSpotlightDomains, from: index)
        try await applyBatch(to: index, deletingIdentifiers: [], searchableItems: [], clientState: clientState(for: legacy))
        defaults.set(false, forKey: synchronizationPendingKey)
        defaults.set(7, forKey: synchronizationGenerationKey)
        defaults.set(7, forKey: completedSynchronizationGenerationKey)
        defaults.removeObject(forKey: "primuse.spotlightIndex.completedSchemaVersion")
        let migrated = SpotlightIndexService()
        AppServices.shared.spotlightIndex = migrated
        defer { migrated.suspendSynchronization() }
        try require(migrated.needsSynchronization, "Legacy clean flag suppressed recovery")
        migrated.resumePendingSynchronization(library: library)
        try await migrated.waitForCompletion()
        try await expectRows(expected, label: "previously clean but empty v1 index repairs itself")
        try require(loadManifest(from: migrated.manifestURL)?.schemaVersion == 2, "Recovery schema not persisted")
        let relaunched = SpotlightIndexService()
        relaunched.synchronizeIfNeeded(library: library)
        try require(relaunched.workPhase == .idle, "Clean recovered index rebuilt again on launch")
        print("PASS: recovered index stays clean across launches")

        library.visibleSongs[0].title = "Updated spotlight smoke"
        library.visibleAlbums = []
        expected["song:one"] = "Updated spotlight smoke"
        expected.removeValue(forKey: "album:one")
        persistLibraryChangePending()
        migrated.resumePendingSynchronization(library: library)
        migrated.suspendSynchronization()
        try require(isSynchronizationPending, "Cancellation lost pending changes")
        let scanService = SmokeScanService()
        playbackPaused(musicLibrary: library, scanService: scanService)
        try require(!migrated.isSynchronizationSuspended, "Background pause failed to resume Spotlight")
        try require(!scanService.backgroundPlaybackActive, "Background pause failed to clear scan playback state")
        try await migrated.waitForCompletion()
        try await expectRows(expected, label: "background pause resumes cancelled work and applies incremental edits/deletions")
        print("PASS: cancelled work remains pending until a successful commit")
    }
}

@main
struct SpotlightIndexSmoke {
    @MainActor
    static func main() async {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
            print("FAIL: Spotlight probe exceeded its 45-second budget")
            exit(2)
        }
        var failed = false
        do { try await SpotlightIndexService.runRegression() }
        catch { print("FAIL: \(error)"); failed = true }
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: kSpotlightDomains + [SmokeStorage.controlDomain])
            LibraryMaintenanceDefaults.store.removePersistentDomain(forName: SmokeStorage.defaultsName)
            print("PASS: probe index and defaults cleaned")
        } catch {
            print("FAIL: probe cleanup: \(error)")
            failed = true
        }
        exit(failed ? 1 : 0)
    }
}
