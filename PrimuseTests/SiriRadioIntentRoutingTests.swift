#if os(iOS)
import Intents
import AppIntents
import PrimuseKit
import UIKit
import XCTest
@testable import Primuse

@MainActor
final class SiriRadioIntentRoutingTests: XCTestCase {
    func testHomeScreenQuickActionsReplaceCachedChineseTitlesWithEnglish() throws {
        let english = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))))
        let actions: [HomeScreenQuickAction] = [.resume, .shuffleLibrary, .shuffleLiked, .search]
        let cachedTitles = ["继续播放", "随机播放全部", "我喜欢的", "搜索"]
        let cached = zip(actions, cachedTitles).map { action, title in
            UIApplicationShortcutItem(type: action.rawValue, localizedTitle: title)
        }

        let localized = HomeScreenQuickAction.localizedShortcutItems(cached, bundle: english)

        XCTAssertEqual(localized.map(\.type), cached.map(\.type))
        XCTAssertEqual(localized.map(\.localizedTitle), ["Resume Playback", "Shuffle all", "Liked Songs", "Search"])
        XCTAssertEqual(localized[2].localizedSubtitle, "Shuffle")
        XCTAssertEqual(cached.map(\.localizedTitle), cachedTitles)
    }

    func testHomeScreenQuickActionsPreservePlaybackMetadataAndUnknownActions() throws {
        let english = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))))
        let resume = UIMutableApplicationShortcutItem(
            type: HomeScreenQuickAction.resume.rawValue,
            localizedTitle: "继续播放",
            localizedSubtitle: "晨间列车 · 测试艺术家",
            icon: UIApplicationShortcutIcon(systemImageName: "play.fill"),
            userInfo: ["songID": "test-song" as NSString]
        )
        resume.targetContentIdentifier = "player"
        let unknown = UIApplicationShortcutItem(type: "future-action", localizedTitle: "Future Action")

        let localized = HomeScreenQuickAction.localizedShortcutItems([resume, unknown], bundle: english)

        XCTAssertEqual(localized[0].localizedSubtitle, resume.localizedSubtitle)
        XCTAssertEqual(localized[0].userInfo?["songID"] as? String, "test-song")
        XCTAssertEqual(localized[0].targetContentIdentifier as? String, "player")
        XCTAssertEqual(localized[0].icon, resume.icon)
        XCTAssertTrue(localized[1] === unknown)
    }

    func testHomeScreenQuickActionsCanSwitchBackToChineseWithoutAddingItems() throws {
        let chinese = try XCTUnwrap(Bundle(path: XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))))
        let cached = [UIApplicationShortcutItem(type: HomeScreenQuickAction.search.rawValue, localizedTitle: "Search")]

        let localized = HomeScreenQuickAction.localizedShortcutItems(cached, bundle: chinese)

        XCTAssertEqual(localized.map(\.localizedTitle), ["搜索"])
        XCTAssertTrue(HomeScreenQuickAction.localizedShortcutItems([], bundle: chinese).isEmpty)
    }

    func testSongSuggestionsShareConcurrentWorkAndSurviveOneCancelledQuery() async {
        let gate = ShortcutSelectionGate()
        let cache = SiriSongSuggestionCache { songs, _, _ in await gate.select(songs) }
        let inputs = shortcutInputs()
        let songs = [shortcutSong("shared")]
        let cancelled = Task { await cache.songs(for: inputs, from: songs) }
        await gate.waitForStart("shared")
        let queries = (0..<20).map { _ in Task { await cache.songs(for: inputs, from: songs) } }
        cancelled.cancel()
        await gate.finish("shared")
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        for query in queries {
            let result = await query.value
            XCTAssertEqual(result?.map(\.id), ["shared"])
        }
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    func testSongSuggestionsDiscardAnOlderSelectionAfterLibraryChanges() async {
        let gate = ShortcutSelectionGate()
        let cache = SiriSongSuggestionCache { songs, _, _ in await gate.select(songs) }
        let old = Task { await cache.songs(for: shortcutInputs(), from: [shortcutSong("removed")]) }
        await gate.waitForStart("removed")
        let inputs = shortcutInputs(revision: 2, visibleRevision: 2)
        let current = Task { await cache.songs(for: inputs, from: [shortcutSong("kept")]) }
        await gate.waitForStart("kept")
        await gate.finish("kept")
        let selected = await current.value
        XCTAssertEqual(selected?.map(\.id), ["kept"])
        await gate.finish("removed")
        let stale = await old.value
        XCTAssertNil(stale)
        let cached = await cache.songs(for: inputs, from: [shortcutSong("kept")])
        XCTAssertEqual(cached?.map(\.id), ["kept"])
        let calls = await gate.calls
        XCTAssertEqual(calls, 2)
    }

    func testSongSuggestionCacheTracksMetadataPriorityBudgetAndRemoval() async {
        let cache = SiriSongSuggestionCache()
        let first = shortcutSong("first")
        var second = shortcutSong("second")
        let token = UUID()
        let original = await cache.songs(for: shortcutInputs(token: token), from: [first, second])
        XCTAssertEqual(original?.map(\.id), ["first", "second"])
        second.title = "不能再作为短歌名建议"
        let renamed = await cache.songs(for: shortcutInputs(), from: [first, second])
        XCTAssertEqual(renamed?.map(\.id), ["first"])
        second.title = "晴天"
        let prioritized = await cache.songs(for: shortcutInputs(token: token, priority: ["second"], limit: 1), from: [first, second])
        XCTAssertEqual(prioritized?.map(\.id), ["second"])
        let removed = await cache.songs(for: shortcutInputs(token: token, visibleRevision: 2), from: [])
        XCTAssertEqual(removed?.count, 0)
    }

    func testRepeatedImportSuggestionsReadAndDecodeEachCoverOnlyOnce() async throws {
        let artwork = shortcutArtwork(.systemTeal)
        let fixture = ShortcutArtworkFixture(data: artwork)
        let cache = PrimuseSongEntityCache(coverIdentity: { fixture.identity($0) }, coverData: { fixture.read($0) })
        let songs = (0..<693).map { shortcutSong(String(format: "%04d", $0)) }
        let selected = SiriSongCatalog.shortcuts(from: songs, priorityIDs: [], limit: 162)
        let inputs = selected.map { PrimuseSongEntityCache.Input(song: $0, artist: "艺人") }
        let queries = (0..<68).map { _ in Task { await cache.entities(for: inputs, showsArtwork: true) } }
        for query in queries {
            let entities = await query.value
            XCTAssertEqual(entities.count, 162)
            XCTAssertNotNil(entities.first?.artworkData)
        }
        XCTAssertEqual(fixture.readCount, 162)
    }

    func testSongEntityCacheUpdatesMetadataArtworkAndMissingCover() async throws {
        let fixture = ShortcutArtworkFixture(data: nil)
        let cache = PrimuseSongEntityCache(coverIdentity: { fixture.identity($0) }, coverData: { fixture.read($0) })
        var song = shortcutSong("changing")
        func query(_ artist: String = "甲", showsArtwork: Bool = true) async -> PrimuseLibrarySongEntity? {
            await cache.entities(for: [.init(song: song, artist: artist)], showsArtwork: showsArtwork).first
        }
        let missing = await query()
        let stillMissing = await query()
        XCTAssertNil(missing?.artworkData)
        XCTAssertNil(stillMissing?.artworkData)
        XCTAssertEqual(fixture.readCount, 1)
        fixture.update(data: shortcutArtwork(.systemTeal), identity: "first-cover")
        let covered = await query()
        XCTAssertNotNil(covered?.artworkData)
        fixture.update(data: shortcutArtwork(.systemPink), identity: "replacement-cover")
        let replaced = await query()
        XCTAssertNotEqual(covered?.artworkData, replaced?.artworkData)
        let readsBeforeMetadataChange = fixture.readCount
        song.title = "新名"
        song.albumTitle = "新专辑"
        song.duration = 125
        let renamed = await query("乙")
        XCTAssertEqual(renamed?.title, "新名")
        XCTAssertEqual(renamed?.subtitle, "乙 — 新专辑 · 2:05")
        XCTAssertEqual(renamed?.artworkData, replaced?.artworkData)
        XCTAssertEqual(fixture.readCount, readsBeforeMetadataChange)
        let reads = fixture.readCount
        let hidden = await query(showsArtwork: false)
        XCTAssertNil(hidden?.artworkData)
        XCTAssertEqual(fixture.readCount, reads)
        fixture.update(data: nil, identity: nil)
        let evicted = await query()
        XCTAssertNil(evicted?.artworkData)
    }

    func testSongEntityCacheKeepsRecentlyUsedEntriesWithinItsLimit() async {
        let fixture = ShortcutArtworkFixture(data: nil)
        let cache = PrimuseSongEntityCache(capacity: 2, coverIdentity: { fixture.identity($0) }, coverData: { fixture.read($0) })
        for id in ["a", "b", "a", "c", "a", "b"] {
            _ = await cache.entities(for: [.init(song: shortcutSong(id), artist: nil)], showsArtwork: true)
        }
        XCTAssertEqual(fixture.readCount, 4)
    }

    func testSongEntityCacheRecoversEvictedContentBehindUnchangedReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root)
        let data = try XCTUnwrap(shortcutArtwork(.systemTeal))
        var song = shortcutSong("evicted")
        store.storeCoverSync(data, for: song.id)
        song.coverArtFileName = store.expectedCoverFileName(for: song.id)
        let cache = PrimuseSongEntityCache(coverIdentity: {
            store.readableDisplayCoverIdentity(songID: $0.id, reference: $0.coverArtFileName)
        }, coverData: {
            store.displayCoverData(songID: $0.id, reference: $0.coverArtFileName)
        })
        let input = [PrimuseSongEntityCache.Input(song: song, artist: nil)]
        let original = await cache.entities(for: input, showsArtwork: true)
        XCTAssertNotNil(original.first?.artworkData)
        let identity = try XCTUnwrap(store.displayCoverIdentity(songID: song.id, reference: song.coverArtFileName))
        let content = store.artworkContentDirectoryURL.appendingPathComponent(
            String(identity.dropFirst("sha256:".count)) + ".jpg")
        try FileManager.default.removeItem(at: content)
        XCTAssertEqual(store.displayCoverIdentity(songID: song.id, reference: song.coverArtFileName), identity)
        let evicted = await cache.entities(for: input, showsArtwork: true)
        XCTAssertNil(evicted.first?.artworkData)
        store.storeCoverSync(data, for: song.id)
        let restored = await cache.entities(for: input, showsArtwork: true)
        XCTAssertEqual(restored.first?.artworkData, original.first?.artworkData)

        let custom = await store.storeAttributedCover(data, songID: song.id, origin: .selected)
        let customReference = try XCTUnwrap(custom)
        try FileManager.default.removeItem(at: content)
        XCTAssertNotNil(store.readableDisplayCoverIdentity(songID: song.id, reference: customReference),
                        "User-selected artwork lives outside the disposable content cache")
    }

    private func shortcutInputs(revision: UInt64 = 1, token: UUID = UUID(), visibleRevision: Int = 1,
                                priority: [String] = [], limit: Int = 162) -> SiriSongSuggestionCache.Inputs {
        .init(libraryRevision: revision, replacementToken: token, visibleRevision: visibleRevision, priorityIDs: priority, limit: limit)
    }

    private func shortcutSong(_ id: String) -> Song {
        Song(id: id, title: "晴天", fileFormat: .m4a, filePath: "Music/\(id).m4a", sourceID: "local",
             dateAdded: Date(timeIntervalSince1970: 0))
    }

    private func shortcutArtwork(_ color: UIColor) -> Data? {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData()
    }

    func testSongShortcutKeepsSearchTitleAndBoundsArtwork() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        let song = Song(id: "shortcut-presentation", title: "绿光", albumTitle: "风筝",
                        artistName: "孙燕姿", duration: 245, fileFormat: .flac, filePath: "fixture.flac", sourceID: "fixture")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 512), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        }.pngData()
        let entity = PrimuseLibrarySongEntity(song, artistDisplayName: "孙燕姿", coverData: cover, showsArtwork: true)
        XCTAssertEqual(entity.id, song.id)
        XCTAssertEqual(entity.title, "绿光")
        XCTAssertEqual(entity.subtitle, "孙燕姿 — 风筝 · 4:05")
        let thumbnail = try XCTUnwrap(entity.artworkData.flatMap { UIImage(data: $0) })
        XCTAssertEqual(thumbnail.size, CGSize(width: 128, height: 64))
        XCTAssertNotEqual(entity.displayRepresentation.image, DisplayRepresentation.Image(systemName: "music.note"))

        let hidden = PrimuseLibrarySongEntity(song, artistDisplayName: "孙燕姿", coverData: cover, showsArtwork: false)
        XCTAssertNil(hidden.artworkData)
        XCTAssertEqual(hidden.displayRepresentation.image, DisplayRepresentation.Image(systemName: "music.note"))
        // Let the hosted app clear its startup sentinel before XCTest exits.
        let remaining = 9 - (ProcessInfo.processInfo.systemUptime - started)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
    }

    func testSongShortcutHandlesMissingDetailsAndInvalidArtwork() {
        let song = Song(id: "shortcut-incomplete", title: "晴天", duration: .nan,
                        fileFormat: .flac, filePath: "fixture.flac", sourceID: "fixture")
        let entity = PrimuseLibrarySongEntity(song, artistDisplayName: nil, coverData: Data("bad image".utf8), showsArtwork: true)
        XCTAssertEqual(entity.title, "晴天")
        XCTAssertTrue(entity.subtitle.isEmpty)
        XCTAssertNil(entity.artworkData)
        XCTAssertNil(entity.displayRepresentation.subtitle)
        XCTAssertEqual(entity.displayRepresentation.image, DisplayRepresentation.Image(systemName: "music.note"))
    }

    func testPhysicalDeviceAcceptsPlaybackDonation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Siri donation acceptance requires a physical device")
        #else
        let id = "primuse-siri-test-" + UUID().uuidString
        let item = INMediaItem(identifier: id, title: "Primuse Playback Test", type: .radioStation, artwork: nil)
        let intent = INPlayMediaIntent(mediaItems: nil, mediaContainer: item, playShuffled: nil,
            playbackRepeatMode: .unknown, resumePlayback: nil, playbackQueueLocation: .unknown,
            playbackSpeed: nil, mediaSearch: nil)
        let interaction = SiriMediaInteractionDonor.playbackInteraction(intent, identifier: id)
        let donationError: NSError? = await withCheckedContinuation { continuation in
            interaction.donate { error in continuation.resume(returning: error as NSError?) }
        }
        let cleanupError: NSError? = await withCheckedContinuation { continuation in
            INInteraction.delete(with: [id]) { error in continuation.resume(returning: error as NSError?) }
        }
        XCTAssertNil(donationError, donationError.map { "\($0.domain):\($0.code)" } ?? "")
        XCTAssertNil(cleanupError, cleanupError.map { "\($0.domain):\($0.code)" } ?? "")
        #endif
    }

    func testPlaybackDonationIncludesSuccessfulResponseAndIncomingDirection() {
        let station = INMediaItem(identifier: "radio:fixture", title: "Fixture", type: .radioStation, artwork: nil)
        let intent = INPlayMediaIntent(mediaItems: nil, mediaContainer: station, playShuffled: nil,
            playbackRepeatMode: .unknown, resumePlayback: nil, playbackQueueLocation: .unknown,
            playbackSpeed: nil, mediaSearch: nil)
        let interaction = SiriMediaInteractionDonor.playbackInteraction(intent, identifier: "radio:fixture")
        XCTAssertEqual((interaction.intentResponse as? INPlayMediaIntentResponse)?.code, .success)
        XCTAssertEqual(interaction.intentHandlingStatus, .success)
        XCTAssertEqual(interaction.direction, .incoming)
        XCTAssertEqual(interaction.identifier, "radio:fixture")
        XCTAssertEqual((interaction.intent as? INPlayMediaIntent)?.mediaContainer?.identifier, "radio:fixture")
    }

    func testAppBundleDeclaresBothMediaIntentsForColdLaunch() {
        let supported = Bundle(for: PrimuseAppDelegate.self)
            .object(forInfoDictionaryKey: "INIntentsSupported") as? [String]

        XCTAssertEqual(
            Set(supported ?? []),
            Set(["INPlayMediaIntent", "INSearchForMediaIntent"])
        )
        let donationTypes = Bundle(for: PrimuseAppDelegate.self)
            .object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]
        XCTAssertTrue(donationTypes?.contains("INPlayMediaIntent") == true)
    }

    /// 系统最多认三个 Siri 别名,多一个整个 App 就装不上(installd 直接拒绝)。
    func testAppBundleDeclaresAtMostThreeAlternativeAppNames() {
        let names = Bundle(for: PrimuseAppDelegate.self)
            .object(forInfoDictionaryKey: "INAlternativeAppNames") as? [[String: Any]]

        XCTAssertNotNil(names)
        XCTAssertLessThanOrEqual(names?.count ?? 0, 3)
    }

    func testColdAppDelegateRoutesMediaSearchToTheRadioCapableHandler() {
        let delegate = PrimuseAppDelegate()
        let intent = INSearchForMediaIntent(mediaItems: nil, mediaSearch: nil)

        let handler = delegate.application(UIApplication.shared, handlerFor: intent)

        XCTAssertTrue(handler is PlayMediaIntentHandler)
        XCTAssertTrue(handler is any INSearchForMediaIntentHandling)
    }

    func testColdAppDelegateKeepsPlayMediaRoutingOnTheSameHandler() {
        let delegate = PrimuseAppDelegate()
        let intent = INPlayMediaIntent(
            mediaItems: nil,
            mediaContainer: nil,
            playShuffled: false,
            playbackRepeatMode: .unknown,
            resumePlayback: false,
            playbackQueueLocation: .now,
            playbackSpeed: nil,
            mediaSearch: nil
        )

        let handler = delegate.application(UIApplication.shared, handlerFor: intent)

        XCTAssertTrue(handler is PlayMediaIntentHandler)
        XCTAssertTrue(handler is any INPlayMediaIntentHandling)
    }
}

private actor ShortcutSelectionGate {
    private(set) var calls = 0
    private var pending: [String: CheckedContinuation<[Song], Never>] = [:]
    private var songs: [String: [Song]] = [:]
    private var started: [String: CheckedContinuation<Void, Never>] = [:]

    func select(_ songs: [Song]) async -> [Song] {
        let id = songs[0].id
        calls += 1
        self.songs[id] = songs
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            started.removeValue(forKey: id)?.resume()
        }
    }

    func waitForStart(_ id: String) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { started[id] = $0 }
    }

    func finish(_ id: String) {
        pending.removeValue(forKey: id)?.resume(returning: songs.removeValue(forKey: id) ?? [])
    }
}

private final class ShortcutArtworkFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var contentID: String?
    private var reads = 0

    init(data: Data?) {
        self.data = data
        contentID = data == nil ? nil : "cover"
    }

    var readCount: Int { lock.withLock { reads } }
    func identity(_ song: Song) -> String? { lock.withLock { contentID } }
    func read(_ song: Song) -> Data? { lock.withLock { reads += 1; return data } }
    func update(data: Data?, identity: String?) {
        lock.withLock { self.data = data; contentID = identity }
    }
}
#endif
