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
    func testEmbeddedSaveUsesTheFileOpenedByTheEditorAndRefusesLaterAudioChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let media = directory.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = MusicSource(id: UUID().uuidString, name: "Test", type: .local, basePath: media.path)
        let local = LocalFileSource(sourceID: source.id, basePath: media)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in local })
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"), publishesKeychainOptOuts: false)
        sources.add(source)
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("db"), deferredMaintenanceAllowed: { false })
        let file = media.appendingPathComponent("One.mp3")
        let originalText = "[00:01.00]Before the hillside"
        let payload = Data([3]) + Data("eng".utf8) + Data([0]) + Data(originalText.utf8)
        let uslt = Data("USLT".utf8) + Data([0, 0, 0, UInt8(payload.count), 0, 0]) + payload
        let frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(count: 413)
        var audio = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, UInt8(uslt.count)]) + uslt
        for _ in 0..<8 { audio.append(frame) }
        try audio.write(to: file)
        var track: Song?
        for try await row in try await local.scanSongs(from: "/", existingSongs: []) { track = row.song }
        let row = try XCTUnwrap(track)
        let scanned = try await local.metadataWritebackState(for: row.filePath)
        let original = scanned.applyingIdentity(to: row)
        library.addSongs([original], pruneMissingSongs: false)
        EmbeddedLyricsCopyPolicy.setMode(.embedOnly, forSongID: original.id)
        defer { EmbeddedLyricsCopyPolicy.setMode(nil, forSongID: original.id) }
        addTeardownBlock { await MetadataAssetStore.shared.invalidateCaches(forSongIDs: [original.id]) }

        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: permissions.intValue ^ 0o100], ofItemAtPath: file.path)
        let current = try await local.metadataWritebackState(for: row.filePath)
        XCTAssertNotEqual(current.revision, scanned.revision)
        XCTAssertEqual(current.modifiedDate, scanned.modifiedDate)
        for changedAfterOpening in [false, true] {
            let song = try XCTUnwrap(library.storedSong(id: original.id))
            let opened = await LyricsWriteback.loadEditablePayload(for: song, sourceManager: manager)
            let mode = await LyricsWriteback.resolveMode(for: song, sourceManager: manager, sourcesStore: sources)
            guard case .sidecar = mode else { return XCTFail("Expected an embedded-file destination") }
            var external = try Data(contentsOf: file)
            if changedAfterOpening {
                let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
                external[external.count - 1] ^= 1
                try external.write(to: file)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
            }
            let lyrics = changedAfterOpening ? "[00:01.00]Robins over the ridge" : "[00:01.00]Stars across the ridge"
            let saved = await LyricsWriteback.save(text: lyrics, for: song, mode: mode, allowRemoval: false,
                                                    sourceSnapshot: opened.sourceSnapshot, cacheSnapshot: opened.cacheSnapshot,
                                                    sourceManager: manager, library: library)
            if changedAfterOpening {
                XCTAssertFalse(saved.succeeded)
                XCTAssertEqual(try Data(contentsOf: file), external)
            } else {
                XCTAssertTrue(saved.succeeded, saved.errorMessage ?? "")
                let metadata = await FileMetadataReader.read(from: file)
                XCTAssertEqual(LyricsParser.parse(try XCTUnwrap(metadata.lyricsText)).map(\.text), ["Stars across the ridge"])
            }
        }
    }

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

    func testClearedSongRejectsRescansAfterReopeningAndAcceptsManualCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory)
        let removed = LyricsDocumentSource.embedded.stamped([LyricLine(timestamp: 1, text: "A paper kite counts clouds")])
        let cached = await store.cacheLyrics(removed, forSongID: "fixture")
        XCTAssertTrue(cached)
        var choices = LyricsVersionPreferences()
        choices.cleared = true
        choices.removedDocuments.insert(LyricsVersionPreferences.documentKey(removed))
        try await store.setLyricsVersionPreferences(choices, forSongID: "fixture")
        let reopened = MetadataAssetStore(storageDirectory: directory)
        let automatic = await reopened.cacheLyrics(removed, forSongID: "fixture")
        let playback = await reopened.cachedLyrics(forSongID: "fixture")
        XCTAssertFalse(automatic)
        XCTAssertNil(playback)
        let replacement = [LyricLine(timestamp: 3, text: "The rooftops turn a page")]
        let created = await reopened.replaceLyricsIfUnchanged(replacement, forSongID: "fixture",
                                                               expectedFingerprint: nil, userEdit: true)
        XCTAssertTrue(created)
        let restored = await reopened.cachedLyrics(forSongID: "fixture")
        XCTAssertEqual(restored?.map(\.text), replacement.map(\.text))
        let rescan = await reopened.cacheLyrics(removed, forSongID: "fixture")
        XCTAssertFalse(rescan)
    }

    @MainActor
    func testEditingAndDeletingLanguageSidecarDoesNotChangeItsSiblingOrPlayback() async throws {
        var track = song()
        track.fileFormat = .wav
        track.filePath = "/Music/Paper Jet.wav"
        let english = Data("[00:01.00]A paper jet leaves port".utf8)
        let chinese = Data("[00:01.00]纸飞机掠过窗台".utf8)
        let connector = LyricsDocumentFixtureConnector(directory: "/Music", files: [
            "Paper Jet.wav": Data([0, 1]), "Paper Jet.en.lrc": english, "Paper Jet.zh.lrc": chinese,
        ])
        let source = MusicSource(id: track.sourceID, name: "Fixture", type: .webdav, host: "fixture.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources = SourcesStore(storageDirectoryURL: directory)
        let library = AppServices.shared.musicLibrary
        guard case .documents(let listing) = await LyricsDocumentCatalog.load(for: track, sourceManager: manager, sourcesStore: sources) else {
            return XCTFail("Expected both language files")
        }
        let en = try XCTUnwrap(listing.entries.first { $0.languageCode == "en" })
        let zh = try XCTUnwrap(listing.entries.first { $0.languageCode == "zh" })
        try await LyricsDocumentCatalog.activate(en, for: track, sourceManager: manager)
        let old = try await LyricsDocumentCatalog.read(zh, for: track, sourceManager: manager)
        try await LyricsDocumentCatalog.save("[00:02.00]纸飞机落在码头", entry: zh, original: old,
                                            for: track, sourceManager: manager, library: library)
        guard case .documents(let saved) = await LyricsDocumentCatalog.load(for: track, sourceManager: manager, sourcesStore: sources) else {
            return XCTFail("Expected the edited file")
        }
        XCTAssertEqual(saved.entries.first(where: \.isActive)?.name, en.name)
        let edited = try XCTUnwrap(saved.entries.first { $0.name == zh.name })
        try await LyricsDocumentCatalog.remove([edited], for: track, sourceManager: manager, sourcesStore: sources, library: library)
        let files = await connector.files
        XCTAssertEqual(files[en.name], english)
        XCTAssertNil(files[zh.name])
        XCTAssertEqual(files["Paper Jet.wav"], Data([0, 1]))
        let playing = await LyricsLoader.load(for: track, sourceManager: manager, allowsAutomaticOnlineLyrics: false)
        XCTAssertEqual(playing.map(\.text), ["A paper jet leaves port"])
        LyricsDocumentPinStore.shared.clearPin(forSongID: track.id)
        _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: track.id)
    }

    @MainActor
    func testVersionDraftKeepsOrReplacesTheEditedEmbeddedLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let source = MusicSource(id: UUID().uuidString, name: "Test", type: .local, basePath: media.path)
        let local = LocalFileSource(sourceID: source.id, basePath: media)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in local })
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"), publishesKeychainOptOuts: false)
        sources.add(source)
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("db"), deferredMaintenanceAllowed: { false })
        let old = "[00:01.00]The rain measures the roof"
        let edited = "[00:02.00]A little boat counts the waves"
        let payload = Data([3]) + Data("eng".utf8) + Data([0]) + Data(old.utf8)
        let uslt = Data("USLT".utf8) + Data([0, 0, 0, UInt8(payload.count), 0, 0]) + payload
        let frame = Data([0xff, 0xfb, 0x90, 0x64]) + Data(count: 413)
        var audio = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, UInt8(uslt.count)]) + uslt
        for _ in 0..<8 { audio.append(frame) }

        for keep in [false, true] {
            let file = media.appendingPathComponent(keep ? "Keep.mp3" : "Replace.mp3")
            try audio.write(to: file)
            var track: Song?
            for try await row in try await local.scanSongs(from: "/", existingSongs: []) where row.song.filePath.hasSuffix(file.lastPathComponent) {
                track = row.song
            }
            let row = try XCTUnwrap(track)
            let scanned = try await local.metadataWritebackState(for: row.filePath)
            let song = scanned.applyingIdentity(to: row)
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
            try FileManager.default.setAttributes([.posixPermissions: permissions.intValue ^ 0o100], ofItemAtPath: file.path)
            let current = try await local.metadataWritebackState(for: row.filePath)
            XCTAssertNotEqual(scanned.revision, current.revision)
            XCTAssertEqual(scanned.fileSize, current.fileSize)
            XCTAssertEqual(scanned.modifiedDate, current.modifiedDate)
            library.addSongs([song], pruneMissingSongs: false)
            addTeardownBlock { await MetadataAssetStore.shared.invalidateCaches(forSongIDs: [song.id]) }
            func listed() async throws -> [LyricsDocumentCatalog.Entry] {
                let current = library.storedSong(id: song.id) ?? song
                guard case .documents(let listing) = await LyricsDocumentCatalog.load(for: current, sourceManager: manager, sourcesStore: sources)
                else { throw CocoaError(.fileReadUnknown) }
                return listing.entries
            }
            let initial = try await listed()
            let physical = try XCTUnwrap(initial.first(where: \.isEmbedded))
            try await LyricsDocumentCatalog.activate(physical, for: song, sourceManager: manager)
            let original = try await LyricsDocumentCatalog.read(physical, for: song, sourceManager: manager)
            let draft = LyricsVersionDraft(entry: physical, original: original, baseline: .init(parsing: old),
                                           document: .init(parsing: edited))
            try await draft.save(for: song, sourceManager: manager, library: library, mode: keep ? .keepAndSelect : .replace)
            let fields = try EmbeddedLyricsArchive.entries(in: Data(contentsOf: file), fileExtension: "mp3")
            XCTAssertEqual(fields.map { LyricsParser.parse($0.text).map(\.text) }, [["A little boat counts the waves"]])
            let after = try await listed()
            let active = try XCTUnwrap(after.first(where: \.isActive))
            XCTAssertTrue(active.isEmbedded)
            let kept = after.filter(\.isKeptVersion)
            XCTAssertEqual(kept.count, keep ? 1 : 0)
            if let previous = kept.first {
                XCTAssertEqual(previous.candidate?.lines.map(\.text), ["The rain measures the roof"])
                try await LyricsDocumentCatalog.activate(previous, for: song, sourceManager: manager)
                let switched = try await listed()
                XCTAssertEqual(switched.first(where: \.isActive)?.id, previous.id)
                try await LyricsDocumentCatalog.activate(active, for: song, sourceManager: manager)
            }
            let reloaded = try await listed()
            let next = try XCTUnwrap(reloaded.first(where: \.isActive))
            let beforeConflict = try await LyricsDocumentCatalog.read(next, for: song, sourceManager: manager)
            var external = try Data(contentsOf: file)
            external[external.count - 1] ^= 1
            let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            try external.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
            let stale = LyricsVersionDraft(entry: next, original: beforeConflict, baseline: .init(parsing: edited),
                                          document: .init(parsing: old))
            do {
                try await stale.save(for: song, sourceManager: manager, library: library, mode: .keepAndSelect)
                XCTFail("An external change after opening must stop the embedded write")
            } catch {
                XCTAssertEqual(try Data(contentsOf: file), external)
            }
            let playing = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
            XCTAssertEqual(playing?.map(\.text), ["A little boat counts the waves"])
        }
    }

    @MainActor
    func testPreviouslyHiddenEmbeddedLyricsStayHiddenWhenPhysicalFieldsAreListed() async throws {
        func frame(_ text: String) -> Data {
            let payload = Data([3]) + Data("eng".utf8) + Data([0]) + Data(text.utf8)
            return Data("USLT".utf8) + Data([0, 0, 0, UInt8(payload.count), 0, 0]) + payload
        }
        let hidden = "[00:01.00]A paper moon"
        let visible = "[00:02.00]The morning tide"
        let frames = frame(hidden) + frame(visible)
        let audio = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, UInt8(frames.count)]) + frames
        let fileName = "Paper Moon.mp3"
        let fixture = LyricsDocumentFixtureConnector(directory: "/Music", files: [fileName: audio])
        let source = MusicSource(id: UUID().uuidString, name: "Lyrics", type: .webdav, host: "fixture.invalid")
        let song = Song(id: UUID().uuidString, title: "Paper Moon", fileFormat: .mp3,
                        filePath: "/Music/" + fileName, sourceID: source.id, fileSize: Int64(audio.count))
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sources = SourcesStore(storageDirectoryURL: directory)
        sources.add(source)
        let store = MetadataAssetStore.shared
        addTeardownBlock {
            await store.invalidateCaches(forSongIDs: [song.id])
            try? FileManager.default.removeItem(at: directory)
        }
        func fields() async throws -> [String] {
            guard case .documents(let catalog) = await LyricsDocumentCatalog.load(for: song, sourceManager: manager, sourcesStore: sources) else {
                XCTFail("Missing embedded fields")
                return []
            }
            return catalog.entries.compactMap(\.embeddedText)
        }
        let before = try await fields()
        XCTAssertEqual(before, [hidden, visible])
        await store.hideLyricsVersion(LyricsDocumentSource.embedded.stamped(LyricsParser.parse(hidden)), forSongID: song.id)
        let after = try await fields()
        XCTAssertEqual(after, [visible])
        let files = await fixture.files
        XCTAssertEqual(files[fileName], audio)
    }

    @MainActor
    func testDeletingLastWritableVersionAllowsCreatingNewSidecar() async throws {
        try await verifyRecreationAfterLastVersion(sourceType: .webdav)
    }

    @MainActor
    func testHidingLastReadOnlyVersionAllowsCreatingLocalLyrics() async throws {
        try await verifyRecreationAfterLastVersion(sourceType: .upnp)
    }

    @MainActor
    private func verifyRecreationAfterLastVersion(sourceType: MusicSourceType) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let song = Song(id: UUID().uuidString, title: "Paper Window", fileFormat: .wav,
                        filePath: "/Music/Paper Window.wav", sourceID: UUID().uuidString, fileSize: 2)
        let audio = Data([0, 1])
        let english = Data("[00:01.00]A paper window holds the rain".utf8)
        let chinese = Data("[00:02.00]一叶纸窗托住雨滴".utf8)
        let initialFiles = ["Paper Window.wav": audio, "Paper Window.en.lrc": english, "Paper Window.zh.lrc": chinese]
        let fixture = LyricsDocumentFixtureConnector(directory: "/Music", files: initialFiles)
        let source = MusicSource(id: song.sourceID, name: "Paper Window", type: sourceType, host: "fixture.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
        let sources = SourcesStore(storageDirectoryURL: directory)
        sources.add(source)
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        addTeardownBlock {
            _ = await library.persistIncrementalNowAndWait()
            LyricsDocumentPinStore.shared.clearPin(forSongID: song.id)
            await MetadataAssetStore.shared.invalidateCaches(forSongIDs: [song.id])
            try FileManager.default.removeItem(at: directory)
        }

        func versions(for song: Song) async throws -> [LyricsDocumentCatalog.Entry] {
            guard case .documents(let listing) = await LyricsDocumentCatalog.load(
                for: song, sourceManager: manager, sourcesStore: sources
            ) else {
                XCTFail("Source did not return a catalog")
                return []
            }
            XCTAssertNil(listing.sourceError)
            return listing.entries
        }
        let original = try await versions(for: song)
        XCTAssertEqual(Set(original.map(\.name)), ["Paper Window.en.lrc", "Paper Window.zh.lrc"])
        var first = try XCTUnwrap(original.first { $0.languageCode == "en" })
        XCTAssertEqual(first.isPhysicallyRemovable, sourceType.supportsSidecarWriting)
        try await LyricsDocumentCatalog.activate(first, for: song, sourceManager: manager)
        if !sourceType.supportsSidecarWriting {
            let opened = try await LyricsDocumentCatalog.read(first, for: song, sourceManager: manager)
            XCTAssertEqual(opened.data, english)
            let edit = "[00:04.25]The window saves a drop of sun"
            try await LyricsDocumentCatalog.saveEditedLines(
                LyricsParser.parse(edit), text: edit, entry: first, original: opened,
                for: song, sourceManager: manager, library: library
            )
            let relisted = try await versions(for: song)
            XCTAssertEqual(Set(relisted.map(\.id)), Set(original.map(\.id)))
            let active = try XCTUnwrap(relisted.first(where: \.isActive))
            XCTAssertEqual(active.id, first.id)
            let edited = try await LyricsDocumentCatalog.read(active, for: song, sourceManager: manager)
            XCTAssertEqual(edited.text, edit)
            let playing = await LyricsLoader.load(for: song, sourceManager: manager, allowsAutomaticOnlineLyrics: false)
            XCTAssertEqual(playing.map(\.text), ["The window saves a drop of sun"])
            XCTAssertEqual(playing.map(\.timestamp), [4.25])
            let filesAfterEdit = await fixture.files
            XCTAssertEqual(filesAfterEdit, initialFiles)
            first = active
        }
        try await LyricsDocumentCatalog.remove([first], for: song, sourceManager: manager, sourcesStore: sources, library: library)
        let remaining = try await versions(for: song)
        XCTAssertEqual(remaining.map(\.name), ["Paper Window.zh.lrc"])
        let last = try XCTUnwrap(remaining.first)
        XCTAssertTrue(last.isActive)
        try await LyricsDocumentCatalog.remove([last], for: song, sourceManager: manager, sourcesStore: sources, library: library)

        let empty = try await versions(for: song)
        XCTAssertTrue(empty.isEmpty)
        let payload = await LyricsWriteback.loadEditablePayload(for: song, sourceManager: manager)
        XCTAssertEqual(payload.text, "")
        let filesAfterRemoval = await fixture.files
        XCTAssertEqual(filesAfterRemoval, sourceType.supportsSidecarWriting ? ["Paper Window.wav": audio] : initialFiles)

        let replacement = "[00:03.00]Daylight folds the paper crane"
        let mode = await LyricsWriteback.resolveMode(for: song, sourceManager: manager, sourcesStore: sources)
        let saved = await LyricsWriteback.save(
            text: replacement, for: song, mode: mode, allowRemoval: false, structuredLines: LyricsParser.parse(replacement),
            sourceSnapshot: payload.sourceSnapshot, cacheSnapshot: payload.cacheSnapshot, sourceManager: manager, library: library
        )
        XCTAssertTrue(saved.succeeded, saved.errorMessage ?? "")
        guard saved.succeeded else { return }
        XCTAssertEqual(saved.persistence, sourceType.supportsSidecarWriting ? .sidecar : .localOnly)
        let filesAfterCreation = await fixture.files
        if sourceType.supportsSidecarWriting {
            XCTAssertEqual(Set(filesAfterCreation.keys), ["Paper Window.wav", "Paper Window.lrc"])
            let sidecar = try XCTUnwrap(filesAfterCreation["Paper Window.lrc"])
            XCTAssertEqual(LyricsParser.parse(String(decoding: sidecar, as: UTF8.self)).map(\.text), ["Daylight folds the paper crane"])
            XCTAssertEqual(filesAfterCreation["Paper Window.wav"], audio)
        } else {
            XCTAssertEqual(filesAfterCreation, initialFiles)
        }
        let reopened = try await versions(for: saved.updatedSong)
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.isActive, true)
        let editor = await LyricsWriteback.loadEditablePayload(for: saved.updatedSong, sourceManager: manager)
        XCTAssertEqual(editor.playbackLines.map(\.text), ["Daylight folds the paper crane"])
        let playback = await LyricsLoader.load(for: saved.updatedSong, sourceManager: manager, allowsAutomaticOnlineLyrics: false)
        XCTAssertEqual(playback.map(\.text), ["Daylight folds the paper crane"])
        XCTAssertEqual(playback.map(\.timestamp), [3])
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

    func deleteFile(at path: String) async throws {
        guard files.removeValue(forKey: (path as NSString).lastPathComponent) != nil else {
            throw SourceError.fileNotFound(path)
        }
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

    func testLateOnlineLyricsDoNotRedirectTheSaveOrBecomeTheVersionBeingEdited() async throws {
        let store = MetadataAssetStore.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        for keepOriginal in [false, true] {
            let item = song()
            let original = "[00:01.00]Opened from the file"
            let draft = "[00:01.00]Handwritten lanterns"
            let otherSong = Data("[00:01.00]Next track".utf8)
            let fixture = LyricsDocumentFixtureConnector(directory: "/", files: [
                "Fixture.lrc": Data(original.utf8), "Next.lrc": otherSong
            ])
            let source = MusicSource(id: item.sourceID, name: "Test", type: .webdav, host: "fixture.invalid")
            let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
            library.addSongs([item])
            EmbeddedLyricsCopyPolicy.setMode(.off, forSongID: item.id)
            addTeardownBlock {
                EmbeddedLyricsCopyPolicy.setMode(nil, forSongID: item.id)
                await store.invalidateCaches(forSongIDs: [item.id])
            }
            let seeded = await store.cacheLyrics(
                LyricsDocumentSource.file("Fixture.lrc").stamped(LyricsContentParser.parseText(original)),
                forSongID: item.id
            )
            XCTAssertTrue(seeded)
            let opened = await LyricsWriteback.loadEditablePayload(for: item, sourceManager: manager)
            let destination = try await SidecarWriteService.shared.preflightLyricsWrite(for: item, using: fixture)
            let online = LyricsDocumentSource.online(identifier: "fixture", name: "Fixture").stamped(
                LyricsContentParser.parseText("[00:01.00]Late online result")
            )
            let arrived = await store.replaceLyricsIfUnchanged(
                online, forSongID: item.id, expectedFingerprint: opened.cacheSnapshot, force: false
            )
            XCTAssertTrue(arrived)
            if keepOriginal { LyricsWriteback.requestNewVersion(forSongID: item.id) }
            let result = await LyricsWriteback.save(
                text: draft, for: item, mode: .sidecar(destination), allowRemoval: false,
                sourceSnapshot: opened.sourceSnapshot, cacheSnapshot: opened.cacheSnapshot,
                sourceManager: manager, library: library
            )
            XCTAssertTrue(result.succeeded, result.errorMessage ?? "")
            XCTAssertEqual(result.persistence, .sidecar)
            let files = await fixture.files
            XCTAssertTrue(LyricsContentParser.areContentsSemanticallyEquivalent(
                String(decoding: try XCTUnwrap(files["Fixture.lrc"]), as: UTF8.self), draft
            ))
            XCTAssertEqual(files["Next.lrc"], otherSong)
            let cached = await store.cachedLyrics(forSongID: item.id)
            XCTAssertEqual(cached?.map(\.text), ["Handwritten lanterns"])
            let sources = await store.lyricsSourceCollection(forSongID: item.id)
            let originals = sources.candidates.filter { $0.lines.first?.text == "Opened from the file" }
            XCTAssertEqual(originals.count, keepOriginal ? 1 : 0)
            if let old = originals.first {
                XCTAssertEqual(old.source, .file("Fixture.lrc"))
                XCTAssertTrue(sources.isKept(old.id))
            }
            let onlineCandidate = try XCTUnwrap(sources.candidates.first { $0.lines.first?.text == "Late online result" })
            XCTAssertFalse(sources.isKept(onlineCandidate.id))
        }
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

    func testClearingStaysClearedUntilTheListenerActsAgain() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        let manager = SourceManager(sourcesProvider: { [] })
        let fileLines = embedded("[00:01.00]Words in the file")
        let seeded = await store.cacheLyrics(fileLines, forSongID: song.id, force: true)
        XCTAssertTrue(seeded)
        await store.storeEmbeddedFallbackLyrics(fileLines, forSongID: song.id)
        let opened = await store.cachedLyrics(forSongID: song.id)
        let snapshot = try XCTUnwrap(opened.map(LyricsDocumentFingerprint.init(lines:)))

        // A read-only source used to refuse this: there was nothing durable to remember it by.
        let outcome = await LyricsWriteback.save(
            text: "", for: song, mode: .localOnly(reason: nil), allowRemoval: true,
            cacheSnapshot: snapshot, sourceManager: manager, library: library
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
        XCTAssertEqual(outcome.notice, String(localized: "lyrics_version_hidden_in_primuse"))
        let cleared = await store.hasUserClearedLyrics(forSongID: song.id)
        XCTAssertTrue(cleared)

        let automatic = await store.cacheLyrics(embedded("[00:01.00]Online"), forSongID: song.id)
        XCTAssertFalse(automatic)
        let completion = await store.cacheLyrics(embedded("[00:01.00]Filled in"), forSongID: song.id, force: true)
        XCTAssertFalse(completion)
        let loaded = await LyricsLoader.load(for: song, sourceManager: manager)
        XCTAssertTrue(loaded.isEmpty)
        let fallback = await LyricsLoader.embeddedFallbackLyrics(for: song)
        XCTAssertNil(fallback)
        let payload = await LyricsWriteback.loadEditablePayload(for: song, sourceManager: manager)
        XCTAssertEqual(payload.text, "")

        let picked = await store.cacheLyrics(
            embedded("[00:01.00]Picked again"), forSongID: song.id, force: true, origin: .user
        )
        XCTAssertTrue(picked)
        let stillCleared = await store.hasUserClearedLyrics(forSongID: song.id)
        XCTAssertFalse(stillCleared)
        let reloaded = await LyricsLoader.load(
            for: song, sourceManager: manager, allowsAutomaticOnlineLyrics: false
        )
        XCTAssertEqual(reloaded.map(\.text), ["Picked again"])
    }

    func testDeletingTheFileInUseSwitchesToTheNextOne() async throws {
        let song = Song(id: "song-\(UUID().uuidString)", title: "Night Changes", fileFormat: .flac,
                        filePath: "/Music/Night Changes.flac", sourceID: "source", fileSize: 1)
        let lrc = Data("[00:01.00]From the LRC\n".utf8)
        let yrc = Data("[1000,1000](1000,1000,0)YRC\n".utf8)
        let fixture = LyricsDocumentFixtureConnector(directory: "/Music", files: [
            "Night Changes.flac": Data([0]), "Night Changes.lrc": lrc, "Night Changes.yrc": yrc,
        ])
        let source = MusicSource(id: "source", name: "Fixture", type: .webdav, host: "fixture.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourcesStore = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"),
                                   deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        let store = MetadataAssetStore.shared
        addTeardownBlock {
            await store.invalidateCaches(forSongIDs: [song.id])
            LyricsDocumentPinStore.shared.clearPin(forSongID: song.id)
        }

        guard case .documents(let first) = await LyricsDocumentCatalog.load(
            for: song, sourceManager: manager, sourcesStore: sourcesStore
        ) else { return XCTFail("Expected the lyric files") }
        let lrcEntry = try XCTUnwrap(first.entries.first { $0.name == "Night Changes.lrc" })
        try await LyricsDocumentCatalog.activate(lrcEntry, for: song, sourceManager: manager)
        guard case .documents(let listed) = await LyricsDocumentCatalog.load(
            for: song, sourceManager: manager, sourcesStore: sourcesStore
        ) else { return XCTFail("Expected the lyric files") }
        let active = try XCTUnwrap(listed.entries.first { $0.isActive && $0.candidate == nil })
        XCTAssertEqual(active.name, "Night Changes.lrc")

        let plan = await LyricsDocumentCatalog.deletionPlan(
            for: active, in: listed, song: song, sourceManager: manager
        )
        XCTAssertEqual(plan, .file)
        let content = try await LyricsDocumentCatalog.read(active, for: song, sourceManager: manager)
        let outcome = await LyricsWriteback.deleteVersion(
            active, plan: plan, expecting: content, for: song,
            sourceManager: manager, sourcesStore: sourcesStore, library: library
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
        XCTAssertFalse(outcome.cleared)
        let files = await fixture.files
        XCTAssertNil(files["Night Changes.lrc"])
        XCTAssertEqual(files["Night Changes.yrc"], yrc)
        let cached = await store.cachedLyrics(forSongID: song.id)
        XCTAssertEqual(cached?.map(\.text), ["YRC"])
    }

    func testDeletingTheOnlyVersionClearsTheSong() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourcesStore = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"),
                                   deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        let manager = SourceManager(sourcesProvider: { [] })
        let online = LyricsDocumentSource.online(identifier: "fixture", name: "Fixture")
            .stamped(LyricsContentParser.parseText("[00:01.00]Only online"))
        let seeded = await store.cacheLyrics(online, forSongID: song.id, force: true)
        XCTAssertTrue(seeded)

        guard case .documents(let documents) = await LyricsDocumentCatalog.load(
            for: song, sourceManager: manager, sourcesStore: sourcesStore
        ) else { return XCTFail("Expected the remembered version") }
        let entry = try XCTUnwrap(documents.entries.first { $0.isActive })
        let plan = await LyricsDocumentCatalog.deletionPlan(
            for: entry, in: documents, song: song, sourceManager: manager
        )
        XCTAssertEqual(plan, .forget)
        let outcome = await LyricsWriteback.deleteVersion(
            entry, plan: plan, expecting: nil, for: song,
            sourceManager: manager, sourcesStore: sourcesStore, library: library
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
        XCTAssertTrue(outcome.cleared)
        let cleared = await store.hasUserClearedLyrics(forSongID: song.id)
        XCTAssertTrue(cleared)
        let cached = await store.cachedLyrics(forSongID: song.id)
        XCTAssertNil(cached)
        let candidates = await store.lyricsSourceCollection(forSongID: song.id).candidates
        XCTAssertTrue(candidates.isEmpty)
    }

    func testSaveWritesOnlyTheSongTheEditorOpened() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        let manager = SourceManager(sourcesProvider: { [] })
        let payload = await LyricsWriteback.loadEditablePayload(for: song, sourceManager: manager)

        // The row now points at another file while the editor still holds the old one.
        var moved = try XCTUnwrap(library.storedSong(id: song.id))
        moved.filePath = "/Elsewhere/Fixture.flac"
        library.replaceSong(moved)
        let refused = await LyricsWriteback.save(
            text: "[00:01.00]Draft", for: song, mode: .localOnly(reason: nil), allowRemoval: false,
            cacheSnapshot: payload.cacheSnapshot, sourceManager: manager, library: library
        )
        XCTAssertFalse(refused.succeeded)
        XCTAssertEqual(refused.errorMessage, String(localized: "lyrics_version_target_moved"))
        let untouched = await store.cachedLyrics(forSongID: song.id)
        XCTAssertNil(untouched)

        // Saving the same draft again is the listener confirming it is still this song.
        let confirmed = await LyricsWriteback.save(
            text: "[00:01.00]Draft", for: song, mode: .localOnly(reason: nil), allowRemoval: false,
            cacheSnapshot: payload.cacheSnapshot, sourceManager: manager, library: library
        )
        XCTAssertTrue(confirmed.succeeded, confirmed.errorMessage ?? "")
    }

    func testSongsOutsideTheLibraryStillSave() async throws {
        // Folder browsing and plug-in songs open the editor without a library row.
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        let outcome = await LyricsWriteback.save(
            text: "[00:01.00]Draft", for: song, mode: .localOnly(reason: nil), allowRemoval: false,
            sourceManager: SourceManager(sourcesProvider: { [] }), library: library
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
    }

    func testOwnFileIdentityIsComparedWithTolerance() {
        var song = song()
        song.lastModified = Date(timeIntervalSince1970: 1_000)
        song.revision = "r1"
        let target = LyricsWriteback.EditTarget(song)
        var resaved = song
        resaved.lastModified = Date(timeIntervalSince1970: 1_001.5)
        XCTAssertTrue(target.isSameFile(as: resaved))
        resaved.fileSize = 2
        XCTAssertFalse(target.isSameFile(as: resaved))
        var rewritten = song
        rewritten.revision = "r2"
        XCTAssertFalse(target.isSameFile(as: rewritten))
    }

    func testDeletingTheOnlyFileClearsInsteadOfRestoringIt() async throws {
        let song = Song(id: "song-\(UUID().uuidString)", title: "Night Changes", fileFormat: .flac,
                        filePath: "/Music/Night Changes.flac", sourceID: "source", fileSize: 1)
        let lrc = Data("[00:01.00]Only file\n".utf8)
        let fixture = LyricsDocumentFixtureConnector(directory: "/Music", files: [
            "Night Changes.flac": Data([0]), "Night Changes.lrc": lrc,
        ])
        let source = MusicSource(id: "source", name: "Fixture", type: .webdav, host: "fixture.invalid")
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in fixture })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourcesStore = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"),
                                   deferredMaintenanceAllowed: { false })
        library.addSongs([song])
        let store = MetadataAssetStore.shared
        addTeardownBlock {
            await store.invalidateCaches(forSongIDs: [song.id])
            LyricsDocumentPinStore.shared.clearPin(forSongID: song.id)
        }
        guard case .documents(let first) = await LyricsDocumentCatalog.load(
            for: song, sourceManager: manager, sourcesStore: sourcesStore
        ) else { return XCTFail("Expected the lyric file") }
        let lrcEntry = try XCTUnwrap(first.entries.first { $0.name == "Night Changes.lrc" })
        try await LyricsDocumentCatalog.activate(lrcEntry, for: song, sourceManager: manager)
        guard case .documents(let listed) = await LyricsDocumentCatalog.load(
            for: song, sourceManager: manager, sourcesStore: sourcesStore
        ) else { return XCTFail("Expected the lyric file") }
        let active = try XCTUnwrap(listed.entries.first { $0.isActive && $0.candidate == nil })
        let content = try await LyricsDocumentCatalog.read(active, for: song, sourceManager: manager)
        let outcome = await LyricsWriteback.deleteVersion(
            active, plan: .file, expecting: content, for: song,
            sourceManager: manager, sourcesStore: sourcesStore, library: library
        )
        XCTAssertTrue(outcome.succeeded, outcome.errorMessage ?? "")
        XCTAssertTrue(outcome.cleared)
        let cached = await store.cachedLyrics(forSongID: song.id)
        XCTAssertNil(cached)
        let candidates = await store.lyricsSourceCollection(forSongID: song.id).candidates
        XCTAssertFalse(candidates.contains { $0.lines.map(\.text) == ["Only file"] })
    }

    func testDeletingAKeptVersionNeverTouchesTheFile() async throws {
        let song = song()
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourcesStore = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let manager = SourceManager(sourcesProvider: { [] })
        let before = embedded("[00:01.00]Before")
        let after = embedded("[00:01.00]After")
        let seeded = await store.cacheLyrics(before, forSongID: song.id, force: true)
        XCTAssertTrue(seeded)
        // The file holds the current version only; the old one stays as a kept version.
        await store.storeEmbeddedFallbackLyrics(after, forSongID: song.id)
        let saved = await store.cacheLyrics(after, forSongID: song.id, force: true, origin: .user, previousVersion: .keep)
        XCTAssertTrue(saved)
        guard case .documents(let documents) = await LyricsDocumentCatalog.load(
            for: song, sourceManager: manager, sourcesStore: sourcesStore
        ) else { return XCTFail("Expected remembered versions") }
        let kept = try XCTUnwrap(documents.entries.first { $0.isKeptVersion })
        let plan = await LyricsDocumentCatalog.deletionPlan(for: kept, in: documents, song: song, sourceManager: manager)
        XCTAssertEqual(plan, .forget)
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
