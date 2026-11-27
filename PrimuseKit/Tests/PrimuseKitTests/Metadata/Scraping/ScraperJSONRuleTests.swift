import Foundation
import XCTest
@testable import PrimuseKit

final class ScraperJSONRuleTests: XCTestCase {
    func testCurrentSourceArtworkAdaptersKeepAudioIDAndRejectAPIError() throws {
        let search = try ScraperJSONRule(format: .hashCatalogSearch).parse(Data(#"{"data":{"info":[{"hash":"h","album_id":9,"album_audio_id":42,"songname":"Paper Lanterns","duration":180}]}}"#.utf8)) as? [[String: Any]]
        XCTAssertEqual((search?.first?["id"] as? String)?.components(separatedBy: "|").last, "42")
        for (format, body) in [
            (ScraperJSONRule.Format.albumCatalogMotionArtwork, #"{"code":200,"data":{"videoPlayUrl":"http://fixture.test/cover.mp4"}}"#),
            (.hashCatalogMotionArtwork, #"{"status":1,"data":[{"dycover":{"h265_url":"http://fixture.test/cover.mp4"}}]}"#)
        ] {
            let rows = try ScraperJSONRule(format: format).parse(Data(body.utf8)) as? [[String: String]]
            XCTAssertEqual(rows?.first?["coverUrl"], "https://fixture.test/cover.mp4")
            XCTAssertEqual(rows?.first?["kind"], "video")
        }
        XCTAssertThrowsError(try ScraperJSONRule(format: .albumCatalogMotionArtwork).parse(Data(#"{"code":403}"#.utf8)))
        XCTAssertThrowsError(try ScraperJSONRule(format: .hashCatalogMotionArtwork).parse(Data(#"{"status":0}"#.utf8)))
    }

    func testCatalogIdentityKeepsAliasesAndAlbumAcrossDetailLookup() throws {
        let body = Data(#"{"result":{"songs":[{"id":42,"name":"Paper Lanterns","artists":[{"name":"北岸","alias":["North Bay"]}],"album":{"name":"Evening"}}]}}"#.utf8)
        let rows = try ScraperJSONRule(format: .albumCatalogSearch).parse(body) as? [[String: Any]]
        XCTAssertEqual(rows?.first?["artistAliases"] as? [String], ["North Bay"])
        let hashBody = Data(#"{"data":{"info":[{"hash":"42","album_id":9,"songname":"Paper Lanterns","singername":"North Bay","album_name":"Evening","duration":180}]}}"#.utf8)
        let search = try ScraperJSONRule(format: .hashCatalogSearch).parse(hashBody) as? [[String: Any]]
        let id = try XCTUnwrap(search?.first?["id"] as? String)
        XCTAssertEqual(id.components(separatedBy: "|")[6], "")
        let detail = try ScraperJSONRule(format: .hashCatalogDetail).parse(Data("{}".utf8), externalID: id) as? [String: String]
        XCTAssertEqual(detail?["album"], "Evening")
        XCTAssertThrowsError(try ScraperJSONRule(format: .quotedCatalogLyrics).parse(Data(#"{"status":301,"data":null}"#.utf8)))
    }

    func testFieldMappingPreservesTypesAndDoesNotInterpretText() throws {
        let data = Data(#"{"items":[{"id":42,"title":"while(true){}","artists":[{"name":"North"},{"name":"Bay"}],"seconds":123}]}"#.utf8)
        let rule = ScraperJSONRule(path: "items", fields: [
            "id": .init(path: "id"), "title": .init(path: "title"),
            "artist": .init(path: "artists.*.name", join: " / "), "durationMs": .init(path: "seconds", scale: 1000)
        ], array: true)
        let items = try XCTUnwrap(rule.parse(data) as? [[String: Any]])
        XCTAssertEqual(items.first?["id"] as? Int, 42)
        XCTAssertEqual(items.first?["title"] as? String, "while(true){}")
        XCTAssertEqual(items.first?["artist"] as? String, "North / Bay")
        XCTAssertEqual(items.first?["durationMs"] as? Double, 123000)
        let local = ScraperJSONRule(fields: ["coverUrl": .init(path: "$id.1")], array: true)
        let cover = try local.parse(Data("{}".utf8), externalID: "42|https://fixture.test/cover.jpg") as? [[String: Any]]
        XCTAssertEqual(cover?.first?["coverUrl"] as? String, "https://fixture.test/cover.jpg")
        let text = ScraperJSONRule(format: .text, fields: ["lrcContent": .init(path: "$text")])
        let lyrics = try text.parse(Data("[00:01.00]Paper lanterns".utf8)) as? [String: String]
        XCTAssertEqual(lyrics?["lrcContent"], "[00:01.00]Paper lanterns")
    }

    func testNativeMetadataAdaptersKeepIdentifiersArtworkAndDurations() throws {
        let cases: [(ScraperJSONRule.Format, String, String, String)] = [
            (.albumCatalogSearch, #"{"result":{"songs":[{"id":42,"name":"Paper Lanterns","artists":[{"name":"North Bay"}],"album":{"name":"Evening","picId":123456789012345678},"duration":180000}]}}"#, "42", "https://fixture.test/123456789012345678?param=150y150"),
            (.envelopeCatalogSearch, #"{"req_1":{"data":{"body":{"song":{"list":[{"mid":"mid42","name":"Paper Lanterns","singer":[{"name":"North Bay"}],"album":{"mid":"alb42","name":"Evening"},"interval":180}]}}}}}"#, "mid42", "https://fixture.test/covers/alb42.jpg"),
            (.hashCatalogSearch, #"{"data":{"info":[{"hash":"hash42","album_id":9,"songname":"Paper Lanterns","singername":"North Bay","duration":180,"trans_param":{"union_cover":"https://fixture.test/{size}/cover.jpg"}}]}}"#, "hash42|9|Paper Lanterns|North Bay|180|https://fixture.test/150/cover.jpg", "https://fixture.test/150/cover.jpg"),
            (.quotedCatalogSearch, #"{"abslist":[{"MUSICRID":"MUSIC_42","NAME":"Paper Lanterns","ARTIST":"North Bay","ALBUM":"Evening","ALBUMID":"9","DURATION":"180","pic":"https://fixture.test/cover.jpg"}]}"#, "42|Paper Lanterns|North Bay|Evening|9|180|https://fixture.test/cover.jpg", "https://fixture.test/cover.jpg"),
            (.groupedCatalogSearch, #"{"code":"000000","songResultData":{"result":[{"copyrightId":"42","name":"Paper Lanterns","singers":[{"name":"North Bay"}],"albums":[{"id":"9","name":"Evening"}],"imgItems":[{"img":"https://fixture.test/cover.jpg"}]}]}}"#, "42|Paper Lanterns|North Bay|Evening|9|https://fixture.test/cover.jpg|0", "https://fixture.test/cover.jpg")
        ]
        for (format, input, id, cover) in cases {
            let result = try ScraperJSONRule(format: format, artworkBaseURL: "https://fixture.test/covers/").parse(Data(input.utf8), coverURL: { "https://fixture.test/" + $0 }) as? [[String: Any]]
            XCTAssertEqual(result?.first?["id"] as? String, id, "\(format)")
            XCTAssertEqual(result?.first?["title"] as? String, "Paper Lanterns")
            XCTAssertEqual(result?.first?["coverUrl"] as? String, cover)
        }
    }

    func testLyricsKeepWordTimingAndCandidateFallbackData() throws {
        let yrc = Data(#"{"lrc":{"lyric":"[00:01.00]Paper lanterns"},"yrc":{"lyric":"[1000,1000](1000,400,0)Paper (1400,600,0)lanterns"}}"#.utf8)
        let lyrics = try ScraperJSONRule(format: .albumCatalogLyrics).parse(yrc) as? [String: Any]
        XCTAssertEqual(lyrics?["lrcContent"] as? String, "[00:01.00]Paper lanterns")
        XCTAssertEqual(lyrics?["wordLevelLrc"] as? String, "[00:01.00]<00:01.00>Paper <00:01.40>lanterns<00:02.00>")
        let lines = try ScraperJSONRule(format: .quotedCatalogLyrics).parse(Data(#"{"data":{"lrclist":[{"time":"61.25","lineLyric":"Across the bay"}]}}"#.utf8)) as? [String: Any]
        XCTAssertEqual(lines?["lrcContent"] as? String, "[01:01.25]Across the bay")
        let candidates = try ScraperJSONRule(format: .hashCatalogLyrics).parse(Data(#"{"candidates":[{"id":42,"accesskey":"fixture"},{"id":43}]}"#.utf8)) as? [String: Any]
        XCTAssertEqual(candidates?["_fetchEncryptedLyrics"] as? Bool, true)
        XCTAssertEqual(candidates?["vars"] as? [[String: String]], [["lyricId": "42", "accessKey": "fixture"]])
    }

    func testMalformedAndOversizedRulesFailWithoutExecutingAnything() throws {
        XCTAssertThrowsError(try ScraperJSONRule().parse(Data("while(true){}".utf8)))
        XCTAssertThrowsError(try ScraperJSONRule().parse(Data("callback({}); steal()".utf8)))
        XCTAssertThrowsError(try ScraperJSONRule().parse(Data(repeating: 32, count: ScraperJSONRule.maximumBytes + 1)))
        XCTAssertThrowsError(try ScraperJSONRule(path: String(repeating: "a", count: 513)).validate())
        let value = try ScraperJSONRule().parse(Data(#"callback({"title":"Paper Lanterns"});"#.utf8)) as? [String: String]
        XCTAssertEqual(value?["title"], "Paper Lanterns")
        let quoted = Data(#"{'abslist':[{'MUSICRID':'MUSIC_42','NAME':'A \'quoted\' "title"','ARTIST':'North Bay','web_albumpic_short':'120/42/cover.jpg'}]}"#.utf8)
        let rows = try ScraperJSONRule(format: .quotedCatalogSearch, artworkBaseURL: "https://fixture.test/").parse(quoted) as? [[String: Any]]
        XCTAssertEqual(rows?.first?["title"] as? String, "A 'quoted' \"title\"")
        XCTAssertEqual(rows?.first?["coverUrl"] as? String, "https://fixture.test/star/albumcover/120/42/cover.jpg")
        XCTAssertThrowsError(try ScraperJSONRule(format: .quotedCatalogSearch).parse(Data("{'abslist':runCode()}".utf8)))
        XCTAssertThrowsError(try ScraperJSONRule(format: .quotedCatalogSearch).parse(Data("{abslist:[]}".utf8)))
    }

    func testArtworkPlaylistKeepsBoundedRenditionAndRejectsUnsafeLayouts() throws {
        let master = Data("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=2160x2160,CODECS="avc1.640028"
        large.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=960x960,CODECS="avc1.640028"
        square.m3u8
        """.utf8)
        XCTAssertEqual(try ScraperArtworkPlaylist.resolve(master).reference, "square.m3u8")
        let finite = "#EXTM3U\n#EXT-X-MAP:URI=\"cover.mp4\"\n#EXTINF:2.0,\ncover.mp4\n#EXT-X-ENDLIST"
        XCTAssertTrue(try ScraperArtworkPlaylist.resolve(Data(finite.utf8)).complete)
        for invalid in [finite.replacingOccurrences(of: "2.0", with: "61"), finite.replacingOccurrences(of: "2.0", with: "nan"), finite.replacingOccurrences(of: "2.0", with: ""), finite.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""), finite + "\n#EXT-X-KEY:METHOD=AES-128"] {
            XCTAssertThrowsError(try ScraperArtworkPlaylist.resolve(Data(invalid.utf8)))
        }
    }
}
