import Foundation

/// 流派字段里除了分号之外，还按哪些符号拆。默认一个都不拆：`R&B/Soul`、
/// `Folk, World, & Country` 这类名字本身就带符号，要用户自己决定。
/// `&` 和 and 不在可选范围内（`R&B`、`Drum & Bass`）。
public struct GenreSeparatorOptions: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue & 0b111
    }

    public static let slash = GenreSeparatorOptions(rawValue: 1 << 0)
    public static let comma = GenreSeparatorOptions(rawValue: 1 << 1)
    public static let bar = GenreSeparatorOptions(rawValue: 1 << 2)

    /// 半角和全角写法一起认。
    var characters: String {
        var result = ""
        if contains(.slash) { result += "/／" }
        if contains(.comma) { result += ",，、" }
        if contains(.bar) { result += "|｜\\" }
        return result
    }
}

/// 用户选的拆分符号。只影响浏览（流派列表、智能歌单、语音点播、标签编辑里的候选），
/// 不改文件里的标签，关掉就恢复原样。
public enum GenreSplitPreference {
    public static let storageKey = "primuse.genre.extraSeparators.v1"

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var value: GenreSeparatorOptions?
    }

    private static let storage = Storage()

    /// 整库逐首都会读，值缓存在内存里；设置改了之后由 `refresh()` 更新。
    public static var current: GenreSeparatorOptions {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if let value = storage.value { return value }
        let loaded = stored(in: .standard)
        storage.value = loaded
        return loaded
    }

    /// 重新读一次设置；值变了返回 true。
    @discardableResult
    public static func refresh(from defaults: UserDefaults = .standard) -> Bool {
        let loaded = stored(in: defaults)
        storage.lock.lock()
        defer { storage.lock.unlock() }
        guard storage.value != loaded else { return false }
        let hadValue = storage.value != nil
        storage.value = loaded
        return hadValue || !loaded.isEmpty
    }

    private static func stored(in defaults: UserDefaults) -> GenreSeparatorOptions {
        GenreSeparatorOptions(rawValue: defaults.integer(forKey: storageKey))
    }
}

/// Multi-value genre tags use a semicolon-separated string in the existing
/// song field. Slashes and commas remain part of a label (e.g. R&B/Soul)
/// unless the user opted into splitting on them for browsing.
public enum GenreTagValues {
    /// 写进标签、发给服务器时用的拆法：只认分号。
    public static func names(in value: String?) -> [String] {
        names(in: value, alsoSplitting: [])
    }

    public static func names(in value: String?, alsoSplitting extra: GenreSeparatorOptions) -> [String] {
        guard let value else { return [] }
        var seen = Set<String>()
        return value.components(separatedBy: CharacterSet(charactersIn: ";\0" + extra.characters)).compactMap {
            let name = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  seen.insert(LibraryGenreIndexBuilder.normalizedID(for: name)).inserted else {
                return nil
            }
            return name
        }
    }

    /// 浏览时用的拆法：分号之外再按用户选的符号拆。
    public static func browseNames(in value: String?) -> [String] {
        names(in: value, alsoSplitting: GenreSplitPreference.current)
    }

    public static func browsePrimary(in value: String?) -> String? {
        browseNames(in: value).first
    }

    public static func joined(_ values: [String]) -> String? {
        let names = names(in: values.joined(separator: "; "))
        return names.isEmpty ? nil : names.joined(separator: "; ")
    }

    /// 只能比一个流派的地方取第一个：多值之前扫描的歌只存了这一个，两边口径一致。
    /// 单值原样返回（不裁空白），整库逐首调用时不必拆分。
    public static func primary(in value: String?) -> String? {
        guard let value else { return nil }
        guard value.utf8.contains(where: { $0 == UInt8(ascii: ";") || $0 == 0 }) else { return value }
        return names(in: value).first
    }
}

/// 服务器在单独的数组里给全部流派（OpenSubsonic 的 `genres: [{"name": …}]`，也认纯字符串数组）。
/// 认不出的写法当没有，不能连累整首歌解码失败。
public struct ServerGenreList: Decodable, Sendable, Equatable {
    public let names: [String]

    public init(names: [String]) {
        self.names = names
    }

    private struct Entry: Decodable {
        let name: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try? decoder.singleValueContainer()
        if let entries = try? container?.decode([Entry].self) {
            names = entries.compactMap(\.name)
        } else {
            names = (try? container?.decode([String].self)) ?? []
        }
    }

    /// 有不止一个流派时按分号拼起来；只有一个时用服务器自己的 `genre` 字段，和以前一致。
    public func genre(fallback: String?) -> String? {
        let joined = GenreTagValues.joined(names)
        return GenreTagValues.names(in: joined).count > 1 ? joined : fallback ?? joined
    }
}

public struct LibraryGenre: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let songCount: Int
    public let albumCount: Int
    public let representativeSongIDs: [String]

    public init(
        id: String,
        name: String,
        songCount: Int,
        albumCount: Int,
        representativeSongIDs: [String]
    ) {
        self.id = id
        self.name = name
        self.songCount = songCount
        self.albumCount = albumCount
        self.representativeSongIDs = representativeSongIDs
    }
}

public struct LibraryGenreIndex: Sendable {
    public let genres: [LibraryGenre]
    public let songIDsByGenreID: [String: [String]]
    public let albumIDsByGenreID: [String: [String]]

    public init(
        genres: [LibraryGenre],
        songIDsByGenreID: [String: [String]],
        albumIDsByGenreID: [String: [String]]
    ) {
        self.genres = genres
        self.songIDsByGenreID = songIDsByGenreID
        self.albumIDsByGenreID = albumIDsByGenreID
    }
}

public enum LibraryGenreIndexBuilder {
    private struct Group {
        var displayName: String
        var songPositions: [Int] = []
        var albumIDs: [String] = []
        var seenAlbumIDs: Set<String> = []

        mutating func append(_ song: Song, at position: Int) {
            songPositions.append(position)
            if let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !albumID.isEmpty,
               seenAlbumIDs.insert(albumID).inserted {
                albumIDs.append(albumID)
            }
        }
    }

    public static func build(
        from songs: [Song],
        alsoSplitting separators: GenreSeparatorOptions = GenreSplitPreference.current
    ) -> LibraryGenreIndex {
        var groups: [String: Group] = [:]
        // 整库只有几十种流派写法, 折叠要带区域设置, 按原始字符串各算一次。
        var resolvedByGenre: [String: [(displayName: String, id: String)]] = [:]

        for (position, song) in songs.enumerated() {
            guard let genre = song.genre else { continue }
            let lookup: [(displayName: String, id: String)]
            if let memoized = resolvedByGenre[genre] {
                lookup = memoized
            } else {
                lookup = GenreTagValues.names(in: genre, alsoSplitting: separators).map { ($0, normalizedID(for: $0)) }
                resolvedByGenre[genre] = lookup
            }
            for resolved in lookup where !resolved.id.isEmpty {
                // Keep each group's buffers uniquely owned while appending;
                // copying it out of the dictionary copies a growing array per song.
                groups[resolved.id, default: Group(displayName: resolved.displayName)].append(song, at: position)
            }
        }

        let orderedIDs = groups.keys.sorted()
        let genres = orderedIDs.compactMap { genreID -> LibraryGenre? in
            guard let group = groups[genreID] else { return nil }
            return LibraryGenre(
                id: genreID,
                name: group.displayName,
                songCount: group.songPositions.count,
                albumCount: group.albumIDs.count,
                representativeSongIDs: representativeSongIDs(in: songs, positions: group.songPositions)
            )
        }

        return LibraryGenreIndex(
            genres: genres,
            songIDsByGenreID: groups.mapValues { $0.songPositions.map { songs[$0].id } },
            albumIDsByGenreID: groups.mapValues(\.albumIDs)
        )
    }

    public static func normalizedID(for value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    /// 排名: 有封面在前, 年份新的在前, 再按 id。
    private static func ranksBefore(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsHasArtwork = lhs.coverArtFileName?.isEmpty == false
        let rhsHasArtwork = rhs.coverArtFileName?.isEmpty == false
        if lhsHasArtwork != rhsHasArtwork { return lhsHasArtwork }

        let lhsYear = lhs.year ?? Int.min
        let rhsYear = rhs.year ?? Int.min
        if lhsYear != rhsYear { return lhsYear > rhsYear }
        return lhs.id < rhs.id
    }

    /// 按排名先取 3 张不同专辑各自最靠前的一首, 不够 3 首再按排名补。
    /// 只需线性扫描: 按排名走到的每张专辑第一首就是它排名最高的歌, 所以
    /// 「先各专辑取最高, 再取前三张」与「整组排序后顺着挑」结果相同, 而
    /// 大流派动辄上万首, 整组排序是启动时最贵的一步。
    private static func representativeSongIDs(in songs: [Song], positions: [Int]) -> [String] {
        // 只保存原数组的位置；大流派不能为每首歌、每张专辑再复制完整 Song。
        var bestByAlbumID: [String: Int] = [:]
        for position in positions {
            let song = songs[position]
            guard let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !albumID.isEmpty else { continue }
            if let current = bestByAlbumID[albumID], !ranksBefore(song, songs[current]) { continue }
            bestByAlbumID[albumID] = position
        }
        var selected = topRanked(3, in: songs, positions: bestByAlbumID.values)
        if selected.count < 3 {
            let selectedIDs = Set(selected.map { songs[$0].id })
            var bestByID: [String: Int] = [:]
            for position in positions where !selectedIDs.contains(songs[position].id) {
                let song = songs[position]
                if let current = bestByID[song.id], !ranksBefore(song, songs[current]) { continue }
                bestByID[song.id] = position
            }
            selected.append(contentsOf: topRanked(3 - selected.count, in: songs, positions: bestByID.values))
        }
        return selected.map { songs[$0].id }
    }

    /// 排名最前的 `limit` 首(最多 3 首), 按排名顺序, 线性插入。
    private static func topRanked<S: Sequence>(
        _ limit: Int, in songs: [Song], positions: S
    ) -> [Int] where S.Element == Int {
        guard limit > 0 else { return [] }
        var top: [Int] = []
        top.reserveCapacity(limit + 1)
        for position in positions {
            let song = songs[position]
            guard top.count < limit || ranksBefore(song, songs[top[top.count - 1]]) else { continue }
            let insertion = top.firstIndex { ranksBefore(song, songs[$0]) } ?? top.count
            top.insert(position, at: insertion)
            if top.count > limit { top.removeLast() }
        }
        return top
    }
}
