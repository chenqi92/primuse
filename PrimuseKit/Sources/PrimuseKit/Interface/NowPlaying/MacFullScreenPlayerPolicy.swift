import Foundation

// MARK: - Mac 全屏播放

/// macOS「全屏播放」的进出规则。
///
/// 全屏播放只有一个开关:进去就是系统全屏加上选定的全屏效果(「原生」也是其中一种),
/// 退出回到进来之前那一页 —— 从资料库进来的,退出时顺手收起播放页,不先露一下窗口版播放页;
/// 进来时也不先展开窗口版播放页再变全屏。
public enum MacFullScreenPlayerPolicy {
    /// 底栏「全屏播放」键按下去做什么。
    public enum EntryControlAction: Equatable, Sendable {
        /// 在按钮上方展开全屏效果面板,点哪一张就带着它进全屏。
        case presentEffectPicker
        /// 没有效果可选,直接进全屏。
        case enterDirectly
    }

    /// 全屏效果只给正在放的音乐:电台没有沉浸展示;有声内容不给效果(和 iPhone 一样),
    /// 全屏时是书封与目录、文稿那一版。
    public static func offersEffects(
        hasCurrentSong: Bool,
        isLiveRadio: Bool,
        isSpokenWord: Bool
    ) -> Bool {
        hasCurrentSong && !isLiveRadio && !isSpokenWord
    }

    /// MV 在放时全屏铺的是画面本身,选效果没有意义,也直接进。
    public static func entryControlAction(
        hasCurrentSong: Bool,
        isLiveRadio: Bool,
        isSpokenWord: Bool,
        isPlayingMusicVideo: Bool
    ) -> EntryControlAction {
        let offers = offersEffects(
            hasCurrentSong: hasCurrentSong,
            isLiveRadio: isLiveRadio,
            isSpokenWord: isSpokenWord
        )
        return offers && !isPlayingMusicVideo ? .presentEffectPicker : .enterDirectly
    }

    public enum ToggleAction: Equatable, Sendable {
        case enter
        case exit
    }

    /// ⌃⌘F 与菜单栏:正在全屏播放就退出,否则进入。窗口全屏但播放页收着(点绿灯进的资料库全屏)
    /// 不算在全屏播放。
    public static func toggleAction(isWindowFullScreen: Bool, isPlayerExpanded: Bool) -> ToggleAction {
        isWindowFullScreen && isPlayerExpanded ? .exit : .enter
    }

    /// 进全屏播放之前停在哪儿。
    public struct ReturnPoint: Equatable, Sendable {
        public let windowWasFullScreen: Bool
        public let playerWasExpanded: Bool
        public let queueWasPresented: Bool
        public let recommendationsWerePresented: Bool

        public init(
            windowWasFullScreen: Bool,
            playerWasExpanded: Bool,
            queueWasPresented: Bool,
            recommendationsWerePresented: Bool
        ) {
            self.windowWasFullScreen = windowWasFullScreen
            self.playerWasExpanded = playerWasExpanded
            self.queueWasPresented = queueWasPresented
            self.recommendationsWerePresented = recommendationsWerePresented
        }
    }

    /// 又一次进入时记哪一份。窗口还在全屏里(全屏播放中点专辑名回到资料库,又从底栏进来)接着用
    /// 最早那份,退出才回得到真正进来之前的地方;窗口版里留着的那份已经过时(上次没进成),换成眼前的。
    public static func returnPoint(
        existing: ReturnPoint?,
        current: ReturnPoint,
        isWindowFullScreen: Bool
    ) -> ReturnPoint {
        if isWindowFullScreen, let existing { return existing }
        return current
    }

    public enum ExitRoute: Equatable, Sendable {
        /// 退出系统全屏;窗口开始退出时按返回点收拾。
        case leaveSystemFullScreen
        /// 进来之前窗口就在全屏里、播放页收着(资料库全屏):留在全屏,只收起播放页。
        case stayInSystemFullScreen
    }

    public static func exitRoute(returnPoint: ReturnPoint?) -> ExitRoute {
        guard let returnPoint,
              returnPoint.windowWasFullScreen,
              !returnPoint.playerWasExpanded else { return .leaveSystemFullScreen }
        return .stayInSystemFullScreen
    }

    /// 退出后各处该是什么样。队列和推荐在同一个位置,一次只开一个,队列优先。
    public struct Restoration: Equatable, Sendable {
        public let collapsesPlayer: Bool
        public let showsQueue: Bool
        public let showsRecommendations: Bool

        public init(collapsesPlayer: Bool, showsQueue: Bool, showsRecommendations: Bool) {
            self.collapsesPlayer = collapsesPlayer
            self.showsQueue = showsQueue
            self.showsRecommendations = showsRecommendations
        }
    }

    public static func restoration(for returnPoint: ReturnPoint) -> Restoration {
        Restoration(
            collapsesPlayer: !returnPoint.playerWasExpanded,
            showsQueue: returnPoint.queueWasPresented,
            showsRecommendations: returnPoint.recommendationsWerePresented && !returnPoint.queueWasPresented
        )
    }

    /// 请求窗口进系统全屏之后,多久之内开始的全屏算这次请求的(要在那一刻装上播放页)。
    /// `toggleFullScreen` 静默没进成时请求不会一直挂着,之后点绿灯进全屏仍是普通的窗口全屏。
    public static let entryRequestLifetime: TimeInterval = 3

    public static func isEntryRequestPending(requestedAt: Date?, now: Date) -> Bool {
        guard let requestedAt else { return false }
        let elapsed = now.timeIntervalSince(requestedAt)
        return elapsed >= 0 && elapsed <= entryRequestLifetime
    }
}
