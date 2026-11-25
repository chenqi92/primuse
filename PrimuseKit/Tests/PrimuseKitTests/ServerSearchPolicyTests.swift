import Foundation
import Testing
@testable import PrimuseKit

@Suite("Server search policy and service clients")
struct ServerSearchPolicyTests {
    @Test("Server search defaults to disabled until explicitly turned on")
    func defaultDisabled() {
        let suiteName = "com.primuse.tests.serverSearch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!ServerSearchFeatureSettings.isEnabled(defaults: defaults))
        defaults.set(true, forKey: ServerSearchFeatureSettings.enabledKey)
        #expect(ServerSearchFeatureSettings.isEnabled(defaults: defaults))
    }

    @Test("All music server types support standard server search, while spoken-word and file sources do not")
    func supportedSourceTypes() {
        let expectedSupported: Set<MusicSourceType> = [
            .subsonic, .navidrome, .airsonic, .gonic, .zspace,
            .songloft,
            .jellyfin, .emby, .plex,
            .synologyAudioStation,
            .fnMusic,
            .daoliyu,
        ]
        for type in MusicSourceType.allCases {
            #expect(
                ServerSearchAvailabilityPolicy.supportsServerSearch(type) == expectedSupported.contains(type),
                "Unexpected supportsServerSearch for \(type.rawValue)"
            )
        }
    }

    @Test("Availability requires explicit opt-in and at least one enabled music server")
    func availabilityChecks() {
        let navidrome = MusicSource(id: "s1", name: "Navidrome", type: .navidrome, isEnabled: true)
        let disabledSongloft = MusicSource(id: "s2", name: "Songloft", type: .songloft, isEnabled: false)
        let webdav = MusicSource(id: "s3", name: "WebDAV", type: .webdav, isEnabled: true)

        #expect(!ServerSearchAvailabilityPolicy.isEnabled(featureEnabled: false, sources: [navidrome]))
        #expect(ServerSearchAvailabilityPolicy.isEnabled(featureEnabled: true, sources: [navidrome]))
        #expect(!ServerSearchAvailabilityPolicy.isEnabled(
            featureEnabled: true,
            sources: [navidrome],
            disabledSourceIDs: ["s1"]
        ))
        #expect(!ServerSearchAvailabilityPolicy.isEnabled(
            featureEnabled: true,
            sources: [disabledSongloft, webdav]
        ))
        #expect(ServerSearchAvailabilityPolicy.normalizedQuery("   \n ") == nil)
        #expect(ServerSearchAvailabilityPolicy.normalizedQuery("  晴天  ") == "晴天")
    }

    @Test("Deduplicator filters local library IDs, source+path matches, and duplicate hits while preserving order")
    func deduplicationFiltersIndexedAndDuplicates() {
        let songA = makeSong(id: "id-a", sourceID: "s1", filePath: "/songs/1.flac", title: "A")
        let songB = makeSong(id: "id-b", sourceID: "s1", filePath: "/songs/2.flac", title: "B")
        let songBDup = makeSong(id: "id-b-alt", sourceID: "s1", filePath: "/songs/2.flac", title: "B")
        let songC = makeSong(id: "id-c", sourceID: "s2", filePath: "/songs/3.mp3", title: "C")
        let songD = makeSong(id: "id-d", sourceID: "s2", filePath: "/songs/4.mp3", title: "D")

        let hits = [
            ServerSearchHit(song: songA, sourceName: "S1", sourceType: .navidrome),
            ServerSearchHit(song: songB, sourceName: "S1", sourceType: .navidrome),
            ServerSearchHit(song: songBDup, sourceName: "S1", sourceType: .navidrome),
            ServerSearchHit(song: songC, sourceName: "S2", sourceType: .songloft),
            ServerSearchHit(song: songD, sourceName: "S2", sourceType: .songloft),
        ]

        let filtered = ServerSearchResultDeduplicator.filterUnindexed(
            hits,
            localSongIDs: ["id-a"],
            localSourceFilePaths: [ServerSearchResultDeduplicator.sourcePathKey(sourceID: "s2", filePath: "/songs/3.mp3")]
        )
        #expect(filtered.map(\.song.id) == ["id-b", "id-d"])
    }

    @Test("DaoLiYuServiceClient.searchTracks sends search query parameter on /api/tracks")
    func daoLiYuSearchTracksQuery() async throws {
        let recorded = Box<[URLRequest]>([])
        let transport = DaoLiYuRequestTransport(
            data: { request in
                recorded.withLock { $0.append(request) }
                let path = request.url?.path ?? ""
                if path.hasSuffix("/auth/login") {
                    return (
                        Data(#"{"token":"tok-1"}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                let payload = """
                {
                  "total": 1,
                  "skip": 0,
                  "take": 10,
                  "items": [
                    {
                      "id": "trk-9",
                      "title": "夜曲",
                      "duration": 226,
                      "fileExtension": "flac",
                      "artists": [{"artist": {"name": "周杰伦"}}],
                      "album": {"id": "alb-1", "title": "十一月的萧邦"}
                    }
                  ]
                }
                """
                return (
                    Data(payload.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            download: { _ in throw DaoLiYuServiceError.invalidResponse("unused") }
        )
        let source = MusicSource(id: "dly-1", name: "道理鱼", type: .daoliyu, host: "nas.local", port: 8080, useSsl: false)
        let client = DaoLiYuServiceClient(
            source: source,
            credential: SourceCredential(username: "u", password: "p"),
            transport: transport
        )

        let tracks = try await client.searchTracks(query: "夜曲", limit: 10)
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == "trk-9")
        #expect(tracks.first?.title == "夜曲")

        let searchReq = try #require(recorded.value.last)
        let items = URLComponents(url: try #require(searchReq.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(searchReq.url?.path == "/api/tracks")
        #expect(items.first(where: { $0.name == "search" })?.value == "夜曲")
        #expect(items.first(where: { $0.name == "take" })?.value == "10")
    }

    @Test("SynologyAudioStationClient.searchSongs falls back to method=list with keyword on apiNotFound")
    func synologyAudioStationSearchFallback() async throws {
        let recorded = Box<[URLRequest]>([])
        let transport = SynologyAudioStationRequestTransport(
            data: { request in
                recorded.withLock { $0.append(request) }
                let query: [URLQueryItem]
                if let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, !items.isEmpty {
                    query = items
                } else if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
                    var comps = URLComponents()
                    comps.percentEncodedQuery = text
                    query = comps.queryItems ?? []
                } else {
                    query = []
                }
                let api = query.first(where: { $0.name == "api" })?.value ?? ""
                let method = query.first(where: { $0.name == "method" })?.value ?? ""
                let json: String
                if api == "SYNO.API.Info" {
                    json = """
                    {"success":true,"data":{
                      "SYNO.API.Auth":{"path":"entry.cgi","minVersion":3,"maxVersion":7},
                      "SYNO.AudioStation.Info":{"path":"AudioStation/info.cgi","minVersion":1,"maxVersion":6},
                      "SYNO.AudioStation.Song":{"path":"AudioStation/song.cgi","minVersion":1,"maxVersion":3},
                      "SYNO.AudioStation.Stream":{"path":"AudioStation/stream.cgi","minVersion":1,"maxVersion":2}
                    }}
                    """
                } else if api == "SYNO.API.Auth" {
                    json = #"{"success":true,"data":{"sid":"sid-1"}}"#
                } else if api == "SYNO.AudioStation.Song", method == "search" {
                    json = #"{"success":false,"error":{"code":103}}"#
                } else if api == "SYNO.AudioStation.Song", method == "list" {
                    json = """
                    {"success":true,"data":{"total":1,"offset":0,"songs":[
                      {"id":"music_77","title":"青花瓷","path":"/music/qhc.flac",
                       "additional":{"song_tag":{"artist":"周杰伦","album":"我很忙"},
                                     "song_audio":{"duration":239,"bitrate":950000,"frequency":44100,"filesize":30000000}}}
                    ]}}
                    """
                } else {
                    json = #"{"success":true,"data":{}}"#
                }
                return (
                    Data(json.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            download: { _ in throw SynologyAudioStationError.invalidResponse }
        )
        let source = MusicSource(id: "syno-1", name: "DSM", type: .synologyAudioStation, host: "dsm.local", port: 5000, useSsl: false)
        let client = SynologyAudioStationClient(
            source: source,
            credential: SourceCredential(username: "u", password: "p"),
            transport: transport
        )

        let songs = try await client.searchSongs(keyword: "青花瓷", limit: 15)
        #expect(songs.count == 1)
        #expect(songs.first?.id == "music_77")
        #expect(songs.first?.makeSong(sourceID: "syno-1")?.title == "青花瓷")

        let songCalls = recorded.value.filter { $0.url?.path.contains("song.cgi") == true }
        #expect(songCalls.count == 2)
        let secondQuery = URLComponents(url: try #require(songCalls.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(secondQuery.first(where: { $0.name == "method" })?.value == "list")
        #expect(secondQuery.first(where: { $0.name == "keyword" })?.value == "青花瓷")
    }

    @Test("FnMusicServiceClient.searchTracks queries /search/track and caps results")
    func fnMusicSearchTracks() async throws {
        let handlerID = UUID().uuidString
        let recorded = Box<[URLRequest]>([])
        MockSearchURLProtocol.register(id: handlerID) { request in
            recorded.withLock { $0.append(request) }
            let path = request.url?.path ?? ""
            if path.hasSuffix("/user/password-login") {
                let body = #"{"code":0,"msg":"","data":{"userToken":"tok-fn"}}"#
                return (200, Data(body.utf8))
            }
            let body = """
            {"code":0,"msg":"","data":{"total":2,"list":[
              {"guid":"g-1","title":"Song One","duration":200000,"isCue":false,"artists":[{"name":"Artist A"}],"album":{"guid":"a-1","name":"Album A"},"audioSpec":{"format":"flac","size":1024}},
              {"guid":"g-2","title":"Song Two","duration":180000,"isCue":false,"artists":[{"name":"Artist B"}],"album":{"guid":"a-2","name":"Album B"},"audioSpec":{"format":"mp3","size":512}}
            ]}}
            """
            return (200, Data(body.utf8))
        }
        defer { MockSearchURLProtocol.unregister(id: handlerID) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSearchURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Handler": handlerID]
        let session = URLSession(configuration: config)
        let source = MusicSource(
            id: "fn-1",
            name: "飞牛音乐",
            type: .fnMusic,
            host: "192.168.0.2",
            port: 5666,
            useSsl: false,
            fnMusicConnectionMode: .address
        )
        let client = FnMusicServiceClient(
            source: source,
            credential: SourceCredential(username: "u", password: "p"),
            session: session
        )

        let tracks = try await client.searchTracks(query: "Song", limit: 1)
        #expect(tracks.count == 1)
        #expect(tracks.first?.guid == "g-1")
        #expect(tracks.first?.makeSong(sourceID: "fn-1")?.title == "Song One")

        let searchReq = try #require(recorded.value.last)
        let items = URLComponents(url: try #require(searchReq.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(searchReq.url?.path == "/music/api/v1/search/track")
        #expect(items.first(where: { $0.name == "q" })?.value == "Song")
        #expect(items.first(where: { $0.name == "size" })?.value == "1")
    }

    private func makeSong(id: String, sourceID: String, filePath: String, title: String) -> Song {
        Song(
            id: id,
            title: title,
            duration: 180,
            fileFormat: .flac,
            filePath: filePath,
            sourceID: sourceID,
            fileSize: 1_000
        )
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.withLock { storage } }
    func withLock(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}

private final class MockSearchURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: @Sendable (URLRequest) -> (Int, Data)] = [:]

    static func register(id: String, handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        lock.withLock { handlers[id] = handler }
    }

    static func unregister(id: String) {
        lock.withLock { _ = handlers.removeValue(forKey: id) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Test-Handler") ?? ""
        let handler = Self.lock.withLock { Self.handlers[id] }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
