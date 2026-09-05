import XCTest
@testable import PrimuseKit

final class SettingsSearchIndexTests: XCTestCase {
    private let index = SettingsSearchIndex(documents: [
        .init(id: "page.lyrics", title: "歌词", path: "设置", isPage: true),
        .init(id: "translation", title: "歌词翻译", path: "歌词 › 翻译"),
        .init(id: "lockScreen", title: "锁屏歌词", path: "歌词 › 锁屏", keywords: ["锁屏没歌词", "Lock Screen Lyrics"]),
        .init(id: "cache", title: "音频缓存", path: "下载与存储", keywords: ["cache", "offline download"]),
        .init(id: "wifi", title: "仅使用 Wi-Fi", path: "网络", keywords: ["省流量", "cellular"]),
        .init(id: "eq", title: "Égaliseur", path: "Audio", keywords: ["EQ"])
    ])

    func testExactFeatureRanksAboveBroaderMatches() {
        XCTAssertEqual(index.search("锁屏歌词").first, "lockScreen")
        XCTAssertEqual(index.search("歌词").first, "page.lyrics")
        XCTAssertEqual(Set(index.search("歌词")), ["page.lyrics", "translation", "lockScreen"])
    }

    func testPlainLanguageAndEnglishAliasesFindSameFeature() {
        XCTAssertEqual(index.search("锁屏没歌词"), ["lockScreen"])
        XCTAssertEqual(index.search("lock screen lyrics"), ["lockScreen"])
        XCTAssertEqual(index.search("省流量"), ["wifi"])
        XCTAssertEqual(index.search("offline download"), ["cache"])
    }

    func testTraditionalChinesePinyinAccentsAndWidth() {
        XCTAssertEqual(index.search("鎖屏歌詞"), ["lockScreen"])
        XCTAssertEqual(index.search("suopinggeci"), ["lockScreen"])
        XCTAssertEqual(index.search("ＥＱ"), ["eq"])
        XCTAssertEqual(index.search("egaliseur"), ["eq"])
        XCTAssertEqual(index.search("WiFi"), ["wifi"])
    }

    func testSeparateWordsMatchAcrossTitleAndPath() {
        XCTAssertEqual(index.search("下载 缓存"), ["cache"])
        XCTAssertTrue(index.search("缓存 登录").isEmpty)
    }

    func testBlankPunctuationAndUnknownQueriesDoNotReturnEverything() {
        for query in ["", "  \n", "… --", "a-setting-that-does-not-exist"] {
            XCTAssertTrue(index.search(query).isEmpty, query)
        }
    }

    func testRecentItemsAreBoundedUniqueAndDropUnavailableFeatures() {
        let ids: Set<String> = ["a", "b", "c", "d", "e", "f"]
        XCTAssertEqual(SettingsRecentItems.recording("c", in: ["a", "b", "a", "gone", "c", "d", "e", "f"], availableIDs: ids),
                       ["c", "a", "b", "d", "e"])
        XCTAssertEqual(SettingsRecentItems.recording("gone", in: ["a", "a", "gone", "b"], availableIDs: ids), ["a", "b"])
    }
}
