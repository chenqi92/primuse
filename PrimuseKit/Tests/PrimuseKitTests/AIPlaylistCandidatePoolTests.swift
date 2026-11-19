import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI playlist candidate pool")
struct AIPlaylistCandidatePoolTests {
    @Test("Indexed candidates include rare distant matches, respect exclusions and cover the full library")
    func indexedRareMatches() {
        var songs = (0..<12_000).map { i in
            Song(id: String(i), title: "Track \(i)", artistName: "Artist \(i)", duration: 2,
                 fileFormat: .mp3, filePath: "/\(i)", sourceID: "local")
        }
        songs[11_991].year = 1984
        songs[11_992].genre = "Jazz"
        songs[11_993].artistName = "Favorite"
        let excluded: Set<String> = ["11995"]
        func pick(_ salt: UInt64) -> [String] {
            AIPlaylistCandidatePoolPolicy.indexedCandidates(
                in: songs, texts: ["80年代 爵士"], searchIDs: ["11995", "11994"], topArtists: ["Favorite"],
                topSongIDs: ["11990"], genreGroups: [["11995", "11992"]], artistGroups: [["11993"]],
                lookup: { Int($0).map { songs[$0] } }, excluding: excluded, salt: salt, limit: 100
            ).map(\.id)
        }
        let result = pick(42)
        #expect(Set(result).count == 100)
        #expect(Set(["11990", "11991", "11992", "11993", "11994"]).isSubset(of: Set(result)))
        #expect(!result.contains("11995"))
        #expect(result == pick(42))
        #expect(result != pick(43))
    }
    /// 「b-3」= 艺人 b 的第 3 首。
    private func artist(_ id: String) -> String? {
        id.split(separator: "-").first.map(String.init)
    }

    @Test("Matched songs take turns and leave room for taste and breadth")
    func reservesBreadth() {
        let search = (1...40).map { "s\($0)-1" }
        let genre = (1...40).map { "g\($0)-1" }
        let spread = (1...40).map { "w\($0)-1" }
        let pool = AIPlaylistCandidatePoolPolicy.compose(
            matched: [search, genre],
            taste: [],
            spread: spread,
            limit: 36,
            artist: artist
        )
        #expect(pool.count == 36)
        #expect(Array(pool.prefix(4)) == ["s1-1", "g1-1", "s2-1", "g2-1"])
        #expect(pool.filter { $0.hasPrefix("w") }.count == AIPlaylistCandidatePoolPolicy.reservedForBreadth(in: 36))
    }

    @Test("Sampling covers the end of the library and keeps the first playable copy of each ID")
    func samplesAcrossTheWholeLibrary() {
        var songs = (0..<4_000).map { index in
            Song(id: "track-\(index)", title: "Track \(index)", artistName: "Artist \(index)",
                 duration: 180, fileFormat: .flac, filePath: "/track/\(index)", sourceID: "sample")
        }
        let last = songs.count - 1
        songs[last].genre = "Indie Rock"
        songs[last].year = 1995
        var duplicate = songs[last]
        duplicate.id = songs[0].id
        duplicate.title = "Later conflicting copy"
        songs.append(duplicate)
        let salt: UInt64 = 27
        let sampled = AIPlaylistCandidatePoolPolicy.songs(
            in: songs, texts: [], searchIDs: [], topArtists: [], topSongIDs: [], salt: salt, limit: 100
        )
        func hash(_ id: String) -> UInt64 {
            id.utf8.reduce(14_695_981_039_346_656_037 ^ salt) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        let expected = songs.dropLast().map { (id: $0.id, hash: hash($0.id)) }.sorted { $0.hash < $1.hash }
        #expect(sampled.map(\.id) == expected.prefix(100).map(\.id))
        let matches = AIPlaylistCandidatePoolPolicy.songs(
            in: songs, texts: ["90年代摇滚"], searchIDs: ["missing", songs[0].id], topArtists: [],
            topSongIDs: [], salt: salt, limit: 10
        )
        #expect(matches.prefix(2).map(\.id) == [songs[0].id, songs[last].id])
        #expect(matches.first?.title == songs[0].title)
        #expect(AIPlaylistCandidatePoolPolicy.songs(in: songs, texts: [], searchIDs: [], topArtists: [],
                                                  topSongIDs: [], salt: salt, limit: 10, isCancelled: { true }).isEmpty)
    }

    @Test("A full-size pool keeps a fifth for breadth and puts the matched songs first")
    func fullSizePool() {
        let search = (1...120).map { "s\($0)-1" }
        let spread = (1...120).map { "w\($0)-1" }
        let pool = AIPlaylistCandidatePoolPolicy.compose(
            matched: [search], taste: [], spread: spread, artist: artist
        )
        #expect(pool.count == AIPlaylistCandidatePoolPolicy.poolSize)
        #expect(pool.filter { $0.hasPrefix("w") }.count == 20)
        // 只认前 36 首的旧服务拿到的全是和提示词直接相关的。
        #expect(pool.prefix(36).allSatisfy { $0.hasPrefix("s") })
    }

    @Test("Without taste or breadth the matched songs fill the whole pool")
    func matchedFillWhenNoBreadth() {
        let search = (1...50).map { "s\($0)-1" }
        let pool = AIPlaylistCandidatePoolPolicy.compose(
            matched: [search], taste: [], spread: [], limit: 36, artist: artist
        )
        #expect(pool == Array(search.prefix(36)))
    }

    @Test("Search results by one artist are kept; breadth only adds new artists")
    func breadthAddsNewArtists() {
        let search = (1...10).map { "jay-\($0)" }
        let taste = ["jay-11", "eason-1", "eason-2", "eason-3"]
        let spread = ["jay-20", "eason-9", "adele-1", "queen-1", "queen-2"]
        let pool = AIPlaylistCandidatePoolPolicy.compose(
            matched: [search], taste: taste, spread: spread, limit: 16, artist: artist
        )
        #expect(pool.filter { $0.hasPrefix("jay-") }.count == 10 + 1)
        #expect(pool.contains("eason-1") && pool.contains("eason-2"))
        #expect(pool.contains("adele-1") && pool.contains("queen-1"))
        // 限量挡下的最后才补。
        #expect(pool.count == 16)
        #expect(Set(pool).count == 16)
    }

    @Test("Taste is capped per artist before spread fills the rest")
    func tasteCap() {
        let taste = ["a-1", "a-2", "a-3", "b-1"]
        let spread = ["c-1", "d-1"]
        let pool = AIPlaylistCandidatePoolPolicy.compose(
            matched: [], taste: taste, spread: spread, limit: 5, artist: artist
        )
        #expect(pool == ["a-1", "a-2", "b-1", "c-1", "d-1"])
    }
}

@Suite("Reading genres and decades from an AI playlist prompt")
struct AIPlaylistPromptHintsTests {
    private let genres = ["Pop", "Rock", "Punk Rock", "Jazz", "中国摇滚", "R&B", "Mandopop", "Folk", "Soundtrack", "Lo-Fi"]

    @Test("Chinese genre words find English genre tags")
    func chineseToEnglish() {
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["来点爵士乐"], libraryGenres: genres) == ["Jazz"])
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["适合开车的摇滚"], libraryGenres: genres)
            == ["Rock", "Punk Rock", "中国摇滚"])
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["电影原声"], libraryGenres: genres) == ["Soundtrack"])
    }

    @Test("Expanded terms and genre names written in the prompt both count")
    func expandedTermsAndLiteralNames() {
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["安静", "folk"], libraryGenres: genres) == ["Folk"])
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["mandopop 情歌"], libraryGenres: genres)
            .contains("Mandopop"))
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["学习时听的 lofi"], libraryGenres: genres) == ["Lo-Fi"])
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["chill lo-fi beats"], libraryGenres: genres) == ["Lo-Fi"])
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["R&B"], libraryGenres: genres) == ["R&B"])
    }

    @Test("Short words do not match inside unrelated words")
    func noShortFalsePositives() {
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["下雨天"], libraryGenres: genres).isEmpty)
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["herb garden"], libraryGenres: genres).isEmpty)
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["most relaxing songs"], libraryGenres: genres).isEmpty)
        #expect(AIPlaylistPromptHints.matchingGenres(texts: ["kpop 舞曲"], libraryGenres: ["Pop"]).isEmpty)
    }

    @Test("Decades in Chinese and English")
    func decades() {
        #expect(AIPlaylistPromptHints.decades(in: "90年代粤语金曲") == [1990...1999])
        #expect(AIPlaylistPromptHints.decades(in: "八十年代的老歌") == [1980...1989])
        #expect(AIPlaylistPromptHints.decades(in: "80s 迪斯科") == [1980...1989])
        #expect(AIPlaylistPromptHints.decades(in: "1970s rock") == [1970...1979])
        #expect(AIPlaylistPromptHints.decades(in: "00年代和2010s") == [2000...2009, 2010...2019])
        #expect(AIPlaylistPromptHints.decades(in: "80's hits") == [1980...1989])
        #expect(AIPlaylistPromptHints.decades(in: "90 年代") == [1990...1999])
    }

    @Test("Numbers that are not decades are ignored")
    func notDecades() {
        #expect(AIPlaylistPromptHints.decades(in: "适合跑步的歌").isEmpty)
        #expect(AIPlaylistPromptHints.decades(in: "1990年的夏天").isEmpty)
        #expect(AIPlaylistPromptHints.decades(in: "听 30 首").isEmpty)
        #expect(AIPlaylistPromptHints.decades(in: "85年代").isEmpty)
        #expect(AIPlaylistPromptHints.decades(in: "80seconds").isEmpty)
    }
}
