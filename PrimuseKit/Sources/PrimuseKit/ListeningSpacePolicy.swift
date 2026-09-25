import Foundation

/// The three ways of listening the app offers side by side. Each keeps its
/// own playback memory and its own rules for "continue":
/// - music plays a queue and resumes that queue;
/// - radio plays a live stream and resumes by tuning back in;
/// - spoken word plays a book and resumes each book where it was left.
public enum ListeningSpace: String, CaseIterable, Codable, Hashable, Sendable {
    case music
    case radio
    case spokenWord
}

/// Which spaces get a top-level entry. Music always does; radio and spoken
/// word only once there is something in them, so an empty tab never sits in
/// the bar. The home page offers the way in for an empty one ("add a
/// station"), and a space appears the moment it has content.
public enum ListeningSpaceVisibilityPolicy {
    public static func visibleSpaces(
        hasRadioStations: Bool,
        hasSpokenWord: Bool
    ) -> [ListeningSpace] {
        var spaces: [ListeningSpace] = [.music]
        if hasRadioStations { spaces.append(.radio) }
        if hasSpokenWord { spaces.append(.spokenWord) }
        return spaces
    }
}

/// What a sleep timer can wait for, per space.
public enum SleepTimerOption: Hashable, Sendable {
    case minutes(Int)
    case endOfTrack
    case endOfChapter
    case endOfBook
}

public enum SleepTimerOptionPolicy {
    /// The choices offered for the space that is playing.
    /// - Parameter hasChapters: the spoken-word item carries chapter marks.
    public static func options(for space: ListeningSpace, hasChapters: Bool) -> [SleepTimerOption] {
        switch space {
        case .music:
            return [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .endOfTrack]
        case .radio:
            // A live stream never ends, so only durations make sense; people
            // fall asleep to radio for longer than to an album.
            return [.minutes(15), .minutes(30), .minutes(60), .minutes(90)]
        case .spokenWord:
            var options: [SleepTimerOption] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60)]
            if hasChapters { options.append(.endOfChapter) }
            options.append(.endOfTrack)
            options.append(.endOfBook)
            return options
        }
    }
}

/// The last stretch of a timed sleep fades out instead of cutting off.
public enum SleepFadePolicy {
    public static let fadeDuration: TimeInterval = 30

    /// Volume multiplier with `remaining` seconds left on the timer: 1 until
    /// the fade starts, then an equal-power curve down to 0.
    public static func volume(remaining: TimeInterval) -> Float {
        guard remaining.isFinite else { return 1 }
        guard remaining < fadeDuration else { return 1 }
        guard remaining > 0 else { return 0 }
        let progress = remaining / fadeDuration
        return Float(sin(progress * .pi / 2))
    }
}

/// One "continue" card on the home page.
public struct ListeningResumeCandidate: Equatable, Sendable {
    public var space: ListeningSpace
    public var lastListenedAt: Date

    public init(space: ListeningSpace, lastListenedAt: Date) {
        self.space = space
        self.lastListenedAt = lastListenedAt
    }
}

public enum ListeningResumePolicy {
    /// Beyond this, a space's last session is not "something you were just
    /// listening to" any more and gets no card.
    public static let maximumAge: TimeInterval = 30 * 24 * 3600

    /// The cards to show, most recent first, at most one per space. The space
    /// that is playing right now gets no card: the player bar already is its
    /// "continue".
    public static func cards(
        from candidates: [ListeningResumeCandidate],
        playingSpace: ListeningSpace?,
        now: Date
    ) -> [ListeningResumeCandidate] {
        var seen = Set<ListeningSpace>()
        return candidates
            .filter { $0.space != playingSpace }
            .filter { now.timeIntervalSince($0.lastListenedAt) <= maximumAge }
            .sorted { $0.lastListenedAt > $1.lastListenedAt }
            .filter { seen.insert($0.space).inserted }
    }
}

/// A one-time note shown on the first launch after the navigation changed,
/// so people who knew where things were are told where they went.
public enum ListeningSpacesIntroductionPolicy {
    public static let seenKey = "primuse.listeningSpaces.introSeen.v1"

    /// Shown only to people who used the app before the change: a fresh
    /// install has no old habits to unlearn.
    public static func shouldShow(hasSeen: Bool, isExistingUser: Bool) -> Bool {
        !hasSeen && isExistingUser
    }
}
