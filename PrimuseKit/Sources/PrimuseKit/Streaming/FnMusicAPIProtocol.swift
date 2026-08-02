import CryptoKit
import Foundation

/// Shared request construction for the Feiniu Music web service.
///
/// The service is mounted below `/music/api/v1`. Media responses are
/// authorized by the `music-token` cookie returned from password login.
public enum FnMusicAPIProtocol {
    public static let apiPath = "/music/api/v1"
    public static let authxHeaderField = "authx"
    public static let defaultAuthxSigningPrefix = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
    public static let defaultAuthxClientKey = "6D5602D4-A342-4799-A0F0-BB795E7167D0"

    private static let deviceIDDefaultsKey = "com.primuse.fnmusic.device-id.v1"
    private static let deviceIDLock = NSLock()
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func serverBaseURL(
        host rawHost: String,
        port: Int?,
        useSSL: Bool,
        basePath: String? = nil
    ) -> URL? {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let defaultScheme = useSSL ? "https" : "http"
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else if isIPv6Literal(trimmed) {
            candidate = "\(defaultScheme)://[\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]"
        } else {
            candidate = "\(defaultScheme)://\(trimmed)"
        }
        guard var components = URLComponents(string: candidate),
              components.host?.isEmpty == false else { return nil }
        if components.scheme?.isEmpty != false { components.scheme = defaultScheme }
        if components.port == nil, let port, port > 0 { components.port = port }

        if components.path.isEmpty || components.path == "/" {
            let suppliedPath = basePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            components.path = normalizedPrefix(suppliedPath)
        } else {
            components.path = normalizedPrefix(components.path)
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func endpointURL(
        serverBaseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard var components = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var prefix = normalizedPrefix(components.path)
        if prefix.hasSuffix(apiPath) {
            // The caller supplied the full API base.
        } else if prefix.hasSuffix("/music") {
            prefix += "/api/v1"
        } else {
            prefix += apiPath
        }
        let endpoint = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = endpoint.isEmpty ? prefix : "\(prefix)/\(endpoint)"
        components.percentEncodedQuery = canonicalQuery(queryItems)
        return components.url
    }

    /// Reproduces the Feiniu Music browser request signature. GET requests
    /// hash the sorted, URL-decoded query string; other methods hash the exact
    /// bytes sent as the request body.
    public static func authxHeader(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        bodyData: Data? = nil,
        nonce: String,
        timestampMilliseconds: Int64,
        prefix: String = defaultAuthxSigningPrefix,
        key: String = defaultAuthxClientKey
    ) -> String {
        let payload: Data
        if method.caseInsensitiveCompare("GET") == .orderedSame {
            let encoded = canonicalQuery(queryItems) ?? ""
            let plusDecoded = encoded.replacingOccurrences(of: "+", with: " ")
            payload = Data((plusDecoded.removingPercentEncoding ?? encoded).utf8)
        } else {
            payload = bodyData ?? Data()
        }

        let payloadHash = Insecure.MD5.hash(data: payload).hexString
        let timestamp = String(timestampMilliseconds)
        let source = [prefix, path, nonce, timestamp, payloadHash, key]
            .joined(separator: "_")
        let signature = Insecure.MD5.hash(data: Data(source.utf8)).hexString
        return "nonce=\(nonce)&timestamp=\(timestamp)&sign=\(signature)"
    }

    /// Generates a fresh six-digit nonce and Unix-millisecond timestamp.
    public static func currentAuthxHeader(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        bodyData: Data? = nil,
        now: Date = Date(),
        prefix: String = defaultAuthxSigningPrefix,
        key: String = defaultAuthxClientKey
    ) -> String {
        authxHeader(
            method: method,
            path: path,
            queryItems: queryItems,
            bodyData: bodyData,
            nonce: String(format: "%06d", Int.random(in: 100_000...999_999)),
            timestampMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)),
            prefix: prefix,
            key: key
        )
    }

    /// Reverse proxies may expose the service below an arbitrary base path,
    /// while the service signer always evaluates the canonical API pathname.
    public static func authxPath(for url: URL) -> String {
        let path = url.path
        guard let range = path.range(of: apiPath, options: .backwards) else { return path }
        let suffix = path[range.upperBound...]
        guard suffix.isEmpty || suffix.first == "/" else { return path }
        return String(path[range.lowerBound...])
    }

    /// Signs the request's actual path, decoded query values, and body. Callers
    /// intentionally invoke this only for `/music/api/v1` requests.
    public static func applyAuthx(to request: inout URLRequest, bodyData: Data? = nil) {
        guard let url = request.url else { return }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        request.setValue(
            currentAuthxHeader(
                method: request.httpMethod ?? "GET",
                path: authxPath(for: url),
                queryItems: queryItems,
                bodyData: bodyData ?? request.httpBody
            ),
            forHTTPHeaderField: authxHeaderField
        )
    }

    public static func passwordHash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).hexString
    }

    public static func deviceID(
        sourceID _: String,
        defaults: UserDefaults = .standard
    ) -> String {
        deviceIDLock.lock()
        defer { deviceIDLock.unlock() }

        if let stored = defaults.string(forKey: deviceIDDefaultsKey), isValidDeviceID(stored) {
            return stored.lowercased()
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(generated, forKey: deviceIDDefaultsKey)
        return generated
    }

    public static func musicTokenCookie(_ token: String) -> String {
        let escaped = token
            .addingPercentEncoding(withAllowedCharacters: unreserved)?
            .replacingOccurrences(of: "%20", with: "+") ?? token
        return "music-token=\(escaped)"
    }

    public static func trackPath(guid: String, fileExtension: String) -> String {
        let suffix = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return "/fnmusic/tracks/\(guid).\(suffix.isEmpty ? "bin" : suffix.lowercased())"
    }

    public static func trackGUID(from path: String) -> String? {
        guard path.hasPrefix("/fnmusic/tracks/") else { return nil }
        let name = (path as NSString).lastPathComponent
        let guid = (name as NSString).deletingPathExtension
        return guid.isEmpty ? nil : guid.removingPercentEncoding ?? guid
    }

    public static func coverReference(coverID: String, revision: Int? = nil) -> String {
        let reference = "fnmusic-cover/\(coverID)"
        guard let revision else { return reference }
        return "\(reference)?revision=\(revision)"
    }

    public static func coverID(from reference: String) -> String? {
        let prefix = "fnmusic-cover/"
        guard reference.hasPrefix(prefix) else { return nil }
        let value = reference
            .dropFirst(prefix.count)
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return value.isEmpty ? nil : value
    }

    public static func coverRevision(from reference: String) -> Int? {
        guard reference.hasPrefix("fnmusic-cover/"),
              let components = URLComponents(string: reference),
              let value = components.queryItems?.first(where: { $0.name == "revision" })?.value,
              let revision = Int(value), revision > 0 else {
            return nil
        }
        return revision
    }

    static func canonicalQuery(_ items: [URLQueryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        return items
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.name != rhs.element.name {
                    return lhs.element.name < rhs.element.name
                }
                return lhs.offset < rhs.offset
            }
            .map { _, item in
                let name = item.name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? item.name
                let rawValue = item.value ?? ""
                let value = rawValue.addingPercentEncoding(withAllowedCharacters: unreserved) ?? rawValue
                return "\(name)=\(value)"
            }
            .joined(separator: "&")
    }

    private static func normalizedPrefix(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return "" }
        return "/" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isIPv6Literal(_ value: String) -> Bool {
        let withoutBrackets = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return !value.contains("://")
            && withoutBrackets.filter({ $0 == ":" }).count >= 2
            && !withoutBrackets.contains("/")
    }

    private static func isValidDeviceID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0)
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
