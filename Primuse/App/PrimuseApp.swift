import CloudKit
import SwiftUI
import PrimuseKit
#if os(iOS)
import BackgroundTasks
import Intents
import UIKit

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
        registerBackgroundScanResume()
        return true
    }

    /// Register a BGProcessingTask handler that resumes any interrupted scans.
    /// iOS fires this when the device is idle and on a network connection,
    /// giving us several minutes of CPU time to keep scanning.
    private func registerBackgroundScanResume() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ScanService.backgroundTaskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                let services = AppServices.shared
                let scanService = services.scanService
                let backfill = services.metadataBackfill

                task.expirationHandler = {
                    Task { @MainActor in
                        scanService.cancelAllActiveScans()
                        backfill.stop()
                    }
                }

                // Resume any interrupted scans, then run backfill until the
                // task expires or work runs out. Both phases use HTTP Range
                // / list-only API calls — safe for iOS background quotas.
                scanService.resumePendingScans(
                    sourceManager: services.sourceManager,
                    library: services.musicLibrary,
                    sourceStore: services.sourcesStore,
                    scraperService: services.scraperService
                )
                await scanService.waitForActiveScansToComplete()

                backfill.start()
                await backfill.waitUntilIdle()

                // If anything still has a checkpoint or pending bare songs,
                // ask iOS to wake us again later.
                scanService.scheduleBackgroundResumeIfNeeded(
                    backfillPending: backfill.hasPendingWork
                )
                task.setTaskCompleted(success: true)
            }
        }
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

    // Routes Siri voice intents (INPlayMediaIntent etc.) to a handler. Without
    // an Intents Extension this only fires while the app is running, but
    // CarPlay voice and Shortcuts both work this way.
    static let playMediaHandler = PlayMediaIntentHandler()

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        if intent is INPlayMediaIntent {
            return Self.playMediaHandler
        }
        return nil
    }
}
#else
import AppKit

/// macOS counterpart of `PrimuseAppDelegate`. macOS has no BGTaskScheduler /
/// CarPlay / Intents-handler routing — the delegate exists only to forward
/// CloudKit silent pushes the same way the iOS one does.
final class PrimuseAppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static weak var sync: CloudKitSyncService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard CKDatabaseNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        Task { @MainActor in await Self.sync?.syncNow() }
    }
}
#endif

@main
struct PrimuseApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(PrimuseAppDelegate.self) private var appDelegate
    #endif
    @State private var sourcesStore: SourcesStore
    @State private var sourceManager: SourceManager
    @State private var playerService: AudioPlayerService
    @State private var scraperSettingsStore: ScraperSettingsStore
    @State private var scraperService: MusicScraperService
    @State private var musicLibrary: MusicLibrary
    @State private var playbackSettingsStore: PlaybackSettingsStore
    @State private var cloudSync: CloudKitSyncService
    @State private var themeService: ThemeService
    @State private var scanService: ScanService
    @State private var metadataBackfill: MetadataBackfillService

    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let services = AppServices.shared
        _sourcesStore = State(initialValue: services.sourcesStore)
        _sourceManager = State(initialValue: services.sourceManager)
        _playerService = State(initialValue: services.playerService)
        _scraperSettingsStore = State(initialValue: services.scraperSettingsStore)
        _scraperService = State(initialValue: services.scraperService)
        _musicLibrary = State(initialValue: services.musicLibrary)
        _playbackSettingsStore = State(initialValue: services.playbackSettingsStore)
        _cloudSync = State(initialValue: services.cloudSync)
        _themeService = State(initialValue: services.themeService)
        _scanService = State(initialValue: services.scanService)
        _metadataBackfill = State(initialValue: services.metadataBackfill)
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
                .environment(metadataBackfill)
                .task {
                    PrimuseAppDelegate.sync = cloudSync
                    if iCloudSyncEnabled { await cloudSync.start() }
                    // Catch up on any songs that were left "bare" by a previous
                    // scan (cloud sources only download metadata in the
                    // background after Phase A completes).
                    metadataBackfill.start()
                }
                .onChange(of: playerService.currentSong?.id) { _, _ in
                    themeService.updateFromCoverArt(
                        fileName: playerService.currentSong?.coverArtFileName,
                        songID: playerService.currentSong?.id
                    )
                }
                // Sync player when library replaces a song (e.g. batch scraping
                // or metadata backfill updates metadata). Backfill uses
                // batched `replaceSongs`, so the currently-playing song may
                // be ANYWHERE in the batch, not just the last entry — we
                // check `lastReplacedSongIDs` to catch every case.
                .onChange(of: musicLibrary.songReplacementToken) { _, _ in
                    guard let currentID = playerService.currentSong?.id,
                          musicLibrary.lastReplacedSongIDs.contains(currentID),
                          let updated = musicLibrary.songs.first(where: { $0.id == currentID })
                    else { return }
                    playerService.syncSongMetadata(updated)
                    playerService.forceRefreshNowPlayingArtwork()
                    themeService.updateFromCoverArt(
                        fileName: updated.coverArtFileName,
                        songID: updated.id
                    )
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background, .inactive:
                        playerService.handleAppWillResignActive()
                        musicLibrary.persistNow()
                        // If a scan was running OR backfill has pending work, ask
                        // iOS to wake us later via BGProcessingTask so we can keep
                        // going past the beginBackgroundTask 30s ceiling. (No-op
                        // on macOS — BGTaskScheduler doesn't exist there.)
                        scanService.scheduleBackgroundResumeIfNeeded(
                            backfillPending: metadataBackfill.hasPendingWork
                        )
                    case .active:
                        playerService.handleAppDidBecomeActive()
                        // Auto-resume any scan that was interrupted (app killed,
                        // backgrounded past the begin/endBackgroundTask window, or
                        // crashed mid-scan). Idempotent.
                        scanService.resumePendingScans(
                            sourceManager: sourceManager,
                            library: musicLibrary,
                            sourceStore: sourcesStore,
                            scraperService: scraperService
                        )
                        // Pick up any bare songs left behind by an earlier scan.
                        metadataBackfill.start()
                    @unknown default:
                        break
                    }
                }
                // After every library write (scan progress, replaceSong, etc.)
                // re-evaluate whether there's bare-song work to do. This
                // ensures backfill kicks in the moment Phase A produces its
                // first batch instead of waiting for app foreground.
                .onChange(of: musicLibrary.songs.count) { _, _ in
                    metadataBackfill.refreshQueue()
                }
                // Auto-resume backfill when the user reconnects to Wi-Fi
                // after the cellular gate paused it.
                .onChange(of: NetworkMonitor.shared.isOnUnmeteredNetwork) { _, onWifi in
                    if onWifi { metadataBackfill.start() }
                }
        }
    }
}
