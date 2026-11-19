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

    func testRecommendationPayloadCapsSongsAndFindsHistoryBeyondTheCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = PlayHistoryStore(storeURL: dir.appendingPathComponent("history.json"))
        var tail = song(id: "history", title: "Night Ferry", path: "/tail")
        history.record(song: tail, startedAt: Date().addingTimeInterval(-3600), listenedSec: 180)
        tail.artistName = "Updated artist"
        tail.genre = "Jazz"
        var laterCopy = tail
        laterCopy.genre = "Other"
        let initial = (0..<150).map { song(id: "track-\($0)", title: "Track \($0)", path: "/track/\($0)") }
        let rows = [song(id: "", title: "Empty", path: "/empty"), initial[0]] + initial + [tail, laterCopy]
        let request = try XCTUnwrap(AIRecommendationContextBuilder.request(
            scene: .automatic, candidates: rows, candidateLimit: 500_000, history: history
        ))
        XCTAssertEqual(request.candidates.map(\.songID), Array(initial.prefix(100).map(\.id)))
        XCTAssertEqual(request.preferences.first?.artist, tail.artistName)
        XCTAssertEqual(request.preferences.first?.genre, "Jazz")
        let album = AIRecommendationAlbumCandidate(albumKey: "a", title: "Harbour", artist: "North", trackCount: 4)
        let albumsOnly = AIRecommendationContextBuilder.request(
            scene: .automatic, candidates: [], candidateLimit: 0, unit: .albums, albumCandidates: [album], history: history
        )
        XCTAssertEqual(albumsOnly?.albumCandidates.map(\.albumKey), ["a"])
        XCTAssertNil(AIRecommendationContextBuilder.request(scene: .automatic, candidates: [], history: history))
    }

    func testThousandSongFillResumesShortBatchesWithoutRepeatingSelections() async {
        let rows = (0..<1030).map { song(id: String($0), title: "Test \($0)", path: "/\($0)") }
        var ids = Array(rows.prefix(6).map(\.id))
        var batches = 0
        let count = await AIPlaylistGeneration.fill(to: 1000, startingWith: ids, candidates: { excluded in
            XCTAssertEqual(excluded, Set(ids))
            return Array(rows.lazy.filter { !excluded.contains($0.id) }.prefix(110))
        }, request: { page, requested, appending in
            XCTAssertTrue(appending)
            XCTAssertLessThanOrEqual(page.count, 100)
            XCTAssertLessThanOrEqual(requested, 30)
            let additions = page.prefix(min(requested, batches.isMultiple(of: 2) ? 5 : 30)).map(\.id)
            ids.append(contentsOf: additions)
            batches += 1
            return .added(additions)
        })
        XCTAssertEqual(count, 1000)
        XCTAssertEqual(ids, rows.prefix(1000).map(\.id))
        XCTAssertGreaterThan(batches, 34)
    }

    func testCandidateRefillsCanSaveAThousandUniquePortableSongs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        await library.whenReady()
        library.sourceIdentityResolver = { _ in "shared-catalog" }
        let tracks = (0..<1002).map { song(id: String($0), title: "Track \($0)", path: "/\($0).flac") }
        var aliases = Array(tracks.prefix(110))
        for index in aliases.indices {
            aliases[index].id = "mirror-\(index)"
            aliases[index].sourceID = "mirror"
        }
        library.addSongs(tracks + aliases)
        await library.waitForPendingIndex()
        library.setDisliked(songID: "1001", isDisliked: true)
        let existing = library.portableSongIdentity(for: tracks[0])
        let finder = AIPlaylistCandidateFinder(queries: ["Track"], library: library, existing: [existing])
        var selected: [String] = []
        var requests = 0
        let count = await AIPlaylistGeneration.fill(to: 1000, startingWith: [], candidates: { excluded in
            await finder.next(excluding: excluded, selectedIDs: selected)
        }, request: { page, requested, _ in
            requests += 1
            let ids = page.prefix(requested).map(\.id)
            selected.append(contentsOf: ids)
            return .added(ids)
        })
        let selections = selected.compactMap { library.visibleSong(id: $0) }.map {
            AISmartPlaylistSelection(identity: library.portableSongIdentity(for: $0))
        }
        let saved = AISmartPlaylistConfiguration().appending(prompt: "Track", selections: selections)
        XCTAssertEqual(count, 1000)
        XCTAssertEqual(saved.selections.count, 1000)
        XCTAssertEqual(Set(saved.selections.map(\.identity.filePath)), Set((1...1000).map { "/\($0).flac" }))
        XCTAssertGreaterThanOrEqual(requests, 34)
    }

    func testPlaylistRefillRetriesShortLimitAndStopsOnRepeatedEmptyOrHardFailure() async {
        let rows = (0..<205).map { song(id: String($0), title: "Test \($0)", path: "/\($0)") }
        var requests: [[String]] = []
        var waits: [Double] = []
        let count = await AIPlaylistGeneration.fill(to: 101, startingWith: [], candidates: { excluded in
            Array(rows.lazy.filter { !excluded.contains($0.id) }.prefix(100))
        }, request: { page, _, appending in
            requests.append(page.map(\.id))
            switch requests.count {
            case 1: return .retry(after: 4.1)
            case 2:
                XCTAssertFalse(appending)
                return .added([page[0].id])
            case 3:
                XCTAssertTrue(appending)
                return .empty
            default: return .empty
            }
        }, wait: { waits.append($0) })
        XCTAssertEqual(count, 1)
        XCTAssertEqual(waits, [5])
        XCTAssertEqual(requests.count, 4)
        if requests.count == 4 {
            XCTAssertEqual(requests[0], requests[1])
            XCTAssertTrue(Set(requests[2]).isDisjoint(with: requests[3]))
        }

        var calls = 0
        let retained = await AIPlaylistGeneration.fill(to: 1000, startingWith: ["saved"], candidates: { _ in rows },
            request: { _, _, _ in calls += 1; return .stopped })
        XCTAssertEqual(retained, 1)
        XCTAssertEqual(calls, 1)
    }

    func testPlaylistRefillHandlesExhaustionAndCancellationWhileWaiting() async {
        let rows = [song(id: "only", title: "Only", path: "/one")]
        var calls = 0
        let exhausted = await AIPlaylistGeneration.fill(to: 1000, startingWith: [], candidates: { _ in rows },
            request: { page, count, _ in
                calls += 1
                XCTAssertEqual(count, 1)
                return .added(page.map(\.id))
            })
        XCTAssertEqual(exhausted, 1)
        XCTAssertEqual(calls, 1)

        var attempts = 0
        let task = Task { @MainActor in
            await AIPlaylistGeneration.fill(to: 100, startingWith: ["saved"], candidates: { _ in rows }, request: { _, _, _ in
                attempts += 1
                return .retry(after: 60)
            }, wait: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            })
        }
        let retained = await task.value
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(retained, 1)
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
