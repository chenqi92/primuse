import Foundation

/// Separates taps on rendered lyric rows from taps on unused lyric-surface
/// space. SwiftUI delivers the child and parent gestures in the same event
/// cycle, so a short window prevents a row seek from also switching surfaces.
public enum LyricsBackgroundTapPolicy {
    public static let rowSuppressionInterval: TimeInterval = 0.08
    /// 按住让惯性滚动停下、或刚松手就点的那一下是在操作滚动，不是在点空白。
    public static let scrollSuppressionInterval: TimeInterval = 0.5
    /// 按住超过这么久就算长按：用户是想按住拖歌词，松手不回封面。
    public static let longPressDuration: TimeInterval = 0.35
    /// 长按识别之后这段时间内松手的那一下都不算点空白（按得再久也少有超过这个）。
    public static let longPressSuppressionInterval: TimeInterval = 8

    /// - Parameter showsLyricsSurface: 歌词、加载占位或「暂无歌词」那一页正显示着。没歌词时点空白
    ///   同样回封面(#348),那一页的按钮自己按 `rowTapTimeDistance` 挡掉;只有有声内容还没有文字稿
    ///   时那一页(生成、导入文字稿的面板)不算。
    public static func shouldHandle(
        showsLyricsSurface: Bool,
        isPinching: Bool,
        rowTapTimeDistance: TimeInterval,
        timeSinceUserScroll: TimeInterval = .infinity,
        timeSinceLongPress: TimeInterval = .infinity
    ) -> Bool {
        showsLyricsSurface
            && !isPinching
            && abs(rowTapTimeDistance) > rowSuppressionInterval
            && abs(timeSinceUserScroll) > scrollSuppressionInterval
            && !(timeSinceLongPress >= 0 && timeSinceLongPress < longPressSuppressionInterval)
    }
}
