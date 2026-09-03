import Foundation

public enum ProgressScrubGestureIntent: Equatable, Sendable {
    case undecided
    case horizontal
    case vertical
}

/// Persistent state for one progress-bar drag. Unlike `GestureState`, this
/// value remains available to the gesture's end callback, so the track that
/// began the interaction can be verified before committing a seek.
public struct ProgressScrubSession: Equatable, Sendable {
    public let interactionID: String?
    public private(set) var intent: ProgressScrubGestureIntent = .undecided
    public private(set) var preview: TimeInterval?

    public init(interactionID: String?) {
        self.interactionID = interactionID
    }

    public mutating func update(
        horizontalTranslation: Double,
        verticalTranslation: Double,
        location: Double,
        trackWidth: Double,
        duration: TimeInterval
    ) {
        intent = NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: intent,
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation
        )
        guard intent == .horizontal else { return }
        preview = NowPlayingInteractionPolicy.scrubValue(
            location: location,
            trackWidth: trackWidth,
            duration: duration
        )
    }

    public func committedValue(
        currentInteractionID: String?,
        horizontalTranslation: Double,
        verticalTranslation: Double,
        location: Double,
        trackWidth: Double,
        duration: TimeInterval
    ) -> TimeInterval? {
        let finalIntent = NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: intent,
            horizontalTranslation: horizontalTranslation,
            verticalTranslation: verticalTranslation
        )
        guard NowPlayingInteractionPolicy.shouldCommitScrub(
            intent: finalIntent,
            startedInteractionID: interactionID,
            currentInteractionID: currentInteractionID
        ) else { return nil }
        return NowPlayingInteractionPolicy.scrubValue(
            location: location,
            trackWidth: trackWidth,
            duration: duration
        )
    }
}

/// Pure interaction rules shared by the Now Playing UI and its regressions.
public enum NowPlayingInteractionPolicy {
    /// A small movement threshold prevents a normal track tap from becoming a seek.
    public static let minimumScrubDistance: Double = 8
    public static let minimumScrubHitTargetSize: Double = 44

    public static func shouldKeepScreenAwake(
        settingEnabled: Bool,
        lyricsVisible: Bool,
        sceneIsActive: Bool
    ) -> Bool {
        settingEnabled && lyricsVisible && sceneIsActive
    }

    public static func updatedScreenWakeOwners(
        _ owners: Set<UUID>,
        ownerID: UUID,
        shouldHold: Bool
    ) -> Set<UUID> {
        var updatedOwners = owners
        if shouldHold {
            updatedOwners.insert(ownerID)
        } else {
            updatedOwners.remove(ownerID)
        }
        return updatedOwners
    }

    public static func shouldSeekFromLyricTap(
        settingEnabled: Bool,
        lineIsSynchronized: Bool
    ) -> Bool {
        settingEnabled && lineIsSynchronized
    }

    public static func scrubValue(
        location: Double,
        trackWidth: Double,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard location.isFinite,
              trackWidth.isFinite,
              trackWidth > 0,
              duration.isFinite,
              duration > 0 else { return nil }
        return min(max(location / trackWidth, 0), 1) * duration
    }

    public static func scrubGestureIntent(
        currentIntent: ProgressScrubGestureIntent,
        horizontalTranslation: Double,
        verticalTranslation: Double
    ) -> ProgressScrubGestureIntent {
        guard currentIntent == .undecided else { return currentIntent }
        guard horizontalTranslation.isFinite,
              verticalTranslation.isFinite else { return .vertical }
        let horizontalDistance = abs(horizontalTranslation)
        let verticalDistance = abs(verticalTranslation)
        guard max(horizontalDistance, verticalDistance) >= minimumScrubDistance else {
            return .undecided
        }
        return horizontalDistance >= minimumScrubDistance
            && horizontalDistance >= verticalDistance * 1.25
            ? .horizontal
            : .vertical
    }

    public static func shouldCommitScrub(
        intent: ProgressScrubGestureIntent,
        startedInteractionID: String?,
        currentInteractionID: String?
    ) -> Bool {
        intent == .horizontal && startedInteractionID == currentInteractionID
    }

    public static func accessibilityStep(for duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(duration * 0.05, 5), 30)
    }

    public static func adjustedPlaybackTime(
        currentTime: TimeInterval,
        duration: TimeInterval,
        incrementing: Bool
    ) -> TimeInterval? {
        guard currentTime.isFinite,
              duration.isFinite,
              duration > 0 else { return nil }
        let delta = accessibilityStep(for: duration) * (incrementing ? 1 : -1)
        return min(max(currentTime + delta, 0), duration)
    }
}
