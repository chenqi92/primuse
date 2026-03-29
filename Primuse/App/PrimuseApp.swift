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
        _playerService = State(initialValue: AudioPlayerService(sourceManager: manager, library: library, playbackSettings: playbackSettings))
        _scraperSettingsStore = State(initialValue: scraperSettings)
        _scraperService = State(initialValue: scraperService)
        _musicLibrary = State(initialValue: library)
        _playbackSettingsStore = State(initialValue: playbackSettings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(playerService)
                .environment(playerService.audioEngine)
                .environment(playerService.equalizerService)
                .environment(musicLibrary)
                .environment(sourcesStore)
                .environment(sourceManager)
                .environment(scraperSettingsStore)
                .environment(scraperService)
                .environment(playbackSettingsStore)
        }
    }
}
