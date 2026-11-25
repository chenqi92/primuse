import Foundation
import Testing
@testable import Primuse
@testable import PrimuseKit

@Suite("Server song search service and connectors")
struct ServerSongSearchTests {
    @Test("Service debounces, deduplicates indexed tracks, preserves source order, and isolates failures")
    @MainActor
    func serviceFansOutDeduplicatesAndIsolatesFailures() async throws {
        let fastSource = MusicSource(id: "src-1", name: "Navidrome", type: .navidrome, isEnabled: true)
        let brokenSource = MusicSource(id: "src-2", name: "Broken", type: .songloft, isEnabled: true)
        let secondSource = MusicSource(id: "src-3", name: "Jellyfin", type: .jellyfin, isEnabled: true)

        let indexedSong = makeSong(id: "local-1", sourceID: "src-1", path: "/songs/1.flac", title: "Already Local")
        let remote1 = makeSong(id: "remote-1", sourceID: "src-1", path: "/songs/2.flac", title: "Fresh One")
        let remote2 = makeSong(id: "remote-2", sourceID: "src-3", path: "/items/9.mp3", title: "Fresh Two")

        let fastConnector = StubSearchingConnector(sourceID: "src-1", result: .success([indexedSong, remote1]))
        let brokenConnector = StubSearchingConnector(sourceID: "src-2", result: .failure(SourceError.connectionFailed("offline")))
        let secondConnector = StubSearchingConnector(sourceID: "src-3", result: .success([remote2]))

        let service = ServerSongSearchService(
            debounce: .milliseconds(30),
            perSourceLimit: 10,
            perSourceTimeout: .seconds(2)
        )

        // Rapidly supersede an earlier query; only the second query should commit.
        service.search(
            query: "old",
            sources: [fastSource, brokenSource, secondSource],
            connectorProvider: { source in
                switch source.id {
                case "src-1": fastConnector
                case "src-2": brokenConnector
                case "src-3": secondConnector
                default: nil
                }
            },
            isLocalSongIndexed: { $0.id == "local-1" }
        )
        service.search(
            query: "fresh",
            sources: [fastSource, brokenSource, secondSource],
            connectorProvider: { source in
                switch source.id {
                case "src-1": fastConnector
                case "src-2": brokenConnector
                case "src-3": secondConnector
                default: nil
                }
            },
            isLocalSongIndexed: { $0.id == "local-1" }
        )

        try await waitUntil { service.hasCompletedQuery && !service.isSearching }

        #expect(service.activeQuery == "fresh")
        #expect(service.failedSourceCount == 1)
        #expect(service.hits.map(\.song.id) == ["remote-1", "remote-2"])
        #expect(service.hits.map(\.sourceName) == ["Navidrome", "Jellyfin"])
        #expect(await fastConnector.recordedQueries == ["fresh"])
    }

    @Test("Service isolates stalled servers with per-source timeout")
    @MainActor
    func serviceTimeoutsDoNotBlockHealthySources() async throws {
        let slowSource = MusicSource(id: "slow", name: "Sleeping NAS", type: .subsonic, isEnabled: true)
        let fastSource = MusicSource(id: "fast", name: "Songloft", type: .songloft, isEnabled: true)
        let fastSong = makeSong(id: "fast-1", sourceID: "fast", path: "/songloft/songs/1.flac", title: "Ready")

        let slowConnector = StubSearchingConnector(sourceID: "slow", delay: .seconds(5), result: .success([]))
        let fastConnector = StubSearchingConnector(sourceID: "fast", result: .success([fastSong]))

        let service = ServerSongSearchService(
            debounce: .zero,
            perSourceLimit: 10,
            perSourceTimeout: .milliseconds(80)
        )
        service.search(
            query: "ready",
            sources: [slowSource, fastSource],
            connectorProvider: { $0.id == "slow" ? slowConnector : fastConnector },
            isLocalSongIndexed: { _ in false }
        )

        try await waitUntil { service.hasCompletedQuery && !service.isSearching }
        #expect(service.hits.map(\.song.id) == ["fast-1"])
        #expect(service.failedSourceCount == 1)
    }

    @Test("SongloftSource.searchServerSongs queries /songs with keyword and skips radio/video")
    func songloftSearchFiltersRadioAndVideo() async throws {
        let transport = SongloftRequestTransport(
            data: { request in
                let path = request.url?.path ?? ""
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if path.hasSuffix("/auth/login") {
                    let body = #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#
                    return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let keyword = query.first(where: { $0.name == "keyword" })?.value
                let body: String
                if keyword == "晴天" {
                    body = """
                    {"songs":[
                      {"id":10,"type":"local","title":"晴天","artist":"周杰伦","album":"叶惠美","duration":269,"format":"flac"},
                      {"id":11,"type":"radio","title":"晴天电台","format":"mp3"},
                      {"id":12,"type":"local","title":"晴天MV","format":"mp4","is_video":true}
                    ],"total":3,"limit":10,"offset":0}
                    """
                } else {
                    body = #"{"songs":[],"total":0,"limit":1,"offset":0}"#
                }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            download: { _ in throw SongloftServiceError.invalidResponse }
        )
        let connector = SongloftSource(
            sourceID: "sl-1",
            host: "192.168.0.2",
            port: 58091,
            useSSL: false,
            basePath: nil,
            username: "u",
            password: "p",
            transport: transport
        )

        let songs = try await connector.searchServerSongs(query: "晴天", limit: 10)
        #expect(songs.count == 1)
        #expect(songs.first?.title == "晴天")
        #expect(songs.first?.filePath == "/songloft/songs/10.flac")
    }

    @Test("MediaServerSource.searchServerSongs respects excluded libraries on Jellyfin")
    func jellyfinSearchRespectsExcludedLibraries() async throws {
        let requestedParents = LockedBox<[String]>([])
        let loader: MediaServerSource.RequestDataLoader = { request in
            let url = request.url!
            let path = url.path
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let body: String
            if path.hasSuffix("/Users/Me") {
                body = #"{"Id":"u1"}"#
            } else if path.hasSuffix("/Users/u1/Views") {
                body = """
                {"Items":[
                  {"Id":"lib-music","Name":"Music","CollectionType":"music"},
                  {"Id":"lib-hidden","Name":"Hidden","CollectionType":"music"}
                ]}
                """
            } else if path.hasSuffix("/Library/VirtualFolders") {
                body = "[]"
            } else if path.hasSuffix("/Users/u1/Items") {
                let parent = items.first(where: { $0.name == "ParentId" })?.value ?? ""
                requestedParents.withLock { $0.append(parent) }
                let term = items.first(where: { $0.name == "searchTerm" })?.value ?? ""
                if parent == "lib-music", term == "稻香" {
                    body = """
                    {"TotalRecordCount":1,"Items":[
                      {"Id":"item-42","Name":"稻香","Album":"魔杰座","Artists":["周杰伦"],
                       "RunTimeTicks":2230000000,"Path":"/music/daoxiang.flac",
                       "MediaSources":[{"Container":"flac","Size":25000000,"Path":"/music/daoxiang.flac"}]}
                    ]}
                    """
                } else {
                    body = #"{"TotalRecordCount":0,"Items":[]}"#
                }
            } else {
                body = "{}"
            }
            return (
                Data(body.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            )
        }

        let connector = MediaServerSource(
            sourceID: "jf-1",
            kind: .jellyfin,
            host: "192.168.0.2",
            port: 8097,
            useSsl: false,
            basePath: nil,
            username: "u",
            secret: "api-key",
            authType: .apiKey,
            excludedLibraryIDs: ["lib-hidden"],
            requestDataLoader: loader
        )

        let songs = try await connector.searchServerSongs(query: "稻香", limit: 15)
        #expect(songs.count == 1)
        #expect(songs.first?.title == "稻香")
        #expect(songs.first?.serverLibraryID == "lib-music")
        #expect(requestedParents.value == ["lib-music"])
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for server search completion")
                return
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }

    private func makeSong(id: String, sourceID: String, path: String, title: String) -> Song {
        Song(
            id: id,
            title: title,
            duration: 200,
            fileFormat: .flac,
            filePath: path,
            sourceID: sourceID,
            fileSize: 1_000
        )
    }
}

private actor StubSearchingConnector: ServerSongSearchingConnector {
    let sourceID: String
    let delay: Duration
    let result: Result<[Song], Error>
    private(set) var recordedQueries: [String] = []

    init(sourceID: String, delay: Duration = .zero, result: Result<[Song], Error>) {
        self.sourceID = sourceID
        self.delay = delay
        self.result = result
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamingURL(for path: String) async throws -> URL? { nil }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func imageURL(for path: String) async throws -> URL? { nil }

    func searchServerSongs(query: String, limit: Int) async throws -> [Song] {
        recordedQueries.append(query)
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return try result.get()
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.withLock { storage } }
    func withLock(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}
