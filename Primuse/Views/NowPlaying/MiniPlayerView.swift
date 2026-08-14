#if os(iOS)
import SwiftUI
import PrimuseKit
import UIKit

struct MiniPlayerView: View {
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                onTap: { onTap?() },
                artworkSize: 40,
                artworkCornerRadius: 8,
                titleFont: .caption
            )

            MiniPlayerTransportControls(showsNextButton: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct MiniPlayerSwipeContent: View {
    var onTap: () -> Void
    var artworkSize: CGFloat
    var artworkCornerRadius: CGFloat
    var titleFont: Font

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var feedbackOffset: CGFloat = 0
    @State private var directionHint: MiniPlayerSwipeAction?
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: artworkSize,
                    cornerRadius: artworkCornerRadius,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath,
                    fileFormat: player.currentSong?.fileFormat,
                    revisionToken: player.coverRevision
                )
                .padding(.trailing, 10)

                Text(player.currentSong?.title ?? "")
                    .font(titleFont)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            contentWidth = width
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .simultaneousGesture(swipeGesture(containerWidth: contentWidth))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(String(localized: "now_playing")): \(player.currentSong?.title ?? "")"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
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
                await player.previous()
            case .next:
                await player.next()
            }
            if didAdvance {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }
}

struct MiniPlayerTransportControls: View {
    var isInline = false
    var showsNextButton: Bool
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        HStack(spacing: isInline ? 0 : 4) {
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Image(systemName: "play.fill")
                        .font(isInline ? .subheadline : .body)
                        .opacity(0)
                    if player.isLoading && !player.isLiveRadio {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isLiveRadio && (player.isPlaybackActive || player.isLoading)
                            ? "stop.fill"
                            : (player.isPlaybackActive ? "pause.fill" : "play.fill"))
                            .font(isInline ? .subheadline : .body)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(player.isLoading && !player.isLiveRadio)
            .accessibilityLabel(player.isLiveRadio && (player.isPlaybackActive || player.isLoading)
                ? String(localized: "radio_stop")
                : (player.isPlaybackActive
                    ? String(localized: "a11y_pause")
                    : String(localized: "a11y_play")))

            if showsNextButton && (!player.isLiveRadio || player.canSwitchRadioStation) {
                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.caption)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isLiveRadio
                    ? String(localized: "radio_next_station")
                    : String(localized: "a11y_next_track"))
            }
        }
        .fixedSize()
    }
}
#endif
