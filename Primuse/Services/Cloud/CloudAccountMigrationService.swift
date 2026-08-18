import Foundation
import PrimuseKit

/// One-shot launch migration that deduplicates OAuth-typed
/// `MusicSource` rows by upstream account identity. Splits the legacy
/// "every OAuth flow mints a new UUID" model into the post-stage-4
/// "one CloudAccount per upstream account, mounts hang off it" shape
/// without forcing the user to re-add anything.
///
/// Algorithm per launch:
/// 1. Collect every active OAuth-typed source.
/// 2. For each, instantiate the connector and call
///    `accountIdentifier()`. Skip sources that fail (network down,
///    token revoked) — they'll be retried on the next launch.
/// 3. Group by `(provider, accountUID)`. Single-mount groups just get
///    a `CloudAccount` record + `mount.cloudAccountID` set.
/// 4. Multi-mount groups: keep the row with the newest
///    `lastScannedAt` as the keeper, repoint every other group
///    member's songs to the keeper's id, then soft-delete the
///    redundant rows via `SourcesStore.remove()`. That fires
///    `primuseSourceDidSoftDelete`, which CloudKitSyncService persists as a
///    durable tombstone so historical mounts cannot return after cursor reset.
///
/// Idempotent. The `migrationKey` UserDefaults flag guards against a
/// repeat run; clearing the flag forces a re-migration on next launch
/// (useful for support / debugging).
@MainActor
enum CloudAccountMigrationService {
    // v2: re-run once for everyone so the credential-free config dedup
    // (phase 1.5) gets a chance to collapse duplicate OAuth mounts that the
    // v1 run couldn't (e.g. a clean reinstall where tokens are gone).
    static let migrationKey = "primuse.cloudAccountMigration.v2"

    static func runIfNeeded(
        sourcesStore: SourcesStore,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        plog("☁️ CloudAccountMigration: starting")
        let stats = await run(
            sourcesStore: sourcesStore,
            sourceManager: sourceManager,
            library: library
        )
        plog("☁️ CloudAccountMigration: done (linked=\(stats.linked) merged=\(stats.merged) songsRepointed=\(stats.songsRepointed) failed=\(stats.failed))")
        // Only mark complete when every source resolved cleanly. With
        // failed > 0, the next launch retries — common case is a
        // network blip or token-refresh-needed source: re-OAuth
        // through the UI repopulates the keychain, then the next
        // launch can identify and merge it. Sources that cannot be
        // identified stay intact until identity can be proven.
        if stats.failed == 0 && stats.examined > 0 {
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else if stats.examined == 0 {
            plog("☁️ CloudAccountMigration: no OAuth sources yet (likely still syncing) — will retry next launch")
        } else {
            plog("☁️ CloudAccountMigration: \(stats.failed) source(s) couldn't identify — will retry next launch")
        }
    }

    struct Stats {
        var linked: Int = 0
        var merged: Int = 0
        var songsRepointed: Int = 0
        var failed: Int = 0
        /// How many OAuth sources this run actually looked at. 0 means the
        /// sources haven't synced down yet — don't mark the migration
        /// complete, or a clean reinstall would "finish" before CloudKit
        /// delivers the duplicate mounts and never get to dedup them.
        var examined: Int = 0
    }

    /// The actual migration body. Exposed (without the UserDefaults
    /// guard) so a future "Re-run migration" support button can drive
    /// it on demand.
    static func run(
        sourcesStore: SourcesStore,
        sourceManager: SourceManager,
        library: MusicLibrary
    ) async -> Stats {
        var stats = Stats()

        let oauthSources = sourcesStore.sources.filter { $0.type.requiresOAuth }
        stats.examined = oauthSources.count
        guard !oauthSources.isEmpty else { return stats }

        // (provider, accountUID) → array of source.id, ordered with the
        // most recently scanned first so the keeper election below is
        // O(1).
        var grouped: [String: [MusicSource]] = [:]
        // Every source that failed network identification (dead creds OR
        // transient), for the credential-free config dedup below.
        var unidentified: [MusicSource] = []

        for source in oauthSources {
            do {
                let conn = sourceManager.connector(for: source)
                guard let oauthConn = conn as? OAuthCloudSource else {
                    plog("☁️ Migration skip: \(source.type.rawValue) connector doesn't implement OAuthCloudSource")
                    continue
                }
                try await conn.connect()
                let uid = try await oauthConn.accountIdentifier()
                let key = "\(source.type.rawValue):\(uid)"
                grouped[key, default: []].append(source)
                plog("☁️ Migration: source=\(source.id) (\(source.type.rawValue)) → uid=\(uid)")
            } catch {
                stats.failed += 1
                unidentified.append(source)
                if isDeadCredentialError(error) {
                    plog("⚠️ Migration: phase 1 skip source=\(source.id) (\(source.type.rawValue)) — credentials require re-authorization; source retained — \(error.localizedDescription)")
                } else {
                    plog("⚠️ Migration: phase 1 skip source=\(source.id) (\(source.type.rawValue)) — transient, retry next launch — \(error.localizedDescription)")
                }
            }
        }

        for (key, members) in grouped {
            // `members` are in scan order; pick the latest-scanned one
            // as the keeper (most likely to have correct songCount,
            // freshest tokens, etc.). Falls back to first when no
            // member has been scanned yet.
            let keeper = members.max { lhs, rhs in
                (lhs.lastScannedAt ?? .distantPast) < (rhs.lastScannedAt ?? .distantPast)
            } ?? members[0]
            let provider = keeper.type
            let uidPart = key.dropFirst(provider.rawValue.count + 1)
            let accountUID = String(uidPart)
            let accountID = CloudAccount.deriveID(provider: provider, accountUID: accountUID)

            // Always ensure a CloudAccount row exists (idempotent —
            // upsertAccount keys on the deterministic id).
            let existing = sourcesStore.account(provider: provider, accountUID: accountUID)
            let account = existing ?? CloudAccount(
                id: accountID,
                provider: provider,
                accountUID: accountUID,
                createdAt: Date()
            )
            sourcesStore.upsertAccount(account)

            // Wire the keeper to the account and retain any directory labels
            // learned by duplicate mounts before those rows become tombstones.
            let directoryNames = mergedDirectoryDisplayNames(from: members)
            sourcesStore.update(keeper.id) {
                $0.cloudAccountID = account.id
                $0.scannedDirectoryDisplayNames.merge(directoryNames) { current, _ in current }
            }
            stats.linked += 1

            // Single-mount group → done; nothing to merge.
            guard members.count > 1 else { continue }

            let toMerge = members.filter { $0.id != keeper.id }
            plog("☁️ Migration: account=\(accountID) keeper=\(keeper.id) merging \(toMerge.count) duplicate mount(s): \(toMerge.map(\.id))")

            // Repoint every song that pointed at a redundant mount to
            // the keeper. Per stage-2 design we keep song.id stable
            // (don't recompute hash), only swap sourceID — playlists
            // and play history stay valid.
            let redundantIDs = Set(toMerge.map(\.id))
            let affectedSongs = library.songs.filter { redundantIDs.contains($0.sourceID) }
            if !affectedSongs.isEmpty {
                let repointed = affectedSongs.map { song -> Song in
                    var copy = song
                    copy.sourceID = keeper.id
                    return copy
                }
                library.replaceSongs(repointed)
                stats.songsRepointed += affectedSongs.count
            }

            // Soft-delete the redundant mounts. This triggers
            // `primuseSourceDidSoftDelete`, which CloudKitSyncService
            // translates into a durable tombstone payload.
            for source in toMerge {
                sourcesStore.remove(id: source.id)
                stats.merged += 1
            }
        }

        // Phase 1.5: credential-free dedup. When *no* live credentials are
        // available (the classic "clean reinstall → CloudKit pulls every
        // historical OAuth mount back down, but the tokens are gone so none
        // can identify over the network" shape), phases 1 & 2 can't help —
        // grouped is empty so there's no keeper to attribute orphans to, and
        // the duplicates all just show up in the list.
        //
        // But duplicate mounts of the same account share an identical set of
        // scanned folder ids (cloud folder ids are globally unique and embed
        // the drive/account id), so we can collapse *exact* config duplicates
        // with zero network calls. This only merges sources whose scanned
        // folders are byte-identical — never two distinct accounts (their
        // folder ids differ), and never same-account-different-folder mounts
        // (those wait for the credential path once the user re-authenticates).
        let bySignature = Dictionary(grouping: unidentified.compactMap { source -> (String, MusicSource)? in
            guard let sig = accountConfigSignature(for: source) else { return nil }
            return (sig, source)
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
        for (_, dupes) in bySignature where dupes.count > 1 {
            let keeper = dupes.max { ($0.lastScannedAt ?? .distantPast) < ($1.lastScannedAt ?? .distantPast) } ?? dupes[0]
            let toMerge = dupes.filter { $0.id != keeper.id }
            let directoryNames = mergedDirectoryDisplayNames(from: dupes)
            sourcesStore.update(keeper.id) {
                $0.scannedDirectoryDisplayNames.merge(directoryNames) { current, _ in current }
            }
            plog("☁️ Migration: phase 1.5 config-dedup — \(toMerge.count) exact-duplicate \(keeper.type.rawValue) mount(s) → keeper=\(keeper.id)")
            let redundantIDs = Set(toMerge.map(\.id))
            let affectedSongs = library.songs.filter { redundantIDs.contains($0.sourceID) }
            if !affectedSongs.isEmpty {
                let repointed = affectedSongs.map { song -> Song in
                    var copy = song
                    copy.sourceID = keeper.id
                    return copy
                }
                library.replaceSongs(repointed)
                stats.songsRepointed += affectedSongs.count
            }
            for source in toMerge {
                sourcesStore.remove(id: source.id)
                stats.merged += 1
            }
        }
        return stats
    }

    private static func mergedDirectoryDisplayNames(
        from sources: [MusicSource]
    ) -> [String: String] {
        sources.reduce(into: [String: String]()) { result, source in
            let selected = Set(source.scannedDirectories)
            result.merge(source.scannedDirectoryDisplayNames.filter { selected.contains($0.key) }) {
                current, _ in current
            }
            result.merge(CloudDirectoryNameStore.displayNames(for: source.id).filter {
                selected.contains($0.key)
            }) { current, _ in current }
        }
    }

    /// True only when the error means the source's credentials are
    /// *definitively* unusable (token revoked / refresh permanently
    /// failed / nothing stored), as opposed to a transient network or
    /// server hiccup. Phase 2's destructive orphan attribution gates on
    /// this so a launch-time network blip never gets a live source
    /// soft-deleted and its songs repointed to another account.
    ///
    /// Network / transient errors (URLError, `apiError` for 5xx/timeout,
    /// `rateLimited`, `invalidResponse`) deliberately return false.
    private static func isDeadCredentialError(_ error: Error) -> Bool {
        switch error {
        case CloudDriveError.notAuthenticated,
             CloudDriveError.tokenRefreshFailed:
            return true
        default:
            return false
        }
    }

    /// A credential-free account fingerprint: the source's scanned cloud
    /// folder ids. These ids are globally unique per drive/account and embed
    /// the account identity, so two OAuth mounts with byte-identical folder
    /// sets are provably the same account — letting us dedup exact duplicates
    /// even when no token is available to identify them over the network.
    /// Returns nil for sources with no scanned folders yet (can't判定, so they
    /// don't participate in this fallback dedup).
    private static func accountConfigSignature(for source: MusicSource) -> String? {
        let dirs = source.scannedDirectories.filter { !$0.isEmpty }
        guard !dirs.isEmpty else { return nil }
        return "\(source.type.rawValue)#\(dirs.sorted().joined(separator: "|"))"
    }

}
