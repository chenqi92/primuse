import SwiftUI
import PrimuseKit

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var playerExpansion: PlayerExpansion = .mini

    var body: some View {
        PlayerContainerView(expansion: $playerExpansion) {
            TabView(selection: $selectedTab) {
                Tab(String(localized: "home_title"), systemImage: "house.fill", value: 0) {
                    HomeView(
                        switchToSettingsTab: { selectedTab = 3 },
                        expandPlayer: { withAnimation(.spring(response: 0.35)) { playerExpansion = .expanded } }
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
        }
        .onChange(of: library.songCount) { _, _ in
            if let currentSong = player.currentSong,
               !library.songs.contains(where: { $0.id == currentSong.id }) {
                player.stop()
                player.queue = []
                playerExpansion = .mini
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
