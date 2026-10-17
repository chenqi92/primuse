import Foundation
import Testing
@testable import PrimuseKit

@Suite("LyricsAPIServerPolicy address")
struct LyricsAPIServerPolicyAddressTests {
    @Test func acceptsPublicHTTP() {
        #expect(LyricsAPIServerPolicy.normalizedAddress("http://lyrics.example.com/api")
            == "http://lyrics.example.com/api")
    }

    @Test func acceptsPortPathAndQueryAndTrims() {
        #expect(LyricsAPIServerPolicy.normalizedAddress("  https://192.168.1.2:28883/lyrics?key=abc \n")
            == "https://192.168.1.2:28883/lyrics?key=abc")
    }

    @Test func rejectsMissingScheme() {
        #expect(LyricsAPIServerPolicy.normalizedAddress("lyrics.example.com/api") == nil)
    }

    @Test func rejectsFTP() {
        #expect(LyricsAPIServerPolicy.normalizedAddress("ftp://lyrics.example.com/api") == nil)
    }

    @Test func rejectsBlank() {
        #expect(LyricsAPIServerPolicy.normalizedAddress("   \n\t ") == nil)
    }
}

@Suite("LyricsAPIServerPolicy requestURL")
struct LyricsAPIServerPolicyRequestURLTests {
    private func items(_ url: URL?) -> [URLQueryItem] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        return components.queryItems ?? []
    }

    @Test func keepsExistingQueryFirst() {
        let url = LyricsAPIServerPolicy.requestURL(
            address: "http://host:8080/lyrics?token=x&mode=lrc",
            title: "Song", artist: "Singer", album: "Album", duration: 200
        )
        let names = items(url).map(\.name)
        #expect(names == ["token", "mode", "title", "artist", "album", "duration"])
        #expect(items(url).first?.value == "x")
        #expect(url?.host == "host")
        #expect(url?.port == 8080)
        #expect(url?.path == "/lyrics")
    }

    @Test func encodesChineseTitle() throws {
        let url = try #require(LyricsAPIServerPolicy.requestURL(
            address: "https://example.com/api",
            title: "晴天", artist: "周杰伦", album: nil, duration: nil
        ))
        #expect(url.absoluteString.contains("title=%E6%99%B4%E5%A4%A9"))
        #expect(items(url).first { $0.name == "title" }?.value == "晴天")
        #expect(items(url).first { $0.name == "artist" }?.value == "周杰伦")
    }

    @Test func encodesPlusSign() throws {
        let url = try #require(LyricsAPIServerPolicy.requestURL(
            address: "https://example.com/api",
            title: "A+B", artist: nil, album: nil, duration: nil
        ))
        #expect(url.absoluteString.contains("title=A%2BB"))
    }

    @Test func omitsBlankArtistAndAlbum() {
        let url = LyricsAPIServerPolicy.requestURL(
            address: "https://example.com/api",
            title: "Song", artist: "  ", album: "", duration: nil
        )
        #expect(items(url).map(\.name) == ["title"])
        let nilURL = LyricsAPIServerPolicy.requestURL(
            address: "https://example.com/api",
            title: "Song", artist: nil, album: nil, duration: nil
        )
        #expect(items(nilURL).map(\.name) == ["title"])
    }

    @Test func omitsInvalidDurations() {
        for duration: TimeInterval? in [0, nil, .nan, .infinity, -3] {
            let url = LyricsAPIServerPolicy.requestURL(
                address: "https://example.com/api",
                title: "Song", artist: nil, album: nil, duration: duration
            )
            #expect(!items(url).contains { $0.name == "duration" })
        }
    }

    @Test func truncatesDurationToWholeSeconds() {
        let url = LyricsAPIServerPolicy.requestURL(
            address: "https://example.com/api",
            title: "Song", artist: nil, album: nil, duration: 120.7
        )
        #expect(items(url).first { $0.name == "duration" }?.value == "120")
    }

    @Test func rejectsInvalidAddress() {
        #expect(LyricsAPIServerPolicy.requestURL(
            address: "example.com", title: "Song", artist: nil, album: nil, duration: nil
        ) == nil)
    }
}

@Suite("LyricsAPIServerPolicy classifyResponse")
struct LyricsAPIServerPolicyClassifyTests {
    private func classify(_ status: Int, _ body: String, contentType: String? = nil) -> LyricsAPIServerPolicy.ResponseClassification {
        LyricsAPIServerPolicy.classifyResponse(statusCode: status, contentType: contentType, body: Data(body.utf8))
    }

    @Test func notFoundStatusCodes() {
        #expect(classify(404, "[00:01.00]x\n[00:02.00]y") == .notFound)
        #expect(classify(204, "") == .notFound)
    }

    @Test func otherStatusCodesFail() {
        #expect(classify(401, "unauthorized") == .failed(statusCode: 401))
        #expect(classify(403, "") == .failed(statusCode: 403))
        #expect(classify(429, "") == .failed(statusCode: 429))
        #expect(classify(500, "") == .failed(statusCode: 500))
    }

    @Test func oversizedBodyIsNotFound() {
        let big = Data(repeating: 0x41, count: LyricsAPIServerPolicy.maximumBodyBytes + 1)
        #expect(LyricsAPIServerPolicy.classifyResponse(statusCode: 200, contentType: "text/plain", body: big) == .notFound)
    }

    @Test func invalidUTF8IsNotFound() {
        let bytes = Data([0xFF, 0xFE, 0xC3, 0x28, 0xA0, 0xA1])
        #expect(LyricsAPIServerPolicy.classifyResponse(statusCode: 200, contentType: nil, body: bytes) == .notFound)
    }

    @Test func emptyBodyIsNotFound() {
        #expect(classify(200, "  \n ") == .notFound)
    }

    @Test func htmlPageIsNotFound() {
        #expect(classify(200, "<!DOCTYPE html><html><body>[00:01.00] nope</body></html>") == .notFound)
        #expect(classify(200, "  <HTML>\n<p>error</p>\n</HTML>") == .notFound)
    }

    @Test func singleLineTextIsNotFound() {
        #expect(classify(200, "Lyrics not found\n") == .notFound)
    }

    @Test func multiLinePlainText() {
        #expect(classify(200, "line one\n\nline two\n") == .lyrics(lrc: nil, plain: "line one\n\nline two"))
    }

    @Test func crlfLRCIsNormalized() {
        #expect(classify(200, "[ti:Song]\r\n[00:01.50]hello\r\n[00:03.00]world\r\n")
            == .lyrics(lrc: "[ti:Song]\n[00:01.50]hello\n[00:03.00]world", plain: nil))
    }

    @Test func singleLineLRCIsLyrics() {
        #expect(classify(200, "[00:01]only line") == .lyrics(lrc: "[00:01]only line", plain: nil))
    }

    @Test func jsonArrayPicksFirstWithLyrics() {
        let body = #"[{"id":"1","title":"A","artist":"B","lyrics":""},{"id":"2","title":"A","artist":"B","lyrics":"[00:01.00]x\n[00:02.00]y"}]"#
        #expect(classify(200, body, contentType: "application/json; charset=utf-8")
            == .lyrics(lrc: "[00:01.00]x\n[00:02.00]y", plain: nil))
    }

    @Test func jsonArrayAcceptsAlternateKeysWithoutContentType() {
        let body = #"[{"id":"1","syncedLyrics":"first\nsecond"}]"#
        #expect(classify(200, body) == .lyrics(lrc: nil, plain: "first\nsecond"))
    }

    @Test func jsonArrayWithoutLyricsIsNotFound() {
        #expect(classify(200, #"[{"id":"1","title":"A"}]"#, contentType: "application/json") == .notFound)
        #expect(classify(200, "[]", contentType: "application/json") == .notFound)
    }

    @Test func jsonObjectLyricsKeys() {
        #expect(classify(200, #"{"lrc":"[01:02.345]hi"}"#) == .lyrics(lrc: "[01:02.345]hi", plain: nil))
    }

    @Test func jsonObjectPlainLyricsOnly() {
        #expect(classify(200, #"{"syncedLyrics":null,"plainLyrics":"a\nb"}"#, contentType: "application/json")
            == .lyrics(lrc: nil, plain: "a\nb"))
    }

    @Test func jsonObjectWithoutLyricsIsNotFound() {
        #expect(classify(200, #"{"code":404,"msg":"not found"}"#) == .notFound)
    }

    // MARK: TTML 与逐字格式

    /// Apple / AMLL 风格：整份 TTML 只有一行。
    private static let singleLineTTML = #"<?xml version="1.0" encoding="utf-8"?><tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div><p begin="00:10.000" end="00:12.000" ttm:agent="v1"><span begin="00:10.000" end="00:11.000">故</span><span begin="00:11.000" end="00:12.000">事</span></p><p begin="00:13.000" end="00:15.000"><span begin="00:13.000" end="00:14.000">的</span><span begin="00:14.000" end="00:15.000">花</span></p></div></body></tt>"#

    private static let yrcDocument = """
    {"t":0,"c":[{"tx":"作词: 某人"}]}
    [190871,1984](190871,361,0)For (191232,172,0)the (191404,376,0)first (191780,1075,0)time
    [193459,1000](193459,412,0)Again
    """

    @Test func singleLineTTMLIsLyricsAndParsesWordTimed() throws {
        let classified = classify(200, Self.singleLineTTML + "\n", contentType: "application/xml")
        #expect(classified == .lyrics(lrc: Self.singleLineTTML, plain: nil))
        guard case .lyrics(let lrc?, _) = classified else { return }
        // 下游按内容认格式：放进 lrc 的 TTML 照样读成逐字歌词。
        let lines = LyricsContentParser.parseText(lrc)
        #expect(lines.map(\.text) == ["故事", "的花"])
        #expect(LyricsTimingLevel(lines: lines) == .word)
    }

    @Test func ttmlWithoutDeclarationOrWithBOMIsLyrics() {
        let bare = String(Self.singleLineTTML.drop { $0 != ">" }.dropFirst())
        #expect(bare.hasPrefix("<tt "))
        #expect(classify(200, bare) == .lyrics(lrc: bare, plain: nil))
        #expect(classify(200, "\u{FEFF}" + Self.singleLineTTML, contentType: "text/plain; charset=utf-8")
            == .lyrics(lrc: Self.singleLineTTML, plain: nil))
    }

    @Test func wordTimedDocumentsAreLyrics() {
        #expect(classify(200, Self.yrcDocument) == .lyrics(lrc: Self.yrcDocument, plain: nil))
        let qrc = #"<?xml version="1.0" encoding="utf-8"?><QrcInfos><LyricInfo LyricCount="1"><Lyric_1 LyricType="1" LyricContent="[0,2000]Hello (0,500)world(500,600)"/></LyricInfo></QrcInfos>"#
        #expect(classify(200, qrc) == .lyrics(lrc: qrc, plain: nil))
        let lys = "[4]Dreaming (5245,696)about (5941,471)the (6412,306)things(6718,458)"
        #expect(classify(200, lys) == .lyrics(lrc: lys, plain: nil))
    }

    @Test func jsonLyricsFieldWithTTMLOrWordTimingIsLRC() throws {
        let ttmlBody = String(
            data: try JSONSerialization.data(withJSONObject: [["id": "1", "lyrics": Self.singleLineTTML]]),
            encoding: .utf8
        ) ?? ""
        #expect(classify(200, ttmlBody, contentType: "application/json")
            == .lyrics(lrc: Self.singleLineTTML, plain: nil))
        let yrcBody = String(
            data: try JSONSerialization.data(withJSONObject: ["lrc": Self.yrcDocument]),
            encoding: .utf8
        ) ?? ""
        #expect(classify(200, yrcBody) == .lyrics(lrc: Self.yrcDocument, plain: nil))
    }

    @Test func htmlPagesStayNotFoundEvenWithTTTags() {
        #expect(classify(200, "<!DOCTYPE html><html><body><tt>monospace</tt></body></html>") == .notFound)
        #expect(classify(200, #"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><tt>x</tt></html>"#)
            == .notFound)
        // 不以 `<` 开头的单行文字仍是「没找到」。
        #expect(classify(200, "No lyrics for <tt>this</tt> song") == .notFound)
    }
}
