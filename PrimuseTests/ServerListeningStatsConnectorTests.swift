import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ServerListeningStatsConnectorTests: XCTestCase {
    func testPasswordFavoriteRoundTripUsesAuthenticatedUserAndReadsEveryPage() async throws {
        for kind in [MediaServerSource.Kind.emby, .jellyfin] {
            let paths = LockedValues<String>()
            let mutations = LockedValues<String>()
            let source = MediaServerSource(
                sourceID: "favorite-password-\(UUID().uuidString)",
                kind: kind,
                host: "favorites.invalid",
                port: nil,
                useSsl: true,
                basePath: nil,
                username: "family",
                secret: "test-password",
                authType: .password,
                requestDataLoader: { request in
                    let url = try XCTUnwrap(request.url)
                    let method = request.httpMethod ?? "GET"
                    paths.append(url.path)
                    if url.path == "/Users/AuthenticateByName" {
                        XCTAssertEqual(method, "POST")
                        let body = try XCTUnwrap(request.httpBody)
                        let login = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                        XCTAssertEqual(login["Username"], "family")
                        return try Self.response(request, json: #"{"AccessToken":"family-token","User":{"Id":"family-user"}}"#)
                    }
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "family-token")
                    switch (method, url.path) {
                    case ("POST", "/Users/family-user/FavoriteItems/501"),
                         ("DELETE", "/Users/family-user/FavoriteItems/501"):
                        mutations.append(method)
                        return try Self.response(request, statusCode: 204, json: "")
                    case ("GET", "/Users/family-user/Items"):
                        let query = Dictionary(uniqueKeysWithValues:
                            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                                .map { ($0.name, $0.value ?? "") }
                        )
                        XCTAssertEqual(query["Filters"], "IsFavorite")
                        XCTAssertEqual(query["IncludeItemTypes"], "Audio")
                        XCTAssertEqual(query["Recursive"], "true")
                        let start = try XCTUnwrap(query["StartIndex"].flatMap(Int.init))
                        let limit = try XCTUnwrap(query["Limit"].flatMap(Int.init))
                        var items: [[String: Any]] = (1...250).map { ["Id": String($0)] }
                        if mutations.values.last == "POST" { items.append(["Id": 501]) }
                        let page = Array(items.dropFirst(start).prefix(limit))
                        let data = try JSONSerialization.data(withJSONObject: [
                            "Items": page, "TotalRecordCount": items.count
                        ])
                        return try Self.response(request, json: String(decoding: data, as: UTF8.self))
                    default:
                        throw FixtureError.invalidRequest
                    }
                }
            )

            let liked = try await source.setServerFavorite(itemID: "501", isFavorite: true)
            XCTAssertTrue(liked.isComplete)
            XCTAssertEqual(liked.itemIDs.count, 251)
            XCTAssertTrue(liked.itemIDs.contains("501"))
            let unliked = try await source.setServerFavorite(itemID: "501", isFavorite: false)
            XCTAssertTrue(unliked.isComplete)
            XCTAssertEqual(unliked.itemIDs.count, 250)
            XCTAssertFalse(unliked.itemIDs.contains("501"))
            XCTAssertEqual(mutations.values, ["POST", "DELETE"])
            XCTAssertEqual(paths.values.filter { $0 == "/Users/AuthenticateByName" }.count, 1)
            XCTAssertFalse(paths.values.contains("/Users/Me"))
            XCTAssertFalse(paths.values.contains("/Users"))
            await source.disconnect()
        }
    }

    func testPlaylistSnapshotReadsAllTracksWithoutRequestingSummaryChildCounts() async throws {
        for kind in [MediaServerSource.Kind.emby, .jellyfin] {
            let source = makeMediaSource(kind: kind) { request in
                let url = try XCTUnwrap(request.url)
                let query = Dictionary(uniqueKeysWithValues:
                    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                switch url.path {
                case "/Users/Me":
                    return try Self.response(request, json: #"{"Id":"user-1"}"#)
                case "/Users/user-1/Items":
                    if query["Fields"]?.split(separator: ",").contains("ChildCount") == true {
                        throw URLError(.timedOut)
                    }
                    guard query["IncludeItemTypes"] == "Playlist",
                          query["Recursive"] == "true" else {
                        throw FixtureError.invalidRequest
                    }
                    return try Self.response(request, json: #"""
                    {"Items":[{"Id":"playlist-1","Name":"Playlist","ImageTags":{"Primary":"cover-tag"}}],"TotalRecordCount":1}
                    """#)
                case "/Playlists/playlist-1/Items":
                    guard query["UserId"] == "user-1",
                          query["Limit"] == "200",
                          let start = query["StartIndex"].flatMap(Int.init),
                          start == 0 || start == 200 else {
                        throw FixtureError.invalidRequest
                    }
                    let items = (start..<min(start + 200, 251)).map {
                        ["Id": "track-\($0)", "Name": "Track \($0)"]
                    }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "Items": items,
                        "TotalRecordCount": 251
                    ])
                    return try Self.response(request, json: String(decoding: data, as: UTF8.self))
                default:
                    throw FixtureError.invalidRequest
                }
            }

            let snapshot = try await source.fetchServerPlaylists()
            XCTAssertTrue(snapshot.failedPlaylistIDs.isEmpty)
            XCTAssertEqual(snapshot.playlists.count, 1)
            let playlist = try XCTUnwrap(snapshot.playlists.first)
            XCTAssertEqual(playlist.name, "Playlist")
            XCTAssertEqual(playlist.trackIDs, (0..<251).map { "track-\($0)" })
            XCTAssertEqual(playlist.reportedTrackCount, 251)
            XCTAssertTrue(playlist.coverArtReference?.contains("cover-tag") == true)
            await source.disconnect()
        }
    }

    /// 一条缺名字、Id 写成数字或读不出的记录, 不再让整个账户的歌单同步失败。
    func testIrregularPlaylistEntriesStillSyncAndCannotProveDeletion() async throws {
        for kind in [MediaServerSource.Kind.emby, .jellyfin] {
            let source = makeMediaSource(kind: kind) { request in
                let url = try XCTUnwrap(request.url)
                switch url.path {
                case "/Users/Me":
                    return try Self.response(request, json: #"{"Id":"user-1"}"#)
                case "/Users/user-1/Items":
                    return try Self.response(request, json: #"""
                    {"Items":[{"Id":"playlist-1"},{"Id":42,"Name":"Numbered"},{"Name":"No id"}],"TotalRecordCount":3}
                    """#)
                case "/Playlists/playlist-1/Items":
                    return try Self.response(request, json: #"""
                    {"Items":[{"Id":"track-1"},{"Name":"No id"},{"Id":"track-2","DateCreated":"not a date"}],"TotalRecordCount":3}
                    """#)
                case "/Playlists/42/Items":
                    return try Self.response(request, json: #"{"Items":[{"Id":"track-3"}],"TotalRecordCount":1}"#)
                default:
                    throw FixtureError.invalidRequest
                }
            }

            let snapshot = try await source.fetchServerPlaylists()
            XCTAssertFalse(snapshot.isIndexComplete)
            XCTAssertTrue(snapshot.failedPlaylistIDs.isEmpty)
            XCTAssertEqual(snapshot.playlists.map(\.id), ["playlist-1", "42"])
            XCTAssertEqual(snapshot.playlists.map(\.name), ["playlist-1", "Numbered"])
            XCTAssertEqual(snapshot.playlists.first?.trackIDs, ["track-1", "track-2"])
            XCTAssertEqual(snapshot.playlists.first?.reportedTrackCount, 3)
            await source.disconnect()
        }
    }

    /// 只追加歌单里还没有的歌, 加完按回读的明细确认, 名字和封面一起带回。
    func testAppendToPlaylistAddsOnlyMissingTracksAndConfirmsByReadBack() async throws {
        for kind in [MediaServerSource.Kind.emby, .jellyfin] {
            let tracks = LockedValues<String>()
            tracks.append("track-1")
            let posted = LockedValues<String>()
            let source = makeMediaSource(kind: kind) { request in
                let url = try XCTUnwrap(request.url)
                let query = Dictionary(uniqueKeysWithValues:
                    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                switch (request.httpMethod ?? "GET", url.path) {
                case ("GET", "/Users/Me"):
                    return try Self.response(request, json: #"{"Id":"user-1"}"#)
                case ("GET", "/Users/user-1/Items/playlist-1"):
                    return try Self.response(request, json: #"{"Id":"playlist-1","Name":"Liked","ImageTags":{"Primary":"cover-tag"}}"#)
                case ("GET", "/Playlists/playlist-1/Items"):
                    let items = tracks.values.map { ["Id": $0] }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "Items": items,
                        "TotalRecordCount": items.count
                    ])
                    return try Self.response(request, json: String(decoding: data, as: UTF8.self))
                case ("POST", "/Playlists/playlist-1/Items"):
                    guard query["UserId"] == "user-1", let ids = query["Ids"] else {
                        throw FixtureError.invalidRequest
                    }
                    posted.append(ids)
                    ids.split(separator: ",").forEach { tracks.append(String($0)) }
                    return try Self.response(request, statusCode: 204, json: "")
                default:
                    throw FixtureError.invalidRequest
                }
            }

            let playlist = try await source.appendToServerPlaylist(
                id: "playlist-1",
                itemIDs: ["track-1", "track-2", "track-3", "track-2"]
            )
            XCTAssertEqual(posted.values, ["track-2,track-3"])
            XCTAssertEqual(playlist.trackIDs, ["track-1", "track-2", "track-3"])
            XCTAssertEqual(playlist.name, "Liked")
            XCTAssertTrue(playlist.coverArtReference?.contains("cover-tag") == true)
            await source.disconnect()
        }
    }

    /// Plex 加歌的 uri 带服务器机器 id, 只加还没在歌单里的; 智能歌单直接拒绝, 不发写请求。
    func testPlexAppendToPlaylistUsesServerURIAndRejectsSmartPlaylists() async throws {
        for smart in [false, true] {
            let tracks = LockedValues<String>()
            tracks.append("track-1")
            let uris = LockedValues<String>()
            let source = makeMediaSource(kind: .plex) { request in
                let url = try XCTUnwrap(request.url)
                let query = Dictionary(uniqueKeysWithValues:
                    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                switch (request.httpMethod ?? "GET", url.path) {
                case ("GET", ""), ("GET", "/"):
                    return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
                case ("GET", "/playlists/pl-1"):
                    return try Self.response(request, json: #"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"pl-1","title":"Mix","playlistType":"audio","smart":\#(smart)}]}}"#)
                case ("GET", "/playlists/pl-1/items"):
                    let items = tracks.values.map { ["ratingKey": $0] }
                    let data = try JSONSerialization.data(withJSONObject: [
                        "MediaContainer": ["size": items.count, "totalSize": items.count, "Metadata": items]
                    ])
                    return try Self.response(request, json: String(decoding: data, as: UTF8.self))
                case ("PUT", "/playlists/pl-1/items"):
                    let uri = try XCTUnwrap(query["uri"])
                    uris.append(uri)
                    uri.split(separator: "/").last?.split(separator: ",").forEach { tracks.append(String($0)) }
                    return try Self.response(request, json: #"{"MediaContainer":{"size":0}}"#)
                default:
                    throw FixtureError.invalidRequest
                }
            }

            do {
                let playlist = try await source.appendToServerPlaylist(id: "pl-1", itemIDs: ["track-1", "track-2", "track-3"])
                XCTAssertFalse(smart)
                XCTAssertEqual(uris.values, ["server://machine-1/com.plexapp.plugins.library/library/metadata/track-2,track-3"])
                XCTAssertEqual(playlist.trackIDs, ["track-1", "track-2", "track-3"])
                XCTAssertEqual(playlist.name, "Mix")
            } catch {
                XCTAssertTrue(smart, "Unexpected error: \(error)")
                XCTAssertEqual(error as? ServerPlaylistAppendError, .readOnly)
                XCTAssertTrue(uris.values.isEmpty)
            }
            await source.disconnect()
        }
    }

    /// 服务器拒绝(别人的歌单)报只读; 请求成功但回读里没有刚加的歌报未确认。
    func testAppendToPlaylistReportsRejectionAndUnconfirmedWrites() async throws {
        let cases: [(statusCode: Int, expected: ServerPlaylistAppendError)] = [(403, .readOnly), (204, .notConfirmed)]
        for (statusCode, expected) in cases {
            let source = makeMediaSource(kind: .emby) { request in
                let url = try XCTUnwrap(request.url)
                switch (request.httpMethod ?? "GET", url.path) {
                case ("GET", "/Users/Me"):
                    return try Self.response(request, json: #"{"Id":"user-1"}"#)
                case ("GET", "/Users/user-1/Items/playlist-1"):
                    return try Self.response(request, json: #"{"Id":"playlist-1","Name":"Shared"}"#)
                case ("GET", "/Playlists/playlist-1/Items"):
                    return try Self.response(request, json: #"{"Items":[{"Id":"track-1"}],"TotalRecordCount":1}"#)
                case ("POST", "/Playlists/playlist-1/Items"):
                    return try Self.response(request, statusCode: statusCode, json: "")
                default:
                    throw FixtureError.invalidRequest
                }
            }

            do {
                _ = try await source.appendToServerPlaylist(id: "playlist-1", itemIDs: ["track-2"])
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ServerPlaylistAppendError, expected)
            }
            await source.disconnect()
        }
    }

    /// Emby / Jellyfin 新建空歌单: 查询串带名字、用户、媒体类型, 回来的 Id 再读一次明细。
    func testCreatePlaylistPostsNameAndReadsTheNewPlaylistBack() async throws {
        for kind in [MediaServerSource.Kind.emby, .jellyfin] {
            let posted = LockedValues<String>()
            let source = makeMediaSource(kind: kind) { request in
                let url = try XCTUnwrap(request.url)
                let query = Dictionary(uniqueKeysWithValues:
                    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                        .map { ($0.name, $0.value ?? "") }
                )
                switch (request.httpMethod ?? "GET", url.path) {
                case ("GET", "/Users/Me"):
                    return try Self.response(request, json: #"{"Id":"user-1"}"#)
                case ("POST", "/Playlists"):
                    guard query["UserId"] == "user-1", query["MediaType"] == "Audio", let name = query["Name"] else {
                        throw FixtureError.invalidRequest
                    }
                    posted.append(name)
                    return try Self.response(request, json: #"{"Id":"playlist-9"}"#)
                case ("GET", "/Users/user-1/Items/playlist-9"):
                    return try Self.response(request, json: #"{"Id":"playlist-9","Name":"Road Trip"}"#)
                case ("GET", "/Playlists/playlist-9/Items"):
                    return try Self.response(request, json: #"{"Items":[],"TotalRecordCount":0}"#)
                default:
                    throw FixtureError.invalidRequest
                }
            }

            let playlist = try await source.createServerPlaylist(named: " Road Trip ")
            XCTAssertEqual(posted.values, ["Road Trip"])
            XCTAssertEqual(playlist.id, "playlist-9")
            XCTAssertEqual(playlist.name, "Road Trip")
            XCTAssertTrue(playlist.trackIDs.isEmpty)
            await source.disconnect()
        }
    }

    /// Plex 新建必须带上至少一首歌, 这里不建, 也不发任何请求。
    func testPlexDoesNotCreateEmptyPlaylists() async {
        let requests = LockedValues<String>()
        let source = makeMediaSource(kind: .plex) { request in
            requests.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")")
            throw FixtureError.invalidRequest
        }
        do {
            _ = try await source.createServerPlaylist(named: "Road Trip")
            XCTFail("Plex should not create an empty playlist")
        } catch {
            XCTAssertEqual(error as? ServerPlaylistAppendError, .creationUnsupported)
        }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testCredentialFailureIsNotMisreportedAsUnsupportedCapability() async {
        let connector = CredentialUnavailableSourceConnector(
            sourceID: "stats-credential-failure",
            failure: .failed(-1)
        )

        do {
            _ = try await connector.fetchServerListeningStats()
            XCTFail("Expected credential failure")
        } catch SourceError.credentialUnavailable(_) {
            // Expected: a supported service remains supported while its credential is unavailable.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingRouteIsNotMisreportedAsUnsupportedCapability() async {
        let connector = NoAvailableConnectionSourceConnector(
            sourceID: "stats-missing-route"
        )

        do {
            _ = try await connector.fetchServerListeningStats()
            XCTFail("Expected route failure")
        } catch SourceError.connectionFailed(_) {
            // Expected: route selection remains a recoverable connection failure.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGenericSubsonicReadsAggregateStatisticsFromLegacyAlbumWalk() async throws {
        try await assertSubsonicStatistics(
            sourceType: .subsonic,
            host: "stats-subsonic.invalid",
            serverType: "subsonic",
            openSubsonic: false,
            expectedCatalogPath: "/rest/getAlbumList2.view"
        )
    }

    func testNavidromeReadsAggregateStatisticsFromSearch3() async throws {
        try await assertSubsonicStatistics(
            sourceType: .navidrome,
            host: "stats-navidrome.invalid",
            serverType: "navidrome",
            openSubsonic: false,
            expectedCatalogPath: "/rest/search3.view"
        )
    }

    func testNavidromeNativeHistoryEnablesEventsForExplicitAndGenericSubsonicSources() async throws {
        for type in [MusicSourceType.navidrome, .subsonic] {
            let host = "stats-native-\(type.rawValue).invalid"
            SubsonicStatsURLProtocol.configure(
                host: host, serverType: "navidrome", openSubsonic: true,
                historyAvailable: true
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SubsonicStatsURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let source = SubsonicSource(
                sourceID: host, sourceType: type, host: host, port: nil,
                useSsl: true, basePath: nil, username: "stats-user",
                password: "stats-password", session: session
            )
            let payload = try await source.fetchServerListeningStats()
            XCTAssertTrue(payload.isStructurallyValid)
            XCTAssertEqual(payload.temporalDetail, .events)
            XCTAssertEqual(payload.events.map(\.id), ["1", "2"])
            XCTAssertEqual(payload.events.map(\.title), ["Server Song", "Server Song"])
            XCTAssertEqual(payload.events.map(\.artist), ["Artist", "Artist"])
            XCTAssertEqual(payload.events.first?.playedAt, Date(timeIntervalSince1970: 1787688000))
            XCTAssertEqual(payload.allTimePlayCount, 5)
            XCTAssertTrue(payload.tracks.isEmpty)
            XCTAssertTrue(payload.events.allSatisfy { $0.listenedSeconds == nil })
            let paths = SubsonicStatsURLProtocol.paths(host: host)
            XCTAssertTrue(paths.contains("/api/scrobble"))
            XCTAssertFalse(paths.contains("/rest/scrobble.view"))
        }
    }

    func testNavidromeHTMLLoginPreservesAggregateStatistics() async throws {
        for type in [MusicSourceType.navidrome, .subsonic] {
            let host = "stats-html-login-\(type.rawValue).invalid"
            try await assertSubsonicStatistics(
                sourceType: type,
                host: host,
                serverType: "navidrome",
                openSubsonic: true,
                expectedCatalogPath: "/rest/search3.view",
                nativeLoginReturnsHTML: true
            )
            let paths = SubsonicStatsURLProtocol.paths(host: host)
            XCTAssertTrue(paths.contains("/auth/login"))
            XCTAssertFalse(paths.contains("/api/scrobble"))
        }
    }

    func testAirsonicReadsAggregateStatisticsFromLegacyAlbumWalk() async throws {
        try await assertSubsonicStatistics(
            sourceType: .airsonic,
            host: "stats-airsonic.invalid",
            serverType: "airsonic",
            openSubsonic: false,
            expectedCatalogPath: "/rest/getAlbumList2.view"
        )
    }

    func testGonicReadsAggregateStatisticsFromOpenSubsonicSearch3() async throws {
        try await assertSubsonicStatistics(
            sourceType: .gonic,
            host: "stats-gonic.invalid",
            serverType: "gonic",
            openSubsonic: true,
            expectedCatalogPath: "/rest/search3.view"
        )
    }

    func testJellyfinReadsAccountScopedUserDataCounters() async throws {
        try await assertJellyfinFamilyStatistics(kind: .jellyfin)
    }

    func testEmbyReadsAccountScopedUserDataCounters() async throws {
        try await assertJellyfinFamilyStatistics(kind: .emby)
    }

    func testPlexUsesTimestampedHistoryWithoutInventingDuration() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1","apiVersion":"1.0"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                guard request.value(forHTTPHeaderField: "X-Plex-Container-Start") == "0",
                      request.value(forHTTPHeaderField: "X-Plex-Container-Size") == "200" else {
                    throw FixtureError.invalidRequest
                }
                return try Self.response(request, json: #"{"MediaContainer":{"size":2,"totalSize":2,"offset":0,"Metadata":[{"historyKey":"/status/sessions/history/11","ratingKey":"track-1","title":"One","parentTitle":"Album","grandparentTitle":"Artist","type":"track","viewedAt":1787688000,"accountID":42},{"historyKey":"/status/sessions/history/12","ratingKey":2,"title":"Two","parentTitle":"Album","grandparentTitle":"Artist","type":"track","viewedAt":"1787601600","accountID":"42"}]}}"#)
            case "/library/sections/1/all":
                return try Self.response(request, json: #"{"MediaContainer":{"totalSize":2,"Metadata":[{"ratingKey":"track-1","title":"One","Genre":[{"tag":"Podcast"}]},{"ratingKey":"2","title":"Two"}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .events)
        XCTAssertEqual(payload.durationAvailability, .unavailable)
        XCTAssertEqual(payload.events.map(\.remoteTrackID), ["track-1", "2"])
        XCTAssertTrue(payload.events.allSatisfy { $0.listenedSeconds == nil })
        XCTAssertTrue(payload.tracks.isEmpty)
        XCTAssertEqual(payload.events.first?.content?.genre, "Podcast")
        let music = ServerListeningStatsService.musicPayload(payload, sourceID: "test", classification: .init())
        XCTAssertEqual(music.events.map(\.remoteTrackID), ["2"])
    }

    func testPlexFallsBackToAggregateOnlyWhenHistoryEndpointIsUnavailable() async throws {
        let paths = LockedValues<String>()
        let source = makeMediaSource(kind: .plex) { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                return try Self.response(request, statusCode: 404, json: "{}")
            case "/library/sections/1/all":
                return try Self.response(request, json: #"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"track-1","title":"One","grandparentTitle":"Artist","parentTitle":"Album","viewCount":7,"lastViewedAt":1787688000}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .aggregate)
        XCTAssertEqual(payload.tracks.first?.playCount, 7)
        XCTAssertNotNil(payload.tracks.first?.lastPlayedAt)
        XCTAssertTrue(paths.values.contains("/library/sections/1/all"))
    }

    func testPlexDoesNotFallbackForServerFailure() async throws {
        let paths = LockedValues<String>()
        let source = makeMediaSource(kind: .plex) { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                return try Self.response(request, statusCode: 500, json: "{}")
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected server failure")
        } catch {
            // Expected: a server failure must not trigger aggregate fallback.
        }
        XCTAssertTrue(paths.values.contains("/status/sessions/history/all"))
        XCTAssertFalse(paths.values.contains("/library/sections/1/all"))
    }

    func testPlexRejectsHistoryThatMixesAccounts() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                return try Self.response(request, json: #"{"MediaContainer":{"totalSize":2,"offset":0,"Metadata":[{"historyKey":"h1","ratingKey":"1","title":"One","type":"track","viewedAt":1787688000,"accountID":1},{"historyKey":"h2","ratingKey":"2","title":"Two","type":"track","viewedAt":1787601600,"accountID":2}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected account ambiguity")
        } catch let error as ServerListeningStatsConnectorError {
            XCTAssertEqual(error, .accountAmbiguous)
        }
    }

    func testPlexRetriesMovingHistoryThenFailsWithoutPublishingPartialData() async throws {
        let historyRequests = LockedCounter()
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                historyRequests.increment()
                let start = request.value(forHTTPHeaderField: "X-Plex-Container-Start")
                if start == "0" {
                    return try Self.response(request, json: #"{"MediaContainer":{"totalSize":2,"offset":0,"Metadata":[{"historyKey":"h1","ratingKey":"1","title":"One","type":"track","viewedAt":1787688000,"accountID":1}]}}"#)
                }
                return try Self.response(request, json: #"{"MediaContainer":{"totalSize":3,"offset":1,"Metadata":[{"historyKey":"h2","ratingKey":"2","title":"Two","type":"track","viewedAt":1787601600,"accountID":1}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected moving history to fail")
        } catch let error as ServerListeningStatsConnectorError {
            XCTAssertEqual(error, .historyChangedDuringPagination)
        }
        XCTAssertEqual(historyRequests.value, 4)
    }

    func testConnectorCancellationPropagatesWithoutFallback() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                throw CancellationError()
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be translated into an empty snapshot.
        }
    }

    func testEmbyScanUsesDeclaredLibraryFoldersWithoutChangingPlaybackIdentity() async throws {
        let source = makeMediaSource(kind: .emby) { request in
            switch request.url?.path {
            case "/Users/Me":
                return try Self.response(request, json: #"{"Id":"user-1"}"#)
            case "/Users/user-1/Views":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"library-1","Name":"Music","CollectionType":"music","ChildCount":1}]}"#
                )
            case "/Library/VirtualFolders/Query":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"ItemId":"library-1","Name":"Music","Locations":["/srv/media/music"]}],"TotalRecordCount":1}"#
                )
            case "/Users/user-1/Items":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"track-1","Name":"Track","Album":"Album","AlbumId":"album-1","AlbumArtist":"Artist","AlbumArtists":[{"Name":"Artist","Id":"artist-1"}],"Artists":["Artist"],"Path":"/srv/media/music/Artist/Album/Track.flac","MediaSources":[{"Size":123}],"MediaStreams":[{"Type":"Audio","Codec":"flac"}]}],"TotalRecordCount":1}"#
                )
            default:
                throw FixtureError.invalidRequest
            }
        }

        let stream = try await source.scanSongs(from: "/")
        var songs: [ConnectorScannedSong] = []
        for try await song in stream {
            songs.append(song)
        }

        let scanned = try XCTUnwrap(songs.first)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(scanned.song.filePath, "/items/track-1.flac")
        XCTAssertEqual(
            scanned.providerHierarchyItems.filter(\.isDirectory).compactMap(\.displayName),
            ["Music", "Artist", "Album"]
        )
        XCTAssertFalse(scanned.providerHierarchyItems.contains {
            $0.path.contains("/srv/") || ($0.displayName?.contains("/srv/") == true)
        })
    }

    func testPlexScanUsesNativeSectionArtistAlbumTaxonomy() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(
                    request,
                    json: #"{"MediaContainer":{"machineIdentifier":"machine-1","apiVersion":"1.0"}}"#
                )
            case "/library/sections":
                return try Self.response(
                    request,
                    json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Plex Music","type":"artist","Location":[{"id":1,"path":"/srv/plex/music"}]}]}}"#
                )
            case "/library/sections/1/all":
                return try Self.response(
                    request,
                    json: #"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"track-1","title":"Track","grandparentRatingKey":"artist-1","grandparentTitle":"Catalog Artist","parentRatingKey":"album-1","parentTitle":"Catalog Album","Media":[{"container":"flac","Part":[{"file":"/srv/plex/music/Physical Artist/Physical Album/Track.flac","size":456}]}]}]}}"#
                )
            default:
                throw FixtureError.invalidRequest
            }
        }

        let stream = try await source.scanSongs(from: "/")
        var songs: [ConnectorScannedSong] = []
        for try await song in stream {
            songs.append(song)
        }

        let scanned = try XCTUnwrap(songs.first)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(scanned.song.filePath, "/items/track-1.flac")
        XCTAssertEqual(
            scanned.providerHierarchyItems.filter(\.isDirectory).compactMap(\.displayName),
            ["Plex Music", "Catalog Artist", "Catalog Album"]
        )
        XCTAssertFalse(scanned.providerHierarchyItems.contains {
            $0.path.contains("/srv/") || ($0.displayName?.contains("Physical Artist") == true)
        })
    }

    func testEmbyCatalogAlbumArtistDoesNotInheritTrackArtistIdentity() async throws {
        let source = makeMediaSource(kind: .emby) { request in
            switch request.url?.path {
            case "/Users/Me":
                return try Self.response(request, json: #"{"Id":"user-1"}"#)
            case "/Users/user-1/Views":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"library-1","Name":"Music","CollectionType":"music","ChildCount":2}]}"#
                )
            case "/Library/VirtualFolders/Query":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"ItemId":"library-1","Locations":["/srv/media/music"]}],"TotalRecordCount":1}"#
                )
            case "/Users/user-1/Items":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"track-1","Name":"First","Album":"Compilation","AlbumId":"album-1","AlbumArtist":"Various Artists","AlbumArtists":[{"Name":"Conflicting Catalog Artist"}],"ArtistItems":[{"Name":"Singer One","Id":"artist-1"}],"Artists":["Singer One"],"Path":"/outside/library/First.flac","MediaStreams":[{"Type":"Audio","Codec":"flac"}]},{"Id":"track-2","Name":"Second","Album":"Compilation","AlbumId":"album-1","AlbumArtist":"Various Artists","AlbumArtists":[{"Name":"Conflicting Catalog Artist"}],"ArtistItems":[{"Name":"Singer Two","Id":"artist-2"}],"Artists":["Singer Two"],"Path":"/outside/library/Second.flac","MediaStreams":[{"Type":"Audio","Codec":"flac"}]}],"TotalRecordCount":2}"#
                )
            default:
                throw FixtureError.invalidRequest
            }
        }

        let stream = try await source.scanSongs(from: "/")
        var songs: [ConnectorScannedSong] = []
        for try await song in stream {
            songs.append(song)
        }

        XCTAssertEqual(songs.count, 2)
        let firstDirectories = try XCTUnwrap(songs.first).providerHierarchyItems.filter(\.isDirectory)
        let secondDirectories = try XCTUnwrap(songs.last).providerHierarchyItems.filter(\.isDirectory)
        XCTAssertEqual(firstDirectories.compactMap(\.displayName), ["Music", "Various Artists", "Compilation"])
        XCTAssertEqual(secondDirectories.compactMap(\.displayName), ["Music", "Various Artists", "Compilation"])
        XCTAssertEqual(firstDirectories.map(\.path), secondDirectories.map(\.path))
    }

    private func assertSubsonicStatistics(
        sourceType: MusicSourceType,
        host: String,
        serverType: String,
        openSubsonic: Bool,
        expectedCatalogPath: String,
        nativeLoginReturnsHTML: Bool = false
    ) async throws {
        SubsonicStatsURLProtocol.configure(
            host: host,
            serverType: serverType,
            openSubsonic: openSubsonic,
            nativeLoginReturnsHTML: nativeLoginReturnsHTML
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubsonicStatsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let source = SubsonicSource(
            sourceID: host,
            sourceType: sourceType,
            host: host,
            port: nil,
            useSsl: true,
            basePath: nil,
            username: "stats-user",
            password: "stats-password",
            session: session
        )

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .aggregate)
        XCTAssertEqual(payload.tracks.count, 1)
        XCTAssertEqual(payload.tracks.first?.playCount, 5)
        XCTAssertEqual(payload.tracks.first?.title, "Server Song")
        XCTAssertNotNil(payload.tracks.first?.lastPlayedAt)
        XCTAssertTrue(SubsonicStatsURLProtocol.paths(host: host).contains(expectedCatalogPath))
        if serverType != "navidrome" {
            XCTAssertFalse(SubsonicStatsURLProtocol.paths(host: host).contains("/auth/login"))
        }
    }

    private func assertJellyfinFamilyStatistics(kind: MediaServerSource.Kind) async throws {
        let source = makeMediaSource(kind: kind) { request in
            switch request.url?.path {
            case "/Users/Me":
                return try Self.response(request, json: #"{"Id":"user-1"}"#)
            case "/Users/user-1/Views":
                return try Self.response(request, json: #"{"Items":[{"Id":"library-1","Name":"Music","CollectionType":"music","ChildCount":1}]}"#)
            case "/Users/user-1/Items":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                guard query?.first(where: { $0.name == "EnableUserData" })?.value == "true",
                      query?.first(where: { $0.name == "Fields" })?.value?.contains("UserData") == true else {
                    throw FixtureError.invalidRequest
                }
                return try Self.response(request, json: #"{"Items":[{"Id":"track-1","Name":"Server Song","Album":"Album","AlbumArtist":"Artist","Artists":["Artist"],"UserData":{"PlayCount":4,"LastPlayedDate":"2026-08-25T12:00:00.000Z"}}],"TotalRecordCount":1}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .aggregate)
        XCTAssertEqual(payload.tracks.first?.playCount, 4)
        XCTAssertEqual(payload.tracks.first?.artist, "Artist")
        XCTAssertNotNil(payload.tracks.first?.lastPlayedAt)
        XCTAssertTrue(payload.events.isEmpty)
    }

    private func makeMediaSource(
        kind: MediaServerSource.Kind,
        loader: @escaping MediaServerSource.RequestDataLoader
    ) -> MediaServerSource {
        MediaServerSource(
            sourceID: "stats-\(kind)",
            kind: kind,
            host: "stats-media.invalid",
            port: nil,
            useSsl: true,
            basePath: nil,
            username: "stats-user",
            secret: "stats-token",
            authType: .apiKey,
            requestDataLoader: loader
        )
    }

    nonisolated private static func response(
        _ request: URLRequest,
        statusCode: Int = 200,
        json: String
    ) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(json.utf8), response)
    }
}

private enum FixtureError: Error {
    case invalidRequest
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedValues<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] {
        lock.withLock { storage }
    }

    func append(_ value: Element) {
        lock.withLock { storage.append(value) }
    }
}

private final class SubsonicStatsURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Configuration {
        let serverType: String
        let openSubsonic: Bool
        let historyAvailable: Bool
        let nativeLoginReturnsHTML: Bool
        var paths: [String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configurations: [String: Configuration] = [:]

    static func configure(
        host: String, serverType: String, openSubsonic: Bool,
        historyAvailable: Bool = false, nativeLoginReturnsHTML: Bool = false
    ) {
        lock.withLock {
            configurations[host] = Configuration(
                serverType: serverType,
                openSubsonic: openSubsonic,
                historyAvailable: historyAvailable,
                nativeLoginReturnsHTML: nativeLoginReturnsHTML,
                paths: []
            )
        }
    }

    static func paths(host: String) -> [String] {
        lock.withLock { configurations[host]?.paths ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            fail(.badURL)
            return
        }
        guard let configuration = Self.lock.withLock({ () -> Configuration? in
            guard var configuration = Self.configurations[host] else { return nil }
            configuration.paths.append(url.path)
            Self.configurations[host] = configuration
            return configuration
        }) else {
            fail(.cannotFindHost)
            return
        }

        switch url.path {
        case "/auth/login":
            if configuration.nativeLoginReturnsHTML {
                respond(json: "<html>Sign in</html>", headers: ["Content-Type": "text/html"])
            } else if configuration.historyAvailable {
                respond(json: #"{"id":"user-1","username":"stats-user","token":"fixture-native-token"}"#)
            } else {
                respond(json: "{}", statusCode: 404)
            }
        case "/api/scrobble":
            guard request.value(forHTTPHeaderField: "X-ND-Authorization") == "Bearer fixture-native-token" else {
                fail(.userAuthenticationRequired)
                return
            }
            let first = #"{"id":1,"mediaFileId":"song-1","submissionTime":1787688000}"#
            let second = #"{"id":2,"mediaFileId":"song-1","submissionTime":1787688000}"#
            let isVerification = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "_start" })?.value == "1"
            respond(json: isVerification ? "[\(second)]" : "[\(first),\(second)]", headers: ["X-Total-Count": "2"])
        case "/rest/ping.view":
            respond(json: #"{"subsonic-response":{"status":"ok","type":"\#(configuration.serverType)","openSubsonic":\#(configuration.openSubsonic)}}"#)
        case "/rest/search3.view":
            respond(json: #"{"subsonic-response":{"status":"ok","searchResult3":{"song":[\#(songJSON)]}}}"#)
        case "/rest/getAlbumList2.view":
            respond(json: #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":"album-1","name":"Album"}]}}}"#)
        case "/rest/getAlbum.view":
            respond(json: #"{"subsonic-response":{"status":"ok","album":{"song":[\#(songJSON)]}}}"#)
        default:
            fail(.unsupportedURL)
        }
    }

    override func stopLoading() {}

    private var songJSON: String {
        #"{"id":"song-1","title":"Server Song","artist":"Artist","album":"Album","playCount":5,"played":"2026-08-25T12:00:00.000Z","suffix":"flac","duration":180}"#
    }

    private func respond(json: String, statusCode: Int = 200, headers: [String: String] = [:]) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(headers) { _, value in value }
              ) else {
            fail(.badServerResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
}

final class ServerLibraryFolderHierarchyTests: XCTestCase {
    func testProviderHierarchySelectionPrefersDeepestPlacementDeterministically() {
        let shallow = providerHierarchyFixture(
            root: "root-b",
            folders: ["all"],
            songID: "song"
        )
        let deep = providerHierarchyFixture(
            root: "root-c",
            folders: ["artists", "album"],
            songID: "song"
        )
        let equallyDeepButCanonical = providerHierarchyFixture(
            root: "root-a",
            folders: ["artists", "album"],
            songID: "song"
        )

        XCTAssertTrue(ConnectorProviderHierarchySelectionPolicy.prefers(
            candidate: deep,
            over: shallow
        ))
        XCTAssertTrue(ConnectorProviderHierarchySelectionPolicy.prefers(
            candidate: equallyDeepButCanonical,
            over: deep
        ))
        XCTAssertFalse(ConnectorProviderHierarchySelectionPolicy.prefers(
            candidate: deep,
            over: equallyDeepButCanonical
        ))
    }

    func testDeclaredLibraryRootBuildsRelativeFoldersWithoutExposingServerPath() throws {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "jellyfin:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/media/music/Artist/Album/track.flac",
            declaredLibraryRoots: ["/srv/media/music"],
            fallbackComponents: []
        )
        XCTAssertEqual(location.components.map(\.displayName), ["Artist", "Album"])

        let song = Song(
            id: "song-1",
            title: "Track",
            fileFormat: .flac,
            filePath: "/items/song-1.flac",
            sourceID: "server"
        )
        let scanned = ConnectorScannedSong(
            song: song,
            displayName: "Track.flac",
            titleMetadataInspected: true,
            folderLocation: location
        )
        let directories = scanned.providerHierarchyItems.filter(\.isDirectory)
        let songItem = try XCTUnwrap(scanned.providerHierarchyItems.last)

        XCTAssertEqual(directories.compactMap(\.displayName), ["Music", "Artist", "Album"])
        XCTAssertEqual(songItem.path, song.filePath)
        XCTAssertEqual(songItem.parentPath, directories.last?.path)
        XCTAssertFalse(scanned.providerHierarchyItems.contains {
            $0.path.contains("/srv/") || ($0.displayName?.contains("/srv/") == true)
        })
    }

    func testOpaqueServerPathUsesNativeCatalogHierarchy() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "plex:library:1",
            rootDisplayName: "Music",
            providerFilePath: "/private/mount/Artist/Album/track.flac",
            declaredLibraryRoots: ["/different/root"],
            fallbackComponents: [
                ConnectorLibraryFolderComponent(
                    stableID: "artist:42",
                    displayName: "Server Artist"
                ),
                ConnectorLibraryFolderComponent(
                    stableID: "album:84",
                    displayName: "Server Album"
                ),
            ]
        )

        XCTAssertEqual(location.components.map(\.stableID), ["artist:42", "album:84"])
        XCTAssertEqual(location.components.map(\.displayName), ["Server Artist", "Server Album"])
    }

    func testIdenticalRelativeFoldersFromDifferentDeclaredRootsRemainDistinct() throws {
        let first = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "jellyfin:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/primary/Artist/Album/first.flac",
            declaredLibraryRoots: ["/srv/primary", "/srv/archive"],
            fallbackComponents: []
        )
        let second = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "jellyfin:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/archive/Artist/Album/second.flac",
            declaredLibraryRoots: ["/srv/primary", "/srv/archive"],
            fallbackComponents: []
        )

        XCTAssertEqual(first.components.map(\.displayName), second.components.map(\.displayName))
        XCTAssertNotEqual(first.components.map(\.stableID), second.components.map(\.stableID))

        let firstSong = Song(
            id: "first",
            title: "First",
            fileFormat: .flac,
            filePath: "/items/first.flac",
            sourceID: "server"
        )
        let secondSong = Song(
            id: "second",
            title: "Second",
            fileFormat: .flac,
            filePath: "/items/second.flac",
            sourceID: "server"
        )
        let firstFolders = ConnectorLibraryFolderHierarchy.indexedItems(
            for: firstSong,
            displayName: "First.flac",
            location: first
        ).filter(\.isDirectory)
        let secondFolders = ConnectorLibraryFolderHierarchy.indexedItems(
            for: secondSong,
            displayName: "Second.flac",
            location: second
        ).filter(\.isDirectory)

        XCTAssertEqual(firstFolders.first?.path, secondFolders.first?.path)
        XCTAssertNotEqual(firstFolders.dropFirst().map(\.path), secondFolders.dropFirst().map(\.path))
    }

    func testUnsafeOrCaseMismatchedPOSIXPathsUseCatalogFallback() {
        let fallback = [
            ConnectorLibraryFolderComponent(
                stableID: "artist:catalog",
                displayName: "Catalog Artist"
            ),
        ]
        let caseMismatch = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/Music/Artist/Album/track.flac",
            declaredLibraryRoots: ["/srv/music"],
            fallbackComponents: fallback
        )
        let traversal = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/music/Artist/../private/track.flac",
            declaredLibraryRoots: ["/srv/music"],
            fallbackComponents: fallback
        )
        let encodedTraversal = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/music/Artist/%2e%2e/private/track.flac",
            declaredLibraryRoots: ["/srv/music"],
            fallbackComponents: fallback
        )

        XCTAssertEqual(caseMismatch.components, fallback)
        XCTAssertEqual(traversal.components, fallback)
        XCTAssertEqual(encodedTraversal.components, fallback)
    }

    func testWindowsLibraryRootsMatchCaseInsensitively() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: #"C:\MUSIC\Artist\Album\track.flac"#,
            declaredLibraryRoots: ["c:/music"],
            fallbackComponents: []
        )

        XCTAssertEqual(location.components.map(\.displayName), ["Artist", "Album"])
    }

    func testUNCLibraryRootsMatchCaseInsensitivelyWithoutExposingShare() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: #"\\NAS\Music\Artist\Album\track.flac"#,
            declaredLibraryRoots: [#"\\nas\music"#],
            fallbackComponents: []
        )

        XCTAssertEqual(location.components.map(\.displayName), ["Artist", "Album"])
        XCTAssertFalse(location.components.contains { $0.displayName.contains("NAS") })
    }

    func testProviderDisplayNamesKeepNativePunctuationAndDistinctAccents() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "plex:library:1",
            rootDisplayName: "Music #1",
            providerFilePath: nil,
            fallbackComponents: [
                ConnectorLibraryFolderComponent(
                    stableID: "artist:c-sharp",
                    displayName: "C# / AC/DC"
                ),
                ConnectorLibraryFolderComponent(
                    stableID: "album:question",
                    displayName: "What? Hits"
                ),
            ]
        )

        XCTAssertEqual(location.rootDisplayName, "Music #1")
        XCTAssertEqual(location.components.map(\.displayName), ["C# / AC/DC", "What? Hits"])
        XCTAssertNotEqual(
            ConnectorLibraryFolderHierarchy.stableNameIdentity("Beyoncé"),
            ConnectorLibraryFolderHierarchy.stableNameIdentity("Beyonce")
        )
    }

    func testUPnPCanonicalPlacementPrefersDeepestThenStableIdentity() {
        let shallow = [
            ConnectorLibraryFolderComponent(stableID: "all", displayName: "All Music"),
        ]
        let deep = [
            ConnectorLibraryFolderComponent(stableID: "artists", displayName: "Artists"),
            ConnectorLibraryFolderComponent(stableID: "artist:1", displayName: "Artist"),
            ConnectorLibraryFolderComponent(stableID: "album:1", displayName: "Album"),
        ]
        let sameDepthEarlier = [
            ConnectorLibraryFolderComponent(stableID: "albums", displayName: "Albums"),
        ]

        XCTAssertTrue(UPnPCanonicalFolderPlacementPolicy.prefers(candidate: deep, over: shallow))
        XCTAssertFalse(UPnPCanonicalFolderPlacementPolicy.prefers(candidate: shallow, over: deep))
        XCTAssertTrue(
            UPnPCanonicalFolderPlacementPolicy.prefers(
                candidate: sameDepthEarlier,
                over: shallow
            )
        )
    }

    func testRelativeProviderPathRequiresConnectorOptIn() {
        let fallback = [
            ConnectorLibraryFolderComponent(
                stableID: "artist:server-id",
                displayName: "Catalog Artist"
            ),
        ]
        let rejected = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "subsonic:library",
            rootDisplayName: "Subsonic",
            providerFilePath: "Path Artist/Path Album/track.flac",
            acceptsProviderRelativePath: false,
            fallbackComponents: fallback
        )
        let accepted = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "subsonic:library",
            rootDisplayName: "Subsonic",
            providerFilePath: "Path Artist/Path Album/track.flac",
            acceptsProviderRelativePath: true,
            fallbackComponents: fallback
        )

        XCTAssertEqual(rejected.components.map(\.displayName), ["Catalog Artist"])
        XCTAssertEqual(accepted.components.map(\.displayName), ["Path Artist", "Path Album"])
    }

    func testProviderHierarchyPlacesOpaqueSongInNativeAlbum() throws {
        let song = Song(
            id: "plex-song",
            title: "Track",
            fileFormat: .m4a,
            filePath: "/items/opaque-track-id.m4a",
            sourceID: "plex"
        )
        let scanned = ConnectorScannedSong(
            song: song,
            displayName: "Track.m4a",
            titleMetadataInspected: true,
            folderLocation: ConnectorLibraryFolderHierarchy.location(
                rootStableID: "plex:library:1",
                rootDisplayName: "Plex Music",
                providerFilePath: nil,
                fallbackComponents: [
                    ConnectorLibraryFolderComponent(
                        stableID: "artist:10",
                        displayName: "Artist"
                    ),
                    ConnectorLibraryFolderComponent(
                        stableID: "album:20",
                        displayName: "Album"
                    ),
                ]
            )
        )
        let indexedRoot = try XCTUnwrap(scanned.providerHierarchyItems.first)
        let hierarchy = LibraryFolderProviderHierarchy(
            roots: [
                LibraryFolderProviderRootDescriptor(
                    path: indexedRoot.path,
                    displayName: indexedRoot.displayName
                ),
            ],
            items: scanned.providerHierarchyItems.map {
                LibraryFolderProviderItemDescriptor(
                    path: $0.path,
                    displayName: $0.displayName,
                    parentPath: $0.parentPath,
                    isDirectory: $0.isDirectory
                )
            }
        )
        let source = LibraryFolderSourceDescriptor(
            sourceID: "plex",
            displayName: "Plex",
            scanRoots: [indexedRoot.path],
            pathSemantics: .opaque,
            providerHierarchy: hierarchy
        )
        let index = LibraryFolderIndexBuilder.build(sources: [source], songs: [song])
        let sourceNode = try XCTUnwrap(index.sourceNode(for: "plex"))
        let root = try XCTUnwrap(index.children(of: sourceNode.id).first { $0.kind == .scanRoot })
        let artist = try XCTUnwrap(index.children(of: root.id).first { $0.displayName == "Artist" })
        let album = try XCTUnwrap(index.children(of: artist.id).first { $0.displayName == "Album" })

        XCTAssertEqual(root.displayName, "Plex Music")
        XCTAssertEqual(index.directSongIDs(in: album.id), [song.id])
        XCTAssertFalse(index.children(of: sourceNode.id).contains { $0.kind == .uncategorized })
    }

    private func providerHierarchyFixture(
        root: String,
        folders: [String],
        songID: String
    ) -> [SourceSyncIndexedItem] {
        var items = [
            SourceSyncIndexedItem(
                stableKey: "hierarchy-root:\(root)",
                path: root,
                displayName: root,
                parentPath: nil,
                isDirectory: true,
                size: 0,
                modifiedDate: nil,
                revision: nil
            ),
        ]
        var parent = root
        for (offset, folder) in folders.enumerated() {
            let path = "\(root)/\(offset)-\(folder)"
            items.append(
                SourceSyncIndexedItem(
                    stableKey: "hierarchy-folder:\(path)",
                    path: path,
                    displayName: folder,
                    parentPath: parent,
                    isDirectory: true,
                    size: 0,
                    modifiedDate: nil,
                    revision: nil
                )
            )
            parent = path
        }
        items.append(
            SourceSyncIndexedItem(
                stableKey: "hierarchy-song:\(songID)",
                path: "/items/\(songID)",
                displayName: songID,
                parentPath: parent,
                isDirectory: false,
                songIDs: [songID],
                size: 0,
                modifiedDate: nil,
                revision: nil
            )
        )
        return items
    }
}

/// 内网、外网两个地址的服务器源会套一层线路代理。代理漏声明的能力, 在双地址下就等于
/// 没有: 往服务端歌单加歌会被当成「不支持」, 道理鱼连歌单都不同步。
@MainActor
final class RoutedServerPlaylistForwardingTests: XCTestCase {
    func testDualAddressServerSourcesForwardPlaylistReadsAndAppends() async throws {
        let types: [MusicSourceType] = [
            .navidrome, .jellyfin, .emby, .plex, .songloft, .synologyAudioStation, .fnMusic, .daoliyu,
        ]
        for type in types {
            var source = MusicSource(id: "routed-playlists-\(UUID().uuidString)", name: "Dual", type: type)
            source.connectionConfiguration = SourceConnectionConfiguration(
                localEndpoint: SourceConnectionEndpoint(host: "lan.invalid", port: 4533, useSsl: false),
                publicEndpoint: SourceConnectionEndpoint(host: "public.invalid", port: 443, useSsl: true)
            )
            let fixture = source
            let stub = PlaylistWritingStubConnector(sourceID: source.id)
            let manager = SourceManager(sourcesProvider: { [fixture] }, connectorFactory: { _ in stub })
            let routed = manager.connector(for: source)
            XCTAssertFalse(routed is PlaylistWritingStubConnector, "\(type) should sit behind a route proxy")

            let reader = try XCTUnwrap(routed as? any ServerPlaylistConnector, "\(type) playlist reads")
            let snapshot = try await reader.fetchServerPlaylists()
            XCTAssertEqual(snapshot.playlists.map(\.id), ["pl-1"], "\(type)")

            let appender = try XCTUnwrap(routed as? any ServerPlaylistAppendingConnector, "\(type) playlist appends")
            let appended = try await appender.appendToServerPlaylist(id: "pl-1", itemIDs: ["a", "b"])
            XCTAssertEqual(appended.trackIDs, ["a", "b"], "\(type)")
            let calls = await stub.appendedItemIDs
            XCTAssertEqual(calls, [["a", "b"]], "\(type)")

            // 能新建的几家, 新建同样要穿过代理; 其余的明确报「不支持」, 不发请求。
            if ServerPlaylistWritebackPolicy.supportsCreating(type) {
                let created = try await manager.createServerPlaylist(named: "Road Trip", source: source)
                XCTAssertEqual(created.name, "Road Trip", "\(type)")
                let names = await stub.createdNames
                XCTAssertEqual(names, ["Road Trip"], "\(type)")
            } else {
                do {
                    _ = try await manager.createServerPlaylist(named: "Road Trip", source: source)
                    XCTFail("\(type) should not create playlists")
                } catch {
                    XCTAssertEqual(error as? ServerPlaylistAppendError, .creationUnsupported, "\(type)")
                }
                let names = await stub.createdNames
                XCTAssertTrue(names.isEmpty, "\(type)")
            }
        }
    }
}

/// 把歌单复制到服务器: 先换成服务器上的同一首, 新建同名歌单, 再加歌; 再复制一次认出这个歌单。
@MainActor
final class ServerPlaylistCopyServiceTests: XCTestCase {
    func testPlaylistFromAnotherSourceIsMatchedCreatedAndThenRecognised() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerPlaylistCopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let server = MusicSource(id: "copy-server-\(UUID().uuidString)", name: "Navidrome", type: .navidrome)
        library.addSongs([
            Song(id: "am-1", title: "Yellow (Remastered 2011)", artistName: "Coldplay", duration: 269,
                 fileFormat: .m4a, filePath: "am/1", sourceID: "apple-music"),
            Song(id: "am-2", title: "Fix You", artistName: "Coldplay", duration: 295,
                 fileFormat: .m4a, filePath: "am/2", sourceID: "apple-music"),
            Song(id: "am-3", title: "Nowhere To Be Found", artistName: "Nobody", duration: 200,
                 fileFormat: .m4a, filePath: "am/3", sourceID: "apple-music"),
            Song(id: "srv-1", title: "Yellow", artistName: "Coldplay", duration: 268,
                 fileFormat: .flac, filePath: "/songs/n1.flac", sourceID: server.id),
            Song(id: "srv-2", title: "Fix You", artistName: "Coldplay", duration: 296,
                 fileFormat: .flac, filePath: "/songs/n2.flac", sourceID: server.id),
        ])
        await library.waitForPendingIndex()
        let playlist = library.createPlaylist(name: "Road Trip", songIDs: ["am-1", "am-2", "am-3"])
        let stub = PlaylistWritingStubConnector(sourceID: server.id)
        let manager = SourceManager(sourcesProvider: { [server] }, connectorFactory: { _ in stub })

        let plans = await ServerPlaylistCopyService.plans(for: [playlist.id], target: server, library: library)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.matchedCount, 2)
        XCTAssertEqual(plan.missingCount, 1)
        XCTAssertEqual(plan.songs(includingProbable: false).map(\.id), ["srv-1", "srv-2"])
        XCTAssertEqual(ServerPlaylistCopyService.destination(forName: plan.name, target: server, library: library), .create)

        let result = try await ServerPlaylistCopyService.copy(
            plan,
            named: plan.name,
            to: .create,
            includingProbable: false,
            target: server,
            library: library,
            sourceManager: manager
        )
        XCTAssertEqual(result?.created, true)
        XCTAssertEqual(result?.trackCount, 2)
        let created = await stub.createdNames
        XCTAssertEqual(created, ["Road Trip"])
        let appended = await stub.appendedItemIDs
        XCTAssertEqual(appended, [["n1", "n2"]])

        let mirrorID = ServerPlaylistIdentity.playlistID(sourceID: server.id, serverPlaylistID: "created-1")
        XCTAssertEqual(library.rawSongIDs(forPlaylist: mirrorID), ["srv-1", "srv-2"])
        XCTAssertEqual(
            ServerPlaylistCopyService.destination(forName: "Road Trip", target: server, library: library),
            .append(playlistID: mirrorID)
        )
        // 服务器自己的歌单不再作为来源。
        XCTAssertFalse(ServerPlaylistCopyService.canCopy(playlistID: mirrorID, to: server))
        XCTAssertTrue(ServerPlaylistCopyService.canCopy(playlistID: playlist.id, to: server))
    }
}

/// Subsonic `createPlaylist`: 新式响应直接带新歌单, 老式只回 ok 时到列表里认出新出现的那个。
final class SubsonicPlaylistCreateTests: XCTestCase {
    func testCreateUsesThePlaylistInTheResponse() async throws {
        try await assertCreate(returnsPlaylist: true)
    }

    func testCreateFindsTheNewPlaylistWhenTheResponseIsBare() async throws {
        try await assertCreate(returnsPlaylist: false)
    }

    private func assertCreate(returnsPlaylist: Bool) async throws {
        let host = "create-\(UUID().uuidString.lowercased()).invalid"
        SubsonicPlaylistCreateURLProtocol.configure(host: host, returnsPlaylist: returnsPlaylist)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubsonicPlaylistCreateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let source = SubsonicSource(
            sourceID: host,
            sourceType: .navidrome,
            host: host,
            port: nil,
            useSsl: true,
            basePath: nil,
            username: "qa-user",
            password: "qa-password",
            session: session
        )

        let playlist = try await source.createServerPlaylist(named: " Road Trip ")
        XCTAssertEqual(playlist.id, "7")
        XCTAssertEqual(playlist.name, "Road Trip")
        XCTAssertTrue(playlist.trackIDs.isEmpty)
        XCTAssertEqual(SubsonicPlaylistCreateURLProtocol.createdNames(host: host), ["Road Trip"])
    }
}

private final class SubsonicPlaylistCreateURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        let returnsPlaylist: Bool
        var createdNames: [String] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    static func configure(host: String, returnsPlaylist: Bool) {
        lock.withLock { states[host] = State(returnsPlaylist: returnsPlaylist) }
    }

    static func createdNames(host: String) -> [String] {
        lock.withLock { states[host]?.createdNames ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let state = Self.lock.withLock({ Self.states[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let created = !state.createdNames.isEmpty
        let newPlaylist = #"{"id":"7","name":"Road Trip","songCount":0}"#
        switch url.path {
        case "/rest/ping.view":
            respond(#"{"status":"ok","type":"navidrome","openSubsonic":true}"#)
        case "/rest/getPlaylists.view":
            let old = #"{"id":"1","name":"Old Favourites","songCount":3}"#
            respond(#"{"status":"ok","playlists":{"playlist":[\#(old)\#(created ? "," + newPlaylist : "")]}}"#)
        case "/rest/createPlaylist.view":
            let name = query.first(where: { $0.name == "name" })?.value ?? ""
            Self.lock.withLock { Self.states[host]?.createdNames.append(name) }
            respond(state.returnsPlaylist ? #"{"status":"ok","playlist":\#(newPlaylist)}"# : #"{"status":"ok"}"#)
        case "/rest/getPlaylist.view" where query.first(where: { $0.name == "id" })?.value == "7":
            respond(#"{"status":"ok","playlist":{"id":"7","name":"Road Trip","songCount":0,"entry":[]}}"#)
        case "/auth/login":
            respond("{}", statusCode: 404)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    private func respond(_ body: String, statusCode: Int = 200) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else { return }
        let json = statusCode == 200 && body.hasPrefix(#"{"status""#) ? #"{"subsonic-response":\#(body)}"# : body
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor PlaylistWritingStubConnector: ServerPlaylistConnector, ServerPlaylistCreatingConnector {
    nonisolated let sourceID: String
    private(set) var appendedItemIDs: [[String]] = []
    private(set) var createdNames: [String] = []
    private var names = ["pl-1": "Road"]
    private var tracks: [String: [String]] = [:]

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw URLError(.unsupportedURL) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        throw URLError(.unsupportedURL)
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        ServerPlaylistSnapshot(playlists: names.keys.sorted().map {
            ServerPlaylist(id: $0, name: names[$0] ?? "", trackIDs: tracks[$0] ?? [])
        })
    }

    func appendToServerPlaylist(id: String, itemIDs: [String]) async throws -> ServerPlaylist {
        appendedItemIDs.append(itemIDs)
        var current = tracks[id] ?? []
        current.append(contentsOf: itemIDs.filter { !current.contains($0) })
        tracks[id] = current
        return ServerPlaylist(id: id, name: names[id] ?? "", trackIDs: current)
    }

    func createServerPlaylist(named name: String) async throws -> ServerPlaylist {
        createdNames.append(name)
        let id = "created-\(createdNames.count)"
        names[id] = name
        return ServerPlaylist(id: id, name: name, trackIDs: [])
    }
}

@MainActor
final class AllSourcePlaylistPendingTests: XCTestCase {
    func testNavidromePlaylistPendingLifecycle() async throws { try await subsonic(.navidrome) }
    func testSubsonicPlaylistPendingLifecycle() async throws { try await subsonic(.subsonic) }
    func testAirsonicPlaylistPendingLifecycle() async throws { try await subsonic(.airsonic) }
    func testGonicPlaylistPendingLifecycle() async throws { try await subsonic(.gonic) }
    func testJellyfinPlaylistPendingLifecycle() async throws { try await media(.jellyfin, type: .jellyfin) }
    func testEmbyPlaylistPendingLifecycle() async throws { try await media(.emby, type: .emby) }
    func testPlexPlaylistPendingLifecycle() async throws { try await media(.plex, type: .plex) }

    private func subsonic(_ type: MusicSourceType) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingSubsonicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let connector = SubsonicSource(sourceID: type.rawValue, sourceType: type, host: "pending.invalid",
            port: nil, useSsl: true, basePath: nil, username: "qa", password: "test", session: session)
        let snapshot = try await connector.fetchServerPlaylists()
        let playlist = try XCTUnwrap(snapshot.playlists.first { $0.id == "playlist" })
        XCTAssertTrue(snapshot.failedPlaylistIDs.isEmpty)
        XCTAssertEqual(playlist.tracks[0].artists, ["原唱", "嘉宾"])
        if type == .airsonic || type == .gonic {
            XCTAssertEqual(snapshot.playlists.last?.tracks.first?.title, "晴天")
        }
        try await lifecycle(playlist, type: type)
        await connector.disconnect()
    }

    private func media(_ kind: MediaServerSource.Kind, type: MusicSourceType) async throws {
        let connector = MediaServerSource(sourceID: type.rawValue, kind: kind, host: "pending.invalid",
            port: nil, useSsl: true, basePath: nil, username: "qa", secret: "test", authType: .apiKey,
            requestDataLoader: { request in
                let path = request.url!.path
                let body: String
                switch path {
                case "/Users/Me": body = #"{"Id":"user"}"#
                case "/Users/user/Items":
                    body = #"{"Items":[{"Id":"playlist","Name":"歌单"}],"TotalRecordCount":1}"#
                case "/Playlists/playlist/Items":
                    body = #"{"Items":[{"Id":"missing","Name":"晴天","Artists":["原唱","嘉宾"],"Album":"专辑","RunTimeTicks":1800000000},{"Id":"known","Name":"已入库"},{"Id":"id-only"}],"TotalRecordCount":3}"#
                case "", "/": body = #"{"MediaContainer":{"machineIdentifier":"fixture"}}"#
                case "/playlists":
                    body = #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"playlist","title":"歌单","playlistType":"audio"}]}}"#
                case "/playlists/playlist/items":
                    body = #"{"MediaContainer":{"size":3,"totalSize":3,"Metadata":[{"ratingKey":"missing","title":"晴天","originalTitle":"原唱 / 嘉宾","grandparentTitle":"合集歌手","parentTitle":"专辑","duration":180000},{"ratingKey":"known","title":"已入库"},{"ratingKey":"id-only"}]}}"#
                default: throw URLError(.unsupportedURL)
                }
                return try Self.response(request, body)
            })
        let snapshot = try await connector.fetchServerPlaylists()
        XCTAssertTrue(snapshot.failedPlaylistIDs.isEmpty)
        let playlist = try XCTUnwrap(snapshot.playlists.first)
        XCTAssertEqual(playlist.tracks[0].duration, 180)
        XCTAssertEqual(playlist.tracks[0].album, "专辑")
        XCTAssertEqual(playlist.tracks[0].artists, type == .plex ? ["原唱 / 嘉宾"] : ["原唱", "嘉宾"])
        try await lifecycle(playlist, type: type)
        await connector.disconnect()
    }

    func testSongloftPlaylistPendingLifecycle() async throws {
        let connector = SongloftSource(sourceID: "songloft", host: "pending.invalid", port: nil,
            useSSL: true, basePath: nil, username: "qa", password: "test",
            transport: SongloftRequestTransport(data: { request in
                let body: String
                switch request.url!.path {
                case "/api/v1/auth/login": body = #"{"access_token":"test","refresh_token":"test","expires_in":3600}"#
                case "/api/v1/playlists": body = #"{"playlists":[{"id":3,"name":"歌单","type":"normal","song_count":3}],"total":1,"offset":0,"limit":500}"#
                case "/api/v1/playlists/3/song-ids": body = #"{"ids":[7,1,9],"total":3}"#
                case "/api/v1/songs/7": body = #"{"id":7,"type":"remote","title":"晴天","artist":"原唱","album":"专辑","duration":180}"#
                case "/api/v1/songs/1": body = #"{"id":1,"type":"local","title":"已入库"}"#
                default: return try Self.response(request, "{}", status: 404)
                }
                return try Self.response(request, body)
            }, download: { _ in throw URLError(.unsupportedURL) }))
        let snapshot = try await connector.fetchServerPlaylists()
        try await lifecycle(try XCTUnwrap(snapshot.playlists.first), type: .songloft)
        await connector.disconnect()
    }

    func testDaoLiYuPlaylistPendingLifecycle() async throws {
        let connector = DaoLiYuSource(sourceID: "daoliyu", host: "pending.invalid", port: nil,
            useSSL: true, basePath: nil, username: "qa", password: "test",
            transport: DaoLiYuRequestTransport(data: { request in
                let body: String
                switch request.url!.path {
                case "/api/auth/login": body = #"{"token":"test"}"#
                case "/api/tracks": body = #"{"items":[],"total":0}"#
                case "/api/playlists/web/mine": body = #"[{"id":"playlist","name":"歌单"}]"#
                case "/api/playlists/playlist/track-ids": body = #"{"items":["missing","known","id-only"]}"#
                case "/api/tracks/missing": body = #"{"id":"missing","title":"晴天","artistName":"原唱","albumTitle":"专辑","durationSeconds":180}"#
                case "/api/tracks/known": body = #"{"id":"known","title":"已入库"}"#
                default: return try Self.response(request, "{}", status: 404)
                }
                return try Self.response(request, body)
            }, download: { _ in throw URLError(.unsupportedURL) }))
        let snapshot = try await connector.fetchServerPlaylists()
        try await lifecycle(try XCTUnwrap(snapshot.playlists.first), type: .daoliyu)
        await connector.disconnect()
    }

    func testTingReaderKeepsChaptersAndUsesOnlyChapterIdentity() async throws {
        let connector = TingReaderSource(sourceID: "ting", host: "pending.invalid", port: nil,
            useSSL: true, basePath: nil, username: "qa", password: "test",
            transport: TingReaderRequestTransport(data: { request in
                let body: String
                switch request.url!.path {
                case "/api/auth/login": body = #"{"token":"test"}"#
                case "/api/libraries": body = "[]"
                case "/api/playlists": body = #"[{"id":"playlist","title":"书单","book_ids":["book"]}]"#
                case "/api/books/book/chapters":
                    body = #"[{"id":"missing","book_id":"book","title":"晴天","path":"/book/one.mp3","duration":180},{"id":"known","book_id":"book","title":"已入库","path":"/book/two.mp3","duration":190},{"id":"last","book_id":"book","path":"/book/末章.mp3"}]"#
                default: throw URLError(.unsupportedURL)
                }
                return try Self.response(request, body)
            }, download: { _ in throw URLError(.unsupportedURL) }))
        let snapshot = try await connector.fetchServerPlaylists()
        let playlist = try XCTUnwrap(snapshot.playlists.first)
        XCTAssertEqual(playlist.tracks.last?.title, "末章")
        try await lifecycle(playlist, type: .tingReader)
        let entry = PlaylistPendingEntry(title: "第一章", artists: ["作者"], duration: 180,
                                        origin: MusicSourceType.tingReader.rawValue, externalID: "one", serverSourceID: "ting")
        let otherBook = Song(id: "wrong", title: "第一章", artistName: "作者", duration: 180,
                             fileFormat: .mp3, filePath: "/other/one.mp3", sourceID: "other-book")
        XCTAssertNil(PlaylistEntryMatcher(songs: [otherBook]).matchServerEntry(entry))
        await connector.disconnect()
    }

    func testSynologyPlaylistPendingLifecycle() async throws {
        let summaries = try JSONDecoder().decode([SynologyAudioStationPlaylist].self,
            from: Data(#"[{"id":"playlist_personal_normal/test","name":"歌单"}]"#.utf8))
        let snapshot = try await SynologyAudioStationPlaylistMirrorSnapshot.collect(index: {
            SynologyAudioStationPlaylistIndex(playlists: summaries, unreadableCount: 0)
        }, tracks: { _ in [
            ExternalPlaylistTrack(title: "晴天", artists: ["原唱"], album: "专辑", duration: 180, externalID: "music_missing"),
            ExternalPlaylistTrack(title: "已入库", artists: [], externalID: "music_known"),
            ExternalPlaylistTrack(title: "", artists: [], externalID: "music_id-only"),
        ] })
        try await lifecycle(ServerPlaylist(try XCTUnwrap(snapshot.playlists.first)), type: .synologyAudioStation)
    }

    func testIDOnlySnapshotsPreserveRowsAndResolveWithoutMetadata() async throws {
        try await lifecycle(ServerPlaylist(id: "playlist", name: "ID only",
            trackIDs: ["missing", "known", "id-only"]), type: .fnMusic, expectedTitle: "")
    }

    func testEveryExternalPlatformKeepsAmbiguousTracksPending() {
        let original = Song(id: "original", title: "晴天", albumTitle: "专辑", artistName: "原唱", duration: 180,
                            fileFormat: .flac, filePath: "/original.flac", sourceID: "local")
        let cover = Song(id: "cover", title: "晴天", albumTitle: "专辑", artistName: "翻唱", duration: 180,
                         fileFormat: .flac, filePath: "/cover.flac", sourceID: "local")
        var live = original; live.id = "live"; live.title = "晴天 (Live)"
        var duplicate = original; duplicate.id = "duplicate"; duplicate.sourceID = "other"
        for platform in ExternalPlaylistPlatform.allCases {
            let entry = PlaylistPendingEntry(title: "晴天", artists: ["原唱"], album: "专辑", duration: 180,
                                             origin: platform.rawValue)
            let tracks = [entry.id: entry]
            XCTAssertTrue(MusicLibrary.matchPendingEntries(tracks, against: [cover, live], keyCache: nil).resolved.isEmpty, platform.rawValue)
            XCTAssertTrue(MusicLibrary.matchPendingEntries(tracks, against: [original, duplicate], keyCache: nil).resolved.isEmpty, platform.rawValue)
            XCTAssertEqual(MusicLibrary.matchPendingEntries(tracks, against: [original, cover, live], keyCache: nil).resolved[entry.id], "original", platform.rawValue)
            var incomplete = entry; incomplete.duration = nil
            XCTAssertTrue(MusicLibrary.matchPendingEntries([entry.id: incomplete], against: [original], keyCache: nil).resolved.isEmpty, platform.rawValue)
        }
    }

    func testFilePlaylistKeepsMissingEntriesAndDoesNotPickAmbiguousFilenames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaylistFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs([
            Song(id: "original", title: "晴天", artistName: "原唱", fileFormat: .flac, filePath: "/a/晴天.flac", sourceID: "a"),
            Song(id: "cover", title: "晴天", artistName: "翻唱", fileFormat: .flac, filePath: "/b/晴天.flac", sourceID: "b"),
            Song(id: "only-cover", title: "另一首", artistName: "翻唱", fileFormat: .flac, filePath: "/b/另一首.flac", sourceID: "b"),
            Song(id: "known", title: "已入库", artistName: "原唱", fileFormat: .flac, filePath: "/known.flac", sourceID: "a"),
        ])
        await library.waitForPendingIndex()
        let file = root.appendingPathComponent("list.m3u8")
        try "#EXTM3U\n#EXTINF:180,晴天\n晴天.flac\n#EXTINF:180,原唱 - 已入库\nknown.flac\n#EXTINF:180,原唱 - 另一首\n另一首.flac\n".write(to: file, atomically: true, encoding: .utf8)
        let preview = try PlaylistImporter.parseAndMatch(fileURL: file, library: library)
        XCTAssertEqual(preview.entries.count, 3)
        XCTAssertNil(preview.entries[0].matchedSong)
        XCTAssertEqual(preview.entries[1].matchedSong?.id, "known")
        XCTAssertNil(preview.entries[2].matchedSong)
        let playlist = PlaylistImporter.createPlaylist(from: preview, named: "Imported", keepingMissing: true, library: library)
        XCTAssertEqual(library.pendingEntryCount(forPlaylist: playlist.id), 2)
        XCTAssertEqual(library.entries(forPlaylist: playlist.id).count, 3)
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), ["known"])
        _ = await library.persistNowAndWait()
    }

    private func lifecycle(_ playlist: ServerPlaylist, type: MusicSourceType, expectedTitle: String = "晴天") async throws {
        XCTAssertEqual(playlist.trackIDs.count, 3, type.rawValue)
        guard playlist.trackIDs.count == 3 else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaylistPending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root)
        let source = MusicSource(id: "fixture-\(type.rawValue)", name: type.rawValue, type: type)
        library.addSongs([Song(id: "known", title: "已入库", fileFormat: .flac,
                               filePath: "/tracks/\(playlist.trackIDs[1]).flac", sourceID: source.id)])
        await library.waitForPendingIndex()
        let id = ServerPlaylistIdentity.playlistID(sourceID: source.id, serverPlaylistID: playlist.id)
        ServerPlaylistMirror.ProgressiveApplier(source: source, library: library).apply(playlist)
        let members = library.rawSongIDs(forPlaylist: id)
        XCTAssertEqual(members.count, 3, type.rawValue)
        XCTAssertEqual(members[1], "known")
        XCTAssertEqual(library.pendingEntryCount(forPlaylist: id), 2)
        XCTAssertEqual(library.pendingEntry(id: members[0])?.title, expectedTitle)
        XCTAssertEqual(library.songs(forPlaylist: id).map(\.id), ["known"])
        _ = ServerPlaylistMirror.apply(snapshot: ServerPlaylistSnapshot(playlists: [playlist]), source: source, library: library)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: id), members)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("persist") }
        library.reloadFromDisk(preferExternalSnapshot: false)
        XCTAssertEqual(library.entries(forPlaylist: id).map(\.id), members)
        library.addSongs([0, 2].map { index in
            Song(id: "added-\(index)", title: "Changed tags", fileFormat: .flac,
                 filePath: "/tracks/\(playlist.trackIDs[index]).flac", sourceID: source.id)
        }, affectedSourceIDs: [source.id], notifyRemovals: false, pruneMissingSongs: false)
        await library.waitForPendingIndex()
        for _ in 0..<140 {
            if library.pendingEntryCount(forPlaylist: id) == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.songs(forPlaylist: id).map(\.id), ["added-0", "known", "added-2"], type.rawValue)
        XCTAssertEqual(library.pendingEntryCount(forPlaylist: id), 0, type.rawValue)
        _ = await library.persistNowAndWait()
    }

    nonisolated private static func response(_ request: URLRequest, _ body: String, status: Int = 200) throws -> (Data, URLResponse) {
        (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
    }
}

private final class PendingSubsonicURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url!.path {
        case "/rest/ping.view": body = #"{"status":"ok"}"#
        case "/rest/getPlaylists.view": body = #"{"status":"ok","playlists":{"playlist":[{"id":"playlist","name":"歌单","songCount":3}]}}"#
        case "/rest/getPlaylist.view": body = #"{"status":"ok","playlist":{"id":"playlist","name":"歌单","entry":[{"id":"missing","title":"晴天","artists":[{"name":"原唱"},{"name":"嘉宾"}],"album":"专辑","duration":"180"},{"id":"known","title":"已入库"},{"id":"id-only","title":null}]}}"#
        case "/rest/getStarred2.view": body = #"{"status":"ok","starred2":{"song":[{"id":"missing","title":"晴天","artist":"原唱","duration":180}]}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let data = Data("{\"subsonic-response\":\(body)}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
