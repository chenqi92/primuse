import BackgroundTasks
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
        /// Newly-added songs from the current scan run (excludes already-known
        /// files that the scanner skipped). UI surfaces this as "新增 N 首"
        /// so a re-scan that finds nothing new shows 0 instead of "2205
        /// files scanned" — which used to make users think every file was
        /// being reprocessed.
        var addedCount: Int = 0
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
            let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
            sourceStore.updateLocal(source.id) { $0.songCount = acceptedCount }
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
            case .smb, .webdav, .ftp, .sftp, .nfs, .upnp,
                 .jellyfin, .emby, .plex,
                 .qnap, .ugreen, .fnos, .s3,
                 .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox,
                 .local:
                await scanConnectorSource(
                    source: source,
                    directories: normalizedDirs,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
            }
        }
        activeTasks[source.id] = task
    }

    /// Identifier used for BGProcessingTask scheduling.
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let backgroundTaskIdentifier = "com.welape.yuanyin.scan-resume"

    /// Re-launch any source whose scan was interrupted (has a checkpoint with
    /// unfinished progress) and is not already running. Idempotent — safe to
    /// call on every app foreground or background-task wake.
    func resumePendingScans(
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?
    ) {
        for (sourceID, state) in scanStates where state.canResume {
            guard activeTasks[sourceID] == nil,
                  let source = sourceStore.source(id: sourceID),
                  source.isEnabled, !source.isDeleted else { continue }
            scanSource(
                source,
                sourceManager: sourceManager,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService
            )
        }
    }

    /// Schedule a BGProcessingTask that iOS will fire when the device is
    /// idle (and ideally plugged in / on Wi-Fi). The task handler resumes
    /// any pending scans and runs metadata backfill. Should be called when
    /// the app moves to background.
    /// - Parameter backfillPending: pass `true` if `MetadataBackfillService`
    ///   still has bare songs to process — we'll schedule even when no scan
    ///   has a checkpoint, so backfill can keep running in the background.
    func scheduleBackgroundResumeIfNeeded(backfillPending: Bool = false) {
        // Only schedule if there's actually something pending.
        let hasScanWork = scanStates.values.contains(where: { $0.canResume || $0.isScanning })
        guard hasScanWork || backfillPending else { return }

        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        // Earliest wake — actual fire time is iOS's call.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskScheduler.Error.unavailable on simulator and when entitlement missing.
            // Don't crash — auto-resume on foreground still works.
            plog("⚠️ BGProcessing submit failed: \(error)")
        }
    }

    func cancelScan(for sourceID: String) {
        activeTasks[sourceID]?.cancel()
        activeTasks[sourceID] = nil
        scanStates[sourceID]?.isScanning = false
        endBackgroundTask(for: sourceID)
    }

    /// Cancel every in-flight scan. Used by the BGProcessingTask expiration
    /// handler so iOS doesn't kill us mid-write.
    func cancelAllActiveScans() {
        for sourceID in Array(activeTasks.keys) {
            cancelScan(for: sourceID)
        }
    }

    /// Polls until no scan is active. Used inside the BGProcessingTask handler
    /// so we can mark the task complete only after work finishes.
    func waitForActiveScansToComplete() async {
        while !activeTasks.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
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
                sourceStore.updateLocal(source.id) { $0.deviceId = did }
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
                    let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
                    sourceStore.updateLocal(source.id) { $0.songCount = acceptedCount }
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
            // Synology doesn't go through CloudPlaybackSource — skip prewarm sweep.
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
        // Pass songs from the live library (for this source) as the
        // existing-set, not just resumeSongs. Without this, re-scanning
        // a finished source would walk the full tree and yield every file
        // as "new" — wasteful, and the UI's "scanned X" counter looked
        // like all files were being reprocessed even when nothing changed
        // remotely. With it, the scanner skips known files at the
        // listFiles-stream level and `addedCount` tracks just the actual
        // delta.
        let knownExisting = library.songs.filter { $0.sourceID == source.id }
        let existingForScan = resumeSongs.isEmpty ? knownExisting : resumeSongs
        let stream = await scanner.scan(
            directories: directories,
            existingSongs: existingForScan,
            startingCount: existingForScan.count
        )

        do {
            var lastSongs: [Song] = []
            var lastIncrementalUpdate = 0
            for try await update in stream {
                try Task.checkCancellation()
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.addedCount = update.addedCount
                scanStates[source.id]?.totalCount = update.totalCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs

                // Flush every 10 *new* songs (not every 10 yields). With
                // incremental scan, yields and new songs are the same, but
                // when the scanner processes a song that was already in
                // the library this still avoids needless DB churn.
                if update.addedCount - lastIncrementalUpdate >= 10 {
                    library.addSongs(lastSongs)
                    let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
                    sourceStore.updateLocal(source.id) { $0.songCount = acceptedCount }
                    persistCheckpoint(
                        sourceID: source.id,
                        directories: directories,
                        songs: lastSongs,
                        totalCount: update.totalCount,
                        currentFile: update.currentFile
                    )
                    lastIncrementalUpdate = update.addedCount
                }
            }

            try Task.checkCancellation()
            completeScan(
                sourceID: source.id,
                songs: lastSongs,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService,
                sourceManager: sourceManager
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
        scraperService: MusicScraperService?,
        sourceManager: SourceManager? = nil
    ) {
        library.addSongs(songs)
        // Use the post-tombstone count from the library, not the raw scan
        // count — otherwise a deleted-then-rescanned song shows as still
        // present in the source card while the library actually filters it.
        let acceptedCount = library.songs.filter { $0.sourceID == sourceID }.count
        sourceStore.updateLocal(sourceID) {
            $0.songCount = acceptedCount
            $0.lastScannedAt = Date()
        }
        scraperService?.enqueueBackgroundEnrichment(for: songs, in: library)
        // Kick off background prewarm for cloud songs. Each call resolves
        // the CDN URL once (cached for 30 min in the connector) and stages
        // the head 256KB into `.partial`. Done one-at-a-time so a
        // 2k-song library doesn't open 2k concurrent HTTP connections —
        // the throttle inside `prewarmAllCloudSongs` does the queueing.
        if let sourceManager {
            prewarmAllCloudSongs(in: songs, sourceManager: sourceManager)
        }
        // Wipe both checkpoint and live state. The source card now reads
        // `lastScannedAt` for the "scanned X songs" line; without clearing
        // scanStates, `canResume` would read true forever (totalCount is
        // always 0 since we removed Phase 1 counting) and the UI would
        // show "click to resume scan" on a finished source.
        checkpoints[sourceID] = nil
        persistCheckpoints()
        scanStates[sourceID] = nil
    }

    /// Sequentially prewarm every cloud song in `songs` so that future
    /// `play(song:)` taps skip the CDN-HEAD round trip (~3-20s through a
    /// proxy) and the first SFB read hits disk instead of the network.
    /// Uses a single background `Task` with a `for` loop — explicit
    /// concurrency limit of 1 — so a fresh scan of 2k songs can't fire 2k
    /// parallel range fetches and trip Baidu's anti-abuse throttle.
    private func prewarmAllCloudSongs(in songs: [Song], sourceManager: SourceManager) {
        let candidates = songs.filter { $0.fileSize > 0 }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .background) { [weak sourceManager] in
            guard let sourceManager else { return }
            for song in candidates {
                if Task.isCancelled { return }
                let alreadyDone = await MainActor.run { sourceManager.isPrewarmed(song: song) }
                if alreadyDone { continue }
                guard await sourceManager.songSupportsRangeStreaming(song) else { continue }
                // `cacheInBackground` already does dedup + connector.connect()
                // + prewarmCloudSong inside its own Task. We await its
                // completion by inlining the same body so the for-loop
                // serialization is honoured (firing it as a fire-and-forget
                // Task per song would defeat the throttle).
                await sourceManager.prewarmCloudSongPublic(song: song)
            }
        }
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
