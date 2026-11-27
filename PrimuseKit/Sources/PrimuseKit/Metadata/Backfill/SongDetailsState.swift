import Foundation

/// A row's metadata state is independent from whether the media can be handed
/// to the player. In particular, STRM and complete-file decoder formats can be
/// playable while their duration remains unknown.
public enum SongDetailsState: Equatable, Sendable {
    case ready
    case reading
    case waitingForSource
    case playableIncomplete
    case confirmedFailure

    public static func resolve(
        duration: TimeInterval,
        isStandaloneMusicVideo: Bool,
        isPlayable: Bool,
        isReading: Bool,
        isWaitingForSource: Bool,
        isIncomplete: Bool,
        hasConfirmedFailure: Bool
    ) -> Self {
        if duration > 0 || isStandaloneMusicVideo { return .ready }
        if isWaitingForSource { return .waitingForSource }
        if isReading { return .reading }
        if isIncomplete || (isPlayable && !hasConfirmedFailure) {
            return .playableIncomplete
        }
        return .confirmedFailure
    }
}
