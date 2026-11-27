import Foundation
import Testing
@testable import PrimuseKit

struct SongDiscoveryTests {
    private func request(
        count: Int = 20,
        avoid: [SongDiscoveryPair] = []
    ) -> SongDiscoveryAIExchange.Request {
        SongDiscoveryAIExchange.request(
            languageCode: "zh-Hans",
            count: count,
            focusGenre: nil,
            taste: SongDiscoveryTaste(genres: [.init(name: "Pop", weight: 3)]),
            avoid: avoid
        )
    }

    @Test func tasteCountsGenresArtistsAndDecadesWithLikedBoost() {
        var accumulator = SongDiscoveryTasteAccumulator(ignoredArtistNames: ["Unknown Artist"])
        accumulator.add(title: "A1", artist: "Alpha", genre: "Pop; Rock", year: 1995, isLiked: false)
        accumulator.add(title: "A2", artist: "Alpha feat. Beta", genre: "pop", year: 1998, isLiked: true)
        accumulator.add(title: "B1", artist: "Beta", genre: "Jazz", year: 2004, isLiked: false)
        accumulator.add(title: "U1", artist: "Unknown Artist", genre: "Other", year: 20011, isLiked: false)
        accumulator.add(title: "N1", artist: nil, genre: nil, year: nil, isLiked: false)

        let taste = accumulator.taste()
        #expect(accumulator.songCount == 5)
        #expect(taste.genres.map(\.name) == ["Pop", "Jazz", "Rock"])
        #expect(taste.genres.first?.weight == 1 + SongDiscoveryTasteAccumulator.likedWeight)
        #expect(taste.artists.map(\.name) == ["Alpha", "Beta"])
        #expect(taste.artists.first?.weight == 5)
        #expect(taste.decades.map(\.decade) == [1990, 2000])
        #expect(!taste.isEmpty)
    }

    @Test func focusGenreOnlyCountsSongsOfThatGenre() {
        var accumulator = SongDiscoveryTasteAccumulator(focusGenre: "ＰＯＰ")
        accumulator.add(title: "A1", artist: "Alpha", genre: "Pop/Rock", year: nil, isLiked: false)
        accumulator.add(title: "B1", artist: "Beta", genre: "Jazz", year: nil, isLiked: false)
        #expect(accumulator.songCount == 1)
        #expect(accumulator.taste().artists.map(\.name) == ["Alpha"])
    }

    @Test func ownedSamplesPreferLikedSongsOfTopArtists() {
        var accumulator = SongDiscoveryTasteAccumulator()
        for index in 0..<8 {
            accumulator.add(title: "Alpha \(index)", artist: "Alpha", genre: nil, year: nil, isLiked: false)
        }
        accumulator.add(title: "Alpha Loved", artist: "Alpha", genre: nil, year: nil, isLiked: true)
        accumulator.add(title: "Beta 1", artist: "Beta", genre: nil, year: nil, isLiked: false)
        let samples = accumulator.ownedSamples(limit: 4)
        #expect(samples.count == 4)
        #expect(samples.first == SongDiscoveryPair(title: "Alpha Loved", artist: "Alpha"))
        #expect(samples.allSatisfy { $0.artist == "Alpha" })
    }

    @Test func genreNamesSplitAndDropPlaceholders() {
        #expect(SongDiscoveryMatching.genreNames("Pop; Rock / pop|J-Pop") == ["Pop", "Rock", "J-Pop"])
        #expect(SongDiscoveryMatching.genreNames("Other").isEmpty)
        #expect(SongDiscoveryMatching.genreNames("(13)").isEmpty)
        #expect(SongDiscoveryMatching.genreNames("流行、摇滚") == ["流行", "摇滚"])
    }

    @Test func matchingIgnoresCaseWidthVersionSuffixAndFeaturing() {
        #expect(SongDiscoveryMatching.titleKey("First Love (Remastered 2014)") == SongDiscoveryMatching.titleKey("first  love"))
        #expect(SongDiscoveryMatching.titleKey("Song - Live") == SongDiscoveryMatching.titleKey("Song"))
        #expect(SongDiscoveryMatching.titleKey("(Intro)") == SongDiscoveryMatching.titleKey("(Intro)"))
        #expect(!SongDiscoveryMatching.titleKey("(Intro)").isEmpty)
        #expect(SongDiscoveryMatching.artistKey("Ａｌｐｈａ ft. Beta") == SongDiscoveryMatching.artistKey("alpha"))
        #expect(SongDiscoveryMatching.primaryArtist("Simon & Garfunkel") == "Simon & Garfunkel")
    }

    @Test func requestAppliesCapsAndTruncation() {
        let longName = String(repeating: "x", count: 200)
        let taste = SongDiscoveryTaste(
            genres: (0..<20).map { .init(name: "G\($0)", weight: $0) },
            artists: (0..<50).map { .init(name: $0 == 0 ? longName : "A\($0)", weight: -1) },
            decades: [.init(decade: 1995, weight: 1), .init(decade: 1990, weight: 2)]
        )
        let avoid = (0..<100).map { SongDiscoveryPair(title: "T\($0)", artist: "A") }
            + [SongDiscoveryPair(title: "T1", artist: "a"), SongDiscoveryPair(title: " ", artist: "A")]
        let built = SongDiscoveryAIExchange.request(
            languageCode: "zh-Hans", count: 99, focusGenre: "  ", taste: taste, avoid: avoid
        )
        #expect(built.count == SongDiscoveryAIExchange.maximumCount)
        #expect(built.focusGenre == nil)
        #expect(built.taste.genres.count == 12)
        #expect(built.taste.artists.count == 40)
        #expect(built.taste.artists[0].name.count == 120)
        #expect(built.taste.artists[0].weight == 0)
        #expect(built.taste.decades.map(\.decade) == [1990])
        #expect(built.avoid.count == SongDiscoveryAIExchange.maximumAvoid)

        let json = SongDiscoveryAIExchange.payloadJSON(built) ?? ""
        #expect(json.contains("\"language_code\":\"zh-Hans\""))
        #expect(!json.contains("focus_genre"))
    }

    @Test func freeFormAnswersAreValidatedItemByItem() throws {
        let output = """
        Here you go:
        {"songs":[
          {"title":"Automatic","artist":"宇多田ヒカル","album":"First Love","year":1998,"reason":"像你常听的"},
          {"title":"automatic","artist":"宇多田ヒカル","year":"1998"},
          {"title":"Link","artist":"See https://example.com"},
          {"title":"","artist":"Nobody"},
          {"title":"Old","artist":"Someone","year":1700,"reason":"  多余   空白  "},
          {"title":"Skip Me","artist":"Avoided"}
        ]}
        """
        let built = request(avoid: [SongDiscoveryPair(title: "Skip me (Live)", artist: "avoided")])
        let suggestions = try SongDiscoveryAIExchange.suggestions(from: output, request: built, currentYear: 2026)
        #expect(suggestions.map(\.title) == ["Automatic", "Old"])
        #expect(suggestions[0].album == "First Love")
        #expect(suggestions[0].year == 1998)
        #expect(suggestions[1].year == nil)
        #expect(suggestions[1].reason == "多余 空白")
        #expect(suggestions[0].copyText == "Automatic - 宇多田ヒカル")
    }

    @Test func countCapsTheAnswer() throws {
        let items = (0..<10).map { #"{"title":"S\#($0)","artist":"A\#($0)"}"# }.joined(separator: ",")
        let suggestions = try SongDiscoveryAIExchange.suggestions(
            from: #"{"songs":[\#(items)]}"#, request: request(count: 3), currentYear: 2026
        )
        #expect(suggestions.count == 3)
    }

    @Test func malformedOrAllInvalidAnswersThrowButEmptyListIsFine() throws {
        #expect(throws: SongDiscoveryAIExchangeError.malformedResponse) {
            try SongDiscoveryAIExchange.suggestions(from: "no json", request: request(), currentYear: 2026)
        }
        #expect(throws: SongDiscoveryAIExchangeError.malformedResponse) {
            try SongDiscoveryAIExchange.suggestions(
                from: #"{"songs":[{"title":"x"}]}"#, request: request(), currentYear: 2026
            )
        }
        let empty = try SongDiscoveryAIExchange.suggestions(
            from: #"{"songs":[]}"#, request: request(), currentYear: 2026
        )
        #expect(empty.isEmpty)
    }

    @Test func libraryMatcherDropsOwnedSongsAndMarksKnownArtists() {
        let suggestions = [
            SongDiscoverySuggestion(title: "Automatic", artist: "Utada"),
            SongDiscoverySuggestion(title: "Traveling", artist: "Utada"),
            SongDiscoverySuggestion(title: "New One", artist: "Stranger"),
        ]
        var matcher = SongDiscoveryLibraryMatcher(suggestions: suggestions)
        matcher.consider(title: "Automatic (Remastered)", artist: "utada feat. Someone")
        matcher.consider(title: "Other", artist: "Utada")
        matcher.consider(title: "New One", artist: "Somebody Else")
        matcher.consider(title: "Untagged", artist: nil)
        let filtered = matcher.filtered(suggestions)
        #expect(filtered.map(\.title) == ["Traveling", "New One"])
        #expect(filtered[0].artistInLibrary)
        #expect(!filtered[1].artistInLibrary)
    }

    @Test func traditionalAndSimplifiedSpellingsCountAsTheSameSong() {
        let suggestions = [SongDiscoverySuggestion(title: "後來", artist: "劉若英")]
        var matcher = SongDiscoveryLibraryMatcher(suggestions: suggestions)
        matcher.consider(title: "后来", artist: "刘若英")
        #expect(matcher.filtered(suggestions).isEmpty)
    }

    @Test func historyKeepsOneBatchPerFocusAndRemembersShownSongs() throws {
        var history = SongDiscoveryHistory()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        history.record(.init(focusGenre: nil, generatedAt: date, providerName: "AI",
                             suggestions: [SongDiscoverySuggestion(title: "A", artist: "X")]))
        history.record(.init(focusGenre: "Pop", generatedAt: date, providerName: "AI",
                             suggestions: [SongDiscoverySuggestion(title: "B", artist: "Y")]))
        history.record(.init(focusGenre: "pop", generatedAt: date, providerName: "AI",
                             suggestions: [SongDiscoverySuggestion(title: "A", artist: "x")]))
        #expect(history.batches.count == 2)
        #expect(history.batch(for: "POP")?.suggestions.first?.title == "A")
        #expect(history.batch(for: nil)?.suggestions.first?.title == "A")
        #expect(history.recentlyShown.map(\.title) == ["A", "B"])

        let decoded = SongDiscoveryHistory.decode(history.encoded())
        #expect(decoded == history)
        #expect(SongDiscoveryHistory.decode(Data("bad".utf8)) == SongDiscoveryHistory())
    }
}
