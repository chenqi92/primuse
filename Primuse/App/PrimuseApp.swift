import CloudKit
import SwiftUI
import PrimuseKit

/// `primuse://pair` 扫码端点的 Identifiable 包装,供 `.sheet(item:)` 驱动「直传到 Apple TV」。
struct PairTarget: Identifiable {
    let id = UUID()
    let link: LANPairLink
}

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

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            await AppIconService.shared.restorePrimaryIconIfNeeded()
        }
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

    // Routes Siri voice intents (INPlayMediaIntent etc.) directly into the app.
    // iOS 14+ can launch a media app in the background for this path, so a
    // separate Intents Extension isn't required.
    static let playMediaHandler = PlayMediaIntentHandler()

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent || intent is INSearchForMediaIntent {
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
                services.scraperService.cancelPreservingCheckpoint()
                services.metadataBackfill.stop()
            }
        }

        Task { @MainActor in
            let services = AppServices.shared
            let scanService = services.scanService
            let backfill = services.metadataBackfill
            let scraper = services.scraperService

            // Background audio is user-facing foreground work. Keep directory
            // scans, scraping and indexing postponed, but let metadata tags
            // advance through a single throttled Range request at a time.
            if services.playerService.isPlaybackActive {
                backfill.setExecutionMode(.backgroundDuringPlayback)
                if backfill.hasPendingWork {
                    backfill.start()
                    await backfill.waitUntilIdle()
                }
                scanService.scheduleBackgroundResumeIfNeeded(
                    backfillPending: backfill.hasPendingWork,
                    scrapePending: scraper.hasPendingBackgroundContinuation,
                    localImportPending: LocalImportService.hasPendingScan,
                    sourceStore: services.sourcesStore
                )
                completion.complete(success: true)
                return
            }

            backfill.setExecutionMode(.background)

            // Resume any interrupted scans, then run one bounded backfill
            // snapshot. If work remains, the scheduling call below requests
            // another BGProcessing wake instead of keeping this task busy.
            services.musicLibrary.resumePendingIdentityResolution()
            services.resumePendingLocalImportScanIfNeeded()
            if scanService.hasResumableScanWork {
                scanService.resumePendingScans(
                    context: .background,
                    sourceManager: services.sourceManager,
                    library: services.musicLibrary,
                    sourceStore: services.sourcesStore,
                    scraperService: services.scraperService
                )
            }
            scanService.startPeriodicQuickSyncIfNeeded(
                sourceManager: services.sourceManager,
                library: services.musicLibrary,
                sourceStore: services.sourcesStore,
                scraperService: services.scraperService
            )
            await scanService.waitForActiveScansToComplete()

            if scraper.hasPendingBackgroundContinuation {
                scraper.resumePendingScrape(
                    in: services.musicLibrary,
                    allowBackgroundExecution: true
                )
                await scraper.waitUntilScrapeIdle()
            }

            if backfill.hasPendingWork {
                backfill.start()
                await backfill.waitUntilIdle()
            }

            // If anything still has a checkpoint or pending bare songs,
            // automatically renew the BGProcessing request for a later wake.
            scanService.scheduleBackgroundResumeIfNeeded(
                backfillPending: backfill.hasPendingWork,
                scrapePending: scraper.hasPendingBackgroundContinuation,
                localImportPending: LocalImportService.hasPendingScan,
                sourceStore: services.sourcesStore
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
import Observation

private final class MacKeyboardEventBox: @unchecked Sendable {
    let event: NSEvent

    init(_ event: NSEvent) {
        self.event = event
    }
}

@MainActor
@Observable
final class MacKeyboardShortcutStore {
    static let shared = MacKeyboardShortcutStore()

    var shortcuts: [MacKeyboardShortcutAction: MacKeyboardShortcut]
    var recordingAction: MacKeyboardShortcutAction?

    private init() {
        shortcuts = MacKeyboardShortcutPolicy.decode(
            UserDefaults.standard.data(forKey: MacKeyboardShortcutPolicy.storageKey)
        )
    }

    func shortcut(for action: MacKeyboardShortcutAction) -> MacKeyboardShortcut? {
        shortcuts[action]
    }

    func conflictingAction(
        for shortcut: MacKeyboardShortcut,
        excluding action: MacKeyboardShortcutAction
    ) -> MacKeyboardShortcutAction? {
        MacKeyboardShortcutPolicy.conflictingAction(
            for: shortcut,
            excluding: action,
            in: shortcuts
        )
    }

    func assign(_ shortcut: MacKeyboardShortcut, to action: MacKeyboardShortcutAction) {
        shortcuts = MacKeyboardShortcutPolicy.assigning(shortcut, to: action, in: shortcuts)
        persist()
    }

    func remove(_ action: MacKeyboardShortcutAction) {
        shortcuts.removeValue(forKey: action)
        persist()
    }

    func restoreDefaults() {
        shortcuts = MacKeyboardShortcutPolicy.defaults
        recordingAction = nil
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(
            MacKeyboardShortcutPolicy.encode(shortcuts),
            forKey: MacKeyboardShortcutPolicy.storageKey
        )
    }
}

extension MacKeyboardShortcutAction {
    var localizedTitle: String {
        switch self {
        case .playPause: return String(localized: "play_pause")
        case .nextTrack: return String(localized: "next_song")
        case .previousTrack: return String(localized: "previous_song")
        case .shuffle: return String(localized: "shuffle")
        case .repeatMode: return String(localized: "repeat")
        case .volumeUp: return String(localized: "volume_up")
        case .volumeDown: return String(localized: "volume_down")
        case .focusSearch: return String(localized: "search_title")
        case .showMiniPlayer: return String(localized: "mini_player")
        case .showDesktopLyrics: return String(localized: "show_desktop_lyrics")
        case .toggleDesktopLyricsLock: return String(localized: "toggle_desktop_lyrics_lock")
        }
    }
}

extension MacKeyboardShortcut {
    @MainActor
    static func appKitShortcut(from event: NSEvent) -> MacKeyboardShortcut {
        var modifiers = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers |= commandModifier }
        if flags.contains(.option) { modifiers |= optionModifier }
        if flags.contains(.control) { modifiers |= controlModifier }
        if flags.contains(.shift) { modifiers |= shiftModifier }
        return MacKeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            keyEquivalent: event.charactersIgnoringModifiers
        )
    }

    var displayString: String {
        var result = ""
        if modifiers & Self.controlModifier != 0 { result += "⌃" }
        if modifiers & Self.optionModifier != 0 { result += "⌥" }
        if modifiers & Self.shiftModifier != 0 { result += "⇧" }
        if modifiers & Self.commandModifier != 0 { result += "⌘" }
        return result + Self.semanticKeyName(keyEquivalent, fallbackKeyCode: keyCode)
    }

    private static func semanticKeyName(_ key: String?, fallbackKeyCode: UInt16) -> String {
        let names: [String: String] = [
            " ": "Space", "\t": "⇥", "\r": "↩", "\u{7F}": "⌫",
            "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
            "\u{F704}": "F1", "\u{F705}": "F2", "\u{F706}": "F3", "\u{F707}": "F4",
            "\u{F708}": "F5", "\u{F709}": "F6", "\u{F70A}": "F7", "\u{F70B}": "F8",
            "\u{F70C}": "F9", "\u{F70D}": "F10", "\u{F70E}": "F11", "\u{F70F}": "F12",
            "\u{F710}": "F13", "\u{F711}": "F14", "\u{F712}": "F15", "\u{F713}": "F16",
            "\u{F714}": "F17", "\u{F715}": "F18", "\u{F716}": "F19", "\u{F717}": "F20",
        ]
        if let key, let name = names[key] { return name }
        if let key, key.count == 1 { return key.uppercased() }
        return keyName(for: fallbackKeyCode)
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let names: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 52: "⌤", 53: "⎋", 65: ".", 67: "*", 69: "+",
            71: "Clear", 75: "/", 76: "⌅", 78: "−", 81: "=", 82: "0", 83: "1",
            84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8",
            92: "9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14",
            109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "↖",
            116: "⇞", 117: "⌦", 118: "F4", 119: "↘", 120: "F2", 121: "⇟",
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
            64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        return names[keyCode] ?? "Key \(keyCode)"
    }
}

extension Notification.Name {
    /// 进入全屏播放器时由 PrimuseAppDelegate 发出,MacContentView 收到后
    /// 自动展开 NowPlaying 视图,让全屏内容直接是播放器而不是歌单。
    static let primuseRequestExpandNowPlaying = Notification.Name("primuse.expandNowPlaying")
}

enum PrimuseNowPlayingExpansion {
    static let animatedKey = "animated"
}

private enum MacScreenshotWindowPreset {
    private static let argumentPrefix = "--primuse-screenshot-window="
    private static let fullScreenArgument = "--primuse-screenshot-fullscreen"
    @MainActor private static var didRequestFullScreen = false

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

    private static var requestsFullScreen: Bool {
        ProcessInfo.processInfo.arguments.contains(fullScreenArgument)
    }

    @MainActor
    static func applyIfRequested() {
        guard requestedSize != nil || requestsFullScreen else { return }
        Task { @MainActor in
            for attempt in 0..<80 {
                if let window = mainWindowCandidate() {
                    if requestsFullScreen {
                        if !didRequestFullScreen, attempt >= 10 {
                            if let size = requestedSize { apply(size: size, to: window) }
                            didRequestFullScreen = true
                            if !window.styleMask.contains(.fullScreen) {
                                window.collectionBehavior.insert(.fullScreenPrimary)
                                window.toggleFullScreen(nil)
                            }
                        }
                    } else if let size = requestedSize {
                        apply(size: size, to: window)
                    }
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
        window.frameAutosaveName != "PrimuseDesktopLyrics_v2" &&
        window.frameAutosaveName != "PrimuseSettings" &&
        window.frameAutosaveName != "PrimuseScrapeOptions"
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
    @MainActor private var keyboardShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        Task { @MainActor in
            Self.shared = self

            // 重放持久化的明暗模式 + Dock 图标 (didSet 在 init 期不触发)。
            MacUIPreferences.shared.applyOnLaunch()

            let bar = MacMenuBarController()
            bar.install()
            self.menuBar = bar

            self.installKeyboardShortcutMonitor()

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
        let isFullScreen = window.styleMask.contains(.fullScreen)
        plog("🖥 FullScreen toggle window=\(window.title) isFull=\(isFullScreen) cb=\(window.collectionBehavior.rawValue)")

        // 先用无动画事务把 Now Playing 安装到窗口中，下一轮主事件循环再交给
        // AppKit 做原生全屏过渡。避免页面展开动画与窗口缩放同时抢主线程。
        NotificationCenter.default.post(
            name: .primuseRequestExpandNowPlaying,
            object: nil,
            userInfo: [PrimuseNowPlayingExpansion.animatedKey: false]
        )
        guard !isFullScreen else { return }
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    @MainActor
    private func installKeyboardShortcutMonitor() {
        guard keyboardShortcutMonitor == nil else { return }
        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local AppKit event monitors run synchronously on the main event
            // loop, but the SDK callback itself is not annotated @MainActor.
            let input = MacKeyboardEventBox(event)
            let output: MacKeyboardEventBox? = MainActor.assumeIsolated {
                let event = input.event
                let window = event.window ?? NSApp.keyWindow
                let shortcutStore = MacKeyboardShortcutStore.shared
                guard MacKeyboardShortcutPolicy.shouldHandleEvent(
                    isEditingText: Self.isEditingText(in: window),
                    isEligibleWindow: Self.acceptsKeyboardShortcut(in: window),
                    isRecordingShortcut: shortcutStore.recordingAction != nil
                ) else { return input }
                let shortcut = MacKeyboardShortcut.appKitShortcut(from: event)
                guard let action = MacKeyboardShortcutPolicy.action(
                    matching: shortcut,
                    in: shortcutStore.shortcuts
                ) else { return input }

                if MacKeyboardShortcutPolicy.shouldPerform(
                    action: action,
                    isRepeat: event.isARepeat
                ) {
                    self.performKeyboardShortcut(action)
                }
                return nil
            }
            return output?.event
        }
    }

    @MainActor
    private func performKeyboardShortcut(_ action: MacKeyboardShortcutAction) {
        let services = AppServices.shared
        switch action {
        case .playPause:
            services.playerService.togglePlayPause()
        case .nextTrack:
            Task { await services.playerService.next() }
        case .previousTrack:
            Task { await services.playerService.previous() }
        case .shuffle:
            services.playerService.shuffleEnabled.toggle()
        case .repeatMode:
            switch services.playerService.repeatMode {
            case .off: services.playerService.repeatMode = .all
            case .all: services.playerService.repeatMode = .one
            case .one: services.playerService.repeatMode = .off
            }
        case .volumeUp:
            services.playerService.audioEngine.volume = min(
                1,
                services.playerService.audioEngine.volume + 0.05
            )
        case .volumeDown:
            services.playerService.audioEngine.volume = max(
                0,
                services.playerService.audioEngine.volume - 0.05
            )
        case .focusSearch:
            focusSearchFromShortcut()
        case .showMiniPlayer:
            toggleMiniPlayer()
        case .showDesktopLyrics:
            toggleDesktopLyrics()
        case .toggleDesktopLyricsLock:
            let key = "desktopLyricsLocked"
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        }
    }

    @MainActor
    private func focusSearchFromShortcut() {
        if let window = mainAppWindow() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .primuseFocusSearch, object: nil)
            return
        }
        MainWindowOpener.openMainWindow()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            NotificationCenter.default.post(name: .primuseFocusSearch, object: nil)
        }
    }

    @MainActor
    private static func isEditingText(in window: NSWindow?) -> Bool {
        if let textView = window?.firstResponder as? NSTextView {
            return textView.isEditable
        }
        if let textField = window?.firstResponder as? NSTextField {
            return textField.isEditable
        }
        return false
    }

    @MainActor
    private static func acceptsKeyboardShortcut(in window: NSWindow?) -> Bool {
        guard let window,
              window.sheetParent == nil,
              window.attachedSheet == nil else {
            return false
        }
        if isMainAppWindow(window) { return true }
        return window.frameAutosaveName == "PrimuseMiniPlayer"
            || window.frameAutosaveName == "PrimuseDesktopLyrics_v2"
    }

    /// 在所有 NSApp.windows 里挑出 SwiftUI 主窗口(不是 mini player /
    /// desktop lyrics / popover / panel 等附属窗口)。靠两个特征:
    /// 是 NSWindow 而非 NSPanel,并且 canBecomeMain。
    @MainActor
    private func mainAppWindow() -> NSWindow? {
        // 优先 mainWindow / keyWindow,但同样要排除 mini player / 桌面歌词 /
        // Settings / 刮削等副窗口——它们也是 canBecomeMain 的 NSWindow,用户
        // 红灯关掉主窗口而副窗口仍聚焦时,快路径会误命中。与
        // MacMenuBarController.existingMainWindow() 保持一致的过滤集。
        if let main = NSApp.mainWindow, Self.isMainAppWindow(main) {
            return main
        }
        if let key = NSApp.keyWindow, Self.isMainAppWindow(key) {
            return key
        }
        // fallback: 遍历所有窗口找第一个不是 panel 的可主窗口。
        return NSApp.windows.first(where: Self.isMainAppWindow)
    }

    /// 判断某个 NSWindow 是不是 SwiftUI 主窗口(排除 mini player / 桌面歌词 /
    /// Settings / 刮削 / 各种 NSPanel 副窗口)。这些副窗口同样 canBecomeMain,
    /// 必须联合 autosaveName 过滤,不能只看 canBecomeMain。
    @MainActor
    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) &&
        window.canBecomeMain &&
        !window.styleMask.contains(.utilityWindow) &&
        window.frameAutosaveName != "PrimuseMiniPlayer" &&
        window.frameAutosaveName != "PrimuseDesktopLyrics_v2" &&
        window.frameAutosaveName != "PrimuseSettings" &&
        window.frameAutosaveName != "PrimuseScrapeOptions"
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

/// Serializes best-effort disk cleanup and remembers the last fully completed
/// pass. A seven-day stale-file policy does not need to rescan every cache tree
/// on every launch or background transition.
private actor ScheduledFileMaintenance {
    static let shared = ScheduledFileMaintenance()

    private static let lastCompletedKey = "primuse.fileMaintenance.lastCompleted.v1"
    private static let minimumInterval: TimeInterval = 24 * 60 * 60
    private var isRunning = false

    nonisolated static func isDue(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Bool {
        AutomaticMaintenanceCadencePolicy.isDue(
            lastCompletedAt: defaults.object(forKey: lastCompletedKey) as? Date,
            now: now,
            minimumInterval: minimumInterval
        )
    }

    func runIfDue() async {
        guard !isRunning, Self.isDue() else { return }
        isRunning = true
        defer { isRunning = false }

        plog("ScheduledFileMaintenance: starting scheduled file cleanup")
        guard SourceManager.pruneStalePartialFiles() else { return }
        guard !Task.isCancelled else { return }
        guard await MetadataAssetStore.shared.performScheduledContentMaintenance() else {
            return
        }
        guard !Task.isCancelled else { return }
        UserDefaults.standard.set(Date(), forKey: Self.lastCompletedKey)
        plog("ScheduledFileMaintenance: completed scheduled file cleanup")
    }
}

/// Coordinates automatic full-library uploads with scene activity. iOS runs
/// them only after the UI has entered background; macOS keeps its settled
/// foreground behavior because a window losing focus does not suspend the app.
@MainActor
private final class LifecycleSnapshotUploadCoordinator {
    static let shared = LifecycleSnapshotUploadCoordinator()

    private var scheduledTask: Task<Void, Never>?

    func sceneDidBecomeActive(syncEnabled: Bool, library: MusicLibrary) {
        scheduledTask?.cancel()
        guard syncEnabled,
              library.hasPendingPortableSnapshotChanges
                || LibrarySnapshotSync.shared.shouldAttemptAutomaticUpload() else {
            return
        }

        scheduledTask = Task(priority: .utility) {
            do {
                // Let startup, scene restoration, and the first home snapshot
                // settle. Cancellation on the next inactive phase is immediate.
                try await Task.sleep(for: .seconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if library.hasPendingPortableSnapshotChanges,
               case .failure = await library.persistNowAndWait() {
                return
            }
            _ = await LibrarySnapshotSync.shared.uploadAutomaticallyIfNeeded()
        }
    }

    func sceneDidEnterBackground(syncEnabled: Bool, library: MusicLibrary) {
        scheduledTask?.cancel()
        guard syncEnabled,
              library.hasPendingPortableSnapshotChanges
                || LibrarySnapshotSync.shared.shouldAttemptAutomaticUpload() else {
            return
        }
        scheduledTask = Task(priority: .utility) {
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if library.hasPendingPortableSnapshotChanges,
               case .failure = await library.persistNowAndWait() {
                return
            }
            _ = await LibrarySnapshotSync.shared.uploadAutomaticallyIfNeeded()
        }
    }

    func cancelScheduledUpload() {
        scheduledTask?.cancel()
        scheduledTask = nil
        Task {
            await LibrarySnapshotSync.shared.cancelUpload()
        }
    }
}

#if os(iOS)
/// Owns cancellable maintenance that is useful but not required for the
/// current foreground interaction. Returning to the app cancels the tasks;
/// the next background/BGProcessing window retries from durable state.
@MainActor
private final class BackgroundLibraryMaintenanceCoordinator {
    static let shared = BackgroundLibraryMaintenanceCoordinator()

    private var searchIndexTask: Task<Void, Never>?
    private var cacheCleanupTask: Task<Void, Never>?

    func sceneDidEnterBackground(library: MusicLibrary) {
        cancel()
        if LibrarySearchIndex.hasPendingPreparation {
            searchIndexTask = Task(priority: .utility) { @MainActor [weak library] in
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard !Task.isCancelled, let library else { return }
                await library.prepareSearchIndexIfNeeded()
            }
        }
        if ScheduledFileMaintenance.isDue() {
            cacheCleanupTask = Task.detached(priority: .background) {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await ScheduledFileMaintenance.shared.runIfDue()
            }
        }
    }

    func cancel() {
        searchIndexTask?.cancel()
        searchIndexTask = nil
        cacheCleanupTask?.cancel()
        cacheCleanupTask = nil
    }
}
#endif

/// Keep network-path Observation out of the scene's root modifier chain.
/// A path update used to invalidate `ContentView` itself, which made SwiftUI
/// revisit every instantiated song row in a large library before running the
/// two side effects below.
@MainActor
private struct NetworkPathChangeObserver: View {
    @Environment(\.scenePhase) private var scenePhase

    let metadataBackfill: MetadataBackfillService
    let sourcesStore: SourcesStore
    let scanService: ScanService

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: NetworkMonitor.shared.pathGeneration) { _, _ in
                metadataBackfill.networkPathChanged(
                    startImmediately: scenePhase == .background
                )
                Task {
                    for source in sourcesStore.sources where source.type == .synology {
                        scanService.removeSynologyAPI(for: source.id)
                    }
                }
            }
    }
}

private struct SourceAuthenticationAlert: Identifiable {
    let source: MusicSource
    let message: String

    var id: String { source.id }
}

private struct SourceAuthenticationPresentationModifier: ViewModifier {
    @Binding var alerts: [String: SourceAuthenticationAlert]
    @Binding var reauthSource: MusicSource?

    let sourcesStore: SourcesStore
    let scanService: ScanService
    let sourceManager: SourceManager

    func body(content: Content) -> some View {
        let activeAlert: Binding<SourceAuthenticationAlert?> = Binding(
            get: {
                guard case .sourceAuthentication(let id) = AppAlertCoordinator.shared.activeRequest else {
                    return nil
                }
                return alerts[id]
            },
            set: { _, _ in }
        )

        content
            .onReceive(NotificationCenter.default.publisher(for: .primuseSourceAuthFailed)) { note in
                guard let id = note.userInfo?["sourceID"] as? String,
                      let source = sourcesStore.source(id: id) else { return }
                alerts[id] = SourceAuthenticationAlert(
                    source: source,
                    message: note.userInfo?["message"] as? String ?? ""
                )
                AppAlertCoordinator.shared.enqueue(.sourceAuthentication(id))
            }
            .alert(item: activeAlert) { prompt in
                let detail = prompt.message.isEmpty
                    ? String(localized: "source_auth_failed_message_generic")
                    : prompt.message
                return Alert(
                    title: Text("source_auth_failed_title"),
                    message: Text("\(prompt.source.name) — \(detail)"),
                    primaryButton: .default(Text("source_auth_failed_re_enter")) {
                        let source = prompt.source
                        alerts[prompt.id] = nil
                        AppAlertCoordinator.shared.finish(
                            .sourceAuthentication(prompt.id),
                            suspendAfterDismiss: true
                        ) {
                            reauthSource = source
                        }
                    },
                    secondaryButton: .cancel(Text("later")) {
                        alerts[prompt.id] = nil
                        AppAlertCoordinator.shared.finish(.sourceAuthentication(prompt.id))
                    }
                )
            }
            .sheet(
                item: $reauthSource,
                onDismiss: { AppAlertCoordinator.shared.resumeAfterModal() }
            ) { source in
                AddSourceView(sourceType: source.type, editingSource: source) { updated in
                    sourcesStore.update(updated.id) { $0 = updated }
                    scanService.removeSynologyAPI(for: updated.id)
                    Task { await sourceManager.refreshConnector(for: updated.id) }
                    SourceAuthAlert.clear(sourceID: updated.id)
                }
            }
    }
}

@main
struct PrimuseApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    #endif
    @State private var sourcesStore: SourcesStore
    @State private var radioStationsStore: RadioStationsStore
    @State private var sourceManager: SourceManager
    @State private var playerService: AudioPlayerService
    @State private var scraperSettingsStore: ScraperSettingsStore
    @State private var scraperService: MusicScraperService
    @State private var musicLibrary: MusicLibrary
    @State private var playbackSettingsStore: PlaybackSettingsStore
    @State private var cloudSync: CloudKitSyncService
    @State private var themeService: ThemeService
    @State private var scanService: ScanService
    @State private var navidromeAutoRefresh: NavidromeAutoRefreshCoordinator
    @State private var metadataBackfill: MetadataBackfillService
    @State private var updateChecker: AppUpdateChecker
    @State private var coverTintProvider: CoverTintProvider
    @State private var appleMusic: AppleMusicService
    @State private var appleMusicLibrary: AppleMusicLibraryService
    @State private var dlnaRenderer: DLNARendererService
    @State private var visualizer: AudioVisualizerService
    @State private var duplicateCleanup: DuplicateCleanupService
    @State private var batchRemoval: SongBatchRemovalService
    @State private var serverListeningStats: ServerListeningStatsService
    @State private var musicIntelligence: MusicIntelligenceService

    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    /// DLNA 接收器持久开关。打开后启动时自动 start, 不需要进 Settings 触发。
    @AppStorage("dlna.rendererEnabled") private var dlnaRendererEnabled: Bool = false
    #if os(iOS)
    @AppStorage(AppThemePreferences.iOSAppearanceKey)
    private var iOSAppearanceRawValue = IOSAppearancePreference.system.rawValue
    #endif
    @Environment(\.scenePhase) private var scenePhase

    /// 后台 connect() 失败时弹的 "登录失败" 提示。点 "重新输入" 后会把 source
    /// 存到 reauthSource 触发 AddSourceView sheet。
    @State private var sourceAuthenticationAlerts: [String: SourceAuthenticationAlert] = [:]
    @State private var reauthSource: MusicSource?
    /// Apple TV 上的二维码扫码后(primuse://add-source)触发的"添加音乐源" sheet。
    @State private var deepLinkAddSource = false
    /// Apple TV 局域网扫码(primuse://pair)解析出的端点,触发「直传到 Apple TV」sheet。
    @State private var pairTarget: PairTarget?

    init() {
        let services = AppServices.shared
        _sourcesStore = State(initialValue: services.sourcesStore)
        _radioStationsStore = State(initialValue: services.radioStationsStore)
        _sourceManager = State(initialValue: services.sourceManager)
        _playerService = State(initialValue: services.playerService)
        _scraperSettingsStore = State(initialValue: services.scraperSettingsStore)
        _scraperService = State(initialValue: services.scraperService)
        _musicLibrary = State(initialValue: services.musicLibrary)
        _playbackSettingsStore = State(initialValue: services.playbackSettingsStore)
        _cloudSync = State(initialValue: services.cloudSync)
        _themeService = State(initialValue: services.themeService)
        _scanService = State(initialValue: services.scanService)
        _navidromeAutoRefresh = State(initialValue: services.navidromeAutoRefresh)
        _metadataBackfill = State(initialValue: services.metadataBackfill)
        _updateChecker = State(initialValue: services.updateChecker)
        _coverTintProvider = State(initialValue: services.coverTintProvider)
        _appleMusic = State(initialValue: services.appleMusic)
        _appleMusicLibrary = State(initialValue: services.appleMusicLibrary)
        _dlnaRenderer = State(initialValue: services.dlnaRenderer)
        _visualizer = State(initialValue: services.visualizer)
        _duplicateCleanup = State(initialValue: services.duplicateCleanup)
        _batchRemoval = State(initialValue: services.batchRemoval)
        _serverListeningStats = State(initialValue: services.serverListeningStats)
        _musicIntelligence = State(initialValue: services.musicIntelligence)
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

    private func injectServices<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        // 自动模式下全局 tint 跟随封面，固定模式下使用用户选择的回退色。
        let injected = content()
            .environment(themeService)
            .environment(playerService)
            .environment(playerService.audioEngine)
            .environment(playerService.equalizerService)
            .environment(playerService.audioEffectsService)
            .environment(musicLibrary)
            .environment(sourcesStore)
            .environment(radioStationsStore)
            .environment(sourceManager)
            .environment(scraperSettingsStore)
            .environment(scraperService)
            .environment(playbackSettingsStore)
            .environment(scanService)
            .environment(navidromeAutoRefresh)
            .environment(cloudSync)
            .environment(metadataBackfill)
            .environment(updateChecker)
            .environment(coverTintProvider)
            .environment(appleMusic)
            .environment(appleMusicLibrary)
            .environment(dlnaRenderer)
            .environment(visualizer)
            .environment(duplicateCleanup)
            .environment(batchRemoval)
            .environment(serverListeningStats)
            .environment(musicIntelligence)
        return injected.tint(themeService.uiAccentColor)
    }

    #if os(iOS)
    private var iOSAppearance: IOSAppearancePreference {
        IOSAppearancePreference(rawValue: iOSAppearanceRawValue) ?? .system
    }
    #endif

    @ViewBuilder
    private var platformRootContent: some View {
        #if os(iOS)
        ContentView()
            .preferredColorScheme(iOSAppearance.colorScheme)
            .modifier(IOSWindowAppearanceModifier(preference: iOSAppearance))
            .automaticAppReviewPrompt()
        #else
        #if DEBUG
        if ProcessInfo.processInfo.environment["PRIMUSE_VISUAL_EVIDENCE"] == "immersiveTypography" {
            MacImmersivePlayerView(
                lyrics: ImmersiveDemoContent.evidenceLyrics,
                onExitFullScreen: {},
                onToggleQueue: {},
                usesDemoEvidenceContent: true,
                debugEffectOverride: .kineticTitle
            )
        } else {
            MacContentView()
                .automaticAppReviewPrompt()
        }
        #else
        MacContentView()
            .automaticAppReviewPrompt()
        #endif
        #endif
    }

    var body: some Scene {
        macAwareMainGroup {
            injectServices {
                platformRootContent
                // Keep one scene-level presenter alive on every platform so
                // background scans and playback never wait for a sheet-local
                // certificate prompt that has already disappeared.
                .transportTrustAlerts()
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
                    // Let SwiftUI commit and accept input before restoring a
                    // potentially 10K+ queue or starting network maintenance.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await AppServices.shared.completeDeferredStartup()
                    navidromeAutoRefresh.setApplicationActive(scenePhase == .active)

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
                    if dlnaRendererEnabled {
                        // keepAlive 开关由 @AppStorage("dlna.keepAlive") 持久;重启后
                        // renderer.keepAliveInBackground 默认是 false,必须在这里回读
                        // 应用,否则后台保活设置重启后静默失效。start() 内部的
                        // syncKeepAliveState 会兜底调度,set 顺序不敏感。
                        dlnaRenderer.setKeepAliveInBackground(
                            UserDefaults.standard.bool(forKey: "dlna.keepAlive")
                        )
                        dlnaRenderer.start()
                    }
                    // macOS can refresh MusicKit while its window is active.
                    // On iOS a full request is reserved for explicit source
                    // sync or the playback cache-miss path, so launch never
                    // invalidates Home a few seconds after interaction starts.
                    #if !os(iOS)
                    if appleMusic.authState == .authorized,
                       AppleMusicFeatureSettings.syncUserLibraryEnabled {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled else { return }
                            appleMusicLibrary.sync()
                        }
                    }
                    #endif
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
                    #if os(iOS)
                    // Submit durable work, but do not execute it merely because
                    // the scene is interactive. Background/BGProcessing owns
                    // scans, scrape checkpoint replay, indexing and backfill.
                    scanService.scheduleBackgroundResumeIfNeeded(
                        backfillPending: metadataBackfill.hasPendingWork,
                        scrapePending: scraperService.hasPendingBackgroundContinuation,
                        localImportPending: LocalImportService.hasPendingScan,
                        sourceStore: sourcesStore
                    )
                    #else
                    // 一次性把已缓存的 .lrc 解析成纯文本写回 Song.lyricsText,
                    // 让 FTS5 全文歌词搜索可用 (v5 migration 加了列但留空)。
                    // 完成后自带 UserDefaults flag, 后续启动直接 noop。
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled else { return }
                        AppServices.shared.lyricsTextBackfill.startIfNeeded()
                    }
                    // Build/update the persistent original+pinyin search index
                    // after launch has settled. The actor processes lyrics in
                    // throttled utility batches and skips unchanged files by
                    // signature, so cold start and interactive searches never
                    // transliterate the whole library.
                    Task(priority: .utility) { @MainActor in
                        try? await Task.sleep(for: .seconds(12))
                        guard !Task.isCancelled else { return }
                        await musicLibrary.prepareSearchIndexIfNeeded()
                    }
                    if ScheduledFileMaintenance.isDue() {
                        Task.detached(priority: .background) {
                            try? await Task.sleep(for: .seconds(10))
                            guard !Task.isCancelled else { return }
                            await ScheduledFileMaintenance.shared.runIfDue()
                        }
                    }
                    #endif
                    // 启动 prewarm —— 只覆盖 currentSong + queue 接下来 5 首。
                    // 之前还会接着 prewarm 整个 library, 一首歌 1MB head +
                    // 256KB tail = 1.25MB, 818 首 ≈ 1GB 后台流量, 用户开
                    // app 听一首歌就发现缓存涨 100MB+。换来的"任意点歌
                    // 首播 < 200ms"对小库或许值得, 对中大型库性价比极差
                    // (绝大多数预热的歌不会被听), 所以砍掉。play(song:)
                    // 路径里的 cacheInBackground 会按需 prewarm 用户实际
                    // 点的歌, 行为退化为「点啥热啥」, 总体盘可控。
                    Task.detached(priority: .background) {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        // 1. currentSong (resume): 优先级最高,提到 .userInitiated
                        //    用户立刻按 play 时大概率就是这首
                        let resumeSong = await MainActor.run { playerService.currentSong }
                        if let song = resumeSong {
                            await Task.detached(priority: .userInitiated) {
                                await sourceManager.prewarmCloudSongPublic(song: song)
                            }.value
                        }

                        // 2. queue 接下来的歌: 已经摆好播放队列时,继续往后跑很可能
                        // 只投影实际需要的几首，避免恢复超大队列后一秒在 main actor
                        // 物化完整 [Song]，与 Watch 队列摘要形成第二个延迟卡顿点。
                        let resumeID = resumeSong?.id
                        let queueOrder = await MainActor.run {
                            let requested = max(
                                0,
                                playerService.playbackSettings.prewarmQueueCount
                            )
                            guard requested > 0 else { return [Song]() }

                            var songs: [Song] = []
                            songs.reserveCapacity(requested)
                            let inspectionLimit = min(
                                playerService.queueCount,
                                max(16, requested * 4)
                            )
                            for index in 0..<inspectionLimit {
                                guard songs.count < requested else { break }
                                guard let song = playerService.queuedSong(at: index),
                                      song.id != resumeID else { continue }
                                songs.append(song)
                            }
                            return songs
                        }
                        for song in queueOrder {
                            if Task.isCancelled { return }
                            let done = await MainActor.run { sourceManager.isPrewarmed(song: song) }
                            if done { continue }
                            await sourceManager.prewarmCloudSongPublic(song: song)
                        }
                    }
                }
                // `.task(id:)` runs once when this scene is mounted as well as
                // on later song changes. A plain `onChange` misses the case
                // where a scene is recreated while the shared player already
                // has a current song, leaving the player on the fallback tint.
                .task(id: playerService.currentSong?.id) {
                    let song = playerService.currentSong
                    themeService.updateFromCoverArt(
                        fileName: song?.coverArtFileName,
                        songID: song?.id,
                        appleMusicID: song?.sourceID == AppleMusicLibraryService.systemSourceID
                            ? song?.filePath
                            : nil
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
                    guard let cachedSongID = note.object as? String,
                          let currentSong = playerService.currentSong,
                          currentSong.id == cachedSongID else { return }
                    playerService.retryNowPlayingArtwork(afterCachingSongID: cachedSongID)
                    themeService.updateFromCoverArt(
                        fileName: currentSong.coverArtFileName,
                        songID: currentSong.id,
                        appleMusicID: currentSong.sourceID == AppleMusicLibraryService.systemSourceID
                            ? currentSong.filePath
                            : nil
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
                          let updated = musicLibrary.song(id: currentID)
                    else { return }
                    playerService.syncSongMetadata(updated)
                    // forceRefreshNowPlayingArtwork 内部已 bump coverRevision,
                    // 这里不需要重复 bump。三处封面 view 监听 revisionToken 会触发
                    // reload, 即便 coverArtFileName 字符串没变 (重复刮 deterministic
                    // hash 文件名时 coverRef 不变, onChange 不会触发)。
                    playerService.forceRefreshNowPlayingArtwork()
                    themeService.updateFromCoverArt(
                        fileName: updated.coverArtFileName,
                        songID: updated.id,
                        appleMusicID: updated.sourceID == AppleMusicLibraryService.systemSourceID
                            ? updated.filePath
                            : nil
                    )
                }
                .onOpenURL { url in
                    plog("🔗 onOpenURL: scheme=\(url.scheme ?? "?") host=\(url.host ?? "?")")
                    // Apple TV 二维码:primuse://add-source → 手机扫码后弹「发送到 Apple TV」
                    // (把已有曲库/源/凭据发过去;也可在其中新建源)。
                    if url.scheme == "primuse", url.host == "add-source" {
                        deepLinkAddSource = true
                        return
                    }
                    // Apple TV 局域网扫码:primuse://pair?host=&port=&k= → 弹「直传到 Apple TV」
                    // (整库 / 源 / 凭据 AES-GCM 加密直接 POST 过去,不经 iCloud)。
                    if let link = LANPairLink(url: url) {
                        pairTarget = PairTarget(link: link)
                        return
                    }
                    #if os(macOS)
                    // macOS OAuth 走系统浏览器,callback 通过 primuse:// 回到 app。
                    if MacOAuthBridge.shared.handle(url) {
                        plog("🔗 onOpenURL handled by MacOAuthBridge")
                        return
                    }
                    plog("⚠️ Unhandled openURL: \(url.absoluteString)")
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    navidromeAutoRefresh.setApplicationActive(newPhase == .active)
                    switch newPhase {
                    case .inactive:
                        #if os(iOS)
                        // Quiesce observable library mutations only for the
                        // active → inactive → background commit. The work is
                        // resumed below after the background scene has settled;
                        // background scraping itself remains enabled.
                        LifecycleSnapshotUploadCoordinator.shared.cancelScheduledUpload()
                        BackgroundLibraryMaintenanceCoordinator.shared.cancel()
                        AppServices.shared.spotlightIndex.suspendSynchronization()
                        AppServices.shared.lyricsTextBackfill.stop()
                        musicLibrary.suspendPendingIdentityResolution()
                        musicLibrary.beginSceneTransitionQuiescence()
                        scraperService.pauseForSceneTransition()
                        scanService.cancelAllActiveScans()
                        metadataBackfill.stop()
                        playerService.handleAppWillResignActive()
                        #else
                        // Window focus changes map to inactive on macOS and are
                        // not an iOS scene-watchdog transition. Keep long-running
                        // work intact there.
                        playerService.handleAppWillResignActive()
                        musicLibrary.persistNow()
                        #endif

                    case .background:
                        #if os(iOS)
                        metadataBackfill.setExecutionMode(
                            playerService.isPlaybackActive
                                ? .backgroundDuringPlayback
                                : .background
                        )
                        scanService.suspendForegroundOnlyScans(sourceStore: sourcesStore)
                        // If a scan was running OR backfill has pending work, ask
                        // iOS to wake us later via BGProcessingTask so we can keep
                        // going past the beginBackgroundTask 30s ceiling. (No-op
                        // on macOS — BGTaskScheduler doesn't exist there.)
                        scanService.scheduleBackgroundResumeIfNeeded(
                            backfillPending: metadataBackfill.hasPendingWork,
                            scrapePending: scraperService.hasPendingBackgroundContinuation,
                            localImportPending: LocalImportService.hasPendingScan,
                            sourceStore: sourcesStore
                        )

                        // Do not start observable/heavy work in the scene-change
                        // callback itself. Once UIKit has had two seconds to
                        // finish the transition, continue scraping in the normal
                        // background execution window. BGProcessingTask takes
                        // over later if iOS expires that finite window.
                        Task { @MainActor in
                            do {
                                try await Task.sleep(for: .seconds(2))
                            } catch {
                                return
                            }
                            guard self.scenePhase == .background else { return }
                            musicLibrary.endSceneTransitionQuiescence()
                            musicLibrary.persistNow()
                            if playerService.isPlaybackActive {
                                metadataBackfill.setExecutionMode(.backgroundDuringPlayback)
                                if metadataBackfill.hasPendingWork {
                                    metadataBackfill.start()
                                }
                                scanService.scheduleBackgroundResumeIfNeeded(
                                    backfillPending: metadataBackfill.hasPendingWork,
                                    scrapePending: scraperService.hasPendingBackgroundContinuation,
                                    localImportPending: LocalImportService.hasPendingScan,
                                    sourceStore: sourcesStore
                                )
                                return
                            }
                            metadataBackfill.setExecutionMode(.background)
                            musicLibrary.resumePendingIdentityResolution()
                            AppServices.shared.spotlightIndex.resumePendingSynchronization(
                                library: musicLibrary
                            )
                            LifecycleSnapshotUploadCoordinator.shared.sceneDidEnterBackground(
                                syncEnabled: iCloudSyncEnabled,
                                library: musicLibrary
                            )
                            AppServices.shared.resumePendingLocalImportScanIfNeeded()
                            if scanService.hasResumableScanWork {
                                scanService.resumePendingScans(
                                    context: .background,
                                    sourceManager: sourceManager,
                                    library: musicLibrary,
                                    sourceStore: sourcesStore,
                                    scraperService: scraperService
                                )
                            }
                            if scraperService.hasPendingBackgroundContinuation {
                                scraperService.resumeBackgroundContinuation(in: musicLibrary)
                            }
                            if metadataBackfill.hasPendingWork {
                                metadataBackfill.start()
                            }
                            AppServices.shared.lyricsTextBackfill.startIfNeeded()
                            BackgroundLibraryMaintenanceCoordinator.shared
                                .sceneDidEnterBackground(library: musicLibrary)
                            scanService.scheduleBackgroundResumeIfNeeded(
                                backfillPending: metadataBackfill.hasPendingWork,
                                scrapePending: scraperService.hasPendingBackgroundContinuation,
                                localImportPending: LocalImportService.hasPendingScan,
                                sourceStore: sourcesStore
                            )
                        }
                        #else
                        if iCloudSyncEnabled {
                            LifecycleSnapshotUploadCoordinator.shared
                                .sceneDidEnterBackground(
                                    syncEnabled: true,
                                    library: musicLibrary
                                )
                        } else {
                            musicLibrary.persistNow()
                        }
                        #endif

                    case .active:
                        #if os(iOS)
                        musicLibrary.endSceneTransitionQuiescence()
                        LifecycleSnapshotUploadCoordinator.shared.cancelScheduledUpload()
                        BackgroundLibraryMaintenanceCoordinator.shared.cancel()
                        AppServices.shared.spotlightIndex.suspendSynchronization()
                        AppServices.shared.lyricsTextBackfill.stop()
                        metadataBackfill.stop()
                        if !metadataBackfill.resumeUserInitiatedIfNeeded() {
                            metadataBackfill.setExecutionMode(.standard)
                        }
                        musicLibrary.suspendPendingIdentityResolution()
                        scanService.scheduleBackgroundResumeIfNeeded(
                            backfillPending: metadataBackfill.hasPendingWork,
                            scrapePending: scraperService.hasPendingBackgroundContinuation,
                            localImportPending: LocalImportService.hasPendingScan,
                            sourceStore: sourcesStore
                        )
                        #else
                        LifecycleSnapshotUploadCoordinator.shared.sceneDidBecomeActive(
                            syncEnabled: iCloudSyncEnabled,
                            library: musicLibrary
                        )
                        AppServices.shared.spotlightIndex.resumePendingSynchronization(
                            library: musicLibrary
                        )
                        #endif
                        playerService.handleAppDidBecomeActive()
                        Task { await updateChecker.checkForUpdate() }
                    @unknown default:
                        break
                    }
                }
                .onChange(of: playerService.isPlaybackActive) { _, isActive in
                    #if os(iOS)
                    guard scenePhase == .background else { return }
                    metadataBackfill.setExecutionMode(
                        isActive ? .backgroundDuringPlayback : .background
                    )
                    if isActive {
                        // A remote-control play command can arrive after the
                        // scene already entered background. Quiesce heavy work
                        // immediately, preserving its durable checkpoints.
                        scanService.cancelAllActiveScans()
                        scraperService.cancelPreservingCheckpoint()
                        AppServices.shared.spotlightIndex.suspendSynchronization()
                        AppServices.shared.lyricsTextBackfill.stop()
                        BackgroundLibraryMaintenanceCoordinator.shared.cancel()
                    }
                    if metadataBackfill.hasPendingWork, !metadataBackfill.isRunning {
                        metadataBackfill.start()
                    }
                    scanService.scheduleBackgroundResumeIfNeeded(
                        backfillPending: metadataBackfill.hasPendingWork,
                        scrapePending: scraperService.hasPendingBackgroundContinuation,
                        localImportPending: LocalImportService.hasPendingScan,
                        sourceStore: sourcesStore
                    )
                    #endif
                }
                // Continue a background scan/backfill pipeline as new bare
                // rows arrive. On iOS, an ordinary foreground publication only
                // marks durable pending work; it must not start maintenance.
                .onChange(of: musicLibrary.songs.count) { _, _ in
                    #if os(iOS)
                    metadataBackfill.refreshQueue(
                        startImmediately: scenePhase == .background
                    )
                    #else
                    metadataBackfill.refreshQueue()
                    #endif
                }
                // Network changes are observed in a separate, zero-size view.
                // Keeping them on this scene root made every path callback
                // invalidate the complete tab/navigation/song-list hierarchy.
                .background {
                    NetworkPathChangeObserver(
                        metadataBackfill: metadataBackfill,
                        sourcesStore: sourcesStore,
                        scanService: scanService
                    )
                }
                .modifier(SourceAuthenticationPresentationModifier(
                    alerts: $sourceAuthenticationAlerts,
                    reauthSource: $reauthSource,
                    sourcesStore: sourcesStore,
                    scanService: scanService,
                    sourceManager: sourceManager
                ))
                .sheet(isPresented: $deepLinkAddSource) {
                    SendToTVSheet()
                        .environment(musicLibrary)
                        .environment(sourcesStore)
                }
                .sheet(item: $pairTarget) { target in
                    SendToTVSheet(lanTarget: target.link)
                        .environment(musicLibrary)
                        .environment(sourcesStore)
                }
            }
        }
        #if os(macOS)
        // 标题栏背景和标题由 PMWindowChromeConfigurator 隐藏。这里保留 SwiftUI
        // 默认窗口样式,避免 `.hiddenTitleBar` 连同原生窗口按钮容器一起隐藏。
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

                // 锁定后桌面歌词上的工具条会消失(因为 panel 设了
                // ignoresMouseEvents 实现"点击穿透"),用户没法再点
                // 解锁。这条命令 + 快捷键让用户在 Primuse 聚焦时也
                // 能直接解锁,不必去找菜单栏的 popover。
                Button("toggle_desktop_lyrics_lock") {
                    let key = "desktopLyricsLocked"
                    let locked = UserDefaults.standard.bool(forKey: key)
                    UserDefaults.standard.set(!locked, forKey: key)
                }
            }

            // Playback menu —— Apple Music / Spotify 一致的桌面播放范式。
            // 所有指令都通过 AppServices.shared 派发, 不需要 binding,
            // .commands 是 Scene-level 拿不到 @Environment。
            CommandMenu("playback_menu") {
                Button("play_pause") {
                    AppServices.shared.playerService.togglePlayPause()
                }

                Button("next_song") {
                    Task { await AppServices.shared.playerService.next() }
                }

                Button("previous_song") {
                    Task { await AppServices.shared.playerService.previous() }
                }

                Divider()

                Button("shuffle") {
                    AppServices.shared.playerService.shuffleEnabled.toggle()
                }

                Button("repeat") {
                    let p = AppServices.shared.playerService
                    switch p.repeatMode {
                    case .off: p.repeatMode = .all
                    case .all: p.repeatMode = .one
                    case .one: p.repeatMode = .off
                    }
                }

                Divider()

                Button("volume_up") {
                    let engine = AppServices.shared.playerService.audioEngine
                    engine.volume = min(1.0, engine.volume + 0.05)
                }

                Button("volume_down") {
                    let engine = AppServices.shared.playerService.audioEngine
                    engine.volume = max(0.0, engine.volume - 0.05)
                }
            }
        }
        #endif

    }
}

#if os(iOS)
/// SwiftUI 的 preferredColorScheme 负责环境值；同步覆盖 UIWindow，确保 UIKit
/// 控件、sheet 和外接显示窗口也在同一帧切换外观。
private struct IOSWindowAppearanceModifier: ViewModifier {
    let preference: IOSAppearancePreference
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear(perform: apply)
            .onChange(of: preference) { _, _ in apply() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { apply() }
            }
    }

    @MainActor
    private func apply() {
        let style: UIUserInterfaceStyle
        switch preference {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
#endif
