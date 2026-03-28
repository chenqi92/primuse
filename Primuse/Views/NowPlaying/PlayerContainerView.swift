import SwiftUI
import PrimuseKit

struct PlayerContainerView<Content: View>: View {
    @Environment(AudioPlayerService.self) private var player
    @Binding var expansion: PlayerExpansion
    let content: () -> Content

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Main content
            content()
                .scaleEffect(expansion == .expanded ? 0.92 : 1.0)
                .clipShape(RoundedRectangle(cornerRadius: expansion == .expanded ? 16 : 0))
                .allowsHitTesting(expansion != .expanded)
                .animation(.spring(response: 0.35), value: expansion)

            // Player overlay
            if player.currentSong != nil {
                if expansion == .expanded {
                    expandedPlayer
                } else {
                    miniPlayer
                }
            }
        }
    }

    // MARK: - Mini Player (floating bar above tab bar)

    private var miniPlayer: some View {
        VStack {
            Spacer()
            MiniPlayerView()
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .padding(.horizontal, 16)
                .padding(.bottom, 54)
                .onTapGesture {
                    withAnimation(.spring(response: 0.35)) { expansion = .expanded }
                }
        }
    }

    // MARK: - Expanded Player (true full screen)

    private var expandedPlayer: some View {
        NowPlayingView(onMinimize: {
            withAnimation(.spring(response: 0.35)) {
                expansion = .mini
                dragOffset = 0
            }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = max(0, value.translation.height)
                }
                .onEnded { value in
                    if dragOffset > 150 || value.predictedEndTranslation.height > 500 {
                        withAnimation(.spring(response: 0.35)) {
                            expansion = .mini
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .ignoresSafeArea()
        .transition(.move(edge: .bottom))
        .animation(.spring(response: 0.35), value: expansion)
    }
}

enum PlayerExpansion: Equatable {
    case mini
    case expanded
}
