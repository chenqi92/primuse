import Foundation
import PrimuseKit

@MainActor
@Observable
final class SourcesStore {
    enum PermanentDeleteResult: Equatable {
        case deleted
        case sourceNotFound
        case credentialCleanupFailed
        case deletionLedgerPersistFailed
    }

    /// Backing storage including soft-deleted entries. `sources` filters this
    /// for normal UI use; `recentlyDeletedSources` exposes the deleted ones.
    private(set) var allSources: [MusicSource]

    /// Live (non-deleted) sources for normal UI use.
    var sources: [MusicSource] { allSources.filter { !$0.isDeleted } }

    /// Deletion evidence lives independently from user-facing source rows so a
    /// permanent prune cannot make an old CloudKit record eligible to restore.
    private(set) var sourceDeletionRecords: [MusicSourceDeletionRecord]

    var sourceDeletionIDs: [String] { sourceDeletionRecords.map(\.id) }

    /// Soft-deleted sources, newest deletion first.
    var recentlyDeletedSources: [MusicSource] {
        allSources
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Source tombstones whose required credential cleanup failed during this
    /// run. Keeping this observable lets both automatic pruning and manual
    /// deletion surface a retry target in Recently Deleted.
    private(set) var permanentDeletionFailureIDs: Set<String> = []

    /// CloudAccount entities owning OAuth-typed mounts. Persisted to a
    /// sibling JSON file (`cloudAccounts.json`). Stage 2 keeps this
    /// internal — UI doesn't read from it yet; stage 4 will wire OAuth
    /// to consult this list before minting a new mount, eliminating
    /// duplicate-account-from-reconnect.
    private(set) var allAccounts: [CloudAccount]

    /// Live (non-deleted) accounts.
    var accounts: [CloudAccount] { allAccounts.filter { !$0.isDeleted } }

    private let storeURL: URL
    private let accountsURL: URL
    private let sourceDeletionsURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        // tvOS 只允许写 Caches / tmp;须与 LibrarySnapshotSync / MusicLibrary 同目录。
        #if os(tvOS)
        let appSupport = fileManager.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let appSupport = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.storeURL = directory.appendingPathComponent("sources.json")
        self.accountsURL = directory.appendingPathComponent("cloudAccounts.json")
        self.sourceDeletionsURL = directory.appendingPathComponent(MusicSourceDeletionRecord.fileName)
        self.allSources = []
        self.allAccounts = []
        self.sourceDeletionRecords = []

        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
        loadSourceDeletions()
        migrateSourceTombstonesIntoDeletionLedger()
        reconcileSourcesWithDeletionLedger()
        pruneForeignDeviceLocalSources()
        loadAccounts()
    }

    func source(id: String) -> MusicSource? {
        allSources.first(where: { $0.id == id })
    }

    /// tvOS 下载到新 sources.json 后重新从磁盘加载。
    func reloadFromDisk() {
        load()
        loadSourceDeletions()
        migrateSourceTombstonesIntoDeletionLedger()
        reconcileSourcesWithDeletionLedger()
        pruneForeignDeviceLocalSources()
        loadAccounts()
    }

    func sourceDeletionRecord(id: String) -> MusicSourceDeletionRecord? {
        sourceDeletionRecords.first(where: { $0.id == id })
    }

    func registerDeletionTombstone(_ tombstone: MusicSource) {
        guard tombstone.isDeleted else { return }
        let deletion = MusicSourceDeletionRecord(tombstone: tombstone)
        if let active = allSources.first(where: { $0.id == tombstone.id && !$0.isDeleted }),
           MusicSourceLifecyclePolicy.isExplicitRestore(active, after: deletion) {
            return
        }
        recordSourceDeletion(tombstone: tombstone)
        if reconcileSourcesWithDeletionLedger().contains(tombstone.id) {
            notifyChanged([tombstone.id])
        }
    }

    func add(_ source: MusicSource) {
        upsert(source)
    }

    /// Adds a source only after `sources.json` has been atomically persisted.
    /// The Files import path uses this before starting a scan so an out-of-space
    /// error cannot leave a source that exists only in memory.
    func addDurably(_ source: MusicSource) throws {
        let previousSources = allSources
        let previousDeletionRecords = sourceDeletionRecords
        applyUpsert(source)
        do {
            try persistThrowing()
        } catch {
            allSources = previousSources
            sourceDeletionRecords = previousDeletionRecords
            _ = persistSourceDeletions()
            throw error
        }
        notifyChanged([source.id])
    }

    func upsert(_ source: MusicSource) {
        applyUpsert(source)
        persist()
        notifyChanged([source.id])
    }

    private func applyUpsert(_ source: MusicSource) {
        var stamped = source
        let selectedDirectories = Set(stamped.scannedDirectories)
        stamped.scannedDirectoryDisplayNames = stamped.scannedDirectoryDisplayNames.filter {
            selectedDirectories.contains($0.key)
        }
        let now = Date()
        stamped.modifiedAt = now
        if !stamped.isDeleted,
           let deletion = sourceDeletionRecord(id: stamped.id),
           !MusicSourceLifecyclePolicy.isExplicitRestore(stamped, after: deletion) {
            stamped.restoredAt = now
        }
        if !stamped.isDeleted {
            removeSourceDeletionRecord(id: stamped.id)
        }
        if let index = allSources.firstIndex(where: { $0.id == stamped.id }) {
            allSources[index] = stamped
        } else {
            allSources.append(stamped)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    /// User-facing edit. Bumps `modifiedAt` and triggers an iCloud sync push.
    func update(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return }
        mutate(&allSources[index])
        let selectedDirectories = Set(allSources[index].scannedDirectories)
        allSources[index].scannedDirectoryDisplayNames = allSources[index]
            .scannedDirectoryDisplayNames.filter { selectedDirectories.contains($0.key) }
        allSources[index].modifiedAt = Date()
        persist()
        notifyChanged([sourceID])
    }

    /// Device-local update — used by the scanner for fields that are derived
    /// state (`lastScannedAt`, `songCount`, `deviceId`). Persists to disk but
    /// does not bump `modifiedAt` or notify the cloud sync.
    func updateLocal(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return }
        mutate(&allSources[index])
        persist()
    }

    /// Merge provider-supplied directory labels into the source payload so the
    /// mapping survives a new device, reinstall, or source resurrection.
    func mergeDirectoryDisplayNames(_ names: [String: String], sourceID: String) {
        guard !names.isEmpty,
              let index = allSources.firstIndex(where: { $0.id == sourceID }),
              !allSources[index].isDeleted else { return }
        let selectedDirectories = Set(allSources[index].scannedDirectories)
        var changed = false
        for (path, rawName) in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard selectedDirectories.contains(path), !name.isEmpty,
                  allSources[index].scannedDirectoryDisplayNames[path] != name else { continue }
            allSources[index].scannedDirectoryDisplayNames[path] = name
            changed = true
        }
        guard changed else { return }
        allSources[index].modifiedAt = Date()
        persist()
        notifyChanged([sourceID])
    }

    /// Reconcile the per-source counter with the songs that are actually
    /// present in the local library. `songCount` is device-local derived
    /// state, so a sources snapshot can legitimately outlive (or arrive
    /// before) the matching library snapshot. Updating every row in one pass
    /// prevents stale historical counts from being shown as if they were the
    /// current visible library size.
    func reconcileLocalSongCounts(_ countsBySourceID: [String: Int]) {
        var changed = false
        for index in allSources.indices where !allSources[index].isDeleted {
            let actualCount = countsBySourceID[allSources[index].id] ?? 0
            guard allSources[index].songCount != actualCount else { continue }
            allSources[index].songCount = actualCount
            changed = true
        }
        if changed { persist() }
    }

    /// Reset scan-derived state for a batch of removed sources with one
    /// Observable mutation/persist instead of rewriting sources.json per row.
    func resetLocalScanState(for sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        var changed = false
        for index in allSources.indices where sourceIDs.contains(allSources[index].id) {
            if allSources[index].songCount != 0 || allSources[index].lastScannedAt != nil {
                allSources[index].songCount = 0
                allSources[index].lastScannedAt = nil
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Source delete: hide from UI, keep the row for recycle-bin recovery,
    /// and persist the tombstone independently so CloudKit cursor resets and
    /// snapshot replay cannot reinterpret a missing row as a restore. This is
    /// not used by the enable/disable toggle.
    func remove(id: String) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        permanentDeletionFailureIDs.remove(id)
        allSources[index].isDeleted = true
        let deletedAt = Date()
        allSources[index].deletedAt = deletedAt
        allSources[index].modifiedAt = deletedAt
        let tombstone = allSources[index]
        recordSourceDeletion(tombstone: tombstone)
        persist()
        // notifyChanged drives UI refresh; the dedicated signal lets the
        // durable cleanup journal track CloudKit tombstone acknowledgement,
        // snapshot propagation and credential removal independently.
        notifyChanged([id])
        NotificationCenter.default.post(
            name: .primuseSourceDidSoftDelete,
            object: nil,
            userInfo: ["id": id, "source": tombstone]
        )
    }

    /// Restore a soft-deleted source from the recycle bin.
    func restore(id: String) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        permanentDeletionFailureIDs.remove(id)
        let restoredAt = Date()
        allSources[index].isDeleted = false
        allSources[index].deletedAt = nil
        allSources[index].restoredAt = restoredAt
        allSources[index].modifiedAt = restoredAt
        removeSourceDeletionRecord(id: id)
        persist()
        notifyChanged([id])
    }

    /// Permanently remove a source (manual purge or 30-day prune).
    @discardableResult
    func permanentlyDelete(id: String) -> PermanentDeleteResult {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else {
            permanentDeletionFailureIDs.remove(id)
            return .sourceNotFound
        }
        let tombstone = allSources[index]
        guard recordSourceDeletion(tombstone: tombstone) else {
            permanentDeletionFailureIDs.insert(id)
            plog("⛔ Source permanent delete deferred: deletion ledger persist failed id=\(id.prefix(8))…")
            return .deletionLedgerPersistFailed
        }

        // Irreversible credential / token cleanup belongs here, not on a view
        // observer: both the manual "delete forever" action and the launch-time
        // 30-day prune funnel through permanentlyDelete, whereas the
        // .primuseSourceDidDelete listener only fires while a Sources view is
        // mounted — pruning at launch (or deleting from another window) would
        // otherwise orphan Keychain passwords, OAuth tokens and cached
        // directory names. These removals key off the source id alone, are
        // no-ops for non-cloud sources, and are idempotent, so the remaining
        // view-layer listener (which still wipes song records / source caches
        // it owns the instances for) can re-run them harmlessly.
        // Keep the soft-deleted row until every persisted credential is gone.
        // If Keychain is locked or otherwise unavailable, the tombstone remains
        // in Recently Deleted and the user (or next prune pass) can retry.
        guard purgeCredentials(for: allSources[index]) else {
            permanentDeletionFailureIDs.insert(id)
            plog("⛔ Source permanent delete deferred: credential cleanup failed id=\(id.prefix(8))…")
            return .credentialCleanupFailed
        }

        permanentDeletionFailureIDs.remove(id)
        allSources.remove(at: index)
        persist()
        NotificationCenter.default.post(
            name: .primuseSourceDidDelete,
            object: nil,
            userInfo: ["id": id, "source": tombstone]
        )
        return .deleted
    }

    /// Tear down the persisted secrets and per-source storage owned outside the
    /// source row itself: Keychain passwords, cloud OAuth tokens + app
    /// credentials, security-scoped bookmarks (macOS only) and cloud directory
    /// display names. Idempotent and safe to call for any source type.
    private func purgeCredentials(for source: MusicSource) -> Bool {
        // KeychainService / CloudTokenManager / CloudDirectoryNameStore 仅存在于
        // iOS/macOS app target;tvOS 共享本文件但用 TVCredentialStore,无这些凭据存储。
        #if os(iOS) || os(macOS)
        let requiredStores = SourcePermanentDeletionPolicy.requiredCredentialStores(
            for: source.type,
            authType: source.authType
        )
        let passwordDeleted = !requiredStores.contains(.password)
            || KeychainService.deletePassword(for: source.id)
        let fnConnectAccessCodeDeleted = source.type != .fnMusic
            || KeychainService.deletePassword(
                for: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: source.id)
            )
        let cloudCredentialsDeleted = !requiredStores.contains(.cloudCredentials)
            || CloudTokenManager.deleteStoredCredentials(for: source.id)
        guard SourcePermanentDeletionPolicy.canRemoveTombstone(
            requiredStores: requiredStores,
            passwordDeleted: passwordDeleted,
            cloudCredentialsDeleted: cloudCredentialsDeleted
        ), fnConnectAccessCodeDeleted else { return false }
        #if os(macOS)
        LocalBookmarkStore.remove(sourceID: source.id)
        #endif
        CloudDirectoryNameStore.deleteAll(for: source.id)
        #endif
        return true
    }

    /// Sweep soft-deleted sources older than `threshold` and remove them for
    /// good. Called on launch with a 30-day threshold.
    @discardableResult
    func pruneSources(deletedBefore threshold: Date) -> [String: PermanentDeleteResult] {
        let toPrune = allSources.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        var results: [String: PermanentDeleteResult] = [:]
        for source in toPrune {
            results[source.id] = permanentlyDelete(id: source.id)
        }
        return results
    }

    /// Apply a remote delete event as a tombstone. The notification keeps
    /// local UI caches in sync; CloudKit suppresses echo saves while applying
    /// remote changes.
    func removeFromRemote(id: String) {
        markDeletedFromRemote(id: id)
    }

    /// Preserve a remote delete as a local tombstone instead of physically
    /// dropping the row. Snapshot sync can arrive later with an older
    /// `sources.json`; without the tombstone there is no evidence that the
    /// source was deleted, so the stale active row can come back.
    func markDeletedFromRemote(id: String, at deletedAt: Date = Date()) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else {
            recordSourceDeletion(id: id, deletedAt: deletedAt)
            return
        }
        if allSources[index].isDeleted {
            if (allSources[index].deletedAt ?? .distantPast) < deletedAt {
                allSources[index].deletedAt = deletedAt
                allSources[index].modifiedAt = max(allSources[index].modifiedAt, deletedAt)
                recordSourceDeletion(tombstone: allSources[index])
                persist()
                notifyChanged([id])
            } else {
                recordSourceDeletion(tombstone: allSources[index])
            }
            return
        }
        allSources[index].isDeleted = true
        allSources[index].deletedAt = deletedAt
        allSources[index].modifiedAt = max(allSources[index].modifiedAt, deletedAt)
        let tombstone = allSources[index]
        recordSourceDeletion(tombstone: tombstone)
        persist()
        notifyChanged([id])
        NotificationCenter.default.post(
            name: .primuseSourceDidSoftDelete,
            object: nil,
            userInfo: ["id": id, "source": tombstone]
        )
    }

    /// Apply a source pulled from CloudKit. Preserves device-local fields
    /// (`lastScannedAt`, `songCount`, `deviceId`) on the existing record if any.
    ///
    /// Last-writer-wins on `modifiedAt`: if the local copy was edited
    /// MORE recently than the remote, we keep the local. Without this
    /// guard, a `DidFetchRecordZoneChanges` event that arrives moments
    /// after the user toggled a directory selection would overwrite the
    /// fresh local edit with the older server payload — observable in
    /// the UI as "checkbox self-deselects ~1 second after tapping".
    /// The push path already does LWW (see `resolveServerRecordChanged`
    /// on the conflict path); the fetch path was the missing half.
    func upsertFromRemote(_ remote: MusicSource) {
        guard MusicSourceCloudSyncPolicy.isEligible(remote) else { return }
        if remote.isDeleted {
            let incomingDeletion = MusicSourceDeletionRecord(tombstone: remote)
            if let existing = allSources.first(where: { $0.id == remote.id }),
               !existing.isDeleted,
               MusicSourceLifecyclePolicy.isExplicitRestore(existing, after: incomingDeletion) {
                return
            }

            recordSourceDeletion(tombstone: remote)
            guard let index = allSources.firstIndex(where: { $0.id == remote.id }) else {
                return
            }
            if allSources[index].isDeleted,
               MusicSourceLifecyclePolicy.winner(
                   local: allSources[index],
                   remote: remote
               ) == .local {
                return
            }
            let wasActive = !allSources[index].isDeleted
            var merged = remote
            merged.lastScannedAt = allSources[index].lastScannedAt
            merged.songCount = allSources[index].songCount
            merged.deviceId = allSources[index].deviceId
            allSources[index] = merged
            persist()
            notifyChanged([remote.id])
            if wasActive {
                NotificationCenter.default.post(
                    name: .primuseSourceDidSoftDelete,
                    object: nil,
                    userInfo: ["id": remote.id, "source": merged]
                )
            }
            return
        }

        let restoresRecordedDeletion: Bool
        if let deletion = sourceDeletionRecord(id: remote.id) {
            guard MusicSourceLifecyclePolicy.isExplicitRestore(remote, after: deletion) else {
                return
            }
            restoresRecordedDeletion = true
        } else {
            restoresRecordedDeletion = false
        }

        if let existing = allSources.first(where: { $0.id == remote.id }) {
            if existing.isDeleted && !remote.isDeleted {
                let deletion = MusicSourceDeletionRecord(tombstone: existing)
                if !MusicSourceLifecyclePolicy.isExplicitRestore(remote, after: deletion) {
                    return
                }
            }
            if Self.sourceClock(existing) > Self.sourceClock(remote) {
                // Local has unsent edits that are newer — keep them.
                // CloudKit will push them on the next sendChanges.
                return
            }
            var merged = remote
            merged.lastScannedAt = existing.lastScannedAt
            merged.songCount = existing.songCount
            // Synology's trusted-device token belongs to this physical
            // device. A remote source edit must not erase it or replace it
            // with another device's token, otherwise the next scan needlessly
            // falls back to password + TOTP.
            merged.deviceId = existing.deviceId
            if let index = allSources.firstIndex(where: { $0.id == merged.id }) {
                allSources[index] = merged
            }
        } else {
            // Don't reanimate a record the server has marked deleted.
            // Stage 4's migration may push tombstones up; once the
            // 30-day prune sweeps them, they shouldn't reappear here.
            if remote.isDeleted { return }
            var sanitized = remote
            sanitized.deviceId = nil
            allSources.append(sanitized)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        if restoresRecordedDeletion {
            removeSourceDeletionRecord(id: remote.id)
        }
        persist()
        notifyChanged([remote.id])
    }

    private func notifyChanged(_ ids: [String]) {
        NotificationCenter.default.post(
            name: .primuseSourcesDidChange,
            object: nil,
            userInfo: ["ids": ids]
        )
    }

    private static func sourceClock(_ source: MusicSource) -> Date {
        MusicSourceLifecyclePolicy.lifecycleClock(source)
    }

    @discardableResult
    private func recordSourceDeletion(tombstone: MusicSource) -> Bool {
        recordSourceDeletion(MusicSourceDeletionRecord(tombstone: tombstone))
    }

    @discardableResult
    private func recordSourceDeletion(id: String, deletedAt: Date) -> Bool {
        recordSourceDeletion(MusicSourceDeletionRecord(id: id, deletedAt: deletedAt))
    }

    @discardableResult
    private func recordSourceDeletion(_ incoming: MusicSourceDeletionRecord) -> Bool {
        if let index = sourceDeletionRecords.firstIndex(where: { $0.id == incoming.id }) {
            sourceDeletionRecords[index] = MusicSourceLifecyclePolicy.coalescing(
                current: sourceDeletionRecords[index],
                incoming: incoming
            )
        } else {
            sourceDeletionRecords.append(incoming)
            sourceDeletionRecords.sort { $0.id < $1.id }
        }
        return persistSourceDeletions()
    }

    private func removeSourceDeletionRecord(id: String) {
        guard sourceDeletionRecords.contains(where: { $0.id == id }) else { return }
        sourceDeletionRecords.removeAll { $0.id == id }
        persistSourceDeletions()
    }

    private func loadSourceDeletions() {
        guard let data = try? Data(contentsOf: sourceDeletionsURL) else {
            sourceDeletionRecords = []
            return
        }
        do {
            let decoded = try decoder.decode([MusicSourceDeletionRecord].self, from: data)
            var merged: [String: MusicSourceDeletionRecord] = [:]
            for record in decoded {
                merged[record.id] = MusicSourceLifecyclePolicy.coalescing(
                    current: merged[record.id],
                    incoming: record
                )
            }
            sourceDeletionRecords = merged.values.sorted { $0.id < $1.id }
        } catch {
            backupCorruptStore(at: sourceDeletionsURL, data: data, error: error)
            sourceDeletionRecords = []
        }
    }

    private func migrateSourceTombstonesIntoDeletionLedger() {
        var changed = false
        for source in allSources where source.isDeleted {
            let incoming = MusicSourceDeletionRecord(tombstone: source)
            if let index = sourceDeletionRecords.firstIndex(where: { $0.id == source.id }) {
                let merged = MusicSourceLifecyclePolicy.coalescing(
                    current: sourceDeletionRecords[index],
                    incoming: incoming
                )
                if merged != sourceDeletionRecords[index] {
                    sourceDeletionRecords[index] = merged
                    changed = true
                }
            } else {
                sourceDeletionRecords.append(incoming)
                changed = true
            }
        }
        guard changed else { return }
        sourceDeletionRecords.sort { $0.id < $1.id }
        persistSourceDeletions()
    }

    @discardableResult
    private func reconcileSourcesWithDeletionLedger() -> [String] {
        var changedSourceIDs: [String] = []
        var restoredIDs = Set<String>()
        var refreshedDeletions: [MusicSourceDeletionRecord] = []

        for index in allSources.indices {
            let source = allSources[index]
            guard !source.isDeleted,
                  let deletion = sourceDeletionRecord(id: source.id) else { continue }
            if MusicSourceLifecyclePolicy.isExplicitRestore(source, after: deletion) {
                restoredIDs.insert(source.id)
                continue
            }

            var tombstone = deletion.tombstone ?? source
            tombstone.isDeleted = true
            tombstone.deletedAt = deletion.deletedAt
            tombstone.modifiedAt = max(tombstone.modifiedAt, deletion.deletedAt)
            tombstone.lastScannedAt = source.lastScannedAt
            tombstone.songCount = source.songCount
            tombstone.deviceId = source.deviceId
            allSources[index] = tombstone
            refreshedDeletions.append(MusicSourceDeletionRecord(tombstone: tombstone))
            changedSourceIDs.append(source.id)
        }

        if !restoredIDs.isEmpty {
            sourceDeletionRecords.removeAll { restoredIDs.contains($0.id) }
        }
        for incoming in refreshedDeletions {
            if let index = sourceDeletionRecords.firstIndex(where: { $0.id == incoming.id }) {
                sourceDeletionRecords[index] = MusicSourceLifecyclePolicy.coalescing(
                    current: sourceDeletionRecords[index],
                    incoming: incoming
                )
            }
        }
        if !restoredIDs.isEmpty || !refreshedDeletions.isEmpty {
            sourceDeletionRecords.sort { $0.id < $1.id }
            persistSourceDeletions()
        }
        if !changedSourceIDs.isEmpty {
            persist()
        }
        return changedSourceIDs
    }

    /// Removes rows that older CloudKit builds copied from another device.
    /// This is intentionally a silent local migration: creating a tombstone or
    /// posting a sync notification could delete the real source on its owner.
    private func pruneForeignDeviceLocalSources() {
        #if os(iOS)
        let ownedSourceIDs = LocalImportService.existingSourceID
            .map { Set([$0]) } ?? []
        let foreignSourceIDs = MusicSourceCloudSyncPolicy.foreignDeviceLocalSourceIDs(
            in: allSources,
            ownedSourceIDs: ownedSourceIDs
        )
        let foreignDeletionIDs: Set<String> = Set(sourceDeletionRecords.lazy.compactMap { record -> String? in
            guard let tombstone = record.tombstone,
                  MusicSourceCloudSyncPolicy.isDeviceLocal(tombstone),
                  !ownedSourceIDs.contains(record.id) else { return nil }
            return record.id
        })
        let removedIDs = foreignSourceIDs.union(foreignDeletionIDs)
        guard !removedIDs.isEmpty else { return }

        allSources.removeAll { foreignSourceIDs.contains($0.id) }
        sourceDeletionRecords.removeAll { foreignDeletionIDs.contains($0.id) }
        persist()
        if !foreignDeletionIDs.isEmpty {
            _ = persistSourceDeletions()
        }
        plog("SourcesStore: pruned \(removedIDs.count) foreign device-local source(s)")
        #endif
    }

    @discardableResult
    private func persistSourceDeletions() -> Bool {
        do {
            let data = try encoder.encode(sourceDeletionRecords)
            try data.write(to: sourceDeletionsURL, options: .atomic)
            return true
        } catch {
            plog("⛔ Source deletion ledger persist failed — \(error.localizedDescription)")
            return false
        }
    }

    private func load() {
        // File-not-present is the normal first-launch case — start empty and
        // let the first add/upsert write a fresh sources.json.
        guard let data = try? Data(contentsOf: storeURL) else {
            allSources = []
            return
        }
        do {
            let decoded = try decoder.decode([MusicSource].self, from: data)
            allSources = decoded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        } catch {
            // The file exists but is undecodable as a whole (corruption, an
            // incompatible future schema after a downgrade, a single malformed
            // row, …). Don't blindly empty the list — the very next persist()
            // would atomically overwrite the user's entire source config and
            // make the loss permanent. Try a per-element tolerant decode first
            // so one bad row only drops that row, and back up the original
            // bytes before anything else can clobber them.
            backupCorruptStore(at: storeURL, data: data, error: error)
            allSources = recoverPartial(MusicSource.self, from: data)
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    private func persist() {
        do {
            try persistThrowing()
        } catch {
            plog("⛔ Sources persist failed — \(error.localizedDescription)")
        }
    }

    private func persistThrowing() throws {
        let data = try encoder.encode(allSources)
        try data.write(to: storeURL, options: .atomic)
    }

    // MARK: - CloudAccount CRUD (stage 2: internal, not exposed to UI)

    /// Lookup by deterministic id. Same as `allAccounts.first(where:)`
    /// but spelled out for readability at call sites.
    func account(id: String) -> CloudAccount? {
        allAccounts.first(where: { $0.id == id })
    }

    /// Lookup by upstream identity. Used by the OAuth flow (stage 4) to
    /// ask "do I already have this Baidu account?" before minting a new
    /// mount. Includes soft-deleted rows so a user re-signing-in to a
    /// recently-deleted account can resurrect rather than duplicate.
    func account(provider: MusicSourceType, accountUID: String) -> CloudAccount? {
        let id = CloudAccount.deriveID(provider: provider, accountUID: accountUID)
        return allAccounts.first(where: { $0.id == id })
    }

    /// Insert or update. Bumps `modifiedAt` so the LWW resolver picks
    /// this edit on the next CloudKit sync. No-op if the deterministic
    /// id collides — by construction that means same upstream account.
    func upsertAccount(_ account: CloudAccount) {
        var stamped = account
        stamped.modifiedAt = Date()
        if let index = allAccounts.firstIndex(where: { $0.id == stamped.id }) {
            allAccounts[index] = stamped
        } else {
            allAccounts.append(stamped)
        }
        persistAccounts()
        NotificationCenter.default.post(
            name: .primuseCloudAccountsDidChange,
            object: nil,
            userInfo: ["ids": [stamped.id]]
        )
    }

    /// Soft-delete: hide the account from `accounts`, but the row stays
    /// on disk for recycle-bin recovery. CloudKit gets a real
    /// `deleteRecord` (via the soft-delete notification) so the upstream
    /// record clears — same pattern as `remove(id:)` for sources.
    func removeAccount(id: String) {
        guard let index = allAccounts.firstIndex(where: { $0.id == id }) else { return }
        allAccounts[index].isDeleted = true
        allAccounts[index].deletedAt = Date()
        allAccounts[index].modifiedAt = Date()
        persistAccounts()
        NotificationCenter.default.post(
            name: .primuseCloudAccountsDidChange,
            object: nil,
            userInfo: ["ids": [id]]
        )
        NotificationCenter.default.post(
            name: .primuseCloudAccountDidSoftDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Permanently remove. Called by the launch-time prune (after the
    /// 30-day soft-delete grace) and by the explicit "delete forever"
    /// action in the recycle bin.
    func permanentlyDeleteAccount(id: String) {
        allAccounts.removeAll { $0.id == id }
        persistAccounts()
        NotificationCenter.default.post(
            name: .primuseCloudAccountDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Apply an account pulled from CloudKit. Mirrors `upsertFromRemote`
    /// for sources — same LWW + soft-delete-respect rules.
    func upsertAccountFromRemote(_ remote: CloudAccount) {
        if let existing = allAccounts.first(where: { $0.id == remote.id }) {
            if existing.isDeleted, existing.modifiedAt >= remote.modifiedAt { return }
            if existing.modifiedAt > remote.modifiedAt { return }
            if let index = allAccounts.firstIndex(where: { $0.id == remote.id }) {
                allAccounts[index] = remote
            }
        } else {
            if remote.isDeleted { return }
            allAccounts.append(remote)
        }
        persistAccounts()
    }

    /// Apply a remote permanent-delete event. Silent so it doesn't echo
    /// back to CloudKit.
    func removeAccountFromRemote(id: String) {
        allAccounts.removeAll { $0.id == id }
        persistAccounts()
    }

    private func loadAccounts() {
        guard let data = try? Data(contentsOf: accountsURL) else {
            allAccounts = []
            return
        }
        do {
            allAccounts = try decoder.decode([CloudAccount].self, from: data)
        } catch {
            // Same hazard as load(): a decode failure here followed by any
            // upsert/remove would persistAccounts() over the original file.
            backupCorruptStore(at: accountsURL, data: data, error: error)
            allAccounts = recoverPartial(CloudAccount.self, from: data)
        }
    }

    private func persistAccounts() {
        guard let data = try? encoder.encode(allAccounts) else { return }
        try? data.write(to: accountsURL, options: .atomic)
    }

    // MARK: - Corruption recovery

    /// Snapshot the undecodable bytes next to the store (`*.corrupt`) before
    /// the next persist() can overwrite them, so the user's config is
    /// recoverable rather than silently lost. Logs the underlying error.
    private func backupCorruptStore(at url: URL, data: Data, error: Error) {
        let backupURL = url.appendingPathExtension("corrupt")
        try? data.write(to: backupURL, options: .atomic)
        print("SourcesStore: failed to decode \(url.lastPathComponent) (\(error)); backed up to \(backupURL.lastPathComponent)")
    }

    /// Best-effort per-element decode: parse the JSON array and decode each
    /// element independently so a single malformed row drops only that row
    /// instead of nuking the whole list. Returns whatever decoded cleanly
    /// (possibly empty if the bytes aren't even a JSON array).
    private func recoverPartial<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        guard let wrapped = try? decoder.decode([FailableDecodable<T>].self, from: data) else {
            return []
        }
        return wrapped.compactMap(\.value)
    }
}

/// Decodes `T` but never throws: a per-element decode failure leaves `value`
/// nil instead of aborting the surrounding array decode.
private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(T.self)
    }
}
