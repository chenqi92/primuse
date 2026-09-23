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
}
