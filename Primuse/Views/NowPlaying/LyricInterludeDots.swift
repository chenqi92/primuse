import SwiftUI
import PrimuseKit

/// 前奏与两句歌词之间的长间奏:三个点跟着间奏的时间依次点亮,下一句开始时正好全亮,开唱前
/// 那一小段跳两下(#315)。原来是系统省略号循环闪动、整行居中,和时间对不上,歌词靠左时也不跟着
/// 靠左(#198)。只有正在走的那一段显示并刷新(每秒约 20 次,心跳那不到一秒按屏幕刷新率);
/// 没轮到的间奏由所在的歌词列表收起,不显示也不占位置。暂停时停住;减弱动态效果时只按进度换亮度,
/// 不呼吸也不跳。iPhone、Mac 播放页与 Apple TV 歌词共用这一份,时间窗、点亮进度与心跳都取自
/// Kit `LyricPlaybackPositionPolicy`,三端只在尺寸和颜色上不同。
struct LyricInterludeDots: View {
    let isActive: Bool
    /// 暂停时进度停在原处,不再每秒重画二十次,也不呼吸。
    var isPlaying = true
    let phase: () -> LyricPlaybackPositionPolicy.InterludePhase
    let tint: Color
    let restingOpacity: Double
    var dotSize: CGFloat = 8
    var spacing: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var anticipationWindow: TimeInterval {
        LyricPlaybackPositionPolicy.InterludeTiming.standard.anticipation
    }

    var body: some View {
        let interval: TimeInterval = reduceMotion || !isPlaying ? 0.5 : 1.0 / 20
        TimelineView(.animation(minimumInterval: interval, paused: !isActive)) { context in
            let current = isActive ? phase() : .idle
            if isActive, isPlaying, !reduceMotion,
               current.secondsUntilNextLine <= anticipationWindow + 0.45 {
                // 开唱前那不到一秒的心跳按屏幕刷新率画,脉冲才不会一格一格地跳。
                TimelineView(.animation) { beat in
                    dots(phase: phase(), date: beat.date)
                }
            } else {
                dots(phase: current, date: context.date)
            }
        }
        .accessibilityHidden(true)
    }

    private func dots(phase: LyricPlaybackPositionPolicy.InterludePhase, date: Date) -> some View {
        let levels = isActive
            ? LyricPlaybackPositionPolicy.interludeDotLevels(progress: phase.progress)
            : [0, 0, 0]
        let animates = isActive && isPlaying && !reduceMotion
        // 呼吸在心跳前 0.4 秒内收掉,两种起伏不叠在一起,换过去也不跳一下。
        let breathAmplitude = animates
            ? 0.06 * min(max((phase.secondsUntilNextLine - anticipationWindow) / 0.4, 0), 1)
            : 0
        let breath = 1 + breathAmplitude * sin(date.timeIntervalSinceReferenceDate * 2.2)
        let heartbeat = animates
            ? LyricPlaybackPositionPolicy.interludeHeartbeatScale(secondsUntilNextLine: phase.secondsUntilNextLine)
            : 1
        let pulse = breath * heartbeat
        return HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(isActive ? 0.28 + 0.72 * levels[index] : restingOpacity)
                    .scaleEffect(isActive ? (0.82 + 0.18 * levels[index]) * pulse : 0.82)
            }
        }
    }
}
