#if os(iOS)
import PrimuseKit
import SwiftUI

/// 底部播放条的「悬浮胶囊」实现(`SkinSlotVariant.BottomChrome.floatingCapsule`)。
///
/// 功能契约与其它播放条完全一致 —— 点按打开播放页、左右滑切歌、播放 / 暂停、下一首 ——
/// 这些都来自共用的 `MiniPlayerSwipeContent`,这里只负责画法,并补上两样原来没有的东西:
/// 播放键外圈的进度环,和直接打开播放队列的入口。
struct FloatingCapsulePlayerBar: View {
    var onTap: () -> Void
    var onOpenQueue: () -> Void

    @Environment(\.skin) private var skin
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight: CGFloat = 44

    /// 大号无障碍字体下只留播放键,把宽度让给歌名。
    private var showsSecondaryControls: Bool { !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                onTap: onTap,
                artworkSize: 40,
                artworkCornerRadius: 20,
                artworkTrailingSpacing: 10,
                titleFont: .subheadline,
                showsSubtitle: true,
                contentHeight: contentHeight
            )

            FloatingCapsulePlayButton()

            if showsSecondaryControls {
                if !player.isLiveRadio || player.canSwitchRadioStation {
                    nextButton
                }
                if !player.isLiveRadio {
                    queueButton
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: 620)
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, skin.metric(.chromeHorizontalInset))
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var capsuleFill: some View {
        if reduceTransparency {
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
            Task { await player.next() }
        } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textPrimary))
        .accessibilityLabel(
            player.isLiveRadio
                ? String(localized: "radio_next_station")
                : String(localized: "a11y_next_track")
        )
    }

    private var queueButton: some View {
        Button(action: onOpenQueue) {
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

private struct FloatingCapsulePlayButton: View {
    @Environment(AudioPlayerService.self) private var player

    private var isStoppableRadio: Bool {
        player.isLiveRadio && (player.isPlaybackActive || player.isLoading)
    }

    private var symbolName: String {
        if isStoppableRadio { return "stop.fill" }
        return player.isPlaybackActive ? "pause.fill" : "play.fill"
    }

    private var label: String {
        if isStoppableRadio { return String(localized: "radio_stop") }
        return player.isPlaybackActive
            ? String(localized: "a11y_pause")
            : String(localized: "a11y_play")
    }

    var body: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                FloatingCapsuleProgressRing()
                if player.isLoading && !player.isLiveRadio {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.skin(.textPrimary))
        .disabled(player.isLoading && !player.isLiveRadio)
        .accessibilityLabel(label)
    }
}

/// 进度环单独成一个视图:`currentTime` 每半秒变一次,只让这一小块重绘,
/// 不牵连歌名、封面和整条播放条。
private struct FloatingCapsuleProgressRing: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.skin) private var skin

    private var fraction: CGFloat {
        let duration = player.duration
        let elapsed = player.currentTime
        guard !player.isLiveRadio, duration > 0, elapsed.isFinite else { return 0 }
        let ratio = min(max(elapsed / duration, 0), 1)
        return CGFloat(ratio)
    }

    var body: some View {
        let progress = fraction
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
