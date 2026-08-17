public struct PlayerOverlayDismissalState: Equatable, Sendable {
    public private(set) var generation: UInt64
    public private(set) var isDismissing: Bool

    public init(generation: UInt64 = 0, isDismissing: Bool = false) {
        self.generation = generation
        self.isDismissing = isDismissing
    }

    @discardableResult
    public mutating func begin() -> UInt64 {
        generation &+= 1
        isDismissing = true
        return generation
    }

    public mutating func cancelForSystemInterruption() {
        guard isDismissing else { return }
        generation &+= 1
        isDismissing = false
    }

    @discardableResult
    public mutating func complete(generation candidate: UInt64) -> Bool {
        guard isDismissing, generation == candidate else { return false }
        isDismissing = false
        return true
    }
}

/// Pure recognition rules for minimizing the regular Now Playing surface.
/// Keeping these rules independent from SwiftUI makes rotation irrelevant to
/// the decision and lets the presentation host unmount immediately afterward.
public enum NowPlayingDismissGesturePolicy {
    public static let topStartMaximumY = 140.0
    public static let leadingEdgeMaximumX = 24.0

    public static func shouldDismissFromTop(
        startY: Double,
        translationX: Double,
        translationY: Double,
        predictedEndTranslationY: Double
    ) -> Bool {
        guard startY >= 0,
              startY <= topStartMaximumY,
              translationY > 0,
              abs(translationY) > abs(translationX) else { return false }
        return translationY >= 110 || predictedEndTranslationY >= 320
    }

    public static func shouldDismissFromLeadingEdge(
        startX: Double,
        translationX: Double,
        translationY: Double,
        predictedEndTranslationX: Double
    ) -> Bool {
        guard startX >= 0,
              startX <= leadingEdgeMaximumX,
              translationX > 0,
              abs(translationX) > abs(translationY) else { return false }
        return translationX >= 100 || predictedEndTranslationX >= 300
    }
}
