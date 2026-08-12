import Testing
@testable import PrimuseKit

@Suite("Mini player swipe")
struct MiniPlayerSwipePolicyTests {
    @Test("Physical left and right swipes keep their playback meaning")
    func physicalDirections() {
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: -70)) == .next)
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: 70)) == .previous)
    }

    @Test("Vertical scrolling and small movement do not change tracks")
    func rejectsVerticalAndJitter() {
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: 30, y: 60)) == nil)
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: 11, velocityX: 1_200)) == nil)
    }

    @Test("A short horizontal flick must meet the velocity threshold")
    func velocityThreshold() {
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: -24, velocityX: -800)) == .next)
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: 24, velocityX: 800)) == .previous)
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: -24, velocityX: -500)) == nil)
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: -24, velocityX: 800)) == nil)
    }

    @Test("The system leading edge is excluded in both layout directions")
    func excludesSystemLeadingEdge() {
        #expect(MiniPlayerSwipePolicy.action(for: sample(x: 80, startX: 12)) == nil)
        #expect(MiniPlayerSwipePolicy.action(for: sample(
            x: -80,
            startX: 308,
            isRightToLeft: true
        )) == nil)
    }

    @Test("RTL does not reverse physical swipe playback meaning")
    func rtlKeepsPhysicalMeaning() {
        #expect(MiniPlayerSwipePolicy.action(for: sample(
            x: -70,
            startX: 160,
            isRightToLeft: true
        )) == .next)
        #expect(MiniPlayerSwipePolicy.action(for: sample(
            x: 70,
            startX: 160,
            isRightToLeft: true
        )) == .previous)
    }

    @Test("Feedback is damped, clamped, and disabled by Reduce Motion")
    func feedbackOffset() {
        let swipe = sample(x: -200)
        #expect(MiniPlayerSwipePolicy.feedbackOffset(for: swipe, reduceMotion: false) == -18)
        #expect(MiniPlayerSwipePolicy.feedbackOffset(for: swipe, reduceMotion: true) == 0)
        #expect(MiniPlayerSwipePolicy.feedbackOffset(
            for: sample(x: 30, y: 50),
            reduceMotion: false
        ) == 0)
    }

    private func sample(
        x: Double,
        y: Double = 0,
        velocityX: Double = 0,
        velocityY: Double = 0,
        startX: Double = 160,
        width: Double = 320,
        isRightToLeft: Bool = false
    ) -> MiniPlayerSwipeSample {
        MiniPlayerSwipeSample(
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
