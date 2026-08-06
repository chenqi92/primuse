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
        accessCode: String?
    ) {
        self.sourceID = sourceID
        self.accessCode = accessCode
        self.usesFNConnect = connectionMode == .fnConnect

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        let session = URLSession(
            configuration: configuration,
            delegate: SmartSSLDelegate(fnMusicRedirects: true),
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
            }
        )
    }

    deinit { session.invalidateAndCancel() }

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

    func logout() async {
        let requestToken = token
        sessionGeneration &+= 1
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

        let (data, response) = try await TrustedHTTPTransport.data(
            for: request,
            session: session
        )
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
            if code == 120001 || code == 401 || code == 403 {
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
