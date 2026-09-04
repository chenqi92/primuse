import Foundation

public enum SongRowSwipeAction: Sendable, Equatable {
    case insertNext
    case appendToQueue
}

public struct SongRowSwipeSample: Sendable, Equatable {
    public var translationX: Double
    public var translationY: Double
    public var velocityX: Double
    public var velocityY: Double
    public var startX: Double
    public var containerWidth: Double
    public var isRightToLeft: Bool

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

/// Pure gesture policy shared by every iOS song row.
///
/// A row pan must fail while UIKit still considers it `.possible` whenever
/// the initial intent is vertical. That lets the ancestor scroll view begin
/// from artwork, text, or trailing controls without waiting for a SwiftUI
/// drag gesture to cancel.
public enum SongRowSwipePolicy {
    public static let minimumIntentDistance = 8.0
    public static let minimumIntentVelocity = 40.0
    public static let horizontalDominanceRatio = 1.25
    public static let systemLeadingEdgeExclusion = 24.0
    public static let revealWidth = 96.0
    public static let revealThreshold = 0.65
    public static let velocityProjectionDuration = 0.08
    public static let maximumInteractiveWidthFraction = 0.94
    public static let fullSwipeWidthFraction = 0.52
    public static let fullSwipeMinimumDistance = 160.0
    public static let fullSwipeMaximumDistance = 360.0

    public static func shouldBegin(_ sample: SongRowSwipeSample) -> Bool {
        guard !startsInSystemLeadingEdge(sample) else { return false }

        let translationMagnitude = hypot(sample.translationX, sample.translationY)
        let velocityMagnitude = hypot(sample.velocityX, sample.velocityY)
        guard translationMagnitude >= minimumIntentDistance
                || velocityMagnitude >= minimumIntentVelocity else {
            return false
        }

        let usesVelocity = velocityMagnitude >= minimumIntentVelocity
        let horizontal = abs(usesVelocity ? sample.velocityX : sample.translationX)
        let vertical = abs(usesVelocity ? sample.velocityY : sample.translationY)
        return horizontal >= max(1, vertical * horizontalDominanceRatio)
    }

    /// Positive offsets expose the physical left side of the row. In LTR that
    /// side is semantic leading (play next); RTL mirrors both actions.
    public static func action(
        forOffset offset: Double,
        isRightToLeft: Bool
    ) -> SongRowSwipeAction? {
        guard offset != 0 else { return nil }
        let exposesSemanticLeading = isRightToLeft ? offset < 0 : offset > 0
        return exposesSemanticLeading ? .insertNext : .appendToQueue
    }

    public static func restingOffset(
        for action: SongRowSwipeAction?,
        isRightToLeft: Bool
    ) -> Double {
        guard let action else { return 0 }
        switch action {
        case .insertNext:
            return isRightToLeft ? -revealWidth : revealWidth
        case .appendToQueue:
            return isRightToLeft ? revealWidth : -revealWidth
        }
    }

    /// Keep the row under the finger through a full swipe instead of hitting
    /// a fixed stop immediately after the action button is revealed.
    public static func interactiveOffset(
        _ proposedOffset: Double,
        containerWidth: Double
    ) -> Double {
        guard containerWidth > 0 else { return proposedOffset }
        let maximumOffset = max(
            revealWidth,
            containerWidth * maximumInteractiveWidthFraction
        )
        return min(max(proposedOffset, -maximumOffset), maximumOffset)
    }

    public static func fullSwipeThreshold(containerWidth: Double) -> Double {
        guard containerWidth > 0 else {
            return revealWidth * 1.75
        }
        let minimum = max(
            revealWidth,
            min(fullSwipeMinimumDistance, containerWidth * 0.8)
        )
        let preferred = max(minimum, containerWidth * fullSwipeWidthFraction)
        let maximum = max(
            revealWidth,
            min(fullSwipeMaximumDistance, containerWidth * 0.85)
        )
        return min(preferred, maximum)
    }

    /// Full swipes require real travel, rather than velocity projection, so a
    /// quick short flick can reveal an action without unexpectedly executing it.
    public static func fullSwipeAction(
        offset: Double,
        containerWidth: Double,
        isRightToLeft: Bool
    ) -> SongRowSwipeAction? {
        guard abs(offset) >= fullSwipeThreshold(containerWidth: containerWidth) else {
            return nil
        }
        return action(forOffset: offset, isRightToLeft: isRightToLeft)
    }

    public static func settledAction(
        offset: Double,
        velocityX: Double,
        isRightToLeft: Bool
    ) -> SongRowSwipeAction? {
        let projectedVelocity = min(
            revealWidth,
            max(-revealWidth, velocityX * velocityProjectionDuration)
        )
        let projectedOffset = offset + projectedVelocity
        if offset != 0,
           projectedOffset != 0,
           offset.sign != projectedOffset.sign {
            return nil
        }
        guard abs(projectedOffset) >= revealWidth * revealThreshold else {
            return nil
        }
        return action(forOffset: projectedOffset, isRightToLeft: isRightToLeft)
    }

    private static func startsInSystemLeadingEdge(_ sample: SongRowSwipeSample) -> Bool {
        guard sample.containerWidth > 0 else { return false }
        if sample.isRightToLeft {
            return sample.startX >= sample.containerWidth - systemLeadingEdgeExclusion
        }
        return sample.startX <= systemLeadingEdgeExclusion
    }
}
