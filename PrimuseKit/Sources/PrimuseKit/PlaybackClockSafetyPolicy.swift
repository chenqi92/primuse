import Foundation

/// Invalidates timer callbacks that were already enqueued when the playback
/// clock stopped or restarted.
public struct PlaybackClockTickGate: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func issue() -> UInt64 {
        advanceGeneration()
        return generation
    }

    public mutating func invalidate() {
        advanceGeneration()
    }

    public func isCurrent(_ candidate: UInt64) -> Bool {
        candidate != 0 && candidate == generation
    }

    private mutating func advanceGeneration() {
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
    }
}

public enum PlaybackClockReadTarget: Equatable, Sendable {
    case primary
    case incoming
}

/// Chooses one physical player node before any framework clock is queried.
/// This keeps an inactive node out of the read path entirely.
public enum PlaybackClockReadPolicy {
    public static func target(isTransitioning: Bool) -> PlaybackClockReadTarget {
        isTransitioning ? .incoming : .primary
    }
}

/// Freezes observable progress from the last safe sample without querying an
/// audio node while the graph may be stopping. A short projection covers the
/// sampling interval but cannot turn a delayed lifecycle callback into drift.
public enum PlaybackClockFreezePolicy {
    public static let maximumExtrapolation: TimeInterval = 1

    public static func frozenTime(
        cachedCurrentTime: TimeInterval,
        currentTimeAnchor: Date,
        eventTime: Date,
        isAdvancing: Bool,
        duration: TimeInterval
    ) -> TimeInterval {
        let cachedTimeIsValid = cachedCurrentTime.isFinite
        let safeCachedTime = cachedTimeIsValid ? max(0, cachedCurrentTime) : 0
        var result = safeCachedTime

        if isAdvancing, cachedTimeIsValid {
            let elapsed = eventTime.timeIntervalSince(currentTimeAnchor)
            if elapsed.isFinite, elapsed > 0 {
                let extrapolation = min(elapsed, maximumExtrapolation)
                let extrapolated = safeCachedTime + extrapolation
                if extrapolated.isFinite {
                    result = extrapolated
                }
            }
        }

        if duration.isFinite, duration > 0 {
            result = min(result, duration)
        }
        return max(0, result)
    }
}

/// Tracks the absolute frame cursor of buffers scheduled on one physical
/// player node. Boundary callbacks can carry a token across asynchronous work
/// without reading the node clock again.
public struct PlaybackTimelineTracker: Equatable, Sendable {
    public struct BoundaryToken: Equatable, Sendable {
        fileprivate let timelineID: UUID
        public let generation: UInt64
        public let frameCursor: Int64

        fileprivate init(timelineID: UUID, generation: UInt64, frameCursor: Int64) {
            self.timelineID = timelineID
            self.generation = generation
            self.frameCursor = frameCursor
        }
    }

    private let timelineID = UUID()
    public private(set) var generation: UInt64 = 0
    public private(set) var scheduledFrameCursor: Int64 = 0
    public private(set) var committedBoundaryFrameCursor: Int64 = 0

    public init() {}

    /// Records one buffer and returns the absolute cursor at its end. Invalid
    /// counts and overflow leave the timeline unchanged.
    @discardableResult
    public mutating func recordScheduledFrames(_ frameCount: Int64) -> BoundaryToken? {
        guard frameCount > 0 else { return nil }
        let (nextCursor, overflowed) = scheduledFrameCursor.addingReportingOverflow(frameCount)
        guard !overflowed, nextCursor >= 0 else { return nil }

        scheduledFrameCursor = nextCursor
        return BoundaryToken(
            timelineID: timelineID,
            generation: generation,
            frameCursor: nextCursor
        )
    }

    /// Commits a track boundary only if it belongs to this live node timeline.
    /// Boundaries are monotonic, so a delayed duplicate cannot move the track
    /// origin backwards after a later song has already begun.
    @discardableResult
    public mutating func commitBoundary(_ token: BoundaryToken) -> Int64? {
        guard token.timelineID == timelineID,
              token.generation == generation,
              token.frameCursor > committedBoundaryFrameCursor,
              token.frameCursor <= scheduledFrameCursor else {
            return nil
        }
        committedBoundaryFrameCursor = token.frameCursor
        return token.frameCursor
    }

    /// Starts a new physical-node timeline. Seek position remains a separate
    /// playback offset and never changes this scheduled-frame coordinate.
    public mutating func reset() {
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
        scheduledFrameCursor = 0
        committedBoundaryFrameCursor = 0
    }
}
