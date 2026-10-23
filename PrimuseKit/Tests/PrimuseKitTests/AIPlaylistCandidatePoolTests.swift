import Foundation
import Testing
@testable import PrimuseKit

@Suite("AI playlist candidate pool")
struct AIPlaylistCandidatePoolTests {
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
        #expect(pool.filter { $0.hasPrefix("w") }.count == AIPlaylistCandidatePoolPolicy.reservedForBreadth)
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
