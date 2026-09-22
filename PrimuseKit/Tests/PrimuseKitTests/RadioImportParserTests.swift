import Foundation
import Testing
@testable import PrimuseKit

@Suite("Radio import parser")
struct RadioImportParserTests {

    // MARK: - 纯文本

    @Test("Parses one URL per line and derives a readable name")
    func parsesPlainURLs() {
        let candidates = RadioImportParser.parse("""
        https://ice5.somafm.com/groovesalad-128
        https://ice2.somafm.com/dronezone-128
        """)

        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.isPlayable })
        #expect(candidates[0].name == "Groovesalad 128")
        #expect(candidates[1].name == "Dronezone 128")
    }

    @Test("Accepts a `Name, URL` prefix without eating URLs that contain commas")
    func parsesNamedLines() {
        let candidates = RadioImportParser.parse("""
        Groove Salad, https://ice5.somafm.com/groovesalad-128
        经典老歌 FM | https://example.com/oldies
        https://example.com/path,with,commas
        """)

        #expect(candidates.count == 3)
        #expect(candidates[0].name == "Groove Salad")
        #expect(candidates[1].name == "经典老歌 FM")
        // 整行都是 URL 时不能被逗号劈开
        #expect(candidates[2].urlString.hasSuffix("/path,with,commas"))
    }

    @Test("Blank lines and comments are skipped")
    func skipsCommentsAndBlanks() {
        let candidates = RadioImportParser.parse("""
        # 这是注释
        https://example.com/a

        // 另一种注释
        """)

        #expect(candidates.count == 1)
    }

    // MARK: - 判重

    @Test("Flags URLs already in the library, naming the existing station")
    func flagsDuplicatesAgainstLibrary() {
        let existing = [
            RadioStation(name: "Groove Salad", streamURL: "https://ice5.somafm.com/groovesalad-128")
        ]
        let candidates = RadioImportParser.parse(
            "https://ice5.somafm.com/groovesalad-128",
            existing: existing
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].status == .duplicate)
        #expect(candidates[0].duplicateOfName == "Groove Salad")
    }

    @Test("http and https forms of one stream count as the same station")
    func treatsSchemeVariantsAsDuplicates() {
        let candidates = RadioImportParser.parse("""
        https://example.com/stream
        http://example.com/stream
        """)

        #expect(candidates[0].status == .playable)
        #expect(candidates[1].status == .duplicate)
    }

    @Test("A trailing slash does not create a second copy")
    func ignoresTrailingSlash() {
        let candidates = RadioImportParser.parse("""
        https://example.com/stream
        https://example.com/stream/
        """)

        #expect(candidates[1].status == .duplicate)
    }

    @Test("Different paths on one host stay distinct")
    func keepsDistinctPathsSeparate() {
        let candidates = RadioImportParser.parse("""
        https://example.com/a
        https://example.com/b
        """)

        #expect(candidates.allSatisfy { $0.isPlayable })
    }

    // MARK: - 无效输入

    @Test("Non-http schemes and malformed input are marked invalid, keeping the raw text")
    func flagsInvalidEntries() {
        let candidates = RadioImportParser.parse("""
        rtsp://broken.example/stream
        not a url at all
        """)

        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.status == .invalid })
        // 原文要留着，用户才看得出哪一行写错了
        #expect(candidates[0].urlString == "rtsp://broken.example/stream")
    }

    // MARK: - M3U

    @Test("Reads EXTINF names and pairs them with the following URL")
    func parsesM3U() {
        let candidates = RadioImportParser.parse("""
        #EXTM3U
        #EXTINF:-1,Groove Salad
        https://ice5.somafm.com/groovesalad-128
        #EXTINF:-1,Drone Zone
        https://ice2.somafm.com/dronezone-128
        """)

        #expect(candidates.count == 2)
        #expect(candidates[0].name == "Groove Salad")
        #expect(candidates[1].name == "Drone Zone")
    }

    @Test("EXTINF attributes containing commas do not swallow the name")
    func parsesM3UWithAttributes() {
        let candidates = RadioImportParser.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="a",tvg-name="b",Real Name
        https://example.com/stream
        """)

        #expect(candidates[0].name == "Real Name")
    }

    @Test("A bare URL after an EXTINF-less line still imports")
    func parsesM3UWithoutExtinf() {
        let candidates = RadioImportParser.parse("""
        #EXTM3U
        https://example.com/stream
        """)

        #expect(candidates.count == 1)
        #expect(candidates[0].isPlayable)
    }

    // MARK: - PLS

    @Test("Matches FileN with its TitleN regardless of line order")
    func parsesPLS() {
        let candidates = RadioImportParser.parse("""
        [playlist]
        NumberOfEntries=2
        Title2=Second Station
        File1=https://example.com/one
        Title1=First Station
        File2=https://example.com/two
        """)

        #expect(candidates.count == 2)
        #expect(candidates[0].name == "First Station")
        #expect(candidates[1].name == "Second Station")
    }

    // MARK: - 格式识别

    @Test("Detects the playlist flavour from its content")
    func detectsSource() {
        #expect(RadioImportParser.detectSource("#EXTM3U\nhttps://a.example") == .m3u)
        #expect(RadioImportParser.detectSource("[playlist]\nFile1=https://a.example") == .pls)
        #expect(RadioImportParser.detectSource("https://a.example") == .plainText)
    }

    // MARK: - 清单里的台标

    @Test("EXTINF 的 tvg-logo 会被收下")
    func parsesTvgLogo() {
        let candidates = RadioImportParser.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="a" tvg-logo="https://cdn.x/logo1.png" group-title="Music",Station One
        https://a.com/one
        #EXTINF:-1 tvg-logo=https://cdn.x/logo2.png,Station Two
        https://a.com/two
        #EXTINF:-1,Station Three
        https://a.com/three
        """)

        #expect(candidates.count == 3)
        #expect(candidates[0].name == "Station One")
        #expect(candidates[0].logoURLString == "https://cdn.x/logo1.png")
        #expect(candidates[0].logoSource == .importedManifest)
        // 不带引号的写法同样常见
        #expect(candidates[1].logoURLString == "https://cdn.x/logo2.png")
        #expect(candidates[2].logoURLString == nil)
        #expect(candidates[2].logoSource == nil)
    }

    @Test("独立的 #EXTIMG 行")
    func parsesExtImg() {
        let candidates = RadioImportParser.parse("""
        #EXTM3U
        #EXTINF:-1,Station
        #EXTIMG:https://cdn.x/logo.jpg
        https://a.com/one
        """)
        #expect(candidates[0].logoURLString == "https://cdn.x/logo.jpg")
    }

    @Test("台标不跨条目串味")
    func doesNotLeakLogoToNextEntry() {
        let candidates = RadioImportParser.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-logo="https://cdn.x/one.png",One
        https://a.com/one
        #EXTINF:-1,Two
        https://a.com/two
        """)
        #expect(candidates[0].logoURLString == "https://cdn.x/one.png")
        #expect(candidates[1].logoURLString == nil)
    }

    @Test("坏的 logo 地址被丢掉，条目本身照常可用")
    func dropsInvalidLogo() {
        let candidates = RadioImportParser.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-logo="javascript:alert(1)",One
        https://a.com/one
        """)
        #expect(candidates[0].isPlayable)
        #expect(candidates[0].logoURLString == nil)
    }

    @Test("PLS 的 LogoN")
    func parsesPLSLogo() {
        let candidates = RadioImportParser.parse("""
        [playlist]
        File1=https://a.com/one
        Title1=One
        Logo1=https://cdn.x/one.png
        File2=https://a.com/two
        Title2=Two
        """)
        #expect(candidates.count == 2)
        #expect(candidates[0].logoURLString == "https://cdn.x/one.png")
        #expect(candidates[1].logoURLString == nil)
    }

    @Test("结构化条目和清单共用同一套判重")
    func structuredEntriesShareDeduplication() {
        let candidates = RadioImportParser.candidates(
            from: [
                RadioImportParser.Entry(
                    name: "Groove Salad",
                    urlString: "https://ice1.somafm.com/groovesalad-128-mp3",
                    logoURLString: "https://somafm.com/logo.png",
                    homepageURLString: "https://somafm.com",
                    logoSource: .directoryFavicon
                ),
                RadioImportParser.Entry(
                    name: "Same Stream",
                    urlString: "https://ice1.somafm.com/groovesalad-128-mp3"
                ),
                RadioImportParser.Entry(name: "Bad", urlString: "not a url"),
            ],
            existing: []
        )

        #expect(candidates[0].logoSource == .directoryFavicon)
        #expect(candidates[0].homepageURLString == "https://somafm.com")
        #expect(candidates[1].status == .duplicate)
        #expect(candidates[2].status == .invalid)
    }

    // MARK: - 分组与带逗号的台名(issue #119)

    @Test("group-title becomes the candidate's group")
    func groupTitleIsCaptured() {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="1-Radio#Music" tvg-id="Big B Radio #Apop" tvg-logo="https://cdn.example.test/logog.png?t=158645",Big B Radio #Apop
        https://antares.example.test/proxy/apop?mp=/s
        #EXTINF:-1 group-title="0-Radio#华语",2CR澳洲中文广播电台
        https://streaming.example.test/2cr-chinese-radio
        #EXTINF:-1,Electric Radio
        https://stream-168.example.test/gocfnmkdsmttv
        """
        let candidates = RadioImportParser.parse(text)

        #expect(candidates.count == 3)
        #expect(candidates[0].name == "Big B Radio #Apop")
        #expect(candidates[0].groupTitle == "1-Radio#Music")
        #expect(candidates[0].logoURLString == "https://cdn.example.test/logog.png?t=158645")
        #expect(candidates[1].groupTitle == "0-Radio#华语")
        #expect(candidates[1].name == "2CR澳洲中文广播电台")
        // 没写分组的条目不该继承上一条的分组。
        #expect(candidates[2].groupTitle == nil)
        #expect(candidates.allSatisfy { $0.status == .playable })
    }

    @Test("A comma inside the station name survives")
    func commaInsideStationName() {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="Pop, Rock" tvg-logo="https://e.test/a.png",Radio X, Sydney
        https://e.test/live
        """
        let candidates = RadioImportParser.parse(text)

        #expect(candidates.count == 1)
        #expect(candidates[0].name == "Radio X, Sydney")
        #expect(candidates[0].groupTitle == "Pop, Rock")
        #expect(candidates[0].logoURLString == "https://e.test/a.png")
    }

    @Test("An unbalanced quote still yields a usable name")
    func unbalancedQuote() {
        let text = """
        #EXTM3U
        #EXTINF:-1 tvg-id="broken,Some Station
        https://e.test/live
        """
        let candidates = RadioImportParser.parse(text)

        #expect(candidates.count == 1)
        #expect(candidates[0].name == "Some Station")
    }

    @Test("EXTGRP applies until the next one changes it")
    func extgrpRunsUntilChanged() {
        let text = """
        #EXTM3U
        #EXTGRP:News
        #EXTINF:-1,First
        https://e.test/1
        #EXTINF:-1,Second
        https://e.test/2
        #EXTGRP:Music
        #EXTINF:-1,Third
        https://e.test/3
        #EXTINF:-1 group-title="Jazz",Fourth
        https://e.test/4
        """
        let candidates = RadioImportParser.parse(text)

        #expect(candidates.map(\.groupTitle) == ["News", "News", "Music", "Jazz"])
    }

    @Test("Group names are normalized like folder names")
    func groupNamesAreNormalized() {
        let text = """
        #EXTM3U
        #EXTINF:-1 group-title="  华语   电台  ",A
        https://e.test/1
        #EXTINF:-1 group-title="   ",B
        https://e.test/2
        """
        let candidates = RadioImportParser.parse(text)

        #expect(candidates[0].groupTitle == "华语 电台")
        #expect(candidates[1].groupTitle == nil)
    }

    @Test("A plain music playlist line keeps the whole title")
    func plainExtinfTitle() {
        let text = """
        #EXTM3U
        #EXTINF:184,Artist - Title, Live
        https://e.test/1
        """
        let candidates = RadioImportParser.parse(text)

        #expect(candidates[0].name == "Artist - Title, Live")
    }

    // MARK: - 播放列表包装

    @Test("Only .pls and .m3u links are wrappers; HLS and direct streams are playable as is")
    func playlistWrapperDetection() {
        #expect(RadioImportParser.isPlaylistWrapper("http://yp.shoutcast.com/sbin/tunein-station.pls?id=1477271"))
        #expect(RadioImportParser.isPlaylistWrapper("https://example.com/listen.M3U"))
        #expect(!RadioImportParser.isPlaylistWrapper("https://example.com/live/index.m3u8"))
        #expect(!RadioImportParser.isPlaylistWrapper("http://216.235.84.3:80/2585_128.mp3"))
        #expect(!RadioImportParser.isPlaylistWrapper("http://46.105.100.126:8000/stream"))
    }

    @Test("Cleartext wrappers are tried over https first")
    func wrapperFetchOrder() {
        #expect(RadioImportParser.wrapperFetchURLs("http://yp.shoutcast.com/sbin/tunein-station.pls?id=1") == [
            "https://yp.shoutcast.com/sbin/tunein-station.pls?id=1",
            "http://yp.shoutcast.com/sbin/tunein-station.pls?id=1",
        ])
        #expect(RadioImportParser.wrapperFetchURLs("http://e.test:80/a.pls") == [
            "https://e.test/a.pls",
            "http://e.test:80/a.pls",
        ])
        #expect(RadioImportParser.wrapperFetchURLs("https://e.test/a.pls") == ["https://e.test/a.pls"])
        #expect(RadioImportParser.wrapperFetchURLs("ftp://e.test/a.pls").isEmpty)
    }

    @Test("A SHOUTcast tune-in playlist unwraps to its first stream")
    func unwrapsShoutcastPLS() {
        // yp.shoutcast.com 的真实响应。
        let text = """
        [playlist]
        numberofentries=2
        File1=http://216.235.84.3:80/2585_128.mp3
        Title1=(#1 - 145/10000) SmoothJazz.com Global
        Length1=-1
        File2=http://66.85.89.30:80/2585_128.mp3
        Title2=(#2 - 155/10000) SmoothJazz.com Global
        Length2=-1
        Version=2
        """
        #expect(RadioImportParser.firstStreamURL(inWrapper: text) == "http://216.235.84.3:80/2585_128.mp3")
        #expect(RadioImportParser.firstStreamURL(inWrapper: "#EXTM3U\nhttps://e.test/inner.pls\nhttps://e.test/live") == "https://e.test/live")
        #expect(RadioImportParser.firstStreamURL(inWrapper: "<html>Not found</html>") == nil)
    }

    @Test("Unwrapping falls back from https to the stored cleartext link and reports nothing when both fail")
    func unwrapsWithFallback() async throws {
        let pls = "[playlist]\nFile1=http://46.105.100.126:8000/stream\n"
        let tried = TriedURLs()
        let stream = try await RadioImportParser.unwrappedStreamURL(
            "http://yp.shoutcast.com/sbin/tunein-station.pls?id=1",
            fetch: { url in
                await tried.append(url)
                guard url.hasPrefix("http://") else { throw URLError(.secureConnectionFailed) }
                return pls
            }
        )
        #expect(stream == "http://46.105.100.126:8000/stream")
        #expect(await tried.urls == [
            "https://yp.shoutcast.com/sbin/tunein-station.pls?id=1",
            "http://yp.shoutcast.com/sbin/tunein-station.pls?id=1",
        ])

        let none = try await RadioImportParser.unwrappedStreamURL(
            "https://e.test/a.pls",
            fetch: { _ in "<html>gone</html>" }
        )
        #expect(none == nil)

        await #expect(throws: CancellationError.self) {
            try await RadioImportParser.unwrappedStreamURL(
                "http://e.test/a.pls",
                fetch: { _ in throw CancellationError() }
            )
        }
    }

}

private actor TriedURLs {
    var urls: [String] = []
    func append(_ url: String) { urls.append(url) }
}
