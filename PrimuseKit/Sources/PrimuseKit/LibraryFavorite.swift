import Foundation

public enum LibraryFavoriteKind: String, Codable, Sendable, CaseIterable {
    case album
    case artist
}

/// 专辑 / 艺人的「喜欢」。和歌曲的喜欢（系统歌单「我喜欢」）互不影响：喜欢一张专辑
/// 不会把里面的歌都标成喜欢，反过来也一样。
///
/// 按名字认，不按 `Album.id` / `Artist.id`：那两个是名字原文的哈希，专辑艺术家没读到时
/// 还会掺进当前语言的「未知艺术家」，换语言、改个大小写就对不上了。这里的键折叠大小写、
/// 全半角与变音符，跨设备、跨语言一致。
///
/// 取消喜欢写墓碑（`deletedAt`）而不是直接删，好让 iCloud 上另一台设备知道这是取消而
/// 不是还没同步到；墓碑过一段时间清掉。
public struct LibraryFavorite: Codable, Sendable, Equatable, Identifiable {
    public let kind: LibraryFavoriteKind
    /// 专辑名；艺人的喜欢为空串。
    public let albumTitle: String
    /// 专辑艺术家 / 艺人名，按显示用的原文存。没有专辑艺术家的专辑是空串。
    public let artistName: String
    public var likedAt: Date
    public var modifiedAt: Date
    public var deletedAt: Date?

    public init(
        kind: LibraryFavoriteKind,
        albumTitle: String,
        artistName: String,
        likedAt: Date,
        modifiedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.kind = kind
        self.albumTitle = kind == .album ? albumTitle : ""
        self.artistName = artistName
        self.likedAt = likedAt
        self.modifiedAt = modifiedAt ?? likedAt
        self.deletedAt = deletedAt
    }

    public var id: String {
        LibraryFavoriteKey.id(kind: kind, albumTitle: albumTitle, artistName: artistName)
    }

    public var isActive: Bool { deletedAt == nil }

    /// 同一条的两份（本机 / iCloud）留哪份：修改时间新的赢，一样新时保留「喜欢」。
    public static func newer(_ lhs: LibraryFavorite, _ rhs: LibraryFavorite) -> LibraryFavorite {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs }
        return lhs.isActive ? lhs : rhs
    }
}

public enum LibraryFavoriteKey {
    /// 稳定 id：类型 + 折叠后的名字，再取两个 64 位 FNV-1a 拼成 32 位十六进制，
    /// 能直接当 CloudKit 记录名用。`unknownArtistName` 是本机语言的「未知艺术家」，
    /// 它和空串当作同一个艺人。
    public static func id(
        kind: LibraryFavoriteKind,
        albumTitle: String,
        artistName: String,
        unknownArtistName: String? = nil
    ) -> String {
        let normalized = "\(kind.rawValue)\u{1F}\(foldedAlbum(kind == .album ? albumTitle : ""))\u{1F}\(foldedArtist(artistName, unknownArtistName: unknownArtistName))"
        let bytes = Array(normalized.utf8)
        return "\(kind.rawValue)-\(hex(fnv1a(bytes, basis: 0xcbf2_9ce4_8422_2325)))\(hex(fnv1a(bytes, basis: 0x8422_2325_cbf2_9ce4)))"
    }

    public static func foldedArtist(_ name: String, unknownArtistName: String? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let unknownArtistName,
           trimmed == unknownArtistName.trimmingCharacters(in: .whitespacesAndNewlines) {
            return ""
        }
        return fold(trimmed)
    }

    static func foldedAlbum(_ title: String) -> String { fold(title) }

    private static func fold(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func fnv1a(_ bytes: [UInt8], basis: UInt64) -> UInt64 {
        var hash = basis
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// 一组「喜欢」在本机的合并与查询，存储与同步都围着它转。
public struct LibraryFavoriteLedger: Codable, Sendable, Equatable {
    public private(set) var entries: [String: LibraryFavorite]

    public init(entries: [LibraryFavorite] = []) {
        var map: [String: LibraryFavorite] = [:]
        for entry in entries {
            map[entry.id] = map[entry.id].map { LibraryFavorite.newer($0, entry) } ?? entry
        }
        self.entries = map
    }

    public func isLiked(_ id: String) -> Bool { entries[id]?.isActive == true }

    /// 生效的喜欢，最近喜欢的在前。
    public func active(_ kind: LibraryFavoriteKind) -> [LibraryFavorite] {
        entries.values
            .filter { $0.kind == kind && $0.isActive }
            .sorted { $0.likedAt != $1.likedAt ? $0.likedAt > $1.likedAt : $0.id < $1.id }
    }

    /// 本机切换。返回改动后的那一条（交给同步）。
    @discardableResult
    public mutating func set(
        kind: LibraryFavoriteKind,
        albumTitle: String,
        artistName: String,
        liked: Bool,
        at date: Date
    ) -> LibraryFavorite? {
        let probe = LibraryFavorite(kind: kind, albumTitle: albumTitle, artistName: artistName, likedAt: date)
        let existing = entries[probe.id]
        guard (existing?.isActive == true) != liked else { return nil }
        var entry = liked
            ? probe
            : (existing ?? probe)
        entry.modifiedAt = max(date, (existing?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
        entry.deletedAt = liked ? nil : entry.modifiedAt
        if liked { entry.likedAt = date }
        entries[entry.id] = entry
        return entry
    }

    /// 远端来的一条。本机的更新就不动；返回是否改了本机。
    @discardableResult
    public mutating func applyRemote(_ remote: LibraryFavorite) -> Bool {
        if let local = entries[remote.id], LibraryFavorite.newer(local, remote) == local {
            return false
        }
        entries[remote.id] = remote
        return true
    }

    public mutating func removeRemote(id: String) {
        entries[id] = nil
    }

    /// 早于 `threshold` 的墓碑清掉，返回被清的 id（同步要把云端那条也删掉）。
    public mutating func pruneTombstones(before threshold: Date) -> [String] {
        let stale = entries.values.filter { ($0.deletedAt ?? .distantFuture) < threshold }.map(\.id)
        for id in stale { entries[id] = nil }
        return stale.sorted()
    }
}

/// 一个服务器源上专辑 / 艺人收藏与本机喜欢的双向对账（服务端：Subsonic 的 star、
/// Jellyfin/Emby 的收藏）。`baseline` 是上次对账后认为服务端收藏着的键，`lastSyncedAt`
/// 是那次对账的时刻。
///
/// - 第一次（没有基线）只把服务端的收藏带进本机，不把本机已有的喜欢整批推上去；
///   本机已经明确取消过的（有墓碑）也不带进来。
/// - 之后：服务端比基线多出来的 → 本机点上；基线里有、服务端没了 → 本机取消；
///   但本机在上次对账之后改过的那一条以本机为准，反过来推到服务端（也兜住推送失败后的重试）。
public enum ServerCollectionFavoriteReconciliation {
    public struct Plan: Equatable, Sendable {
        public var likeLocally: Set<String> = []
        public var unlikeLocally: Set<String> = []
        public var starOnServer: Set<String> = []
        public var unstarOnServer: Set<String> = []

        public init() {}
    }

    public static func plan(
        serverKeys: Set<String>,
        baseline: Set<String>?,
        lastSyncedAt: Date?,
        local: [String: LibraryFavorite]
    ) -> Plan {
        var plan = Plan()
        guard let baseline, let lastSyncedAt else {
            for key in serverKeys where local[key] == nil {
                plan.likeLocally.insert(key)
            }
            return plan
        }
        func changedLocallySinceSync(_ key: String) -> Bool {
            (local[key]?.modifiedAt ?? .distantPast) > lastSyncedAt
        }
        for key in serverKeys.union(baseline).union(local.keys) {
            let onServer = serverKeys.contains(key)
            let wasOnServer = baseline.contains(key)
            let localEntry = local[key]
            let likedLocally = localEntry?.isActive == true
            if changedLocallySinceSync(key) {
                // 本机后来改过：以本机为准。
                if likedLocally, !onServer { plan.starOnServer.insert(key) }
                if !likedLocally, onServer { plan.unstarOnServer.insert(key) }
                continue
            }
            if onServer, !wasOnServer, !likedLocally {
                plan.likeLocally.insert(key)
            } else if !onServer, wasOnServer, likedLocally {
                plan.unlikeLocally.insert(key)
            }
        }
        return plan
    }
}
