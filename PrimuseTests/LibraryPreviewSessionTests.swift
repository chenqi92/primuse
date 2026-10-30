import Foundation
import PrimuseKit
import XCTest
#if os(iOS)
import SwiftUI
import UIKit
import Vision
#endif
@testable import Primuse

#if os(iOS)
@MainActor
final class HomeHeroRecommendationTests: XCTestCase {
    func testDailyCollectionPersistsAndManualRefreshAvoidsPreviousBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeroRecommendations-\(UUID())")
        let suite = "HeroRecommendations-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        library.addSongs((0..<150).map { index in
            Song(id: "daily-\(index)", title: "Track \(index)", albumTitle: "Album \(index / 3)",
                 artistName: "Artist \(index / 3)", duration: 180, fileFormat: .mp3,
                 filePath: "Music/\(index).mp3", sourceID: "daily-fixture")
        }, indexMaintenance: .deferredIncremental)
        await library.waitForPendingIndex()
        XCTAssertEqual(library.musicSongs.count, 150)
        let intelligence = MusicIntelligenceService(settingsStore: AISettingsStore(defaults: defaults), recommendationReuseDefaults: defaults)
        XCTAssertFalse(intelligence.isPersonalizedRecommendationsConfigured)
        let config = HomeHeroRecommendationModel.Configuration(content: .songs, songCount: 50, albumCount: 6)
        let first = HomeHeroRecommendationModel(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_798_041_600)
        await first.refresh(configuration: config, library: library, intelligence: intelligence, now: now)
        let firstIDs = first.songs.map(\.id)
        XCTAssertEqual(firstIDs.count, 50)
        XCTAssertNil(first.providerName)
        let restored = HomeHeroRecommendationModel(defaults: defaults)
        await restored.refresh(configuration: config, library: library, intelligence: intelligence, now: now)
        XCTAssertEqual(restored.songs.map(\.id), firstIDs)
        await restored.refresh(configuration: config, library: library, intelligence: intelligence, force: true, now: now)
        XCTAssertEqual(restored.songs.count, 50)
        XCTAssertTrue(Set(restored.songs.map(\.id)).isDisjoint(with: firstIDs))
        let secondIDs = restored.songs.map(\.id)
        await restored.refresh(configuration: config, library: library, intelligence: intelligence, now: now.addingTimeInterval(86_400))
        XCTAssertTrue(Set(restored.songs.map(\.id)).isDisjoint(with: secondIDs))
        let albums = HomeHeroRecommendationModel.Configuration(content: .albums, songCount: 500, albumCount: 12)
        await restored.refresh(configuration: albums, library: library, intelligence: intelligence, now: now)
        XCTAssertEqual(restored.albums.count, 12)
        XCTAssertEqual(Set(restored.albums.map(\.id)).count, 12)
        XCTAssertEqual(restored.songs.count, 50)
        XCTAssertFalse(restored.isLoading)
    }

    func testAIUsesDisjointBoundedPagesAndFallsBackOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeroRecommendations-\(UUID())")
        let suite = "HeroRecommendations-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        library.addSongs((0..<150).map { index in
            Song(id: "ai-daily-\(index)", title: "Track \(index)", albumTitle: "Album \(index / 3)",
                 artistName: "Artist \(index / 3)", duration: 180, fileFormat: .mp3,
                 filePath: "Music/\(index).mp3", sourceID: "ai-daily-fixture")
        }, indexMaintenance: .deferredIncremental)
        await library.waitForPendingIndex()
        let intelligence = MusicIntelligenceService(settingsStore: AISettingsStore(defaults: defaults), recommendationReuseDefaults: defaults)
        var requests: [AIRecommendationRequest] = []
        let model = HomeHeroRecommendationModel(defaults: defaults) { request in
            requests.append(request)
            let selections: [AIRecommendationSelection] = request.unit == .albums
                ? request.albumCandidates.prefix(request.maximumAlbumResults).map { .init(albumKey: $0.albumKey, reason: "Album recommendation") }
                : request.candidates.prefix(request.maximumResults).map { .init(songID: $0.songID, reason: "Song recommendation") }
            return .success(.init(plan: .init(selections: selections), providerName: "Fixture", fallbackDepth: 0,
                                  resolvedScene: .automatic, isCached: false))
        }
        await model.refresh(configuration: .init(content: .songs, songCount: 50, albumCount: 12), library: library, intelligence: intelligence)
        XCTAssertEqual(requests.map(\.maximumResults), [30, 20])
        XCTAssertEqual(model.songs.count, 50)
        XCTAssertEqual(model.providerName, "Fixture")
        XCTAssertEqual(Set(model.songs.map(\.id)).count, 50)
        if requests.count == 2 {
            XCTAssertTrue(Set(requests[0].candidates.prefix(30).map(\.songID)).isDisjoint(with: requests[1].candidates.map(\.songID)))
        }
        requests = []
        await model.refresh(configuration: .init(content: .albums, songCount: 50, albumCount: 12), library: library, intelligence: intelligence)
        XCTAssertEqual(requests.map(\.maximumAlbumResults), [6, 6])
        XCTAssertEqual(model.albums.count, 12)
        var failedRequests = 0
        let fallback = HomeHeroRecommendationModel(defaults: defaults) { _ in
            failedRequests += 1
            return .failed(.upstream)
        }
        await fallback.refresh(configuration: .init(content: .songs, songCount: 50, albumCount: 6), library: library,
                               intelligence: intelligence, force: true)
        XCTAssertEqual(failedRequests, 1)
        XCTAssertEqual(fallback.songs.count, 50)
        XCTAssertNil(fallback.providerName)
    }

    func testThemesUseIndependentDailyCachesAndPassTheirIntentToAI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeroThemes-\(UUID())")
        let suite = "HeroThemes-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        library.addSongs((0..<200).map { index in
            var song = Song(id: "theme-\(index)", title: "Track \(index)", albumTitle: "Album \(index / 3)",
                            artistName: "Artist \(index / 3)", duration: 180, fileFormat: .mp3,
                            filePath: "Music/\(index).mp3", sourceID: "theme-fixture")
            song.year = 1950 + index / 3
            return song
        }, indexMaintenance: .deferredIncremental)
        await library.waitForPendingIndex()
        let intelligence = MusicIntelligenceService(settingsStore: AISettingsStore(defaults: defaults), recommendationReuseDefaults: defaults)
        let config = HomeHeroRecommendationModel.Configuration(content: .songs, songCount: 24, albumCount: 6)
        let now = Date(timeIntervalSince1970: 1_798_041_600)
        let older = HomeHeroRecommendationModel(theme: .catalogRewind, defaults: defaults)
        let newer = HomeHeroRecommendationModel(theme: .recentCatalog, defaults: defaults)
        await older.refresh(configuration: config, library: library, intelligence: intelligence, now: now)
        await newer.refresh(configuration: config, library: library, intelligence: intelligence, now: now)
        let originalOlder = older.songs.map(\.id)
        let originalNewer = newer.songs.map(\.id)
        XCTAssertEqual(originalOlder.count, 24)
        XCTAssertEqual(originalNewer.count, 24)
        XCTAssertTrue(Set(originalOlder).isDisjoint(with: originalNewer))
        XCTAssertLessThanOrEqual(try XCTUnwrap(older.songs.compactMap(\.year).max()), try XCTUnwrap(newer.songs.compactMap(\.year).min()))
        await older.refresh(configuration: config, library: library, intelligence: intelligence, force: true, now: now)
        XCTAssertTrue(Set(older.songs.map(\.id)).isDisjoint(with: originalOlder))
        let restored = HomeHeroRecommendationModel(theme: .recentCatalog, defaults: defaults)
        await restored.refresh(configuration: config, library: library, intelligence: intelligence, now: now)
        XCTAssertEqual(restored.songs.map(\.id), originalNewer, "Refreshing one theme must not replace another theme's cache")
        let following = now.addingTimeInterval(86_400)
        await restored.refresh(configuration: config, library: library, intelligence: intelligence, now: following)
        XCTAssertTrue(Set(restored.songs.map(\.id)).isDisjoint(with: originalNewer))
        var receivedIntent: String?
        let ai = HomeHeroRecommendationModel(theme: .catalogRewind, defaults: defaults) { request in
            receivedIntent = request.intent
            return .failed(.upstream)
        }
        await ai.refresh(configuration: config, library: library, intelligence: intelligence, force: true, now: now)
        XCTAssertEqual(receivedIntent, AIRecommendationIntentPreset.catalogRewind.semanticIntent)
        XCTAssertEqual(ai.songs.count, 24, "The themed local collection remains usable when AI fails")
    }

    func testUndatedThemesStayWithinTheSystemRecommendationPool() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeroUndated-\(UUID())")
        let suite = "HeroUndated-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        library.addSongs((0..<800).map { index in
            Song(id: "undated-\(index)", title: "Track \(index)", albumTitle: "Album \(index / 3)",
                 artistName: "Artist \(index / 3)", duration: 180, fileFormat: .mp3,
                 filePath: "Music/\(index).mp3", sourceID: "undated-fixture")
        }, indexMaintenance: .deferredIncremental)
        await library.waitForPendingIndex()
        let now = Date(timeIntervalSince1970: 1_798_041_600)
        let input = MusicDiscoveryEngine.recommendationSnapshot(in: library, now: now).makeInput()
        let ranked = Set(MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 200).map { $0.song.id })
        let intelligence = MusicIntelligenceService(settingsStore: AISettingsStore(defaults: defaults), recommendationReuseDefaults: defaults)
        for theme in [HomeHeroRecommendationTheme.catalogRewind, .recentCatalog] {
            let model = HomeHeroRecommendationModel(theme: theme, defaults: defaults)
            await model.refresh(configuration: .init(content: .songs, songCount: 50, albumCount: 6),
                                library: library, intelligence: intelligence, now: now)
            XCTAssertEqual(model.songs.count, 50)
            XCTAssertTrue(Set(model.songs.map(\.id)).isSubset(of: ranked), "Unknown years must retain the system's ranking instead of sampling unranked library entries")
        }
    }

    func testEmptyLibraryAndCancelledRefreshLeaveNoLoadingState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HeroRecommendations-\(UUID())")
        let suite = "HeroRecommendations-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        let intelligence = MusicIntelligenceService(settingsStore: AISettingsStore(defaults: defaults), recommendationReuseDefaults: defaults)
        let model = HomeHeroRecommendationModel(defaults: defaults)
        let config = HomeHeroRecommendationModel.Configuration(content: .songs, songCount: 50, albumCount: 6)
        await model.refresh(configuration: config, library: library, intelligence: intelligence)
        XCTAssertTrue(model.songs.isEmpty)
        XCTAssertFalse(model.isLoading)
        let task = Task { await model.refresh(configuration: config, library: library, intelligence: intelligence, force: true) }
        task.cancel()
        await task.value
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.songs.isEmpty)
    }
}

@MainActor
final class HomeHeroCarouselLayoutTests: XCTestCase {
    func testFeaturedCardsResizeAndKeepTheNextCardVisible() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let songs = (0..<3).map {
            Song(id: "featured-\($0)", title: "Song \($0)", albumTitle: "A longer album title for layout",
                 artistName: "Featured Artist", fileFormat: .mp3, filePath: "", sourceID: "featured-source")
        }
        var heroFrame = CGRect.zero
        let tintProvider = CoverTintProvider()
        func root(_ size: CGSize, largeText: Bool = false) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Daily Picks").font(.title3.bold())
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(songs) { song in
                                HomeHeroRecommendationCard(
                                    metrics: .init(viewportWidth: size.width, compactCanvasHeight: size.width > size.height ? size.height : nil),
                                    songs: [song], title: song.albumTitle ?? song.title,
                                    subtitle: song.artistName ?? ""
                                )
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("featured-test")) } action: { heroFrame = $0 }
            }
            .coordinateSpace(name: "featured-test")
            .frame(width: size.width, height: size.height)
            .environment(library)
            .environment(AppServices.shared.playerService)
            .environment(AppServices.shared.sourcesStore)
            .environment(AppServices.shared.sourceManager)
            .environment(tintProvider)
            .dynamicTypeSize(largeText ? .accessibility1 : .large)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: root(CGSize(width: 390, height: 844)))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 768, height: 1024)] {
            host.rootView = root(size)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let metrics = HomeHeroFeaturedMetrics(viewportWidth: size.width, compactCanvasHeight: size.width > size.height ? size.height : nil)
            let medium = HomeHeroFeaturedMetrics(viewportWidth: size.width, compactCanvasHeight: size.width > size.height ? size.height : nil, medium: true)
            XCTAssertLessThan(medium.cardWidth, metrics.cardWidth)
            XCTAssertLessThan(medium.artworkSide, metrics.artworkSide)
            XCTAssertLessThan(metrics.cardWidth + 52, size.width, "The next card must peek into view")
            XCTAssertLessThan(heroFrame.height, size.height * 0.7, "The following section must remain visible")
            XCTAssertGreaterThan(heroFrame.height, metrics.cardHeight(captionHeight: 84))
        }
        let size = CGSize(width: 390, height: 844)
        host.rootView = root(size, largeText: true)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Featured Artist"), "The artist must remain readable with large text")
        let attachment = XCTAttachment(image: image)
        attachment.name = "featured-large-text"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCarouselKeepsFollowingSectionVisibleAfterResizing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeHeroCarouselLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "HomeHeroCarouselLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        let player = AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Layout tests must not start playback") }
        )
        let songs = (0..<48).map { index in
            Song(id: "hero-layout-\(index)", title: "Song \(index)", artistName: "Artist",
                 fileFormat: .mp3, filePath: "", sourceID: "hero-layout-source")
        }
        var heroFrame = CGRect.zero
        var followingSectionFrame = CGRect.zero
        let tintProvider = CoverTintProvider()

        func root(_ size: CGSize) -> some View {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Music · Radio · Audiobooks · Podcasts")
                        .frame(height: 36)
                    HomeHeroCarousel(songs: songs, isInteractive: false,
                                     playFromSong: { _ in }, shuffleAll: {}, playAll: {})
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("home-layout-test"))
                        } action: { heroFrame = $0 }
                    Text("Following section")
                        .frame(height: 44)
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("home-layout-test"))
                        } action: { followingSectionFrame = $0 }
                }
            }
            .coordinateSpace(name: "home-layout-test")
            .frame(width: size.width, height: size.height)
            .environment(library)
            .environment(player)
            .environment(tintProvider)
            .environment(AppServices.shared.sourceManager)
        }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: root(CGSize(width: 390, height: 844)))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        for size in [CGSize(width: 390, height: 844), CGSize(width: 430, height: 932),
                     CGSize(width: 768, height: 1024), CGSize(width: 390, height: 844)] {
            host.rootView = root(size)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            print("Home hero layout \(size): hero=\(heroFrame), following=\(followingSectionFrame)")
            XCTAssertGreaterThan(heroFrame.height, 200)
            XCTAssertLessThan(heroFrame.height, size.height * 0.6, "The carousel must not fill the vertical scroll viewport")
            XCTAssertLessThan(followingSectionFrame.maxY, size.height * 0.75, "The next section must remain visible below the carousel")
        }
    }
}
#endif

@MainActor
final class HomePresentationCacheTests: XCTestCase {
    func testStaleDiskCacheRestoresOnlyCurrentVisibleContent() throws {
        let song = Song(id: "kept", title: "Updated title", fileFormat: .mp3, filePath: "/kept.mp3", sourceID: "source")
        let album = Album(id: "kept-album", title: "Updated album")
        let cached = PersistedHomeSnapshot(
            version: PersistedHomeSnapshot.currentVersion, dayStamp: 20200101,
            visibleSongCount: 99, visibleAlbumCount: 50, visibleArtistCount: 10,
            recentSongIDs: ["removed"], heroSongIDs: ["removed", "kept"],
            recentlyAddedAlbums: [
                PersistedHomeAlbumTile(albumID: "removed-album", artworkSongID: "removed"),
                PersistedHomeAlbumTile(albumID: album.id, artworkSongID: "removed")
            ],
            recommendations: [
                PersistedHomeRecommendation(songID: "removed", score: 100, reasons: []),
                PersistedHomeRecommendation(songID: song.id, score: 80, reasons: [])
            ]
        )
        let restored = try XCTUnwrap(HomeView.rehydrateInitialHomePayload(
            cached, visibleAlbums: [album], songForID: { $0 == song.id ? song : nil }
        ))
        XCTAssertEqual(restored.heroCoverSongs.map(\.id), [song.id])
        XCTAssertEqual(restored.forYouResults.map(\.song.title), ["Updated title"])
        XCTAssertEqual(restored.recentlyAddedAlbums.map(\.album.title), ["Updated album"])
        XCTAssertNil(restored.recentlyAddedAlbums.first?.artworkSong)

        let removedSource = try XCTUnwrap(HomeView.rehydrateInitialHomePayload(
            cached, visibleAlbums: [], songForID: { _ in nil }
        ))
        XCTAssertTrue(removedSource.heroCoverSongs.isEmpty)
        XCTAssertTrue(removedSource.recentlyAddedAlbums.isEmpty)
        XCTAssertTrue(removedSource.forYouResults.isEmpty)
    }

    func testRecommendationSnapshotBuildsOffMainThreadWithVisiblePlayableSeeds() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let playable = Song(id: "playable", title: "Song", fileFormat: .mp3, filePath: "/song.mp3", sourceID: "source")
        let unavailable = Song(id: "unavailable", title: "Unavailable", fileFormat: .mp3, filePath: "", sourceID: "source")
        func entry(_ id: String, daysAgo: Double) -> PlayHistoryStore.Entry {
            PlayHistoryStore.Entry(songID: id, songTitle: id, artistName: "Artist", albumTitle: "Album",
                playedAt: now.addingTimeInterval(-daysAgo * 86_400), listenedSec: 60, sourceID: "source")
        }
        let snapshot = MusicDiscoveryEngine.RecommendationSnapshot(
            songs: [playable, unavailable], recentSongs: [playable, unavailable, playable],
            historyEntries: [entry("playable", daysAgo: 2), entry("removed", daysAgo: 20), entry("future", daysAgo: -1)],
            now: now
        )
        let worker = Task.detached { [snapshot] in
            HomePresentationCacheTests.prepareRecommendationSnapshot(snapshot)
        }
        let result = await worker.value
        XCTAssertFalse(result.1)
        XCTAssertEqual(result.0.songs.map(\.id), [playable.id])
        XCTAssertEqual(result.0.seedIDs, [playable.id])
        XCTAssertEqual(result.0.recentWeekIDs, ["playable"])
        XCTAssertEqual(result.0.recentMonthIDs, ["playable", "removed"])
        XCTAssertTrue(MusicDiscoveryEngine.dailyRecommendations(from: result.0, isCancelled: { true }).isEmpty)
    }

    private nonisolated static func prepareRecommendationSnapshot(
        _ snapshot: MusicDiscoveryEngine.RecommendationSnapshot
    ) -> (MusicDiscoveryEngine.RecommendationInput, Bool) {
        (snapshot.makeInput(), Thread.isMainThread)
    }

    private func signature(
        library: Int = 1, history: Int = 1, pins: String = "",
        recommendations: Bool = true
    ) -> HomeView.HomeSnapshotSignature {
        HomeView.HomeSnapshotSignature(
            libraryRevision: library, playlistRevision: 1, historyRevision: history,
            visibleSongCount: 2, visibleAlbumCount: 1, visibleArtistCount: 1,
            recentSongIDs: ["one"], dayStamp: 20260908,
            localeIdentifier: "zh-Hans_CN", timeZoneIdentifier: "Asia/Shanghai",
            quickAccess: pins, favoritesRevision: 6, showsRecommendations: recommendations
        )
    }

    func testReturningToCompletedHomeReusesSnapshotButSameCountEditsInvalidateIt() {
        let model = HomeView.Model()
        let original = signature()
        model.isPrepared = true
        model.signature = original
        model.highlightsSignature = original
        model.recommendationSignature = original

        XCTAssertFalse(model.needsRefresh(for: signature()))
        XCTAssertTrue(model.needsRefresh(for: signature(library: 2)))
        XCTAssertTrue(model.needsRefresh(for: signature(history: 2)))
        XCTAssertTrue(model.needsRefresh(for: signature(pins: "changed-pins")))
    }

    func testLeavingDuringRefreshDoesNotMakePartialResultsReusable() {
        let model = HomeView.Model()
        let previous = signature(library: 1)
        let current = signature(library: 2)
        model.isPrepared = true
        model.signature = current
        model.highlightsSignature = current
        model.recommendationSignature = previous

        XCTAssertTrue(model.needsRefresh(for: current))
        model.recommendationSignature = current
        XCTAssertFalse(model.needsRefresh(for: current))
    }

    func testHiddenRecommendationsDoNotKeepHomeCachePending() {
        let model = HomeView.Model()
        let current = signature(recommendations: false)
        model.isPrepared = true
        model.signature = current
        model.highlightsSignature = current

        XCTAssertFalse(model.needsRefresh(for: current))
        XCTAssertTrue(model.needsRefresh(for: signature(recommendations: true)))
    }

    func testReturningToFoldersReusesIndexAndCatchesMissedMetadataOrNames() {
        let model = HomeDiscoveryModel()
        let song = Song(
            id: "one", title: "One", fileFormat: .mp3,
            filePath: "/Music/one.mp3", sourceID: "source"
        )
        let source = LibraryFolderSourceDescriptor(
            sourceID: "source", displayName: "Library",
            scanRoots: ["/Music"], pathSemantics: .hierarchical
        )
        let request = HomeDiscoveryModel.Request(
            collection: 1, playlists: 1, hierarchy: 1, names: 0, sources: [source]
        )
        let token = UUID()
        let names = ["source": ["/Music": "Music"]]
        XCTAssertTrue(model.needsRebuild(for: request, metadataToken: token, directoryNames: names))
        model.publish(
            index: LibraryFolderIndexBuilder.build(sources: [source], songs: [song]),
            songs: [song.id: song], covers: [:], request: request,
            metadataToken: token, directoryNames: names
        )
        let publishedRevision = model.revision

        XCTAssertFalse(model.needsRebuild(for: request, metadataToken: token, directoryNames: names))
        model.refreshHistory()
        XCTAssertEqual(model.revision, publishedRevision)
        XCTAssertEqual(model.songsByID[song.id]?.title, "One")
        XCTAssertTrue(model.needsRebuild(for: request, metadataToken: UUID(), directoryNames: names))
        XCTAssertTrue(model.needsRebuild(
            for: request, metadataToken: token,
            directoryNames: ["source": ["/Music": "Renamed"]]
        ))

        var updated = song
        updated.title = "Edited title"
        model.updateMetadata(song: updated)
        let handledToken = UUID()
        model.handledMetadataToken = handledToken
        XCTAssertEqual(model.songsByID[song.id]?.title, "Edited title")
        XCTAssertFalse(model.needsRebuild(for: request, metadataToken: handledToken, directoryNames: names))
    }

    func testFolderRequestIsOnlyReusableAfterSuccessfulPublication() {
        let model = HomeDiscoveryModel()
        let initial = HomeDiscoveryModel.Request(
            collection: 1, playlists: 1, hierarchy: 1, names: 0, sources: []
        )
        let changed = HomeDiscoveryModel.Request(
            collection: 1, playlists: 2, hierarchy: 1, names: 0, sources: []
        )
        let token = UUID()
        model.publish(
            index: LibraryFolderIndexBuilder.build(sources: [], songs: []),
            songs: [:], covers: [:], request: initial,
            metadataToken: token, directoryNames: [:]
        )

        XCTAssertTrue(model.needsRebuild(for: changed, metadataToken: token, directoryNames: [:]))
        XCTAssertFalse(model.needsRebuild(for: initial, metadataToken: token, directoryNames: [:]))
        model.publish(
            index: LibraryFolderIndexBuilder.build(sources: [], songs: []),
            songs: [:], covers: [:], request: changed,
            metadataToken: token, directoryNames: [:]
        )
        XCTAssertFalse(model.needsRebuild(for: changed, metadataToken: token, directoryNames: [:]))
    }
}

@MainActor
final class SourcePlaylistVisibilityTests: XCTestCase {
    private func withLibrary(
        _ verify: (MusicLibrary, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourcePlaylistVisibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([
            Song(id: "remote", title: "Remote", fileFormat: .mp3,
                 filePath: "/songs/remote.mp3", sourceID: "server-a"),
            Song(id: "other", title: "Other", fileFormat: .mp3,
                 filePath: "/songs/other.mp3", sourceID: "server-b"),
        ])
        await library.waitForPendingIndex()
        try await verify(library, directory)
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Isolated playlist library failed to persist")
        }
    }

    @discardableResult
    private func mirror(
        in library: MusicLibrary, sourceID: String = "server-a",
        remoteID: String = "favorites", songs: [String] = ["remote"]
    ) -> String {
        let id = ServerPlaylistIdentity.playlistID(sourceID: sourceID, serverPlaylistID: remoteID)
        library.ensurePlaylist(id: id, name: remoteID)
        library.replaceMirrorPlaylistSongs(playlistID: id, songIDs: songs, coverArtPath: nil)
        return id
    }

    func testDisablingSourceHidesExclusivePlaylistsAndKeepsMixedAndEmptyUserPlaylists() async throws {
        try await withLibrary { library, _ in
            let server = mirror(in: library)
            let emptyServer = mirror(in: library, remoteID: "empty", songs: [])
            let local = library.createPlaylist(name: "Only remote", songIDs: ["remote"])
            let mixed = library.createPlaylist(name: "Mixed", songIDs: ["remote", "other"])
            let empty = library.createPlaylist(name: "Empty")
            let revision = library.playlistCollectionRevision

            library.updateDisabledSourceIDs(["server-a"])

            let visible = Set(library.playlists.map(\.id))
            XCTAssertFalse(visible.contains(server))
            XCTAssertFalse(visible.contains(emptyServer))
            XCTAssertFalse(visible.contains(local.id))
            XCTAssertTrue(visible.contains(mixed.id))
            XCTAssertTrue(visible.contains(empty.id))
            XCTAssertEqual(library.songs(forPlaylist: mixed.id).map(\.id), ["other"])
            XCTAssertEqual(library.rawSongIDs(forPlaylist: mixed.id), ["remote", "other"])
            XCTAssertEqual(library.rawSongIDs(forPlaylist: server), ["remote"])
            XCTAssertTrue(library.hiddenMirrorPlaylists.isEmpty)
            XCTAssertGreaterThan(library.playlistCollectionRevision, revision)

            await library.updateDisabledSourceIDsInBackground([])
            XCTAssertTrue(Set(library.playlists.map(\.id)).isSuperset(of: [server, emptyServer, local.id]))
            XCTAssertEqual(library.songs(forPlaylist: mixed.id).map(\.id), ["remote", "other"])
        }
    }

    func testMixedSourcePlaylistRemainsVisibleEvenWhenBothSourcesAreDisabled() async throws {
        try await withLibrary { library, _ in
            let mixed = library.createPlaylist(name: "Mixed", songIDs: ["remote", "other"])
            let mixedMirror = mirror(in: library, songs: ["other", "remote"])
            library.updateDisabledSourceIDs(["server-a", "server-b"])

            XCTAssertTrue(library.playlists.contains { $0.id == mixed.id })
            XCTAssertTrue(library.playlists.contains { $0.id == mixedMirror })
        }
    }

    func testMembershipAndSongSourceChangesInvalidateVisibilityCache() async throws {
        try await withLibrary { library, _ in
            let playlist = library.createPlaylist(name: "Editable", songIDs: ["remote"])
            library.updateDisabledSourceIDs(["server-a"])
            XCTAssertFalse(library.playlists.contains { $0.id == playlist.id })

            library.add(songIDs: ["other"], toPlaylist: playlist.id)
            XCTAssertTrue(library.playlists.contains { $0.id == playlist.id })

            library.replacePlaylistSongs(playlistID: playlist.id, songIDs: ["remote"])
            XCTAssertFalse(library.playlists.contains { $0.id == playlist.id })

            var moved = try XCTUnwrap(library.song(id: "remote"))
            moved.sourceID = "server-b"
            library.addSongs([moved], pruneMissingSongs: false)
            await library.waitForPendingIndex()
            XCTAssertTrue(library.playlists.contains { $0.id == playlist.id })
        }
    }

    func testBackgroundDisableInvalidatesEmptyMirrorVisibility() async throws {
        try await withLibrary { library, _ in
            let emptyMirror = mirror(in: library, sourceID: "empty-source", songs: [])
            let songRevision = library.visibleSongCollectionRevision
            let playlistRevision = library.playlistCollectionRevision

            await library.updateDisabledSourceIDsInBackground(["empty-source"])

            XCTAssertEqual(library.visibleSongCollectionRevision, songRevision)
            XCTAssertGreaterThan(library.playlistCollectionRevision, playlistRevision)
            XCTAssertFalse(library.playlists.contains { $0.id == emptyMirror })
            library.updateDisabledSourceIDs([])
            XCTAssertTrue(library.playlists.contains { $0.id == emptyMirror })
        }
    }

    func testUnresolvedImportedMembersKeepPlaylistVisible() async throws {
        try await withLibrary { library, _ in
            let pending = PlaylistPendingEntry(title: "Unmatched", artists: ["Artist"], origin: "import")
            let playlist = library.createPlaylist(name: "Imported", members: [.song("remote"), .pending(pending)])
            library.updateDisabledSourceIDs(["server-a"])
            XCTAssertTrue(library.playlists.contains { $0.id == playlist.id })
            XCTAssertEqual(library.pendingEntryCount(forPlaylist: playlist.id), 1)
        }
    }

    func testManualHidingSurvivesServerSyncAndRestoresOnlySelectedSource() async throws {
        try await withLibrary { library, directory in
            let first = mirror(in: library)
            let second = mirror(in: library, sourceID: "server-b", songs: ["other"])
            library.hideMirrorPlaylist(id: first)
            library.hideMirrorPlaylist(id: second)
            let source = MusicSource(id: "server-a", name: "Server", type: .navidrome)
            let snapshot = ServerPlaylistSnapshot(playlists: [
                ServerPlaylist(id: "favorites", name: "Renamed favorites", trackIDs: ["remote"]),
            ])
            _ = ServerPlaylistMirror.apply(snapshot: snapshot, source: source, library: library)
            XCTAssertFalse(library.playlists.contains { $0.id == first })
            XCTAssertEqual(library.rawSongIDs(forPlaylist: first), ["remote"])
            XCTAssertEqual(library.hiddenMirrorPlaylists(forSourceID: "server-a").map(\.playlistID), [first])

            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: "server-a").first)
            library.restoreHiddenMirrorPlaylist(hidden)
            XCTAssertTrue(library.playlists.contains { $0.id == first })
            XCTAssertFalse(library.playlists.contains { $0.id == second })
            XCTAssertTrue(library.hiddenMirrorPlaylists(forSourceID: "server-a").isEmpty)
            guard case .success = await library.persistNowAndWait() else {
                return XCTFail("Restore did not persist")
            }

            let reloaded = MusicLibrary(storageDirectory: directory)
            XCTAssertTrue(reloaded.playlists.contains { $0.id == first })
            XCTAssertFalse(reloaded.playlists.contains { $0.id == second })
            XCTAssertEqual(reloaded.hiddenMirrorPlaylists(forSourceID: "server-b").map(\.playlistID), [second])
        }
    }

    func testRestoreWhileDisabledShowsPlaylistAfterSourceIsEnabled() async throws {
        try await withLibrary { library, _ in
            let id = mirror(in: library)
            library.hideMirrorPlaylist(id: id)
            library.updateDisabledSourceIDs(["server-a"])
            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: "server-a").first)
            library.restoreHiddenMirrorPlaylist(hidden)
            _ = ServerPlaylistMirror.apply(
                snapshot: ServerPlaylistSnapshot(playlists: [
                    ServerPlaylist(id: "favorites", name: "Favorites", trackIDs: ["remote"]),
                ]),
                source: MusicSource(id: "server-a", name: "Server", type: .navidrome),
                library: library
            )
            XCTAssertFalse(library.playlists.contains { $0.id == id })
            XCTAssertTrue(library.hiddenMirrorPlaylists.isEmpty)

            library.updateDisabledSourceIDs([])
            XCTAssertTrue(library.playlists.contains { $0.id == id })
        }
    }

    func testRestoringPrunedMirrorAllowsNextSyncToShowItAgain() async throws {
        try await withLibrary { library, _ in
            let id = mirror(in: library)
            library.hideMirrorPlaylist(id: id)
            library.prunePlaylists(withIDPrefix: ServerPlaylistIdentity.playlistIDPrefix(sourceID: "server-a"), keepingIDs: [])
            XCTAssertNil(library.playlist(id: id))
            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: "server-a").first)
            library.restoreHiddenMirrorPlaylist(hidden)

            _ = ServerPlaylistMirror.apply(
                snapshot: ServerPlaylistSnapshot(playlists: [
                    ServerPlaylist(id: "favorites", name: "Favorites", trackIDs: ["remote"]),
                ]),
                source: MusicSource(id: "server-a", name: "Server", type: .navidrome),
                library: library
            )
            XCTAssertTrue(library.playlists.contains { $0.id == id })
            XCTAssertEqual(library.songs(forPlaylist: id).map(\.id), ["remote"])
        }
    }

    func testColdStartupPreservesDisabledMembershipAndManualRestore() async throws {
        try await withLibrary { library, directory in
            let automatic = mirror(in: library)
            let manual = mirror(in: library, sourceID: "server-b", songs: ["other"])
            library.hideMirrorPlaylist(id: manual)
            let suppression = try XCTUnwrap(library.hiddenMirrorPlaylists.first)
            guard case .success = await library.persistNowAndWait() else {
                return XCTFail("Fixture did not persist")
            }
            let preparing = MusicLibrary.makePreparing(storageDirectory: directory, disabledSourceIDs: ["server-a"])
            preparing.restoreHiddenMirrorPlaylist(suppression)
            let prepared = await MusicLibrary.prepareStartup(disabledSourceIDs: ["server-a"], storageDirectory: directory)
            preparing.publish(prepared)

            XCTAssertFalse(preparing.playlists.contains { $0.id == automatic })
            XCTAssertTrue(preparing.playlists.contains { $0.id == manual })
            XCTAssertEqual(preparing.rawSongIDs(forPlaylist: automatic), ["remote"])
            preparing.updateDisabledSourceIDs([])
            XCTAssertTrue(preparing.playlists.contains { $0.id == automatic })
            guard case .success = await preparing.persistNowAndWait() else {
                return XCTFail("Prepared restore did not persist")
            }
        }
    }

    func testAppleMusicDisableAndManualHidingUseIndependentVisibilityRules() async throws {
        try await withLibrary { library, _ in
            library.updateAppleMusicLibrarySyncEnabled(true)
            library.updateAppleMusicSourceInstalled(true)
            let id = AppleMusicLibraryIdentity.systemPlaylistID
            library.ensurePlaylist(id: id, name: "Apple Music")
            library.updateDisabledSourceIDs([AppleMusicLibraryIdentity.sourceID])
            XCTAssertFalse(library.playlists.contains { $0.id == id })
            library.updateDisabledSourceIDs([])
            XCTAssertTrue(library.playlists.contains { $0.id == id })

            library.hideMirrorPlaylist(id: id)
            let hidden = try XCTUnwrap(library.hiddenMirrorPlaylists(forSourceID: AppleMusicLibraryIdentity.sourceID).first)
            library.updateAppleMusicLibrarySyncEnabled(false)
            library.restoreHiddenMirrorPlaylist(hidden)
            XCTAssertFalse(library.playlists.contains { $0.id == id })
            library.updateAppleMusicLibrarySyncEnabled(true)
            XCTAssertTrue(library.playlists.contains { $0.id == id })
        }
    }
}

@MainActor
final class PlaylistBatchImportWriteTests: XCTestCase {
    func testBatchCreatesMergesAndLikesAndSurvivesReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistBatchImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs([
            Song(id: "a", title: "Alpha", fileFormat: .mp3, filePath: "/songs/a.mp3", sourceID: "local"),
            Song(id: "b", title: "Bravo", fileFormat: .mp3, filePath: "/songs/b.mp3", sourceID: "local"),
            Song(id: "c", title: "Charlie", fileFormat: .mp3, filePath: "/songs/c.mp3", sourceID: "local"),
        ])
        await library.waitForPendingIndex()
        let existing = library.createPlaylist(name: "Road Trip", songIDs: ["a"])
        let pending = PlaylistPendingEntry(title: "Missing", artists: ["Nobody"], origin: "file")

        library.importPlaylists([
            .newPlaylist(name: "Fresh", members: [.song("b"), .pending(pending)]),
            .merge(members: [.song("a"), .song("c")], playlistID: existing.id),
            // 歌单里已经都有了: 不改动, 也不报错。
            .merge(members: [.song("a")], playlistID: existing.id),
            .likedSongs(songIDs: ["c"]),
            .likedSongs(songIDs: ["b", "c"]),
        ])

        let fresh = try XCTUnwrap(library.playlists.first { $0.name == "Fresh" })
        XCTAssertEqual(library.rawSongIDs(forPlaylist: fresh.id), ["b", pending.id])
        XCTAssertEqual(library.pendingEntryCount(forPlaylist: fresh.id), 1)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: existing.id), ["a", "c"])
        XCTAssertTrue(library.isLiked(songID: "b"))
        XCTAssertTrue(library.isLiked(songID: "c"))
        XCTAssertFalse(library.isLiked(songID: "a"))
        XCTAssertEqual(library.rawSongIDs(forPlaylist: MusicLibrary.likedSongsPlaylistID), ["c", "b"])

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Batch import did not persist")
        }
        let reloaded = MusicLibrary(storageDirectory: directory)
        let reloadedFresh = try XCTUnwrap(reloaded.playlists.first { $0.id == fresh.id })
        XCTAssertEqual(reloaded.rawSongIDs(forPlaylist: reloadedFresh.id), ["b", pending.id])
        XCTAssertEqual(reloaded.pendingEntry(id: pending.id)?.title, "Missing")
        XCTAssertEqual(reloaded.rawSongIDs(forPlaylist: existing.id), ["a", "c"])
    }
}

@MainActor
final class LibraryPreviewSessionTests: XCTestCase {
    func testSuccessfulSourceSyncAdvancesPreviewInvalidationRevision() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseSourceSyncRevisionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let initialRevision = library.sourceSyncCompletionRevision

        library.sourceSyncDidComplete()

        XCTAssertEqual(library.sourceSyncCompletionRevision, initialRevision + 1)
    }

    func testIdenticalMirrorPlaylistSnapshotDoesNotAdvanceRevision() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseMirrorPlaylistNoopTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let songs = [
            Song(id: "one", title: "One", fileFormat: .mp3, filePath: "/songs/one.mp3", sourceID: "source"),
            Song(id: "two", title: "Two", fileFormat: .mp3, filePath: "/songs/two.mp3", sourceID: "source"),
        ]
        library.addSongs(songs, affectedSourceIDs: ["source"])
        let playlistID = ServerPlaylistIdentity.playlistID(
            sourceID: "source",
            serverPlaylistID: "favorites"
        )
        library.ensurePlaylist(id: playlistID, name: "Favorites")
        library.replaceMirrorPlaylistSongs(
            playlistID: playlistID,
            songIDs: ["one", "two"],
            coverArtPath: "cover-1"
        )
        let revision = library.playlistCollectionRevision
        let updatedAt = try XCTUnwrap(library.playlist(id: playlistID)?.updatedAt)

        library.replaceMirrorPlaylistSongs(
            playlistID: playlistID,
            songIDs: ["one", "two"],
            coverArtPath: "cover-1"
        )

        XCTAssertEqual(library.playlistCollectionRevision, revision)
        XCTAssertEqual(library.playlist(id: playlistID)?.updatedAt, updatedAt)

        library.replaceMirrorPlaylistSongs(
            playlistID: playlistID,
            songIDs: ["two", "one"],
            coverArtPath: "cover-1"
        )
        XCTAssertEqual(library.playlistCollectionRevision, revision + 1)
    }

    func testAppleMusicSnapshotPrunesDeletedPlaylistWithoutDeletingLibrarySongs() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseAppleMusicPlaylistPruneTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let sourceID = AppleMusicLibraryIdentity.sourceID
        let song = Song(
            id: "apple-song",
            title: "Apple Song",
            fileFormat: .aac,
            filePath: "i.apple-song",
            sourceID: sourceID
        )
        library.addSongs([song], affectedSourceIDs: [sourceID])

        let removedPlaylistID = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.removed"
        let retainedPlaylistID = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.retained"
        for (id, name) in [
            (AppleMusicLibraryIdentity.systemPlaylistID, "Apple Music Library"),
            (removedPlaylistID, "Primuse Bulk"),
            (retainedPlaylistID, "Retained"),
        ] {
            library.ensurePlaylist(id: id, name: name)
            library.replaceMirrorPlaylistSongs(
                playlistID: id,
                songIDs: [song.id],
                coverArtPath: nil
            )
        }

        library.prunePlaylists(
            withIDPrefix: AppleMusicLibraryIdentity.userPlaylistIDPrefix,
            keepingIDs: [retainedPlaylistID]
        )

        XCTAssertNil(library.playlist(id: removedPlaylistID))
        XCTAssertNotNil(library.playlist(id: retainedPlaylistID))
        XCTAssertNotNil(library.playlist(id: AppleMusicLibraryIdentity.systemPlaylistID))
        XCTAssertEqual(library.song(id: song.id)?.sourceID, sourceID)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: retainedPlaylistID), [song.id])
        XCTAssertEqual(
            library.rawSongIDs(forPlaylist: AppleMusicLibraryIdentity.systemPlaylistID),
            [song.id]
        )
    }

    func testMergeOnlyServerFallbackPreservesMissingRowsAndLocalEnrichment() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseServerFallbackMergeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        var existing = Song(
            id: "one",
            title: "One",
            albumID: "provider-old",
            artistID: "provider-artist-old",
            albumTitle: "Album",
            artistName: "Artist",
            duration: 180,
            fileFormat: .mp3,
            filePath: "/songs/one.mp3",
            sourceID: "source",
            fileSize: 1_024,
            revision: "r1"
        )
        existing.lyricsText = "local lyrics"
        existing.replayGainTrackGain = -7.25
        let missingFromFallback = Song(
            id: "two",
            title: "Two",
            fileFormat: .mp3,
            filePath: "/songs/two.mp3",
            sourceID: "source"
        )
        library.addSongs([existing, missingFromFallback], affectedSourceIDs: ["source"])
        let locallyEnriched = try XCTUnwrap(library.song(id: existing.id))

        var incoming = existing
        incoming.albumID = "provider-new"
        incoming.artistID = "provider-artist-new"
        incoming.lyricsText = nil
        incoming.replayGainTrackGain = nil
        library.addSongs(
            [incoming],
            affectedSourceIDs: ["source"],
            pruneMissingSongs: false,
            mergeServerCatalogRows: true
        )

        XCTAssertEqual(library.song(id: existing.id), locallyEnriched)
        XCTAssertNotNil(library.song(id: missingFromFallback.id))
    }

    func testProgressiveServerPagesAreVisibleWithoutPruningEarlierRows() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseProgressiveServerPageTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let existing = Song(
            id: "existing",
            title: "Existing",
            fileFormat: .mp3,
            filePath: "/songs/existing.mp3",
            sourceID: "source"
        )
        let firstPage = Song(
            id: "page-one",
            title: "Page One",
            fileFormat: .flac,
            filePath: "/songs/page-one.flac",
            sourceID: "source"
        )
        library.addSongs([existing], affectedSourceIDs: ["source"])

        library.addSongs(
            [firstPage],
            affectedSourceIDs: ["source"],
            notifyRemovals: false,
            pruneMissingSongs: false,
            mergeServerCatalogRows: true
        )
        library.addSongs(
            [firstPage],
            affectedSourceIDs: ["source"],
            notifyRemovals: false,
            pruneMissingSongs: false,
            mergeServerCatalogRows: true
        )

        XCTAssertNotNil(library.song(id: existing.id))
        XCTAssertNotNil(library.song(id: firstPage.id))
        XCTAssertEqual(library.songs.filter { $0.sourceID == "source" }.count, 2)
    }

    func testFormatAndCueReplacementSurvivesBareRowMergeAndPublishesContentChange() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseServerFormatReplacementTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        var existing = Song(
            id: "disc-track",
            title: "Track",
            albumTitle: "Album",
            artistName: "Artist",
            duration: 180,
            fileFormat: .mp3,
            filePath: "/music/disc.mp3",
            sourceID: "source",
            fileSize: 4_096,
            bitRate: 320,
            revision: "r1"
        )
        existing.lyricsText = "device enrichment"
        library.addSongs([existing], affectedSourceIDs: ["source"])

        let contentChanged = expectation(description: "content replacement notification")
        let token = NotificationCenter.default.addObserver(
            forName: .primuseSongContentChanged,
            object: nil,
            queue: nil
        ) { _ in
            contentChanged.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let incoming = Song(
            id: existing.id,
            title: existing.title,
            fileFormat: .flac,
            filePath: "/music/disc.flac",
            sourceID: existing.sourceID,
            fileSize: existing.fileSize,
            cueSheetPath: "/music/disc.cue",
            cueStartTime: 15,
            cueEndTime: 195,
            revision: existing.revision
        )
        library.addSongs(
            [incoming],
            affectedSourceIDs: ["source"],
            mergeServerCatalogRows: true
        )

        XCTAssertEqual(XCTWaiter().wait(for: [contentChanged], timeout: 0), .completed)
        let replaced = try XCTUnwrap(library.song(id: existing.id))
        XCTAssertEqual(replaced.fileFormat, .flac)
        XCTAssertEqual(replaced.cueSheetPath, incoming.cueSheetPath)
        XCTAssertEqual(replaced.cueStartTime, incoming.cueStartTime)
        XCTAssertEqual(replaced.cueEndTime, incoming.cueEndTime)
        XCTAssertNil(replaced.lyricsText)
    }

    func testLargeSourceRemovalPublishesPrecomputedIDsAndRetainsOtherSources() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseLargeSourceRemovalTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let removedSongs = (0..<2_048).map { index in
            Song(
                id: "removed-\(index)",
                title: "Removed \(index)",
                fileFormat: .flac,
                filePath: "/removed/\(index).flac",
                sourceID: "large-source"
            )
        }
        let retainedSongs = (0..<32).map { index in
            Song(
                id: "retained-\(index)",
                title: "Retained \(index)",
                fileFormat: .mp3,
                filePath: "/retained/\(index).mp3",
                sourceID: "other-source"
            )
        }
        library.addSongs(
            removedSongs + retainedSongs,
            affectedSourceIDs: ["large-source", "other-source"]
        )

        let notification = expectation(description: "source-scoped song removal")
        let token = NotificationCenter.default.addObserver(
            forName: .primuseSongsRemoved,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(
                Set((note.userInfo?["sourceIDs"] as? [String]) ?? []),
                ["large-source"]
            )
            XCTAssertEqual(
                (note.userInfo?["songIDs"] as? Set<String>)?.count,
                removedSongs.count
            )
            notification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let removedIDs = await library.removeSongsForSources(["large-source"])

        await fulfillment(of: [notification], timeout: 1)
        XCTAssertEqual(removedIDs.count, removedSongs.count)
        XCTAssertEqual(library.songs.map(\.id), retainedSongs.map(\.id))
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The isolated library did not finish persistence")
            return
        }
    }
}

#if os(iOS)
@MainActor
final class SpokenWordTranscriptReaderRefreshTests: XCTestCase {
    func testEditedTextAppearsWithoutChangingCueIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptRefresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "TranscriptRefresh-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(storageDirectory: directory)
        let player = AudioPlayerService(library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Reading text must not start playback") })
        let size = CGSize(width: 375, height: 812)
        func reader(_ text: String) -> some View {
            SpokenWordTranscriptReader(lines: [LyricLine(id: "same-cue", timestamp: 0, text: text)],
                                       title: "Transcript", player: player)
                .defaultAppStorage(defaults)
                .environment(AppServices.shared.themeService)
                .frame(width: size.width, height: size.height)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: reader("Original passage."))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func visibleText() throws -> String {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(try visibleText().contains("Original passage"))
        host.rootView = reader("Updated passage.")
        try await Task.sleep(for: .milliseconds(700))
        let updated = try visibleText()
        XCTAssertTrue(updated.contains("Updated passage"), updated)
        XCTAssertFalse(updated.contains("Original passage"), updated)
    }
}
#endif
