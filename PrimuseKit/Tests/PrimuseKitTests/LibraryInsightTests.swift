import Foundation
import Testing
@testable import PrimuseKit

struct LibraryInsightTests {
    @Test func albumRequestIsClippedDedupedAndCapped() throws {
        let subject = LibraryInsightSubject.album(
            title: "  First   Love ",
            artist: "宇多田ヒカル",
            year: 20011,
            genres: ["J-Pop", "j-pop", "", "R&B", "A", "B", "C", "D"],
            tracks: (0..<50).map { "Track \($0)" } + [String(repeating: "x", count: 300)]
        )
        let request = try #require(LibraryInsightAIExchange.request(for: subject, languageCode: "zh-Hans"))
        #expect(request.kind == .album)
        #expect(request.artist == nil)
        let album = try #require(request.album)
        #expect(album.title == "First Love")
        #expect(album.year == nil)
        #expect(album.genres == ["J-Pop", "R&B", "A", "B", "C"])
        #expect(album.tracks.count == 40)

        let json = LibraryInsightAIExchange.payloadJSON(request) ?? ""
        #expect(json.contains("\"language_code\":\"zh-Hans\""))
        #expect(json.contains("\"kind\":\"album\""))
        #expect(!json.contains("\"artist\":{"))
    }

    @Test func artistRequestKeepsAlbumsWithYears() throws {
        let albums = (0..<25).map { LibraryInsightSubject.AlbumReference(title: "Album \($0)", year: 1990 + $0) }
            + [.init(title: "album 1", year: nil), .init(title: " ", year: 2000)]
        let subject = LibraryInsightSubject.artist(
            name: "Utada", genres: ["Pop"], albums: albums, tracks: (0..<30).map { "Song \($0)" }
        )
        let request = try #require(LibraryInsightAIExchange.request(for: subject, languageCode: "en"))
        let artist = try #require(request.artist)
        #expect(request.album == nil)
        #expect(artist.albums.count == 20)
        #expect(artist.albums.first == .init(title: "Album 0", year: 1990))
        #expect(artist.tracks.count == 20)
    }

    @Test func missingNamesProduceNoRequest() {
        #expect(LibraryInsightAIExchange.request(
            for: .album(title: "  ", artist: "A", year: nil, genres: [], tracks: []),
            languageCode: "en") == nil)
        #expect(LibraryInsightAIExchange.request(
            for: .artist(name: "", genres: [], albums: [], tracks: []),
            languageCode: "en") == nil)
    }

    @Test func knownAnswerIsCleanedAndTagsCapped() throws {
        let output = """
        Sure:
        {"known": true, "summary": "  第一段\\u0007 介绍。\\n\\n第二段   内容。\\n第三段要并进来。",
         "tags": ["J-Pop", "j-pop", "", "R&B", "90 年代", "抒情", "都市", "多余", "\(String(repeating: "长", count: 30))"]}
        """
        let answer = try LibraryInsightAIExchange.answer(from: output)
        #expect(answer.known)
        #expect(answer.summary == "第一段 介绍。\n第二段 内容。 第三段要并进来。")
        #expect(answer.tags == ["J-Pop", "R&B", "90 年代", "抒情", "都市"])
    }

    @Test func unknownOrEmptyAnswersAreBlanked() throws {
        let unknown = try LibraryInsightAIExchange.answer(
            from: #"{"known": false, "summary": "Probably a pop album.", "tags": ["Pop"]}"#
        )
        #expect(unknown == .init(known: false, summary: "", tags: []))
        let empty = try LibraryInsightAIExchange.answer(from: #"{"known": true, "summary": "   ", "tags": ["Pop"]}"#)
        #expect(empty == .init(known: false, summary: "", tags: []))
    }

    @Test func linksAndMalformedAnswersThrow() {
        #expect(throws: LibraryInsightAIExchangeError.containsLink) {
            try LibraryInsightAIExchange.answer(from: #"{"known": true, "summary": "See https://x.com", "tags": []}"#)
        }
        #expect(throws: LibraryInsightAIExchangeError.containsLink) {
            try LibraryInsightAIExchange.answer(from: #"{"known": true, "summary": "Fine.", "tags": ["www.x.com"]}"#)
        }
        #expect(throws: LibraryInsightAIExchangeError.malformedResponse) {
            try LibraryInsightAIExchange.answer(from: "no json here")
        }
        #expect(throws: LibraryInsightAIExchangeError.malformedResponse) {
            try LibraryInsightAIExchange.answer(from: #"{"summary": "x"}"#)
        }
    }

    @Test func longSummariesCutAtSentenceEndOrEllipsis() throws {
        let sentence = String(repeating: "很", count: 99) + "。"
        let long = String(repeating: sentence, count: 7)
        let cut = try LibraryInsightAIExchange.validated(known: true, summary: long, tags: [])
        #expect(cut.summary.count == 600)
        #expect(cut.summary.hasSuffix("。"))

        let decimals = String(repeating: "Version 2.5 of Mr.Children", count: 30)
        let noFalseStop = try LibraryInsightAIExchange.validated(known: true, summary: decimals, tags: [])
        #expect(noFalseStop.summary.hasSuffix("…"))

        let quoted = String(repeating: "x", count: 500) + "他说「好。」" + String(repeating: "y", count: 200)
        let keepsCloser = try LibraryInsightAIExchange.validated(known: true, summary: quoted, tags: [])
        #expect(keepsCloser.summary.hasSuffix("好。」"))

        let noStop = String(repeating: "a", count: 700)
        let hard = try LibraryInsightAIExchange.validated(known: true, summary: noStop, tags: [])
        #expect(hard.summary.count == 600)
        #expect(hard.summary.hasSuffix("…"))
    }

    @Test func cacheKeysFollowFoldedNamesAndScript() {
        let a = LibraryInsightSubject.album(title: "First Love", artist: "Ｕｔａｄａ", year: nil, genres: [], tracks: [])
        let b = LibraryInsightSubject.album(title: " first love", artist: "utada", year: 1999, genres: ["Pop"], tracks: ["x"])
        #expect(a.cacheKey(languageCode: "zh-Hans") == b.cacheKey(languageCode: "zh_CN"))
        #expect(a.cacheKey(languageCode: "zh-Hans") != a.cacheKey(languageCode: "zh-Hant"))
        #expect(a.cacheKey(languageCode: "en-US") == a.cacheKey(languageCode: "en"))
        let artist = LibraryInsightSubject.artist(name: "Utada", genres: [], albums: [], tracks: [])
        #expect(artist.cacheKey(languageCode: "en") != a.cacheKey(languageCode: "en"))
        #expect(LibraryInsightAIExchange.normalizedLanguageCode("zh-HK") == "zh-Hant")
        #expect(LibraryInsightAIExchange.normalizedLanguageCode("ja-JP") == "ja")
    }

    @Test func topGenresSplitAndRankByCount() {
        let genres = LibraryInsightSubject.topGenres(["Pop; Rock", "pop", nil, "Jazz", "Other", "Rock"], limit: 2)
        #expect(genres == ["Pop", "Rock"])
    }

    @Test func cacheRoundTripsAndDropsOldestPastTheLimit() {
        var cache = LibraryInsightCache()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(LibraryInsightCache.maximumEntries + 2) {
            cache.store(
                LibraryInsight(
                    kind: .album, known: true, summary: "S\(index)", tags: [],
                    providerName: "AI", languageCode: "en",
                    generatedAt: base.addingTimeInterval(TimeInterval(index))
                ),
                for: "k\(index)"
            )
        }
        #expect(cache.entries.count == LibraryInsightCache.maximumEntries)
        #expect(cache.entries["k0"] == nil)
        #expect(cache.entries["k1"] == nil)
        #expect(cache.entries["k2"] != nil)
        #expect(LibraryInsightCache.decode(cache.encoded()) == cache)
        #expect(LibraryInsightCache.decode(Data("bad".utf8)) == LibraryInsightCache())
    }
}
