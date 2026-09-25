import Foundation

public enum SongloftServiceError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential, invalidURL, authenticationFailed, invalidResponse
    case badServerResponse(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: PMString("error.songloft.missingCredential")
        case .invalidURL: PMString("error.songloft.invalidURL")
        case .authenticationFailed: PMString("error.songloft.authenticationFailed")
        case .invalidResponse: PMString("error.songloft.invalidResponse")
        case .badServerResponse(let status): PMString("error.songloft.http", String(status))
        }
    }
}

public struct SongloftRequestTransport: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias DownloadLoader = @Sendable (URLRequest) async throws -> (URL, URLResponse)
    let data: DataLoader
    let download: DownloadLoader

    public init(data: @escaping DataLoader, download: @escaping DownloadLoader) {
        self.data = data
        self.download = download
    }
}

public actor SongloftServiceClient {
    private struct Tokens: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
    }
    private struct Session: Sendable {
        let tokens: Tokens
        var expiresAt: Date
    }
    private struct IDList: Decodable, Sendable {
        let ids: [Int64]?
        let total: Int
        func validated() throws -> [Int64] {
            let values = ids ?? []
            guard total >= 0, values.count == total, Set(values).count == total,
                  values.allSatisfy({ $0 > 0 }) else { throw SongloftServiceError.invalidResponse }
            return values
        }
    }
    private struct PlaylistPage: Decodable, Sendable {
        let playlists: [SongloftPlaylist]?
        let total: Int
        let offset: Int
        let limit: Int
    }
    private struct Lyrics: Decodable, Sendable {
        let lyric: String?
        let tlyric: String?
        let rlyric: String?
        let lxlyric: String?
    }

    public let baseURL: URL?
    private let username: String
    private let password: String?
    private let transport: SongloftRequestTransport
    private let ownedSession: URLSession?
    private var session: Session?
    private var authTask: (id: UUID, task: Task<Session, Error>)?
    private var sessionGeneration = UUID()
    /// Set by a whole-library `catalog()` walk that saw the library move.
    private var catalogDriftObserved = false
    private static let maximumCatalogTracks = 10_000_000

    /// Whether a whole-library `catalog()` walk since the last call saw the
    /// library move. Such a walk may add and update songs but must not prune.
    public func takeCatalogDriftObservation() -> Bool {
        defer { catalogDriftObserved = false }
        return catalogDriftObserved
    }

    public init(source: MusicSource, credential: SourceCredential?, transport: SongloftRequestTransport? = nil) {
        baseURL = SongloftAPIProtocol.serverBaseURL(
            host: source.host ?? "", port: source.port, useSSL: source.useSsl, basePath: source.basePath
        )
        username = credential?.username ?? source.username ?? ""
        password = credential?.password
        if let transport {
            self.transport = transport
            ownedSession = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 600
            configuration.httpMaximumConnectionsPerHost = 4
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            let session = StreamResolverSessionFactory.make(configuration: configuration)
            self.transport = SongloftRequestTransport(
                data: { try await StreamResolverHTTPTransport.data(for: $0, session: session) },
                download: { try await StreamResolverHTTPTransport.download(for: $0, session: session) }
            )
            ownedSession = session
        }
    }

    deinit { ownedSession?.invalidateAndCancel() }

    public func invalidateSession() {
        sessionGeneration = UUID()
        authTask?.task.cancel()
        authTask = nil
        session = nil
    }

    public func validateConnection() async throws -> Int {
        let page = try await trackPage(offset: 0, limit: 1)
        var validation = SongloftCatalogPagination()
        _ = try validation.accept(page, requestedLimit: 1)
        return page.total
    }

    public func trackPage(offset: Int, limit: Int = SongloftAPIProtocol.pageSize, keyword: String? = nil, type: String? = nil) async throws -> SongloftTrackPage {
        guard offset >= 0, limit > 0, limit <= 100_000 else { throw SongloftServiceError.invalidResponse }
        var query = Self.catalogQuery + [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let keyword, !keyword.isEmpty { query.append(URLQueryItem(name: "keyword", value: keyword)) }
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        return try await json(path: "/songs", query: query)
    }

    public func track(id: Int64) async throws -> SongloftTrack {
        guard id > 0 else { throw SongloftServiceError.invalidResponse }
        let result: SongloftTrack = try await json(path: "/songs/\(id)")
        guard result.id == id else { throw SongloftServiceError.invalidResponse }
        return result
    }

    public func catalog(type: String? = nil) -> AsyncThrowingStream<SongloftTrack, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let expected = try await self.catalogIDs(type: type)
                    var pagination = SongloftCatalogPagination()
                    while true {
                        try Task.checkCancellation()
                        let page = try await self.trackPage(offset: pagination.offset, type: type)
                        let outcome = try pagination.accept(page, requestedLimit: SongloftAPIProtocol.pageSize)
                        for track in outcome.tracks {
                            try Task.checkCancellation()
                            continuation.yield(track)
                        }
                        if outcome.finished { break }
                        guard pagination.offset <= Self.maximumCatalogTracks else {
                            throw SongloftServiceError.invalidResponse
                        }
                    }
                    // The id listings before and after bracket the walk: a
                    // walk that does not match both read a moving library.
                    let closingIDs = try await self.catalogIDs(type: type)
                    let moved = pagination.driftObserved
                        || pagination.admittedIDs != expected
                        || closingIDs != expected
                    if moved, type == nil { self.catalogDriftObserved = true }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    private static let catalogQuery = [
        URLQueryItem(name: "sort", value: "id"),
        URLQueryItem(name: "order", value: "asc"),
        // Hidden playlists must not silently remove otherwise valid songs from a whole-library scan.
        URLQueryItem(name: "exclude_playlist_labels", value: "none"),
    ]

    private func catalogIDs(type: String?) async throws -> [Int64] {
        let query = Self.catalogQuery + (type.map { [URLQueryItem(name: "type", value: $0)] } ?? [])
        let result: IDList = try await json(path: "/songs/ids", query: query)
        let ids = try result.validated()
        guard ids == ids.sorted() else { throw SongloftServiceError.invalidResponse }
        return ids
    }

    public func playlists() async throws -> [SongloftPlaylist] {
        let first = try await playlistSnapshot()
        guard try await playlistSnapshot() == first else { throw SongloftServiceError.invalidResponse }
        return first
    }

    private func playlistSnapshot() async throws -> [SongloftPlaylist] {
        var values: [SongloftPlaylist] = []
        var expectedTotal: Int?
        var seen: Set<Int64> = []
        while true {
            try Task.checkCancellation()
            let page: PlaylistPage = try await json(path: "/playlists", query: [
                URLQueryItem(name: "offset", value: String(values.count)),
                URLQueryItem(name: "limit", value: String(SongloftAPIProtocol.pageSize)),
                URLQueryItem(name: "type", value: "normal"),
            ])
            let items = page.playlists ?? []
            guard page.total >= 0, page.offset == values.count, page.limit == SongloftAPIProtocol.pageSize,
                  expectedTotal == nil || expectedTotal == page.total,
                  items.count <= SongloftAPIProtocol.pageSize, items.count <= page.total - values.count else {
                throw SongloftServiceError.invalidResponse
            }
            expectedTotal = page.total
            for item in items {
                guard item.id > 0, item.songCount >= 0, seen.insert(item.id).inserted else {
                    throw SongloftServiceError.invalidResponse
                }
            }
            values.append(contentsOf: items)
            if values.count == page.total { return values }
            guard items.count == SongloftAPIProtocol.pageSize else { throw SongloftServiceError.invalidResponse }
        }
    }

    public func playlistSongIDs(id: Int64, expectedCount: Int? = nil) async throws -> [Int64] {
        guard id > 0 else { throw SongloftServiceError.invalidResponse }
        let result: IDList = try await json(path: "/playlists/\(id)/song-ids", query: [
            URLQueryItem(name: "sort", value: "position"), URLQueryItem(name: "order", value: "asc"),
        ])
        let ids = try result.validated()
        guard expectedCount == nil || expectedCount == ids.count else { throw SongloftServiceError.invalidResponse }
        return ids
    }

    public func favorites() async throws -> [Int64] {
        let playlist: SongloftPlaylist = try await json(path: "/playlists/1")
        guard playlist.isFavorite else { throw SongloftServiceError.invalidResponse }
        return try await playlistSongIDs(id: playlist.id, expectedCount: playlist.songCount)
    }

    public func setFavorite(id: Int64, isFavorite: Bool) async throws -> [Int64] {
        guard id > 0 else { throw SongloftServiceError.invalidResponse }
        let existing = try await favorites()
        if existing.contains(id) != isFavorite {
            _ = try await data(
                path: isFavorite ? "/playlists/1/songs" : "/playlists/1/songs/\(id)",
                method: isFavorite ? "POST" : "DELETE",
                body: isFavorite ? JSONEncoder().encode(["song_ids": [id]]) : nil
            )
        }
        let confirmed = try await favorites()
        guard confirmed.contains(id) == isFavorite else { throw SongloftServiceError.invalidResponse }
        return confirmed
    }

    public func preferredLyrics(trackPath: String) async throws -> String? {
        guard let id = SongloftAPIProtocol.trackID(from: trackPath) else { throw SongloftServiceError.invalidResponse }
        do {
            let value: Lyrics = try await json(path: "/songs/\(id)/lyric")
            let wordLyrics = value.lxlyric.flatMap { text in
                LyricsContentParser.parse(text).contains { $0.syllables?.isEmpty == false } ? text : nil
            }
            let candidates = [wordLyrics, value.lyric, value.rlyric, value.tlyric]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard let primary = candidates.first else { return nil }
            var lines = LyricsContentParser.parseText(primary)
            for index in lines.indices { lines[index].id = "songloft:\(id):\(index)" }
            if let translation = value.tlyric, translation != primary {
                let translations = LyricsContentParser.parse(translation)
                for index in lines.indices where lines[index].isSynchronized {
                    if let paired = translations.first(where: { abs($0.timestamp - lines[index].timestamp) < 0.02 }) {
                        lines[index].manualTranslation = LyricManualTranslation(
                            id: "songloft:\(id):translation:\(index)", text: paired.text, source: .embeddedField)
                    }
                }
            }
            if let romanization = value.rlyric, romanization != primary {
                // A romanized track reads the original out loud; it matches no
                // target language, so it must not be offered as a translation.
                let romanized = LyricsContentParser.parse(romanization)
                for index in lines.indices where lines[index].isSynchronized {
                    if let paired = romanized.first(where: { abs($0.timestamp - lines[index].timestamp) < 0.02 }) {
                        lines[index].romanization = paired.text
                    }
                }
            }
            return try SourceLyricsDocument.encode(lines)
        } catch SongloftServiceError.badServerResponse(404) { return nil }
    }

    public func reportPlayback(trackPath: String, submission: Bool) async throws {
        guard let id = SongloftAPIProtocol.trackID(from: trackPath) else { throw SongloftServiceError.invalidResponse }
        _ = try await data(path: "/songs/\(id)/played", method: "POST", query: [
            URLQueryItem(name: "type", value: submission ? "finish" : "play"),
            URLQueryItem(name: "source", value: "primuse"),
        ])
    }

    private static let originalAudioQuery = [URLQueryItem(name: "normalize", value: "0")]

    public func fetchRange(trackPath: String, offset: Int64, length: Int64) async throws -> Data {
        guard let id = SongloftAPIProtocol.trackID(from: trackPath), length > 0,
              length <= Int64(Int.max) else { throw SongloftServiceError.invalidResponse }
        let range: String
        if offset < 0 { range = "bytes=-\(length)" }
        else {
            guard let end = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                throw SongloftServiceError.invalidResponse
            }
            range = "bytes=\(offset)-\(end - 1)"
        }
        let (body, response) = try await data(path: "/songs/\(id)/play", query: Self.originalAudioQuery,
            headers: ["Range": range, "Accept-Encoding": "identity"])
        guard response.statusCode == 206,
              HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: response.value(forHTTPHeaderField: "Content-Range"),
                contentLength: response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: body.count, requestedOffset: offset, requestedLength: length
              ) != nil else { throw SongloftServiceError.invalidResponse }
        return body
    }

    public func downloadTrack(trackPath: String) async throws -> URL {
        guard let id = SongloftAPIProtocol.trackID(from: trackPath) else { throw SongloftServiceError.invalidResponse }
        return try await download(path: "/songs/\(id)/play", query: Self.originalAudioQuery, audio: true)
    }

    public func artworkData(reference: String, maximumBytes: Int) async throws -> Data? {
        guard maximumBytes > 0, let path = SongloftAPIProtocol.coverEndpoint(reference: reference) else {
            throw SongloftServiceError.invalidResponse
        }
        do {
            let file = try await download(path: path)
            defer { try? FileManager.default.removeItem(at: file) }
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size > 0, size <= maximumBytes else { throw SongloftServiceError.invalidResponse }
            return try Data(contentsOf: file)
        } catch SongloftServiceError.badServerResponse(404) { return nil }
    }

    public func resolvedStream(trackPath: String) async throws -> ResolvedStream {
        guard let id = SongloftAPIProtocol.trackID(from: trackPath) else { throw SongloftServiceError.invalidResponse }
        // A HEAD request checks both authentication and item availability without counting byte probes as plays.
        _ = try await data(path: "/songs/\(id)/play", method: "HEAD", query: Self.originalAudioQuery)
        let request = try await request(path: "/songs/\(id)/play", query: Self.originalAudioQuery)
        return ResolvedStream(url: request.url!, headers: ["Authorization": request.value(forHTTPHeaderField: "Authorization")!])
    }

    public func radioURL(id: Int64) async throws -> URL {
        let item = try await track(id: id)
        guard item.isRadio else { throw SongloftServiceError.invalidResponse }
        let token = try await accessToken()
        guard let baseURL, let url = SongloftAPIProtocol.endpoint(baseURL: baseURL,
            path: "/songs/\(id)/play\(item.usesHLS ? ".m3u8" : "")", query: [
                URLQueryItem(name: "access_token", value: token),
            ]) else { throw SongloftServiceError.invalidURL }
        return url
    }

    public func libraryRoot() async throws -> String? {
        struct FolderRoot: Decodable, Sendable { let musicPath: String? }
        do {
            let root: FolderRoot = try await json(path: "/songs/folders")
            return root.musicPath
        } catch SongloftServiceError.badServerResponse(400) { return nil }
        catch SongloftServiceError.badServerResponse(404) { return nil }
    }

    private func json<T: Decodable & Sendable>(path: String, query: [URLQueryItem] = []) async throws -> T {
        let (body, _) = try await data(path: path, query: query)
        do { return try SongloftAPIProtocol.decoder().decode(T.self, from: body) }
        catch { throw SongloftServiceError.invalidResponse }
    }

    private func data(path: String, method: String = "GET", query: [URLQueryItem] = [],
                      headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0...1 {
            var request = try await request(path: path, query: query)
            request.httpMethod = method
            request.httpBody = body
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let (body, response) = try await transport.data(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SongloftServiceError.invalidResponse }
            if http.statusCode == 401, attempt == 0 {
                expireRejectedSession(request)
                continue
            }
            try Self.validate(http)
            return (body, http)
        }
        throw SongloftServiceError.authenticationFailed
    }

    private func download(path: String, query: [URLQueryItem] = [], audio: Bool = false) async throws -> URL {
        for attempt in 0...1 {
            var request = try await request(path: path, query: query)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (file, response) = try await transport.download(request)
            do {
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw SongloftServiceError.invalidResponse }
                if http.statusCode == 401, attempt == 0 {
                    expireRejectedSession(request)
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                try Self.validate(http)
                let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard http.statusCode == 200, size > 0,
                      http.expectedContentLength < 0 || http.expectedContentLength == Int64(size) else {
                    throw SongloftServiceError.invalidResponse
                }
                let mime = http.mimeType?.lowercased() ?? ""
                if audio && (mime.contains("json") || mime.contains("html") || mime.contains("mpegurl")) {
                    throw SongloftServiceError.invalidResponse
                }
                return file
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }
        throw SongloftServiceError.authenticationFailed
    }

    private func request(path: String, query: [URLQueryItem]) async throws -> URLRequest {
        let token = try await accessToken()
        guard let baseURL, let url = SongloftAPIProtocol.endpoint(baseURL: baseURL, path: path, query: query) else {
            throw SongloftServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func expireRejectedSession(_ request: URLRequest) {
        // A late 401 from an old request must not invalidate another request's refreshed session.
        if let session, request.value(forHTTPHeaderField: "Authorization") == "Bearer \(session.tokens.accessToken)" {
            self.session?.expiresAt = .distantPast
        }
    }

    private func accessToken() async throws -> String {
        try Task.checkCancellation()
        if let session, session.expiresAt.timeIntervalSinceNow > 30 { return session.tokens.accessToken }
        let generation = sessionGeneration
        let pending: (id: UUID, task: Task<Session, Error>)
        if let authTask { pending = authTask }
        else {
            let refresh = session?.tokens.refreshToken
            pending = (UUID(), Task { try await self.authenticate(refreshToken: refresh) })
            authTask = pending
        }
        do {
            let value = try await pending.task.value
            // Invalidating a source while login is in flight must never resurrect its session.
            guard generation == sessionGeneration else { throw CancellationError() }
            if authTask?.id == pending.id { session = value; authTask = nil }
            guard let session else { throw CancellationError() }
            try Task.checkCancellation()
            return session.tokens.accessToken
        } catch {
            if authTask?.id == pending.id { authTask = nil }
            throw error
        }
    }

    private func authenticate(refreshToken: String?) async throws -> Session {
        if let refreshToken {
            do { return try await authenticate(path: "/auth/refresh", body: ["refresh_token": refreshToken]) }
            catch SongloftServiceError.authenticationFailed { /* A revoked refresh token requires a new login. */ }
        }
        guard !username.isEmpty, let password, !password.isEmpty else { throw SongloftServiceError.missingCredential }
        return try await authenticate(path: "/auth/login", body: ["username": username, "password": password])
    }

    private func authenticate(path: String, body: [String: String]) async throws -> Session {
        guard let baseURL, let url = SongloftAPIProtocol.endpoint(baseURL: baseURL, path: path) else {
            throw SongloftServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Primuse/1.0", forHTTPHeaderField: "User-Agent")
        let (body, response) = try await transport.data(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SongloftServiceError.invalidResponse }
        try Self.validate(http)
        guard let tokens = try? SongloftAPIProtocol.decoder().decode(Tokens.self, from: body),
              !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
              tokens.expiresIn.isFinite, tokens.expiresIn > 0 else { throw SongloftServiceError.invalidResponse }
        return Session(tokens: tokens, expiresAt: Date().addingTimeInterval(tokens.expiresIn))
    }

    private static func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 { throw SongloftServiceError.authenticationFailed }
        guard (200...299).contains(response.statusCode) else { throw SongloftServiceError.badServerResponse(response.statusCode) }
    }
}
