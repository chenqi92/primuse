import UniformTypeIdentifiers

nonisolated func plog(_ message: String) { SmokeLog.shared.append(message); print(message) }
enum FileLogger { static let isDiagnosticModeActive = true }

private final class SmokeLog: @unchecked Sendable {
    static let shared = SmokeLog()
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func snapshot() -> [String] { lock.withLock { lines } }
}

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
    var visibleSongs = [Song(id: "one", title: "Green spotlight smoke"), Song(id: "emoji", title: "🎵")]
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
/// 「在 Primuse 中搜索」意图打开搜索页的路由;探针只编译它,不会走到。
@MainActor
final class SystemActivityRouter {
    static let shared = SystemActivityRouter()
    func showSearch(_ query: String, route: String) {}
}
typealias MacSystemActivityRouter = SystemActivityRouter
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

private actor QueryVisibilityFixture {
    private var replies: [[String: String]?]
    private(set) var reads = 0
    init(_ replies: [[String: String]?]) { self.replies = replies }
    func next() -> [String: String]? {
        reads += 1
        return replies.isEmpty ? nil : replies.removeFirst()
    }
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
            let query = CSSearchQuery(queryString: "contentType == \"public.audio\" || contentType == \"public.text\"", queryContext: context)
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

        if let filter = ProcessInfo.processInfo.environment["SPOTLIGHT_SMOKE_FILTER"] {
            if filter == "search-diagnostics" {
                try await searchDiagnosticsCoverShortTitles(library: library, service: service)
            } else if filter == "system-reindex" {
                let complete = await performSynchronization(snapshot: service.makeLibrarySnapshot(library: library),
                    manifestURL: service.manifestURL, thumbnailDirectoryURL: service.thumbnailDirectoryURL,
                    status: SpotlightIndexStatus())
                try require(complete, "System recovery fixture did not index")
                try await systemReindexRequests(library: library, service: service)
            } else {
                throw SmokeFailure(description: "Unknown smoke filter: \(filter)")
            }
            return
        }

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
            thumbnailDirectoryURL: service.thumbnailDirectoryURL,
            status: SpotlightIndexStatus()
        )
        try require(succeeded, "Full rebuild failed")
        var expected = ["control": "Unrelated control", "song:one": "Green spotlight smoke", "song:emoji": "🎵",
                        "album:one": "Smoke album", "artist:one": "Smoke artist", "playlist:one": "Smoke playlist"]
        try await expectRows(expected, label: "full rebuild preserves all four content kinds and removes only stale library items")
        try require(await indexedSignatures()?["song:emoji"] != nil, "Enumeration omitted an emoji-only title")
        print("PASS: production enumeration includes emoji-only titles")

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

        try await artworkChangesPreserveCoverage(library: library, service: migrated)
        try await committedWritesNeedVerification(library: library, service: migrated)
        try await staleRewriteHintsDoNotRepeatWrites(library: library, service: migrated)
        try await staleAndEmptyIndexRepair(library: library, service: migrated)
        try await systemReindexRequests(library: library, service: migrated)
        try await deletionNeedsVerification(library: library, service: migrated)

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
        try await searchDiagnosticsCoverShortTitles(library: library, service: migrated)
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
                thumbnailDirectoryURL: thumbnailDirectoryURL,
                status: SpotlightIndexStatus()
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
            thumbnailDirectoryURL: thumbnailDirectoryURL,
            status: SpotlightIndexStatus()
        )
        try require(finished, "Resumed synchronization failed")
        var expected = ["control": "Unrelated control"]
        for song in library.visibleSongs { expected["song:\(song.id)"] = song.title }
        try await expectRows(expected, label: "resumed rebuild completes the library without starting over")

        try await missingItemsAreRewritten(library: library, service: service, expected: expected)
    }

    /// #346: the manifest said every song was in, yet some could not be found.
    /// Items the system index lost behind the manifest's back must show up as
    /// not indexed when the settings page measures, and be written again.
    private static func missingItemsAreRewritten(
        library: MusicLibrary,
        service: SpotlightIndexService,
        expected: [String: String]
    ) async throws {
        let lost = ["song:bulk-0003", "song:bulk-0500"]
        try await CSSearchableIndex(name: kSpotlightIndexName).deleteSearchableItems(withIdentifiers: lost)
        var trimmed = expected
        for identifier in lost { trimmed.removeValue(forKey: identifier) }
        try await expectRows(trimmed, label: "fixture drops two items from the system index only")

        service.refreshStatus(library: library)
        for _ in 0..<100 where service.status.activity != .idle {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(service.status.coverage?.remaining == lost.count,
                    "Status reports \(String(describing: service.status.coverage)) after losing \(lost.count) items")
        try require(service.identifiersMissingFromIndex == Set(lost), "Lost items were not queued for rewriting")
        print("PASS: settings measurement finds items missing from the system index")

        service.synchronizeIfNeeded(library: library, delay: .seconds(30))
        service.synchronizeIfNeeded(library: library, delay: .seconds(30))
        service.cancelPendingSynchronization()
        try require(service.identifiersMissingFromIndex == Set(lost), "Cancelling debounced work lost the rewrite queue")
        print("PASS: replacement and cancellation during debounce preserve missing identifiers")

        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        try await expectRows(expected, label: "next synchronization writes the lost items again")
        service.refreshStatus(library: library)
        for _ in 0..<100 where service.status.activity != .idle {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(service.status.coverage?.isComplete == true, "Coverage not complete after rewriting")
        try require(service.identifiersMissingFromIndex.isEmpty, "Rewritten items still queued")
    }

    private static func artworkChangesPreserveCoverage(library: MusicLibrary, service: SpotlightIndexService) async throws {
        service.refreshStatus(library: library)
        for _ in 0..<100 where service.status.activity != .idle {
            try await Task.sleep(for: .milliseconds(50))
        }
        let artwork = MetadataAssetStore.shared.artworkDirectoryURL.appendingPathComponent("one.jpg")
        try Data([1]).write(to: artwork)
        defer { try? FileManager.default.removeItem(at: artwork) }
        library.visibleSongs[0].coverArtFileName = "one.jpg"
        service.suspendSynchronization()
        service.artworkPreferenceChanged(library: library)
        for _ in 0..<100 where service.status.activity != .idle {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(service.status.coverage?.remaining == 0, "Cover change was counted as missing from search")
        try require(service.status.coverage?.awaitingUpdate == 1, "Cover update was not reported immediately")
        try require(service.status.coverage?.isComplete == false, "Cover change retained stale completion status")
        library.visibleSongs[0].coverArtFileName = nil
        try FileManager.default.removeItem(at: artwork)
        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        print("PASS: cover change refreshes status immediately and keeps existing search coverage")
    }

    private static func staleAndEmptyIndexRepair(library: MusicLibrary, service: SpotlightIndexService) async throws {
        let index = CSSearchableIndex(name: kSpotlightIndexName)
        let baseline = loadManifest(from: service.manifestURL)!
        let stale = CSSearchableItemAttributeSet(contentType: .audio)
        stale.title = "Outdated fixture title"
        stale.setValue("old-version" as NSString, forCustomKey: spotlightContentVersionKey())
        try await index.indexSearchableItems([CSSearchableItem(uniqueIdentifier: "song:one", domainIdentifier: kSongDomain, attributeSet: stale)])
        for _ in 0..<30 {
            if await indexedSignatures()?["song:one"] == "old-version" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(try await indexedRows()["song:one"] == "Outdated fixture title", "Stale fixture not visible")
        service.refreshStatus(library: library)
        for _ in 0..<100 where service.status.activity != .idle { try await Task.sleep(for: .milliseconds(50)) }
        try require(service.status.coverage?.awaitingUpdate == 1 && service.status.coverage?.isComplete == false,
                    "Stale content with the same identifier was marked current")
        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        try require(try await indexedRows()["song:one"] == library.visibleSongs[0].title, "Manual build left stale content")
        print("PASS: actual stored version detects and repairs stale content with an unchanged ID")

        // An older app's item has no version attribute. It is present but needs one upgrade write.
        stale.title = "Legacy fixture title"
        stale.setValue(nil, forCustomKey: spotlightContentVersionKey())
        try await index.indexSearchableItems([CSSearchableItem(uniqueIdentifier: "song:one", domainIdentifier: kSongDomain, attributeSet: stale)])
        for _ in 0..<30 {
            if await indexedSignatures()?["song:one"] == "" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(await indexedSignatures()?["song:one"] == "", "Legacy item not found without its marker")
        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        try require(await indexedSignatures()?["song:one"] == baseline.signaturesByIdentifier["song:one"], "Legacy item not upgraded")
        print("PASS: legacy records without a version marker receive an incremental upgrade")

        try await index.deleteSearchableItems(withIdentifiers: Array(baseline.signaturesByIdentifier.keys))
        for _ in 0..<30 {
            if await indexedSignatures()?.isEmpty == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(await indexedSignatures()?.isEmpty == true, "Empty-index injection failed")
        let client = await fetchClientState(from: index)
        try require(client.data == clientState(for: baseline), "Deletion unexpectedly changed client state")
        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        try require(await indexedSignatures() == baseline.signaturesByIdentifier && service.status.coverage?.isComplete == true,
                    "Manual build failed to recover a fully empty index")
        print("PASS: a fully empty index repairs itself even when its client state matches the manifest")
    }

    private static func systemReindexRequests(library: MusicLibrary, service: SpotlightIndexService) async throws {
        service.suspendSynchronization()
        let connection = service.indexConnection!
        var acknowledged = false
        connection.delegate.searchableIndex(connection.index, reindexSearchableItemsWithIdentifiers: ["song:one", "song:removed"]) {
            acknowledged = service.recoveryJournal.request?.identifiers == ["song:one", "song:removed"]
        }
        try require(acknowledged, "System request was acknowledged before it was persisted")
        let relaunched = SpotlightIndexService()
        try require(relaunched.needsSynchronization && relaunched.recoveryJournal.request != nil, "Restart lost the system request")
        let removed = CSSearchableItemAttributeSet(contentType: .audio)
        removed.title = "Removed fixture"
        try await connection.index.indexSearchableItems([CSSearchableItem(uniqueIdentifier: "song:removed", domainIdentifier: kSongDomain, attributeSet: removed)])
        // Let the callback reach the main actor before starting the manual run.
        await Task.yield()
        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        try require(service.recoveryJournal.request == nil, "Completed recovery was not cleared")
        try require(await indexedSignatures()?["song:removed"] == nil, "Requested deleted item survived recovery")
        connection.delegate.searchableIndex(connection.index, reindexAllSearchableItemsWithAcknowledgementHandler: {})
        await Task.yield()
        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        try require(service.recoveryJournal.request == nil && service.status.coverage?.isComplete == true, "Full system recovery did not complete")
        print("PASS: system requests persist before acknowledgment, survive relaunch, and repair or delete requested items")
    }

    private static func deletionNeedsVerification(library: MusicLibrary, service: SpotlightIndexService) async throws {
        let recovery = try service.recoveryJournal.record(identifiers: ["song:removed"])
        var actual = await indexedSignatures()!
        actual["song:removed"] = "stale"
        let delayed = actual
        let deletionStatus = SpotlightIndexStatus()
        let succeeded = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library), manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL, status: deletionStatus,
            recovery: recovery, querySignatures: { delayed })
        try require(!succeeded && deletionStatus.coverage?.isComplete == false, "An acknowledged deletion was treated as query-confirmed")
        let saved = loadManifest(from: service.manifestURL)!
        try require(saved.signaturesByIdentifier["song:removed"] == "", "Unverified deletion was not retained for retry")
        let unavailable = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library), manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL, status: deletionStatus,
            querySignatures: { nil })
        try require(!unavailable && loadManifest(from: service.manifestURL)?.signaturesByIdentifier["song:removed"] == "",
                    "A query failure lost the unconfirmed deletion")
        service.synchronizeNow(library: library)
        try await service.waitForCompletion()
        try require(service.recoveryJournal.request == nil, "Retried deletion left recovery pending")
        print("PASS: deletions also wait for query visibility and survive interruption in the manifest")
    }

    private static func searchDiagnosticsCoverShortTitles(library: MusicLibrary, service: SpotlightIndexService) async throws {
        library.visibleSongs.append(Song(id: "aaa-diagnostic-control", title: "晴天"))
        library.visibleSongs.append(Song(id: "diagnostic-short", title: "绿光"))
        library.visibleSongs.append(Song(id: "diagnostic-long", title: "待你归来"))
        library.visibleSongs.append(Song(id: "diagnostic-stale", title: "旧的标题"))
        library.recentPlaybackSongIDsForSync = ["diagnostic-short", "diagnostic-short", "absent"]
        let selected = searchDiagnosticSamples(songs: library.visibleSongs, prioritySongIDs: library.recentPlaybackSongIDsForSync)
        try require(selected.first?.identifier == "song:diagnostic-short", "The recently replayed failing song was omitted")
        try require(selected.filter { $0.identifier == "song:diagnostic-short" }.count == 1, "Diagnostic samples were duplicated")
        try require(selected.contains { $0.identifier == "song:aaa-diagnostic-control" }, "Title-group control was lost")
        let snapshot = service.makeLibrarySnapshot(library: library)
        let complete = await performSynchronization(snapshot: snapshot, manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL, status: SpotlightIndexStatus())
        try require(complete, "Diagnostic sample indexing failed")
        let context = CSSearchQueryContext()
        context.fetchAttributes = []
        let query = CSSearchQuery(queryString: "title == \"绿光\"cd", queryContext: context)
        let match = await diagnosticMatch(query, identifier: "song:diagnostic-short")
        try require(match.hasPrefix("hit"), "Short Chinese title predicate failed: \(match)")
        let reports = await searchDiagnostics(for: [
            SearchDiagnosticSample(group: "target", identifier: "song:diagnostic-short", title: "绿光"),
            SearchDiagnosticSample(group: "stale", identifier: "song:diagnostic-stale", title: "绿光"),
        ])
        try require(reports.count == 2, "Targeted diagnostics did not complete")
        try require(reports[0].stored.items["song:diagnostic-short"]?.title == "绿光", "Stored title was not read back")
        try require(reports[0].stored.items["song:diagnostic-short"]?.keywords?.contains("绿光") == true, "Stored keywords were not read back")
        try require(reports[0].user.items["song:diagnostic-short"] != nil, "User query did not match the target")
        try require(reports[0].ranked.failure == nil, "Ranked query failed")
        try require(reports[1].stored.items["song:diagnostic-stale"]?.title == "旧的标题", "Stale metadata could not be distinguished from a missing item")
        try require(reports[1].title.count > 0 && reports[1].title.items["song:diagnostic-stale"] == nil,
                    "Another item's title match was mistaken for the requested song")
        let cancelled = await searchDiagnostics(for: selected, shouldContinue: { false })
        try require(cancelled.isEmpty, "Disabled diagnostics still ran queries")
        print("PASS: recent failing songs are sampled, actual fields are read back, and another item's matches cannot mask stale metadata")
        searchDiagnosticGate.resetForTesting()
        await logSearchDiagnostics(snapshot: snapshot, prepared: prepareSnapshot(snapshot)!, found: await indexedSignatures())
        let manifestBefore = try Data(contentsOf: service.manifestURL)
        let rowsBefore = try await indexedRows()
        let greenIndex = library.visibleSongs.firstIndex { $0.id == "diagnostic-short" }!
        library.visibleSongs[greenIndex].title = "绿光改名"
        let logOffset = SmokeLog.shared.snapshot().count
        await service.prepareDiagnosticsForExport(library: library)
        let exported = SmokeLog.shared.snapshot().dropFirst(logOffset)
        try require(exported.contains { $0.contains("search diagnostics finished") && $0.contains("trigger=export") },
                    "Explicit export skipped the probe after a recent status measurement or returned before completion")
        try require(exported.contains { $0.contains("group=priority1") && $0.contains("titleMatches=false") && $0.contains("versionMatches=false") },
                    "Export did not capture newly changed metadata")
        let rowsAfter = try await indexedRows()
        try require(rowsAfter == rowsBefore && (try Data(contentsOf: service.manifestURL)) == manifestBefore,
                    "Diagnostic export changed the index or manifest")
        library.visibleSongs[greenIndex].title = "绿光"
        print("PASS: explicit export captures fresh mismatches despite throttling, awaits completion, and does not repair the index")
        let timeout = await diagnosticMatch(SilentDiagnosticQuery(queryString: "title == \"never\"", queryContext: context), identifier: "none")
        try require(timeout == "timeout", "An unresponsive diagnostic query did not time out")
        print("PASS: short Chinese title matching is checked separately, and diagnostic queries have a bounded timeout")
    }

    private static func staleRewriteHintsDoNotRepeatWrites(library: MusicLibrary, service: SpotlightIndexService) async throws {
        let found = await indexedSignatures()!
        let queries = QueryVisibilityFixture([found, found])
        let succeeded = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library), manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL, status: SpotlightIndexStatus(),
            missingFromIndex: Set(found.keys), querySignatures: { await queries.next() })
        let reads = await queries.reads
        try require(succeeded && reads == 1, "Stale rewrite hints repeated acknowledged writes despite current query versions (query reads=\(reads))")
        let confirmed = loadManifest(from: service.manifestURL)!
        let interrupted = SpotlightIndexVerification.manifest(confirmed, markingUnconfirmed: Set(found.keys))
        try saveManifest(interrupted, to: service.manifestURL)
        try await applyBatch(to: CSSearchableIndex(name: kSpotlightIndexName), deletingIdentifiers: [],
            searchableItems: [], clientState: clientState(for: interrupted))
        let recovered = await performSynchronization(snapshot: service.makeLibrarySnapshot(library: library),
            manifestURL: service.manifestURL, thumbnailDirectoryURL: service.thumbnailDirectoryURL, status: SpotlightIndexStatus())
        try require(recovered && loadManifest(from: service.manifestURL) == confirmed, "Query-confirmed progress did not repair the durable checkpoint")
        print("PASS: current query versions discard obsolete rewrite hints and recover interrupted checkpoints without rewriting items")
    }

    private static func committedWritesNeedVerification(library: MusicLibrary, service: SpotlightIndexService) async throws {
        let realFound = await indexedSignatures()!
        let withheld = realFound.filter { $0.key != "song:emoji" }
        let status = SpotlightIndexStatus()
        let result = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library),
            manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL,
            status: status,
            querySignatures: { withheld }
        )
        try require(!result, "Batch acknowledgment was mistaken for query visibility")
        try require(status.coverage?.remaining == 1 && status.coverage?.isComplete == false, "Missing query result was shown as complete")
        let checkpoint = loadManifest(from: service.manifestURL)!
        try require(checkpoint.signaturesByIdentifier["song:emoji"] == "", "Unverified write was not persisted for retry")
        let client = await fetchClientState(from: CSSearchableIndex(name: kSpotlightIndexName))
        try require(client.data == clientState(for: checkpoint), "Verification checkpoint and client state differ")
        let repaired = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library),
            manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL,
            status: status
        )
        try require(repaired && status.coverage?.isComplete == true, "Persisted retry did not converge after query visibility recovered")
        let unavailable = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library),
            manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL,
            status: status,
            querySignatures: { nil }
        )
        try require(!unavailable && status.coverage?.isVerified == false && status.coverage?.isComplete == false,
                    "Unavailable query was shown as confirmed")
        let delayed = QueryVisibilityFixture([withheld, withheld, realFound])
        let converged = await performSynchronization(
            snapshot: service.makeLibrarySnapshot(library: library),
            manifestURL: service.manifestURL,
            thumbnailDirectoryURL: service.thumbnailDirectoryURL,
            status: status,
            missingFromIndex: ["song:emoji"],
            querySignatures: { await delayed.next() }
        )
        let queryCount = await delayed.reads
        try require(converged && status.coverage?.isComplete == true && queryCount == 3,
                    "Delayed visibility did not converge through verification retries")
        print("PASS: committed writes await query visibility, persist missing items, and recover without rebuilding")
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

private final class SilentDiagnosticQuery: CSSearchQuery, @unchecked Sendable {
    override func start() {}
    override func cancel() {}
}

extension SpotlightSearchDiagnosticGate {
    func resetForTesting() { lock.withLock { lastStart = .distantPast } }
}
