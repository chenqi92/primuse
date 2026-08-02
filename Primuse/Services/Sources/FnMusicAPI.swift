import Foundation
import PrimuseKit

/// Authenticated client for the Feiniu Music app's catalogue and media API.
actor FnMusicAPI {
    private static let maximumArtworkBytes = 8 * 1_024 * 1_024

    private let sourceID: String
    private let baseURL: URL?
    private let session: URLSession
    private(set) var token: String?
    private var sessionGeneration: UInt64 = 0

    var isLoggedIn: Bool { token?.isEmpty == false }

    init(
        sourceID: String,
        host: String,
        port: Int?,
        useSSL: Bool,
        basePath: String?
    ) {
        self.sourceID = sourceID
        self.baseURL = FnMusicAPIProtocol.serverBaseURL(
            host: host,
            port: port,
            useSSL: useSSL,
            basePath: basePath
        )

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0"]
        self.session = URLSession(
            configuration: configuration,
            delegate: SmartSSLDelegate(),
            delegateQueue: nil
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
            includeCookie: false,
            includeServiceHeader: false
        )
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
        guard let object = data as? [String: Any],
              let userToken = stringValue(object["userToken"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !userToken.isEmpty else {
            throw SourceError.connectionFailed("飞牛音乐登录响应缺少 userToken")
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
            throw SourceError.connectionFailed("飞牛音乐曲目列表响应无效")
        }
        let tracks = rawList.compactMap(FnMusicTrack.init(json:))
        guard tracks.count == rawList.count else {
            throw SourceError.connectionFailed("飞牛音乐曲目列表包含无法识别的项目")
        }
        let total = intValue(dictionary["total"])
        if let total, total < 0 {
            throw SourceError.connectionFailed("飞牛音乐曲目总数无效")
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

    func streamURL(trackGUID: String) throws -> URL {
        guard let baseURL,
              let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: baseURL,
            path: "/track/stream",
            queryItems: [URLQueryItem(name: "guid", value: trackGUID)]
        ) else {
            throw SourceError.fileNotFound(trackGUID)
        }
        return url
    }

    func fetchRange(trackGUID: String, offset: Int64, length: Int64) async throws -> FnMusicRangeResponse {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return FnMusicRangeResponse(data: Data(), statusCode: 206)
        }
        let media = try mediaRequest(path: "/track/stream", queryItems: [
            URLQueryItem(name: "guid", value: trackGUID),
        ])
        var request = media.request
        let requestToken = media.token
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        let http = try validateMediaResponse(response, requestToken: requestToken)
        switch http.statusCode {
        case 206:
            let expectedLength = try validatedRangeLength(
                response: http,
                requestedOffset: offset,
                requestedLength: length
            )
            guard expectedLength <= Int64(Int.max) else {
                throw SourceError.connectionFailed("飞牛音乐 Range 响应过大")
            }
            var data = Data()
            data.reserveCapacity(Int(min(expectedLength, 4 * 1_024 * 1_024)))
            for try await byte in bytes {
                if Int64(data.count) >= expectedLength { break }
                data.append(byte)
            }
            guard Int64(data.count) == expectedLength else {
                throw SourceError.connectionFailed("飞牛音乐 Range 响应长度不符")
            }
            return FnMusicRangeResponse(data: data, statusCode: http.statusCode)
        case 200:
            throw SourceError.connectionFailed("飞牛音乐服务器忽略了 Range 请求")
        default:
            throw SourceError.connectionFailed("飞牛音乐 Range HTTP \(http.statusCode)")
        }
    }

    func downloadTrack(trackGUID: String) async throws -> URL {
        let (request, requestToken) = try mediaRequest(path: "/track/stream", queryItems: [
            URLQueryItem(name: "guid", value: trackGUID),
        ])
        let (temporaryURL, response) = try await session.download(for: request)
        do {
            let http = try validateMediaResponse(response, requestToken: requestToken)
            guard http.statusCode == 200 else {
                throw SourceError.connectionFailed("飞牛音乐下载 HTTP \(http.statusCode)")
            }
            let prefix = try readPrefix(from: temporaryURL, maximumLength: 512)
            guard !prefix.isEmpty, !httpMediaResponseLooksLikeErrorBody(http, data: prefix) else {
                invalidateToken(ifMatching: requestToken)
                throw SourceError.authenticationFailed
            }
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func coverData(coverID: String, size: Int = 640, revision: Int? = nil) async throws -> Data {
        var queryItems = [
            URLQueryItem(name: "coverId", value: coverID),
            URLQueryItem(name: "size", value: String(max(64, min(size, 2_048)))),
        ]
        if let revision, revision > 0 {
            queryItems.append(URLQueryItem(name: "t", value: String(revision)))
        }
        let (request, requestToken) = try mediaRequest(path: "/static/cover", queryItems: queryItems)
        let (bytes, response) = try await session.bytes(for: request)
        let http = try validateMediaResponse(response, requestToken: requestToken)
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > Self.maximumArtworkBytes {
            throw SourceError.connectionFailed("飞牛音乐封面文件过大")
        }
        var data = Data()
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > 0 {
            data.reserveCapacity(min(length, Self.maximumArtworkBytes))
        }
        for try await byte in bytes {
            guard data.count < Self.maximumArtworkBytes else {
                throw SourceError.connectionFailed("飞牛音乐封面文件过大")
            }
            data.append(byte)
        }
        guard !data.isEmpty else {
            throw SourceError.connectionFailed("飞牛音乐封面数据为空")
        }
        guard !httpMediaResponseLooksLikeErrorBody(http, data: data) else {
            invalidateToken(ifMatching: requestToken)
            throw SourceError.authenticationFailed
        }
        return data
    }

    private func requestJSON(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        includeCookie: Bool = true,
        cookieToken: String? = nil,
        includeServiceHeader: Bool = true
    ) async throws -> Any {
        guard let baseURL,
              let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: baseURL,
            path: path,
            queryItems: queryItems
        ) else {
            throw SourceError.connectionFailed("飞牛音乐地址无效")
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
        if let requestToken {
            request.setValue(FnMusicAPIProtocol.musicTokenCookie(requestToken), forHTTPHeaderField: "Cookie")
        }
        if includeServiceHeader {
            FnMusicAPIProtocol.applyServiceHeader(to: &request)
        }
        FnMusicAPIProtocol.applyAuthx(to: &request, bodyData: bodyData)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("飞牛音乐无有效 HTTP 响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateToken(ifMatching: requestToken)
            throw SourceError.authenticationFailed
        }
        if http.statusCode == 429 {
            throw SourceError.connectionFailed("飞牛音乐服务限流（HTTP 429）")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed("飞牛音乐 HTTP \(http.statusCode)")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = intValue(envelope["code"]) else {
            throw SourceError.connectionFailed("飞牛音乐返回了无法识别的数据")
        }
        guard code == 0 || code == 200 else {
            if code == 120001 || code == 401 || code == 403 {
                invalidateToken(ifMatching: requestToken)
                throw SourceError.authenticationFailed
            }
            let message = stringValue(envelope["msg"])
                ?? stringValue(envelope["message"])
                ?? "业务错误 \(code)"
            throw SourceError.connectionFailed("飞牛音乐：\(message)")
        }
        guard let payload = envelope["data"], !(payload is NSNull) else {
            return [String: Any]()
        }
        return payload
    }

    private func mediaRequest(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> (request: URLRequest, token: String) {
        guard let requestToken = token else { throw SourceError.authenticationFailed }
        guard let baseURL,
              let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: baseURL,
            path: path,
            queryItems: queryItems
        ) else {
            throw SourceError.connectionFailed("飞牛音乐媒体地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.setValue(FnMusicAPIProtocol.musicTokenCookie(requestToken), forHTTPHeaderField: "Cookie")
        FnMusicAPIProtocol.applyServiceHeader(to: &request)
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
            throw SourceError.connectionFailed("飞牛音乐 Range 响应缺少 Content-Range")
        }
        let unitAndValue = header.split(
            separator: " ",
            maxSplits: 1,
            omittingEmptySubsequences: true
        )
        guard unitAndValue.count == 2,
              unitAndValue[0].lowercased() == "bytes" else {
            throw SourceError.connectionFailed("飞牛音乐 Content-Range 无效")
        }
        let rangeAndTotal = unitAndValue[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1]),
              total > 0 else {
            throw SourceError.connectionFailed("飞牛音乐 Content-Range 总长度无效")
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
            throw SourceError.connectionFailed("飞牛音乐 Content-Range 范围无效")
        }

        let expectedStart: Int64
        let expectedEnd: Int64
        if requestedOffset >= 0 {
            guard requestedOffset < total,
                  let requestedEnd = SafeByteRange.exclusiveEnd(
                    offset: requestedOffset,
                    length: requestedLength
                  ) else {
                throw SourceError.connectionFailed("飞牛音乐 Range 请求无效")
            }
            expectedStart = requestedOffset
            expectedEnd = min(requestedEnd - 1, total - 1)
        } else {
            let suffixLength = requestedOffset == .min ? Int64.max : -requestedOffset
            expectedStart = max(0, total - suffixLength)
            expectedEnd = total - 1
        }
        guard start == expectedStart, end == expectedEnd else {
            throw SourceError.connectionFailed("飞牛音乐 Content-Range 与请求不符")
        }

        let responseLength = end - start + 1
        if let contentLengthValue = response.value(forHTTPHeaderField: "Content-Length") {
            guard let contentLength = Int64(
                contentLengthValue.trimmingCharacters(in: .whitespacesAndNewlines)
            ), contentLength == responseLength else {
                throw SourceError.connectionFailed("飞牛音乐 Range Content-Length 无效")
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
            throw SourceError.connectionFailed("飞牛音乐媒体响应无效")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            invalidateToken(ifMatching: requestToken)
            throw SourceError.authenticationFailed
        }
        if http.statusCode == 429 {
            throw SourceError.connectionFailed("飞牛音乐服务限流（HTTP 429）")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.connectionFailed("飞牛音乐媒体 HTTP \(http.statusCode)")
        }
        return http
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
