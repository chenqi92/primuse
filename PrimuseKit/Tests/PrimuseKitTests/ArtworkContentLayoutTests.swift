import Foundation
import Testing
@testable import PrimuseKit

struct ArtworkContentLayoutTests {
    @Test func portraitAndLandscapeCoversKeepAllEdges() {
        #expect(ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 200, height: 400),
                    in: CGRect(x: 0, y: 0, width: 300, height: 300))
                == CGRect(x: 75, y: 0, width: 150, height: 300))
        #expect(ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 400, height: 200),
                    in: CGRect(x: 0, y: 0, width: 300, height: 300))
                == CGRect(x: 0, y: 75, width: 300, height: 150))
    }

    @Test func fullBleedFitsBetweenChromeAndFade() {
        let rect = ArtworkContentLayout.fittedRect(imageSize: CGSize(width: 100, height: 400),
                    in: CGRect(x: 0, y: 120, width: 400, height: 300))
        #expect(rect == CGRect(x: 162.5, y: 120, width: 75, height: 300))
        #expect(!ArtworkContentLayout.isRectangular(CGSize(width: 601, height: 600)))
        #expect(ArtworkContentLayout.isRectangular(CGSize(width: 300, height: 600)))
        #expect(ArtworkContentLayout.fittedRect(imageSize: .zero,
                    in: CGRect(x: 0, y: 0, width: 300, height: 300)) == .zero)
    }
}

struct VolumeScrubSessionTests {
    @Test func tapsJitterAndVerticalDismissalNeverChangeVolume() {
        var session = VolumeScrubSession(initialValue: 0.65, trackWidth: 200)
        #expect(session.update(horizontalTranslation: 0, verticalTranslation: 0) == nil)
        #expect(session.update(horizontalTranslation: 3, verticalTranslation: 2) == nil)
        #expect(session.update(horizontalTranslation: 4, verticalTranslation: 20) == nil)
        #expect(session.update(horizontalTranslation: -150, verticalTranslation: 80) == nil)
    }

    @Test func horizontalDragStartsAtCurrentVolumeAndLocksDirection() {
        var session = VolumeScrubSession(initialValue: 0.65, trackWidth: 200)
        #expect(session.update(horizontalTranslation: 20, verticalTranslation: 2) == 0.75)
        #expect(session.update(horizontalTranslation: 20, verticalTranslation: 100) == 0.75)
        #expect(session.update(horizontalTranslation: -400, verticalTranslation: 0) == 0)
        #expect(session.update(horizontalTranslation: 400, verticalTranslation: 0) == 1)
    }

    @Test func newGestureResetsIntentAndSupportsReversedTracks() {
        var session = VolumeScrubSession(initialValue: 0.5, trackWidth: -200)
        #expect(session.update(horizontalTranslation: -20, verticalTranslation: 0) == 0.6)
        var invalid = VolumeScrubSession(initialValue: 0.5, trackWidth: 0)
        #expect(invalid.update(horizontalTranslation: 20, verticalTranslation: 0) == nil)
    }
}
