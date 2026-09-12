import Foundation

/// What to do with gapless successor preparation when a traversal-only edit
/// (shuffle toggle, Up Next reorder) changes which song follows the current
/// track without touching the current track's transport.
///
/// Two loops can exist around the current track. `inFlight` decodes the
/// *next* song. `feed` is the loop a gapless boundary promoted to the current
/// track's decoder; its follow-up arms the next preparation once the current
/// track is fully scheduled. Only preparation that has not yet put audio on
/// the player node may be restarted: buffers already queued behind the
/// current track's final buffer cannot be taken back, so that boundary must
/// fall back to a normal advance instead.
public enum GaplessSuccessorDiscardPolicy {
    public struct PreparationSnapshot: Sendable, Equatable {
        /// At least one successor buffer is queued on the player node.
        public var hasScheduledBuffers: Bool
        /// The transition was already marked stale by an earlier decision.
        public var isStale: Bool
        public var queueGeneration: Int

        public init(hasScheduledBuffers: Bool, isStale: Bool, queueGeneration: Int) {
            self.hasScheduledBuffers = hasScheduledBuffers
            self.isStale = isStale
            self.queueGeneration = queueGeneration
        }
    }

    public struct FeedSnapshot: Sendable, Equatable {
        /// The feed belongs to the play ID that is currently audible.
        public var ownsCurrentPlayback: Bool
        /// The feed was cancelled or failed; its boundary will not be gapless.
        public var isStale: Bool
        /// The current track's own boundary transition, if the feed made one.
        public var following: PreparationSnapshot?

        public init(ownsCurrentPlayback: Bool, isStale: Bool, following: PreparationSnapshot?) {
            self.ownsCurrentPlayback = ownsCurrentPlayback
            self.isStale = isStale
            self.following = following
        }
    }

    public enum Action: Sendable, Equatable {
        /// Start the in-flight preparation over with the new queue order.
        case restartPreparation
        /// Wait for the current feed to finish scheduling, then prepare the
        /// new successor.
        case rearmFollowup
        /// Nothing can be re-armed; the boundary resolves the successor.
        case leaveToBoundary
    }

    /// A cancelled preparation whose buffers already sit on the node, but
    /// which has not scheduled the whole successor, must never be activated:
    /// nobody would keep feeding that track. A fully scheduled successor is
    /// safe to keep; the boundary still verifies the queue slot.
    public static func marksPreparationStale(
        hasScheduledBuffers: Bool,
        isFullyScheduled: Bool
    ) -> Bool {
        hasScheduledBuffers && !isFullyScheduled
    }

    /// The in-flight preparation takes precedence: when one exists, the feed
    /// has already finished scheduling and its follow-up has fired.
    public static func action(
        inFlight: PreparationSnapshot?,
        feed: FeedSnapshot?,
        queueGeneration: Int
    ) -> Action {
        if let inFlight {
            guard !inFlight.hasScheduledBuffers,
                  !inFlight.isStale,
                  inFlight.queueGeneration == queueGeneration else { return .leaveToBoundary }
            return .restartPreparation
        }
        guard let feed,
              feed.ownsCurrentPlayback,
              !feed.isStale,
              let following = feed.following,
              !following.hasScheduledBuffers,
              !following.isStale,
              following.queueGeneration == queueGeneration else { return .leaveToBoundary }
        return .rearmFollowup
    }
}
