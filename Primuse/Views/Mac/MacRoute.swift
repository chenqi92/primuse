#if os(macOS)
import Foundation
import AppKit
import QuartzCore
import PrimuseKit

enum MacRoute: Hashable {
    case home
    case stats
    case search
    case sources
    case section(LibrarySection)
    /// 单独的"我喜欢的"快捷入口 — 等同于 .section(.songs) + isLiked 过滤。
    case liked
    /// 直接打开指定歌单 (从侧栏歌单列表点入)。
    case playlist(Playlist)
    /// 直接打开指定智能歌单 (从侧栏智能歌单列表点入)。
    case smartPlaylist(SmartPlaylist)
    case source(String)
}

extension MacRoute {
    var stableID: String {
        switch self {
        case .home: return "home"
        case .stats: return "stats"
        case .search: return "search"
        case .sources: return "sources"
        case .section(let section): return "section-\(section)"
        case .liked: return "liked"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .smartPlaylist(let smart): return "smartPlaylist-\(smart.id)"
        case .source(let id): return "source-\(id)"
        }
    }
}

/// 侧栏换页的两步(见 `MacContentView.requestRoute`)共用的状态。放进可观察对象, 谁读谁重画:
/// 第一步只动侧栏、标题栏里读了 `requested` 的那几行和详情区外面那层, 第二步只重建详情区;
/// 主窗口的 body 两步都不再求一遍 —— 那会把侧栏、标题栏、底栏连同当前页整个重建。
///
/// 侧栏、标题栏拿的是这个对象, 不是 `Binding`: 绑定一建出来就先读一遍值, 主窗口在 body 里
/// 给它们建绑定, 就等于主窗口自己订上了选中项, 每换一次高亮整个主窗口照样重算。
@MainActor
@Observable
final class MacRouteSwitch {
    /// 侧栏、标题栏高亮的那一项。点下去就变, 详情区等第二步才换。
    var requested: MacRoute = .home {
        didSet { updateRowHighlights() }
    }
    /// 详情区正在显示的那一页。
    var shown: MacRoute = .home
    /// 每换一次页换一个: 详情栈连同里面压进去的页整个重建。
    var navigationID = UUID()
    /// 旧页已藏起来、新页还没建。
    var isSwitching = false
    /// 排着等第二步的那一页。
    @ObservationIgnored var pending: MacRoute?
    /// 侧栏每一行各订一份「是不是我」: 换高亮时只惊动新旧两行, 不是二十来行全部重算。
    @ObservationIgnored private var rowHighlights: [String: MacRouteRowHighlight] = [:]
    /// `requested` 的不观察副本: 侧栏建行时取一份高亮要看它, 读 `requested` 的话侧栏自己就订上了。
    @ObservationIgnored private var requestedKey = MacRoute.home.stableID

    func rowHighlight(for route: MacRoute) -> MacRouteRowHighlight {
        let key = route.stableID
        if let highlight = rowHighlights[key] { return highlight }
        let highlight = MacRouteRowHighlight(isSelected: key == requestedKey)
        rowHighlights[key] = highlight
        return highlight
    }

    private func updateRowHighlights() {
        requestedKey = requested.stableID
        for (key, highlight) in rowHighlights {
            let isSelected = key == requestedKey
            if highlight.isSelected != isSelected { highlight.isSelected = isSelected }
        }
    }
}

/// 侧栏一行是不是当前高亮的那一项。歌单、智能歌单按 id 认(`MacRoute.stableID`): 改了名的同一张仍算选中。
@MainActor
@Observable
final class MacRouteRowHighlight {
    var isSelected: Bool

    init(isSelected: Bool) {
        self.isSelected = isSelected
    }
}

/// 工具面板。标题栏的工具菜单和菜单栏「工具」里打开, 以弹框 (`.sheet`) 盖在当前页上 ——
/// 工具是临时操作面板, 用完即关, 不占侧栏。`Identifiable` 让 `MacContentView` 能直接
/// `.sheet(item:)`。
enum MacTool: String, Identifiable, Hashable, CaseIterable {
    case cacheSync
    case deviceTransfer
    case lyricsConverter
    case duplicates
    case scrobble

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cacheSync: CacheSyncLocalization.text("cache_sync_title")
        case .deviceTransfer: WiFiTransferText.string("nativeTitle")
        case .lyricsConverter: String(localized: "lyrics_converter_title")
        case .duplicates: String(localized: "Duplicate Song Cleanup")
        case .scrobble: String(localized: "Scrobble Configuration")
        }
    }

    var systemImage: String {
        switch self {
        case .cacheSync: "externaldrive.badge.wifi"
        case .deviceTransfer: "laptopcomputer.and.iphone"
        case .lyricsConverter: "arrow.left.arrow.right"
        case .duplicates: "arrow.triangle.2.circlepath"
        case .scrobble: "waveform.path.ecg"
        }
    }
}

#if DEBUG
/// 侧栏换页的耗时: 点下去 → 新页 `onAppear` → 这一帧提交给屏幕 → 内容真正摆出来。
/// 每段一行 🧪 日志, 编译机上用调试脚本的 `route:` 换页量出来; 之后一秒的显示链接
/// 节拍另记一行(最长间隔、丢了几帧), 看入场动画卡不卡。
@MainActor
enum MacRouteTiming {
    private static var start: ContinuousClock.Instant?
    private static var label = ""
    private static var frames: MacRouteFrameRecorder?

    static func begin(_ route: MacRoute) {
        start = .now
        label = route.stableID
        PMWindowChromeTrace.start("route \(label)")
        frames?.stop()
        let recorder = MacRouteFrameRecorder(label: label)
        recorder.start()
        frames = recorder
        markAfterCommit("click committed")
    }

    static func mark(_ event: String) {
        guard let start else { return }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        plog("🧪 route \(label) \(event) +\(Int(ms.rounded()))ms")
    }

    /// 这一轮主线程把图层树提交出去之后记一笔, 即「这一帧画好交出去了」。
    /// 要在运行循环的观察者回调之外调用(按钮动作、通知、主队列里的活): `onAppear` 这类
    /// 视图更新里的回调本身就在提交那一轮的观察者里, 那时挂上的要等下一轮才轮到。
    static func markAfterCommit(_ event: String) {
        MacFrameCommit.afterCurrentCommit { mark(event) }
    }
}

/// 换页之后一秒里显示链接的节拍。主线程被占住时回调会断档, 断档按屏幕刷新间隔折成丢了几帧。
@MainActor
private final class MacRouteFrameRecorder: NSObject {
    private let label: String
    private var link: CADisplayLink?
    private var origin: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var ticks = 0
    private var dropped = 0
    private var longest: CFTimeInterval = 0
    private var interval: CFTimeInterval = 1.0 / 60

    init(label: String) {
        self.label = label
    }

    func start() {
        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // 从点下去那一刻算起: 点下去这一轮就建新页的话, 第一拍要等它建完才来。
        origin = CACurrentMediaTime()
        last = origin
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        interval = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        let gap = now - last
        longest = max(longest, gap)
        dropped += max(0, Int((gap / interval).rounded()) - 1)
        ticks += 1
        last = now
        guard now - origin >= 1 else { return }
        plog("🧪 route \(label) frames ticks=\(ticks) longest=\(Int((longest * 1000).rounded()))ms dropped=\(dropped) refresh=\(Int((1 / interval).rounded()))Hz")
        stop()
    }
}
#endif

/// 等这一轮主线程把改动提交给屏幕之后再做一件事。
///
/// Core Animation 在主运行循环进入休眠前(BeforeWaiting, order 2000000)提交图层树。这里挂一个
/// 排在它后面的一次性观察者, 提交完再把活投回主队列 —— 投进主队列会把运行循环马上叫醒,
/// 不用等下一个事件; 那一轮里改的状态在那一轮末尾另成一帧。
@MainActor
enum MacFrameCommit {
    static func afterCurrentCommit(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            2_100_000
        ) { _, _ in
            DispatchQueue.main.async { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

extension Notification.Name {
    static let primuseDetailOpenAlbum = Notification.Name("primuse.detail.openAlbum")
    static let primuseDetailOpenArtist = Notification.Name("primuse.detail.openArtist")
    static let primuseSelectScrobble = Notification.Name("primuse.route.scrobble")
    /// 跳到「歌单」总览 (删除当前歌单后用)。主容器同时会清掉详情栈, 避免栈里
    /// 还压着刚删掉那张歌单的空详情。
    static let primuseSelectPlaylists = Notification.Name("primuse.route.playlists")
    /// 跳到侧栏的「电台」项。首页电台分区的「全部」用它 —— 侧栏本来就有这一项,
    /// push 一个带返回键的新页面等于同一个目的地有两条路径。
    static let primuseSelectRadio = Notification.Name("primuse.route.radio")
    /// 跳到侧栏的「有声」项。首页「在听的书」一栏的「全部」用它, 理由同上。
    /// object 是 `LibrarySection` 时跳到那一项(首页「播客更新」给 `.podcasts`)。
    static let primuseSelectSpokenWord = Notification.Name("primuse.route.spokenWord")
    /// 打开一本有声书的详情(object 是书的 id)。播放页「转到这本书」用它:
    /// 先切到侧栏的「有声」, 再把书压进那一栏的详情栈, 返回就回到书架。
    static let primuseDetailOpenSpokenWordBook = Notification.Name("primuse.detail.openSpokenWordBook")
    /// 菜单栏打开工具面板, object 是 `MacTool.rawValue`。
    static let primuseOpenMacTool = Notification.Name("primuse.mac.openTool")
    /// 菜单栏开关智能推荐面板。
    static let primuseToggleRecommendationsPanel = Notification.Name("primuse.mac.toggleRecommendations")
    /// 菜单栏打开听歌统计。
    static let primuseOpenListeningStats = Notification.Name("primuse.mac.openListeningStats")
}
#endif
