import Foundation
import Testing
@testable import PrimuseKit

@Suite("Mini player window placement")
struct MiniPlayerWindowPlacementTests {
    private let screen = CGRect(x: 0, y: 24, width: 1440, height: 876)

    @Test("Bottom corners expand upward and collapse to their original position", arguments: [0.0, 1140.0])
    func bottomCorners(x: Double) {
        let original = CGRect(x: x, y: 24, width: 300, height: 240)
        let anchor = NowPlayingInteractionPolicy.miniPlayerExpansionAnchor(
            frame: original, expandedHeight: 540, visibleFrame: screen
        )
        #expect(anchor == .bottom)
        let expanded = resize(original, to: 540, anchor: anchor)
        #expect(expanded == CGRect(x: x, y: 24, width: 300, height: 540))
        #expect(resize(expanded, to: 240, anchor: anchor) == original)
    }

    @Test("Enough space below keeps the top edge fixed", arguments: [324.0, 660.0])
    func expandsDownward(y: Double) {
        let original = CGRect(x: 400, y: y, width: 300, height: 240)
        let anchor = NowPlayingInteractionPolicy.miniPlayerExpansionAnchor(
            frame: original, expandedHeight: 540, visibleFrame: screen
        )
        #expect(anchor == .top)
        let expanded = resize(original, to: 540, anchor: anchor)
        #expect(expanded.maxY == original.maxY)
        #expect(screen.contains(expanded))
        #expect(resize(expanded, to: 240, anchor: anchor) == original)
    }

    @Test("Neither side fitting uses more space and stays inside the visible screen")
    func limitedSpace() {
        let visible = CGRect(x: 0, y: 40, width: 1000, height: 600)
        let original = CGRect(x: 0, y: 140, width: 300, height: 240)
        let anchor = NowPlayingInteractionPolicy.miniPlayerExpansionAnchor(
            frame: original, expandedHeight: 540, visibleFrame: visible
        )
        #expect(anchor == .bottom)
        let expanded = NowPlayingInteractionPolicy.miniPlayerFrame(
            currentFrame: original, targetHeight: 540, visibleFrame: visible, anchor: anchor
        )
        #expect(expanded == CGRect(x: 0, y: 100, width: 300, height: 540))
    }

    @Test("Secondary displays use their own visible origin")
    func secondaryScreen() {
        let visible = CGRect(x: -1920, y: -1056, width: 1920, height: 1056)
        let original = CGRect(x: -300, y: -1030, width: 300, height: 240)
        let anchor = NowPlayingInteractionPolicy.miniPlayerExpansionAnchor(
            frame: original, expandedHeight: 540, visibleFrame: visible
        )
        #expect(anchor == .bottom)
        let expanded = NowPlayingInteractionPolicy.miniPlayerFrame(
            currentFrame: original, targetHeight: 540, visibleFrame: visible, anchor: anchor
        )
        #expect(expanded == CGRect(x: -300, y: -1030, width: 300, height: 540))
    }

    @Test("A dragged expanded window collapses against its current anchor")
    func collapsesAfterDrag() {
        let dragged = CGRect(x: 700, y: 200, width: 300, height: 540)
        #expect(resize(dragged, to: 240, anchor: .bottom).minY == dragged.minY)
        #expect(resize(dragged, to: 240, anchor: .top).maxY == dragged.maxY)
    }

    @Test("Small screens and offscreen restored positions remain reachable")
    func constrainedScreen() {
        let visible = CGRect(x: 60, y: 20, width: 900, height: 480)
        let original = CGRect(x: 800, y: -40, width: 300, height: 240)
        let expanded = NowPlayingInteractionPolicy.miniPlayerFrame(
            currentFrame: original, targetHeight: 540, visibleFrame: visible, anchor: .bottom
        )
        #expect(expanded == CGRect(x: 660, y: 20, width: 300, height: 480))
    }

    private func resize(
        _ frame: CGRect,
        to height: CGFloat,
        anchor: NowPlayingInteractionPolicy.MiniPlayerExpansionAnchor
    ) -> CGRect {
        NowPlayingInteractionPolicy.miniPlayerFrame(
            currentFrame: frame, targetHeight: height, visibleFrame: screen, anchor: anchor
        )
    }
}
