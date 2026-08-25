import Foundation
import PrimuseKit

@MainActor
final class AppServices {
    static let shared = AppServices()

    let sourcesStore: SourcesStore
    let radioStationsStore: RadioStationsStore
    let sourceManager: SourceManager
    let playerService: AudioPlayerService
    let scraperSettingsStore: ScraperSettingsStore
    let scraperService: MusicScraperService
    let musicLibrary: MusicLibrary
    let playbackSettingsStore: PlaybackSettingsStore
    let cloudSync: CloudKitSyncService
    let themeService: ThemeService
    let scanService: ScanService
    #if os(iOS) || os(macOS)
    let localReferenceRefresh: LocalReferenceRefreshService
    #endif
    let metadataBackfill: MetadataBackfillService
    let lyricsTextBackfill: LyricsTextBackfillService
    let similarTracks: SimilarTracksService
    let updateChecker: AppUpdateChecker
    let coverTintProvider: CoverTintProvider
    let spotlightIndex: SpotlightIndexService
    let appleMusic: AppleMusicService
    let appleMusicLibrary: AppleMusicLibraryService
    let dlnaRenderer: DLNARendererService
    let visualizer: AudioVisualizerService
    let crashDiagnostics: CrashDiagnosticsService
    let duplicateCleanup: DuplicateCleanupService
    let batchRemoval: SongBatchRemovalService
    let serverFavoriteSync: ServerFavoriteSyncService
    let musicIntelligence: MusicIntelligenceService

    private var sourceLifecycleObserverTokens: [NSObjectProtocol] = []
    private struct SourceCleanupRequest {
        var purgePersistentCaches = false
        var removeImportedFiles = false
        var uploadSourcesSnapshot = false
    }
    private var pendingSourceCleanup: [String: SourceCleanupRequest] = [:]
    private var sourceCleanupTask: Task<Void, Never>?
    private var pendingSourceCloudCleanups: [String: SourceCloudCleanupIntent] = [:]
    private var sourceCloudCleanupPropagationTask: Task<Void, Never>?
    private var sourceCloudCleanupFailureStreak = 0
    private var didCompleteDeferredStartup = false
    private var sourceCountReconciliationTask: Task<Void, Never>?

    private struct StartupLibraryReconciliation: Sendable {
        let sourceSongCounts: [String: Int]
        let staleSourceIDsWithSongs: Set<String>
    }

    private var sourceCloudCleanupJournalURL: URL {
        #if os(tvOS)
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return base
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("pending-source-cloud-cleanups.json")
    }

    private init() {
        let startupStartedAt = ProcessInfo.processInfo.systemUptime
        // Class is @MainActor so this initializer is too — but the static
        // `shared` instantiation is lazy-on-first-access. If anything
        // ever touches `AppServices.shared` from a non-main thread, Swift
        // will hop here implicitly and we'd silently break invariants in
        // the services we own. Crash loudly instead.
        dispatchPrecondition(condition: .onQueue(.main))
        FullscreenPlayerEffectSync.shared.install()

        if CloudSyncChannel.usesSynchronizableKeychain() {
            KeychainService.migrateLegacyEntriesToICloud()
            CloudTokenManager.migrateLegacyEntriesToICloud()
        }
        let keychainFinishedAt = ProcessInfo.processInfo.systemUptime

        let store = SourcesStore()
        let radioStore = RadioStationsStore()
        let sourcesFinishedAt = ProcessInfo.processInfo.systemUptime
        let initiallyDisabledSourceIDs = Set(
            store.sources.filter { !$0.isEnabled }.map(\.id)
        )
        let library = MusicLibrary(disabledSourceIDs: initiallyDisabledSourceIDs)
        let libraryFinishedAt = ProcessInfo.processInfo.systemUptime
        let manager = SourceManager(sourcesProvider: {
            await MainActor.run { store.sources }
        }, songsProvider: {
            library.songs
        })
        let scraperSettings = ScraperSettingsStore()
        let scraper = MusicScraperService(sourceManager: manager)
        let playbackSettings = PlaybackSettingsStore()
        manager.setAutomaticAudioCachingEnabled(playbackSettings.audioCacheEnabled)
        playbackSettings.audioCacheEnabledDidChange = { [weak manager] enabled in
            manager?.setAutomaticAudioCachingEnabled(enabled)
        }
        let player = AudioPlayerService(sourceManager: manager, library: library, playbackSettings: playbackSettings)
        let favoriteSync = ServerFavoriteSyncService(
            sourceManager: manager,
            sourcesStore: store,
            library: library,
            player: player
        )
        let sync = CloudKitSyncService(
            library: library,
            sourcesStore: store,
            radioStationsStore: radioStore,
            scraperConfigStore: .shared,
            scraperSettingsStore: scraperSettings
        )
        let coreServicesFinishedAt = ProcessInfo.processInfo.systemUptime

        self.sourcesStore = store
        self.radioStationsStore = radioStore
        self.sourceManager = manager
        self.playerService = player
        self.scraperSettingsStore = scraperSettings
        self.scraperService = scraper
        self.musicLibrary = library
        self.playbackSettingsStore = playbackSettings
        self.cloudSync = sync
        self.serverFavoriteSync = favoriteSync
        let theme = ThemeService()
        // 启动时同时恢复固定回退色、主题色来源与封面氛围偏好。
        #if os(iOS)
        theme.setBaseAccent(ThemeColorSettings.shared.baseAccent)
        theme.setColorMode(ThemeColorSettings.shared.mode, animated: false)
        theme.setCoverDrivenAmbient(ThemeColorSettings.shared.coverDrivenAmbient, animated: false)
        #else
        theme.setBaseAccent(MacUIPreferences.shared.fixedBrandColor)
        theme.setColorMode(MacUIPreferences.shared.themeColorMode, animated: false)
        theme.setCoverDrivenAmbient(MacUIPreferences.shared.coverDrivenAmbient, animated: false)
        #endif
        self.themeService = theme
        let scanService = ScanService()
        let metadataBackfill = MetadataBackfillService(library: library, sourceManager: manager) {
            Set(store.sources.filter { $0.isEnabled && $0.supportsRangeStreaming }.map(\.id))
        }
        scanService.metadataInspectionHandler = { [weak metadataBackfill] songIDs in
            metadataBackfill?.acknowledgeScannerMetadataInspection(songIDs: songIDs)
        }
        scanService.successfulSourceScanHandler = { [weak metadataBackfill] sourceID in
            metadataBackfill?.sourceScanSucceeded(forSourceID: sourceID)
        }
        scanService.serverRadioSyncHandler = { [weak manager, weak radioStore] source in
            guard let manager, let radioStore else { return }
            await ServerRadioSyncService.sync(
                source: source,
                sourceManager: manager,
                store: radioStore
            )
        }
        scanService.serverFavoriteSyncHandler = { [weak favoriteSync] source in
            await favoriteSync?.refresh(source: source)
        }
        library.likedStateMutationHandler = { [weak favoriteSync] song, previous, desired in
            favoriteSync?.localLikedStateDidChange(
                song: song,
                previous: previous,
                desired: desired
            )
        }
        self.scanService = scanService
        #if os(iOS) || os(macOS)
        self.localReferenceRefresh = LocalReferenceRefreshService(
            sourcesStore: store,
            sourceManager: manager,
            library: library,
            scanService: scanService,
            scraperService: scraper
        )
        #endif
        self.metadataBackfill = metadataBackfill
        self.lyricsTextBackfill = LyricsTextBackfillService(library: library)
        self.similarTracks = SimilarTracksService()
        self.musicIntelligence = MusicIntelligenceService()
        self.updateChecker = AppUpdateChecker()
        self.coverTintProvider = CoverTintProvider()
        self.spotlightIndex = SpotlightIndexService()
        let amService = AppleMusicService(playbackSettings: playbackSettings)
        self.appleMusic = amService
        self.appleMusicLibrary = AppleMusicLibraryService(library: library, appleMusic: amService)
        amService.onPlaybackEnded = { [weak player] requestID in
            player?.handleAppleMusicPlaybackEnded(requestID: requestID)
        }
        amService.preparePlaybackHandoff = { [weak player] requestID in
            guard let player else { return false }
            return await player.prepareAppleMusicPlaybackHandoff(requestID: requestID)
        }

        // 确保 Apple Music 虚拟 source 一直存在 — 用户首次安装 / iCloud
        // 同步过来时, 我们这边没这个 source 记录, library 里的 Apple Music
        // 歌就会因为 sourceID 找不到 mount 被 visibleSongs 过滤掉。
        // 这里手动 upsert 一个 enabled=true 的固定 ID source, 让 song.sourceID
        // 总能对得上。
        let amSourceID = AppleMusicLibraryService.systemSourceID
        // 清理误加的重复 Apple Music 源:Apple Music 是系统单例,只该有 systemSourceID 这一个。
        // 早期"添加源"列表把 .appleMusic 也列了出来,用户可能加出 type=.appleMusic 但 id 非系统的重复源。
        for dup in store.allSources where dup.type == .appleMusic && dup.id != amSourceID && !dup.isDeleted {
            store.remove(id: dup.id)
        }
        if store.allSources.first(where: { $0.id == amSourceID }) == nil {
            store.upsert(MusicSource(
                id: amSourceID,
                name: "Apple Music",
                type: .appleMusic,
                authType: .none,
                isEnabled: true,
                songCount: 0
            ))
        }
        self.dlnaRenderer = DLNARendererService(player: player)
        self.visualizer = AudioVisualizerService()
        let crash = CrashDiagnosticsService()
        crash.register()
        self.crashDiagnostics = crash
        self.duplicateCleanup = DuplicateCleanupService(
            library: library,
            sourceManager: manager,
            sourcesStore: store
        )
        self.batchRemoval = SongBatchRemovalService(
            library: library,
            sourceManager: manager,
            sourcesStore: store,
            player: player
        )
        let auxiliaryServicesFinishedAt = ProcessInfo.processInfo.systemUptime

        library.updateDisabledSourceIDs(
            Set(store.sources.filter { !$0.isEnabled }.map(\.id))
        )
        let playbackRestoreFinishedAt = ProcessInfo.processInfo.systemUptime

        // Wire the library's tombstone identity resolver. Maps a song's
        // mount UUID → its CloudAccount id (when available) so deletion
        // tombstones survive re-OAuth — the user re-adding the same
        // Baidu account mints a new mount UUID, which would otherwise
        // change song.id and silently bypass the tombstone set.
        library.sourceIdentityResolver = { [weak store] sourceID in
            store?.allSources.first(where: { $0.id == sourceID })?.cloudAccountID
        }

        loadPendingSourceCloudCleanups()
        observeSourceLifecycle()

        wireIntentBridge()
        observeSpotlightSynchronization()
        musicIntelligence.start()
        let startupFinishedAt = ProcessInfo.processInfo.systemUptime
        plog(String(
            format: "🚀 launch services total=%.0fms keychain=%.0f sources=%.0f library=%.0f core=%.0f auxiliary=%.0f wiring=%.0f observers=%.0f",
            (startupFinishedAt - startupStartedAt) * 1_000,
            (keychainFinishedAt - startupStartedAt) * 1_000,
            (sourcesFinishedAt - keychainFinishedAt) * 1_000,
            (libraryFinishedAt - sourcesFinishedAt) * 1_000,
            (coreServicesFinishedAt - libraryFinishedAt) * 1_000,
            (auxiliaryServicesFinishedAt - coreServicesFinishedAt) * 1_000,
            (playbackRestoreFinishedAt - auxiliaryServicesFinishedAt) * 1_000,
            (startupFinishedAt - playbackRestoreFinishedAt) * 1_000
        ))
    }

    /// Runs after SwiftUI has had a chance to present the first frame. Queue
    /// decoding and whole-library reconciliation are intentionally absent from
    /// `init`, where even background-capable work would extend Time to First
    /// Draw on the main actor.
    func completeDeferredStartup() async {
        guard !didCompleteDeferredStartup else { return }
        didCompleteDeferredStartup = true
        let startedAt = ProcessInfo.processInfo.systemUptime

        #if os(iOS)
        await Task.detached(priority: .utility) {
            LocalImportService.recoverIncompleteTransactions()
        }.value
        #endif

        let sourceSnapshot = sourcesStore.allSources
        let songSnapshot = musicLibrary.songs
        async let playbackRestore: Void = playerService.restorePlaybackSessionIfAvailable()
        let reconciliation = await Task.detached(priority: .utility) {
            var counts: [String: Int] = [:]
            counts.reserveCapacity(sourceSnapshot.count)
            for song in songSnapshot {
                counts[song.sourceID, default: 0] += 1
            }
            let knownSourceIDs = Set(sourceSnapshot.map(\.id))
            let deletedSourceIDs = Set(sourceSnapshot.lazy.filter(\.isDeleted).map(\.id))
            let missingSourceIDs = Set(counts.keys).subtracting(knownSourceIDs)
            let staleSourceIDs = deletedSourceIDs.union(missingSourceIDs)
            return StartupLibraryReconciliation(
                sourceSongCounts: counts,
                staleSourceIDsWithSongs: Set(staleSourceIDs.filter { (counts[$0] ?? 0) > 0 })
            )
        }.value
        await playbackRestore
        let restoreFinishedAt = ProcessInfo.processInfo.systemUptime

        let pruneThreshold = RecoverableDeletionPolicy.pruneThreshold()
        musicLibrary.prunePlaylists(deletedBefore: pruneThreshold)
        let sourcePruneResults = sourcesStore.pruneSources(deletedBefore: pruneThreshold)
        let sourcePruneFailures = sourcePruneResults.filter {
            $0.value == .credentialCleanupFailed || $0.value == .deletionLedgerPersistFailed
        }
        if !sourcePruneFailures.isEmpty {
            plog("⏳ Source prune retained \(sourcePruneFailures.count) tombstone(s) for durable cleanup retry")
        }
        ScraperConfigStore.shared.pruneConfigs(deletedBefore: pruneThreshold)

        let currentlyStaleSourceIDs = reconciliation.staleSourceIDsWithSongs.filter { sourceID in
            guard let currentSource = sourcesStore.source(id: sourceID) else { return true }
            return currentSource.isDeleted
        }
        if !currentlyStaleSourceIDs.isEmpty {
            let removedCount = currentlyStaleSourceIDs.reduce(0) {
                $0 + (reconciliation.sourceSongCounts[$1] ?? 0)
            }
            plog("📚 removing \(removedCount) song(s) from deleted/missing source(s): \(currentlyStaleSourceIDs)")
            for id in currentlyStaleSourceIDs {
                removeSourceLibraryData(id: id, purgePersistentCaches: false)
            }
        }
        let activeSourceIDs = Set(sourcesStore.sources.map(\.id))
        let staleRadioSourceIDs = Set(
            radioStationsStore.allStations.lazy
                .filter { $0.isServerMirror && !$0.isDeleted }
                .compactMap(\.sourceID)
        ).subtracting(activeSourceIDs)
        radioStationsStore.removeServerMirrors(forSourceIDs: staleRadioSourceIDs)
        sourcesStore.reconcileLocalSongCounts(reconciliation.sourceSongCounts)
        migrateSourceDirectoryDisplayNames()
        #if os(iOS) || os(macOS)
        localReferenceRefresh.start()
        #endif

        CloudKVSSync.shared.register(key: CloudKVSKey.lyricsFontScale) { }
        CloudKVSSync.shared.register(key: CloudKVSKey.recentSearches) { }

        // Phase 3: Apple TV relay is opt-in. Starting its listeners after the
        // first frame preserves behavior without charging launch rendering.
        PhoneRelayServer.shared.startIfEnabled(
            sourceManager: sourceManager,
            sourcesStore: sourcesStore,
            library: musicLibrary
        )
        schedulePendingSourceCloudCleanupPropagation(delay: .seconds(1))
        let finishedAt = ProcessInfo.processInfo.systemUptime
        plog(String(
            format: "🚀 deferred startup total=%.0fms restore=%.0fms maintenance=%.0fms",
            (finishedAt - startedAt) * 1_000,
            (restoreFinishedAt - startedAt) * 1_000,
            (finishedAt - restoreFinishedAt) * 1_000
        ))
    }

    private func migrateSourceDirectoryDisplayNames() {
        #if os(iOS) || os(macOS)
        for source in sourcesStore.sources where source.type.isCloudDrive {
            let selected = Set(source.scannedDirectories)
            guard !selected.isEmpty else { continue }
            var names = source.scannedDirectoryDisplayNames.filter { selected.contains($0.key) }
            for (path, name) in CloudDirectoryNameStore.displayNames(for: source.id)
                where selected.contains(path) && !name.isEmpty {
                names[path] = name
            }
            for item in scanService.libraryFolderSyncIndex(for: source.id).values
                where selected.contains(item.path) {
                if let name = item.displayName, !name.isEmpty {
                    names[item.path] = name
                }
            }
            sourcesStore.mergeDirectoryDisplayNames(names, sourceID: source.id)
        }
        #endif
    }

    /// Resume interrupted local-import recovery only from an iOS background
    /// execution window. Cold-start recovery used to launch a complete local
    /// scan a moment after the first frame, which reproduced the apparent
    /// "freezes later" behavior on libraries with unfinished imports.
    func resumePendingLocalImportScanIfNeeded() {
        #if os(iOS)
        guard let sourceID = LocalImportService.existingSourceID else { return }
        let hasPendingCheckpoint = scanService.scanStates[sourceID]?.hasPendingWork == true
        let hasUnplayableRows = musicLibrary.songs.contains {
            $0.sourceID == sourceID && $0.duration <= 0
        }
        let hasPendingScan = LocalImportService.hasPendingScan

        let source: MusicSource
        if let existing = sourcesStore.source(id: sourceID),
           existing.isEnabled,
           !existing.isDeleted {
            guard hasPendingScan || hasPendingCheckpoint || hasUnplayableRows else { return }
            source = existing
        } else if LocalImportService.hasRecoverableCompleteFiles || hasPendingCheckpoint {
            let recovered = LocalImportService.makeSource(
                name: String(localized: "local_import_source_name")
            )
            do {
                try sourcesStore.addDurably(recovered)
                source = recovered
            } catch {
                plog("⛔ LocalImport: cold-start source recovery failed — \(error.localizedDescription)")
                return
            }
        } else {
            return
        }
        plog("📥 LocalImport: scheduling pending/interrupted local import scan")
        scanService.scanSource(
            source,
            snapshotExecutionContext: .background,
            sourceManager: sourceManager,
            library: musicLibrary,
            sourceStore: sourcesStore,
            scraperService: scraperService
        )
        #endif
    }

    private func observeSourceLifecycle() {
        let nc = NotificationCenter.default

        sourceLifecycleObserverTokens.append(
            nc.addObserver(forName: .primuseSourceDidSoftDelete, object: nil, queue: .main) { [weak self] note in
                guard let self, let id = note.userInfo?["id"] as? String else { return }
                let capturedTombstone = note.userInfo?["source"] as? MusicSource
                Task { @MainActor in
                    if let tombstone = capturedTombstone ?? self.sourcesStore.source(id: id),
                       tombstone.isDeleted {
                        self.enqueueSourceCloudCleanup(tombstone)
                    }
                    // 软删(进回收站)即回收空间:删本地导入源在沙箱的原始拷贝。
                    // 产品取舍 —— restore 不会自动重扫找回歌, 保留拷贝意义不大,
                    // 而用户删源的核心诉求就是立即回收空间。Toggling isEnabled
                    // never posts this notification.
                    self.removeSourceLibraryData(
                        id: id,
                        purgePersistentCaches: true,
                        removeImportedFiles: true,
                        uploadSourcesSnapshot: true
                    )
                }
            }
        )

        sourceLifecycleObserverTokens.append(
            nc.addObserver(forName: .primuseSourceDidDelete, object: nil, queue: .main) { [weak self] note in
                guard let self, let id = note.userInfo?["id"] as? String else { return }
                let capturedTombstone = note.userInfo?["source"] as? MusicSource
                Task { @MainActor in
                    // The row may already be gone from SourcesStore. The
                    // notification carries its last tombstone so the delayed
                    // soft-delete propagation cannot be lost.
                    if let tombstone = capturedTombstone, tombstone.isDeleted {
                        self.enqueueSourceCloudCleanup(tombstone)
                    }
                    // 永久删除(回收站清空 / 30 天清理 / CloudKit 远端永久删 echo)。
                    // 软删时通常已回收, 这里幂等兜底(目录已删则 removeItem no-op)。
                    self.removeSourceLibraryData(
                        id: id,
                        purgePersistentCaches: true,
                        removeImportedFiles: true,
                        uploadSourcesSnapshot: capturedTombstone?.isDeleted == true
                    )
                }
            }
        )

        sourceLifecycleObserverTokens.append(
            nc.addObserver(forName: .primuseSourceTombstoneDidSync, object: nil, queue: .main) { [weak self] note in
                guard let self, let id = note.userInfo?["id"] as? String else { return }
                Task { @MainActor in
                    self.acknowledgeSourceTombstoneUpload(sourceID: id)
                }
            }
        )
    }

    private func enqueueSourceCloudCleanup(_ tombstone: MusicSource) {
        sourcesStore.registerDeletionTombstone(tombstone)
        guard MusicSourceCloudSyncPolicy.isEligible(tombstone) else {
            if pendingSourceCloudCleanups.removeValue(forKey: tombstone.id) != nil {
                persistPendingSourceCloudCleanups()
            }
            return
        }
        guard let intent = SourceCloudCleanupPolicy.coalescing(
            current: pendingSourceCloudCleanups[tombstone.id],
            tombstone: tombstone
        ) else { return }
        pendingSourceCloudCleanups[tombstone.id] = intent
        persistPendingSourceCloudCleanups()
        schedulePendingSourceCloudCleanupPropagation(delay: .milliseconds(400))
    }

    private func loadPendingSourceCloudCleanups() {
        guard let data = try? Data(contentsOf: sourceCloudCleanupJournalURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let intents = try? decoder.decode([SourceCloudCleanupIntent].self, from: data) else {
            plog("⛔ Source cloud cleanup journal is unreadable; preserving file for recovery")
            return
        }
        var removedDeviceLocalIntent = false
        for intent in intents where intent.tombstone.isDeleted {
            guard MusicSourceCloudSyncPolicy.isEligible(intent.tombstone) else {
                removedDeviceLocalIntent = true
                continue
            }
            sourcesStore.registerDeletionTombstone(intent.tombstone)
            if let current = pendingSourceCloudCleanups[intent.tombstone.id] {
                let currentClock = max(
                    current.tombstone.modifiedAt,
                    current.tombstone.deletedAt ?? .distantPast
                )
                let incomingClock = max(
                    intent.tombstone.modifiedAt,
                    intent.tombstone.deletedAt ?? .distantPast
                )
                var merged = incomingClock >= currentClock ? intent : current
                merged.needsMusicSourceTombstoneUpload = current.needsMusicSourceTombstoneUpload
                    || intent.needsMusicSourceTombstoneUpload
                merged.needsSourceSnapshotUpload = current.needsSourceSnapshotUpload
                    || intent.needsSourceSnapshotUpload
                merged.needsCredentialRemoval = current.needsCredentialRemoval
                    || intent.needsCredentialRemoval
                pendingSourceCloudCleanups[intent.tombstone.id] = merged
            } else {
                pendingSourceCloudCleanups[intent.tombstone.id] = intent
            }
        }
        if removedDeviceLocalIntent {
            persistPendingSourceCloudCleanups()
        }
        if !pendingSourceCloudCleanups.isEmpty {
            plog("⏳ Restored \(pendingSourceCloudCleanups.count) pending source cloud cleanup(s)")
            schedulePendingSourceCloudCleanupPropagation(delay: .seconds(1))
        }
    }

    private func persistPendingSourceCloudCleanups() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let intents = pendingSourceCloudCleanups.values.sorted {
            $0.tombstone.id < $1.tombstone.id
        }
        do {
            try FileManager.default.createDirectory(
                at: sourceCloudCleanupJournalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(intents)
            try data.write(to: sourceCloudCleanupJournalURL, options: .atomic)
        } catch {
            plog("⛔ Source cloud cleanup journal persist failed — \(error.localizedDescription)")
        }
    }

    private func schedulePendingSourceCloudCleanupPropagation(delay: Duration) {
        guard !pendingSourceCloudCleanups.isEmpty,
              sourceCloudCleanupPropagationTask == nil else { return }
        sourceCloudCleanupPropagationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let madeProgress = await self.propagatePendingSourceCloudCleanups()
            self.sourceCloudCleanupPropagationTask = nil
            if !self.pendingSourceCloudCleanups.isEmpty {
                if madeProgress {
                    self.sourceCloudCleanupFailureStreak = 0
                } else {
                    self.sourceCloudCleanupFailureStreak = min(
                        self.sourceCloudCleanupFailureStreak + 1,
                        6
                    )
                }
                let retrySeconds = min(
                    30 * 60,
                    30 * (1 << self.sourceCloudCleanupFailureStreak)
                )
                self.schedulePendingSourceCloudCleanupPropagation(
                    delay: .seconds(retrySeconds)
                )
            } else {
                self.sourceCloudCleanupFailureStreak = 0
            }
        }
    }

    private func acknowledgeSourceTombstoneUpload(sourceID: String) {
        guard let current = pendingSourceCloudCleanups[sourceID] else { return }
        pendingSourceCloudCleanups[sourceID] = SourceCloudCleanupPolicy.applying(
            musicSourceTombstoneUploaded: true,
            sourceSnapshotUploaded: false,
            credentialRemoved: false,
            to: current
        )
        persistPendingSourceCloudCleanups()
    }

    private func propagatePendingSourceCloudCleanups() async -> Bool {
        let original = pendingSourceCloudCleanups
        let snapshot = pendingSourceCloudCleanups.values.sorted {
            $0.tombstone.id < $1.tombstone.id
        }
        for intent in snapshot {
            let sourceID = intent.tombstone.id
            if SourceCloudCleanupPolicy.isSuperseded(
                intent,
                by: sourcesStore.source(id: sourceID)
            ) {
                pendingSourceCloudCleanups.removeValue(forKey: sourceID)
                persistPendingSourceCloudCleanups()
                continue
            }

            if intent.needsMusicSourceTombstoneUpload {
                _ = cloudSync.enqueueSourceTombstoneForCleanup(id: sourceID)
            }

            let sourceSnapshotUploaded: Bool
            if intent.needsSourceSnapshotUpload, CloudSyncChannel.isEnabled(.sources) {
                sourceSnapshotUploaded = await LibrarySnapshotSync.shared.uploadSourcesOnly(
                    includingTombstones: [intent.tombstone]
                )
            } else {
                sourceSnapshotUploaded = !intent.needsSourceSnapshotUpload
            }

            // A restore can happen while the snapshot request is suspended.
            // Re-check before applying irreversible credential cleanup.
            if SourceCloudCleanupPolicy.isSuperseded(
                intent,
                by: sourcesStore.source(id: sourceID)
            ) {
                pendingSourceCloudCleanups.removeValue(forKey: sourceID)
                persistPendingSourceCloudCleanups()
                continue
            }

            let credentialRemoved: Bool
            if intent.needsCredentialRemoval {
                credentialRemoved = await LibrarySnapshotSync.shared
                    .removeCredentialFromCloud(forSourceID: sourceID)
            } else {
                credentialRemoved = true
            }
            guard let current = pendingSourceCloudCleanups[sourceID] else { continue }
            let sameTombstone = current.tombstone == intent.tombstone
            let updated = SourceCloudCleanupPolicy.applying(
                musicSourceTombstoneUploaded: false,
                sourceSnapshotUploaded: sameTombstone && sourceSnapshotUploaded,
                credentialRemoved: credentialRemoved,
                to: current
            )
            if updated != current {
                pendingSourceCloudCleanups[sourceID] = updated
                persistPendingSourceCloudCleanups()
            }
        }
        return pendingSourceCloudCleanups != original
    }

    private func removeSourceLibraryData(
        id: String,
        purgePersistentCaches: Bool,
        removeImportedFiles: Bool = false,
        uploadSourcesSnapshot: Bool = false
    ) {
        // Stop source-specific work immediately, but coalesce the expensive
        // library/cache cleanup. Rapidly removing many 10K-song sources used
        // to run the complete O(librarySize) pipeline once per source.
        scanService.cancelScan(for: id)
        scanService.removeCheckpoint(for: id)
        scanService.removeSynologyAPI(for: id)
        var request = pendingSourceCleanup[id] ?? SourceCleanupRequest()
        request.purgePersistentCaches = request.purgePersistentCaches || purgePersistentCaches
        request.removeImportedFiles = request.removeImportedFiles || removeImportedFiles
        request.uploadSourcesSnapshot = request.uploadSourcesSnapshot || uploadSourcesSnapshot
        pendingSourceCleanup[id] = request

        sourceCleanupTask?.cancel()
        sourceCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.flushPendingSourceCleanup()
        }
    }

    private func flushPendingSourceCleanup() {
        let requests = pendingSourceCleanup
        pendingSourceCleanup.removeAll(keepingCapacity: true)
        sourceCleanupTask = nil
        guard !requests.isEmpty else { return }

        let sourceIDs = Set(requests.keys)
        metadataBackfill.discardWorkNow(forSourceIDs: sourceIDs)
        musicLibrary.removeSongsForSources(sourceIDs)
        musicLibrary.pruneServerPlaylistMirrors(forSourceIDs: sourceIDs)
        radioStationsStore.removeServerMirrors(forSourceIDs: sourceIDs)
        sourcesStore.resetLocalScanState(for: sourceIDs)

        let cachePurgeIDs = Set(requests.compactMap { id, request in
            request.purgePersistentCaches ? id : nil
        })
        sourceManager.deleteSourceCaches(sourceIDs: cachePurgeIDs)

        for (id, request) in requests {
            if request.removeImportedFiles {
                removeImportedLocalFilesIfNeeded(sourceID: id)
            }
        }

        // The durable intent was captured by the lifecycle notification before
        // this debounce. Do not query SourcesStore here: an immediate permanent
        // delete has legitimately removed the row by now.
        if requests.values.contains(where: \.uploadSourcesSnapshot) {
            schedulePendingSourceCloudCleanupPropagation(delay: .zero)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for id in sourceIDs {
                await self.sourceManager.removeConnector(for: id)
            }
        }
    }

    /// 回收 iOS「本地音乐」源在沙箱 Documents/LocalMusic 的原始拷贝。三道闸:
    /// ① id 必须等于本设备的 `LocalImportService.sourceID` —— macOS 用户文件夹源
    ///    的 id 是随机 UUID, 永不命中, 故对其 basePath(沙箱外用户目录)恒 no-op;
    ///    CloudKit 把他设备本地源记录 echo 过来时其 id 也 ≠ 本机 sourceID(每设备
    ///    独立), 同样不命中 —— 安全严格依赖「sourceID 每设备独立」这一前提。
    /// ② 当前不存在活跃(未软删)的同 id 记录 —— 防「软删 → 再次导入复用同 id →
    ///    对回收站旧记录彻底删除」时误删刚导入的活跃音频。
    /// ③ 目标用运行时常量 musicDirectory(不用可被 CloudKit 改写的 source.basePath),
    ///    且必须落在沙箱 Documents 子树内、目录名恰为 LocalMusic。
    /// 删大目录放后台, 避免卡主线程。
    private func removeImportedLocalFilesIfNeeded(sourceID: String) {
        guard sourceID == LocalImportService.existingSourceID else { return }
        guard !sourcesStore.allSources.contains(where: { $0.id == sourceID && !$0.isDeleted }) else { return }
        let fm = FileManager.default
        let importDir = LocalImportService.musicDirectory.standardizedFileURL
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
        guard importDir.path.hasPrefix(documents.path + "/"),
              importDir.lastPathComponent == "LocalMusic",
              fm.fileExists(atPath: importDir.path) else { return }
        // 原子 rename 到临时名后再后台删:删除可能耗时(几 GB), 而紧接着的「再次
        // 导入」复用同一个 LocalMusic 目录。先把旧目录搬走, 再导入就会
        // ensureMusicDirectory 新建干净目录, 不与后台删除竞争 / 被误删。
        let trash = documents.appendingPathComponent(".LocalMusic-deleting-\(UUID().uuidString)")
        guard (try? fm.moveItem(at: importDir, to: trash)) != nil else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: trash)
        }
    }

    private func reconcileDeletedSourceSongs() {
        let knownSourceIDs = Set(sourcesStore.allSources.map(\.id))
        let deletedSourceIDs = Set(sourcesStore.allSources.lazy.filter(\.isDeleted).map(\.id))
        let sourceSongCounts = musicLibrary.songCountsBySourceID()
        let missingSourceIDs = Set(sourceSongCounts.keys).subtracting(knownSourceIDs)
        let staleSourceIDs = deletedSourceIDs.union(missingSourceIDs)
        let staleSourceIDsWithSongs = staleSourceIDs.filter { (sourceSongCounts[$0] ?? 0) > 0 }

        guard !staleSourceIDsWithSongs.isEmpty else { return }
        let removedCount = staleSourceIDsWithSongs.reduce(0) { $0 + (sourceSongCounts[$1] ?? 0) }
        plog("📚 removing \(removedCount) song(s) from deleted/missing source(s): \(staleSourceIDsWithSongs)")
        for id in staleSourceIDsWithSongs {
            removeSourceLibraryData(id: id, purgePersistentCaches: false)
        }
    }

    /// Source-card counts are local derived state, not authoritative cloud
    /// data. Rebuild them from the library both at launch and whenever a
    /// library snapshot/replacement lands so an old scan count cannot masquerade
    /// as the number of songs currently available on this device.
    private func reconcileSourceSongCounts() {
        sourcesStore.reconcileLocalSongCounts(musicLibrary.songCountsBySourceID())
    }

    private func scheduleSourceSongCountReconciliation() {
        sourceCountReconciliationTask?.cancel()
        sourceCountReconciliationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.sourceCountReconciliationTask = nil
            self.reconcileSourceSongCounts()
        }
    }

    /// 启动时只恢复上次中断的 Spotlight 工作；已确认干净的 manifest 不再
    /// 全库核对。之后 library token 翻动只提交新增、修改和删除的条目。
    /// Observation 自动 re-arm,跟 MacMenuBarController 的 observePlayerState
    /// 是同一个模式。
    private func observeSpotlightSynchronization() {
        let library = self.musicLibrary
        let index = self.spotlightIndex
        // 等 CloudKit 先拉一拨远端歌单 / 设置，服务自身还会再做一次去抖。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            index.synchronizeIfNeeded(library: library)
        }

        observeSpotlightLibraryToken(library: library, index: index)
        observeSearchLibraryToken(library: library)
    }

    private func observeSpotlightLibraryToken(
        library: MusicLibrary,
        index: SpotlightIndexService
    ) {
        withObservationTracking {
            _ = library.songReplacementToken
            _ = library.visibleSongCollectionRevision
            _ = library.playlistCollectionRevision
        } onChange: { [weak library, weak index] in
            SpotlightIndexService.persistLibraryChangePending()
            Task { @MainActor [weak self] in
                guard let library, let index else { return }
                index.scheduleSynchronization(library: library)
                self?.scheduleSourceSongCountReconciliation()
                self?.observeSpotlightLibraryToken(library: library, index: index)
            }
        }
    }

    /// Search indexing follows only metadata/lyrics revisions. Playlist edits
    /// still update Spotlight, but no longer dirty the 14K-row FTS database.
    private func observeSearchLibraryToken(library: MusicLibrary) {
        withObservationTracking {
            _ = library.searchRevision
            _ = library.lyricsSearchRevision
        } onChange: { [weak library] in
            LibrarySearchIndex.persistLibraryChangePending()
            Task { @MainActor [weak self] in
                guard let library else { return }
                #if os(macOS)
                let songs = library.visibleSongs
                Task(priority: .utility) {
                    await LibrarySearchIndex.shared.prepare(songs: songs)
                }
                #endif
                self?.observeSearchLibraryToken(library: library)
            }
        }
    }

    /// 把 `PrimuseIntentBridge` 的闭包指向真实的 player / library。Widget
    /// extension / Shortcuts / Control Center 触发 intent 时,系统会把
    /// `AudioPlaybackIntent.perform()` 路由到主 app 进程(必要时唤醒),
    /// 这里注入的闭包就跑起来了。
    private func wireIntentBridge() {
        let bridge = PrimuseIntentBridge.shared
        let player = self.playerService
        let library = self.musicLibrary

        bridge.togglePlayPause = { player.togglePlayPause() }
        bridge.setPlaying = { desired in
            // 状态对齐: 想播放且当前没播 → toggle 一下; 想暂停且当前在播 → toggle。
            // 已经对齐就别动 (避免来回开停)。
            if desired != player.isPlaybackActive { player.togglePlayPause() }
        }
        bridge.next = { await player.next(caller: "AppIntent") }
        bridge.previous = { await player.previous() }
        bridge.resumePlayback = {
            guard player.currentSong != nil else { return false }
            player.resume()
            return true
        }

        bridge.playSong = { [self] title, artist in
            let query = SiriMediaSearchQuery(
                kind: .song,
                mediaName: title,
                artistName: artist
            )
            guard let match = SiriMediaSearchResolver.resolve(
                query: query,
                songs: library.visibleSongs
            ), let song = match.queue.first else {
                return nil
            }
            // A named selection is an exact request. Keeping a one-item queue
            // prevents the player's failure auto-advance from silently playing
            // an unrelated library song when that source is temporarily down.
            guard startIntentQueue([song]) != nil else { return nil }
            if let artist = song.artistName, !artist.isEmpty {
                return String(
                    format: String(localized: "intent_playing_song_by_format"),
                    song.title,
                    artist
                )
            }
            return String(
                format: String(localized: "intent_playing_song_format"),
                song.title
            )
        }

        bridge.playAlbum = { [self] title, artist in
            guard let result = SiriMediaSearchResolver.resolve(
                query: SiriMediaSearchQuery(
                    kind: .album,
                    mediaName: title,
                    artistName: artist
                ),
                songs: library.visibleSongs
            ), let first = startIntentQueue(result.queue) else {
                return nil
            }
            return String(
                format: String(localized: "intent_playing_album_format"),
                first.albumTitle ?? title
            )
        }

        bridge.playArtist = { [self] name in
            guard let result = SiriMediaSearchResolver.resolve(
                query: SiriMediaSearchQuery(kind: .artist, mediaName: name),
                songs: library.visibleSongs
            ), let first = startIntentQueue(result.queue) else {
                return nil
            }
            return String(
                format: String(localized: "intent_playing_artist_format"),
                first.artistName ?? name
            )
        }

        bridge.playGenre = { [self] name in
            guard let result = SiriMediaSearchResolver.resolve(
                query: SiriMediaSearchQuery(kind: .genre, genreNames: [name]),
                songs: library.visibleSongs
            ), startIntentQueue(result.queue) != nil else {
                return nil
            }
            return String(
                format: String(localized: "intent_playing_genre_format"),
                name
            )
        }

        bridge.playPlaylist = { [self] name in
            let items = library.playlists.map {
                SiriNamedMediaItem(id: $0.id, name: $0.name)
            } + library.smartPlaylists.map {
                SiriNamedMediaItem(id: $0.id, name: $0.name)
            }
            guard let resolved = SiriNamedMediaResolver.resolve(
                query: name,
                namespace: "playlist",
                items: items
            ) else {
                return nil
            }

            let songs: [Song]
            if let playlist = library.playlists.first(where: { $0.id == resolved.selected.id }) {
                songs = library.songs(forPlaylist: playlist.id)
            } else if let smart = library.smartPlaylists.first(where: { $0.id == resolved.selected.id }) {
                songs = SmartPlaylistEngine.match(smart, in: library, history: .shared)
            } else {
                return nil
            }
            guard startIntentQueue(songs) != nil else { return nil }
            return String(
                format: String(localized: "intent_playing_playlist_format"),
                resolved.selected.name
            )
        }

        bridge.playRadio = { [self] name in
            let stations = radioStationsStore.stations
            guard let resolved = SiriNamedMediaResolver.resolve(
                query: name,
                namespace: "radio",
                items: stations.map { SiriNamedMediaItem(id: $0.id, name: $0.name) }
            ), let station = radioStationsStore.station(id: resolved.selected.id) else {
                return nil
            }
            startIntentRadio(station)
            return String(
                format: String(localized: "intent_playing_radio_format"),
                station.name
            )
        }

        bridge.playSongRadio = { [self] in
            guard let seed = player.currentSong, !player.isLiveRadio else { return nil }
            let queue = MusicDiscoveryEngine.songRadio(
                from: seed,
                in: library,
                limit: 48
            ).map(\.song)
            guard startIntentQueue(queue) != nil else { return nil }
            return String(
                format: String(localized: "intent_playing_similar_format"),
                seed.title
            )
        }

        bridge.shuffleLibrary = { [self] in
            let pool = library.visibleSongs.filteredPlayable()
            _ = startIntentQueue(pool, shuffled: true)
        }

        bridge.setRepeatMode = { player.repeatMode = $0 }
        bridge.setPlaybackSpeed = { [self] requested in
            let effective = min(max(requested, 0.5), 2.0)
            playbackSettingsStore.playbackRate = Float(effective)
            player.applyPlaybackRate()
            return effective
        }

        bridge.scrapeCurrentSong = { [self] in
            await scrapeCurrentSongFromIntent()
        }

        bridge.setLiked = { desired in
            guard let songID = player.currentSong?.id else { return }
            // 对齐到目标状态: 已经是想要的结果就别再 toggle 一次。
            guard library.isLiked(songID: songID) != desired else { return }
            library.toggleLiked(songID: songID)
            // 心的状态同时挂在两个 surface 上, 都要立刻跟上, 否则乐观 UI
            // 会在下一次刷新时被旧数据打回去。
            player.republishNowPlayingSurfaces()
        }
    }

    /// Queue acceptance is synchronous; remote URL resolution and first-buffer
    /// decoding continue independently so Siri/App Intents can respond before
    /// their interaction timeout.
    @discardableResult
    private func startIntentQueue(_ songs: [Song], shuffled: Bool = false) -> Song? {
        var queue = songs.filteredPlayable()
        guard !queue.isEmpty else { return nil }
        if shuffled { queue.shuffle() }
        let first = queue[0]
        playerService.shuffleEnabled = shuffled
        playerService.setQueue(queue, startAt: 0)
        Task { @MainActor [playerService] in
            await playerService.play(song: first, caller: "AppIntent")
        }
        return first
    }

    private func startIntentRadio(_ station: RadioStation) {
        let stations = radioStationsStore.stations
        Task { @MainActor [playerService] in
            await playerService.play(station: station, within: stations)
        }
    }

    private func scrapeCurrentSongFromIntent() async -> String? {
        if playerService.isLiveRadio {
            return String(localized: "intent_scrape_live_radio_unsupported")
        }
        guard let displayedSong = playerService.currentSong else { return nil }
        guard SingleSongScrapeGatePolicy.decision(
            for: .appIntent,
            enabledSourceCount: ScraperSettings.load().enabledSources.count
        ) == .proceed else {
            return String(localized: "intent_scrape_no_source")
        }

        if displayedSong.sourceID == AppleMusicLibraryIdentity.sourceID {
            let song = appleMusicLibrary.canonicalLibrarySong(for: displayedSong)
            if song.id != displayedSong.id {
                _ = await MetadataAssetStore.shared.preserveLyricsAlias(
                    fromSongID: displayedSong.id,
                    toSongID: song.id
                )
                if playerService.currentSong?.id == displayedSong.id {
                    playerService.adoptCanonicalAppleMusicSong(
                        song,
                        replacing: displayedSong.id
                    )
                }
            }
            let startResult = scraperService.startOnlineLyricsOnlyScrape(
                song: song,
                in: musicLibrary
            )
            let runID: UUID
            switch startResult {
            case .started(let id), .joined(let id):
                runID = id
            case .busy:
                return String(localized: "intent_scrape_busy")
            case .noScraperSource:
                return String(localized: "intent_scrape_no_source")
            }
            Task { @MainActor [scraperService, playerService] in
                do {
                    let updated = try await scraperService.awaitSingleScrape(runID: runID).song
                    if playerService.currentSong?.id == updated.id {
                        playerService.syncSongMetadata(updated)
                        playerService.forceRefreshNowPlayingArtwork()
                    }
                    plog("🎙️ AppIntent lyrics scrape completed song=\(updated.id.prefix(12))")
                } catch {
                    plog("⚠️ AppIntent lyrics scrape failed: \(error.localizedDescription)")
                }
            }
            return String(
                format: String(localized: "intent_scrape_started_lyrics_format"),
                song.title
            )
        }

        switch scraperService.scrapeMissingMetadata(
            songs: [displayedSong],
            in: musicLibrary
        ) {
        case .started:
            plog("🎙️ AppIntent scrape started song=\(displayedSong.id.prefix(12))")
            return String(
                format: String(localized: "intent_scrape_started_metadata_format"),
                displayedSong.title
            )
        case .busy:
            return String(localized: "intent_scrape_busy")
        case .deferred:
            return String(localized: "intent_scrape_deferred")
        case .empty:
            return String(
                format: String(localized: "intent_scrape_nothing_missing_format"),
                displayedSong.title
            )
        case .noScraperSource:
            return String(localized: "intent_scrape_no_source")
        }
    }
}
