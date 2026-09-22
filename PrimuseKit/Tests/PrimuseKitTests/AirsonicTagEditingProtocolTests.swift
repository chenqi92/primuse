import Foundation
import Testing
@testable import PrimuseKit

@Suite("Airsonic native tag editor protocol")
struct AirsonicTagEditingProtocolTests {
    @Test func legacyWireEscapesValuesWithoutChangingParameterOrder() throws {
        let values = AirsonicTagValues(title: "标题\n歌手&=+", artist: "独立歌手", album: "原专辑", genre: "", year: nil, track: 3)
        let body = String(decoding: AirsonicTagEditingProtocol.dwrBody(batch: 1, page: "/music/editTags?id=42", httpSessionID: "web-session", scriptSessionID: "script-session", mediaFileID: 42, values: values), as: UTF8.self)
        let fields = Dictionary(uniqueKeysWithValues: body.split(separator: "\n").map { line in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]), String(pair[1]))
        })
        #expect(fields.count == 16)
        #expect(fields["c0-param0"] == "number:42")
        #expect(fields["c0-param1"] == "string:3")
        #expect(fields["c0-param2"]?.removingPercentEncoding == "string:独立歌手")
        #expect(fields["c0-param4"]?.removingPercentEncoding == "string:标题\n歌手&=+")
        #expect(fields["c0-param5"] == "string:")
        #expect(fields["windowName"] == "")
        #expect(fields["page"]?.removingPercentEncoding == "/music/editTags?id=42")
    }

    @Test func legacyCallbacksMustMatchSessionAndBatchWithoutEvaluatingJavaScript() throws {
        #expect(try AirsonicTagEditingProtocol.dwrScriptSession(#"throw 'allowScriptTagRemoting is false.'; dwr.engine.remote.handleNewScriptSession("session/abc");"#) == "session/abc")
        #expect(try AirsonicTagEditingProtocol.dwrResult(#"dwr.engine.remote.handleCallback("1","0","UPDATED");"#, batch: 1) == "UPDATED")
        for response in [#"dwr.engine.remote.handleCallback("0","0","UPDATED");"#,
                         #"dwr.engine._remoteHandleCallback("1","0","UPDATED");"#,
                         #"dwr.engine.remote.handleException("1","0",{});"#,
                         #"<html>Login</html>"#] {
            #expect(throws: (any Error).self) { try AirsonicTagEditingProtocol.dwrResult(response, batch: 1) }
        }
    }

    @Test func loginAndAdvancedIndexUseTheirActualCSRFMarkup() throws {
        let login = AirsonicTagEditingProtocol.csrf(in: #"<input value='first&amp;second' type='hidden' name='_csrf'/>"#)
        #expect(login?.token == "first&second")
        let index = AirsonicTagEditingProtocol.csrf(in: #"var csrfheaderName = "X-CSRF-TOKEN"; var csrftoken = "after-login";"#)
        #expect(index?.header == "X-CSRF-TOKEN")
        #expect(index?.token == "after-login")
        #expect(AirsonicTagEditingProtocol.csrf(in: #"var csrfheaderName = "X-CSRF-TOKEN\nCookie"; var csrftoken = "secret";"#) == nil)
        let encoded = String(decoding: AirsonicTagEditingProtocol.form(["j_password": "中&=+\n"]), as: UTF8.self)
        #expect(encoded == "j_password=%E4%B8%AD%26%3D%2B%0A")
    }

    @Test func advancedFramesPreserveUnicodeAndExplicitClears() throws {
        let payload = try AirsonicTagValues(title: "歌名", artist: "", album: "", genre: "", year: nil, track: nil).advancedPayload(mediaFileID: 42)
        let json = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        #expect(json["track"] is NSNull)
        #expect(json["year"] is NSNull)
        #expect(json["artist"] as? String == "")
        let frame = AirsonicTagEditingProtocol.stomp("SEND", headers: ["content-length": String(payload.utf8.count)], body: payload)
        let wire = "o\nh\na" + String(decoding: try AirsonicTagEditingProtocol.sockJSBody([frame]), as: UTF8.self) + "\n"
        let frames = try AirsonicTagEditingProtocol.sockJSMessages(wire)
        let decoded = try AirsonicTagEditingProtocol.stompResponse(#require(frames.first))
        #expect(decoded.command == "SEND")
        #expect(decoded.body == payload)
        #expect(throws: (any Error).self) { try AirsonicTagEditingProtocol.sockJSMessages("c[2010,\"Another connection still open\"]\n") }
        #expect(throws: (any Error).self) { try AirsonicTagEditingProtocol.stompResponse("MESSAGE\ncontent-length:1\n\n歌\0") }
    }

    @Test func capabilitiesKeepReadOnlyServersAndEmbeddedLyricsOut() {
        #expect(AudioMetadataWritebackPolicy.capability(sourceType: .airsonic, format: .flac) == .serverAPI)
        for type in [MusicSourceType.subsonic, .navidrome, .gonic] {
            #expect(AudioMetadataWritebackPolicy.capability(sourceType: type, format: .mp3) == .localOnly)
        }
        #expect(!EmbeddedLyricsCopyPolicy.canEmbed(sourceType: .airsonic, format: .mp3, isCueTrack: false, isStreamDescriptor: false))
    }
}
