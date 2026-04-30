import CloudKit
import SwiftUI
import UIKit
import PrimuseKit

/// Forwards CloudKit silent pushes to the sync engine. CKSyncEngine relies on these
/// to know when to fetch — without forwarding, sync only happens on app launch and
/// manual "sync now" presses.
final class PrimuseAppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static weak var sync: CloudKitSyncService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKDatabaseNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await Self.sync?.syncNow()
            completionHandler(.newData)
        }
    }
}

@main
struct PrimuseApp: App {
    @UIApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    @State private var sourcesStore: SourcesStore
    @State private var sourceManager: SourceManager
    @State private var playerService: AudioPlayerService
    @State private var scraperSettingsStore: ScraperSettingsStore
    @State private var scraperService: MusicScraperService
    @State private var musicLibrary: MusicLibrary
    @State private var playbackSettingsStore: PlaybackSettingsStore
    @State private var cloudSync: CloudKitSyncService
    @State private var themeService = ThemeService()
    @State private var scanService = ScanService()

    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true

    init() {
        // One-shot migration: lift any pre-iCloud Keychain entries up so they sync.
        // Skip when the user has the credentials channel switched off — those
        // entries should stay local-only.
        if CloudSyncChannel.isEnabled(.credentials) {
            KeychainService.migrateLegacyEntriesToICloud()
            CloudTokenManager.migrateLegacyEntriesToICloud()
        }

        let store = SourcesStore()
        let manager = SourceManager(sourcesProvider: {
            await MainActor.run { store.sources }
        })
        let scraperSettings = ScraperSettingsStore()
        let scraperService = MusicScraperService(sourceManager: manager)
        let library = MusicLibrary()
        let playbackSettings = PlaybackSettingsStore()
        let sync = CloudKitSyncService(
            library: library,
            sourcesStore: store,
            scraperConfigStore: .shared,
            scraperSettingsStore: scraperSettings
        )

        _sourcesStore = State(initialValue: store)
        _sourceManager = State(initialValue: manager)
        let player = AudioPlayerService(sourceManager: manager, library: library, playbackSettings: playbackSettings)
        _playerService = State(initialValue: player)
        _scraperSettingsStore = State(initialValue: scraperSettings)
        _scraperService = State(initialValue: scraperService)
        _musicLibrary = State(initialValue: library)
        _playbackSettingsStore = State(initialValue: playbackSettings)
        _cloudSync = State(initialValue: sync)

        // Sync disabled source IDs at launch
        library.updateDisabledSourceIDs(
            Set(store.sources.filter { !$0.isEnabled }.map(\.id))
        )

        // Sweep recycle-bin entries older than 30 days. Uses a wall-clock
        // threshold; multiple devices converge because each writes the same
        // permanent-delete to CloudKit.
        let pruneThreshold = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        library.prunePlaylists(deletedBefore: pruneThreshold)
        store.pruneSources(deletedBefore: pruneThreshold)
        ScraperConfigStore.shared.pruneConfigs(deletedBefore: pruneThreshold)

        // Eagerly register KVS keys so the first launch on a fresh device pulls
        // remote values into UserDefaults before any view reads them.
        CloudKVSSync.shared.register(key: CloudKVSKey.lyricsFontScale) { }
        CloudKVSSync.shared.register(key: CloudKVSKey.recentSearches) { }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(themeService.accentColor)
                .environment(themeService)
                .environment(playerService)
                .environment(playerService.audioEngine)
                .environment(playerService.equalizerService)
                .environment(playerService.audioEffectsService)
                .environment(musicLibrary)
                .environment(sourcesStore)
                .environment(sourceManager)
                .environment(scraperSettingsStore)
                .environment(scraperService)
                .environment(playbackSettingsStore)
                .environment(scanService)
                .environment(cloudSync)
                .task {
                    PrimuseAppDelegate.sync = cloudSync
                    if iCloudSyncEnabled { await cloudSync.start() }
                }
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
