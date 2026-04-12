import Foundation
import PrimuseKit
import UIKit

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

        var canResume: Bool {
            !isScanning && scannedCount > 0 && (totalCount == 0 || scannedCount < totalCount)
        }
    }

    private struct ScanCheckpoint: Codable {
        var directories: [String]
        var songs: [Song]
        var totalCount: Int
        var currentFile: String
        var updatedAt: Date
    }

    private(set) var scanStates: [String: ScanState] = [:]
    var synologyAPIs: [String: SynologyAPI] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var checkpoints: [String: ScanCheckpoint] = [:]
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]

    private let checkpointURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        checkpointURL = directory.appendingPathComponent("scan-checkpoints.json")
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        loadCheckpoints()
    }

    func scanSource(
        _ source: MusicSource,
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService? = nil
    ) {
        guard activeTasks[source.id] == nil else { return }

        // Media servers scan all libraries automatically; other sources need user-selected directories
        let dirs: [String]
        if source.type.isMediaServer {
            dirs = ["/"]  // Sentinel: scan all libraries
        } else {
            dirs = decodeDirs(source.extraConfig)
            guard !dirs.isEmpty else { return }
        }

        let normalizedDirs = normalizedDirectories(dirs)
        let checkpoint = resumeCheckpoint(for: source.id, directories: normalizedDirs)
        let resumeSongs = checkpoint?.songs ?? []
        let resumeCount = checkpoint?.songs.count ?? 0
        let resumeTotal = checkpoint?.totalCount ?? 0

        if !resumeSongs.isEmpty {
            library.addSongs(resumeSongs)
            sourceStore.update(source.id) { $0.songCount = resumeSongs.count }
        }

        scanStates[source.id] = ScanState(
            isScanning: true,
            currentFile: checkpoint?.currentFile ?? "",
            scannedCount: resumeCount,
            totalCount: resumeTotal
        )

        beginBackgroundTask(for: source.id)

        let task = Task {
            defer {
                activeTasks[source.id] = nil
                endBackgroundTask(for: source.id)
            }

            switch source.type {
            case .synology:
                await scanSynology(
                    source: source,
                    directories: normalizedDirs,
                    resumeSongs: resumeSongs,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
            case .smb, .webdav, .ftp, .sftp, .nfs, .upnp, .jellyfin, .emby, .plex:
                await scanConnectorSource(
                    source: source,
                    directories: normalizedDirs,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
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
        endBackgroundTask(for: sourceID)
    }

    func removeCheckpoint(for sourceID: String) {
        checkpoints[sourceID] = nil
        persistCheckpoints()
        if scanStates[sourceID]?.canResume == true {
            scanStates[sourceID] = nil
        }
    }

    func removeSynologyAPI(for sourceID: String) {
        synologyAPIs[sourceID] = nil
    }

    // MARK: - Synology Scan

    private func scanSynology(
        source: MusicSource,
        directories: [String],
        resumeSongs: [Song],
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?
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
                        await scanSynology(
                            source: source,
                            directories: directories,
                            resumeSongs: resumeSongs,
                            library: library,
                            sourceStore: sourceStore,
                            scraperService: scraperService
                        )
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
        let stream = await scanner.scan(
            directories: directories,
            existingSongs: resumeSongs,
            startingCount: resumeSongs.count
        )

        do {
            var lastSongs: [Song] = []
            var lastIncrementalUpdate = 0
            for try await update in stream {
                try Task.checkCancellation()
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.totalCount = update.totalCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs

                if update.scannedCount - lastIncrementalUpdate >= 10 {
                    library.addSongs(lastSongs)
                    sourceStore.update(source.id) { $0.songCount = lastSongs.count }
                    persistCheckpoint(
                        sourceID: source.id,
                        directories: directories,
                        songs: lastSongs,
                        totalCount: update.totalCount,
                        currentFile: update.currentFile
                    )
                    lastIncrementalUpdate = update.scannedCount
                }
            }

            try Task.checkCancellation()
            completeScan(
                sourceID: source.id,
                songs: lastSongs,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService
            )
        } catch is CancellationError {
            // Scan was cancelled (e.g. source deleted) — clean up silently
            scanStates[source.id] = ScanState(isScanning: false)
        } catch {
            let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
            if trusted {
                // Retry scan after user trusted the domain
                scanStates[source.id] = ScanState(isScanning: true)
                await scanSynology(
                    source: source,
                    directories: directories,
                    resumeSongs: resumeSongs,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
                return
            }
            scanStates[source.id] = ScanState(
                isScanning: false,
                currentFile: error.localizedDescription
            )
        }
    }

    // MARK: - Connector Scan

    private func scanConnectorSource(
        source: MusicSource,
        directories: [String],
        resumeSongs: [Song],
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?
    ) async {
        let connector = sourceManager.connector(for: source)
        let scanner = ConnectorScanner(connector: connector, sourceID: source.id)
        let stream = await scanner.scan(
            directories: directories,
            existingSongs: resumeSongs,
            startingCount: resumeSongs.count
        )

        do {
            var lastSongs: [Song] = []
            var lastIncrementalUpdate = 0
            for try await update in stream {
                try Task.checkCancellation()
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.totalCount = update.totalCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs

                if update.scannedCount - lastIncrementalUpdate >= 10 {
                    library.addSongs(lastSongs)
                    sourceStore.update(source.id) { $0.songCount = lastSongs.count }
                    persistCheckpoint(
                        sourceID: source.id,
                        directories: directories,
                        songs: lastSongs,
                        totalCount: update.totalCount,
                        currentFile: update.currentFile
                    )
                    lastIncrementalUpdate = update.scannedCount
                }
            }

            try Task.checkCancellation()
            completeScan(
                sourceID: source.id,
                songs: lastSongs,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService
            )
        } catch is CancellationError {
            // Scan was cancelled (e.g. source deleted) — clean up silently
            scanStates[source.id] = ScanState(isScanning: false)
        } catch {
            let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
            if trusted {
                // Retry scan after user trusted the domain
                scanStates[source.id] = ScanState(isScanning: true)
                await scanConnectorSource(
                    source: source,
                    directories: directories,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
                return
            }
            scanStates[source.id] = ScanState(
                isScanning: false,
                currentFile: error.localizedDescription
            )
        }
    }

    private func completeScan(
        sourceID: String,
        songs: [Song],
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?
    ) {
        library.addSongs(songs)
        sourceStore.update(sourceID) {
            $0.songCount = songs.count
            $0.lastScannedAt = Date()
        }
        scraperService?.enqueueBackgroundEnrichment(for: songs, in: library)
        removeCheckpoint(for: sourceID)
        scanStates[sourceID]?.isScanning = false
        scanStates[sourceID]?.scannedCount = songs.count
        scanStates[sourceID]?.currentFile = "\(songs.count) \(String(localized: "songs_found"))"
    }

    // MARK: - Helpers

    private func loadCheckpoints() {
        guard let data = try? Data(contentsOf: checkpointURL),
              let decoded = try? decoder.decode([String: ScanCheckpoint].self, from: data) else {
            checkpoints = [:]
            return
        }

        checkpoints = decoded
        for (sourceID, checkpoint) in decoded {
            scanStates[sourceID] = ScanState(
                isScanning: false,
                currentFile: String(localized: "scan_resume_hint"),
                scannedCount: checkpoint.songs.count,
                totalCount: checkpoint.totalCount
            )
        }
    }

    private func persistCheckpoint(
        sourceID: String,
        directories: [String],
        songs: [Song],
        totalCount: Int,
        currentFile: String
    ) {
        checkpoints[sourceID] = ScanCheckpoint(
            directories: normalizedDirectories(directories),
            songs: songs,
            totalCount: totalCount,
            currentFile: currentFile,
            updatedAt: Date()
        )
        persistCheckpoints()
    }

    private func persistCheckpoints() {
        guard let data = try? encoder.encode(checkpoints) else { return }
        try? data.write(to: checkpointURL, options: .atomic)
    }

    private func beginBackgroundTask(for sourceID: String) {
        endBackgroundTask(for: sourceID)
        backgroundTaskIDs[sourceID] = UIApplication.shared.beginBackgroundTask(withName: "scan-\(sourceID)") { [weak self] in
            Task { @MainActor in
                self?.cancelScan(for: sourceID)
            }
        }
    }

    private func endBackgroundTask(for sourceID: String) {
        guard let taskID = backgroundTaskIDs.removeValue(forKey: sourceID),
              taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
    }

    private func normalizedDirectories(_ directories: [String]) -> [String] {
        SynologyScanner.deduplicateDirectories(directories).sorted()
    }

    private func resumeCheckpoint(for sourceID: String, directories: [String]) -> ScanCheckpoint? {
        guard let checkpoint = checkpoints[sourceID] else { return nil }
        guard checkpoint.directories == directories else {
            removeCheckpoint(for: sourceID)
            return nil
        }
        return checkpoint
    }

    private func decodeDirs(_ config: String?) -> [String] {
        guard let config, let data = config.data(using: .utf8),
              let dirs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return dirs
    }
}
