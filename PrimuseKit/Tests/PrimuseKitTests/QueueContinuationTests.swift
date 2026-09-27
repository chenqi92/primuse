import Foundation
import Testing
@testable import PrimuseKit

@Suite("Queue window and continuation")
struct QueueContinuationTests {
    @Test("Requests that fit are installed whole")
    func smallRequestsHaveNoWindow() {
        #expect(QueueWindowPolicy.window(count: 0, selectedIndex: 0) == nil)
        #expect(QueueWindowPolicy.window(count: QueueWindowPolicy.windowLimit, selectedIndex: 500) == nil)
    }

    @Test("The window keeps a little history and never runs past either end")
    func windowPlacement() {
        let limit = QueueWindowPolicy.windowLimit
        let lead = QueueWindowPolicy.leadingHistory
        #expect(QueueWindowPolicy.window(count: 219_474, selectedIndex: 0) == 0..<limit)
        #expect(QueueWindowPolicy.window(count: 219_474, selectedIndex: 10) == 0..<limit)
        #expect(QueueWindowPolicy.window(count: 219_474, selectedIndex: 5_000) == (5_000 - lead)..<(5_000 - lead + limit))
        #expect(QueueWindowPolicy.window(count: 219_474, selectedIndex: 219_473) == (219_474 - limit)..<219_474)
        #expect(QueueWindowPolicy.window(count: 219_474, selectedIndex: 999_999) == (219_474 - limit)..<219_474)
        #expect(QueueWindowPolicy.window(count: 1_001, selectedIndex: 600) == 1..<1_001)
    }

    @Test("Songs after the window come out in order, then it is exhausted without repeat")
    func trailingSongsInOrder() {
        let ids = (0..<2_600).map { "s\($0)" }
        var continuation = QueueContinuation(requestedIDs: ids, window: 100..<1_100)
        #expect(continuation.takeNext(maxCount: 500, repeatsAll: false) == Array(ids[1_100..<1_600]))
        #expect(continuation.takeNext(maxCount: 500, repeatsAll: false) == Array(ids[1_600..<2_100]))
        #expect(continuation.takeNext(maxCount: 800, repeatsAll: false) == Array(ids[2_100..<2_600]))
        #expect(continuation.takeNext(maxCount: 500, repeatsAll: false).isEmpty)
        // Songs before the window are still owed to a later repeat-all cycle.
        #expect(!continuation.isExhausted)
    }

    @Test("Repeat-all brings the songs before the window after the tail, once")
    func repeatAllCoversEverySong() {
        let ids = (0..<1_300).map { "s\($0)" }
        var continuation = QueueContinuation(requestedIDs: ids, window: 200..<1_200)
        var handedOut: [String] = []
        while !continuation.isExhausted {
            let batch = continuation.takeNext(maxCount: 70, repeatsAll: true)
            #expect(!batch.isEmpty)
            handedOut += batch
        }
        #expect(handedOut == Array(ids[1_200..<1_300]) + Array(ids[0..<200]))
        #expect(continuation.takeNext(maxCount: 10, repeatsAll: true).isEmpty)
        // Window plus everything handed out is exactly the request.
        #expect(Set(handedOut + ids[200..<1_200]) == Set(ids))
    }

    @Test("Remapped IDs are handed out under their new identity")
    func remapFollowsMigrations() {
        var continuation = QueueContinuation(requestedIDs: (0..<1_200).map { "s\($0)" }, window: 0..<1_000)
        continuation.remapIDs(["s1000": "n1000", "s5": "n5"])
        #expect(continuation.takeNext(maxCount: 2, repeatsAll: false) == ["n1000", "s1001"])
    }

    @Test("A continuation survives the store round trip")
    func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueContinuationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueueContinuationStore(url: directory.appendingPathComponent("c.json"))
        #expect(store.load() == nil)
        var continuation = QueueContinuation(requestedIDs: (0..<3_000).map { "id-\($0)" }, window: 0..<1_000)
        _ = continuation.takeNext(maxCount: 500, repeatsAll: false)
        store.save(continuation)
        #expect(store.load() == continuation)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test("Session files written before the token existed still decode")
    func legacySessionDecodes() throws {
        let legacy = #"{"currentIndex":0,"currentSongID":"a","currentTime":1,"duration":2,"isAtTrackEnd":false,"queueSongIDs":["a"],"repeatMode":"off","shuffleEnabled":false,"shufflePosition":0,"shuffledIndices":[],"updatedAt":"2026-09-26T00:00:00Z","version":1,"wasPlaying":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(PlaybackSessionSnapshot.self, from: Data(legacy.utf8))
        #expect(snapshot.queueContinuationToken == nil)
        #expect(snapshot.queueSongIDs == ["a"])
    }

    private func legacySnapshot(count: Int, current: Int, shuffled: [Int]? = nil, position: Int = 0) -> PlaybackSessionSnapshot {
        PlaybackSessionSnapshot(
            queueSongIDs: (0..<count).map { "s\($0)" },
            currentSongID: "s\(current)",
            currentIndex: current,
            currentTime: 12,
            duration: 200,
            wasPlaying: false,
            shuffleEnabled: shuffled != nil,
            shuffledIndices: shuffled ?? [],
            shufflePosition: position,
            pendingNextShuffleIndices: shuffled.map { Array($0.reversed()) },
            repeatMode: .all,
            isAtTrackEnd: false
        )
    }

    @Test("A whole-library session restores as a window around the current song")
    func legacyOrderedSessionIsWindowed() throws {
        #expect(QueueWindowPolicy.windowed(legacySnapshot(count: 1_000, current: 3)) == nil)
        let result = try #require(QueueWindowPolicy.windowed(legacySnapshot(count: 219_474, current: 120_000)))
        let windowed = result.snapshot
        #expect(windowed.queueSongIDs.count == QueueWindowPolicy.windowLimit)
        #expect(windowed.queueSongIDs[windowed.currentIndex] == "s120000")
        #expect(windowed.currentSongID == "s120000")
        #expect(windowed.currentIndex == QueueWindowPolicy.leadingHistory)
        #expect(windowed.queueContinuationToken == result.continuation.token)
        #expect(windowed.pendingNextShuffleIndices == nil)
        var continuation = result.continuation
        #expect(continuation.takeNext(maxCount: 2, repeatsAll: false) == ["s120950", "s120951"])
        // The restore plan accepts the reshaped snapshot as-is.
        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: windowed,
            availableSongIDs: Set(windowed.queueSongIDs)
        ))
        #expect(plan.currentIndex == windowed.currentIndex)
    }

    @Test("A shuffled whole-library session keeps the rest of its random round")
    func legacyShuffledSessionKeepsItsOrder() throws {
        let count = 5_000
        var order = Array((0..<count).reversed())
        order.swapAt(0, 2_000)          // order[0] == 2999, order[2000] == 4999
        let result = try #require(QueueWindowPolicy.windowed(
            legacySnapshot(count: count, current: order[1_500], shuffled: order, position: 1_500)
        ))
        let windowed = result.snapshot
        let expected = order[1_500...].map { "s\($0)" }
        #expect(windowed.queueSongIDs == Array(expected.prefix(QueueWindowPolicy.windowLimit)))
        #expect(windowed.currentIndex == 0 && windowed.shufflePosition == 0)
        #expect(windowed.shuffledIndices == Array(0..<QueueWindowPolicy.windowLimit))
        var continuation = result.continuation
        var rest: [String] = []
        while case let batch = continuation.takeNext(maxCount: 700, repeatsAll: true), !batch.isEmpty {
            rest += batch
        }
        #expect(rest == Array(expected.dropFirst(QueueWindowPolicy.windowLimit)))
        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: windowed,
            availableSongIDs: Set(windowed.queueSongIDs)
        ))
        #expect(plan.shuffledIndices == Array(0..<QueueWindowPolicy.windowLimit))
    }
}
