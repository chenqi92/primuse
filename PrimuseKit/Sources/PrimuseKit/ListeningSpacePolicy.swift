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

/// Shuffle and repeat as one space has them set.
public struct ListeningPlayMode: Codable, Equatable, Sendable {
    public var shuffleEnabled: Bool
    public var repeatMode: RepeatMode

    public init(shuffleEnabled: Bool, repeatMode: RepeatMode) {
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
    }

    /// How a book is heard: chapter after chapter, once.
    public static let inOrder = ListeningPlayMode(shuffleEnabled: false, repeatMode: .off)
}

/// Shuffle and repeat belong to a way of listening, not to the player.
///
/// The player has one queue and one pair of switches, so without this a book
/// opened after shuffled music would play its chapters in random order — and,
/// once they ran out, shuffle would top the queue up from the library and the
/// book would end in the middle of someone else's album. A book therefore
/// starts in reading order, and music gets its own settings back when a music
/// queue replaces the book. A switch the listener touched while the book held
/// the queue is their latest word and is kept rather than overwritten; that
/// also covers a "shuffle" entry point that sets the switch just before it
/// installs its music queue.
///
/// Only a queue replacement moves the ledger: the item changing inside one
/// queue (music queued after the book's last chapter) leaves it alone, since
/// reshuffling a queue mid-way would replay what was already heard.
public struct ListeningPlayModeLedger: Codable, Equatable, Sendable {
    /// The space whose queue is installed. Radio never owns the queue.
    public private(set) var activeSpace: ListeningSpace = .music
    /// Music's own settings, kept while a book holds the queue.
    public private(set) var parkedMusicMode: ListeningPlayMode?
    public private(set) var shuffleChangedDuringBook = false
    public private(set) var repeatChangedDuringBook = false

    public init() {}

    /// A queue starting on an item of `owner` replaced the current one.
    /// - Parameter current: the switches as they are right now.
    /// - Returns: the switches the new queue should play with, or nil to
    ///   leave them as they are.
    public mutating func queueInstalled(
        ownedBy owner: ListeningSpace,
        current: ListeningPlayMode
    ) -> ListeningPlayMode? {
        switch (activeSpace, owner) {
        case (_, .radio), (.music, .music), (.radio, _):
            return nil
        case (.music, .spokenWord):
            activeSpace = .spokenWord
            parkedMusicMode = current
            shuffleChangedDuringBook = false
            repeatChangedDuringBook = false
            return current == .inOrder ? nil : .inOrder
        case (.spokenWord, .spokenWord):
            // Another book starts in order too; music stays parked.
            shuffleChangedDuringBook = false
            repeatChangedDuringBook = false
            return current == .inOrder ? nil : .inOrder
        case (.spokenWord, .music):
            let parked = parkedMusicMode ?? current
            let restored = ListeningPlayMode(
                shuffleEnabled: shuffleChangedDuringBook ? current.shuffleEnabled : parked.shuffleEnabled,
                repeatMode: repeatChangedDuringBook ? current.repeatMode : parked.repeatMode
            )
            activeSpace = .music
            parkedMusicMode = nil
            shuffleChangedDuringBook = false
            repeatChangedDuringBook = false
            return restored == current ? nil : restored
        }
    }

    /// The listener (or an entry point acting for them) flipped shuffle.
    public mutating func shuffleChanged() {
        if activeSpace == .spokenWord { shuffleChangedDuringBook = true }
    }

    /// The listener (or an entry point acting for them) changed repeat.
    public mutating func repeatChanged() {
        if activeSpace == .spokenWord { repeatChangedDuringBook = true }
    }
}

/// Which queue transitions may overlap two items.
public enum ListeningSpaceTransitionPolicy {
    /// Crossfading is a music effect. Between chapters it talks over the last
    /// sentence of one and the first of the next, and between a book and a
    /// song it blends two ways of listening that should simply change over.
    public static func allowsCrossfade(from outgoing: ListeningSpace, to incoming: ListeningSpace) -> Bool {
        outgoing == .music && incoming == .music
    }
}

/// Where shuffle may top up an exhausted queue from.
public enum ShuffleLibraryContinuationPolicy {
    /// Only music continues from the library, and only with music: a book
    /// ends when its chapters do, and a book's chapters are not songs to be
    /// shuffled in among an album.
    public static func continuesFromLibrary(currentSpace: ListeningSpace?) -> Bool {
        currentSpace == .music
    }
}
