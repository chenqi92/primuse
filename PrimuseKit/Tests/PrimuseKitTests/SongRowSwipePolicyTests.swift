import Testing
@testable import PrimuseKit

@Suite("Song row swipe")
struct SongRowSwipePolicyTests {
    @Test("Vertical intent fails before the row pan begins")
    func rejectsVerticalIntent() {
        #expect(!SongRowSwipePolicy.shouldBegin(sample(x: 1, y: 12)))
        #expect(!SongRowSwipePolicy.shouldBegin(sample(
            x: 4,
            y: 10,
            velocityX: 90,
            velocityY: 420
        )))
        #expect(!SongRowSwipePolicy.shouldBegin(sample(
            x: 10,
            y: 10,
            velocityX: 280,
            velocityY: 300
        )))
    }

    @Test("Horizontal intent begins for slow drags and quick flicks")
    func acceptsHorizontalIntent() {
        #expect(SongRowSwipePolicy.shouldBegin(sample(x: 12, y: 4)))
        #expect(SongRowSwipePolicy.shouldBegin(sample(
            x: -3,
            y: 1,
            velocityX: -460,
            velocityY: 80
        )))
    }

    @Test("Small jitter and the system back edge are excluded")
    func excludesJitterAndSystemEdge() {
        #expect(!SongRowSwipePolicy.shouldBegin(sample(x: 3, y: 1)))
        #expect(!SongRowSwipePolicy.shouldBegin(sample(x: 20, startX: 12)))
        #expect(!SongRowSwipePolicy.shouldBegin(sample(
            x: -20,
            startX: 310,
            isRightToLeft: true
        )))
    }

    @Test("Queue actions mirror with semantic leading and trailing edges")
    func mirrorsActionsForRTL() {
        #expect(SongRowSwipePolicy.action(
            forOffset: 60,
            isRightToLeft: false
        ) == .insertNext)
        #expect(SongRowSwipePolicy.action(
            forOffset: -60,
            isRightToLeft: false
        ) == .appendToQueue)
        #expect(SongRowSwipePolicy.action(
            forOffset: 60,
            isRightToLeft: true
        ) == .appendToQueue)
        #expect(SongRowSwipePolicy.action(
            forOffset: -60,
            isRightToLeft: true
        ) == .insertNext)
    }

    @Test("A short drag rebounds while a committed drag stays open")
    func settlesByDistance() {
        #expect(SongRowSwipePolicy.settledAction(
            offset: 30,
            velocityX: 0,
            isRightToLeft: false
        ) == nil)
        #expect(SongRowSwipePolicy.settledAction(
            offset: -70,
            velocityX: 0,
            isRightToLeft: false
        ) == .appendToQueue)
    }

    @Test("A directional flick may commit but an opposing flick cancels")
    func settlesByProjectedVelocity() {
        #expect(SongRowSwipePolicy.settledAction(
            offset: 20,
            velocityX: 700,
            isRightToLeft: false
        ) == .insertNext)
        #expect(SongRowSwipePolicy.settledAction(
            offset: 60,
            velocityX: -900,
            isRightToLeft: false
        ) == nil)
    }

    @Test("The row follows a full swipe without the old action-width stop")
    func followsFullSwipe() {
        #expect(SongRowSwipePolicy.interactiveOffset(80, containerWidth: 320) == 80)
        #expect(SongRowSwipePolicy.interactiveOffset(212, containerWidth: 320) == 212)
        #expect(abs(
            SongRowSwipePolicy.interactiveOffset(-400, containerWidth: 320) + 300.8
        ) < 0.001)
    }

    @Test("Only a deliberate full swipe executes immediately")
    func detectsFullSwipe() {
        #expect(SongRowSwipePolicy.fullSwipeThreshold(containerWidth: 320) == 166.4)
        #expect(SongRowSwipePolicy.fullSwipeAction(
            offset: 150,
            containerWidth: 320,
            isRightToLeft: false
        ) == nil)
        #expect(SongRowSwipePolicy.fullSwipeAction(
            offset: 180,
            containerWidth: 320,
            isRightToLeft: false
        ) == .insertNext)
        #expect(SongRowSwipePolicy.fullSwipeAction(
            offset: -180,
            containerWidth: 320,
            isRightToLeft: true
        ) == .insertNext)
        #expect(SongRowSwipePolicy.fullSwipeThreshold(containerWidth: 100) == 96)
        #expect(SongRowSwipePolicy.fullSwipeThreshold(containerWidth: 900) == 360)
    }

    @Test("Resting offsets preserve action meaning in RTL")
    func restingOffsets() {
        #expect(SongRowSwipePolicy.restingOffset(
            for: .appendToQueue,
            isRightToLeft: false
        ) == -96)
        #expect(SongRowSwipePolicy.restingOffset(
            for: .appendToQueue,
            isRightToLeft: true
        ) == 96)
        #expect(SongRowSwipePolicy.restingOffset(
            for: .insertNext,
            isRightToLeft: true
        ) == -96)
    }

    private func sample(
        x: Double,
        y: Double = 0,
        velocityX: Double = 0,
        velocityY: Double = 0,
        startX: Double = 160,
        width: Double = 320,
        isRightToLeft: Bool = false
    ) -> SongRowSwipeSample {
        SongRowSwipeSample(
            translationX: x,
            translationY: y,
            velocityX: velocityX,
            velocityY: velocityY,
            startX: startX,
            containerWidth: width,
            isRightToLeft: isRightToLeft
        )
    }
}
