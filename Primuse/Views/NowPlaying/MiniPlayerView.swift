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

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title)
                        .font(titleFont)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .foregroundStyle(.skin(.textPrimary))
                        .contentTransition(.opacity)

                    if showsSubtitle, let subtitle = model.subtitle {
                        switch subtitle {
                        case .error(let error):
                            // A song picked from a list can fail with the player
                            // closed; this line is the only place left to say why.
                            Text(verbatim: error)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.orange)
                                .contentTransition(.opacity)
                        case .artist(let artist):
                            Text(artist)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.skin(.textSecondary))
                                .contentTransition(.opacity)
                        }
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

    private func swipeGesture(containerWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: MiniPlayerSwipePolicy.minimumGestureDistance)
            .onChanged { value in
                let sample = swipeSample(value, containerWidth: containerWidth)
                directionHint = MiniPlayerSwipePolicy.directionHint(for: sample)
                feedbackOffset = MiniPlayerSwipePolicy.feedbackOffset(
                    for: sample,
                    reduceMotion: reduceMotion
                )
            }
            .onEnded { value in
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

/// 附件迷你条右侧的播放 / 暂停与下一首(有声内容是前进 30 秒)。
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

            // 有声内容按「前进 30 秒」用: 下一条目是另一本书或另一集,
            // 在迷你播放器上误触的代价比漏听一段大得多。
            if model.isSpokenWord, !model.isLiveRadio {
                Button {
                    model.skipSpokenWordForward()
                } label: {
                    Image(systemName: model.spokenWordSkipForwardSymbol)
                        .font(iconFont)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(String(localized: "a11y_skip_forward"))
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
