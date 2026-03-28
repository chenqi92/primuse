import SwiftUI
import PrimuseKit

@main
struct PrimuseApp: App {
    @State private var playerService = AudioPlayerService()
    @State private var musicLibrary = MusicLibrary()

    init() {
        AudioSessionManager.shared.configureForPlayback()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(playerService)
                .environment(playerService.audioEngine)
                .environment(playerService.equalizerService)
                .environment(musicLibrary)
        }
    }
}
