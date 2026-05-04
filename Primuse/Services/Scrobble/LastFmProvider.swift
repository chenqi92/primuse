import Foundation
import CryptoKit
import PrimuseKit

/// Last.fm scrobble provider。需要 API key + secret (在 Last.fm 注册 application
/// 拿) + 用户的 sessionKey (走 web auth flow 之后存 Keychain)。
///
/// API doc: https://www.last.fm/api
///
/// 当前 v1 占位实现 — apiKey/apiSecret 还没填, validateCredentials 会返
/// false 让 settings UI 提示"未配置"。后续注册 Last.fm app 拿到 key 填进
/// AppSecrets 即可启用。Web auth flow 入口 (`makeAuthURL`) 也已经准备好。
struct LastFmProvider: ScrobbleProvider {
    let id: ScrobbleProviderID = .lastFm

    /// API key/secret 由 Primuse 应用持有 (注册一次, 所有用户共用)。
    /// 现在为空 — 等申请到再填。
    let apiKey: String
    let apiSecret: String
    /// 用户授权后拿到的永久 sessionKey (存 Keychain)。
    let sessionKey: String

    private let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    func validateCredentials() async -> Bool? {
        guard !apiKey.isEmpty, !apiSecret.isEmpty, !sessionKey.isEmpty else {
            return false
        }
        // user.getInfo 不需要 write 权限, 用作存活检查比较安全。
        let params: [String: String] = [
            "method": "user.getInfo",
            "api_key": apiKey,
            "sk": sessionKey,
            "format": "json"
        ]
        do {
            let (_, response) = try await call(method: "GET", params: params, signed: false)
            return response.statusCode == 200
        } catch {
            return nil
        }
    }

    func sendNowPlaying(_ entry: ScrobbleEntry) async throws {
        guard !apiKey.isEmpty else { throw ScrobbleError.notConfigured }
        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "artist": entry.artist,
            "track": entry.title,
            "api_key": apiKey,
            "sk": sessionKey
        ]
        if let album = entry.album { params["album"] = album }
        if let dur = entry.durationSec { params["duration"] = String(dur) }
        if let n = entry.trackNumber { params["trackNumber"] = String(n) }
        try await callSigned(method: "POST", params: params)
    }

    func submitListens(_ entries: [ScrobbleEntry]) async throws {
        guard !apiKey.isEmpty else { throw ScrobbleError.notConfigured }
        // Last.fm 一次请求最多 50 条 — 上层 ScrobbleQueue 应该已经分批,
        // 这里再 enforce 一遍防止意外超限被服务端 reject 整批。
        for batch in entries.chunked(by: 50) {
            var params: [String: String] = [
                "method": "track.scrobble",
                "api_key": apiKey,
                "sk": sessionKey
            ]
            for (i, e) in batch.enumerated() {
                params["artist[\(i)]"] = e.artist
                params["track[\(i)]"] = e.title
                params["timestamp[\(i)]"] = String(e.startedAt)
                if let album = e.album { params["album[\(i)]"] = album }
                if let dur = e.durationSec { params["duration[\(i)]"] = String(dur) }
                if let n = e.trackNumber { params["trackNumber[\(i)]"] = String(n) }
            }
            try await callSigned(method: "POST", params: params)
        }
    }

    /// Web auth URL — 引导用户去 Last.fm 授权, 授权后回调到 cb URL 带 token。
    /// 然后用 auth.getSession 把 token 换 sessionKey 存 Keychain。
    static func makeAuthURL(apiKey: String, callback: URL) -> URL? {
        guard !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "cb", value: callback.absoluteString)
        ]
        return components?.url
    }

    /// Web auth 回调拿到 token 后调用, 把 token 换成永久 sessionKey。
    static func exchangeToken(token: String, apiKey: String, apiSecret: String) async throws -> String {
        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": apiKey,
            "token": token,
            "format": "json"
        ]
        let signed = sign(params: params, secret: apiSecret)
        let provider = LastFmProvider(apiKey: apiKey, apiSecret: apiSecret, sessionKey: "")
        let (data, response) = try await provider.call(method: "GET", params: signed, signed: false)
        guard response.statusCode == 200 else {
            throw ScrobbleError.http(response.statusCode, String(data: data, encoding: .utf8))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let session = json?["session"] as? [String: Any],
              let key = session["key"] as? String else {
            throw ScrobbleError.invalidResponse
        }
        return key
    }

    // MARK: - Internal HTTP

    /// Last.fm write 操作 (POST) 必须带 api_sig 签名 + format=json。
    private func callSigned(method: String, params: [String: String]) async throws {
        var p = params
        p["api_sig"] = Self.sign(params: p, secret: apiSecret)["api_sig"]
        p["format"] = "json"
        let (data, response) = try await call(method: method, params: p, signed: true)
        guard 200..<300 ~= response.statusCode else {
            switch response.statusCode {
            case 401, 403: throw ScrobbleError.invalidCredentials
            case 429: throw ScrobbleError.rateLimited
            default: throw ScrobbleError.http(response.statusCode, String(data: data, encoding: .utf8))
            }
        }
    }

    private func call(method: String, params: [String: String], signed: Bool) async throws -> (Data, HTTPURLResponse) {
        var request: URLRequest
        if method == "GET" {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            request = URLRequest(url: components.url!)
        } else {
            request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            let body = params
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
                .joined(separator: "&")
            request.httpBody = body.data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ScrobbleError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw ScrobbleError.invalidResponse }
        return (data, http)
    }

    /// Last.fm api_sig 算法: 把 params (除 format/callback) 按 key 字母序拼接
    /// "key1value1key2value2..." + apiSecret, 取 MD5 hex。
    static func sign(params: [String: String], secret: String) -> [String: String] {
        let exclude: Set<String> = ["format", "callback"]
        let sorted = params.filter { !exclude.contains($0.key) }.sorted { $0.key < $1.key }
        let str = sorted.map { "\($0.key)\($0.value)" }.joined() + secret
        let hash = Insecure.MD5.hash(data: Data(str.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        var result = params
        result["api_sig"] = hex
        return result
    }
}

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
