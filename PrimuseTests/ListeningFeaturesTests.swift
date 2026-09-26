import CoreGraphics
import Foundation
import ImageIO
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

/// App-side behaviour of the audiobook, medley, suggestion and batch-edit
/// features. The pure policies behind them are covered in PrimuseKitTests;
/// these check the wiring into the player, the stores and the library.
@MainActor
final class ListeningFeaturesTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.reversed().forEach { $0() }
        cleanups = []
        PlayHistoryStore.shared.isRecordingSuspended = false
        ScrobbleService.shared.isSuspended = false
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "listening-features-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        cleanups.append { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("listening-features-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanups.append { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makePlayer(library: MusicLibrary? = nil) throws -> AudioPlayerService {
        let directory = makeDirectory()
        return AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: try makeDefaults()),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("These tests must not start audio") }
        )
    }

    private func song(
        _ id: String,
        duration: TimeInterval = 240,
        genre: String? = nil,
        path: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: "Song \(id)",
            albumTitle: "Album",
            artistName: "Artist",
            duration: duration,
            fileFormat: .flac,
            filePath: path ?? "/music/\(id).flac",
            sourceID: "local-source",
            genre: genre
        )
    }

    // MARK: - Medley

    func testMedleySlicesCarryTheirWindowAndSkipWhatCannotBeSliced() throws {
        let player = try makePlayer()
        player.playbackSettings.medleySegmentSeconds = 45
        let slices = player.medleySlices(for: [
            song("a"),
            song("a"), // duplicate
            song("short", duration: 50),
            song("book", genre: "Audiobook"),
            song("b", duration: 300),
        ])
        XCTAssertEqual(slices.map(\.id), ["a", "short", "b"])
        let first = try XCTUnwrap(slices.first)
        XCTAssertEqual(first.cueStartTime, 79)
        XCTAssertEqual(first.cueEndTime, 124)
        XCTAssertEqual(first.duration, 45)
        // A song too short to cut plays whole.
        XCTAssertEqual(slices[1].cueStartTime, 0)
        XCTAssertEqual(slices[1].cueEndTime, 50)
    }

    func testMedleyForcesCrossfadeSuspendsHistoryAndEndsWithTheNextQueue() throws {
        let player = try makePlayer()
        player.playbackSettings.outputMode = .effects
        player.playbackSettings.crossfadeEnabled = false
        player.repeatMode = .one
        let slices = player.medleySlices(for: [song("a"), song("b"), song("c")])

        player.installMedley(slices)
        XCTAssertTrue(player.isMedleyActive)
        XCTAssertEqual(player.medleySongIDs, ["a", "b", "c"])
        XCTAssertEqual(player.queue.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(player.queue.first?.duration, 10)
        XCTAssertEqual(player.repeatMode, .off, "repeat-one would never crossfade")
        XCTAssertTrue(player.shouldUseCrossfade(player.playbackSettings.snapshot()))
        XCTAssertTrue(PlayHistoryStore.shared.isRecordingSuspended)
        XCTAssertTrue(ScrobbleService.shared.isSuspended)

        player.setQueue([song("x"), song("y")], startAt: 0)
        XCTAssertFalse(player.isMedleyActive)
        XCTAssertTrue(player.medleySongIDs.isEmpty)
        XCTAssertFalse(player.shouldUseCrossfade(player.playbackSettings.snapshot()))
        XCTAssertFalse(PlayHistoryStore.shared.isRecordingSuspended)
        XCTAssertFalse(ScrobbleService.shared.isSuspended)
    }

    func testMedleySliceSurvivesALibraryMetadataRefresh() throws {
        let player = try makePlayer()
        let slices = player.medleySlices(for: [song("a"), song("b")])
        player.installMedley(slices)

        // The library row changes (a tag edit, a backfill) and is pushed to
        // the player: the queue entry must keep its slice, not widen back to
        // the whole song.
        var refreshed = song("b")
        refreshed.title = "Renamed"
        player.syncSongMetadata(refreshed)
        let entry = try XCTUnwrap(player.queue.first { $0.id == "b" })
        XCTAssertEqual(entry.title, "Renamed")
        XCTAssertEqual(entry.cueStartTime, slices[1].cueStartTime)
        XCTAssertEqual(entry.cueEndTime, slices[1].cueEndTime)
        XCTAssertEqual(entry.duration, 10)

        // The hand-off refresh must not reintroduce the library's length.
        XCTAssertEqual(player.songRefreshingLatestDuration(entry).duration, 10)
    }

    func testMedleyCandidatesComeFromTheCurrentRoundOfTheQueue() throws {
        let player = try makePlayer()
        player.setQueue([song("a"), song("book", genre: "Audiobook"), song("c")], startAt: 0)
        player.currentSong = player.queue.first
        XCTAssertEqual(player.medleyCandidatesFromQueue.map(\.id), ["a", "c"])
    }

    // MARK: - Spoken word store

    func testListeningToTheEndMarksAnItemFinishedAndListeningAgainReopensIt() throws {
        let url = makeDirectory().appendingPathComponent("spoken.json")
        let store = SpokenWordStore(storeURL: url)
        store.rememberPosition(600, duration: 3_600, forSongID: "ch1")
        XCTAssertNotNil(store.position(forSongID: "ch1"))
        XCTAssertFalse(store.isFinished(songID: "ch1"))

        store.rememberPosition(3_590, duration: 3_600, forSongID: "ch1")
        XCTAssertTrue(store.isFinished(songID: "ch1"))
        XCTAssertNil(store.position(forSongID: "ch1"), "a finished item starts over")

        store.rememberPosition(120, duration: 3_600, forSongID: "ch1")
        XCTAssertFalse(store.isFinished(songID: "ch1"))
    }

    func testBookmarksAndFinishedMarksPersistAndOldFilesStillLoad() throws {
        let url = makeDirectory().appendingPathComponent("spoken.json")
        let store = SpokenWordStore(storeURL: url)
        XCTAssertTrue(store.addBookmark(SpokenWordBookmark(songID: "ch1", position: 300, title: "A")))
        XCTAssertFalse(store.addBookmark(SpokenWordBookmark(songID: "ch1", position: 301, title: "dup")))
        XCTAssertTrue(store.addBookmark(SpokenWordBookmark(songID: "ch1", position: 90, title: "B")))
        store.markFinished(true, songIDs: ["ch0"])
        store.flush()

        let reloaded = SpokenWordStore(storeURL: url)
        XCTAssertEqual(reloaded.bookmarks(forSongID: "ch1").map(\.title), ["B", "A"])
        XCTAssertTrue(reloaded.isFinished(songID: "ch0"))

        let removed = try XCTUnwrap(reloaded.bookmarks(forSongID: "ch1").first)
        reloaded.removeBookmark(id: removed.id, songID: "ch1")
        XCTAssertEqual(reloaded.bookmarks(forSongID: "ch1").map(\.title), ["A"])

        // A file written before bookmarks existed has neither key.
        let legacy = makeDirectory().appendingPathComponent("legacy.json")
        try Data(#"{"overrides":{},"positions":{"x":{"position":100,"duration":1000,"updatedAt":0}}}"#.utf8)
            .write(to: legacy)
        let legacyStore = SpokenWordStore(storeURL: legacy)
        XCTAssertEqual(legacyStore.position(forSongID: "x")?.position, 100)
        XCTAssertTrue(legacyStore.bookmarks(forSongID: "x").isEmpty)
    }

    func testReclassifyingAsMusicDropsFinishedMarks() throws {
        let store = SpokenWordStore(storeURL: makeDirectory().appendingPathComponent("s.json"))
        store.markFinished(true, songIDs: ["x"])
        store.setKind(.music, forSongIDs: ["x"])
        XCTAssertFalse(store.isFinished(songID: "x"))
    }

    // MARK: - Playback rate and chapter sleep

    func testSpokenWordAndMusicKeepSeparateRates() throws {
        let player = try makePlayer()
        player.playbackSettings.outputMode = .effects
        player.playbackSettings.playbackRate = 1
        player.playbackSettings.spokenWordPlaybackRate = 1.5
        XCTAssertEqual(player.requestedPlaybackRate(for: song("m")), 1)
        XCTAssertEqual(player.requestedPlaybackRate(for: song("b", genre: "Audiobook")), 1.5)
        player.playbackSettings.outputMode = .highFidelity
        XCTAssertEqual(player.requestedPlaybackRate(for: song("b", genre: "Audiobook")), 1)
    }

    func testSkipIntervalsFollowTheSettingAndSnapToAGlyph() throws {
        let player = try makePlayer()
        player.playbackSettings.spokenWordSkipBackwardSeconds = 10
        player.playbackSettings.spokenWordSkipForwardSeconds = 44
        XCTAssertEqual(player.spokenWordSkipBackwardSymbol, "gobackward.10")
        XCTAssertEqual(player.playbackSettings.spokenWordSkipForwardSeconds, 45)
        XCTAssertEqual(player.spokenWordSkipForwardSymbol, "goforward.45")
    }

    func testChapterSleepOnTheLastChapterBecomesTrackEndAndCancelClearsIt() throws {
        let player = try makePlayer()
        let book = song("book", duration: 3_600, genre: "Audiobook")
        player.currentSong = book
        player.spokenWordChapters = [
            MediaChapter(startTime: 0, title: "One"),
            MediaChapter(startTime: 1_800, title: "Two"),
        ]

        player.currentChapterIndex = 0
        player.scheduleSleepAtChapterEnd()
        XCTAssertEqual(player.sleepStopAfterChapter, SpokenWordChapterSleepLock(songID: "book", chapterIndex: 0))
        XCTAssertTrue(player.isSleepTimerActive)

        player.currentChapterIndex = 1
        player.scheduleSleepAtChapterEnd()
        XCTAssertNil(player.sleepStopAfterChapter)
        XCTAssertEqual(player.sleepStopAfterSongID, "book")

        player.cancelSleep()
        XCTAssertFalse(player.isSleepTimerActive)
    }

    func testChapterSleepLockIsDroppedWhenAnotherItemPlays() throws {
        let player = try makePlayer()
        player.currentSong = song("book", duration: 3_600, genre: "Audiobook")
        player.spokenWordChapters = [
            MediaChapter(startTime: 0, title: "One"),
            MediaChapter(startTime: 1_800, title: "Two"),
            MediaChapter(startTime: 2_700, title: "Three"),
        ]
        player.currentChapterIndex = 0
        player.scheduleSleepAtChapterEnd()
        player.currentSong = song("other")
        player.enforceChapterSleepLockIfNeeded()
        XCTAssertNil(player.sleepStopAfterChapter)
    }

    // MARK: - Suggestions

    func testEarlySkipsAreCountedOnlyForEarlyManualSkips() throws {
        let track = song("s")
        // Reconstructed through a second center on the same defaults: the
        // skips were persisted.
        let defaults = try makeDefaults()
        let first = SmartNudgeCenter(defaults: defaults)
        first.noteManualSkip(of: track, listened: 2, duration: 240)
        first.noteManualSkip(of: track, listened: 120, duration: 240) // not early
        let second = SmartNudgeCenter(defaults: defaults)
        second.noteManualSkip(of: track, listened: 2, duration: 240)
        let data = try XCTUnwrap(defaults.data(forKey: "primuse.smartNudge.skips.v1"))
        let skips = try JSONDecoder().decode([String: [Date]].self, from: data)
        XCTAssertEqual(skips["s"]?.count, 2)
    }

    func testAcceptingASuggestionRunsItsActionAndClearsIt() async throws {
        let directory = makeDirectory()
        let library = MusicLibrary(
            storageDirectory: directory.appendingPathComponent("library"),
            deferredMaintenanceAllowed: { false },
            searchIndexDefaults: try makeDefaults(),
            lyricsSearchIndexRefresh: { _, _, _ in }
        )
        let track = song("liked")
        library.addSongs([track], affectedSourceIDs: ["local-source"])
        for _ in 0..<200 where library.song(id: "liked") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let player = try makePlayer(library: library)
        let center = SmartNudgeCenter(defaults: try makeDefaults())

        center.debugPresent(.addToFavorites, song: track)
        let nudge = try XCTUnwrap(center.activeNudge)
        center.accept(nudge, player: player, library: library)
        XCTAssertNil(center.activeNudge)
        for _ in 0..<200 where !library.isLiked(songID: "liked") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(library.isLiked(songID: "liked"))

        // The sleep prompt only appears while something plays; "stop after
        // this song" locks onto that song.
        player.currentSong = track
        center.debugPresent(.sleepTimer, song: nil)
        let sleep = try XCTUnwrap(center.activeNudge)
        center.accept(sleep, player: player, library: library, variant: 1)
        XCTAssertEqual(player.sleepStopAfterSongID, "liked")
        player.cancelSleep()
    }

    func testTurningSuggestionsOffHidesTheActiveOne() throws {
        let center = SmartNudgeCenter(defaults: try makeDefaults())
        center.debugPresent(.sleepTimer, song: nil)
        XCTAssertNotNil(center.activeNudge)
        center.isEnabled = false
        XCTAssertNil(center.activeNudge)
        center.setKind(.playSimilar, enabled: false)
        XCTAssertFalse(center.isKindEnabled(.playSimilar))
    }

    // MARK: - Batch edit

    func testProposalsBecomeTheUpdatedRow() {
        var original = song("t")
        original.albumArtistName = nil
        let proposals = [
            TagCleanupProposal(songID: "t", field: .title, oldValue: original.title, newValue: "Clean", reason: .whitespace),
            TagCleanupProposal(songID: "t", field: .artist, oldValue: "Artist", newValue: "New Artist", reason: .assistant),
            TagCleanupProposal(songID: "t", field: .genre, oldValue: nil, newValue: "Pop", reason: .assistant),
            TagCleanupProposal(songID: "t", field: .year, oldValue: nil, newValue: "1999", reason: .assistant),
            TagCleanupProposal(songID: "t", field: .trackNumber, oldValue: nil, newValue: "7", reason: .trackPrefix),
            TagCleanupProposal(songID: "other", field: .title, oldValue: nil, newValue: "Not me", reason: .assistant),
        ]
        let updated = BatchTagEditService.song(original, applying: proposals)
        XCTAssertEqual(updated.title, "Clean")
        XCTAssertEqual(updated.artistName, "New Artist")
        XCTAssertNil(updated.sourceArtistNames)
        XCTAssertEqual(updated.genre, "Pop")
        XCTAssertEqual(updated.year, 1999)
        XCTAssertEqual(updated.trackNumber, 7)
        XCTAssertEqual(updated.albumTitle, "Album")

        // Clearing a title is refused: a song always keeps one.
        let cleared = BatchTagEditService.song(original, applying: [
            TagCleanupProposal(songID: "t", field: .title, oldValue: original.title, newValue: nil, reason: .assistant),
            TagCleanupProposal(songID: "t", field: .album, oldValue: "Album", newValue: nil, reason: .placeholder),
        ])
        XCTAssertEqual(cleared.title, original.title)
        XCTAssertNil(cleared.albumTitle)
    }

    func testUndoRestoresTheFileNotALaggingLibraryRow() {
        // The library row had not read the file's tags yet: no album, a
        // file-name title, no track number.
        var lagging = song("u")
        lagging.title = "01 Song u"
        lagging.albumTitle = nil
        lagging.trackNumber = nil
        var edited = lagging
        edited.albumTitle = "Batch Album"
        let fileBefore = EmbeddedMetadataVerification(
            title: "Real Title", artist: "Real Artist", albumTitle: "Real Album",
            genre: "Pop", year: 2019, trackNumber: 4, discNumber: 1, coverData: nil
        )
        let target = BatchTagEditService.undoTarget(original: lagging, updated: edited, fileBefore: fileBefore)
        XCTAssertEqual(target.albumTitle, "Real Album", "undo puts back the file's album")
        XCTAssertEqual(target.title, "01 Song u", "fields the edit did not touch are left as they were")
        XCTAssertNil(target.trackNumber)

        // Without a file reading (server writes) undo falls back to the row.
        XCTAssertEqual(
            BatchTagEditService.undoTarget(original: lagging, updated: edited, fileBefore: nil).albumTitle,
            nil
        )
    }

    func testCleanupViewOfASongMatchesItsTags() {
        var track = song("t")
        track.trackNumber = 3
        track.discNumber = 1
        track.year = 2001
        let view = BatchTagEditService.cleanupSong(track)
        XCTAssertEqual(view.value(of: .title), "Song t")
        XCTAssertEqual(view.value(of: .artist), "Artist")
        XCTAssertEqual(view.value(of: .album), "Album")
        XCTAssertEqual(view.value(of: .trackNumber), "3")
        XCTAssertEqual(view.value(of: .discNumber), "1")
        XCTAssertEqual(view.value(of: .year), "2001")
        XCTAssertEqual(view.fileName, "/music/t.flac")
    }

    func testCoverScalingProducesAJPEGWithinTheLimit() throws {
        // A 2048×1024 PNG made with ImageIO itself.
        let width = 2048, height = 1024
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let png = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let scaled = try XCTUnwrap(BatchCoverImage.scaled(png as Data))
        XCTAssertEqual(Array(scaled.prefix(2)), [0xFF, 0xD8], "JPEG")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(scaled as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1024)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 512)
    }
}


extension ListeningFeaturesTests {
    func testSpokenWordSnapshotKeepsShelfSectionsAndChapterQueuesConsistent() async throws {
        let model = SpokenWordBooksModel()
        XCTAssertFalse(model.snapshot.isPrepared)
        var a = song("a", genre: "Audiobook")
        a.albumTitle = "Book A"
        var b = song("b", genre: "Audiobook")
        b.albumTitle = "Book B"
        var c = song("c", genre: "Audiobook")
        c.albumTitle = "Book C"
        var untouched = song("untouched", genre: "Audiobook")
        untouched.albumTitle = "Book D"
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = earlier.addingTimeInterval(100)
        await model.refresh(
            songs: [untouched, c, b, a],
            positions: [a.id: .init(position: 60, duration: 240, updatedAt: later),
                        b.id: .init(position: 30, duration: 240, updatedAt: earlier)],
            finishedAt: [c.id: later]
        )
        let snapshot = model.snapshot
        XCTAssertTrue(snapshot.isPrepared)
        XCTAssertEqual(snapshot.entriesByID.count, 4)
        XCTAssertEqual(snapshot.nowListening?.songs.map(\.id), [a.id])
        XCTAssertEqual(snapshot.shelf.flatMap(\.songs).map(\.id), [b.id, untouched.id])
        XCTAssertEqual(snapshot.finished.flatMap(\.songs).map(\.id), [c.id])
        XCTAssertEqual(snapshot.inProgress.flatMap { $0.1 }.map(\.id), [a.id, b.id])
        let current = try XCTUnwrap(snapshot.nowListening)
        XCTAssertEqual(snapshot.entriesByID[current.id]?.songs, current.songs)

        await model.refresh(songs: [untouched, c, b, a], positions: [b.id: .init(position: 30, duration: 240, updatedAt: earlier)], finishedAt: [c.id: later])
        XCTAssertEqual(model.snapshot.nowListening?.songs.map(\.id), [b.id])
        XCTAssertEqual(model.snapshot.shelf.flatMap(\.songs).map(\.id), [a.id, untouched.id])
    }

    func testSpokenWordSnapshotUpdatesDetailMetadataAndDropsRemovedBooks() async throws {
        let model = SpokenWordBooksModel()
        var chapter = song("chapter", genre: "Audiobook")
        await model.refresh(songs: [chapter], positions: [:], finishedAt: [:])
        let original = try XCTUnwrap(model.snapshot.shelf.first)
        chapter.title = "Updated chapter"
        chapter.duration = 480
        await model.refresh(songs: [chapter], positions: [:], finishedAt: [:])
        let updated = try XCTUnwrap(model.snapshot.entriesByID[original.id])
        XCTAssertEqual(updated.songs.first?.title, chapter.title)
        XCTAssertEqual(updated.book.items.first?.title, chapter.title)
        XCTAssertEqual(updated.book.totalDuration, 480)
        await model.refresh(songs: [], positions: [:], finishedAt: [:])
        XCTAssertTrue(model.snapshot.isPrepared)
        XCTAssertTrue(model.snapshot.entriesByID.isEmpty)
        XCTAssertTrue(model.snapshot.shelf.isEmpty)
        XCTAssertTrue(model.snapshot.finished.isEmpty)
        XCTAssertNil(model.snapshot.nowListening)
    }

    #if os(iOS)
    func testSpokenWordShelfRendersScrollableListAndRemembersLayout() async throws {
        let defaults = try makeDefaults()
        let library = MusicLibrary(storageDirectory: makeDirectory())
        let player = try makePlayer(library: library)
        let songs = (0..<24).map { index in
            var item = song("shelf-layout-\(index)", genre: "Audiobook")
            item.albumTitle = String(format: "长篇有声书 %02d：远方的故事", index / 2 + 1)
            item.artistName = "测试作者"
            item.trackNumber = index % 2 + 1
            return item
        }
        library.addSongs(songs)
        for _ in 0..<200 where library.spokenWordSongs.count != songs.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.spokenWordSongs.count, songs.count)
        XCTAssertEqual(library.spokenWordBookCount, 12)
        func root(_ identity: Int) -> some View {
            NavigationStack { SpokenWordLibraryView() }
                .environment(library)
                .environment(player)
                .environment(AppServices.shared.sourceManager)
                .environment(ThemeService())
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .defaultAppStorage(defaults)
                .id(identity)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: root(0))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants<T: UIView>(_ view: UIView, _: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, T.self) }
        }
        func capture(_ name: String) {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try await Task.sleep(for: .milliseconds(450))
        host.view.layoutIfNeeded()
        XCTAssertTrue(descendants(host.view, UISegmentedControl.self).isEmpty)
        capture("spoken-word-bookshelf")
        defaults.set("list", forKey: "spokenWord.shelf.layout")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(defaults.string(forKey: "spokenWord.shelf.layout"), "list")
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(descendants(host.view, UIScrollView.self).first { $0.contentSize.height > $0.bounds.height })
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let listHeight = scroll.contentSize.height
        capture("spoken-word-list")
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        capture("spoken-word-list-scrolled")
        host.rootView = root(1)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(defaults.string(forKey: "spokenWord.shelf.layout"), "list")
        host.view.layoutIfNeeded()
        let restoredScroll = try XCTUnwrap(descendants(host.view, UIScrollView.self).first { $0.contentSize.height > $0.bounds.height })
        XCTAssertEqual(restoredScroll.contentSize.height, listHeight, accuracy: 1)
        capture("spoken-word-list-restored")
        defaults.set("bookshelf", forKey: "spokenWord.shelf.layout")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(defaults.string(forKey: "spokenWord.shelf.layout"), "bookshelf")
        capture("spoken-word-bookshelf-restored")
    }
    #endif

    func testHomeBookRevisionFollowsPublishedClassificationChanges() async throws {
        let library = MusicLibrary(storageDirectory: makeDirectory())
        let before = library.spokenWordContentRevision
        var book = song("book", genre: "Audiobook")
        library.addSongs([book])
        for _ in 0..<200 where library.spokenWordSongs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.spokenWordSongs.map(\.id), [book.id])
        XCTAssertGreaterThan(library.spokenWordContentRevision, before)
        let classified = library.spokenWordContentRevision
        book.genre = "Rock"
        library.replaceSongs([book], maintenance: .immediate)
        for _ in 0..<200 where !library.spokenWordSongs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(library.spokenWordSongs.isEmpty)
        XCTAssertGreaterThan(library.spokenWordContentRevision, classified)
    }

    func testHomeBookProjectionKeepsChapterOrderAndTracksProgressAndRemoval() async {
        let model = SpokenWordBooksModel()
        var first = song("chapter-1", genre: "Audiobook")
        first.trackNumber = 1
        var second = song("chapter-2", genre: "Audiobook")
        second.trackNumber = 2
        let position = SpokenWordStore.StoredPosition(position: 60, duration: 240, updatedAt: Date())
        await model.refresh(songs: [second, first], positions: [first.id: position], finishedAt: [:])
        XCTAssertEqual(model.inProgress.count, 1)
        XCTAssertEqual(model.inProgress.first?.1.map(\.id), [first.id, second.id])
        let before = model.inProgress.first?.0.fractionComplete ?? 0

        await model.refresh(songs: [second, first], positions: [second.id: position], finishedAt: [first.id: Date()])
        XCTAssertGreaterThan(model.inProgress.first?.0.fractionComplete ?? 0, before)
        await model.refresh(songs: [second, first], positions: [:], finishedAt: [first.id: Date(), second.id: Date()])
        XCTAssertTrue(model.inProgress.isEmpty)
        await model.refresh(songs: [first], positions: [first.id: position], finishedAt: [:])
        XCTAssertEqual(model.inProgress.count, 1)
        await model.refresh(songs: [], positions: [first.id: position], finishedAt: [:])
        XCTAssertTrue(model.inProgress.isEmpty)
    }

    func testHomeBookProjectionRejectsOlderComputationAfterLibraryClears() async {
        let model = SpokenWordBooksModel()
        let songs = (0..<10_000).map { song("chapter-\($0)", genre: "Audiobook") }
        let position = SpokenWordStore.StoredPosition(position: 60, duration: 240, updatedAt: Date())
        let older = Task {
            await model.refresh(songs: songs, positions: [songs[0].id: position], finishedAt: [:])
        }
        while model.requestRevision == 0 { await Task.yield() }
        await model.refresh(songs: [], positions: [:], finishedAt: [:])
        await older.value
        XCTAssertTrue(model.inProgress.isEmpty)
    }

    func testCancelledHomeBookRefreshPreservesCurrentProjection() async {
        let model = SpokenWordBooksModel()
        let book = song("chapter", genre: "Audiobook")
        await model.refresh(songs: [book], positions: [book.id: .init(position: 60, duration: 240, updatedAt: Date())], finishedAt: [:])
        let cancelled = Task { await model.refresh(songs: [], positions: [:], finishedAt: [:]) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(model.inProgress.first?.1.map(\.id), [book.id])
    }

    func testLyricsPreparationKeepsManualTranslationsWhenDisabledAndAfterEdits() async throws {
        let service = LyricsTranslationPreparer()
        var line = LyricLine(id: "line", timestamp: 1, text: "I am walking home tonight.", manualTranslation: .init(text: "今晚我走路回家", languageCode: "zh-Hans", source: .localEditor))
        let disabled = try await service.prepare(lyrics: [line], targetLanguageCode: "zh-Hans", enabled: false)
        XCTAssertEqual(disabled.manualTranslations[line.id], "今晚我走路回家")
        XCTAssertTrue(disabled.groups.isEmpty)
        let enabled = try await service.prepare(lyrics: [line], targetLanguageCode: "zh-Hans", enabled: true)
        XCTAssertEqual(enabled, disabled)
        line.manualTranslation?.text = "更新后的译文"
        let edited = try await service.prepare(lyrics: [line], targetLanguageCode: "zh-Hans", enabled: false)
        XCTAssertEqual(edited.manualTranslations[line.id], "更新后的译文")
    }

    func testLyricsPreparationCacheSeparatesTargetsAndContentWithSameLineIDs() async throws {
        let service = LyricsTranslationPreparer()
        let english = LyricLine(id: "line", timestamp: 1, text: "The sun is shining brightly in the beautiful blue sky.", metadataLines: ["[language:en]"])
        let toChinese = try await service.prepare(lyrics: [english], targetLanguageCode: "zh-Hans", enabled: true)
        XCTAssertEqual(toChinese.groups.flatMap(\.candidates).map(\.text), [english.text])
        let toEnglish = try await service.prepare(lyrics: [english], targetLanguageCode: "en", enabled: true)
        XCTAssertTrue(toEnglish.groups.isEmpty)
        var edited = english
        edited.text = "The moon is rising over the quiet mountains tonight."
        let changed = try await service.prepare(lyrics: [edited], targetLanguageCode: "zh-Hans", enabled: true)
        XCTAssertEqual(changed.groups.flatMap(\.candidates).map(\.text), [edited.text])
        let reused = try await service.prepare(lyrics: [english], targetLanguageCode: "zh-Hans", enabled: true)
        XCTAssertEqual(reused, toChinese)
    }

    func testCancelledLyricsPreparationDoesNotReturnCachedResult() async throws {
        let service = LyricsTranslationPreparer()
        _ = try await service.prepare(lyrics: [], targetLanguageCode: "en", enabled: false)
        let cancelled = Task { try await service.prepare(lyrics: [], targetLanguageCode: "en", enabled: false) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled preparation must not publish even a cached result")
        } catch is CancellationError {
        }
    }
}
