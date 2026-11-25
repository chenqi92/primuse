import Foundation
import Testing
@testable import PrimuseKit

/// 比较两张队列请求:续接(映射文件里的也一样)与普通数组按内容比,与比较两个数组同一结果。
@Suite("Queue requested songs")
struct QueueRequestedSongsTests {
    @Test("Requests compare by their IDs, whatever holds them")
    func requestsCompareByContent() {
        let ids = (0..<10_000).map { "song-\($0)" }
        let mapped = QueueContinuation(requestedIDs: ids, window: 0..<1_000)
        let other = QueueContinuation(requestedIDs: ids, window: 500..<1_500)
        guard case .file = mapped.idStorage else {
            Issue.record("expected a mapped list")
            return
        }
        #expect(QueueRequestedSongs.continuation(mapped) == .continuation(other))
        #expect(QueueRequestedSongs.continuation(mapped) == .ids(ids))
        #expect(QueueRequestedSongs.ids(ids) == .continuation(mapped))
        #expect(QueueRequestedSongs.continuation(mapped) != .ids(Array(ids.dropLast())))
        var changed = ids
        changed[9_999] = "different"
        #expect(QueueRequestedSongs.continuation(mapped) != .ids(changed))
        #expect(QueueRequestedSongs.ids(["a", "b"]) == .ids(["a", "b"]))
        #expect(QueueRequestedSongs.ids(["e\u{301}"]) == .ids(["\u{E9}"]))
        #expect(QueueRequestedSongs.continuation(mapped).count == 10_000)
        #expect(Array(mapped.requestedIDList.prefix(3)) == ["song-0", "song-1", "song-2"])
        #expect(mapped.requestedIDList.count == 10_000)
    }
}
