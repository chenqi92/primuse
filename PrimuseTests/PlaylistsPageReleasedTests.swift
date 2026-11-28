import Foundation
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

/// 6c 单元 4 U9b:iPhone 资料库的「歌单」分区(与 Mac 的歌单总览同一个 `PlaylistListView`)在歌曲模型放掉之后不再占用模型:
/// 「只看有离线可用曲目的」要看的歌、分组「播放全部」要的智能歌单 id、长按菜单「分享到服务器」的目标,都与模型在内存里时
/// 相同,不装模型、不读整库数组;AI 歌单要按身份对回整库,先占用模型装回来再对(装一次),结果相同。
/// 行上的曲数与封面走资料库的按 id 读(19a 的 `songSummary` / `songCount`,Mac 那一页已经这样用)。
@MainActor
final class PlaylistsPageReleasedTests: LibraryReadyCatalogFixture {
    private static let serverSource = "u9b-navidrome"

    private static func serverSongs(prefix: String) -> [Song] {
        (1...3).map { index in
            var song = Song(id: "\(prefix)-srv-\(index)", title: "Server \(index)", albumTitle: "Remote", artistName: "Ada",
                            fileFormat: .mp3, filePath: "/songs/item-\(index).mp3", sourceID: serverSource)
            song.dateAdded = Date(timeIntervalSince1970: 1_700_700_000 + Double(index))
            return song
        }
    }

    private static func selection(_ song: Song) -> AISmartPlaylistSelection {
        AISmartPlaylistSelection(identity: SongIdentity(
            songID: song.id, title: song.title, artistName: song.artistName ?? "", duration: song.duration,
            cloudAccountID: nil, filePath: song.filePath
        ))
    }

    private struct Picture: Equatable {
        var offline: [String: [String]] = [:]
        var smartIDs: [String: [String]] = [:]
    }

    private func picture(
        _ library: MusicLibrary, playlists: [Playlist], smarts: [SmartPlaylist]
    ) async throws -> Picture {
        var picture = Picture()
        for playlist in playlists {
            let answer = await PlaylistListCatalog.offlineProbeSongs(playlist: playlist, library: library)
            let songs = try XCTUnwrap(answer, playlist.name)
            picture.offline[playlist.name] = songs.map { "\($0.id)|\($0.title)|\($0.sourceID)|\($0.filePath)" }
        }
        for smart in smarts {
            let answer = await PlaylistListCatalog.offlineProbeSongs(smart: smart, library: library)
            let songs = try XCTUnwrap(answer, smart.name)
            picture.offline[smart.name] = songs.map { "\($0.id)|\($0.title)|\($0.sourceID)|\($0.filePath)" }
            let ids = await PlaylistListCatalog.matchedSongIDs(smart, library: library)
            picture.smartIDs[smart.name] = try XCTUnwrap(ids, smart.name)
        }
        return picture
    }

    func testPlaylistsPageAnswersMatchTheLoadedPageWhileReleased() async throws {
        let prefix = "u9b-playlists"
        let songs = Self.fixture(prefix: prefix)
        let (library, storage) = try makeLaunchedTwin(prefix, songs: songs, extra: Self.serverSongs(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mixed = library.createPlaylist(
            name: "Mixed", songIDs: ["\(prefix)-comp-3", "\(prefix)-blueb-1", "\(prefix)-blue-2", "\(prefix)-cue-1"]
        )
        let server = library.createPlaylist(name: "Server", songIDs: (1...3).map { "\(prefix)-srv-\($0)" })
        let rule = SmartPlaylist(
            id: "\(prefix)-ada", name: "Rule",
            ruleGroups: [SmartPlaylistRuleGroup(
                rules: [SmartPlaylistRule(field: .artistName, op: .contains, value: "Ada")], combinator: .and, isExcluded: false
            )],
            groupCombinator: .and, limit: nil, sortField: .title, sortDirection: .descending
        )
        let picks = try ["blue-3", "comp-1"].map { try XCTUnwrap(byID["\(prefix)-\($0)"]) }
        let ai = SmartPlaylist(
            name: "AI", kind: .ai, aiConfiguration: AISmartPlaylistConfiguration(selections: picks.map(Self.selection))
        )
        let sources = SourcesStore(storageDirectoryURL: storage.appendingPathComponent("sources"))
        sources.add(MusicSource(id: Self.serverSource, name: "Server", type: .navidrome))

        let loaded = try await picture(library, playlists: [mixed, server], smarts: [rule])
        XCTAssertEqual(loaded.offline["Mixed"]?.count, 3, "the disabled source's song is not counted")
        XCTAssertFalse(loaded.smartIDs["Rule"]?.isEmpty ?? true)
        let loadedAIAnswer = await PlaylistListCatalog.matchedSongIDs(ai, library: library)
        let loadedAI = try XCTUnwrap(loadedAIAnswer)
        XCTAssertEqual(loadedAI, picks.map(\.id))
        let loadedTarget = try XCTUnwrap(PlaylistShareTargets().target(for: server, library: library, sourcesStore: sources))
        XCTAssertEqual(loadedTarget.itemIDs, ["item-1", "item-2", "item-3"])
        XCTAssertNil(PlaylistShareTargets().target(for: mixed, library: library, sourcesStore: sources))

        let before = try await releaseForReal(library)
        let released = try await picture(library, playlists: [mixed, server], smarts: [rule])
        XCTAssertEqual(released, loaded)
        // 分享目标:放掉之后先不给(不在菜单求值时读整张歌单),在后台建好后与模型在内存里时相同。
        let targets = PlaylistShareTargets()
        XCTAssertNil(targets.target(for: server, library: library, sourcesStore: sources), "built in the background")
        try await waitUntil("share target") { targets.target(for: server, library: library, sourcesStore: sources) != nil }
        XCTAssertEqual(targets.target(for: server, library: library, sourcesStore: sources), loadedTarget)
        _ = targets.target(for: mixed, library: library, sourcesStore: sources)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(targets.target(for: mixed, library: library, sourcesStore: sources), "a playlist of local songs has none")
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: .playlists), .catalog)
        assertNoLoadAndNoArrayRead(library, since: before, "playlists page while released")

        // AI 歌单按身份对回整库:占用模型装回来再对,结果相同(装一次)。
        let releasedAI = await PlaylistListCatalog.matchedSongIDs(ai, library: library)
        XCTAssertEqual(releasedAI, loadedAI)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
    }

    func testOfflineFilterSongsAfterALaunchThatNeverLoadedTheModel() async throws {
        let name = "u9b-playlists-launch"
        let (source, library) = try await launchWithoutTheSongModel(name)
        let kept = try XCTUnwrap(source.playlists.first { $0.name == "Kept" })
        let loaded = await PlaylistListCatalog.offlineProbeSongs(playlist: kept, library: source)
        XCTAssertEqual(loaded?.isEmpty, false)
        let before = library.songModelResidencyStatistics
        let launchedKept = try XCTUnwrap(library.playlists.first { $0.name == "Kept" })
        let released = await PlaylistListCatalog.offlineProbeSongs(playlist: launchedKept, library: library)
        XCTAssertEqual(released, loaded)
        XCTAssertFalse(library.isReady)
        assertNoLoadAndNoArrayRead(library, since: before, "offline filter after an unloaded launch")
    }
}
