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

/// 群晖歌单加歌:镜像 id 是服务端 id 的摘要,要先从歌单列表里找回服务端 id。
final class AudioStationPlaylistAppendTests: XCTestCase {
    func testMirrorRetainsUnindexedTracksAndMetadata() async throws {
        let fixture = AudioStationPlaylistHTTPFixture(includeUnindexed: true)
        let connector = source(fixture)
        let snapshot = try await connector.fetchServerPlaylists()
        let playlist = try XCTUnwrap(snapshot.playlists.first)
        XCTAssertEqual(playlist.trackIDs, ["music_1", "music_/volume1/music/missing.flac"])
        XCTAssertEqual(playlist.tracks.last?.title, "未索引歌曲")
        XCTAssertEqual(playlist.tracks.last?.artists, ["原唱"])
        XCTAssertEqual(playlist.tracks.last?.duration, 180)
        await connector.disconnect()
    }

    func testAppendFindsServerPlaylistByMirrorIDAndConfirmsByReadBack() async throws {
        let fixture = AudioStationPlaylistHTTPFixture()
        let mirrorID = SynologyAudioStationPlaylistMirrorSnapshot.mirrorID(for: AudioStationPlaylistHTTPFixture.normalID)

        let playlist = try await source(fixture).appendToServerPlaylist(
            id: mirrorID,
            itemIDs: ["music_2", "music_3", "music_2", "music_/volume1/music/a.flac"]
        )
        let updates = await fixture.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?["id"], AudioStationPlaylistHTTPFixture.normalID)
        XCTAssertEqual(updates.first?["songs"], "music_2,music_3")
        XCTAssertEqual(updates.first?["offset"], "-1")
        XCTAssertEqual(updates.first?["limit"], "0")
        XCTAssertEqual(playlist.id, mirrorID)
        XCTAssertEqual(playlist.name, "开车")
        XCTAssertEqual(playlist.trackIDs, ["music_1", "music_2", "music_3"])
    }

    func testSmartPlaylistIsRejectedWithoutWriting() async throws {
        let fixture = AudioStationPlaylistHTTPFixture()
        let mirrorID = SynologyAudioStationPlaylistMirrorSnapshot.mirrorID(for: AudioStationPlaylistHTTPFixture.smartID)

        do {
            _ = try await source(fixture).appendToServerPlaylist(id: mirrorID, itemIDs: ["music_2"])
            XCTFail("Expected read-only rejection")
        } catch {
            XCTAssertEqual(error as? ServerPlaylistAppendError, .readOnly)
        }
        let updates = await fixture.updates
        XCTAssertTrue(updates.isEmpty)
    }

    /// 新建个人歌单, 返回的 id 是摘要, 和同步、加歌时用的同一套。
    func testCreateMakesAPersonalPlaylistAndReturnsItsMirrorID() async throws {
        let fixture = AudioStationPlaylistHTTPFixture()

        let playlist = try await source(fixture).createServerPlaylist(named: " 健身 ")
        let creates = await fixture.creates
        XCTAssertEqual(creates.count, 1)
        XCTAssertEqual(creates.first?["library"], "personal")
        XCTAssertEqual(creates.first?["name"], "健身")
        XCTAssertEqual(playlist.id, SynologyAudioStationPlaylistMirrorSnapshot.mirrorID(for: "playlist_personal_normal/健身"))
        XCTAssertEqual(playlist.name, "健身")
        XCTAssertTrue(playlist.trackIDs.isEmpty)
    }

    private func source(_ fixture: AudioStationPlaylistHTTPFixture) -> SynologyAudioStationSource {
        SynologyAudioStationSource(source: MusicSource(id: "as-playlist", name: "NAS", type: .synologyAudioStation,
            host: "nas.example", port: 5001, useSsl: true, username: "listener", basePath: nil),
            password: "password", deviceName: nil, transport: SynologyAudioStationRequestTransport(
                data: { try await fixture.reply($0) }, download: { _ in throw URLError(.unsupportedURL) }))
    }
}

private actor AudioStationPlaylistHTTPFixture {
    static let normalID = "playlist_personal_normal/开车"
    static let smartID = "playlist_personal_smart/智能"
    private(set) var updates: [[String: String]] = []
    private(set) var creates: [[String: String]] = []
    private var songs = ["music_1"]
    private let includeUnindexed: Bool
    init(includeUnindexed: Bool = false) { self.includeUnindexed = includeUnindexed }

    func reply(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let encoded = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? url.query ?? ""
        let params = Dictionary(encoded.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let key = String(parts[0]).removingPercentEncoding,
                  let value = String(parts[1]).removingPercentEncoding else { return nil }
            return (key, value)
        }, uniquingKeysWith: { _, last in last })
        func json(_ object: [String: Any]) throws -> (Data, URLResponse) {
            (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        if url.path.hasSuffix("query.cgi") {
            return try json(["success": true, "data": [
                "SYNO.API.Auth": ["path": "auth.cgi", "minVersion": 1, "maxVersion": 7],
                "SYNO.AudioStation.Info": ["path": "AudioStation/info.cgi", "minVersion": 1, "maxVersion": 6],
                "SYNO.AudioStation.Playlist": ["path": "AudioStation/playlist.cgi", "minVersion": 1, "maxVersion": 3],
                // Song 与 Stream 是套件必备的接口,缺了会被当成 Audio Station 没装。
                "SYNO.AudioStation.Song": ["path": "AudioStation/song.cgi", "minVersion": 1, "maxVersion": 3],
                "SYNO.AudioStation.Stream": ["path": "AudioStation/stream.cgi", "minVersion": 1, "maxVersion": 2],
            ]])
        }
        switch params["api"] {
        case "SYNO.API.Auth": return try json(["success": true, "data": ["sid": "sid-1"]])
        case "SYNO.AudioStation.Info": return try json(["success": true, "data": ["privilege": [String: Bool]()]])
        case "SYNO.AudioStation.Playlist": break
        default: throw URLError(.unsupportedURL)
        }
        switch params["method"] {
        case "list":
            return try json(["success": true, "data": ["offset": 0, "total": 2, "playlists": [
                ["id": Self.normalID, "library": "personal", "name": "开车", "type": "normal"],
                ["id": Self.smartID, "library": "personal", "name": "智能", "type": "smart"],
            ]]])
        case "getinfo":
            let id = params["id"] ?? ""
            var entries: [[String: Any]] = songs.map { ["id": $0, "path": "/music/\($0).flac", "title": $0] }
            if includeUnindexed {
                entries.append(["id": "music_/volume1/music/missing.flac", "title": "未索引歌曲",
                    "additional": ["song_tag": ["artist": "原唱"], "song_audio": ["duration": 180]]])
            }
            return try json(["success": true, "data": ["playlists": [[
                "id": id, "library": "personal", "name": "n", "type": "normal",
                "additional": ["songs": entries, "songs_offset": 0, "songs_total": entries.count],
            ]]]])
        case "create":
            creates.append(params)
            return try json(["success": true, "data": ["id": "playlist_personal_normal/\(params["name"] ?? "")"]])
        case "updatesongs":
            updates.append(params)
            for song in (params["songs"] ?? "").split(separator: ",").map(String.init) where !songs.contains(song) {
                songs.append(song)
            }
            return try json(["success": true])
        default:
            throw URLError(.unsupportedURL)
        }
    }
}
