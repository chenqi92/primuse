import CloudKit
import Foundation
import PrimuseKit
import SwiftUI

enum CloudSyncStatus: Equatable, Sendable {
    case disabled
    case idle
    case syncing
    case upToDate
    case error(String)
    case accountUnavailable(AccountUnavailableReason)
    case quotaExceeded
    case networkUnavailable
}

enum AccountUnavailableReason: Equatable, Sendable {
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unknown

    var localizedKey: LocalizedStringKey {
        switch self {
        case .noAccount: return "status_no_icloud_account"
        case .restricted: return "status_icloud_restricted"
        case .temporarilyUnavailable: return "status_icloud_temporarily_unavailable"
        case .unknown: return "status_icloud_unknown"
        }
    }
}

/// Entity payloads flowing through CKSyncEngine. Each conforms to `Codable` so we can
/// stash them inside a single CKRecord blob field, which sidesteps schema management
/// for CloudKit dashboard.
@MainActor
@Observable
final class CloudKitSyncService {
    nonisolated static let containerID = "iCloud.com.welape.yuanyin"
    nonisolated static let zoneID = CKRecordZone.ID(zoneName: "PrimuseSync")

    enum RecordType {
        static let playlist = "Playlist"
        static let musicSource = "MusicSource"
        static let playbackHistory = "PlaybackHistory"
        static let scraperConfig = "ScraperConfig"
    }

    /// Singleton ID used for the playback-history record (one per user).
    static let playbackHistoryRecordName = "primuse.playbackHistory.singleton"

    // MARK: - Collaborators

    private let library: MusicLibrary
    private let sourcesStore: SourcesStore
    private let scraperConfigStore: ScraperConfigStore
    private let scraperSettingsStore: ScraperSettingsStore

    // MARK: - State

    private let container: CKContainer
    private let database: CKDatabase
    private(set) var engine: CKSyncEngine?
    private let stateURL: URL

    /// In-memory marker so callers know whether a remote update is currently being
    /// applied — local stores can bail out of their own `markChanged` loop.
    private(set) var isApplyingRemote = false

    /// Coalesces playback-history pushes to at most once per 5 minutes.
    private var pendingHistoryFlush: Task<Void, Never>?
    private static let historyThrottle: Duration = .seconds(300)

    /// Set true once the consumer calls `start()`. While false we don't propagate
    /// local changes to CloudKit.
    private(set) var isStarted = false

    /// NotificationCenter observer tokens — held so we can detach in `stop()`.
    private var observerTokens: [NSObjectProtocol] = []

    /// User-facing sync state — bound to the Settings UI.
    private(set) var status: CloudSyncStatus = .disabled
    private(set) var lastSyncedAt: Date?

    /// Listens for `CKAccountChanged` so we can flip into `.accountUnavailable`
    /// when the user signs out of iCloud while the app is running.
    private var accountChangeObserver: NSObjectProtocol?

    // MARK: - Init

    init(
        library: MusicLibrary,
        sourcesStore: SourcesStore,
        scraperConfigStore: ScraperConfigStore = .shared,
        scraperSettingsStore: ScraperSettingsStore
    ) {
        self.library = library
        self.sourcesStore = sourcesStore
        self.scraperConfigStore = scraperConfigStore
        self.scraperSettingsStore = scraperSettingsStore
        self.container = CKContainer(identifier: Self.containerID)
        self.database = container.privateCloudDatabase

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.stateURL = directory.appendingPathComponent("cloudkit-engine-state.bin")
    }

    // MARK: - Lifecycle

    /// Bring the sync engine online. Reads previous engine state from disk if present,
    /// then does an initial fetch + sends any locally pending changes.
    func start() async {
        guard engine == nil else { return }

        // Verify the user has an iCloud account before standing up the engine —
        // CKSyncEngine will fail every operation with `.notAuthenticated`
        // otherwise, and the UI is much friendlier when we surface that up front.
        let accountAvailable = await checkAccountAndUpdateStatus()
        guard accountAvailable else { return }

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = true

        let engine = CKSyncEngine(configuration)
        self.engine = engine
        self.isStarted = true
        self.status = .syncing

        // Make sure the zone exists by enqueueing a save (the engine de-dupes).
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])

        attachLocalChangeObservers()
        attachAccountChangeObserver()

        // Push existing local state on first run so the other device sees something.
        scheduleInitialUpload()

        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            self.status = .upToDate
            self.lastSyncedAt = Date()
        } catch {
            plog("CloudKitSync: initial fetch/send error: \(error.localizedDescription)")
            self.status = mapToSyncStatus(error)
        }
    }

    /// Query CloudKit account status and translate it into `self.status`. Returns
    /// `true` only if the account is available for sync.
    @discardableResult
    private func checkAccountAndUpdateStatus() async -> Bool {
        do {
            let accountStatus = try await container.accountStatus()
            switch accountStatus {
            case .available:
                return true
            case .noAccount:
                self.status = .accountUnavailable(.noAccount)
            case .restricted:
                self.status = .accountUnavailable(.restricted)
            case .temporarilyUnavailable:
                self.status = .accountUnavailable(.temporarilyUnavailable)
            case .couldNotDetermine:
                self.status = .accountUnavailable(.unknown)
            @unknown default:
                self.status = .accountUnavailable(.unknown)
            }
        } catch {
            self.status = .error(error.localizedDescription)
        }
        return false
    }

    private func attachAccountChangeObserver() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let available = await self.checkAccountAndUpdateStatus()
                if !available {
                    self.stop(updateStatus: false)
                }
            }
        }
    }

    /// Tear down the engine. Local data is left intact.
    func stop(updateStatus: Bool = true) {
        pendingHistoryFlush?.cancel()
        pendingHistoryFlush = nil
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens.removeAll()
        if let accountChangeObserver {
            NotificationCenter.default.removeObserver(accountChangeObserver)
            self.accountChangeObserver = nil
        }
        engine = nil
        isStarted = false
        if updateStatus { status = .disabled }
    }

    /// Force a fetch + send pass (used by the "Sync now" action).
    func syncNow() async {
        guard let engine else { return }
        status = .syncing
        do {
            try await engine.fetchChanges()
            try await engine.sendChanges()
            status = .upToDate
            lastSyncedAt = Date()
        } catch {
            status = mapToSyncStatus(error)
        }
    }

    private func mapToSyncStatus(_ error: any Error) -> CloudSyncStatus {
        guard let ckError = error as? CKError else {
            return .error(error.localizedDescription)
        }
        plog("CloudKitSync: CKError code=\(ckError.code.rawValue) (\(ckError.code)) desc=\(ckError.localizedDescription) userInfo=\(ckError.userInfo)")
        switch ckError.code {
        case .quotaExceeded:
            return .quotaExceeded
        case .networkUnavailable, .networkFailure:
            return .networkUnavailable
        case .notAuthenticated:
            return .accountUnavailable(.noAccount)
        case .accountTemporarilyUnavailable:
            return .accountUnavailable(.temporarilyUnavailable)
        case .serverRejectedRequest, .badContainer, .missingEntitlement, .permissionFailure:
            // Container / entitlement misconfigured server-side. Surface a specific
            // hint so the user knows it isn't a transient runtime issue.
            return .error("CloudKit \(ckError.code.rawValue): \(ckError.localizedDescription) — \(String(localized: "icloud_container_setup_hint"))")
        default:
            return .error("CloudKit \(ckError.code.rawValue): \(ckError.localizedDescription)")
        }
    }

    private func attachLocalChangeObservers() {
        let nc = NotificationCenter.default
        observerTokens.append(nc.addObserver(forName: .primusePlaylistsDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.playlistsChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primusePlaylistDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.playlistDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseSourcesDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.sourcesChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseSourceDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.sourceDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseScraperConfigDidChange, object: nil, queue: .main) { [weak self] note in
            let ids = (note.userInfo?["ids"] as? [String]) ?? []
            Task { @MainActor in self?.scraperConfigsChanged(ids: ids) }
        })
        observerTokens.append(nc.addObserver(forName: .primuseScraperConfigDidDelete, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            Task { @MainActor in self?.scraperConfigDeleted(id: id) }
        })
        observerTokens.append(nc.addObserver(forName: .primusePlaybackHistoryDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.playbackHistoryChanged() }
        })
    }

    // MARK: - Local-change hooks (called by stores after they persist locally)

    func playlistsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        enqueueSaves(recordType: RecordType.playlist, ids: ids)
    }

    func playlistDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.playlists) else { return }
        enqueueDeletes(recordType: RecordType.playlist, ids: [id])
    }

    func sourcesChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueSaves(recordType: RecordType.musicSource, ids: ids)
    }

    func sourceDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        enqueueDeletes(recordType: RecordType.musicSource, ids: [id])
    }

    func scraperConfigsChanged(ids: [String]) {
        guard CloudSyncChannel.isEnabled(.settings) else { return }
        enqueueSaves(recordType: RecordType.scraperConfig, ids: ids)
    }

    func scraperConfigDeleted(id: String) {
        guard CloudSyncChannel.isEnabled(.settings) else { return }
        enqueueDeletes(recordType: RecordType.scraperConfig, ids: [id])
    }

    /// Coalesce playback-history pushes — at most once per 5 minutes.
    func playbackHistoryChanged() {
        guard isStarted, !isApplyingRemote else { return }
        guard CloudSyncChannel.isEnabled(.playbackHistory) else { return }
        guard pendingHistoryFlush == nil else { return }

        pendingHistoryFlush = Task { [weak self] in
            try? await Task.sleep(for: Self.historyThrottle)
            guard let self else { return }
            self.pendingHistoryFlush = nil
            self.enqueueSaves(
                recordType: RecordType.playbackHistory,
                ids: [Self.playbackHistoryRecordName]
            )
        }
    }

    /// Maps a CloudKit record type to the channel that controls it. Used to
    /// gate inbound (apply-remote) processing.
    private static func channel(for recordType: String) -> CloudSyncChannel? {
        switch recordType {
        case RecordType.playlist: return .playlists
        case RecordType.musicSource: return .sources
        case RecordType.playbackHistory: return .playbackHistory
        case RecordType.scraperConfig: return .settings
        default: return nil
        }
    }

    // MARK: - Internal helpers

    private func enqueueSaves(recordType: String, ids: [String]) {
        guard let engine, isStarted, !isApplyingRemote else { return }
        let changes = ids.map { id in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(recordType: recordType, id: id))
        }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    private func enqueueDeletes(recordType: String, ids: [String]) {
        guard let engine, isStarted, !isApplyingRemote else { return }
        let changes = ids.map { id in
            CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID(recordType: recordType, id: id))
        }
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    private func recordID(recordType: String, id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(recordType)/\(id)", zoneID: Self.zoneID)
    }

    /// On first start, push everything we have locally — including soft-deleted
    /// tombstones — so the engine can de-dupe against existing server records
    /// via change tags.
    private func scheduleInitialUpload() {
        playlistsChanged(ids: library.allPlaylists.map(\.id))
        sourcesChanged(ids: sourcesStore.allSources.map(\.id))
        scraperConfigsChanged(ids: scraperConfigStore.allConfigsIncludingDeleted.map(\.id))
        // Push history at startup too (bypass throttle once).
        enqueueSaves(recordType: RecordType.playbackHistory, ids: [Self.playbackHistoryRecordName])
    }

    // MARK: - State persistence

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    fileprivate func saveStateSerialization(_ state: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - Record (de)serialization

    fileprivate func populateRecord(_ record: CKRecord, recordType: String, id: String) -> Bool {
        switch recordType {
        case RecordType.playlist:
            return populatePlaylistRecord(record, playlistID: id)
        case RecordType.musicSource:
            return populateSourceRecord(record, sourceID: id)
        case RecordType.scraperConfig:
            return populateScraperConfigRecord(record, configID: id)
        case RecordType.playbackHistory:
            return populatePlaybackHistoryRecord(record)
        default:
            return false
        }
    }

    fileprivate func applyRemoteRecord(_ record: CKRecord) {
        if let channel = Self.channel(for: record.recordType),
           !CloudSyncChannel.isEnabled(channel) {
            return
        }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        switch record.recordType {
        case RecordType.playlist:
            applyPlaylistRecord(record)
        case RecordType.musicSource:
            applySourceRecord(record)
        case RecordType.scraperConfig:
            applyScraperConfigRecord(record)
        case RecordType.playbackHistory:
            applyPlaybackHistoryRecord(record)
        default:
            break
        }
    }

    fileprivate func applyRemoteDeletion(recordID: CKRecord.ID, recordType: String) {
        if let channel = Self.channel(for: recordType),
           !CloudSyncChannel.isEnabled(channel) {
            return
        }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        guard let id = parseLocalID(from: recordID, recordType: recordType) else { return }
        switch recordType {
        case RecordType.playlist:
            library.deletePlaylistFromRemote(id: id)
        case RecordType.musicSource:
            sourcesStore.removeFromRemote(id: id)
        case RecordType.scraperConfig:
            scraperConfigStore.deleteFromRemote(id: id)
        case RecordType.playbackHistory:
            library.clearPlaybackHistory()
        default:
            break
        }
    }

    private func parseLocalID(from recordID: CKRecord.ID, recordType: String) -> String? {
        let prefix = "\(recordType)/"
        guard recordID.recordName.hasPrefix(prefix) else { return nil }
        return String(recordID.recordName.dropFirst(prefix.count))
    }

    // MARK: - Playlist mapping

    private func populatePlaylistRecord(_ record: CKRecord, playlistID: String) -> Bool {
        guard let playlist = library.playlist(id: playlistID) else { return false }
        record["name"] = playlist.name
        record["createdAt"] = playlist.createdAt
        record["updatedAt"] = playlist.updatedAt
        if let cover = playlist.coverArtPath { record["coverArtPath"] = cover }
        record["songIDs"] = library.rawSongIDs(forPlaylist: playlistID)
        return true
    }

    private func applyPlaylistRecord(_ record: CKRecord) {
        guard let id = parseLocalID(from: record.recordID, recordType: RecordType.playlist),
              let name = record["name"] as? String,
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else { return }
        let coverArtPath = record["coverArtPath"] as? String
        let songIDs = (record["songIDs"] as? [String]) ?? []
        library.applyRemotePlaylist(
            Playlist(id: id, name: name, createdAt: createdAt, updatedAt: updatedAt, coverArtPath: coverArtPath),
            songIDs: songIDs
        )
    }

    // MARK: - Music source mapping

    private func populateSourceRecord(_ record: CKRecord, sourceID: String) -> Bool {
        guard let source = sourcesStore.source(id: sourceID) else { return false }
        do {
            let data = try JSONEncoder().encode(SyncableSource(source: source))
            record["payload"] = data
            record["updatedAt"] = source.modifiedAt
            return true
        } catch {
            plog("CloudKitSync: encode source failed: \(error.localizedDescription)")
            return false
        }
    }

    private func applySourceRecord(_ record: CKRecord) {
        guard let data = record["payload"] as? Data,
              let syncable = try? JSONDecoder().decode(SyncableSource.self, from: data) else { return }
        sourcesStore.upsertFromRemote(syncable.source)
    }

    // MARK: - Scraper config mapping

    private func populateScraperConfigRecord(_ record: CKRecord, configID: String) -> Bool {
        guard let config = scraperConfigStore.config(for: configID) else { return false }
        do {
            let data = try JSONEncoder().encode(config)
            record["payload"] = data
            record["updatedAt"] = config.modifiedAt ?? .distantPast
            return true
        } catch {
            plog("CloudKitSync: encode scraper config failed: \(error.localizedDescription)")
            return false
        }
    }

    private func applyScraperConfigRecord(_ record: CKRecord) {
        guard let data = record["payload"] as? Data,
              let config = try? JSONDecoder().decode(ScraperConfig.self, from: data) else { return }
        scraperConfigStore.applyRemoteConfig(config)
        scraperSettingsStore.ensureCustomSourcePresent(for: config)
    }

    // MARK: - Playback history mapping

    private func populatePlaybackHistoryRecord(_ record: CKRecord) -> Bool {
        record["songIDs"] = library.recentPlaybackSongIDsForSync
        record["updatedAt"] = Date()
        return true
    }

    private func applyPlaybackHistoryRecord(_ record: CKRecord) {
        guard let songIDs = record["songIDs"] as? [String] else { return }
        library.applyRemotePlaybackHistory(songIDs: songIDs)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudKitSyncService: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            await MainActor.run { self.saveStateSerialization(event.stateSerialization) }
        case .fetchedRecordZoneChanges(let event):
            for modification in event.modifications {
                await MainActor.run { self.applyRemoteRecord(modification.record) }
            }
            for deletion in event.deletions {
                await MainActor.run {
                    self.applyRemoteDeletion(recordID: deletion.recordID, recordType: deletion.recordType)
                }
            }
        case .sentRecordZoneChanges(let event):
            for failed in event.failedRecordSaves {
                await MainActor.run {
                    self.handleFailedSave(failed, syncEngine: syncEngine)
                }
            }
        case .accountChange(let change):
            await MainActor.run { self.handleAccountChange(change) }
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run { self.makeRecord(for: recordID) }
        }
    }

    @MainActor
    fileprivate func handleFailedSave(
        _ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) {
        let recordID = failed.record.recordID
        guard let ckError = failed.error as? CKError else {
            plog("CloudKitSync: unhandled save error: \(failed.error.localizedDescription)")
            return
        }

        switch ckError.code {
        case .serverRecordChanged:
            resolveServerRecordChanged(local: failed.record, error: ckError, syncEngine: syncEngine)
        case .zoneNotFound, .userDeletedZone:
            // Re-create the zone and try again.
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: recordID.zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .unknownItem:
            // Server-side record went away (deleted on another device). Mirror
            // that locally so the two sides line up.
            applyRemoteDeletion(recordID: recordID, recordType: failed.record.recordType)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // Engine retries automatically; honor any explicit retry-after.
            if let retry = ckError.retryAfterSeconds {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(retry))
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
            }
        case .quotaExceeded:
            status = .quotaExceeded
        case .notAuthenticated:
            status = .accountUnavailable(.noAccount)
        default:
            plog("CloudKitSync: unhandled save error code \(ckError.code.rawValue): \(ckError.localizedDescription)")
        }
    }

    /// Last-writer-wins on `updatedAt`. If the server copy is newer we apply it
    /// locally and let the local save get dropped; otherwise we re-enqueue —
    /// CKSyncEngine carries the server's new changeTag forward so the next save
    /// won't conflict.
    @MainActor
    private func resolveServerRecordChanged(
        local: CKRecord,
        error: CKError,
        syncEngine: CKSyncEngine
    ) {
        guard let server = error.serverRecord else {
            // No server record provided — naive re-queue.
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
            return
        }

        let localUpdated = (local["updatedAt"] as? Date) ?? .distantPast
        let serverUpdated = (server["updatedAt"] as? Date) ?? .distantPast

        if serverUpdated >= localUpdated {
            // Server wins — drop the local save and apply the server version.
            applyRemoteRecord(server)
        } else {
            // Local wins — re-enqueue the save.
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(local.recordID)])
        }
    }

    @MainActor
    private func makeRecord(for recordID: CKRecord.ID) -> CKRecord? {
        let parts = recordID.recordName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let recordType = parts[0]
        let localID = parts[1]
        let record = CKRecord(recordType: recordType, recordID: recordID)
        guard populateRecord(record, recordType: recordType, id: localID) else {
            return nil
        }
        return record
    }

    @MainActor
    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut, .switchAccounts:
            // Drop the local engine state — the new account starts fresh.
            try? FileManager.default.removeItem(at: stateURL)
            engine = nil
            isStarted = false
        case .signIn:
            Task { await self.start() }
        @unknown default:
            break
        }
    }
}

// MARK: - Sync payloads

/// Sources are written to CloudKit minus their device-local fields (`lastScannedAt`,
/// `songCount`) so a freshly-synced device doesn't inherit a stale scan state.
private struct SyncableSource: Codable {
    var source: MusicSource

    init(source: MusicSource) {
        var copy = source
        copy.lastScannedAt = nil
        copy.songCount = 0
        self.source = copy
    }
}

private extension CKError {
    var retryAfterSeconds: Double? {
        userInfo[CKErrorRetryAfterKey] as? Double
    }
}

private extension Error {
    var retryAfterSeconds: Double? {
        (self as? CKError)?.retryAfterSeconds
    }
}
