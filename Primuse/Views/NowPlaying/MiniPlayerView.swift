#if os(iOS)
import SwiftUI
import PrimuseKit
import UIKit

/// 标签栏附件迷你条在 iOS 26.1 之前的画法:贴在标签栏上沿的一条(`LegacyNowPlayingAccessory`)。
struct MiniPlayerView: View {
    let model: NowPlayingBarModel
    var showsNextButton = true
    var showsSubtitle = false

    @Environment(\.pmHeightClass) private var heightClass
    /// 固定条高跟随 Dynamic Type，与 PadNowPlayingAccessory 一致。
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                model: model,
                artworkSize: 30,
                artworkCornerRadius: 6,
                artworkTrailingSpacing: 8,
                titleFont: .subheadline,
                showsSubtitle: showsSubtitle,
                contentHeight: contentHeight
            )

            MiniPlayerTransportControls(model: model, showsNextButton: showsNextButton)
        }
        .padding(.horizontal, 16)
        // 手机横屏只收上下留白。条高由 ScaledMetric 决定、传输键仍是 44×44 命中区，
        // 两者都不动，省下来的是纯粹的余白。
        .padding(.vertical, heightClass.value(6, compact: 3))
    }
}

/// 播放条里「封面 + 歌名」那一块:点按打开播放页、左右滑切歌、无障碍动作都在这里。
/// 外壳的三种播放条都用它,数据与动作全部来自 `NowPlayingBarModel`。
struct MiniPlayerSwipeContent: View {
    let model: NowPlayingBarModel
    var artworkSize: CGFloat
    var artworkCornerRadius: CGFloat
    var artworkTrailingSpacing: CGFloat = 10
    var titleFont: Font
    var showsSubtitle = false
    var contentHeight: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var feedbackOffset: CGFloat = 0
    @State private var directionHint: MiniPlayerSwipeAction?
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let artwork = model.artwork
        ZStack {
            HStack(spacing: 0) {
                if model.isSpokenWordBook {
                    // 书是竖的:同一块槽位里放 3:4 的书封。
                    SpokenWordBookCover(
                        song: model.currentSong,
                        width: SpokenWordCoverLayout.width(forHeight: artworkSize),
                        cornerRadius: max(3, artworkCornerRadius * 0.6),
                        decodeSize: artworkSize * 2
                    )
                    .frame(width: artworkSize, height: artworkSize)
                    .padding(.trailing, artworkTrailingSpacing)
                } else {
                    CachedArtworkView(
                        coverRef: artwork.coverRef,
                        songID: artwork.songID,
                        size: artworkSize,
                        cornerRadius: artworkCornerRadius,
                        sourceID: artwork.sourceID,
                        filePath: artwork.filePath,
                        fileFormat: artwork.fileFormat,
                        revisionToken: artwork.revisionToken
                    )
                    .artworkCrossfade()
                    .padding(.trailing, artworkTrailingSpacing)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(titleFont)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .foregroundStyle(.skin(.textPrimary))
                        .contentTransition(.opacity)

                    let subtitle = showsSubtitle ? model.subtitle : nil
                    if case .error(let error)? = subtitle {
                        // A song picked from a list can fail with the player
                        // closed; this line is the only place left to say why.
                        Text(verbatim: error)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.orange)
                            .contentTransition(.opacity)
                    } else if model.isSpokenWordBook {
                        // 有声内容总带这一行:第几章、本章还剩多久。书名已经在上面了。
                        MiniPlayerSpokenWordSubtitle(model: model)
                    } else if case .artist(let artist)? = subtitle {
                        Text(artist)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.skin(.textSecondary))
                            .contentTransition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pmAnimation(.trackChange, value: model.songID)
            }
            .offset(x: feedbackOffset)

            if let directionHint {
                Image(systemName: directionHint == .next ? "forward.fill" : "backward.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: directionHint == .next ? .trailing : .leading)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            contentWidth = width
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: model.onTap)
        .simultaneousGesture(swipeGesture(containerWidth: contentWidth))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilityLabel(includesSubtitle: showsSubtitle))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onTap() }
        .accessibilityAction(named: Text("a11y_previous_track")) {
            perform(.previous)
        }
        .accessibilityAction(named: Text("a11y_next_track")) {
            perform(.next)
        }
    }

    private var allowsSwipe: Bool {
        model.listeningSpace != .spokenWord
    }

    private func swipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: MiniPlayerSwipePolicy.minimumGestureDistance)
            .onChanged { value in
                // 有声内容不滑动换条目:下一条是另一集甚至另一本,误触代价太大。
                guard allowsSwipe else { return }
                let sample = swipeSample(value, containerWidth: containerWidth)
                directionHint = MiniPlayerSwipePolicy.directionHint(for: sample)
                feedbackOffset = MiniPlayerSwipePolicy.feedbackOffset(
                    for: sample,
                    reduceMotion: reduceMotion
                )
            }
            .onEnded { value in
                guard allowsSwipe else { return }
                let action = MiniPlayerSwipePolicy.action(
                    for: swipeSample(value, containerWidth: containerWidth)
                )
                resetFeedback()
                if let action {
                    perform(action)
                }
            }
    }

    private func swipeSample(
        _ value: DragGesture.Value,
        containerWidth: CGFloat
    ) -> MiniPlayerSwipeSample {
        MiniPlayerSwipeSample(
            translationX: value.translation.width,
            translationY: value.translation.height,
            velocityX: value.velocity.width,
            velocityY: value.velocity.height,
            startX: value.startLocation.x,
            containerWidth: containerWidth,
            isRightToLeft: layoutDirection == .rightToLeft
        )
    }

    private func resetFeedback() {
        if reduceMotion {
            feedbackOffset = 0
            directionHint = nil
        } else {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                feedbackOffset = 0
                directionHint = nil
            }
        }
    }

    private func perform(_ action: MiniPlayerSwipeAction) {
        Task { @MainActor in
            let didAdvance = switch action {
            case .previous:
                await model.previous()
            case .next:
                await model.next()
            }
            if didAdvance {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }
}

/// 迷你条上有声内容的第二行:「第 12 章 · 本章还剩约 18 分钟」。单独一个视图,
/// 播放时钟的高频刷新只落在这一行上。
private struct MiniPlayerSpokenWordSubtitle: View {
    let model: NowPlayingBarModel

    var body: some View {
        Text(verbatim: model.spokenWordPartLine)
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .foregroundStyle(.skin(.textSecondary))
            .contentTransition(.opacity)
    }
}

/// 附件迷你条右侧的播放 / 暂停与下一首(有声内容是播放键前的「后退」)。
struct MiniPlayerTransportControls: View {
    let model: NowPlayingBarModel
    var isInline = false
    var showsNextButton: Bool
    var regularIconSize: CGFloat = 20

    private var iconFont: Font {
        isInline ? .subheadline : .system(size: regularIconSize, weight: .semibold)
    }

    var body: some View {
        HStack(spacing: isInline ? 0 : 4) {
            // 有声内容在播放键前放「后退」:漏听一句往回倒是听书最常按的键。
            // 前进与下一条目都不放 —— 下一条目是另一集甚至另一本,迷你条上误触代价太大。
            if model.isSpokenWordBook {
                Button {
                    model.skipSpokenWordBackward()
                } label: {
                    Image(systemName: model.spokenWordSkipBackwardSymbol)
                        .font(iconFont)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(String(localized: "a11y_skip_backward"))
            }

            Button {
                model.togglePlayPause()
            } label: {
                ZStack {
                    Image(systemName: "play.fill")
                        .font(iconFont)
                        .opacity(0)
                    if model.isLoading && !model.isLiveRadio {
                        ProgressView().controlSize(.small)
                            .pmFadeTransition(motion: .control)
                    } else {
                        Image(systemName: model.isLiveRadio && (model.isPlaying || model.isLoading)
                            ? "stop.fill"
                            : (model.isPlaying ? "pause.fill" : "play.fill"))
                            .font(iconFont)
                            .contentTransition(.symbolEffect(.replace))
                            // ProgressView 与 Image 之间 symbolEffect 不生效, 这一跳只能走透明度。
                            .pmFadeTransition(motion: .control)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(model.isLoading && !model.isLiveRadio)
            .accessibilityLabel(model.isLiveRadio && (model.isPlaying || model.isLoading)
                ? String(localized: "radio_stop")
                : (model.isPlaying
                    ? String(localized: "a11y_pause")
                    : String(localized: "a11y_play")))

            if model.isSpokenWordBook {
                EmptyView()
            } else if showsNextButton && (!model.isLiveRadio || model.canSwitchRadioStation) {
                Button {
                    Task { await model.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(iconFont)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(model.isLiveRadio
                    ? String(localized: "radio_next_station")
                    : String(localized: "a11y_next_track"))
            }
        }
        .fixedSize()
    }
}
#endif
