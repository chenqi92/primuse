import Foundation
import PrimuseKit

/// 道理鱼原生 API 的只读整库 connector。
actor DaoLiYuSource: RefreshingMetadataSongConnector, ServerLyricsConnector {
    let sourceID: String

    private static let pageSize = 100
    private let client: DaoLiYuServiceClient
    private let session: URLSession
    private let serverBaseURL: URL?
    private let audioCacheDirectory: URL
    private var connected = false

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        username: String,
        password: String,
        alternateTLSValidationHostname: String? = nil
    ) {
        self.sourceID = sourceID
        self.serverBaseURL = DaoLiYuAPIProtocol.serverBaseURL(
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath
        )
        let configuration = URLSessionConfiguration.ephemeral
        // Shared by catalogue scanning and playback, so size it for a full
        // library walk like the other server sources.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: SmartSSLDelegate(
                redirectPolicy: .sameEndpoint,
                alternateServerTrustHostname: alternateTLSValidationHostname,
                alternateServerTrustEndpoint: NetworkEndpointIdentity(
                    scheme: useSSL ? "https" : "http",
                    host: host,
                    port: port
                )
            ),
            delegateQueue: nil
        )
        self.session = session
        self.client = DaoLiYuServiceClient(
            sourceID: sourceID,
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath,
            username: username,
            password: password,
            transport: DaoLiYuRequestTransport(
                data: { try await TrustedHTTPTransport.data(for: $0, session: session) },
                download: { try await TrustedHTTPTransport.download(for: $0, session: session) }
            )
        )
        let root = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        self.audioCacheDirectory = root
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: audioCacheDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit { session.invalidateAndCancel() }

    func connect() async throws {
        if connected { return }
        do {
            _ = try await client.validateConnection()
            connected = true
            await MainActor.run { SourceAuthAlert.clear(sourceID: sourceID) }
        } catch {
            let message: String
            if let serviceError = error as? DaoLiYuServiceError,
               serviceError == .authenticationFailed || serviceError == .missingCredential {
                message = PMString("error.daoliyu.authenticationFailed")
            } else {
                message = error.localizedDescription
            }
            await MainActor.run {
                SourceAuthAlert.report(sourceID: sourceID, message: message)
            }
            throw error
        }
    }

    func disconnect() async {
        connected = false
        await client.invalidateSession()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return [
            RemoteFileItem(
                name: MusicSourceType.daoliyu.displayName,
                path: "/",
                isDirectory: true,
                size: 0,
                modifiedDate: nil
            ),
        ]
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        try await connect()
        guard let serverBaseURL else {
            throw DaoLiYuServiceError.invalidURL
        }
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    var skip = 0
                    var expectedTotal: Int?
                    var seenIDs: Set<String> = []
                    while true {
                        try Task.checkCancellation()
                        let page = try await self.client.trackPage(
                            skip: skip,
                            take: Self.pageSize
                        )
                        if let expectedTotal, expectedTotal != page.total {
                            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.totalChanged"))
                        }
                        expectedTotal = page.total
                        guard page.skip == skip,
                              page.rawCount == page.tracks.count,
                              page.rawCount <= Self.pageSize else {
                            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.invalidPagePositionOrCount"))
                        }
                        if page.total == 0 {
                            guard skip == 0, page.rawCount == 0 else {
                                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.pageTotalMismatch"))
                            }
                            break
                        }
                        guard page.rawCount > 0, skip <= page.total - page.rawCount else {
                            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.pageEndedEarlyOrExceeded"))
                        }

                        for track in page.tracks {
                            try Task.checkCancellation()
                            guard seenIDs.insert(track.id).inserted else {
                                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.duplicateItem"))
                            }
                            guard let song = track.makeSong(
                                sourceID: self.sourceID,
                                serverBaseURL: serverBaseURL
                            ) else {
                                throw DaoLiYuServiceError.invalidResponse(
                                    PMString("error.catalog.trackMissingFormat", track.title)
                                )
                            }
                            let suffix = track.fileExtension ?? "audio"
                            continuation.yield(
                                ConnectorScannedSong(
                                    song: song,
                                    displayName: "\(track.title).\(suffix)",
                                    titleMetadataInspected: track.hasUsableCatalogTitle
                                )
                            )
                        }

                        skip += page.rawCount
                        if skip == page.total { break }
                        guard page.rawCount == Self.pageSize else {
                            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.incompletePage"))
                        }
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let songs = try await scanSongs(from: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await scanned in songs {
                        continuation.yield(
                            RemoteFileItem(
                                name: scanned.displayName,
                                path: scanned.song.filePath,
                                isDirectory: false,
                                size: scanned.song.fileSize,
                                modifiedDate: scanned.song.lastModified,
                                revision: scanned.song.revision
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func streamingURL(for path: String) async throws -> URL? {
        // 原生 stream 需要 Authorization 头，iOS/macOS 使用 Range/localURL 通道。
        nil
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await connect()
        return try await client.fetchRange(trackPath: path, offset: offset, length: length)
    }

    func localURL(for path: String) async throws -> URL {
        guard DaoLiYuAPIProtocol.trackID(from: path) != nil else {
            throw SourceError.fileNotFound(path)
        }
        let suffix = (path as NSString).pathExtension
        let target = audioCacheDirectory.appendingPathComponent(
            CacheFileNamePolicy.make(
                path: path,
                preferredExtension: suffix.isEmpty ? "bin" : suffix
            )
        )
        if FileManager.default.fileExists(atPath: target.path) { return target }

        try await connect()
        let temporaryURL = try await client.downloadTrack(trackPath: path)
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: temporaryURL)
            return target
        }
        try FileManager.default.moveItem(at: temporaryURL, to: target)
        return target
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let local = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: local)
                    defer { try? handle.close() }
                    while true {
                        try Task.checkCancellation()
                        let data = try handle.read(upToCount: 64 * 1_024) ?? Data()
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    Task.isCancelled
                        ? continuation.finish()
                        : continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func imageURL(for path: String) async throws -> URL? {
        if let url = URL(string: path), url.scheme != nil {
            if let serverBaseURL,
               let rebased = SourceConnectionURLRewriter.rebasedURL(
                for: url,
                onto: serverBaseURL,
                pathMarkers: ["/api/"]
               ) {
                return rebased
            }
            return url
        }
        return serverBaseURL.flatMap {
            DaoLiYuAPIProtocol.coverURL(serverBaseURL: $0, reference: path)
        }
    }

    func fetchServerLyrics(for path: String) async -> String? {
        do {
            try await connect()
            return try await client.preferredLyrics(trackPath: path)
        } catch {
            return nil
        }
    }
}
