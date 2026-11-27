import Foundation

/// 流派字段里除了分号之外，还按哪些符号拆。默认一个都不拆：`R&B/Soul`、
/// `Folk, World, & Country` 这类名字本身就带符号，要用户自己决定。
/// ID3 标签的格式另有斜杠惯例（见 `GenreSlashConvention`），打开斜杠后所有斜杠都拆。
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

/// ID3 标签的惯例：TCON 里的斜杠事实上是多值分隔符（ID3v2.3 没有别的多值写法，
/// 主流打标工具都用它连多个流派）。用户没打开「按斜杠拆分」时，ID3 标签的格式按这个惯例拆，
/// 但本身带斜杠的常见流派名（`R&B/Soul`、`Hip-Hop/Rap`、`Singer/Songwriter`……）整段保留，
/// 括号里的斜杠（`Techno (Peak Time / Driving)`）和拆出单个字符的写法（`N/A`）也不拆。
/// 只影响浏览，不改文件。
public enum GenreSlashConvention {
    /// 流派来自 ID3 标签的格式。服务器源同样按文件格式走：服务端没拆开的斜杠照这个惯例拆。
    public static func applies(to format: AudioFormat?) -> Bool {
        guard let format else { return false }
        switch format {
        case .mp3, .mp2, .aac, .aiff, .aif, .wav, .dsf, .dff: return true
        default: return false
        }
    }

    /// 本身带斜杠的常见流派名：Apple Music / iTunes（含各语言版）、YouTube Music、
    /// AllMusic、Discogs、Beatport、Billboard 的分类，以及 ID3v1 表里的 Pop/Funk。
    /// 写法上的空格、连字符、撇号、大小写和全半角都不影响命中。
    public static let protectedNames: [String] = [
        // Apple Music / iTunes
        "Hip-Hop/Rap", "R&B/Soul", "Singer/Songwriter", "Contemporary Singer/Songwriter",
        "Pop/Rock", "Prog-Rock/Art Rock", "Death Metal/Black Metal", "IDM/Experimental",
        "Jungle/Drum'n'bass", "Cantopop/HK-Pop", "Tex-Mex/Tejano",
        "嘻哈/说唱", "说唱/嘻哈", "嘻哈/饶舌", "R&B/灵魂乐", "节奏布鲁斯/灵魂乐",
        "嘻哈/饒舌", "R&B/靈魂樂", "節奏藍調/靈魂樂",
        "ヒップホップ/ラップ", "R&B/ソウル", "힙합/랩", "R&B/소울", "Хип-хоп/рэп", "R&B/соул",
        // 同一类的倒序写法与排行榜分类
        "Rap/Hip-Hop", "Soul/R&B", "R&B/Hip-Hop", "Hip-Hop/R&B", "RnB/Soul",
        // YouTube Music / Google Play
        "Alternative/Indie", "Indie/Alternative", "Dance/Electronic", "Electronic/Dance",
        "Christian/Gospel", "Vocal/Easy Listening",
        // AllMusic、Discogs
        "Comedy/Spoken", "Alternative/Indie Rock", "Punk/New Wave", "Psychedelic/Garage",
        "Folk/Country Rock", "Rock & Roll/Roots", "Club/Dance", "Funk/Soul", "Folk/Rock",
        // Beatport
        "Bass/Club", "Hard Dance/Hardcore", "Breaks/Breakbeat/UK Bass", "Dance/Electro Pop",
        "Dance/Pop", "Minimal/Deep Tech", "Nu Disco/Disco", "Indie Dance/Nu Disco",
        "Organic House/Downtempo", "Electronica/Downtempo", "Ambient/Experimental",
        "Trap/Future Bass", "Trap/Wave", "UK Garage/Bassline", "140/Deep Dubstep/Grime",
        "Funk/Soul/Disco", "Reggae/Dancehall/Dub", "Hardcore/Hard Techno",
        // ID3v1 第 62 号
        "Pop/Funk",
    ]

    private static let protectedKeys = Set(protectedNames.map { key(Substring($0)) })
    private static let ignoredKeyCharacters = CharacterSet(charactersIn: " \t-‐‑–—_'’.·・")
    private static let slashes: Set<Character> = ["/", "／"]
    private static let openers: Set<Character> = ["(", "[", "{", "（", "【", "［", "｛"]
    private static let closers: Set<Character> = [")", "]", "}", "）", "】", "］", "｝"]

    /// 比较用的写法：去掉空格、连字符、撇号、点，折叠大小写、变音和全半角，全角斜杠当半角。
    static func key(_ value: Substring) -> String {
        let folded = String(value)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where !ignoredKeyCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    public static func isProtected(_ name: String) -> Bool {
        protectedKeys.contains(key(Substring(name.trimmingCharacters(in: .whitespacesAndNewlines))))
    }

    /// 一个流派值按斜杠拆开。拆不了或不该拆时原样返回一个元素。
    public static func split(_ value: String) -> [String] {
        guard value.contains(where: { slashes.contains($0) }) else { return [value] }

        // 只在括号外的斜杠处断开，记下每段的范围，保留原文的写法。
        var pieces: [Range<String.Index>] = []
        var depth = 0
        var start = value.startIndex
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if openers.contains(character) {
                depth += 1
            } else if closers.contains(character) {
                depth = max(0, depth - 1)
            } else if depth == 0, slashes.contains(character) {
                pieces.append(start..<index)
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        pieces.append(start..<value.endIndex)

        func trimmed(_ range: Range<String.Index>) -> Substring {
            let text = value[range]
            guard let first = text.firstIndex(where: { !$0.isWhitespace }),
                  let last = text.lastIndex(where: { !$0.isWhitespace }) else { return text[text.startIndex..<text.startIndex] }
            return text[first...last]
        }

        let parts = pieces.filter { !trimmed($0).isEmpty }
        guard parts.count > 1 else {
            return parts.first.map { [String(trimmed($0))] } ?? [value]
        }
        // `N/A`、`A/B` 这类：拆出来只剩一个字符，说明斜杠不是在分隔流派。
        guard parts.allSatisfy({ trimmed($0).count >= 2 }) else { return [value] }

        var result: [String] = []
        var position = 0
        while position < parts.count {
            var matchedEnd: Int?
            // 保护表里最长的名字有三段。
            for end in stride(from: min(parts.count, position + 3), to: position + 1, by: -1) {
                let span = value[parts[position].lowerBound..<parts[end - 1].upperBound]
                if protectedKeys.contains(key(span)) {
                    matchedEnd = end
                    break
                }
            }
            if let matchedEnd {
                let span = parts[position].lowerBound..<parts[matchedEnd - 1].upperBound
                result.append(String(trimmed(span)))
                position = matchedEnd
            } else {
                result.append(String(trimmed(parts[position])))
                position += 1
            }
        }
        return result
    }
}

/// Multi-value genre tags use a semicolon-separated string in the existing
/// song field. Slashes and commas remain part of a label (e.g. R&B/Soul)
/// unless the user opted into splitting on them for browsing, or the
/// file format's tag convention treats slashes as separators.
public enum GenreTagValues {
    /// 写进标签、发给服务器时用的拆法：只认分号（半角、全角）。
    public static func names(in value: String?) -> [String] {
        names(in: value, alsoSplitting: [])
    }

    public static func names(
        in value: String?,
        alsoSplitting extra: GenreSeparatorOptions,
        slashConvention: Bool = false
    ) -> [String] {
        guard let value else { return [] }
        let splitsSlashByConvention = slashConvention && !extra.contains(.slash)
        var seen = Set<String>()
        var result: [String] = []
        for piece in value.components(separatedBy: CharacterSet(charactersIn: ";；\0" + extra.characters)) {
            let name = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for part in splitsSlashByConvention ? GenreSlashConvention.split(name) : [name]
            where seen.insert(LibraryGenreIndexBuilder.normalizedID(for: part)).inserted {
                result.append(part)
            }
        }
        return result
    }

    /// 浏览时用的拆法：分号之外再按用户选的符号拆；不知道文件格式时不套格式惯例。
    public static func browseNames(in value: String?) -> [String] {
        browseNames(in: value, format: nil)
    }

    /// 浏览时用的拆法：分号之外再按用户选的符号拆，ID3 标签的格式再按斜杠惯例拆。
    public static func browseNames(in value: String?, format: AudioFormat?) -> [String] {
        names(
            in: value,
            alsoSplitting: GenreSplitPreference.current,
            slashConvention: GenreSlashConvention.applies(to: format)
        )
    }

    public static func browseNames(for song: Song) -> [String] {
        browseNames(in: song.genre, format: song.fileFormat)
    }

    public static func browsePrimary(in value: String?) -> String? {
        browseNames(in: value).first
    }

    public static func browsePrimary(for song: Song) -> String? {
        browseNames(for: song).first
    }

    public static func joined(_ values: [String]) -> String? {
        let names = names(in: values.joined(separator: "; "))
        return names.isEmpty ? nil : names.joined(separator: "; ")
    }

    /// 只能比一个流派的地方取第一个：多值之前扫描的歌只存了这一个，两边口径一致。
    /// 单值原样返回（不裁空白），整库逐首调用时不必拆分。
    public static func primary(in value: String?) -> String? {
        guard let value else { return nil }
        // 全角分号的 UTF-8 是 EF BC 9B：看到 0x9B 再确认一次，其余单值仍原样返回。
        let bytes = value.utf8
        guard bytes.contains(where: { $0 == UInt8(ascii: ";") || $0 == 0 })
            || (bytes.contains(0x9B) && value.contains("；")) else {
            return value
        }
        return names(in: value).first
    }
}

/// 流派页菜单里那句提示：流派名里还带着可拆的符号、用户又没开对应的拆分时，提一句有几个。
/// 不弹窗、不挂在别处，只是菜单项下面的一行说明。
public enum GenreSeparatorHint {
    /// 还带着没拆的斜杠、逗号或竖线的流派名有几个。用户已经开了的符号不算，
    /// 本身带斜杠的常见流派名（保护表里的）不算。
    public static func unsplitNameCount(
        in names: [String],
        enabled: GenreSeparatorOptions
    ) -> Int {
        let commaCharacters = Set(GenreSeparatorOptions.comma.characters)
        let barCharacters = Set(GenreSeparatorOptions.bar.characters)
        let slashCharacters = Set(GenreSeparatorOptions.slash.characters)
        return names.reduce(into: 0) { count, name in
            let hasSlash = !enabled.contains(.slash)
                && name.contains(where: { slashCharacters.contains($0) })
                && !GenreSlashConvention.isProtected(name)
            let hasComma = !enabled.contains(.comma) && name.contains(where: { commaCharacters.contains($0) })
            let hasBar = !enabled.contains(.bar) && name.contains(where: { barCharacters.contains($0) })
            if hasSlash || hasComma || hasBar { count += 1 }
        }
    }

    /// 值得提：至少 3 个，并且占到全部流派的十分之一。
    public static func shouldHint(unsplitCount: Int, totalCount: Int) -> Bool {
        unsplitCount >= 3 && unsplitCount * 10 >= totalCount
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
        // ID3 格式的歌另按斜杠惯例拆, 两种拆法各记一份。
        var resolvedByGenre: [String: [(displayName: String, id: String)]] = [:]
        var resolvedBySlashConvention: [String: [(displayName: String, id: String)]] = [:]

        for (position, song) in songs.enumerated() {
            guard let genre = song.genre else { continue }
            let slashConvention = GenreSlashConvention.applies(to: song.fileFormat)
            let lookup: [(displayName: String, id: String)]
            if let memoized = slashConvention ? resolvedBySlashConvention[genre] : resolvedByGenre[genre] {
                lookup = memoized
            } else {
                lookup = GenreTagValues.names(
                    in: genre,
                    alsoSplitting: separators,
                    slashConvention: slashConvention
                ).map { ($0, normalizedID(for: $0)) }
                if slashConvention {
                    resolvedBySlashConvention[genre] = lookup
                } else {
                    resolvedByGenre[genre] = lookup
                }
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
