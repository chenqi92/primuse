import Foundation

public struct CrossfadePlaybackClockDecision: Equatable, Sendable {
    public let visibleTime: TimeInterval?
    public let shouldRunTrackEndWatchdog: Bool

    public var shouldRecordListeningProgress: Bool {
        visibleTime != nil
    }

    public init(
        visibleTime: TimeInterval?,
        shouldRunTrackEndWatchdog: Bool
    ) {
        self.visibleTime = visibleTime
        self.shouldRunTrackEndWatchdog = shouldRunTrackEndWatchdog
    }
}

/// Keeps the visible song on the clock of the node that owns its audio.
/// During a committed crossfade the primary node is still the outgoing song,
/// so its much later sample time must not drive the incoming song's progress.
public enum CrossfadePlaybackClockPolicy {
    public static func decision(
        currentTime: TimeInterval,
        primaryNodeTime: TimeInterval?,
        incomingNodeTime: TimeInterval?,
        isTransitioning: Bool
    ) -> CrossfadePlaybackClockDecision {
        let nodeTime = isTransitioning ? incomingNodeTime : primaryNodeTime
        guard let nodeTime, nodeTime.isFinite else {
            return CrossfadePlaybackClockDecision(
                visibleTime: nil,
                shouldRunTrackEndWatchdog: !isTransitioning
            )
        }

        let sampledTime = max(0, nodeTime)
        let visibleTime: TimeInterval
        if isTransitioning {
            let normalizedCurrentTime = currentTime.isFinite ? max(0, currentTime) : 0
            visibleTime = max(normalizedCurrentTime, sampledTime)
        } else {
            // Outside a transition, the primary clock remains authoritative.
            // It may legitimately move backwards after an explicit seek.
            visibleTime = sampledTime
        }
        return CrossfadePlaybackClockDecision(
            visibleTime: visibleTime,
            shouldRunTrackEndWatchdog: !isTransitioning
        )
    }
}
