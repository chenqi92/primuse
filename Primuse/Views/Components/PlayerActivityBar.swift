import SwiftUI
import PrimuseKit

/// A compact, non-interactive status shared by playback and metadata work.
struct PlayerActivityStatusView: View {
    let status: PlayerActivityStatus

    var body: some View {
        HStack(spacing: 8) {
            if status.isRunning {
                ProgressView().controlSize(.small)
            }
            Text(status.title)
                .lineLimit(1)
            if let progress = status.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }
    }
}
