import Foundation
import PrimuseKit

/// Authenticated client for the Feiniu Music app's catalogue and media API.
actor FnMusicAPI {
    private static let maximumArtworkBytes = 8 * 1_024 * 1_024

    private let sourceID: String
    private let endpointProvider: FnMusicEndpointProvider
    private let accessCode: String?
    private let usesFNConnect: Bool
    private let session: URLSession
    private(set) var token: String?
    private var sessionGeneration: UInt64 = 0

    var isLoggedIn: Bool { token?.isEmpty == false }

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?,
        connectionMode: FnMusicConnectionMode,
        accessCode: String?,
        alternateTLSValidationHostname: String? = nil,
        session: URLSession? = nil
    ) {
        self.sourceID = sourceID
        self.accessCode = accessCode
        self.usesFNConnect = connectionMode == .fnConnect

        let configuration = URLSessionConfiguration.default
        // Catalogue pages over the public internet outrun a LAN-sized
        // per-request budget; matches the other server sources.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        let session = session ?? URLSession(
            configuration: configuration,
            delegate: SmartSSLDelegate(
                fnMusicRedirects: true,
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
        let source = MusicSource(
            id: sourceID,
            name: MusicSourceType.fnMusic.displayName,
            type: .fnMusic,
            host: host,
            port: port,
            useSsl: useSSL,
            fnMusicConnectionMode: connectionMode,
            basePath: basePath
        )
        self.endpointProvider = FnMusicEndpointProvider(
            source: source,
            accessCode: accessCode,
            session: session,
            dataLoader: { request in
                try await TrustedHTTPTransport.data(for: request, session: session)
            },
            diagnosticLogger: { message in
                plog("\(message) source=\(sourceID.prefix(8))")
            }
        )
    }

    deinit { session.invalidateAndCancel() }

    func prepareConnection() async throws {
        _ = try await endpointProvider.endpoint()
    }

    func login(username: String, password: String) async throws {
        guard !username.isEmpty, !password.isEmpty else {
            throw SourceError.authenticationFailed
        }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        token = nil
        let body: [String: Any] = [
            "username": username,
            "password": FnMusicAPIProtocol.passwordHash(password),
            "deviceId": FnMusicAPIProtocol.deviceID(sourceID: sourceID),
        ]
        let data = try await requestJSON(
            method: "POST",
            path: "/user/password-login",
            body: body,
            includeCookie: false
        )
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        guard let object = data as? [String: Any],
              let userToken = stringValue(object["userToken"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !userToken.isEmpty else {
            throw SourceError.connectionFailed(PMString("error.catalog.loginMissingUserToken"))
        }
        token = userToken
    }

    func cancelPendingLogin() async {
        // A cancelled waiter may arrive just after login committed its token.
        // Keep that established session available to subsequent callers.
        guard token == nil else { return }
        sessionGeneration &+= 1
        await endpointProvider.releaseSession()
    }

    func logout() async {
        let requestToken = token
        sessionGeneration &+= 1
        let generation = sessionGeneration
        token = nil
        if let requestToken {
            _ = try? await requestJSON(
                method: "POST",
                path: "/user/logout",
                body: nil,
                includeCookie: false,
                cookieToken: requestToken
            )
        }
        if sessionGeneration == generation { await endpointProvider.releaseSession() }
    }

    func invalidateSession() {
        sessionGeneration &+= 1
        token = nil
        Task { await endpointProvider.invalidate() }
    }

    func trackPage(page: Int, size: Int) async throws -> FnMusicTrackPage {
        let payload = try await requestJSON(
            method: "GET",
            path: "/track/list",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(size)),
                URLQueryItem(name: "sort", value: "createdAt,asc"),
            ]
        )
        guard let dictionary = payload as? [String: Any],
              let rawList = dictionary["list"] as? [[String: Any]] else {
            throw SourceError.connectionFailed(PMString("error.catalog.missingList"))
        }
        let tracks = rawList.compactMap(FnMusicTrack.init(json:))
        guard tracks.count == rawList.count else {
            throw SourceError.connectionFailed(PMString("error.catalog.unrecognizedItem"))
        }
        let total = intValue(dictionary["total"])
        if let total, total < 0 {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidTotal"))
        }
        return FnMusicTrackPage(tracks: tracks, total: total, rawCount: rawList.count)
    }

    /// `/album/list` 一页就带回一批专辑的 `artists`, 比一张张问详情省得多。
    /// 服务端不认这个端点时由调用方退回 `albumArtistName(albumGUID:)`。
    func albumPage(page: Int, size: Int) async throws -> FnMusicAlbumPage {
        let payload = try await requestJSON(
            method: "GET",
            path: "/album/list",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(size)),
                URLQueryItem(name: "sort", value: "newTrackAddedAt,desc"),
            ]
        )
        guard let dictionary = payload as? [String: Any],
              let rawList = dictionary["list"] as? [[String: Any]] else {
            throw SourceError.connectionFailed(PMString("error.catalog.missingList"))
        }
        let albums = rawList.compactMap { item -> FnMusicAlbumSummary? in
            guard let guid = stringValue(item["guid"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !guid.isEmpty else { return nil }
            return FnMusicAlbumSummary(guid: guid, artistName: Self.artistName(in: item))
        }
        return FnMusicAlbumPage(albums: albums, total: intValue(dictionary["total"]), rawCount: rawList.count)
    }

    /// `/track/list` 的 album 对象只有 guid/name/coverId —— 专辑艺术家只在专辑
    /// 列表和详情的 `artists` 里。少了它, 一张专辑会按每首歌各自的艺术家散成
    /// 多张同名专辑。一张专辑问一次就够, 缓存由调用方持有。
    func albumArtistName(albumGUID: String) async throws -> String? {
        let payload = try await requestJSON(
            method: "GET",
            path: "/album/detail",
            queryItems: [URLQueryItem(name: "guid", value: albumGUID)]
        )
        guard let dictionary = payload as? [String: Any] else { return nil }
        return Self.artistName(in: dictionary)
    }

    /// 专辑对象的 `artists[].name`, 多位时按曲目艺术家同样的写法连接。
    private static func artistName(in album: [String: Any]) -> String? {
        let names = (album["artists"] as? [[String: Any]] ?? [])
            .compactMap { stringValue($0["name"])?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    func preferredLyrics(trackGUID: String) async throws -> String? {
        let payload = try await requestJSON(
            method: "GET",
            path: "/lyric/list",
            queryItems: [URLQueryItem(name: "trackGUID", value: trackGUID)]
        )
        let dictionary = payload as? [String: Any]
        let rawLyrics = dictionary?["list"] as? [[String: Any]]
            ?? payload as? [[String: Any]]
            ?? []
        let preferred = stringValue(dictionary?["preferred"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lyrics = rawLyrics.compactMap { item -> (String, String)? in
            guard let content = (stringValue(item["content"]) ?? stringValue(item["text"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { return nil }
            return (stringValue(item["guid"]) ?? stringValue(item["id"]) ?? "", content)
        }
        if let preferred, !preferred.isEmpty {
            return lyrics.first(where: { $0.0 == preferred })?.1
        }
        return lyrics.first?.1
    }

    func libraryPayload(_ request: FnMusicLibraryRequest) async throws -> Data {
        let payload = try await requestJSON(
            method: request.method, path: request.path, queryItems: request.queryItems,
            body: request.body?.mapValues { $0 as Any }
        )
        return try SafeJSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
    }

    func reportPlayback(trackGUID: String) async throws {
        _ = try await requestJSON(
            method: "POST",
            path: "/event/report",
            body: [
                "events": [[
                    "eventType": "track_play",
                    "occurredAt": Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down)),
                    "payload": ["trackGUID": trackGUID],
                ]],
            ]
        )
    }

    func streamURL(trackGUID: String) async throws -> URL {
        do {
            return try await streamURLOnce(trackGUID: trackGUID)
        } catch {
            try Task.checkCancellation()
            guard usesFNConnect, FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            await endpointProvider.invalidate()
            return try await streamURLOnce(trackGUID: trackGUID)
        }
    }

    private func streamURLOnce(trackGUID: String) async throws -> URL {
        let endpoint = try await endpointProvider.endpoint()
        guard let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: endpoint.baseURL,
            path: "/track/stream",
            queryItems: [URLQueryItem(name: "guid", value: trackGUID)]
        ) else {
            throw SourceError.fileNotFound(trackGUID)
        }
        return url
    }

    func fetchRange(trackGUID: String, offset: Int64, length: Int64) async throws -> FnMusicRangeResponse {
        do {
            return try await fetchRangeOnce(trackGUID: trackGUID, offset: offset, length: length)
        } catch {
            guard usesFNConnect, FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            await endpointProvider.invalidate()
            return try await fetchRangeOnce(trackGUID: trackGUID, offset: offset, length: length)
        }
    }

    private func fetchRangeOnce(
        trackGUID: String,
        offset: Int64,
        length: Int64
    ) async throws -> FnMusicRangeResponse {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return FnMusicRangeResponse(data: Data(), statusCode: 206)
        }
        let media = try await mediaRequest(path: "/track/stream", queryItems: [
            URLQueryItem(name: "guid", value: trackGUID),
        ])
        var request = media.request
        let requestToken = media.token
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        let requestedBytes = Int(clamping: max(length, 0))
        let responseLimit = requestedBytes > Int.max - 64 * 1_024
            ? Int.max
            : requestedBytes + 64 * 1_024
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: session,
            maxBytes: max(PlainHTTPClient.defaultMaxBytes, responseLimit)
        )
        let http = try validateMediaResponse(response, requestToken: requestToken)
        switch http.statusCode {
        case 206:
            let expectedLength = try validatedRangeLength(
                response: http,
                requestedOffset: offset,
                requestedLength: length
            )
            guard expectedLength <= Int64(Int.max) else {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
            }
            guard Int64(data.count) == expectedLength else {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
            }
            return FnMusicRangeResponse(data: data, statusCode: http.statusCode)
        case 200:
            try validateMediaPayload(http, data: data, requestToken: requestToken)
            throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
        default:
            throw SourceError.connectionFailed(PMString("error.fnMusic.http", String(http.statusCode)))
        }
    }

    func downloadTrack(trackGUID: String) async throws -> URL {
        do {
            return try await downloadTrackOnce(trackGUID: trackGUID)
        } catch {
            guard usesFNConnect, FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            await endpointProvider.invalidate()
            return try await downloadTrackOnce(trackGUID: trackGUID)
        }
    }

    private func downloadTrackOnce(trackGUID: String) async throws -> URL {
        let (request, requestToken) = try await mediaRequest(path: "/track/stream", queryItems: [
            URLQueryItem(name: "guid", value: trackGUID),
        ])
        let (temporaryURL, response) = try await TrustedHTTPTransport.download(
            for: request,
            session: session
        )
        do {
            let http = try validateMediaResponse(response, requestToken: requestToken)
            guard http.statusCode == 200 else {
                throw SourceError.connectionFailed(PMString("error.fnMusic.http", String(http.statusCode)))
            }
            let prefix = try readPrefix(from: temporaryURL, maximumLength: 512)
            guard !prefix.isEmpty else {
                throw SourceError.connectionFailed(PMString("error.catalog.mediaEndpointNonMedia"))
            }
            try validateMediaPayload(http, data: prefix, requestToken: requestToken)
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func coverData(coverID: String, size: Int = 640, revision: Int? = nil) async throws -> Data {
        do {
            return try await coverDataOnce(coverID: coverID, size: size, revision: revision)
        } catch {
            guard usesFNConnect, FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            await endpointProvider.invalidate()
            return try await coverDataOnce(coverID: coverID, size: size, revision: revision)
        }
    }

    private func coverDataOnce(coverID: String, size: Int, revision: Int?) async throws -> Data {
        var queryItems = [
            URLQueryItem(name: "coverId", value: coverID),
            URLQueryItem(name: "size", value: String(max(64, min(size, 2_048)))),
        ]
        if let revision, revision > 0 {
            queryItems.append(URLQueryItem(name: "t", value: String(revision)))
        }
        let (request, requestToken) = try await mediaRequest(path: "/static/cover", queryItems: queryItems)
        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: session,
            maxBytes: Self.maximumArtworkBytes + 64 * 1_024
        )
        let http = try validateMediaResponse(response, requestToken: requestToken)
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > Self.maximumArtworkBytes {
            throw SourceError.connectionFailed(PMString("error.catalog.coverTooLarge"))
        }
        guard data.count <= Self.maximumArtworkBytes else {
            throw SourceError.connectionFailed(PMString("error.catalog.coverTooLarge"))
        }
        guard !data.isEmpty else {
            throw SourceError.connectionFailed(PMString("error.catalog.emptyOrOversizedCover"))
        }
        try validateMediaPayload(http, data: data, requestToken: requestToken)
        return data
    }

    private func requestJSON(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        includeCookie: Bool = true,
        cookieToken: String? = nil
    ) async throws -> Any {
        do {
            return try await requestJSONOnce(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                includeCookie: includeCookie,
                cookieToken: cookieToken
            )
        } catch {
            try Task.checkCancellation()
            guard usesFNConnect, FnMusicAPIProtocol.isRouteFailure(error) else { throw error }
            await endpointProvider.invalidate()
            return try await requestJSONOnce(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body,
                includeCookie: includeCookie,
                cookieToken: cookieToken
            )
        }
    }

    private func requestJSONOnce(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        body: [String: Any]?,
        includeCookie: Bool,
        cookieToken: String?
    ) async throws -> Any {
        let endpoint = try await endpointProvider.endpoint()
        try Task.checkCancellation()
        guard let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: endpoint.baseURL,
            path: path,
            queryItems: queryItems
        ) else {
            throw SourceError.connectionFailed(PMString("error.fnMusic.invalidURL"))
        }
        let bodyData = try body.map {
            try SafeJSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let requestToken = cookieToken ?? (includeCookie ? token : nil)
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

        let requestID = UUID().uuidString.prefix(8)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let context = "FN Music request=\(requestID) path=\(path) route=\(endpoint.route.rawValue) source=\(sourceID.prefix(8))"
        plog("\(context) event=start")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await TrustedHTTPTransport.data(for: request, session: session)
        } catch {
            let failure = error as NSError
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            plog("\(context) event=failed error=\(failure.domain)/\(failure.code) cancelled=\(Task.isCancelled || OperationCancellationPolicy.isCancellation(error)) elapsed_ms=\(elapsed)")
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let diagnosticEnvelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = intValue(diagnosticEnvelope?["code"]).map(String.init) ?? "none"
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        plog("\(context) event=response status=\(status) code=\(code) elapsed_ms=\(elapsed)")
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed(PMString("error.catalog.missingHTTPResponse"))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateToken(ifMatching: requestToken)
            throw SourceError.authenticationFailed
        }
        if http.statusCode == 429 {
            throw SourceError.connectionFailed(PMString("error.fnMusic.http", "429"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed(PMString("error.fnMusic.http", String(http.statusCode)))
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = intValue(envelope["code"]) else {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidFnMusicJSON"))
        }
        guard code == 0 || code == 200 else {
            // 99999 与 120001 都表示会话已失效, 只认后者会让 token 过期后
            // 一直重试却不重新登录。120002 是账号被停用, 重登也没有用。
            if code == 99999 || code == 120001 || code == 401 || code == 403 {
                invalidateToken(ifMatching: requestToken)
                throw SourceError.authenticationFailed
            }
            let message = stringValue(envelope["msg"])
                ?? stringValue(envelope["message"])
                ?? PMString("error.catalog.businessError", String(code))
            throw SourceError.connectionFailed(PMString("error.catalog.mediaEndpointMessage", message))
        }
        guard let payload = envelope["data"], !(payload is NSNull) else {
            return [String: Any]()
        }
        return payload
    }

    private func mediaRequest(
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> (request: URLRequest, token: String) {
        guard let requestToken = token else { throw SourceError.authenticationFailed }
        let endpoint = try await endpointProvider.endpoint()
        guard let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: endpoint.baseURL,
            path: path,
            queryItems: queryItems
        ) else {
            throw SourceError.connectionFailed(PMString("error.fnMusic.invalidURL"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        if let cookie = FnMusicAPIProtocol.authenticationCookie(
            token: requestToken,
            usesRelay: endpoint.usesRelay
        ) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        FnMusicAPIProtocol.applyAuthx(to: &request)
        return (request, requestToken)
    }

    private func validatedRangeLength(
        response: HTTPURLResponse,
        requestedOffset: Int64,
        requestedLength: Int64
    ) throws -> Int64 {
        guard requestedLength > 0,
              let header = response.value(forHTTPHeaderField: "Content-Range") else {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
        }
        let unitAndValue = header.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard unitAndValue.count == 2,
              unitAndValue[0].lowercased() == "bytes" else {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
        }
        let rangeAndTotal = unitAndValue[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]),
              total > 0 else {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
        }
        let bounds = rangeAndTotal[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              end < total else {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
        }

        let expectedStart: Int64
        let expectedEnd: Int64
        if requestedOffset >= 0 {
            guard requestedOffset < total,
                  let requestedEnd = SafeByteRange.exclusiveEnd(
                    offset: requestedOffset,
                    length: requestedLength
                  ) else {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
            }
            expectedStart = requestedOffset
            expectedEnd = min(requestedEnd - 1, total - 1)
        } else {
            let suffixLength = requestedOffset == .min ? Int64.max : -requestedOffset
            expectedStart = max(0, total - suffixLength)
            expectedEnd = total - 1
        }
        guard start == expectedStart, end == expectedEnd else {
            throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
        }

        let responseLength = end - start + 1
        if let contentLengthValue = response.value(forHTTPHeaderField: "Content-Length") {
            guard let contentLength = Int64(
                contentLengthValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ), contentLength == responseLength else {
                throw SourceError.connectionFailed(PMString("error.catalog.invalidRangeResponse"))
            }
        }
        return requestedOffset < 0 ? min(responseLength, requestedLength) : responseLength
    }

    private func readPrefix(from url: URL, maximumLength: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maximumLength) ?? Data()
    }

    private func validateMediaResponse(
        _ response: URLResponse,
        requestToken: String
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed(PMString("error.catalog.mediaEndpointNonMedia"))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateToken(ifMatching: requestToken)
            throw SourceError.authenticationFailed
        }
        if http.statusCode == 429 {
            throw SourceError.connectionFailed(PMString("error.fnMusic.http", "429"))
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed(PMString("error.fnMusic.http", String(http.statusCode)))
        }
        return http
    }

    private func validateMediaPayload(
        _ response: HTTPURLResponse,
        data: Data,
        requestToken: String
    ) throws {
        guard httpMediaResponseLooksLikeErrorBody(response, data: data) else { return }
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = intValue(envelope["code"]) {
            plog("FN Music media response source=\(sourceID.prefix(8)) status=\(response.statusCode) code=\(code)")
            if code == 120001 || code == 401 || code == 403 {
                invalidateToken(ifMatching: requestToken)
                throw SourceError.authenticationFailed
            }
            let message = stringValue(envelope["msg"])
                ?? stringValue(envelope["message"])
                ?? PMString("error.catalog.businessError", String(code))
            throw SourceError.connectionFailed(PMString("error.catalog.mediaEndpointMessage", message))
        }
        throw SourceError.connectionFailed(PMString("error.catalog.mediaEndpointNonMedia"))
    }

    private func invalidateToken(ifMatching requestToken: String?) {
        guard let requestToken, token == requestToken else { return }
        sessionGeneration &+= 1
        token = nil
    }
}

struct FnMusicAlbumSummary: Sendable {
    let guid: String
    let artistName: String?
}

struct FnMusicAlbumPage: Sendable {
    let albums: [FnMusicAlbumSummary]
    let total: Int?
    let rawCount: Int
}

typealias FnMusicTrackPage = FnMusicCatalogPage
typealias FnMusicTrack = FnMusicCatalogTrack

struct FnMusicRangeResponse: Sendable {
    let data: Data
    let statusCode: Int
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    return nil
}

private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

extension FnMusicAPI {
    /// The native editor accepts a complete metadata object, including entity
    /// IDs. Always obtain those IDs from fresh server data before changing it.
    func updateTrackMetadata(original: Song, updated: Song, fields: Set<TagMetadataWritebackField>) async throws -> MediaServerWritebackResult {
        guard let guid = FnMusicAPIProtocol.trackGUID(from: original.filePath),
              original.sourceID == sourceID, updated.sourceID == sourceID,
              original.filePath == updated.filePath else { throw SourceError.fileNotFound(original.filePath) }
        let current = try await editableTrack(guid: guid)
        var writable = fields
        var result = MediaServerWritebackResult()
        let originalArtists = try entityIDs(current["artists"])
        let originalGenres = try entityIDs(current["genres"])
        let album = current["album"] as? [String: Any]
        var body: [String: Any] = [
            "guid": guid, "title": stringValue(current["title"]) ?? "",
            "album": stringValue(album?["name"]) ?? "",
            "artistGUIDs": originalArtists, "genreGUIDs": originalGenres,
            "year": intValue(current["year"]).map { $0 as Any } ?? NSNull(),
            "trackNo": intValue(current["trackNo"]).map { $0 as Any } ?? NSNull(),
            "discNo": intValue(current["discNo"]).map { $0 as Any } ?? NSNull(),
        ]
        if let albumID = stringValue(album?["guid"]), !albumID.isEmpty { body["albumGUID"] = albumID }
        if let cover = stringValue(current["coverId"]), !cover.isEmpty {
            body["coverId"] = cover
            let prefixes = ["track_", "album_", "artist_", "playlist_"]
            body["coverGUID"] = prefixes.first(where: { cover.hasPrefix($0) }).map { String(cover.dropFirst($0.count)) } ?? cover
        }
        if fields.contains(.title) { body["title"] = updated.title }
        if fields.contains(.year) { body["year"] = updated.year.map { $0 as Any } ?? NSNull() }
        if fields.contains(.trackNumber) { body["trackNo"] = updated.trackNumber.map { $0 as Any } ?? NSNull() }
        if fields.contains(.discNumber) { body["discNo"] = updated.discNumber.map { $0 as Any } ?? NSNull() }
        if fields.contains(.album) {
            let name = (updated.albumTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            body["album"] = name
            body.removeValue(forKey: "albumGUID")
            if !name.isEmpty {
                let albums = try await metadataEntities(path: "/album/list-all")
                if let existing = try uniqueEntity(named: name, in: albums) { body["albumGUID"] = existing }
            }
        }
        if fields.contains(.genre) {
            let name = (updated.genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { body["genreGUIDs"] = [String]() }
            else if let genreID = try await metadataGenreID(named: name) { body["genreGUIDs"] = [genreID] }
            else {
                writable.remove(.genre)
                let detail = String(localized: "metadata_writeback_error_unsupported")
                result.unsupported.append(detail)
                result.fieldResults.append(TagMetadataFieldWritebackResult(field: .genre, disposition: .unsupported(detail)))
            }
        }
        if fields.contains(.artist) {
            let name = (updated.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { body["artistGUIDs"] = [String]() }
            else {
                let artists = try await metadataEntities(path: "/artist/list-all")
                let artistID: String
                if let existing = try uniqueEntity(named: name, in: artists) { artistID = existing }
                else {
                    // Creation is not idempotent. A lost reply must not cause
                    // an automatic replay through another FN Connect route.
                    let created = try await requestJSONOnce(method: "POST", path: "/artist/create", queryItems: [],
                        body: ["name": name, "coverId": NSNull()], includeCookie: true, cookieToken: nil)
                    guard let entity = created as? [String: Any], let id = stringValue(entity["guid"]), !id.isEmpty else {
                        throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
                    }
                    artistID = id
                }
                body["artistGUIDs"] = [artistID]
            }
        }
        guard !writable.isEmpty else { return result }
        try Task.checkCancellation()
        _ = try await requestJSONOnce(method: "POST", path: "/track/metadata", queryItems: [], body: body, includeCookie: true, cookieToken: nil)
        let readback = try await editableTrack(guid: guid)
        let readbackAlbum = readback["album"] as? [String: Any]
        for field in writable {
            let matches: Bool
            switch field {
            case .title: matches = stringValue(readback["title"]) == body["title"] as? String
            case .artist:
                matches = Set(try entityIDs(readback["artists"])) == Set(body["artistGUIDs"] as? [String] ?? [])
                    && entityNames(readback["artists"]) == [(updated.artistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
            case .album:
                matches = (stringValue(readbackAlbum?["name"]) ?? "") == body["album"] as? String
                    && ((body["albumGUID"] as? String).map { stringValue(readbackAlbum?["guid"]) == $0 } ?? true)
            case .genre:
                matches = Set(try entityIDs(readback["genres"])) == Set(body["genreGUIDs"] as? [String] ?? [])
                    && entityNames(readback["genres"]) == [(updated.genre ?? "").trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
            case .year: matches = intValue(readback["year"]) == intValue(body["year"])
            case .trackNumber: matches = intValue(readback["trackNo"]) == intValue(body["trackNo"])
            case .discNumber: matches = intValue(readback["discNo"]) == intValue(body["discNo"])
            case .cover: matches = false
            }
            let detail = String(localized: "metadata_writeback_media_readback_mismatch")
            result.fieldResults.append(TagMetadataFieldWritebackResult(field: field, disposition: matches ? .written : .failed(detail)))
            if matches { result.metadataWritten = true }
            else if !result.errors.contains(detail) { result.errors.append(detail) }
        }
        return result
    }

    private func editableTrack(guid: String) async throws -> [String: Any] {
        let payload = try await requestJSON(method: "GET", path: "/track/metadata", queryItems: [URLQueryItem(name: "guid", value: guid)])
        guard let data = payload as? [String: Any], let track = data["track"] as? [String: Any],
              stringValue(track["guid"]) == guid, track["title"] is String else {
            throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
        }
        return track
    }

    private func metadataEntities(path: String) async throws -> [[String: Any]] {
        let payload = try await requestJSON(method: "GET", path: path)
        guard let data = payload as? [String: Any], let list = data["list"] as? [[String: Any]] else {
            throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
        }
        return list
    }

    private func entityIDs(_ value: Any?) throws -> [String] {
        guard let entities = value as? [[String: Any]] else {
            throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
        }
        return try entities.map {
            guard let id = stringValue($0["guid"]), !id.isEmpty else {
                throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
            }
            return id
        }
    }

    private func entityNames(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { stringValue($0["name"]) }
    }

    private func uniqueEntity(named name: String, in entities: [[String: Any]]) throws -> String? {
        let matches = entities.filter { stringValue($0["name"]) == name }
        guard matches.count <= 1 else { throw EmbeddedMetadataWritebackSourceError.conflict }
        guard let match = matches.first else { return nil }
        guard let guid = stringValue(match["guid"]), !guid.isEmpty else {
            throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
        }
        return guid
    }

    private func metadataGenreID(named name: String) async throws -> String? {
        var genres: [[String: Any]] = []
        for page in 1...100 {
            let payload = try await requestJSON(method: "GET", path: "/genre/list", queryItems: [
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "200"),
            ])
            guard let data = payload as? [String: Any], let list = data["list"] as? [[String: Any]] else {
                throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
            }
            genres.append(contentsOf: list)
            if list.count < 200 || intValue(data["total"]).map({ genres.count >= $0 }) == true {
                return try uniqueEntity(named: name, in: genres)
            }
        }
        throw SourceError.connectionFailed(String(localized: "metadata_writeback_error_invalid_state"))
    }
}
