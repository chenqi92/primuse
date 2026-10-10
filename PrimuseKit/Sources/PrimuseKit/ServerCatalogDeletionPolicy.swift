import Foundation

/// How much a completed catalogue observation is allowed to conclude about
/// rows it did not see.
public enum CatalogDeletionAuthority: String, Sendable, Equatable, Codable {
    /// A complete walk is authoritative on its own: anything absent is gone.
    /// File-oriented sources and media servers that enumerate by stable item
    /// identity belong here.
    case authoritative
    /// A complete snapshot is evidence, not authority. Absence has to be
    /// witnessed by several separate complete walks before a row may be
    /// removed.
    case confirmationRequired
    /// A degraded, partial or compatibility listing. It may merge rows but
    /// must never remove them.
    case never
}

/// 服务端删掉的歌什么时候从资料库移除。用户按音乐源选（#155）。
public enum ServerCatalogRemovalMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// 默认：一次完整走查只是一票证词，凑够 `requiredWitnesses` 才移除，大批消失还要多等一票。
    case confirmFirst
    /// 一次没漂移的完整走查里不在就移除，大批消失也一样。走查漂移、没走完、只是兼容列表时照旧不删。
    case immediate
}

/// Turns repeated "this song was not in the complete catalogue" observations
/// into an actual deletion decision.
///
/// Subsonic-family servers cannot express an immutable snapshot of what one
/// account may see: `getScanStatus.lastScan|count` describes the server-wide
/// scanner, so a permission change, a library remount or a mid-flight re-index
/// can shift every `search3` page without changing that marker. A single
/// complete walk is therefore not allowed to delete.
///
/// 证词按「一次完整走查」计，不按服务端的扫描标记计。以前要求两票来自不同的
/// `lastScan`，可这个标记只在服务端重新扫描资料库时才动：用户删完文件、服务端扫过
/// 那一次之后它就停住，此后 App 再扫多少遍都被当成同一份证词的重读，缺席永远停在
/// 一票，歌一直删不掉（#155）。现在每次重新开始的完整走查各算一票，身份见
/// `walkObservationRevision`；断点续扫、提交重放沿用同一个暂存会话，仍是同一份证词。
public enum ServerCatalogDeletionConfirmationPolicy {
    /// Witnesses required before an absent row is removed.
    public static let requiredWitnessCount = 2
    /// A pass that loses this share of the source's rows at once is treated as
    /// suspicious and needs an extra witness.
    public static let massDisappearanceRatio = 0.2
    /// Small libraries lose a large share on ordinary edits, so the ratio only
    /// applies once the absolute loss is meaningful too.
    public static let massDisappearanceFloor = 50
    /// Witnesses required for rows that disappeared in a suspicious pass.
    public static let massDisappearanceWitnessCount = 3

    /// How many complete observations must agree before an absent row may be
    /// removed. `nil` means "never remove it from this kind of listing".
    ///
    /// An authoritative snapshot decides on its own, but a pass that lost a
    /// suspicious share of the source still has to be repeated — an unmounted
    /// library reads exactly like a bulk deletion, and that is the one case
    /// where being wrong costs the user their playlists.
    ///
    /// 用户选了「立即移除」时一票就够，大批消失也不再多等；兼容列表仍然不删。
    public static func requiredWitnesses(
        for authority: CatalogDeletionAuthority,
        isMassDisappearance: Bool,
        removalMode: ServerCatalogRemovalMode = .confirmFirst
    ) -> Int? {
        switch (authority, removalMode) {
        case (.never, _):
            return nil
        case (_, .immediate):
            return 1
        case (.authoritative, .confirmFirst):
            return isMassDisappearance ? massDisappearanceWitnessCount : 1
        case (.confirmationRequired, .confirmFirst):
            return isMassDisappearance ? massDisappearanceWitnessCount : requiredWitnessCount
        }
    }

    public struct Plan: Sendable, Equatable {
        /// Rows that may be removed from the library now.
        public var confirmedDeletionSongIDs: Set<String>
        /// Updated per-song witness counts, to be persisted on the sync state.
        public var missingCounts: [String: Int]
        /// 这次观察的身份（见 `walkObservationRevision`），存下来让下一轮分得清
        /// 「新的一次走查」和「同一次走查的重读」。
        public var evidenceRevision: String?
        /// Rows observed as absent that are still short of their witness bar.
        public var pendingSongIDs: Set<String>
        /// True when this pass lost a suspiciously large share of the source.
        public var isMassDisappearance: Bool

        public init(
            confirmedDeletionSongIDs: Set<String> = [],
            missingCounts: [String: Int] = [:],
            evidenceRevision: String? = nil,
            pendingSongIDs: Set<String> = [],
            isMassDisappearance: Bool = false
        ) {
            self.confirmedDeletionSongIDs = confirmedDeletionSongIDs
            self.missingCounts = missingCounts
            self.evidenceRevision = evidenceRevision
            self.pendingSongIDs = pendingSongIDs
            self.isMassDisappearance = isMassDisappearance
        }

        public var hasPendingConfirmations: Bool { !pendingSongIDs.isEmpty }

        /// 这一轮少了一大批、而且还有歌在等证词：来源卡片要说明为什么还留着。
        /// 凑够票数、这一轮全删掉的那次不算 —— 否则卡片上会写「少了 0 首」。
        public var holdsMassDisappearance: Bool {
            isMassDisappearance && hasPendingConfirmations
        }
    }

    /// 一次完整走查在证词里的身份，存进 `SourceSyncState.deletionEvidenceRevision`。
    ///
    /// 暂存会话每次从头走查都换新的，断点续扫与提交重放沿用原来的，所以「同一个会话」
    /// 恰好就是「同一份证词」。服务端修订只是附带记下，方便看诊断。
    public static func walkObservationRevision(
        catalogRevision: String?,
        stageSessionID: String
    ) -> String {
        "\(catalogRevision ?? "-")@\(stageSessionID)"
    }

    /// 大批消失时来源卡片上的「再完整扫描几次」：还在等的歌里票数最多的那首还差几票。
    /// 只用于默认的「确认后移除」；「立即移除」不会留下待确认的歌。
    public static func remainingMassDisappearanceWitnesses(
        unresolvedSongIDs: [String],
        missingCounts: [String: Int]
    ) -> Int {
        let witnessed = unresolvedSongIDs.compactMap { missingCounts[$0] }.max() ?? 1
        return max(1, massDisappearanceWitnessCount - witnessed)
    }

    /// - Parameters:
    ///   - existingSongIDs: library rows currently attributed to this source.
    ///   - authoritativeSongIDs: every song id in the verified complete snapshot.
    ///   - previousMissingCounts: witness counts carried on the sync state.
    ///   - previousEvidenceRevision: revision that produced the newest counts.
    ///   - currentRevision: 这次观察的身份。完整走查传 `walkObservationRevision`；
    ///     `nil` 表示每次都算新的一票（增量对账每一轮各自列一遍 id）。
    ///   - authority: how much this listing may conclude about rows it did not
    ///     see. Defaults to the conservative bar.
    ///   - removalMode: 用户为这个源选的移除方式。
    public static func plan(
        existingSongIDs: Set<String>,
        authoritativeSongIDs: Set<String>,
        previousMissingCounts: [String: Int],
        previousEvidenceRevision: String?,
        currentRevision: String?,
        authority: CatalogDeletionAuthority = .confirmationRequired,
        removalMode: ServerCatalogRemovalMode = .confirmFirst
    ) -> Plan {
        let missing = existingSongIDs.subtracting(authoritativeSongIDs)
        guard !missing.isEmpty else {
            // Nothing is absent, so no evidence is carried forward. Rows that
            // came back clear their history along with it.
            return Plan(evidenceRevision: currentRevision)
        }

        // 同一份证词再读一遍（同一次走查的提交重放）不算第二票，否则一次走查
        // 自己就能凑够票数。
        let isRepeatedObservation = currentRevision != nil
            && currentRevision == previousEvidenceRevision

        let isMassDisappearance = missing.count >= massDisappearanceFloor
            && Double(missing.count) >= Double(existingSongIDs.count) * massDisappearanceRatio
        let witnessBar = requiredWitnesses(
            for: authority,
            isMassDisappearance: isMassDisappearance,
            removalMode: removalMode
        )

        var counts: [String: Int] = [:]
        counts.reserveCapacity(missing.count)
        var confirmed: Set<String> = []
        var pending: Set<String> = []
        for songID in missing {
            let previous = previousMissingCounts[songID] ?? 0
            let witnesses = isRepeatedObservation ? max(previous, 1) : previous + 1
            counts[songID] = witnesses
            if let witnessBar, witnesses >= witnessBar {
                confirmed.insert(songID)
            } else {
                pending.insert(songID)
            }
        }

        return Plan(
            confirmedDeletionSongIDs: confirmed,
            missingCounts: counts,
            evidenceRevision: currentRevision,
            pendingSongIDs: pending,
            isMassDisappearance: isMassDisappearance
        )
    }

    /// Song ids the library must keep even though the snapshot did not contain
    /// them. Feeding this to the authoritative-prune path removes exactly the
    /// confirmed rows and nothing else.
    public static func retainedAuthoritativeSongIDs(
        existingSongIDs: Set<String>,
        authoritativeSongIDs: Set<String>,
        confirmedDeletionSongIDs: Set<String>
    ) -> Set<String> {
        authoritativeSongIDs
            .union(existingSongIDs.subtracting(confirmedDeletionSongIDs))
    }
}
