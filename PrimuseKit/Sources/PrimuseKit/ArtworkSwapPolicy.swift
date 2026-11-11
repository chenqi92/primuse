import Foundation

/// 播放页大封面换歌时往哪边换。
public enum ArtworkSwapDirection: Equatable, Sendable {
    /// 下一首:旧封面往前(左)退,新封面从后(右)进。
    case forward
    /// 上一首:反过来。
    case backward
}

/// 一次换歌的封面动作:方向,以及是不是「自己播完换的」(那种更柔)。
public struct ArtworkSwapStyle: Equatable, Sendable {
    public let direction: ArtworkSwapDirection
    /// 自然播完接到下一首,不是用户按的。
    public let isGentle: Bool

    public init(direction: ArtworkSwapDirection, isGentle: Bool) {
        self.direction = direction
        self.isGentle = isGentle
    }
}

/// 判断一次换歌在播放页大封面上该怎么换。
///
/// 只认两种来路,其余(从列表点一首、换了整个队列、从队列里跳着点)都返回 nil,
/// 照旧原地交叉淡入:
/// - 用户刚按过下一首 / 上一首(播放器在 `next()` / `previous()` 里记下的意图,
///   在 `intentLifetime` 内有效):按意图的方向,干脆利落。
/// - 没有意图,但换到的正是上次记下的「接下来那首」:自然播完,同一方向但更柔;
///   换到的正是「前一首」(比如别处发来的上一首命令):往回换。
public enum ArtworkSwapPolicy {
    /// 按下键到换上新歌之间可能要准备淡入淡出、取远端文件,留足余量;
    /// 超过这么久还没换,就不再认这次按键。
    public static let intentLifetime: TimeInterval = 4

    public static func style(
        newSongID: String?,
        predictedNextID: String?,
        predictedPreviousID: String?,
        manualIntent: ArtworkSwapDirection?,
        intentAge: TimeInterval?
    ) -> ArtworkSwapStyle? {
        guard let newSongID, !newSongID.isEmpty else { return nil }
        if let manualIntent, let intentAge,
           intentAge >= 0, intentAge <= intentLifetime {
            return ArtworkSwapStyle(direction: manualIntent, isGentle: false)
        }
        if newSongID == predictedNextID {
            return ArtworkSwapStyle(direction: .forward, isGentle: true)
        }
        if newSongID == predictedPreviousID {
            return ArtworkSwapStyle(direction: .backward, isGentle: false)
        }
        return nil
    }

    /// 旧封面退场的水平位移(按封面宽度的比例,正数朝后/右)。新封面入场从反方向同样距离进来。
    /// 从右到左的版面整体镜像。
    public static func exitOffsetFraction(
        for direction: ArtworkSwapDirection,
        isRightToLeft: Bool
    ) -> Double {
        let magnitude = 0.32
        let forwardSign: Double = isRightToLeft ? 1 : -1
        return direction == .forward ? magnitude * forwardSign : -magnitude * forwardSign
    }
}
