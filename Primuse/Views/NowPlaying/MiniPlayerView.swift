#if os(iOS)
import SwiftUI
import PrimuseKit
import UIKit

struct MiniPlayerView: View {
    var onTap: (() -> Void)? = nil
    @AppStorage(PrimuseAppSkin.storageKey)
    private var appSkinRawValue = PrimuseAppSkin.system.rawValue

    @ViewBuilder
    var body: some View {
        if PrimuseAppSkin(rawValue: appSkinRawValue) == .nocturne {
            NocturneMiniPlayerContent(
                onTap: { onTap?() },
                isInline: false,
                showsNextButton: true
            )
        } else {
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
}

struct NocturneMiniPlayerContent: View {
    let onTap: () -> Void
    let isInline: Bool
    let showsNextButton: Bool

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioVisualizerService.self) private var visualizer

    private var stripColor: Color {
        PrimuseNocturnePalette.stripColor(for: player.currentSong?.id ?? "primuse")
    }

    private var liveLevels: [Float] {
        visualizer.bandLevels
    }

    var body: some View {
        HStack(spacing: isInline ? 9 : 12) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.9), stripColor, PrimuseNocturnePalette.peach],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4, height: isInline ? 28 : 42)

            VStack(alignment: .leading, spacing: isInline ? 1 : 3) {
                Text(player.currentSong?.title ?? "")
                    .font(isInline ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(PrimuseNocturnePalette.ink)
                    .lineLimit(1)

                if !isInline {
                    Text(player.currentSong?.artistName ?? "")
                        .font(.caption2.monospaced())
                        .tracking(0.8)
                        .foregroundStyle(PrimuseNocturnePalette.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isInline {
                VisualizerBarsView(
                    levels: liveLevels,
                    barColor: PrimuseNocturnePalette.violet.opacity(0.8),
                    barWidth: 2,
                    spacing: 2,
                    maxHeight: 24
                )
                .frame(width: 46)
                .opacity(player.isPlaybackActive ? 1 : 0.42)
                .accessibilityHidden(true)
            }

            MiniPlayerTransportControls(
                isInline: true,
                showsNextButton: showsNextButton
            )
            .foregroundStyle(PrimuseNocturnePalette.ink)
        }
        .padding(.horizontal, isInline ? 10 : 14)
        .padding(.vertical, isInline ? 3 : 7)
        .background(PrimuseNocturnePalette.canvas.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(String(localized: "now_playing")): \(player.currentSong?.title ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onTap()
        }
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
