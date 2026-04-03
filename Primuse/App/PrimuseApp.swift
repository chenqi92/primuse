import SwiftUI
import PrimuseKit

@main
struct PrimuseApp: App {
    @State private var sourcesStore: SourcesStore
    @State private var sourceManager: SourceManager
    @State private var playerService: AudioPlayerService
    @State private var scraperSettingsStore: ScraperSettingsStore
    @State private var scraperService: MusicScraperService
    @State private var musicLibrary: MusicLibrary
    @State private var playbackSettingsStore: PlaybackSettingsStore
    @State private var themeService = ThemeService()
    @State private var scanService = ScanService()

    init() {
        AudioSessionManager.shared.configureForPlayback()

        let store = SourcesStore()
        let manager = SourceManager(sourcesProvider: {
            await MainActor.run { store.sources }
        })
        let scraperSettings = ScraperSettingsStore()
        let scraperService = MusicScraperService(sourceManager: manager)
        let library = MusicLibrary()
        let playbackSettings = PlaybackSettingsStore()

        _sourcesStore = State(initialValue: store)
        _sourceManager = State(initialValue: manager)
        let player = AudioPlayerService(sourceManager: manager, library: library, playbackSettings: playbackSettings)
        _playerService = State(initialValue: player)
        _scraperSettingsStore = State(initialValue: scraperSettings)
        _scraperService = State(initialValue: scraperService)
        _musicLibrary = State(initialValue: library)
        _playbackSettingsStore = State(initialValue: playbackSettings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(themeService.accentColor)
                .environment(themeService)
                .environment(playerService)
                .environment(playerService.audioEngine)
                .environment(playerService.equalizerService)
                .environment(musicLibrary)
                .environment(sourcesStore)
                .environment(sourceManager)
                .environment(scraperSettingsStore)
                .environment(scraperService)
                .environment(playbackSettingsStore)
                .environment(scanService)
                .onChange(of: playerService.currentSong?.id) { _, _ in
                    themeService.updateFromCoverArt(
                        fileName: playerService.currentSong?.coverArtFileName,
                        songID: playerService.currentSong?.id
                    )
                }
                // Sync player when library replaces a song (e.g. batch scraping updates metadata)
                .onChange(of: musicLibrary.songReplacementToken) { _, _ in
                    guard let updated = musicLibrary.lastReplacedSong,
                          playerService.currentSong?.id == updated.id else { return }
                    playerService.syncSongMetadata(updated)
                    playerService.forceRefreshNowPlayingArtwork()
                    themeService.updateFromCoverArt(
                        fileName: updated.coverArtFileName,
                        songID: updated.id
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    playerService.handleAppWillResignActive()
                    musicLibrary.persistNow()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    playerService.handleAppDidBecomeActive()
                }
        }
    }
}
