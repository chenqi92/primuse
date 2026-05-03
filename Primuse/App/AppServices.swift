import Foundation
import PrimuseKit

@MainActor
final class AppServices {
    static let shared = AppServices()

    let sourcesStore: SourcesStore
    let sourceManager: SourceManager
    let playerService: AudioPlayerService
    let scraperSettingsStore: ScraperSettingsStore
    let scraperService: MusicScraperService
    let musicLibrary: MusicLibrary
    let playbackSettingsStore: PlaybackSettingsStore
    let cloudSync: CloudKitSyncService
    let themeService: ThemeService
    let scanService: ScanService
    let metadataBackfill: MetadataBackfillService
    private var observerTokens: [NSObjectProtocol] = []

    private init() {
        // Class is @MainActor so this initializer is too — but the static
        // `shared` instantiation is lazy-on-first-access. If anything
        // ever touches `AppServices.shared` from a non-main thread, Swift
        // will hop here implicitly and we'd silently break invariants in
        // the services we own. Crash loudly instead.
        dispatchPrecondition(condition: .onQueue(.main))

        if CloudSyncChannel.isEnabled(.credentials) {
            KeychainService.migrateLegacyEntriesToICloud()
            CloudTokenManager.migrateLegacyEntriesToICloud()
        }

        let store = SourcesStore()
        let manager = SourceManager(sourcesProvider: {
            await MainActor.run { store.sources }
        })
        let scraperSettings = ScraperSettingsStore()
        let scraper = MusicScraperService(sourceManager: manager)
        let library = MusicLibrary()
        let playbackSettings = PlaybackSettingsStore()
        let player = AudioPlayerService(sourceManager: manager, library: library, playbackSettings: playbackSettings)
        let sync = CloudKitSyncService(
            library: library,
            sourcesStore: store,
            scraperConfigStore: .shared,
            scraperSettingsStore: scraperSettings
        )

        self.sourcesStore = store
        self.sourceManager = manager
        self.playerService = player
        self.scraperSettingsStore = scraperSettings
        self.scraperService = scraper
        self.musicLibrary = library
        self.playbackSettingsStore = playbackSettings
        self.cloudSync = sync
        let theme = ThemeService()
        #if os(iOS)
        // Pull the user's chosen app icon tint into the theme so the in-app
        // accent matches the icon they picked. Cover-art-derived colors will
        // override this while a song with artwork plays.
        theme.setBaseAccent(AppIconService.shared.currentTint)
        #endif
        self.themeService = theme
        self.scanService = ScanService()
        self.metadataBackfill = MetadataBackfillService(library: library, sourceManager: manager)

        library.updateSourceVisibility(
            activeSourceIDs: Set(store.sources.map(\.id)),
            disabledSourceIDs: Set(store.sources.filter { !$0.isEnabled }.map(\.id))
        )
        library.removeSongsExcludingSources(Set(store.sources.map(\.id)))

        // Wire the library's tombstone identity resolver. Maps a song's
        // mount UUID → its CloudAccount id (when available) so deletion
        // tombstones survive re-OAuth — the user re-adding the same
        // Baidu account mints a new mount UUID, which would otherwise
        // change song.id and silently bypass the tombstone set.
        library.sourceIdentityResolver = { [weak store] sourceID in
            store?.allSources.first(where: { $0.id == sourceID })?.cloudAccountID
        }

        let pruneThreshold = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        library.prunePlaylists(deletedBefore: pruneThreshold)
        store.pruneSources(deletedBefore: pruneThreshold)
        ScraperConfigStore.shared.pruneConfigs(deletedBefore: pruneThreshold)

        CloudKVSSync.shared.register(key: CloudKVSKey.lyricsFontScale) { }
        CloudKVSSync.shared.register(key: CloudKVSKey.recentSearches) { }

        observerTokens.append(
            NotificationCenter.default.addObserver(
                forName: .primuseSourcesDidChange,
                object: nil,
                queue: .main
            ) { [weak store, weak library, weak manager] note in
                // Pull the needed values out before entering the MainActor task.
                // Notification itself is not Sendable under strict concurrency.
                let deletedIDs = (note.userInfo?["ids"] as? [String]) ?? []
                Task { @MainActor in
                    guard let store, let library else { return }
                    let activeSourceIDs = Set(store.sources.map(\.id))
                    library.updateSourceVisibility(
                        activeSourceIDs: activeSourceIDs,
                        disabledSourceIDs: Set(store.sources.filter { !$0.isEnabled }.map(\.id))
                    )
                    library.removeSongsExcludingSources(activeSourceIDs)
                    for id in deletedIDs where !activeSourceIDs.contains(id) {
                        manager?.deleteSourceCaches(sourceID: id)
                        #if os(macOS)
                        LocalBookmarkStore.remove(sourceID: id)
                        #endif
                    }
                }
            }
        )
    }
}
