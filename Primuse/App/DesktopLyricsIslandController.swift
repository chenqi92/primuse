#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// 岛上临时浮现的一条系统状态 —— 换输出设备、调音量、插拔电源。出现几秒后
/// 自己退回歌词。
struct DesktopLyricsIslandActivity: Equatable {
    enum Kind: Equatable {
        case output
        case volume
        case power
    }

    enum Tint: Equatable {
        case neutral
        case charging
        case warning
    }

    var kind: Kind
    var symbol: String
    /// 小字说明：「声音输出」「正在充电」。
    var caption: String
    /// 主体文字：设备名、电量百分比。音量没有主体文字，改画一条电平。
    var title: String
    /// 有值时画成一条电平（音量）。
    var level: Double?
    /// 右翼 / 胶囊尾部的短读数，例如音量百分比。
    var trailing: String?
    var tint: Tint
}

/// 岛的显示状态，controller 写、view 读。
@MainActor
@Observable
final class DesktopLyricsIslandState {
    var metrics: DesktopLyricsIslandMetrics
    /// 指针停在刘海 / 顶部那条上之后展开成卡片。
    var expanded = false
    /// false 时岛缩回刘海背后（普通屏收回屏幕顶边）。上岛、下岛的动画都靠它。
    var presented = false
    /// 指针压在刘海下面那行歌词上：整块淡下去，好看清、点到后面的东西。
    var peeking = false
    var alwaysOnTop = false
    var activity: DesktopLyricsIslandActivity?
    /// view 按当前内容算出的岛本体目标尺寸（不含两肩），controller 拿它判定指针。
    var islandSize: CGSize = .zero
    /// 当前这首的歌词和正在唱的行。由 view 加载、跟播放时间更新；放在这里而不是
    /// view 的 @State，面板重建时不必等重新加载就有东西可画。
    var lyrics: [LyricLine] = []
    /// `lyrics` 属于哪首歌。
    var lyricsSongID: String?
    var currentIndex: Int = -1

    init(metrics: DesktopLyricsIslandMetrics) {
        self.metrics = metrics
    }
}

/// 岛的窗口贴住屏幕顶边，不让 AppKit 按菜单栏安全区域挪动。
final class DesktopLyricsIslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// 桌面歌词「上岛」之后的那块面板：贴在屏幕顶边正中，刘海屏上从刘海里长出来。
///
/// 面板本身比岛大一圈（要装下展开的卡片和光晕），平时整块穿透；指针停在刘海 /
/// 顶部那条上才展开、开始吃鼠标，移开后收回。判定走的是和浮动桌面歌词同一套
/// 「全局 + 本地鼠标监视器 + 低频保险丝」，理由见 `DesktopLyricsWindowController`。
@MainActor
final class DesktopLyricsIslandController {
    /// 上岛时记下的那块屏幕，下次启动还回到它上面。
    static let displayKey = "desktopLyricsIslandDisplay"
    /// 设置里的「在岛上显示耳机、音量和充电状态」，默认开。
    static let systemStatusKey = "desktopLyricsIslandSystemStatus"
    static let alwaysOnTopKey = "desktopLyricsIslandAlwaysOnTop"

    let state: DesktopLyricsIslandState
    var onToggleDesktop: () -> Void = {}
    var onClose: () -> Void = {}

    private var panel: DesktopLyricsIslandPanel?
    private var screenFrame: CGRect = .zero
    private let systemMonitor = DesktopLyricsIslandSystemMonitor()

    nonisolated(unsafe) private var pointerMonitors: [Any] = []
    nonisolated(unsafe) private var pointerTimer: Timer?
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) private var preferenceObserver: NSObjectProtocol?

    private var expandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    /// 在展开的卡片里按下了左键（拖进度、按按钮）。松手前不收起也不穿透，
    /// 否则拖出卡片边缘时拖动会被截断。
    private var pressBeganInside = false

    #if DEBUG
    /// 取证钩子把岛钉在某个状态上时，指针判定不去动它。
    private var debugPinned = false
    #endif

    /// 形变动画：展开、收起、上岛、下岛共用。减少动态效果时只做短淡入淡出。
    static var morph: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.42, dampingFraction: 0.8)
    }

    init() {
        let screen = Self.resolveScreen()
        state = DesktopLyricsIslandState(
            metrics: screen.map(Self.metrics(for:))
                ?? DesktopLyricsIslandMetrics.resolve(for: DesktopLyricsIslandScreen(
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876)
                ))
        )
        state.alwaysOnTop = UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
    }

    deinit {
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    /// 岛在屏上、并且没在往回收。
    var isShowing: Bool {
        panel?.isVisible == true && dismissTask == nil
    }

    /// - Parameter screen: 优先显示在桌面歌词所在的屏幕顶部。
    func show(preferring screen: NSScreen? = nil) {
        dismissTask?.cancel()
        dismissTask = nil
        if let id = screen?.primuseDisplayID {
            UserDefaults.standard.set(Int(id), forKey: Self.displayKey)
        }
        guard let target = Self.resolveScreen() else { return }
        state.alwaysOnTop = UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        apply(screen: target)
        panel.alphaValue = 1
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        startPointerTracking()
        observeScreenChanges()
        observePreferenceChanges()
        systemMonitor.start { [weak self] activity in
            self?.present(activity)
        }

        // 先按缩在刘海里的样子画出第一帧，再放出来 —— SwiftUI 得有个起点才有动画。
        // 同一轮 runloop 里改状态会赶在第一帧提交之前，起点就丢了，所以隔一小段。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.dismissTask == nil, self.panel != nil else { return }
            withAnimation(Self.morph) { self.state.presented = true }
            #if DEBUG
            self.applyDebugStateIfRequested()
            #endif
        }
    }

    /// 缩回刘海后再收掉面板，`completion` 在面板真正撤下之后调用。
    func dismiss(completion: (() -> Void)? = nil) {
        guard let panel, panel.isVisible else {
            teardown()
            completion?()
            return
        }
        stopPointerTracking()
        systemMonitor.stop()
        expandTask?.cancel()
        expandTask = nil
        collapseTask?.cancel()
        collapseTask = nil
        activityTask?.cancel()
        activityTask = nil
        panel.ignoresMouseEvents = true
        withAnimation(Self.morph) {
            state.expanded = false
            state.peeking = false
            state.activity = nil
            state.presented = false
        }
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, !Task.isCancelled else { return }
            self.dismissTask = nil
            self.teardown()
            completion?()
        }
    }

    // MARK: - Screen

    /// 优先上次上岛的那块屏幕，其次带刘海的内建屏，再退到主屏。
    private static func resolveScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let stored = UserDefaults.standard.object(forKey: displayKey) as? Int,
           let match = screens.first(where: { $0.primuseDisplayID.map(Int.init) == stored }) {
            return match
        }
        return screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first
    }

    private static func metrics(for screen: NSScreen) -> DesktopLyricsIslandMetrics {
        var description = DesktopLyricsIslandScreen(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            statusBarThickness: NSStatusBar.system.thickness
        )
        #if DEBUG
        // 编译机和外接屏都没有刘海：PRIMUSE_DEBUG_ISLAND_NOTCH=190x32 按这么大的刘海排版。
        if let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_ISLAND_NOTCH"] {
            let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                let side = (screen.frame.width - CGFloat(parts[0])) / 2
                description.safeAreaTop = CGFloat(parts[1])
                description.auxiliaryLeftWidth = side
                description.auxiliaryRightWidth = side
            }
        }
        #endif
        return DesktopLyricsIslandMetrics.resolve(for: description)
    }

    private func apply(screen: NSScreen) {
        screenFrame = screen.frame
        let metrics = Self.metrics(for: screen)
        if state.metrics != metrics { state.metrics = metrics }
        guard let panel else { return }
        // isFloatingPanel 会重设窗口层级，最终层级在面板配置完成后应用。
        let level = NSWindow.Level(rawValue: state.alwaysOnTop
            ? NSWindow.Level.statusBar.rawValue + 1
            : NSWindow.Level.mainMenu.rawValue - 1)
        if panel.level != level { panel.level = level }
        let frame = metrics.panelFrame(on: screen.frame)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func setAlwaysOnTop(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.alwaysOnTopKey)
        state.alwaysOnTop = enabled
        if let screen = Self.resolveScreen() { apply(screen: screen) }
        updatePointer()
    }

    private func observePreferenceChanges() {
        guard preferenceObserver == nil else { return }
        // 不挂主队列: 写 UserDefaults 的线程会同步等主队列上的回调跑完 (#200)。
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let enabled = UserDefaults.standard.bool(forKey: Self.alwaysOnTopKey)
                guard enabled != self.state.alwaysOnTop else { return }
                self.state.alwaysOnTop = enabled
                if let screen = Self.resolveScreen() { self.apply(screen: screen) }
                self.updatePointer()
            }
        }
    }

    /// 插拔显示器、改分辨率、合盖都会改屏幕排布，岛要跟着回到正确的顶边。
    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing, let screen = Self.resolveScreen() else { return }
                self.apply(screen: screen)
                self.updatePointer()
            }
        }
    }

    // MARK: - Panel

    private func makePanel() -> DesktopLyricsIslandPanel {
        let size = state.metrics.panelSize
        let panel = DesktopLyricsIslandPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: DesktopLyricsIslandView(
            state: state,
            onToggleDesktop: { [weak self] in self?.onToggleDesktop() },
            onClose: { [weak self] in self?.onClose() },
            onAlwaysOnTopChange: { [weak self] in self?.setAlwaysOnTop($0) }
        ).applyPrimuseEnvironments())
        // 面板尺寸由这里按屏幕算好，不让 SwiftUI 内容反过来撑窗口。
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// 面板撤下时连 SwiftUI 内容一起释放 —— 岛里有逐字扫光和声线两个时钟，
    /// 留在屏幕外空转没有意义。下次上岛重新建一份，状态对象保留。
    private func teardown() {
        stopPointerTracking()
        systemMonitor.stop()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
            self.preferenceObserver = nil
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        state.expanded = false
        state.peeking = false
        state.activity = nil
        state.presented = false
        #if DEBUG
        debugPinned = false
        #endif
    }

    // MARK: - Pointer

    private func startPointerTracking() {
        guard pointerMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel
        ]
        // 回调只读 NSEvent.mouseLocation 这类静态状态，不碰传进来的 event。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updatePointer() }
            return event
        }) {
            pointerMonitors.append(local)
        }
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTracking() {
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors.removeAll()
        pointerTimer?.invalidate()
        pointerTimer = nil
        pressBeganInside = false
    }

    private func currentZone() -> DesktopLyricsIslandZone {
        let size = state.islandSize == .zero ? state.metrics.restingSize : state.islandSize
        let island = state.metrics.islandFrame(size: size, on: screenFrame)
        return state.metrics.zone(
            of: NSEvent.mouseLocation,
            islandFrame: island,
            screenFrame: screenFrame,
            expanded: state.expanded
        )
    }

    /// 按指针此刻的位置决定展开 / 收起 / 变淡，以及面板吃不吃鼠标。
    private func updatePointer() {
        guard let panel, panel.isVisible, state.presented, dismissTask == nil else { return }
        #if DEBUG
        if debugPinned { return }
        #endif
        let zone = currentZone()
        let buttonHeld = NSEvent.pressedMouseButtons & 0x1 != 0
        if !buttonHeld { pressBeganInside = false }

        if state.expanded {
            if zone == .inside {
                if buttonHeld { pressBeganInside = true }
                cancelCollapse()
                setPassthrough(false, panel)
            } else if pressBeganInside {
                cancelCollapse()
            } else {
                // 卡片以外的透明区域一律放行；给一小段宽限再收，指针擦出边缘又回来不会闪。
                setPassthrough(true, panel)
                scheduleCollapse()
            }
            return
        }

        setPassthrough(true, panel)
        switch zone {
        case .trigger:
            setPeeking(false)
            scheduleExpand()
        case .peek:
            cancelExpand()
            setPeeking(true)
        case .outside, .inside:
            cancelExpand()
            setPeeking(false)
        }
    }

    private func setPassthrough(_ passthrough: Bool, _ panel: NSPanel) {
        if panel.ignoresMouseEvents != passthrough { panel.ignoresMouseEvents = passthrough }
    }

    private func setPeeking(_ peeking: Bool) {
        guard state.peeking != peeking else { return }
        withAnimation(.easeOut(duration: 0.16)) { state.peeking = peeking }
    }

    /// 停一下才展开：指针只是扫过菜单栏正中时不该弹出一张卡片。
    private func scheduleExpand() {
        guard expandTask == nil else { return }
        expandTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled else { return }
            self.expandTask = nil
            guard !self.state.expanded,
                  self.currentZone() == .trigger,
                  let panel = self.panel else { return }
            withAnimation(Self.morph) {
                self.state.expanded = true
                self.state.peeking = false
            }
            self.setPassthrough(false, panel)
        }
    }

    private func cancelExpand() {
        expandTask?.cancel()
        expandTask = nil
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }
        collapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, !Task.isCancelled else { return }
            self.collapseTask = nil
            guard self.state.expanded, self.currentZone() != .inside else { return }
            self.collapse()
        }
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func collapse() {
        cancelCollapse()
        cancelExpand()
        pressBeganInside = false
        withAnimation(Self.morph) { state.expanded = false }
        if let panel { setPassthrough(true, panel) }
    }

    // MARK: - System activities

    private func present(_ activity: DesktopLyricsIslandActivity) {
        guard UserDefaults.standard.object(forKey: Self.systemStatusKey) as? Bool ?? true,
              state.presented, dismissTask == nil else { return }
        #if DEBUG
        if debugPinned { return }
        #endif
        // 连续调音量时同一条状态只更新读数，不重新走一遍形变。
        let sameKind = state.activity?.kind == activity.kind
        if !sameKind { plog("🏝 island activity \(activity.kind) \(activity.symbol)") }
        withAnimation(sameKind ? .easeOut(duration: 0.12) : Self.morph) {
            state.activity = activity
        }
        let duration = activity.kind == .volume
            ? DesktopLyricsIslandActivityPolicy.volumeDuration
            : DesktopLyricsIslandActivityPolicy.statusDuration
        activityTask?.cancel()
        activityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.activityTask = nil
            withAnimation(Self.morph) { self.state.activity = nil }
        }
    }

    #if DEBUG
    /// PRIMUSE_DEBUG_ISLAND=expanded|volume|output|power：上岛后把岛钉在对应状态。
    /// PRIMUSE_DEBUG_ISLAND_SNAPSHOT=<目录>：歌词读出来后把刘海屏 / 普通屏各个状态
    /// 离屏渲染成 PNG —— 编译机经常锁屏，截屏只拍得到壁纸。
    private func applyDebugStateIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let directory = env["PRIMUSE_DEBUG_ISLAND_SNAPSHOT"], !directory.isEmpty {
            renderDebugSnapshots(to: URL(fileURLWithPath: directory))
        }
        guard let raw = env["PRIMUSE_DEBUG_ISLAND"] else { return }
        if raw == "expanded" {
            debugPinned = true
            withAnimation(Self.morph) { state.expanded = true }
            panel?.ignoresMouseEvents = false
            return
        }
        guard let activity = Self.debugActivity(named: raw) else { return }
        debugPinned = true
        withAnimation(Self.morph) { state.activity = activity }
    }

    private static func debugActivity(named name: String) -> DesktopLyricsIslandActivity? {
        switch name {
        case "volume":
            return DesktopLyricsIslandActivity(
                kind: .volume,
                symbol: DesktopLyricsIslandActivityPolicy.volumeSymbol(level: 0.62, muted: false),
                caption: String(localized: "desktop_lyrics_island_volume"),
                title: "",
                level: 0.62,
                trailing: 0.62.formatted(.percent.precision(.fractionLength(0))),
                tint: .neutral
            )
        case "output":
            return DesktopLyricsIslandActivity(
                kind: .output,
                symbol: "airpodspro",
                caption: String(localized: "desktop_lyrics_island_output"),
                title: "AirPods Pro",
                level: nil,
                trailing: nil,
                tint: .neutral
            )
        case "power":
            return DesktopLyricsIslandActivity(
                kind: .power,
                symbol: DesktopLyricsIslandActivityPolicy.batterySymbol(level: 0.8, charging: true),
                caption: String(localized: "desktop_lyrics_island_charging"),
                title: 0.8.formatted(.percent.precision(.fractionLength(0))),
                level: nil,
                trailing: nil,
                tint: .charging
            )
        default:
            return nil
        }
    }

    private func renderDebugSnapshots(to directory: URL) {
        Task { @MainActor [weak self] in
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.state.currentIndex >= 0 { break }
            }
            try? await Task.sleep(for: .seconds(1))
            self?.writeDebugSnapshots(to: directory)
        }
    }

    private func writeDebugSnapshots(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notched = DesktopLyricsIslandMetrics.resolve(for: DesktopLyricsIslandScreen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryLeftWidth: 663.5,
            auxiliaryRightWidth: 663.5
        ))
        let flat = DesktopLyricsIslandMetrics.resolve(for: DesktopLyricsIslandScreen(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
        ))
        let states: [(String, Bool, String?)] = [
            ("compact", false, nil),
            ("expanded", true, nil),
            ("volume", false, "volume"),
            ("output", false, "output"),
            ("power", false, "power")
        ]
        for (screenName, metrics) in [("notch", notched), ("flat", flat)] {
            for (stateName, expanded, activityName) in states {
                let snapshot = DesktopLyricsIslandState(metrics: metrics)
                snapshot.presented = true
                snapshot.expanded = expanded
                snapshot.activity = activityName.flatMap(Self.debugActivity(named:))
                snapshot.lyrics = state.lyrics
                snapshot.lyricsSongID = state.lyricsSongID
                snapshot.currentIndex = state.currentIndex
                let size = metrics.panelSize
                let content = ZStack(alignment: .top) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.30, green: 0.36, blue: 0.56),
                            Color(red: 0.86, green: 0.60, blue: 0.50)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    DesktopLyricsIslandView(state: snapshot)
                }
                .frame(width: size.width, height: size.height)
                .applyPrimuseEnvironments()
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    plog("🧪 island snapshot \(screenName)-\(stateName) failed")
                    continue
                }
                try? png.write(to: directory.appendingPathComponent("\(screenName)-\(stateName).png"))
            }
        }
        plog("🧪 island snapshots written to \(directory.path) lyrics=\(state.lyrics.count) index=\(state.currentIndex)")
    }
    #endif
}

extension NSScreen {
    /// CGDirectDisplayID。同一块屏幕重启后通常不变，拿来记住岛上在哪块屏幕。
    var primuseDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
#endif
