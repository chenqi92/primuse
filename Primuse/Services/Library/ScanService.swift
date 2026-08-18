import CryptoKit
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
    /// Full-metadata scanners report only IDs they actually inspected. AppServices
    /// wires this to MetadataBackfillService after both services are initialized.
    @ObservationIgnored var metadataInspectionHandler: ((Set<String>) -> Void)?
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
        var failureMessage: String?
        /// A safe first-pass snapshot retained unmatched rows. The next
        /// foreground scan is the explicit confirmation required before prune.
        var reconciliationMessage: String?
        /// A checkpoint may contain only an unfinished directory queue, before
        /// the scanner has discovered its first song.
        var hasPendingWork: Bool = false

        var progress: Double {
            guard totalCount > 0 else { return 0 }
            return Double(scannedCount) / Double(totalCount)
        }

        var canResume: Bool {
            !isScanning && (hasPendingWork
                || (scannedCount > 0 && (totalCount == 0 || scannedCount < totalCount)))
        }
    }

    private(set) var scanStates: [String: ScanState] = [:]
    var synologyAPIs: [String: SynologyAPI] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    /// Monotonic token bumped on every `scanSource` launch and every
    /// `cancelScan`. A scan task captures its generation at registration
    /// and checks it before any terminal write (defer cleanup, final
    /// `scanStates`/background-task release). Without this, a cancelled-
    /// but-still-suspended old task would, on resume, run its `defer` and
    /// wipe `activeTasks`/the UIBackgroundTask assertion belonging to a
    /// *new* scan the user launched in between — letting two scans of the
    /// same source run concurrently and clobber each other's state.
    /// Mirrors `MetadataBackfillService.workerGeneration`.
    private var scanGenerations: [String: Int] = [:]
    private var checkpoints: [String: ScanCheckpoint] = [:]
    /// Serial off-main checkpoint writes. A checkpoint can contain thousands
    /// of Song values, so JSON encoding it on the main actor visibly stalls
    /// scrolling even though scanning itself is asynchronous.
    private var checkpointWriteTask: Task<Bool, Never>?
    /// A checkpoint contains the complete accumulated song array. Encoding it
    /// after every 1.5-second library flush keeps a core busy for most of a
    /// large scan even though the work is off-main. Ten-second persistence is
    /// still frequent enough for resume while avoiding a queue of full-library
    /// JSON encodes. Cancellation and completion always force a final write.
    private var lastCheckpointPersistenceAt = Date.distantPast
    private static let checkpointPersistenceInterval: TimeInterval = 10
    #if os(iOS)
    private var backgroundTaskIDs: [String: UIBackgroundTaskIdentifier] = [:]
    #endif

    private let checkpointStore: ScanCheckpointFileStore
    private let syncStateURL: URL
    private let decoder = JSONDecoder()
    private var syncStates: [String: SourceSyncState] = [:]
    /// Invalidates folder indexes when a committed provider scan changes the
    /// ID/name/parent topology without adding or removing any songs.
    private(set) var folderHierarchyRevision = 0

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = appSupport.appendingPathComponent("Primuse", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedCheckpointURL = directory.appendingPathComponent("scan-checkpoints.json")
        let loadedCheckpoints = ScanCheckpointFileStore.load(from: resolvedCheckpointURL)
        checkpointStore = ScanCheckpointFileStore(
            checkpointURL: resolvedCheckpointURL,
            initialCheckpoints: loadedCheckpoints
        )
        syncStateURL = directory.appendingPathComponent("source-sync-states.json")
        decoder.dateDecodingStrategy = .iso8601
        loadCheckpoints(loadedCheckpoints)
        loadSyncStates()
    }

    func libraryFolderSyncIndex(
        for sourceID: String
    ) -> [String: SourceSyncIndexedItem] {
        syncStates[sourceID]?.index ?? [:]
    }

    func scanSource(
        _ source: MusicSource,
        mode: SourceSyncMode = .automatic,
        snapshotExecutionContext: BaiduSnapshotExecutionContext = .userInitiatedForeground,
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService? = nil
    ) {
        guard activeTasks[source.id] == nil else { return }
        guard !source.isDeleted else {
            removeCheckpoint(for: source.id)
            scanStates[source.id] = nil
            return
        }
        guard source.isEnabled else { return }

        // 整库来源没有额外的目录选择步骤。Local 已由用户选择的 basePath
        // 确定范围；媒体服务器与 Apple Music Library 也天然是完整资料库。
        // 统一用 "/" 哨兵触发 connector.scanSongs(from: "/")，避免 Local
        // 因 extraConfig 没有目录数组而在保存后静默跳过扫描。
        let dirs: [String]
        if source.type.scansEntireLibrary {
            dirs = ["/"]
        } else {
            dirs = source.scannedDirectories
            guard !dirs.isEmpty else { return }
        }

        let normalizedDirs = normalizedDirectories(dirs)
        let checkpointScopeFingerprint = Self.scopeFingerprint(
            for: source,
            directories: normalizedDirs
        )
        if mode == .deep {
            // “Deep Scan” is an explicit fresh reconciliation. The ordinary
            // scan action resumes a checkpoint; carrying that partial queue
            // into this mode would make the two operations behave identically.
            removeCheckpoint(for: source.id)
        }
        // Feiniu Music is a fast server-catalogue enumeration with strict
        // pagination invariants. A partial checkpoint is not resumable (the
        // next request must restart at page 1), and restoring one would make
        // an incomplete catalogue visible before the retry has succeeded.
        let requiresAtomicCatalogCommit = source.type == .fnMusic
        if requiresAtomicCatalogCommit {
            removeCheckpoint(for: source.id)
        }
        let checkpoint = requiresAtomicCatalogCommit || mode == .deep
            ? nil
            : resumeCheckpoint(
                for: source.id,
                directories: normalizedDirs,
                scopeFingerprint: checkpointScopeFingerprint
            )
        let resumeSongs = checkpoint?.songs ?? []
        let resumeCount = checkpoint?.songs.count ?? 0
        let resumeTotal = checkpoint?.totalCount ?? 0

        if !resumeSongs.isEmpty {
            // resume 阶段恢复 checkpoint 内容, 是部分扫描结果, 不应触发"已删除"
            // 通知 (otherwise listener 会把还没扫到的歌的本地缓存全清)。
            // 同样要带上 library 中该源的全部已知歌曲再 addSongs: 否则
            // checkpoint 只含部分歌, addSongs 会把其余已知歌从 songs 移除,
            // 进而 cleanPlaylist/cleanPlaybackHistory 把它们从歌单(含「我喜欢」)
            // 与最近播放里永久剔除。checkpoint 条目(可能带更新后的元数据)优先,
            // 已知歌仅用于补齐缺失项, 完整扫描结束后再做真正的删除对账。
            let resumeIDs = Set(resumeSongs.map(\.id))
            let knownExisting = library.songs.filter {
                $0.sourceID == source.id && !resumeIDs.contains($0.id)
            }
            library.addSongs(
                resumeSongs + knownExisting,
                affectedSourceIDs: Set([source.id]),
                notifyRemovals: false,
                pruneMissingSongs: false
            )
            let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
            sourceStore.updateLocal(source.id) { $0.songCount = acceptedCount }
        }

        scanStates[source.id] = ScanState(
            isScanning: true,
            currentFile: String(localized: "source_diag_preparing_scan"),
            scannedCount: resumeCount,
            totalCount: resumeTotal,
            hasPendingWork: true
        )

        // Make the scan intent durable before diagnose/login/connect can issue
        // network I/O. Existing progress for the same scope wins unchanged;
        // FnMusic receives only a restart-from-page-1 intent, never a partial
        // catalogue. Apple Music uses its separate library sync path.
        let initialCheckpointWrite: Task<Bool, Never>?
        if source.type == .appleMusic {
            initialCheckpointWrite = nil
        } else {
            checkpoints[source.id] = ScanCheckpointPreparationPolicy.preparingCheckpoint(
                existing: checkpoint,
                directories: normalizedDirs,
                mode: mode,
                scopeFingerprint: checkpointScopeFingerprint
            )
            initialCheckpointWrite = persistCheckpoints(force: true)
        }

        beginBackgroundTask(for: source.id)

        scanGenerations[source.id, default: 0] += 1
        let generation = scanGenerations[source.id] ?? 0

        let task = Task {
            defer {
                // Only release shared state if we're still the current scan.
                // A cancelled-but-resuming old task must not wipe the
                // activeTasks entry / background-task assertion of a newer
                // scan the user launched after cancelling this one.
                if isCurrentScan(source.id, generation: generation) {
                    activeTasks[source.id] = nil
                    endBackgroundTask(for: source.id)
                }
            }

            if let initialCheckpointWrite,
               await initialCheckpointWrite.value == false {
                guard !Task.isCancelled,
                      isCurrentScan(source.id, generation: generation),
                      sourceCanContinue(source.id, sourceStore: sourceStore) else { return }
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(
                        for: SourceError.connectionFailed("Unable to persist scan checkpoint"),
                        source: source
                    ),
                    scannedCount: resumeCount,
                    totalCount: resumeTotal
                )
                return
            }

            guard !Task.isCancelled,
                  isCurrentScan(source.id, generation: generation),
                  sourceCanContinue(source.id, sourceStore: sourceStore) else {
                if isCurrentScan(source.id, generation: generation) {
                    scanStates[source.id] = nil
                }
                return
            }

            // Synology has a dedicated authenticated scan path below and may
            // already hold the exact API session established by the directory
            // picker (including a just-completed TOTP challenge). Running the
            // generic connector preflight first can reuse a connector created
            // before the user corrected a bad password, falsely rejecting the
            // scan before that valid session gets a chance to run.
            let usesDedicatedSynologyScan = source.type == .synology
                && source.connectionConfiguration == nil
            if !usesDedicatedSynologyScan {
                let preflight = await sourceManager.diagnose(source: source, directories: normalizedDirs)
                guard isCurrentScan(source.id, generation: generation),
                      sourceCanContinue(source.id, sourceStore: sourceStore) else {
                    if isCurrentScan(source.id, generation: generation) {
                        scanStates[source.id] = nil
                    }
                    return
                }
                if preflight.wasCancelled {
                    recordScanInterruption(
                        sourceID: source.id,
                        scannedCount: resumeCount,
                        totalCount: resumeTotal
                    )
                    return
                }
                if preflight.blockingFailure != nil {
                    recordScanFailure(
                        sourceID: source.id,
                        message: sourceManager.scanFailureMessage(for: preflight),
                        scannedCount: resumeCount,
                        totalCount: resumeTotal
                    )
                    return
                }
            }

            scanStates[source.id]?.currentFile = checkpoints[source.id]?.currentFile
                ?? checkpoint?.currentFile
                ?? ""

            if usesDedicatedSynologyScan {
                await scanSynology(
                    source: source,
                    generation: generation,
                    directories: normalizedDirs,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService,
                    checkpoint: checkpoints[source.id] ?? checkpoint
                )
            } else if source.type != .appleMusic {
                await scanConnectorSource(
                    source: source,
                    generation: generation,
                    directories: normalizedDirs,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService,
                    mode: mode,
                    snapshotExecutionContext: snapshotExecutionContext,
                    checkpoint: checkpoints[source.id] ?? checkpoint
                )
            } else {
                // Apple Music 不走文件 scan, 走 AppleMusicLibraryService.sync()
                // 拉 user library (用户在 Settings 里手动点同步)。这里 noop。
            }
        }
        activeTasks[source.id] = task
    }

    /// Starts a fresh incremental scan after the user finishes changing a
    /// source's directory selection.
    ///
    /// Directory pickers persist their binding while the sheet is open. The
    /// caller captures the selection before presenting the picker and passes
    /// it here when the picker closes. Comparing normalized effective roots
    /// avoids rescanning for ordering changes or a child directory that is
    /// already covered by a selected parent.
    func scanAfterDirectorySelectionChange(
        sourceID: String,
        previousDirectories: [String],
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService? = nil
    ) {
        guard let source = sourceStore.source(id: sourceID),
              source.isEnabled,
              !source.isDeleted else { return }

        let previous = normalizedDirectories(previousDirectories)
        let current = normalizedDirectories(source.scannedDirectories)
        guard !current.isEmpty, current != previous else { return }

        // A checkpoint belongs to the old directory scope. If a scan is
        // currently running, invalidate it before launching the replacement;
        // generation fencing keeps the cancelled task from overwriting the
        // new scan's state when its async work eventually unwinds.
        cancelScan(for: sourceID)
        removeCheckpoint(for: sourceID)
        scanSource(
            source,
            mode: .deep,
            sourceManager: sourceManager,
            library: library,
            sourceStore: sourceStore,
            scraperService: scraperService
        )
    }

    /// Identifier used for BGProcessingTask scheduling.
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    nonisolated static let backgroundTaskIdentifier = "com.welape.yuanyin.scan-resume"

    /// 扫描期间向 library 批量提交的阈值。改大可以显著降低 main actor 上
    /// rebuildIndex / persistSnapshot 的频率, 避免 1w+ 首库 scale 时出现
    /// "扫描期间 UI 卡顿"。1w 首库下从原本的每 10 首提交一次 (1000 次
    /// rebuildIndex) 降到每 200 首一次 (50 次), 主线程阻塞时间下降 20×。
    private static let flushBatchSize = 200
    /// Scanner streams can yield much faster than the display refresh rate.
    /// Publishing progress four times a second is enough for smooth feedback
    /// without repeatedly invalidating the Sources hierarchy.
    private static let progressPublishInterval: TimeInterval = 0.75
    /// 即便没攒够 batchSize, 距离上次 flush 超过这个间隔也强制 flush 一次
    /// 让用户看到 "scanned X" 数字仍在动 (别等到扫描结束才一次性更新)。
    private static let flushInterval: TimeInterval = 1.5

    /// Re-launch any source whose scan was interrupted (has a checkpoint with
    /// unfinished progress) and is not already running. Idempotent — safe to
    /// call on every app foreground or background-task wake.
    func resumePendingScans(
        context: BaiduSnapshotExecutionContext = .foregroundResume,
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?
    ) {
        for (sourceID, state) in Array(scanStates) where state.canResume {
            guard activeTasks[sourceID] == nil else { continue }
            let source = sourceStore.source(id: sourceID)
            switch ScanCheckpointSourcePolicy.disposition(
                sourceExists: source != nil,
                isEnabled: source?.isEnabled ?? false,
                isDeleted: source?.isDeleted ?? true
            ) {
            case .discard:
                removeCheckpoint(for: sourceID)
                continue
            case .retain:
                continue
            case .resume:
                break
            }
            guard let source else { continue }
            // Apple Music Library 扫描会触发 ITLibrary 初始化,弹出"访问其他
            // App 数据"的 macOS Sandbox 授权对话框。它是读本地 iTunes 数据库
            // 的全量枚举,没有"接着上次扫到一半的位置"这种增量语义,checkpoint
            // 没意义。所以启动时不主动恢复,等用户在源列表里手动点扫描再触发。
            if source.type == .appleMusicLibrary { continue }
            if source.type == .baiduPan,
               case .deferred = BaiduSnapshotRefreshPolicy.eligibility(
                   context: context,
                   hasDeterminedNetwork: NetworkMonitor.shared.hasDeterminedPath,
                   isReachable: NetworkMonitor.shared.isReachable,
                   isExpensive: NetworkMonitor.shared.isExpensive,
                   isConstrained: NetworkMonitor.shared.isConstrained,
                   isLowPowerModeEnabled: Self.isLowPowerModeEnabled,
                   hasSeriousThermalPressure: Self.hasSeriousThermalPressure
               ) {
                continue
            }
            scanSource(
                source,
                snapshotExecutionContext: context,
                sourceManager: sourceManager,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService
            )
        }
    }

    /// Starts only cheap provider-native delta checks that are already backed
    /// by a committed cursor. It never performs the first scan and never walks
    /// NAS/WebDAV/SMB trees in the background.
    func startPeriodicQuickSyncIfNeeded(
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?
    ) {
        let now = Date()
        for source in sourceStore.sources {
            guard activeTasks[source.id] == nil,
                  source.isEnabled,
                  !source.isDeleted,
                  Self.supportsPeriodicNativeSync(source.type),
                  let directories = periodicDirectories(for: source),
                  let state = syncStates[source.id],
                  state.isUsable(
                      sourceID: source.id,
                      scopeFingerprint: Self.scopeFingerprint(for: source, directories: directories)
                  ),
                  !SourceSyncFolderTopologyPolicy.requiresRebuild(
                      sourceType: source.type,
                      state: state
                  ),
                  SourcePeriodicSyncPolicy.isDue(state, now: now) else {
                continue
            }
            scanSource(
                source,
                mode: .quick,
                sourceManager: sourceManager,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService
            )
        }
    }

    /// Earliest native-cursor refresh due date, used to submit the next iOS
    /// BGProcessing request even when there is no interrupted work.
    func nextPeriodicSyncDate(sourceStore: SourcesStore) -> Date? {
        sourceStore.sources.compactMap { source -> Date? in
            guard source.isEnabled,
                  !source.isDeleted,
                  Self.supportsPeriodicNativeSync(source.type),
                  let directories = periodicDirectories(for: source),
                  let state = syncStates[source.id],
                  state.isUsable(
                      sourceID: source.id,
                      scopeFingerprint: Self.scopeFingerprint(for: source, directories: directories)
                  ),
                  !SourceSyncFolderTopologyPolicy.requiresRebuild(
                      sourceType: source.type,
                      state: state
                  ) else {
                return nil
            }
            return SourcePeriodicSyncPolicy.nextSyncDate(for: state)
        }.min()
    }

    private nonisolated static func supportsPeriodicNativeSync(_ type: MusicSourceType) -> Bool {
        switch type {
        case .dropbox, .googleDrive, .oneDrive:
            return true
        default:
            return false
        }
    }

    private nonisolated static var isLowPowerModeEnabled: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        false
        #endif
    }

    private nonisolated static var hasSeriousThermalPressure: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            true
        case .nominal, .fair:
            false
        @unknown default:
            true
        }
    }

    private func periodicDirectories(for source: MusicSource) -> [String]? {
        let directories = source.type.scansEntireLibrary ? ["/"] : source.scannedDirectories
        guard !directories.isEmpty else { return nil }
        return normalizedDirectories(directories)
    }

    /// Schedule a BGProcessingTask that iOS will fire when the device is
    /// idle (and ideally plugged in / on Wi-Fi). The task handler resumes
    /// any pending scans and runs metadata backfill. Should be called when
    /// the app moves to background.
    /// - Parameter backfillPending: pass `true` if `MetadataBackfillService`
    ///   still has bare songs to process — we'll schedule even when no scan
    ///   has a checkpoint, so backfill can keep running in the background.
    func scheduleBackgroundResumeIfNeeded(
        backfillPending: Bool = false,
        scrapePending: Bool = false,
        sourceStore: SourcesStore? = nil
    ) {
        #if os(iOS)
        let hasScanWork = scanStates.contains { sourceID, state in
            guard state.canResume || state.isScanning else { return false }
            // Baidu has no native delta feed. Its resumable tree snapshot is
            // foreground-only and must never be the reason for a BGProcessing
            // wake that would enumerate the cloud tree behind the user's back.
            return sourceStore?.source(id: sourceID)?.type != .baiduPan
        }
        let periodicDate = sourceStore.flatMap { nextPeriodicSyncDate(sourceStore: $0) }
        guard hasScanWork || backfillPending || scrapePending || periodicDate != nil else { return }

        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        let immediateWork = hasScanWork || backfillPending || scrapePending
        let earliestUsefulWake = Date(timeIntervalSinceNow: 60)
        request.earliestBeginDate = immediateWork
            ? earliestUsefulWake
            : periodicDate.map { max($0, earliestUsefulWake) }
        do {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskScheduler.Error.unavailable on simulator and when entitlement missing.
            // Don't crash — auto-resume on foreground still works.
            plog("⚠️ BGProcessing submit failed: \(error)")
        }
        #endif
        // macOS has no BGTaskScheduler — scans run while the app is open.
    }

    /// True while `generation` is still the latest scan launched for this
    /// source. Used to fence terminal writes of a stale (cancelled) task.
    private func isCurrentScan(_ sourceID: String, generation: Int) -> Bool {
        scanGenerations[sourceID] == generation
    }

    func cancelScan(for sourceID: String) {
        activeTasks[sourceID]?.cancel()
        activeTasks[sourceID] = nil
        // Invalidate the cancelled task's generation so its still-suspended
        // body can't run terminal cleanup/state writes once it resumes.
        scanGenerations[sourceID, default: 0] += 1
        scanStates[sourceID]?.isScanning = false
        persistCheckpoints(force: true)
        endBackgroundTask(for: sourceID)
    }

    /// Cancel every in-flight scan. Used by the BGProcessingTask expiration
    /// handler so iOS doesn't kill us mid-write.
    func cancelAllActiveScans() {
        for sourceID in Array(activeTasks.keys) {
            cancelScan(for: sourceID)
        }
    }

    /// Baidu refresh is a foreground-only snapshot walk. If the user leaves
    /// the app mid-run, persist its queue and resume only after the app becomes
    /// active again; do not spend the finite UIKit background window traversing
    /// the cloud tree.
    func suspendForegroundOnlyScans(sourceStore: SourcesStore) {
        for sourceID in Array(activeTasks.keys)
        where sourceStore.source(id: sourceID)?.type == .baiduPan {
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
        persistCheckpoints(force: true)
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
        generation: Int,
        directories: [String],
        resumeSongs: [Song],
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?,
        checkpoint: ScanCheckpoint?
    ) async {
        let api: SynologyAPI
        if let existing = synologyAPIs[source.id] {
            api = existing
        } else {
            let created = SynologyAPI(
                host: source.host ?? "",
                port: source.port ?? 5001,
                useSsl: source.useSsl,
                connectionMode: source.effectiveSynologyConnectionMode
            )
            synologyAPIs[source.id] = created
            api = created
        }

        if await api.isLoggedIn == false {
            let password: String
            switch KeychainService.passwordLookup(for: source.id) {
            case .found(let savedPassword):
                password = savedPassword
            case .notFound:
                recordScanFailure(
                    sourceID: source.id,
                    message: String(localized: "scan_needs_connect")
                )
                return
            case .temporarilyUnavailable(let status):
                plog("⏳ Synology scan deferred: credential temporarily unavailable status=\(status)")
                recordScanFailure(
                    sourceID: source.id,
                    message: String(localized: "credential_temporarily_unavailable")
                )
                return
            case .failed(let status):
                plog("⛔ Synology scan stopped: credential read failed status=\(status)")
                recordScanFailure(
                    sourceID: source.id,
                    message: String(localized: "credential_read_failed")
                )
                return
            }
            let loginResult = await api.login(
                account: source.username ?? "",
                password: password,
                deviceName: source.rememberDevice ? AppConstants.trustedDeviceName : nil,
                deviceId: source.rememberDevice ? source.deviceId : nil
            )

            guard isCurrentScan(source.id, generation: generation) else { return }

            if loginResult.needs2FA {
                recordScanFailure(
                    sourceID: source.id,
                    message: loginResult.errorMessage ?? String(localized: "scan_needs_connect")
                )
                return
            }

            guard loginResult.success else {
                // Check if login failure is due to SSL certificate issue
                if let error = loginResult.underlyingError {
                    let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    if trusted {
                        guard isCurrentScan(source.id, generation: generation) else { return }
                        scanStates[source.id] = ScanState(isScanning: true)
                        await scanSynology(
                            source: source,
                            generation: generation,
                            directories: directories,
                            resumeSongs: resumeSongs,
                            sourceManager: sourceManager,
                            library: library,
                            sourceStore: sourceStore,
                            scraperService: scraperService,
                            checkpoint: checkpoints[source.id] ?? checkpoint
                        )
                        return
                    }
                }
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(
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
        // Seed the scanner with the live library songs for this source (not
        // just resumeSongs, which is empty on a fresh rescan) — same reason
        // as scanConnectorSource. Without it, each intermediate flush below
        // only carries the partially-scanned subset, so addSongs would strip
        // every not-yet-rescanned song from this source and cleanPlaylist/
        // cleanPlaybackHistory would permanently remove them from playlists
        // (incl. Liked) and recents. Carrying the known set through keeps the
        // flush sets complete; genuine deletions are still reconciled at the
        // scanner's terminal yield after a full walk.
        let knownExisting = library.songs.filter { $0.sourceID == source.id }
        // On resume, merge the known set in too (checkpoint entries win on id
        // collision) — passing only resumeSongs would drop the rest on the
        // first flush, exactly the stripping the comment above warns about.
        let existingForScan: [Song]
        if resumeSongs.isEmpty {
            existingForScan = knownExisting
        } else {
            let resumeIDs = Set(resumeSongs.map(\.id))
            existingForScan = resumeSongs + knownExisting.filter { !resumeIDs.contains($0.id) }
        }

        let nextScanEpoch = (syncStates[source.id]?.scanEpoch ?? 0) + 1
        let resumableDirectoryState: SourceScanResumeState? = {
            guard let state = checkpoint?.directoryState, state.isUsable else { return nil }
            return state
        }()
        let stream = await scanner.scan(
            directories: directories,
            existingSongs: existingForScan,
            startingCount: existingForScan.count,
            resumeState: resumableDirectoryState
        )

        do {
            var lastSongs: [Song] = []
            var lastIncrementalUpdate = 0
            var lastFlushAt = Date()
            var lastProgressPublishedAt = Date.distantPast
            var lastDirectoryState = resumableDirectoryState
            for try await update in stream {
                try Task.checkCancellation()
                try checkSourceStillEnabled(source.id, sourceStore: sourceStore)
                metadataInspectionHandler?(await scanner.takeMetadataInspectedSongIDs())
                publishScanProgress(
                    sourceID: source.id,
                    scannedCount: update.scannedCount,
                    addedCount: nil,
                    totalCount: update.totalCount,
                    currentFile: update.currentFile,
                    lastPublishedAt: &lastProgressPublishedAt
                )
                lastSongs = update.songs

                if let directoryState = update.resumeState {
                    lastDirectoryState = directoryState
                    persistCheckpoint(
                        sourceID: source.id,
                        directories: directories,
                        songs: lastSongs,
                        totalCount: update.totalCount,
                        currentFile: update.currentFile,
                        directoryState: directoryState
                    )
                }

                let pendingDelta = update.scannedCount - lastIncrementalUpdate
                let timeSinceFlush = Date().timeIntervalSince(lastFlushAt)
                if pendingDelta >= Self.flushBatchSize || (pendingDelta > 0 && timeSinceFlush >= Self.flushInterval) {
                    // 中间 flush ── lastSongs 是当前累积的部分扫描结果, 还没
                    // 扫到的歌会被 addSongs 临时移除, 下次 flush 又补回。
                    // 这种"伪移除"不该触发缓存清理, 否则扫描中用户的本地
                    // 缓存被反复清空。
                    library.addSongs(
                        lastSongs,
                        affectedSourceIDs: Set([source.id]),
                        notifyRemovals: false,
                        pruneMissingSongs: false
                    )
                    let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
                    sourceStore.updateLocal(source.id) { $0.songCount = acceptedCount }
                    if update.resumeState == nil {
                        persistCheckpoint(
                            sourceID: source.id,
                            directories: directories,
                            songs: lastSongs,
                            totalCount: update.totalCount,
                            currentFile: update.currentFile
                        )
                    }
                    lastIncrementalUpdate = update.scannedCount
                    lastFlushAt = Date()
                }
            }

            try Task.checkCancellation()
            try checkSourceStillEnabled(source.id, sourceStore: sourceStore)
            metadataInspectionHandler?(await scanner.takeMetadataInspectedSongIDs())
            // Synology doesn't go through CloudPlaybackSource — skip prewarm sweep.
            try await completeScan(
                sourceID: source.id,
                generation: generation,
                songs: lastSongs,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService,
                syncState: SourceSyncState(
                    sourceID: source.id,
                    scopeFingerprint: Self.scopeFingerprint(for: source, directories: directories),
                    index: lastDirectoryState?.index ?? [:],
                    scanEpoch: nextScanEpoch,
                    lastFullScanAt: Date(),
                    lastSuccessfulSyncAt: Date()
                )
            )
        } catch let error where OperationCancellationPolicy.isCancellation(error) {
            // Scan was cancelled (e.g. source deleted) — clean up silently.
            // Skip the write if a newer scan already took over this source,
            // otherwise we'd stomp its in-progress state back to idle.
            if isCurrentScan(source.id, generation: generation) {
                recordScanInterruption(sourceID: source.id)
            }
        } catch {
            guard isCurrentScan(source.id, generation: generation) else { return }
            let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
            if trusted {
                guard isCurrentScan(source.id, generation: generation) else { return }
                // Retry scan after user trusted the domain
                scanStates[source.id] = ScanState(isScanning: true)
                await scanSynology(
                    source: source,
                    generation: generation,
                    directories: directories,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService,
                    checkpoint: checkpoints[source.id] ?? checkpoint
                )
                return
            }
            recordScanFailure(
                sourceID: source.id,
                message: sourceManager.scanFailureMessage(for: error, source: source)
            )
            Self.notifyScanFailed(sourceName: source.name, error: error)
        }
    }

    // MARK: - Connector Scan

    private func scanConnectorSource(
        source: MusicSource,
        generation: Int,
        directories: [String],
        resumeSongs: [Song],
        sourceManager: SourceManager,
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?,
        mode: SourceSyncMode,
        snapshotExecutionContext: BaiduSnapshotExecutionContext,
        checkpoint: ScanCheckpoint?
    ) async {
        let connector = sourceManager.connector(for: source)
        let scanner = ConnectorScanner(connector: connector, sourceID: source.id)
        let requiresAtomicCatalogCommit = source.type == .fnMusic
        // Pass songs from the live library (for this source) as the
        // existing-set, not just resumeSongs. Without this, re-scanning
        // a finished source would walk the full tree and yield every file
        // as "new" — wasteful, and the UI's "scanned X" counter looked
        // like all files were being reprocessed even when nothing changed
        // remotely. With it, the scanner skips known files at the
        // listFiles-stream level and `addedCount` tracks just the actual
        // delta.
        let knownExisting = library.songs.filter { $0.sourceID == source.id }
        // On resume, the scanner must start from the *full* known set (seeded
        // into the library above), not just the checkpoint slice — otherwise
        // the first intermediate flush below drops every not-yet-rewalked song
        // and cleanPlaylistEntries() permanently un-playlists them.
        let existingForScan: [Song]
        if resumeSongs.isEmpty {
            existingForScan = knownExisting
        } else {
            let resumeIDs = Set(resumeSongs.map(\.id))
            existingForScan = resumeSongs + knownExisting.filter { !resumeIDs.contains($0.id) }
        }

        let scopeFingerprint = Self.scopeFingerprint(for: source, directories: directories)
        let identityScopeFingerprint = Self.scopeFingerprint(for: source, directories: [])
        let storedState = syncStates[source.id]
        let scopedState = storedState.flatMap { state in
            state.matchesScope(sourceID: source.id, scopeFingerprint: scopeFingerprint)
                ? state
                : nil
        }
        var workingState = scopedState

        if connector is any ResumableSnapshotMusicSourceConnector {
            let reusableState: SourceSyncState? = if let scopedState {
                scopedState
            } else if storedState?.matchesIdentityScope(
                sourceID: source.id,
                identityScopeFingerprint: identityScopeFingerprint
            ) == true {
                storedState
            } else {
                nil
            }
            if storedState == nil || reusableState != nil {
                workingState = Self.legacyBaiduState(
                    base: reusableState,
                    sourceID: source.id,
                    scopeFingerprint: scopeFingerprint,
                    identityScopeFingerprint: identityScopeFingerprint,
                    songs: existingForScan
                )
            }
        }

        if connector is any ResumableSnapshotMusicSourceConnector,
           case .deferred = BaiduSnapshotRefreshPolicy.eligibility(
               context: snapshotExecutionContext,
               hasDeterminedNetwork: NetworkMonitor.shared.hasDeterminedPath,
               isReachable: NetworkMonitor.shared.isReachable,
               isExpensive: NetworkMonitor.shared.isExpensive,
               isConstrained: NetworkMonitor.shared.isConstrained,
               isLowPowerModeEnabled: Self.isLowPowerModeEnabled,
               hasSeriousThermalPressure: Self.hasSeriousThermalPressure
           ) {
            recordScanInterruption(sourceID: source.id)
            return
        }

        var effectiveDirectories = directories
        var rootIdentities = workingState?.rootIdentities ?? []
        if let rootConnector = connector as? any PersistentRootIdentityConnector {
            do {
                let resolution = try await rootConnector.resolveRootIdentities(
                    configuredRoots: directories,
                    previous: rootIdentities
                )
                effectiveDirectories = resolution.effectiveRoots
                rootIdentities = resolution.identities
            } catch SourceRootResolutionError.requiresReselection(let path) {
                do {
                    try await clearCheckpointAndWait(for: source.id)
                } catch {
                    plog("⛔ Unable to clear relocated-root checkpoint for \(source.name): \(error.localizedDescription)")
                }
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(
                        for: SourceError.pathNotFound(path),
                        source: source
                    )
                )
                return
            } catch let error where OperationCancellationPolicy.isCancellation(error) {
                recordScanInterruption(sourceID: source.id)
                return
            } catch {
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(for: error, source: source)
                )
                return
            }
        }

        let quickOnly = checkpoint?.isQuickOnly == true
            || (checkpoint == nil && mode == .quick)
        let supportsStatefulRefresh = connector is any IncrementalMusicSourceConnector
            || connector is any ResumableSnapshotMusicSourceConnector
        if checkpoint?.permitsStatefulRefresh != false,
           mode != .deep,
           supportsStatefulRefresh,
           let state = workingState,
           state.isUsable(sourceID: source.id, scopeFingerprint: scopeFingerprint),
           !SourceSyncFolderTopologyPolicy.requiresRebuild(
               sourceType: source.type,
               state: state
           ),
           !state.cursors.isEmpty
                || (connector is any ResumableSnapshotMusicSourceConnector
                    && (!state.index.isEmpty || checkpoint?.baiduSnapshotState != nil)) {
            do {
                if try await performQuickSync(
                    source: source,
                    generation: generation,
                    directories: effectiveDirectories,
                    state: state,
                    connector: connector,
                    scanner: scanner,
                    existingSongs: existingForScan,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService,
                    sourceManager: sourceManager,
                    rootIdentities: rootIdentities,
                    checkpoint: checkpoint
                ) {
                    return
                }
            } catch let error where OperationCancellationPolicy.isCancellation(error) {
                if isCurrentScan(source.id, generation: generation) {
                    if connector is any ResumableSnapshotMusicSourceConnector {
                        try? await waitForCheckpointPersistence()
                    }
                    recordScanInterruption(sourceID: source.id)
                }
                return
            } catch BaiduSnapshotExecutionError.snapshotRestartRequired(let telemetry) {
                if let checkpoint = checkpoints[source.id] {
                    checkpoints[source.id] = checkpoint.restartingSnapshotTraversal(
                        telemetry: telemetry
                    )
                    persistCheckpoints(force: true)
                }
                do {
                    try await waitForCheckpointPersistence()
                } catch {
                    recordScanFailure(
                        sourceID: source.id,
                        message: sourceManager.scanFailureMessage(for: error, source: source)
                    )
                    return
                }
                recordScanInterruption(sourceID: source.id)
                return
            } catch BaiduSnapshotExecutionError.reconciliationRequiresDeepScan(let telemetry) {
                if var diagnosticState = syncStates[source.id] {
                    diagnosticState.lastTelemetry = telemetry
                    try? await persistSyncState(diagnosticState)
                }
                do {
                    try await clearCheckpointAndWait(for: source.id)
                } catch {
                    recordScanFailure(
                        sourceID: source.id,
                        message: sourceManager.scanFailureMessage(for: error, source: source)
                    )
                    return
                }
                recordScanFailure(
                    sourceID: source.id,
                    message: String(localized: "baidu_snapshot_deep_scan_required")
                )
                return
            } catch BaiduSnapshotExecutionError.budgetExhausted(_, let telemetry) {
                if var checkpoint = checkpoints[source.id] {
                    checkpoint.baiduTelemetry = telemetry
                    checkpoint.updatedAt = Date()
                    checkpoints[source.id] = checkpoint
                    persistCheckpoints(force: true)
                }
                do {
                    try await waitForCheckpointPersistence()
                } catch {
                    recordScanFailure(
                        sourceID: source.id,
                        message: sourceManager.scanFailureMessage(for: error, source: source)
                    )
                    return
                }
                recordScanInterruption(sourceID: source.id)
                return
            } catch {
                plog("⚠️ Quick sync failed for \(source.name); keeping committed cursor: \(error.localizedDescription)")
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(for: error, source: source)
                )
                return
            }
        }

        if quickOnly {
            do {
                if var deepRequiredState = scopedState {
                    deepRequiredState.requiresDeepScan = true
                    try await persistSyncState(deepRequiredState)
                }
                try await clearCheckpointAndWait(for: source.id)
                guard isCurrentScan(source.id, generation: generation) else { return }
                scanStates[source.id] = nil
            } catch {
                guard isCurrentScan(source.id, generation: generation) else { return }
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(for: error, source: source)
                )
            }
            return
        }

        do {
            // From this point onward the operation is a full walk. Persist the
            // promotion so an explicit deep scan or an automatic deep fallback
            // cannot turn back into a provider quick sync after cold launch.
            try await promoteCheckpointToFullScanAndWait(for: source.id)
        } catch {
            guard isCurrentScan(source.id, generation: generation) else { return }
            recordScanFailure(
                sourceID: source.id,
                message: sourceManager.scanFailureMessage(for: error, source: source)
            )
            return
        }

        var baselineCursors = checkpoint?.baselineCursors ?? [:]
        if baselineCursors.isEmpty, supportsStatefulRefresh {
            do {
                if let snapshot = connector as? any ResumableSnapshotMusicSourceConnector {
                    baselineCursors = try await snapshot.initialSnapshotMarker(
                        for: effectiveDirectories
                    )
                } else if let incremental = connector as? any IncrementalMusicSourceConnector {
                    baselineCursors = try await incremental.initialChangeCursors(
                        for: effectiveDirectories
                    )
                }
            } catch {
                // The full scan is still useful. Mark the state for another
                // deep scan rather than claiming stateful refresh coverage.
                plog("⚠️ Unable to capture synchronization baseline for \(source.name): \(error.localizedDescription)")
            }
        }
        if !baselineCursors.isEmpty {
            do {
                try await persistBaselineCursorsAndWait(
                    baselineCursors,
                    sourceID: source.id
                )
            } catch {
                guard isCurrentScan(source.id, generation: generation) else { return }
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(for: error, source: source)
                )
                return
            }
        }
        let nextScanEpoch = (workingState?.scanEpoch ?? 0) + 1
        let resumableDirectoryState: SourceScanResumeState? = {
            guard (checkpoint?.resolvedDirectories ?? directories) == effectiveDirectories,
                  let state = checkpoint?.directoryState,
                  state.isUsable else { return nil }
            return state
        }()
        let stream = await scanner.scan(
            directories: effectiveDirectories,
            existingSongs: existingForScan,
            startingCount: existingForScan.count,
            resumeState: resumableDirectoryState,
            identityIndex: SourceSyncIdentityReusePolicy.reusableIndex(
                from: workingState,
                sourceID: source.id,
                scopeFingerprint: scopeFingerprint
            ),
            identityMissingStableKeys: workingState?.missingStableKeys ?? [:],
            scanEpoch: nextScanEpoch
        )

        do {
            var lastSongs: [Song] = []
            var lastIncrementalUpdate = 0
            var lastFlushAt = Date()
            var lastProgressPublishedAt = Date.distantPast
            for try await update in stream {
                try Task.checkCancellation()
                try checkSourceStillEnabled(source.id, sourceStore: sourceStore)
                metadataInspectionHandler?(await scanner.takeMetadataInspectedSongIDs())
                publishScanProgress(
                    sourceID: source.id,
                    scannedCount: update.scannedCount,
                    addedCount: update.addedCount,
                    totalCount: update.totalCount,
                    currentFile: update.currentFile,
                    lastPublishedAt: &lastProgressPublishedAt
                )
                lastSongs = update.songs

                if let directoryState = update.resumeState {
                    // Update the in-memory checkpoint on every completed (or
                    // in-flight) directory. Disk encoding remains throttled;
                    // cancellation forces the latest snapshot to disk.
                    persistCheckpoint(
                        sourceID: source.id,
                        directories: directories,
                        songs: lastSongs,
                        totalCount: update.totalCount,
                        currentFile: update.currentFile,
                        directoryState: directoryState,
                        baselineCursors: baselineCursors,
                        resolvedDirectories: effectiveDirectories
                    )
                }

                // Flush 阈值: 每 flushBatchSize 首 *新增* 一次, 或者距上次 flush
                // 超过 flushInterval 也强制 flush。原本是每 10 首一次, 1w 首库
                // 时 1000 次 rebuildIndex / persistSnapshot 把 main actor 卡到
                // 用户能感觉到。
                let pendingDelta = update.addedCount - lastIncrementalUpdate
                let timeSinceFlush = Date().timeIntervalSince(lastFlushAt)
                let shouldFlushIncrementally = pendingDelta >= Self.flushBatchSize
                    || (pendingDelta > 0 && timeSinceFlush >= Self.flushInterval)
                if !requiresAtomicCatalogCommit, shouldFlushIncrementally {
                    // 中间 flush ── lastSongs 是当前累积的部分扫描结果, 还没
                    // 扫到的歌会被 addSongs 临时移除, 下次 flush 又补回。
                    // 这种"伪移除"不该触发缓存清理, 否则扫描中用户的本地
                    // 缓存被反复清空。
                    library.addSongs(
                        lastSongs,
                        affectedSourceIDs: Set([source.id]),
                        notifyRemovals: false,
                        pruneMissingSongs: false
                    )
                    let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
                    sourceStore.updateLocal(source.id) { $0.songCount = acceptedCount }
                    if update.resumeState == nil {
                        persistCheckpoint(
                            sourceID: source.id,
                            directories: directories,
                            songs: lastSongs,
                            totalCount: update.totalCount,
                            currentFile: update.currentFile,
                            baselineCursors: baselineCursors,
                            resolvedDirectories: effectiveDirectories
                        )
                    }
                    lastIncrementalUpdate = update.addedCount
                    lastFlushAt = Date()
                }
            }

            try Task.checkCancellation()
            try checkSourceStillEnabled(source.id, sourceStore: sourceStore)
            metadataInspectionHandler?(await scanner.takeMetadataInspectedSongIDs())
            let scanIndex = await scanner.syncIndexSnapshot()
            let scanReconciliation = await scanner.syncReconciliationSnapshot()
            let candidateState = SourceSyncState(
                sourceID: source.id,
                scopeFingerprint: scopeFingerprint,
                identityScopeFingerprint: identityScopeFingerprint,
                cursors: baselineCursors,
                index: scanIndex,
                pendingDirectories: [],
                scanEpoch: nextScanEpoch,
                requiresDeepScan: supportsStatefulRefresh && baselineCursors.isEmpty,
                lastFullScanAt: Date(),
                lastSuccessfulSyncAt: Date(),
                identityAliases: workingState?.identityAliases ?? [:],
                rootIdentities: rootIdentities,
                reconciliation: scanReconciliation.reconciliation,
                missingStableKeys: scanReconciliation.missingStableKeys
            )
            try await completeScan(
                sourceID: source.id,
                generation: generation,
                songs: lastSongs,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService,
                sourceManager: sourceManager,
                syncState: candidateState,
                source: source
            )
        } catch let error where OperationCancellationPolicy.isCancellation(error) {
            // Scan was cancelled (e.g. source deleted) — clean up silently.
            // Skip the write if a newer scan already took over this source,
            // otherwise we'd stomp its in-progress state back to idle.
            if isCurrentScan(source.id, generation: generation) {
                recordScanInterruption(sourceID: source.id)
            }
        } catch {
            guard isCurrentScan(source.id, generation: generation) else { return }
            if Self.isMissingConnectorRootError(error) {
                // ConnectorScanner only lets a missing-path error escape for
                // a selected root. Clear its durable resume intent so the UI
                // cannot loop forever on "Continue Scan" with that stale root.
                do {
                    try await clearCheckpointAndWait(for: source.id)
                } catch {
                    plog("⛔ Unable to clear missing-root checkpoint for \(source.name): \(error.localizedDescription)")
                }
                recordScanFailure(
                    sourceID: source.id,
                    message: sourceManager.scanFailureMessage(for: error, source: source)
                )
                Self.notifyScanFailed(sourceName: source.name, error: error)
                return
            }
            let trusted = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
            if trusted {
                guard isCurrentScan(source.id, generation: generation) else { return }
                // Retry scan after user trusted the domain
                scanStates[source.id] = ScanState(isScanning: true)
                await scanConnectorSource(
                    source: source,
                    generation: generation,
                    directories: directories,
                    resumeSongs: resumeSongs,
                    sourceManager: sourceManager,
                    library: library,
                    sourceStore: sourceStore,
                    scraperService: scraperService,
                    mode: mode,
                    snapshotExecutionContext: snapshotExecutionContext,
                    checkpoint: checkpoints[source.id] ?? checkpoint
                )
                return
            }
            recordScanFailure(
                sourceID: source.id,
                message: sourceManager.scanFailureMessage(for: error, source: source)
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

    private func performQuickSync(
        source: MusicSource,
        generation: Int,
        directories: [String],
        state: SourceSyncState,
        connector: any MusicSourceConnector,
        scanner: ConnectorScanner,
        existingSongs: [Song],
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?,
        sourceManager: SourceManager,
        rootIdentities: [SourceSyncRootIdentity],
        checkpoint: ScanCheckpoint?
    ) async throws -> Bool {
        scanStates[source.id]?.currentFile = String(localized: "source_quick_sync")
        let snapshotBudget = BaiduSnapshotRefreshBudget()
        let changes: IncrementalSourceChanges
        if let snapshotConnector = connector as? any ResumableSnapshotMusicSourceConnector {
            changes = try await snapshotConnector.snapshotChanges(
                from: state,
                roots: directories,
                rootIdentities: rootIdentities,
                resumeState: checkpoint?.baiduSnapshotState,
                budget: snapshotBudget
            ) { [weak self] resumeState, telemetry in
                await self?.persistBaiduSnapshotProgress(
                    sourceID: source.id,
                    generation: generation,
                    effectiveDirectories: directories,
                    resumeState: resumeState,
                    telemetry: telemetry
                )
            }
        } else if let incremental = connector as? any IncrementalMusicSourceConnector {
            changes = try await incremental.changes(
                since: state.cursors,
                roots: directories,
                index: state.index
            )
        } else {
            return false
        }
        guard !changes.requiresDeepScan else {
            plog("↻ Native cursor requires a deep reconciliation for \(source.name)")
            return false
        }
        try Task.checkCancellation()
        try checkSourceStillEnabled(source.id, sourceStore: sourceStore)
        guard isCurrentScan(source.id, generation: generation) else {
            throw CancellationError()
        }

        let nextScanEpoch = state.scanEpoch + 1
        if changes.changedParentPaths.isEmpty && changes.deletedStableKeys.isEmpty {
            var candidateState = state
            candidateState.cursors = changes.cursors
            candidateState.index = changes.reconciledIndex ?? state.index
            candidateState.pendingDirectories = []
            candidateState.scanEpoch = nextScanEpoch
            candidateState.requiresDeepScan = false
            candidateState.lastSuccessfulSyncAt = Date()
            candidateState.identityAliases = changes.identityAliases
                ?? candidateState.identityAliases
            candidateState.rootIdentities = changes.rootIdentities
                ?? candidateState.rootIdentities
            candidateState.missingStableKeys = changes.missingStableKeys
                ?? candidateState.missingStableKeys
            candidateState.reconciliation = changes.reconciliation
            candidateState.lastTelemetry = changes.telemetry

            // The provider cursor advanced, but the committed library snapshot
            // did not change. Persisting the whole JSON library here turns a
            // no-op sync of a large catalog into an avoidable full rewrite.
            try await persistSyncState(candidateState)
            let acceptedCount = library.songs.filter { $0.sourceID == source.id }.count
            sourceStore.updateLocal(source.id) {
                $0.songCount = acceptedCount
                $0.lastScannedAt = Date()
            }
            try await clearCheckpointAndWait(for: source.id)
            guard isCurrentScan(source.id, generation: generation) else {
                throw CancellationError()
            }
            scanStates[source.id] = Self.completedScanState(
                reconciliation: candidateState.reconciliation
            )
            return true
        }

        if let telemetry = changes.telemetry,
           telemetry.directoryCount + changes.changedParentPaths.count
                > snapshotBudget.maximumDirectories {
            var exhausted = telemetry
            exhausted.budgetExhausted = true
            exhausted.stopReason = .directories
            throw BaiduSnapshotExecutionError.reconciliationRequiresDeepScan(exhausted)
        }

        let requiresCompleteListings = connector is any ResumableSnapshotMusicSourceConnector
        let result: ConnectorScanner.IncrementalResult
        var combinedTelemetry = changes.telemetry
        if requiresCompleteListings,
           let budgeted = connector as? any SnapshotReconciliationBudgetConnector {
            await budgeted.beginSnapshotReconciliationBudget(
                snapshotBudget,
                consumed: changes.telemetry
            )
            do {
                result = try await scanner.reconcileChangedDirectories(
                    changes.changedParentPaths,
                    deletedStableKeys: changes.deletedStableKeys,
                    existingSongs: existingSongs,
                    existingIndex: changes.reconciledIndex ?? state.index,
                    scanEpoch: nextScanEpoch,
                    requiresCompleteListings: true
                )
                combinedTelemetry = await budgeted.finishSnapshotReconciliationBudget()
                    ?? combinedTelemetry
            } catch let error as BaiduSnapshotExecutionError {
                let finalTelemetry = await budgeted.finishSnapshotReconciliationBudget()
                if case .budgetExhausted = error {
                    throw BaiduSnapshotExecutionError.reconciliationRequiresDeepScan(
                        finalTelemetry ?? changes.telemetry ?? SourceSyncTelemetry(
                            budgetExhausted: true
                        )
                    )
                }
                throw error
            } catch {
                _ = await budgeted.finishSnapshotReconciliationBudget()
                throw error
            }
        } else {
            result = try await scanner.reconcileChangedDirectories(
                changes.changedParentPaths,
                deletedStableKeys: changes.deletedStableKeys,
                existingSongs: existingSongs,
                existingIndex: changes.reconciledIndex ?? state.index,
                scanEpoch: nextScanEpoch,
                requiresCompleteListings: false
            )
        }
        var candidateState = state
        candidateState.cursors = changes.cursors
        candidateState.index = result.index
        candidateState.pendingDirectories = []
        candidateState.scanEpoch = nextScanEpoch
        candidateState.requiresDeepScan = false
        candidateState.lastSuccessfulSyncAt = Date()
        candidateState.identityAliases = changes.identityAliases
            ?? candidateState.identityAliases
        candidateState.rootIdentities = changes.rootIdentities
            ?? candidateState.rootIdentities
        candidateState.missingStableKeys = changes.missingStableKeys
            ?? candidateState.missingStableKeys
        candidateState.reconciliation = changes.reconciliation
        candidateState.lastTelemetry = combinedTelemetry

        var progressTimestamp = Date.distantPast
        publishScanProgress(
            sourceID: source.id,
            scannedCount: result.songs.count,
            addedCount: result.changedCount,
            totalCount: result.songs.count,
            currentFile: "",
            lastPublishedAt: &progressTimestamp
        )
        try await completeScan(
            sourceID: source.id,
            generation: generation,
            songs: result.songs,
            library: library,
            sourceStore: sourceStore,
            scraperService: scraperService,
            sourceManager: sourceManager,
            syncState: candidateState,
            source: source
        )
        return true
    }

    private func completeScan(
        sourceID: String,
        generation: Int,
        songs: [Song],
        library: MusicLibrary,
        sourceStore: SourcesStore,
        scraperService: MusicScraperService?,
        sourceManager: SourceManager? = nil,
        syncState: SourceSyncState? = nil,
        source: MusicSource? = nil
    ) async throws {
        guard isCurrentScan(sourceID, generation: generation) else {
            throw CancellationError()
        }
        library.addSongs(songs, affectedSourceIDs: Set([sourceID]))
        guard case .success = await library.persistIncrementalNowAndWait() else {
            throw SourceError.connectionFailed("Unable to persist the music library")
        }
        guard isCurrentScan(sourceID, generation: generation) else {
            throw CancellationError()
        }
        if let syncState {
            try await persistSyncState(syncState)
        }
        guard isCurrentScan(sourceID, generation: generation) else {
            throw CancellationError()
        }
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
        // Wipe both checkpoint and live state. The source card now reads
        // `lastScannedAt` for the "scanned X songs" line; without clearing
        // scanStates, `canResume` would read true forever (totalCount is
        // always 0 since we removed Phase 1 counting) and the UI would
        // show "click to resume scan" on a finished source.
        try await clearCheckpointAndWait(for: sourceID)
        guard isCurrentScan(sourceID, generation: generation) else {
            throw CancellationError()
        }
        scanStates[sourceID] = Self.completedScanState(
            reconciliation: syncState?.reconciliation
        )

        // 歌单镜像放在扫描收尾之后: 曲库已经落库(上面 addSongs +
        // persistIncrementalNowAndWait), serverItemID → Song.id 的索引才是完整的;
        // 而且这一步的网络往返不会推迟"扫描完成"在 UI 上的呈现。
        if let source, let sourceManager, source.type.isServerLibrary {
            await ServerPlaylistSyncService.sync(
                source: source,
                sourceManager: sourceManager,
                library: library
            )
        }
    }

    // MARK: - Helpers

    private func publishScanProgress(
        sourceID: String,
        scannedCount: Int,
        addedCount: Int?,
        totalCount: Int,
        currentFile: String,
        lastPublishedAt: inout Date
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= Self.progressPublishInterval else {
            return
        }
        var state = scanStates[sourceID] ?? ScanState(isScanning: true)
        state.isScanning = true
        state.scannedCount = scannedCount
        if let addedCount {
            state.addedCount = addedCount
        }
        state.totalCount = totalCount
        state.currentFile = currentFile
        state.failureMessage = nil
        state.reconciliationMessage = nil
        // One dictionary write produces one observation change instead of
        // publishing each ScanState field independently.
        scanStates[sourceID] = state
        lastPublishedAt = now
    }

    private func recordScanFailure(
        sourceID: String,
        message: String,
        scannedCount: Int? = nil,
        totalCount: Int? = nil
    ) {
        var state = scanStates[sourceID] ?? ScanState()
        state.isScanning = false
        state.failureMessage = message
        state.reconciliationMessage = nil
        state.hasPendingWork = checkpoints[sourceID] != nil
        if let scannedCount {
            state.scannedCount = scannedCount
        }
        if let totalCount {
            state.totalCount = totalCount
        }
        scanStates[sourceID] = state
    }

    private func recordScanInterruption(
        sourceID: String,
        scannedCount: Int? = nil,
        totalCount: Int? = nil
    ) {
        var state = scanStates[sourceID] ?? ScanState()
        state.isScanning = false
        state.failureMessage = nil
        state.hasPendingWork = checkpoints[sourceID] != nil
        if let scannedCount {
            state.scannedCount = scannedCount
        }
        if let totalCount {
            state.totalCount = totalCount
        }
        scanStates[sourceID] = state
    }

    private func loadCheckpoints(_ decoded: [String: ScanCheckpoint]) {
        checkpoints = decoded
        for (sourceID, checkpoint) in decoded {
            scanStates[sourceID] = ScanState(
                isScanning: false,
                currentFile: String(localized: "scan_resume_hint"),
                scannedCount: checkpoint.songs.count,
                totalCount: checkpoint.totalCount,
                hasPendingWork: true
            )
        }
    }

    private func loadSyncStates() {
        guard let data = try? Data(contentsOf: syncStateURL),
              let decoded = try? decoder.decode([String: SourceSyncState].self, from: data) else {
            syncStates = [:]
            return
        }
        syncStates = decoded
        for (sourceID, state) in decoded
        where state.reconciliation != nil && scanStates[sourceID] == nil {
            scanStates[sourceID] = Self.completedScanState(
                reconciliation: state.reconciliation
            )
        }
    }

    private static func completedScanState(
        reconciliation: SourceSyncReconciliation?
    ) -> ScanState? {
        guard reconciliation != nil else { return nil }
        return ScanState(
            isScanning: false,
            reconciliationMessage: String(localized: "baidu_snapshot_reconciliation_required")
        )
    }

    private func persistSyncState(_ state: SourceSyncState) async throws {
        var snapshot = syncStates
        snapshot[state.sourceID] = state
        let url = syncStateURL
        let succeeded = await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                plog("⛔ Source sync state persistence failed: \(error.localizedDescription)")
                return false
            }
        }.value
        guard succeeded else {
            throw SourceError.connectionFailed("Unable to persist source sync state")
        }
        syncStates = snapshot
        folderHierarchyRevision &+= 1
    }

    private func persistBaiduSnapshotProgress(
        sourceID: String,
        generation: Int,
        effectiveDirectories: [String],
        resumeState: BaiduSnapshotResumeState,
        telemetry: SourceSyncTelemetry
    ) {
        guard isCurrentScan(sourceID, generation: generation) else { return }
        guard var checkpoint = checkpoints[sourceID] else { return }
        checkpoint.phase = .scanning
        checkpoint.currentFile = resumeState.pendingDirectories.last ?? ""
        checkpoint.updatedAt = Date()
        checkpoint.resolvedDirectories = effectiveDirectories
        checkpoint.baiduSnapshotState = resumeState
        checkpoint.baiduTelemetry = telemetry
        checkpoints[sourceID] = checkpoint

        var scanState = scanStates[sourceID] ?? ScanState(isScanning: true)
        scanState.isScanning = true
        scanState.currentFile = checkpoint.currentFile
        scanState.scannedCount = resumeState.visitedDirectories.count
        scanState.totalCount = resumeState.visitedDirectories.count
            + resumeState.pendingDirectories.count
        scanState.hasPendingWork = true
        scanState.failureMessage = nil
        scanStates[sourceID] = scanState
        persistCheckpoints(force: Task.isCancelled)
    }

    private func persistCheckpoint(
        sourceID: String,
        directories: [String],
        songs: [Song],
        totalCount: Int,
        currentFile: String,
        directoryState: SourceScanResumeState? = nil,
        baselineCursors: [String: String]? = nil,
        resolvedDirectories: [String]? = nil
    ) {
        let existing = checkpoints[sourceID]
        checkpoints[sourceID] = ScanCheckpoint(
            phase: .scanning,
            intent: existing?.intent ?? .fullScan,
            directories: normalizedDirectories(directories),
            songs: songs,
            totalCount: totalCount,
            currentFile: currentFile,
            updatedAt: Date(),
            scopeFingerprint: existing?.scopeFingerprint,
            resolvedDirectories: resolvedDirectories ?? existing?.resolvedDirectories,
            directoryState: directoryState ?? existing?.directoryState,
            baselineCursors: baselineCursors ?? existing?.baselineCursors,
            baiduSnapshotState: existing?.baiduSnapshotState,
            baiduTelemetry: existing?.baiduTelemetry
        )
        persistCheckpoints()
    }

    @discardableResult
    private func persistCheckpoints(force: Bool = false) -> Task<Bool, Never>? {
        let now = Date()
        guard force
                || now.timeIntervalSince(lastCheckpointPersistenceAt)
                    >= Self.checkpointPersistenceInterval else { return nil }
        lastCheckpointPersistenceAt = now
        let snapshot = checkpoints
        let store = checkpointStore
        let previous = checkpointWriteTask
        let writeTask = Task.detached(priority: .utility) {
            _ = await previous?.value
            do {
                try await store.replace(with: snapshot)
                return true
            } catch {
                plog("⛔ Scan checkpoint persistence failed: \(error.localizedDescription)")
                return false
            }
        }
        checkpointWriteTask = writeTask
        return writeTask
    }

    private func waitForCheckpointPersistence(force: Bool = true) async throws {
        guard let writeTask = persistCheckpoints(force: force) else { return }
        guard await writeTask.value else {
            throw SourceError.connectionFailed("Unable to persist scan checkpoint")
        }
    }

    private func clearCheckpointAndWait(for sourceID: String) async throws {
        let previous = checkpoints[sourceID]
        checkpoints[sourceID] = nil
        do {
            try await waitForCheckpointPersistence()
        } catch {
            if checkpoints[sourceID] == nil, let previous {
                checkpoints[sourceID] = previous
            }
            throw error
        }
    }

    private func promoteCheckpointToFullScanAndWait(for sourceID: String) async throws {
        guard let previous = checkpoints[sourceID] else { return }
        let promoted = previous.promotedToFullScan()
        guard promoted != previous else { return }
        checkpoints[sourceID] = promoted
        do {
            try await waitForCheckpointPersistence()
        } catch {
            if checkpoints[sourceID] == promoted {
                checkpoints[sourceID] = previous
            }
            throw error
        }
    }

    private func persistBaselineCursorsAndWait(
        _ baselineCursors: [String: String],
        sourceID: String
    ) async throws {
        guard var updated = checkpoints[sourceID],
              updated.baselineCursors != baselineCursors else { return }
        let previous = updated
        updated.baselineCursors = baselineCursors
        updated.updatedAt = Date()
        checkpoints[sourceID] = updated
        do {
            try await waitForCheckpointPersistence()
        } catch {
            if checkpoints[sourceID] == updated {
                checkpoints[sourceID] = previous
            }
            throw error
        }
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

    private nonisolated static func scopeFingerprint(
        for source: MusicSource,
        directories: [String]
    ) -> String {
        var components = [
            source.type.rawValue,
            source.cloudAccountID ?? "",
            source.connectionConfiguration != nil && source.type.supportsEndpointSpecificPath
                ? ""
                : (source.basePath ?? ""),
            source.shareName ?? "",
            source.exportPath ?? "",
            directories.sorted().joined(separator: "\u{1F}"),
        ]
        if let configuration = source.connectionConfiguration {
            for endpoint in [configuration.localEndpoint, configuration.publicEndpoint] {
                let normalized = endpoint?.normalized
                components.append(normalized?.host.lowercased() ?? "")
                components.append(normalized?.port.description ?? "")
                components.append(normalized?.useSsl == true ? "tls" : "plain")
                components.append(normalized?.pathPrefix ?? "")
            }
            components.append(configuration.vendorIdentifier?.lowercased() ?? "")
        } else {
            components.append(source.host?.lowercased() ?? "")
            components.append(source.port.map(String.init) ?? "")
            components.append(source.useSsl ? "tls" : "plain")
        }
        let digest = SHA256.hash(data: Data(components.joined(separator: "\u{1E}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the conservative bridge for libraries created before Baidu
    /// exposed `fs_id` to the scanner. Rows already represented by a committed
    /// index are left untouched; orphaned songs become path-keyed aliases that
    /// the pure snapshot migration can match without changing `Song.id`.
    private nonisolated static func legacyBaiduState(
        base: SourceSyncState?,
        sourceID: String,
        scopeFingerprint: String,
        identityScopeFingerprint: String,
        songs: [Song]
    ) -> SourceSyncState? {
        guard base != nil || !songs.isEmpty else { return nil }
        var state = base ?? SourceSyncState(
            sourceID: sourceID,
            scopeFingerprint: scopeFingerprint,
            identityScopeFingerprint: identityScopeFingerprint
        )
        state.scopeFingerprint = scopeFingerprint
        state.identityScopeFingerprint = identityScopeFingerprint
        let alreadyIndexed = Set(state.index.values.flatMap(\.songIDs))
        for song in songs where !alreadyIndexed.contains(song.id) && !song.filePath.isEmpty {
            var key = BaiduSnapshotIdentity.legacyPathKey(song.filePath)
            if var entry = state.index[key], entry.path == song.filePath {
                if !entry.songIDs.contains(song.id) {
                    entry.songIDs.append(song.id)
                    entry.songIDs.sort()
                }
                state.index[key] = entry
                continue
            }
            // The historical key lower-cased paths, so two valid remote names
            // that differ only by case can collide. Preserve both orphan rows
            // for conservative fingerprint reconciliation instead of letting
            // dictionary insertion silently discard one Song ID.
            if state.index[key] != nil {
                key += "#song:\(song.id)"
            }
            let rawParent = (song.filePath as NSString).deletingLastPathComponent
            let parent = rawParent.isEmpty || rawParent == "." ? "/" : rawParent
            state.index[key] = SourceSyncIndexedItem(
                stableKey: key,
                path: song.filePath,
                displayName: (song.filePath as NSString).lastPathComponent,
                parentPath: parent,
                isDirectory: false,
                songIDs: [song.id],
                size: song.fileSize,
                modifiedDate: song.lastModified,
                revision: song.revision,
                seenEpoch: state.scanEpoch
            )
        }
        return state
    }

    private nonisolated static func isMissingConnectorRootError(_ error: Error) -> Bool {
        switch error {
        case CloudDriveError.fileNotFound,
             SourceError.pathNotFound,
             SourceError.fileNotFound:
            return true
        default:
            return false
        }
    }

    private func resumeCheckpoint(
        for sourceID: String,
        directories: [String],
        scopeFingerprint: String
    ) -> ScanCheckpoint? {
        guard let checkpoint = checkpoints[sourceID] else { return nil }
        guard checkpoint.directories == directories,
              checkpoint.scopeFingerprint == scopeFingerprint else {
            removeCheckpoint(for: sourceID)
            return nil
        }
        return checkpoint
    }

    private func sourceCanContinue(_ sourceID: String, sourceStore: SourcesStore) -> Bool {
        guard let live = sourceStore.source(id: sourceID) else { return false }
        return live.isEnabled && !live.isDeleted
    }

    private func checkSourceStillEnabled(_ sourceID: String, sourceStore: SourcesStore) throws {
        guard let live = sourceStore.source(id: sourceID), !live.isDeleted else {
            removeCheckpoint(for: sourceID)
            throw CancellationError()
        }
        guard live.isEnabled else { throw CancellationError() }
    }

}
