import Foundation

/// Protects the identity supplied by a CUE sheet when metadata is scraped from
/// the shared physical audio file. A forced scrape may replace ordinary-track
/// text, but it must not collapse every virtual segment to one file-level name.
public enum ScrapeCueIdentityPolicy {
    public static func resolvedTitle(
        original: String,
        scraped: String,
        isCueTrack: Bool
    ) -> String {
        guard isCueTrack, !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scraped
        }
        return original
    }

    public static func resolvedOptionalText(
        original: String?,
        scraped: String?,
        isCueTrack: Bool
    ) -> String? {
        guard isCueTrack,
              let original,
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return scraped
        }
        return original
    }
}

public extension ScrapeCueIdentityPolicy {
    /// 批量 / 整张专辑补全合并完之后,CUE 分轨的身份字段以 CUE 表为准:标题、艺术家有值
    /// 就不换,轨号只补空缺,专辑归属见 `protectingCueAlbumGrouping`。在线结果描述的是
    /// 整个音频文件,覆盖模式下照搬会把每一轨改成同一个名字、拆出专辑。
    static func protectingCueIdentity(
        _ merged: ScrapedMetadataMergePolicy.Fields,
        original: ScrapedMetadataMergePolicy.Fields
    ) -> ScrapedMetadataMergePolicy.Fields {
        var result = merged
        result.title = resolvedTitle(original: original.title, scraped: merged.title, isCueTrack: true)
        result.artist = resolvedOptionalText(original: original.artist, scraped: merged.artist, isCueTrack: true)
        if result.artist == original.artist { result.sourceArtistNames = original.sourceArtistNames }
        result.trackNumber = original.trackNumber ?? merged.trackNumber
        return protectingCueAlbumGrouping(result, original: original)
    }

    /// CUE 分轨归在哪张专辑由 CUE 表决定:专辑名、专辑艺术家、碟号保持原样,CUE 里没写的
    /// 也不从在线结果补;艺术家只在不改变专辑归属时才换。在线结果是一首一首各自找的,
    /// 每一首对上的专辑艺术家、碟号可能都不一样,补进来整张专辑就散成一首一张。
    static func protectingCueAlbumGrouping(
        _ proposed: ScrapedMetadataMergePolicy.Fields,
        original: ScrapedMetadataMergePolicy.Fields
    ) -> ScrapedMetadataMergePolicy.Fields {
        var result = proposed
        result.albumTitle = original.albumTitle
        result.albumArtist = original.albumArtist
        result.discNumber = original.discNumber
        // CUE 没写专辑艺术家时专辑跟着这一轨的艺术家走,换艺术家就等于换专辑。
        if albumGroupingKey(result) != albumGroupingKey(original) {
            result.artist = original.artist
            result.sourceArtistNames = original.sourceArtistNames
        }
        return result
    }

    private static func albumGroupingKey(_ fields: ScrapedMetadataMergePolicy.Fields) -> [String?] {
        [
            trimmedNonEmpty(fields.albumTitle),
            trimmedNonEmpty(fields.albumArtist) ?? trimmedNonEmpty(fields.artist),
        ]
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
