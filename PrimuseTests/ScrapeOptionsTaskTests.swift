import Foundation
import PrimuseKit
import UIKit
import XCTest
@testable import Primuse

@MainActor
final class ScrapeContentSelectionTests: XCTestCase {
    func testLyricsPreferenceSurvivesReopeningAndPreviewOverridesStayLocal() throws {
        let suite = "ScrapeContentSelectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ScrapeContentPreferences(defaults: defaults)
        XCTAssertEqual(preferences.parts, .all)
        preferences.binding(for: .metadata).wrappedValue = false
        preferences.binding(for: .cover).wrappedValue = false

        let reopened = ScrapeContentPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.parts, .lyrics)
        var draft = review(original: song(), defaults: reopened.parts)
        XCTAssertEqual(Set(draft.selected.keys), [.lyrics])
        draft.select("New title", for: .title)
        draft.select("embedded", for: .cover)
        draft.select(nil, for: .lyrics)
        XCTAssertEqual(Set(draft.selected.keys), [.title, .cover])
        XCTAssertEqual(ScrapeContentPreferences(defaults: defaults).parts, .lyrics)
        XCTAssertEqual(Set(review(original: song(id: "next-song"), defaults: reopened.parts).selected.keys), [.lyrics])
        preferences.binding(for: .lyrics).wrappedValue = false
        XCTAssertTrue(ScrapeContentPreferences(defaults: defaults).parts.isEmpty)
    }

    func testEveryContentCombinationControlsOnlyInitialSelection() {
        for raw in 0...ScrapeParts.all.rawValue {
            let parts = ScrapeParts(rawValue: raw)
            let draft = review(original: song(), defaults: parts)
            for field in ScrapeField.allCases {
                XCTAssertEqual(draft.selected[field] != nil, parts.contains(field.part), field.rawValue)
            }
        }
    }

    func testUnchangedOrUnavailableResultsStayUnselected() {
        let original = song()
        var catalog = ScrapeReviewCatalog()
        catalog.addText(original.title, field: .title, source: "Archive")
        catalog.recommended[.title] = original.title
        catalog.includeLocalResults(original: original, updated: original, fields: Set(ScrapeField.allCases), cover: nil, lyrics: [])
        let request = ScraperSettings().reviewFields(for: original, parts: .all)
        let draft = ScrapeReviewDraft(song: original, catalog: catalog, request: request, defaults: request)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(draft.choices(for: .title).isEmpty)
        XCTAssertNil(draft.cover)
        XCTAssertNil(draft.lyrics)
    }

    func testAppleMusicAllowsAllFieldsWhileCueKeepsAlbumIdentity() {
        var original = song()
        original.sourceID = AppleMusicLibraryIdentity.sourceID
        XCTAssertEqual(Set(review(original: original, defaults: .all).selected.keys), Set(ScrapeField.allCases))
        original = song()
        original.cueSheetPath = "/album.cue"
        original.cueStartTime = 0
        var cue = review(original: original, defaults: .all)
        XCTAssertEqual(Set(cue.selected.keys), [.title, .year, .genre, .lyrics])
        cue.select("Album", for: .album)
        XCTAssertNil(cue.proposedTags(on: original).albumTitle)
        cue.select("embedded", for: .cover)
        XCTAssertNotNil(cue.cover)
    }

    private func review(original: Song, defaults: ScrapeParts) -> ScrapeReviewDraft {
        let settings = ScraperSettings(onlyFillMissingFields: false)
        let request = settings.reviewFields(for: original, parts: .all)
        var catalog = ScrapeReviewCatalog()
        catalog.includeLocalResults(original: original, updated: changedSong(original), fields: request.fields, cover: Data([1]),
                                    lyrics: [LyricLine(timestamp: 1, text: "At the corner of the quay")])
        return ScrapeReviewDraft(song: original, catalog: catalog, request: request,
                                defaults: settings.request(for: original, parts: defaults, checkingAssetCache: false))
    }

    private func song(id: String = "song") -> Song {
        Song(id: id, title: "Original", fileFormat: .mp3, filePath: "/test.mp3", sourceID: "test")
    }

    private func changedSong(_ original: Song) -> Song {
        var candidate = original
        candidate.title = "New title"
        candidate.artistName = "Artist"
        candidate.albumTitle = "Album"
        candidate.albumArtistName = "Harbor Quartet"
        candidate.year = 2026
        candidate.trackNumber = 2
        candidate.discNumber = 1
        candidate.genre = "Rock"
        return candidate
    }
}

@MainActor
final class ExistingCoverScrapeTests: XCTestCase {
    func testForcedBatchAndSinglePreviewHonorExplicitRulesOnLocalAndCatalogSongs() async throws {
        try await withFixture { service, probe, original, _ in
            var settings = ScraperSettings.load()
            for field in ScrapeField.allCases { settings.fieldRules[field].mode = .skip }
            settings.fieldRules[.year].mode = .overwrite
            settings.fieldRules[.genre].mode = .fillMissing
            var song = original
            song.year = 1999
            song.genre = "Folk"
            let batch = try await service.processedSongForBatch(song, forceRescrape: true, settings: settings)
            XCTAssertEqual(batch?.song.year, 2026)
            XCTAssertEqual(batch?.song.genre, "Folk")
            XCTAssertEqual(batch?.song.albumArtistName, song.albumArtistName)
            XCTAssertNil(batch?.coverData)
            XCTAssertNil(batch?.lyricsLines)

            song.sourceID = AppleMusicLibraryIdentity.sourceID
            song.genre = nil
            let preview = try await service.processedSongWithAssets(song, forceRescrape: true,
                                                                   storeAssets: false, settings: settings)
            XCTAssertEqual(preview?.song.genre, "Ambient")
            XCTAssertEqual(preview?.song.year, 2026)
            let covers = await probe.coverRequests
            XCTAssertEqual(covers, 0)
            let skipped = try await service.processedSongForBatch(song, forceRescrape: true, parts: .cover, settings: settings)
            XCTAssertNil(skipped)
        }
    }

    func testAutomaticScrapeKeepsSourceCoverWhenLocalAudioCopyHasNoImage() async throws {
        try await withFixture { service, probe, song, _ in
            let processed = try await service.processedSongWithAssets(song, forceRescrape: false)
            let result = try XCTUnwrap(processed)
            XCTAssertEqual(result.song.coverArtFileName, song.coverArtFileName)
            XCTAssertNil(result.coverData)
            XCTAssertEqual(result.song.year, 2026, "Missing metadata must still be filled")
            let coverRequests = await probe.coverRequests
            XCTAssertEqual(coverRequests, 0, "A known source cover must suppress online cover matching")
        }
    }

    func testAutomaticScrapeDoesNotReturnAnotherLocalImageAsReplacement() async throws {
        try await withFixture { service, _, song, root in
            let data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }.pngData()
            try XCTUnwrap(data).write(to: root.appendingPathComponent("cover.png"))
            let processed = try await service.processedSongWithAssets(song, forceRescrape: false)
            let result = try XCTUnwrap(processed)
            XCTAssertEqual(result.song.coverArtFileName, song.coverArtFileName)
            XCTAssertNil(result.coverData, "Reading another image must not bypass fill-only application")
        }
    }

    func testExplicitRescrapeCanStillRequestAReplacementCover() async throws {
        try await withFixture { service, probe, song, _ in
            _ = try await service.processedSongWithAssets(song, forceRescrape: true)
            let coverRequests = await probe.coverRequests
            XCTAssertEqual(coverRequests, 1)
        }
    }

    func testAppleMusicScrapeUsesMetadataWithoutResolvingAnAudioFile() async throws {
        try await withFixture { service, probe, original, _ in
            var song = original
            song.sourceID = AppleMusicLibraryIdentity.sourceID
            song.filePath = "8090148269108553694"
            song.bitRate = 320
            song.sampleRate = 44_100
            let processed = try await service.processedSongWithAssets(
                song, forceRescrape: true, storeAssets: false
            )
            let result = try XCTUnwrap(processed)
            XCTAssertEqual(result.song.year, 2026)
            XCTAssertEqual(result.song.genre, "Ambient")
            XCTAssertEqual(result.song.sourceID, song.sourceID)
            XCTAssertEqual(result.song.filePath, song.filePath)
            XCTAssertEqual(result.song.bitRate, song.bitRate)
            XCTAssertEqual(result.song.sampleRate, song.sampleRate)
            let coverRequests = await probe.coverRequests
            XCTAssertEqual(coverRequests, 1)
        }
    }

    func testBackgroundPublicationPreservesCoverDiscoveredWhileScraping() async throws {
        try await withFixture { _, _, song, root in
            let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
            var latest = song
            latest.coverArtFileName = "/Album/newly-discovered-cover.jpg"
            library.addSongs([latest])
            var pending = song
            pending.coverArtFileName = "scraped-" + String(repeating: "a", count: 64) + ".jpg"
            pending.year = 2026
            let result = MusicScraperService.rebasedOntoLatestUserEdits(
                [pending], in: library, preservingExistingArtwork: true
            )[0]
            XCTAssertEqual(result.coverArtFileName, latest.coverArtFileName)
            XCTAssertEqual(result.year, 2026)
            let expected = try XCTUnwrap(latest.coverArtFileName)
            let replacement = MusicScraperService.rebasedOntoLatestUserEdits(
                [pending], in: library, preservingExistingArtwork: true,
                replacingArtworkReferences: [song.id: expected]
            )[0]
            XCTAssertEqual(replacement.coverArtFileName, pending.coverArtFileName)
            let stale = MusicScraperService.rebasedOntoLatestUserEdits(
                [pending], in: library, preservingExistingArtwork: true,
                replacingArtworkReferences: [song.id: "old-cover.jpg"]
            )[0]
            XCTAssertEqual(stale.coverArtFileName, expected)
            XCTAssertEqual(MusicScraperService.rebasedOntoLatestUserEdits([pending], in: library)[0].coverArtFileName,
                           pending.coverArtFileName, "Explicit replacement must retain its existing semantics")
        }
    }

    /// 整批刮削拿来刮的是开刮时的快照。写回库里时文件身份要跟库里那一行走，
    /// 否则会把嵌封面后记下的新身份倒回去，之后的写回都判成源文件已变化。
    func testPublicationKeepsTheLibrarysCurrentFileIdentity() async throws {
        try await withFixture { _, _, song, root in
            let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
            var latest = song
            latest.fileSize = 4_096
            latest.lastModified = Date(timeIntervalSince1970: 1_800_000_000)
            latest.revision = "after-embed"
            library.addSongs([latest])
            var pending = song
            pending.year = 2026
            pending.fileSize = 2_048
            pending.revision = "before-embed"
            let result = MusicScraperService.rebasedOntoLatestUserEdits([pending], in: library)[0]
            XCTAssertEqual(result.year, 2026)
            XCTAssertEqual(result.filePath, latest.filePath)
            XCTAssertEqual(result.fileSize, 4_096)
            XCTAssertEqual(result.lastModified, latest.lastModified)
            XCTAssertEqual(result.revision, "after-embed")
        }
    }

    private func withFixture(
        _ body: (MusicScraperService, CoverScrapeProbe, Song, URL) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ScraperSettings.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: ScraperSettings.defaultsKey) }
            else { defaults.removeObject(forKey: ScraperSettings.defaultsKey) }
        }
        var settings = ScraperSettings.load()
        for index in settings.sources.indices {
            settings.sources[index].isEnabled = settings.sources[index].type == .itunes
        }
        settings.onlyFillMissingFields = true
        settings.save()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var wav = Data("RIFF".utf8)
        func u32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        wav.append(u32(36 + 160))
        wav.append(Data("WAVEfmt ".utf8))
        wav.append(u32(16))
        wav.append(contentsOf: [1, 0, 1, 0])
        wav.append(u32(8_000))
        wav.append(u32(16_000))
        wav.append(contentsOf: [2, 0, 16, 0])
        wav.append(Data("data".utf8))
        wav.append(u32(160))
        wav.append(Data(repeating: 0, count: 160))
        try wav.write(to: root.appendingPathComponent("Window at Dawn.wav"))
        let source = MusicSource(id: UUID().uuidString, name: "Fixture", type: .local, basePath: root.path)
        let probe = CoverScrapeProbe()
        let service = MusicScraperService(
            sourceManager: SourceManager(sourcesProvider: { [source] }),
            metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in probe }))
        )
        let song = Song(id: UUID().uuidString, title: "Window at Dawn", albumTitle: "Quiet Windows",
                        artistName: "Paper Harbor", fileFormat: .wav, filePath: "/Window at Dawn.wav",
                        sourceID: source.id, coverArtFileName: "/Album/cover.jpg")
        try await body(service, probe, song, root)
    }

    private actor CoverScrapeProbe: MusicScraper {
        let type = MusicScraperType.itunes
        private(set) var coverRequests = 0
        func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
            .init(items: [.init(externalId: "track", source: .itunes, title: "Window at Dawn",
                                artist: "Paper Harbor", album: "Quiet Windows", durationMs: 10)], source: .itunes)
        }
        func getDetail(externalId: String) async throws -> ScraperDetail? {
            .init(externalId: externalId, source: .itunes, title: "Window at Dawn",
                  artist: "Paper Harbor", album: "Quiet Windows", year: 2026, genres: ["Ambient"])
        }
        func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
            coverRequests += 1
            return []
        }
        func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }
    }
}

@MainActor
final class AppleMusicScrapePersistenceTests: XCTestCase {
    func testLibraryRefreshPreservesChosenMetadataCoverAndLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        var original = Song(id: "apple-local", title: "Window at Dawn", albumTitle: "Quiet Windows",
                            artistName: "Paper Harbor", duration: 180, fileFormat: .aac,
                            filePath: "123456", sourceID: AppleMusicLibraryIdentity.sourceID)
        original.coverArtFileName = "musicKit://official-cover"
        library.addSongs([original])
        var chosen = try XCTUnwrap(library.storedSong(id: original.id))
        chosen.title = "Window at Dawn — Alternate"
        chosen.albumTitle = "Lantern Sketches"
        chosen.artistName = "Harbor Ensemble"
        chosen.coverArtFileName = "selected-" + String(repeating: "a", count: 64) + ".jpg"
        chosen.lyricsFileName = "local-lyrics.json"
        chosen.lyricsText = "Paper lanterns cross the quiet sky"
        chosen = SongUserMetadataPolicy.stampingUserEdit(original: original, updated: chosen)
        library.replaceSong(chosen)
        chosen = try XCTUnwrap(library.storedSong(id: original.id))

        var incoming = original
        incoming.duration = 181
        incoming.bitRate = 256
        incoming.coverArtFileName = "musicKit://refreshed-cover"
        let prepared = await library.prepareIncomingSongsOffMain([incoming])
        library.addSongs(prepared, affectedSourceIDs: [original.sourceID],
                         mergeServerCatalogRows: false, indexMaintenance: .immediate)
        let refreshed = try XCTUnwrap(library.storedSong(id: original.id))
        XCTAssertEqual(refreshed.title, chosen.title)
        XCTAssertEqual(refreshed.albumTitle, chosen.albumTitle)
        XCTAssertEqual(refreshed.artistName, chosen.artistName)
        XCTAssertEqual(refreshed.albumID, chosen.albumID)
        XCTAssertEqual(refreshed.coverArtFileName, chosen.coverArtFileName)
        XCTAssertEqual(refreshed.lyricsFileName, chosen.lyricsFileName)
        XCTAssertEqual(refreshed.lyricsText, chosen.lyricsText)
        XCTAssertEqual(refreshed.userMetadataEditedAt, chosen.userMetadataEditedAt)
        XCTAssertEqual(refreshed.filePath, original.filePath)
        XCTAssertEqual(refreshed.duration, 181)
        XCTAssertEqual(refreshed.bitRate, 256)
    }

    func testCoverOnlyChoiceDoesNotFreezeUneditedCatalogText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let selectedCover = "selected-" + String(repeating: "b", count: 64) + ".jpg"
        let song = Song(id: "apple-cover", title: "Window", duration: 180, fileFormat: .aac,
                        filePath: "i.library-song", sourceID: AppleMusicLibraryIdentity.sourceID,
                        coverArtFileName: selectedCover)
        library.addSongs([song])
        var incoming = song
        incoming.title = "Window at Dawn"
        incoming.coverArtFileName = "musicKit://official-cover"
        library.addSongs([incoming], affectedSourceIDs: [song.sourceID])
        let refreshed = try XCTUnwrap(library.storedSong(id: song.id))
        XCTAssertEqual(refreshed.coverArtFileName, selectedCover)
        XCTAssertEqual(refreshed.title, incoming.title)
        XCTAssertNil(refreshed.userMetadataEditedAt)
    }

    func testChosenAppleMusicCoverResolvesFromLocalStorage() async throws {
        let songID = UUID().uuidString
        let assets = MetadataAssetStore.shared
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
        let stored = await assets.storeAttributedCover(data, songID: songID, origin: .selected)
        let reference = try XCTUnwrap(stored)
        defer { CachedArtworkView.invalidateCache(for: songID) }
        let song = Song(id: songID, title: "Window", fileFormat: .aac, filePath: "i.local-test",
                        sourceID: AppleMusicLibraryIdentity.sourceID, coverArtFileName: reference)
        let image = try await AsyncOperationTimeout.run(seconds: 5) {
            await AppleMusicSongArtwork.image(for: song, pixelSize: 32, mirrorsIntoSongCache: false)
        }
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
        await assets.invalidateRemovedSongCaches(songs: [song], songIDs: [songID], retainingSongs: [], lastWrittenBefore: Date())
    }
}

@MainActor
final class ScrapeOptionsTaskTests: XCTestCase {
    func testLyricsCacheReadsLocalBasenamesWithoutFollowingRemoteReferences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsReferences-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory)
        let lines = [LyricLine(timestamp: 0, text: "Cached lyrics")]
        let fileName = await store.storeLyrics(lines, for: "cached-song")
        let cached = await store.lyrics(named: fileName)
        XCTAssertEqual(cached, lines)

        let nested = store.lyricsDirectoryURL.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try JSONEncoder().encode(lines).write(to: nested.appendingPathComponent("song.json"))
        for reference in ["remote/song.json", "/music/song.lrc", "https://nas.invalid/song.json",
                          "remote\\song.json", "song.lrc"] {
            let result = await store.lyrics(named: reference)
            XCTAssertNil(result)
        }
    }

    @MainActor
    private final class SuspendedRequest {
        let started = XCTestExpectation(description: "Request started")
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func complete() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testCancelBeforeStartingDoesNotApplyChanges() async {
        let session = ScrapeOptionsTask()
        var applied = false
        let task = session.start { applied = true }

        session.cancel()
        await task.value

        XCTAssertFalse(applied)
        XCTAssertFalse(session.isRunning)
    }

    func testCancelReleasesBusyStateWithoutWaitingForNetwork() async {
        let session = ScrapeOptionsTask()
        let request = SuspendedRequest()
        var observedCancellation = false
        let task = session.start {
            await request.wait()
            observedCancellation = Task.isCancelled
        }
        await fulfillment(of: [request.started], timeout: 2)

        session.cancel()

        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(observedCancellation)
        request.complete()
        await task.value
        XCTAssertTrue(observedCancellation)
    }

    func testCancelledTaskHandleAlsoReleasesBusyState() async {
        let session = ScrapeOptionsTask()
        let task = session.start { XCTFail("Cancelled work must not start") }

        task.cancel()
        await task.value

        XCTAssertFalse(session.isRunning)
    }

    func testLateCompletionDoesNotClearReplacementBusyState() async {
        let session = ScrapeOptionsTask()
        let oldRequest = SuspendedRequest()
        let newRequest = SuspendedRequest()
        let oldTask = session.start { await oldRequest.wait() }
        await fulfillment(of: [oldRequest.started], timeout: 2)

        let newTask = session.start { await newRequest.wait() }
        await fulfillment(of: [newRequest.started], timeout: 2)
        oldRequest.complete()
        await oldTask.value

        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertTrue(session.isRunning)
        newRequest.complete()
        await newTask.value
        XCTAssertFalse(session.isRunning)
    }

    func testClosingAfterSuccessfulApplyDoesNotCancelCommittedWriteback() async {
        let session = ScrapeOptionsTask()
        let writeback = SuspendedRequest()
        var writebackWasCancelled = true
        let task = session.start {
            session.finish()
            await writeback.wait()
            writebackWasCancelled = Task.isCancelled
        }
        await fulfillment(of: [writeback.started], timeout: 2)

        session.cancel()
        writeback.complete()
        await task.value

        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(writebackWasCancelled)
    }

    func testCancelledLyricsSavePreservesExistingLyricsAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrapeCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary(storageDirectory: directory)
        let sourceManager = SourceManager(sourcesProvider: { [] })
        let songID = UUID().uuidString
        let oldLines = [LyricLine(timestamp: 0, text: "Original lyrics")]
        let newLines = [LyricLine(timestamp: 0, text: "Replacement lyrics")]
        var song = Song(
            id: songID, title: "Song", fileFormat: .mp3,
            filePath: "/test/song.mp3", sourceID: "scrape-test"
        )
        song.lyricsText = "Original lyrics"
        song.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: songID)
        let seeded = await MetadataAssetStore.shared.cacheLyrics(oldLines, forSongID: songID)
        XCTAssertTrue(seeded)
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        let storedSong = try XCTUnwrap(library.song(id: songID))
        let fingerprint = LyricsDocumentFingerprint(lines: oldLines)
        let save = Task { @MainActor in
            await LyricsWriteback.save(
                text: LyricsContentParser.serialize(newLines), for: storedSong,
                mode: .localOnly(reason: nil), allowRemoval: false,
                structuredLines: newLines, cacheSnapshot: fingerprint,
                sourceManager: sourceManager, library: library
            )
        }
        save.cancel()
        let cancelled = await save.value

        XCTAssertFalse(cancelled.succeeded)
        XCTAssertEqual(library.song(id: songID)?.lyricsText, "Original lyrics")
        let unchanged = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID)
        XCTAssertEqual(unchanged?.map(\.text), ["Original lyrics"])

        let retried = await LyricsWriteback.save(
            text: LyricsContentParser.serialize(newLines), for: storedSong,
            mode: .localOnly(reason: nil), allowRemoval: false,
            structuredLines: newLines, cacheSnapshot: fingerprint,
            sourceManager: sourceManager, library: library
        )
        XCTAssertTrue(retried.succeeded, retried.errorMessage ?? "")
        XCTAssertEqual(library.song(id: songID)?.lyricsText, "Replacement lyrics")
        _ = await MetadataAssetStore.shared.invalidateLyricsCacheIfUnchanged(
            forSongID: songID, expectedFingerprint: retried.cacheSnapshot
        )
    }
}
