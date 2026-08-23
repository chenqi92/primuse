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

@Suite("Lyric row layout")
struct LyricRowLayoutPolicyTests {
    @Test("Active lyric scaling remains inside the padded viewport")
    func scaledWidthFitsViewport() {
        let viewportWidth = 390.0
        let padding = 24.0
        let scale = 1.08

        let width = LyricRowLayoutPolicy.unscaledContentWidth(
            viewportWidth: viewportWidth,
            horizontalPadding: padding,
            maximumVisualScale: scale
        )

        #expect(abs(width * scale + padding * 2 - viewportWidth) < 0.000_001)
    }

    @Test("Invalid dimensions cannot produce a negative or non-finite width")
    func invalidDimensionsAreClamped() {
        #expect(LyricRowLayoutPolicy.unscaledContentWidth(
            viewportWidth: -100,
            horizontalPadding: 24,
            maximumVisualScale: 1.08
        ) == 0)
        #expect(LyricRowLayoutPolicy.unscaledContentWidth(
            viewportWidth: 100,
            horizontalPadding: 80,
            maximumVisualScale: .infinity
        ) == 0)
    }
}
