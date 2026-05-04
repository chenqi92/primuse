import BackgroundTasks
import CloudKit
import Intents
import SwiftUI
import UIKit
import PrimuseKit

/// Forwards CloudKit silent pushes to the sync engine. CKSyncEngine relies on these
/// to know when to fetch — without forwarding, sync only happens on app launch and
/// manual "sync now" presses.
final class PrimuseAppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static weak var sync: CloudKitSyncService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        registerBackgroundScanResume()
        return true
    }

    /// Register a BGProcessingTask handler that resumes any interrupted scans.
    /// iOS fires this when the device is idle and on a network connection,
    /// giving us several minutes of CPU time to keep scanning.
    private func registerBackgroundScanResume() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ScanService.backgroundTaskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                let services = AppServices.shared
                let scanService = services.scanService
                let backfill = services.metadataBackfill

                task.expirationHandler = {
                    Task { @MainActor in
                        scanService.cancelAllActiveScans()
                        backfill.stop()
                    }
                }

                // Resume any interrupted scans, then run backfill until the
                // task expires or work runs out. Both phases use HTTP Range
                // / list-only API calls — safe for iOS background quotas.
                scanService.resumePendingScans(
                    sourceManager: services.sourceManager,
                    library: services.musicLibrary,
                    sourceStore: services.sourcesStore,
                    scraperService: services.scraperService
                )
                await scanService.waitForActiveScansToComplete()

                backfill.start()
                await backfill.waitUntilIdle()

                // If anything still has a checkpoint or pending bare songs,
                // ask iOS to wake us again later.
                scanService.scheduleBackgroundResumeIfNeeded(
                    backfillPending: backfill.hasPendingWork
                )
                task.setTaskCompleted(success: true)
            }
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKDatabaseNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await Self.sync?.syncNow()
            completionHandler(.newData)
        }
    }

    // Routes Siri voice intents (INPlayMediaIntent etc.) to a handler. Without
    // an Intents Extension this only fires while the app is running, but
    // CarPlay voice and Shortcuts both work this way.
    static let playMediaHandler = PlayMediaIntentHandler()

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            return Self.playMediaHandler
        }
        return nil
    }
}

@main
struct PrimuseApp: App {
    @UIApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    @State private var sourcesStore: SourcesStore
    @State private var sourceManager: SourceManager
    @State private var playerService: AudioPlayerService
    @State private var scraperSettingsStore: ScraperSettingsStore
    @State private var scraperService: MusicScraperService
    @State private var musicLibrary: MusicLibrary
    @State private var playbackSettingsStore: PlaybackSettingsStore
    @State private var cloudSync: CloudKitSyncService
    @State private var themeService: ThemeService
    @State private var scanService: ScanService
    @State private var metadataBackfill: MetadataBackfillService

    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true

    init() {
        let services = AppServices.shared
        _sourcesStore = State(initialValue: services.sourcesStore)
        _sourceManager = State(initialValue: services.sourceManager)
        _playerService = State(initialValue: services.playerService)
        _scraperSettingsStore = State(initialValue: services.scraperSettingsStore)
        _scraperService = State(initialValue: services.scraperService)
        _musicLibrary = State(initialValue: services.musicLibrary)
        _playbackSettingsStore = State(initialValue: services.playbackSettingsStore)
        _cloudSync = State(initialValue: services.cloudSync)
        _themeService = State(initialValue: services.themeService)
        _scanService = State(initialValue: services.scanService)
        _metadataBackfill = State(initialValue: services.metadataBackfill)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(themeService.accentColor)
                .environment(themeService)
                .environment(playerService)
                .environment(playerService.audioEngine)
                .environment(playerService.equalizerService)
                .environment(playerService.audioEffectsService)
                .environment(musicLibrary)
                .environment(sourcesStore)
                .environment(sourceManager)
                .environment(scraperSettingsStore)
                .environment(scraperService)
                .environment(playbackSettingsStore)
                .environment(scanService)
                .environment(cloudSync)
                .environment(metadataBackfill)
                .task {
                    PrimuseAppDelegate.sync = cloudSync
                    if iCloudSyncEnabled { await cloudSync.start() }
                    // Stage 4c migration: deduplicate legacy
                    // duplicate-OAuth sources by upstream account UID.
                    // Runs once (gated by UserDefaults flag); needs
                    // CloudKit sync started first so any
                    // newly-synced sources participate. Backfill
                    // starts after — it'll see the merged song set.
                    await CloudAccountMigrationService.runIfNeeded(
                        sourcesStore: sourcesStore,
                        sourceManager: sourceManager,
                        library: musicLibrary
                    )
                    // Catch up on any songs that were left "bare" by a previous
                    // scan (cloud sources only download metadata in the
                    // background after Phase A completes).
                    metadataBackfill.start()
                    // 清掉 7 天没动的 .partial 半成品 —— Range streaming 路径
                    // 用户跳过 / prewarm 完没接着播的歌会留下大量孤立
                    // .partial 永久占盘, LRU 看不到这些。同步执行很快
                    // (只 stat mtime, 不读内容)。
                    sourceManager.pruneStalePartialFiles()
                    // 启动 prewarm —— 只覆盖 currentSong + queue 接下来 5 首。
                    // 之前还会接着 prewarm 整个 library, 一首歌 1MB head +
                    // 256KB tail = 1.25MB, 818 首 ≈ 1GB 后台流量, 用户开
                    // app 听一首歌就发现缓存涨 100MB+。换来的"任意点歌
                    // 首播 < 200ms"对小库或许值得, 对中大型库性价比极差
                    // (绝大多数预热的歌不会被听), 所以砍掉。play(song:)
                    // 路径里的 cacheInBackground 会按需 prewarm 用户实际
                    // 点的歌, 行为退化为「点啥热啥」, 总体盘可控。
                    Task.detached(priority: .background) {
                        // 1. currentSong (resume): 优先级最高,提到 .userInitiated
                        //    用户立刻按 play 时大概率就是这首
                        let resumeSong = await MainActor.run { playerService.currentSong }
                        if let song = resumeSong {
                            await Task.detached(priority: .userInitiated) {
                                await sourceManager.prewarmCloudSongPublic(song: song)
                            }.value
                        }

                        // 2. queue 接下来的歌: 已经摆好播放队列时,继续往后跑很可能
                        let queueSnapshot = await MainActor.run { playerService.queue }
                        let resumeID = resumeSong?.id
                        let queueOrder = queueSnapshot.filter { $0.id != resumeID }.prefix(5)
                        for song in queueOrder {
                            if Task.isCancelled { return }
                            let done = await MainActor.run { sourceManager.isPrewarmed(song: song) }
                            if done { continue }
                            await sourceManager.prewarmCloudSongPublic(song: song)
                        }
                    }
                }
                .onChange(of: playerService.currentSong?.id) { _, _ in
                    themeService.updateFromCoverArt(
                        fileName: playerService.currentSong?.coverArtFileName,
                        songID: playerService.currentSong?.id
                    )
                }
                // Sync player when library replaces a song (e.g. batch scraping
                // or metadata backfill updates metadata). Backfill uses
                // batched `replaceSongs`, so the currently-playing song may
                // be ANYWHERE in the batch, not just the last entry — we
                // check `lastReplacedSongIDs` to catch every case.
                .onChange(of: musicLibrary.songReplacementToken) { _, _ in
                    guard let currentID = playerService.currentSong?.id,
                          musicLibrary.lastReplacedSongIDs.contains(currentID),
                          let updated = musicLibrary.songs.first(where: { $0.id == currentID })
                    else { return }
                    playerService.syncSongMetadata(updated)
                    playerService.forceRefreshNowPlayingArtwork()
                    themeService.updateFromCoverArt(
                        fileName: updated.coverArtFileName,
                        songID: updated.id
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    playerService.handleAppWillResignActive()
                    musicLibrary.persistNow()
                    // If a scan was running OR backfill has pending work, ask
                    // iOS to wake us later via BGProcessingTask so we can keep
                    // going past the beginBackgroundTask 30s ceiling.
                    scanService.scheduleBackgroundResumeIfNeeded(
                        backfillPending: metadataBackfill.hasPendingWork
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    playerService.handleAppDidBecomeActive()
                    // Auto-resume any scan that was interrupted (app killed,
                    // backgrounded past the begin/endBackgroundTask window, or
                    // crashed mid-scan). Idempotent.
                    scanService.resumePendingScans(
                        sourceManager: sourceManager,
                        library: musicLibrary,
                        sourceStore: sourcesStore,
                        scraperService: scraperService
                    )
                    // Pick up any bare songs left behind by an earlier scan.
                    metadataBackfill.start()
                }
                // After every library write (scan progress, replaceSong, etc.)
                // re-evaluate whether there's bare-song work to do. This
                // ensures backfill kicks in the moment Phase A produces its
                // first batch instead of waiting for app foreground.
                .onChange(of: musicLibrary.songs.count) { _, _ in
                    metadataBackfill.refreshQueue()
                }
                // Auto-resume backfill when the user reconnects to Wi-Fi
                // after the cellular gate paused it.
                .onChange(of: NetworkMonitor.shared.isOnUnmeteredNetwork) { _, onWifi in
                    if onWifi { metadataBackfill.start() }
                }
        }
    }
}
