import CryptoKit
import Foundation

public enum DaoLiYuServiceError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case invalidURL
    case authenticationFailed
    case badServerResponse(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return PMString("error.daoliyu.missingCredential")
        case .invalidURL:
            return PMString("error.daoliyu.invalidURL")
        case .authenticationFailed:
            return PMString("error.daoliyu.authenticationFailed")
        case .badServerResponse(let status):
            return PMString("error.daoliyu.http", String(status))
        case .invalidResponse(let detail):
            return PMString("error.daoliyu.invalidResponse", detail)
        }
    }
}

public struct DaoLiYuCatalogPage: Sendable {
    public let tracks: [DaoLiYuCatalogTrack]
    public let total: Int
    public let skip: Int
    public let take: Int
    public let rawCount: Int

    public init(tracks: [DaoLiYuCatalogTrack], total: Int, skip: Int, take: Int, rawCount: Int) {
        self.tracks = tracks
        self.total = total
        self.skip = skip
        self.take = take
        self.rawCount = rawCount
    }
}

public struct DaoLiYuCatalogTrack: Sendable {
    public let id: String
    public let title: String
    public let hasUsableCatalogTitle: Bool
    public let albumID: String?
    public let albumTitle: String?
    public let artistID: String?
    public let artistName: String?
    public let albumArtist: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let durationSeconds: Double
    public let fileExtension: String?
    public let fileSize: Int64
    public let bitRate: Int?
    public let sampleRate: Int?
    public let bitDepth: Int?
    public let genre: String?
    public let year: Int?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let coverReference: String?
    public let synchronizedLyrics: String?
    public let plainLyrics: String?

    public init?(json: [String: Any]) {
        guard let id = daoLiYuNonemptyString(json["id"]) else { return nil }
        self.id = id
        let catalogTitle = daoLiYuNonemptyString(json["title"])
        self.title = catalogTitle ?? "Unknown"
        self.hasUsableCatalogTitle = ServerCatalogMetadataInspectionPolicy.hasUsableTitle(
            catalogTitle
        )

        let album = json["album"] as? [String: Any]
        let artist = json["artist"] as? [String: Any]
        let artists = json["artists"] as? [[String: Any]] ?? []
        self.albumID = daoLiYuNonemptyString(json["albumId"])
            ?? daoLiYuNonemptyString(album?["id"])
        self.albumTitle = daoLiYuNonemptyString(json["albumTitle"])
            ?? daoLiYuNonemptyString(album?["title"])
        self.artistID = daoLiYuNonemptyString(json["artistId"])
            ?? daoLiYuNonemptyString(artist?["id"])
            ?? artists.compactMap { daoLiYuNonemptyString($0["id"]) }.first
        let explicitArtist = daoLiYuNonemptyString(json["artistName"])
            ?? daoLiYuNonemptyString(json["artistLabel"])
            ?? daoLiYuNonemptyString(artist?["name"])
        let artistNames = artists.compactMap { daoLiYuNonemptyString($0["name"]) }
        self.artistName = explicitArtist ?? (artistNames.isEmpty ? nil : artistNames.joined(separator: ", "))
        self.albumArtist = daoLiYuNonemptyString(json["albumArtist"])
            ?? daoLiYuNonemptyString(album?["albumArtist"])

        self.trackNumber = daoLiYuInt(json["trackNumber"]) ?? daoLiYuInt(json["track"])
        self.discNumber = daoLiYuInt(json["discNumber"]) ?? daoLiYuInt(json["disc"])
        self.durationSeconds = daoLiYuDouble(json["durationSeconds"])
            ?? daoLiYuDouble(json["duration"])
            ?? 0

        let rawFilePath = daoLiYuNonemptyString(json["filePath"])
        let pathExtension = rawFilePath.map { ($0 as NSString).pathExtension }
        self.fileExtension = [
            daoLiYuNonemptyString(json["fileFormat"]),
            daoLiYuNonemptyString(json["detectedContainer"]),
            pathExtension,
        ]
        .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() }
        .first(where: { !$0.isEmpty })
        self.fileSize = daoLiYuInt64(json["fileSize"]) ?? 0
        self.bitRate = daoLiYuInt(json["bitrate"])
        self.sampleRate = daoLiYuInt(json["sampleRate"])
        self.bitDepth = daoLiYuInt(json["bitDepth"])
        self.year = daoLiYuInt(json["year"])

        let genres = json["genres"] as? [Any] ?? []
        let genreNames = genres.compactMap { value -> String? in
            if let string = value as? String { return daoLiYuNonemptyString(string) }
            return daoLiYuNonemptyString((value as? [String: Any])?["name"])
        }
        self.genre = daoLiYuNonemptyString(json["genre"])
            ?? (genreNames.isEmpty ? nil : genreNames.joined(separator: ", "))
        self.createdAt = Self.parseDate(json["createdAt"])
        self.updatedAt = Self.parseDate(json["updatedAt"])

        self.coverReference = [
            daoLiYuNonemptyString(json["coverArtUrl"]),
            daoLiYuNonemptyString(json["coverArtPath"]),
            daoLiYuNonemptyString(album?["coverArtUrl"]),
            daoLiYuNonemptyString(album?["coverArtPath"]),
        ].compactMap { $0 }.first
        self.synchronizedLyrics = Self.lyricsText(json["lyricsSync"])
        self.plainLyrics = Self.lyricsText(json["lyrics"])
    }

    public func makeSong(sourceID: String, serverBaseURL: URL) -> Song? {
        let suffix = fileExtension ?? ""
        guard let format = AudioFormat.from(fileExtension: suffix) else { return nil }
        let path = DaoLiYuAPIProtocol.trackPath(id: id, fileExtension: suffix)
        let revisionDate = updatedAt ?? createdAt
        let coverURL = DaoLiYuAPIProtocol.coverURL(
            serverBaseURL: serverBaseURL,
            reference: coverReference
        )
        return Song(
            id: Self.hash("\(sourceID):daoliyu:\(id)"),
            title: title,
            albumID: albumID,
            artistID: artistID,
            albumTitle: albumTitle,
            artistName: artistName ?? albumArtist,
            albumArtistName: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: albumArtist,
                trackArtistName: artistName
            ),
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: durationSeconds,
            fileFormat: format,
            filePath: path,
            sourceID: sourceID,
            fileSize: fileSize,
            bitRate: bitRate,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            genre: genre,
            year: year,
            lastModified: revisionDate,
            dateAdded: createdAt ?? Date(),
            coverArtFileName: coverURL?.absoluteString,
            revision: "daoliyu:\(Self.revisionValue(revisionDate)):\(fileSize)"
        )
    }

    private static func lyricsText(_ value: Any?) -> String? {
        if let text = daoLiYuNonemptyString(value) { return text }
        guard let dictionary = value as? [String: Any] else { return nil }
        return daoLiYuNonemptyString(dictionary["content"])
            ?? daoLiYuNonemptyString(dictionary["text"])
            ?? daoLiYuNonemptyString(dictionary["lrc"])
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let seconds = daoLiYuDouble(value), seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let string = daoLiYuNonemptyString(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func revisionValue(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Injectable request transport so application targets can apply their own
/// certificate and explicitly-approved cleartext policies without duplicating
/// the DaoLiYu protocol implementation.
public struct DaoLiYuRequestTransport: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias DownloadLoader = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    private let dataLoader: DataLoader
    private let downloadLoader: DownloadLoader

    public init(
        data: @escaping DataLoader,
        download: @escaping DownloadLoader
    ) {
        self.dataLoader = data
        self.downloadLoader = download
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await dataLoader(request)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await downloadLoader(request)
    }

    static func urlSession(_ session: URLSession) -> Self {
        Self(
            data: {
                try await StreamResolverHTTPTransport.data(
                    for: $0,
                    session: session
                )
            },
            download: {
                try await StreamResolverHTTPTransport.download(
                    for: $0,
                    session: session
                )
            }
        )
    }
}

/// 道理鱼曲库、歌词和媒体流共用的原生 API 客户端。
public actor DaoLiYuServiceClient {
    private let sourceID: String
    public let baseURL: URL?
    private let username: String
    private let password: String?
    private let transport: DaoLiYuRequestTransport
    private let ownedSession: URLSession?
    private var token: String?

    public init(
        source: MusicSource,
        credential: SourceCredential?,
        transport: DaoLiYuRequestTransport? = nil
    ) {
        let credential = credential ?? SourceCredential()
        self.sourceID = source.id
        self.baseURL = DaoLiYuAPIProtocol.serverBaseURL(
            host: source.host ?? "",
            port: source.port,
            useSSL: source.useSsl,
            basePath: source.basePath
        )
        self.username = credential.username ?? source.username ?? ""
        self.password = credential.password
        if let transport {
            self.transport = transport
            self.ownedSession = nil
        } else {
            let session = Self.makeSession()
            self.transport = .urlSession(session)
            self.ownedSession = session
        }
    }

    public init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        username: String,
        password: String,
        transport: DaoLiYuRequestTransport? = nil
    ) {
        self.sourceID = sourceID
        self.baseURL = DaoLiYuAPIProtocol.serverBaseURL(
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath
        )
        self.username = username
        self.password = password
        if let transport {
            self.transport = transport
            self.ownedSession = nil
        } else {
            let session = Self.makeSession()
            self.transport = .urlSession(session)
            self.ownedSession = session
        }
    }

    deinit { ownedSession?.invalidateAndCancel() }

    public func invalidateSession() {
        token = nil
    }

    public func validateConnection() async throws -> Int {
        try await trackPage(skip: 0, take: 1).total
    }

    public func trackPage(skip: Int, take: Int) async throws -> DaoLiYuCatalogPage {
        guard skip >= 0, take > 0, take <= 500 else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.invalidPagination"))
        }
        let payload = try await authorizedJSON(
            path: "/tracks",
            queryItems: [
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "take", value: String(take)),
            ]
        )
        guard let dictionary = payload as? [String: Any],
              let rawTracks = dictionary["items"] as? [[String: Any]],
              let total = daoLiYuInt(dictionary["total"]), total >= 0 else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.missingItemsOrTotal"))
        }
        let tracks = rawTracks.compactMap(DaoLiYuCatalogTrack.init(json:))
        guard tracks.count == rawTracks.count else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.unrecognizedItem"))
        }
        return DaoLiYuCatalogPage(
            tracks: tracks,
            total: total,
            skip: daoLiYuInt(dictionary["skip"]) ?? skip,
            take: daoLiYuInt(dictionary["take"]) ?? take,
            rawCount: rawTracks.count
        )
    }

    public func track(id: String) async throws -> DaoLiYuCatalogTrack {
        let payload = try await authorizedJSON(
            path: "/tracks/\(Self.encodedPathComponent(id))"
        )
        let raw = (payload as? [String: Any])?["track"] as? [String: Any]
            ?? payload as? [String: Any]
        guard let raw, let track = DaoLiYuCatalogTrack(json: raw) else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.unrecognizedTrackDetails"))
        }
        return track
    }

    public func preferredLyrics(trackPath: String) async throws -> String? {
        guard let id = DaoLiYuAPIProtocol.trackID(from: trackPath) else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.invalidTrackReference"))
        }
        let detail = try await track(id: id)
        return detail.synchronizedLyrics ?? detail.plainLyrics
    }

    public func fetchRange(trackPath: String, offset: Int64, length: Int64) async throws -> Data {
        guard length > 0,
              length <= Int64(Int.max),
              let id = DaoLiYuAPIProtocol.trackID(from: trackPath) else { return Data() }
        let rangeValue: String
        if offset < 0 {
            rangeValue = "bytes=-\(length)"
        } else {
            guard let exclusiveEnd = SafeByteRange.exclusiveEnd(offset: offset, length: length) else {
                return Data()
            }
            rangeValue = "bytes=\(offset)-\(exclusiveEnd - 1)"
        }

        for attempt in 0...1 {
            let request = try await authenticatedRequest(
                path: "/tracks/\(Self.encodedPathComponent(id))/download",
                headers: [
                    "Range": rangeValue,
                    "Accept-Encoding": "identity",
                ]
            )
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if Self.isAuthenticationFailure(http.statusCode), attempt == 0 {
                token = nil
                continue
            }
            if Self.isAuthenticationFailure(http.statusCode) {
                token = nil
                throw DaoLiYuServiceError.authenticationFailed
            }
            guard http.statusCode == 206 else {
                throw DaoLiYuServiceError.badServerResponse(http.statusCode)
            }
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.invalidRangeResponse"))
            }
            return data
        }
        throw DaoLiYuServiceError.authenticationFailed
    }

    public func downloadTrack(trackPath: String) async throws -> URL {
        guard let id = DaoLiYuAPIProtocol.trackID(from: trackPath) else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.invalidTrackReference"))
        }
        for attempt in 0...1 {
            let request = try await authenticatedRequest(
                path: "/tracks/\(Self.encodedPathComponent(id))/download"
            )
            let (temporaryURL, response) = try await transport.download(for: request)
            guard let http = response as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if Self.isAuthenticationFailure(http.statusCode), attempt == 0 {
                token = nil
                try? FileManager.default.removeItem(at: temporaryURL)
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                if Self.isAuthenticationFailure(http.statusCode) {
                    token = nil
                    throw DaoLiYuServiceError.authenticationFailed
                }
                throw DaoLiYuServiceError.badServerResponse(http.statusCode)
            }
            return temporaryURL
        }
        throw DaoLiYuServiceError.authenticationFailed
    }

    /// 为 tvOS 返回经过真实两字节 Range 探测的 URL 与播放头。
    public func resolvedStream(trackPath: String) async throws -> ResolvedStream {
        _ = try await fetchRange(trackPath: trackPath, offset: 0, length: 2)
        guard let baseURL,
              let id = DaoLiYuAPIProtocol.trackID(from: trackPath),
              let url = DaoLiYuAPIProtocol.streamURL(serverBaseURL: baseURL, trackID: id),
              let token else {
            throw DaoLiYuServiceError.invalidURL
        }
        return ResolvedStream(url: url, headers: ["Authorization": "Bearer \(token)"])
    }

    private func authorizedJSON(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> Any {
        for attempt in 0...1 {
            let request = try await authenticatedRequest(path: path, queryItems: queryItems)
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
            }
            if Self.isAuthenticationFailure(http.statusCode), attempt == 0 {
                token = nil
                continue
            }
            if Self.isAuthenticationFailure(http.statusCode) {
                token = nil
                throw DaoLiYuServiceError.authenticationFailed
            }
            guard (200...299).contains(http.statusCode) else {
                throw DaoLiYuServiceError.badServerResponse(http.statusCode)
            }
            do {
                return try JSONSerialization.jsonObject(with: data)
            } catch {
                throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.responseNotJSON"))
            }
        }
        throw DaoLiYuServiceError.authenticationFailed
    }

    private func authenticatedRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:]
    ) async throws -> URLRequest {
        try await ensureLoggedIn()
        guard let baseURL,
              let url = DaoLiYuAPIProtocol.endpointURL(
                serverBaseURL: baseURL,
                path: path,
                queryItems: queryItems
              ), let token else {
            throw DaoLiYuServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private func ensureLoggedIn() async throws {
        if token?.isEmpty == false { return }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let password, !password.isEmpty else {
            throw DaoLiYuServiceError.missingCredential
        }
        guard let baseURL,
              let url = DaoLiYuAPIProtocol.endpointURL(
                serverBaseURL: baseURL,
                path: "/auth/login"
              ) else {
            throw DaoLiYuServiceError.invalidURL
        }
        let body = try JSONSerialization.data(
            withJSONObject: [
                "email": username,
                "username": username,
                "password": password,
            ],
            options: [.sortedKeys]
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.loginMissingHTTPResponse"))
        }
        if Self.isAuthenticationFailure(http.statusCode) {
            throw DaoLiYuServiceError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw DaoLiYuServiceError.badServerResponse(http.statusCode)
        }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = daoLiYuNonemptyString(dictionary["token"]) else {
            throw DaoLiYuServiceError.invalidResponse(PMString("error.catalog.loginMissingToken"))
        }
        token = value
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return StreamResolverSessionFactory.make(configuration: configuration)
    }

    private static func isAuthenticationFailure(_ statusCode: Int) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private func daoLiYuNonemptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func daoLiYuInt(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

private func daoLiYuInt64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

private func daoLiYuDouble(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}
