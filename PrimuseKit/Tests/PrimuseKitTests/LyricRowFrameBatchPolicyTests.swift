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

@Suite("Lyric row depth effect")
struct LyricDepthEffectPolicyTests {
    @Test("Current, disabled, and unsynchronized lyrics stay sharp")
    func sharpStates() {
        #expect(LyricDepthEffectPolicy.blurRadius(
            forRow: 3,
            activeRow: 3,
            isEnabled: true,
            isSynchronized: true
        ) == 0)
        #expect(LyricDepthEffectPolicy.blurRadius(
            forRow: 4,
            activeRow: 3,
            isEnabled: false,
            isSynchronized: true
        ) == 0)
        #expect(LyricDepthEffectPolicy.blurRadius(
            forRow: 4,
            activeRow: 3,
            isEnabled: true,
            isSynchronized: false
        ) == 0)
    }

    @Test("Upcoming blur grows linearly with distance and then reaches a cap")
    func progressiveDepth() {
        let radii = (1...5).map { distance in
            LyricDepthEffectPolicy.blurRadius(
                forRow: 10 + distance,
                activeRow: 10,
                isEnabled: true,
                isSynchronized: true
            )
        }

        #expect(abs(radii[0] - 1.25) < 0.000_001)
        #expect(abs(radii[1] - 2.5) < 0.000_001)
        #expect(abs(radii[2] - 3.75) < 0.000_001)
        #expect(abs(radii[3] - 5.0) < 0.000_001)
        #expect(radii[4] == radii[3])
    }

    @Test("Passed rows recede one depth step beyond upcoming rows")
    func directionalDepth() {
        let past = LyricDepthEffectPolicy.blurRadius(
            forRow: 7,
            activeRow: 8,
            isEnabled: true,
            isSynchronized: true
        )
        let future = LyricDepthEffectPolicy.blurRadius(
            forRow: 9,
            activeRow: 8,
            isEnabled: true,
            isSynchronized: true
        )

        #expect(abs(past - 2.5) < 0.000_001)
        #expect(abs(future - 1.25) < 0.000_001)
        #expect(past > future)
    }
}

@Suite("Lyric pulse motion")
struct LyricPulseMotionPolicyTests {
    @Test("A takeover grows, rebounds, and settles without a jump at either end")
    func pulseShape() {
        let scales = (0...1000).map { LyricPulseMotionPolicy.scale(at: Double($0) / 1000) }
        #expect(scales.first == 1)
        #expect(scales.last == 1)
        #expect(scales.contains { $0 > 1.08 })
        #expect(scales.contains { $0 < 0.99 })
        #expect(scales.allSatisfy {
            $0 >= LyricPulseMotionPolicy.minimumScale && $0 <= LyricPulseMotionPolicy.maximumScale
        })
        for (before, after) in zip(scales, scales.dropFirst()) {
            #expect(abs(after - before) < 0.001)
        }
    }

    @Test("Disabled motion and invalid or completed progress leave text at its normal scale")
    func restingStates() {
        for progress in [-1.0, 0, 0.28, 0.65, 1, 2, .nan, .infinity, -.infinity] {
            #expect(LyricPulseMotionPolicy.scale(at: progress, isEnabled: false) == 1)
        }
        for progress in [-1.0, 0, 1, 2, .nan, .infinity, -.infinity] {
            #expect(LyricPulseMotionPolicy.scale(at: progress) == 1)
        }
    }

    @Test("Every pulse frame fits the same reserved width on narrow and wide screens")
    func pulseFitsStableLayout() {
        for viewport in [240.0, 320, 390, 768, 1024] {
            let maximumScale = 1.08 * LyricPulseMotionPolicy.maximumScale
            let width = LyricRowLayoutPolicy.unscaledContentWidth(
                viewportWidth: viewport, horizontalPadding: 24, maximumVisualScale: maximumScale
            )
            for frame in 0...100 {
                let scale = 1.08 * LyricPulseMotionPolicy.scale(at: Double(frame) / 100)
                #expect(width * scale <= viewport - 48 + 0.000_001)
            }
        }
    }
}
