import Foundation
import Testing
@testable import PrimuseKit

@Suite struct LibraryUserDataBackupTests {
    private func track(_ key: String, _ title: String, songID: String? = nil) -> LibraryUserDataBackup.Track {
        .init(key: key, songID: songID, title: title, artists: ["歌手"], album: "专辑", duration: 200)
    }

    private var sample: LibraryUserDataBackup {
        LibraryUserDataBackup(
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
            tracks: [track("t1", "一", songID: "a"), track("t2", "二", songID: "b"), track("t3", "三")],
            ratings: [
                .init(track: "t1", rating: 5, comment: "副歌"),
                .init(track: "t2", rating: 3),
                .init(track: "t3", rating: 4),
            ],
            liked: ["t2", "t3"],
            playlists: [.init(id: "p1", name: "通勤", tracks: ["t3", "t1", "t2"])]
        )
    }

    @Test func roundTripsThroughJSON() throws {
        let decoded = try LibraryUserDataBackup.decode(sample.encoded())
        #expect(decoded == sample)
    }

    @Test func rejectsOtherFilesAndNewerVersions() throws {
        let playlistExport = #"{"format":"primuse-playlist","version":1,"tracks":[]}"#
        #expect(throws: LibraryUserDataBackup.DecodeError.notABackup) {
            try LibraryUserDataBackup.decode(Data(playlistExport.utf8))
        }
        #expect(throws: LibraryUserDataBackup.DecodeError.notABackup) {
            try LibraryUserDataBackup.decode(Data("not json".utf8))
        }
        var future = sample
        future.version = 9
        #expect(throws: LibraryUserDataBackup.DecodeError.newerVersion(9)) {
            try LibraryUserDataBackup.decode(future.encoded())
        }
    }

    @Test func dropsDanglingReferencesAndOutOfRangeRatings() throws {
        var messy = sample
        messy.ratings.append(.init(track: "missing", rating: 5))
        messy.ratings.append(.init(track: "t2", rating: 9, comment: "  "))
        messy.liked.append("missing")
        messy.liked.append("t2")
        messy.playlists.append(.init(id: "p2", name: "  ", tracks: ["t1"]))
        messy.playlists[0].tracks.append("missing")
        let cleaned = try LibraryUserDataBackup.decode(messy.encoded())
        #expect(cleaned.ratings.count == 3)
        #expect(cleaned.liked == ["t2", "t3"])
        #expect(cleaned.playlists.count == 1)
        #expect(cleaned.playlists[0].tracks == ["t3", "t1", "t2"])
    }

    @Test func planFillsGapsKeepsLocalConflictsAndQueuesMissingSongs() {
        let local = LibraryUserDataRestorePolicy.LocalState(
            ratings: ["a": (nil, ""), "b": (2, "")],
            likedSongIDs: ["b"],
            playlists: [(id: "p9", name: "通勤 ")]
        )
        let plan = LibraryUserDataRestorePolicy.plan(sample, resolutions: ["t1": "a", "t2": "b"], local: local)

        #expect(plan.reviewWrites == [.init(songID: "a", rating: 5, comment: "副歌")])
        // 本机 2 星、备份 3 星：默认不动，列为冲突。
        #expect(plan.conflicts == [.init(songID: "b", localRating: 2, backupRating: 3)])
        #expect(plan.conflictWrites == [.init(songID: "b", rating: 3, comment: "")])
        #expect(plan.likedToAdd.isEmpty)
        #expect(plan.alreadyLikedCount == 1)
        // t3 曲库里还没有：评分和喜欢合成一条等着。
        #expect(plan.waiting.count == 1)
        #expect(plan.waiting.first?.rating == 4)
        #expect(plan.waiting.first?.liked == true)
        #expect(plan.waiting.first?.origin == .backup)
        #expect(plan.unmatchedTrackCount == 1)
        // 同名歌单（忽略空白与大小写）合并进去，没对上的留占位，顺序照备份。
        #expect(plan.playlistWrites.count == 1)
        #expect(plan.playlistWrites[0].target == .existing(id: "p9"))
        #expect(plan.playlistWrites[0].members == [.pending(track("t3", "三")), .song("a"), .song("b")])
    }

    @Test func sameIDPlaylistWinsAndMissingOnesAreCreated() {
        var backup = sample
        backup.playlists.append(.init(id: "p2", name: "通勤", tracks: ["t1"]))
        let local = LibraryUserDataRestorePolicy.LocalState(
            ratings: [:], likedSongIDs: [], playlists: [(id: "p1", name: "改过名的")]
        )
        let plan = LibraryUserDataRestorePolicy.plan(backup, resolutions: ["t1": "a"], local: local)
        #expect(plan.playlistWrites.map(\.target) == [.existing(id: "p1"), .new(name: "通勤")])
    }

    @Test func reimportingTheSameBackupChangesNothing() {
        let local = LibraryUserDataRestorePolicy.LocalState(
            ratings: ["a": (5, "副歌"), "b": (3, ""), "c": (4, "")],
            likedSongIDs: ["b", "c"],
            playlists: [(id: "p1", name: "通勤")]
        )
        let plan = LibraryUserDataRestorePolicy.plan(
            sample, resolutions: ["t1": "a", "t2": "b", "t3": "c"], local: local
        )
        #expect(plan.reviewWrites.isEmpty)
        #expect(plan.conflicts.isEmpty)
        #expect(plan.unchangedRatingCount == 3)
        #expect(plan.likedToAdd.isEmpty)
        #expect(plan.waiting.isEmpty)
        #expect(plan.playlistWrites[0].target == .existing(id: "p1"))
    }

    @Test func waitingEntriesKeepTheExportingDevicesSongID() {
        let entry = track("t1", "一", songID: "a").carriedMarks(rating: 5)
        #expect(entry.id == "a")
        #expect(track("t3", "三").carriedMarks(liked: true).id == "backup:t3")
    }
}
