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
    public static let revealWidth = 112.0
    public static let revealThreshold = 0.42
    public static let velocityProjectionDuration = 0.12
    public static let overscrollResistance = 0.18
    public static let maximumOverscroll = 18.0

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
    /// side is semantic leading (queue end); RTL mirrors both actions.
    public static func action(
        forOffset offset: Double,
        isRightToLeft: Bool
    ) -> SongRowSwipeAction? {
        guard offset != 0 else { return nil }
        let exposesSemanticLeading = isRightToLeft ? offset < 0 : offset > 0
        return exposesSemanticLeading ? .appendToQueue : .insertNext
    }

    public static func restingOffset(
        for action: SongRowSwipeAction?,
        isRightToLeft: Bool
    ) -> Double {
        guard let action else { return 0 }
        switch action {
        case .appendToQueue:
            return isRightToLeft ? -revealWidth : revealWidth
        case .insertNext:
            return isRightToLeft ? revealWidth : -revealWidth
        }
    }

    public static func interactiveOffset(_ proposedOffset: Double) -> Double {
        let magnitude = abs(proposedOffset)
        guard magnitude > revealWidth else { return proposedOffset }
        let overscroll = min(
            maximumOverscroll,
            (magnitude - revealWidth) * overscrollResistance
        )
        return proposedOffset.sign == .minus
            ? -(revealWidth + overscroll)
            : revealWidth + overscroll
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
