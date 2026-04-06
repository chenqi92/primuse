import Foundation
import PrimuseKit

/// Manages music source scanning state and tasks.
/// Lives in the SwiftUI environment so scan progress persists across navigation.
@MainActor
@Observable
final class ScanService {
    struct ScanState: Equatable {
        var isScanning: Bool = false
        var currentFile: String = ""
        var scannedCount: Int = 0
        var totalCount: Int = 0

        var progress: Double {
            guard totalCount > 0 else { return 0 }
            return Double(scannedCount) / Double(totalCount)
        }
    }

    private(set) var scanStates: [String: ScanState] = [:]
    var synologyAPIs: [String: SynologyAPI] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]

    func scanSource(
        _ source: MusicSource,
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore
    ) {
        // Media servers scan all libraries automatically; other sources need user-selected directories
        let dirs: [String]
        if source.type.isMediaServer {
            dirs = ["/"]  // Sentinel: scan all libraries
        } else {
            dirs = decodeDirs(source.extraConfig)
            guard !dirs.isEmpty else { return }
        }

        scanStates[source.id] = ScanState(isScanning: true)

        let task = Task {
            switch source.type {
            case .synology:
                await scanSynology(source: source, directories: dirs, library: library, sourceStore: sourceStore)
            case .smb, .webdav, .ftp, .sftp, .nfs, .upnp, .jellyfin, .emby, .plex:
                await scanConnectorSource(source: source, directories: dirs, sourceManager: sourceManager, library: library, sourceStore: sourceStore)
            default:
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: String(localized: "scan_needs_connect")
                )
            }
        }
        activeTasks[source.id] = task
    }

    func cancelScan(for sourceID: String) {
        activeTasks[sourceID]?.cancel()
        activeTasks[sourceID] = nil
        scanStates[sourceID]?.isScanning = false
    }

    func removeSynologyAPI(for sourceID: String) {
        synologyAPIs[sourceID] = nil
    }

    // MARK: - Synology Scan

    private func scanSynology(
        source: MusicSource,
        directories: [String],
        library: MusicLibrary,
        sourceStore: SourcesStore
    ) async {
        let api: SynologyAPI
        if let existing = synologyAPIs[source.id] {
            api = existing
        } else {
            let created = SynologyAPI(
                host: source.host ?? "",
                port: source.port ?? 5001,
                useSsl: source.useSsl
            )
            synologyAPIs[source.id] = created
            api = created
        }

        if await api.isLoggedIn == false {
            let password = KeychainService.getPassword(for: source.id) ?? ""
            let loginResult = await api.login(
                account: source.username ?? "",
                password: password,
                deviceName: source.rememberDevice ? "Primuse-iOS" : nil,
                deviceId: source.deviceId
            )

            if loginResult.needs2FA {
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: String(localized: "scan_needs_connect")
                )
                return
            }

            guard loginResult.success else {
                // Check if login failure is due to SSL certificate issue
                if let error = loginResult.underlyingError {
                    let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    if trusted {
                        scanStates[source.id] = ScanState(isScanning: true)
                        await scanSynology(source: source, directories: directories, library: library, sourceStore: sourceStore)
                        return
                    }
                }
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: loginResult.errorMessage ?? "Login failed"
                )
                return
            }

            if let did = loginResult.deviceId {
                sourceStore.update(source.id) { $0.deviceId = did }
            }
        }

        let scanner = SynologyScanner(api: api, sourceID: source.id)
        let stream = await scanner.scan(directories: directories)

        do {
            var lastSongs: [Song] = []
            var lastIncrementalUpdate = 0
            for try await update in stream {
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.totalCount = update.totalCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs

                if update.scannedCount - lastIncrementalUpdate >= 10 {
                    library.addSongs(lastSongs)
                    lastIncrementalUpdate = update.scannedCount
                }
            }

            completeScan(sourceID: source.id, songs: lastSongs, library: library, sourceStore: sourceStore)
        } catch {
            let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
            if trusted {
                // Retry scan after user trusted the domain
                scanStates[source.id] = ScanState(isScanning: true)
                await scanSynology(source: source, directories: directories, library: library, sourceStore: sourceStore)
                return
            }
            scanStates[source.id] = ScanState(
                isScanning: false,
                currentFile: error.localizedDescription
            )
        }
        activeTasks[source.id] = nil
    }

    // MARK: - Connector Scan

    private func scanConnectorSource(
        source: MusicSource,
        directories: [String],
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore
    ) async {
        let connector = sourceManager.connector(for: source)
        let scanner = ConnectorScanner(connector: connector, sourceID: source.id)
        let stream = await scanner.scan(directories: directories)

        do {
            var lastSongs: [Song] = []
            var lastIncrementalUpdate = 0
            for try await update in stream {
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.totalCount = update.totalCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs

                if update.scannedCount - lastIncrementalUpdate >= 10 {
                    library.addSongs(lastSongs)
                    lastIncrementalUpdate = update.scannedCount
                }
            }

            completeScan(sourceID: source.id, songs: lastSongs, library: library, sourceStore: sourceStore)
        } catch {
            let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
            if trusted {
                // Retry scan after user trusted the domain
                scanStates[source.id] = ScanState(isScanning: true)
                await scanConnectorSource(source: source, directories: directories, sourceManager: sourceManager, library: library, sourceStore: sourceStore)
                return
            }
            scanStates[source.id] = ScanState(
                isScanning: false,
                currentFile: error.localizedDescription
            )
        }
        activeTasks[source.id] = nil
    }

    private func completeScan(sourceID: String, songs: [Song], library: MusicLibrary, sourceStore: SourcesStore) {
        library.addSongs(songs)
        sourceStore.update(sourceID) {
            $0.songCount = songs.count
            $0.lastScannedAt = Date()
        }
        scanStates[sourceID]?.isScanning = false
        scanStates[sourceID]?.scannedCount = songs.count
        scanStates[sourceID]?.currentFile = "\(songs.count) \(String(localized: "songs_found"))"
    }

    // MARK: - Helpers

    private func decodeDirs(_ config: String?) -> [String] {
        guard let config, let data = config.data(using: .utf8),
              let dirs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return dirs
    }
}
