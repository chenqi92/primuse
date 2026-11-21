import Foundation
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

/// The lyric sources page end to end on a path-addressed source: which file
/// each request resolves to, that a picked read-only file never gets its
/// replacement written over another source, and that the raw editor's save
/// rewrites exactly one file, byte for byte, only while it is unchanged.
final class LyricsDocumentSourcesResolutionTests: XCTestCase {
    @MainActor
    func testSourceLyricsLoadDisplaysConcurrentCacheWinner() async {
        let song = song()
        let store = MetadataAssetStore.shared
        let lines = [LyricLine(timestamp: 1, text: "Source lyrics")]
        let first = await LyricsLoader.persistLoadedSourceLyrics(lines, forSongID: song.id, cachedDocument: nil)
        XCTAssertTrue(first.didWrite)
        let second = await LyricsLoader.persistLoadedSourceLyrics(lines, forSongID: song.id, cachedDocument: nil)
        XCTAssertFalse(second.didWrite)
        XCTAssertEqual(second.lines.map(\.text), ["Source lyrics"])
        await store.invalidateCaches(forSongIDs: [song.id])
    }

    @MainActor
    func testSourceLyricsLoadPreservesAndDisplaysConcurrentEdit() async {
        let song = song()
        let store = MetadataAssetStore.shared
        let original = [LyricLine(timestamp: 1, text: "Original")]
        _ = await store.cacheLyrics(original, forSongID: song.id, force: true)
        let edited = [LyricLine(timestamp: 2, text: "Edited")]
        _ = await store.cacheLyrics(edited, forSongID: song.id, force: true)
        let result = await LyricsLoader.persistLoadedSourceLyrics(original, forSongID: song.id, cachedDocument: original)
        XCTAssertFalse(result.didWrite)
        XCTAssertEqual(result.lines.map(\.text), ["Edited"])
        let stored = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(stored?.map(\.text), ["Edited"])
        await store.invalidateCaches(forSongIDs: [song.id])
    }

    @MainActor
    func testAppleMusicWithoutEmbeddedLyricsFallsBackOnline() async {
        let item = song()
        let expected = [LyricLine(timestamp: 1, text: "Lanterns drift across the bay")]
        var calls = 0
        let result = await LyricsLoader.resolveAppleMusicLyrics(
            for: item, allowsAutomaticOnlineLyrics: true,
            fetchEmbedded: { nil }, fetchOnline: { calls += 1; return expected }
        )
        XCTAssertEqual(result.map(\.text), expected.map(\.text))
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testAppleMusicEmbeddedLyricsAndExplicitEditorLoadDoNotSearchOnline() async {
        for embedded in [nil, [LyricLine(timestamp: 1, text: "A paper moon above the tide")]] as [[LyricLine]?] {
            let item = song()
            let result = await LyricsLoader.resolveAppleMusicLyrics(
                for: item, allowsAutomaticOnlineLyrics: embedded != nil,
                fetchEmbedded: { embedded }, fetchOnline: { XCTFail("Unexpected online request"); return nil }
            )
            XCTAssertEqual(result.map(\.text), (embedded ?? []).map(\.text))
            _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: item.id)
        }
    }

    @MainActor
    func testAppleMusicKeepsManualLyricsSavedDuringOnlineLookup() async {
        let item = song()
        let manual = [LyricLine(timestamp: 1, text: "I marked the harbour on a map")]
        let result = await LyricsLoader.resolveAppleMusicLyrics(
            for: item, allowsAutomaticOnlineLyrics: true,
            fetchEmbedded: { nil }, fetchOnline: {
                _ = await MetadataAssetStore.shared.cacheLyrics(manual, forSongID: item.id, force: true)
                return [LyricLine(timestamp: 1, text: "A different lantern")]
            }
        )
        XCTAssertEqual(result.map(\.text), manual.map(\.text))
        _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: item.id)
    }

    @MainActor
    func testASMRLyricsRemainReadableInMusicAndAudiobookClassification() async throws {
        let lines = Data("[00:01.00]雨停在窗沿\n[00:03.50]灯影落在纸上\n".utf8)
        for genre in ["ASMR", "Audiobook ASMR"] {
            var item = song()
            item.genre = genre
            item.lyricsFileName = "/Music/Night Changes.lrc"
            let fixture = connector(["Night Changes.lrc": lines])
            let source = MusicSource(id: "source", name: "Lyrics fixture", type: .webdav, host: "fixture.invalid")
            let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
            let loaded = await LyricsLoader.load(for: item, sourceManager: manager, sourceType: .webdav,
                                                allowsAutomaticOnlineLyrics: false)
            XCTAssertEqual(loaded.map(\.text), ["雨停在窗沿", "灯影落在纸上"])
            XCTAssertEqual(loaded.map(\.timestamp), [1, 3.5])
            let writes = await fixture.writtenPaths
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func testSelectedCandidateSurvivesReopenAndRejectsAutomaticReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory)
        let original = LyricsDocumentSource.embedded.stamped([LyricLine(timestamp: 1, text: "Paper lanterns")])
        let online = LyricsDocumentSource.online(identifier: "fixture", name: "Fixture").stamped([LyricLine(timestamp: 2, text: "Across the bay")])
        let cached = await store.cacheLyrics(original, forSongID: "fixture")
        XCTAssertTrue(cached)
        let candidate = await store.rememberLyricsCandidate(online, forSongID: "fixture")
        let duringFetch = await store.cachedLyrics(forSongID: "fixture")
        XCTAssertEqual(duringFetch?.map(\.text), ["Paper lanterns"], "Fetching a candidate must not switch playback")
        let id = try XCTUnwrap(candidate?.id)
        let selected = await store.selectLyricsCandidate(id, forSongID: "fixture")
        XCTAssertTrue(selected)
        let automatic = await store.cacheLyrics(original, forSongID: "fixture")
        XCTAssertFalse(automatic)
        let lateRefresh = await store.replaceLyricsIfUnchanged(
            LyricsDocumentSource.embedded.stamped(online), forSongID: "fixture",
            expectedFingerprint: LyricsDocumentFingerprint(lines: online), force: true, preservingSelection: true
        )
        XCTAssertFalse(lateRefresh, "A stale automatic refresh must keep a manual choice even when the text is identical")
        let reopened = MetadataAssetStore(storageDirectory: directory)
        let restored = await reopened.cachedLyrics(forSongID: "fixture")
        XCTAssertEqual(restored?.map(\.text), ["Across the bay"])
        let sources = await reopened.lyricsSourceCollection(forSongID: "fixture")
        XCTAssertEqual(sources.candidates.count, 2)
        let switchedBack = await reopened.cacheLyrics(original, forSongID: "fixture", force: true)
        XCTAssertTrue(switchedBack)
        let afterSwitch = await reopened.lyricsSourceCollection(forSongID: "fixture")
        XCTAssertNil(afterSwitch.selected)
        XCTAssertEqual(afterSwitch.candidates.count, 2)
        let removed = await reopened.invalidateLyricsCache(forSongID: "fixture")
        XCTAssertTrue(removed)
        let afterRemoval = await reopened.cachedLyrics(forSongID: "fixture")
        XCTAssertNil(afterRemoval)
    }

    @MainActor
    func testCatalogListsOnlineAndEmbeddedAlongsideSidecarsAndEditorFollowsPick() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc])
        let source = MusicSource(id: "source", name: "Fixture", type: .webdav, host: "fixture.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
        let sourcesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sourcesDirectory) }
        let sourcesStore = SourcesStore(storageDirectoryURL: sourcesDirectory)
        let embedded = LyricsDocumentSource.embedded.stamped([LyricLine(timestamp: 1, text: "Embedded lantern")])
        let online = LyricsDocumentSource.online(identifier: "fixture", name: "Fixture Online").stamped([LyricLine(timestamp: 1, text: "Online lantern")])
        await MetadataAssetStore.shared.storeEmbeddedFallbackLyrics(embedded, forSongID: song.id)
        _ = await MetadataAssetStore.shared.cacheLyrics(online, forSongID: song.id, force: true)
        let listing = await LyricsDocumentCatalog.load(for: song, sourceManager: manager, sourcesStore: sourcesStore)
        guard case .documents(let documents) = listing else { return XCTFail("Expected source candidates") }
        XCTAssertEqual(documents.entries.count, 3)
        XCTAssertEqual(documents.entries.filter(\.isActive).count, 1)
        XCTAssertEqual(documents.entries.first(where: \.isActive)?.candidate?.source?.kind, .online)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: LyricsSourcesView(song: song, editorHasUnsavedChanges: false, onActiveDocumentChanged: { _ in })
            .environment(manager).environment(sourcesStore).environment(AppServices.shared.musicLibrary)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "lyrics-sources-online-embedded-file"
        attachment.lifetime = .keepAlways
        add(attachment)
        let embeddedEntry = try XCTUnwrap(documents.entries.first { $0.candidate?.source?.kind == .embedded })
        try await LyricsDocumentCatalog.activate(embeddedEntry, for: song, sourceManager: manager)
        let payload = await LyricsWriteback.loadEditablePayload(for: song, sourceManager: manager)
        XCTAssertEqual(payload.playbackLines.map(\.text), ["Embedded lantern"])
        let mode = await LyricsWriteback.resolveMode(for: song, sourceManager: manager, sourcesStore: sourcesStore)
        XCTAssertTrue(mode.isLocalStructuredOnly)
        let writes = await fixture.writtenPaths
        XCTAssertTrue(writes.isEmpty)
        _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id)
    }

    func testSlowLyricsLookupRemainsPendingWhileRecoveryActionsAreAvailable() {
        var state = LyricsResolutionState()
        state.begin(1)
        state.revealRecoveryActions(1)
        XCTAssertEqual(state.revision, 1, "A slow lookup is not an empty result")
        XCTAssertTrue(state.offersRecoveryActions)
        state.clear()
        state.revealRecoveryActions(1)
        XCTAssertNil(state.revision, "A late timeout must not restart a completed lookup")
        XCTAssertFalse(state.offersRecoveryActions)
    }

    func testOldLyricsTimeoutCannotChangeANewerLookup() {
        var state = LyricsResolutionState()
        state.begin(1)
        state.revealRecoveryActions(1)
        state.begin(2)
        state.revealRecoveryActions(1)
        XCTAssertEqual(state.revision, 2)
        XCTAssertFalse(state.offersRecoveryActions)
    }

    func testEditorPlaybackPayloadPreservesStructuredTranslationAndTiming() {
        let lines = [LyricLine(timestamp: 3, text: "Original", manualTranslation: .init(text: "Translation", source: .localEditor))]
        let payload = LyricsWriteback.EditablePayload(text: "Fallback", structuredLines: lines)
        XCTAssertEqual(LyricsDocumentFingerprint(lines: payload.playbackLines), LyricsDocumentFingerprint(lines: lines))
        let lrc = LyricsWriteback.EditablePayload(text: "[00:02.50]Source lyrics", structuredLines: nil)
        XCTAssertEqual(lrc.playbackLines.map(\.text), ["Source lyrics"])
        XCTAssertEqual(lrc.playbackLines.first?.timestamp, 2.5)
    }

    @MainActor
    func testEditorPublishesExistingLyricsWithoutAnEditOrSourceWrite() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": Data("[00:01.00]Existing source lyrics\n[00:03.00]Second line\n".utf8)])
        let source = MusicSource(id: "source", name: "Fixture", type: .webdav, host: "fixture.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
        let loaded = expectation(description: "Lyrics reach the player without pressing Save")
        var published: [LyricLine] = []
        var saved = false
        let services = AppServices.shared
        let editor = LyricsEditorSheet(song: song, autoStartsAudioTranscription: true, onSave: { _ in saved = true }, onLoad: { receivedSong, lines in
            XCTAssertEqual(receivedSong.id, song.id)
            published = lines
            loaded.fulfill()
        })
            .environment(manager)
            .environment(services.sourcesStore)
            .environment(services.musicLibrary)
            .environment(services.playerService)
            .environment(services.musicIntelligence)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, .dark)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: editor)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [loaded], timeout: 8)
        XCTAssertEqual(published.map(\.text), ["Existing source lyrics", "Second line"])
        XCTAssertFalse(saved)
        let written = await fixture.writtenPaths
        XCTAssertTrue(written.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Lyrics editor translation alignment"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private let lrc = Data("[00:01.00]From the LRC\n".utf8)
    private let ttml = Data("""
    <tt xmlns="http://www.w3.org/ns/ttml"><body><div>\
    <p begin="00:01.000" end="00:02.000"><span begin="00:01.000" end="00:02.000">TTML</span></p>\
    </div></body></tt>
    """.utf8)
    private let yrc = Data("[1000,1000](1000,1000,0)YRC\n".utf8)

    private func song() -> Song {
        Song(id: "song-\(UUID().uuidString)", title: "Night Changes", fileFormat: .flac,
             filePath: "/Music/Night Changes.flac", sourceID: "source", fileSize: 1)
    }

    private func connector(_ files: [String: Data]) -> LyricsDocumentFixtureConnector {
        var all = files
        all["Night Changes.flac"] = Data([0])
        all["cover.jpg"] = Data([1])
        return LyricsDocumentFixtureConnector(directory: "/Music", files: all)
    }

    func testRequestsResolveTheListenersChoice() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.ttml": ttml, "Night Changes.yrc": yrc])

        // Two writable documents and no pick: a save cannot tell which one is meant.
        do {
            _ = try await LyricsSidecarTargetPolicy.resolve(for: song, using: fixture, request: .current(pinned: nil))
            XCTFail("expected the two writable documents to stay ambiguous")
        } catch EmbeddedMetadataWritebackSourceError.conflict {
        }

        let catalog = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .catalog(pinned: nil)
        )
        XCTAssertEqual(catalog.fileName, "Night Changes.lrc")
        XCTAssertEqual(catalog.documents.map(\.name),
                       ["Night Changes.lrc", "Night Changes.ttml", "Night Changes.yrc"])

        let pinned = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .current(pinned: "Night Changes.ttml")
        )
        XCTAssertEqual(pinned.fileName, "Night Changes.ttml")
        XCTAssertEqual(pinned.existingPath, "/Music/Night Changes.ttml")
        XCTAssertEqual(pinned.existingSize, Int64(ttml.count))

        let named = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .named("Night Changes.yrc")
        )
        XCTAssertTrue(named.exists)
        XCTAssertEqual(named.fileName, "Night Changes.yrc")

        let missing = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .named("Night Changes.qrc")
        )
        XCTAssertFalse(missing.exists)
    }

    func testImportKeepsChineseLRCWithRenamedAudio() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("Imported", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let audio = root.appendingPathComponent("Paper Pier.flac")
        let renamed = destination.appendingPathComponent("Paper Pier (2).flac")
        let primary = Data("[00:03.00]Fold a silver sail".utf8)
        let chinese = Data("[00:03.00]折起一面银帆".utf8)
        try primary.write(to: root.appendingPathComponent("Paper Pier.lrc"))
        try chinese.write(to: root.appendingPathComponent("Paper Pier.zh.lrc"))
        let transaction = LocalImportFileTransaction(destinationDirectory: destination)
        try transaction.prepareAndCleanStaging()
        var index = LocalImportService.LanguageTaggedSidecarCache()
        let copied = LocalImportService.copySidecarsAtomically(
            forAudio: audio, audioDest: renamed, transaction: transaction, taggedSidecars: &index
        )
        XCTAssertEqual(Set(copied.map { $0.url.lastPathComponent }), ["Paper Pier (2).lrc", "Paper Pier (2).zh.lrc"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Paper Pier (2).lrc")), primary)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Paper Pier (2).zh.lrc")), chinese)
        let lines = try XCTUnwrap(SidecarMetadataLoader.loadLyrics(for: renamed))
        XCTAssertEqual(lines.first?.text, "Fold a silver sail")
        XCTAssertEqual(lines.first?.manualTranslation?.text, "折起一面银帆")
    }

    @MainActor
    func testChineseLRCAppearsAfterOriginalWasCachedAndChecked() async throws {
        var song = song()
        song.lyricsFileName = "/Music/Night Changes.lrc"
        let primary = "[00:02.00]Silver folds at dawn\n[00:08.00]Glass bells sail away"
        let (manager, store) = recheckFixture([
            "Night Changes.lrc": Data(primary.utf8),
            "Night Changes.zh.lrc": Data("[00:02.00]银光折入黎明\n[00:08.00]玻璃铃扬帆远去".utf8),
        ])
        let cached = LyricsParser.parseDocument(primary, fileName: "Night Changes.lrc")
        let songID = song.id
        defer { Task { await store.invalidateCaches(forSongIDs: [songID]) } }
        _ = await store.cacheLyrics(cached, forSongID: songID, force: true)
        await store.recordSourceRecheck(reference: "/Music/Night Changes.lrc", forSongID: songID)
        let refreshed = await LyricsLoader.recheckSourceDocument(for: song, sourceManager: manager, cachedDocument: cached)
        XCTAssertEqual(refreshed?.map { $0.manualTranslation?.text }, ["银光折入黎明", "玻璃铃扬帆远去"])
        let stored = await store.cachedLyrics(forSongID: songID)
        XCTAssertEqual(stored?.map(\.text), cached.map(\.text))
        XCTAssertEqual(stored?.last?.manualTranslation?.languageCode, "zh")
    }

    func testSeveralFilesWithoutAPickReadTheFinerTimedOne() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.yrc": yrc])

        // 没人选过: 逐字的 .yrc 胜过逐行的 .lrc, 播放、来源页与保存都按它。
        await LyricsLoader.refreshAutomaticDocumentPick(for: song, connector: fixture)
        XCTAssertEqual(
            LyricsDocumentPinStore.shared.effectiveFileName(forSongID: song.id),
            "Night Changes.yrc"
        )
        XCTAssertNil(LyricsDocumentPinStore.shared.pinnedFileName(forSongID: song.id))
        let current = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .current(for: song)
        )
        XCTAssertEqual(current.fileName, "Night Changes.yrc")

        // 用户在来源页选了别的, 以用户的为准。
        LyricsDocumentPinStore.shared.pin("Night Changes.lrc", forSongID: song.id)
        defer { LyricsDocumentPinStore.shared.clearPin(forSongID: song.id) }
        let picked = try await LyricsSidecarTargetPolicy.resolve(
            for: song, using: fixture, request: .current(for: song)
        )
        XCTAssertEqual(picked.fileName, "Night Changes.lrc")
    }

    /// #208: 早先读标签存下的逐行内嵌歌词盖住了歌旁边的歌词文件, 只比时间轴粗细永远换不掉。
    /// 歌指着那份文件时缓存命中后核对一次就换成文件, 核对过的引用记下来不再列目录。
    @MainActor
    func testLineTimedEmbeddedCacheYieldsToTheReferencedFile() async throws {
        var song = song()
        song.lyricsFileName = "/Music/Night Changes.lrc"
        let (manager, store) = recheckFixture(["Night Changes.lrc": lrc])
        let songID = song.id
        defer { Task { await store.invalidateCaches(forSongIDs: [songID]) } }
        let embedded = [LyricLine(timestamp: 3, text: "From the embedded tag")]
        let cached = await store.cacheLyrics(embedded, forSongID: song.id, force: true)
        XCTAssertTrue(cached)

        let replaced = await LyricsLoader.recheckSourceDocument(
            for: song, sourceManager: manager, cachedDocument: embedded
        )
        XCTAssertEqual(replaced?.map(\.text), ["From the LRC"])
        let stored = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(stored?.map(\.text), ["From the LRC"])
        let checked = await store.sourceRecheckReference(forSongID: song.id)
        XCTAssertEqual(checked, song.lyricsFileName)
    }

    /// 手动刮削到的歌词记的是缓存名: 旁边的歌词文件只在时间轴更细时才换掉它。
    @MainActor
    func testScrapedCacheOnlyYieldsToFinerTiming() async throws {
        var song = song()
        song.lyricsFileName = "\(song.id).json"
        let (manager, store) = recheckFixture(["Night Changes.lrc": lrc])
        let songID = song.id
        defer { Task { await store.invalidateCaches(forSongIDs: [songID]) } }
        let scraped = [LyricLine(timestamp: 3, text: "Scraped online")]
        let cached = await store.cacheLyrics(scraped, forSongID: song.id, force: true)
        XCTAssertTrue(cached)

        let replaced = await LyricsLoader.recheckSourceDocument(
            for: song, sourceManager: manager, cachedDocument: scraped
        )
        XCTAssertNil(replaced)
        let stored = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(stored?.map(\.text), ["Scraped online"])
        let checked = await store.sourceRecheckReference(forSongID: song.id)
        XCTAssertEqual(checked, song.lyricsFileName)
    }

    @MainActor
    private func recheckFixture(_ files: [String: Data]) -> (SourceManager, MetadataAssetStore) {
        let fixture = connector(files)
        let source = MusicSource(id: "source", name: "Fixture", type: .webdav, host: "fixture.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
        return (manager, MetadataAssetStore.shared)
    }

    func testPickedReadOnlyFileNeverOverwritesAnotherSource() async throws {
        let song = song()
        let fixture = connector(["Night Changes.ttml": ttml, "Night Changes.yrc": yrc])
        LyricsDocumentPinStore.shared.pin("Night Changes.yrc", forSongID: song.id)
        defer { LyricsDocumentPinStore.shared.clearPin(forSongID: song.id) }

        do {
            _ = try await SidecarWriteService.shared.preflightLyricsWrite(for: song, using: fixture)
            XCTFail("expected the replacement name to collide with the existing TTML")
        } catch let collision as LyricsSidecarReplacementCollision {
            XCTAssertEqual(collision.documentName, "Night Changes.yrc")
            XCTAssertEqual(collision.replacementName, "Night Changes.ttml")
        }
        let written = await fixture.writtenPaths
        XCTAssertTrue(written.isEmpty)
    }

    func testPickedReadOnlyFileWithoutSiblingStillSavesBesideIt() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.yrc": yrc])
        LyricsDocumentPinStore.shared.pin("Night Changes.yrc", forSongID: song.id)
        defer { LyricsDocumentPinStore.shared.clearPin(forSongID: song.id) }

        // `.yrc` is saved as `.ttml`; the `.lrc` is another name and stays out of it.
        let preflight = try await SidecarWriteService.shared.preflightLyricsWrite(for: song, using: fixture)
        XCTAssertEqual(preflight.fileName, "Night Changes.ttml")
        XCTAssertFalse(preflight.replacesExistingFile)
        XCTAssertTrue(preflight.hasLyricsDocument)
    }

    func testRawSaveRewritesOnlyThatFileByteForByte() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc, "Night Changes.yrc": yrc])
        let edited = Data("[1000,1500](1000,1500,0)Edited\n".utf8)

        let target = try await SidecarWriteService.shared.lyricsDocumentTarget(
            named: "Night Changes.yrc", for: song, using: fixture
        )
        let receipt = try await SidecarWriteService.shared.writeLyricsDocument(
            edited, to: target, expecting: yrc, using: fixture
        )
        XCTAssertEqual(receipt.readback, edited)
        let files = await fixture.files
        XCTAssertEqual(files["Night Changes.yrc"], edited)
        XCTAssertEqual(files["Night Changes.lrc"], lrc)
        let written = await fixture.writtenPaths
        XCTAssertEqual(written, ["/Music/Night Changes.yrc"])
    }

    func testRawSaveRefusesAFileChangedSinceItWasOpened() async throws {
        let song = song()
        let fixture = connector(["Night Changes.ttml": ttml])
        let target = try await SidecarWriteService.shared.lyricsDocumentTarget(
            named: "Night Changes.ttml", for: song, using: fixture
        )
        do {
            _ = try await SidecarWriteService.shared.writeLyricsDocument(
                Data("<tt/>".utf8), to: target, expecting: Data("stale".utf8), using: fixture
            )
            XCTFail("expected a stale baseline to be refused")
        } catch SidecarWriteService.LyricsDocumentWriteError.changedElsewhere(let name) {
            XCTAssertEqual(name, "Night Changes.ttml")
        }
        let written = await fixture.writtenPaths
        XCTAssertTrue(written.isEmpty)
    }

    func testRawSaveOfAVanishedFileIsRefused() async throws {
        let song = song()
        let fixture = connector(["Night Changes.lrc": lrc])
        do {
            _ = try await SidecarWriteService.shared.lyricsDocumentTarget(
                named: "Night Changes.ttml", for: song, using: fixture
            )
            XCTFail("expected a missing file to be refused")
        } catch SidecarWriteService.LyricsDocumentWriteError.documentMissing(let name) {
            XCTAssertEqual(name, "Night Changes.ttml")
        }
    }
}

/// A writable folder held in memory.
private actor LyricsDocumentFixtureConnector: MusicSourceConnector {
    let sourceID = "source"
    let directory: String
    private(set) var files: [String: Data]
    private(set) var writtenPaths: [String] = []

    nonisolated var supportsSidecarWriting: Bool { true }

    init(directory: String, files: [String: Data]) {
        self.directory = directory
        self.files = files
    }

    func connect() async throws { }
    func disconnect() async { }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard path == directory else { throw SourceError.pathNotFound(path) }
        return files.keys.sorted().map { name in
            RemoteFileItem(
                name: name,
                path: (directory as NSString).appendingPathComponent(name),
                isDirectory: false,
                size: Int64(files[name]?.count ?? 0),
                modifiedDate: nil
            )
        }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let data = files[(path as NSString).lastPathComponent] else {
            throw SourceError.fileNotFound(path)
        }
        let start = Int(max(0, offset))
        let end = min(data.count, start + Int(max(0, length)))
        return start < end ? data.subdata(in: start..<end) : Data()
    }

    func writeFile(data: Data, to path: String) async throws {
        writtenPaths.append(path)
        files[(path as NSString).lastPathComponent] = data
    }

    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

/// 用户保存的那一份就是这首歌正在用的版本：按设置重挑内嵌原文、重读标签都换不掉它，
/// 被替换下来的旧版本也不再作为多出来的一份留在来源列表里。
@MainActor
final class LyricsUserVersionTests: XCTestCase {
    private func song() -> Song {
        Song(id: "user-version-\(UUID().uuidString)", title: "Fixture", fileFormat: .flac,
             filePath: "/Fixture.flac", sourceID: "user-version-test", fileSize: 1)
    }

    private func embedded(_ text: String) -> [LyricLine] {
        LyricsDocumentSource.embedded.stamped(LyricsContentParser.parseText(text))
    }

    func testSavedVersionSurvivesReselectionAndTagRereads() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let old = "[00:01.00]Old version one\n[00:02.00]Old version two"
        let other = "[00:01.00]Other version"
        let oldLines = embedded(old)
        let seeded = await store.cacheLyrics(oldLines, forSongID: song.id, force: true)
        XCTAssertTrue(seeded)
        await store.storeEmbeddedLyricsAlternatives(
            .init(variants: [.init(text: other), .init(text: old)]), forSongID: song.id
        )

        let savedLines = embedded("[00:01.00]Saved one\n[00:02.00]Saved two\n[00:03.00]Saved three")
        let saved = await store.cacheLyrics(
            savedLines, forSongID: song.id, force: true, origin: .user, previousVersion: .forget
        )
        XCTAssertTrue(saved)
        let pinned = await store.isUserPinned(forSongID: song.id)
        XCTAssertTrue(pinned)

        let reselected = await LyricsLoader.reselectedEmbeddedVariant(for: song, cached: savedLines)
        XCTAssertNil(reselected)
        let reread = await store.cacheLyrics(embedded(other), forSongID: song.id)
        XCTAssertFalse(reread)
        let current = await store.cachedLyrics(forSongID: song.id)
        let variantSwap = await store.replaceLyricsIfUnchanged(
            embedded(other), forSongID: song.id,
            expectedFingerprint: current.map(LyricsDocumentFingerprint.init(lines:)),
            force: true, preservingSelection: true
        )
        XCTAssertFalse(variantSwap)

        let loaded = await LyricsLoader.load(
            for: song, sourceManager: SourceManager(sourcesProvider: { [] }),
            allowsAutomaticOnlineLyrics: false
        )
        XCTAssertEqual(loaded.map(\.text), savedLines.map(\.text))

        let candidates = await store.lyricsSourceCollection(forSongID: song.id).candidates
        XCTAssertFalse(candidates.contains { $0.lines.map(\.text) == oldLines.map(\.text) })
        XCTAssertTrue(candidates.contains { $0.lines.map(\.text) == savedLines.map(\.text) })
    }

    func testSaveRecoversWhenAnAutomaticPathChangedTheCache() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        let manager = SourceManager(sourcesProvider: { [] })
        let seeded = await store.cacheLyrics(embedded("[00:01.00]Opened"), forSongID: song.id, force: true)
        XCTAssertTrue(seeded)
        let openedLines = await store.cachedLyrics(forSongID: song.id)
        let snapshot = LyricsDocumentFingerprint(lines: try XCTUnwrap(openedLines))
        // The priority setting re-picks another embedded original while the editor is open.
        let repicked = await store.replaceLyricsIfUnchanged(
            embedded("[00:01.00]Re-picked"), forSongID: song.id,
            expectedFingerprint: snapshot, force: true, preservingSelection: true
        )
        XCTAssertTrue(repicked)

        let outcome = await LyricsWriteback.save(
            text: "[00:01.00]Draft", for: song, mode: .localOnly(reason: nil), allowRemoval: false,
            cacheSnapshot: snapshot, sourceManager: manager, library: library
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
        let cached = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(cached?.map(\.text), ["Draft"])
    }

    func testSaveAsksBeforeOverwritingAVersionSavedElsewhere() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        let manager = SourceManager(sourcesProvider: { [] })
        let seeded = await store.cacheLyrics(embedded("[00:01.00]Opened"), forSongID: song.id, force: true)
        XCTAssertTrue(seeded)
        let openedLines = await store.cachedLyrics(forSongID: song.id)
        let snapshot = LyricsDocumentFingerprint(lines: try XCTUnwrap(openedLines))
        let elsewhere = await store.cacheLyrics(
            embedded("[00:01.00]Saved in another window"), forSongID: song.id, force: true, origin: .user
        )
        XCTAssertTrue(elsewhere)

        let first = await LyricsWriteback.save(
            text: "[00:01.00]Draft", for: song, mode: .localOnly(reason: nil), allowRemoval: false,
            cacheSnapshot: snapshot, sourceManager: manager, library: library
        )
        XCTAssertFalse(first.succeeded)
        XCTAssertEqual(first.errorMessage, String(localized: "lyrics_version_changed_elsewhere"))
        let kept = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(kept?.map(\.text), ["Saved in another window"])

        // Saving the same draft again is the listener choosing to overwrite.
        let second = await LyricsWriteback.save(
            text: "[00:01.00]Draft", for: song, mode: .localOnly(reason: nil), allowRemoval: false,
            cacheSnapshot: snapshot, sourceManager: manager, library: library
        )
        XCTAssertTrue(second.succeeded, second.errorMessage ?? "")
        let replaced = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(replaced?.map(\.text), ["Draft"])
    }

    func testSavingAsANewVersionKeepsTheOldOneSelectable() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let oldLines = embedded("[00:01.00]Before")
        let newLines = embedded("[00:01.00]After")
        let seeded = await store.cacheLyrics(oldLines, forSongID: song.id, force: true)
        XCTAssertTrue(seeded)
        let saved = await store.cacheLyrics(
            newLines, forSongID: song.id, force: true, origin: .user, previousVersion: .keep
        )
        XCTAssertTrue(saved)
        let sources = await store.lyricsSourceCollection(forSongID: song.id)
        let kept = try XCTUnwrap(sources.candidates.first { $0.lines.map(\.text) == ["Before"] })
        XCTAssertTrue(sources.isKept(kept.id))
        XCTAssertTrue(sources.candidates.contains { $0.lines.map(\.text) == ["After"] })
        let current = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(current?.map(\.text), ["After"])
    }

    func testEmbeddedRecordsFollowTheReplacedVersion() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let other = "[00:01.00]Other version"
        let old = "[00:01.00]Old version"
        let saved = "[00:01.00]Saved version\n[00:02.00]Saved two"
        await store.storeEmbeddedLyricsAlternatives(
            .init(variants: [.init(text: other), .init(text: old)]), forSongID: song.id
        )
        await store.storeEmbeddedFallbackLyrics(embedded(old), forSongID: song.id)

        // A timestamp spelled differently is another version: nothing is matched, the records are dropped.
        await store.updateEmbeddedLyricsRecords(
            forSongID: song.id, result: .replacedField, anchor: "[00:01.000]Old version", text: saved
        )
        let dropped = await store.embeddedLyricsAlternatives(forSongID: song.id)
        XCTAssertNil(dropped)

        await store.storeEmbeddedLyricsAlternatives(
            .init(variants: [.init(text: other), .init(text: old)]), forSongID: song.id
        )
        await store.storeEmbeddedFallbackLyrics(embedded(old), forSongID: song.id)
        await store.updateEmbeddedLyricsRecords(forSongID: song.id, result: .replacedField, anchor: old, text: saved)
        let alternatives = await store.embeddedLyricsAlternatives(forSongID: song.id)
        XCTAssertEqual(alternatives?.variants.map(\.text), [saved, other])
        XCTAssertEqual(alternatives?.inUseText, saved)
        let fallback = await store.embeddedFallbackLyrics(forSongID: song.id)
        XCTAssertEqual(fallback?.map(\.text), ["Saved version", "Saved two"])

        // The other version is deleted from the file: only one original is left, nothing to choose from.
        await store.updateEmbeddedLyricsRecords(forSongID: song.id, result: .removedField, anchor: other, text: nil)
        let remaining = await store.embeddedLyricsAlternatives(forSongID: song.id)
        XCTAssertNil(remaining)

        // Only the default field written: the records no longer describe the file.
        await store.updateEmbeddedLyricsRecords(forSongID: song.id, result: .wroteDefaultField, anchor: nil, text: saved)
        let gone = await store.embeddedFallbackLyrics(forSongID: song.id)
        XCTAssertNil(gone)
    }
}
