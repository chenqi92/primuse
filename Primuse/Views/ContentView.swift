import SwiftUI
import PrimuseKit

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var showNowPlaying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "library_title"), systemImage: "books.vertical", value: 0) {
                LibraryView(switchToSourcesTab: { selectedTab = 1 })
            }

            Tab(String(localized: "sources_title"), systemImage: "externaldrive.connected.to.line.below", value: 1) {
                SourcesView()
            }

            Tab(String(localized: "settings_title"), systemImage: "gearshape", value: 2) {
                SettingsView()
            }

            Tab(String(localized: "search_title"), systemImage: "magnifyingglass", value: 3, role: .search) {
                SearchView(searchText: $searchText)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentSong != nil {
                MiniPlayerView()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 52) // Above tab bar
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
                .presentationCornerRadius(24)
        }
    }
}

#Preview {
    let store = SourcesStore()
    let manager = SourceManager(sourcesProvider: { await MainActor.run { store.sources } })
    let scraperSettings = ScraperSettingsStore()
    let scraperService = MusicScraperService(sourceManager: manager)

    ContentView()
        .environment(AudioPlayerService(sourceManager: manager))
        .environment(MusicLibrary())
        .environment(store)
        .environment(manager)
        .environment(scraperSettings)
        .environment(scraperService)
}
