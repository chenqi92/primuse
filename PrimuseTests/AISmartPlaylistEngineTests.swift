import Foundation
import PrimuseKit
import XCTest
import SwiftUI
import UIKit
@testable import Primuse

@MainActor
final class AISmartPlaylistEngineTests: XCTestCase {
    func testEditingPinnedSceneRefreshesItsTitleAndSongsWithoutMovingThePin() async throws {
        let suite = "ListeningSceneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory)
        await library.whenReady()
        library.addSongs([song(id: "one", title: "One", path: "/one.flac"), song(id: "two", title: "Two", path: "/two.flac")])
        for _ in 0..<100 where library.musicSongs.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        var scene = SmartPlaylist(name: "Old scene", kind: .ai, aiConfiguration:
            AISmartPlaylistConfiguration().replacingScene(prompt: "sad", selections: [
                selection(songID: "one", title: "One", path: "/one.flac")
            ]))
        library.saveSmartPlaylist(scene)
        let service = ListeningIntentService(defaults: defaults)
        service.setAICurationEnabled(false)
        service.refresh(library: library)
        service.setSmartPlaylistPinned(true, playlistID: scene.id)
        service.setPinned(true, intentID: "builtin:pop")
        let pins = service.configuration.pinnedIDs
        let intentID = ListeningIntent.smartPlaylistIntentID(scene.id)
        XCTAssertEqual(service.smartPlaylistCounts[intentID], 1)
        scene.name = "New scene"
        scene.aiConfiguration = scene.aiConfiguration?.replacingScene(prompt: "sweet", selections: [
            selection(songID: "one", title: "One", path: "/one.flac"),
            selection(songID: "two", title: "Two", path: "/two.flac")
        ])
        library.saveSmartPlaylist(scene)
        service.refresh(library: library)
        service.setSmartPlaylistPinned(true, playlistID: scene.id)
        XCTAssertEqual(service.smartPlaylistCounts[intentID], 2)
        XCTAssertEqual(service.smartPlaylistNames[intentID], "New scene")
        XCTAssertEqual(service.configuration.pinnedIDs, pins)
    }

    func testSceneEditorRestoresSavedPrompt() async throws {
        let suite = "ListeningSceneEditorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory)
        let intelligence = MusicIntelligenceService(
            settingsStore: AISettingsStore(defaults: defaults, syncsThroughICloud: false),
            recommendationReuseDefaults: defaults
        )
        let prompt = "适合求婚的温柔情歌，排除分手和遗憾主题。"
        let playlist = SmartPlaylist(name: "求婚", kind: .ai, aiConfiguration:
            AISmartPlaylistConfiguration().replacingScene(prompt: prompt, selections: []))
        let host = UIHostingController(rootView: AIPlaylistEditorView(existing: playlist)
            .environment(library).environment(intelligence)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        func textViews(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        XCTAssertTrue(textViews(host.view).contains { $0.text == prompt })
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "listening-scene-editor"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAIPlaylistResolvesPortableIdentitiesInGeneratedOrder() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseAISmartPlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        library.sourceIdentityResolver = { sourceID in
            sourceID == "local-source" ? "shared-account" : nil
        }
        let first = song(id: "local-one", title: "First", path: "/one.flac")
        let second = song(id: "local-two", title: "Second", path: "/two.flac")
        library.addSongs([first, second], affectedSourceIDs: ["local-source"])
        for _ in 0..<100 where library.visibleSongs.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.map(\.id), [first.id, second.id])

        let playlist = SmartPlaylist(
            name: "Generated",
            kind: .ai,
            aiConfiguration: AISmartPlaylistConfiguration(selections: [
                selection(
                    songID: "remote-two",
                    title: "Second",
                    path: "/two.flac",
                    accountID: "shared-account"
                ),
                selection(songID: first.id, title: first.title, path: first.filePath),
                selection(songID: "missing", title: "Missing", path: "/missing.flac"),
                selection(songID: first.id, title: first.title, path: first.filePath),
            ])
        )

        let matches = SmartPlaylistEngine.match(
            playlist,
            in: library,
            history: .shared
        )

        XCTAssertEqual(matches.map(\.id), [second.id, first.id])
    }

    private func song(id: String, title: String, path: String) -> Song {
        Song(
            id: id,
            title: title,
            artistName: "Artist",
            duration: 180,
            fileFormat: .flac,
            filePath: path,
            sourceID: "local-source"
        )
    }

    private func selection(
        songID: String,
        title: String,
        path: String,
        accountID: String? = nil
    ) -> AISmartPlaylistSelection {
        AISmartPlaylistSelection(identity: SongIdentity(
            songID: songID,
            title: title,
            artistName: "Artist",
            duration: 180,
            cloudAccountID: accountID,
            filePath: path
        ))
    }
}

/// 规则歌单的匹配结果按输入版本缓存: 歌曲内容、规则、歌单成员任一变了, 下一次
/// 取到的就是新结果; 随机排序每次取用照旧重新洗牌、截断。
@MainActor
final class SmartPlaylistEngineCacheTests: XCTestCase {
    func testCachedMatchFollowsSongsRulesAndMembership() async throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseSmartPlaylistCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let library = MusicLibrary(storageDirectory: storageDirectory)
        var two = song(id: "two", title: "Hate Two")
        library.addSongs([song(id: "one", title: "Love One"), two, song(id: "three", title: "Love Three")])
        for _ in 0..<100 where library.visibleSongs.count != 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.count, 3)

        let love = SmartPlaylist(name: "Love", rules: [.init(field: .title, op: .contains, value: "love")])
        func ids(_ smart: SmartPlaylist) -> Set<String> {
            Set(SmartPlaylistEngine.match(smart, in: library, history: .shared).map(\.id))
        }
        XCTAssertEqual(ids(love), ["one", "three"])
        XCTAssertEqual(ids(love), ["one", "three"])

        two.title = "Love Two"
        library.replaceSongs([two], maintenance: .immediate)
        XCTAssertEqual(ids(love), ["one", "two", "three"])

        var edited = love
        edited.rules = [.init(field: .title, op: .contains, value: "three")]
        XCTAssertEqual(ids(edited), ["three"])

        let playlist = library.createPlaylist(name: "Picked")
        let inPlaylist = SmartPlaylist(
            name: "In playlist",
            rules: [.init(field: .isInPlaylist, op: .equals, value: playlist.id)]
        )
        XCTAssertTrue(ids(inPlaylist).isEmpty)
        library.add(songIDs: ["one"], toPlaylist: playlist.id)
        XCTAssertEqual(ids(inPlaylist), ["one"])

        let random = SmartPlaylist(name: "Random", limit: 2, sortField: .random)
        for _ in 0..<6 {
            let picked = SmartPlaylistEngine.match(random, in: library, history: .shared)
            XCTAssertEqual(picked.count, 2)
            XCTAssertTrue(Set(picked.map(\.id)).isSubset(of: ["one", "two", "three"]))
        }
    }

    private func song(id: String, title: String) -> Song {
        Song(id: id, title: title, artistName: "Artist", duration: 180,
             fileFormat: .flac, filePath: "/\(id).flac", sourceID: "local-source")
    }
}
