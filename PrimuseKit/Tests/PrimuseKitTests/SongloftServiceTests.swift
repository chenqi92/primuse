import Foundation
import Testing
@testable import PrimuseKit

@Suite("Songloft")
struct SongloftServiceTests {
    @Test func sourceCapabilitiesAndIdentity() throws {
        let type = MusicSourceType.songloft
        #expect(type.displayName == "Songloft")
        #expect(type.category == .mediaServer)
        #expect(type.defaultPort == 58091)
        #expect(type.isServerLibrary && type.scansEntireLibrary && type.supportsRangeStreaming)
        #expect(type.supportsAdaptiveConnections && type.supportsEndpointSpecificPath)
        #expect(!type.isSubsonicFamily && !type.supportsFileDeletion && !type.supportsSidecarWriting)
        #expect(!type.supportsEmbeddedMetadataBackfill)
        #expect(ServerFavoriteWritebackPolicy.supports(type))
        #expect(LyricsAuthoritativeSourcePolicy.supportsServerDocument(type))
        let base = try #require(SongloftAPIProtocol.serverBaseURL(host: "music.example", port: 8080, useSSL: true, basePath: "/my music/api/v1/"))
        let url = try #require(SongloftAPIProtocol.endpoint(baseURL: base, path: "/songs", query: [URLQueryItem(name: "keyword", value: "a+b&c")]))
        #expect(url.path == "/my music/api/v1/songs")
        #expect(url.absoluteString.contains("a%2Bb%26c"))
        #expect(SongloftAPIProtocol.serverBaseURL(host: "https://user:secret@host", port: nil, useSSL: true, basePath: nil) == nil)
        #expect(SongloftAPIProtocol.serverBaseURL(host: "ftp://host", port: nil, useSSL: false, basePath: nil) == nil)
    }

    @Test(arguments: ["/songs/1.mp3", "/songloft/songs/../1.mp3", "/songloft/songs/0.mp3", "/songloft/songs/-1.mp3", "/songloft/songs/1.mp3?access_token=x", "/songloft/songs/1/2.mp3"])
    func rejectInvalidTrackReferences(path: String) {
        #expect(SongloftAPIProtocol.trackID(from: path) == nil)
        #expect(ServerFavoriteWritebackPolicy.songID(fromConnectorPath: path, sourceType: .songloft) == nil)
    }

    @Test func mapMetadataWithoutCredentialsOrSharedCuePaths() throws {
        let track = try decodeTrack(#"{"id":42,"type":"local","title":"曲目","artist":"艺人","album":"专辑","duration":3.75,"format":"ape","file_path":"/private/music/album.ape","file_size":1234,"track":"3/12","cue_source_path":"/private/music/album.cue","cue_track_index":3,"cover_url":"https://unrelated.example/art?access_token=SECRET","updated_at":"2026-09-06T00:00:00Z"}"#)
        let song = try #require(track.makeSong(sourceID: "account-a"))
        #expect(song.duration == 3.75 && song.trackNumber == 3)
        #expect(song.fileFormat == .flac && song.fileSize == 0)
        #expect(song.filePath == "/songloft/songs/42.flac")
        #expect(song.coverArtFileName?.contains("SECRET") == false)
        #expect(song.coverArtFileName?.contains("unrelated") == false)
        #expect(song.id != track.makeSong(sourceID: "account-b")?.id)
        let moved = try decodeTrack(#"{"id":42,"type":"local","title":"新标题","format":"mp3","file_path":"/other/file.mp3"}"#)
        #expect(moved.makeSong(sourceID: "account-a")?.id == song.id)
        #expect(ServerFavoriteWritebackPolicy.songID(fromConnectorPath: song.filePath, sourceType: .songloft) == "42")
    }

    @Test func radioAndVideoAreNotDownloadableLibrarySongs() throws {
        for body in [#"{"id":1,"type":"radio","format":"mp3","url":"/api/v1/songs/1/play.m3u8"}"#,
                     #"{"id":2,"type":"local","format":"mp3","is_video":true}"#] {
            #expect(try decodeTrack(body).makeSong(sourceID: "a") == nil)
        }
    }

    @Test func paginationAcceptsEmptyAndExactFinalPage() throws {
        var empty = SongloftCatalogPagination()
        let emptyOutcome = try empty.accept(decodePage(#"{"songs":null,"total":0,"offset":0,"limit":2}"#), requestedLimit: 2)
        #expect(emptyOutcome.finished)
        #expect(!empty.driftObserved)
        var pagination = SongloftCatalogPagination()
        let first = try pagination.accept(decodePage(#"{"songs":[{"id":1,"type":"local"},{"id":2,"type":"remote"}],"total":3,"offset":0,"limit":2}"#), requestedLimit: 2)
        #expect(!first.finished)
        let last = try pagination.accept(decodePage(#"{"songs":[{"id":3,"type":"radio"}],"total":3,"offset":2,"limit":2}"#), requestedLimit: 2)
        #expect(last.finished)
        #expect(!pagination.driftObserved)
        #expect(pagination.admittedIDs == [1, 2, 3])
    }

    /// A library that moves under the walk ends it with what was read and
    /// marks it as drift, so neither platform prunes on the strength of it.
    @Test(arguments: [
        #"{"songs":[],"total":2,"offset":0,"limit":2}"#,
        #"{"songs":[{"id":1,"type":"local"}],"total":2,"offset":0,"limit":2}"#,
        #"{"songs":[{"id":1,"type":"local"},{"id":1,"type":"local"}],"total":2,"offset":0,"limit":2}"#,
        #"{"songs":[{"id":1,"type":"local"}],"total":0,"offset":0,"limit":2}"#,
    ])
    func paginationFinishesAMovingLibraryAsDrift(body: String) throws {
        var pagination = SongloftCatalogPagination()
        let outcome = try pagination.accept(decodePage(body), requestedLimit: 2)
        #expect(outcome.finished)
        #expect(pagination.driftObserved)
        #expect(outcome.tracks.count <= 1)
    }

    @Test(arguments: [
        #"{"songs":null,"total":1,"offset":0,"limit":2}"#,
        #"{"songs":[{"id":1,"type":"local"}],"total":1,"offset":1,"limit":2}"#,
        #"{"songs":[{"id":1,"type":"unknown"}],"total":1,"offset":0,"limit":2}"#,
    ])
    func paginationRejectsMalformedPages(body: String) throws {
        var pagination = SongloftCatalogPagination()
        let page = try decodePage(body)
        #expect(throws: SongloftServiceError.invalidResponse) { try pagination.accept(page, requestedLimit: 2) }
    }

    @Test func emptyLiveStyleLibraryIsSuccessful() async throws {
        let fixture = SongloftFixture(mode: .empty)
        let client = fixture.client()
        #expect(try await client.validateConnection() == 0)
        var count = 0
        for try await _ in await client.catalog() { count += 1 }
        #expect(count == 0)
        #expect(try await client.favorites().isEmpty)
    }

    @Test func catalogChecksStableIDsAndIncludesHiddenSongs() async throws {
        let fixture = SongloftFixture()
        let client = fixture.client()
        var ids: [Int64] = []
        for try await track in await client.catalog() { ids.append(track.id) }
        #expect(ids == [1])
        let requests = await fixture.requests
        let catalogRequests = requests.filter { $0.url?.path.contains("/songs") == true }
        #expect(catalogRequests.count == 3)
        for request in catalogRequests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "exclude_playlist_labels", value: "none")))
            #expect(query.contains(URLQueryItem(name: "sort", value: "id")))
        }
    }

    @Test func sameCountReplacementIsReportedAsDrift() async throws {
        let fixture = SongloftFixture(mode: .changedIDs)
        let client = fixture.client()
        for try await _ in await client.catalog() {}
        #expect(await client.takeCatalogDriftObservation() == true)
        #expect(await client.takeCatalogDriftObservation() == false)

        let still = SongloftFixture().client()
        for try await _ in await still.catalog() {}
        #expect(await still.takeCatalogDriftObservation() == false)
    }

    @Test func concurrentUnauthorizedRequestsShareOneTokenRefresh() async throws {
        let fixture = SongloftFixture(mode: .refresh)
        let client = fixture.client()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 { group.addTask { try await client.validateConnection() } }
            for try await total in group { #expect(total == 1) }
        }
        let requests = await fixture.requests
        #expect(requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count == 1)
        let refresh = requests.filter { $0.url?.path.hasSuffix("/auth/refresh") == true }
        #expect(refresh.count == 1)
        #expect(try JSONDecoder().decode([String: String].self, from: refresh[0].httpBody!) == ["refresh_token": "refresh-1"])
    }

    @Test func permissionFailureDoesNotLoopLogin() async throws {
        let fixture = SongloftFixture(mode: .forbidden)
        let client = fixture.client()
        await #expect(throws: SongloftServiceError.badServerResponse(403)) { try await client.validateConnection() }
        #expect(await fixture.requests.count == 2)
    }

    @Test func invalidatingInFlightLoginCannotRestoreSession() async throws {
        let fixture = SongloftFixture()
        let client = fixture.client()
        let pending = Task { try await client.validateConnection() }
        while await fixture.requests.isEmpty { await Task.yield() }
        await client.invalidateSession()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await client.validateConnection() == 1)
        #expect(await fixture.requests.filter { $0.url?.path.hasSuffix("/auth/login") == true }.count == 2)
    }

    @Test func radioUsesFreshAuthenticationAndPreservesHLSSuffix() async throws {
        let fixture = SongloftFixture()
        let client = fixture.client()
        let url = try await client.radioURL(id: 2)
        #expect(url.host == "music.example")
        #expect(url.path == "/prefix/api/v1/songs/2/play.m3u8")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query == [URLQueryItem(name: "access_token", value: "access-1")])
        #expect(!url.absoluteString.contains("test-password"))
    }

    @Test(arguments: [Int64(2), 3])
    func syncedRadioResolvesOnTVAndRefreshesItsSession(id: Int64) async throws {
        let fixture = SongloftFixture()
        let resolver = SongloftStreamResolver(transport: fixture.transport())
        let track = try decodeTrack("{\"id\":\(id),\"type\":\"radio\",\"bit_rate\":128}")
        let station = RadioStation(name: "Radio", streamURL: "", streamFormat: id == 2 ? .hls : .automatic,
            bitRate: track.radioBitRateInBitsPerSecond, sourceID: fixture.source.id,
            serverStationID: String(id), sourcePlaybackPath: SongloftAPIProtocol.radioPlaybackPath(id: id))
        let synced = try JSONDecoder().decode(RadioStation.self, from: JSONEncoder().encode(station))
        #expect(synced.requiresSourceStreamResolution)
        #expect(synced.playbackSubtitle.contains("128 kbps"))
        #expect(SongloftAPIProtocol.trackID(from: synced.playbackSong.filePath) == nil)
        let first = try await resolver.resolve(for: synced.playbackSong, source: fixture.source, credential: fixture.credential)
        #expect(first.url.path == "/prefix/api/v1/songs/\(id)/play\(id == 2 ? ".m3u8" : "")")
        #expect(first.headers.isEmpty)
        #expect(URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "access_token", value: "access-1")])
        await resolver.invalidateSession(sourceID: fixture.source.id)
        let refreshed = try await resolver.resolve(for: synced.playbackSong, source: fixture.source, credential: fixture.credential)
        #expect(URLComponents(url: refreshed.url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "access_token", value: "access-2")])
        #expect(await fixture.requests.allSatisfy { $0.httpMethod != "HEAD" })
    }

    @Test func resolverKeepsRadioSeparateFromOriginalAudio() async throws {
        let fixture = SongloftFixture()
        let resolver = SongloftStreamResolver(transport: fixture.transport())
        let song = try #require(decodeTrack(#"{"id":1,"type":"local","format":"flac"}"#).makeSong(sourceID: fixture.source.id))
        let resolved = try await resolver.resolve(for: song, source: fixture.source, credential: fixture.credential)
        #expect(resolved.headers == ["Authorization": "Bearer access-1"])
        #expect(URLComponents(url: resolved.url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "normalize", value: "0")])
        #expect(await fixture.requests.contains { $0.httpMethod == "HEAD" && $0.url?.path.hasSuffix("/songs/1/play") == true })
        var invalid = song
        invalid.filePath = SongloftAPIProtocol.radioPlaybackPath(id: 1)
        await #expect(throws: StreamResolveError.cannotBuildURL) {
            try await resolver.resolve(for: invalid, source: fixture.source, credential: fixture.credential)
        }
        for path in ["/songloft/radio/0", "/songloft/radio/-1", "/songloft/radio/2?access_token=x", "/songloft/radio/2/3", "/songloft/radio/+2", "2"] {
            invalid.filePath = path
            await #expect(throws: StreamResolveError.cannotBuildURL) {
                try await resolver.resolve(for: invalid, source: fixture.source, credential: fixture.credential)
            }
        }
    }

    @Test func rangeAndDownloadDisableImplicitServerTranscoding() async throws {
        let fixture = SongloftFixture()
        let client = fixture.client()
        #expect(try await client.fetchRange(trackPath: "/songloft/songs/1.flac", offset: 0, length: 2) == Data([0x66, 0x4c]))
        let file = try await client.downloadTrack(trackPath: "/songloft/songs/1.flac")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data([0x66, 0x4c]))
        for request in await fixture.requests where request.url?.path.hasSuffix("/play") == true {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query == [URLQueryItem(name: "normalize", value: "0")])
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        }
    }

    @Test func wrongRangeCannotPoisonSparseCache() async throws {
        let client = SongloftFixture(mode: .wrongRange).client()
        await #expect(throws: SongloftServiceError.invalidResponse) {
            try await client.fetchRange(trackPath: "/songloft/songs/1.flac", offset: 0, length: 2)
        }
    }

    @Test func htmlCannotBecomeOfflineAudio() async throws {
        let client = SongloftFixture(mode: .htmlAudio).client()
        await #expect(throws: SongloftServiceError.invalidResponse) { try await client.downloadTrack(trackPath: "/songloft/songs/1.flac") }
    }

    @Test func authenticatedArtworkUsesSourceRouteAndBounds() async throws {
        let fixture = SongloftFixture()
        let client = fixture.client()
        let reference = SongloftAPIProtocol.coverReference(id: 1, revision: "2026-09-06")
        #expect(try await client.artworkData(reference: reference, maximumBytes: 2) == Data([0x66, 0x4c]))
        await #expect(throws: SongloftServiceError.invalidResponse) { try await client.artworkData(reference: reference, maximumBytes: 1) }
        await #expect(throws: SongloftServiceError.invalidResponse) { try await client.artworkData(reference: "https://foreign.example/api/v1/songs/1/cover", maximumBytes: 2) }
        #expect(await fixture.requests.allSatisfy { $0.url?.host == "music.example" })
    }

    @Test func lyricsRetainWordTimingAndTranslation() async throws {
        let client = SongloftFixture().client()
        let text = try #require(await client.preferredLyrics(trackPath: "/songloft/songs/1.flac"))
        let lines = LyricsContentParser.parseText(text)
        #expect(lines.first?.text == "Hello")
        #expect(lines.first?.syllables?.isEmpty == false)
        #expect(lines.first?.manualTranslation?.text == "你好")
        #expect(!text.contains("lxlyric"))
    }

    @Test func missingLyricsAreAbsentWhileFailureThrows() async throws {
        #expect(try await SongloftFixture(mode: .absentLyrics).client().preferredLyrics(trackPath: "/songloft/songs/1.flac") == nil)
        await #expect(throws: SongloftServiceError.badServerResponse(502)) {
            try await SongloftFixture(mode: .failedLyrics).client().preferredLyrics(trackPath: "/songloft/songs/1.flac")
        }
    }

    @Test func favoritesWriteThroughAndReadBackWithoutDeletingAudio() async throws {
        let fixture = SongloftFixture()
        let client = fixture.client()
        #expect(try await client.setFavorite(id: 1, isFavorite: true) == [1])
        #expect(try await client.setFavorite(id: 1, isFavorite: true) == [1])
        #expect(try await client.setFavorite(id: 1, isFavorite: false).isEmpty)
        let mutations = await fixture.requests.filter { ["POST", "DELETE"].contains($0.httpMethod) && $0.url?.path.contains("/playlists/") == true }
        #expect(mutations.count == 2)
        #expect(mutations.map { $0.url!.path } == ["/prefix/api/v1/playlists/1/songs", "/prefix/api/v1/playlists/1/songs/1"])
        #expect(try JSONDecoder().decode([String: [Int64]].self, from: mutations[0].httpBody!) == ["song_ids": [1]])
    }

    @Test func playlistsKeepServerOrderAndRejectCountMismatch() async throws {
        let client = SongloftFixture().client()
        let playlists = try await client.playlists()
        #expect(playlists.map(\.id) == [3])
        #expect(try await client.playlistSongIDs(id: 3, expectedCount: 2) == [7, 1])
        await #expect(throws: SongloftServiceError.invalidResponse) { try await client.playlistSongIDs(id: 3, expectedCount: 3) }
    }

    @Test func playbackEventsAcceptNoContentResponse() async throws {
        let fixture = SongloftFixture()
        let client = fixture.client()
        try await client.reportPlayback(trackPath: "/songloft/songs/1.flac", submission: false)
        try await client.reportPlayback(trackPath: "/songloft/songs/1.flac", submission: true)
        let events = await fixture.requests.filter { $0.url?.path.hasSuffix("/played") == true }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.httpMethod == "POST" })
    }

    private func decodeTrack(_ json: String) throws -> SongloftTrack {
        try SongloftAPIProtocol.decoder().decode(SongloftTrack.self, from: Data(json.utf8))
    }
    private func decodePage(_ json: String) throws -> SongloftTrackPage {
        try SongloftAPIProtocol.decoder().decode(SongloftTrackPage.self, from: Data(json.utf8))
    }
}

private actor SongloftFixture {
    enum Mode { case normal, empty, changedIDs, refresh, forbidden, wrongRange, htmlAudio, absentLyrics, failedLyrics }
    let mode: Mode
    var requests: [URLRequest] = []
    var favorite = false
    private var idReads = 0
    private var authGeneration = 0
    init(mode: Mode = .normal) { self.mode = mode }

    nonisolated var source: MusicSource {
        MusicSource(id: "test", name: "Songloft", type: .songloft,
            host: "music.example", port: nil, useSsl: true, username: "test", basePath: "/prefix")
    }

    nonisolated var credential: SourceCredential {
        SourceCredential(username: "test", password: "test-password")
    }

    nonisolated func client() -> SongloftServiceClient {
        SongloftServiceClient(source: source, credential: credential, transport: transport())
    }

    nonisolated func transport() -> SongloftRequestTransport {
        SongloftRequestTransport(data: { try await self.reply($0) }, download: { request in
                let (data, response) = try await self.reply(request)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try data.write(to: file)
                return (file, response)
            })
    }

    func reply(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        let path = String(url.path.dropFirst("/prefix/api/v1".count))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if path == "/auth/login" || path == "/auth/refresh" {
            authGeneration += 1
            let generation = authGeneration
            try await Task.sleep(for: .milliseconds(10))
            return response(url, json: "{\"access_token\":\"access-\(generation)\",\"refresh_token\":\"refresh-\(generation)\",\"expires_in\":604800}")
        }
        if mode == .forbidden { return response(url, status: 403, json: "{}") }
        if mode == .refresh, request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1" { return response(url, status: 401, json: "{}") }
        switch path {
        case "/songs":
            let limit = query.first { $0.name == "limit" }?.value ?? "500"
            return response(url, json: mode == .empty
                ? "{\"songs\":null,\"total\":0,\"offset\":0,\"limit\":\(limit)}"
                : "{\"songs\":[{\"id\":1,\"type\":\"local\",\"format\":\"flac\"}],\"total\":1,\"offset\":0,\"limit\":\(limit)}")
        case "/songs/ids":
            idReads += 1
            return response(url, json: mode == .empty ? #"{"ids":null,"total":0}"#
                : mode == .changedIDs && idReads > 1 ? #"{"ids":[2],"total":1}"# : #"{"ids":[1],"total":1}"#)
        case "/songs/1/play", "/songs/1/cover":
            let range = request.value(forHTTPHeaderField: "Range") != nil
            let fields = ["Content-Type": mode == .htmlAudio ? "text/html" : "audio/flac", "Content-Length": "2",
                          "Content-Range": mode == .wrongRange ? "bytes 2-3/4" : "bytes 0-1/2"]
            return (Data([0x66, 0x4c]), HTTPURLResponse(url: url, statusCode: range ? 206 : 200, httpVersion: nil, headerFields: fields)!)
        case "/songs/1/lyric":
            if mode == .absentLyrics { return response(url, status: 404, json: "{}") }
            if mode == .failedLyrics { return response(url, status: 502, json: "{}") }
            return response(url, json: #"{"lyric":"[00:01.00]Hello","lxlyric":"[00:01.00]<00:01.00>Hello<00:02.00>","tlyric":"[00:01.00]你好"}"#)
        case "/playlists/1":
            return response(url, json: "{\"id\":1,\"type\":\"normal\",\"name\":\"Favorites\",\"labels\":[\"built_in\"],\"song_count\":\(favorite ? 1 : 0)}")
        case "/playlists/1/song-ids":
            return response(url, json: favorite ? #"{"ids":[1],"total":1}"# : #"{"ids":[],"total":0}"#)
        case "/playlists/1/songs": favorite = true; return response(url, json: "{}")
        case "/playlists/1/songs/1": favorite = false; return response(url, json: "{}")
        case "/playlists":
            return response(url, json: #"{"playlists":[{"id":3,"name":"Ordered","type":"normal","song_count":2}],"total":1,"offset":0,"limit":500}"#)
        case "/playlists/3/song-ids": return response(url, json: #"{"ids":[7,1],"total":2}"#)
        case "/songs/1/played": return response(url, status: 204, json: "")
        case "/songs/1": return response(url, json: #"{"id":1,"type":"local","format":"flac"}"#)
        case "/songs/2": return response(url, json: #"{"id":2,"type":"radio","title":"Radio","url":"/api/v1/songs/2/play.m3u8","is_live":true}"#)
        case "/songs/3": return response(url, json: #"{"id":3,"type":"radio","title":"Radio","url":"/api/v1/songs/3/play","is_live":true}"#)
        default: throw URLError(.unsupportedURL)
        }
    }

    private func response(_ url: URL, status: Int = 200, json: String) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
