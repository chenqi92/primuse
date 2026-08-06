import CryptoKit
import Foundation

public enum SynologyConnectionMode: String, CaseIterable, Sendable {
    case quickConnect
    case address

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Self.quickConnect.rawValue:
            self = .quickConnect
        case Self.address.rawValue, "domain", "ip":
            // Early builds exposed domain and IP as separate UI modes even
            // though both use the same direct host/port transport.
            self = .address
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown Synology connection mode: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SynologyConnectionMode: Codable {}

public enum SynologyAuthenticationPolicy {
    public static func requiresTwoFactorAuthentication(errorCode: Int) -> Bool {
        switch errorCode {
        case 403, 404, 406:
            return true
        default:
            return false
        }
    }
}

/// Determines when a complete HTTP/1.1 response has arrived without waiting
/// for the peer to close a keep-alive connection.
public enum HTTPResponseFramingPolicy {
    private static let lineBreak = Data([13, 10])
    private static let headerTerminator = Data([13, 10, 13, 10])

    public static func completeMessageLength(in data: Data) -> Int? {
        guard let headerRange = data.range(of: headerTerminator) else { return nil }
        let headerEnd = data.distance(from: data.startIndex, to: headerRange.upperBound)
        let headerData = Data(data[..<headerRange.lowerBound])
        let headerText = String(data: headerData, encoding: .isoLatin1)
            ?? String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")

        var statusCode: Int?
        if let statusLine = lines.first {
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count >= 2 { statusCode = Int(parts[1]) }
        }

        var contentLength: Int?
        var isChunked = false
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "content-length":
                guard let parsed = Int(value), parsed >= 0 else { return nil }
                contentLength = parsed
            case "transfer-encoding":
                isChunked = value.localizedCaseInsensitiveContains("chunked")
            default:
                break
            }
        }

        if isChunked {
            return completeChunkedMessageLength(in: data, bodyOffset: headerEnd)
        }
        if let contentLength {
            guard contentLength <= Int.max - headerEnd else { return nil }
            let messageLength = headerEnd + contentLength
            return data.count >= messageLength ? messageLength : nil
        }
        if statusCode == 204 || statusCode == 304 {
            return headerEnd
        }
        return nil
    }

    private static func completeChunkedMessageLength(in data: Data, bodyOffset: Int) -> Int? {
        guard bodyOffset <= data.count else { return nil }
        var cursor = data.index(data.startIndex, offsetBy: bodyOffset)

        while cursor < data.endIndex {
            guard let sizeLineRange = data[cursor...].range(of: lineBreak) else { return nil }
            let sizeLine = String(decoding: data[cursor..<sizeLineRange.lowerBound], as: UTF8.self)
            let sizeToken = sizeLine
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first ?? ""
            guard let chunkSize = Int(sizeToken.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16),
                  chunkSize >= 0 else {
                return nil
            }

            cursor = sizeLineRange.upperBound
            if chunkSize == 0 {
                if data[cursor...].starts(with: lineBreak) {
                    return data.distance(
                        from: data.startIndex,
                        to: data.index(cursor, offsetBy: lineBreak.count)
                    )
                }
                guard let trailerEnd = data[cursor...].range(of: headerTerminator) else { return nil }
                return data.distance(from: data.startIndex, to: trailerEnd.upperBound)
            }

            guard let chunkEnd = data.index(cursor, offsetBy: chunkSize, limitedBy: data.endIndex),
                  data[chunkEnd...].starts(with: lineBreak) else {
                return nil
            }
            cursor = data.index(chunkEnd, offsetBy: lineBreak.count)
        }
        return nil
    }
}

public struct SynologyResolvedEndpoint: Equatable, Sendable {
    public enum Route: String, Sendable {
        case direct
        case relay
        case certificateTrustRequired
    }

    public let baseURL: URL
    public let route: Route
    public let controlHosts: [String]

    public init(baseURL: URL, route: Route, controlHosts: [String] = []) {
        self.baseURL = baseURL
        self.route = route
        self.controlHosts = controlHosts
    }
}

public enum SynologyQuickConnectError: Error, LocalizedError, Equatable, Sendable {
    case invalidID
    case serverNotFound
    case serviceUnavailable
    case invalidResponse
    case unreachable

    public var errorDescription: String? {
        switch self {
        case .invalidID:
            return PMString("ext.synology.quickconnect.error.invalidID")
        case .serverNotFound:
            return PMString("ext.synology.quickconnect.error.serverNotFound")
        case .serviceUnavailable:
            return PMString("ext.synology.quickconnect.error.serviceUnavailable")
        case .invalidResponse:
            return PMString("ext.synology.quickconnect.error.invalidResponse")
        case .unreachable:
            return PMString("ext.synology.quickconnect.error.unreachable")
        }
    }
}

/// Resolves a QuickConnect ID with the same public control flow used by the
/// QuickConnect web portal: control-site handoff, direct endpoint verification,
/// then relay fallback. Every candidate must answer DSM's identity ping before
/// it can be selected, preventing a stale DNS/IP response from reaching login.
public struct SynologyQuickConnectResolver: Sendable {
    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let probeTimeout: TimeInterval

    public init(
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 8,
        probeTimeout: TimeInterval = 5
    ) {
        self.session = session
        self.requestTimeout = requestTimeout
        self.probeTimeout = probeTimeout
    }

    public static func quickConnectID(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = normalizedURL(from: trimmed), let host = url.host?.lowercased() {
            if host == "quickconnect.to" || host == "quickconnect.cn" {
                return validatedID(url.pathComponents.dropFirst().first)
            }
            if host.hasSuffix(".quickconnect.to") || host.hasSuffix(".quickconnect.cn") {
                return validatedID(host.split(separator: ".").first.map(String.init))
            }
        }

        if !trimmed.contains(".") && !trimmed.contains("/") && !trimmed.contains(":") {
            return validatedID(trimmed)
        }
        return nil
    }

    public static func isValidQuickConnectID(_ rawValue: String) -> Bool {
        quickConnectID(from: rawValue) != nil
    }

    public func resolve(_ rawValue: String) async throws -> SynologyResolvedEndpoint {
        guard let serverID = Self.quickConnectID(from: rawValue) else {
            throw SynologyQuickConnectError.invalidID
        }

        let initialControlHost = Self.prefersChinaControlDomain(rawValue)
            ? "global.quickconnect.cn"
            : "global.quickconnect.to"
        let lookup = try await lookupServer(serverID: serverID, initialControlHost: initialControlHost)

        let preferredRecords = lookup.records.sorted { lhs, rhs in
            if lhs.isHTTPS != rhs.isHTTPS { return lhs.isHTTPS }
            return lhs.response.service?.pingpong == "CONNECTED"
                && rhs.response.service?.pingpong != "CONNECTED"
        }

        var certificateFallback: Candidate?
        for record in preferredRecords {
            let candidates = directCandidates(from: record)
            let directProbe = await probe(candidates, serverNumericID: record.response.server?.serverID)
            if let reachable = directProbe.reachable {
                return SynologyResolvedEndpoint(
                    baseURL: reachable.baseURL,
                    route: .direct,
                    controlHosts: lookup.controlHosts
                )
            }
            if certificateFallback == nil {
                certificateFallback = directProbe.certificateRejected
            }

            if let relay = try? await requestRelay(
                serverID: serverID,
                controlHost: lookup.controlHost,
                isHTTPS: record.isHTTPS
            ) {
                let relayProbe = await probe([relay], serverNumericID: relay.serverNumericID)
                if let reachable = relayProbe.reachable {
                    return SynologyResolvedEndpoint(
                        baseURL: reachable.baseURL,
                        route: .relay,
                        controlHosts: lookup.controlHosts
                    )
                }
                if certificateFallback == nil {
                    certificateFallback = relayProbe.certificateRejected
                }
            }
        }

        // The app layer owns explicit certificate decisions. Returning only a
        // candidate that failed *system* TLS validation lets its trust delegate
        // show the exact final hostname and pin that certificate before login.
        if let certificateFallback {
            return SynologyResolvedEndpoint(
                baseURL: certificateFallback.baseURL,
                route: .certificateTrustRequired,
                controlHosts: lookup.controlHosts
            )
        }
        throw SynologyQuickConnectError.unreachable
    }

    private func lookupServer(serverID: String, initialControlHost: String) async throws -> LookupResult {
        var pending = [initialControlHost]
        var visited: [String] = []
        var sawServerNotFound = false
        var sawServiceUnavailable = false

        while let rawHost = pending.first, visited.count < 8 {
            pending.removeFirst()
            guard let host = Self.safeControlHost(rawHost), !visited.contains(host) else { continue }
            visited.append(host)

            let responses: [ControlResponse]
            do {
                responses = try await post(
                    commands: [
                        ControlCommand(command: "get_server_info", id: "mainapp_https", serverID: serverID),
                        ControlCommand(command: "get_server_info", id: "mainapp_http", serverID: serverID),
                    ],
                    to: host
                )
            } catch {
                continue
            }

            var records: [ProtocolRecord] = []
            for (index, response) in responses.enumerated() {
                for site in response.sites ?? [] {
                    if let candidate = Self.safeControlHost(site),
                       !visited.contains(candidate), !pending.contains(candidate) {
                        pending.append(candidate)
                    }
                }
                if response.errno == 0,
                   response.server?.serverID?.isEmpty == false,
                   response.service?.port != nil {
                    records.append(ProtocolRecord(response: response, isHTTPS: index == 0))
                } else if response.suberrno == 2 {
                    sawServerNotFound = true
                } else if response.suberrno == 3 {
                    sawServiceUnavailable = true
                }
            }
            if !records.isEmpty {
                return LookupResult(
                    records: records,
                    controlHost: host,
                    controlHosts: visited
                )
            }
        }

        if sawServiceUnavailable { throw SynologyQuickConnectError.serviceUnavailable }
        if sawServerNotFound { throw SynologyQuickConnectError.serverNotFound }
        throw SynologyQuickConnectError.invalidResponse
    }

    private func requestRelay(
        serverID: String,
        controlHost: String,
        isHTTPS: Bool
    ) async throws -> Candidate {
        let response: [ControlResponse] = try await post(
            commands: [
                ControlCommand(
                    command: "request_tunnel",
                    id: isHTTPS ? "mainapp_https" : "mainapp_http",
                    serverID: serverID
                )
            ],
            to: controlHost
        )
        guard let record = response.first(where: {
            $0.errno == 0 && $0.server?.serverID?.isEmpty == false && $0.env?.relayRegion?.isEmpty == false
        }),
        let relayRegion = record.env?.relayRegion,
        let numericID = record.server?.serverID else {
            throw SynologyQuickConnectError.unreachable
        }

        let topDomain = controlHost.hasSuffix(".cn") ? "cn" : "to"
        let relayHost = "\(serverID).\(relayRegion).quickconnect.\(topDomain)"
        let scheme = isHTTPS ? "https" : "http"
        let port = isHTTPS ? 443 : 80
        guard let baseURL = Self.endpointURL(scheme: scheme, host: relayHost, port: port) else {
            throw SynologyQuickConnectError.invalidResponse
        }
        return Candidate(
            baseURL: baseURL,
            pingPongPath: record.server?.pingPongPath,
            serverNumericID: numericID
        )
    }

    private func post<T: Decodable>(commands: [ControlCommand], to host: String) async throws -> T {
        guard let url = URL(string: "https://\(host)/Serv.php") else {
            throw SynologyQuickConnectError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = try JSONEncoder().encode(commands)
        let (data, response) = try await StreamResolverHTTPTransport.data(
            for: request,
            session: session
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SynologyQuickConnectError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func directCandidates(from record: ProtocolRecord) -> [Candidate] {
        guard let server = record.response.server,
              let service = record.response.service,
              let port = service.port else { return [] }
        let scheme = record.isHTTPS ? "https" : "http"
        let ports = [port, service.extPort].compactMap { value -> Int? in
            guard let value, value > 0 else { return nil }
            return value
        }
        var hosts: [String] = []
        hosts.append(contentsOf: record.response.smartDNS?.lan ?? [])
        hosts.append(contentsOf: server.interfaces?.compactMap(\.ip) ?? [])
        if let smartHost = record.response.smartDNS?.host { hosts.append(smartHost) }
        if let fqdn = server.fqdn, fqdn != "NULL" { hosts.append(fqdn) }
        if let ddns = server.ddns, ddns != "NULL" { hosts.append(ddns) }
        if let externalIP = server.external?.ip { hosts.append(externalIP) }
        if let externalIPv6 = server.external?.ipv6 { hosts.append(externalIPv6) }

        var seen = Set<String>()
        var candidates: [Candidate] = []
        for host in hosts where !host.isEmpty {
            for candidatePort in ports {
                guard let baseURL = Self.endpointURL(
                    scheme: scheme,
                    host: host,
                    port: candidatePort
                ) else { continue }
                let key = baseURL.absoluteString.lowercased()
                guard seen.insert(key).inserted else { continue }
                candidates.append(Candidate(
                    baseURL: baseURL,
                    pingPongPath: server.pingPongPath,
                    serverNumericID: server.serverID
                ))
            }
        }
        return candidates
    }

    private func probe(
        _ candidates: [Candidate],
        serverNumericID: String?
    ) async -> (reachable: Candidate?, certificateRejected: Candidate?) {
        guard !candidates.isEmpty,
              let serverNumericID,
              let digest = Self.md5(serverNumericID) else { return (nil, nil) }

        return await withTaskGroup(
            of: (Int, ProbeResult).self,
            returning: (Candidate?, Candidate?).self
        ) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    (index, await probe(candidate, expectedDigest: digest))
                }
            }

            var reachableIndexes = Set<Int>()
            var certificateIndexes = Set<Int>()
            for await (index, result) in group {
                switch result {
                case .reachable: reachableIndexes.insert(index)
                case .certificateRejected: certificateIndexes.insert(index)
                case .failed: break
                }
            }
            return (
                candidates.indices.first(where: { reachableIndexes.contains($0) }).map { candidates[$0] },
                candidates.indices.first(where: { certificateIndexes.contains($0) }).map { candidates[$0] }
            )
        }
    }

    private func probe(_ candidate: Candidate, expectedDigest: String) async -> ProbeResult {
        let path = candidate.pingPongPath?.isEmpty == false
            ? candidate.pingPongPath!
            : "/webman/pingpong.cgi?action=cors&quickconnect=true"
        guard let url = URL(string: path, relativeTo: candidate.baseURL)?.absoluteURL else {
            return .failed
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await StreamResolverHTTPTransport.data(
                for: request,
                session: session
            )
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["success"] as? Bool == true,
                  (json["ezid"] as? String)?.lowercased() == expectedDigest else {
                return .failed
            }
            return .reachable
        } catch {
            return Self.isCertificateFailure(error) ? .certificateRejected : .failed
        }
    }

    private static func endpointURL(scheme: String, host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            components.port = port
        }
        return components.url
    }

    private static func normalizedURL(from value: String) -> URL? {
        if value.contains("://") { return URL(string: value) }
        if value.lowercased().hasPrefix("quickconnect.to/")
            || value.lowercased().hasPrefix("quickconnect.cn/") {
            return URL(string: "https://\(value)")
        }
        return nil
    }

    private static func validatedID(_ value: String?) -> String? {
        guard let value else { return nil }
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$|^[A-Za-z]$"),
              regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil else {
            return nil
        }
        return id
    }

    private static func prefersChinaControlDomain(_ value: String) -> Bool {
        value.lowercased().contains("quickconnect.cn")
    }

    private static func safeControlHost(_ value: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty,
              !host.contains("/"), !host.contains(":"),
              host.hasSuffix(".quickconnect.to") || host.hasSuffix(".quickconnect.cn") else {
            return nil
        }
        return host
    }

    private static func md5(_ value: String) -> String? {
        guard let data = value.data(using: .utf8) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCertificateFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed,
        ].contains(nsError.code)
    }
}

private extension SynologyQuickConnectResolver {
    struct ControlCommand: Encodable, Sendable {
        let version = 1
        let command: String
        let stopWhenError = false
        let stopWhenSuccess: Bool
        let id: String
        let serverID: String
        let isGofile = false
        let path = ""

        init(command: String, id: String, serverID: String) {
            self.command = command
            self.stopWhenSuccess = command == "request_tunnel"
            self.id = id
            self.serverID = serverID
        }

        enum CodingKeys: String, CodingKey {
            case version, command, id, serverID, path
            case stopWhenError = "stop_when_error"
            case stopWhenSuccess = "stop_when_success"
            case isGofile = "is_gofile"
        }
    }

    struct ControlResponse: Decodable, Sendable {
        let errno: Int?
        let suberrno: Int?
        let sites: [String]?
        let env: Environment?
        let server: Server?
        let service: Service?
        let smartDNS: SmartDNS?

        enum CodingKeys: String, CodingKey {
            case errno, suberrno, sites, env, server, service
            case smartDNS = "smartdns"
        }
    }

    struct Environment: Decodable, Sendable {
        let relayRegion: String?

        enum CodingKeys: String, CodingKey {
            case relayRegion = "relay_region"
        }
    }

    struct Server: Decodable, Sendable {
        let serverID: String?
        let ddns: String?
        let fqdn: String?
        let pingPongPath: String?
        let external: ExternalAddress?
        let interfaces: [InterfaceAddress]?

        enum CodingKeys: String, CodingKey {
            case serverID, ddns, fqdn, external
            case pingPongPath = "pingpong_path"
            case interfaces = "interface"
        }
    }

    struct ExternalAddress: Decodable, Sendable {
        let ip: String?
        let ipv6: String?
    }

    struct InterfaceAddress: Decodable, Sendable {
        let ip: String?
    }

    struct Service: Decodable, Sendable {
        let port: Int?
        let extPort: Int?
        let pingpong: String?

        enum CodingKeys: String, CodingKey {
            case port, pingpong
            case extPort = "ext_port"
        }
    }

    struct SmartDNS: Decodable, Sendable {
        let host: String?
        let lan: [String]?
    }

    struct ProtocolRecord: Sendable {
        let response: ControlResponse
        let isHTTPS: Bool
    }

    struct LookupResult: Sendable {
        let records: [ProtocolRecord]
        let controlHost: String
        let controlHosts: [String]
    }

    struct Candidate: Sendable {
        let baseURL: URL
        let pingPongPath: String?
        let serverNumericID: String?
    }

    enum ProbeResult: Sendable {
        case reachable
        case certificateRejected
        case failed
    }
}
