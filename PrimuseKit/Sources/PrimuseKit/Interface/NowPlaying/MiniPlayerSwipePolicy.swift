import Foundation

public enum MiniPlayerSwipeAction: Equatable, Sendable {
    case previous
    case next
}

public struct MiniPlayerSwipeSample: Equatable, Sendable {
    public let translationX: Double
    public let translationY: Double
    public let velocityX: Double
    public let velocityY: Double
    public let startX: Double
    public let containerWidth: Double
    public let isRightToLeft: Bool

    public init(
        translationX: Double,
        translationY: Double,
        velocityX: Double,
        velocityY: Double,
        startX: Double,
        containerWidth: Double,
        isRightToLeft: Bool
    ) {
        self.translationX = translationX
        self.translationY = translationY
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.startX = startX
        self.containerWidth = containerWidth
        self.isRightToLeft = isRightToLeft
    }
}

public enum MiniPlayerSwipePolicy {
    public static let minimumGestureDistance = 12.0
    public static let distanceThreshold = 56.0
    public static let velocityThreshold = 650.0
    public static let minimumFlickDistance = 20.0
    public static let horizontalDominanceRatio = 1.25
    public static let leadingEdgeExclusion = 24.0
    public static let maximumFeedbackOffset = 18.0

    public static func action(for sample: MiniPlayerSwipeSample) -> MiniPlayerSwipeAction? {
        guard let hint = directionHint(for: sample) else { return nil }

        let horizontalDistance = abs(sample.translationX)
        let distanceQualified = horizontalDistance >= distanceThreshold
        let velocityQualified = horizontalDistance >= minimumFlickDistance
            && abs(sample.velocityX) >= velocityThreshold
            && abs(sample.velocityX) >= abs(sample.velocityY) * horizontalDominanceRatio
            && sample.translationX.sign == sample.velocityX.sign

        return distanceQualified || velocityQualified ? hint : nil
    }

    public static func directionHint(for sample: MiniPlayerSwipeSample) -> MiniPlayerSwipeAction? {
        guard !startsInSystemLeadingEdge(sample),
              abs(sample.translationX) >= minimumGestureDistance,
              abs(sample.translationX) >= abs(sample.translationY) * horizontalDominanceRatio else {
            return nil
        }
        return sample.translationX < 0 ? .next : .previous
    }

    public static func feedbackOffset(
        for sample: MiniPlayerSwipeSample,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion, directionHint(for: sample) != nil else { return 0 }
        return min(
            maximumFeedbackOffset,
            max(-maximumFeedbackOffset, sample.translationX * 0.22)
        )
    }

    private static func startsInSystemLeadingEdge(_ sample: MiniPlayerSwipeSample) -> Bool {
        guard sample.containerWidth > 0 else { return false }
        if sample.isRightToLeft {
            return sample.startX >= sample.containerWidth - leadingEdgeExclusion
        }
        return sample.startX <= leadingEdgeExclusion
    }
}
