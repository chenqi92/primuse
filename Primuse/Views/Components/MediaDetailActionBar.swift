import SwiftUI

struct MediaDetailActionBar: View {
    let canPlay: Bool
    let canShuffle: Bool
    let playAction: () -> Void
    let shuffleAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: playAction) {
                Label("play_all", systemImage: "play.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPlay)

            Button(action: shuffleAction) {
                Label("shuffle", systemImage: "shuffle")
                    .frame(minWidth: 112)
            }
            .buttonStyle(.bordered)
            .disabled(!canShuffle)
        }
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }
}
