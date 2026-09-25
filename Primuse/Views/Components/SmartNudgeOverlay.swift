import PrimuseKit
import SwiftUI

extension View {
    /// Hosts the playback suggestions for the whole app. Attached once, at the
    /// root, above the full player, so a suggestion can appear wherever the
    /// listener is. It sits at the top edge like a system banner: the bottom
    /// belongs to the mini player and the transport controls.
    func smartNudges() -> some View {
        modifier(SmartNudgeOverlayModifier())
    }
}

private struct SmartNudgeOverlayModifier: ViewModifier {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase

    private var center: SmartNudgeCenter { SmartNudgeCenter.shared }

    /// How often the moment is looked at. Suggestions are about minutes of
    /// listening, so a few seconds of latency cost nothing.
    private static let evaluationInterval: Duration = .seconds(8)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack {
                    if let nudge = center.activeNudge {
                        SmartNudgeBanner(
                            nudge: nudge,
                            onAccept: { variant in
                                center.accept(nudge, player: player, library: library, variant: variant)
                            },
                            onDismiss: { center.dismiss(nudge) }
                        )
                        .pmSlideTransition(edge: .top, motion: .list)
                    }
                }
                .padding(.horizontal, 16)
                #if os(macOS)
                .padding(.top, 52)
                .frame(maxWidth: 520)
                #else
                .padding(.top, 6)
                #endif
                .pmAnimation(.list, value: center.activeNudge?.id)
            }
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.evaluationInterval)
                    guard !Task.isCancelled else { return }
                    center.evaluate(player: player, library: library)
                }
            }
    }
}

private struct SmartNudgeBanner: View {
    let nudge: SmartNudge
    let onAccept: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: nudge.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if nudge.kind == .sleepTimer {
                Menu {
                    Button("smart_nudge_sleep_30") { onAccept(0) }
                    Button("sleep_at_track_end") { onAccept(1) }
                } label: {
                    Text("smart_nudge_action_set")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
            } else {
                Button { onAccept(0) } label: {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .fixedSize()
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("smart_nudge_dismiss"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height < -12 { onDismiss() }
            }
        )
        #endif
    }

    private var message: String {
        switch nudge.kind {
        case .addToFavorites:
            String(localized: "smart_nudge_add_favorite_message")
        case .playSimilar:
            String(localized: "smart_nudge_similar_message")
        case .removeFromFavorites:
            String(localized: "smart_nudge_remove_favorite_message")
        case .continueWithRecommendations:
            String(localized: "smart_nudge_continue_message")
        case .sleepTimer:
            String(localized: "smart_nudge_sleep_message")
        case .backToMusic:
            String(localized: "smart_nudge_back_to_music_message")
        case .classifyAsSpokenWord:
            String(localized: "smart_nudge_classify_spoken_message")
        }
    }

    private var detail: String? {
        switch nudge.kind {
        case .sleepTimer:
            return nil
        case .backToMusic:
            return MusicSessionMemoryStore.shared.memory?.title
        case .continueWithRecommendations, .playSimilar:
            return String(format: String(localized: "smart_nudge_songs_format"), nudge.songs.count)
        default:
            return nudge.songTitle
        }
    }

    private var actionTitle: String {
        switch nudge.kind {
        case .addToFavorites: String(localized: "smart_nudge_action_like")
        case .playSimilar: String(localized: "smart_nudge_action_play_next")
        case .removeFromFavorites: String(localized: "smart_nudge_action_unlike")
        case .continueWithRecommendations: String(localized: "smart_nudge_action_add")
        case .sleepTimer: String(localized: "smart_nudge_action_set")
        case .backToMusic: String(localized: "smart_nudge_action_add")
        case .classifyAsSpokenWord: String(localized: "smart_nudge_action_move")
        }
    }
}

/// Switches for the playback suggestions, shared by the iOS and Mac settings.
struct SmartNudgeSettingsSection: View {
    var body: some View {
        @Bindable var center = SmartNudgeCenter.shared
        Section {
            Toggle("smart_nudge_enabled", isOn: $center.isEnabled)
                .settingsAnchor("playback.smartNudges")
            if center.isEnabled {
                ForEach(SmartNudgeKind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(
                        get: { center.isKindEnabled(kind) },
                        set: { center.setKind(kind, enabled: $0) }
                    )) {
                        Label(LocalizedStringKey(kind.settingsTitleKey), systemImage: kind.systemImage)
                    }
                }
                Button("smart_nudge_reset") { center.resetHistory() }
            }
        } header: {
            Text("smart_nudge_section")
        } footer: {
            Text("smart_nudge_footer")
        }
    }
}
