import Foundation

/// 只存在本机、不写回音乐源的刮削改动(Apple TV 上的手动匹配与整张专辑补全),
/// 在别处来的曲库快照整份覆盖之后怎么补回来。
public enum LocalMetadataOverridePolicy {
    public enum Kind: String, Codable, Sendable {
        /// 用户在候选里挑的:本机的值盖回快照。
        case chosen
        /// 批量「只补空缺」补上的:只补快照里仍然空着的字段。
        case filledMissing
    }

    /// 快照里这一行的来源设备上有人在本机改动之后又手动编辑过:那边的更新,
    /// 本机这条改动作废。
    public static func isSuperseded(
        localEditedAt: Date,
        incomingUserEditedAt: Date?
    ) -> Bool {
        guard let incomingUserEditedAt else { return false }
        return incomingUserEditedAt > localEditedAt
    }

    /// 把本机改过的标签叠回快照里的这一行。本机某个字段为空时保留快照的值。
    public static func replayedFields(
        incoming: ScrapedMetadataMergePolicy.Fields,
        local: ScrapedMetadataMergePolicy.Fields,
        kind: Kind
    ) -> ScrapedMetadataMergePolicy.Fields {
        ScrapedMetadataMergePolicy.merged(
            incoming,
            with: ScrapedMetadataMergePolicy.Candidate(
                title: local.title,
                artist: local.artist,
                albumArtist: local.albumArtist,
                album: local.albumTitle,
                year: local.year,
                genres: local.genre.map { [$0] },
                trackNumber: local.trackNumber,
                discNumber: local.discNumber
            ),
            overwrite: kind == .chosen
        )
    }

    /// 本机缓存里这首歌眼下的封面 / 歌词,和本机改动留的那份副本比。
    public enum AssetState: Sendable, Equatable {
        case missing
        case matchesLocalCopy
        case differs
    }

    public enum AssetAction: Sendable, Equatable {
        /// 已经是本机那份,不用动。
        case keep
        /// 写回本机那份。
        case restore
        /// 快照带来了自己的一份,「只补空缺」让给它,这份副本不再需要。
        case yieldToIncoming
    }

    public static func assetAction(kind: Kind, current: AssetState) -> AssetAction {
        switch (kind, current) {
        case (_, .matchesLocalCopy): return .keep
        case (_, .missing): return .restore
        case (.chosen, .differs): return .restore
        case (.filledMissing, .differs): return .yieldToIncoming
        }
    }
}
