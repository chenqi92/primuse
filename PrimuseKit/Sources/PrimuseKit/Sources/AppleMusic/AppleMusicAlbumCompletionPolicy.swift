import Foundation

/// 专辑页用 Apple Music 目录补全整张专辑:资料库里只收了其中几首时,其余曲目也列出来。
public enum AppleMusicAlbumCompletionPolicy {
    public enum Slot: Equatable, Sendable {
        /// 资料库里已有的那一首(下标指向传入的资料库曲目)。
        case library(Int)
        /// 只在目录里的那一首(下标指向传入的目录曲目)。
        case catalog(Int)
    }

    /// 按目录曲序排出整张专辑。目录里每首先找资料库里的同一首(ID 交叉对上为准,
    /// 对不上再按歌名、歌手、时长保守匹配),找到就用资料库那一行;一首资料库曲目
    /// 只被认领一次。没被认领的资料库曲目(目录里没有,比如自己导入的版本)排在最后。
    public static func merge(
        catalogTracks: [AppleMusicTrackIdentity],
        librarySongs: [AppleMusicTrackIdentity]
    ) -> [Slot] {
        let index = AppleMusicTrackIdentityIndex(librarySongs)
        var libraryIndexByItemID: [String: Int] = [:]
        for (offset, song) in librarySongs.enumerated() where libraryIndexByItemID[song.itemID] == nil {
            libraryIndexByItemID[song.itemID] = offset
        }
        var claimed = Set<Int>()
        var slots: [Slot] = []
        slots.reserveCapacity(max(catalogTracks.count, librarySongs.count))
        for (offset, track) in catalogTracks.enumerated() {
            if let itemID = index.canonicalID(for: track),
               let libraryOffset = libraryIndexByItemID[itemID],
               claimed.insert(libraryOffset).inserted {
                slots.append(.library(libraryOffset))
            } else {
                slots.append(.catalog(offset))
            }
        }
        for offset in librarySongs.indices where !claimed.contains(offset) {
            slots.append(.library(offset))
        }
        return slots
    }

    /// 目录给回来的专辑是不是资料库里这一张:专辑名去掉版本说明后一致,或一方包含另一方
    /// (「Album」与「Album (Deluxe Edition)」)。对不上就不补,免得把别的专辑的曲目塞进来。
    public static func albumTitlesMatch(_ catalogTitle: String, _ libraryTitle: String) -> Bool {
        let lhs = AppleMusicCatalogContinuationPolicy.titleKey(catalogTitle)
        let rhs = AppleMusicCatalogContinuationPolicy.titleKey(libraryTitle)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }
}

/// 曲库里一首都没有的 Apple Music 专辑:播放目录曲时「前往专辑」打开的是按目录现拼的专辑页。
/// 专辑 ID 带着正在放的那首目录歌的 ID,专辑页凭它向目录取整张。曲库专辑的 ID 是专辑艺人加
/// 专辑名的哈希,两种不会撞上;按专辑 ID 记账的收藏、评价也凭这个前缀认出它,不记。
public enum AppleMusicCatalogAlbumIdentity {
    private static let prefix = "applemusic-catalog-album:"
    /// 搜索结果里点开的目录专辑没有种子歌,直接带专辑自己的目录 ID。
    /// 目录歌与资料库条目的 ID 是数字或 `i.` 开头,不会撞上这个前缀。
    private static let albumSeedPrefix = "album."

    public static func albumID(seedItemID: String) -> String {
        prefix + seedItemID
    }

    public static func albumID(catalogAlbumID: String) -> String {
        prefix + albumSeedPrefix + catalogAlbumID
    }

    /// 按种子歌拼的专辑才有;不是这种专辑、或者是按专辑 ID 打开的,返回 nil。
    public static func seedItemID(fromAlbumID albumID: String) -> String? {
        guard let seed = seed(fromAlbumID: albumID), !seed.hasPrefix(albumSeedPrefix) else { return nil }
        return seed
    }

    /// 从搜索结果按专辑 ID 打开的目录专辑才有。
    public static func catalogAlbumID(fromAlbumID albumID: String) -> String? {
        guard let seed = seed(fromAlbumID: albumID), seed.hasPrefix(albumSeedPrefix) else { return nil }
        let id = String(seed.dropFirst(albumSeedPrefix.count))
        return id.isEmpty ? nil : id
    }

    public static func isCatalogAlbum(_ albumID: String) -> Bool {
        seed(fromAlbumID: albumID) != nil
    }

    private static func seed(fromAlbumID albumID: String) -> String? {
        guard albumID.hasPrefix(prefix) else { return nil }
        let seed = String(albumID.dropFirst(prefix.count))
        return seed.isEmpty ? nil : seed
    }
}
