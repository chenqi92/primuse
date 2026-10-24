import UniformTypeIdentifiers

// Library and artwork dependencies are fixtures; the service, planner and
// Core Spotlight writes/queries are production code and the real framework.
struct Song: Sendable {
    let id: String
    var title: String
    var albumTitle: String? = "Smoke album"
    var coverArtFileName: String?
    var dateAdded = Date()
    var duration: TimeInterval = 0
    func displayArtistName(configuration: ArtistNameConfiguration) -> String? { "Smoke artist" }
}
struct Album: Sendable { let id: String; let title: String; var artistName: String?; var coverArtPath: String? }
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
    var artworkDirectoryURL: URL { SmokeStorage.root.appendingPathComponent("artwork") }
    func coverContentIdentifier(named: String) -> String? {
        guard FileManager.default.fileExists(atPath: artworkDirectoryURL.appendingPathComponent(named).path) else { return nil }
        return "fixture:\(named)"
    }
    func readCoverData(named: String) -> Data? { nil }
    func expectedCoverFileName(for key: String) -> String { "\(key).jpg" }
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
        try coverLookupPreservesLocalFallback()
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
        try require(loadManifest(from: migrated.manifestURL)?.schemaVersion == schemaVersion, "Recovery schema not persisted")
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

        try await interruptedRebuildResumes(library: library, service: migrated)
    }

    private static func coverLookupPreservesLocalFallback() throws {
        let root = MetadataAssetStore.shared.artworkDirectoryURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("album"), withIntermediateDirectories: true)
        let direct = root.appendingPathComponent("album/cover.jpg")
        let mirrored = root.appendingPathComponent("mirrored.jpg")
        try Data([1]).write(to: direct)
        try Data([2]).write(to: mirrored)
        defer {
            try? FileManager.default.removeItem(at: direct)
            try? FileManager.default.removeItem(at: mirrored)
        }
        let names = availableCoverFileNames()
        var identities: [String: String?] = [:]
        let album = coverSource(reference: "album/cover.jpg", songID: nil, availableFileNames: names, identities: &identities)
        let fallback = coverSource(reference: "server/path/cover.jpg", songID: "mirrored", availableFileNames: names, identities: &identities)
        let missing = coverSource(reference: "missing.jpg", songID: "uncached", availableFileNames: names, identities: &identities)
        try require(album?.fileName == "album/cover.jpg", "Nested local album cover was lost")
        try require(fallback?.fileName == "mirrored.jpg", "Server cover did not use the local song mirror")
        try require(missing == nil, "Uncached cover unexpectedly resolved")
        try require(identities["missing.jpg"] == nil && identities["uncached.jpg"] == nil, "Missing files reached the cover reader")
        print("PASS: cover inventory preserves nested artwork and server-song mirrors while skipping missing files")
    }

    /// A 30-second background window used to end a rebuild before its manifest
    /// was saved, so every window wiped the index and wrote the same first few
    /// hundred items again. The interrupted run must leave a checkpoint the
    /// next run continues from, with the recently played song already in.
    private static func interruptedRebuildResumes(
        library: MusicLibrary,
        service: SpotlightIndexService
    ) async throws {
        let total = 1200
        library.visibleSongs = (0..<total).map {
            Song(id: String(format: "bulk-%04d", $0), title: "Bulk smoke \($0)")
        }
        library.visibleAlbums = []
        library.visibleArtists = []
        library.playlists = []
        library.recentPlaybackSongIDsForSync = ["bulk-0007"]
        try saveManifest(SpotlightIndexManifest(schemaVersion: 0, signaturesByIdentifier: [:]), to: service.manifestURL)
        let snapshot = service.makeLibrarySnapshot(library: library)
        let manifestURL = service.manifestURL
        let thumbnailDirectoryURL = service.thumbnailDirectoryURL
        let interrupted = Task.detached {
            await performSynchronization(
                snapshot: snapshot,
                manifestURL: manifestURL,
                thumbnailDirectoryURL: thumbnailDirectoryURL
            )
        }
        var sawFirstBatch = false
        for _ in 0..<200 {
            if try await indexedRows().keys.contains(where: { $0.hasPrefix("song:bulk-") }) {
                sawFirstBatch = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        interrupted.cancel()
        let interruptedResult = await interrupted.value
        try require(sawFirstBatch, "Rebuild never committed a batch")
        try require(!interruptedResult, "Interrupted rebuild reported success")

        guard let checkpoint = loadManifest(from: manifestURL) else {
            throw SmokeFailure(description: "Interrupted rebuild left no checkpoint")
        }
        let confirmed = checkpoint.signaturesByIdentifier.filter {
            $0.value != SpotlightIndexCheckpoint.unconfirmedSignature
        }
        try require(
            !confirmed.isEmpty && confirmed.count < total,
            "Checkpoint kept \(confirmed.count) of \(total) items"
        )
        try require(confirmed["song:bulk-0007"] != nil, "Recently played song was not written first")
        let state = await fetchClientState(from: CSSearchableIndex(name: kSpotlightIndexName))
        try require(state.data == clientState(for: checkpoint), "Checkpoint and client state disagree")
        let resumedPlan = SpotlightIndexPlanner.makePlan(
            currentRecords: prepareSnapshot(snapshot)!.records,
            previousManifest: checkpoint,
            schemaVersion: schemaVersion
        )
        try require(!resumedPlan.requiresFullRebuild, "Resume would wipe the index again")
        try require(
            resumedPlan.identifiersToUpsert.count == total - confirmed.count,
            "Resume plans \(resumedPlan.identifiersToUpsert.count) upserts after \(confirmed.count) were kept"
        )
        print("PASS: interrupted rebuild keeps \(confirmed.count) committed items and the recently played song")

        let finished = await performSynchronization(
            snapshot: snapshot,
            manifestURL: manifestURL,
            thumbnailDirectoryURL: thumbnailDirectoryURL
        )
        try require(finished, "Resumed synchronization failed")
        var expected = ["control": "Unrelated control"]
        for song in library.visibleSongs { expected["song:\(song.id)"] = song.title }
        try await expectRows(expected, label: "resumed rebuild completes the library without starting over")
    }
}

@main
struct SpotlightIndexSmoke {
    @MainActor
    static func main() async {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90) {
            print("FAIL: Spotlight probe exceeded its 90-second budget")
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
