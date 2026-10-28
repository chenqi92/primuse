import AppIntents
import CoreSpotlight
import CryptoKit
import Foundation
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

private nonisolated func spotlightContentVersionKey() -> CSCustomAttributeKey {
    CSCustomAttributeKey(keyName: "com_primuse_content_version", searchable: false,
                         searchableByDefault: false, unique: false, multiValued: false)!
}

private nonisolated func spotlightDiagnostic(_ message: String) {
    plog("[SpotlightIndex] " + message)
}

private nonisolated func spotlightError(_ operation: String, _ error: any Error) {
    let error = error as NSError
    spotlightDiagnostic("\(operation) failed domain=\(error.domain) code=\(error.code)")
}

private final class SpotlightRecoveryDelegate: NSObject, CSSearchableIndexDelegate, @unchecked Sendable {
    private let journal: SpotlightIndexRecoveryJournal
    private let onRequest: @Sendable () -> Void

    nonisolated init(journal: SpotlightIndexRecoveryJournal, onRequest: @escaping @Sendable () -> Void) {
        self.journal = journal
        self.onRequest = onRequest
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        receive(identifiers: nil, acknowledgementHandler: acknowledgementHandler)
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void) {
        receive(identifiers: Set(identifiers), acknowledgementHandler: acknowledgementHandler)
    }

    private nonisolated func receive(identifiers: Set<String>?, acknowledgementHandler: () -> Void) {
        do {
            let request = try journal.record(identifiers: identifiers)
            spotlightDiagnostic("system reindex persisted all=\(request.allItems) ids=\(request.identifiers.count)")
            onRequest()
            acknowledgementHandler()
        } catch {
            spotlightError("persist system reindex", error)
        }
    }
}

// Core Spotlight retains its delegate weakly. Keep both alive between runs.
private final class SpotlightIndexConnection: @unchecked Sendable {
    let index: CSSearchableIndex
    let delegate: SpotlightRecoveryDelegate

    nonisolated init(journal: SpotlightIndexRecoveryJournal, onRequest: @escaping @Sendable () -> Void) {
        index = CSSearchableIndex(name: kSpotlightIndexName)
        delegate = SpotlightRecoveryDelegate(journal: journal, onRequest: onRequest)
        index.indexDelegate = delegate
    }
}

private let kSpotlightIndexName = "com.welape.yuanyin.library.v1"
private let kSongDomain = "com.welape.yuanyin.spotlight.song"
private let kAlbumDomain = "com.welape.yuanyin.spotlight.album"
private let kArtistDomain = "com.welape.yuanyin.spotlight.artist"
private let kPlaylistDomain = "com.welape.yuanyin.spotlight.playlist"
private let kSpotlightDomains = [kSongDomain, kAlbumDomain, kArtistDomain, kPlaylistDomain]

/// Keeps the on-device Spotlight index converged with the visible music
/// library. Ordinary library changes are upserted/deleted incrementally; a
/// complete rebuild is reserved for the first named-index migration, schema
/// changes, and missing/mismatched Core Spotlight client state.
@MainActor
final class SpotlightIndexService {
    private enum WorkPhase {
        case idle
        case debouncing
        case running
    }

    private struct PlaylistSummary: Sendable {
        let id: String
        let name: String
        let songCount: Int
    }

    private struct LibrarySnapshot: Sendable {
        let songs: [Song]
        /// Recently played and liked songs: indexed first, and the ones a
        /// capped index keeps.
        var prioritySongIDs: [String] = []
        let albums: [Album]
        let artists: [Artist]
        let playlists: [PlaylistSummary]
        let artistNameConfiguration: ArtistNameConfiguration
        var showsArtwork = true
    }

    /// A cover in the artwork store that a search result can show.
    private struct CoverSource: Sendable {
        let fileName: String
        let contentIdentifier: String
    }

    private enum IndexPayload: Sendable {
        case song(Song, artistDisplayName: String?, cover: CoverSource?)
        case album(Album, cover: CoverSource?)
        case artist(Artist)
        case playlist(PlaylistSummary)
    }

    /// The first pass attaches only thumbnails already on disk, so every item
    /// becomes searchable at the text-only rate; covers that still have to be
    /// decoded follow in a second pass under the per-batch decode budget.
    private enum ThumbnailPass {
        case cachedOnly
        case generating
    }

    private enum ThumbnailOutcome {
        case none
        case attached
        /// A cover exists but has no thumbnail yet; indexed text-only for now.
        case deferred
        /// Attached after decoding the cover (counts against the budget).
        case generated
    }

    private struct PreparedSnapshot: Sendable {
        let records: [SpotlightIndexRecord]
        let payloadsByIdentifier: [String: IndexPayload]
    }

    private struct ClientStateResult {
        let data: Data?
        let error: (any Error)?
    }

    /// 3: thumbnails travel as data (Spotlight cannot read a file in the app
    /// container), items are written in priority order with checkpoints.
    private nonisolated static let schemaVersion = 3
    private nonisolated static let debounceDuration: Duration = .seconds(3)
    private nonisolated static let followUpDebounceDuration: Duration = .seconds(1)
    private nonisolated static let interBatchDelay: Duration = .milliseconds(180)
    private nonisolated static let maxItemsPerBatch = 100
    /// A very large library is not indexed song by song. Hundreds of thousands
    /// of items keep the system's indexing daemon busy for hours and the phone
    /// warm, for search hits nobody scrolls to; past this many songs the index
    /// holds the recently played and liked ones and then the newest additions.
    /// Albums, artists and playlists are always indexed in full.
    nonisolated static let maxIndexedSongs = 20_000
    private nonisolated static let maxDeletesPerBatch = 250
    private nonisolated static let maxThumbnailCacheMissesPerBatch = 8
    /// How often a long synchronization saves its progress. Each save rewrites
    /// the whole manifest, so not after every batch; an interruption also
    /// saves before stopping.
    private nonisolated static let checkpointInterval: Duration = .seconds(8)
    /// Manifest signature of an item indexed without the thumbnail it should
    /// have: it differs from the real one, so the next run adds the cover.
    private nonisolated static let textOnlySignatureSuffix = "~text"
    /// 「Spotlight 搜索结果显示封面」。用户在设置里翻的开关, 只在翻动时写。
    nonisolated static let showsArtworkKey = "primuse.spotlight.showsArtwork"
    private nonisolated static let synchronizationPendingKey =
        "primuse.spotlightIndex.synchronizationPending.v2"
    private nonisolated static let synchronizationGenerationKey =
        "primuse.spotlightIndex.synchronizationGeneration.v2"
    private nonisolated static let completedSynchronizationGenerationKey =
        "primuse.spotlightIndex.completedSynchronizationGeneration.v2"
    private nonisolated static let completedSchemaVersionKey =
        "primuse.spotlightIndex.completedSchemaVersion"
    /// 每次资料库变动都要写代次, 不能写进 standard, 见 `LibraryMaintenanceDefaults`。
    nonisolated(unsafe) private static let defaults = LibraryMaintenanceDefaults.migrating([
        synchronizationPendingKey,
        synchronizationGenerationKey,
        completedSynchronizationGenerationKey,
        completedSchemaVersionKey,
    ])

    private let manifestURL: URL
    private let thumbnailDirectoryURL: URL
    private let recoveryJournal: SpotlightIndexRecoveryJournal
    private var indexConnection: SpotlightIndexConnection!
    private weak var library: MusicLibrary?
    private var workPhase: WorkPhase = .idle
    /// 设置页上看的收录进度与状态。
    let status = SpotlightIndexStatus()
    /// 设置页里点了「现在建立」:离开那一页时把前台建的这一轮交回后台。
    private var isForegroundSynchronizationRequested = false
    private var isStatusVisible = false
    private var pendingTask: Task<Void, Never>?
    private var pendingGeneration: UUID?
    private var queuedSnapshot: LibrarySnapshot?
    /// 设置页核对时清单记着、系统索引里却查不到的条目,交给下一轮同步当作未确认重写。
    private var identifiersMissingFromIndex: Set<String> = []
    private var needsSynchronization = true
    #if os(iOS)
    /// Keep opportunistic full-library indexing out of the interactive
    /// foreground. The scene lifecycle resumes it in the background.
    private var isSynchronizationSuspended = true
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundAssertionGeneration: UUID?
    #else
    private var isSynchronizationSuspended = false
    #endif

    init(fileManager: FileManager = .default) {
        #if os(tvOS)
        let base = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = base.appendingPathComponent("Primuse/Spotlight", isDirectory: true)
        manifestURL = directory.appendingPathComponent("index-manifest-v1.json")
        thumbnailDirectoryURL = directory.appendingPathComponent("thumbnails-v1", isDirectory: true)
        recoveryJournal = SpotlightIndexRecoveryJournal(url: directory.appendingPathComponent("reindex-requests-v1.json"))
        needsSynchronization = Self.isSynchronizationPending || recoveryJournal.request != nil
        indexConnection = SpotlightIndexConnection(journal: recoveryJournal) { [weak self] in
            Task { @MainActor [weak self] in self?.systemReindexRequested() }
        }
        if recoveryJournal.recoveredUnreadableState {
            spotlightDiagnostic("unreadable recovery journal; all items scheduled for repair")
        }
    }

    private func systemReindexRequested() {
        persistSynchronizationPending()
        if let library { synchronizeIfNeeded(library: library) }
    }

    /// Persist before hopping back to the main actor so a process termination
    /// between a library mutation and Observation delivery cannot leave a
    /// stale Spotlight manifest marked clean.
    nonisolated static func persistLibraryChangePending() {
        let generation = defaults.integer(forKey: synchronizationGenerationKey)
        defaults.set(
            generation == .max ? 1 : generation + 1,
            forKey: synchronizationGenerationKey
        )
        // 已经记着待同步就不再写一遍, 理由同 `LibrarySearchIndex.persistLibraryChangePending`。
        if defaults.object(forKey: synchronizationPendingKey) as? Bool != true {
            defaults.set(true, forKey: synchronizationPendingKey)
        }
    }

    nonisolated static var showsArtwork: Bool {
        UserDefaults.standard.object(forKey: showsArtworkKey) as? Bool ?? true
    }

    /// The cover switch changes signatures for items with cached artwork, so
    /// the next synchronization adds or removes their thumbnails.
    func artworkPreferenceChanged(library: MusicLibrary) {
        Self.persistLibraryChangePending()
        needsSynchronization = true
        scheduleSynchronization(library: library)
        if isStatusVisible { refreshStatus(library: library) }
    }

    /// 本机新存下了一批封面(存储管理里「下载全部封面和歌词」)。带封面的条目签名变了,
    /// 下一轮同步只重写这些条目。
    func artworkAvailabilityChanged(library: MusicLibrary) {
        artworkPreferenceChanged(library: library)
    }

    private nonisolated static var synchronizationGeneration: Int {
        defaults.integer(forKey: synchronizationGenerationKey)
    }

    private nonisolated static var isSynchronizationPending: Bool {
        (defaults.object(forKey: synchronizationPendingKey) as? Bool ?? true)
            || defaults.integer(forKey: completedSynchronizationGenerationKey)
                != defaults.integer(forKey: synchronizationGenerationKey)
            // Older releases could commit a manifest after deleting its items.
            // A clean dirty bit must not suppress the recovery schema rebuild.
            || defaults.integer(forKey: completedSchemaVersionKey) != schemaVersion
    }

    /// Coalesces rapid library mutations. If a Core Spotlight batch is already
    /// running, the latest snapshot is queued instead of overlapping two batch
    /// sessions on the same named index.
    func scheduleSynchronization(library: MusicLibrary) {
        guard !isSynchronizationSuspended else { return }
        enqueueSynchronization(library: library, delay: Self.debounceDuration)
    }

    /// Reconcile an interrupted/first-run index without turning every process
    /// launch into a new dirty event. On iOS this remains deferred until the
    /// scene enters a non-playing background window.
    func synchronizeIfNeeded(library: MusicLibrary) {
        synchronizeIfNeeded(library: library, delay: Self.debounceDuration)
    }

    private func synchronizeIfNeeded(library: MusicLibrary, delay: Duration) {
        self.library = library
        // Stage 2b: 准备中的库快照是空的。空快照与上一份 manifest 一比, 所有
        // 已索引的条目都会落进 `identifiersToDelete`, 整份 Spotlight 索引被
        // 提交删除, 发布之后再花几分钟重建。守卫放在这里, 启动定时器、后台
        // settle 与非 iOS 的 `.active` 三个入口(含 `resumePendingSynchronization`)
        // 一起覆盖。
        guard library.isReady else {
            library.onReady { [weak self] in
                self?.synchronizeIfNeeded(library: library, delay: delay)
            }
            return
        }
        needsSynchronization = needsSynchronization || Self.isSynchronizationPending
        guard needsSynchronization, !isSynchronizationSuspended else { return }
        enqueueSynchronization(library: library, delay: delay)
    }

    private func enqueueSynchronization(library: MusicLibrary, delay: Duration) {
        beginBackgroundTaskIfNeeded()
        let snapshot = makeLibrarySnapshot(library: library)

        switch workPhase {
        case .idle:
            beginDebouncedSynchronization(snapshot: snapshot, delay: delay)
        case .debouncing:
            pendingTask?.cancel()
            beginDebouncedSynchronization(snapshot: snapshot, delay: delay)
        case .running:
            queuedSnapshot = snapshot
        }
    }

    /// Restarts work canceled for an iOS scene transition without performing a
    /// redundant full-library comparison after every foreground activation.
    func resumePendingSynchronization(library: MusicLibrary) {
        // 解除挂起是纯标志位, 立刻生效; 真正的快照由 `synchronizeIfNeeded`
        // 的就绪守卫推迟到发布之后。
        isSynchronizationSuspended = false
        synchronizeIfNeeded(library: library, delay: .zero)
    }

    /// Keep the process alive across the scene-settle delay. Without this
    /// assertion, iOS can suspend the app before the delayed indexing starts.
    func prepareForBackgroundSynchronization() {
        guard needsSynchronization || Self.isSynchronizationPending else { return }
        beginBackgroundTaskIfNeeded()
    }

    /// Retain only the dirty bit while the user is interacting. The next
    /// background resume snapshots the latest library instead of retaining a
    /// large stale copy from an earlier publication.
    func suspendSynchronization() {
        isSynchronizationSuspended = true
        cancelPendingSynchronization()
    }

    /// Stops opportunistic CPU/file work while the app is resigning active.
    /// A running Core Spotlight commit is allowed to finish its current batch;
    /// cancellation is observed before any subsequent batch or manifest save.
    func cancelPendingSynchronization() {
        defer { endBackgroundTaskIfHeld() }
        guard workPhase != .idle else { return }
        persistSynchronizationPending()
        queuedSnapshot = nil
        pendingTask?.cancel()

        if workPhase == .debouncing {
            pendingTask = nil
            pendingGeneration = nil
            workPhase = .idle
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .background,
              backgroundTaskID == .invalid else { return }
        let generation = UUID()
        backgroundAssertionGeneration = generation
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "primuse.spotlight") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.backgroundAssertionGeneration == generation else { return }
                self.suspendSynchronization()
            }
        }
        #endif
    }

    private func endBackgroundTaskIfHeld() {
        #if os(iOS)
        guard backgroundTaskID != .invalid else { return }
        let identifier = backgroundTaskID
        backgroundTaskID = .invalid
        backgroundAssertionGeneration = nil
        UIApplication.shared.endBackgroundTask(identifier)
        #endif
    }

    /// 打开设置页时量一次收录进度:没在建时拿本机记下的清单比对这份曲库,再到系统索引里查一遍
    /// App 自己的条目 —— 清单说写进去了、索引里却没有的,按没收录算,交给下一轮重写(#346)。
    func refreshStatus(library: MusicLibrary) {
        isStatusVisible = true
        guard library.isReady, workPhase != .running, status.beginMeasuring() else { return }
        let snapshot = makeLibrarySnapshot(library: library)
        let manifestURL = self.manifestURL
        let revision = Self.synchronizationGeneration
        Task.detached(priority: .utility) { [weak self] in
            let stored = Self.loadManifest(from: manifestURL)
            let found = await Self.indexedSignatures()
            guard let prepared = Self.prepareSnapshot(snapshot) else { return }
            let wanted = SpotlightIndexPlanner.makePlan(currentRecords: prepared.records, previousManifest: nil,
                                                         schemaVersion: Self.schemaVersion).nextManifest
            let verification = SpotlightIndexVerification.compare(manifest: wanted, found: found)
            let missing = verification.identifiersToRewrite
            Self.logVerification("status", wanted: wanted, found: found, outcome: verification)
            let measured = found.map { SpotlightIndexManifest(schemaVersion: Self.schemaVersion, signaturesByIdentifier: $0) } ?? stored
            let coverage = SpotlightIndexCoverage.measure(wanted: wanted, stored: measured,
                textOnlySuffix: Self.textOnlySignatureSuffix,
                foundIdentifiers: found.map { Set($0.keys) }, isVerified: found != nil)
            await self?.finishStatusMeasurement(
                coverage, missing: missing, revision: revision, library: library,
                exceedsSongLimit: snapshot.songs.count > Self.maxIndexedSongs
            )
        }
    }

    private func finishStatusMeasurement(
        _ coverage: SpotlightIndexCoverage?, missing: Set<String>, revision: Int,
        library: MusicLibrary, exceedsSongLimit: Bool
    ) {
        guard workPhase != .running, status.activity == .measuring else { return }
        guard revision == Self.synchronizationGeneration else {
            status.finishMeasuring(nil, exceedsSongLimit: exceedsSongLimit)
            if isStatusVisible { refreshStatus(library: library) }
            return
        }
        if !missing.isEmpty { scheduleRewrite(of: missing) }
        status.finishMeasuring(coverage, exceedsSongLimit: exceedsSongLimit)
    }

    private func scheduleRewrite(of identifiers: Set<String>) {
        identifiersMissingFromIndex.formUnion(identifiers)
        persistSynchronizationPending()
    }

    /// 设置页里的「现在建立」。iOS 平时只在退到后台、没在播放时建;点了就在这一页前台接着建,
    /// 离开这一页(`endForegroundSynchronization`)再交回后台。
    func synchronizeNow(library: MusicLibrary) {
        isForegroundSynchronizationRequested = true
        needsSynchronization = true
        isSynchronizationSuspended = false
        synchronizeIfNeeded(library: library, delay: .zero)
    }

    func endForegroundSynchronization() {
        isStatusVisible = false
        guard isForegroundSynchronizationRequested else { return }
        isForegroundSynchronizationRequested = false
        #if os(iOS)
        // 已经退到后台的那一次交给场景切换照常处理。
        guard UIApplication.shared.applicationState != .background else { return }
        suspendSynchronization()
        #endif
    }

    private nonisolated static func logVerification(_ phase: String, wanted: SpotlightIndexManifest,
        found: [String: String]?, outcome: SpotlightIndexVerification.Outcome) {
        let missing: Int
        let outdated: Int
        if case let .needsRewrite(absent, stale) = outcome { missing = absent.count; outdated = stale.count }
        else { missing = 0; outdated = 0 }
        spotlightDiagnostic("\(phase) desired=\(wanted.signaturesByIdentifier.count) found=\(found?.count ?? -1) missing=\(missing) outdated=\(outdated) legacy=\(found?.values.filter(\.isEmpty).count ?? 0) queryOK=\(found != nil)")
    }

    /// 所有条目统一使用 audio 类型；title 通配符会漏掉没有可分词标题的条目。
    private nonisolated static func indexedSignatures() async -> [String: String]? {
        #if os(tvOS)
        return nil
        #else
        return await withCheckedContinuation { continuation in
            let context = CSSearchQueryContext()
            context.fetchAttributes = [spotlightContentVersionKey().keyName]
            let query = CSSearchQuery(queryString: "contentType == \"public.audio\"", queryContext: context)
            let collector = IndexedSignatureCollector()
            query.foundItemsHandler = { collector.append($0) }
            query.completionHandler = { error in
                _ = query
                if let error {
                    spotlightError("query", error)
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: collector.signatures())
                }
            }
            query.start()
        }
        #endif
    }

    nonisolated static func parse(uniqueIdentifier: String) -> SpotlightItem? {
        let parts = uniqueIdentifier.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        switch String(parts[0]) {
        case "song": return .song(id: String(parts[1]))
        case "album": return .album(id: String(parts[1]))
        case "artist": return .artist(id: String(parts[1]))
        case "playlist": return .playlist(id: String(parts[1]))
        default: return nil
        }
    }

    private func makeLibrarySnapshot(library: MusicLibrary) -> LibrarySnapshot {
        self.library = library
        let playlistSummaries = library.playlists.map { playlist in
            PlaylistSummary(
                id: playlist.id,
                name: playlist.name,
                songCount: library.songCount(forPlaylist: playlist.id)
            )
        }
        // 最近放过、喜欢的歌最先进索引: 首页顶上那几首正是用户最先去搜的。
        let prioritySongIDs = library.recentPlaybackSongIDsForSync
            + library.songIDs(forPlaylist: MusicLibrary.likedSongsPlaylistID)
        return LibrarySnapshot(
            songs: library.visibleSongs,
            prioritySongIDs: prioritySongIDs,
            albums: library.visibleAlbums,
            artists: library.visibleArtists,
            playlists: playlistSummaries,
            artistNameConfiguration: library.artistNameConfiguration,
            showsArtwork: Self.showsArtwork
        )
    }

    private func beginDebouncedSynchronization(snapshot: LibrarySnapshot, delay: Duration) {
        let generation = UUID()
        let synchronizationRevision = Self.synchronizationGeneration
        let manifestURL = self.manifestURL
        let thumbnailDirectoryURL = self.thumbnailDirectoryURL
        let status = self.status
        let connection = self.indexConnection!
        let journal = self.recoveryJournal
        pendingGeneration = generation
        workPhase = .debouncing

        pendingTask = Task.detached(priority: .background) { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let missingFromIndex = await self?.transitionToRunning(generation: generation) else { return }

            let recovery = journal.request
            var succeeded = await Self.performSynchronization(
                snapshot: snapshot,
                manifestURL: manifestURL,
                thumbnailDirectoryURL: thumbnailDirectoryURL,
                status: status,
                missingFromIndex: missingFromIndex,
                recovery: recovery,
                connection: connection
            )
            if succeeded, let recovery {
                do { succeeded = try journal.complete(revision: recovery.revision) }
                catch { spotlightError("complete system reindex", error); succeeded = false }
            }
            // 没跑完的那一轮可能还没把它们记成未确认,留给下一轮;已经重写过的再写一次也无妨。
            if !succeeded { await self?.returnMissingIdentifiers(missingFromIndex) }
            await self?.finishSynchronization(
                generation: generation,
                synchronizationRevision: synchronizationRevision,
                succeeded: succeeded
            )
        }
    }

    private func returnMissingIdentifiers(_ identifiers: Set<String>) {
        identifiersMissingFromIndex.formUnion(identifiers)
    }

    private func transitionToRunning(generation: UUID) -> Set<String>? {
        guard pendingGeneration == generation, workPhase == .debouncing else { return nil }
        workPhase = .running
        status.beginIndexing()
        let missing = identifiersMissingFromIndex
        identifiersMissingFromIndex = []
        return missing
    }

    private func finishSynchronization(
        generation: UUID,
        synchronizationRevision completedRevision: Int,
        succeeded: Bool
    ) {
        guard pendingGeneration == generation else { return }
        pendingTask = nil
        pendingGeneration = nil
        workPhase = .idle
        status.finishIndexing()

        if isSynchronizationSuspended {
            queuedSnapshot = nil
            persistSynchronizationPending()
            endBackgroundTaskIfHeld()
            return
        }

        if let queuedSnapshot {
            self.queuedSnapshot = nil
            needsSynchronization = true
            beginDebouncedSynchronization(
                snapshot: queuedSnapshot,
                delay: Self.followUpDebounceDuration
            )
        } else {
            if succeeded, completedRevision == Self.synchronizationGeneration {
                Self.defaults.set(
                    completedRevision,
                    forKey: Self.completedSynchronizationGenerationKey
                )
                Self.defaults.set(Self.schemaVersion, forKey: Self.completedSchemaVersionKey)
                needsSynchronization = false
                Self.defaults.set(false, forKey: Self.synchronizationPendingKey)
            } else {
                persistSynchronizationPending()
            }
            endBackgroundTaskIfHeld()
        }
    }

    private func persistSynchronizationPending() {
        needsSynchronization = true
        Self.persistLibraryChangePending()
    }

    private nonisolated static func performSynchronization(
        snapshot: LibrarySnapshot,
        manifestURL: URL,
        thumbnailDirectoryURL: URL,
        status: SpotlightIndexStatus,
        missingFromIndex: Set<String> = [],
        recovery: SpotlightIndexRecoveryRequest? = nil,
        connection: SpotlightIndexConnection? = nil,
        querySignatures: @Sendable () async -> [String: String]? = { await indexedSignatures() }
    ) async -> Bool {
        let exceedsSongLimit = snapshot.songs.count > maxIndexedSongs
        guard canPerformIndexing, !Task.isCancelled else {
            spotlightDiagnostic("sync deferred cancelled=\(Task.isCancelled) deviceAllows=\(canPerformIndexing)")
            if !Task.isCancelled { await status.holdByDevice() }
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: thumbnailDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            spotlightError("cache setup", error)
            return false
        }

        guard let prepared = prepareSnapshot(snapshot), !Task.isCancelled else { return false }
        let storedManifest = loadManifest(from: manifestURL)
        let index = connection?.index ?? CSSearchableIndex(name: kSpotlightIndexName)
        let clientStateResult = await fetchClientState(from: index)
        if let error = clientStateResult.error {
            // A transiently unavailable index is not evidence that its contents
            // are stale. Defer instead of turning a read failure into a rebuild.
            spotlightError("client-state fetch", error)
            return false
        }
        let expectedClientState = storedManifest.map(clientState(for:))
        let clientStateMatches = clientStateResult.data == expectedClientState
        let forceFullRebuild = storedManifest != nil && !clientStateMatches
        let initiallyFound = await querySignatures()
        guard !Task.isCancelled else { return false }
        let wanted = SpotlightIndexPlanner.makePlan(currentRecords: prepared.records, previousManifest: nil,
                                                     schemaVersion: schemaVersion).nextManifest
        let verification = SpotlightIndexVerification.compare(manifest: wanted, found: initiallyFound)
        logVerification("before sync", wanted: wanted, found: initiallyFound, outcome: verification)
        var missingIdentifiers = missingFromIndex.union(verification.identifiersToRewrite)
        if let recovery {
            missingIdentifiers.formUnion(recovery.allItems ? Set(wanted.signaturesByIdentifier.keys) : recovery.identifiers)
        }
        let previousManifest = storedManifest.map { manifest in
            SpotlightIndexVerification.manifest(manifest, markingUnconfirmed: missingIdentifiers)
        }
        var plan = SpotlightIndexPlanner.makePlan(
            currentRecords: prepared.records,
            previousManifest: previousManifest,
            schemaVersion: schemaVersion,
            forceFullRebuild: forceFullRebuild
        )
        if let recovery, !plan.requiresFullRebuild {
            let requested = recovery.allItems ? Set((initiallyFound ?? [:]).keys).union(recovery.identifiers) : recovery.identifiers
            let deleted = requested.filter { parse(uniqueIdentifier: $0) != nil && wanted.signaturesByIdentifier[$0] == nil }
            plan = SpotlightIndexPlan(identifiersToUpsert: plan.identifiersToUpsert,
                identifiersToDelete: Array(Set(plan.identifiersToDelete).union(deleted)).sorted(),
                requiresFullRebuild: false, nextManifest: plan.nextManifest)
        }
        spotlightDiagnostic("plan desired=\(prepared.records.count) upsert=\(plan.identifiersToUpsert.count) delete=\(plan.identifiersToDelete.count) full=\(plan.requiresFullRebuild) artwork=\(snapshot.showsArtwork) clientStateMatches=\(clientStateMatches)")

        var lastReport = ContinuousClock.now
        /// 设置页上的进度:每写完一批报一次,最多半秒一次。
        func report(
            _ stored: SpotlightIndexManifest?,
            indexing: Bool,
            force: Bool = false,
            found: [String: String]? = nil
        ) async {
            guard force || ContinuousClock.now - lastReport >= .milliseconds(500) else { return }
            lastReport = .now
            var available = found.map { Set($0.keys) }
            if available == nil {
                available = Set((stored?.signaturesByIdentifier ?? [:]).compactMap {
                    $0.value.isEmpty ? nil : $0.key
                })
                if !plan.requiresFullRebuild { available?.formUnion((initiallyFound ?? [:]).keys) }
            }
            let coverage = SpotlightIndexCoverage.measure(
                wanted: plan.nextManifest,
                stored: found.map { SpotlightIndexManifest(schemaVersion: schemaVersion, signaturesByIdentifier: $0) } ?? stored,
                textOnlySuffix: textOnlySignatureSuffix,
                foundIdentifiers: available,
                isVerified: found.map { Set(plan.identifiersToDelete).isDisjoint(with: $0.keys) } ?? false
            )
            await status.report(coverage, isIndexing: indexing, exceedsSongLimit: exceedsSongLimit)
        }

        if plan.isEmpty, !plan.requiresFullRebuild {
            spotlightDiagnostic("no writes needed queryOK=\(initiallyFound != nil)")
            let verified = initiallyFound.map {
                SpotlightIndexVerification.compare(manifest: plan.nextManifest, found: $0) == .consistent
            } ?? false
            await report(previousManifest, indexing: false, force: true, found: initiallyFound)
            return verified
        }
        await report(plan.requiresFullRebuild ? nil : previousManifest, indexing: true, force: true)

        guard canPerformIndexing, !Task.isCancelled else { return false }
        let pendingState = Data("v\(schemaVersion):pending".utf8)
        let signatures = plan.nextManifest.signaturesByIdentifier

        // Progress survives an interruption: the manifest on disk and the
        // index's client state always describe the same checkpoint, so the
        // next run plans from it instead of wiping the index and starting
        // over (which, in 30-second background windows, never got past the
        // first few hundred items).
        var progress = SpotlightIndexCheckpoint(plan: plan, previousManifest: previousManifest)
        var checkpointState = pendingState
        var hasUnsavedProgress = false
        var lastCheckpoint = ContinuousClock.now

        func saveCheckpoint() async throws {
            let manifest = progress.manifest
            try saveManifest(manifest, to: manifestURL)
            let state = clientState(for: manifest)
            try await applyBatch(
                to: index,
                deletingIdentifiers: [],
                searchableItems: [],
                clientState: state
            )
            checkpointState = state
            hasUnsavedProgress = false
            lastCheckpoint = .now
        }

        func saveCheckpointIfDue() async throws {
            guard hasUnsavedProgress,
                  ContinuousClock.now - lastCheckpoint >= checkpointInterval else { return }
            try await saveCheckpoint()
        }

        /// Stops at a batch boundary, keeping what has been committed so far.
        func stop() async -> Bool {
            if hasUnsavedProgress {
                do {
                    try await saveCheckpoint()
                } catch {
                    spotlightError("checkpoint", error)
                }
            }
            spotlightDiagnostic("sync paused; checkpoint retained")
            await report(progress.manifest, indexing: false, force: true)
            if !canPerformIndexing { await status.holdByDevice() }
            return false
        }

        do {
            if plan.requiresFullRebuild {
                // Mark the named index dirty before clearing it. If the app is
                // suspended after deletion but before the first checkpoint,
                // the next launch will detect the mismatch and recover again.
                try await applyBatch(
                    to: index,
                    deletingIdentifiers: [],
                    searchableItems: [],
                    clientState: pendingState
                )
                guard canPerformIndexing, !Task.isCancelled else { return false }
                // Index names partition client state, not domain deletions.
                // This also removes legacy items; never repeat it after upserts.
                try await deleteDomains(kSpotlightDomains, from: index)
            }
            // Everything this run is about to touch is recorded as unconfirmed
            // before the first change reaches the index.
            try await saveCheckpoint()

            var deleteCursor = 0
            while deleteCursor < plan.identifiersToDelete.count {
                guard canPerformIndexing, !Task.isCancelled else { return await stop() }
                let end = min(
                    deleteCursor + maxDeletesPerBatch,
                    plan.identifiersToDelete.count
                )
                let identifiers = Array(plan.identifiersToDelete[deleteCursor..<end])
                try await applyBatch(
                    to: index,
                    deletingIdentifiers: identifiers,
                    searchableItems: [],
                    clientState: checkpointState
                )
                progress.confirmDeleted(identifiers)
                hasUnsavedProgress = true
                deleteCursor = end
                await report(progress.manifest, indexing: true)
                try await saveCheckpointIfDue()
                guard await pauseBetweenBatches() else { return await stop() }
            }

            var deferredThumbnails: [String] = []
            for pass in [ThumbnailPass.cachedOnly, .generating] {
                let identifiers = pass == .cachedOnly ? plan.identifiersToUpsert : deferredThumbnails
                var upsertCursor = 0
                while upsertCursor < identifiers.count {
                    guard canPerformIndexing, !Task.isCancelled else { return await stop() }
                    var searchableItems: [CSSearchableItem] = []
                    searchableItems.reserveCapacity(maxItemsPerBatch)
                    var confirmed: [String: String] = [:]
                    var thumbnailCacheMissCount = 0

                    while upsertCursor < identifiers.count,
                          searchableItems.count < maxItemsPerBatch,
                          thumbnailCacheMissCount < maxThumbnailCacheMissesPerBatch {
                        let identifier = identifiers[upsertCursor]
                        guard let payload = prepared.payloadsByIdentifier[identifier],
                              let signature = signatures[identifier] else {
                            spotlightDiagnostic("payload missing; sync remains pending")
                            return false
                        }
                        let item = makeSearchableItem(
                            payload: payload,
                            thumbnailPass: pass,
                            thumbnailDirectoryURL: thumbnailDirectoryURL
                        )
                        // The library's explicit deletion plan owns their lifetime.
                        item.searchableItem.expirationDate = .distantFuture
                        searchableItems.append(item.searchableItem)
                        switch item.thumbnail {
                        case .deferred:
                            deferredThumbnails.append(identifier)
                            confirmed[identifier] = signature + textOnlySignatureSuffix
                        case .generated:
                            thumbnailCacheMissCount += 1
                            confirmed[identifier] = signature
                        case .none, .attached:
                            confirmed[identifier] = signature
                        }
                        item.searchableItem.attributeSet.setValue(confirmed[identifier]! as NSString, forCustomKey: spotlightContentVersionKey())
                        upsertCursor += 1
                    }

                    try await applyBatch(
                        to: index,
                        deletingIdentifiers: [],
                        searchableItems: searchableItems,
                        clientState: checkpointState
                    )
                    progress.confirmIndexed(confirmed)
                    hasUnsavedProgress = true
                    await report(progress.manifest, indexing: true)
                    try await saveCheckpointIfDue()
                    guard await pauseBetweenBatches() else { return await stop() }
                }
            }

            guard canPerformIndexing, !Task.isCancelled else { return await stop() }
            try await saveCheckpoint()
            guard progress.manifest == plan.nextManifest else {
                // Still a truthful checkpoint: the next run plans the rest.
                spotlightDiagnostic("checkpoint differs from plan; sync remains pending")
                return false
            }
            // 批次提交并不代表查询已可见。只等待查询收敛，不在等待期间重复写入。
            let deletedIdentifiers = Set(plan.identifiersToDelete)
            func isVerified(_ found: [String: String]) -> Bool {
                SpotlightIndexVerification.compare(manifest: plan.nextManifest, found: found) == .consistent
                    && deletedIdentifiers.isDisjoint(with: found.keys)
            }
            var found: [String: String]?
            for attempt in 0..<3 {
                guard !Task.isCancelled else { return await stop() }
                found = await querySignatures()
                logVerification("after write attempt=\(attempt + 1)", wanted: plan.nextManifest, found: found,
                                outcome: SpotlightIndexVerification.compare(manifest: plan.nextManifest, found: found))
                if let found,
                   isVerified(found) {
                    await report(progress.manifest, indexing: false, force: true, found: found)
                    spotlightDiagnostic("write verified items=\(found.count)")
                    break
                }
                if attempt < 2 { try await Task.sleep(for: .milliseconds(400 * (attempt + 1))) }
            }
            guard !Task.isCancelled else { return await stop() }
            if let found {
                let rewrite = SpotlightIndexVerification.compare(manifest: plan.nextManifest, found: found).identifiersToRewrite
                let undeleted = deletedIdentifiers.intersection(found.keys)
                let retry = rewrite.union(undeleted)
                if !retry.isEmpty {
                    progress.confirmIndexed(Dictionary(uniqueKeysWithValues: retry.map { ($0, SpotlightIndexCheckpoint.unconfirmedSignature) }))
                    try await saveCheckpoint()
                    await report(progress.manifest, indexing: false, force: true, found: found)
                    spotlightDiagnostic("verification pending rewrite=\(rewrite.count) undeleted=\(undeleted.count); checkpoint retained")
                    return false
                }
            }
            guard let found,
                  isVerified(found) else {
                // A failed query cannot confirm that acknowledged deletions took effect.
                if !deletedIdentifiers.isEmpty {
                    progress.confirmIndexed(Dictionary(uniqueKeysWithValues: deletedIdentifiers.map {
                        ($0, SpotlightIndexCheckpoint.unconfirmedSignature)
                    }))
                    try await saveCheckpoint()
                }
                await report(progress.manifest, indexing: false, force: true)
                spotlightDiagnostic("write awaits system verification")
                return false
            }
            spotlightDiagnostic(
                "synchronized: upsert=\(plan.identifiersToUpsert.count) delete=\(plan.identifiersToDelete.count) thumbnails=\(deferredThumbnails.count) full=\(plan.requiresFullRebuild)"
            )
            return true
        } catch {
            spotlightError("synchronization", error)
            return false
        }
    }

    /// The songs that go into the index, in the order they are written: the
    /// priority songs (recently played, liked) and then the newest additions,
    /// up to `maxIndexedSongs`. A bounded selection, not a sort of the library.
    private nonisolated static func indexedSongs(
        of snapshot: LibrarySnapshot
    ) -> (songs: [Song], priorityCount: Int) {
        let songs = snapshot.songs
        let limit = min(songs.count, maxIndexedSongs)
        var chosen: [Song] = []
        chosen.reserveCapacity(limit)
        var chosenIDs: Set<String> = []
        let wanted = Set(snapshot.prioritySongIDs)
        if !wanted.isEmpty {
            // 先按最近放过、再按喜欢的顺序: 列表本身就是这个顺序。
            var byID: [String: Int] = [:]
            byID.reserveCapacity(wanted.count)
            for index in songs.indices where wanted.contains(songs[index].id) {
                byID[songs[index].id] = index
            }
            for id in snapshot.prioritySongIDs {
                guard chosen.count < limit,
                      let index = byID[id],
                      chosenIDs.insert(id).inserted else { continue }
                chosen.append(songs[index])
            }
        }
        let priorityCount = chosen.count
        guard chosen.count < limit else { return (chosen, priorityCount) }
        // 选的是下标: 比较只读日期与 ID, 不为每次比较复制整首歌。
        let newest = CarPlayListSelection.firstSorted(
            songs.indices.lazy.filter { !chosenIDs.contains(songs[$0].id) },
            limit: limit - chosen.count
        ) { lhs, rhs in
            songs[lhs].dateAdded != songs[rhs].dateAdded
                ? songs[lhs].dateAdded > songs[rhs].dateAdded
                : songs[lhs].id < songs[rhs].id
        }
        chosen.append(contentsOf: newest.map { songs[$0] })
        return (chosen, priorityCount)
    }

    /// Resolves a cover the artwork store already holds; nothing is fetched.
    /// Source-relative and remote references fall back to the song's own
    /// mirror, which the app writes once it has shown that cover.
    private nonisolated static func coverSource(
        reference: String?,
        songID: String?,
        availableFileNames: Set<String>?,
        identities: inout [String: String?]
    ) -> CoverSource? {
        var candidates: [String] = []
        if let reference, !reference.isEmpty { candidates.append(reference) }
        if let songID {
            candidates.append(MetadataAssetStore.shared.expectedCoverFileName(for: songID))
        }
        for fileName in candidates {
            if let availableFileNames, !availableFileNames.contains(fileName) { continue }
            let identity: String?
            if let cached = identities[fileName] {
                identity = cached
            } else {
                identity = MetadataAssetStore.shared.coverContentIdentifier(named: fileName)
                identities.updateValue(identity, forKey: fileName)
            }
            if let identity {
                return CoverSource(fileName: fileName, contentIdentifier: identity)
            }
        }
        return nil
    }

    /// Most server songs have no local cover. One directory walk avoids
    /// opening a missing file for every song in each short background window.
    private nonisolated static func availableCoverFileNames() -> Set<String>? {
        guard let files = FileManager.default.enumerator(
            atPath: MetadataAssetStore.shared.artworkDirectoryURL.path
        ) else { return nil }
        return Set(files.compactMap { $0 as? String })
    }

    private nonisolated static func prepareSnapshot(
        _ snapshot: LibrarySnapshot
    ) -> PreparedSnapshot? {
        let (songs, priorityCount) = indexedSongs(of: snapshot)
        let totalCount = songs.count
            + snapshot.albums.count
            + snapshot.artists.count
            + snapshot.playlists.count
        var records: [SpotlightIndexRecord] = []
        records.reserveCapacity(totalCount)
        var payloads: [String: IndexPayload] = [:]
        payloads.reserveCapacity(totalCount)
        var coverIdentities: [String: String?] = [:]
        let showsArtwork = snapshot.showsArtwork
        let availableFileNames = showsArtwork ? availableCoverFileNames() : nil
        let artistConfigurationSignature = snapshot.artistNameConfiguration.cacheSignature

        func appendSong(_ song: Song) {
            let identifier = "song:\(song.id)"
            let cover = showsArtwork
                ? coverSource(
                    reference: song.coverArtFileName,
                    songID: song.id,
                    availableFileNames: availableFileNames,
                    identities: &coverIdentities
                )
                : nil
            let artistDisplayName = song.displayArtistName(
                configuration: snapshot.artistNameConfiguration
            )
            let signature = contentSignature([
                song.title,
                song.albumTitle,
                artistDisplayName,
                artistConfigurationSignature,
                cover?.contentIdentifier,
            ])
            records.append(SpotlightIndexRecord(identifier: identifier, signature: signature))
            payloads[identifier] = .song(
                song,
                artistDisplayName: artistDisplayName,
                cover: cover
            )
        }

        // Write order: the songs people search first, then the few albums,
        // artists and playlists, then the rest of the songs.
        for (offset, song) in songs[..<priorityCount].enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            appendSong(song)
        }

        for album in snapshot.albums {
            let identifier = "album:\(album.id)"
            let cover = showsArtwork
                ? coverSource(
                    reference: album.coverArtPath,
                    songID: nil,
                    availableFileNames: availableFileNames,
                    identities: &coverIdentities
                )
                : nil
            records.append(SpotlightIndexRecord(
                identifier: identifier,
                signature: contentSignature([album.title, album.artistName, cover?.contentIdentifier])
            ))
            payloads[identifier] = .album(album, cover: cover)
        }

        let artistSubtitle = String(localized: "spotlight_artist_subtitle")
        for artist in snapshot.artists {
            let identifier = "artist:\(artist.id)"
            records.append(SpotlightIndexRecord(
                identifier: identifier,
                signature: contentSignature([artist.name, artistSubtitle])
            ))
            payloads[identifier] = .artist(artist)
        }

        for playlist in snapshot.playlists {
            let identifier = "playlist:\(playlist.id)"
            let subtitle = String(
                format: String(localized: "spotlight_playlist_subtitle_format"),
                playlist.songCount
            )
            records.append(SpotlightIndexRecord(
                identifier: identifier,
                signature: contentSignature([playlist.name, subtitle])
            ))
            payloads[identifier] = .playlist(playlist)
        }

        for (offset, song) in songs[priorityCount...].enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            appendSong(song)
        }

        return PreparedSnapshot(records: records, payloadsByIdentifier: payloads)
    }

    private nonisolated static func makeSearchableItem(
        payload: IndexPayload,
        thumbnailPass: ThumbnailPass,
        thumbnailDirectoryURL: URL
    ) -> (searchableItem: CSSearchableItem, thumbnail: ThumbnailOutcome) {
        switch payload {
        case let .song(song, artistDisplayName, cover):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = song.title
            attrs.displayName = song.title
            attrs.album = song.albumTitle
            attrs.artist = artistDisplayName
            attrs.contentDescription = [artistDisplayName, song.albumTitle]
                .compactMap { $0 }
                .joined(separator: " — ")
            attrs.keywords = [song.title, artistDisplayName, song.albumTitle].compactMap { $0 }
            if song.duration > 0 {
                attrs.duration = NSNumber(value: song.duration)
            }
            let thumbnail = attachThumbnail(
                cover,
                to: attrs,
                pass: thumbnailPass,
                directoryURL: thumbnailDirectoryURL
            )
            return (
                CSSearchableItem(
                    uniqueIdentifier: "song:\(song.id)",
                    domainIdentifier: kSongDomain,
                    attributeSet: attrs
                ),
                thumbnail
            )

        case let .album(album, cover):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = album.title
            attrs.displayName = album.title
            attrs.album = album.title
            attrs.artist = album.artistName
            attrs.contentDescription = album.artistName ?? ""
            attrs.keywords = [album.title, album.artistName].compactMap { $0 }
            let thumbnail = attachThumbnail(
                cover,
                to: attrs,
                pass: thumbnailPass,
                directoryURL: thumbnailDirectoryURL
            )
            return (
                CSSearchableItem(
                    uniqueIdentifier: "album:\(album.id)",
                    domainIdentifier: kAlbumDomain,
                    attributeSet: attrs
                ),
                thumbnail
            )

        case let .artist(artist):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = artist.name
            attrs.displayName = artist.name
            attrs.artist = artist.name
            attrs.contentDescription = String(localized: "spotlight_artist_subtitle")
            attrs.keywords = [artist.name]
            return (
                CSSearchableItem(
                    uniqueIdentifier: "artist:\(artist.id)",
                    domainIdentifier: kArtistDomain,
                    attributeSet: attrs
                ),
                .none
            )

        case let .playlist(playlist):
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = playlist.name
            attrs.displayName = playlist.name
            attrs.contentDescription = String(
                format: String(localized: "spotlight_playlist_subtitle_format"),
                playlist.songCount
            )
            attrs.keywords = [playlist.name]
            return (
                CSSearchableItem(
                    uniqueIdentifier: "playlist:\(playlist.id)",
                    domainIdentifier: kPlaylistDomain,
                    attributeSet: attrs
                ),
                .none
            )
        }
    }

    /// Spotlight renders results in its own process, which cannot open files
    /// in the app container, so the thumbnail travels as data. A thumbnailURL
    /// into Application Support showed only the generic icon.
    private nonisolated static func attachThumbnail(
        _ cover: CoverSource?,
        to attrs: CSSearchableItemAttributeSet,
        pass: ThumbnailPass,
        directoryURL: URL
    ) -> ThumbnailOutcome {
        guard let cover else { return .none }
        let url = thumbnailURL(for: cover, directoryURL: directoryURL)
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            attrs.thumbnailData = data
            return .attached
        }
        guard pass == .generating else { return .deferred }
        // A cover that cannot be decoded stays without a thumbnail until it
        // changes; retrying it every run would only repeat the failure.
        if let data = makeThumbnail(for: cover, at: url) {
            attrs.thumbnailData = data
        }
        return .generated
    }

    private nonisolated static func thumbnailURL(
        for cover: CoverSource,
        directoryURL: URL
    ) -> URL {
        let cacheKey = SHA256.hash(data: Data(cover.contentIdentifier.utf8))
            .prefix(20)
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent("\(cacheKey).jpg")
    }

    /// Writes a persistent 128 px JPEG keyed by the cover's content identity.
    /// Builds decode at most eight new covers per batch; later runs and
    /// metadata-only updates read the cached file.
    private nonisolated static func makeThumbnail(for cover: CoverSource, at url: URL) -> Data? {
        guard let raw = MetadataAssetStore.shared.readCoverData(named: cover.fileName),
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(raw) else {
            return nil
        }

        let encoded: Data? = autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(raw as CFData, sourceOptions) else {
                return nil
            }
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
            ] as CFDictionary
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions
            ) else {
                return nil
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, thumbnail, [
                kCGImageDestinationLossyCompressionQuality: 0.7,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }
        guard let encoded else { return nil }
        do {
            try encoded.write(to: url, options: .atomic)
        } catch {
            spotlightError("thumbnail cache write", error)
        }
        return encoded
    }

    private nonisolated static func applyBatch(
        to index: CSSearchableIndex,
        deletingIdentifiers: [String],
        searchableItems: [CSSearchableItem],
        clientState: Data
    ) async throws {
        enqueueBatchMutations(
            to: index,
            deletingIdentifiers: deletingIdentifiers,
            searchableItems: searchableItems
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            index.endBatch(withClientState: clientState) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    /// The completion-handler variants are intentional inside a Core Spotlight
    /// batch: mutations are enqueued synchronously, and the single awaited
    /// commit point is `endBatch` below.
    private nonisolated static func enqueueBatchMutations(
        to index: CSSearchableIndex,
        deletingIdentifiers: [String],
        searchableItems: [CSSearchableItem]
    ) {
        index.beginBatch()
        if !deletingIdentifiers.isEmpty {
            index.deleteSearchableItems(
                withIdentifiers: deletingIdentifiers,
                completionHandler: nil
            )
        }
        if !searchableItems.isEmpty {
            index.indexSearchableItems(searchableItems, completionHandler: nil)
        }
    }

    private nonisolated static func deleteDomains(
        _ domains: [String],
        from index: CSSearchableIndex
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domains) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private nonisolated static func fetchClientState(
        from index: CSSearchableIndex
    ) async -> ClientStateResult {
        await withCheckedContinuation { continuation in
            index.fetchLastClientState { data, error in
                continuation.resume(returning: ClientStateResult(data: data, error: error))
            }
        }
    }

    private nonisolated static func pauseBetweenBatches() async -> Bool {
        do {
            try await Task.sleep(for: interBatchDelay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private nonisolated static var canPerformIndexing: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return false
        case .nominal, .fair:
            break
        @unknown default:
            return false
        }
        #if os(iOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return false
        }
        #endif
        return true
    }

    private nonisolated static func contentSignature(_ fields: [String?]) -> String {
        var encoded = Data()
        for field in fields {
            guard let field else {
                encoded.append(0)
                continue
            }
            encoded.append(1)
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        return SHA256.hash(data: encoded)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func clientState(
        for manifest: SpotlightIndexManifest
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("schema:\(manifest.schemaVersion)\n".utf8))
        for identifier in manifest.signaturesByIdentifier.keys.sorted() {
            hasher.update(data: Data(identifier.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data((manifest.signaturesByIdentifier[identifier] ?? "").utf8))
            hasher.update(data: Data([0x0A]))
        }
        let digest = hasher.finalize()
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return Data("v\(manifest.schemaVersion):\(digest)".utf8)
    }

    private nonisolated static func loadManifest(from url: URL) -> SpotlightIndexManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SpotlightIndexManifest.self, from: data)
    }

    private nonisolated static func saveManifest(
        _ manifest: SpotlightIndexManifest,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }
}

/// 写入进度与系统查询确认分开保存，待更新的封面不会算作搜索缺项。
@MainActor
@Observable
final class SpotlightIndexStatus {
    enum Activity: Equatable {
        case idle
        case measuring
        case indexing
    }

    private(set) var coverage: SpotlightIndexCoverage?
    private(set) var activity: Activity = .idle
    /// 上一次该建时设备过热或开着低电量模式,停着没建。
    private(set) var isHeldByDevice = false
    /// 曲库里的歌多于能收录的上限,只收录其中一部分。
    private(set) var exceedsSongLimit = false

    func report(_ coverage: SpotlightIndexCoverage, isIndexing: Bool, exceedsSongLimit: Bool) {
        self.coverage = coverage
        self.exceedsSongLimit = exceedsSongLimit
        activity = isIndexing ? .indexing : .idle
        if isIndexing { isHeldByDevice = false }
    }

    func holdByDevice() {
        isHeldByDevice = true
        if activity == .indexing { activity = .idle }
    }

    func beginIndexing() {
        activity = .indexing
        isHeldByDevice = false
    }

    func finishIndexing() {
        if activity == .indexing { activity = .idle }
    }

    /// 已经在量或在建时不再量。
    func beginMeasuring() -> Bool {
        guard activity == .idle else { return false }
        activity = .measuring
        return true
    }

    func finishMeasuring(_ coverage: SpotlightIndexCoverage?, exceedsSongLimit: Bool) {
        // 量的时候开始建了:以建的那边报的为准。
        guard activity == .measuring else { return }
        activity = .idle
        if let coverage { self.coverage = coverage }
        self.exceedsSongLimit = exceedsSongLimit
    }
}

/// 系统搜索、Siri 里的「在 Primuse 中搜索」(#346):带着输入的字打开 App 的搜索页。App Intents 的
/// 搜索意图;Spotlight 结果下面那条老的 `CoreSpotlightContinuation` 照旧留着,两条路进的是同一个搜索页。
struct PrimuseSearchInAppIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search Library"
    static let description = IntentDescription("Open Primuse's search with these words.")
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Keyword")
    var criteria: StringSearchCriteria

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let query = criteria.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .result() }
        #if os(iOS)
        SystemActivityRouter.shared.showSearch(query, route: "intent")
        #elseif os(macOS)
        MacSystemActivityRouter.shared.showSearch(query, route: "intent")
        #endif
        return .result()
    }
}

#if !os(tvOS)
/// 查询结果分批从别的线程回来,收在这里。
private final class IndexedSignatureCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String: String] = [:]

    func append(_ items: [CSSearchableItem]) {
        lock.lock()
        defer { lock.unlock() }
        for item in items where kSpotlightDomains.contains(item.domainIdentifier ?? "") {
            found[item.uniqueIdentifier] = item.attributeSet.value(forCustomKey: spotlightContentVersionKey()) as? String ?? ""
        }
    }

    func signatures() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return found
    }
}
#endif

enum SpotlightItem: Sendable, Equatable {
    case song(id: String)
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
}
