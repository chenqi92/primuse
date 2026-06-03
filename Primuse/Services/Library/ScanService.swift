import Foundation
import PrimuseKit
#if os(iOS)
import BackgroundTasks
#if os(iOS)
import UIKit
#endif
#endif

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
    #if os(iOS)
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]
    #endif

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

        // Media servers / Apple Music Library 都是自动全库扫描,没有"用户选
        // 目录"这一步,用 "/" 哨兵触发 connector.scanSongs(from: "/") 走全
        // 量列举。其余 NAS / Cloud / Protocol / Local 都依赖 extraConfig
        // 里持久化的目录列表。
        let dirs: [String]
        if source.type.isServerLibrary || source.type == .appleMusicLibrary {
            dirs = ["/"]
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
            // resume 阶段恢复 checkpoint 内容, 是部分扫描结果, 不应触发"已删除"
            // 通知 (otherwise listener 会把还没扫到的歌的本地缓存全清)。
            library.addSongs(resumeSongs, affectedSourceIDs: Set([source.id]), notifyRemovals: false)
            let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
            sourceStore.updateLocal(source.id) { $0.songCount = acceptedCount }
        }

        scanStates[source.id] = ScanState(
            isScanning: true,
            currentFile: String(localized: "source_diag_preparing_scan"),
            scannedCount: resumeCount,
            totalCount: resumeTotal
        )

        beginBackgroundTask(for: source.id)

        let task = Task {
            defer {
                activeTasks[source.id] = nil
                endBackgroundTask(for: source.id)
            }

            let preflight = await sourceManager.diagnose(source: source, directories: normalizedDirs)
            if preflight.blockingFailure != nil {
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: sourceManager.scanFailureMessage(for: preflight),
                    scannedCount: resumeCount,
                    totalCount: resumeTotal
                )
                return
            }

            scanStates[source.id]?.currentFile = checkpoint?.currentFile ?? ""

            switch source.type {
            case .synology:
                await scanSynology(
                    source: source,
                    directories: normalizedDirs,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
            case .smb, .webdav, .ftp, .sftp, .nfs, .upnp,
                 .jellyfin, .emby, .plex,
                 .subsonic, .navidrome, .airsonic, .gonic,
                 .qnap, .ugreen, .fnos, .s3,
                 .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123,
                 .local, .appleMusicLibrary:
                await scanConnectorSource(
                    source: source,
                    directories: normalizedDirs,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
            case .appleMusic:
                // Apple Music 不走文件 scan, 走 AppleMusicLibraryService.sync()
                // 拉 user library (用户在 Settings 里手动点同步)。这里 noop。
                break
            }
        }
        activeTasks[source.id] = task
    }

    /// Identifier used for BGProcessingTask scheduling.
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    nonisolated static let backgroundTaskIdentifier = "com.welape.yuanyin.scan-resume"

    /// 扫描期间向 library 批量提交的阈值。改大可以显著降低 main actor 上
    /// rebuildIndex / persistSnapshot 的频率, 避免 1w+ 首库 scale 时出现
    /// "扫描期间 UI 卡顿"。1w 首库下从原本的每 10 首提交一次 (1000 次
    /// rebuildIndex) 降到每 200 首一次 (50 次), 主线程阻塞时间下降 20×。
    private static let flushBatchSize = 200
    /// 即便没攒够 batchSize, 距离上次 flush 超过这个间隔也强制 flush 一次
    /// 让用户看到 "scanned X" 数字仍在动 (别等到扫描结束才一次性更新)。
    private static let flushInterval: TimeInterval = 1.5

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
            // Apple Music Library 扫描会触发 ITLibrary 初始化,弹出"访问其他
            // App 数据"的 macOS Sandbox 授权对话框。它是读本地 iTunes 数据库
            // 的全量枚举,没有"接着上次扫到一半的位置"这种增量语义,checkpoint
            // 没意义。所以启动时不主动恢复,等用户在源列表里手动点扫描再触发。
            if source.type == .appleMusicLibrary { continue }
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
        #if os(iOS)
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
        #endif
        // macOS has no BGTaskScheduler — scans run while the app is open.
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
        sourceManager: SourceManager,
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
                deviceName: source.rememberDevice ? AppConstants.trustedDeviceName : nil,
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
                            sourceManager: sourceManager,
                            library: library,
                            sourceStore: sourceStore,
                            scraperService: scraperService
                        )
                        return
                    }
                }
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: sourceManager.scanFailureMessage(
                        for: SourceError.connectionFailed(loginResult.errorMessage ?? "Login failed"),
                        source: source
                    )
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
            var lastFlushAt = Date()
            for try await update in stream {
                try Task.checkCancellation()
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.totalCount = update.totalCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs

                let pendingDelta = update.scannedCount - lastIncrementalUpdate
                let timeSinceFlush = Date().timeIntervalSince(lastFlushAt)
                if pendingDelta >= Self.flushBatchSize || (pendingDelta > 0 && timeSinceFlush >= Self.flushInterval) {
                    // 中间 flush ── lastSongs 是当前累积的部分扫描结果, 还没
                    // 扫到的歌会被 addSongs 临时移除, 下次 flush 又补回。
                    // 这种"伪移除"不该触发缓存清理, 否则扫描中用户的本地
                    // 缓存被反复清空。
                    library.addSongs(lastSongs, affectedSourceIDs: Set([source.id]), notifyRemovals: false)
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
                    lastFlushAt = Date()
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
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService
                )
                return
            }
            scanStates[source.id] = ScanState(
                isScanning: false,
                currentFile: sourceManager.scanFailureMessage(for: error, source: source)
            )
            Self.notifyScanFailed(sourceName: source.name, error: error)
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
            var lastFlushAt = Date()
            for try await update in stream {
                try Task.checkCancellation()
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.addedCount = update.addedCount
                scanStates[source.id]?.totalCount = update.totalCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs

                // Flush 阈值: 每 flushBatchSize 首 *新增* 一次, 或者距上次 flush
                // 超过 flushInterval 也强制 flush。原本是每 10 首一次, 1w 首库
                // 时 1000 次 rebuildIndex / persistSnapshot 把 main actor 卡到
                // 用户能感觉到。
                let pendingDelta = update.addedCount - lastIncrementalUpdate
                let timeSinceFlush = Date().timeIntervalSince(lastFlushAt)
                if pendingDelta >= Self.flushBatchSize || (pendingDelta > 0 && timeSinceFlush >= Self.flushInterval) {
                    // 中间 flush ── lastSongs 是当前累积的部分扫描结果, 还没
                    // 扫到的歌会被 addSongs 临时移除, 下次 flush 又补回。
                    // 这种"伪移除"不该触发缓存清理, 否则扫描中用户的本地
                    // 缓存被反复清空。
                    library.addSongs(lastSongs, affectedSourceIDs: Set([source.id]), notifyRemovals: false)
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
                    lastFlushAt = Date()
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
                currentFile: sourceManager.scanFailureMessage(for: error, source: source)
            )
            Self.notifyScanFailed(sourceName: source.name, error: error)
        }
    }

    /// Build & post the "scan failed" error notification. Only the
    /// localizedDescription leaks to the user — full error chains stay in the
    /// log via the existing `currentFile` debug field.
    private static func notifyScanFailed(sourceName: String, error: Error) {
        let title = String(localized: "notify_scan_failed_title")
        let format = String(localized: "notify_scan_failed_body")
        let body = String(format: format, sourceName, error.localizedDescription)
        Task { @MainActor in
            await UserNotificationService.shared.postError(
                category: .scanFailed,
                title: title,
                body: body
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
        library.addSongs(songs, affectedSourceIDs: Set([sourceID]))
        // Use the post-tombstone count from the library, not the raw scan
        // count — otherwise a deleted-then-rescanned song shows as still
        // present in the source card while the library actually filters it.
        let acceptedCount = library.songs.filter { $0.sourceID == sourceID }.count
        sourceStore.updateLocal(sourceID) {
            $0.songCount = acceptedCount
            $0.lastScannedAt = Date()
        }
        scraperService?.enqueueBackgroundEnrichment(for: songs, in: library)
        // 注意: 这里不做整库 prewarm。之前会一首歌拉 1MB head + 256KB tail,
        // 818 首 ~ 1GB 后台流量, 大部分歌用户根本不会听。删掉, 让 prewarm
        // 走「按需」路径: AudioPlayerService.play 时调 cacheInBackground
        // 给当前曲做 prewarm, 启动 task 给 currentSong + 队列做 prewarm。
        _ = sourceManager  // 参数保留兼容签名, 暂未使用
        // Wipe both checkpoint and live state. The source card now reads
        // `lastScannedAt` for the "scanned X songs" line; without clearing
        // scanStates, `canResume` would read true forever (totalCount is
        // always 0 since we removed Phase 1 counting) and the UI would
        // show "click to resume scan" on a finished source.
        checkpoints[sourceID] = nil
        persistCheckpoints()
        scanStates[sourceID] = nil
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
        #if os(iOS)
        endBackgroundTask(for: sourceID)
        backgroundTaskIDs[sourceID] = UIApplication.shared.beginBackgroundTask(withName: "scan-\(sourceID)") { [weak self] in
            Task { @MainActor in
                self?.cancelScan(for: sourceID)
            }
        }
        #endif
    }

    private func endBackgroundTask(for sourceID: String) {
        #if os(iOS)
        guard let taskID = backgroundTaskIDs.removeValue(forKey: sourceID),
              taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        #endif
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
