import Foundation
import XCTest
import SwiftUI
import UIKit
import Observation
import Vision
import PrimuseKit
@testable import Primuse

final class AlbumMetadataTests: XCTestCase {
    func testDiscAndTrackIdentityMatchesWithinOneRelease() {
        var first = song("first", title: "Intro", track: 1)
        first.discNumber = 1
        var second = song("second", title: "Intro", track: 1)
        second.discNumber = 2
        let tracks = [track("a", title: "Intro", number: 1, disc: 1), track("b", title: "Intro", number: 1, disc: 2)]
        XCTAssertEqual(AlbumMetadataMatching.assignments(songs: [second, first], tracks: tracks), ["first": "a", "second": "b"])
    }

    func testAmbiguousTitlesAndDuplicateFilesStayUnmatched() {
        let local = song("local", title: "Intro")
        let tracks = [track("a", title: "Intro", number: 1, disc: 1), track("b", title: "Intro", number: 1, disc: 2)]
        XCTAssertTrue(AlbumMetadataMatching.assignments(songs: [local], tracks: tracks).isEmpty)
        XCTAssertTrue(AlbumMetadataMatching.assignments(songs: [local, song("copy", title: "Intro")], tracks: [tracks[0]]).isEmpty)
    }

    func testWrongDurationAndConflictingTitleNeverMatchByPositionAlone() {
        var local = song("local", title: "Wrong Version", track: 1)
        local.duration = 180
        XCTAssertTrue(AlbumMetadataMatching.assignments(songs: [local], tracks: [track("a", title: "Intro", number: 1)]).isEmpty)
        local.title = "Intro"
        var remote = track("a", title: "Intro", number: 1)
        remote.durationMs = 260_000
        XCTAssertTrue(AlbumMetadataMatching.assignments(songs: [local], tracks: [remote]).isEmpty)
    }

    func testNumberOnlyFilenameCanUseTrackOrderWithoutZippingSelections() {
        let local = song("local", title: "Track 02", track: 2)
        XCTAssertEqual(AlbumMetadataMatching.assignments(songs: [local], tracks: [track("a", title: "First", number: 1), track("b", title: "Second", number: 2)]), ["local": "b"])
    }

    func testProposalApplicationKeepsPhysicalAudioFieldsAndAlbumArtist() {
        let local = song("local", title: "Old", track: 1)
        var remote = track("a", title: "New", number: 2)
        remote.artist = "Guest"
        remote.albumArtist = "Various Artists"
        remote.album = "Compilation"
        remote.durationMs = 200_000
        let proposals = AlbumMetadataMatching.proposals(song: local, track: remote)
        let updated = BatchTagEditService.song(local, applying: proposals)
        XCTAssertEqual(updated.title, "New")
        XCTAssertEqual(updated.albumTitle, "Compilation")
        XCTAssertEqual(updated.artistName, "Guest")
        XCTAssertEqual(updated.albumArtistName, "Various Artists")
        XCTAssertEqual(updated.duration, local.duration)
        XCTAssertEqual(updated.filePath, local.filePath)
        XCTAssertEqual(updated.fileFormat, local.fileFormat)
    }

    @MainActor
    func testUntaggedArtistAlbumFoldersAreSeparateAndDiscFoldersStayTogether() {
        var first = song("a", title: "First")
        first.filePath = "/Artist/Album A/CD1/01.flac"
        var second = song("b", title: "Second")
        second.filePath = "/Artist/Album A/CD2/01.flac"
        var third = song("c", title: "Third")
        third.filePath = "/Artist/Album B/01.flac"
        let groups = AlbumMetadataGroup.groups(for: [third, second, first, first])
        XCTAssertEqual(groups.map(\.title), ["Album A", "Album B"])
        XCTAssertEqual(groups.map { $0.songs.count }, [2, 1])
        XCTAssertEqual(groups.map(\.artist), ["Artist", "Artist"])
    }

    func testITunesSearchesAlbumsAndFetchesOnlyTheirTracks() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let scraper = ITunesScraper(session: session, requestExecutor: RequestExecutor())
        let albums = try await scraper.searchAlbums(title: "Album", artist: "Artist", limit: 20)
        XCTAssertEqual(albums.map(\.externalID), ["42"])
        let tracks = try await scraper.albumTracks(externalID: "42")
        XCTAssertEqual(tracks.map(\.externalId), ["101", "102"])
        XCTAssertEqual(tracks.map(\.discNumber), [1, 2])
        XCTAssertEqual(tracks.map(\.albumArtist), ["Album Artist", "Album Artist"])
    }

    @MainActor
    func testSameNamedAlbumsInDifferentArtistFoldersStaySeparate() {
        var first = song("first", title: "First")
        first.albumTitle = "Greatest Hits"
        first.filePath = "/Artist A/Greatest Hits/CD1/01.flac"
        var second = song("second", title: "Second")
        second.albumTitle = "Greatest Hits"
        second.filePath = "/Artist A/Greatest Hits/CD2/01.flac"
        var other = song("other", title: "Other")
        other.albumTitle = "Greatest Hits"
        other.filePath = "/Artist B/Greatest Hits/01.flac"
        let groups = AlbumMetadataGroup.groups(for: [first, second, other])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first { $0.artist == "Artist A" }?.songs.map(\.id), ["first", "second"])
        XCTAssertEqual(groups.first { $0.artist == "Artist B" }?.songs.map(\.id), ["other"])
    }

    func testMusicBrainzKeepsReleaseTrackIDsAndMultipleDiscs() async throws {
        let session = fixtureSession()
        defer { session.invalidateAndCancel() }
        let scraper = MusicBrainzScraper(session: session, requestExecutor: RequestExecutor())
        let albums = try await scraper.searchAlbums(title: "Album", artist: "Artist", limit: 20)
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.trackCount, 2)
        let tracks = try await scraper.albumTracks(externalID: try XCTUnwrap(albums.first?.externalID))
        XCTAssertEqual(tracks.map(\.externalId), ["release-track-1", "release-track-2"])
        XCTAssertEqual(tracks.map(\.discNumber), [1, 2])
        XCTAssertEqual(tracks.map(\.artist), ["Guest", "Album Artist"])
        XCTAssertEqual(tracks.map(\.albumArtist), ["Album Artist", "Album Artist"])
    }

    @MainActor
    func testAlbumSearchSheetFitsPortraitAndLandscape() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        var local = song("local", title: "Intro", track: 1)
        local.albumTitle = "The Dark Side of the Moon"
        local.artistName = "Pink Floyd"
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let window = try show(AlbumMetadataView(songs: [local]).environment(library), size: size)
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(250))
            attach(window, name: "album-search-\(Int(size.width))")
        }
    }

    @MainActor
    func testMatchingRowsShowDiscFoldersForIdenticalFilenames() async throws {
        var first = song("first", title: "01.flac", track: 1)
        first.filePath = "/Artist/Album/CD1/01.flac"
        var second = song("second", title: "01.flac", track: 1)
        second.filePath = "/Artist/Album/CD2/01.flac"
        let tracks = [track("a", title: "Intro", number: 1, disc: 1), track("b", title: "Intro", number: 1, disc: 2)]
        let view = NavigationStack {
            List {
                AlbumMetadataTrackRow(song: first, ordinal: 1, tracks: tracks, assignments: .constant(["first": "a"]))
                AlbumMetadataTrackRow(song: second, ordinal: 2, tracks: tracks, assignments: .constant([:]))
            }.navigationTitle("album_metadata_match")
        }
        let window = try show(view, size: CGSize(width: 390, height: 844))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        attach(window, name: "album-matching-disc-folders")
    }

    @MainActor
    func testLoadingLibraryAllowsTabSwitchingAndKeepsSelectionWhenPublished() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let probe = LoadingNavigationProbe()
        let view = TabView(selection: Binding(get: { probe.selection }, set: { probe.selection = $0 })) {
            LibraryReadyContent {
                Text("Loaded Library").onAppear { probe.libraryAppeared = true }
            }.tabItem { Label("home_title", systemImage: "house") }.tag(0)
            Text("Settings").onAppear { probe.settingsAppeared = true }
                .tabItem { Label("settings_title", systemImage: "gearshape") }.tag(1)
        }
        .environment(library)
        .environment(AppServices.shared.playerService)
        .environment(AppServices.shared.sourcesStore)
        let window = try show(view, size: CGSize(width: 390, height: 844))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(probe.libraryAppeared)
        attach(window, name: "startup-navigation-before-library")
        probe.selection = 1
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(probe.settingsAppeared)
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(probe.selection, 1)
        probe.selection = 0
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(probe.libraryAppeared)
    }

    @MainActor
    func testStartupKeepsNormalLibraryNavigationWithoutTemporarySongRows() async throws {
        let suite = "StartupDestinationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path)
        try store.replaceAll(with: [song("startup", title: "Startup Sentinel")])
        try store.markMigrationCompleted(version: 10)
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        sources.add(MusicSource(id: "source", name: "Startup Source", type: .local))
        let player = AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Startup rendering must not play audio") }
        )

        for size in [CGSize(width: 390, height: 844), CGSize(width: 1024, height: 768)] {
            for section: LibrarySection? in [nil, .albums, .songs] {
                let view = startupLibraryView(
                    LibraryView(rootSection: section), library: library,
                    sources: sources, player: player, defaults: defaults, directory: directory
                )
                let window = try show(view, size: size)
                defer { window.isHidden = true; window.rootViewController = nil }
                try await Task.sleep(for: .milliseconds(800))
                let text = try recognizedText(window, name: "startup-\(section?.rawValue ?? "home")-\(Int(size.width))")
                XCTAssertFalse(library.isReady)
                XCTAssertFalse(text.contains("StartupSentinel"), text)
                XCTAssertTrue(text.contains("准备资料库"), text)
                XCTAssertTrue(text.contains(section == .songs ? "歌曲" : section == .albums ? "专辑" : "资料库"), text)
            }
        }
    }

    @MainActor
    func testRememberedLibraryDetailWaitsForPublicationAndYieldsToNavigation() async throws {
        for navigationOverride: LibrarySection? in [nil, .albums] {
            let suite = "StartupRestorationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: directory)
            }
            var local = song("restored", title: "Restored Track")
            local.albumTitle = "Restored Album"
            local.artistName = "Archive Artist"
            local.albumArtistName = "Archive Artist"
            MusicLibrary.fillDerivedIDs(&local)
            let pageID = "album:\(try XCTUnwrap(local.albumID))"
            defaults.set(pageID, forKey: "primuse.navigation.libraryPage.v1")
            let store = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path)
            try store.replaceAll(with: [local])
            try store.markMigrationCompleted(version: 10)
            let library = MusicLibrary.makePreparing(storageDirectory: directory)
            let sources = SourcesStore(storageDirectoryURL: directory)
            sources.add(MusicSource(id: "source", name: "Startup Source", type: .local))
            let player = AudioPlayerService(
                library: library,
                playbackSettings: PlaybackSettingsStore(defaults: defaults),
                playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
                activateAudioSession: { _ in XCTFail("Restoring navigation must not play audio") }
            )
            let probe = LoadingNavigationProbe()
            let view = startupLibraryView(
                LibraryView(deepLink: Binding(get: { probe.deepLink }, set: { probe.deepLink = $0 }),
                            onActiveSectionChange: { probe.activeSection = $0 }),
                library: library, sources: sources, player: player, defaults: defaults, directory: directory
            )
            let window = try show(view, size: CGSize(width: 390, height: 844))
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(defaults.string(forKey: "primuse.navigation.libraryPage.v1"), pageID)
            if let navigationOverride {
                probe.deepLink = .section(navigationOverride)
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(probe.activeSection, navigationOverride)
                XCTAssertEqual(defaults.string(forKey: "primuse.navigation.libraryPage.v1"), "section:\(navigationOverride.rawValue)")
            }
            library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
            XCTAssertTrue(library.isReady)
            try await waitForLibraryPush(in: window)
            let text = try recognizedText(window, name: "startup-restored-\(navigationOverride?.rawValue ?? "album")")
            XCTAssertFalse(text.contains("准备资料库"), text)
            if let navigationOverride {
                XCTAssertEqual(probe.activeSection, navigationOverride)
                XCTAssertEqual(defaults.string(forKey: "primuse.navigation.libraryPage.v1"), "section:\(navigationOverride.rawValue)")
            } else {
                XCTAssertEqual(defaults.string(forKey: "primuse.navigation.libraryPage.v1"), pageID)
                XCTAssertTrue(text.contains("RestoredAlbum"), text)
            }
        }
    }

    @MainActor
    private func waitForLibraryPush(in window: UIWindow) async throws {
        func navigationController(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            return controller.children.lazy.compactMap { navigationController(in: $0) }.first
        }
        let root = try XCTUnwrap(window.rootViewController)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let navigation = navigationController(in: root),
               navigation.viewControllers.count == 2,
               navigation.visibleViewController === navigation.topViewController,
               navigation.topViewController?.view.window === window,
               navigation.transitionCoordinator == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let navigation = try XCTUnwrap(navigationController(in: root))
        XCTAssertEqual(navigation.viewControllers.count, 2, "The remembered destination must finish pushing")
        XCTAssertTrue(navigation.visibleViewController === navigation.topViewController)
        XCTAssertTrue(navigation.topViewController?.view.window === window)
        XCTAssertNil(navigation.transitionCoordinator, "Library restoration must not leave a transition pending")
    }

    @MainActor
    private func startupLibraryView<Content: View>(
        _ content: Content, library: MusicLibrary, sources: SourcesStore,
        player: AudioPlayerService, defaults: UserDefaults, directory: URL
    ) -> some View {
        let services = AppServices.shared
        return content
            .environment(library).environment(sources).environment(player)
            .environment(RadioStationsStore(storeURL: directory.appendingPathComponent("radio.json")))
            .environment(services.sourceManager).environment(services.scanService)
            .environment(services.metadataBackfill).environment(services.scraperService)
            .environment(services.scraperSettingsStore).environment(services.themeService)
            .environment(services.batchRemoval).environment(services.musicIntelligence)
            .environment(services.playbackSettingsStore).environment(services.coverTintProvider)
            .environment(\.appNavigationMode, .standard)
            .defaultAppStorage(defaults)
    }

    @MainActor
    private func recognizedText(_ window: UIWindow, name: String) throws -> String {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().filter { !$0.isWhitespace }
    }

    @MainActor
    private func show<V: View>(_ view: V, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh-Hans")))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.frame = CGRect(origin: .zero, size: size)
        window.isHidden = false
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    @MainActor
    private func attach(_ window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fixtureSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AlbumMetadataURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func song(_ id: String, title: String, track: Int? = nil) -> Song {
        Song(id: id, title: title, trackNumber: track, duration: 180, fileFormat: .flac,
             filePath: "/Artist/Album/\(id).flac", sourceID: "source")
    }

    private func track(_ id: String, title: String, number: Int, disc: Int = 1) -> ScraperDetail {
        ScraperDetail(externalId: id, source: .itunes, title: title, trackNumber: number, discNumber: disc, durationMs: 180_000)
    }
}

private final class AlbumMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let json: String
        if url.host == "itunes.apple.com", url.path == "/search", query.contains(URLQueryItem(name: "entity", value: "album")) {
            json = #"{"resultCount":1,"results":[{"collectionId":42,"collectionName":"Album","artistName":"Album Artist","trackCount":2}]}"#
        } else if url.host == "itunes.apple.com", url.path == "/lookup", query.contains(URLQueryItem(name: "entity", value: "song")) {
            json = #"{"resultCount":4,"results":[{"collectionId":42,"collectionName":"Album","artistName":"Album Artist","trackCount":2},{"collectionId":42,"trackId":101,"trackName":"Intro","artistName":"Guest","trackNumber":1,"discNumber":1},{"collectionId":42,"trackId":102,"trackName":"Intro","trackNumber":1,"discNumber":2},{"collectionId":99,"trackId":999,"trackName":"Other album"}]}"#
        } else if ["/ws/2/release", "/ws/2/release/"].contains(url.path) {
            json = #"{"releases":[{"id":"00112233-4455-6677-8899-aabbccddeeff","title":"Album","track-count":2,"artist-credit":[{"name":"Album Artist"}]}]}"#
        } else if url.path == "/ws/2/release/00112233-4455-6677-8899-aabbccddeeff", query.contains(URLQueryItem(name: "inc", value: "recordings+artist-credits")) {
            json = #"{"id":"00112233-4455-6677-8899-aabbccddeeff","title":"Album","artist-credit":[{"name":"Album Artist"}],"media":[{"position":1,"tracks":[{"id":"release-track-1","title":"Intro","position":1,"artist-credit":[{"name":"Guest"}],"recording":{"id":"same-recording","title":"Intro"}}]},{"position":2,"tracks":[{"id":"release-track-2","title":"Intro","position":1,"recording":{"id":"same-recording","title":"Intro"}}]}]}"#
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
@Observable
private final class LoadingNavigationProbe {
    var selection = 0
    var libraryAppeared = false
    var settingsAppeared = false
    var deepLink: LibraryDeepLink?
    var activeSection: LibrarySection?
}
