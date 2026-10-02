import Foundation

/// Apple TV home scenes: what is going on in the living room rather than what
/// kind of music it is. Each one is a `ListeningIntent` built from the same
/// rule vocabulary (no tempo or loudness data, so genre families and track
/// length stand in for "mid-tempo" and "slow"), lit by the same one-pass count.
public enum ListeningScene: String, CaseIterable, Codable, Hashable, Sendable {
    /// Guests over: easy pop and light music, nothing loud.
    case guests
    /// Unwinding: folk and jazz.
    case leisure
    /// Late at night: slow and soft; stops on its own after an hour.
    case night
    /// Focus: instrumental and classical, no vocals-first genres.
    case focus
    /// Party: electronic, dance and upbeat pop, shuffled.
    case party

    /// Cards on the home row at most.
    public static let shelfLimit = 5
    /// The sleep timer "night listening" sets as it starts.
    public static let nightSleepTimerMinutes = 60

    /// Localization key of the name, e.g. `listening_scene_night`.
    public var titleKey: String { "listening_scene_" + rawValue }
    /// Localization key of the one-line description under the name.
    public var subtitleKey: String { "listening_scene_" + rawValue + "_hint" }

    public var symbolName: String {
        switch self {
        case .guests: "person.2.wave.2"
        case .leisure: "sofa"
        case .night: "moon.stars"
        case .focus: "book"
        case .party: "party.popper"
        }
    }

    public var rule: ListeningIntentRule {
        switch self {
        case .guests:
            return ListeningIntentRule(
                genreFamilies: [.pop, .easyListening],
                excludedGenreFamilies: [.rock, .hipHop],
                duration: 150...360
            )
        case .leisure:
            return ListeningIntentRule(
                genreFamilies: [.folk, .jazz],
                excludedGenreFamilies: [.hipHop],
                duration: 120...600
            )
        case .night:
            return ListeningIntentRule(
                genreFamilies: ListeningGenreFamily.gentle,
                excludedGenreFamilies: ListeningGenreFamily.energetic,
                duration: 120...900
            )
        case .focus:
            return ListeningIntentRule(
                genreFamilies: [.classical, .easyListening, .soundtrack],
                excludedGenreFamilies: [.pop, .rock, .hipHop],
                duration: 150...1_200
            )
        case .party:
            return ListeningIntentRule(
                genreFamilies: [.electronic, .pop, .hipHop],
                excludedGenreFamilies: [.classical, .easyListening],
                duration: 120...420
            )
        }
    }

    public var playback: ListeningIntentPlayback {
        switch self {
        case .night:
            ListeningIntentPlayback(
                songLimit: 30,
                sleepTimerMinutes: Self.nightSleepTimerMinutes,
                startsResting: true
            )
        default:
            .standard
        }
    }

    /// Party keeps the shuffle switch on; the others start in the (already
    /// random) order they were picked in.
    public var turnsShuffleOn: Bool { self == .party }

    public var intent: ListeningIntent {
        .scene(id: rawValue, symbolName: symbolName, titleKey: titleKey, rule: rule, playback: playback)
    }

    /// Every scene's intent, for the one-pass lighting count.
    public static let intents: [ListeningIntent] = allCases.map(\.intent)

    public init?(intentID: String) {
        guard intentID.hasPrefix("scene:") else { return nil }
        self.init(rawValue: String(intentID.dropFirst("scene:".count)))
    }

    /// The scenes the library lights up, in their fixed order (a remote's
    /// row is easier to learn when it does not reshuffle), with song counts.
    public static func shelf(
        availability: ListeningIntentAvailability?,
        limit: Int = shelfLimit
    ) -> [ListeningSceneEntry] {
        guard let availability, limit > 0 else { return [] }
        return allCases
            .filter { availability.isLit($0.intent) }
            .prefix(limit)
            .map { ListeningSceneEntry(scene: $0, songCount: availability.songCount(for: $0.intent)) }
    }
}

/// A lit scene on the TV home row.
public struct ListeningSceneEntry: Equatable, Identifiable, Sendable {
    public let scene: ListeningScene
    public let songCount: Int

    public var id: String { scene.rawValue }

    public init(scene: ListeningScene, songCount: Int) {
        self.scene = scene
        self.songCount = songCount
    }
}
