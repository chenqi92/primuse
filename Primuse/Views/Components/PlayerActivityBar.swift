import SwiftUI
import PrimuseKit

extension NowPlayingStatusItem {
    var titleKey: LocalizedStringKey {
        switch self {
        case .source: "player_controls_status_source"
        case .output: "player_controls_status_output"
        case .sleepTimer: "player_controls_status_sleep"
        case .activity: "player_activity_status"
        }
    }
}

struct PlayerStatusItemsRow<Content: View>: View {
    let items: [NowPlayingStatusItem]
    @ViewBuilder var content: (NowPlayingStatusItem) -> Content

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Text(verbatim: "·").accessibilityHidden(true)
                }
                content(item)
                    .imageScale(.small)
                    .accessibilityIdentifier("playerStatusItem.\(item.rawValue)")
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}

/// Fits beside source and output information in the player's footer.
struct PlayerActivityStatusView: View {
    let status: PlayerActivityStatus

    var body: some View {
        HStack(spacing: 3) {
            if status.isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 10, height: 10)
            }
            Text(status.title)
                .lineLimit(1)
            if let progress = status.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .font(.caption2.monospacedDigit())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playerActivityStatus")
        .allowsHitTesting(false)
    }
}

struct PlayerActivityBar: View {
    let songID: String?
    @AppStorage(WordLyricsDiscoveryPreferences.showsActivityKey)
    private var showsActivity = WordLyricsDiscoveryPreferences.showsActivityByDefault

    private var status: PlayerActivityStatus? {
        PlayerActivityStore.shared.status(for: songID)
    }

    var body: some View {
        if showsActivity, let status {
            PlayerActivityStatusView(status: status)
                .foregroundStyle(.secondary)
        }
    }
}
