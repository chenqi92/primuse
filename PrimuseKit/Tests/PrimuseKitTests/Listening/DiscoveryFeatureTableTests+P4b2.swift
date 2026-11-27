import Foundation
import Testing
@testable import PrimuseKit

/// 推荐特征表:进程里的那份与映射文件那份,都必须与原先 App 里的 `FeatureIndex`(下面原样抄来的
/// `ReferenceFeatureIndex`)逐列、逐键、逐首打分相同。
@Suite("Discovery feature table parity", .serialized)
struct DiscoveryFeatureTableTests {
    // MARK: - Seeded library

    static let albumTitles = ["Café", "CAFE\u{301}", "cafe", " Night ", "夜曲", "夜曲 ", "", "Ünïcode", "unicode", "Blue"]
    static let artists = ["周杰伦", "周杰倫", "Beyond", "BEYOND", " beyond", "Ólafur", "olafur", "", "AC/DC"]
    static let genres = ["Pop", "pop; Rock", "Rock/Pop", "", "有声书", "Jazz, Blues", "Électro"]
    static let folders = ["Music/A", "music/a", "Music/Á", "", ".", "/", "Volumes/share/Rock", "a//b", "x/./y"]

    static func library(seed: UInt64, count: Int) -> [Song] {
        var rng = CatalogTestRandom(seed: seed)
        return (0..<count).map { index in
            let folder = rng.pick(folders)
            let name = "\(rng.int(1...30)) song.\(rng.pick(["flac", "mp3"]))"
            return Song(
                id: rng.chance(3) ? "dup-\(index % 7)" : String(format: "%016llx-%d", rng.next(), index),
                title: rng.pick(["Intro", "intro", "Song \(index % 13)", "第\(index % 9)集", "", "Ångström"]),
                albumID: rng.maybe(40) { $0.pick(["alb-1", "ALB-1", "alb-2", " ", "alb-\($0.int(0...20))"]) },
                artistID: rng.maybe(35) { $0.pick(["art-1", "art-2", "Art-1", "art-\($0.int(0...10))"]) },
                albumTitle: rng.maybe(85) { $0.pick(albumTitles) },
                artistName: rng.maybe(85) { $0.pick(artists) },
                duration: rng.pick([0, 29, 30, 31, 120, 135, 180, 200, 240, 600, Double(rng.int(1...900))]),
                fileFormat: .flac,
                filePath: rng.chance(5) ? "" : (folder.isEmpty ? name : "\(folder)/\(name)"),
                sourceID: rng.pick(["smb", "nas", "local", "srv"]),
                genre: rng.maybe(70) { $0.pick(genres) },
                year: rng.maybe(70) { $0.pick([1960, 1999, 2000, 2001, 2003, 2005, 2006, 2007, 2020, 2024]) },
                dateAdded: Date(timeIntervalSinceReferenceDate: Double(rng.int(0...900_000_000)) + Double(rng.int(0...999)) / 1_000),
                coverArtFileName: rng.maybe(60) { $0.pick(["", "cover.jpg"]) }
            )
        }
    }

    /// 不在库里的种子:写法与库里的只差规范等价、大小写、首尾空白。
    static func externalSeeds(seed: UInt64) -> [Song] {
        var rng = CatalogTestRandom(seed: seed &+ 99)
        return (0..<12).map { index in
            Song(
                id: "external-\(index)",
                title: "External",
                albumID: rng.maybe(50) { $0.pick(["alb-1", "ALB-2", "missing"]) },
                artistID: rng.maybe(50) { $0.pick(["art-1", "nobody"]) },
                albumTitle: rng.maybe(80) { $0.pick(albumTitles + ["Cafe\u{301}", "Unknown"]) },
                artistName: rng.maybe(80) { $0.pick(artists + ["Somebody"]) },
                duration: rng.pick([0, 31, 180, 240]),
                fileFormat: .flac,
                filePath: "\(rng.pick(folders + ["Elsewhere"]))/x.flac",
                sourceID: rng.pick(["smb", "nas", "other"]),
                genre: rng.maybe(70) { $0.pick(genres + ["pop"]) },
                year: rng.maybe(70) { $0.pick([1998, 2002, 2010]) }
            )
        }
    }

    // MARK: - Comparison

    static func expectSame(_ table: DiscoveryFeatureTable, _ reference: ReferenceFeatureIndex, songs: [Song], seed: UInt64, _ label: String) {
        let context = "seed \(seed) \(label)"
        #expect(table.count == reference.ids.count, "\(context): count")
        for position in 0..<reference.ids.count {
            let same = table.ids[position] == reference.ids[position]
                && table.titles[position] == reference.titles[position]
                && table.dateAdded[position] == reference.dateAdded[position]
                && table.playable[position] == reference.playable[position]
                && table.hasCoverArt[position] == reference.hasCoverArt[position]
                && table.albumID[position] == reference.albumID[position]
                && table.albumTitle[position] == reference.albumTitle[position]
                && table.artistID[position] == reference.artistID[position]
                && table.artistName[position] == reference.artistName[position]
                && table.genre[position] == reference.genre[position]
                && table.folder[position] == reference.folder[position]
                && table.source[position] == reference.source[position]
                && table.year[position] == reference.year[position]
                && table.duration[position].bitPattern == reference.duration[position].bitPattern
                && table.artistIdentity[position] == reference.artistIdentity[position]
                && table.albumIdentity[position] == reference.albumIdentity[position]
            #expect(same, "\(context): column values at \(position)")
            if !same { return }
        }
        #expect(table.textKeys.count == reference.textKeys.count, "\(context): text key count")
        for (text, key) in reference.textKeys {
            #expect(table.textKeys[text] == key, "\(context): text key \(text)")
            let decomposed = text.decomposedStringWithCanonicalMapping
            #expect(table.textKeys[decomposed] == reference.textKeys[decomposed], "\(context): NFD text key \(text)")
        }
        for probe in ["missing", "", "café", "cafe\u{301}", "zzz", "\u{0}"] {
            #expect(table.textKeys[probe] == reference.textKeys[probe], "\(context): probe \(probe)")
        }
        #expect(table.sourceKeys.count == reference.sourceKeys.count, "\(context): source key count")
        for (text, key) in reference.sourceKeys { #expect(table.sourceKeys[text] == key, "\(context): source \(text)") }

        let seeds = Array(songs.prefix(25)) + externalSeeds(seed: seed)
        for seedSong in seeds {
            let expectedFeature = reference.feature(for: seedSong)
            let feature = table.feature(for: seedSong)
            #expect(feature == expectedFeature, "\(context): feature for \(seedSong.id)")
            for position in 0..<reference.ids.count {
                let expected = ReferenceFeatureIndex.similarity(between: expectedFeature, and: position, in: reference)
                let actual = table.similarity(between: feature, at: position)
                if actual != expected {
                    #expect(actual == expected, "\(context): similarity \(seedSong.id) vs \(position)")
                    return
                }
            }
        }
        for position in stride(from: 0, to: reference.ids.count, by: 17) {
            #expect(table.feature(at: position) == reference.feature(at: position), "\(context): feature at \(position)")
        }
    }

    @Test("Memory and mapped tables match today's feature index", arguments: Array(UInt64(1)...UInt64(12)))
    func tablesMatchTheReference(seed: UInt64) throws {
        let songs = Self.library(seed: seed, count: 1_500)
        let reference = try #require(ReferenceFeatureIndex(songs: songs, isCancelled: { false }))
        let memory = try #require(DiscoveryFeatureTable.make(songs: songs))
        #expect(!memory.isMapped)
        Self.expectSame(memory, reference, songs: songs, seed: seed, "memory")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("features.bin")
        let columns = try #require(DiscoveryFeatureColumns(songs: songs))
        let mapped = try DiscoveryFeatureTable.writeMapped(columns, to: url, revision: seed)
        #expect(mapped.isMapped)
        Self.expectSame(mapped, reference, songs: songs, seed: seed, "mapped")

        let reopened = try #require(DiscoveryFeatureTable.openMapped(at: url, revision: seed, count: songs.count))
        Self.expectSame(reopened, reference, songs: songs, seed: seed, "reopened")
        // 别的修订号、别的条数、别的进程写的都不认。
        #expect(DiscoveryFeatureTable.openMapped(at: url, revision: seed + 1, count: songs.count) == nil)
        #expect(DiscoveryFeatureTable.openMapped(at: url, revision: seed, count: songs.count + 1) == nil)
        #expect(DiscoveryFeatureTable.openMapped(at: url, revision: seed, count: songs.count, token: UUID()) == nil)
    }

    @Test("Paged slices and empty lists match too")
    func slicesAndEmpty() throws {
        let songs = Self.library(seed: 77, count: 600)
        let page = songs[200..<450]
        let reference = try #require(ReferenceFeatureIndex(songs: page, isCancelled: { false }))
        let table = try #require(DiscoveryFeatureTable.make(songs: page))
        Self.expectSame(table, reference, songs: Array(page), seed: 77, "page")
        let empty = try #require(DiscoveryFeatureTable.make(songs: [Song]()))
        #expect(empty.count == 0 && empty.textKeys.count == 0)
        #expect(empty.textKeys["anything"] == nil)
        #expect(DiscoveryFeatureTable.make(songs: songs, isCancelled: { true }) == nil)
    }

    @Test("A damaged or truncated file is not mapped")
    func damagedFile() throws {
        let songs = Self.library(seed: 5, count: 300)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("features.bin")
        let columns = try #require(DiscoveryFeatureColumns(songs: songs))
        _ = try DiscoveryFeatureTable.writeMapped(columns, to: url, revision: 3)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 400)
        try handle.close()
        #expect(DiscoveryFeatureTable.openMapped(at: url, revision: 3, count: songs.count) == nil)
        try Data("not a table".utf8).write(to: url)
        #expect(DiscoveryFeatureTable.openMapped(at: url, revision: 3, count: songs.count) == nil)
    }
}

extension DiscoveryFeature: Equatable {
    public static func == (lhs: DiscoveryFeature, rhs: DiscoveryFeature) -> Bool {
        lhs.id == rhs.id && lhs.albumID == rhs.albumID && lhs.albumTitle == rhs.albumTitle && lhs.artistID == rhs.artistID
            && lhs.artistName == rhs.artistName && lhs.genre == rhs.genre && lhs.folder == rhs.folder
            && lhs.source == rhs.source && lhs.year == rhs.year && lhs.duration.bitPattern == rhs.duration.bitPattern
    }
}

// MARK: - Reference: today's App implementation, copied verbatim

/// `MusicDiscoveryEngine.FeatureIndex`、`similarity`、`normalized`、`folderPath`、`normalizedFolder`、
/// `parentFolder`(2026-11-24 的 main 64bc78409),只把 `Feature` 换成 `DiscoveryFeature`、把理由换成位。
struct ReferenceFeatureIndex {
    static let noKey: Int32 = -1

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
    private var rawTextKeys: [String: Int32] = [:]
    private var folderKeys: [String: Int32] = [:]

    init?(songs: some Collection<Song>, isCancelled: () -> Bool) {
        var albumTitleIdentityKeys: [AlbumTitleIdentity: Int64] = [:]
        for (position, song) in songs.enumerated() {
            if position.isMultiple(of: 512), isCancelled() { return nil }
            ids.append(song.id)
            titles.append(song.title)
            dateAdded.append(song.dateAdded)
            playable.append(song.isPlayable)
            hasCoverArt.append(song.coverArtFileName?.isEmpty == false)
            let albumIDKey = intern(song.albumID)
            let albumTitleKey = intern(song.albumTitle)
            let artistIDKey = intern(song.artistID)
            let artistNameKey = intern(song.artistName)
            albumID.append(albumIDKey)
            albumTitle.append(albumTitleKey)
            artistID.append(artistIDKey)
            artistName.append(artistNameKey)
            genre.append(intern(GenreTagValues.primary(in: song.genre)))
            folder.append(internFolder(of: song.filePath))
            source.append(internSource(song.sourceID))
            year.append(song.year)
            duration.append(song.duration)
            let artistKey: Int64
            if artistIDKey != Self.noKey {
                artistKey = Int64(artistIDKey)
            } else if artistNameKey != Self.noKey {
                artistKey = (1 << 32) | Int64(artistNameKey)
            } else {
                artistKey = (2 << 32) | Int64(position)
            }
            artistIdentity.append(artistKey)
            if albumIDKey != Self.noKey {
                albumIdentity.append(Int64(albumIDKey))
            } else if albumTitleKey != Self.noKey {
                let pair = AlbumTitleIdentity(artist: artistKey, title: albumTitleKey)
                let next = (1 << 40) | Int64(albumTitleIdentityKeys.count)
                albumIdentity.append(albumTitleIdentityKeys[pair, default: next])
                if albumTitleIdentityKeys[pair] == nil { albumTitleIdentityKeys[pair] = next }
            } else {
                albumIdentity.append((2 << 40) | Int64(position))
            }
        }
        rawTextKeys = [:]
        folderKeys = [:]
    }

    private struct AlbumTitleIdentity: Hashable {
        let artist: Int64
        let title: Int32
    }

    private mutating func intern(_ text: String?) -> Int32 {
        guard let text else { return Self.noKey }
        if let key = rawTextKeys[text] { return key }
        let key = internNormalized(Self.normalized(text))
        rawTextKeys[text] = key
        return key
    }

    private mutating func internFolder(of path: String) -> Int32 {
        let folder = Self.folderPath(of: path)
        if let key = folderKeys[folder] { return key }
        let key = internNormalized(Self.normalizedFolder(folder))
        folderKeys[folder] = key
        return key
    }

    private mutating func internNormalized(_ value: String) -> Int32 {
        guard !value.isEmpty else { return Self.noKey }
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

    func feature(at position: Int) -> DiscoveryFeature {
        DiscoveryFeature(
            id: ids[position], albumID: albumID[position], albumTitle: albumTitle[position],
            artistID: artistID[position], artistName: artistName[position], genre: genre[position],
            folder: folder[position], source: source[position], year: year[position], duration: duration[position]
        )
    }

    func feature(for song: Song) -> DiscoveryFeature {
        func key(_ text: String?) -> Int32 {
            guard let text else { return Self.noKey }
            let value = Self.normalized(text)
            guard !value.isEmpty else { return Self.noKey }
            return textKeys[value] ?? -2
        }
        let folderText = Self.parentFolder(song.filePath)
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

    static func similarity(between seed: DiscoveryFeature, and position: Int, in index: ReferenceFeatureIndex) -> DiscoverySimilarity {
        var score: Double = 0
        var reasons = DiscoverySimilarityReasons()
        if keysMatch(seed.albumID, index.albumID[position])
            || keysMatch(seed.albumTitle, index.albumTitle[position]) {
            score += 46
            reasons.insert(.sameAlbum)
        }
        if keysMatch(seed.artistID, index.artistID[position])
            || keysMatch(seed.artistName, index.artistName[position]) {
            score += 40
            reasons.insert(.sameArtist)
        }
        if keysMatch(seed.genre, index.genre[position]) {
            score += 30
            reasons.insert(.sameGenre)
        }
        if let seedYear = seed.year, let candidateYear = index.year[position] {
            let delta = abs(seedYear - candidateYear)
            if delta <= 2 {
                score += 10
                reasons.insert(.sameEra)
            } else if delta <= 6 {
                score += 5
                reasons.insert(.sameEra)
            }
        }
        let candidateDuration = index.duration[position]
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
        if seed.source == index.source[position],
           keysMatch(seed.folder, index.folder[position]) {
            score += 12
            reasons.insert(.sameFolder)
        }
        return DiscoverySimilarity(score: score, reasons: reasons)
    }

    static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func folderPath(of path: String) -> String {
        AlbumArtistInferencePolicy.directory(ofPath: path)
    }

    static func normalizedFolder(_ folder: String) -> String {
        guard folder != "." else { return "" }
        return normalized(folder)
    }

    static func parentFolder(_ path: String) -> String {
        normalizedFolder(folderPath(of: path))
    }
}
