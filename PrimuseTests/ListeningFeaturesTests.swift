import CoreGraphics
import Foundation
import ImageIO
import PrimuseKit
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
        XCTAssertEqual(player.queue.first?.duration, 45)
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
        XCTAssertEqual(entry.duration, 45)

        // The hand-off refresh must not reintroduce the library's length.
        XCTAssertEqual(player.songRefreshingLatestDuration(entry).duration, 45)
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
