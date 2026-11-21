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

/// 批量刮削按部分结算：只有真的补上并落了地才算更新；存不下的记失败、不改引用。
@MainActor
final class BatchScrapeAccountingTests: XCTestCase {
    private func makeService(_ root: URL) -> MusicScraperService {
        MusicScraperService(sourceManager: SourceManager(sourcesProvider: { [] }),
                            checkpointDirectory: root.appendingPathComponent("checkpoint"))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrape-tally-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func song(cover: String? = nil, lyrics: String? = nil) -> Song {
        Song(id: UUID().uuidString, title: "Window at Dawn", albumTitle: "Quiet Windows", artistName: "Paper Harbor",
             duration: 180, fileFormat: .flac, filePath: "/Music/Window at Dawn.flac", sourceID: "nas",
             coverArtFileName: cover, lyricsFileName: lyrics)
    }

    private func scope(_ fields: Set<ScrapeField>) -> MusicScraperService.ScrapeScope {
        MusicScraperService.ScrapeScope(considered: fields, fetched: fields)
    }

    private func pngData() throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData())
    }

    private func processed(_ song: Song, cover: Data?, lyrics: [LyricLine]?) -> MusicScraperService.ProcessedResult {
        MusicScraperService.ProcessedResult(song: song, coverData: cover, lyricsLines: lyrics)
    }

    private func cleanUp(_ songID: String) async {
        await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
        _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
        CachedArtworkView.invalidateCache(for: songID)
    }

    func testTechnicalParametersAloneAreSavedButNotCountedAsUpdated() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root)
        let original = song()
        var scraped = original
        scraped.duration = 181.4
        scraped.bitRate = 1_411
        scraped.sampleRate = 96_000
        scraped.bitDepth = 24
        let applied = await service.applyScrapedResult(
            processed(scraped, cover: nil, lyrics: nil), scope: scope([.year, .genre, .cover, .lyrics]),
            to: original, parts: .all, coverOrigin: .scraped, stampsUserEdit: true
        )
        XCTAssertEqual(applied.parts.tags, .notFound)
        XCTAssertEqual(applied.parts.cover, .notFound)
        XCTAssertEqual(applied.parts.result, .unchanged)
        XCTAssertTrue(applied.persists, "Technical parameters are still saved silently")
        XCTAssertEqual(applied.song.sampleRate, 96_000)
        XCTAssertNil(applied.song.userMetadataEditedAt)

        scraped.year = 2026
        let tagged = await service.applyScrapedResult(
            processed(scraped, cover: nil, lyrics: nil), scope: scope([.year]),
            to: original, parts: .all, coverOrigin: .scraped, stampsUserEdit: true
        )
        XCTAssertEqual(tagged.parts.tags, .filled)
        XCTAssertEqual(tagged.parts.result, .updated)
    }

    func testCoverThatCannotBeStoredIsAFailureAndKeepsTheReference() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root)
        let original = song(cover: "/Music/Album/cover.jpg")
        var scraped = original
        scraped.coverArtFileName = MetadataAssetStore.shared.expectedCoverFileName(for: original.id)
        let applied = await service.applyScrapedResult(
            processed(scraped, cover: Data("not an image".utf8), lyrics: nil), scope: scope([.cover]),
            to: original, parts: .all, coverOrigin: .selected, stampsUserEdit: true
        )
        XCTAssertEqual(applied.parts.cover, .saveFailed)
        XCTAssertEqual(applied.parts.result, .failed)
        XCTAssertNil(applied.storedCover)
        XCTAssertEqual(applied.song.coverArtFileName, original.coverArtFileName)
        XCTAssertFalse(applied.persists)

        let image = try pngData()
        let stored = await service.applyScrapedResult(
            processed(scraped, cover: image, lyrics: nil), scope: scope([.cover]),
            to: original, parts: .all, coverOrigin: .scraped, stampsUserEdit: true
        )
        XCTAssertEqual(stored.parts.cover, .filled)
        let reference = try XCTUnwrap(stored.song.coverArtFileName)
        XCTAssertTrue(MetadataAssetStore.shared.hasReadableCoverFile(named: reference))
        await cleanUp(original.id)
    }

    func testLyricsRejectedByTheCacheAreNotFilledAndKeepTheReference() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = makeService(root)
        let original = song()
        let lines = [LyricLine(timestamp: 1, text: "Paper lanterns cross the quiet sky")]
        // 别处正在改这首的歌词：缓存不收，这一轮不算补上，引用也不改。
        let token = await MetadataAssetStore.shared.beginLyricsMutation(forSongID: original.id, expectedFingerprint: nil)
        let reserved = try XCTUnwrap(token)
        let rejected = await service.applyScrapedResult(
            processed(original, cover: nil, lyrics: lines), scope: scope([.lyrics]),
            to: original, parts: .all, coverOrigin: .scraped, stampsUserEdit: true
        )
        await MetadataAssetStore.shared.cancelLyricsMutation(forSongID: original.id, token: reserved)
        XCTAssertEqual(rejected.parts.lyrics, .saveFailed)
        XCTAssertNil(rejected.cachedLyrics)
        XCTAssertNil(rejected.song.lyricsFileName)

        let blank = await service.applyScrapedResult(
            processed(original, cover: nil, lyrics: [LyricLine(timestamp: 1, text: "  ")]), scope: scope([.lyrics]),
            to: original, parts: .all, coverOrigin: .scraped, stampsUserEdit: true
        )
        XCTAssertEqual(blank.parts.lyrics, .saveFailed)

        let cached = await service.applyScrapedResult(
            processed(original, cover: nil, lyrics: lines), scope: scope([.lyrics]),
            to: original, parts: .all, coverOrigin: .scraped, stampsUserEdit: true
        )
        XCTAssertEqual(cached.parts.lyrics, .filled)
        XCTAssertEqual(cached.song.lyricsFileName, MetadataAssetStore.shared.expectedLyricsFileName(for: original.id))
        await cleanUp(original.id)
    }

    func testWritebackFailuresAreClassified() {
        XCTAssertEqual(MusicScraperService.writebackFailureReason(for: EmbeddedMetadataCoordinatedWritebackError.conflict), .conflict)
        XCTAssertEqual(MusicScraperService.writebackFailureReason(for: CancellationError()), .timeout)
        XCTAssertEqual(MusicScraperService.writebackFailureReason(for: SourceFileMutationError.readOnly), .unavailable)
        XCTAssertEqual(MusicScraperService.writebackFailureReason(for: NSError(domain: "Primuse.Test", code: 7)), .other)
    }

    func testCompletionSummaryHidesZeroItemsAndSaysWhenNothingWasFound() {
        var tally = BatchScrapeTally()
        tally.record(ScrapeSongParts(cover: .alreadyPresent, lyrics: .notFound, tags: .notFound))
        let nothing = MusicScraperService.BatchScrapeCompletion(
            runID: UUID(), originPlaylistID: nil, songCount: 1, updatedCount: 0, skippedCount: 1, failedCount: 0,
            artworkTotalCount: 0, artworkAvailableCount: 0, artworkUnavailableCount: 0, tally: tally
        )
        XCTAssertEqual(nothing.summaryLines, [String(localized: "scrape_tally_nothing")])
        XCTAssertFalse(nothing.offersDetails)

        tally.record(ScrapeSongParts(cover: .saveFailed, lyrics: .filled, tags: .notRequested))
        tally.recordFailure(.init(songID: "s", title: "Window at Dawn", part: .cover))
        tally.recordWriteback(.failed(.conflict))
        let mixed = MusicScraperService.BatchScrapeCompletion(
            runID: UUID(), originPlaylistID: nil, songCount: 2, updatedCount: 0, skippedCount: 1, failedCount: 1,
            artworkTotalCount: 0, artworkAvailableCount: 0, artworkUnavailableCount: 0, tally: tally
        )
        XCTAssertEqual(mixed.summaryLines.count, 3, "Cover, lyrics and writeback lines; no tags line for zero")
        XCTAssertTrue(mixed.offersDetails)
        XCTAssertTrue(mixed.hasAnyFailure)
    }

    func testTechnicalChangesInABatchAreNotReportedAsUpdated() async throws {
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
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var wav = Data("RIFF".utf8)
        func u32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        wav.append(u32(196)); wav.append(Data("WAVEfmt ".utf8)); wav.append(u32(16)); wav.append(contentsOf: [1, 0, 1, 0])
        wav.append(u32(8000)); wav.append(u32(16000)); wav.append(contentsOf: [2, 0, 16, 0])
        wav.append(Data("data".utf8)); wav.append(u32(160)); wav.append(Data(repeating: 0, count: 160))
        try wav.write(to: root.appendingPathComponent("Lantern Shore.wav"))
        let source = MusicSource(id: UUID().uuidString, name: "Tally fixture", type: .local, basePath: root.path)
        let service = MusicScraperService(
            sourceManager: SourceManager(sourcesProvider: { [source] }),
            metadataService: MetadataService(scraperManager: ScraperManager(scraperFactory: { _ in EmptyMetadataProbe() })),
            checkpointDirectory: root.appendingPathComponent("checkpoint"), scrapeRetrySleep: { _ in }
        )
        defer { service.cancel() }
        let song = Song(id: UUID().uuidString, title: "Lantern Shore", fileFormat: .wav,
                        filePath: "/Lantern Shore.wav", sourceID: source.id)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs([song])
        await library.waitForPendingIndex()

        _ = service.scrapeMissingMetadata(songs: [song], in: library, parts: .metadata)
        await service.waitUntilScrapeIdle()
        let completion = try XCTUnwrap(service.lastCompletion)
        XCTAssertEqual(completion.updatedCount, 0, "Only duration / sample rate changed: not an update")
        XCTAssertEqual(completion.skippedCount, 1)
        XCTAssertEqual(completion.tally.tags.notFound, 1)
        XCTAssertEqual(completion.summaryLines.first, String(localized: "scrape_tally_nothing"))
        let stored = try XCTUnwrap(library.storedSong(id: song.id))
        XCTAssertTrue(stored.sampleRate != nil || stored.duration > 0, "Technical parameters are still saved")
    }

    private struct EmptyMetadataProbe: MusicScraper {
        let type = MusicScraperType.itunes
        func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
            .empty(.itunes)
        }
        func getDetail(externalId: String) async throws -> ScraperDetail? { nil }
        func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] { [] }
        func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }
    }
}
