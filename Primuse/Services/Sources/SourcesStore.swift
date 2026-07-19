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
        // tvOS 只允许写 Caches / tmp;须与 LibrarySnapshotSync / MusicLibrary 同目录。
        #if os(tvOS)
        let appSupport = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif
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

    /// tvOS 下载到新 sources.json 后重新从磁盘加载。
    func reloadFromDisk() { load(); loadAccounts() }

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

    /// Source delete: hide from UI, keep the row on disk for recycle-bin
    /// recovery — but push a REAL deleteRecord to CloudKit so the
    /// upstream record clears. The previous "save with isDeleted=true"
    /// strategy left server records lingering, which then resurrected
    /// the source on every fetch (this is the root of the duplicate
    /// Baidu sources mess). This is not used by the enable/disable toggle.
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
        purgeCredentials(forSourceID: id)
        NotificationCenter.default.post(
            name: .primuseSourceDidDelete,
            object: nil,
            userInfo: ["id": id]
        )
    }

    /// Tear down the persisted secrets and per-source storage owned outside the
    /// source row itself: Keychain passwords, cloud OAuth tokens + app
    /// credentials, security-scoped bookmarks (macOS only) and cloud directory
    /// display names. Idempotent and safe to call for any source type.
    private func purgeCredentials(forSourceID id: String) {
        // KeychainService / CloudTokenManager / CloudDirectoryNameStore 仅存在于
        // iOS/macOS app target;tvOS 共享本文件但用 TVCredentialStore,无这些凭据存储。
        #if os(iOS) || os(macOS)
        KeychainService.deletePassword(for: id)
        Task {
            let tm = CloudTokenManager(sourceID: id)
            await tm.deleteTokens()
            await tm.deleteAppCredentials()
        }
        #if os(macOS)
        LocalBookmarkStore.remove(sourceID: id)
        #endif
        CloudDirectoryNameStore.deleteAll(for: id)
        #endif
    }

    /// Sweep soft-deleted sources older than `threshold` and remove them for
    /// good. Called on launch with a 30-day threshold.
    func pruneSources(deletedBefore threshold: Date) {
        let toPrune = allSources.filter { $0.isDeleted && ($0.deletedAt ?? .distantFuture) < threshold }
        for source in toPrune {
            permanentlyDelete(id: source.id)
        }
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
        guard let index = allSources.firstIndex(where: { $0.id == id }) else { return }
        if allSources[index].isDeleted {
            if (allSources[index].deletedAt ?? .distantPast) < deletedAt {
                allSources[index].deletedAt = deletedAt
                allSources[index].modifiedAt = max(allSources[index].modifiedAt, deletedAt)
                persist()
                notifyChanged([id])
            }
            return
        }
        allSources[index].isDeleted = true
        allSources[index].deletedAt = deletedAt
        allSources[index].modifiedAt = max(allSources[index].modifiedAt, deletedAt)
        persist()
        notifyChanged([id])
        NotificationCenter.default.post(
            name: .primuseSourceDidSoftDelete,
            object: nil,
            userInfo: ["id": id]
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
        if let existing = allSources.first(where: { $0.id == remote.id }) {
            if existing.isDeleted && !remote.isDeleted {
                if Self.sourceClock(existing) >= Self.sourceClock(remote) {
                    return
                }
                // A later active payload is an explicit restore/edit from
                // another device, so let it revive this source.
            }
            // 远端也是墓碑 → 用更新的那个时间戳合并 deletedAt,确保
            // 7 天窗口在所有设备上一致。
            if existing.isDeleted && remote.isDeleted {
                if Self.sourceClock(remote) > Self.sourceClock(existing),
                   let index = allSources.firstIndex(where: { $0.id == remote.id }) {
                    allSources[index] = remote
                    persist()
                }
                return
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
        max(source.modifiedAt, source.deletedAt ?? .distantPast)
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
