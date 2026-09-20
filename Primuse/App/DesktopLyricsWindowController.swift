#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// 桌面歌词面板的鼠标穿透状态 —— view 侧上报"真的画了东西"的那块区域,
/// controller 侧盯着指针位置决定面板吃不吃鼠标事件。
///
/// 为什么要单开一层:桌面歌词是一块按屏幕宽度算出来的透明 NSPanel (横向
/// 900–1400pt),浮在所有窗口之上。AppKit 没有"按像素穿透"的开关,
/// `ignoresMouseEvents` 只能整窗开关,所以整块透明区域都会把点击吞掉 ——
/// 哪怕用户关掉背板,后面的桌面图标和窗口也点不到。主流桌面歌词
/// (网易云音乐 / QQ 音乐 / LyricsX) 的做法都一样:用鼠标监视器判断指针在
/// 不在歌词上,再动态切 `ignoresMouseEvents`。这里照做。
@MainActor
@Observable
final class DesktopLyricsInteraction {
    static let shared = DesktopLyricsInteraction()

    /// 歌词 (连同背板) 在面板局部坐标里的矩形,SwiftUI 坐标系:左上原点、
    /// y 向下。`.null` = 还没量出来,这时按整块面板算 —— 宁可暂时不穿透,
    /// 也不能让歌词点不到。
    var contentRect: CGRect = .null

    /// 指针是否已经"进入"面板。进入只认 `contentRect`,离开认整块面板 ——
    /// 鼠标一碰到歌词,浮出的工具栏、四边缩放热区、拖动就全都能用,移出
    /// 面板之后才重新变回穿透。只由 controller 写。
    var engaged = false

    /// 整窗穿透 —— 关掉背板或锁定时置位,面板一个像素都不再接收鼠标事件。
    /// 这条路不看 `contentRect`:用户说"背板都关了还挡"的就是这种情况,
    /// 不能再押在测量上,测不准就等于没修。由 view 写。
    var fullyTransparent = false

    /// popover 撑开期间强制保持。popover 是另一个窗口,指针移过去时面板
    /// 这边一个事件都收不到,不兜住会被判成"离开"把 chrome 连同 popover
    /// 一起收掉。由 view 写。
    var keepsEngaged = false
}

/// Borderless transparent NSPanel that floats over every other window. The
/// SwiftUI content (`DesktopLyricsView`) re-fetches lyrics on song change and
/// follows playback time. Position is persisted via the panel's auto-save
/// frame name so users only have to drag it once per screen layout.
@MainActor
final class DesktopLyricsWindowController {
    private var panel: NSPanel?
    @AppStorage("desktopLyricsVisible") private var visible: Bool = false
    @AppStorage("desktopLyricsLocked") private var locked: Bool = false
    /// didChangeNotification observer token —— 必须持有并在 deinit 注销, 否则
    /// block-based observer 永远不会移除 (内存泄漏)。nonisolated(unsafe): 仅 init
    /// (MainActor) 写、deinit 读, 无并发竞争, 让 Swift 6 的 nonisolated deinit 可访问。
    nonisolated(unsafe) private var lockObserver: NSObjectProtocol?
    /// 上次已应用的 lock 值 —— 全局 didChange 会因 app 内任何 UserDefaults 写入
    /// (音量/主题等高频) 触发, 只在 lock 真正变化时才动 panel, 避免主线程噪声。
    private var lastKnownLocked: Bool = false

    /// autosave name 带 v2 后缀:之前默认 600x140 太窄会截断长歌词,
    /// 改默认值时换 key 让老用户也跳到新的宽默认值,而不是停在旧
    /// 持久化的 600pt 上看 ... 截断。
    private static let frameAutosaveName = "PrimuseDesktopLyrics_v2"

    /// 一次拖动的起点:按下瞬间的鼠标屏幕坐标 + panel 当时的原点。
    /// 每个拖动事件都按"当前鼠标 - 起点鼠标"算绝对位移,而不是累加
    /// SwiftUI 给的 translation —— panel 是跟着手一起走的,窗口坐标系
    /// 里的位移每次都被自身的移动抵消回去,累加的写法会让窗口抖在原地。
    private var dragAnchor: (mouse: NSPoint, origin: NSPoint)?

    /// 鼠标监视器 —— 全局一个 (指针落在别的 app 上) + 本地一个 (落在本 app 上)。
    /// 面板穿透时自己收不到任何鼠标事件,只能靠监视器知道指针走到哪了。
    /// nonisolated(unsafe) 的理由跟 lockObserver 一样:只有 MainActor 方法写、
    /// deinit 读,没有并发竞争,但 deinit 是 nonisolated 的。
    nonisolated(unsafe) private var pointerMonitors: [Any] = []

    /// 保险丝。监视器只在系统真的派发了鼠标移动事件时才响:面板穿透时事件
    /// 落到下面那个窗口上,如果那恰好是本 app 里一个没开
    /// `acceptsMouseMovedEvents` 的窗口,系统压根不会生成事件,穿透状态就会
    /// 停在旧值、歌词再也点不回来。低频轮一次兜住,tolerance 拉满让系统合并
    /// 唤醒。
    nonisolated(unsafe) private var pointerTimer: Timer?

    /// 直接读 UserDefaults 而不是 @AppStorage 包装,因为这个类不是
    /// SwiftUI View,@AppStorage 的"自动跟随"在非 View 上下文里
    /// 不一定每次都拿到最新值。
    private var isLockedNow: Bool {
        UserDefaults.standard.bool(forKey: "desktopLyricsLocked")
    }

    /// 主屏可见区域 —— 拿不到就按 1440×900 这块最常见的笔记本屏算。
    private static var referenceScreen: NSRect {
        NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 横向布局 (single/dual) 默认尺寸 —— 参考主流桌面歌词软件的宽度习惯
    /// (网易云 / QQ 音乐 / LyricsX 都是屏幕宽度 60-75%)。
    ///
    /// 长短边都跟着屏幕算,不写死 pt:同一组数字在 1280×800 的笔记本上会占掉
    /// 大半个屏,在 6K 显示器上又小得像贴纸。高度尤其不能固定 —— 歌词字号本身
    /// 是按长边算的 (长边 6%,上限 64pt),所以面板高度按"字号能排下双行 + 顶部
    /// 工具栏"推出来,超宽屏上就不会剩一大片空白。
    private static var horizontalSize: NSSize {
        let visible = referenceScreen
        // 宽度下限 720pt:顶部工具栏五颗按钮加内边距约 160pt,720 给长歌词留够余量。
        let width = min(max(visible.width * 0.62, 720), 1600)
        let fontSize = min(64, max(20, width * 0.06))
        // 双行 (当前行 + 提示行 ≈ 1.55 倍字号) + 行距 + 上下留白 ≈ 2.4 倍字号,
        // 再加顶部工具栏那条。最后夹到可见高度的 30% 以内。
        let height = min(max(fontSize * 2.4 + Self.toolbarAllowance, 150), visible.height * 0.3)
        return NSSize(width: width, height: height)
    }

    /// 纵向布局默认尺寸 —— 跟横向尺寸"长宽对调",但 height 还要再
    /// clamp 到屏可见区域的 85% 以内,免得长条延伸到屏幕外把底部按钮
    /// 顶到 dock 下面点不到。屏幕短的笔记本 (13/14 寸 1080p) 上长边可
    /// 能缩到 ~700pt,这是预期的。
    private static var verticalSize: NSSize {
        let h = horizontalSize
        let maxAllowed = referenceScreen.height * 0.85
        return NSSize(width: max(h.height, 240), height: min(h.width, maxAllowed))
    }

    /// 顶部悬浮工具栏占掉的高度,跟 DesktopLyricsView.topToolbarHeight 对齐。
    private static let toolbarAllowance: CGFloat = 38

    init() {
        if visible { show() }
        lastKnownLocked = locked
        // 监听 lock 变化（来自菜单栏 popover 或桌面歌词的悬浮 toolbar）
        // 同步给 NSPanel,因为 ignoresMouseEvents 是 NSWindow 级别状态。
        lockObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.locked != self.lastKnownLocked else { return }
                self.lastKnownLocked = self.locked
                self.applyLockedState()
            }
        }
    }

    deinit {
        if let lockObserver {
            NotificationCenter.default.removeObserver(lockObserver)
        }
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerTimer?.invalidate()
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = makePanel()
            self.panel = panel
        }
        panel.orderFrontRegardless()
        visible = true
        startPointerTracking()
        applyLockedState()
    }

    func hide() {
        stopPointerTracking()
        panel?.orderOut(nil)
        visible = false
    }

    /// 用户切换排版时把 panel 拉成对应朝向。围绕中心点缩放,避免
    /// 从某个角"长"出来视觉跳变。如果用户已经手动拖到接近目标尺寸
    /// (可能他自己定的),不强行覆盖。
    private func applyLayoutSize(_ layout: DesktopLyricsLayout) {
        guard let panel else { return }
        let target: NSSize
        switch layout {
        case .single, .dual: target = Self.horizontalSize
        case .vertical: target = Self.verticalSize
        }
        let current = panel.frame
        // 已经接近就不动 —— 用户可能拖过自定义尺寸,不要每次切排版
        // 都把人家辛苦调好的尺寸抹掉。
        if abs(current.width - target.width) < 60,
           abs(current.height - target.height) < 60 {
            return
        }
        let center = NSPoint(x: current.midX, y: current.midY)
        let newFrame = NSRect(
            x: center.x - target.width / 2,
            y: center.y - target.height / 2,
            width: target.width,
            height: target.height
        )
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(newFrame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    private func applyLockedState() {
        // 锁定只管两件事:拖动由 updateWindowDrag 按锁定态拦掉 (防误拖),
        // chrome 换成那颗解锁按钮。吃不吃鼠标事件跟锁定无关,统一交给
        // updatePassthrough 按指针位置判 —— 锁定态下指针照样能落到歌词上
        // hover 出解锁按钮,而歌词以外的地方一直是穿透的。
        // 解锁路径:hover 浮现的锁按钮 / 菜单栏开关 / ⇧⌘L 快捷键。
        updatePassthrough()
        // 拖动过程中被锁上就把这次拖动作废,免得松手前还继续跟手。
        if isLockedNow { dragAnchor = nil }
    }

    // MARK: - 鼠标穿透

    private func startPointerTracking() {
        guard pointerMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .scrollWheel
        ]
        // 监视器回调同步跑在主事件循环上,但 SDK 没给它标 @MainActor。
        // 回调里只读 NSEvent.mouseLocation (静态、线程安全),不碰传进来的
        // event,所以不需要像键盘监视器那样把事件装箱搬运。
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePassthrough()
            }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePassthrough()
            }
            return event
        }) {
            pointerMonitors.append(local)
        }

        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updatePassthrough()
            }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        updatePassthrough()
    }

    private func stopPointerTracking() {
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors.removeAll()
        pointerTimer?.invalidate()
        pointerTimer = nil
        DesktopLyricsInteraction.shared.engaged = false
        // 下次 show() 之前保持可点,免得停在"穿透"上把再次打开的面板变成死的。
        panel?.ignoresMouseEvents = false
    }

    /// 按指针此刻的位置决定面板吃不吃鼠标事件。
    private func updatePassthrough() {
        guard let panel, panel.isVisible else { return }
        let interaction = DesktopLyricsInteraction.shared
        let mouse = NSEvent.mouseLocation
        // 关掉背板 / 锁定 = 面板上没有一块"看得见的板",除了右上角那个把手
        // 以外整窗放行。这一支不看 contentRect,所以即使测量出问题也一定生效
        // —— 用户抱怨的就是"背板都关了还挡",这条不能再押在测量上。
        if interaction.fullyTransparent, !interaction.keepsEngaged {
            let onHandle = cornerHandleOnScreen(panel).contains(mouse)
            let stillInside = interaction.engaged && panel.frame.contains(mouse)
            let inside = onHandle || stillInside
            if interaction.engaged != inside { interaction.engaged = inside }
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
            return
        }
        let inside: Bool
        if interaction.keepsEngaged {
            inside = true
        } else if interaction.engaged {
            // 已经进来了就按整块面板判离开 —— 否则指针从歌词挪向顶部工具栏
            // 的半路上就被判成离开,按钮永远点不到,四边的缩放热区也没了。
            inside = panel.frame.contains(mouse)
        } else {
            inside = interactiveRectOnScreen(panel).contains(mouse)
                || cornerHandleOnScreen(panel).contains(mouse)
        }
        if interaction.engaged != inside { interaction.engaged = inside }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    /// view 上报的内容矩形换算成屏幕坐标。SwiftUI 那边是左上原点、y 向下,
    /// AppKit 是左下原点、y 向上,所以要按面板高度翻一次。面板是 borderless,
    /// 窗口坐标系跟 contentView 的重合,不用再减标题栏。
    private func interactiveRectOnScreen(_ panel: NSPanel) -> NSRect {
        let rect = DesktopLyricsInteraction.shared.contentRect
        guard !rect.isNull, !rect.isEmpty else { return panel.frame }
        let flipped = NSRect(
            x: rect.minX,
            y: panel.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        return panel.convertToScreen(flipped).intersection(panel.frame)
    }

    /// 面板右上角常驻的一小块把手 —— 悬浮工具栏和锁定提示本来就锚在这儿。
    /// 不论背板开没开、锁没锁,它都接收鼠标:没有它,关掉背板之后整块面板
    /// 全透,用户就再也够不到"重新显示背板"和"解锁"那两个开关了。
    /// 纯几何算出来,不经过 SwiftUI 测量。
    private func cornerHandleOnScreen(_ panel: NSPanel) -> NSRect {
        let frame = panel.frame
        let size = NSSize(width: min(150, frame.width), height: min(40, frame.height))
        return NSRect(
            x: frame.maxX - size.width,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - 窗口拖动

    /// 桌面歌词的拖动自己做,不再交给 NSWindow.isMovableByWindowBackground ——
    /// panel 的 contentView 是 SwiftUI 的承载视图,它会把背景区域的 mouseDown
    /// 一并吃掉,AppKit 那条"点背景拖窗口"的路径就再也拿不到事件 (macOS 27 上
    /// 表现为解锁状态下歌词完全拖不动,只能待在初始位置)。改由 SwiftUI 侧识别
    /// 拖拽手势、这里直接搬 panel,行为在各版本 macOS 上都一致。
    /// 锁定时直接不动,菜单栏/悬浮锁按钮解锁后才恢复。
    private func updateWindowDrag() {
        guard let panel, !isLockedNow else { return }
        // 第一帧只记锚点:锚点同时取"此刻的鼠标位置"和"此刻的窗口原点",
        // 之后的位移都相对这一刻算,所以起手不会有跳一下的偏移。
        guard let anchor = dragAnchor else {
            dragAnchor = (NSEvent.mouseLocation, panel.frame.origin)
            return
        }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(
            x: anchor.origin.x + (mouse.x - anchor.mouse.x),
            y: anchor.origin.y + (mouse.y - anchor.mouse.y)
        ))
    }

    private func endWindowDrag() {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        // setFrameOrigin 是代码改的 frame,不会触发 autosave 的自动落盘,
        // 松手时显式存一次,下次打开才回到用户拖好的位置。
        panel?.saveFrame(usingName: Self.frameAutosaveName)
    }

    /// 存下来的 frame 可能整块落在屏幕外 (拔掉外接屏、换分辨率、显示器重新排列),
    /// 那样窗口就"打开了但看不见"。只要和任何一块屏的可见区域都不相交就挪回主屏。
    private func moveOnScreenIfNeeded(_ panel: NSPanel) {
        let frame = panel.frame
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        applyDefaultOrigin(panel)
    }

    /// 默认位置:横向居中、贴 Dock 上方。
    private func applyDefaultOrigin(_ panel: NSPanel) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + 80
        ))
    }

    private func makePanel() -> NSPanel {
        // .resizable + .borderless 让 panel 没有标题条但仍可从四边
        // 拖拽改尺寸。SwiftUI 内部 GeometryReader 会按新尺寸刷新字号。
        let initial = Self.horizontalSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 80, width: initial.width, height: initial.height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        // 拖动改由 updateWindowDrag 负责,这里保持关闭:
        // 两条路径同时生效会把同一次拖动算两遍,窗口跑得比鼠标快一倍。
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 90, height: 70)
        // 让本地监视器在指针压在面板自己头上时也能收到移动事件 —— 面板不
        // 穿透的那段时间就靠它保持同步。
        panel.acceptsMouseMovedEvents = true
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        // setFrameAutosaveName 只登记"以后自动存",不会把上次存的 frame 读回来
        // (读是 setFrameUsingName 的事)。少了这一步,每次开桌面歌词都回到
        // contentRect 给的 (0, 80) —— 也就是屏幕左下角偏上一点点,用户上次
        // 拖到哪全白费。
        if panel.setFrameUsingName(Self.frameAutosaveName) {
            moveOnScreenIfNeeded(panel)
        } else {
            applyDefaultOrigin(panel)
        }

        let host = NSHostingController(
            rootView: DesktopLyricsView(
                onClose: { [weak self] in self?.hide() },
                onLayoutChange: { [weak self] layout in
                    self?.applyLayoutSize(layout)
                },
                onWindowDragChanged: { [weak self] in self?.updateWindowDrag() },
                onWindowDragEnded: { [weak self] in self?.endWindowDrag() },
                onContentRectChange: { [weak self] rect in
                    DesktopLyricsInteraction.shared.contentRect = rect
                    // 换歌、切排版都会改这块矩形。指针没动时监视器不会响,
                    // 这里顺手重算一次,免得热区跟着歌词变了状态还是旧的。
                    self?.updatePassthrough()
                }
            ).applyPrimuseEnvironments()
        )
        host.view.frame = panel.contentView?.bounds ?? .zero
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view
        return panel
    }
}
#endif
