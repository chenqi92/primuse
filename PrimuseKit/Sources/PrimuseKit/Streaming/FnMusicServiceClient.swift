import CryptoKit
import Foundation

/// Typed failures from the Feiniu Music catalogue service.
public enum FnMusicServiceError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case invalidURL
    case authenticationFailed
    case badServerResponse(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return PMString("error.fnMusic.missingCredential")
        case .invalidURL:
            return PMString("error.fnMusic.invalidURL")
        case .authenticationFailed:
            return PMString("error.fnMusic.authenticationFailed")
        case .badServerResponse(let status):
            return PMString("error.fnMusic.http", String(status))
        case .invalidResponse(let detail):
            return PMString("error.fnMusic.invalidResponse", detail)
        }
    }
}

public struct FnMusicCatalogPage: Sendable {
    public let tracks: [FnMusicCatalogTrack]
    public let total: Int?
    public let rawCount: Int

    public init(tracks: [FnMusicCatalogTrack], total: Int?, rawCount: Int) {
        self.tracks = tracks
        self.total = total
        self.rawCount = rawCount
    }
}

/// A track returned by `/music/api/v1/track/list`.
public struct FnMusicCatalogTrack: Sendable {
    public let guid: String
    public let title: String
    /// Whether the catalog payload itself supplied a usable semantic title.
    /// A `filename` fallback remains useful for display but does not replace
    /// the bounded file-header title inspection.
    public let hasUsableCatalogTitle: Bool
    public let coverID: String?
    public let year: Int?
    public let discNumber: Int?
    public let trackNumber: Int?
    public let durationMilliseconds: Int?
    public let isCue: Bool
    public let createdAt: Int?
    public let updatedAt: Int?
    public let albumGUID: String?
    public let albumName: String?
    public let albumArtistName: String?
    public let artistGUID: String?
    public let artistNames: [String]
    public let genreNames: [String]
    public let fileExtension: String?
    public let fileSize: Int64
    public let bitRate: Int?
    public let sampleRate: Int?
    public let bitDepth: Int?
    public let cueStartTime: TimeInterval?
    public let cueEndTime: TimeInterval?
    public let cueTrackIndex: Int?

    public init?(json: [String: Any]) {
        guard let guid = fnMusicFirstNonemptyString(
            json,
            keys: ["guid", "id", "trackGUID", "trackGuid", "songId"]
        ) else { return nil }
        self.guid = guid
        let catalogTitle = fnMusicFirstNonemptyString(
            json,
            keys: ["title", "trackTitle", "name"]
        )
        self.title = catalogTitle
            ?? fnMusicNonemptyString(json["filename"])
            ?? "Unknown"
        self.hasUsableCatalogTitle = ServerCatalogMetadataInspectionPolicy.hasUsableTitle(
            catalogTitle
        )
        self.year = fnMusicInt(json["year"])
        self.discNumber = fnMusicInt(json["discNo"])
        self.cueTrackIndex = fnMusicInt(json["trackIndex"])
            ?? fnMusicInt(json["cueTrackIndex"])
        self.trackNumber = fnMusicInt(json["trackNo"]) ?? cueTrackIndex
        self.isCue = fnMusicBool(json["isCue"])
            ?? (fnMusicNonemptyString(json["cueSheet"]) != nil)
        self.createdAt = fnMusicInt(json["createdAt"])
        self.updatedAt = fnMusicInt(json["updatedAt"])
        self.cueStartTime = fnMusicDouble(json["startTime"])
            ?? fnMusicDouble(json["cueStartTime"])
        self.cueEndTime = fnMusicDouble(json["endTime"])
            ?? fnMusicDouble(json["cueEndTime"])

        let album = fnMusicObject(json["album"])
        self.coverID = fnMusicCoverID(json) ?? fnMusicCoverID(album)
        self.albumGUID = fnMusicFirstNonemptyString(album, keys: ["guid", "id"])
            ?? fnMusicFirstNonemptyString(json, keys: ["albumGUID", "albumGuid", "albumId"])
        self.albumName = fnMusicFirstNonemptyString(album, keys: ["name", "title"])
            ?? fnMusicNonemptyString(json["album"])

        let albumArtistObjects = (json["albumArtists"] as? [[String: Any]])
            ?? (album?["artists"] as? [[String: Any]])
            ?? []
        let albumArtistObjectNames = albumArtistObjects.compactMap {
            fnMusicFirstNonemptyString($0, keys: ["name", "title"])
        }
        let albumArtistStrings = (json["albumArtists"] as? [String])?
            .compactMap(fnMusicNonemptyString) ?? []
        let albumArtistObject = fnMusicObject(album?["artist"])
        self.albumArtistName = fnMusicFirstNonemptyString(
            json,
            keys: ["albumArtist", "albumArtistName"]
        )
            ?? fnMusicFirstNonemptyString(album, keys: ["albumArtist", "artistName"])
            ?? fnMusicFirstNonemptyString(albumArtistObject, keys: ["name", "title"])
            ?? fnMusicNonemptyString(album?["artist"])
            ?? (!albumArtistObjectNames.isEmpty ? albumArtistObjectNames.joined(separator: ", ") : nil)
            ?? (!albumArtistStrings.isEmpty ? albumArtistStrings.joined(separator: ", ") : nil)

        let artists = json["artists"] as? [[String: Any]] ?? []
        self.artistGUID = artists.compactMap {
            fnMusicFirstNonemptyString($0, keys: ["guid", "id"])
        }.first ?? fnMusicFirstNonemptyString(
            json,
            keys: ["artistGUID", "artistGuid", "artistId"]
        )
        let objectArtistNames = artists.compactMap {
            fnMusicFirstNonemptyString($0, keys: ["name", "title"])
        }
        let stringArtistNames = (json["artists"] as? [String])?
            .compactMap(fnMusicNonemptyString) ?? []
        let directArtistName = fnMusicNonemptyString(json["artist"])
        self.artistNames = !objectArtistNames.isEmpty
            ? objectArtistNames
            : (!stringArtistNames.isEmpty ? stringArtistNames : directArtistName.map { [$0] } ?? [])

        let genreObjects = json["genres"] as? [[String: Any]] ?? []
        let objectGenreNames = genreObjects.compactMap {
            fnMusicFirstNonemptyString($0, keys: ["name", "title"])
        }
        let stringGenreNames = (json["genres"] as? [String])?
            .compactMap(fnMusicNonemptyString) ?? []
        let directGenreName = fnMusicNonemptyString(json["genre"])
        self.genreNames = !objectGenreNames.isEmpty
            ? objectGenreNames
            : (!stringGenreNames.isEmpty ? stringGenreNames : directGenreName.map { [$0] } ?? [])

        let audio = fnMusicObject(json["audioSpec"])
        let audioDuration = fnMusicInt(audio?["duration"]) ?? 0
        if isCue,
           let cueStartTime,
           let cueEndTime,
           cueEndTime > cueStartTime {
            self.durationMilliseconds = Int(((cueEndTime - cueStartTime) * 1_000).rounded())
        } else {
            self.durationMilliseconds = audioDuration != 0
                ? audioDuration
                : fnMusicInt(json["duration"])
        }
        let audioPathExtension = fnMusicNonemptyString(audio?["path"])
            .flatMap { fnMusicNonemptyString(($0 as NSString).pathExtension) }
        let rootPathExtension = fnMusicNonemptyString(json["path"])
            .flatMap { fnMusicNonemptyString(($0 as NSString).pathExtension) }
        self.fileExtension = [
            fnMusicNonemptyString(audio?["extension"]),
            fnMusicNonemptyString(audio?["format"]),
            fnMusicNonemptyString(audio?["container"]),
            fnMusicNonemptyString(audio?["codec"]),
            fnMusicNonemptyString(json["extension"]),
            fnMusicNonemptyString(json["format"]),
            audioPathExtension,
            rootPathExtension,
        ]
            .lazy
            .compactMap(fnMusicPlayableAudioExtension)
            .first
        self.fileSize = fnMusicInt64(audio?["size"]) ?? fnMusicInt64(json["size"]) ?? 0
        self.bitRate = fnMusicInt(audio?["bitrate"]) ?? fnMusicInt(json["bitrate"])
        self.sampleRate = fnMusicInt(audio?["sampleRate"]) ?? fnMusicInt(json["sampleRate"])
        self.bitDepth = fnMusicInt(audio?["bitDepth"]) ?? fnMusicInt(json["bitDepth"])
    }

    /// Builds the same stable Primuse song record on every platform. The
    /// synthetic path contains only the Feiniu track GUID; it is never treated
    /// as a path in the fnOS filesystem.
    public func makeSong(sourceID: String) -> Song? {
        let suffix = fileExtension ?? ""
        guard let format = AudioFormat.from(fileExtension: suffix) else { return nil }
        let path = FnMusicAPIProtocol.trackPath(guid: guid, fileExtension: suffix)
        let artistName = artistNames.isEmpty ? nil : artistNames.joined(separator: ", ")
        let genreName = genreNames.isEmpty ? nil : genreNames.joined(separator: ", ")
        let revisionTimestamp = updatedAt ?? createdAt
        let coverReference = coverID.map {
            FnMusicAPIProtocol.coverReference(coverID: $0, revision: revisionTimestamp)
        }
        let hasValidCueRange = isCue
            && cueStartTime != nil
            && cueEndTime != nil
            && cueEndTime! > cueStartTime!
        return Song(
            id: Self.hash("\(sourceID):fnmusic:\(guid)"),
            title: title,
            albumID: albumGUID,
            artistID: artistGUID,
            albumTitle: albumName,
            artistName: artistName,
            albumArtistName: AlbumGroupingPolicy.resolvedAlbumArtistName(
                albumArtistName: albumArtistName,
                trackArtistName: artistName
            ),
            trackNumber: trackNumber,
            discNumber: discNumber,
            duration: TimeInterval(durationMilliseconds ?? 0) / 1_000,
            fileFormat: format,
            filePath: path,
            sourceID: sourceID,
            fileSize: fileSize,
            bitRate: bitRate.map { $0 >= 10_000 ? max(1, $0 / 1_000) : $0 },
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            genre: genreName,
            year: year,
            lastModified: Self.date(fromUnixTimestamp: revisionTimestamp),
            dateAdded: Self.date(fromUnixTimestamp: createdAt) ?? Date(),
            coverArtFileName: coverReference,
            cueSheetPath: hasValidCueRange ? "/fnmusic/cue/\(guid).cue" : nil,
            cueStartTime: hasValidCueRange ? cueStartTime : nil,
            cueEndTime: hasValidCueRange ? cueEndTime : nil,
            revision: "fnmusic:\(updatedAt ?? 0):\(fileSize)"
        )
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func date(fromUnixTimestamp value: Int?) -> Date? {
        guard let value, value > 0 else { return nil }
        let seconds = value > 10_000_000_000
            ? TimeInterval(value) / 1_000
            : TimeInterval(value)
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Reusable Feiniu Music catalogue/resource client. It is intentionally
/// separate from NAS/file connectors and only calls `/music/api/v1`.
public actor FnMusicServiceClient {
    private static let maximumAnimatedArtworkBytes =
        ArtworkAnimationLimits.default.maximumCompressedBytes

    private struct LoginOperation {
        let id: UUID
        let generation: UInt64
        let task: Task<String, Error>
    }

    private let sourceID: String
    private let endpointProvider: FnMusicEndpointProvider
    private let username: String
    private let password: String?
    private let accessCode: String?
    private let usesFNConnect: Bool
    private let session: URLSession
    private var token: String?
    private var sessionGeneration: UInt64 = 0
    private var loginOperation: LoginOperation?

    public init(source: MusicSource, credential: SourceCredential?) {
        let credential = credential ?? SourceCredential()
        self.sourceID = source.id
        self.username = credential.username ?? source.username ?? ""
        self.password = credential.password
        self.accessCode = credential.extra[FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey]
        self.usesFNConnect = source.effectiveFnMusicConnectionMode == .fnConnect

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = StreamResolverSessionFactory.make(
            configuration: configuration,
            fnMusicRedirects: true
        )
        self.session = session
        self.endpointProvider = FnMusicEndpointProvider(
            source: source,
            accessCode: accessCode,
            session: session
        )
    }

    /// Module-internal injection point for deterministic URLProtocol tests.
    init(source: MusicSource, credential: SourceCredential?, session: URLSession) {
        let credential = credential ?? SourceCredential()
        self.sourceID = source.id
        self.username = credential.username ?? source.username ?? ""
        self.password = credential.password
        self.accessCode = credential.extra[FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey]
        self.usesFNConnect = source.effectiveFnMusicConnectionMode == .fnConnect
        self.session = session
        self.endpointProvider = FnMusicEndpointProvider(
            source: source,
            accessCode: accessCode,
            session: session
        )
    }

    deinit { session.invalidateAndCancel() }

    public func invalidateSession() async {
        sessionGeneration &+= 1
        token = nil
        loginOperation?.task.cancel()
        loginOperation = nil
        await endpointProvider.invalidate()
    }

    /// Logs in and validates the real music catalogue route. A generic fnOS
    /// management service without the Music app cannot pass this probe.
    public func validateConnection() async throws -> Int? {
        let page = try await trackPage(page: 1, size: 1)
        return page.total
    }

    public func trackPage(page: Int, size: Int) async throws -> FnMusicCatalogPage {
        guard page > 0, size > 0, size <= 500 else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.invalidPagination"))
        }
        let payload = try await authenticatedJSON(
            method: "GET",
            path: "/track/list",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(size)),
                URLQueryItem(name: "sort", value: "createdAt,asc"),
            ]
        )
        guard let dictionary = payload as? [String: Any],
              let rawTracks = dictionary["list"] as? [[String: Any]] else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.missingList"))
        }
        let tracks = rawTracks.compactMap(FnMusicCatalogTrack.init(json:))
        guard tracks.count == rawTracks.count else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.unrecognizedItem"))
        }
        let total = fnMusicInt(dictionary["total"])
        if let total, total < 0 {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.invalidTotal"))
        }
        return FnMusicCatalogPage(tracks: tracks, total: total, rawCount: rawTracks.count)
    }

    public func coverData(
        reference: String,
        size: Int = 640,
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) async throws -> Data {
        guard let coverID = FnMusicAPIProtocol.coverID(from: reference) else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.invalidCoverReference"))
        }
        guard maximumBytes > 0,
              maximumBytes <= Self.maximumAnimatedArtworkBytes else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.coverTooLarge"))
        }
        var queryItems = [
            URLQueryItem(name: "coverId", value: coverID),
            URLQueryItem(name: "size", value: String(max(64, min(size, 2_048)))),
        ]
        if let revision = FnMusicAPIProtocol.coverRevision(from: reference) {
            queryItems.append(URLQueryItem(name: "t", value: String(revision)))
        }
        try await ensureLoggedIn()
        guard let requestToken = token else { throw FnMusicServiceError.authenticationFailed }
        do {
            return try await fetchCoverData(
                queryItems: queryItems,
                token: requestToken,
                maximumBytes: maximumBytes
            )
        } catch FnMusicServiceError.authenticationFailed {
            try await ensureLoggedIn()
            guard let refreshedToken = token else { throw FnMusicServiceError.authenticationFailed }
            return try await fetchCoverData(
                queryItems: queryItems,
                token: refreshedToken,
                maximumBytes: maximumBytes
            )
        } catch {
            guard usesFNConnect, FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            await endpointProvider.invalidate()
            return try await fetchCoverData(
                queryItems: queryItems,
                token: requestToken,
                maximumBytes: maximumBytes
            )
        }
    }

    private func fetchCoverData(
        queryItems: [URLQueryItem],
        token requestToken: String,
        maximumBytes: Int
    ) async throws -> Data {
        let request = try await authenticatedRequest(
            path: "/static/cover",
            queryItems: queryItems,
            token: requestToken
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await StreamResolverHTTPTransport.data(
                for: request,
                session: session,
                maximumBytes: maximumBytes + 1,
                redirectMode: .fnMusic
            )
        } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.coverTooLarge"))
        }
        let http = try validateHTTP(response, requestToken: requestToken)
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > maximumBytes {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.coverTooLarge"))
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.emptyOrOversizedCover"))
        }
        try validateMediaPayload(http, data: data, requestToken: requestToken)
        return data
    }

    public func preferredLyrics(trackPath: String) async throws -> String? {
        guard let trackGUID = FnMusicAPIProtocol.trackGUID(from: trackPath) else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.invalidTrackReference"))
        }
        let payload = try await authenticatedJSON(
            method: "GET",
            path: "/lyric/list",
            queryItems: [URLQueryItem(name: "trackGUID", value: trackGUID)]
        )
        let dictionary = payload as? [String: Any]
        let rawLyrics = dictionary?["list"] as? [[String: Any]]
            ?? payload as? [[String: Any]]
            ?? []
        let preferred = fnMusicNonemptyString(dictionary?["preferred"])
        let lyrics = rawLyrics.compactMap {
            item -> (guid: String, content: String)? in
            guard let content = fnMusicNonemptyString(item["content"])
                    ?? fnMusicNonemptyString(item["text"]) else { return nil }
            return (
                fnMusicNonemptyString(item["guid"])
                    ?? fnMusicNonemptyString(item["id"])
                    ?? "",
                content
            )
        }
        if let preferred {
            return lyrics.first(where: { $0.guid == preferred })?.content
        }
        return lyrics.first?.content
    }

    /// Retry one authenticated API request after the exact 401/403/session
    /// business codes used by Feiniu Music. Rate limits and server failures do
    /// not clear the token and are never turned into misleading login errors.
    private func authenticatedJSON(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Any {
        try await ensureLoggedIn()
        do {
            return try await requestJSON(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body
            )
        } catch FnMusicServiceError.authenticationFailed {
            try await ensureLoggedIn()
            return try await requestJSON(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body
            )
        }
    }

    private func ensureLoggedIn() async throws {
        if token?.isEmpty == false { return }
        if let operation = loginOperation {
            let userToken = try await operation.task.value
            try installLoginToken(userToken, from: operation)
            return
        }
        guard !username.isEmpty, let password, !password.isEmpty else {
            throw FnMusicServiceError.missingCredential
        }

        let generation = sessionGeneration
        let operationID = UUID()
        let task = Task<String, Error> { [self] in
            try await performLogin(password: password, generation: generation)
        }
        let operation = LoginOperation(id: operationID, generation: generation, task: task)
        loginOperation = operation
        do {
            let userToken = try await task.value
            try installLoginToken(userToken, from: operation)
        } catch {
            if loginOperation?.id == operationID {
                loginOperation = nil
            }
            throw error
        }
    }

    private func performLogin(password: String, generation: UInt64) async throws -> String {
        try Task.checkCancellation()
        let payload = try await requestJSON(
            method: "POST",
            path: "/user/password-login",
            body: [
                "username": username,
                "password": FnMusicAPIProtocol.passwordHash(password),
                "deviceId": FnMusicAPIProtocol.deviceID(sourceID: sourceID),
            ],
            includeCookie: false
        )
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        guard let dictionary = payload as? [String: Any],
              let userToken = fnMusicNonemptyString(dictionary["userToken"]) else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.loginMissingUserToken"))
        }
        return userToken
    }

    private func installLoginToken(_ userToken: String, from operation: LoginOperation) throws {
        guard sessionGeneration == operation.generation else { throw CancellationError() }
        if token == userToken { return }
        guard loginOperation?.id == operation.id else { throw CancellationError() }
        token = userToken
        loginOperation = nil
    }

    private func requestJSON(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        includeCookie: Bool = true
    ) async throws -> Any {
        do {
            return try await requestJSONOnce(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                includeCookie: includeCookie
            )
        } catch {
            guard usesFNConnect, FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            await endpointProvider.invalidate()
            return try await requestJSONOnce(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                includeCookie: includeCookie
            )
        }
    }

    private func requestJSONOnce(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: [String: Any]?,
        includeCookie: Bool
    ) async throws -> Any {
        let endpoint = try await endpointProvider.endpoint()
        guard let url = FnMusicAPIProtocol.endpointURL(
                serverBaseURL: endpoint.baseURL,
                path: path,
                queryItems: queryItems
              ) else {
            throw FnMusicServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        let bodyData: Data?
        if let body {
            bodyData = try SafeJSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys]
            )
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            bodyData = nil
        }
        let requestToken = includeCookie ? token : nil
        if let cookie = FnMusicAPIProtocol.authenticationCookie(
            token: requestToken,
            usesRelay: endpoint.usesRelay
        ) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        FnMusicAPIProtocol.applyAuthx(to: &request, bodyData: bodyData)
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session,
            redirectMode: .fnMusic
        )
        _ = try validateHTTP(response, requestToken: requestToken)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = fnMusicInt(envelope["code"]) else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.invalidFnMusicJSON"))
        }
        guard code == 0 || code == 200 else {
            if code == 120001 || code == 401 || code == 403 {
                if includeCookie { invalidateToken(ifMatching: requestToken) }
                throw FnMusicServiceError.authenticationFailed
            }
            let message = fnMusicString(envelope["msg"])
                ?? fnMusicString(envelope["message"])
                ?? PMString("error.catalog.businessError", String(code))
            throw FnMusicServiceError.invalidResponse(message)
        }
        guard let payload = envelope["data"], !(payload is NSNull) else {
            return [String: Any]()
        }
        return payload
    }

    private func authenticatedRequest(
        path: String,
        queryItems: [URLQueryItem],
        token: String
    ) async throws -> URLRequest {
        let endpoint = try await endpointProvider.endpoint()
        guard let url = FnMusicAPIProtocol.endpointURL(
                serverBaseURL: endpoint.baseURL,
                path: path,
                queryItems: queryItems
              ) else {
            throw FnMusicServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        if let cookie = FnMusicAPIProtocol.authenticationCookie(
            token: token,
            usesRelay: endpoint.usesRelay
        ) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        FnMusicAPIProtocol.applyAuthx(to: &request)
        return request
    }

    private func validateHTTP(
        _ response: URLResponse,
        requestToken: String? = nil
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.missingHTTPResponse"))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateToken(ifMatching: requestToken)
            throw FnMusicServiceError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) else {
            throw FnMusicServiceError.badServerResponse(http.statusCode)
        }
        return http
    }

    private func validateMediaPayload(
        _ response: HTTPURLResponse,
        data: Data,
        requestToken: String
    ) throws {
        let mime = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let prefix = String(data: data.prefix(64), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard mime.contains("json") || mime.contains("html")
                || mime.hasPrefix("text/") || prefix.hasPrefix("{") || prefix.hasPrefix("<") else {
            return
        }
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = fnMusicInt(envelope["code"]) {
            if code == 120001 || code == 401 || code == 403 {
                invalidateToken(ifMatching: requestToken)
                throw FnMusicServiceError.authenticationFailed
            }
            let message = fnMusicString(envelope["msg"])
                ?? fnMusicString(envelope["message"])
                ?? PMString("error.catalog.businessError", String(code))
            throw FnMusicServiceError.invalidResponse(PMString("error.catalog.mediaEndpointMessage", message))
        }
        throw FnMusicServiceError.invalidResponse(PMString("error.catalog.mediaEndpointNonMedia"))
    }

    private func invalidateToken(ifMatching requestToken: String?) {
        guard let requestToken, token == requestToken else { return }
        token = nil
    }
}

private func fnMusicNonemptyString(_ value: Any?) -> String? {
    guard let value = fnMusicString(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
}

private func fnMusicFirstNonemptyString(
    _ dictionary: [String: Any]?,
    keys: [String]
) -> String? {
    guard let dictionary else { return nil }
    return keys.lazy.compactMap { fnMusicNonemptyString(dictionary[$0]) }.first
}

private func fnMusicCoverID(_ dictionary: [String: Any]?) -> String? {
    guard let dictionary else { return nil }
    if let direct = fnMusicFirstNonemptyString(
        dictionary,
        keys: ["coverId", "coverID", "coverGuid", "coverGUID"]
    ) {
        return direct
    }
    if let coverURL = fnMusicFirstNonemptyString(
        dictionary,
        keys: ["coverUrl", "coverURL"]
    ), let components = URLComponents(string: coverURL),
       let coverID = components.queryItems?.first(where: { $0.name == "coverId" })?.value,
       let normalized = fnMusicNonemptyString(coverID) {
        return normalized
    }
    return fnMusicFirstNonemptyString(
        fnMusicObject(dictionary["cover"]),
        keys: ["coverId", "guid", "id"]
    )
}

private func fnMusicObject(_ value: Any?) -> [String: Any]? {
    if let dictionary = value as? [String: Any] { return dictionary }
    if let values = value as? [[String: Any]] { return values.first }
    return nil
}

private func fnMusicString(_ value: Any?) -> String? {
    value as? String
}

private func fnMusicInt(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String {
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

private func fnMusicInt64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String {
        return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
}

private func fnMusicDouble(_ value: Any?) -> Double? {
    if let value = value as? Double, value.isFinite { return value }
    if let value = value as? Float, value.isFinite { return Double(value) }
    if let value = value as? NSNumber {
        let number = value.doubleValue
        return number.isFinite ? number : nil
    }
    if let value = value as? String,
       let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
       number.isFinite {
        return number
    }
    return nil
}

/// The 0.9.11 service reports a mixture of filename extensions, container
/// names, codec aliases and MIME-like values. Pick the first value Primuse can
/// actually decode instead of letting an earlier `cue`/`mpeg`/`pcm_*` alias
/// hide a valid container later in the response.
private func fnMusicPlayableAudioExtension(_ rawValue: String?) -> String? {
    guard var value = fnMusicNonemptyString(rawValue)?.lowercased() else { return nil }
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))

    let normalized: String?
    switch value {
    case "", "audio", "cue", "cue-track":
        normalized = nil
    case "mpeg", "audio/mpeg", "audio/mp3":
        normalized = "mp3"
    case "mp4a", "audio/mp4", "audio/m4a":
        normalized = "m4a"
    case "wave", "audio/wav", "audio/wave", "audio/x-wav", "lpcm", "pcm":
        normalized = "wav"
    case let codec where codec.hasPrefix("pcm_"):
        normalized = "wav"
    case "vorbis", "audio/ogg", "application/ogg":
        normalized = "ogg"
    case "audio/opus":
        normalized = "opus"
    case "audio/flac", "x-flac":
        normalized = "flac"
    case "aifc", "audio/aiff", "audio/x-aiff":
        normalized = "aiff"
    case "monkeys-audio", "audio/ape", "audio/x-ape":
        normalized = "ape"
    case "wavpack", "audio/wavpack":
        normalized = "wv"
    default:
        normalized = value
    }
    guard let normalized, AudioFormat.from(fileExtension: normalized) != nil else {
        return nil
    }
    return normalized
}

private func fnMusicBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
        switch value.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }
    return nil
}
