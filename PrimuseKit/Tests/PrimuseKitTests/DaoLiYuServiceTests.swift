import Foundation
import Testing
@testable import PrimuseKit

@Test func daoLiYuProtocolBuildsNativeEndpointsAndOpaqueReferences() throws {
    let base = try #require(DaoLiYuAPIProtocol.serverBaseURL(
        host: "music.example.com",
        port: 8443,
        useSSL: true,
        basePath: "/music"
    ))
    #expect(base.absoluteString == "https://music.example.com:8443/music")

    let list = try #require(DaoLiYuAPIProtocol.endpointURL(
        serverBaseURL: base,
        path: "/tracks",
        queryItems: [
            URLQueryItem(name: "skip", value: "0"),
            URLQueryItem(name: "take", value: "100"),
        ]
    ))
    #expect(list.path == "/music/api/tracks")
    #expect(URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems?.count == 2)

    let trackPath = DaoLiYuAPIProtocol.trackPath(id: "trk_123", fileExtension: "FLAC")
    #expect(trackPath == "/daoliyu/tracks/trk_123.flac")
    #expect(DaoLiYuAPIProtocol.trackID(from: trackPath) == "trk_123")
    #expect(DaoLiYuAPIProtocol.streamURL(serverBaseURL: base, trackID: "trk_123")?.path
        == "/music/api/tracks/trk_123/download")
    // 转义过的 id 段不再被转第二遍(`%20` 曾经变成 `%2520`)。
    #expect(DaoLiYuAPIProtocol.streamURL(serverBaseURL: base, trackID: "trk 1/2")?.absoluteString
        == "https://music.example.com:8443/music/api/tracks/trk%201%2F2/download")
}

@Test func daoLiYuTrackBuildsStableSongFromVNextPayload() throws {
    let json: [String: Any] = [
        "id": "trk_123",
        "title": "Connector Tone",
        "artist": ["id": "artist_1", "name": "Primuse QA"],
        "artistName": "Primuse QA",
        "album": [
            "id": "album_1",
            "title": "Validation",
            "albumArtist": "Various Artists",
        ],
        "filePath": "/data/music/tone.flac",
        "fileSize": 114_514,
        "fileFormat": "flac",
        "durationSeconds": 8.0,
        "bitrate": 115,
        "genres": [["id": "genre_1", "name": "Test"]],
        "createdAt": "2026-08-02T00:00:00.000Z",
        "updatedAt": "2026-08-02T00:01:00.000Z",
        "coverArtPath": "/data/music/cover.jpg",
        "lyricsSync": "[00:00.00]Connector",
    ]
    let base = try #require(URL(string: "https://music.example.com"))
    let track = try #require(DaoLiYuCatalogTrack(json: json))
    let first = try #require(track.makeSong(sourceID: "source-1", serverBaseURL: base))
    let second = try #require(track.makeSong(sourceID: "source-1", serverBaseURL: base))

    #expect(track.hasUsableCatalogTitle)
    #expect(first.id == second.id)
    #expect(first.title == "Connector Tone")
    #expect(first.artistName == "Primuse QA")
    #expect(first.albumTitle == "Validation")
    #expect(first.albumArtistName == "Various Artists")
    #expect(first.filePath == "/daoliyu/tracks/trk_123.flac")
    #expect(first.fileFormat == .flac)
    #expect(first.duration == 8)
    #expect(first.bitRate == 115)
    #expect(first.genre == "Test")
    #expect(first.coverArtFileName == "https://music.example.com/api/cover?path=/data/music/cover.jpg")
    #expect(track.synchronizedLyrics == "[00:00.00]Connector")
}

@Test func daoLiYuMissingAndPlaceholderTitlesNeedFileHeaderInspection() throws {
    for (index, title) in [nil, "", "Unknown", "未知标题"].enumerated() {
        var json: [String: Any] = ["id": "missing-title-\(index)"]
        if let title { json["title"] = title }
        let track = try #require(DaoLiYuCatalogTrack(json: json))
        #expect(!track.hasUsableCatalogTitle)
    }
}

/// 仅在 QA 环境变量齐全时运行；不会把局域网凭据写入源码或测试输出。
@Test func daoLiYuLiveConnectionWhenConfigured() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rawURL = environment["PRIMUSE_DAOLIYU_QA_URL"],
          let url = URL(string: rawURL),
          let host = url.host,
          let username = environment["PRIMUSE_DAOLIYU_QA_USERNAME"],
          let password = environment["PRIMUSE_DAOLIYU_QA_PASSWORD"] else {
        return
    }
    let source = MusicSource(
        id: "daoliyu-live-qa",
        name: "Daoliyu Live QA",
        type: .daoliyu,
        host: host,
        port: url.port,
        useSsl: url.scheme == "https",
        username: username,
        basePath: url.path == "/" ? nil : url.path
    )
    let credential = SourceCredential(username: username, password: password)
    let client = DaoLiYuServiceClient(source: source, credential: credential)
    let total = try await client.validateConnection()
    #expect(total >= 1)

    let page = try await client.trackPage(skip: 0, take: min(max(total, 1), 500))
    let track = try #require(
        page.tracks.first(where: { $0.fileExtension?.lowercased() != "mp3" })
            ?? page.tracks.first
    )
    let base = try #require(DaoLiYuAPIProtocol.serverBaseURL(
        host: host,
        port: url.port,
        useSSL: url.scheme == "https",
        basePath: source.basePath
    ))
    let song = try #require(track.makeSong(sourceID: source.id, serverBaseURL: base))
    let prefix = try await client.fetchRange(trackPath: song.filePath, offset: 0, length: 2)
    #expect(prefix.count == 2)

    let resolved = try await client.resolvedStream(trackPath: song.filePath)
    #expect(resolved.url.path.hasSuffix("/api/tracks/\(track.id)/download"))
    #expect(resolved.headers["Authorization"]?.hasPrefix("Bearer ") == true)
}

@Test func daoLiYuClientUsesOriginalDownloadRouteForRangeAndCache() async throws {
    let recorder = DaoLiYuRequestRecorder()
    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("daoliyu-original-download.flac")
    let transport = DaoLiYuRequestTransport(
        data: { request in
            let path = try #require(request.url?.path)
            await recorder.recordData(path)
            let url = try #require(request.url)
            switch path {
            case "/api/auth/login":
                return (
                    Data(#"{"token":"TOKEN"}"#.utf8),
                    try #require(HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    ))
                )
            case "/api/tracks/trk_123/download":
                return (
                    Data([0x66, 0x4C]),
                    try #require(HTTPURLResponse(
                        url: url,
                        statusCode: 206,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Range": "bytes 0-1/2",
                            "Content-Length": "2",
                        ]
                    ))
                )
            default:
                throw URLError(.badServerResponse)
            }
        },
        download: { request in
            let path = try #require(request.url?.path)
            await recorder.recordDownload(path)
            let url = try #require(request.url)
            return (
                temporaryURL,
                try #require(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "audio/flac"]
                ))
            )
        }
    )
    let client = DaoLiYuServiceClient(
        sourceID: "source-1",
        host: "music.example.com",
        port: nil,
        useSSL: true,
        basePath: nil,
        username: "qa@example.com",
        password: "password",
        transport: transport
    )
    let trackPath = DaoLiYuAPIProtocol.trackPath(id: "trk_123", fileExtension: "flac")

    let prefix = try await client.fetchRange(trackPath: trackPath, offset: 0, length: 2)
    let downloadedURL = try await client.downloadTrack(trackPath: trackPath)
    let requests = await recorder.snapshot()

    #expect(prefix == Data([0x66, 0x4C]))
    #expect(downloadedURL == temporaryURL)
    #expect(requests.data.contains("/api/tracks/trk_123/download"))
    #expect(requests.download == ["/api/tracks/trk_123/download"])
    #expect(!requests.data.contains(where: { $0.hasSuffix("/stream") }))
}

@Test func daoLiYuClientReportsPlaybackLikeTheWebClientAndRetriesOnExpiredToken() async throws {
    let recorder = DaoLiYuPlaybackReportRecorder()
    let transport = DaoLiYuRequestTransport(
        data: { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/auth/login":
                let token = await recorder.nextToken()
                return (
                    Data(#"{"token":"\#(token)"}"#.utf8),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                )
            case "/api/library/playback-history":
                let status = await recorder.recordReport(
                    method: request.httpMethod,
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    body: request.httpBody
                )
                return (
                    Data(),
                    try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                )
            default:
                throw URLError(.badServerResponse)
            }
        },
        download: { _ in throw URLError(.unsupportedURL) }
    )
    let client = DaoLiYuServiceClient(
        sourceID: "source-1",
        host: "music.example.com",
        port: nil,
        useSSL: true,
        basePath: nil,
        username: "qa@example.com",
        password: "password",
        transport: transport
    )
    let trackPath = DaoLiYuAPIProtocol.trackPath(id: "trk_123", fileExtension: "flac")

    try await client.reportPlayback(
        trackPath: trackPath,
        playedAt: Date(timeIntervalSince1970: 1_760_000_000.5)
    )
    let reports = await recorder.reports

    // 第一次带过期令牌被拒,重新登录后再报一次。
    #expect(reports.map(\.authorization) == ["Bearer TOKEN-1", "Bearer TOKEN-2"])
    let report = try #require(reports.last)
    #expect(report.method == "POST")
    #expect(report.contentType == "application/json")
    let body = try #require(report.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(json == ["trackId": "trk_123", "playedAt": "2025-10-09T08:53:20.500Z"])
}

@Test func daoLiYuPlaybackReportSurfacesMissingEndpointOnOlderServers() async throws {
    let transport = DaoLiYuRequestTransport(
        data: { request in
            let url = try #require(request.url)
            let isLogin = url.path == "/api/auth/login"
            return (
                Data(isLogin ? #"{"token":"TOKEN"}"#.utf8 : #"404 page not found"#.utf8),
                try #require(HTTPURLResponse(
                    url: url,
                    statusCode: isLogin ? 200 : 404,
                    httpVersion: nil,
                    headerFields: nil
                ))
            )
        },
        download: { _ in throw URLError(.unsupportedURL) }
    )
    let client = DaoLiYuServiceClient(
        sourceID: "source-1",
        host: "music.example.com",
        port: nil,
        useSSL: true,
        basePath: nil,
        username: "qa@example.com",
        password: "password",
        transport: transport
    )
    let trackPath = DaoLiYuAPIProtocol.trackPath(id: "trk_123", fileExtension: "flac")

    await #expect(throws: DaoLiYuServiceError.badServerResponse(404)) {
        try await client.reportPlayback(trackPath: trackPath)
    }
}

private actor DaoLiYuPlaybackReportRecorder {
    struct Report: Sendable {
        let method: String?
        let authorization: String?
        let contentType: String?
        let body: Data?
    }

    private var logins = 0
    private(set) var reports: [Report] = []

    func nextToken() -> String {
        logins += 1
        return "TOKEN-\(logins)"
    }

    /// 第一次上报回 401,模拟令牌过期。
    func recordReport(method: String?, authorization: String?, contentType: String?, body: Data?) -> Int {
        reports.append(Report(method: method, authorization: authorization, contentType: contentType, body: body))
        return reports.count == 1 ? 401 : 204
    }
}

private actor DaoLiYuRequestRecorder {
    private var dataPaths: [String] = []
    private var downloadPaths: [String] = []

    func recordData(_ path: String) {
        dataPaths.append(path)
    }

    func recordDownload(_ path: String) {
        downloadPaths.append(path)
    }

    func snapshot() -> (data: [String], download: [String]) {
        (dataPaths, downloadPaths)
    }
}
