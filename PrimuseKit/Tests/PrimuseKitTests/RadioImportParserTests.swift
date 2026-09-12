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
}
