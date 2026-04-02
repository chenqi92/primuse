import Foundation
import Network
import PrimuseKit

enum NetworkURLBuilder {
    static func baseURLString(host: String, scheme: String, port: Int? = nil) -> String? {
        guard let url = baseURL(host: host, scheme: scheme, port: port) else {
            return nil
        }

        return url.absoluteString.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
    }

    static func baseURL(host: String, scheme: String, port: Int? = nil) -> URL? {
        makeURL(host: host, defaultScheme: scheme, port: port)
    }

    static func makeURL(
        host rawHost: String,
        defaultScheme: String,
        port: Int? = nil,
        path: String? = nil,
        forceScheme: Bool = false
    ) -> URL? {
        let trimmedHost = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHost.isEmpty == false else {
            return nil
        }

        var components: URLComponents
        if trimmedHost.contains("://"), let parsed = URLComponents(string: trimmedHost) {
            components = parsed
        } else if isLikelyIPv6Literal(trimmedHost) {
            components = URLComponents()
            components.scheme = defaultScheme
            components.host = sanitizedHost(trimmedHost)
        } else if let parsed = URLComponents(string: "\(defaultScheme)://\(trimmedHost)") {
            components = parsed
        } else {
            components = URLComponents()
            components.scheme = defaultScheme
            components.host = sanitizedHost(trimmedHost)
        }

        if forceScheme || components.scheme?.isEmpty != false {
            components.scheme = defaultScheme
        }

        if let parsedHost = components.host, parsedHost.isEmpty == false {
            components.host = sanitizedHost(parsedHost)
        } else if trimmedHost.contains("://") == false {
            components.host = sanitizedHost(trimmedHost)
        }

        if let port {
            components.port = port
        }

        if let path {
            components.path = normalizedPath(path)
        }

        return components.url
    }

    static func sanitizedHost(_ host: String) -> String {
        var sanitized = host.trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.hasPrefix("[") && sanitized.hasSuffix("]") && sanitized.count >= 2 {
            sanitized.removeFirst()
            sanitized.removeLast()
        }

        if sanitized.hasSuffix(".") {
            sanitized.removeLast()
        }

        return sanitized
    }

    static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }

        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private static func isLikelyIPv6Literal(_ value: String) -> Bool {
        let sanitized = sanitizedHost(value)
        return sanitized.contains(":")
            && sanitized.filter({ $0 == ":" }).count >= 2
            && sanitized.contains("/") == false
            && sanitized.contains("?") == false
    }
}

private struct ResolvedServiceEndpoint: Sendable {
    let host: String
    let port: Int
}

private final class BonjourHostResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private var continuation: CheckedContinuation<ResolvedServiceEndpoint?, Never>?

    init(name: String, type: String, domain: String) {
        self.service = NetService(domain: domain, type: type, name: name)
        super.init()
        self.service.delegate = self
    }

    func resolve(timeout: TimeInterval = 2.0) async -> ResolvedServiceEndpoint? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            service.resolve(withTimeout: timeout)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = NetworkURLBuilder.sanitizedHost(sender.hostName ?? "")
        guard host.isEmpty == false, sender.port > 0 else {
            finish(with: nil)
            return
        }

        finish(with: ResolvedServiceEndpoint(host: host, port: sender.port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(with: nil)
    }

    private func finish(with result: ResolvedServiceEndpoint?) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        service.stop()
        continuation.resume(returning: result)
    }
}

private final class EndpointResolutionBox: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<ResolvedServiceEndpoint?, Never>
    private var hasResumed = false

    init(connection: NWConnection, continuation: CheckedContinuation<ResolvedServiceEndpoint?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(with result: ResolvedServiceEndpoint?) {
        guard hasResumed == false else {
            return
        }

        hasResumed = true
        connection.cancel()
        continuation.resume(returning: result)
    }
}

/// A device discovered on the local network via mDNS/Bonjour
struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    let id: String  // host:port
    let name: String
    let host: String
    let port: Int
    let sourceType: MusicSourceType
    let serviceType: String
    let preferredUseSsl: Bool?

    init(
        name: String,
        host: String,
        port: Int,
        sourceType: MusicSourceType,
        serviceType: String,
        preferredUseSsl: Bool? = nil
    ) {
        self.id = "\(host):\(port)"
        self.name = name
        self.host = host
        self.port = port
        self.sourceType = sourceType
        self.serviceType = serviceType
        self.preferredUseSsl = preferredUseSsl
    }
}

/// Discovers NAS devices and services on the local network using Apple's Network framework (NWBrowser).
/// Scans for mDNS service types: SMB, WebDAV, SFTP, FTP, NFS, Synology, QNAP, Jellyfin, etc.
@MainActor
@Observable
final class NetworkDiscoveryService {
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var isDiscovering = false
    private(set) var lastDiscoveryTime: Date?

    private var browsers: [NWBrowser] = []
    private var discoveredSet: Set<DiscoveredDevice> = []
    private var timeoutTask: Task<Void, Never>?
    private var pendingResolutionKeys: Set<String> = []

    /// mDNS service type → MusicSourceType mapping
    private static let serviceTypes: [(String, MusicSourceType?)] = [
        ("_smb._tcp.", .smb),
        ("_webdav._tcp.", .webdav),
        ("_webdavs._tcp.", .webdav),
        ("_ftp._tcp.", .ftp),
        ("_sftp-ssh._tcp.", .sftp),
        ("_nfs._tcp.", .nfs),
        ("_diskstation._tcp.", .synology),
        ("_synology-dsm._tcp.", .synology),
        ("_http._tcp.", nil),
        ("_https._tcp.", nil),
    ]

    func startDiscovery() {
        guard !isDiscovering else { return }

        stopDiscovery()
        isDiscovering = true
        discoveredSet.removeAll()
        pendingResolutionKeys.removeAll()
        devices.removeAll()

        NSLog("🔍 NetworkDiscovery: Starting mDNS scan...")

        let params = NWParameters()
        params.includePeerToPeer = true

        for (serviceType, sourceType) in Self.serviceTypes {
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: params)

            browser.stateUpdateHandler = { state in
                Task { @MainActor in
                    if case .failed(let error) = state {
                        NSLog("⚠️ NetworkDiscovery: Browser failed for \(serviceType): \(error)")
                    }
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    self?.handleResults(results, serviceType: serviceType, sourceType: sourceType)
                }
            }

            browser.start(queue: .main)
            browsers.append(browser)
        }

        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            finishDiscovery()
        }
    }

    func stopDiscovery() {
        timeoutTask?.cancel()
        timeoutTask = nil

        for browser in browsers {
            browser.cancel()
        }
        browsers.removeAll()
        pendingResolutionKeys.removeAll()

        if isDiscovering {
            isDiscovering = false
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, serviceType: String, sourceType: MusicSourceType?) {
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                continue
            }

            let resolutionKey = "\(name)|\(type)|\(domain)"
            guard pendingResolutionKeys.insert(resolutionKey).inserted else {
                continue
            }

            Task { @MainActor in
                defer { pendingResolutionKeys.remove(resolutionKey) }

                guard let resolved = await resolveEndpoint(
                    for: result.endpoint,
                    name: name,
                    type: type,
                    domain: domain
                ) else {
                    return
                }

                guard isDiscovering else {
                    return
                }

                let resolvedType = sourceType ?? guessSourceType(name: name, port: resolved.port)
                guard let resolvedType else {
                    return
                }

                let device = DiscoveredDevice(
                    name: name,
                    host: resolved.host,
                    port: resolved.port,
                    sourceType: resolvedType,
                    serviceType: serviceType,
                    preferredUseSsl: preferredUseSsl(
                        for: serviceType,
                        sourceType: resolvedType,
                        port: resolved.port
                    )
                )

                if discoveredSet.insert(device).inserted {
                    devices.append(device)
                    NSLog("🔍 NetworkDiscovery: Found \(device.name) (\(device.sourceType)) at \(device.host):\(device.port)")
                }
            }
        }
    }

    private func resolveEndpoint(
        for endpoint: NWEndpoint,
        name: String,
        type: String,
        domain: String
    ) async -> ResolvedServiceEndpoint? {
        if let resolvedByBonjour = await BonjourHostResolver(name: name, type: type, domain: domain).resolve() {
            return resolvedByBonjour
        }

        return await resolveHostPort(for: endpoint)
    }

    private func resolveHostPort(for endpoint: NWEndpoint) async -> ResolvedServiceEndpoint? {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let resolution = EndpointResolutionBox(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let endpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let host, let port) = endpoint {
                        let hostString = NetworkURLBuilder.sanitizedHost(
                            "\(host)".replacingOccurrences(
                                of: "%.*",
                                with: "",
                                options: .regularExpression
                            )
                        )
                        resolution.finish(with: ResolvedServiceEndpoint(
                            host: hostString,
                            port: Int(port.rawValue)
                        ))
                    } else {
                        resolution.finish(with: nil)
                    }
                case .failed, .cancelled:
                    resolution.finish(with: nil)
                default:
                    break
                }
            }

            connection.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                resolution.finish(with: nil)
            }
        }
    }

    private func preferredUseSsl(for serviceType: String, sourceType: MusicSourceType, port: Int) -> Bool? {
        switch serviceType {
        case "_webdavs._tcp.", "_https._tcp.":
            return true
        case "_webdav._tcp.", "_http._tcp.":
            return false
        default:
            switch sourceType {
            case .webdav:
                if port == 80 { return false }
                if port == 443 { return true }
                return sourceType.defaultSSL
            case .jellyfin, .emby, .plex:
                if port == 443 { return true }
                if port == 80 || port == 8096 || port == 32400 { return false }
                return nil
            default:
                return nil
            }
        }
    }

    private func guessSourceType(name: String, port: Int) -> MusicSourceType? {
        let nameLower = name.lowercased()

        if nameLower.contains("synology") || nameLower.contains("diskstation") { return .synology }
        if nameLower.contains("qnap") { return .qnap }
        if nameLower.contains("ugreen") { return .ugreen }
        if nameLower.contains("jellyfin") { return .jellyfin }
        if nameLower.contains("emby") { return .emby }
        if nameLower.contains("plex") { return .plex }

        switch port {
        case 5000, 5001: return .synology
        case 8080: return .qnap
        case 9999: return .ugreen
        case 5666: return .fnos
        case 445: return .smb
        case 443, 80: return .webdav
        case 21: return .ftp
        case 22: return .sftp
        case 2049: return .nfs
        case 8096: return .jellyfin
        case 32400: return .plex
        default: return nil
        }
    }

    private func finishDiscovery() {
        stopDiscovery()
        lastDiscoveryTime = Date()
        NSLog("🔍 NetworkDiscovery: Scan complete, found \(devices.count) device(s)")
    }
}
