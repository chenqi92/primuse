import SwiftUI
import PrimuseKit

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var showNowPlaying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "home_title"), systemImage: "house.fill", value: 0) {
                HomeView(
                    switchToSettingsTab: { selectedTab = 3 },
                    expandPlayer: { showNowPlaying = true }
                )
            }

            Tab(String(localized: "library_title"), systemImage: "books.vertical", value: 1) {
                LibraryView()
            }

            Tab(String(localized: "search_title"), systemImage: "magnifyingglass", value: 2, role: .search) {
                SearchView(searchText: $searchText)
            }

            Tab(String(localized: "settings_title"), systemImage: "gearshape", value: 3) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(player.currentSong != nil ? .onScrollDown : .never)
        .tabViewBottomAccessory(isEnabled: player.currentSong != nil) {
            NowPlayingAccessory(onTap: { showNowPlaying = true })
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            PlayerSheet(onDismiss: { showNowPlaying = false })
        }
        .onChange(of: library.songCount) { _, _ in
            if let cs = player.currentSong, !library.songs.contains(where: { $0.id == cs.id }) {
                player.stop(); player.queue = []; showNowPlaying = false
            }
        }
    }
}

// MARK: - Now Playing Accessory (adapts to inline/expanded)

struct NowPlayingAccessory: View {
    var onTap: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        ZStack {
            // Background tap area → opens player
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

            HStack(spacing: 0) {
                // Fixed left: cover art
                CachedArtworkView(
                    coverFileName: player.currentSong?.coverArtFileName,
                    size: isInline ? 32 : 40,
                    cornerRadius: isInline ? 6 : 8
                )
                .padding(.trailing, isInline ? 10 : 10)

                // Flexible middle: song title fills remaining space
                Text(player.currentSong?.title ?? "")
                    .font(isInline ? .caption : .caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Fixed right: transport controls
                HStack(spacing: isInline ? 0 : 4) {
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(isInline ? .subheadline : .body)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: isInline ? 28 : 32, height: isInline ? 28 : 32)
                    }

                    if !isInline {
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill").font(.caption)
                                .frame(width: 28, height: 28)
                        }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, isInline ? 12 : 8)
            .padding(.vertical, isInline ? 2 : 4)
        }
    }
}

// MARK: - Player Sheet (fullScreenCover with drag dismiss)

struct PlayerSheet: View {
    var onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        NowPlayingView(onMinimize: onDismiss)
            .background(Color(.systemBackground))
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        if dragOffset > 150 || value.predictedEndTranslation.height > 500 {
                            onDismiss()
                        }
                        withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                    }
            )
    }
}

#Preview {
    ContentView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
