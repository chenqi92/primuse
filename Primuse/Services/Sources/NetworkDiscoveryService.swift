import Foundation
import Network
import PrimuseKit

/// A device discovered on the local network via mDNS/Bonjour
struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    let id: String  // host:port
    let name: String
    let host: String
    let port: Int
    let sourceType: MusicSourceType
    let serviceType: String

    init(name: String, host: String, port: Int, sourceType: MusicSourceType, serviceType: String) {
        self.id = "\(host):\(port)"
        self.name = name
        self.host = host
        self.port = port
        self.sourceType = sourceType
        self.serviceType = serviceType
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

    /// mDNS service type → MusicSourceType mapping
    private static let serviceTypes: [(String, MusicSourceType?)] = [
        ("_smb._tcp.", .smb),
        ("_webdav._tcp.", .webdav),
        ("_webdavs._tcp.", .webdav),
        ("_ftp._tcp.", .ftp),
        ("_sftp-ssh._tcp.", .sftp),
        ("_nfs._tcp.", .nfs),
        // NAS vendor-specific
        ("_diskstation._tcp.", .synology),
        ("_synology-dsm._tcp.", .synology),
        // Media servers
        ("_http._tcp.", nil),  // Generic HTTP — needs heuristic
        ("_https._tcp.", nil),
    ]

    func startDiscovery() {
        guard !isDiscovering else { return }

        stopDiscovery()
        isDiscovering = true
        discoveredSet.removeAll()
        devices.removeAll()

        NSLog("🔍 NetworkDiscovery: Starting mDNS scan...")

        let params = NWParameters()
        params.includePeerToPeer = true

        for (serviceType, sourceType) in Self.serviceTypes {
            let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
            let browser = NWBrowser(for: descriptor, using: params)

            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .failed(let error):
                        NSLog("⚠️ NetworkDiscovery: Browser failed for \(serviceType): \(error)")
                    default:
                        break
                    }
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, changes in
                Task { @MainActor in
                    self?.handleResults(results, serviceType: serviceType, sourceType: sourceType)
                }
            }

            browser.start(queue: .main)
            browsers.append(browser)
        }

        // Auto-stop after 8 seconds
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

        if isDiscovering {
            isDiscovering = false
        }
    }

    // MARK: - Private

    private func handleResults(_ results: Set<NWBrowser.Result>, serviceType: String, sourceType: MusicSourceType?) {
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }

            // Resolve the endpoint to get host and port
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let endpoint = connection.currentPath?.remoteEndpoint,
                           case .hostPort(let host, let port) = endpoint {
                            let hostStr = "\(host)"
                                .replacingOccurrences(of: "%.*", with: "", options: .regularExpression) // Remove interface suffix
                            let portInt = Int(port.rawValue)

                            let resolvedType = sourceType ?? self.guessSourceType(name: name, port: portInt)
                            if let resolvedType {
                                let device = DiscoveredDevice(
                                    name: name,
                                    host: hostStr,
                                    port: portInt,
                                    sourceType: resolvedType,
                                    serviceType: serviceType
                                )
                                if self.discoveredSet.insert(device).inserted {
                                    self.devices.append(device)
                                    NSLog("🔍 NetworkDiscovery: Found \(device.name) (\(device.sourceType)) at \(hostStr):\(portInt)")
                                }
                            }
                        }
                        connection.cancel()
                    case .failed:
                        connection.cancel()
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)

            // Timeout individual connection resolution after 3 seconds
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                connection.cancel()
            }
        }
    }

    private func guessSourceType(name: String, port: Int) -> MusicSourceType? {
        let nameLower = name.lowercased()

        // By name
        if nameLower.contains("synology") || nameLower.contains("diskstation") { return .synology }
        if nameLower.contains("qnap") { return .qnap }
        if nameLower.contains("ugreen") { return .ugreen }
        if nameLower.contains("jellyfin") { return .jellyfin }
        if nameLower.contains("emby") { return .emby }
        if nameLower.contains("plex") { return .plex }

        // By port
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
