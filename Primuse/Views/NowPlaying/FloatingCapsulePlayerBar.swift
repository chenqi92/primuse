#if os(iOS)
import PrimuseKit
import SwiftUI

/// 底部播放条的「悬浮胶囊」实现(`SkinShell.NowPlayingBar.floatingCapsule`)。
/// 现在没有皮肤选它(极简用的是 `DockedPlayerBar`),留作以后皮肤的外壳播放条。
///
/// 功能契约与其它播放条完全一致 —— 只收 `NowPlayingBarModel`:点按打开播放页、左右滑切歌、
/// 播放 / 暂停、下一首都来自那里与共用的 `MiniPlayerSwipeContent`,这里只负责画法,并补上两样
/// 附件迷你条没有的东西:播放键外圈的进度环,和直接打开播放队列的入口。
struct FloatingCapsulePlayerBar: View {
    let model: NowPlayingBarModel

    @Environment(\.skin) private var skin
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pmHeightClass) private var heightClass
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight: CGFloat = 44

    /// 大号无障碍字体下只留播放键,把宽度让给歌名。
    private var showsSecondaryControls: Bool { !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        // 手机横屏下胶囊收窄并靠向尾侧,和极简皮肤的播放条一个口径:横贯七百多点的
        // 一条板会把只剩三百多点的版面压得更死,让开之后左侧内容仍然看得见。
        let capsuleWidth = heightClass.value(620, compact: 380)
        let capsuleAlignment = heightClass.pick(Alignment.center, compact: .trailing)
        return HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                model: model,
                artworkSize: 40,
                artworkCornerRadius: 20,
                artworkTrailingSpacing: 10,
                titleFont: .subheadline,
                showsSubtitle: true,
                contentHeight: contentHeight
            )

            FloatingCapsulePlayButton(model: model)

            if showsSecondaryControls {
                if !model.isLiveRadio || model.canSwitchRadioStation {
                    nextButton
                }
                if !model.isLiveRadio {
                    queueButton
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: capsuleWidth)
        .background { capsuleFill }
        .overlay {
            Capsule()
                .strokeBorder(skin.color(.chromeBorder), lineWidth: skin.rawMetric(.borderWidth))
                .allowsHitTesting(false)
        }
        .contentShape(Capsule())
        .shadow(
            color: Color.black.opacity(Double(skin.rawMetric(.shadowOpacity))),
            radius: skin.rawMetric(.shadowRadius),
            y: 8
        )
        .frame(maxWidth: .infinity, alignment: capsuleAlignment)
        .padding(.horizontal, skin.metric(.chromeHorizontalInset))
        .padding(.top, heightClass.value(6, compact: 4))
        .padding(.bottom, heightClass.value(8, compact: 6))
    }

    @ViewBuilder
    private var capsuleFill: some View {
        if reduceTransparency || skin.usesSolidChrome {
            Capsule().fill(skin.color(.canvasElevated))
        } else {
            // 样式的半透明底色叠在模糊之上:底下滚过的封面只透出一点颜色,文字始终可读。
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(skin.color(.chromeBackground))
            }
        }
    }

    private var nextButton: some View {
        Button {
            Task { await model.next() }
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textPrimary))
        .accessibilityLabel(
            model.isLiveRadio
                ? String(localized: "radio_next_station")
                : String(localized: "a11y_next_track")
        )
    }

    private var queueButton: some View {
        Button(action: model.onOpenQueue) {
            Image(systemName: "list.bullet")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textSecondary))
        .accessibilityLabel(Text("queue_title"))
    }
}

/// 播放 / 暂停键:加载中是转圈,转圈与播放键之间淡入淡出。停靠条也用这一颗(不带进度环)。
struct FloatingCapsulePlayButton: View {
    let model: NowPlayingBarModel
    /// 外圈画进度环(悬浮胶囊);停靠条的进度在顶沿细线上,不要环。
    var showsProgressRing = true

    private var isStoppableRadio: Bool {
        model.isLiveRadio && (model.isPlaying || model.isLoading)
    }

    private var symbolName: String {
        if isStoppableRadio { return "stop.fill" }
        return model.isPlaying ? "pause.fill" : "play.fill"
    }

    private var label: String {
        if isStoppableRadio { return String(localized: "radio_stop") }
        return model.isPlaying
            ? String(localized: "a11y_pause")
            : String(localized: "a11y_play")
    }

    var body: some View {
        Button {
            model.togglePlayPause()
        } label: {
            ZStack {
                if showsProgressRing {
                    FloatingCapsuleProgressRing(model: model)
                }
                if model.isLoading && !model.isLiveRadio {
                    ProgressView().controlSize(.small)
                        .pmFadeTransition(motion: .control)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        // ProgressView 与 Image 之间 symbolEffect 不生效, 这一跳只能走透明度。
                        .pmFadeTransition(motion: .control)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textPrimary))
        .disabled(model.isLoading && !model.isLiveRadio)
        .accessibilityLabel(label)
    }
}

/// 进度环单独成一个视图:`currentTime` 每半秒变一次,只让这一小块重绘,
/// 不牵连歌名、封面和整条播放条。
private struct FloatingCapsuleProgressRing: View {
    let model: NowPlayingBarModel
    @Environment(\.skin) private var skin

    var body: some View {
        let progress = CGFloat(model.progress)
        ZStack {
            Circle()
                .stroke(skin.color(.textQuaternary), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(skin.color(.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 36, height: 36)
        // 引擎每半秒报一次进度,用同样时长的线性动画把两次采样之间补平。
        .animation(skin.reduceMotion ? nil : .linear(duration: 0.5), value: progress)
        .accessibilityHidden(true)
    }
}
#endif
