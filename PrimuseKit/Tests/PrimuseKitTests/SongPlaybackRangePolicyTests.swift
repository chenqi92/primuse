import Foundation
import Testing
@testable import PrimuseKit

@Suite struct SongPlaybackRangePolicyTests {
    @Test func appliesOnlyAnEnabledRangeThatFitsTheSong() {
        let range = SongPlaybackRange(start: 30, end: 165, isEnabled: true)
        let applied = SongPlaybackRangePolicy.applied(range, songDuration: 240)
        #expect(applied == AppliedSongPlaybackRange(start: 30, end: 165, songDuration: 240))

        var off = range
        off.isEnabled = false
        #expect(SongPlaybackRangePolicy.applied(off, songDuration: 240) == nil)
        #expect(SongPlaybackRangePolicy.applied(nil, songDuration: 240) == nil)
        // Unknown length: nothing to measure the range against.
        #expect(SongPlaybackRangePolicy.applied(range, songDuration: 0) == nil)
        #expect(SongPlaybackRangePolicy.applied(range, songDuration: .nan) == nil)
    }

    @Test func clampsARangeLongerThanTheSong() {
        // The file turned out shorter than when the range was set.
        let range = SongPlaybackRange(start: 20, end: 300, isEnabled: true)
        let applied = SongPlaybackRangePolicy.applied(range, songDuration: 200)
        #expect(applied?.start == 20)
        #expect(applied?.end == 200)
    }

    @Test func wholeSongOrTooShortPlaysWhole() {
        let whole = SongPlaybackRange(start: 0, end: 240, isEnabled: true)
        #expect(SongPlaybackRangePolicy.applied(whole, songDuration: 240) == nil)
        let sliver = SongPlaybackRange(start: 100, end: 101, isEnabled: true)
        #expect(SongPlaybackRangePolicy.applied(sliver, songDuration: 240) == nil)
        let pastTheEnd = SongPlaybackRange(start: 250, end: 300, isEnabled: true)
        #expect(SongPlaybackRangePolicy.applied(pastTheEnd, songDuration: 240) == nil)
        // Trimming only the end, or only the start, is a range.
        #expect(SongPlaybackRangePolicy.applied(
            SongPlaybackRange(start: 0, end: 200, isEnabled: true), songDuration: 240
        ) != nil)
        #expect(SongPlaybackRangePolicy.applied(
            SongPlaybackRange(start: 12, end: 240, isEnabled: true), songDuration: 240
        ) != nil)
    }

    @Test func movingAnEdgeKeepsTheOtherAndTheMinimumLength() {
        let range = SongPlaybackRange(start: 30, end: 60, isEnabled: true)
        let later = SongPlaybackRangePolicy.moving(.start, of: range, to: 59, songDuration: 240)
        #expect(later.start == 60 - SongPlaybackRangePolicy.minimumLength)
        #expect(later.end == 60)
        let earlier = SongPlaybackRangePolicy.moving(.end, of: range, to: 10, songDuration: 240)
        #expect(earlier.start == 30)
        #expect(earlier.end == 30 + SongPlaybackRangePolicy.minimumLength)
        #expect(SongPlaybackRangePolicy.moving(.start, of: range, to: -5, songDuration: 240).start == 0)
        #expect(SongPlaybackRangePolicy.moving(.end, of: range, to: 999, songDuration: 240).end == 240)
        // Moving keeps whether the range is on.
        #expect(SongPlaybackRangePolicy.moving(.end, of: range, to: 90, songDuration: 240).isEnabled)
    }

    @Test func seeksAndRestartsStayInsideTheRange() {
        let applied = AppliedSongPlaybackRange(start: 30, end: 165, songDuration: 240)
        #expect(SongPlaybackRangePolicy.clampedSeekTarget(0, in: applied) == 30)
        #expect(SongPlaybackRangePolicy.clampedSeekTarget(100, in: applied) == 100)
        #expect(SongPlaybackRangePolicy.clampedSeekTarget(200, in: applied) == 165)
        #expect(SongPlaybackRangePolicy.clampedSeekTarget(.nan, in: applied) == 30)

        #expect(SongPlaybackRangePolicy.startPosition(requested: 0, in: applied) == 30)
        #expect(SongPlaybackRangePolicy.startPosition(requested: 80, in: applied) == 80)
        // A resume point at the very end would end the song at once.
        #expect(SongPlaybackRangePolicy.startPosition(requested: 164.5, in: applied) == 30)
        #expect(SongPlaybackRangePolicy.startPosition(requested: 200, in: applied) == 30)
    }

    @Test func labels() {
        #expect(SongPlaybackRangePolicy.timeLabel(0) == "0:00")
        #expect(SongPlaybackRangePolicy.timeLabel(65.9) == "1:05")
        #expect(SongPlaybackRangePolicy.timeLabel(3723) == "1:02:03")
        #expect(SongPlaybackRangePolicy.timeLabel(65.4, showsTenths: true) == "1:05.4")
        #expect(SongPlaybackRangePolicy.timeLabel(65.0, showsTenths: true) == "1:05")
        #expect(SongPlaybackRangePolicy.timeLabel(59.96, showsTenths: true) == "1:00")
        #expect(SongPlaybackRangePolicy.rangeLabel(SongPlaybackRange(start: 30, end: 165, isEnabled: true)) == "0:30 – 2:45")
    }
}

@Suite struct SongPlaybackRangeSyncPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ range: SongPlaybackRange?,
        at offset: TimeInterval,
        title: String = "Song",
        artist: String = "Artist",
        duration: TimeInterval = 240
    ) -> SongPlaybackRangeRecord {
        SongPlaybackRangeRecord(
            range: range,
            updatedAt: base.addingTimeInterval(offset),
            title: title,
            artist: artist,
            songDuration: duration
        )
    }

    @Test func newerWriteWinsAndClearingsPropagate() {
        let first = SongPlaybackRange(start: 10, end: 100, isEnabled: true)
        let edited = SongPlaybackRange(start: 20, end: 100, isEnabled: true)
        let local = SongPlaybackRangeSyncState(records: ["a": record(first, at: 0), "b": record(first, at: 0)])
        let remote = SongPlaybackRangeSyncState(records: ["a": record(edited, at: 5), "b": record(nil, at: 5)])
        let merged = SongPlaybackRangeSyncPolicy.merge(local, remote)
        #expect(merged.records["a"]?.range == edited)
        #expect(merged.records["b"] != nil)
        #expect(merged.records["b"]?.range == nil)
        // Merging is symmetric.
        #expect(SongPlaybackRangeSyncPolicy.merge(remote, local) == merged)
    }

    @Test func aTieIsDecidedTheSameWayOnEveryDevice() {
        let one = SongPlaybackRange(start: 10, end: 100, isEnabled: true)
        let two = SongPlaybackRange(start: 15, end: 100, isEnabled: true)
        let lhs = SongPlaybackRangeSyncState(records: ["a": record(one, at: 0)])
        let rhs = SongPlaybackRangeSyncState(records: ["a": record(two, at: 0)])
        #expect(SongPlaybackRangeSyncPolicy.merge(lhs, rhs) == SongPlaybackRangeSyncPolicy.merge(rhs, lhs))
        let cleared = SongPlaybackRangeSyncState(records: ["a": record(nil, at: 0)])
        #expect(SongPlaybackRangeSyncPolicy.merge(cleared, lhs).records["a"]?.range == one)
    }

    @Test func oldClearingsAreForgotten() {
        let state = SongPlaybackRangeSyncState(records: [
            "kept": record(SongPlaybackRange(start: 1, end: 50, isEnabled: false), at: 0),
            "recent": record(nil, at: 0),
        ])
        let later = base.addingTimeInterval(SongPlaybackRangeSyncPolicy.tombstoneLifetime + 1)
        let retained = SongPlaybackRangeSyncPolicy.retained(state, now: later)
        #expect(retained.records.keys.sorted() == ["kept"])
        #expect(SongPlaybackRangeSyncPolicy.retained(state, now: base).records.count == 2)
    }

    @Test func uploadDropsClearingsBeforeRanges() {
        var records: [String: SongPlaybackRangeRecord] = [:]
        for index in 0..<40 {
            records["range-\(index)"] = record(
                SongPlaybackRange(start: 1, end: 50, isEnabled: true),
                at: TimeInterval(index),
                title: String(repeating: "t", count: 40)
            )
            records["cleared-\(index)"] = record(nil, at: TimeInterval(100 + index))
        }
        let state = SongPlaybackRangeSyncState(records: records)
        let full = SongPlaybackRangeSyncPolicy.encode(state)!.count
        let upload = SongPlaybackRangeSyncPolicy.uploadState(state, byteBudget: full * 3 / 4)
        #expect(SongPlaybackRangeSyncPolicy.encode(upload)!.count <= full * 3 / 4)
        #expect(upload.records.keys.filter { $0.hasPrefix("range-") }.count == 40)
        #expect(SongPlaybackRangeSyncPolicy.uploadState(state, byteBudget: full) == state)
    }

    @Test func roundTripsThroughTheStoredForm() {
        let state = SongPlaybackRangeSyncState(records: [
            "a": record(SongPlaybackRange(start: 12.5, end: 80, isEnabled: false), at: 3),
            "b": record(nil, at: 4),
        ])
        let data = SongPlaybackRangeSyncPolicy.encode(state)
        #expect(SongPlaybackRangeSyncPolicy.decode(data) == state)
        #expect(SongPlaybackRangeSyncPolicy.decode(Data()) == nil)
        #expect(SongPlaybackRangeSyncPolicy.decode(Data("junk".utf8)) == nil)
    }

    @Test func findsTheSameSongUnderAnotherDevicesID() {
        let mine = record(SongPlaybackRange(start: 10, end: 100, isEnabled: true), at: 0)
        let theirs = record(SongPlaybackRange(start: 30, end: 100, isEnabled: true), at: 10, duration: 241)
        let elsewhere = record(SongPlaybackRange(start: 50, end: 100, isEnabled: true), at: 20, duration: 180)
        let records = ["mine": mine, "theirs": theirs, "elsewhere": elsewhere]
        // The other device's newer edit wins over this device's older record.
        #expect(SongPlaybackRangeSyncPolicy.resolvedRecord(
            songID: "mine", songDuration: 240, records: records, twinIDs: ["theirs", "elsewhere"]
        ) == theirs)
        // Without a record of its own the twin's range applies.
        #expect(SongPlaybackRangeSyncPolicy.resolvedRecord(
            songID: "new", songDuration: 240, records: records, twinIDs: ["theirs"]
        ) == theirs)
        // A same-titled song of another length is a different recording.
        #expect(SongPlaybackRangeSyncPolicy.resolvedRecord(
            songID: "new", songDuration: 240, records: records, twinIDs: ["elsewhere"]
        ) == nil)
        // A newer clearing on this device beats an older twin range.
        let cleared = record(nil, at: 30)
        #expect(SongPlaybackRangeSyncPolicy.resolvedRecord(
            songID: "mine", songDuration: 240, records: ["mine": cleared, "theirs": theirs], twinIDs: ["theirs"]
        )?.range == nil)
    }

    @Test func matchKeyIgnoresCaseWidthAndSpacing() {
        #expect(SongPlaybackRangeSyncPolicy.matchKey(title: "Hello  World", artist: "ＡＢＣ")
            == SongPlaybackRangeSyncPolicy.matchKey(title: "hello world", artist: "abc"))
        #expect(SongPlaybackRangeSyncPolicy.matchKey(title: "Song", artist: nil)
            != SongPlaybackRangeSyncPolicy.matchKey(title: "Song", artist: "Someone"))
    }
}

@Suite struct SongAppliedPlaybackRangeTests {
    private func song(duration: TimeInterval = 240, cueStart: TimeInterval? = nil, cueEnd: TimeInterval? = nil) -> Song {
        Song(
            id: "song-1",
            title: "Song",
            duration: duration,
            fileFormat: .flac,
            filePath: "/music/song.flac",
            sourceID: "source",
            cueStartTime: cueStart,
            cueEndTime: cueEnd
        )
    }

    @Test func playingCopyEndsAtTheRangeAndRestoresTheWholeSong() {
        let whole = song()
        let applied = AppliedSongPlaybackRange(start: 30, end: 165, songDuration: 240)
        let copy = whole.playing(applied)
        #expect(copy.duration == 165)
        #expect(copy.appliedPlaybackRange == applied)
        #expect(copy.playbackMediaWindow.start == 30)
        #expect(copy.playbackMediaWindow.end == 165)
        #expect(copy.withoutAppliedPlaybackRange == whole)
        #expect(copy.playing(nil) == whole)
        // Re-applying starts from the whole song, not from the copy.
        let narrower = AppliedSongPlaybackRange(start: 40, end: 100, songDuration: 240)
        #expect(copy.playing(narrower) == whole.playing(narrower))
        #expect(whole.playbackMediaWindow.start == nil)
        #expect(whole.playbackMediaWindow.end == nil)
    }

    @Test func cueTrackRangeIsOffsetIntoTheImage() {
        let track = song(duration: 200, cueStart: 600, cueEnd: 800)
        let copy = track.playing(AppliedSongPlaybackRange(start: 20, end: 190, songDuration: 200))
        #expect(copy.cueStartTime == 600)
        #expect(copy.cueEndTime == 800)
        #expect(copy.playbackMediaWindow.start == 620)
        #expect(copy.playbackMediaWindow.end == 790)
    }

    @Test func encodedCopyIsTheWholeSong() throws {
        let whole = song()
        let copy = whole.playing(AppliedSongPlaybackRange(start: 30, end: 165, songDuration: 240))
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(copy))
        #expect(decoded == whole)
        #expect(decoded.appliedPlaybackRange == nil)
        #expect(decoded.duration == 240)
    }
}
