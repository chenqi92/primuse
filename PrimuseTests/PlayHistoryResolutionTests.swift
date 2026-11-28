import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 别的设备上播的、本机歌曲 ID 不同的播放记录认回本机的歌(`PlayHistoryStore` 的补认):
/// 歌曲模型放掉时照样从曲库目录认、不装模型不读整库数组;认过的不再认;同步合并不丢时长;车机排行也用上。
@MainActor
final class PlayHistoryResolutionTests: LibraryReleasedTwinTestCase {
    private func makeStore(_ name: String) throws -> PlayHistoryStore {
        let store = PlayHistoryStore(
            storeURL: directory.appendingPathComponent("\(name).json"),
            defaults: try XCTUnwrap(UserDefaults(suiteName: "primuse.test.\(UUID().uuidString)")),
            localListenRule: { (ListenCountRule(percent: 50, countsAfterFourMinutes: false), false) }
        )
        store.songResolutionDebounce = .milliseconds(50)
        store.songResolutionMinimumFullInterval = .zero
        return store
    }

    private struct Fixture {
        let library: MusicLibrary
        let songs: [Song]
        let boostEntry: PlayHistoryStore.Entry
        let pathOnlyEntry: PlayHistoryStore.Entry
        let disabledEntry: PlayHistoryStore.Entry
        var entries: [PlayHistoryStore.Entry] { [boostEntry, pathOnlyEntry, disabledEntry] }
    }

    /// 本机三个同名不同版本、一首没标签的(只能按路径认)、一首在停用源 B 里的;
    /// 别的设备上的三条记录,歌曲 ID 本机都没有。
    private func makeFixture(_ name: String) async throws -> Fixture {
        let orig = Song(
            id: "ios-orig", title: "SUIATSU", albumTitle: "SUIATSU", artistName: "Stray Kids",
            duration: 190, fileFormat: .flac, filePath: "/Music/Stray Kids/01.flac", sourceID: Self.sourceA
        )
        let deep = Song(
            id: "ios-deep", title: "SUIATSU (Deep Version)", albumTitle: "SUIATSU", artistName: "Stray Kids",
            duration: 225, fileFormat: .flac, filePath: "/Music/Stray Kids/06.flac", sourceID: Self.sourceA
        )
        let boost = Song(
            id: "ios-boost", title: "SUIATSU (Boost Version)", albumTitle: "SUIATSU", artistName: "Stray Kids",
            duration: 165, fileFormat: .flac, filePath: "/Music/Stray Kids/07.flac", sourceID: Self.sourceA
        )
        let untagged = Song(
            id: "ios-untagged", title: "08", albumTitle: nil, artistName: nil,
            duration: 0, fileFormat: .flac, filePath: "/Music/Cloud/08.flac", sourceID: Self.sourceA
        )
        let disabledSong = Song(
            id: "ios-disabled", title: "Disabled Track", albumTitle: "Disabled Album", artistName: "Hidden",
            duration: 200, fileFormat: .flac, filePath: "/Share/Hidden/01.flac", sourceID: Self.sourceB
        )
        let songs = [orig, deep, boost, untagged, disabledSong]
        let (library, _) = try makeLaunchedTwin(name, songs: songs)
        await assertShadowMatches(library, name)

        let now = Date(timeIntervalSince1970: 1_795_700_000)
        return Fixture(
            library: library,
            songs: songs,
            boostEntry: PlayHistoryStore.Entry(
                songID: "mac-boost-id", songTitle: "SUIATSU (Boost Version)", artistName: "Stray Kids",
                albumTitle: "SUIATSU", playedAt: now, listenedSec: 160, sourceID: Self.sourceA,
                content: .init(kind: .music, filePath: "/MacOnly/07.flac", sourceID: Self.sourceA)
            ),
            pathOnlyEntry: PlayHistoryStore.Entry(
                songID: "mac-untagged-id", songTitle: "Cloud Song", artistName: "Some Artist",
                albumTitle: "Some Album", playedAt: now.addingTimeInterval(-60), listenedSec: 120, sourceID: Self.sourceA,
                content: .init(kind: .music, filePath: "/Music/Cloud/08.flac", sourceID: Self.sourceA)
            ),
            disabledEntry: PlayHistoryStore.Entry(
                songID: "mac-disabled-id", songTitle: "Disabled Track", artistName: "Hidden",
                albumTitle: "Disabled Album", playedAt: now.addingTimeInterval(-120), listenedSec: 150, sourceID: Self.sourceB,
                content: .init(kind: .music, filePath: "/Share/Hidden/01.flac", sourceID: Self.sourceB)
            )
        )
    }

    func testPlayHistoryContentEncodesDurationAndDecodesLegacyPayloadWithoutDuration() throws {
        let legacyJSON = Data("""
        {
          "songID": "mac-legacy",
          "songTitle": "SUIATSU (Boost Version)",
          "artistName": "Stray Kids",
          "albumTitle": "SUIATSU",
          "playedAt": 1795700000,
          "listenedSec": 165,
          "sourceID": "primuse.appleMusic.system",
          "content": {
            "kind": "music",
            "filePath": "/Music/SUIATSU/07.flac",
            "sourceID": "primuse.appleMusic.system"
          }
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(PlayHistoryStore.Entry.self, from: legacyJSON)
        XCTAssertNil(decoded.content?.duration)
        XCTAssertEqual(decoded.listeningEvent.sourceID, "primuse.appleMusic.system")
        XCTAssertEqual(decoded.listeningEvent.filePath, "/Music/SUIATSU/07.flac")

        let store = try makeStore("history-duration")
        let song = Song(
            id: "mac-boost", title: "SUIATSU (Boost Version)", albumTitle: "SUIATSU", artistName: "Stray Kids",
            duration: 165, fileFormat: .flac, filePath: "/Music/SUIATSU/07.flac", sourceID: Self.sourceA
        )
        store.record(song: song, startedAt: Date(timeIntervalSince1970: 1_795_700_100), listenedSec: 160)
        store.flush()

        let reloaded = try makeStore("history-duration")
        let entry = try XCTUnwrap(reloaded.entries.first)
        XCTAssertEqual(entry.content?.duration, 165)
        XCTAssertEqual(entry.listeningEvent.songDuration, 165)
        XCTAssertEqual(entry.listeningEvent.sourceID, Self.sourceA)
        XCTAssertEqual(entry.listeningEvent.filePath, "/Music/SUIATSU/07.flac")
    }

    /// 放掉之后内存里那张表是空的、内存那一路答不了(返回 nil):答得与装着时一样,只能是从目录答的。
    func testCrossDevicePlayHistoryResolvesFromTheCatalogWhileReleasedAndExcludesDisabledSources() async throws {
        let fixture = try await makeFixture("history-resolution")
        let library = fixture.library
        let loadedAnswer = await PlayHistoryStore.resolveMissingSongIDs(for: fixture.entries, in: library)
        let loaded = try XCTUnwrap(loadedAnswer)
        XCTAssertEqual(loaded["mac-boost-id"], ["ios-boost"])
        XCTAssertEqual(loaded["mac-untagged-id"], ["ios-untagged"])
        XCTAssertNil(loaded["mac-disabled-id"])

        let before = try await releaseForReal(library)
        let released = await PlayHistoryStore.resolveMissingSongIDs(for: fixture.entries, in: library)
        XCTAssertEqual(released, loaded, "the catalog answers the same while the song model is released")

        let store = try makeStore("history-store-resolution")
        store.mergeRemoteEntries(fixture.entries)
        store.refreshClassification(library: library)
        await store.waitForMissingSongResolution()
        XCTAssertEqual(store.songResolutionRuns, 1)
        XCTAssertEqual(store.resolvedSong(for: fixture.boostEntry, in: library)?.id, "ios-boost")
        XCTAssertEqual(store.resolvedSong(for: fixture.pathOnlyEntry, in: library)?.id, "ios-untagged")
        XCTAssertNil(store.resolvedSong(for: fixture.disabledEntry, in: library))
        XCTAssertEqual(store.expandingResolvedSongIDs(["mac-boost-id"]), ["mac-boost-id", "ios-boost"])
        assertNoLoadAndNoArrayRead(library, since: before, "play history resolution while released")
    }

    /// 发布、播完一首本机的歌都会来问:认过的不再认,一个新的也没有就不去扫;
    /// 同步进来新记录只认新的那几条;曲库进了歌才整份重认。
    func testResolutionRunsOnlyForNewHistoryIDsUntilTheLibraryMembershipChanges() async throws {
        let fixture = try await makeFixture("history-resolution-memo")
        let library = fixture.library
        let store = try makeStore("history-resolution-memo")
        store.mergeRemoteEntries([fixture.boostEntry, fixture.disabledEntry])
        store.refreshClassification(library: library)
        await store.waitForMissingSongResolution()
        XCTAssertEqual(store.songResolutionRuns, 1)
        XCTAssertEqual(store.resolvedSong(for: fixture.boostEntry, in: library)?.id, "ios-boost")

        // 再发布一次、再播一首已经在记录里的本机歌:不重认。
        let local = fixture.songs[0]
        store.record(song: local, startedAt: Date(timeIntervalSince1970: 1_795_700_500), listenedSec: 150)
        await store.waitForMissingSongResolution()
        XCTAssertEqual(store.songResolutionRuns, 2, "a new history ID is checked once")
        store.record(song: local, startedAt: Date(timeIntervalSince1970: 1_795_700_900), listenedSec: 150)
        store.refreshClassification(library: library)
        store.refreshClassification(library: library)
        await store.waitForMissingSongResolution()
        XCTAssertEqual(store.songResolutionRuns, 2, "nothing new to resolve: no scan")

        // 同步进来一条新的:只认它,先前认出来的留着。
        store.mergeRemoteEntries([fixture.pathOnlyEntry])
        await store.waitForMissingSongResolution()
        XCTAssertEqual(store.songResolutionRuns, 3)
        XCTAssertEqual(store.resolvedSong(for: fixture.pathOnlyEntry, in: library)?.id, "ios-untagged")
        XCTAssertEqual(store.resolvedSong(for: fixture.boostEntry, in: library)?.id, "ios-boost")

        // 曲库进了一首歌(成员修订号变了):整份重认,新进的这首也认得出来。
        let arrived = Song(
            id: "ios-arrived", title: "Disabled Track", albumTitle: "Disabled Album", artistName: "Hidden",
            duration: 200, fileFormat: .flac, filePath: "/Music/Hidden/01.flac", sourceID: Self.sourceA
        )
        let membership = library.catalogHost?.revisions.membership
        library.addSongs([arrived], affectedSourceIDs: [Self.sourceA], pruneMissingSongs: false)
        await library.waitForCatalogMirror()
        for _ in 0..<150 where library.catalogHost?.revisions.membership == membership {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(library.catalogHost?.revisions.membership, membership)
        store.refreshClassification(library: library)
        await store.waitForMissingSongResolution()
        XCTAssertEqual(store.songResolutionRuns, 4)
        XCTAssertEqual(store.resolvedSong(for: fixture.disabledEntry, in: library)?.id, "ios-arrived")
        XCTAssertEqual(store.resolvedSong(for: fixture.boostEntry, in: library)?.id, "ios-boost")
    }

    /// 一个常见歌名命中的行比物化上限还多:那一组整组不收(这一轮答不了,结果里没有它),别的记录照常认出来。
    func testATitleMatchingMoreRowsThanTheMaterializationCapIsSkippedWithoutBlockingOthers() async throws {
        let cap = LibraryScale.maxMaterializedRows
        var songs = (0...cap).map { index in
            Song(
                id: "intro-\(index)", title: "Intro", albumTitle: "Album \(index)", artistName: "Artist \(index)",
                duration: 60, fileFormat: .mp3, filePath: "/Music/Intro/\(index).mp3", sourceID: Self.sourceA
            )
        }
        songs.append(Song(
            id: "ios-unique", title: "Unique Song", albumTitle: "Unique", artistName: "Solo",
            duration: 200, fileFormat: .flac, filePath: "/Music/unique.flac", sourceID: Self.sourceA
        ))
        let (library, _) = try makeLaunchedTwin("history-cap", songs: songs)
        await library.waitForCatalogMirror()
        XCTAssertNotNil(P2cCatalogAccess.reader(for: library))
        let playedAt = Date(timeIntervalSince1970: 1_795_700_000)
        let entries = [
            PlayHistoryStore.Entry(
                songID: "mac-intro", songTitle: "Intro", artistName: "Artist 7", albumTitle: "Album 7",
                playedAt: playedAt, listenedSec: 60, sourceID: "mac-only-source"
            ),
            PlayHistoryStore.Entry(
                songID: "mac-unique", songTitle: "Unique Song", artistName: "Solo", albumTitle: "Unique",
                playedAt: playedAt.addingTimeInterval(-300), listenedSec: 180, sourceID: "mac-only-source"
            ),
        ]
        let answer = await PlayHistoryStore.resolveMissingSongIDs(for: entries, in: library)
        let resolved = try XCTUnwrap(answer)
        XCTAssertEqual(resolved["mac-unique"], ["ios-unique"])
        XCTAssertNil(resolved["mac-intro"], "\(cap + 1) rows titled Intro do not fit under the cap")
    }

    /// 旧版本的设备同步来的那份记录不带时长:本机记过的时长留着。
    func testMergingARemoteCopyWithoutDurationKeepsTheLocalDuration() throws {
        let store = try makeStore("history-merge-duration")
        let song = Song(
            id: "local-song", title: "Track", artistName: "Artist", duration: 200,
            fileFormat: .flac, filePath: "/Music/track.flac", sourceID: Self.sourceA
        )
        store.record(song: song, startedAt: Date(timeIntervalSince1970: 1_795_700_000), listenedSec: 150)
        var remote = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(remote.content?.duration, 200)
        remote.content?.duration = nil
        store.mergeRemoteEntries([remote])
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.content?.duration, 200)
    }

    /// 车机的排行榜用补认出来的本机副本:别的设备上播的歌也能点开播。
    func testCarPlayRankingPlaysTheLocalCopyOfAnotherDevicesPlay() {
        let local = Song(
            id: "ios-boost", title: "SUIATSU (Boost Version)", albumTitle: "SUIATSU", artistName: "Stray Kids",
            duration: 165, fileFormat: .flac, filePath: "/Music/Stray Kids/07.flac", sourceID: Self.sourceA
        )
        let play = HomeListeningEvent(
            songID: "mac-boost-id", playedAt: Date(timeIntervalSince1970: 1_795_700_000), listenedSeconds: 160,
            songTitle: "SUIATSU (Boost Version)", artistName: "Stray Kids", albumTitle: "SUIATSU"
        )
        var input = CarPlayEditorCatalog.Input(
            songs: [local], albums: [], playlists: [], memberships: [:], stations: [],
            artistNames: .defaultValue, history: [play]
        )
        XCTAssertTrue(CarPlayEditorCatalog.project(input).ranking.isEmpty)
        input.historyCandidates = ["mac-boost-id": ["ios-boost"]]
        XCTAssertEqual(CarPlayEditorCatalog.project(input).ranking.map(\.id), ["ios-boost"])
    }
}
