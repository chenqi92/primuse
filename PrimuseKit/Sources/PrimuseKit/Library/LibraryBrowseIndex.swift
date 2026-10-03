import Foundation

/// 按名字浏览曲库时共用的排序键与首字母分组(电视海报墙索引、CarPlay 列表、歌曲列表索引)。
///
/// 规则:非拉丁文字先转写成拉丁(中文得到拼音、日文假名得到罗马字、西里尔 / 阿拉伯 /
/// 波斯文各自转写),再去掉声调、全半角与大小写差异。首字母落在 A–Z 之外的(数字、符号、
/// 没有拉丁读法的文字)归 "#",排在 Z 后面。这样「Beyond」和「北京」都在 B 下面相邻,
/// 而不是按文字体系分成前后两大块。
public enum LibraryCollationPolicy {
    public static let otherBucket = "#"
    public static let letterBuckets: [String] = (UInt8(ascii: "A")...UInt8(ascii: "Z"))
        .map { String(UnicodeScalar($0)) }
    /// 索引栏的完整顺序:A–Z,然后 "#"。
    public static let buckets: [String] = letterBuckets + [otherBucket]

    /// 只看开头这么多个字符:先后顺序几乎总在前几个字里分出来。
    static let keyPrefixLength = 24

    public struct Key: Comparable, Hashable, Sendable {
        /// 0–25 对应 A–Z,26 是 "#"。
        public let bucketIndex: Int
        /// 转写、折叠后的小写文本,同一个字母下靠它排先后。
        public let text: String

        public var bucket: String { LibraryCollationPolicy.buckets[bucketIndex] }

        public static func < (lhs: Key, rhs: Key) -> Bool {
            lhs.bucketIndex != rhs.bucketIndex ? lhs.bucketIndex < rhs.bucketIndex : lhs.text < rhs.text
        }
    }

    /// 排在所有名字之后的键(给「未知艺术家」这类占位名用)。
    public static let trailingKey = Key(bucketIndex: letterBuckets.count, text: "\u{10FFFF}")

    /// 非 ASCII 字符逐个转写并按码位缓存:整串转写每次都要建一个 ICU 转写器,
    /// 一万多张专辑要好几秒;而曲库里出现的不同汉字只有几千个。
    public static func key(for name: String) -> Key {
        let scalars = trimmedScalars(name)
        guard let first = scalars.first else {
            return Key(bucketIndex: letterBuckets.count, text: "")
        }
        var text: [UInt8] = []
        text.reserveCapacity(keyPrefixLength * 3)
        for scalar in scalars.prefix(keyPrefixLength) {
            switch scalar.value {
            case 0x41...0x5A: text.append(UInt8(scalar.value + 0x20))
            case 0..<0x80: text.append(UInt8(scalar.value))
            default: text.append(contentsOf: CharacterReadings.shared.reading(of: scalar).utf8)
            }
        }
        return Key(bucketIndex: bucketIndex(forFirstScalar: first), text: String(decoding: text, as: UTF8.self))
    }

    /// 名字归到哪个索引字母("A"–"Z" 或 "#")。
    public static func indexLetter(for name: String) -> String {
        guard let first = trimmedScalars(name).first else { return otherBucket }
        return buckets[bucketIndex(forFirstScalar: first)]
    }

    /// 只看第一个字符。
    public static func indexLetter(forFirstCharacter first: Character) -> String {
        guard let scalar = first.unicodeScalars.first else { return otherBucket }
        return buckets[bucketIndex(forFirstScalar: scalar)]
    }

    static func bucketIndex(forFirstScalar scalar: UnicodeScalar) -> Int {
        switch scalar.value {
        case 0x41...0x5A: return Int(scalar.value) - 0x41
        case 0x61...0x7A: return Int(scalar.value) - 0x61
        case 0..<0x80: return letterBuckets.count
        default: return CharacterReadings.shared.reading(of: scalar).bucketIndex
        }
    }

    /// 去掉首尾空白。名字多半两头本来就没有空白,先看一眼再决定要不要真的去
    /// (`trimmingCharacters` 在大库上是可观的一笔)。
    private static func trimmedScalars(_ name: String) -> Substring.UnicodeScalarView {
        let scalars = Substring(name).unicodeScalars
        guard let first = scalars.first, let last = scalars.last else { return scalars }
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard whitespace.contains(first) || whitespace.contains(last) else { return scalars }
        guard let start = scalars.firstIndex(where: { !whitespace.contains($0) }),
              let end = scalars.lastIndex(where: { !whitespace.contains($0) }) else {
            return scalars[scalars.endIndex...]
        }
        return scalars[start...end]
    }

    /// 单个非 ASCII 码位的拉丁读法与它归属的索引字母。
    private final class CharacterReadings: @unchecked Sendable {
        struct Reading {
            let utf8: [UInt8]
            let bucketIndex: Int
        }

        static let shared = CharacterReadings()
        /// 不同码位的上限;超出后照常计算,只是不再缓存。
        private static let capacity = 30_000
        private let lock = NSLock()
        private var readings: [UInt32: Reading] = [:]

        func reading(of scalar: UnicodeScalar) -> Reading {
            lock.lock()
            let cached = readings[scalar.value]
            lock.unlock()
            if let cached { return cached }

            let reading = Self.compute(scalar)
            lock.lock()
            if readings.count < Self.capacity { readings[scalar.value] = reading }
            lock.unlock()
            return reading
        }

        private static func compute(_ scalar: UnicodeScalar) -> Reading {
            let source = String(Character(scalar))
            let latin = (source.applyingTransform(.toLatin, reverse: false) ?? source)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .lowercased()
            var bucketIndex = LibraryCollationPolicy.letterBuckets.count
            for scalar in latin.unicodeScalars {
                if (0x61...0x7A).contains(scalar.value) {
                    bucketIndex = Int(scalar.value) - 0x61
                    break
                }
                if scalar.value == 0x02BE || scalar.value == 0x02BF {
                    // Hamza / Ayin 转写成没有 ASCII 字母底的修饰符号,按常见读音归到 A。
                    bucketIndex = 0
                    break
                }
            }
            let text = latin
                .replacingOccurrences(of: "\u{02BE}", with: "a")
                .replacingOccurrences(of: "\u{02BF}", with: "a")
            return Reading(utf8: Array(text.utf8), bucketIndex: bucketIndex)
        }
    }
}

/// 一段同首字母的连续条目。
public struct LibraryBrowseSection: Hashable, Sendable {
    public let bucket: String
    public let range: Range<Int>

    public init(bucket: String, range: Range<Int>) {
        self.bucket = bucket
        self.range = range
    }

    /// 在按顺序排好、首尾相接的分段里二分查找第 `index` 项所在的那一段。
    public static func section(containing index: Int, in sections: [LibraryBrowseSection]) -> LibraryBrowseSection? {
        var low = 0
        var high = sections.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = sections[mid].range
            if index < range.lowerBound {
                high = mid - 1
            } else if index >= range.upperBound {
                low = mid + 1
            } else {
                return sections[mid]
            }
        }
        return nil
    }
}

/// 排好序的浏览列表与它的分段(按名字排时是首字母,按年份排时是年份)。
/// 没有分段(最近添加、喜欢)时 `sections` 为空。
public struct LibraryBrowseLayout<Element: Sendable>: Sendable {
    public let items: [Element]
    public let sections: [LibraryBrowseSection]

    public init(items: [Element], sections: [LibraryBrowseSection]) {
        self.items = items
        self.sections = sections
    }

    /// 第 `index` 项所在的分段;没有分段时为 nil。
    public func section(containing index: Int) -> LibraryBrowseSection? {
        LibraryBrowseSection.section(containing: index, in: sections)
    }

    public func section(forBucket bucket: String) -> LibraryBrowseSection? {
        sections.first { $0.bucket == bucket }
    }

    /// 按已排好的键切出连续分段。
    static func sections(bucketIndices: [Int]) -> [LibraryBrowseSection] {
        var sections: [LibraryBrowseSection] = []
        var start = 0
        for index in bucketIndices.indices where index > 0 && bucketIndices[index] != bucketIndices[index - 1] {
            sections.append(LibraryBrowseSection(
                bucket: LibraryCollationPolicy.buckets[bucketIndices[start]],
                range: start..<index
            ))
            start = index
        }
        if !bucketIndices.isEmpty {
            sections.append(LibraryBrowseSection(
                bucket: LibraryCollationPolicy.buckets[bucketIndices[start]],
                range: start..<bucketIndices.count
            ))
        }
        return sections
    }
}

/// 分段网格(电视专辑墙 / 艺人墙)只渲染一个窗口时的算术。窗口起点只落在分段内的
/// 整行上:分段在网格里各自从新的一行开始,起点不对齐的话往前补卡片时已有的行会重新换行。
public enum LibraryBrowseWindow {
    /// 把 `index` 向下取整到它所在分段内的整行起点。
    public static func rowAligned(_ index: Int, in section: LibraryBrowseSection, columns: Int) -> Int {
        let columns = max(1, columns)
        let offset = max(0, index - section.range.lowerBound)
        return section.range.lowerBound + (offset / columns) * columns
    }

    /// 窗口从 `start` 往前补一页:新起点(不越过上一项所在分段的开头,整行对齐),
    /// 以及补出来以后焦点该去的那一项 —— 紧挨着的上一行里与上次聚焦同一列的卡片,
    /// 那一行不满就取它的最后一张。
    public static func earlierWindow(
        before start: Int,
        sections: [LibraryBrowseSection],
        columns: Int,
        pageSize: Int,
        focusedIndex: Int?
    ) -> (start: Int, target: Int) {
        let columns = max(1, columns)
        guard start > 0 else { return (0, 0) }
        guard let previous = LibraryBrowseSection.section(containing: start - 1, in: sections) else {
            return (0, start - 1)
        }
        let newStart = rowAligned(max(previous.range.lowerBound, start - pageSize), in: previous, columns: columns)
        let lastRowStart = rowAligned(start - 1, in: previous, columns: columns)
        var column = 0
        if let focusedIndex,
           let focusedSection = LibraryBrowseSection.section(containing: focusedIndex, in: sections) {
            column = (focusedIndex - focusedSection.range.lowerBound) % columns
        }
        return (newStart, min(lastRowStart + column, start - 1))
    }

    /// 网格重建时要直接落到第 `anchor` 项:窗口从它前面约半页起,不越过它所在分段的开头。
    /// 没有分段时返回 nil(窗口从头开始)。
    public static func start(
        revealing anchor: Int,
        sections: [LibraryBrowseSection],
        columns: Int,
        pageSize: Int
    ) -> (section: LibraryBrowseSection, start: Int)? {
        guard let section = LibraryBrowseSection.section(containing: anchor, in: sections) else { return nil }
        let start = rowAligned(max(section.range.lowerBound, anchor - pageSize / 2), in: section, columns: columns)
        return (section, start)
    }
}

/// 专辑墙的排序方式。
public enum LibraryAlbumBrowseOrder: String, CaseIterable, Sendable {
    /// 按专辑艺术家的名字(拼音)归集,同一艺术家的专辑按发行年份从早到晚。
    case artist
    case title
    /// 发行年份从新到旧,没有年份的排最后;按年代分段(和资料库「发行日期」页同一套年代)。
    case year
    case recentlyAdded
    /// 只放喜欢的专辑，最近喜欢的在前（调用方按这个顺序把专辑交进来）。
    case liked

    /// 电视资料库专辑墙记住的排序方式。
    public static let tvStorageKey = "primuse.tv.albumSort.v1"
    public static let tvDefault: LibraryAlbumBrowseOrder = .artist

    /// 有首字母索引栏的排序。
    public var hasLetterIndex: Bool { self == .artist || self == .title }

    public static func resolved(_ rawValue: String) -> LibraryAlbumBrowseOrder {
        LibraryAlbumBrowseOrder(rawValue: rawValue) ?? tvDefault
    }
}

public enum LibraryAlbumBrowseLayoutBuilder {
    /// - Parameters:
    ///   - songs: 专辑的歌曲,只有 `.recentlyAdded` 用到(取每张专辑最近一首的入库时间)。
    ///   - unknownArtistName: 曲库给没有艺术家的专辑填的占位名;按艺术家排时这一组放最后。
    ///   - currentYear: 按年份排时判断年份像不像样;不给就取今年。
    public static func layout(
        albums: [Album],
        order: LibraryAlbumBrowseOrder,
        songs: [Song] = [],
        unknownArtistName: String? = nil,
        currentYear: Int? = nil
    ) -> LibraryBrowseLayout<Album> {
        switch order {
        case .recentlyAdded:
            let sorted = RecentlyAddedAlbumPolicy.sorted(albums: albums, songs: songs)
            return LibraryBrowseLayout(items: sorted, sections: [])
        case .liked:
            return LibraryBrowseLayout(items: albums, sections: [])
        case .artist, .title, .year:
            break
        }

        // 同一位艺术家有好几张专辑,名字的键只算一次;专辑名大多各不相同,不缓存。
        var artistKeyCache: [String: LibraryCollationPolicy.Key] = [:]
        func artistKey(_ name: String) -> LibraryCollationPolicy.Key {
            if let cached = artistKeyCache[name] { return cached }
            let value = LibraryCollationPolicy.key(for: name)
            artistKeyCache[name] = value
            return value
        }
        // 先把每张专辑的比较值算好放进平行数组,再只排下标:排序时不搬动专辑本身,
        // 也不在比较里反复取可选值。
        let artistNames = albums.map { $0.artistName ?? "" }
        let artistKeys = artistNames.map { name in
            let value = artistKey(name)
            return value.text.isEmpty || name == unknownArtistName ? LibraryCollationPolicy.trailingKey : value
        }
        let titleKeys = albums.map { LibraryCollationPolicy.key(for: $0.title) }
        let years = albums.map { album -> Int? in
            guard let year = album.year, year > 0 else { return nil }
            return year
        }
        // 按年份排时只认像样的年份(两位数、写成日期串的都当没有),年代分段才是连续的。
        let thisYear = currentYear ?? Calendar.current.component(.year, from: Date())
        let releaseYears = order == .year
            ? albums.map { ReleaseDateBrowseLayoutBuilder.plausibleYear($0.year, currentYear: thisYear) }
            : []

        func compare(_ lhs: LibraryCollationPolicy.Key, _ rhs: LibraryCollationPolicy.Key) -> Int {
            if lhs.bucketIndex != rhs.bucketIndex { return lhs.bucketIndex < rhs.bucketIndex ? -1 : 1 }
            if lhs.text == rhs.text { return 0 }
            return lhs.text < rhs.text ? -1 : 1
        }
        func compareTail(_ lhs: Int, _ rhs: Int) -> Bool {
            let title = compare(titleKeys[lhs], titleKeys[rhs])
            if title != 0 { return title < 0 }
            return albums[lhs].id < albums[rhs].id
        }

        let sortedIndices: [Int] = switch order {
        case .artist:
            albums.indices.sorted { lhs, rhs in
                let artist = compare(artistKeys[lhs], artistKeys[rhs])
                if artist != 0 { return artist < 0 }
                // 转写相同的两位艺术家(同音字)各自成组,不互相穿插。
                if artistNames[lhs] != artistNames[rhs] { return artistNames[lhs] < artistNames[rhs] }
                // 同一艺术家下没有年份的专辑排在有年份的后面。
                let lhsYear = years[lhs] ?? Int.max
                let rhsYear = years[rhs] ?? Int.max
                if lhsYear != rhsYear { return lhsYear < rhsYear }
                return compareTail(lhs, rhs)
            }
        case .title:
            albums.indices.sorted { lhs, rhs in
                let title = compare(titleKeys[lhs], titleKeys[rhs])
                if title != 0 { return title < 0 }
                let artist = compare(artistKeys[lhs], artistKeys[rhs])
                if artist != 0 { return artist < 0 }
                return albums[lhs].id < albums[rhs].id
            }
        case .year, .recentlyAdded, .liked:
            albums.indices.sorted { lhs, rhs in
                let lhsYear = releaseYears[lhs] ?? Int.min
                let rhsYear = releaseYears[rhs] ?? Int.min
                if lhsYear != rhsYear { return lhsYear > rhsYear }
                let artist = compare(artistKeys[lhs], artistKeys[rhs])
                if artist != 0 { return artist < 0 }
                return compareTail(lhs, rhs)
            }
        }

        let sections: [LibraryBrowseSection]
        switch order {
        case .artist:
            sections = LibraryBrowseLayout<Album>.sections(bucketIndices: sortedIndices.map { artistKeys[$0].bucketIndex })
        case .title:
            sections = LibraryBrowseLayout<Album>.sections(bucketIndices: sortedIndices.map { titleKeys[$0].bucketIndex })
        case .year:
            sections = eraSections(sortedIndices.map { releaseYears[$0] }, currentYear: thisYear)
        case .recentlyAdded, .liked:
            sections = []
        }
        return LibraryBrowseLayout(items: sortedIndices.map { albums[$0] }, sections: sections)
    }

    /// 按年份排时的分段名是 `ReleaseDateBrowseLayout.Era.id`(「decade-1990」「earlier」「unknown」),
    /// 显示时由界面换成文字。
    static func eraSections(_ sortedYears: [Int?], currentYear: Int) -> [LibraryBrowseSection] {
        let buckets = sortedYears.map { ReleaseDateBrowseLayoutBuilder.era(for: $0, currentYear: currentYear).id }
        var sections: [LibraryBrowseSection] = []
        var start = 0
        for index in buckets.indices where index > 0 && buckets[index] != buckets[index - 1] {
            sections.append(LibraryBrowseSection(bucket: buckets[start], range: start..<index))
            start = index
        }
        if !buckets.isEmpty {
            sections.append(LibraryBrowseSection(bucket: buckets[start], range: start..<buckets.count))
        }
        return sections
    }

}

extension LibraryAlbumBrowseLayoutBuilder {
    /// 决定排序结果的那几项(id、标题、专辑艺术家、年份)的指纹。曲库修订号常因封面、
    /// 歌单之类与排序无关的变化而变;指纹没变就沿用已经排好的布局。
    public static func fingerprint(albums: [Album]) -> Int {
        var hasher = Hasher()
        hasher.combine(albums.count)
        for album in albums {
            hasher.combine(album.id)
            hasher.combine(album.title)
            hasher.combine(album.artistName)
            hasher.combine(album.year)
        }
        return hasher.finalize()
    }
}

/// 歌曲列表(电视「歌曲」页)按标题读音排序并按首字母分段,与专辑墙、艺人墙同一套索引。
public enum LibrarySongBrowseLayoutBuilder {
    public static func fingerprint(songs: [Song]) -> Int {
        var hasher = Hasher()
        hasher.combine(songs.count)
        for song in songs {
            hasher.combine(song.id)
            hasher.combine(song.title)
        }
        return hasher.finalize()
    }

    /// 同名的歌再按艺人、id 排,顺序稳定;没有标题的放最后。条目是歌曲 id:几十万首时
    /// 再拷一份按序排好的 `Song` 要上百 MB,行视图按 id 现取就够了。
    public static func layout(songs: [Song]) -> LibraryBrowseLayout<String> {
        let keys = songs.map { song in
            let key = LibraryCollationPolicy.key(for: song.title)
            return key.text.isEmpty ? LibraryCollationPolicy.trailingKey : key
        }
        let sortedIndices = songs.indices.sorted { lhs, rhs in
            if keys[lhs] != keys[rhs] { return keys[lhs] < keys[rhs] }
            if songs[lhs].title != songs[rhs].title { return songs[lhs].title < songs[rhs].title }
            let lhsArtist = songs[lhs].artistName ?? ""
            let rhsArtist = songs[rhs].artistName ?? ""
            if lhsArtist != rhsArtist { return lhsArtist < rhsArtist }
            return songs[lhs].id < songs[rhs].id
        }
        return LibraryBrowseLayout(
            items: sortedIndices.map { songs[$0].id },
            sections: LibraryBrowseLayout<String>.sections(bucketIndices: sortedIndices.map { keys[$0].bucketIndex })
        )
    }
}

public enum LibraryArtistBrowseLayoutBuilder {
    public static func fingerprint(artists: [Artist]) -> Int {
        var hasher = Hasher()
        hasher.combine(artists.count)
        for artist in artists {
            hasher.combine(artist.id)
            hasher.combine(artist.name)
        }
        return hasher.finalize()
    }

    /// 艺人墙按名字(拼音)排序并分段;`unknownArtistName` 那一项放最后。
    public static func layout(
        artists: [Artist],
        unknownArtistName: String? = nil
    ) -> LibraryBrowseLayout<Artist> {
        let keys = artists.map { artist in
            let key = LibraryCollationPolicy.key(for: artist.name)
            return key.text.isEmpty || artist.name == unknownArtistName ? LibraryCollationPolicy.trailingKey : key
        }
        let sortedIndices = artists.indices.sorted { lhs, rhs in
            if keys[lhs].bucketIndex != keys[rhs].bucketIndex { return keys[lhs].bucketIndex < keys[rhs].bucketIndex }
            if keys[lhs].text != keys[rhs].text { return keys[lhs].text < keys[rhs].text }
            if artists[lhs].name != artists[rhs].name { return artists[lhs].name < artists[rhs].name }
            return artists[lhs].id < artists[rhs].id
        }
        return LibraryBrowseLayout(
            items: sortedIndices.map { artists[$0] },
            sections: LibraryBrowseLayout<Artist>.sections(bucketIndices: sortedIndices.map { keys[$0].bucketIndex })
        )
    }
}
