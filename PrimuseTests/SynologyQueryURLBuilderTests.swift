import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class SynologyQueryURLBuilderTests: XCTestCase {
    func testLiteralPlusInFilePathAndSessionIDIsPercentEncoded() throws {
        var components = try XCTUnwrap(
            URLComponents(string: "https://nas.example/webapi/entry.cgi")
        )
        let path = "/music/杨茜 + 小芳 & demo=1.flac"
        let sid = "session+token"
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "_sid", value: sid),
        ]

        let url = try XCTUnwrap(SynologyQueryURLBuilder.url(from: components))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        XCTAssertFalse(url.query?.contains("+") ?? true)

        let decodedItems = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(decodedItems.first(where: { $0.name == "path" })?.value, path)
        XCTAssertEqual(decodedItems.first(where: { $0.name == "_sid" })?.value, sid)
    }

    func testSpacesRemainSpacesInsteadOfFormEncodedPlus() throws {
        let title = "杨茜、江智民、凌澜 _ 弯弯的月亮 + 小芳 + 快乐老家"
        for fileExtension in ["dts", "flac", "wav"] {
            var components = try XCTUnwrap(
                URLComponents(string: "https://nas.example/webapi/entry.cgi")
            )
            components.queryItems = [
                URLQueryItem(
                    name: "path",
                    value: "/music/\(title).\(fileExtension)"
                ),
            ]

            let url = try XCTUnwrap(SynologyQueryURLBuilder.url(from: components))
            XCTAssertTrue(url.absoluteString.contains("%20%2B%20"))
            XCTAssertFalse(url.query?.contains("+") ?? true)
        }
    }
}

final class AudioStationMetadataWritebackTests: XCTestCase {
    func testNativeTagSavePreservesUneditedFieldsLyricsAndCover() async throws {
        let fixture = AudioStationTagHTTPFixture()
        let original = song()
        var updated = original
        updated.title = "歌曲 + A&B = 现场"
        updated.year = nil
        let report = await TagMetadataWritebackCoordinator.write(mode: .serverAPI, connector: source(fixture),
            original: original, updated: updated, coverData: Data([1, 2, 3]))
        XCTAssertFalse(report.hasFailures)
        XCTAssertTrue(report.remoteMutationOccurred)
        XCTAssertEqual(report.unsupportedFields.map(\.field), [.cover])
        let data = await fixture.appliedData
        let writes = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let payload = try XCTUnwrap(writes.first)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(payload["title"] as? String, updated.title)
        XCTAssertEqual(payload["year"] as? String, "0")
        XCTAssertEqual(payload["artist"] as? String, "服务端歌手")
        XCTAssertEqual(payload["album_artist"] as? String, "专辑歌手")
        XCTAssertEqual(payload["composer"] as? String, "作曲")
        XCTAssertEqual(payload["comment"] as? String, "保留注释")
        XCTAssertEqual(payload["genre"] as? String, "Rock; Pop")
        XCTAssertEqual(payload["lyrics"] as? String, "[00:01.00]原歌词")
        XCTAssertEqual(payload["coverType"] as? String, "original_image")
        XCTAssertEqual(payload["coverPath"] as? String, "")
        XCTAssertEqual(payload["codePage"] as? String, "SYNO_NO_CODE_PAGE_CONVERT")
        let before = try XCTUnwrap((payload["audioInfos"] as? [[String: Any]])?.first)
        XCTAssertEqual(before["title"] as? String, "旧标题")
        XCTAssertEqual(before["path"] as? String, AudioStationTagHTTPFixture.path)
        let requests = await fixture.tagRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.query == nil })
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/proxy/webman/3rdparty/AudioStation/tagEditorUI/tag_editor.cgi" })
    }

    func testAllEditableFieldsUseIndependentReadback() async {
        let fixture = AudioStationTagHTTPFixture()
        let original = song()
        var updated = original
        updated.title = "新标题"
        updated.artistName = "新歌手"
        updated.albumTitle = "新专辑"
        updated.genre = "Jazz"
        updated.year = 2026
        updated.trackNumber = 9
        updated.discNumber = 3
        let result = await source(fixture).writeScrapedMetadata(original: original, updated: updated,
            coverData: nil, lyricsLines: nil, lyricsContent: nil)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(Set(result.fieldResults.filter { $0.disposition == .written }.map(\.field)), TagMetadataWritebackField.metadataFields)
        let reads = await fixture.loadCount
        XCTAssertEqual(reads, 2)
    }

    func testDeniedIncompleteOrWrongFileResponsesNeverStartWrite() async {
        for mode in [AudioStationTagHTTPFixture.Mode.noPermission, .missingLyrics, .missingTag, .wrongPath, .readFailure, .unsupportedFormat] {
            let fixture = AudioStationTagHTTPFixture(mode: mode)
            let original = song()
            var updated = original
            updated.title = "新标题"
            let result = await source(fixture).writeScrapedMetadata(original: original, updated: updated,
                coverData: nil, lyricsLines: nil, lyricsContent: nil)
            XCTAssertFalse(result.errors.isEmpty, "\(mode)")
            XCTAssertFalse(result.metadataWritten, "\(mode)")
            let writes = await fixture.applyCount
            XCTAssertEqual(writes, 0, "\(mode)")
        }
    }

    func testFailedPartialOrUncertainWriteIsNotReportedAsSuccessOrReplayed() async {
        for mode in [AudioStationTagHTTPFixture.Mode.writeFailure, .ignoredTitle, .lostReply, .wrongReadback] {
            let fixture = AudioStationTagHTTPFixture(mode: mode)
            let original = song()
            var updated = original
            updated.title = "新标题"
            let result = await source(fixture).writeScrapedMetadata(original: original, updated: updated,
                coverData: nil, lyricsLines: nil, lyricsContent: nil)
            XCTAssertFalse(result.errors.isEmpty, "\(mode)")
            XCTAssertFalse(result.metadataWritten, "\(mode)")
            let writes = await fixture.applyCount
            XCTAssertEqual(writes, 1, "\(mode)")
        }
        let fixture = AudioStationTagHTTPFixture(mode: .ignoredTitle)
        let original = song()
        var updated = original
        updated.title = "新标题"
        updated.artistName = "新歌手"
        let result = await source(fixture).writeScrapedMetadata(original: original, updated: updated,
            coverData: nil, lyricsLines: nil, lyricsContent: nil)
        XCTAssertEqual(result.fieldResults.first { $0.field == .artist }?.disposition, .written)
        if case .failed = result.fieldResults.first(where: { $0.field == .title })?.disposition {} else {
            XCTFail("Ignored title must remain failed while artist succeeds")
        }
    }

    func testCueAndUnsupportedFormatsNeverMakeRemoteRequests() async {
        for path in ["/songs/music_v_123.mp3", "/songs/music_123.wav", "/songs/music_123.flac"] {
            let fixture = AudioStationTagHTTPFixture()
            var original = song()
            original.filePath = path
            if path.hasSuffix(".flac") {
                original.cueSheetPath = "/music/album.cue"
                original.cueStartTime = 30
            }
            var updated = original
            updated.title = "新标题"
            let result = await source(fixture).writeScrapedMetadata(original: original, updated: updated,
                coverData: nil, lyricsLines: nil, lyricsContent: nil)
            XCTAssertFalse(result.metadataWritten)
            XCTAssertFalse(result.unsupported.isEmpty)
            let count = await fixture.requestCount
            XCTAssertEqual(count, 0)
        }
    }

    private func song() -> Song {
        Song(id: "as-tag", title: "旧标题", albumTitle: "本地专辑", artistName: "本地歌手", trackNumber: 1,
            discNumber: 1, fileFormat: .flac, filePath: "/songs/music_123.flac", sourceID: "as-tag", year: 2020)
    }

    private func source(_ fixture: AudioStationTagHTTPFixture) -> SynologyAudioStationSource {
        SynologyAudioStationSource(source: MusicSource(id: "as-tag", name: "NAS", type: .synologyAudioStation,
            host: "nas.example", port: 5001, useSsl: true, username: "editor", basePath: "/proxy"),
            password: "password", deviceName: nil, transport: SynologyAudioStationRequestTransport(
                data: { try await fixture.reply($0) }, download: { _ in throw URLError(.unsupportedURL) }))
    }
}

private actor AudioStationTagHTTPFixture {
    enum Mode { case success, noPermission, missingLyrics, missingTag, wrongPath, readFailure, unsupportedFormat,
        writeFailure, ignoredTitle, lostReply, wrongReadback }
    static let path = "/music/歌手 + A&B/歌曲.flac"
    let mode: Mode
    private var applied: [[String: Any]] = []
    var applyCount: Int { applied.count }
    var appliedData: Data { (try? JSONSerialization.data(withJSONObject: applied)) ?? Data() }
    private(set) var tagRequests: [URLRequest] = []
    private(set) var loadCount = 0
    private(set) var requestCount = 0
    private var tags: [String: Any] = ["path": path, "title": "旧标题", "artist": "服务端歌手", "album": "服务端专辑",
        "album_artist": "专辑歌手", "composer": "作曲", "comment": "保留注释", "genre": "Rock; Pop", "year": 2020, "track": 2, "disc": 1]
    init(mode: Mode = .success) { self.mode = mode }

    func reply(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        let url = try XCTUnwrap(request.url)
        let encoded = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? url.query ?? ""
        let params = Dictionary(uniqueKeysWithValues: encoded.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let key = String(parts[0]).removingPercentEncoding,
                  let value = String(parts[1]).removingPercentEncoding else { return nil }
            return (key, value)
        })
        func json(_ object: [String: Any]) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        if url.path.hasSuffix("query.cgi") {
            let endpoints = ["Auth": "auth.cgi", "Song": "AudioStation/song.cgi", "Info": "AudioStation/info.cgi", "Stream": "AudioStation/stream.cgi"]
            let data = Dictionary(uniqueKeysWithValues: endpoints.map { key, path in
                (key == "Auth" ? "SYNO.API.Auth" : "SYNO.AudioStation.\(key)", ["path": path, "minVersion": 1, "maxVersion": key == "Auth" ? 7 : 6] as [String: Any])
            })
            return try json(["success": true, "data": data])
        }
        if params["api"] == "SYNO.API.Auth" { return try json(["success": true, "data": ["sid": "sid+A&B"]]) }
        XCTAssertEqual(params["_sid"], "sid+A&B")
        switch params["api"] {
        case "SYNO.AudioStation.Info": return try json(["success": true, "data": ["privilege": ["tag_edit": mode != .noPermission]]])
        case "SYNO.AudioStation.Song": return try json(["success": true, "data": ["songs": [["id": "music_123", "path": mode == .unsupportedFormat ? "/music/a.wav" : Self.path]]]])
        default: break
        }
        guard url.path.hasSuffix("tag_editor.cgi") else { throw URLError(.unsupportedURL) }
        tagRequests.append(request)
        if params["action"] == "apply" {
            let payload = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data((params["data"] ?? "").utf8)) as? [[String: Any]])?.first)
            applied.append(payload)
            if mode == .lostReply { throw URLError(.networkConnectionLost) }
            if mode == .writeFailure {
                return try json(["success": true, "files": [tags], "read_fail_count": 0,
                    "write_fail_files": [["path": Self.path, "error_reason": "error_fs_ro"]]])
            }
            for key in ["title", "artist", "album", "album_artist", "composer", "comment", "genre", "year", "track", "disc"] {
                if key == "title" && mode == .ignoredTitle { continue }
                tags[key] = payload[key]
            }
            return try json(["success": true, "files": [tags], "read_fail_count": 0, "write_fail_files": []])
        }
        XCTAssertEqual(params["action"], "load")
        let requested = try JSONSerialization.jsonObject(with: Data((params["audioInfos"] ?? "").utf8)) as? [[String: String]]
        XCTAssertEqual(requested, [["path": Self.path]])
        loadCount += 1
        var file = tags
        if mode == .wrongPath || (mode == .wrongReadback && loadCount > 1) { file["path"] = "/music/someone-else.flac" }
        if mode == .missingTag { file["comment"] = nil }
        var result: [String: Any] = ["success": true, "files": [file], "read_fail_count": mode == .readFailure ? 1 : 0]
        if mode != .missingLyrics { result["lyrics"] = "[00:01.00]原歌词" }
        return try json(result)
    }
}
