import Foundation

/// 资料库「艺术家」页列哪些人。
///
/// `allArtists` 列参与演唱的每一位：曲目艺人按分隔符拆开，合辑里的每位歌手、feat. 的嘉宾
/// 各占一项。`albumArtists` 只列专辑艺人，取值和专辑分组用的是同一个名字（读到 ALBUMARTIST
/// 用它，读不到退回曲目艺人），一张专辑只算在一个人名下，合辑归在「群星 / Various Artists」
/// 这类名字下。专辑怎么合并跟这里无关，两种模式下专辑都一样。
public enum ArtistBrowseMode: String, CaseIterable, Sendable {
    case allArtists
    case albumArtists

    /// 本机偏好，不走 iCloud：iPhone / iPad / Mac 与电视各自一份，CarPlay 跟着手机。
    public static let storageKey = "library.artistBrowseMode"

    public static func resolved(_ rawValue: String?) -> ArtistBrowseMode {
        rawValue.flatMap(Self.init(rawValue:)) ?? .allArtists
    }
}

/// 「专辑艺术家」列表与只当过专辑艺人的那些人名下的专辑。
public struct AlbumArtistIndex: Sendable {
    /// 每位专辑艺人一项，和曲目艺人列表同样按名字排好。专辑数是他名下的专辑，
    /// 歌曲数是这些专辑的曲目合计。
    public var artists: [Artist]
    /// 不是任何曲目艺人的专辑艺人（「群星」、合写成一个名字的「A & B」）→ 他名下的专辑，
    /// 按专辑的顺序。这些人没有自己署名的歌，艺人页的歌从这些专辑里取。
    public var albumIDsByAlbumOnlyArtistID: [String: [String]]

    public init(artists: [Artist] = [], albumIDsByAlbumOnlyArtistID: [String: [String]] = [:]) {
        self.artists = artists
        self.albumIDsByAlbumOnlyArtistID = albumIDsByAlbumOnlyArtistID
    }

    public static let empty = AlbumArtistIndex()
}

public enum AlbumArtistIndexBuilder {
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
        trackArtistsByID: [String: Artist]
    ) -> AlbumArtistIndex {
        var albumCountByID: [String: Int] = [:]
        var songCountByID: [String: Int] = [:]
        var albumOnlyAlbumIDs: [String: [String]] = [:]
        var albumOnlyNameByID: [String: String] = [:]
        for album in albums {
            guard let id = album.artistID, !id.isEmpty else { continue }
            albumCountByID[id, default: 0] += 1
            songCountByID[id, default: 0] += album.songCount
            guard trackArtistsByID[id] == nil else { continue }
            albumOnlyAlbumIDs[id, default: []].append(album.id)
            if albumOnlyNameByID[id] == nil,
               let name = album.artistName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                albumOnlyNameByID[id] = name
            }
        }
        guard !albumCountByID.isEmpty else { return .empty }

        var shared: [Artist] = []
        shared.reserveCapacity(albumCountByID.count - albumOnlyAlbumIDs.count)
        for artist in trackArtists {
            guard let albumCount = albumCountByID[artist.id] else { continue }
            var entry = artist
            entry.albumCount = albumCount
            entry.songCount = songCountByID[artist.id] ?? 0
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
