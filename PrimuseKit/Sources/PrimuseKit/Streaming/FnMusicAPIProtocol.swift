import CryptoKit
import Foundation
import Network

public enum FnMusicConnectionMode: String, Codable, CaseIterable, Sendable {
    case fnConnect
    case address
}

public struct FnMusicResolvedEndpoint: Equatable, Sendable {
    public enum Route: String, Sendable {
        case direct
        case relay
    }

    public let baseURL: URL
    public let route: Route

    public init(baseURL: URL, route: Route) {
        self.baseURL = baseURL
        self.route = route
    }

    public var usesRelay: Bool { route == .relay }
}

public enum FnConnectError: Error, LocalizedError, Equatable, Sendable {
    case invalidID
    case serverNotFound
    case invalidResponse
    case accessCodeRequired
    case accessCodeRejected
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .invalidID:
            return PMString("error.fnConnect.invalidID")
        case .serverNotFound:
            return PMString("error.fnConnect.serverNotFound")
        case .invalidResponse:
            return PMString("error.fnConnect.invalidResponse")
        case .accessCodeRequired:
            return PMString("error.fnConnect.accessCodeRequired")
        case .accessCodeRejected:
            return PMString("error.fnConnect.accessCodeRejected")
        case .unreachable:
            return PMString("error.fnConnect.unreachable")
        }
    }
}

/// Shared request construction for the Feiniu Music web service.
///
/// The service is mounted below `/music/api/v1`. Media responses are
/// authorized by the `music-token` cookie returned from password login.
public enum FnMusicAPIProtocol {
    public static let apiPath = "/music/api/v1"
    public static let authxHeaderField = "authx"
    public static let defaultAuthxSigningPrefix = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"
    public static let defaultAuthxClientKey = "6D5602D4-A342-4799-A0F0-BB795E7167D0"
    public static let fnConnectAccessCodeCredentialKey = "fnconnect_access_code"

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

    public static func authenticationCookie(token: String?, usesRelay: Bool) -> String? {
        var values: [String] = []
        if let token, !token.isEmpty {
            values.append(musicTokenCookie(token))
        }
        if usesRelay {
            values.append("mode=relay")
        }
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    public static func accessCodeHeaders(_ accessCode: String?) -> [String: String] {
        guard let accessCode, !accessCode.isEmpty else { return [:] }
        return [
            "x-access-code": Data(accessCode.utf8).base64EncodedString(),
            "x-access-source": "app",
        ]
    }

    public static func fnConnectAccessCodeAccount(sourceID: String) -> String {
        "fnconnect-access.\(sourceID)"
    }

    public static func isRouteFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
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

/// Resolves an FN ID through FN Connect, then verifies the exact Feiniu Music
/// service before returning a route. Address discovery and Music login remain
/// separate: callers still authenticate with the NAS-local Music account.
public struct FnConnectResolver: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let lookupURL = URL(string: "https://5ddd.com/api/v1/fn/con")!
    private static let lookupPath = "/api/v1/fn/con"
    private static let lookupClientKey = "zIGtkc3dqZnJpd29qZXJqa2w7c"

    private let dataLoader: DataLoader
    private let lookupTimeout: TimeInterval
    private let probeTimeout: TimeInterval

    public init(
        session: URLSession = .shared,
        lookupTimeout: TimeInterval = 10,
        probeTimeout: TimeInterval = 2
    ) {
        self.dataLoader = {
            try await StreamResolverHTTPTransport.data(
                for: $0,
                session: session,
                redirectMode: .fnMusic
            )
        }
        self.lookupTimeout = lookupTimeout
        self.probeTimeout = probeTimeout
    }

    public init(
        data: @escaping DataLoader,
        lookupTimeout: TimeInterval = 10,
        probeTimeout: TimeInterval = 2
    ) {
        self.dataLoader = data
        self.lookupTimeout = lookupTimeout
        self.probeTimeout = probeTimeout
    }

    public static func fnID(from rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://"), value.lowercased().hasSuffix(".5ddd.com") {
            value = String(value.dropLast(".5ddd.com".count))
        } else if let url = URL(string: value.contains("://") ? value : "https://\(value)"),
                  let host = url.host?.lowercased(),
                  host.hasSuffix(".5ddd.com"),
                  url.path.isEmpty || url.path == "/" {
            value = String(host.dropLast(".5ddd.com".count))
        }

        guard (6...63).contains(value.utf8.count),
              value.first != "-", value.last != "-",
              value.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                      || byte == UInt8(ascii: "-")
              }) else {
            return nil
        }
        return value.lowercased()
    }

    public static func isValidFNID(_ rawValue: String) -> Bool {
        fnID(from: rawValue) != nil
    }

    public func resolve(
        _ rawValue: String,
        accessCode: String? = nil
    ) async throws -> FnMusicResolvedEndpoint {
        guard let fnID = Self.fnID(from: rawValue) else {
            throw FnConnectError.invalidID
        }
        let parameters = try await lookup(fnID: fnID)
        let groups = Self.candidateGroups(fnID: fnID, parameters: parameters)
        var sawAccessCodeChallenge = false

        for group in groups where !group.isEmpty {
            let result = await probe(group, accessCode: accessCode)
            if let endpoint = result.endpoint {
                return endpoint
            }
            sawAccessCodeChallenge = sawAccessCodeChallenge || result.sawAccessCodeChallenge
        }

        if sawAccessCodeChallenge {
            if accessCode?.isEmpty == false {
                throw FnConnectError.accessCodeRejected
            }
            throw FnConnectError.accessCodeRequired
        }
        throw FnConnectError.unreachable
    }

    private func lookup(fnID: String) async throws -> Parameters {
        let body = try JSONSerialization.data(
            withJSONObject: ["fnId": fnID],
            options: [.sortedKeys]
        )
        var request = URLRequest(url: Self.lookupURL)
        request.httpMethod = "POST"
        request.timeoutInterval = lookupTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.setValue(
            FnMusicAPIProtocol.currentAuthxHeader(
                method: "POST",
                path: Self.lookupPath,
                bodyData: body,
                key: Self.lookupClientKey
            ),
            forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField
        )

        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = Self.int(envelope["code"]) else {
            throw FnConnectError.invalidResponse
        }
        guard code == 0 else {
            if code == 404 || code == 1001 || code == 1004 {
                throw FnConnectError.serverNotFound
            }
            throw FnConnectError.invalidResponse
        }
        guard let data = envelope["data"] as? [String: Any] else {
            throw FnConnectError.serverNotFound
        }
        return Parameters(json: data)
    }

    private func probe(
        _ candidates: [Candidate],
        accessCode: String?
    ) async -> (endpoint: FnMusicResolvedEndpoint?, sawAccessCodeChallenge: Bool) {
        await withTaskGroup(
            of: (Int, ProbeResult).self,
            returning: (FnMusicResolvedEndpoint?, Bool).self
        ) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    (index, await probe(candidate, accessCode: accessCode))
                }
            }

            var reachable = Set<Int>()
            var sawAccessCodeChallenge = false
            for await (index, result) in group {
                switch result {
                case .reachable:
                    reachable.insert(index)
                case .accessCodeChallenge:
                    sawAccessCodeChallenge = true
                case .failed:
                    break
                }
            }
            let endpoint = candidates.indices
                .first(where: { reachable.contains($0) })
                .map { candidates[$0].endpoint }
            return (endpoint, sawAccessCodeChallenge)
        }
    }

    private func probe(_ candidate: Candidate, accessCode: String?) async -> ProbeResult {
        let accessCodeResult = await probeAccessCode(candidate, accessCode: accessCode)
        if accessCodeResult == .accessCodeChallenge {
            return .accessCodeChallenge
        }
        guard accessCodeResult == .reachable else { return .failed }

        guard let url = FnMusicAPIProtocol.endpointURL(
            serverBaseURL: candidate.endpoint.baseURL,
            path: "/sys/config"
        ) else { return .failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyConnectionHeaders(
            to: &request,
            endpoint: candidate.endpoint,
            accessCode: accessCode
        )
        FnMusicAPIProtocol.applyAuthx(to: &request)

        do {
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = Self.int(envelope["code"]),
                  code == 0 || code == 200 else {
                return .failed
            }
            return .reachable
        } catch {
            return .failed
        }
    }

    private func probeAccessCode(_ candidate: Candidate, accessCode: String?) async -> ProbeResult {
        guard let url = URL(string: "/access_code_verify", relativeTo: candidate.endpoint.baseURL)?.absoluteURL else {
            return .failed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        applyConnectionHeaders(
            to: &request,
            endpoint: candidate.endpoint,
            accessCode: accessCode
        )

        do {
            let (_, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200...299, 404:
                // Older fnOS builds do not expose the verification endpoint;
                // the signed Music config probe below remains authoritative.
                return .reachable
            case 401, 403, 429:
                return .accessCodeChallenge
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    private func applyConnectionHeaders(
        to request: inout URLRequest,
        endpoint: FnMusicResolvedEndpoint,
        accessCode: String?
    ) {
        if let cookie = FnMusicAPIProtocol.authenticationCookie(
            token: nil,
            usesRelay: endpoint.usesRelay
        ) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (name, value) in FnMusicAPIProtocol.accessCodeHeaders(accessCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private static func candidateGroups(fnID: String, parameters: Parameters) -> [[Candidate]] {
        let internalIPv4 = unique(parameters.internalIPv4
            .filter(InsecureHTTPHostPolicy.isLocalNetworkHost)
            .compactMap {
            candidate(host: $0, port: parameters.httpPort, scheme: "http", route: .direct)
        })
        let internalIPv6 = unique(parameters.internalIPv6
            .filter(InsecureHTTPHostPolicy.isLocalNetworkHost)
            .compactMap {
            candidate(host: $0, port: parameters.httpPort, scheme: "http", route: .direct)
        })
        let internalHTTPS = unique((parameters.internalIPv4 + parameters.internalIPv6).compactMap {
            candidate(host: $0, port: parameters.httpsPort, scheme: "https", route: .direct)
        })
        let publicIPv6 = unique(parameters.publicIPv6.compactMap {
            candidate(host: $0, port: parameters.httpsPort, scheme: "https", route: .direct)
        })
        let publicIPv4 = unique(parameters.publicIPv4.compactMap {
            candidate(host: $0, port: parameters.httpsPort, scheme: "https", route: .direct)
        })

        let relayValues = parameters.relayAddresses.isEmpty
            ? ["\(fnID).5ddd.com"]
            : parameters.relayAddresses
        let relay = unique(relayValues.compactMap { relayCandidate($0) })
        return [internalIPv4 + internalIPv6, internalHTTPS, publicIPv6, publicIPv4, relay]
    }

    private static func candidate(
        host rawHost: String,
        port: Int,
        scheme: String,
        route: FnMusicResolvedEndpoint.Route
    ) -> Candidate? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...65_535).contains(port),
              IPv4Address(host) != nil || IPv6Address(host) != nil else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if !((scheme == "http" && port == 80) || (scheme == "https" && port == 443)) {
            components.port = port
        }
        guard let url = components.url else { return nil }
        return Candidate(endpoint: FnMusicResolvedEndpoint(baseURL: url, route: route))
    }

    private static func relayCandidate(_ rawValue: String) -> Candidate? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
        guard let host = url?.host?.lowercased(),
              host.hasSuffix(".5ddd.com"),
              host != "5ddd.com" else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        guard let baseURL = components.url else { return nil }
        return Candidate(endpoint: FnMusicResolvedEndpoint(baseURL: baseURL, route: .relay))
    }

    private static func unique(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.endpoint.baseURL.absoluteString.lowercased()).inserted
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private struct Parameters: Sendable {
        let internalIPv4: [String]
        let internalIPv6: [String]
        let publicIPv4: [String]
        let publicIPv6: [String]
        let httpsPort: Int
        let httpPort: Int
        let relayAddresses: [String]

        init(json: [String: Any]) {
            let port = json["port"] as? [String: Any] ?? [:]
            internalIPv4 = Self.strings(json["ipv4"])
            internalIPv6 = Self.strings(json["ipv6"])
            publicIPv4 = Self.strings(json["publicIpv4"])
            publicIPv6 = Self.strings(json["publicIpv6"])
            httpsPort = Self.validPort(FnConnectResolver.int(port["httpsPort"])) ?? 5667
            httpPort = Self.validPort(FnConnectResolver.int(port["httpPort"])) ?? 5666
            relayAddresses = Self.strings(json["fn"])
        }

        private static func strings(_ value: Any?) -> [String] {
            (value as? [Any])?.compactMap { item in
                guard let string = item as? String else { return nil }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? []
        }

        private static func validPort(_ value: Int?) -> Int? {
            guard let value, (1...65_535).contains(value) else { return nil }
            return value
        }
    }

    private struct Candidate: Sendable {
        let endpoint: FnMusicResolvedEndpoint
    }

    private enum ProbeResult: Sendable, Equatable {
        case reachable
        case accessCodeChallenge
        case failed
    }
}

/// Per-client endpoint cache. FN Connect is re-resolved only after an explicit
/// route failure, while legacy address sources keep their exact stored URL.
public actor FnMusicEndpointProvider {
    private let directEndpoint: FnMusicResolvedEndpoint?
    private let fnID: String?
    private let accessCode: String?
    private let resolver: FnConnectResolver
    private var cachedEndpoint: FnMusicResolvedEndpoint?
    private var resolutionTask: Task<FnMusicResolvedEndpoint, Error>?

    public init(
        source: MusicSource,
        accessCode: String? = nil,
        session: URLSession = .shared,
        dataLoader: FnConnectResolver.DataLoader? = nil
    ) {
        self.accessCode = accessCode
        if let dataLoader {
            self.resolver = FnConnectResolver(data: dataLoader)
        } else {
            self.resolver = FnConnectResolver(session: session)
        }
        if source.type == .fnMusic, source.effectiveFnMusicConnectionMode == .fnConnect {
            self.fnID = source.host
            self.directEndpoint = nil
        } else {
            self.fnID = nil
            self.directEndpoint = FnMusicAPIProtocol.serverBaseURL(
                host: source.host ?? "",
                port: source.port,
                useSSL: source.useSsl,
                basePath: source.basePath
            ).map { FnMusicResolvedEndpoint(baseURL: $0, route: .direct) }
        }
    }

    public func endpoint(forceRefresh: Bool = false) async throws -> FnMusicResolvedEndpoint {
        if let directEndpoint { return directEndpoint }
        if forceRefresh {
            resolutionTask?.cancel()
            resolutionTask = nil
            cachedEndpoint = nil
        }
        if let cachedEndpoint { return cachedEndpoint }
        if let resolutionTask {
            return try await resolutionTask.value
        }
        guard let fnID else { throw FnConnectError.invalidID }

        let task = Task { try await resolver.resolve(fnID, accessCode: accessCode) }
        resolutionTask = task
        do {
            let endpoint = try await task.value
            cachedEndpoint = endpoint
            resolutionTask = nil
            return endpoint
        } catch {
            resolutionTask = nil
            throw error
        }
    }

    public func invalidate() {
        resolutionTask?.cancel()
        resolutionTask = nil
        cachedEndpoint = nil
    }
}

/// Rebuilds an FN Music request after a same-host redirect. Authentication is
/// never forwarded cross-host or from HTTPS down to HTTP, and `authx` is
/// regenerated because its signature includes the final path and query.
public enum FnMusicRedirectPolicy {
    public static let maximumRedirects = 5

    public static func redirectedRequest(
        from original: URLRequest,
        to proposed: URLRequest
    ) -> URLRequest? {
        guard let originalURL = original.url,
              let proposedURL = proposed.url,
              let originalHost = originalURL.host?.lowercased(),
              let proposedHost = proposedURL.host?.lowercased(),
              originalHost == proposedHost else {
            return nil
        }
        let originalScheme = originalURL.scheme?.lowercased()
        let proposedScheme = proposedURL.scheme?.lowercased()
        guard proposedScheme == "https" || proposedScheme == "http",
              !(originalScheme == "https" && proposedScheme != "https"),
              effectivePort(for: originalURL) == effectivePort(for: proposedURL) else {
            return nil
        }

        var request = proposed
        request.httpMethod = original.httpMethod
        request.httpBody = original.httpBody
        for name in [
            "Cookie",
            "x-access-code",
            "x-access-source",
            "Accept",
            "Accept-Language",
            "Content-Type",
            "Range",
        ] {
            if let value = original.value(forHTTPHeaderField: name) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        request.setValue(nil, forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField)
        if proposedURL.path.contains(FnMusicAPIProtocol.apiPath) {
            FnMusicAPIProtocol.applyAuthx(to: &request)
        }
        return request
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
