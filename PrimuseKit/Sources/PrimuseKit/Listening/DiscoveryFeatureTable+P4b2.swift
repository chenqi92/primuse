import Foundation

/// 推荐引擎(`MusicDiscoveryEngine`)按一份歌曲列表建的特征表:每首歌的文本字段折叠一次、按整数键
/// 比较。与原先 App 里的 `FeatureIndex` 逐项相同(同一套折叠、同一套键、同一套打分),只是存法换了:
/// 表按固定格式排在一块连续内存里,整库那份写进 Caches 下的文件再只读映射回来,常驻的只有干净页。
///
/// 布局(小端,各段 8 字节对齐):文件头 → dateAdded、duration、year、artistIdentity、albumIdentity
/// (各 8 字节 × n) → albumID、albumTitle、artistID、artistName、genre、folder、source(各 4 字节 × n)
/// → 标志位(1 字节 × n:可播放、有封面、有年份) → id、标题(偏移表 + 正文) → 文本键表、源键表
/// (按 Swift 字符串顺序排好的文本 + 键,查键用二分,与字典查找同一个相等口径)。
public final class DiscoveryFeatureTable: @unchecked Sendable {
    /// Nil or empty after normalization: never equal to anything.
    public static let noKey: Int32 = -1
    /// 这个进程的标记:写进文件头,别的进程(上一次启动)留下的文件修订号同名也不认。
    public static let processToken = UUID()

    public let count: Int
    public let revision: UInt64
    public let ids: DiscoveryStringColumn
    public let titles: DiscoveryStringColumn
    public let dateAdded: DiscoveryDateColumn
    public let duration: DiscoveryDoubleColumn
    public let year: DiscoveryOptionalIntColumn
    public let artistIdentity: DiscoveryInt64Column
    public let albumIdentity: DiscoveryInt64Column
    public let albumID: DiscoveryInt32Column
    public let albumTitle: DiscoveryInt32Column
    public let artistID: DiscoveryInt32Column
    public let artistName: DiscoveryInt32Column
    public let genre: DiscoveryInt32Column
    public let folder: DiscoveryInt32Column
    public let source: DiscoveryInt32Column
    public let playable: DiscoveryFlagColumn
    public let hasCoverArt: DiscoveryFlagColumn
    /// Normalized text → key. Shared by every folded field; keys are only ever compared within the same field.
    public let textKeys: DiscoveryKeyTable
    public let sourceKeys: DiscoveryKeyTable
    /// 是不是映射文件(否则是进程里的一块内存)。
    public let isMapped: Bool

    private let storage: DiscoveryFeatureStorage

    fileprivate init(storage: DiscoveryFeatureStorage, layout: DiscoveryFeatureLayout, revision: UInt64) {
        self.storage = storage
        self.revision = revision
        self.isMapped = storage.isMapped
        count = layout.count
        let base = storage.base
        func int64(_ section: Int) -> DiscoveryInt64Column {
            DiscoveryInt64Column(base: base + layout.offsets[section], count: layout.count, owner: storage)
        }
        func int32(_ index: Int) -> DiscoveryInt32Column {
            DiscoveryInt32Column(base: base + layout.offsets[DiscoveryFeatureLayout.firstInt32 + index], count: layout.count, owner: storage)
        }
        dateAdded = DiscoveryDateColumn(base: base + layout.offsets[0], count: layout.count, owner: storage)
        duration = DiscoveryDoubleColumn(base: base + layout.offsets[1], count: layout.count, owner: storage)
        let flags = base + layout.offsets[DiscoveryFeatureLayout.flagsSection]
        year = DiscoveryOptionalIntColumn(values: base + layout.offsets[2], flags: flags, count: layout.count, owner: storage)
        artistIdentity = int64(3)
        albumIdentity = int64(4)
        albumID = int32(0)
        albumTitle = int32(1)
        artistID = int32(2)
        artistName = int32(3)
        genre = int32(4)
        folder = int32(5)
        source = int32(6)
        playable = DiscoveryFlagColumn(base: flags, mask: DiscoveryFeatureLayout.playableFlag, count: layout.count, owner: storage)
        hasCoverArt = DiscoveryFlagColumn(base: flags, mask: DiscoveryFeatureLayout.coverFlag, count: layout.count, owner: storage)
        ids = DiscoveryStringColumn(
            offsets: base + layout.offsets[DiscoveryFeatureLayout.idsSection],
            blob: base + layout.offsets[DiscoveryFeatureLayout.idsSection + 1], count: layout.count, owner: storage
        )
        titles = DiscoveryStringColumn(
            offsets: base + layout.offsets[DiscoveryFeatureLayout.titlesSection],
            blob: base + layout.offsets[DiscoveryFeatureLayout.titlesSection + 1], count: layout.count, owner: storage
        )
        textKeys = DiscoveryKeyTable(
            texts: DiscoveryStringColumn(
                offsets: base + layout.offsets[DiscoveryFeatureLayout.textSection],
                blob: base + layout.offsets[DiscoveryFeatureLayout.textSection + 1], count: layout.textCount, owner: storage
            ),
            keys: DiscoveryInt32Column(base: base + layout.offsets[DiscoveryFeatureLayout.textSection + 2], count: layout.textCount, owner: storage)
        )
        sourceKeys = DiscoveryKeyTable(
            texts: DiscoveryStringColumn(
                offsets: base + layout.offsets[DiscoveryFeatureLayout.sourceSection],
                blob: base + layout.offsets[DiscoveryFeatureLayout.sourceSection + 1], count: layout.sourceCount, owner: storage
            ),
            keys: DiscoveryInt32Column(base: base + layout.offsets[DiscoveryFeatureLayout.sourceSection + 2], count: layout.sourceCount, owner: storage)
        )
    }

    /// 占用的字节数(映射文件是文件长度)。
    public var byteCount: Int { storage.length }

    // MARK: - Building

    /// 在进程里建一份(小范围、临时用)。被取消时返回 nil。
    public static func make(songs: some Collection<Song>, isCancelled: () -> Bool = { false }) -> DiscoveryFeatureTable? {
        guard let columns = DiscoveryFeatureColumns(songs: songs, isCancelled: isCancelled) else { return nil }
        return try? columns.makeTable()
    }

    /// 写进 `url`(先写临时文件再换上)并只读映射回来。
    public static func writeMapped(
        _ columns: DiscoveryFeatureColumns,
        to url: URL,
        revision: UInt64,
        token: UUID = processToken
    ) throws -> DiscoveryFeatureTable {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try columns.write(to: temporary, revision: revision, token: token)
            // rename 原子地换上:正映射着旧文件的那份照样可读,别的线程不会看到写了一半的文件。
            guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard let table = openMapped(at: url, revision: revision, count: columns.count, token: token) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return table
    }

    /// 映射一个已写好的文件;不是这个进程、这个修订号、这个条数写的,或格式不对,返回 nil。
    public static func openMapped(at url: URL, revision: UInt64, count: Int, token: UUID = processToken) -> DiscoveryFeatureTable? {
        guard let storage = DiscoveryFeatureStorage(mapping: url),
              storage.header.matches(token: token, revision: revision, count: count),
              let layout = DiscoveryFeatureLayout(validating: storage.header, length: storage.length) else { return nil }
        return DiscoveryFeatureTable(storage: storage, layout: layout, revision: revision)
    }

    // MARK: - Features and scoring

    public func feature(at position: Int) -> DiscoveryFeature {
        DiscoveryFeature(
            id: ids[position],
            albumID: albumID[position],
            albumTitle: albumTitle[position],
            artistID: artistID[position],
            artistName: artistName[position],
            genre: genre[position],
            folder: folder[position],
            source: source[position],
            year: year[position],
            duration: duration[position]
        )
    }

    /// Features of a song that may not be in the list (a radio seed). Text
    /// absent from the index cannot equal any indexed song's text.
    public func feature(for song: Song) -> DiscoveryFeature {
        func key(_ text: String?) -> Int32 {
            guard let text else { return Self.noKey }
            let value = DiscoveryFeatureText.normalized(text)
            guard !value.isEmpty else { return Self.noKey }
            return textKeys[value] ?? -2
        }
        let folderText = DiscoveryFeatureText.parentFolder(song.filePath)
        return DiscoveryFeature(
            id: song.id,
            albumID: key(song.albumID),
            albumTitle: key(song.albumTitle),
            artistID: key(song.artistID),
            artistName: key(song.artistName),
            genre: key(GenreTagValues.primary(in: song.genre)),
            folder: folderText.isEmpty ? Self.noKey : (textKeys[folderText] ?? -2),
            source: sourceKeys[song.sourceID] ?? -2,
            year: song.year,
            duration: song.duration
        )
    }

    private static func keysMatch(_ lhs: Int32, _ rhs: Int32) -> Bool {
        lhs >= 0 && lhs == rhs
    }

    /// Scoring over interned features; identical rules and weights to the
    /// string comparison it replaces (folded, non-empty equality).
    public func similarity(between seed: DiscoveryFeature, at position: Int) -> DiscoverySimilarity {
        Self.similarity(
            between: seed, albumID: albumID[position], albumTitle: albumTitle[position], artistID: artistID[position],
            artistName: artistName[position], genre: genre[position], year: year[position], duration: duration[position],
            source: source[position], folder: folder[position]
        )
    }

    /// 同上,候选的特征直接给(目录一遍扫时没有表;键出自同一个 `DiscoveryFeatureInterner`)。
    public static func similarity(between seed: DiscoveryFeature, and candidate: DiscoveryFeature) -> DiscoverySimilarity {
        similarity(
            between: seed, albumID: candidate.albumID, albumTitle: candidate.albumTitle, artistID: candidate.artistID,
            artistName: candidate.artistName, genre: candidate.genre, year: candidate.year, duration: candidate.duration,
            source: candidate.source, folder: candidate.folder
        )
    }

    @inline(__always)
    private static func similarity(
        between seed: DiscoveryFeature, albumID: Int32, albumTitle: Int32, artistID: Int32, artistName: Int32,
        genre: Int32, year: Int?, duration candidateDuration: TimeInterval, source: Int32, folder: Int32
    ) -> DiscoverySimilarity {
        var score: Double = 0
        var reasons = DiscoverySimilarityReasons()

        if keysMatch(seed.albumID, albumID) || keysMatch(seed.albumTitle, albumTitle) {
            score += 46
            reasons.insert(.sameAlbum)
        }

        if keysMatch(seed.artistID, artistID) || keysMatch(seed.artistName, artistName) {
            score += 40
            reasons.insert(.sameArtist)
        }

        if keysMatch(seed.genre, genre) {
            score += 30
            reasons.insert(.sameGenre)
        }

        if let seedYear = seed.year, let candidateYear = year {
            let delta = abs(seedYear - candidateYear)
            if delta <= 2 {
                score += 10
                reasons.insert(.sameEra)
            } else if delta <= 6 {
                score += 5
                reasons.insert(.sameEra)
            }
        }

        if seed.duration > 30, candidateDuration > 30 {
            let delta = abs(seed.duration - candidateDuration)
            let ratio = delta / max(seed.duration, candidateDuration)
            if ratio <= 0.12 {
                score += 7
                reasons.insert(.similarDuration)
            } else if ratio <= 0.22 {
                score += 3
            }
        }

        if seed.source == source, keysMatch(seed.folder, folder) {
            score += 12
            reasons.insert(.sameFolder)
        }

        return DiscoverySimilarity(score: score, reasons: reasons)
    }
}

/// The comparison features of one song, as keys into a `DiscoveryFeatureTable`.
public struct DiscoveryFeature: Sendable {
    public let id: String
    public let albumID: Int32
    public let albumTitle: Int32
    public let artistID: Int32
    public let artistName: Int32
    public let genre: Int32
    public let folder: Int32
    public let source: Int32
    public let year: Int?
    public let duration: TimeInterval
}

/// 打分给出的理由。位的先后与推荐引擎 `ReasonSet` 里前六个理由的先后一致。
public struct DiscoverySimilarityReasons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let sameAlbum = Self(rawValue: 1 << 0)
    public static let sameArtist = Self(rawValue: 1 << 1)
    public static let sameGenre = Self(rawValue: 1 << 2)
    public static let sameEra = Self(rawValue: 1 << 3)
    public static let similarDuration = Self(rawValue: 1 << 4)
    public static let sameFolder = Self(rawValue: 1 << 5)
}

public struct DiscoverySimilarity: Sendable, Equatable {
    public var score: Double
    public var reasons: DiscoverySimilarityReasons
}

/// 推荐引擎的文本折叠(原 App 里 `MusicDiscoveryEngine` 的同名函数)。
public enum DiscoveryFeatureText {
    public static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// `(path as NSString).deletingLastPathComponent` without bridging every
    /// song's path; shapes it does not handle the same way go to NSString.
    public static func folderPath(of path: String) -> String {
        AlbumArtistInferencePolicy.directory(ofPath: path)
    }

    public static func normalizedFolder(_ folder: String) -> String {
        guard folder != "." else { return "" }
        return normalized(folder)
    }

    public static func parentFolder(_ path: String) -> String {
        normalizedFolder(folderPath(of: path))
    }
}

// MARK: - Building the columns

/// 特征表与流式打分(目录一遍扫,不建表)共用的折叠与键:同一段文本按 `DiscoveryFeatureText` 折叠后同一个键,
/// 空的是 `noKey`;同一首歌在列表第 `position` 位时的特征与艺人、专辑归属(`row`)。按同一个先后喂进来的歌,
/// 两边得到的键与归属逐个相同。
public struct DiscoveryFeatureInterner {
    public private(set) var textKeys: [String: Int32] = [:]
    public private(set) var sourceKeys: [String: Int32] = [:]
    /// Raw text → key while building. A library repeats the same album,
    /// artist and genre strings across every track, and folding each one
    /// again was most of the build (a million songs: tens of seconds).
    private var rawTextKeys: [String: Int32] = [:]
    private var folderKeys: [String: Int32] = [:]
    private var albumTitleIdentityKeys: [AlbumTitleIdentity: Int64] = [:]

    private struct AlbumTitleIdentity: Hashable {
        let artist: Int64
        let title: Int32
    }

    public init() {}

    /// 列表里一首歌的特征与归属。
    public struct Row {
        public let feature: DiscoveryFeature
        public let artistIdentity: Int64
        public let albumIdentity: Int64
    }

    public mutating func row(_ song: Song, position: Int) -> Row {
        let albumIDKey = intern(song.albumID)
        let albumTitleKey = intern(song.albumTitle)
        let artistIDKey = intern(song.artistID)
        let artistNameKey = intern(song.artistName)
        let feature = DiscoveryFeature(
            id: song.id,
            albumID: albumIDKey,
            albumTitle: albumTitleKey,
            artistID: artistIDKey,
            artistName: artistNameKey,
            genre: intern(GenreTagValues.primary(in: song.genre)),
            folder: internFolder(of: song.filePath),
            source: internSource(song.sourceID),
            year: song.year,
            duration: song.duration
        )
        // Same precedence as `artistIdentity(_:)` / `albumIdentity(_:artistKey:)`:
        // id, then name/title, then the song itself.
        let artistKey: Int64
        if artistIDKey != DiscoveryFeatureTable.noKey {
            artistKey = Int64(artistIDKey)
        } else if artistNameKey != DiscoveryFeatureTable.noKey {
            artistKey = (1 << 32) | Int64(artistNameKey)
        } else {
            artistKey = (2 << 32) | Int64(position)
        }
        let albumKey: Int64
        if albumIDKey != DiscoveryFeatureTable.noKey {
            albumKey = Int64(albumIDKey)
        } else if albumTitleKey != DiscoveryFeatureTable.noKey {
            let pair = AlbumTitleIdentity(artist: artistKey, title: albumTitleKey)
            let next = (1 << 40) | Int64(albumTitleIdentityKeys.count)
            albumKey = albumTitleIdentityKeys[pair, default: next]
            if albumTitleIdentityKeys[pair] == nil { albumTitleIdentityKeys[pair] = next }
        } else {
            albumKey = (2 << 40) | Int64(position)
        }
        return Row(feature: feature, artistIdentity: artistKey, albumIdentity: albumKey)
    }

    /// 不在列表里的一首(续播、电台的种子)的特征,键在同一套里:列表里有同样文本的歌就与它相等。
    public mutating func seedFeature(for song: Song) -> DiscoveryFeature {
        DiscoveryFeature(
            id: song.id,
            albumID: intern(song.albumID),
            albumTitle: intern(song.albumTitle),
            artistID: intern(song.artistID),
            artistName: intern(song.artistName),
            genre: intern(GenreTagValues.primary(in: song.genre)),
            folder: internFolder(of: song.filePath),
            source: internSource(song.sourceID),
            year: song.year,
            duration: song.duration
        )
    }

    /// 建完不再要的查找缓存。
    public mutating func dropBuildCaches() {
        rawTextKeys = [:]
        folderKeys = [:]
        albumTitleIdentityKeys = [:]
    }

    private mutating func intern(_ text: String?) -> Int32 {
        guard let text else { return DiscoveryFeatureTable.noKey }
        if let key = rawTextKeys[text] { return key }
        let key = internNormalized(DiscoveryFeatureText.normalized(text))
        rawTextKeys[text] = key
        return key
    }

    private mutating func internFolder(of path: String) -> Int32 {
        let folder = DiscoveryFeatureText.folderPath(of: path)
        if let key = folderKeys[folder] { return key }
        let key = internNormalized(DiscoveryFeatureText.normalizedFolder(folder))
        folderKeys[folder] = key
        return key
    }

    private mutating func internNormalized(_ value: String) -> Int32 {
        guard !value.isEmpty else { return DiscoveryFeatureTable.noKey }
        if let key = textKeys[value] { return key }
        let key = Int32(textKeys.count)
        textKeys[value] = key
        return key
    }

    private mutating func internSource(_ sourceID: String) -> Int32 {
        if let key = sourceKeys[sourceID] { return key }
        let key = Int32(sourceKeys.count)
        sourceKeys[sourceID] = key
        return key
    }
}

/// 建表时的各列(一份歌曲列表的特征,按列存)。建好后写成映射文件或一块内存就放掉。
public struct DiscoveryFeatureColumns {
    var ids: [String] = []
    var titles: [String] = []
    var dateAdded: [Date] = []
    var playable: [Bool] = []
    var hasCoverArt: [Bool] = []
    var albumID: [Int32] = []
    var albumTitle: [Int32] = []
    var artistID: [Int32] = []
    var artistName: [Int32] = []
    var genre: [Int32] = []
    var folder: [Int32] = []
    var source: [Int32] = []
    var year: [Int?] = []
    var duration: [TimeInterval] = []
    var artistIdentity: [Int64] = []
    var albumIdentity: [Int64] = []
    var textKeys: [String: Int32] = [:]
    var sourceKeys: [String: Int32] = [:]

    public var count: Int { ids.count }

    public init?(songs: some Collection<Song>, isCancelled: () -> Bool = { false }) {
        let count = songs.count
        ids.reserveCapacity(count)
        titles.reserveCapacity(count)
        dateAdded.reserveCapacity(count)
        playable.reserveCapacity(count)
        hasCoverArt.reserveCapacity(count)
        albumID.reserveCapacity(count)
        albumTitle.reserveCapacity(count)
        artistID.reserveCapacity(count)
        artistName.reserveCapacity(count)
        genre.reserveCapacity(count)
        folder.reserveCapacity(count)
        source.reserveCapacity(count)
        year.reserveCapacity(count)
        duration.reserveCapacity(count)
        artistIdentity.reserveCapacity(count)
        albumIdentity.reserveCapacity(count)
        var interner = DiscoveryFeatureInterner()

        for (position, song) in songs.enumerated() {
            if position.isMultiple(of: 512), isCancelled() { return nil }
            ids.append(song.id)
            titles.append(song.title)
            dateAdded.append(song.dateAdded)
            playable.append(song.isPlayable)
            hasCoverArt.append(song.coverArtFileName?.isEmpty == false)
            let row = interner.row(song, position: position)
            albumID.append(row.feature.albumID)
            albumTitle.append(row.feature.albumTitle)
            artistID.append(row.feature.artistID)
            artistName.append(row.feature.artistName)
            genre.append(row.feature.genre)
            folder.append(row.feature.folder)
            source.append(row.feature.source)
            year.append(song.year)
            duration.append(song.duration)
            artistIdentity.append(row.artistIdentity)
            albumIdentity.append(row.albumIdentity)
        }
        interner.dropBuildCaches()
        textKeys = interner.textKeys
        sourceKeys = interner.sourceKeys
    }

    // MARK: Serialization

    private func sortedKeys(_ keys: [String: Int32]) -> [(text: String, key: Int32)] {
        keys.map { ($0.key, $0.value) }.sorted { $0.text < $1.text }
    }

    fileprivate func layout(textCount: Int, sourceCount: Int, texts: [(text: String, key: Int32)],
                            sources: [(text: String, key: Int32)]) throws -> DiscoveryFeatureHeader {
        func blobLength<S: Sequence>(_ strings: S) throws -> Int where S.Element == String {
            var length = 0
            for string in strings { length += string.utf8.count }
            guard length <= Int(UInt32.max) else { throw CocoaError(.fileWriteOutOfSpace) }
            return length
        }
        return DiscoveryFeatureHeader(
            token: UUID(), revision: 0, count: count, textCount: textCount, sourceCount: sourceCount,
            idsBlob: try blobLength(ids), titlesBlob: try blobLength(titles),
            textBlob: try blobLength(texts.lazy.map(\.text)), sourceBlob: try blobLength(sources.lazy.map(\.text))
        )
    }

    /// 写成一块进程里的内存(小范围用,或写不了文件时)。
    public func makeTable() throws -> DiscoveryFeatureTable {
        let texts = sortedKeys(textKeys)
        let sources = sortedKeys(sourceKeys)
        var header = try layout(textCount: texts.count, sourceCount: sources.count, texts: texts, sources: sources)
        header.token = DiscoveryFeatureTable.processToken
        guard let layout = DiscoveryFeatureLayout(validating: header, length: nil) else { throw CocoaError(.fileWriteUnknown) }
        let storage = DiscoveryFeatureStorage(allocating: layout.length, header: header)
        var sink = DiscoveryByteSink(memory: storage.mutableBase, capacity: layout.length)
        try serialize(into: &sink, header: header, layout: layout, texts: texts, sources: sources)
        try sink.finish()
        return DiscoveryFeatureTable(storage: storage, layout: layout, revision: 0)
    }

    func write(to url: URL, revision: UInt64, token: UUID) throws {
        let texts = sortedKeys(textKeys)
        let sources = sortedKeys(sourceKeys)
        var header = try layout(textCount: texts.count, sourceCount: sources.count, texts: texts, sources: sources)
        header.token = token
        header.revision = revision
        guard let layout = DiscoveryFeatureLayout(validating: header, length: nil) else { throw CocoaError(.fileWriteUnknown) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var sink = DiscoveryByteSink(file: handle)
        try serialize(into: &sink, header: header, layout: layout, texts: texts, sources: sources)
        try sink.finish()
        try handle.synchronize()
    }

    private func serialize(
        into sink: inout DiscoveryByteSink,
        header: DiscoveryFeatureHeader,
        layout: DiscoveryFeatureLayout,
        texts: [(text: String, key: Int32)],
        sources: [(text: String, key: Int32)]
    ) throws {
        try sink.append(header.encoded)
        func section(_ index: Int) throws { try sink.pad(to: layout.offsets[index]) }
        try section(0)
        for date in dateAdded { try sink.append(date.timeIntervalSinceReferenceDate.bitPattern) }
        try section(1)
        for value in duration { try sink.append(value.bitPattern) }
        try section(2)
        for value in year { try sink.append(Int64(value ?? 0)) }
        try section(3)
        for value in artistIdentity { try sink.append(value) }
        try section(4)
        for value in albumIdentity { try sink.append(value) }
        for (offset, column) in [albumID, albumTitle, artistID, artistName, genre, folder, source].enumerated() {
            try section(DiscoveryFeatureLayout.firstInt32 + offset)
            for value in column { try sink.append(value) }
        }
        try section(DiscoveryFeatureLayout.flagsSection)
        for position in 0..<count {
            var flags: UInt8 = 0
            if playable[position] { flags |= DiscoveryFeatureLayout.playableFlag }
            if hasCoverArt[position] { flags |= DiscoveryFeatureLayout.coverFlag }
            if year[position] != nil { flags |= DiscoveryFeatureLayout.yearFlag }
            try sink.append(flags)
        }
        func strings<S: Sequence>(_ values: S, section first: Int) throws where S.Element == String {
            try section(first)
            var offset: UInt32 = 0
            try sink.append(offset)
            for value in values {
                offset += UInt32(value.utf8.count)
                try sink.append(offset)
            }
            try section(first + 1)
            for value in values { try sink.append(string: value) }
        }
        try strings(ids, section: DiscoveryFeatureLayout.idsSection)
        try strings(titles, section: DiscoveryFeatureLayout.titlesSection)
        try strings(texts.lazy.map(\.text), section: DiscoveryFeatureLayout.textSection)
        try section(DiscoveryFeatureLayout.textSection + 2)
        for entry in texts { try sink.append(entry.key) }
        try strings(sources.lazy.map(\.text), section: DiscoveryFeatureLayout.sourceSection)
        try section(DiscoveryFeatureLayout.sourceSection + 2)
        for entry in sources { try sink.append(entry.key) }
        try sink.pad(to: layout.length)
    }
}

// MARK: - Columns

public struct DiscoveryInt32Column: RandomAccessCollection, @unchecked Sendable {
    let base: UnsafeRawPointer
    public let count: Int
    let owner: DiscoveryFeatureStorage
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> Int32 {
        Int32(littleEndian: base.loadUnaligned(fromByteOffset: position &* 4, as: Int32.self))
    }
}

public struct DiscoveryInt64Column: RandomAccessCollection, @unchecked Sendable {
    let base: UnsafeRawPointer
    public let count: Int
    let owner: DiscoveryFeatureStorage
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> Int64 {
        Int64(littleEndian: base.loadUnaligned(fromByteOffset: position &* 8, as: Int64.self))
    }
}

public struct DiscoveryDoubleColumn: RandomAccessCollection, @unchecked Sendable {
    let base: UnsafeRawPointer
    public let count: Int
    let owner: DiscoveryFeatureStorage
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> Double {
        Double(bitPattern: UInt64(littleEndian: base.loadUnaligned(fromByteOffset: position &* 8, as: UInt64.self)))
    }
}

public struct DiscoveryDateColumn: RandomAccessCollection, @unchecked Sendable {
    let base: UnsafeRawPointer
    public let count: Int
    let owner: DiscoveryFeatureStorage
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(
            littleEndian: base.loadUnaligned(fromByteOffset: position &* 8, as: UInt64.self)
        )))
    }
}

public struct DiscoveryOptionalIntColumn: RandomAccessCollection, @unchecked Sendable {
    let values: UnsafeRawPointer
    let flags: UnsafeRawPointer
    public let count: Int
    let owner: DiscoveryFeatureStorage
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> Int? {
        guard flags.load(fromByteOffset: position, as: UInt8.self) & DiscoveryFeatureLayout.yearFlag != 0 else { return nil }
        return Int(Int64(littleEndian: values.loadUnaligned(fromByteOffset: position &* 8, as: Int64.self)))
    }
}

public struct DiscoveryFlagColumn: RandomAccessCollection, @unchecked Sendable {
    let base: UnsafeRawPointer
    let mask: UInt8
    public let count: Int
    let owner: DiscoveryFeatureStorage
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> Bool {
        base.load(fromByteOffset: position, as: UInt8.self) & mask != 0
    }
}

public struct DiscoveryStringColumn: RandomAccessCollection, @unchecked Sendable {
    let offsets: UnsafeRawPointer
    let blob: UnsafeRawPointer
    public let count: Int
    let owner: DiscoveryFeatureStorage
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public subscript(position: Int) -> String {
        let lower = Int(UInt32(littleEndian: offsets.loadUnaligned(fromByteOffset: position &* 4, as: UInt32.self)))
        let upper = Int(UInt32(littleEndian: offsets.loadUnaligned(fromByteOffset: (position &+ 1) &* 4, as: UInt32.self)))
        return String(decoding: UnsafeRawBufferPointer(start: blob + lower, count: upper - lower), as: UTF8.self)
    }
}

/// 文本 → 键。按 Swift 字符串的先后排好,二分查找;相等用 `==`(与字典同一个口径:规范等价的写法算同一个)。
public struct DiscoveryKeyTable: @unchecked Sendable {
    let texts: DiscoveryStringColumn
    let keys: DiscoveryInt32Column

    public var count: Int { texts.count }

    public subscript(text: String) -> Int32? {
        var lower = 0
        var upper = texts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let candidate = texts[middle]
            if candidate == text { return keys[middle] }
            if candidate < text { lower = middle + 1 } else { upper = middle }
        }
        return nil
    }

    /// 全部条目(测试与诊断用)。
    public var entries: [(text: String, key: Int32)] {
        (0..<texts.count).map { (texts[$0], keys[$0]) }
    }
}

// MARK: - Storage and layout

struct DiscoveryFeatureHeader {
    static let magic: [UInt8] = Array("PDFTv001".utf8)
    static let size = 128

    var token: UUID
    var revision: UInt64
    var count: Int
    var textCount: Int
    var sourceCount: Int
    var idsBlob: Int
    var titlesBlob: Int
    var textBlob: Int
    var sourceBlob: Int

    init(token: UUID, revision: UInt64, count: Int, textCount: Int, sourceCount: Int,
         idsBlob: Int, titlesBlob: Int, textBlob: Int, sourceBlob: Int) {
        self.token = token
        self.revision = revision
        self.count = count
        self.textCount = textCount
        self.sourceCount = sourceCount
        self.idsBlob = idsBlob
        self.titlesBlob = titlesBlob
        self.textBlob = textBlob
        self.sourceBlob = sourceBlob
    }

    init?(_ base: UnsafeRawPointer, length: Int) {
        guard length >= Self.size,
              Array(UnsafeRawBufferPointer(start: base, count: 8)) == Self.magic else { return nil }
        let uuid = UnsafeRawBufferPointer(start: base + 8, count: 16)
        token = UUID(uuid: (uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
                            uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]))
        func value(_ index: Int) -> UInt64 {
            UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 24 + index * 8, as: UInt64.self))
        }
        revision = value(0)
        guard let count = Int(exactly: value(1)), let textCount = Int(exactly: value(2)),
              let sourceCount = Int(exactly: value(3)), let idsBlob = Int(exactly: value(4)),
              let titlesBlob = Int(exactly: value(5)), let textBlob = Int(exactly: value(6)),
              let sourceBlob = Int(exactly: value(7)) else { return nil }
        self.count = count
        self.textCount = textCount
        self.sourceCount = sourceCount
        self.idsBlob = idsBlob
        self.titlesBlob = titlesBlob
        self.textBlob = textBlob
        self.sourceBlob = sourceBlob
    }

    func matches(token: UUID, revision: UInt64, count: Int) -> Bool {
        self.token == token && self.revision == revision && self.count == count
    }

    var encoded: [UInt8] {
        var bytes = Self.magic
        withUnsafeBytes(of: token.uuid) { bytes.append(contentsOf: $0) }
        for value in [revision, UInt64(count), UInt64(textCount), UInt64(sourceCount), UInt64(idsBlob),
                      UInt64(titlesBlob), UInt64(textBlob), UInt64(sourceBlob)] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: Self.size - bytes.count))
        return bytes
    }
}

/// 各段起点(由文件头里的条数与正文长度算出,不另存)。
struct DiscoveryFeatureLayout {
    static let firstInt32 = 5
    static let flagsSection = 12
    static let idsSection = 13
    static let titlesSection = 15
    static let textSection = 17
    static let sourceSection = 20
    static let playableFlag: UInt8 = 1 << 0
    static let coverFlag: UInt8 = 1 << 1
    static let yearFlag: UInt8 = 1 << 2

    let count: Int
    let textCount: Int
    let sourceCount: Int
    let offsets: [Int]
    let length: Int

    init(header: DiscoveryFeatureHeader) {
        count = header.count
        textCount = header.textCount
        sourceCount = header.sourceCount
        let n = header.count
        let sizes: [Int] = [
            n * 8, n * 8, n * 8, n * 8, n * 8,          // 0–4:dateAdded、duration、year、artistIdentity、albumIdentity
            n * 4, n * 4, n * 4, n * 4, n * 4, n * 4, n * 4, // 5–11:七个文本键列
            n,                                           // 12:标志位
            (n + 1) * 4, header.idsBlob,                 // 13–14:id
            (n + 1) * 4, header.titlesBlob,              // 15–16:标题
            (header.textCount + 1) * 4, header.textBlob, header.textCount * 4, // 17–19:文本键表
            (header.sourceCount + 1) * 4, header.sourceBlob, header.sourceCount * 4, // 20–22:源键表
        ]
        var offsets: [Int] = []
        var position = DiscoveryFeatureHeader.size
        for size in sizes {
            position = (position + 7) & ~7
            offsets.append(position)
            position += size
        }
        self.offsets = offsets
        length = (position + 7) & ~7
    }

    /// 算出的总长与文件长度对得上才用(`length` 为 nil 时不核对)。
    init?(validating header: DiscoveryFeatureHeader, length: Int?) {
        let maximum = Int(UInt32.max)
        guard header.count >= 0, header.count < maximum / 8, header.textCount >= 0, header.textCount < maximum / 4,
              header.sourceCount >= 0, header.sourceCount < maximum / 4,
              [header.idsBlob, header.titlesBlob, header.textBlob, header.sourceBlob].allSatisfy({ $0 >= 0 && $0 <= maximum })
        else { return nil }
        self.init(header: header)
        if let length, length != self.length { return nil }
    }
}

/// 一块只读的特征表字节:进程里分配的,或只读映射的文件。放掉时归还。
final class DiscoveryFeatureStorage: @unchecked Sendable {
    let base: UnsafeRawPointer
    let length: Int
    let isMapped: Bool
    let header: DiscoveryFeatureHeader
    private let allocated: UnsafeMutableRawPointer?

    var mutableBase: UnsafeMutableRawPointer { allocated! }

    init(allocating length: Int, header: DiscoveryFeatureHeader) {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(length, 1), alignment: 16)
        allocated = pointer
        base = UnsafeRawPointer(pointer)
        self.length = length
        self.header = header
        isMapped = false
    }

    init?(mapping url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= DiscoveryFeatureHeader.size else { return nil }
        let length = Int(status.st_size)
        guard let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE | MAP_FILE, descriptor, 0),
              mapped != MAP_FAILED else { return nil }
        guard let header = DiscoveryFeatureHeader(UnsafeRawPointer(mapped), length: length) else {
            munmap(mapped, length)
            return nil
        }
        base = UnsafeRawPointer(mapped)
        self.length = length
        self.header = header
        allocated = nil
        isMapped = true
    }

    deinit {
        if let allocated {
            allocated.deallocate()
        } else {
            munmap(UnsafeMutableRawPointer(mutating: base), length)
        }
    }
}

/// 顺序写出字节:写进一块内存,或经 64 KB 缓冲写进文件。
struct DiscoveryByteSink {
    private var memory: UnsafeMutableRawPointer?
    private var capacity = 0
    private var file: FileHandle?
    private var buffer: [UInt8] = []
    private(set) var position = 0

    init(memory: UnsafeMutableRawPointer, capacity: Int) {
        self.memory = memory
        self.capacity = capacity
    }

    init(file: FileHandle) {
        self.file = file
        buffer.reserveCapacity(1 << 16)
    }

    mutating func append(string: String) throws {
        var string = string
        try string.withUTF8 { try append(raw: UnsafeRawBufferPointer($0)) }
    }

    mutating func append(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try append(raw: $0) }
    }

    mutating func append<T: FixedWidthInteger>(_ value: T) throws {
        var little = value.littleEndian
        try withUnsafeBytes(of: &little) { try append(raw: $0) }
    }

    mutating func pad(to offset: Int) throws {
        guard offset >= position else { throw CocoaError(.fileWriteUnknown) }
        let zeros = [UInt8](repeating: 0, count: offset - position)
        try append(zeros)
    }

    private mutating func append(raw: UnsafeRawBufferPointer) throws {
        guard !raw.isEmpty else { return }
        if let memory {
            guard position + raw.count <= capacity, let source = raw.baseAddress else { throw CocoaError(.fileWriteOutOfSpace) }
            (memory + position).copyMemory(from: source, byteCount: raw.count)
        } else {
            buffer.append(contentsOf: raw)
            if buffer.count >= 1 << 16 { try flush() }
        }
        position += raw.count
    }

    private mutating func flush() throws {
        guard let file, !buffer.isEmpty else { return }
        try file.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func finish() throws {
        try flush()
    }
}
