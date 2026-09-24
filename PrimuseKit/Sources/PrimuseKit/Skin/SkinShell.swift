import Foundation

// MARK: - 外壳

/// 一套皮肤的外壳:根导航用什么结构,正在播放的那条放在哪、画成什么。
///
/// 外壳决定整个 App 的骨架 —— 经典是系统标签栏,标签栏附件里一条迷你播放条;极简是顶部 tab 条,
/// 底部一条通栏停靠条。页面在外壳里怎么画由各个表面(`SkinSurface`)决定,外壳不管。
/// 一套新皮肤先定外壳,再逐个表面挑实现。
public struct SkinShell: Sendable, Hashable, Codable {
    /// 根导航的结构。
    public enum Navigation: String, CaseIterable, Sendable, Codable {
        /// 系统标签栏 + 各页自己的导航栏。
        case tabBar
        /// 顶部一行横向可滚的 tab 条(首页、资料库各分类、电台),右侧是页面动作、搜索与设置;
        /// 不显示标签栏,根页不显示系统导航栏,推入详情页时 tab 条让位给系统导航栏。
        case topTabs
    }

    /// 正在播放的那一条。三种画法收的是同一份数据(App 层的 `NowPlayingBarModel`),只换画法。
    public enum NowPlayingBar: String, CaseIterable, Sendable, Codable {
        /// 标签栏附件里的迷你条(iOS 26.1 起是系统附件,更早是贴在标签栏上沿的一条)。
        case tabAccessory
        /// 通栏停靠条:左右内缩的圆角条,封面 + 两行文字 + 播放键 + 队列键,顶沿一条进度细线。
        case dockedBar
        /// 悬浮胶囊:圆形封面、进度环、队列入口。现在没有皮肤选它,留给以后的皮肤。
        case floatingCapsule
    }

    public let navigation: Navigation
    public let nowPlayingBar: NowPlayingBar

    public init(navigation: Navigation, nowPlayingBar: NowPlayingBar) {
        self.navigation = navigation
        self.nowPlayingBar = nowPlayingBar
    }

    /// 经典外壳:系统标签栏 + 标签栏附件迷你条。
    public static let tabBar = SkinShell(navigation: .tabBar, nowPlayingBar: .tabAccessory)
    /// 极简外壳:顶部 tab 条 + 底部通栏停靠条。
    public static let topTabs = SkinShell(navigation: .topTabs, nowPlayingBar: .dockedBar)

    /// 这种导航结构能配哪些播放条。
    ///
    /// 标签栏只能配它自己的附件:停靠条或胶囊放在标签栏上面,两条底部 chrome 叠在一起。
    /// 顶部 tab 没有标签栏,附件无处可挂,只能配浮在页面之上的那两种。
    public static func nowPlayingBars(for navigation: Navigation) -> [NowPlayingBar] {
        switch navigation {
        case .tabBar: return [.tabAccessory]
        case .topTabs: return [.dockedBar, .floatingCapsule]
        }
    }

    /// 导航结构与播放条是不是一对能同时成立的组合。
    public var isValid: Bool {
        Self.nowPlayingBars(for: navigation).contains(nowPlayingBar)
    }
}
