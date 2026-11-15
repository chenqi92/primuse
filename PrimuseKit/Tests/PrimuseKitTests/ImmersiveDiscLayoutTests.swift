import Foundation
import Testing
@testable import PrimuseKit

struct ImmersiveDiscLayoutTests {
    @Test(arguments: [CGSize(width: 345, height: 620), CGSize(width: 734, height: 230),
                      CGSize(width: 1740, height: 840), CGSize(width: 300, height: 150)])
    func movedDiscAndTonearmStayInsideArtworkArea(size: CGSize) {
        for hasTonearm in [true, false] {
            let content = CGRect(origin: CGPoint(x: 24, y: 90), size: size)
            let layout = ImmersiveDiscLayout(content: content, portrait: size.height > size.width,
                                             hasTonearm: hasTonearm, spacing: 24)
            for point in [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: -5, y: 20)] {
                let frame = layout.frame(at: point)
                #expect(layout.artworkBounds.insetBy(dx: -0.001, dy: -0.001).contains(frame))
                #expect(!frame.intersects(layout.textBounds))
                #expect(content.insetBy(dx: -0.001, dy: -0.001).contains(frame))
            }
        }
    }

    /// iPhone Duo 内屏横握 / 竖握多分给唱片的那一份：唱片变大，仍不压文字、不出内容区。
    @Test(arguments: [(CGSize(width: 871, height: 486), false, CGFloat(0.62)),
                      (CGSize(width: 605, height: 651), true, CGFloat(0.64))])
    func largerArtworkShareGrowsDiscWithoutTouchingText(size: CGSize, portrait: Bool, share: CGFloat) {
        let content = CGRect(origin: CGPoint(x: 40, y: 78), size: size)
        let base = ImmersiveDiscLayout(content: content, portrait: portrait, hasTonearm: true, spacing: 40)
        let roomy = ImmersiveDiscLayout(content: content, portrait: portrait, hasTonearm: true,
                                        spacing: 40, artworkShare: share)
        #expect(roomy.diameter > base.diameter)
        for point in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
            let frame = roomy.frame(at: point)
            #expect(!frame.intersects(roomy.textBounds))
            #expect(content.insetBy(dx: -0.001, dy: -0.001).contains(frame))
        }
    }

    @Test func onlyTheActualDiscStartsDragging() {
        let layout = ImmersiveDiscLayout(content: CGRect(x: 20, y: 80, width: 900, height: 600),
                                         portrait: false, hasTonearm: true, spacing: 40)
        let position = CGPoint(x: 0.5, y: 0.5)
        let frame = layout.frame(at: position)
        #expect(layout.containsDisc(CGPoint(x: frame.minX + layout.diameter / 2, y: frame.midY), at: position))
        #expect(!layout.containsDisc(frame.origin, at: position))
        #expect(!layout.containsDisc(CGPoint(x: layout.textBounds.midX, y: layout.textBounds.midY), at: position))
        #expect(!layout.containsDisc(CGPoint(x: 50, y: 30), at: position))
    }

    @Test func dragUsesRelativePositionAndClampsAtEdges() {
        let layout = ImmersiveDiscLayout(content: CGRect(x: 0, y: 0, width: 900, height: 600),
                                         portrait: false, hasTonearm: false, spacing: 40)
        let center = CGPoint(x: 0.5, y: 0.5)
        let moved = layout.translated(center, by: CGSize(width: layout.travel.width / 4, height: -layout.travel.height / 4))
        #expect(moved == CGPoint(x: 0.75, y: 0.25))
        #expect(layout.translated(center, by: CGSize(width: 10_000, height: -10_000)) == CGPoint(x: 1, y: 0))
        #expect(ImmersiveDiscLayout.clamped(CGPoint(x: CGFloat.nan, y: CGFloat.infinity)) == center)
    }

    @Test func previousDiscSelectionUsesTheCombinedScene() {
        #expect(ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: "compactDisc", hasSynchronizedLyrics: false, hasArtwork: false
        ) == "vinylDeck")
    }
}
