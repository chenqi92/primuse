import Foundation

/// 一首歌换了 `Song.id` 以后（音乐源删掉重加、网盘里的文件被改名或挪了位置、电视改了源的
/// 连接参数、电视把源移除后又把同一个网盘当新源加回来），用户亲手留下的评分、评论和
/// 「我喜欢」不能跟着旧 id 一起没了。旧歌离开曲库时记一条，曲库里出现能确定是同一首的歌时
/// 还回去；对不上的一直留着等，不悄悄丢。歌单成员另有置灰占位（`PlaylistPendingEntry`）。
///
/// 只认元数据，不做音频指纹：网盘、NAS 上的歌要整首下载解码才算得出指纹，几万首的曲库
/// 重扫一遍就是几百 GB 流量；而丢标记的几种情形里，标题、歌手、专辑、时长都没变。
public struct CarriedSongMarks: Codable, Hashable, Sendable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        /// 音乐源被移除，或者文件从源里消失（改名、挪走、改了连接参数后重扫）。
        case removedSource
        /// 电视上「从 Apple TV 移除」：源只是藏起来，歌还在库里。
        case hiddenSource
        /// 从备份文件恢复时曲库里还没有这首。
        case backup
    }

    /// 离开曲库时的 `Song.id`。同一个 id 回到曲库时直接认它。
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String?
    /// 秒；nil 表示不知道。不知道时长的不会被自动认领。
    public var duration: Double?
    public var fileSize: Int64?
    /// 文件名（不含目录），小写。几份同名同时长的歌之间按它挑。
    public var fileName: String?
    /// 1…5。
    public var rating: Int?
    public var comment: String?
    public var liked: Bool
    public var origin: Origin
    public var createdAt: Date

    public init(
        id: String,
        title: String,
        artists: [String],
        album: String? = nil,
        duration: Double? = nil,
        fileSize: Int64? = nil,
        fileName: String? = nil,
        rating: Int? = nil,
        comment: String? = nil,
        liked: Bool = false,
        origin: Origin,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.fileSize = fileSize
        self.fileName = fileName
        self.rating = rating
        self.comment = comment
        self.liked = liked
        self.origin = origin
        self.createdAt = createdAt
    }

    public var hasMarks: Bool {
        rating != nil || !(comment ?? "").isEmpty || liked
    }

    public var matchSubject: ExternalTrackMatchPolicy.Subject {
        .init(title: title, artists: artists, duration: duration)
    }

    /// 文件名取路径最后一段、转小写；没有就是 nil。
    public static func fileName(fromPath path: String) -> String? {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
        guard let name, !name.isEmpty else { return nil }
        return name.lowercased()
    }
}

public enum CarriedSongMarksPolicy {
    /// 最多留这么多条，满了丢最早记下的。整源删掉几万首时只有打过分、写过评论、点过喜欢的会进来。
    public static let maximumEntries = 20_000

    /// 曲库里一首候选歌，只含认领要用的字段。
    public struct Candidate: Sendable, Hashable {
        public var title: String
        public var artists: [String]
        public var album: String?
        public var duration: Double?
        public var fileSize: Int64?
        public var fileName: String?

        public init(
            title: String,
            artists: [String],
            album: String? = nil,
            duration: Double? = nil,
            fileSize: Int64? = nil,
            fileName: String? = nil
        ) {
            self.title = title
            self.artists = artists
            self.album = album
            self.duration = duration
            self.fileSize = fileSize
            self.fileName = fileName
        }
    }

    /// 在候选里挑出「就是它」的那一首，拿不准时返回 nil（条目留着继续等）。
    ///
    /// 比歌单占位的自动点亮更严：两边都要有时长，且按 `ExternalTrackMatchPolicy` 判为
    /// `confident`（主歌名一致、版本标记一致、歌手有交集、时长差不超过 3 秒）；两边都有专辑时
    /// 专辑也要一致，所以原专辑上那一首的标记不会落到精选集里的同一首上。还剩几份（同一张
    /// 专辑的 FLAC 和 MP3）时依次按文件大小、文件名挑出唯一的一份，挑不出就不认。
    public static func select(for entry: CarriedSongMarks, among candidates: [Candidate]) -> Int? {
        let query = ExternalTrackMatchPolicy.Key(entry.matchSubject)
        guard query.isMatchable, query.duration != nil, !query.artistTokens.isEmpty else { return nil }
        let album = normalizedAlbum(entry.album)
        let eligible = candidates.indices.filter { index in
            let candidate = candidates[index]
            let key = ExternalTrackMatchPolicy.Key(.init(
                title: candidate.title,
                artists: candidate.artists,
                duration: candidate.duration
            ))
            guard key.duration != nil,
                  ExternalTrackMatchPolicy.verdict(query, key) == .confident else { return false }
            if let album, let other = normalizedAlbum(candidate.album) { return album == other }
            return true
        }
        if eligible.count == 1 { return eligible[0] }
        guard eligible.count > 1 else { return nil }
        if let size = entry.fileSize, size > 0 {
            let sameSize = eligible.filter { candidates[$0].fileSize == size }
            if sameSize.count == 1 { return sameSize[0] }
        }
        if let name = entry.fileName, !name.isEmpty {
            let sameName = eligible.filter { candidates[$0].fileName == name }
            if sameName.count == 1 { return sameName[0] }
        }
        return nil
    }

    /// 并进新记下的条目。同一个旧 id 又记了一次（藏起来以后又真删了）时，两次的标记取并：
    /// 新的一次没有评分、评论时沿用旧的，喜欢任一次是就算是；记下时间取早的那次。
    /// 超出上限时按记下时间丢最早的。
    public static func merging(
        _ existing: [String: CarriedSongMarks],
        adding fresh: [CarriedSongMarks],
        limit: Int = maximumEntries
    ) -> [String: CarriedSongMarks] {
        var result = existing
        for entry in fresh where entry.hasMarks {
            guard let previous = result[entry.id] else {
                result[entry.id] = entry
                continue
            }
            var merged = entry
            merged.rating = entry.rating ?? previous.rating
            if (entry.comment ?? "").isEmpty { merged.comment = previous.comment }
            merged.liked = entry.liked || previous.liked
            merged.createdAt = min(entry.createdAt, previous.createdAt)
            result[entry.id] = merged
        }
        guard result.count > limit else { return result }
        let kept = result.values
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
            .prefix(max(0, limit))
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
    }

    /// 还回去时评分与评论怎么定：目标歌自己已有的不动（那是用户对这一份的判断），
    /// 只补它空着的那一项。返回 nil 表示两项都不用改。
    public static func restoredReview(
        entry: CarriedSongMarks,
        existingRating: Int?,
        existingComment: String?
    ) -> (rating: Int?, comment: String)? {
        let currentComment = existingComment ?? ""
        let rating = existingRating ?? entry.rating
        let comment = currentComment.isEmpty ? (entry.comment ?? "") : currentComment
        guard rating != existingRating || comment != currentComment else { return nil }
        return (rating, comment)
    }

    private static func normalizedAlbum(_ album: String?) -> String? {
        guard let album else { return nil }
        let normalized = ExternalTrackMatchPolicy.normalize(album)
        return normalized.isEmpty ? nil : normalized
    }
}
