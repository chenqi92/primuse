#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// Owns the menu bar status item and its popover. Survives for the lifetime
/// of the app — the popover view is rebuilt on demand so SwiftUI sees fresh
/// observable state every time the user opens it.
@MainActor
final class MacMenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    /// Toggle whether the status item shows the current song title next to
    /// the icon. Stored in UserDefaults so it survives launches; users who
    /// prefer a clean menu bar can turn it off.
    @AppStorage("menuBarShowTitle") private var showTitle: Bool = true
    /// Max characters of song title shown in the status bar — Apple's
    /// system bar caps text width and squeezes other items if too long.
    private let titleLimit = 28
    /// 菜单栏歌词比歌名长，给宽一点，但仍然不能把其他菜单栏图标挤走。
    private let lyricLimit = 40

    /// 设置里的「菜单栏歌词」开关。默认关：菜单栏宽度随歌词逐行变化，
    /// 不是每个人都想要。
    static let lyricsEnabledKey = "menuBarLyricsEnabled"
    private var lyricsEnabled = UserDefaults.standard.bool(forKey: MacMenuBarController.lyricsEnabledKey)
    /// 只保留带时间戳的行：纯文本歌词没有可跟的播放位置。
    private var lyrics: [LyricLine] = []
    private var lyricsSongID: String?
    private var lyricsTask: Task<Void, Never>?
    private var activeLyricIndex: Int?
    private var isTrackingLyricTime = false
    private var notificationTokens: [NSObjectProtocol] = []

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = statusBarImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 320, height: 360)
        pop.delegate = self
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPlayerView(onOpenMainWindow: { [weak self] in
                self?.activateMainWindow()
                self?.popover?.performClose(nil)
            })
            .applyPrimuseEnvironments()
        )
        self.popover = pop

        observePlayerState()
        observeLyricsNotifications()
        refreshStatusItem()
    }

    /// Re-arms whenever any of the tracked observable values changes.
    /// Each fire re-evaluates the status item text + icon, then re-registers
    /// the tracking closure so we keep listening.
    private func observePlayerState() {
        let player = AppServices.shared.playerService
        let library = AppServices.shared.musicLibrary
        withObservationTracking {
            _ = player.currentSong?.id
            _ = player.currentSong?.title
            _ = player.currentSong?.artistName
            _ = player.currentSong?.sourceArtistNames
            _ = library.artistNameConfiguration
            _ = player.currentSong?.coverArtFileName
            _ = player.coverRevision
            _ = player.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshStatusItem()
                self?.observePlayerState()
            }
        }
    }

    private func observeLyricsNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let enabled = UserDefaults.standard.bool(forKey: Self.lyricsEnabledKey)
                guard enabled != self.lyricsEnabled else { return }
                self.lyricsEnabled = enabled
                self.resetLyrics()
                self.reloadLyricsIfNeeded(for: AppServices.shared.playerService.currentSong)
                self.refreshStatusTitle()
            }
        })
        // 用户在编辑器里改了歌词或手动刮削后，菜单栏跟着换成新歌词。
        notificationTokens.append(center.addObserver(
            forName: .primuseLyricsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let songID = note.object as? String
            MainActor.assumeIsolated {
                guard let self,
                      songID == AppServices.shared.playerService.currentSong?.id else { return }
                self.resetLyrics()
                self.reloadLyricsIfNeeded(for: AppServices.shared.playerService.currentSong)
                self.refreshStatusTitle()
            }
        })
    }

    /// 没有封面时使用 template image, 交给系统按菜单栏状态自动着色。
    private func statusBarImage() -> NSImage {
        let image = (NSImage(named: "BrandGlyph")?.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 17, height: 17)
        image.isTemplate = true
        return image
    }

    private func statusBarArtworkImage(for song: Song?) -> NSImage? {
        guard let song else { return nil }
        let store = MetadataAssetStore.shared
        let candidates = [
            store.expectedCoverFileName(for: song.id),
            song.coverArtFileName,
        ].compactMap { $0 }

        for name in candidates where !name.isEmpty && !name.contains("/") && !name.contains("://") {
            guard let data = store.readCoverData(named: name),
                  let image = NSImage(data: data) else { continue }
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            return image
        }
        return nil
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let player = AppServices.shared.playerService

        button.image = statusBarArtworkImage(for: player.currentSong) ?? statusBarImage()
        button.imagePosition = .imageLeading

        reloadLyricsIfNeeded(for: player.currentSong)
        refreshStatusTitle()
    }

    /// 歌词换行只走这里，不重读封面。
    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        let player = AppServices.shared.playerService
        let library = AppServices.shared.musicLibrary
        let songToolTip = [
            player.currentSong?.title,
            player.currentSong.flatMap { library.artistDisplayName(for: $0) },
        ].compactMap { $0 }.joined(separator: " — ")

        if let line = currentLyricText() {
            // 歌词前也留一个空格，理由同下。
            button.title = " " + truncate(line, max: lyricLimit)
            button.toolTip = songToolTip
        } else if showTitle, let title = player.currentSong?.title, !title.isEmpty {
            // Title 旁边一个空格,避免和图标贴在一起。
            button.title = " " + truncate(title, max: titleLimit)
            button.toolTip = songToolTip
        } else {
            button.title = ""
            button.toolTip = "Primuse"
        }
    }

    // MARK: - Menu bar lyrics

    private func resetLyrics() {
        lyricsTask?.cancel()
        lyricsTask = nil
        lyrics = []
        lyricsSongID = nil
        activeLyricIndex = nil
    }

    private func reloadLyricsIfNeeded(for song: Song?) {
        let player = AppServices.shared.playerService
        guard lyricsEnabled, let song, !player.isLiveRadio else {
            if lyricsSongID != nil || lyricsTask != nil { resetLyrics() }
            return
        }
        guard lyricsSongID != song.id else { return }
        resetLyrics()
        lyricsSongID = song.id
        let services = AppServices.shared
        lyricsTask = Task { @MainActor [weak self] in
            let loaded = await LyricsLoader.load(
                for: song,
                sourceManager: services.sourceManager,
                sourceType: services.sourcesStore.source(id: song.sourceID)?.type
            )
            guard !Task.isCancelled,
                  let self,
                  self.lyricsSongID == song.id else { return }
            self.lyricsTask = nil
            self.lyrics = loaded.filter { $0.isSynchronized }
            self.updateLyricLine()
            self.observeLyricTime()
        }
    }

    /// 只在开着菜单栏歌词、并且真有同步歌词时才跟播放进度；
    /// 每次进度变化只算当前行，行没变就不碰菜单栏。
    private func observeLyricTime() {
        guard !isTrackingLyricTime, lyricsEnabled, !lyrics.isEmpty else { return }
        isTrackingLyricTime = true
        let player = AppServices.shared.playerService
        withObservationTracking {
            _ = player.currentTime
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTrackingLyricTime = false
                self.updateLyricLine()
                self.observeLyricTime()
            }
        }
    }

    private func updateLyricLine() {
        let player = AppServices.shared.playerService
        guard lyricsEnabled,
              !lyrics.isEmpty,
              lyricsSongID == player.currentSong?.id else { return }
        let index = LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: player.currentTime
        )
        guard index != activeLyricIndex else { return }
        activeLyricIndex = index
        refreshStatusTitle()
    }

    /// 当前该显示的歌词行；前奏、间奏的空行和没有歌词时返回 nil，回落到歌名。
    private func currentLyricText() -> String? {
        guard lyricsEnabled,
              let index = activeLyricIndex,
              lyrics.indices.contains(index),
              lyricsSongID == AppServices.shared.playerService.currentSong?.id else { return nil }
        let text = lyrics[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let idx = s.index(s.startIndex, offsetBy: max - 1)
        return String(s[..<idx]) + "…"
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = existingMainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 主窗口已被用户关掉(红灯), SwiftUI 把 WindowGroup 实例销毁了,
        // NSApp.windows 找不到任何可 makeKey 的内容窗口。走 SwiftUI 的
        // openWindow(id:) 让 WindowGroup 重新建一份;桥接的 action 在
        // MacContentView.task 里已经注册过。
        MainWindowOpener.openMainWindow()
    }

    /// 这些 autosaveName 对应的窗口都是 canBecomeMain 的普通 titled
    /// NSWindow(设置 / 刮削)或附属面板(mini player / 桌面歌词),
    /// 不是 SwiftUI 主窗口,必须在主窗口探测里排除掉,否则用户红灯关掉
    /// 主窗口、但设置/刮削窗还开着时,"Open Main Window" 会误命中它们而
    /// 不去重建主窗口。
    private static let nonMainAutosaveNames: Set<String> = [
        "PrimuseMiniPlayer",
        "PrimuseDesktopLyrics_v2",
        "PrimuseSettings",
        "PrimuseScrapeOptions",
    ]

    /// 找到当前 SwiftUI 主窗口。排除 mini player / 桌面歌词 / Settings /
    /// 刮削 / 各种 NSPanel 副窗口。这些副窗口也是 canBecomeMain 的 NSWindow,
    /// 必须用 autosaveName 联合过滤,不能只看 canBecomeMain。
    private func existingMainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            guard window.canBecomeMain,
                  !(window is NSPanel),
                  !window.styleMask.contains(.utilityWindow) else { return false }
            // Settings 场景(已弃用的 SwiftUI Settings scene)identifier
            // 形如 "com_apple_SwiftUI_Settings_window"。
            if let id = window.identifier?.rawValue, id.contains("Settings") {
                return false
            }
            if Self.nonMainAutosaveNames.contains(window.frameAutosaveName) {
                return false
            }
            return true
        }
    }
}

/// Helper to mirror the same environment objects PrimuseApp injects into
/// the main scene, so the popover view sees the same services.
extension View {
    func applyPrimuseEnvironments() -> some View {
        PMScrollViewStyle.shared.install()
        let services = AppServices.shared
        // No global tint here: same reasoning as PrimuseApp.injectServices
        // — macOS ships native control colors, the brand purple only
        // belongs on hand-styled brand surfaces.
        return self
            .environment(services.themeService)
            .environment(services.playerService)
            .environment(services.playerService.audioEngine)
            .environment(services.playerService.equalizerService)
            .environment(services.playerService.audioEffectsService)
            .environment(services.musicLibrary)
            .environment(services.sourcesStore)
            .environment(services.radioStationsStore)
            .environment(services.sourceManager)
            .environment(services.scraperSettingsStore)
            .environment(services.scraperService)
            .environment(services.playbackSettingsStore)
            .environment(services.scanService)
            .environment(services.cloudSync)
            .environment(services.metadataBackfill)
            // 下面这些是 MacSettingsView 各 tab 需要的, 菜单栏 popover 用不到也无害。
            .environment(services.updateChecker)
            .environment(services.coverTintProvider)
            .environment(services.appleMusic)
            .environment(services.appleMusicLibrary)
            .environment(services.dlnaRenderer)
            .environment(services.visualizer)
            .environment(services.duplicateCleanup)
            .environment(services.batchRemoval)
            .environment(services.musicIntelligence)
    }
}
#endif
