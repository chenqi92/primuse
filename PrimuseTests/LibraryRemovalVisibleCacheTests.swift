import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 删除路径的可见缓存摘除回归。
///
/// `requestLibraryIndexMaintenance(.immediate)` 触发的重建是去抖之后的异步任务,
/// 所以删除之后的同一个主线程轮次里, 所有以 ID 为键的可见查找表都必须已经
/// 不含被删的行 —— 否则 `song(id:)` / `visibleSongCount(forSourceID:)` 会答出
/// 已经删掉的歌, 而紧随其后的歌单 / 最近播放清理也会因为解析得到非 nil 而把
/// 条目留下来。
///
/// 可见缓存只有在装载发布之后才是填好的 (`addSongs` 把重建交给异步维护),
/// 所以每个用例都先播种落盘, 再走 `prepareStartup` + `publish` 得到一个可见
/// 缓存完整的库。
@MainActor
final class LibraryRemovalVisibleCacheTests: XCTestCase {
    private static let sourceID = "source-a"

    private static func makeStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLibraryRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeSong(id: String, sourceID: String = sourceID) -> Song {
        Song(
            id: id,
            title: "Title \(id)",
            albumTitle: "Album \(sourceID)",
            artistName: "Artist \(sourceID)",
            duration: 180,
            fileFormat: .flac,
            filePath: "/Music/\(sourceID)/\(id).flac",
            sourceID: sourceID
        )
    }

    /// 播种一个三首歌 + 一个歌单 + 一条播放记录的库并落盘, 返回歌单 ID。
    private static func seed(
        _ directory: URL,
        songs: [Song],
        playedSongID: String
    ) async throws -> String {
        let library = MusicLibrary(storageDirectory: directory)
        // 一个源一次性交上去: `addSongs` 会把受影响源里这一批没带上的行当成
        // 远端已删除而剪掉。
        for (sourceID, sourceSongs) in Dictionary(grouping: songs, by: \.sourceID) {
            library.addSongs(sourceSongs, affectedSourceIDs: [sourceID])
        }
        let playlist = library.createPlaylist(name: "Mixed", songIDs: songs.map(\.id))
        library.recordPlayback(of: playedSongID)
        guard case .success = await library.persistNowAndWait() else {
            throw XCTSkip("The isolated library did not finish persistence")
        }
        return playlist.id
    }

    /// 可见缓存已经填好的库: 离线准备 + 主线程发布。
    private static func publishedLibrary(at directory: URL) async -> MusicLibrary {
        let preparation = await MusicLibrary.prepareStartup(storageDirectory: directory)
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        library.publish(preparation)
        return library
    }

    // MARK: - deleteSongs

    func testDeleteSongsPrunesVisibleLookupsAndMembershipInTheSameTurn() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Self.makeSong(id: "s1")
        let second = Self.makeSong(id: "s2")
        let third = Self.makeSong(id: "s3")
        let playlistID = try await Self.seed(
            directory,
            songs: [first, second, third],
            playedSongID: second.id
        )

        let library = await Self.publishedLibrary(at: directory)
        XCTAssertEqual(library.readiness, .ready)
        XCTAssertEqual(library.songCount, 3)
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 3)
        XCTAssertNotNil(library.visibleSong(id: second.id))
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlistID), [first.id, second.id, third.id])
        XCTAssertTrue(library.recentPlaybackSongIDsForSync.contains(second.id))

        let remaining = library.deleteSongs([second])

        // 以下断言全部在删除的同一个主线程轮次里, 不等去抖重建。
        XCTAssertEqual(remaining[Self.sourceID], 2)
        XCTAssertNil(library.song(id: second.id))
        XCTAssertNil(library.visibleSong(id: second.id))
        XCTAssertNil(library.unobservedVisibleSong(id: second.id))
        XCTAssertFalse(library.containsVisibleSong(id: second.id))
        XCTAssertEqual(library.songCount, 2)
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 2)
        XCTAssertEqual(library.songCountsBySourceID()[Self.sourceID], 2)
        XCTAssertEqual(
            Set(library.playableSongs(forSourceID: Self.sourceID).map(\.id)),
            [first.id, third.id]
        )
        XCTAssertEqual(
            Set(library.visibleSongs(forSourceID: Self.sourceID).map(\.id)),
            [first.id, third.id]
        )
        // 保留下来的行仍然要能按新下标解析。
        XCTAssertEqual(library.visibleSong(id: third.id)?.id, third.id)
        // 歌单与最近播放的清理跑在摘除之后, 因此看得到已删除的成员。
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlistID), [first.id, third.id])
        XCTAssertFalse(library.recentPlaybackSongIDsForSync.contains(second.id))
    }

    func testDeleteSongPrunesVisibleLookupsAndMembershipInTheSameTurn() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Self.makeSong(id: "s1")
        let second = Self.makeSong(id: "s2")
        let playlistID = try await Self.seed(
            directory,
            songs: [first, second],
            playedSongID: second.id
        )

        let library = await Self.publishedLibrary(at: directory)
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 2)

        let remaining = library.deleteSong(second)

        XCTAssertEqual(remaining, 1)
        XCTAssertNil(library.song(id: second.id))
        XCTAssertFalse(library.containsVisibleSong(id: second.id))
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 1)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlistID), [first.id])
        XCTAssertFalse(library.recentPlaybackSongIDsForSync.contains(second.id))
    }

    // MARK: - removeSongsForSources

    func testRemovingASourcePrunesItsVisibleEntriesInTheSameTurn() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let kept = Self.makeSong(id: "b1", sourceID: "source-b")
        let removedFirst = Self.makeSong(id: "s1")
        let removedSecond = Self.makeSong(id: "s2")
        let playlistID = try await Self.seed(
            directory,
            songs: [removedFirst, removedSecond, kept],
            playedSongID: removedFirst.id
        )

        let library = await Self.publishedLibrary(at: directory)
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 2)
        XCTAssertEqual(library.visibleSongCount(forSourceID: "source-b"), 1)

        let removedIDs = await library.removeSongsForSources([Self.sourceID])

        XCTAssertEqual(removedIDs, [removedFirst.id, removedSecond.id])
        XCTAssertNil(library.song(id: removedFirst.id))
        XCTAssertNil(library.song(id: removedSecond.id))
        XCTAssertEqual(library.songCount, 1)
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 0)
        XCTAssertTrue(library.playableSongs(forSourceID: Self.sourceID).isEmpty)
        XCTAssertTrue(library.visibleSongs(forSourceID: Self.sourceID).isEmpty)
        // 另一个源不受影响。
        XCTAssertEqual(library.visibleSongCount(forSourceID: "source-b"), 1)
        XCTAssertNotNil(library.visibleSong(id: kept.id))
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlistID), [kept.id])
        XCTAssertFalse(library.recentPlaybackSongIDsForSync.contains(removedFirst.id))
    }

    // MARK: - removeSongsFromThisDevice

    func testDeviceLocalRemovalPrunesVisibleLookupsButKeepsSyncMembership() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Self.makeSong(id: "s1")
        let second = Self.makeSong(id: "s2")
        let playlistID = try await Self.seed(
            directory,
            songs: [first, second],
            playedSongID: second.id
        )

        let library = await Self.publishedLibrary(at: directory)
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 2)

        let remaining = try library.removeSongsFromThisDevice([second])

        XCTAssertEqual(remaining[Self.sourceID], 1)
        XCTAssertNil(library.song(id: second.id))
        XCTAssertNil(library.visibleSong(id: second.id))
        XCTAssertFalse(library.containsVisibleSong(id: second.id))
        XCTAssertEqual(library.songCount, 1)
        XCTAssertEqual(library.visibleSongCount(forSourceID: Self.sourceID), 1)
        XCTAssertEqual(Set(library.playableSongs(forSourceID: Self.sourceID).map(\.id)), [first.id])
        // 仅本机隐藏: 目录记录仍然保留, 歌单成员不随之删除。
        XCTAssertNotNil(library.songForSynchronization(id: second.id))
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlistID), [first.id, second.id])
    }
}
