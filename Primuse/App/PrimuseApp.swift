import CloudKit
import SwiftUI
import PrimuseKit
#if os(iOS)
import BackgroundTasks
import Intents
import UIKit

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
#else
import AppKit

extension Notification.Name {
    /// 进入全屏播放器时由 PrimuseAppDelegate 发出,MacContentView 收到后
    /// 自动展开 NowPlaying 视图,让全屏内容直接是播放器而不是歌单。
    static let primuseRequestExpandNowPlaying = Notification.Name("primuse.expandNowPlaying")
}

/// macOS counterpart of `PrimuseAppDelegate`. macOS has no BGTaskScheduler /
/// CarPlay / Intents-handler routing — the delegate exists only to forward
/// CloudKit silent pushes the same way the iOS one does, plus install the
/// menu bar status item.
final class PrimuseAppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static weak var sync: CloudKitSyncService?
    /// SwiftUI macOS 14+ 把自定义 AppDelegate 包了一层,`NSApp.delegate as?
    /// PrimuseAppDelegate` 会失败(实际是 NSApplicationDelegate 协议类型,
    /// 不是具体类),导致从 SwiftUI view 里调 AppDelegate 上的方法静默失效。
    /// 用一个 weak shared 引用绕开这个坑,SwiftUI 视图直接拿。
    @MainActor static weak var shared: PrimuseAppDelegate?
    @MainActor private var menuBar: MacMenuBarController?
    @MainActor private var desktopLyrics: DesktopLyricsWindowController?
    @MainActor private var miniPlayer: MiniPlayerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        Task { @MainActor in
            Self.shared = self

            let bar = MacMenuBarController()
            bar.install()
            self.menuBar = bar

            let lyrics = DesktopLyricsWindowController()
            self.desktopLyrics = lyrics

            self.miniPlayer = MiniPlayerWindowController()
            plog("🪟 AppDelegate didFinishLaunching: menuBar=ok lyrics=ok miniPlayer=\(self.miniPlayer == nil ? "nil" : "ok") delegateType=\(type(of: NSApp.delegate as Any))")
        }
    }

    @MainActor
    func toggleDesktopLyrics() {
        plog("🪟 AppDelegate.toggleDesktopLyrics desktopLyrics=\(desktopLyrics == nil ? "nil" : "ok")")
        desktopLyrics?.toggle()
    }

    @MainActor
    func showMiniPlayer() {
        plog("🪟 AppDelegate.showMiniPlayer miniPlayer=\(miniPlayer == nil ? "nil" : "ok")")
        miniPlayer?.show()
    }

    @MainActor
    func toggleFullScreenPlayer() {
        // 主窗口切到 macOS 全屏 + 自动展开 NowPlaying。退出全屏由用户
        // 主动按 ⌃⌘F 或绿灯触发,这里只负责进入。
        guard let window = mainAppWindow() else {
            plog("⚠️ FullScreen: no main window candidate found, all windows: \(NSApp.windows.map { ($0.title, $0.styleMask.rawValue, $0.canBecomeMain) })")
            return
        }
        // SwiftUI 的 WindowGroup 默认 collectionBehavior 不带
        // .fullScreenPrimary,导致 toggleFullScreen 静默无效。先补上。
        if !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        plog("🖥 FullScreen toggle window=\(window.title) isFull=\(window.styleMask.contains(.fullScreen)) cb=\(window.collectionBehavior.rawValue)")
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        NotificationCenter.default.post(name: .primuseRequestExpandNowPlaying, object: nil)
    }

    /// 在所有 NSApp.windows 里挑出 SwiftUI 主窗口(不是 mini player /
    /// desktop lyrics / popover / panel 等附属窗口)。靠两个特征:
    /// 是 NSWindow 而非 NSPanel,并且 canBecomeMain。
    @MainActor
    private func mainAppWindow() -> NSWindow? {
        // 优先 mainWindow / keyWindow,如果它符合"非 panel + canBecomeMain"
        // 就直接用,这是 macOS 标准 mainWindow 选择器。
        if let main = NSApp.mainWindow, !(main is NSPanel), main.canBecomeMain {
            return main
        }
        if let key = NSApp.keyWindow, !(key is NSPanel), key.canBecomeMain {
            return key
        }
        // fallback: 遍历所有窗口找第一个不是 panel 的可主窗口。
        return NSApp.windows.first {
            !($0 is NSPanel) && $0.canBecomeMain &&
            !$0.styleMask.contains(.utilityWindow) &&
            $0.frameAutosaveName != "PrimuseMiniPlayer" &&
            $0.frameAutosaveName != "PrimuseDesktopLyrics"
        }
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard CKDatabaseNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        Task { @MainActor in await Self.sync?.syncNow() }
    }
}
#endif

@main
struct PrimuseApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    #endif
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
    @Environment(\.scenePhase) private var scenePhase

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

    @ViewBuilder
    private func injectServices<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        // On macOS we deliberately don't force the global tint to the brand
        // purple — letting SwiftUI fall through to the user's system accent
        // makes Toggle / Checkbox / standard buttons look native instead of
        // blanketed in iOS purple. Hand-built UI elements that need brand
        // tinting keep `themeService.accentColor` directly.
        let injected = content()
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
        #if os(iOS)
        return injected.tint(themeService.accentColor)
        #else
        return injected
        #endif
    }

    var body: some Scene {
        WindowGroup {
            injectServices {
                #if os(iOS)
                ContentView()
                #else
                MacContentView()
                #endif
            }
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
                    // Re-prewarm any cloud songs whose `.partial` cache or
                    // CDN URL has expired since last launch. Cheap (skips
                    // already-prewarmed via marker check); huge win on the
                    // first play after a cold start where every CDN HEAD
                    // would otherwise add 3-20s of latency in front of the
                    // user.
                    Task.detached(priority: .background) {
                        let snapshot = await MainActor.run { musicLibrary.songs }
                        for song in snapshot {
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
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background, .inactive:
                        playerService.handleAppWillResignActive()
                        musicLibrary.persistNow()
                        // If a scan was running OR backfill has pending work, ask
                        // iOS to wake us later via BGProcessingTask so we can keep
                        // going past the beginBackgroundTask 30s ceiling. (No-op
                        // on macOS — BGTaskScheduler doesn't exist there.)
                        scanService.scheduleBackgroundResumeIfNeeded(
                            backfillPending: metadataBackfill.hasPendingWork
                        )
                    case .active:
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
                    @unknown default:
                        break
                    }
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
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("show_desktop_lyrics") {
                    PrimuseAppDelegate.shared?.toggleDesktopLyrics()
                }
                .keyboardShortcut("l", modifiers: [.command])

                // 锁定后桌面歌词上的工具条会消失(因为 panel 设了
                // ignoresMouseEvents 实现"点击穿透"),用户没法再点
                // 解锁。这条命令 + 快捷键让用户在 Primuse 聚焦时也
                // 能直接解锁,不必去找菜单栏的 popover。
                Button("toggle_desktop_lyrics_lock") {
                    let key = "desktopLyricsLocked"
                    let locked = UserDefaults.standard.bool(forKey: key)
                    UserDefaults.standard.set(!locked, forKey: key)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            injectServices { MacSettingsView() }
        }
        // 防止切到内容少的 tab (RecentlyDeleted 空 / Replay Gain 关闭后
        // 的 Playback Settings) 时整个 Settings 窗口突兀缩小。
        .windowResizability(.contentMinSize)
        #endif
    }
}
