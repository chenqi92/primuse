import Foundation
import GRDB
import Testing
@testable import PrimuseKit

/// 搜索库里的专辑、艺人索引必须与原先 App 里的内存版(下面原样抄来的 `ReferenceCollectionSearchIndex`)
/// 每一次查找的结果、准备次数、候选数都相同,包括拼音备忘的先后影响(先不带拼音查、再带拼音查、再不带)。
@Suite("Album and artist search text in the search database", .serialized)
struct LibraryCollectionSearchStoreTests {
    static let titles = [
        "七里香", "七里香 ", "夜曲", "Moonlight", "moonlight", "Café live", "Cafe\u{301} live", "Other", "qlx live",
        "Earth, Wind & Fire", "AC/DC", "周杰伦精选", "Ünïcode", "独立专辑名称", "Ångström", "第一季", "1999", "",
    ]
    static let artists = [
        "周杰伦", "周杰倫", "Artist", "Someone", "Else", "Earth, Wind & Fire", "Café", "Cafe\u{301}", "AC/DC",
        "Beyond", "beyond", "", "王菲 / 那英", "Ólafur Arnalds",
    ]
    static let queries = [
        "七里", "qilixiang", "qlx", "zhoujielun", "zjl", "mnlt", "cafe", "café", "unmatched", "&", "wind", "fire earth",
        "周杰伦", "  ", "ac/dc", "AC", "moon light", "1999", "o", "e", "第一", "dyj", "Ångström", "angstrom",
    ]

    static func albums(_ rng: inout CatalogTestRandom, count: Int, round: Int) -> [Album] {
        (0..<count).map { index in
            let title = rng.chance(15) ? "Fresh \(round)-\(index) \(rng.pick(titles))" : rng.pick(titles)
            return Album(id: rng.chance(10) ? "dup-\(index % 4)" : "a\(round)-\(index)", title: title,
                         artistName: rng.maybe(80) { $0.pick(artists) })
        }
    }

    static func artists(_ rng: inout CatalogTestRandom, count: Int, round: Int) -> [Artist] {
        (0..<count).map { index in
            Artist(id: "r\(round)-\(index)", name: rng.chance(15) ? "New \(round)-\(index)" : rng.pick(artists))
        }
    }

    @Test("Random query sequences give the same results as the in-memory index", arguments: Array(UInt64(1)...UInt64(10)))
    func sequencesMatch(seed: UInt64) throws {
        var rng = CatalogTestRandom(seed: seed)
        let reference = ReferenceCollectionSearchIndex()
        let store = try LibraryCollectionSearchStore.temporary()
        var albums = Self.albums(&rng, count: rng.int(0...40), round: 0)
        var artists = Self.artists(&rng, count: rng.int(0...25), round: 0)
        for step in 0..<120 {
            if rng.chance(12) { albums = Self.albums(&rng, count: rng.int(0...60), round: step) }
            if rng.chance(10) { artists = Self.artists(&rng, count: rng.int(0...40), round: step) }
            let query = rng.pick(Self.queries)
            let includePinyin = rng.chance(60)
            let semantic = rng.chance(30)
            let related: [Album] = rng.chance(30)
                ? (0..<rng.int(0...5)).map { _ in
                    rng.chance(50) && !albums.isEmpty ? rng.pick(albums) : Album(id: "gone-\(rng.int(0...3))", title: "Gone")
                }
                : []
            let expected = reference.search(query: query, albums: albums, artists: artists, relatedAlbums: related,
                                            semanticArtists: semantic, includePinyin: includePinyin)
            let actual = try store.search(query: query, albums: albums, artists: artists, relatedAlbums: related,
                                          semanticArtists: semantic, includePinyin: includePinyin)
            let context = "seed \(seed) step \(step) query \(query) pinyin \(includePinyin)"
            #expect(actual.albums.map(\.id) == expected.albums.map(\.id), "\(context): albums")
            #expect(actual.artists.map(\.id) == expected.artists.map(\.id), "\(context): artists")
            #expect(store.preparationCount == reference.preparationCount, "\(context): preparations")
            #expect(store.lastAlbumCandidateCount == reference.lastAlbumCandidateCount, "\(context): candidates")
        }
    }

    @Test("The text memo is trimmed the same way when many titles come and go")
    func trimmingMatches() throws {
        var rng = CatalogTestRandom(seed: 4_242)
        let reference = ReferenceCollectionSearchIndex()
        let store = try LibraryCollectionSearchStore.temporary()
        var kept: [Album] = []
        for round in 0..<30 {
            var albums = (0..<45).map { Album(id: "t\(round)-\($0)", title: "Title \(round)-\($0) 七里香", artistName: "A\(round)") }
            if round % 7 == 0 { albums += kept }
            if round == 3 { kept = Array(albums.prefix(10)) }
            let artists = (0..<5).map { Artist(id: "x\(round)-\($0)", name: "Artist \(round)-\($0)") }
            for query in ["qlx", "七里", "title"] {
                let includePinyin = rng.chance(50)
                let expected = reference.search(query: query, albums: albums, artists: artists, includePinyin: includePinyin)
                let actual = try store.search(query: query, albums: albums, artists: artists, includePinyin: includePinyin)
                #expect(actual.albums.map(\.id) == expected.albums.map(\.id), "round \(round) \(query)")
                #expect(actual.artists.map(\.id) == expected.artists.map(\.id), "round \(round) \(query)")
                #expect(store.lastAlbumCandidateCount == reference.lastAlbumCandidateCount, "round \(round) \(query)")
            }
        }
        #expect(store.preparationCount == reference.preparationCount)
    }

    @Test("The App's literal-then-pinyin expectations hold")
    func literalThenPinyin() throws {
        let albums = [Album(id: "literal", title: "qlx live"), Album(id: "pinyin", title: "七里香")]
        let store = try LibraryCollectionSearchStore.temporary()
        #expect(try store.search(query: "qlx", albums: albums, artists: [], includePinyin: false).albums.map(\.id) == ["literal"])
        #expect(Set(try store.search(query: "qlx", albums: albums, artists: []).albums.map(\.id)) == ["literal", "pinyin"])
        let warm = try store.search(query: "qlx", albums: albums, artists: [], includePinyin: false)
        #expect(Set(warm.albums.map(\.id)) == ["literal", "pinyin"])
        #expect(store.preparationCount == 2)
    }

    @Test("Instances sharing one database keep apart, and a cancelled rebuild keeps the old rows")
    func instancesAndCancellation() throws {
        let first = try LibraryCollectionSearchStore.temporary()
        let albums = [Album(id: "a", title: "Moonlight"), Album(id: "b", title: "Other")]
        #expect(try first.search(query: "moon", albums: albums, artists: []).albums.map(\.id) == ["a"])
        let replaced = [Album(id: "c", title: "Moonlight two"), Album(id: "d", title: "Moonlight three")]
        var checks = 0
        let cancelled = try first.search(query: "moon", albums: replaced, artists: [], isCancelled: {
            checks += 1
            return checks > 2
        })
        #expect(cancelled.albums.isEmpty)
        #expect(try first.search(query: "moon", albums: albums, artists: []).albums.map(\.id) == ["a"])
        #expect(first.preparationCount == 1)

        // 两个实例共用一个库(各占一个 space)。
        let queue = try DatabaseQueue()
        try queue.write { db in try LibraryCollectionSearchStore.createTables(in: db) }
        let left = LibraryCollectionSearchStore(writer: queue)
        let right = LibraryCollectionSearchStore(writer: queue)
        #expect(try left.search(query: "moon", albums: albums, artists: []).albums.map(\.id) == ["a"])
        #expect(try right.search(query: "moon", albums: replaced, artists: []).albums.map(\.id) == ["d", "c"])
        #expect(try left.search(query: "moon", albums: albums, artists: []).albums.map(\.id) == ["a"])
    }
}

// MARK: - Reference: today's App implementation (actor body, made a class), copied verbatim

final class ReferenceCollectionSearchIndex {
    struct Output {
        let albums: [Album]
        let artists: [Artist]
    }

    private struct AlbumText {
        let title: LibrarySearchTextMatcher.PreparedText
        let artist: LibrarySearchTextMatcher.PreparedText
    }
    private var albums: [Album] = []
    private var artists: [Artist] = []
    private var albumText: [AlbumText] = []
    private var artistText: [LibrarySearchTextMatcher.PreparedText] = []
    private var albumIDs = Set<String>()
    private var albumIncludesPinyin = false
    private var albumPostings: [Unicode.Scalar: Set<Int>] = [:]
    private var artistPostings: [Unicode.Scalar: Set<Int>] = [:]
    private var texts: [String: LibrarySearchTextMatcher.PreparedText] = [:]
    private(set) var preparationCount = 0
    private(set) var lastAlbumCandidateCount = 0

    private static func sharesStorage<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }

    private func prepared(_ text: String, includesPinyin: Bool) -> LibrarySearchTextMatcher.PreparedText {
        if let cached = texts[text], cached.includesPinyin || !includesPinyin { return cached }
        let value = LibrarySearchTextMatcher.PreparedText(text, includesPinyin: includesPinyin)
        texts[text] = value
        return value
    }

    private func prepare(albums nextAlbums: [Album], artists nextArtists: [Artist], includesPinyin: Bool) -> Bool {
        if !Self.sharesStorage(albums, nextAlbums) || (includesPinyin && !albumIncludesPinyin) {
            var rows: [AlbumText] = []
            var postings: [Unicode.Scalar: Set<Int>] = [:]
            rows.reserveCapacity(nextAlbums.count)
            for (index, album) in nextAlbums.enumerated() {
                let row = AlbumText(
                    title: prepared(album.title, includesPinyin: includesPinyin),
                    artist: prepared(album.artistName ?? "", includesPinyin: includesPinyin)
                )
                rows.append(row)
                for character in row.title.characters.union(row.artist.characters) {
                    postings[character, default: []].insert(index)
                }
            }
            albums = nextAlbums
            albumText = rows
            albumPostings = postings
            albumIDs = Set(nextAlbums.map(\.id))
            albumIncludesPinyin = includesPinyin
            preparationCount += 1
        }
        if !Self.sharesStorage(artists, nextArtists) {
            var rows: [LibrarySearchTextMatcher.PreparedText] = []
            var postings: [Unicode.Scalar: Set<Int>] = [:]
            for (index, artist) in nextArtists.enumerated() {
                let row = prepared(artist.name, includesPinyin: false)
                rows.append(row)
                for character in row.characters { postings[character, default: []].insert(index) }
            }
            artists = nextArtists
            artistText = rows
            artistPostings = postings
            preparationCount += 1
        }
        if texts.count > max(1_024, 2 * (nextAlbums.count * 2 + nextArtists.count)) {
            var retained = Set(nextAlbums.flatMap { [$0.title, $0.artistName ?? ""] })
            retained.formUnion(nextArtists.map(\.name))
            texts = texts.filter { retained.contains($0.key) }
        }
        return true
    }

    private func candidates(
        _ query: String, postings: [Unicode.Scalar: Set<Int>], alphanumericOnly: Bool = true
    ) -> Set<Int> {
        let characters = Set(query.unicodeScalars.filter {
            alphanumericOnly ? CharacterSet.alphanumerics.contains($0) : !CharacterSet.whitespacesAndNewlines.contains($0)
        })
        guard !characters.isEmpty else { return [] }
        let lists = characters.map { postings[$0] ?? [] }.sorted { $0.count < $1.count }
        var result = lists[0]
        for list in lists.dropFirst() {
            result.formIntersection(list)
            if result.isEmpty { break }
        }
        return result
    }

    func search(
        query: String, albums: [Album], artists: [Artist],
        relatedAlbums: [Album] = [], semanticArtists: Bool = false,
        includePinyin: Bool = true
    ) -> Output {
        let matcher = LibrarySearchTextMatcher(query: query)
        guard !matcher.rawQuery.isEmpty,
              prepare(albums: albums, artists: artists, includesPinyin: includePinyin && matcher.requiresPinyinCandidates) else {
            return Output(albums: [], artists: [])
        }
        let offsets = candidates(matcher.normalizedQuery, postings: albumPostings)
        lastAlbumCandidateCount = offsets.count
        var ranked: [(Album, Int)] = []
        for offset in offsets.sorted() {
            let row = albumText[offset]
            let titleScore = matcher.score(prepared: row.title).map { $0 + 20 } ?? 0
            let artistScore = matcher.score(prepared: row.artist).map { $0 + 10 } ?? 0
            let score = max(titleScore, artistScore)
            if score > 0 { ranked.append((self.albums[offset], score)) }
        }
        var matchedAlbums = ranked.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.map(\.0)
        var seen = Set(matchedAlbums.map(\.id))
        matchedAlbums += relatedAlbums.filter { albumIDs.contains($0.id) && seen.insert($0.id).inserted }
        let semanticQuery = ListeningSpaceSearchPolicy.normalized(query)
        let words = semanticQuery.split(separator: " ")
        let artistCandidates = candidates(semanticQuery, postings: artistPostings, alphanumericOnly: false)
        let matchedArtists = artistCandidates.sorted().compactMap { offset -> Artist? in
            let text = artistText[offset]
            let matches = semanticArtists
                ? text.semantic.contains(semanticQuery) || (words.count > 1 && words.allSatisfy { text.semantic.contains($0) })
                : text.raw.localizedCaseInsensitiveContains(matcher.rawQuery)
            return matches ? self.artists[offset] : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Output(albums: matchedAlbums, artists: matchedArtists)
    }
}
