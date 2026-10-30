import XCTest
import PrimuseKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

@MainActor
final class SpokenChapterGeneratorTests: XCTestCase {
    typealias G = SpokenChapterGeneration
    private func song(_ id: String = "one") -> Song {
        Song(id: id, title: "Book \(id)", duration: 4_000, fileFormat: .mp3, filePath: "\(id).mp3", sourceID: "test")
    }
    private let transcript = [LyricLine(timestamp: 0, text: "Opening", isSynchronized: true),
                              LyricLine(timestamp: 2_000, text: "Next topic", isSynchronized: true)]
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChapterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func answer(_ request: G.Request) -> G.Answer {
        .init(summary: "Topics", chapters: request.stage == .curate ? request.candidates : request.lines.map { .init(lineID: $0.id, title: $0.text) })
    }

    func testWholeBookApplyEditingAndReopening() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let library = MusicLibrary(storageDirectory: url)
        let generator = SpokenChapterGenerator(usesDefaultStorage: false)
        generator.start(songs: [song(), song("two")], library: library, loadTranscript: { _ in self.transcript }, request: answer)
        await generator.waitForCompletion()
        XCTAssertNil(generator.failure)
        XCTAssertEqual(generator.completedItems, 2)
        XCTAssertNil(library.generatedChapters(for: "one"), "Preview must not replace playback chapters")
        generator.rename(songID: "one", index: 0, title: "Edited opening")
        generator.remove(songID: "two", index: 1)
        try await generator.apply(to: library)
        XCTAssertEqual(library.generatedChapters(for: "one")?.map(\.startTime), [0, 2_000])
        XCTAssertEqual(library.generatedChapters(for: "two")?.count, 1)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }
        let reopened = MusicLibrary(storageDirectory: url)
        XCTAssertEqual(reopened.generatedChapters(for: "one")?.first?.title, "Edited opening")
        var disabled = try XCTUnwrap(reopened.generatedChapterRecord(id: "one"))
        disabled.isEnabled = false; disabled.updatedAt = Date().addingTimeInterval(1)
        reopened.saveGeneratedChapterRecord(disabled)
        XCTAssertNil(reopened.generatedChapters(for: "one"))
        XCTAssertEqual(reopened.generatedChapterRecord(id: "one")?.chapters.count, 2)
    }

    func testChangedTranscriptPreventsApplyingAnyPartOfBook() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let library = MusicLibrary(storageDirectory: url)
        let generator = SpokenChapterGenerator(usesDefaultStorage: false)
        var changed = false
        generator.start(songs: [song(), song("two")], library: library, loadTranscript: { song in
            changed && song.id == "two" ? [.init(timestamp: 0, text: "New transcript", isSynchronized: true)] : self.transcript
        }, request: answer)
        await generator.waitForCompletion()
        changed = true
        do { try await generator.apply(to: library); XCTFail("Expected stale transcript rejection") }
        catch { XCTAssertEqual(error as? G.Failure, .changedDuringGeneration) }
        XCTAssertNil(library.generatedChapterRecord(id: "one"))
        XCTAssertNil(library.generatedChapterRecord(id: "two"))
    }

    func testConcurrentUserEditIsNotOverwritten() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let library = MusicLibrary(storageDirectory: url)
        let generator = SpokenChapterGenerator(usesDefaultStorage: false)
        generator.start(songs: [song()], library: library, loadTranscript: { _ in self.transcript }, request: answer)
        await generator.waitForCompletion()
        let edit = SpokenChapterRecord(id: "one", chapters: [.init(startTime: 0, title: "From another device")], transcriptFingerprint: "other", providerName: "AI")
        library.saveGeneratedChapterRecord(edit)
        do { try await generator.apply(to: library); XCTFail("Expected revision conflict") }
        catch { XCTAssertEqual(error as? G.Failure, .changedDuringGeneration) }
        XCTAssertEqual(library.generatedChapterRecord(id: "one"), edit)
    }

    func testFailedRequestResumesAfterRestartWithoutRepeatingCompletedRequests() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let library = MusicLibrary(storageDirectory: url)
        let checkpoint = url.appendingPathComponent("resume.json")
        let first = SpokenChapterGenerator(checkpointURL: checkpoint, usesDefaultStorage: false)
        var calls = 0
        first.start(songs: [song()], library: library, loadTranscript: { _ in self.transcript }, request: { request in
            calls += 1
            if calls == 2 { throw G.Failure.invalidResponse }
            return self.answer(request)
        })
        await first.waitForCompletion()
        XCTAssertNotNil(first.failure)
        XCTAssertTrue(first.previews.isEmpty)
        XCTAssertNil(library.generatedChapterRecord(id: "one"))
        let resumed = SpokenChapterGenerator(checkpointURL: checkpoint, usesDefaultStorage: false)
        var resumedCalls = 0
        resumed.start(songs: [song()], library: library, loadTranscript: { _ in self.transcript }, request: { request in
            resumedCalls += 1; return self.answer(request)
        })
        await resumed.waitForCompletion()
        XCTAssertNil(resumed.failure)
        XCTAssertEqual(resumedCalls, 2, "Only the failed window and curation should run")
        try await resumed.apply(to: library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    func testCancellationAndMissingTimelineNeverPublishChapters() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let library = MusicLibrary(storageDirectory: url)
        let generator = SpokenChapterGenerator(usesDefaultStorage: false)
        generator.start(songs: [song()], library: library, loadTranscript: { _ in self.transcript }, request: { _ in
            throw CancellationError()
        })
        await generator.waitForCompletion()
        XCTAssertFalse(generator.isRunning)
        XCTAssertTrue(generator.previews.isEmpty)
        XCTAssertNil(library.generatedChapterRecord(id: "one"))
        var requested = false
        generator.start(songs: [song()], library: library, loadTranscript: { _ in [] }, request: { request in
            requested = true; return self.answer(request)
        })
        await generator.waitForCompletion()
        XCTAssertNotNil(generator.failure)
        XCTAssertFalse(requested)
    }

    #if !os(tvOS)
    func testPlaybackUsesGeneratedChaptersAndRestoresOriginals() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let suite = "ChapterPlayback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(storageDirectory: url)
        let player = AudioPlayerService(library: library, playbackSettings: PlaybackSettingsStore(defaults: defaults),
                                        playbackSessionStore: PlaybackSessionStore(url: url.appendingPathComponent("session.json")),
                                        activateAudioSession: { _ in XCTFail("Editing chapters must not start playback") })
        player.currentSong = song()
        let original = [MediaChapter(startTime: 0, title: "Embedded opening"), .init(startTime: 2_000, title: "Embedded next")]
        player.spokenWordChapters = original
        var generated = SpokenChapterRecord(id: "one", chapters: [.init(startTime: 0, title: "AI opening"), .init(startTime: 900, title: "AI next")], transcriptFingerprint: "text", providerName: "AI")
        library.saveGeneratedChapterRecord(generated)
        player.currentTime = 1_200; player.refreshCurrentChapter()
        XCTAssertEqual(player.currentChapterIndex, 1)
        XCTAssertEqual(player.currentChapter?.title, "AI next")
        XCTAssertEqual(player.originalSpokenWordChapters, original)
        generated.isEnabled = false; generated.updatedAt = Date().addingTimeInterval(1)
        library.saveGeneratedChapterRecord(generated)
        player.refreshCurrentChapter()
        XCTAssertEqual(player.spokenWordChapters, original)
        XCTAssertEqual(player.currentChapterIndex, 0)
        player.currentSong = nil
    }
    #endif

    func testPreviewAndSavedChapterScreensRender() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let library = MusicLibrary(storageDirectory: url)
        let generator = SpokenChapterGenerator(usesDefaultStorage: false)
        let item = Song(id: "screen", title: "城市的声音：从街头到录音室", duration: 4_000, fileFormat: .mp3, filePath: "screen.mp3", sourceID: "test")
        let lines = [LyricLine(timestamp: 0, text: "开场：城市声音的记忆", isSynchronized: true),
                     LyricLine(timestamp: 900, text: "街头采样与声音设计", isSynchronized: true),
                     LyricLine(timestamp: 2_000, text: "从生活素材到音乐作品", isSynchronized: true)]
        generator.start(songs: [item], library: library, loadTranscript: { _ in lines }, request: answer)
        await generator.waitForCompletion()
        let content = SpokenChapterGenerationSheet(song: item, bookSongs: [item, song("two")], library: library,
                                                   loadTranscript: { _ in lines }, generator: generator)
            .environment(MusicIntelligenceService())
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        #if os(macOS)
        let host = NSHostingController(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = host; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let host = UIHostingController(rootView: content)
        #if os(tvOS)
        window.overrideUserInterfaceStyle = .dark
        #endif
        window.rootViewController = host; window.makeKeyAndVisible()
        #endif
        for state in ["preview", "saved"] {
            if state == "saved" { try await generator.apply(to: library) }
            try await Task.sleep(for: .milliseconds(700))
            #if os(macOS)
            host.view.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.isVisible)
            XCTAssertGreaterThan(host.view.bounds.width, 400)
            #else
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let data = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(data.count, 10_000)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("chapters-\(state).png")
            try data.write(to: file)
            print("CHAPTER_SCREEN=\(file.path)")
            let attachment = XCTAttachment(image: image); attachment.name = "chapters-\(state)"; add(attachment)
            #endif
        }
    }

    func testSnapshotSyncKeepsDeletionAndAcceptsNewerEdit() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let library = MusicLibrary(storageDirectory: url)
        let old = SpokenChapterRecord(id: "one", chapters: [.init(startTime: 0, title: "Old")], transcriptFingerprint: "x", providerName: "AI", updatedAt: Date(timeIntervalSince1970: 10))
        var deleted = old; deleted.isDeleted = true; deleted.chapters = []; deleted.updatedAt = Date(timeIntervalSince1970: 20)
        library.saveGeneratedChapterRecord(deleted)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }
        let local = try Data(contentsOf: url.appendingPathComponent("library-cache.json"))
        struct Snapshot: Encodable { var songs: [Song] = []; var playlists: [Playlist] = []; var generatedChapters: [SpokenChapterRecord] }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let merged = try MusicLibrary.mergingSnapshotUserState(localData: local, incomingData: encoder.encode(Snapshot(generatedChapters: [old])), locallyRetainedSongIDs: [])
        try merged.write(to: url.appendingPathComponent("library-cache.json"))
        let reopened = MusicLibrary(storageDirectory: url)
        XCTAssertNil(reopened.generatedChapters(for: "one"))
        XCTAssertTrue(reopened.generatedChapterRecord(id: "one")?.isDeleted == true)
        var fresh = old; fresh.updatedAt = Date(timeIntervalSince1970: 30); fresh.chapters[0].title = "Regenerated"
        let next = try MusicLibrary.mergingSnapshotUserState(localData: merged, incomingData: encoder.encode(Snapshot(generatedChapters: [fresh])), locallyRetainedSongIDs: [])
        try next.write(to: url.appendingPathComponent("library-cache.json"))
        XCTAssertEqual(MusicLibrary(storageDirectory: url).generatedChapters(for: "one")?.first?.title, "Regenerated")
    }
}
