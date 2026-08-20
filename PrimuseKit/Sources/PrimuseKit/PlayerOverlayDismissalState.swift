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
    public enum Axis: Equatable, Sendable {
        case horizontal
        case vertical
    }

    public static let topStartMaximumY = 140.0
    public static let leadingEdgeMaximumX = 24.0

    public static func translationTowardCenter(
        translationX: Double,
        layoutIsRightToLeft: Bool
    ) -> Double {
        translationX * (layoutIsRightToLeft ? -1 : 1)
    }

    public static func distanceFromLeadingEdge(
        startX: Double,
        containerWidth: Double,
        layoutIsRightToLeft: Bool
    ) -> Double {
        layoutIsRightToLeft ? containerWidth - startX : startX
    }

    public static func topInteractiveTranslation(
        startY: Double,
        translationX: Double,
        translationY: Double
    ) -> Double? {
        guard startY >= 0,
              startY <= topStartMaximumY,
              translationY > 0,
              abs(translationY) > abs(translationX) else { return nil }
        return translationY
    }

    public static func leadingInteractiveTranslation(
        startDistanceFromLeadingEdge: Double,
        translationTowardCenter: Double,
        translationY: Double
    ) -> Double? {
        guard startDistanceFromLeadingEdge >= 0,
              startDistanceFromLeadingEdge <= leadingEdgeMaximumX,
              translationTowardCenter > 0,
              abs(translationTowardCenter) > abs(translationY) else { return nil }
        return translationTowardCenter
    }

    /// Chooses one dismissal axis for the lifetime of a drag. The caller must
    /// retain the returned value until the gesture ends so a diagonal drag
    /// cannot alternate between two interactive offsets.
    public static func recognizedAxis(
        startY: Double,
        startDistanceFromLeadingEdge: Double,
        translationTowardCenter: Double,
        translationY: Double
    ) -> Axis? {
        if topInteractiveTranslation(
            startY: startY,
            translationX: translationTowardCenter,
            translationY: translationY
        ) != nil {
            return .vertical
        }
        if leadingInteractiveTranslation(
            startDistanceFromLeadingEdge: startDistanceFromLeadingEdge,
            translationTowardCenter: translationTowardCenter,
            translationY: translationY
        ) != nil {
            return .horizontal
        }
        return nil
    }

    public static func shouldDismissFromTop(
        startY: Double,
        translationX: Double,
        translationY: Double,
        predictedEndTranslationY: Double
    ) -> Bool {
        guard topInteractiveTranslation(
            startY: startY,
            translationX: translationX,
            translationY: translationY
        ) != nil else { return false }
        return translationY >= 110 || predictedEndTranslationY >= 320
    }

    public static func shouldDismissFromLeadingEdge(
        startX: Double,
        translationX: Double,
        translationY: Double,
        predictedEndTranslationX: Double
    ) -> Bool {
        guard leadingInteractiveTranslation(
            startDistanceFromLeadingEdge: startX,
            translationTowardCenter: translationX,
            translationY: translationY
        ) != nil else { return false }
        return translationX >= 100 || predictedEndTranslationX >= 300
    }
}
