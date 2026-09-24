#if os(iOS)
import PrimuseKit
import SwiftUI

/// 底部播放条的「通栏停靠条」实现(`SkinSlotVariant.BottomChrome.dockedBar`)。
///
/// 功能契约与其它播放条一致 —— 点按打开播放页、左右滑切歌、无障碍动作都来自共用的
/// `MiniPlayerSwipeContent`,播放键沿用悬浮胶囊那颗(加载圈与播放键之间淡入淡出);
/// 这里只负责画法:左右内缩的圆角条,顶沿一条进度细线,右侧是播放键和队列键。
/// 手机横屏与折叠屏内屏这类宽视口里最宽 560、居中(`DockedPlayerBarLayoutPolicy`),
/// 进度线、点击热区与滑动切歌都在条子里,跟着一起收窄;竖屏 iPhone 仍铺满整行。
struct DockedPlayerBar: View {
    var onTap: () -> Void
    var onOpenQueue: () -> Void

    @Environment(\.skin) private var skin
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.pmHeightClass) private var heightClass
    /// 封面与两行文字那一块的高度,随字号放大;竖屏条高 = 它 + 上下各 10,横屏上下各 4。
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight: CGFloat = 44

    private static let cornerRadius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let isCompactHeight = heightClass.isCompact
        HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                onTap: onTap,
                artworkSize: isCompactHeight ? 36 : 44,
                artworkCornerRadius: 8,
                artworkTrailingSpacing: 12,
                titleFont: .subheadline,
                showsSubtitle: true,
                contentHeight: contentHeight
            )

            FloatingCapsulePlayButton(showsProgressRing: false)

            if !player.isLiveRadio {
                queueButton
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, isCompactHeight ? 4 : 10)
        .background { barFill(shape) }
        .overlay {
            if !player.isLiveRadio {
                DockedPlayerProgressLine()
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            shape
                .strokeBorder(skin.color(.chromeBorder), lineWidth: skin.rawMetric(.borderWidth))
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .shadow(
            color: Color.black.opacity(Double(skin.rawMetric(.shadowOpacity)) * 0.6),
            radius: skin.rawMetric(.shadowRadius) * 0.75,
            y: 6
        )
        .frame(maxWidth: CGFloat(DockedPlayerBarLayoutPolicy.maximumWidth))
        .padding(.horizontal, CGFloat(DockedPlayerBarLayoutPolicy.horizontalInset))
        .padding(.top, isCompactHeight ? 4 : 6)
        .padding(.bottom, isCompactHeight ? 4 : 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func barFill(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency || skin.usesSolidChrome {
            shape.fill(skin.color(.canvasElevated))
        } else {
            // 与 tab 条同一种材质:模糊之上叠一层样式自己的半透明底色。
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(skin.color(.chromeBackground))
            }
        }
    }

    private var queueButton: some View {
        Button(action: onOpenQueue) {
            Image(systemName: "list.bullet")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textSecondary))
        .accessibilityLabel(Text("queue_title"))
        .accessibilityIdentifier("dockedBar.queue")
    }
}

/// 停靠条顶沿的进度细线。单独成一个视图:`currentTime` 每半秒变一次,只让这一条重绘。
private struct DockedPlayerProgressLine: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.skin) private var skin
    /// 上一次画到的比例,只用来判断这次变化是不是一次普通的时钟推进。
    @State private var previousProgress: CGFloat = 0

    private var duration: Double {
        let duration = player.duration
        return duration.isFinite && duration > 0 ? duration : 0
    }

    private var progress: CGFloat {
        let elapsed = player.currentTime
        guard duration > 0, elapsed.isFinite else { return 0 }
        return CGFloat(min(max(elapsed / duration, 0), 1))
    }

    /// 引擎每半秒报一次进度,正常推进时用同样时长的线性动画补平两次采样之间;
    /// 换歌、拖动、跳转都硬跳 —— 否则换歌时细线会从上一首的位置一路倒扫回起点。
    private var fillAnimation: Animation? {
        guard !skin.reduceMotion, duration > 0 else { return nil }
        let advanced = Double(progress - previousProgress) * duration
        guard advanced > 0, advanced <= 1 else { return nil }
        return .linear(duration: 0.5)
    }

    var body: some View {
        let progress = progress
        GeometryReader { proxy in
            Rectangle()
                .fill(skin.color(.accent))
                .frame(width: proxy.size.width * progress, height: 2)
                .animation(fillAnimation, value: progress)
        }
        .frame(height: 2)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: progress) { _, updated in
            previousProgress = updated
        }
        .accessibilityHidden(true)
    }
}
#endif
