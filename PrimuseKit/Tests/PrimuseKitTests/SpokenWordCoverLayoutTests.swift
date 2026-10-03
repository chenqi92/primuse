import Foundation
import Testing
@testable import PrimuseKit

@Suite struct SpokenWordCoverLayoutTests {
    @Test func coverFrameIsPortrait() {
        #expect(SpokenWordCoverLayout.aspectRatio < 1)
        #expect(SpokenWordCoverLayout.height(forWidth: 90) == 120)
        #expect(SpokenWordCoverLayout.width(forHeight: 56) == 42)
        #expect(SpokenWordCoverLayout.width(forHeight: 220) == 165)
    }

    @Test func degenerateSizesCollapseToZero() {
        #expect(SpokenWordCoverLayout.height(forWidth: 0) == 0)
        #expect(SpokenWordCoverLayout.height(forWidth: -4) == 0)
        #expect(SpokenWordCoverLayout.width(forHeight: .infinity) == 0)
        #expect(SpokenWordCoverLayout.width(forHeight: .nan) == 0)
    }

    @Test func artOfTheFrameShapeFillsIt() {
        #expect(SpokenWordCoverLayout.artworkFillsFrame(imageSize: CGSize(width: 1200, height: 1200), frameAspectRatio: 1))
        #expect(SpokenWordCoverLayout.artworkFillsFrame(imageSize: CGSize(width: 600, height: 590), frameAspectRatio: 1))
        #expect(SpokenWordCoverLayout.artworkFillsFrame(
            imageSize: CGSize(width: 900, height: 1200),
            frameAspectRatio: SpokenWordCoverLayout.aspectRatio
        ))
    }

    @Test func artOfAnotherShapeIsFittedOverItsBlur() {
        #expect(!SpokenWordCoverLayout.artworkFillsFrame(
            imageSize: CGSize(width: 1200, height: 1200),
            frameAspectRatio: SpokenWordCoverLayout.aspectRatio
        ))
        #expect(!SpokenWordCoverLayout.artworkFillsFrame(imageSize: CGSize(width: 800, height: 1200), frameAspectRatio: 1))
        #expect(!SpokenWordCoverLayout.artworkFillsFrame(imageSize: CGSize(width: 1600, height: 900), frameAspectRatio: 1))
    }

    @Test func unknownShapesNeverCountAsFilling() {
        #expect(!SpokenWordCoverLayout.artworkFillsFrame(imageSize: CGSize(width: 1200, height: 1200), frameAspectRatio: nil))
        #expect(!SpokenWordCoverLayout.artworkFillsFrame(imageSize: .zero, frameAspectRatio: 1))
        #expect(!SpokenWordCoverLayout.artworkFillsFrame(imageSize: CGSize(width: 10, height: 10), frameAspectRatio: 0))
    }
}
