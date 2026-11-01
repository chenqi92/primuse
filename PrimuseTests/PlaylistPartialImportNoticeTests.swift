import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class PlaylistPartialImportNoticeTests: XCTestCase {
    func testBothPlatformPreviewsExplainQuotaAndRemainingWait() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracks = [ExternalPlaylistTrack(title: "Fixture", artists: [])]
        let quota = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: tracks,
            partialReason: .rateLimited(statusCode: 503, retryAt: now.addingTimeInterval(86400)))
        let notice = try XCTUnwrap(PlaylistPartialImportNotice(playlist: quota, platformName: "YouTube"))
        let before = notice.message(at: now)
        let remaining = HTTPResponseFailure(statusCode: 503, retryAfter: 86400).localizedDescription
        XCTAssertTrue(before.contains(remaining), "The preview must display the actual server wait")
        XCTAssertFalse(notice.reason.canRetry(at: now))
        XCTAssertTrue(notice.reason.canRetry(at: now.addingTimeInterval(86400)))
        XCTAssertNotEqual(before, notice.message(at: now.addingTimeInterval(86400)))
        let preview = ExternalPlaylist(name: "Fixture", platform: .spotify, tracks: tracks, isPartial: true)
        let publicNotice = try XCTUnwrap(PlaylistPartialImportNotice(playlist: preview, platformName: "Spotify"))
        XCTAssertNotEqual(before, publicNotice.message(at: now), "Quota failures must not use the public-preview explanation")
        XCTAssertFalse(publicNotice.reason.canRetry(at: now))
    }
    func testCompleteImportHasNoPartialWarningAndGenericFailureIsDistinct() throws {
        let complete = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: [])
        XCTAssertNil(PlaylistPartialImportNotice(playlist: complete, platformName: "YouTube"))
        let incomplete = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: [], partialReason: .incomplete)
        let notice = try XCTUnwrap(PlaylistPartialImportNotice(playlist: incomplete, platformName: "YouTube"))
        XCTAssertFalse(notice.message().isEmpty)
        XCTAssertTrue(notice.reason.canRetry())
    }
}

@MainActor
final class PlaylistImportOrderTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: "local-\(id)", title: id.uppercased(), artistName: "Artist", duration: 180,
             fileFormat: .flac, filePath: "/\(id).flac", sourceID: "source")
    }

    private func identity(_ id: String) -> SongIdentity {
        let song = song(id)
        return SongIdentity(songID: "remote-\(id)", title: song.title, artistName: song.artistName,
                            duration: song.duration, cloudAccountID: "account", filePath: song.filePath)
    }

    func testImportKeepsInterleavedMissingSongsInFileOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.addSongs([song("a"), song("b")])
        await library.waitForPendingIndex()
        let input = "#EXTM3U\n#EXTINF:180,Artist - C\nc.flac\n#EXTINF:180,Artist - B\nb.flac\n#EXTINF:180,Artist - D\nd.flac\n#EXTINF:180,Artist - A\na.flac\n"
        let file = directory.appendingPathComponent("order.m3u8")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try input.write(to: file, atomically: true, encoding: .utf8)
        let preview = try PlaylistImporter.parseAndMatch(fileURL: file, library: library)
        XCTAssertEqual(preview.entries.map(\.displayTitle), ["C", "B", "D", "A"])
        XCTAssertEqual(preview.entries.compactMap { $0.matchedSong?.id }, ["local-b", "local-a"])

        let complete = PlaylistImporter.createPlaylist(from: preview, named: "Complete", keepingMissing: true, library: library)
        let matched = PlaylistImporter.createPlaylist(from: preview, named: "Matched", keepingMissing: false, library: library)
        func titles(_ library: MusicLibrary) -> [String] {
            library.entries(forPlaylist: complete.id).map { entry in
                switch entry {
                case .song(let song): song.title
                case .pending(let pending): pending.title
                }
            }
        }
        XCTAssertEqual(titles(library), ["C", "B", "D", "A"])
        XCTAssertEqual(library.songs(forPlaylist: matched.id).map(\.id), ["local-b", "local-a"])
        let entries = library.entries(forPlaylist: complete.id)
        library.addSongs([song("d"), song("c")], pruneMissingSongs: false)
        await library.waitForPendingIndex()
        library.resolvePendingEntry(entries[2].id, inPlaylist: complete.id, with: "local-d")
        library.resolvePendingEntry(entries[0].id, inPlaylist: complete.id, with: "local-c")
        XCTAssertEqual(titles(library), ["C", "B", "D", "A"])
        XCTAssertEqual(library.songs(forPlaylist: complete.id).map(\.id), ["local-c", "local-b", "local-d", "local-a"])
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }
    }

    func testSyncedPlaylistPreservesOrderThroughPartialScansAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.sourceIdentityResolver = { _ in "account" }
        library.addSongs([song("b")])
        await library.waitForPendingIndex()
        let playlist = Playlist(id: "imported", name: "Imported", syncRevision: 3)
        let identities = [identity("c"), identity("a"), identity("b")]
        library.applyRemotePlaylist(playlist, songIDs: identities.map(\.songID), identities: identities)
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), ["remote-c", "remote-a", "local-b"])
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), ["local-b"])
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }

        let reopened = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        reopened.sourceIdentityResolver = { _ in "account" }
        for id in ["a", "c"] {
            reopened.addSongs([song(id)], pruneMissingSongs: false)
            await reopened.waitForPendingIndex()
            reopened.flushPendingIdentitiesForTesting(exactIDOnly: false)
        }
        XCTAssertEqual(reopened.songs(forPlaylist: playlist.id).map(\.id), ["local-c", "local-a", "local-b"])
        XCTAssertTrue(reopened.pendingSongIdentities(forPlaylist: playlist.id).isEmpty)
        // 同步基线也必须换成本机 id，否则下一次冲突合并会把补齐的歌当作已删除。
        reopened.mergeRemotePlaylist(playlist, baseSongIDs: reopened.rawSongIDs(forPlaylist: playlist.id), additionalIdentities: identities)
        XCTAssertEqual(reopened.songs(forPlaylist: playlist.id).map(\.id), ["local-c", "local-a", "local-b"])
        guard case .success = await reopened.persistNowAndWait() else { return XCTFail("Persistence failed") }
    }

    func testSyncMergeKeepsSlotsWhenScanCompletesBeforePendingRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        library.sourceIdentityResolver = { _ in "account" }
        library.addSongs([song("a")])
        await library.waitForPendingIndex()
        let playlist = Playlist(id: "imported", name: "Imported", syncRevision: 3)
        let identities = [identity("c"), identity("a"), identity("b")]
        library.applyRemotePlaylist(playlist, songIDs: identities.map(\.songID), identities: identities)
        library.addSongs([song("b"), song("c")], pruneMissingSongs: false)
        await library.waitForPendingIndex()
        library.mergeRemotePlaylist(playlist, baseSongIDs: library.rawSongIDs(forPlaylist: playlist.id), additionalIdentities: identities)
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), ["local-c", "local-a", "local-b"])
        XCTAssertTrue(library.pendingSongIdentities(forPlaylist: playlist.id).isEmpty)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Persistence failed") }
    }
}
