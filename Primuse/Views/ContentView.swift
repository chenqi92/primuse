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
                HomeView(switchToSettingsTab: { selectedTab = 3 })
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
        .safeAreaInset(edge: .bottom) {
            // Only show mini player on non-home tabs (home has big card player)
            if player.currentSong != nil && selectedTab != 0 {
                MiniPlayerView()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 52)
                    .onTapGesture { showNowPlaying = true }
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onEnded { if $0.translation.height < -30 { showNowPlaying = true } }
                    )
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(20)
                .interactiveDismissDisabled(false)
        }
        .onChange(of: library.songCount) { _, _ in
            if let currentSong = player.currentSong,
               !library.songs.contains(where: { $0.id == currentSong.id }) {
                player.stop()
                player.queue = []
                showNowPlaying = false
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
