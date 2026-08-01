import Testing
@testable import PrimuseKit

@Suite("Lyric row geometry batching")
struct LyricRowFrameBatchPolicyTests {
    @Test("The latest frame wins while other current rows are retained")
    func latestFrameWins() {
        let validIDs: Set<String> = ["first", "second"]
        let initial = ["first": 10, "second": 20]

        let result = LyricRowFrameBatchPolicy.merging(
            id: "first",
            frame: 30,
            into: initial,
            retaining: validIDs
        )

        #expect(result == ["first": 30, "second": 20])
    }

    @Test("Rows removed by a lyric refresh cannot remain in the batch")
    func prunesRowsFromPreviousLyrics() {
        let result = LyricRowFrameBatchPolicy.merging(
            id: "old",
            frame: 40,
            into: ["old": 10, "current": 20],
            retaining: ["current"]
        )

        #expect(result == ["current": 20])
    }
}
