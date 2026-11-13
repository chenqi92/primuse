import Foundation
import Testing
@testable import PrimuseKit

@Suite("Tag write-back scheduling")
struct TagWritebackSchedulingTests {
    @Test func firstRefusalSkipsTheFoldersUnstartedSongs() {
        let a = "src\u{1F}Music"
        var scheduler = TagWritebackRefusalScheduler(keys: [a, a, a, a, a])
        // Writes start side by side; nobody waits for the first answer.
        #expect(scheduler.next() == .write(0))
        #expect(scheduler.next() == .write(1))
        #expect(scheduler.next() == .write(2))
        scheduler.finished(1, .refused)
        #expect(scheduler.next() == .skip(3))
        // A write already in flight still reports, and changes nothing.
        scheduler.finished(0, .written)
        #expect(scheduler.next() == .skip(4))
        #expect(scheduler.next() == nil)
        #expect(!scheduler.hasUnstarted)
    }

    @Test func aWrittenFileKeepsItsFolderGoingPastALaterRefusal() {
        let a = "src\u{1F}Music"
        var scheduler = TagWritebackRefusalScheduler(keys: [a, a, a])
        #expect(scheduler.next() == .write(0))
        scheduler.finished(0, .written)
        #expect(scheduler.next() == .write(1))
        // One read-only file in a writable folder does not stop the others.
        scheduler.finished(1, .refused)
        #expect(scheduler.next() == .write(2))
    }

    @Test func timeoutsDecideNothingAndFoldersAreSeparate() {
        let a = "src\u{1F}A"
        let b = "src\u{1F}B"
        var scheduler = TagWritebackRefusalScheduler(keys: [a, b, nil, a, b, nil])
        #expect(scheduler.next() == .write(0))
        #expect(scheduler.next() == .write(1))
        #expect(scheduler.next() == .write(2))
        scheduler.finished(0, .other)
        scheduler.finished(1, .refused)
        scheduler.finished(2, .refused)
        #expect(scheduler.next() == .write(3))
        #expect(scheduler.next() == .skip(4))
        // Songs without a folder key are never skipped.
        #expect(scheduler.next() == .write(5))
        #expect(scheduler.next() == nil)
    }

    @Test func probeKeyIsSourceAndTopLevelFolder() {
        let first = TagWritebackFolderKey.key(sourceID: "s1", filePath: "/music/Artist/Album/01.flac")
        let second = TagWritebackFolderKey.key(sourceID: "s1", filePath: "music/Other/02.mp3")
        let otherFolder = TagWritebackFolderKey.key(sourceID: "s1", filePath: "/photo/03.mp3")
        let otherSource = TagWritebackFolderKey.key(sourceID: "s2", filePath: "/music/Artist/Album/01.flac")
        #expect(first == second)
        #expect(first != otherFolder)
        #expect(first != otherSource)
        // Files at the root share the source's root group.
        #expect(TagWritebackFolderKey.key(sourceID: "s1", filePath: "/a.mp3")
            == TagWritebackFolderKey.key(sourceID: "s1", filePath: "b.mp3"))
    }

    @Test func refusalsWaitADayAndDroppedConnectionsTenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(PendingTagWritebackSchedule.isDue(lastAttemptAt: nil, refused: true, sourceJustReachable: false, now: now))
        let fiveMinutes = now.addingTimeInterval(-5 * 60)
        #expect(!PendingTagWritebackSchedule.isDue(lastAttemptAt: fiveMinutes, refused: false, sourceJustReachable: false, now: now))
        #expect(PendingTagWritebackSchedule.isDue(lastAttemptAt: fiveMinutes, refused: false, sourceJustReachable: true, now: now))
        #expect(!PendingTagWritebackSchedule.isDue(lastAttemptAt: now.addingTimeInterval(-20), refused: false, sourceJustReachable: true, now: now))
        #expect(PendingTagWritebackSchedule.isDue(lastAttemptAt: now.addingTimeInterval(-11 * 60), refused: false, sourceJustReachable: false, now: now))
        // A source that scanned fine can still refuse writes.
        let hours = now.addingTimeInterval(-3 * 3600)
        #expect(!PendingTagWritebackSchedule.isDue(lastAttemptAt: hours, refused: true, sourceJustReachable: true, now: now))
        #expect(PendingTagWritebackSchedule.isDue(lastAttemptAt: now.addingTimeInterval(-25 * 3600), refused: true, sourceJustReachable: false, now: now))
        #expect(PendingTagWritebackSchedule.isDue(lastAttemptAt: now.addingTimeInterval(3600), refused: true, sourceJustReachable: false, now: now))
    }

    @Test func textTagsStayLocalOnSidecarCueAndUnsupportedSongs() {
        #expect(AudioMetadataWritebackPolicy.textTagsLeaveLibrary(sourceType: .smb, format: .flac, isCueTrack: false, isStreamDescriptor: false))
        #expect(!AudioMetadataWritebackPolicy.textTagsLeaveLibrary(sourceType: .smb, format: .flac, isCueTrack: true, isStreamDescriptor: false))
        #expect(AudioMetadataWritebackPolicy.textTagsLeaveLibrary(sourceType: .jellyfin, format: .flac, isCueTrack: false, isStreamDescriptor: false))
        #expect(!AudioMetadataWritebackPolicy.textTagsLeaveLibrary(sourceType: .smb, format: .ogg, isCueTrack: false, isStreamDescriptor: false))
    }
}
