import AppIntents
import CoreSpotlight
import CryptoKit
import Foundation
import ImageIO
import OSLog
import PrimuseKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

private let spotlightLog = Logger(subsystem: "com.welape.yuanyin", category: "Spotlight")

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
    private var workPhase: WorkPhase = .idle
    private var pendingTask: Task<Void, Never>?
    private var pendingGeneration: UUID?
    private var queuedSnapshot: LibrarySnapshot?
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
        needsSynchronization = Self.isSynchronizationPending
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

    /// The cover switch changes every item's signature, so the next
    /// synchronization re-indexes the library with or without thumbnails.
    func artworkPreferenceChanged(library: MusicLibrary) {
        Self.persistLibraryChangePending()
        needsSynchronization = true
        scheduleSynchronization(library: library)
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

    static func parse(uniqueIdentifier: String) -> SpotlightItem? {
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
        pendingGeneration = generation
        workPhase = .debouncing

        pendingTask = Task.detached(priority: .background) { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  await self?.transitionToRunning(generation: generation) == true else {
                return
            }

            let succeeded = await Self.performSynchronization(
                snapshot: snapshot,
                manifestURL: manifestURL,
                thumbnailDirectoryURL: thumbnailDirectoryURL
            )
            await self?.finishSynchronization(
                generation: generation,
                synchronizationRevision: synchronizationRevision,
                succeeded: succeeded
            )
        }
    }

    private func transitionToRunning(generation: UUID) -> Bool {
        guard pendingGeneration == generation, workPhase == .debouncing else { return false }
        workPhase = .running
        return true
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
        thumbnailDirectoryURL: URL
    ) async -> Bool {
        guard canPerformIndexing, !Task.isCancelled else {
            spotlightLog.notice("Spotlight sync deferred because of thermal/low-power state")
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
            spotlightLog.error("Spotlight cache setup failed: \(error.localizedDescription)")
            return false
        }

        guard let prepared = prepareSnapshot(snapshot), !Task.isCancelled else { return false }
        let previousManifest = loadManifest(from: manifestURL)
        let index = CSSearchableIndex(name: kSpotlightIndexName)
        let clientStateResult = await fetchClientState(from: index)
        if let error = clientStateResult.error {
            // A transiently unavailable index is not evidence that its contents
            // are stale. Defer instead of turning a read failure into a rebuild.
            spotlightLog.error("Spotlight client-state fetch failed: \(error.localizedDescription)")
            return false
        }
        let expectedClientState = previousManifest.map(clientState(for:))
        let clientStateMatches = clientStateResult.data == expectedClientState
        let forceFullRebuild = previousManifest != nil && !clientStateMatches
        let plan = SpotlightIndexPlanner.makePlan(
            currentRecords: prepared.records,
            previousManifest: previousManifest,
            schemaVersion: schemaVersion,
            forceFullRebuild: forceFullRebuild
        )

        if plan.isEmpty, !plan.requiresFullRebuild {
            spotlightLog.debug("Spotlight index already matches the library")
            return true
        }

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
                    spotlightLog.error("Spotlight checkpoint failed: \(error.localizedDescription)")
                }
            }
            spotlightLog.notice("Spotlight sync paused; progress kept for the next run")
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
                            spotlightLog.error("Spotlight payload missing for \(identifier, privacy: .public)")
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
                    try await saveCheckpointIfDue()
                    guard await pauseBetweenBatches() else { return await stop() }
                }
            }

            guard canPerformIndexing, !Task.isCancelled else { return await stop() }
            try await saveCheckpoint()
            guard progress.manifest == plan.nextManifest else {
                // Still a truthful checkpoint: the next run plans the rest.
                spotlightLog.error("Spotlight progress diverged from the plan; continuing next run")
                return false
            }
            spotlightLog.notice(
                "Spotlight synchronized: upsert=\(plan.identifiersToUpsert.count) delete=\(plan.identifiersToDelete.count) thumbnails=\(deferredThumbnails.count) full=\(plan.requiresFullRebuild)"
            )
            return true
        } catch {
            spotlightLog.error("Spotlight synchronization failed: \(error.localizedDescription)")
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
            spotlightLog.error("Spotlight thumbnail cache write failed: \(error.localizedDescription)")
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

enum SpotlightItem: Sendable, Equatable {
    case song(id: String)
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
}
