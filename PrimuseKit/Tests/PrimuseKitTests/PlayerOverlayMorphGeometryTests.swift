import CoreGraphics
import Testing
@testable import PrimuseKit

@Suite("Player overlay corner transitions")
struct PlayerOverlayMorphGeometryTests {
    private let container = CGSize(width: 390, height: 844)
    private let capsule = CGRect(x: 16, y: 694, width: 358, height: 56)

    @Test("An exposed edge rounds during downward and leading-edge drags", arguments: [
        CGSize(width: 0, height: 60),
        CGSize(width: 60, height: 0),
        CGSize(width: -60, height: 0)
    ])
    func draggedSurfaceHasRoundedCorners(offset: CGSize) {
        let geometry = geometry(offset: offset)

        #expect(geometry.cornerRadius >= 28)
        #expect(geometry.cornerRadius <= 40)
        #expect(geometry.transform.tx == offset.width)
        #expect(geometry.transform.ty == offset.height)
        #expect(geometry.contentOpacity == 1)
    }

    @Test("Canceling a drag smoothly returns to an edge-to-edge surface")
    func canceledDragRestoresFullScreen() {
        var previousRadius: CGFloat = 40
        for distance in stride(from: 60.0, through: 0.0, by: -0.25) {
            let radius = geometry(offset: CGSize(width: 0, height: distance)).cornerRadius
            #expect(radius <= previousRadius)
            #expect(previousRadius - radius < 0.5)
            previousRadius = radius
        }
        #expect(geometry().cornerRadius == 0)
        #expect(geometry().transform == .identity)
    }

    @Test("Releasing a drag into collapse preserves the visible corner", arguments: [8.0, 20.0, 60.0, 180.0])
    func dismissalContinuesFromDraggedCorner(distance: Double) {
        let offset = CGSize(width: 0, height: distance)
        var previous = geometry(offset: offset)
        for progress in stride(from: 0.999, through: 0.85, by: -0.001) {
            let current = geometry(progress: progress, offset: offset)
            #expect(screenRadius(current) > 0)
            #expect(abs(screenRadius(current) - screenRadius(previous)) < 2)
            previous = current
        }
    }

    @Test("Expansion and collapse round the exposed surface even close to full screen")
    func morphRoundsBeforeSettling() {
        let nearlyExpanded = geometry(progress: 0.98)
        #expect(screenRadius(nearlyExpanded) > 5)

        let collapsed = geometry(progress: 0)
        #expect(abs(screenRadius(collapsed) - capsule.height / 2) < 0.001)
        #expect(collapsed.overallOpacity == 0)

        var previousRadius: CGFloat = 0
        for progress in stride(from: 1.0, through: 0.85, by: -0.001) {
            let radius = screenRadius(geometry(progress: progress))
            #expect(abs(radius - previousRadius) < 2)
            previousRadius = radius
        }
    }

    @Test("Upward spring overshoot covers the screen without rounded gaps", arguments: [0.0, -1.0, -20.0])
    func upwardBounceCoversScreen(offsetY: Double) {
        let geometry = geometry(offset: CGSize(width: 0, height: offsetY))
        #expect(geometry.cornerRadius < 0.001)
        #expect(abs(container.height * geometry.transform.d + geometry.transform.ty - container.height) < 0.001)
        #expect(self.geometry(progress: 1.02).cornerRadius == 0)
    }

    @Test("Portrait, landscape and tablet surfaces share the edge rounding behavior", arguments: [
        CGSize(width: 390, height: 844),
        CGSize(width: 844, height: 390),
        CGSize(width: 1024, height: 1366)
    ])
    func roundingAdaptsToContainer(size: CGSize) {
        let capsule = CGRect(x: 16, y: size.height - 150, width: size.width - 32, height: 56)
        let dragged = PlayerOverlayMorphGeometry(
            progress: 1, offset: CGSize(width: 0, height: 60), capsule: capsule, container: size
        )
        #expect(dragged.cornerRadius >= 28)
        let resting = PlayerOverlayMorphGeometry(progress: 1, offset: .zero, capsule: capsule, container: size)
        #expect(resting.cornerRadius == 0)
    }

    private func geometry(progress: CGFloat = 1, offset: CGSize = .zero) -> PlayerOverlayMorphGeometry {
        PlayerOverlayMorphGeometry(progress: progress, offset: offset, capsule: capsule, container: container)
    }

    private func screenRadius(_ geometry: PlayerOverlayMorphGeometry) -> CGFloat {
        geometry.cornerRadius * geometry.transform.a
    }
}
