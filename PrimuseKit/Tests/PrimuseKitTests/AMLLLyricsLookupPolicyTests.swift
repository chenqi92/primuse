import Foundation
import Testing
@testable import PrimuseKit

@Suite("AMLLLyricsLookupPolicy requests")
struct AMLLLyricsLookupPolicyRequestTests {
    @Test func searchURLCarriesTitleArtistAndPageSize() throws {
        let url = try #require(AMLLLyricsLookupPolicy.searchURL(title: " 晴天 ", artistName: "周杰伦"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "api.amll.dev")
        #expect(components.path == "/v1/lyrics/search")
        let items = components.queryItems ?? []
        #expect(items.first { $0.name == "musicName" }?.value == "晴天")
        #expect(items.first { $0.name == "artistName" }?.value == "周杰伦")
        #expect(items.first { $0.name == "pageSize" }?.value == "50")
    }

    @Test func searchURLWithoutArtistOmitsTheField() throws {
        let url = try #require(AMLLLyricsLookupPolicy.searchURL(title: "Idol", artistName: "  "))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains { $0.name == "artistName" } == false)
    }

    @Test func searchURLEncodesPlusSoItIsNotReadAsASpace() throws {
        let url = try #require(AMLLLyricsLookupPolicy.searchURL(title: "A+B", artistName: nil))
        #expect(url.absoluteString.contains("musicName=A%2BB"))
    }

    @Test func blankTitleHasNoSearch() {
        #expect(AMLLLyricsLookupPolicy.searchURL(title: " \n", artistName: "Singer") == nil)
    }

    @Test func lyricsURLUsesTheID() {
        #expect(AMLLLyricsLookupPolicy.lyricsURL(id: 7192686136682066)?.absoluteString
            == "https://api.amll.dev/v1/lyrics/get?id=7192686136682066")
        #expect(AMLLLyricsLookupPolicy.lyricsURL(id: -1) == nil)
    }

    @Test func searchArtistIsTheFirstRealName() {
        #expect(AMLLLyricsLookupPolicy.searchArtistName("Taylor Swift/Brendon Urie") == "Taylor Swift")
        #expect(AMLLLyricsLookupPolicy.searchArtistName("未知歌手") == nil)
        #expect(AMLLLyricsLookupPolicy.searchArtistName("群星、陈奕迅") == "陈奕迅")
        #expect(AMLLLyricsLookupPolicy.searchArtistName(nil) == nil)
    }
}

@Suite("AMLLLyricsLookupPolicy responses")
struct AMLLLyricsLookupPolicyResponseTests {
    @Test func decodesSearchItemsAndIgnoresExtraFields() throws {
        let body = #"""
        {"status":200,"data":{"items":[{"id":7192686136682066,"filename":"1730652389036-69615623-d1511ea9.ttml",
        "createdAt":1730652389036,"musicNames":["晴天"],"artistNames":["周杰伦"],"albumNames":["叶惠美"],
        "ncmMusicIds":["186016"],"qqMusicIds":["97773"],"appleMusicIds":["535824738"],"spotifyIds":[],
        "isrcs":["TWK970300503"],"authorIds":["69615623"],"authorUsernames":["Sikz1218"]}],
        "pagination":{"page":1,"pageSize":50,"total":1,"totalPages":1,"hasMore":false}}}
        """#
        let items = try AMLLLyricsLookupPolicy.decodeSearch(Data(body.utf8))
        #expect(items == [AMLLLyricsLookupPolicy.SongItem(
            id: 7192686136682066, musicNames: ["晴天"], artistNames: ["周杰伦"], albumNames: ["叶惠美"]
        )])
    }

    @Test func emptySearchDecodesToNoItems() throws {
        let body = #"{"status":200,"data":{"items":[],"pagination":{"page":1,"pageSize":50,"total":0,"totalPages":0,"hasMore":false}}}"#
        #expect(try AMLLLyricsLookupPolicy.decodeSearch(Data(body.utf8)).isEmpty)
    }

    @Test func decodesTheLyricsOfAGetResponse() throws {
        let body = #"{"status":200,"data":{"id":1,"musicNames":["Song"],"artistNames":["Singer"],"albumNames":[],"lyrics":"<tt/>","format":"ttml"}}"#
        #expect(try AMLLLyricsLookupPolicy.decodeSong(Data(body.utf8)).lyrics == "<tt/>")
    }
}

@Suite("AMLLLyricsLookupPolicy matching")
struct AMLLLyricsLookupPolicyMatchingTests {
    typealias Item = AMLLLyricsLookupPolicy.SongItem
    typealias Query = AMLLLyricsLookupPolicy.Query

    private func ids(_ query: Query, _ items: [Item]) -> [Int64] {
        AMLLLyricsLookupPolicy.rankedCandidates(for: query, in: items).map(\.id)
    }

    @Test func titleAndArtistMatch() {
        let items = [Item(id: 1, musicNames: ["晴天"], artistNames: ["周杰伦"], albumNames: ["叶惠美"])]
        #expect(ids(Query(title: "晴天", artist: "周杰伦"), items) == [1])
    }

    @Test func featuringSuffixAndAliasTitlesStillMatch() {
        let items = [
            Item(id: 1, musicNames: ["ME! (feat. Brendon Urie of Panic! At The Disco)"], artistNames: ["Taylor Swift", "Brendon Urie"]),
            Item(id: 2, musicNames: ["我是如此相信", "I truly believe"], artistNames: ["周杰伦"]),
        ]
        #expect(ids(Query(title: "ME!", artist: "Taylor Swift"), items) == [1])
        #expect(ids(Query(title: "I Truly Believe", artist: "周杰伦"), items) == [2])
    }

    @Test func differentArtistIsRejected() {
        let items = [Item(id: 1, musicNames: ["晴天"], artistNames: ["周杰伦"])]
        #expect(ids(Query(title: "晴天", artist: "孙燕姿"), items).isEmpty)
    }

    @Test func differentVersionIsRejected() {
        let items = [
            Item(id: 1, musicNames: ["稻香 (Remix摇滚版)"], artistNames: ["周杰伦"]),
            Item(id: 2, musicNames: ["稻香"], artistNames: ["周杰伦"]),
        ]
        #expect(ids(Query(title: "稻香", artist: "周杰伦"), items) == [2])
        #expect(ids(Query(title: "晴天 (Live)", artist: "周杰伦"), [Item(id: 3, musicNames: ["晴天"], artistNames: ["周杰伦"])]).isEmpty)
    }

    @Test func eitherOfSeveralArtistsIsEnough() {
        let items = [Item(id: 1, musicNames: ["ME!"], artistNames: ["Brendon Urie", "Taylor Swift"])]
        #expect(ids(Query(title: "ME!", artist: "Taylor Swift / Brendon Urie"), items) == [1])
        #expect(ids(Query(title: "ME!", artist: "Taylor Swift feat. Someone Else"), items) == [1])
    }

    @Test func sameAlbumAndMoreSharedArtistsRankFirst() {
        let items = [
            Item(id: 1, musicNames: ["ME!"], artistNames: ["Taylor Swift"], albumNames: ["ME! - Single"]),
            Item(id: 2, musicNames: ["ME!"], artistNames: ["Taylor Swift", "Brendon Urie"], albumNames: ["ME! - Single"]),
            Item(id: 3, musicNames: ["ME!"], artistNames: ["Taylor Swift"], albumNames: ["Lover"]),
        ]
        #expect(ids(Query(title: "ME!", artist: "Taylor Swift/Brendon Urie", album: "Lover"), items) == [3, 2, 1])
        #expect(ids(Query(title: "ME!", artist: "Taylor Swift/Brendon Urie"), items) == [2, 1, 3])
    }

    @Test func withoutArtistOnlyAnUnambiguousSongIsKept() {
        let one = [
            Item(id: 1, musicNames: ["Shape of You"], artistNames: ["Ed Sheeran"]),
            Item(id: 2, musicNames: ["Shape of You"], artistNames: ["Ed Sheeran"]),
        ]
        #expect(ids(Query(title: "Shape of You", artist: nil), one) == [1, 2])
        let two = [
            Item(id: 1, musicNames: ["Hello"], artistNames: ["Adele"]),
            Item(id: 2, musicNames: ["Hello"], artistNames: ["Lionel Richie"]),
        ]
        #expect(ids(Query(title: "Hello", artist: nil), two).isEmpty)
        #expect(ids(Query(title: "Hello", artist: "未知歌手"), two).isEmpty)
    }

    @Test func untitledQueryHasNoCandidates() {
        let items = [Item(id: 1, musicNames: ["晴天"], artistNames: ["周杰伦"])]
        #expect(ids(Query(title: "（）", artist: "周杰伦"), items).isEmpty)
    }
}

@Suite("AMLLLyricsLookupPolicy duration")
struct AMLLLyricsLookupPolicyDurationTests {
    @Test func lyricsWithinTheSongFit() {
        #expect(AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: 265.5, songDuration: 269, artistKnown: true))
        #expect(AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: 271, songDuration: 269, artistKnown: false))
    }

    @Test func lyricsRunningPastTheSongAreALongerVersion() {
        #expect(!AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: 280, songDuration: 269, artistKnown: true))
    }

    @Test func lyricsCoveringTooLittleAreAShortVersion() {
        #expect(!AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: 85, songDuration: 240, artistKnown: true))
        #expect(AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: 150, songDuration: 360, artistKnown: true))
    }

    @Test func unknownDurationNeedsAMatchedArtist() {
        #expect(AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: 200, songDuration: nil, artistKnown: true))
        #expect(!AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: 200, songDuration: 0, artistKnown: false))
        #expect(!AMLLLyricsLookupPolicy.lyricsFit(lastLyricEnd: nil, songDuration: 200, artistKnown: true))
    }

    @Test func comparableArtistIgnoresPlaceholders() {
        #expect(AMLLLyricsLookupPolicy.hasComparableArtist(.init(title: "x", artist: "周杰伦")))
        #expect(!AMLLLyricsLookupPolicy.hasComparableArtist(.init(title: "x", artist: "Various Artists")))
        #expect(!AMLLLyricsLookupPolicy.hasComparableArtist(.init(title: "x", artist: nil)))
    }
}
