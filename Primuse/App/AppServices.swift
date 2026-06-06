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
        self.metadataBackfill = MetadataBackfillService(library: library, sourceManager: manager)
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

        let pruneThreshold = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        library.prunePlaylists(deletedBefore: pruneThreshold)
        store.pruneSources(deletedBefore: pruneThreshold)
        ScraperConfigStore.shared.pruneConfigs(deletedBefore: pruneThreshold)

        CloudKVSSync.shared.register(key: CloudKVSKey.lyricsFontScale) { }
        CloudKVSSync.shared.register(key: CloudKVSKey.recentSearches) { }

        // Phase 3:Apple TV 中继(默认关闭,用户在设置开启)。开启后 Apple TV 可经本机
        // 局域网播放本地 / SMB / SFTP / NFS / WebDAV 等不可直连的源。
        PhoneRelayServer.shared.startIfEnabled(sourceManager: manager, sourcesStore: store, library: library)

        wireIntentBridge()
        observeSpotlightReindex()
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
            guard let song = candidates.first else { return nil }
            // 命中歌 + 整库剩下的拼起来当队列,播完会自然往下接。
            let rest = library.visibleSongs.filter { s in !candidates.contains(where: { $0.id == s.id }) }
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
            let songs = library.songs(forPlaylist: playlist.id)
            guard let first = songs.first else { return nil }
            player.setQueue(songs, startAt: 0)
            await player.play(song: first, caller: "AppIntent")
            return "Playing playlist \(playlist.name)."
        }

        bridge.shuffleLibrary = {
            let pool = library.visibleSongs.shuffled()
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
