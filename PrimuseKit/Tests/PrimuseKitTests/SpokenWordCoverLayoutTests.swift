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
}
