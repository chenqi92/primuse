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
        BackgroundScanResumeTask.register()
        // 年度报告: 启动时把 PlayHistoryStore 按年份归档, 防止 5000 条 FIFO
        // 上限把跨年的早期月份裁掉。详见 Docs/YearlyReport.md §二。
        Task { @MainActor in
            PlayHistoryArchiver.runIfNeeded()
        }
        return true
    }

    /// 系统在用户从 iMessage / 邮件 / Files 点开 .ck 分享链接时调这里, 把
    /// CKShare metadata 传给 app。我们转交给 CloudKitSyncService.acceptShare
    /// 完成 share 接受 + 启动 participant 侧的 sharedEngine。
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in
            await Self.sync?.acceptShare(metadata: cloudKitShareMetadata)
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

/// BGProcessingTask handler that resumes any interrupted scans. iOS fires
/// this when the device is idle and on a network connection, giving us
/// several minutes of CPU time to keep scanning.
private enum BackgroundScanResumeTask {
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ScanService.backgroundTaskIdentifier,
            using: nil
        ) { task in
            handle(task)
        }
    }

    private static func handle(_ task: BGTask) {
        let completion = BackgroundTaskCompletion(task)
        task.expirationHandler = {
            completion.complete(success: false)
            Task { @MainActor in
                let services = AppServices.shared
                services.scanService.cancelAllActiveScans()
                services.metadataBackfill.stop()
            }
        }

        Task { @MainActor in
            let services = AppServices.shared
            let scanService = services.scanService
            let backfill = services.metadataBackfill

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
            completion.complete(success: true)
        }
    }
}

private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var didComplete = false

    init(_ task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !didComplete else { return }
        didComplete = true
        task.setTaskCompleted(success: success)
    }
}
#else
import AppKit

extension Notification.Name {
    /// 进入全屏播放器时由 PrimuseAppDelegate 发出,MacContentView 收到后
    /// 自动展开 NowPlaying 视图,让全屏内容直接是播放器而不是歌单。
    static let primuseRequestExpandNowPlaying = Notification.Name("primuse.expandNowPlaying")
}

private enum MacScreenshotWindowPreset {
    private static let argumentPrefix = "--primuse-screenshot-window="

    private static var requestedSize: NSSize? {
        ProcessInfo.processInfo.arguments.compactMap { argument -> NSSize? in
            guard argument.hasPrefix(argumentPrefix) else { return nil }
            let rawValue = argument.dropFirst(argumentPrefix.count)
            let parts = rawValue.split(separator: "x")
            guard parts.count == 2,
                  let width = Double(String(parts[0])),
                  let height = Double(String(parts[1])),
                  width > 0,
                  height > 0 else {
                return nil
            }
            return NSSize(width: width, height: height)
        }.first
    }

    @MainActor
    static func applyIfRequested() {
        guard let size = requestedSize else { return }
        Task { @MainActor in
            for _ in 0..<80 {
                if let window = mainWindowCandidate() {
                    apply(size: size, to: window)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    @MainActor
    private static func mainWindowCandidate() -> NSWindow? {
        if let main = NSApp.mainWindow, isMainAppWindow(main) {
            return main
        }
        if let key = NSApp.keyWindow, isMainAppWindow(key) {
            return key
        }
        return NSApp.windows
            .filter(isMainAppWindow)
            .max { lhs, rhs in
                (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
            }
    }

    @MainActor
    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) &&
        window.canBecomeMain &&
        !window.styleMask.contains(.utilityWindow) &&
        window.frameAutosaveName != "PrimuseMiniPlayer" &&
        window.frameAutosaveName != "PrimuseDesktopLyrics"
    }

    @MainActor
    private static func apply(size: NSSize, to window: NSWindow) {
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: size)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// SwiftUI 的 `openWindow` action 只能在 View 层级里通过 `@Environment`
/// 拿到,但菜单栏 popover 上的 "Open Main Window" 按钮要从 AppKit 的
/// `MacMenuBarController` 调用——用户把主窗口红灯关掉后,`NSApp.windows`
/// 里已经没有 WindowGroup 创建的 NSWindow 可以 `makeKeyAndOrderFront`,
/// 按钮就静默失效。MacContentView 启动时把 action 注册过来,菜单栏
/// 兜底就有路径触发 SwiftUI 重建主窗口。
@MainActor
enum MainWindowOpener {
    static let mainWindowID = "primuse-main"
    private static var action: OpenWindowAction?

    static func register(_ openWindow: OpenWindowAction) {
        action = openWindow
    }

    static func openMainWindow() {
        action?(id: mainWindowID)
    }
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

            // 重放持久化的明暗模式 + Dock 图标 (didSet 在 init 期不触发)。
            MacUIPreferences.shared.applyOnLaunch()

            let bar = MacMenuBarController()
            bar.install()
            self.menuBar = bar

            let lyrics = DesktopLyricsWindowController()
            self.desktopLyrics = lyrics

            self.miniPlayer = MiniPlayerWindowController()
            plog("🪟 AppDelegate didFinishLaunching: menuBar=ok lyrics=ok miniPlayer=\(self.miniPlayer == nil ? "nil" : "ok") delegateType=\(type(of: NSApp.delegate as Any))")
            MacScreenshotWindowPreset.applyIfRequested()

            // 年度报告: 启动时把 PlayHistoryStore 按年份归档, 防止 5000 条
            // FIFO 上限把跨年的早期月份裁掉。详见 Docs/YearlyReport.md §二。
            PlayHistoryArchiver.runIfNeeded()
        }
    }

    @MainActor
    func toggleDesktopLyrics() {
        plog("🪟 AppDelegate.toggleDesktopLyrics desktopLyrics=\(desktopLyrics == nil ? "nil" : "ok")")
        desktopLyrics?.toggle()
    }

    @MainActor
    func toggleMiniPlayer() {
        plog("🪟 AppDelegate.toggleMiniPlayer miniPlayer=\(miniPlayer == nil ? "nil" : "ok")")
        miniPlayer?.toggle()
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
    @State private var updateChecker: AppUpdateChecker
    @State private var coverTintProvider: CoverTintProvider
    @State private var appleMusic: AppleMusicService
    @State private var appleMusicLibrary: AppleMusicLibraryService
    @State private var dlnaRenderer: DLNARendererService
    @State private var visualizer: AudioVisualizerService
    @State private var duplicateCleanup: DuplicateCleanupService

    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    /// DLNA 接收器持久开关。打开后启动时自动 start, 不需要进 Settings 触发。
    @AppStorage("dlna.rendererEnabled") private var dlnaRendererEnabled: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    /// 后台 connect() 失败时弹的 "登录失败" 提示。点 "重新输入" 后会把 source
    /// 存到 reauthSource 触发 AddSourceView sheet。
    @State private var authAlertSource: MusicSource?
    @State private var authAlertMessage: String = ""
    @State private var reauthSource: MusicSource?

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
        _updateChecker = State(initialValue: services.updateChecker)
        _coverTintProvider = State(initialValue: services.coverTintProvider)
        _appleMusic = State(initialValue: services.appleMusic)
        _appleMusicLibrary = State(initialValue: services.appleMusicLibrary)
        _dlnaRenderer = State(initialValue: services.dlnaRenderer)
        _visualizer = State(initialValue: services.visualizer)
        _duplicateCleanup = State(initialValue: services.duplicateCleanup)
    }

    /// macOS 给主 WindowGroup 一个稳定 id,菜单栏 "Open Main Window"
    /// 兜底走 `openWindow(id:)` 才能在窗口被关掉后重新拉出来; iOS 没这
    /// 需求,沿用原来的无 id 版本即可。
    @SceneBuilder
    private func macAwareMainGroup<V: View>(@ViewBuilder _ content: @escaping () -> V) -> some Scene {
        #if os(macOS)
        WindowGroup(id: MainWindowOpener.mainWindowID) { content() }
        #else
        WindowGroup { content() }
        #endif
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
            .environment(updateChecker)
            .environment(coverTintProvider)
            .environment(appleMusic)
            .environment(appleMusicLibrary)
            .environment(dlnaRenderer)
            .environment(visualizer)
            .environment(duplicateCleanup)
        #if os(iOS)
        return injected.tint(themeService.accentColor)
        #else
        return injected
        #endif
    }

    var body: some Scene {
        macAwareMainGroup {
            injectServices {
                #if os(iOS)
                ContentView()
                #else
                MacContentView()
                #endif
            }
                .task {
                    // Background-poll the App Store. Throttled internally
                    // to once per day, so calling on every scene-active is
                    // cheap. Failure is silent — banner only appears when
                    // a strictly newer version is found.
                    await updateChecker.checkForUpdate()
                }
                #if os(macOS)
                // 把 macOS 桌面小组件需要的快照(歌词/统计/音乐源/年度报告)写进
                // App Group。keyed 在当前歌曲上: 启动跑一次, 之后每次换歌刷新。
                .task(id: playerService.currentSong?.id) {
                    MacWidgetDataPublisher.publishAll(
                        player: playerService,
                        sources: sourcesStore,
                        sourceManager: sourceManager
                    )
                }
                #endif
                .task {
                    PrimuseAppDelegate.sync = cloudSync
                    // Apple Watch 桥 ── 启动 WCSession, 1Hz 推 Now Playing
                    // 状态到 Watch, 接收 Watch 端的播控指令。
                    // macOS 上 WatchConnectivity 不可用, attach 内部已做
                    // `#if os(iOS)` 守卫, 这里直接调即可。
                    #if os(iOS)
                    WatchSessionBridge.shared.attach(
                        player: playerService,
                        library: musicLibrary,
                        theme: themeService
                    )
                    #endif
                    if iCloudSyncEnabled { await cloudSync.start() }
                    if dlnaRendererEnabled { dlnaRenderer.start() }
                    // Apple Music user library 启动自动 sync 一次 ── songCache
                    // 是 in-memory, 重启后空; 没 cache → play 走 catalog lookup,
                    // 用 user library 的 i.* id 查 catalog 必失败 → 卡 loading。
                    // 同时填上 cache 后 ArtworkImage 才能拉到 user library 歌的
                    // 封面 (musicKit:// scheme 必须走 framework 内部解码)。
                    if appleMusic.authState == .authorized,
                       AppleMusicFeatureSettings.syncUserLibraryEnabled {
                        appleMusicLibrary.sync()
                    }
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
                    // 一次性把已缓存的 .lrc 解析成纯文本写回 Song.lyricsText,
                    // 让 FTS5 全文歌词搜索可用 (v5 migration 加了列但留空)。
                    // 完成后自带 UserDefaults flag, 后续启动直接 noop。
                    AppServices.shared.lyricsTextBackfill.startIfNeeded()
                    // 清掉 7 天没动的 .partial 半成品 —— Range streaming 路径
                    // 用户跳过 / prewarm 完没接着播的歌会留下大量孤立
                    // .partial 永久占盘, LRU 看不到这些。同步执行很快
                    // (只 stat mtime, 不读内容)。
                    sourceManager.pruneStalePartialFiles()
                    // 把内容寻址的封面 content/ 目录限定在 500MB 以内。
                    // 超过就按 mtime 删最老的物理 jpeg, ref 文件下次读
                    // miss → CachedArtworkView 自动重新拉。运行在 background
                    // 优先级 detached, 不阻塞启动序列。
                    Task.detached(priority: .background) {
                        await MetadataAssetStore.shared.evictArtworkContentIfNeeded()
                    }
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
                        let prewarmCount = await MainActor.run { playerService.playbackSettings.prewarmQueueCount }
                        let resumeID = resumeSong?.id
                        let queueOrder = queueSnapshot.filter { $0.id != resumeID }.prefix(prewarmCount)
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
                    // forceRefreshNowPlayingArtwork 内部已 bump coverRevision,
                    // 这里不需要重复 bump。三处封面 view 监听 revisionToken 会触发
                    // reload, 即便 coverArtFileName 字符串没变 (重复刮 deterministic
                    // hash 文件名时 coverRef 不变, onChange 不会触发)。
                    playerService.forceRefreshNowPlayingArtwork()
                    themeService.updateFromCoverArt(
                        fileName: updated.coverArtFileName,
                        songID: updated.id
                    )
                }
                #if os(macOS)
                // macOS OAuth 走系统浏览器,callback 通过 primuse:// URL Scheme
                // 回到 app。把 URL 转给 OAuthService 的 bridge 唤醒等待中的请求。
                .onOpenURL { url in
                    plog("🔗 onOpenURL: \(url.absoluteString)")
                    if MacOAuthBridge.shared.handle(url) {
                        plog("🔗 onOpenURL handled by MacOAuthBridge")
                        return
                    }
                    plog("⚠️ Unhandled openURL: \(url.absoluteString)")
                }
                #endif
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
                        Task { await updateChecker.checkForUpdate() }
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
                .onReceive(NotificationCenter.default.publisher(for: .primuseSourceAuthFailed)) { note in
                    guard let id = note.userInfo?["sourceID"] as? String,
                          let src = sourcesStore.source(id: id) else { return }
                    authAlertMessage = note.userInfo?["message"] as? String ?? ""
                    authAlertSource = src
                }
                .alert(
                    String(localized: "source_auth_failed_title"),
                    isPresented: Binding(
                        get: { authAlertSource != nil },
                        set: { if !$0 { authAlertSource = nil } }
                    ),
                    presenting: authAlertSource
                ) { source in
                    Button(String(localized: "source_auth_failed_re_enter")) {
                        reauthSource = source
                        authAlertSource = nil
                    }
                    Button(String(localized: "later"), role: .cancel) {
                        authAlertSource = nil
                    }
                } message: { source in
                    let detail = authAlertMessage.isEmpty
                        ? String(localized: "source_auth_failed_message_generic")
                        : authAlertMessage
                    Text("\(source.name) — \(detail)")
                }
                .sheet(item: $reauthSource) { source in
                    AddSourceView(sourceType: source.type, editingSource: source) { updated in
                        sourcesStore.update(updated.id) { $0 = updated }
                        scanService.removeSynologyAPI(for: updated.id)
                        Task { await sourceManager.refreshConnector(for: updated.id) }
                        SourceAuthAlert.clear(sourceID: updated.id)
                    }
                }
        }
        #if os(macOS)
        // 1.6 重设计: 隐藏系统 title bar, 内容延伸到顶部, 自定义 PMTitleBar
        // 负责窗口控制点 / 导航 / 搜索 / 工具按钮。
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {}
            // 自定义设置窗口 (独立 NSWindow, 见 SettingsWindowController) 取代
            // SwiftUI `Settings {}` scene —— 后者强制原生标题栏盖住自绘标题栏。
            CommandGroup(replacing: .appSettings) {
                Button("settings_menu_item") {
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
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

            // Playback menu —— Apple Music / Spotify 一致的桌面播放范式。
            // 所有指令都通过 AppServices.shared 派发, 不需要 binding,
            // .commands 是 Scene-level 拿不到 @Environment。
            CommandMenu("playback_menu") {
                Button("play_pause") {
                    AppServices.shared.playerService.togglePlayPause()
                }
                .keyboardShortcut("p", modifiers: [.command])

                Button("next_song") {
                    Task { await AppServices.shared.playerService.next() }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("previous_song") {
                    Task { await AppServices.shared.playerService.previous() }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Divider()

                Button("shuffle") {
                    AppServices.shared.playerService.shuffleEnabled.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("repeat") {
                    let p = AppServices.shared.playerService
                    switch p.repeatMode {
                    case .off: p.repeatMode = .all
                    case .all: p.repeatMode = .one
                    case .one: p.repeatMode = .off
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("volume_up") {
                    let engine = AppServices.shared.playerService.audioEngine
                    engine.volume = min(1.0, engine.volume + 0.05)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command])

                Button("volume_down") {
                    let engine = AppServices.shared.playerService.audioEngine
                    engine.volume = max(0.0, engine.volume - 0.05)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            }
        }
        #endif

    }
}
