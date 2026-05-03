import Foundation
import PrimuseKit

@MainActor
@Observable
final class SourcesStore {
    /// Backing storage including soft-deleted entries. `sources` filters this
    /// for normal UI use; `recentlyDeletedSources` exposes the deleted ones.
    private(set) var allSources: [MusicSource]

    /// Live (non-deleted) sources for normal UI use.
    var sources: [MusicSource] { allSources.filter { !$0.isDeleted } }

    /// Soft-deleted sources, newest deletion first.
    var recentlyDeletedSources: [MusicSource] {
        allSources
            .filter { $0.isDeleted }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        self.storeURL = directory.appendingPathComponent("sources.json")
        self.accountsURL = directory.appendingPathComponent("cloudAccounts.json")
        self.allSources = []
        self.allAccounts = []

        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
        loadAccounts()
    }

    func source(id: String) -> MusicSource? {
        allSources.first(where: { $0.id == id })
    }

    func add(_ source: MusicSource) {
        upsert(source)
    }

    func upsert(_ source: MusicSource) {
        var stamped = source
        stamped.modifiedAt = Date()
        if let index = allSources.firstIndex(where: { $0.id == stamped.id }) {
            allSources[index] = stamped
        } else {
            allSources.append(stamped)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        persist()
        notifyChanged([stamped.id])
    }

    /// User-facing edit. Bumps `modifiedAt` and triggers an iCloud sync push.
    func update(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        guard let index = allSources.firstIndex(where: { $0.id == sourceID }) else { return }
        mutate(&allSources[index])
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

    /// Soft-delete: hide from UI, keep the row on disk for recycle-bin
    /// recovery — but push a REAL deleteRecord to CloudKit so the
    /// upstream record clears. The previous "save with isDeleted=true"
    /// strategy left server records lingering, which then resurrected
    /// the source on every fetch (this is the root of the duplicate
    /// Baidu sources mess).
    func remove(id: String) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        allSources[index].isDeleted = true
        allSources[index].deletedAt = Date()
        allSources[index].modifiedAt = Date()
        persist()
        // notifyChanged drives UI refresh + recycle-bin sync; the
        // dedicated soft-delete notification tells CloudKit to enqueue
        // a deleteRecord (the saveRecord path would re-push the
        // soft-deleted record, which is what we used to do wrong).
        notifyChanged([id])
        NotificationCenter.default.post(
            name: .primuseSourceDidSoftDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Restore a soft-deleted source from the recycle bin.
    func restore(id: String) {
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        allSources[index].isDeleted = false
        allSources[index].deletedAt = nil
        allSources[index].modifiedAt = Date()
        persist()
        notifyChanged([id])
    }

    /// Permanently remove a source (manual purge or 30-day prune).
    func permanentlyDelete(id: String) {
        allSources.removeAll { $0.id == id }
        persist()
        NotificationCenter.default.post(
            name: .primuseSourceDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Sweep soft-deleted sources older than `threshold` and remove them for
    /// good. Called on launch with a 30-day threshold.
    func pruneSources(deletedBefore threshold: Date) {
        let toPrune = allSources.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        for source in toPrune {
            permanentlyDelete(id: source.id)
        }
    }

    /// Remove a source in response to a remote permanent-delete event.
    /// The notification keeps local UI caches in sync; CloudKit suppresses
    /// echo saves while applying remote changes.
    func removeFromRemote(id: String) {
        allSources.removeAll { $0.id == id }
        persist()
        notifyChanged([id])
    }

    /// Apply a source pulled from CloudKit. Preserves device-local fields
    /// (`lastScannedAt`, `songCount`) on the existing record if any.
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
        if let existing = allSources.first(where: { $0.id == remote.id }) {
            // 墓碑胜出 (tombstone wins) —— 一旦本地把源删了,就当作用户
            // 的明确意图,远端任何「alive」更新都不能让它复活。
            // 之前用 modifiedAt 比,但 iOS 端如果还在用这个源（扫描时
            // 更新 songCount 就会 bump modifiedAt),它的更新永远比
            // Mac 上的删除时刻新,导致每次 fetch 都把删的源拉回来。
            //
            // 标准做法 (Apple Notes / Reminders): 软删除的 30 天恢复
            // 窗口内,墓碑无条件胜出。用户真的想再加同一个源,会通过
            // AddSource 流程产生一条新 record(新 id),不靠"复用旧 id"。
            if existing.isDeleted && !remote.isDeleted {
                return
            }
            // 远端也是墓碑 → 用更新的那个时间戳合并 deletedAt,确保
            // 30 天窗口在所有设备上一致。
            if existing.isDeleted && remote.isDeleted {
                if remote.modifiedAt > existing.modifiedAt,
                   let index = allSources.firstIndex(where: { $0.id == remote.id }) {
                    allSources[index] = remote
                    persist()
                }
                return
            }
            if existing.modifiedAt > remote.modifiedAt {
                // Local has unsent edits that are newer — keep them.
                // CloudKit will push them on the next sendChanges.
                return
            }
            var merged = remote
            merged.lastScannedAt = existing.lastScannedAt
            merged.songCount = existing.songCount
            if let index = allSources.firstIndex(where: { $0.id == merged.id }) {
                allSources[index] = merged
            }
        } else {
            // Don't reanimate a record the server has marked deleted.
            // Stage 4's migration may push tombstones up; once the
            // 30-day prune sweeps them, they shouldn't reappear here.
            if remote.isDeleted { return }
            allSources.append(remote)
            allSources.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
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

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode([MusicSource].self, from: data) else {
            allSources = []
            return
        }

        allSources = decoded.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private func persist() {
        guard let data = try? encoder.encode(allSources) else { return }
        try? data.write(to: storeURL, options: .atomic)
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
        guard let data = try? Data(contentsOf: accountsURL),
              let decoded = try? decoder.decode([CloudAccount].self, from: data) else {
            allAccounts = []
            return
        }
        allAccounts = decoded
    }

    private func persistAccounts() {
        guard let data = try? encoder.encode(allAccounts) else { return }
        try? data.write(to: accountsURL, options: .atomic)
    }
}
