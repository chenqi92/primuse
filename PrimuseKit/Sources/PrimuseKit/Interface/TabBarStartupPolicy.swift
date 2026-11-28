import Foundation

/// 底部标签栏与系统迷你播放条在冷启动期间的稳定状态规则。
///
/// 在 iOS 26+ 液态玻璃标签栏上，当可见标签少于 4 个且系统底部附件（`tabViewBottomAccessory`）
/// 处于关闭状态时，标签栏会收缩为紧凑的短胶囊；等异步播放会话恢复完毕、底部附件再开启时，
/// 标签栏会被拉伸为全宽长胶囊，造成冷启动瞬间「短 → 长」跳变。
///
/// 若磁盘上已有持久化的播放会话且启动恢复尚未结束，冷启动首帧即保持底部附件占位开启，
/// 避免标签栏宽度和折叠策略在启动中途翻跳。
public enum TabBarStartupPolicy {
    /// 少于该数量时，无底部附件的液态玻璃标签栏呈紧凑短胶囊形态。
    public static let compactTabCountThreshold = 4

    /// iOS 26.1+ 系统底部附件（`tabViewBottomAccessory`）的挂载状态。
    public enum SystemBottomAccessoryState: Equatable, Sendable {
        case hidden
        case restoringPlaceholder
        case live

        public var isEnabled: Bool { self != .hidden }
        public var isInteractive: Bool { self == .live }
    }

    /// 当前标签数量是否属于紧凑短标签栏形态。
    public static func isCompactTabLayout(visibleTabCount: Int) -> Bool {
        visibleTabCount > 0 && visibleTabCount < compactTabCountThreshold
    }

    /// 同步探查磁盘上是否存在上次保存的播放会话文件（仅做存在性检查，不读内容）。
    public static func hasPersistedSession(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// 计算系统底部附件此刻的状态。
    /// - Parameters:
    ///   - hasLivePlayback: 当前已有真实在播/待续曲目（本机播放器或 Apple Music）。
    ///   - restorePhase: 启动播放会话恢复所处阶段。
    ///   - hasPersistedSession: 启动时磁盘上是否存在上次保存的播放会话。
    ///   - isSafeModeActive: 启动安全模式是否生效（安全模式会跳过恢复）。
    ///   - isSuppressedByOverlay: 批量选择或 CarPlay 编辑器是否正在占用底部区域。
    public static func systemBottomAccessoryState(
        hasLivePlayback: Bool,
        restorePhase: PlaybackSessionRestoreLifecycle.Phase,
        hasPersistedSession: Bool,
        isSafeModeActive: Bool,
        isSuppressedByOverlay: Bool
    ) -> SystemBottomAccessoryState {
        if isSuppressedByOverlay { return .hidden }
        if hasLivePlayback { return .live }
        guard !isSafeModeActive, hasPersistedSession else { return .hidden }
        switch restorePhase {
        case .pending, .restoring:
            return .restoringPlaceholder
        case .superseded, .completed:
            return .hidden
        }
    }

    /// 决定 `tabBarMinimizeBehavior` 是否采用 `.onScrollDown`。
    /// 与 `systemBottomAccessoryState.isEnabled` 同源，避免恢复完成时策略跟着翻转。
    public static func minimizesTabBarOnScroll(
        accessoryState: SystemBottomAccessoryState,
        pinsMiniPlayer: Bool,
        carPlayEditorActive: Bool
    ) -> Bool {
        accessoryState.isEnabled && !pinsMiniPlayer && !carPlayEditorActive
    }
}
