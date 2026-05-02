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
/// CloudKit silent pushes the same way the iOS one does, plus install the
/// menu bar status item.
final class PrimuseAppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static weak var sync: CloudKitSyncService?
    @MainActor private var menuBar: MacMenuBarController?
    @MainActor private var desktopLyrics: DesktopLyricsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        Task { @MainActor in
            let bar = MacMenuBarController()
            bar.install()
            self.menuBar = bar

            let lyrics = DesktopLyricsWindowController()
            self.desktopLyrics = lyrics
        }
    }

    @MainActor
    func toggleDesktopLyrics() {
        desktopLyrics?.toggle()
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

    @ViewBuilder
    private func injectServices<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        // On macOS we deliberately don't force the global tint to the brand
        // purple — letting SwiftUI fall through to the user's system accent
        // makes Toggle / Checkbox / standard buttons look native instead of
        // blanketed in iOS purple. Hand-built UI elements that need brand
        // tinting keep `themeService.accentColor` directly.
        let injected = content()
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
        #if os(iOS)
        return injected.tint(themeService.accentColor)
        #else
        return injected
        #endif
    }

    var body: some Scene {
        WindowGroup {
            injectServices {
                #if os(iOS)
                ContentView()
                #else
                MacContentView()
                #endif
            }
                .task {
                    PrimuseAppDelegate.sync = cloudSync
                    if iCloudSyncEnabled { await cloudSync.start() }
                    // Stage 4c migration: deduplicate legacy
                    // duplicate-OAuth sources by upstream account UID.
                    // Runs once (gated by UserDefaults flag); needs
                    // CloudKit sync started first so any
                    // newly-synced sources participate. Backfill
                    // starts after — it'll see the merged song set.
                    await CloudAccountMigrationService.runIfNeeded(
                        sourcesStore: sourcesStore,
                        sourceManager: sourceManager,
                        library: musicLibrary
                    )
                    // Catch up on any songs that were left "bare" by a previous
                    // scan (cloud sources only download metadata in the
                    // background after Phase A completes).
                    metadataBackfill.start()
                    // Re-prewarm any cloud songs whose `.partial` cache or
                    // CDN URL has expired since last launch. Cheap (skips
                    // already-prewarmed via marker check); huge win on the
                    // first play after a cold start where every CDN HEAD
                    // would otherwise add 3-20s of latency in front of the
                    // user.
                    Task.detached(priority: .background) {
                        let snapshot = await MainActor.run { musicLibrary.songs }
                        for song in snapshot {
                            if Task.isCancelled { return }
                            let done = await MainActor.run { sourceManager.isPrewarmed(song: song) }
                            if done { continue }
                            await sourceManager.prewarmCloudSongPublic(song: song)
                        }
                    }
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
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("show_desktop_lyrics") {
                    (NSApp.delegate as? PrimuseAppDelegate)?.toggleDesktopLyrics()
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
        }
        #endif

        #if os(macOS)
        Settings {
            injectServices { MacSettingsView() }
        }
        #endif
    }
}
