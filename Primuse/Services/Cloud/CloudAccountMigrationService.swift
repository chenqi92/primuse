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
///    `primuseSourceDidSoftDelete`, which CloudKitSyncService
///    translates to a real `deleteRecord` push — clearing the
///    upstream "5 baidu sources" garbage.
///
/// Idempotent. The `migrationKey` UserDefaults flag guards against a
/// repeat run; clearing the flag forces a re-migration on next launch
/// (useful for support / debugging).
@MainActor
enum CloudAccountMigrationService {
    static let migrationKey = "primuse.cloudAccountMigration.v1"

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
        // launch can identify and merge it. Phase-2 orphan
        // attribution still runs on each retry, so single-account
        // users get cleanup immediately even when phase 1 is
        // incomplete.
        if stats.failed == 0 {
            UserDefaults.standard.set(true, forKey: migrationKey)
        } else {
            plog("☁️ CloudAccountMigration: \(stats.failed) source(s) couldn't identify — will retry next launch")
        }
    }

    struct Stats {
        var linked: Int = 0
        var merged: Int = 0
        var songsRepointed: Int = 0
        var failed: Int = 0
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
        guard !oauthSources.isEmpty else { return stats }

        // (provider, accountUID) → array of source.id, ordered with the
        // most recently scanned first so the keeper election below is
        // O(1).
        var grouped: [String: [MusicSource]] = [:]
        // Failed-to-resolve sources, partitioned by provider. Phase 2
        // below tries to attribute them to a known account when the
        // provider has exactly one identified account (the common
        // legacy shape: one user account, several stale duplicate
        // mounts whose tokens were overwritten by the freshest add).
        var unresolvedByProvider: [MusicSourceType: [MusicSource]] = [:]

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
                unresolvedByProvider[source.type, default: []].append(source)
                plog("⚠️ Migration: phase 1 skip source=\(source.id) (\(source.type.rawValue)) — \(error.localizedDescription)")
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

            // Wire the keeper to the account.
            sourcesStore.update(keeper.id) { $0.cloudAccountID = account.id }
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
            // translates into a real `deleteRecord` push, clearing the
            // server-side garbage that's been accumulating.
            for source in toMerge {
                sourcesStore.remove(id: source.id)
                stats.merged += 1
            }
        }

        // Phase 2: best-effort fallback for sources whose tokens are
        // dead (the legacy "5 baidu sources, only the latest still
        // signed in" shape). When a provider has exactly one
        // identified account in this run, assume the orphans belong to
        // it — this matches >99% of real cases (one upstream account,
        // several stale duplicates created by repeated re-adds), and
        // mis-attribution is bounded: we only repoint songs, never
        // delete them, and the user can manually re-add a mount with
        // its own OAuth.
        //
        // Conservative gate: skip when there are zero or ≥2 known
        // accounts for the provider (can't distinguish orphan
        // ownership). Skip when there's no keeper at all.
        for (provider, orphans) in unresolvedByProvider {
            let knownKeys = grouped.keys.filter { $0.hasPrefix("\(provider.rawValue):") }
            guard knownKeys.count == 1, let key = knownKeys.first,
                  let candidates = grouped[key],
                  let keeper = candidates.max(by: { ($0.lastScannedAt ?? .distantPast) < ($1.lastScannedAt ?? .distantPast) })
            else {
                plog("☁️ Migration: phase 2 skip provider=\(provider.rawValue) — \(knownKeys.count) known account(s), can't disambiguate \(orphans.count) orphan(s)")
                continue
            }
            plog("☁️ Migration: phase 2 attributing \(orphans.count) orphan \(provider.rawValue) source(s) to keeper=\(keeper.id)")
            let orphanIDs = Set(orphans.map(\.id))
            let affectedSongs = library.songs.filter { orphanIDs.contains($0.sourceID) }
            if !affectedSongs.isEmpty {
                let repointed = affectedSongs.map { song -> Song in
                    var copy = song
                    copy.sourceID = keeper.id
                    return copy
                }
                library.replaceSongs(repointed)
                stats.songsRepointed += affectedSongs.count
            }
            for source in orphans {
                sourcesStore.remove(id: source.id)
                stats.merged += 1
            }
        }

        return stats
    }
}
