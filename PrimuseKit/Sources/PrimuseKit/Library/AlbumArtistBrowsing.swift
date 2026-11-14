import Foundation

/// 资料库「艺术家」页列哪些人。
///
/// `allArtists` 列参与演唱的每一位：曲目艺人按分隔符拆开，合辑里的每位歌手、feat. 的嘉宾
/// 各占一项。`albumArtists` 只列专辑署名者，合作署名按同一套规则拆开，同一张专辑可以
/// 同时出现在各位署名者名下；合辑仍归在「群星 / Various Artists」这类名字下。
/// 专辑怎么合并跟这里无关，两种模式下专辑都一样。
public enum ArtistBrowseMode: String, CaseIterable, Sendable {
    case allArtists
    case albumArtists

    /// 本机偏好，不走 iCloud：iPhone / iPad / Mac 与电视各自一份，CarPlay 跟着手机。
    public static let storageKey = "library.artistBrowseMode"

    public static func resolved(_ rawValue: String?) -> ArtistBrowseMode {
        rawValue.flatMap(Self.init(rawValue:)) ?? .allArtists
    }
}

/// 「专辑艺术家」里不列名下只有单曲、EP 的人。本机偏好，默认关。
///
/// 合作单曲常把对方也署成专辑艺人；收整张专辑的人不想让这些人混进专辑艺术家。
/// 一张专辑算不算正式专辑：手动分类说了算；没有手动分类时，标签或标题认出是单曲/EP
/// 的不算，什么都没认出来又只有一首歌的也按单曲算（单曲常常就是一首歌一张专辑）。
/// 现场专辑算。只收了一首的正式专辑会被当成单曲，在「专辑分类」里改成专辑即可。
public enum AlbumArtistReleaseFilter {
    public static let storageKey = "library.albumArtistsHidesSinglesOnly"

    public static func countsAsFullRelease(
        categories: Set<AlbumReleaseCategory>,
        isManualChoice: Bool,
        songCount: Int
    ) -> Bool {
        guard !categories.isEmpty, !categories.isSubset(of: [.singleEP]) else { return false }
        if isManualChoice || categories.contains(.live) { return true }
        return songCount > 1
    }

    /// 只留下名下至少有一张正式专辑的人，顺序不变。
    public static func artists(
        _ artists: [Artist],
        albumIDsByArtistID: [String: Set<String>],
        isFullRelease: (String) -> Bool
    ) -> [Artist] {
        var verdicts: [String: Bool] = [:]
        return artists.filter { artist in
            (albumIDsByArtistID[artist.id] ?? []).contains { albumID in
                if let known = verdicts[albumID] { return known }
                let verdict = isFullRelease(albumID)
                verdicts[albumID] = verdict
                return verdict
            }
        }
    }
}

/// 「专辑艺术家」列表与只当过专辑艺人的那些人名下的专辑。
public struct AlbumArtistIndex: Sendable {
    /// 每位专辑艺人一项，和曲目艺人列表同样按名字排好。专辑数是他名下的专辑；
    /// 歌曲数与艺人页一致：也唱歌的人是他唱的歌数，只当专辑艺人的人（如「群星」）
    /// 是名下专辑的曲目合计。
    public var artists: [Artist]
    /// 全部专辑署名者 → 他名下的专辑；合作署名共享同一张专辑，不创建专辑副本。
    public var albumIDsByArtistID: [String: Set<String>]
    /// 不是任何曲目艺人的专辑艺人（如「群星」）→ 他名下的专辑，
    /// 按专辑的顺序。这些人没有自己署名的歌，艺人页的歌从这些专辑里取。
    public var albumIDsByAlbumOnlyArtistID: [String: [String]]

    public init(
        artists: [Artist] = [],
        albumIDsByArtistID: [String: Set<String>] = [:],
        albumIDsByAlbumOnlyArtistID: [String: [String]] = [:]
    ) {
        self.artists = artists
        self.albumIDsByArtistID = albumIDsByArtistID
        self.albumIDsByAlbumOnlyArtistID = albumIDsByAlbumOnlyArtistID
    }

    public static let empty = AlbumArtistIndex()
}

public enum AlbumArtistIndexBuilder {
    private struct CreditKey: Hashable {
        let id: String
        let name: String?
    }

    /// - Parameters:
    ///   - albums: 可见专辑。`artistID` 与艺人 id 是同一套哈希（专辑分组名的 groupingKey）。
    ///   - trackArtists: 可见的曲目艺人，已按名字排好序。
    ///   - trackArtistsByID: 同一批曲目艺人按 id 查。
    ///
    /// 同一个人两边都有时沿用曲目艺人的显示名和头像，列表里的名字和点进去的艺人页一致。
    /// 顺序直接沿用 `trackArtists` 已经排好的，只给只当过专辑艺人的那几位排序再归并进去：
    /// 整库艺人再按区域规则排一遍是一笔不小的开销，曲库刷新时要反复做。
    public static func build(
        albums: [Album],
        trackArtists: [Artist],
        trackArtistsByID: [String: Artist],
        configuration: ArtistNameConfiguration,
        artistID: (String) -> String
    ) -> AlbumArtistIndex {
        let configuration = configuration.normalized()
        var albumCountByID: [String: Int] = [:]
        var songCountByID: [String: Int] = [:]
        var albumIDsByArtistID: [String: Set<String>] = [:]
        var albumOnlyAlbumIDs: [String: [String]] = [:]
        var albumOnlyNameByID: [String: String] = [:]
        var creditsByKey: [CreditKey: [(id: String, name: String?)]] = [:]
        for album in albums {
            guard let originalID = album.artistID, !originalID.isEmpty else { continue }
            let key = CreditKey(id: originalID, name: album.artistName)
            let credits: [(id: String, name: String?)]
            if let cached = creditsByKey[key] {
                credits = cached
            } else if let artist = trackArtistsByID[originalID] {
                // 曲目索引已确认的单一艺人（包括原生多人字段中的乐队名）保留身份。
                credits = [(originalID, artist.name)]
                creditsByKey[key] = credits
            } else {
                let names = ArtistNameParser.names(rawName: album.artistName, configuration: configuration)
                if names.isEmpty {
                    credits = [(originalID, nil)]
                } else if names.count == 1,
                          ArtistIdentityPolicy.groupingKey(names[0]) == ArtistIdentityPolicy.groupingKey(album.artistName ?? "") {
                    credits = [(originalID, names[0])]
                } else {
                    credits = names.map { (artistID($0), $0) }
                }
                creditsByKey[key] = credits
            }
            for (id, name) in credits {
                guard albumIDsByArtistID[id, default: []].insert(album.id).inserted else { continue }
                albumCountByID[id, default: 0] += 1
                songCountByID[id, default: 0] += album.songCount
                guard trackArtistsByID[id] == nil else { continue }
                albumOnlyAlbumIDs[id, default: []].append(album.id)
                if albumOnlyNameByID[id] == nil, let name {
                    albumOnlyNameByID[id] = name
                }
            }
        }
        guard !albumCountByID.isEmpty else { return .empty }

        var shared: [Artist] = []
        shared.reserveCapacity(albumCountByID.count - albumOnlyAlbumIDs.count)
        for artist in trackArtists {
            guard let albumCount = albumCountByID[artist.id] else { continue }
            var entry = artist
            entry.albumCount = albumCount
            // 歌曲数保持曲目艺人的口径: 艺人页列的是这个人唱的歌。按专辑累加会把合辑、
            // 合作专辑里别人唱的歌也算进来, 列表上的数字就比点进去的多。
            shared.append(entry)
        }

        var albumOnly: [Artist] = albumOnlyNameByID.map { id, name in
            Artist(
                id: id,
                name: name,
                albumCount: albumCountByID[id] ?? 0,
                songCount: songCountByID[id] ?? 0
            )
        }
        albumOnly.sort(by: precedes)

        return AlbumArtistIndex(
            artists: merged(shared, albumOnly),
            albumIDsByArtistID: albumIDsByArtistID,
            albumIDsByAlbumOnlyArtistID: albumOnlyAlbumIDs.filter { albumOnlyNameByID[$0.key] != nil }
        )
    }

    /// 与曲目艺人列表同一个口径（`localizedCompare`），名字一样时按 id 定先后。
    static func precedes(_ lhs: Artist, _ rhs: Artist) -> Bool {
        switch lhs.name.localizedCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }

    /// 只当过专辑艺人的通常只有几位到几百位：逐个二分找插入点，比较次数随它们的人数走，
    /// 不随整库艺人数走。
    private static func merged(_ lhs: [Artist], _ rhs: [Artist]) -> [Artist] {
        guard !rhs.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return rhs }
        var result: [Artist] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var start = 0
        for item in rhs {
            // 第一个排在 item 后面的曲目艺人；rhs 已排好，从上一个插入点往后找。
            var low = start
            var high = lhs.count
            while low < high {
                let mid = (low + high) / 2
                if precedes(item, lhs[mid]) { high = mid } else { low = mid + 1 }
            }
            result.append(contentsOf: lhs[start..<low])
            result.append(item)
            start = low
        }
        result.append(contentsOf: lhs[start...])
        return result
    }
}
