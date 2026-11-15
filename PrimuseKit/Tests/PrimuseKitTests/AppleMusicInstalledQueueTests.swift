import Foundation
import Testing
@testable import PrimuseKit

@Suite("Installed Apple Music queue reuse")
struct AppleMusicInstalledQueueTests {
    @Test("A filtered queue can bind the current unique track without guessing duplicate occurrences")
    func mapsOnlyUnambiguousCurrentEntries() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(AppleMusicQueueMirrorPolicy.uniqueEntryID(
            songID: "b", expectedSongIDs: ["a", "b", "a"], queueEntryIDs: ids
        ) == ids[1])
        for songID in ["a", "missing", nil] {
            #expect(AppleMusicQueueMirrorPolicy.uniqueEntryID(
                songID: songID, expectedSongIDs: ["a", "b", "a"], queueEntryIDs: ids
            ) == nil)
        }
        #expect(AppleMusicQueueMirrorPolicy.uniqueEntryID(
            songID: "b", expectedSongIDs: ["a", "b"], queueEntryIDs: ids
        ) == nil)
    }

    @Test("Resolved native IDs do not require replacing an unchanged installed queue")
    func reusesSuccessfullyInstalledOccurrences() throws {
        let ids = [UUID(), UUID(), UUID()]
        let installed = try #require(AppleMusicInstalledQueue(songIDs: ["a", "b", "a"], entryIDs: ids, nativeEntryIDs: ["n1", "n2", "n3"]))
        #expect(installed.matches(songIDs: ["a", "b", "a"], entryIDs: ids, nativeEntryIDs: ["n1", "n2", "n3"]))
    }

    @Test("An unchanged system-filtered queue is reused without losing canonical occurrences")
    func reusesAcceptedSubset() throws {
        let ids = [UUID(), UUID(), UUID()]
        let installed = try #require(AppleMusicInstalledQueue(
            songIDs: ["a", "unavailable", "b"], entryIDs: ids, nativeEntryIDs: ["n1", "n3"]
        ))
        #expect(installed.matches(songIDs: ["a", "unavailable", "b"], entryIDs: ids, nativeEntryIDs: ["n1", "n3"]))
        #expect(!installed.matches(songIDs: ["a", "unavailable", "b"], entryIDs: ids, nativeEntryIDs: ["n1"]))
        #expect(!installed.matches(songIDs: ["a", "b"], entryIDs: [ids[0], ids[2]], nativeEntryIDs: ["n1", "n3"]))
    }

    @Test("Moving repeated occurrences or replacing a track still updates the queue")
    func rejectsEditsWithTheSameCount() throws {
        let ids = [UUID(), UUID(), UUID()]
        let installed = try #require(AppleMusicInstalledQueue(songIDs: ["a", "b", "a"], entryIDs: ids, nativeEntryIDs: ["n1", "n2", "n3"]))
        #expect(!installed.matches(songIDs: ["a", "b", "a"], entryIDs: [ids[2], ids[1], ids[0]], nativeEntryIDs: ["n1", "n2", "n3"]))
        #expect(!installed.matches(songIDs: ["a", "c", "a"], entryIDs: ids, nativeEntryIDs: ["n1", "n2", "n3"]))
        #expect(!installed.matches(songIDs: ["a", "b", "a"], entryIDs: [ids[0], UUID(), ids[2]], nativeEntryIDs: ["n1", "n2", "n3"]))
    }

    @Test("A truncated or extended native queue must be repaired")
    func rejectsNativeCountChanges() throws {
        let ids = [UUID(), UUID()]
        let installed = try #require(AppleMusicInstalledQueue(songIDs: ["a", "b"], entryIDs: ids, nativeEntryIDs: ["n1", "n2"]))
        for nativeIDs in [[], ["n1"], ["n1", "n2", "n3"], ["n2", "n1"], ["n1", "different"]] {
            #expect(!installed.matches(songIDs: ["a", "b"], entryIDs: ids, nativeEntryIDs: nativeIDs))
        }
    }

    @Test("Incomplete or duplicate occurrence identities cannot become an installed queue")
    func rejectsInvalidInstallation() {
        let id = UUID()
        #expect(AppleMusicInstalledQueue(songIDs: [], entryIDs: [], nativeEntryIDs: []) == nil)
        #expect(AppleMusicInstalledQueue(songIDs: ["a"], entryIDs: [id, UUID()], nativeEntryIDs: ["n1"]) == nil)
        #expect(AppleMusicInstalledQueue(songIDs: ["a", "a"], entryIDs: [id, id], nativeEntryIDs: ["n1", "n2"]) == nil)
    }

    @Test("A failed replacement leaves the same queue eligible for retry")
    func doesNotReuseAnUnfinishedInstallation() {
        let ids = [UUID()]
        var cache = AppleMusicQueueInstallationCache()
        let first = cache.begin()
        cache.complete(attemptID: first, songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"])
        #expect(cache.matches(songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"]))
        _ = cache.begin()
        #expect(!cache.matches(songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"]))
        let retry = cache.begin()
        cache.complete(attemptID: retry, songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"])
        #expect(cache.matches(songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"]))
    }

    @Test("Late success from a cancelled or superseded attempt cannot validate a queue")
    func rejectsStaleInstallationCompletion() {
        let ids = [UUID()]
        var cache = AppleMusicQueueInstallationCache()
        let old = cache.begin()
        let current = cache.begin()
        cache.complete(attemptID: old, songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"])
        #expect(!cache.matches(songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"]))
        cache.reset()
        cache.complete(attemptID: current, songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"])
        #expect(!cache.matches(songIDs: ["a"], entryIDs: ids, nativeEntryIDs: ["n1"]))
    }

    @Test("Next and previous to the adjacent installed entry skip natively instead of rebuilding")
    func adjacentEntriesSkipNatively() {
        let ids = [UUID(), UUID(), UUID()]
        let entries: [UUID?] = ids
        #expect(AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 1, currentEntryID: ids[1], targetEntryID: ids[2], direction: .forward
        ))
        #expect(AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 1, currentEntryID: ids[1], targetEntryID: ids[0], direction: .backward
        ))
    }

    @Test("A target that is not the native neighbour falls back to rebuilding the queue")
    func nonAdjacentTargetsRebuild() {
        let ids = [UUID(), UUID(), UUID()]
        let entries: [UUID?] = ids
        // 队列改过 / 随机顺序换过: 系统里挨着的不是 Primuse 要去的那条。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 0, currentEntryID: ids[0], targetEntryID: ids[2], direction: .forward
        ))
        // 方向反了。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 1, currentEntryID: ids[1], targetEntryID: ids[0], direction: .forward
        ))
        // 下一首是本地歌, 不在系统那段里。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 2, currentEntryID: ids[2], targetEntryID: UUID(), direction: .forward
        ))
        // 不绕回: 队尾按下一首、队首按上一首交给重装。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 2, currentEntryID: ids[2], targetEntryID: ids[0], direction: .forward
        ))
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 0, currentEntryID: ids[0], targetEntryID: ids[2], direction: .backward
        ))
        // 回到当前这条本身(没有上一首时)不是切歌。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: entries, currentIndex: 1, currentEntryID: ids[1], targetEntryID: ids[1], direction: .backward
        ))
    }

    @Test("The native current entry must be the Primuse current entry and the neighbour must be mapped")
    func outOfSyncOrUnmappedQueuesRebuild() {
        let ids = [UUID(), UUID(), UUID()]
        // 系统已经自己换到别的歌、镜像还没收养: 当前条对不上。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: ids, currentIndex: 2, currentEntryID: ids[1], targetEntryID: ids[2], direction: .forward
        ))
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: ids, currentIndex: nil, currentEntryID: ids[1], targetEntryID: ids[2], direction: .forward
        ))
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: ids, currentIndex: 7, currentEntryID: ids[1], targetEntryID: ids[2], direction: .forward
        ))
        // 系统队列里挨着的那条还没认出是哪个条目(重复出现的同一首)。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: [ids[0], ids[1], nil], currentIndex: 1, currentEntryID: ids[1], targetEntryID: ids[2], direction: .forward
        ))
        // 停止点只留下当前这一条。
        #expect(!AppleMusicManagedSkipPolicy.canSkipNatively(
            entryIDs: [ids[1]], currentIndex: 0, currentEntryID: ids[1], targetEntryID: ids[2], direction: .forward
        ))
    }
}
