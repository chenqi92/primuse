import Foundation

/// Suggestions offered while something plays, as a small prompt that never
/// blocks the screen: the listener can act on it, dismiss it or ignore it and
/// it goes away on its own.
public enum SmartNudgeKind: String, Codable, CaseIterable, Sendable {
    /// Played a lot and not in favourites yet.
    case addToFavorites
    /// Played on repeat and already a favourite: offer more like it.
    case playSimilar
    /// A favourite the listener keeps skipping.
    case removeFromFavorites
    /// The queue is about to run out: offer recommendations to carry on.
    case continueWithRecommendations
    /// Listening late into the night without a timer.
    case sleepTimer
    /// The last chapter of a book is ending and there is music the listener
    /// left for it: carry on with that music afterwards.
    case backToMusic
    /// A long file with no album or artist playing as music: ask whether it
    /// is spoken word, since guessing wrong would bury it among songs.
    case classifyAsSpokenWord
}

public struct SmartNudgeContext: Equatable, Sendable {
    public var songID: String?
    public var isLiked: Bool
    /// Plays of this song in the last seven days, the current one included.
    public var playsInLastWeek: Int
    /// How many times in a row this song has just been played.
    public var consecutivePlays: Int
    /// Early skips of this song in the last thirty days.
    public var recentEarlySkips: Int
    /// How far through the current song, 0…1.
    public var progress: Double
    public var isLastInQueue: Bool
    public var repeatsQueue: Bool
    public var isLiveRadio: Bool
    public var isSpokenWord: Bool
    public var isMedley: Bool
    public var sleepTimerActive: Bool
    /// Minutes of uninterrupted listening up to now.
    public var continuousListeningMinutes: Double
    public var hour: Int
    /// A music queue was set aside for the book now playing.
    public var hasRememberedMusic: Bool
    /// Long, no album and no artist, and nobody has classified it by hand.
    public var isLongUntagged: Bool

    public init(
        songID: String?,
        isLiked: Bool = false,
        playsInLastWeek: Int = 0,
        consecutivePlays: Int = 0,
        recentEarlySkips: Int = 0,
        progress: Double = 0,
        isLastInQueue: Bool = false,
        repeatsQueue: Bool = false,
        isLiveRadio: Bool = false,
        isSpokenWord: Bool = false,
        isMedley: Bool = false,
        sleepTimerActive: Bool = false,
        continuousListeningMinutes: Double = 0,
        hour: Int = 12,
        hasRememberedMusic: Bool = false,
        isLongUntagged: Bool = false
    ) {
        self.songID = songID
        self.isLiked = isLiked
        self.playsInLastWeek = playsInLastWeek
        self.consecutivePlays = consecutivePlays
        self.recentEarlySkips = recentEarlySkips
        self.progress = progress
        self.isLastInQueue = isLastInQueue
        self.repeatsQueue = repeatsQueue
        self.isLiveRadio = isLiveRadio
        self.isSpokenWord = isSpokenWord
        self.isMedley = isMedley
        self.sleepTimerActive = sleepTimerActive
        self.continuousListeningMinutes = continuousListeningMinutes
        self.hour = hour
        self.hasRememberedMusic = hasRememberedMusic
        self.isLongUntagged = isLongUntagged
    }
}

/// What the listener did with earlier prompts. Kept so a prompt that was
/// turned down is not offered again the next day.
public struct SmartNudgeHistory: Codable, Equatable, Sendable {
    public var lastShownAt: Date?
    /// "kind|songID" (or just "kind" for song-independent prompts) → when it
    /// was last dismissed or accepted.
    public var answeredAt: [String: Date]
    /// Dismissals in a row per kind; reset when that kind is accepted.
    public var consecutiveDismissals: [String: Int]
    /// Per kind, the time before which it is not offered at all.
    public var snoozedUntil: [String: Date]

    public init(
        lastShownAt: Date? = nil,
        answeredAt: [String: Date] = [:],
        consecutiveDismissals: [String: Int] = [:],
        snoozedUntil: [String: Date] = [:]
    ) {
        self.lastShownAt = lastShownAt
        self.answeredAt = answeredAt
        self.consecutiveDismissals = consecutiveDismissals
        self.snoozedUntil = snoozedUntil
    }
}

public enum SmartNudgePolicy {
    /// Never two prompts closer than this: a prompt is an interruption.
    public static let minimumInterval: TimeInterval = 10 * 60
    /// A prompt about one song that was answered is not repeated for a month.
    public static let songCooldown: TimeInterval = 30 * 24 * 3600
    /// Song-independent prompts (sleep timer) come back the next night.
    public static let generalCooldown: TimeInterval = 20 * 3600
    /// Turned down this many times in a row, a kind rests for two weeks.
    public static let dismissalsBeforeSnooze = 3
    public static let snoozeDuration: TimeInterval = 14 * 24 * 3600
    /// How long a prompt stays on screen when ignored.
    public static let displayDuration: TimeInterval = 9

    public static let favoritePlayThreshold = 5
    public static let favoriteRepeatThreshold = 3
    public static let similarRepeatThreshold = 2
    public static let skipThreshold = 3
    public static let lateNightListeningMinutes: Double = 45
    /// How far into the last chapter "back to music" is offered.
    public static let bookEndingProgress = 0.8
    /// Shorter than this, an untagged file is more likely a song or a demo
    /// than a chapter or an episode.
    public static let longUntaggedMinimumDuration: TimeInterval = 20 * 60

    /// Whether an item looks like spoken word that was never tagged as such.
    public static func isLongUntagged(duration: TimeInterval, albumTitle: String?, artistName: String?) -> Bool {
        func isBlank(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        }
        return duration >= longUntaggedMinimumDuration && isBlank(albumTitle) && isBlank(artistName)
    }

    public static func key(kind: SmartNudgeKind, songID: String?) -> String {
        switch kind {
        case .sleepTimer, .continueWithRecommendations, .backToMusic:
            return kind.rawValue
        default:
            return kind.rawValue + "|" + (songID ?? "")
        }
    }

    static func isLateNight(hour: Int) -> Bool { hour >= 23 || hour < 5 }

    /// The prompt to show now, or nil.
    public static func nudge(
        for context: SmartNudgeContext,
        history: SmartNudgeHistory,
        enabledKinds: Set<SmartNudgeKind> = Set(SmartNudgeKind.allCases),
        now: Date
    ) -> SmartNudgeKind? {
        // Medleys and live radio are not "this song" listening; spoken word
        // has its own rhythm and no favourites semantics.
        guard !context.isMedley, !context.isLiveRadio else { return nil }
        if let last = history.lastShownAt, now.timeIntervalSince(last) < minimumInterval {
            return nil
        }

        for kind in candidates(for: context) where enabledKinds.contains(kind) {
            if let until = history.snoozedUntil[kind.rawValue], until > now { continue }
            let key = key(kind: kind, songID: context.songID)
            if let answered = history.answeredAt[key] {
                let cooldown = key == kind.rawValue ? generalCooldown : songCooldown
                if now.timeIntervalSince(answered) < cooldown { continue }
            }
            return kind
        }
        return nil
    }

    /// Kinds whose conditions hold, most time-sensitive first.
    static func candidates(for context: SmartNudgeContext) -> [SmartNudgeKind] {
        var result: [SmartNudgeKind] = []
        let hasSong = context.songID != nil

        if hasSong, context.isLastInQueue, !context.repeatsQueue,
           !context.isSpokenWord, context.progress >= 0.5 {
            result.append(.continueWithRecommendations)
        }
        if !context.sleepTimerActive, isLateNight(hour: context.hour),
           context.continuousListeningMinutes >= lateNightListeningMinutes {
            result.append(.sleepTimer)
        }
        if hasSong, context.isSpokenWord, context.hasRememberedMusic, context.isLastInQueue,
           !context.repeatsQueue, context.progress >= bookEndingProgress {
            result.append(.backToMusic)
        }
        guard hasSong, !context.isSpokenWord else { return result }

        if context.isLongUntagged, context.progress >= 0.05 {
            result.append(.classifyAsSpokenWord)
        }

        if context.isLiked, context.recentEarlySkips >= skipThreshold, context.progress < 0.15 {
            result.append(.removeFromFavorites)
        }
        if !context.isLiked, context.progress >= 0.5,
           context.playsInLastWeek >= favoritePlayThreshold
            || context.consecutivePlays >= favoriteRepeatThreshold {
            result.append(.addToFavorites)
        }
        if context.isLiked, context.consecutivePlays >= similarRepeatThreshold,
           context.progress >= 0.5 {
            result.append(.playSimilar)
        }
        return result
    }

    /// Records that a prompt was shown.
    public static func recordingShown(_ history: SmartNudgeHistory, at now: Date) -> SmartNudgeHistory {
        var updated = history
        updated.lastShownAt = now
        return updated
    }

    /// Records the answer. `accepted` false covers both the close button and
    /// the prompt timing out: either way the listener did not want it.
    public static func recordingAnswer(
        _ history: SmartNudgeHistory,
        kind: SmartNudgeKind,
        songID: String?,
        accepted: Bool,
        at now: Date
    ) -> SmartNudgeHistory {
        var updated = history
        updated.answeredAt[key(kind: kind, songID: songID)] = now
        if accepted {
            updated.consecutiveDismissals[kind.rawValue] = 0
        } else {
            let count = (updated.consecutiveDismissals[kind.rawValue] ?? 0) + 1
            if count >= dismissalsBeforeSnooze {
                updated.snoozedUntil[kind.rawValue] = now.addingTimeInterval(snoozeDuration)
                updated.consecutiveDismissals[kind.rawValue] = 0
            } else {
                updated.consecutiveDismissals[kind.rawValue] = count
            }
        }
        // Keep the answer map from growing without bound: entries past their
        // cooldown no longer change any decision.
        updated.answeredAt = updated.answeredAt.filter {
            now.timeIntervalSince($0.value) < songCooldown
        }
        return updated
    }
}

/// Early skips: the listener moved on within the opening of a song. Counted
/// per song so a favourite that is always skipped can be noticed.
public enum SmartNudgeSkipPolicy {
    public static let earlySkipWindow: TimeInterval = 30
    public static let retention: TimeInterval = 30 * 24 * 3600
    public static let maximumTrackedSongs = 500

    public static func isEarlySkip(listened: TimeInterval, duration: TimeInterval) -> Bool {
        guard listened.isFinite, listened >= 0 else { return false }
        // A very short song can finish inside the window; that is not a skip.
        if duration > 0, listened >= duration * 0.8 { return false }
        return listened < earlySkipWindow
    }

    /// Adds a skip and drops what is past retention.
    public static func recording(
        skipOf songID: String,
        at now: Date,
        into skips: [String: [Date]]
    ) -> [String: [Date]] {
        var updated = pruned(skips, now: now)
        updated[songID, default: []].append(now)
        if updated.count > maximumTrackedSongs {
            let stalest = updated
                .map { ($0.key, $0.value.max() ?? .distantPast) }
                .sorted { $0.1 < $1.1 }
                .prefix(updated.count - maximumTrackedSongs)
            for (id, _) in stalest { updated.removeValue(forKey: id) }
        }
        return updated
    }

    public static func pruned(_ skips: [String: [Date]], now: Date) -> [String: [Date]] {
        skips.compactMapValues { dates in
            let kept = dates.filter { now.timeIntervalSince($0) < retention }
            return kept.isEmpty ? nil : kept
        }
    }

    public static func recentCount(of songID: String, in skips: [String: [Date]], now: Date) -> Int {
        (skips[songID] ?? []).filter { now.timeIntervalSince($0) < retention }.count
    }
}
