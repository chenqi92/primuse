import Foundation
import PrimuseKit

@MainActor
final class AppServices {
    static let shared = AppServices()

    let sourcesStore: SourcesStore
    let sourceManager: SourceManager
    let playerService: AudioPlayerService
    let scraperSettingsStore: ScraperSettingsStore
    let scraperService: MusicScraperService
    let musicLibrary: MusicLibrary
    let playbackSettingsStore: PlaybackSettingsStore
    let cloudSync: CloudKitSyncService
    let themeService: ThemeService
    let scanService: ScanService
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

    private var sourceLifecycleObserverTokens: [NSObjectProtocol] = []

    private init() {
        // Class is @MainActor so this initializer is too — but the static
        // `shared` instantiation is lazy-on-first-access. If anything
        // ever touches `AppServices.shared` from a non-main thread, Swift
        // will hop here implicitly and we'd silently break invariants in
        // the services we own. Crash loudly instead.
        dispatchPrecondition(condition: .onQueue(.main))

        if CloudSyncChannel.usesSynchronizableKeychain() {
            KeychainService.migrateLegacyEntriesToICloud()
            CloudTokenManager.migrateLegacyEntriesToICloud()
        }

        let store = SourcesStore()
        let manager = SourceManager(sourcesProvider: {
            await MainActor.run { store.sources }
        })
        let scraperSettings = ScraperSettingsStore()
        let scraper = MusicScraperService(sourceManager: manager)
        let library = MusicLibrary()
        let playbackSettings = PlaybackSettingsStore()
        let player = AudioPlayerService(sourceManager: manager, library: library, playbackSettings: playbackSettings)
        let sync = CloudKitSyncService(
            library: library,
            sourcesStore: store,
            scraperConfigStore: .shared,
            scraperSettingsStore: scraperSettings
        )

        self.sourcesStore = store
        self.sourceManager = manager
        self.playerService = player
        self.scraperSettingsStore = scraperSettings
        self.scraperService = scraper
        self.musicLibrary = library
        self.playbackSettingsStore = playbackSettings
        self.cloudSync = sync
        let theme = ThemeService()
        // Pull the user's chosen app icon tint into the theme so the in-app
        // accent matches the icon they picked. Cover-art-derived colors will
        // override this while a song with artwork plays.
        #if os(iOS)
        theme.setBaseAccent(AppIconService.shared.currentTint)
        #else
        // macOS: 用用户在「外观」里选的品牌色作为 ambient fallback (没封面取色时)。
        theme.setBaseAccent(MacUIPreferences.shared.brandColor)
        #endif
        self.themeService = theme
        self.scanService = ScanService()
        self.metadataBackfill = MetadataBackfillService(library: library, sourceManager: manager) {
            Set(store.sources.filter { $0.isEnabled && $0.supportsRangeStreaming }.map(\.id))
        }
        self.lyricsTextBackfill = LyricsTextBackfillService(library: library)
        self.similarTracks = SimilarTracksService()
        self.updateChecker = AppUpdateChecker()
        self.coverTintProvider = CoverTintProvider()
        self.spotlightIndex = SpotlightIndexService()
        let amService = AppleMusicService()
        self.appleMusic = amService
        self.appleMusicLibrary = AppleMusicLibraryService(library: library, appleMusic: amService)

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

        library.updateDisabledSourceIDs(
            Set(store.sources.filter { !$0.isEnabled }.map(\.id))
        )

        // Wire the library's tombstone identity resolver. Maps a song's
        // mount UUID → its CloudAccount id (when available) so deletion
        // tombstones survive re-OAuth — the user re-adding the same
        // Baidu account mints a new mount UUID, which would otherwise
        // change song.id and silently bypass the tombstone set.
        library.sourceIdentityResolver = { [weak store] sourceID in
            store?.allSources.first(where: { $0.id == sourceID })?.cloudAccountID
        }

        observeSourceLifecycle()

        let pruneThreshold = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        library.prunePlaylists(deletedBefore: pruneThreshold)
        store.pruneSources(deletedBefore: pruneThreshold)
        ScraperConfigStore.shared.pruneConfigs(deletedBefore: pruneThreshold)
        reconcileDeletedSourceSongs()

        CloudKVSSync.shared.register(key: CloudKVSKey.lyricsFontScale) { }
        CloudKVSSync.shared.register(key: CloudKVSKey.recentSearches) { }

        // Phase 3:Apple TV 中继(默认关闭,用户在设置开启)。开启后 Apple TV 可经本机
        // 局域网播放本地 / SMB / SFTP / NFS / WebDAV 等不可直连的源。
        PhoneRelayServer.shared.startIfEnabled(sourceManager: manager, sourcesStore: store, library: library)

        wireIntentBridge()
        observeSpotlightReindex()
        rescanLocalImportIfNeeded()
        // 注意: 不在这里接线 Live Activity。PrimuseActivityExtension 的灵动岛 /
        // 锁屏布局仍是半成品(切歌不更新、杀进程后不消失),激活它比留作未启用
        // 更糟。Live Activity 作为完整功能另行实现后再接线。
    }

    private func rescanLocalImportIfNeeded() {
        #if os(iOS)
        guard let sourceID = LocalImportService.existingSourceID,
              musicLibrary.songs.contains(where: { $0.sourceID == sourceID && $0.duration <= 0 }),
              let source = sourcesStore.source(id: sourceID),
              source.isEnabled,
              !source.isDeleted else { return }
        plog("📥 LocalImport: detected unplayable local rows, scheduling local rescan")
        scanService.scanSource(
            source,
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
                Task { @MainActor in
                    // 软删(进回收站)即回收空间:删本地导入源在沙箱的原始拷贝。
                    // 产品取舍 —— restore 不会自动重扫找回歌, 保留拷贝意义不大,
                    // 而用户删源的核心诉求就是立即回收空间。Toggling isEnabled
                    // never posts this notification.
                    self.removeSourceLibraryData(id: id, purgePersistentCaches: true, removeImportedFiles: true)
                    self.uploadSourcesSnapshotAfterSoftDeleteIfNeeded()
                }
            }
        )

        sourceLifecycleObserverTokens.append(
            nc.addObserver(forName: .primuseSourceDidDelete, object: nil, queue: .main) { [weak self] note in
                guard let self, let id = note.userInfo?["id"] as? String else { return }
                Task { @MainActor in
                    // 永久删除(回收站清空 / 30 天清理 / CloudKit 远端永久删 echo)。
                    // 软删时通常已回收, 这里幂等兜底(目录已删则 removeItem no-op)。
                    self.removeSourceLibraryData(id: id, purgePersistentCaches: true, removeImportedFiles: true)
                }
            }
        )
    }

    private func uploadSourcesSnapshotAfterSoftDeleteIfNeeded() {
        guard CloudSyncChannel.isEnabled(.sources) else { return }
        Task.detached(priority: .background) {
            await LibrarySnapshotSync.shared.uploadSourcesOnly()
        }
    }

    private func removeSourceLibraryData(id: String, purgePersistentCaches: Bool, removeImportedFiles: Bool = false) {
        scanService.cancelScan(for: id)
        scanService.removeCheckpoint(for: id)
        scanService.removeSynologyAPI(for: id)
        metadataBackfill.discardWork(forSourceID: id)
        musicLibrary.removeSongsForSource(id)
        sourcesStore.updateLocal(id) {
            $0.songCount = 0
            $0.lastScannedAt = nil
        }

        if purgePersistentCaches {
            sourceManager.deleteSourceCaches(sourceID: id)
        }

        if removeImportedFiles {
            removeImportedLocalFilesIfNeeded(sourceID: id)
        }

        Task { @MainActor in
            await sourceManager.removeConnector(for: id)
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
        let sourceSongCounts = Dictionary(grouping: musicLibrary.songs, by: \.sourceID)
            .mapValues(\.count)
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

    /// Spotlight 重建索引 ── 启动时跑一次, 之后只要 library 的
    /// songReplacementToken 翻动 (新增/删除/批量替换) 就重新拉一次。
    /// Observation 自动 re-arm,跟 MacMenuBarController 的 observePlayerState
    /// 是同一个模式。
    private func observeSpotlightReindex() {
        let library = self.musicLibrary
        let index = self.spotlightIndex
        // 启动 reindex 延 1s,等 CloudKit 同步先拉一拨远端歌单 / 设置,避免
        // 反复重建。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            index.reindex(library: library)
        }

        observeLibraryToken(library: library, index: index)
    }

    private func observeLibraryToken(library: MusicLibrary, index: SpotlightIndexService) {
        withObservationTracking {
            _ = library.songReplacementToken
            _ = library.songs.count
            _ = library.playlists.count
        } onChange: { [weak library, weak index] in
            Task { @MainActor [weak self] in
                guard let library, let index else { return }
                index.reindex(library: library)
                self?.observeLibraryToken(library: library, index: index)
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
            if desired != player.isPlaying { player.togglePlayPause() }
        }
        bridge.next = { await player.next(caller: "AppIntent") }
        bridge.previous = { await player.previous() }

        bridge.playSong = { title, artist in
            let candidates = Self.matchingSongs(in: library.visibleSongs, title: title, artist: artist)
                .filteredPlayable()
            guard let song = candidates.first else { return nil }
            // 命中歌 + 整库剩下的拼起来当队列,播完会自然往下接。
            let rest = library.visibleSongs
                .filter { s in !candidates.contains(where: { $0.id == s.id }) }
                .filteredPlayable()
            player.setQueue(candidates + rest, startAt: 0)
            await player.play(song: song, caller: "AppIntent")
            let by = song.artistName.map { " by \($0)" } ?? ""
            return "Playing \(song.title)\(by)"
        }

        bridge.playPlaylist = { name in
            let trimmed = name.lowercased()
            let exact = library.playlists.first(where: { $0.name.lowercased() == trimmed })
            let target = exact ?? library.playlists.first(where: { $0.name.lowercased().contains(trimmed) })
            guard let playlist = target else { return nil }
            let songs = library.songs(forPlaylist: playlist.id).filteredPlayable()
            guard let first = songs.first else { return nil }
            player.setQueue(songs, startAt: 0)
            await player.play(song: first, caller: "AppIntent")
            return "Playing playlist \(playlist.name)."
        }

        bridge.shuffleLibrary = {
            let pool = library.visibleSongs.filteredPlayable().shuffled()
            guard let first = pool.first else { return }
            player.setQueue(pool, startAt: 0)
            await player.play(song: first, caller: "AppIntent")
        }
    }

    /// 模糊匹配 ── title 包含 + (可选) artist 包含,都不区分大小写。
    /// 精确 title 匹配排前。
    private static func matchingSongs(in songs: [Song], title: String, artist: String?) -> [Song] {
        let titleLower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleLower.isEmpty else { return [] }
        let artistLower = artist?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = songs.filter { s in
            let titleMatch = s.title.lowercased().contains(titleLower)
            guard titleMatch else { return false }
            if let artistLower, !artistLower.isEmpty {
                return (s.artistName ?? "").lowercased().contains(artistLower)
            }
            return true
        }
        return filtered.sorted { a, b in
            let aExact = a.title.lowercased() == titleLower
            let bExact = b.title.lowercased() == titleLower
            if aExact != bExact { return aExact }
            return false
        }
    }
}
