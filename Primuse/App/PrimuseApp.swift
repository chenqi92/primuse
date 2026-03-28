import SwiftUI
import PrimuseKit

@main
struct PrimuseApp: App {
    @State private var sourcesStore: SourcesStore
    @State private var sourceManager: SourceManager
    @State private var playerService: AudioPlayerService
    @State private var musicLibrary = MusicLibrary()

    init() {
        AudioSessionManager.shared.configureForPlayback()

        let store = SourcesStore()
        let manager = SourceManager(sourcesProvider: {
            await MainActor.run { store.sources }
        })

        _sourcesStore = State(initialValue: store)
        _sourceManager = State(initialValue: manager)
        _playerService = State(initialValue: AudioPlayerService(sourceManager: manager))
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
        }
    }
}
