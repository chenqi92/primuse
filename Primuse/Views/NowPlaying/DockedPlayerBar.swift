#if os(iOS)
import PrimuseKit
import SwiftUI

/// 底部播放条的「通栏停靠条」实现(`SkinShell.NowPlayingBar.dockedBar`)。
///
/// 功能契约与其它播放条一致 —— 只收 `NowPlayingBarModel`:点按打开播放页、左右滑切歌、无障碍动作
/// 都来自共用的 `MiniPlayerSwipeContent`,播放键沿用悬浮胶囊那颗(加载圈与播放键之间淡入淡出);
/// 这里只负责画法:左右内缩的圆角条,顶沿一条进度细线,右侧是播放键和队列键。
/// 右侧第二颗键随听法变:音乐是队列,有声是前进 30 秒(下一条是另一集甚至另一本,不给切),电台没有。
/// 手机横屏与折叠屏内屏这类宽视口里最宽 560、居中(`DockedPlayerBarLayoutPolicy`),
/// 进度线、点击热区与滑动切歌都在条子里,跟着一起收窄;竖屏 iPhone 仍铺满整行。
struct DockedPlayerBar: View {
    let model: NowPlayingBarModel

    @Environment(\.skin) private var skin
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
                model: model,
                artworkSize: isCompactHeight ? 36 : 44,
                artworkCornerRadius: 8,
                artworkTrailingSpacing: 12,
                titleFont: .subheadline,
                showsSubtitle: true,
                contentHeight: contentHeight
            )

            FloatingCapsulePlayButton(model: model, showsProgressRing: false)

            if model.isSpokenWord, !model.isLiveRadio {
                skipForwardButton
            } else if !model.isLiveRadio {
                queueButton
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, isCompactHeight ? 4 : 10)
        .background { barFill(shape) }
        .overlay {
            if !model.isLiveRadio {
                DockedPlayerProgressLine(model: model)
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

    private var skipForwardButton: some View {
        Button(action: model.skipSpokenWordForward) {
            Image(systemName: model.spokenWordSkipForwardSymbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textSecondary))
        .accessibilityLabel(Text("a11y_skip_forward"))
        .accessibilityIdentifier("dockedBar.skipForward")
    }

    private var queueButton: some View {
        Button(action: model.onOpenQueue) {
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
    let model: NowPlayingBarModel
    @Environment(\.skin) private var skin
    /// 上一次画到的比例,只用来判断这次变化是不是一次普通的时钟推进。
    @State private var previousProgress: CGFloat = 0

    /// 正常推进时用引擎采样间隔同样时长的线性动画补平;换歌、拖动、跳转都硬跳
    /// (`NowPlayingBarPresentationPolicy.isClockAdvance`)。
    private func fillAnimation(for progress: CGFloat) -> Animation? {
        guard !skin.reduceMotion,
              NowPlayingBarPresentationPolicy.isClockAdvance(
                from: Double(previousProgress),
                to: Double(progress),
                duration: model.duration
              ) else { return nil }
        return .linear(duration: 0.5)
    }

    var body: some View {
        let progress = CGFloat(model.progress)
        GeometryReader { proxy in
            Rectangle()
                // 有声的进度用它自己的颜色,和条上的小圆点一致;音乐跟随强调色。
                .fill(model.listeningSpace == .spokenWord ? ListeningSpace.spokenWord.tint : skin.color(.accent))
                .frame(width: proxy.size.width * progress, height: 2)
                .animation(fillAnimation(for: progress), value: progress)
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
