import Foundation
import Testing
@testable import PrimuseKit

@Suite struct CarriedSongMarksPolicyTests {
    private func entry(
        id: String = "old",
        title: String = "晴天",
        artists: [String] = ["周杰伦"],
        album: String? = "叶惠美",
        duration: Double? = 269,
        fileSize: Int64? = nil,
        fileName: String? = nil,
        rating: Int? = 5,
        liked: Bool = false
    ) -> CarriedSongMarks {
        CarriedSongMarks(
            id: id, title: title, artists: artists, album: album, duration: duration,
            fileSize: fileSize, fileName: fileName, rating: rating, liked: liked,
            origin: .removedSource, createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func candidate(
        title: String = "晴天",
        artists: [String] = ["周杰伦"],
        album: String? = "叶惠美",
        duration: Double? = 269,
        fileSize: Int64? = nil,
        fileName: String? = nil
    ) -> CarriedSongMarksPolicy.Candidate {
        .init(title: title, artists: artists, album: album, duration: duration, fileSize: fileSize, fileName: fileName)
    }

    @Test func sameSongAfterRenameIsClaimed() {
        // 重新刮削后繁简、括号附注变了，时长差在 3 秒内：仍是同一首。
        let index = CarriedSongMarksPolicy.select(
            for: entry(),
            among: [candidate(title: "晴天 (Remastered)", artists: ["周杰倫"], album: "葉惠美", duration: 270)]
        )
        #expect(index == 0)
    }

    @Test func otherVersionsAreNeverClaimed() {
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: [candidate(title: "晴天 (Live)")]) == nil)
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: [candidate(title: "晴天 (伴奏)")]) == nil)
        // 时长差超过 3 秒：只够「可能是」，不自动认领。
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: [candidate(duration: 276)]) == nil)
        // 歌手对不上。
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: [candidate(artists: ["别人"])]) == nil)
    }

    @Test func albumMustAgreeWhenBothSidesHaveOne() {
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: [candidate(album: "最伟大的作品精选")]) == nil)
        // 有一边不知道专辑时不拿专辑否决。
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: [candidate(album: nil)]) == 0)
        #expect(CarriedSongMarksPolicy.select(for: entry(album: nil), among: [candidate(album: "叶惠美")]) == 0)
    }

    @Test func missingDurationOrArtistIsNotEnough() {
        #expect(CarriedSongMarksPolicy.select(for: entry(duration: nil), among: [candidate()]) == nil)
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: [candidate(duration: nil)]) == nil)
        #expect(CarriedSongMarksPolicy.select(for: entry(artists: []), among: [candidate()]) == nil)
    }

    @Test func severalCopiesAreSeparatedBySizeThenNameOrLeftWaiting() {
        let copies = [
            candidate(fileSize: 30_000_000, fileName: "01 晴天.flac"),
            candidate(fileSize: 9_000_000, fileName: "01 晴天.mp3"),
        ]
        #expect(CarriedSongMarksPolicy.select(for: entry(fileSize: 9_000_000), among: copies) == 1)
        #expect(CarriedSongMarksPolicy.select(for: entry(fileSize: 1, fileName: "01 晴天.flac"), among: copies) == 0)
        // 分不出是哪一份就不认，条目继续等。
        #expect(CarriedSongMarksPolicy.select(for: entry(), among: copies) == nil)
    }

    @Test func mergingKeepsBothRemovalsMarksAndCapsOldestFirst() {
        let first = entry(rating: 4, liked: true)
        var second = entry(rating: nil, liked: false)
        second.createdAt = Date(timeIntervalSince1970: 2_000)
        let merged = CarriedSongMarksPolicy.merging(["old": first], adding: [second])
        #expect(merged["old"]?.rating == 4)
        #expect(merged["old"]?.liked == true)
        #expect(merged["old"]?.createdAt == Date(timeIntervalSince1970: 1_000))

        // 没有任何标记的条目不收。
        #expect(CarriedSongMarksPolicy.merging([:], adding: [entry(rating: nil, liked: false)]).isEmpty)

        let many = (0..<5).map { index -> CarriedSongMarks in
            var item = entry(id: "s\(index)")
            item.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            return item
        }
        let capped = CarriedSongMarksPolicy.merging([:], adding: many, limit: 3)
        #expect(Set(capped.keys) == ["s2", "s3", "s4"])
    }

    @Test func restoringNeverOverridesTheTargetsOwnMarks() {
        let marks = CarriedSongMarks(
            id: "old", title: "晴天", artists: ["周杰伦"], rating: 5, comment: "副歌那段",
            origin: .removedSource
        )
        let fresh = CarriedSongMarksPolicy.restoredReview(entry: marks, existingRating: nil, existingComment: nil)
        #expect(fresh?.rating == 5)
        #expect(fresh?.comment == "副歌那段")
        // 目标歌自己打了 3 星：评分不动，只补空着的评论。
        let partial = CarriedSongMarksPolicy.restoredReview(entry: marks, existingRating: 3, existingComment: "")
        #expect(partial?.rating == 3)
        #expect(partial?.comment == "副歌那段")
        // 两项都有了：什么也不改。
        #expect(CarriedSongMarksPolicy.restoredReview(entry: marks, existingRating: 3, existingComment: "好听") == nil)
    }

    @Test func fileNameIsTheLastPathComponentLowercased() {
        #expect(CarriedSongMarks.fileName(fromPath: "/Music/Jay/01 晴天.FLAC") == "01 晴天.flac")
        #expect(CarriedSongMarks.fileName(fromPath: "") == nil)
    }

    @Test func pendingEntryDecodesWithoutFormerSongID() throws {
        let legacy = #"{"id":"pending:a","title":"晴天","artists":["周杰伦"],"createdAt":0}"#
        let decoder = JSONDecoder()
        let entry = try decoder.decode(PlaylistPendingEntry.self, from: Data(legacy.utf8))
        #expect(entry.formerSongID == nil)
        var current = entry
        current.formerSongID = "song-1"
        let roundTrip = try decoder.decode(PlaylistPendingEntry.self, from: JSONEncoder().encode(current))
        #expect(roundTrip.formerSongID == "song-1")
    }
}
