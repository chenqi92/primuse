import Foundation

// MARK: - Song traits

/// What the listening features — intents, album picks and queue continuation —
/// read from a song. `Song` conforms (SongListeningTraits.swift); tests use
/// light stand-ins. Everything built on it is generic, so a whole-library pass
/// walks the library's own array off the main actor without copying songs.
public protocol ListeningSongTraits {
    var id: String { get }
    var albumID: String? { get }
    var albumTitle: String? { get }
    var artistName: String? { get }
    var albumArtistName: String? { get }
    var genre: String? { get }
    var year: Int? { get }
    var duration: TimeInterval { get }
    var dateAdded: Date { get }
    var trackNumber: Int? { get }
    var discNumber: Int? { get }
    var cueSheetPath: String? { get }
    var coverArtFileName: String? { get }
    var isPlayable: Bool { get }
}

/// Case-, width- and diacritic-insensitive comparison key shared by the
/// listening features (genre words, artist names, album titles).
public enum ListeningTextKey {
    public static func folded(_ text: String?) -> String {
        guard let text else { return "" }
        return text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Genre families

/// The broad families the listening features group genre tags into. A tag can
/// fall into more than one ("Pop Rock", "Electropop").
public enum ListeningGenreFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case pop
    case rock
    case electronic
    case classical
    case jazz
    case soundtrack
    case folk
    case hipHop
    case easyListening

    /// Quiet, slow-leaning families: evening, bedtime and focus lean on these.
    public static let gentle: Set<ListeningGenreFamily> = [.classical, .jazz, .folk, .easyListening]
    /// Loud, driving families: workouts lean on these, bedtime avoids them.
    public static let energetic: Set<ListeningGenreFamily> = [.rock, .electronic, .hipHop]
}

/// Maps free-form genre tags ("J-Pop", "華語流行", "Hip-Hop/Rap", "Original
/// Soundtrack") onto `ListeningGenreFamily`. Latin words must match whole
/// ("ost" must not match "Post-Rock"); CJK terms match anywhere in the tag.
public enum ListeningGenreClassifier {
    struct Vocabulary {
        var words: Set<String> = []
        var prefixes: [String] = []
        var phrases: [[String]] = []
        var cjk: [String] = []
    }

    static func vocabulary(_ family: ListeningGenreFamily) -> Vocabulary {
        switch family {
        case .pop:
            return Vocabulary(
                words: ["pop", "kpop", "jpop", "cpop", "mandopop", "cantopop", "britpop", "synthpop", "electropop", "dancepop"],
                cjk: ListeningGenreTerms.pop
            )
        case .rock:
            return Vocabulary(
                words: ["rock", "punk", "metal", "grunge", "emo", "hardcore", "alternative", "indie", "shoegaze"],
                cjk: ListeningGenreTerms.rock
            )
        case .electronic:
            return Vocabulary(
                words: ["edm", "house", "techno", "trance", "dubstep", "dnb", "dance", "disco", "idm", "synthwave", "breakbeat", "garage"],
                prefixes: ["electro"],
                phrases: [["drum", "and", "bass"], ["drum", "n", "bass"], ["drum", "bass"]],
                cjk: ListeningGenreTerms.electronic
            )
        case .classical:
            return Vocabulary(
                words: ["classical", "baroque", "symphony", "symphonic", "orchestral", "orchestra", "opera", "concerto", "chamber", "choral"],
                cjk: ListeningGenreTerms.classical
            )
        case .jazz:
            return Vocabulary(
                words: ["jazz", "swing", "bossa", "bebop", "blues", "fusion"],
                cjk: ListeningGenreTerms.jazz
            )
        case .soundtrack:
            return Vocabulary(
                words: ["soundtrack", "soundtracks", "ost", "score", "anime", "game", "musical", "film", "movie"],
                phrases: [["video", "game"], ["original", "soundtrack"]],
                cjk: ListeningGenreTerms.soundtrack
            )
        case .folk:
            return Vocabulary(
                words: ["folk", "country", "americana", "acoustic", "songwriter", "bluegrass"],
                cjk: ListeningGenreTerms.folk
            )
        case .hipHop:
            return Vocabulary(
                words: ["rap", "hiphop", "trap", "grime", "drill"],
                phrases: [["hip", "hop"]],
                cjk: ListeningGenreTerms.hipHop
            )
        case .easyListening:
            return Vocabulary(
                words: ["ambient", "lounge", "chill", "chillout", "instrumental", "relax", "relaxing", "meditation", "piano", "newage", "lofi", "downtempo"],
                phrases: [["new", "age"], ["easy", "listening"], ["lo", "fi"]],
                cjk: ListeningGenreTerms.easyListening
            )
        }
    }

    private static let vocabularies: [(ListeningGenreFamily, Vocabulary)] =
        ListeningGenreFamily.allCases.map { ($0, vocabulary($0)) }

    public static func families(for genre: String?) -> Set<ListeningGenreFamily> {
        let folded = ListeningTextKey.folded(genre)
        guard !folded.isEmpty else { return [] }
        let words = folded
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var result = Set<ListeningGenreFamily>()
        for (family, vocabulary) in vocabularies {
            if words.contains(where: { word in
                vocabulary.words.contains(word)
                    || vocabulary.prefixes.contains(where: { word.hasPrefix($0) })
            }) || vocabulary.phrases.contains(where: { containsPhrase($0, in: words) })
                || vocabulary.cjk.contains(where: { folded.contains($0) }) {
                result.insert(family)
            }
        }
        return result
    }

    private static func containsPhrase(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count)
        where words[start..<(start + phrase.count)].elementsEqual(phrase) {
            return true
        }
        return false
    }

    /// A whole-library pass sees the same few hundred tags again and again;
    /// classify each distinct tag once.
    public struct Memo {
        private var masks: [String: UInt16] = [:]

        public init() {}

        public mutating func families(for genre: String?) -> Set<ListeningGenreFamily> {
            ListeningGenreFamily.families(inMask: mask(for: genre))
        }

        /// The families as a bit mask (`ListeningGenreFamily.bit`), the form
        /// whole-library passes compare.
        public mutating func mask(for genre: String?) -> UInt16 {
            guard let genre, !genre.isEmpty else { return 0 }
            if let cached = masks[genre] { return cached }
            let mask = ListeningGenreFamily.mask(of: ListeningGenreClassifier.families(for: genre))
            masks[genre] = mask
            return mask
        }
    }
}

public extension ListeningGenreFamily {
    /// This family's bit in a family mask.
    var bit: UInt16 { UInt16(1) << UInt16(Self.allCases.firstIndex(of: self) ?? 0) }

    static func mask<Families: Sequence>(of families: Families) -> UInt16 where Families.Element == ListeningGenreFamily {
        families.reduce(0) { $0 | $1.bit }
    }

    static func families(inMask mask: UInt16) -> Set<ListeningGenreFamily> {
        Set(allCases.filter { mask & $0.bit != 0 })
    }
}

// MARK: - Intent model

public enum ListeningDecade: Int, CaseIterable, Codable, Hashable, Sendable {
    case eighties = 1980
    case nineties = 1990
    case twoThousands = 2000
    case twentyTens = 2010

    public var years: ClosedRange<Int> { rawValue...(rawValue + 9) }
}

/// Listening habits that are not about what a song is but about when it was
/// heard or added.
public enum ListeningHabit: String, Codable, Hashable, Sendable {
    /// "Pick up where I left off": the music session the player remembers.
    case resume
    /// "Anything": the whole music library, shuffled.
    case anything
    /// Songs not heard for a long while (or never, once there is a history).
    case longUnplayed
    /// Songs added recently.
    case newlyAdded
}

/// Which songs an intent plays. Every constraint that is set must hold.
public struct ListeningIntentRule: Codable, Hashable, Sendable {
    /// The song's genre falls into at least one of these. Empty: any genre.
    public var genreFamilies: Set<ListeningGenreFamily>
    /// The song's genre falls into none of these.
    public var excludedGenreFamilies: Set<ListeningGenreFamily>
    public var years: ClosedRange<Int>?
    /// Seconds.
    public var duration: ClosedRange<Double>?
    public var addedWithinDays: Int?
    /// Never played, or last played at least this many days ago.
    public var notPlayedForDays: Int?

    public init(
        genreFamilies: Set<ListeningGenreFamily> = [],
        excludedGenreFamilies: Set<ListeningGenreFamily> = [],
        years: ClosedRange<Int>? = nil,
        duration: ClosedRange<Double>? = nil,
        addedWithinDays: Int? = nil,
        notPlayedForDays: Int? = nil
    ) {
        self.genreFamilies = genreFamilies
        self.excludedGenreFamilies = excludedGenreFamilies
        self.years = years
        self.duration = duration
        self.addedWithinDays = addedWithinDays
        self.notPlayedForDays = notPlayedForDays
    }

    /// Needs a play history to mean anything.
    public var dependsOnHistory: Bool { notPlayedForDays != nil }
}

/// How an intent starts playing.
public struct ListeningIntentPlayback: Codable, Hashable, Sendable {
    /// Songs in the first queue.
    public var songLimit: Int
    public var shuffles: Bool
    /// Keep going with similar songs once the queue runs out (#166 policy).
    public var continuesWithSimilarSongs: Bool
    /// A sleep timer the intent sets as it starts (TV "night listening").
    public var sleepTimerMinutes: Int?
    /// Dim into the resting overlay once playing (TV "night listening").
    public var startsResting: Bool

    public init(
        songLimit: Int = 50,
        shuffles: Bool = true,
        continuesWithSimilarSongs: Bool = true,
        sleepTimerMinutes: Int? = nil,
        startsResting: Bool = false
    ) {
        self.songLimit = songLimit
        self.shuffles = shuffles
        self.continuesWithSimilarSongs = continuesWithSimilarSongs
        self.sleepTimerMinutes = sleepTimerMinutes
        self.startsResting = startsResting
    }

    public static let standard = ListeningIntentPlayback()
}

/// "What do you feel like listening to": a name, an icon, a rule for picking
/// songs and how to play them. Built-ins light up when the library has enough
/// songs for them; a smart playlist can be pinned as one; other surfaces (the
/// Apple TV scenes) compose their own from the same rule vocabulary.
public struct ListeningIntent: Codable, Hashable, Identifiable, Sendable {
    public enum Category: String, Codable, Hashable, Sendable {
        case genre, era, mood, habit, smartPlaylist, scene
    }

    public enum Source: Codable, Hashable, Sendable {
        case builtIn(BuiltInListeningIntent)
        /// The songs are whatever the smart playlist matches (resolved by the
        /// app's smart playlist engine), so `rule` is nil.
        case smartPlaylist(id: String)
        /// A composite defined by a surface, e.g. a TV home scene.
        case scene(id: String)
    }

    public var id: String
    public var source: Source
    public var category: Category
    public var symbolName: String
    /// Localization key of the title. Nil for a pinned smart playlist, whose
    /// title is the playlist's name.
    public var titleKey: String?
    public var rule: ListeningIntentRule?
    public var habit: ListeningHabit?
    public var playback: ListeningIntentPlayback

    public init(
        id: String,
        source: Source,
        category: Category,
        symbolName: String,
        titleKey: String?,
        rule: ListeningIntentRule?,
        habit: ListeningHabit? = nil,
        playback: ListeningIntentPlayback = .standard
    ) {
        self.id = id
        self.source = source
        self.category = category
        self.symbolName = symbolName
        self.titleKey = titleKey
        self.rule = rule
        self.habit = habit
        self.playback = playback
    }

    public static func builtIn(_ intent: BuiltInListeningIntent) -> ListeningIntent {
        intent.intent
    }

    public static func pinnedSmartPlaylist(id playlistID: String, symbolName: String = "music.note.list") -> ListeningIntent {
        ListeningIntent(
            id: "smart:" + playlistID,
            source: .smartPlaylist(id: playlistID),
            category: .smartPlaylist,
            symbolName: symbolName,
            titleKey: nil,
            rule: nil
        )
    }

    public static func scene(
        id sceneID: String,
        symbolName: String,
        titleKey: String,
        rule: ListeningIntentRule,
        playback: ListeningIntentPlayback = .standard
    ) -> ListeningIntent {
        ListeningIntent(
            id: "scene:" + sceneID,
            source: .scene(id: sceneID),
            category: .scene,
            symbolName: symbolName,
            titleKey: titleKey,
            rule: rule,
            playback: playback
        )
    }

    /// All built-ins in catalog order.
    public static let builtIns: [ListeningIntent] = BuiltInListeningIntent.allCases.map(\.intent)
}

public enum BuiltInListeningIntent: String, CaseIterable, Codable, Hashable, Sendable {
    // Genres
    case pop, rock, electronic, classical, jazz, soundtrack, folk, hipHop, easyListening
    // Eras
    case eighties, nineties, twoThousands, twentyTens
    // Moods: no tempo or energy data, so genre + length heuristics.
    case calm, focus, workout, bedtime
    // Habits
    case resume, anything, longUnplayed, newlyAdded

    /// Localization key of the title, e.g. `listening_intent_pop`.
    public var titleKey: String { "listening_intent_" + rawValue }

    public var category: ListeningIntent.Category {
        switch self {
        case .pop, .rock, .electronic, .classical, .jazz, .soundtrack, .folk, .hipHop, .easyListening: .genre
        case .eighties, .nineties, .twoThousands, .twentyTens: .era
        case .calm, .focus, .workout, .bedtime: .mood
        case .resume, .anything, .longUnplayed, .newlyAdded: .habit
        }
    }

    public var symbolName: String {
        switch self {
        case .pop: "music.mic"
        case .rock: "guitars"
        case .electronic: "waveform"
        case .classical: "music.quarternote.3"
        case .jazz: "music.note"
        case .soundtrack: "film"
        case .folk: "leaf"
        case .hipHop: "beats.headphones"
        case .easyListening: "cloud"
        case .eighties, .nineties, .twoThousands, .twentyTens: "calendar"
        case .calm: "moon.stars"
        case .focus: "brain.head.profile"
        case .workout: "figure.run"
        case .bedtime: "bed.double"
        case .resume: "arrow.uturn.forward"
        case .anything: "shuffle"
        case .longUnplayed: "hourglass"
        case .newlyAdded: "sparkles"
        }
    }

    public var genreFamily: ListeningGenreFamily? {
        switch self {
        case .pop: .pop
        case .rock: .rock
        case .electronic: .electronic
        case .classical: .classical
        case .jazz: .jazz
        case .soundtrack: .soundtrack
        case .folk: .folk
        case .hipHop: .hipHop
        case .easyListening: .easyListening
        default: nil
        }
    }

    public var decade: ListeningDecade? {
        switch self {
        case .eighties: .eighties
        case .nineties: .nineties
        case .twoThousands: .twoThousands
        case .twentyTens: .twentyTens
        default: nil
        }
    }

    public var habit: ListeningHabit? {
        switch self {
        case .resume: .resume
        case .anything: .anything
        case .longUnplayed: .longUnplayed
        case .newlyAdded: .newlyAdded
        default: nil
        }
    }

    /// Nil for "resume", which plays the player's remembered music session.
    public var rule: ListeningIntentRule? {
        if let genreFamily { return ListeningIntentRule(genreFamilies: [genreFamily]) }
        if let decade { return ListeningIntentRule(years: decade.years) }
        switch self {
        case .calm:
            return ListeningIntentRule(
                genreFamilies: ListeningGenreFamily.gentle,
                excludedGenreFamilies: ListeningGenreFamily.energetic,
                duration: 120...900
            )
        case .focus:
            return ListeningIntentRule(
                genreFamilies: [.classical, .easyListening, .soundtrack, .jazz],
                excludedGenreFamilies: [.hipHop],
                duration: 150...1_200
            )
        case .workout:
            return ListeningIntentRule(
                genreFamilies: ListeningGenreFamily.energetic.union([.pop]),
                excludedGenreFamilies: [.classical, .easyListening],
                duration: 120...360
            )
        case .bedtime:
            return ListeningIntentRule(
                genreFamilies: [.classical, .easyListening, .jazz, .folk],
                excludedGenreFamilies: ListeningGenreFamily.energetic,
                duration: 120...900
            )
        case .anything:
            return ListeningIntentRule()
        case .longUnplayed:
            return ListeningIntentRule(notPlayedForDays: 90)
        case .newlyAdded:
            return ListeningIntentRule(addedWithinDays: 30)
        default:
            return nil
        }
    }

    public var playback: ListeningIntentPlayback {
        switch self {
        case .resume: ListeningIntentPlayback(shuffles: false)
        case .bedtime: ListeningIntentPlayback(songLimit: 30)
        default: .standard
        }
    }

    public var intent: ListeningIntent {
        ListeningIntent(
            id: "builtin:" + rawValue,
            source: .builtIn(self),
            category: category,
            symbolName: symbolName,
            titleKey: titleKey,
            rule: rule,
            habit: habit,
            playback: playback
        )
    }
}

// MARK: - History

/// Per-song play history the rules read: last play and play count.
public struct ListeningHistoryIndex: Sendable {
    public let now: Date
    public private(set) var lastPlayedAt: [String: Date] = [:]
    public private(set) var playCounts: [String: Int] = [:]
    public let totalPlays: Int

    public init(events: [HomeListeningEvent], now: Date) {
        self.now = now
        var total = 0
        for event in events where event.playedAt <= now {
            total += 1
            playCounts[event.songID, default: 0] += 1
            if let last = lastPlayedAt[event.songID], last >= event.playedAt { continue }
            lastPlayedAt[event.songID] = event.playedAt
        }
        totalPlays = total
    }

    public static func empty(now: Date) -> ListeningHistoryIndex {
        ListeningHistoryIndex(events: [], now: now)
    }
}

// MARK: - Matching, lighting, queues

/// How many songs each intent has in this library, computed in one pass.
public struct ListeningIntentAvailability: Equatable, Sendable {
    public var songCounts: [String: Int]
    /// The library generation (`musicSongsRevision`) the counts belong to.
    public var libraryGeneration: UInt64
    public var computedAt: Date

    public init(songCounts: [String: Int], libraryGeneration: UInt64, computedAt: Date) {
        self.songCounts = songCounts
        self.libraryGeneration = libraryGeneration
        self.computedAt = computedAt
    }

    public func songCount(for intent: ListeningIntent) -> Int {
        songCounts[intent.id] ?? 0
    }

    /// Lit when there are enough songs for a proper queue. "Resume" is lit by
    /// the caller (it depends on the player's memory, not the library).
    public func isLit(_ intent: ListeningIntent) -> Bool {
        if intent.habit == .resume { return false }
        return songCount(for: intent) >= ListeningIntentEngine.minimumSongCount
    }

    /// Lit intents, strongest first (most songs), ties in catalog order.
    public func litIntents(_ intents: [ListeningIntent], limit: Int = .max) -> [ListeningIntent] {
        let lit = intents.enumerated().filter { isLit($0.element) }
        return lit.sorted { lhs, rhs in
            let left = songCount(for: lhs.element)
            let right = songCount(for: rhs.element)
            if left != right { return left > right }
            return lhs.offset < rhs.offset
        }
        .prefix(max(0, limit))
        .map(\.element)
    }
}

public enum ListeningIntentEngine {
    /// Fewer matching songs than this and an intent stays dark.
    public static let minimumSongCount = 12
    /// "Long unplayed" needs this many plays on record before "not played"
    /// means anything.
    public static let minimumHistoryForUnplayed = 30
    /// Lighting is recomputed at most this often while the library churns
    /// (the same cadence as other whole-library derivations).
    public static let refreshInterval: TimeInterval = 300

    /// Recompute when the library moved on and the last pass is old enough,
    /// or when there has never been one.
    public static func shouldRefresh(
        last: ListeningIntentAvailability?,
        libraryGeneration: UInt64,
        now: Date,
        interval: TimeInterval = refreshInterval
    ) -> Bool {
        guard let last else { return true }
        guard last.libraryGeneration != libraryGeneration else { return false }
        return now.timeIntervalSince(last.computedAt) >= interval
    }

    public static func matches<Song: ListeningSongTraits>(
        _ song: Song,
        rule: ListeningIntentRule,
        families: Set<ListeningGenreFamily>,
        history: ListeningHistoryIndex
    ) -> Bool {
        CompiledRule(rule, now: history.now)
            .matches(song, mask: ListeningGenreFamily.mask(of: families), history: history)
    }

    /// A rule with its sets turned into masks and its day counts into dates,
    /// so checking it against a song does no allocation.
    struct CompiledRule {
        let include: UInt16
        let exclude: UInt16
        let years: ClosedRange<Int>?
        let duration: ClosedRange<Double>?
        let addedAfter: Date?
        let notPlayedSince: Date?

        init(_ rule: ListeningIntentRule, now: Date) {
            include = ListeningGenreFamily.mask(of: rule.genreFamilies)
            exclude = ListeningGenreFamily.mask(of: rule.excludedGenreFamilies)
            years = rule.years
            duration = rule.duration
            addedAfter = rule.addedWithinDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
            notPlayedSince = rule.notPlayedForDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        }

        func matches<Song: ListeningSongTraits>(_ song: Song, mask: UInt16, history: ListeningHistoryIndex) -> Bool {
            if include != 0, mask & include == 0 { return false }
            if exclude != 0, mask & exclude != 0 { return false }
            if let years {
                guard let year = song.year, years.contains(year) else { return false }
            }
            if let duration {
                let length = song.duration
                guard length > 0, duration.contains(length) else { return false }
            }
            if let addedAfter, song.dateAdded < addedAfter { return false }
            if let notPlayedSince {
                guard history.totalPlays >= minimumHistoryForUnplayed else { return false }
                if let last = history.lastPlayedAt[song.id], last > notPlayedSince { return false }
            }
            return song.isPlayable
        }
    }

    /// Counts every rule-based intent in one pass over the library. Nil when
    /// cancelled. Intents without a rule (resume, smart playlists) get no count.
    public static func availability<Songs: Collection>(
        songs: Songs,
        intents: [ListeningIntent],
        history: ListeningHistoryIndex,
        libraryGeneration: UInt64,
        isCancelled: () -> Bool = { false }
    ) -> ListeningIntentAvailability? where Songs.Element: ListeningSongTraits {
        let ruled = intents.compactMap { intent in
            intent.rule.map { CompiledRule($0, now: history.now) }.map { (intent.id, $0) }
        }
        var tallies = Array(repeating: 0, count: ruled.count)
        var memo = ListeningGenreClassifier.Memo()
        var position = 0
        for song in songs {
            if position.isMultiple(of: 1_024), isCancelled() { return nil }
            position += 1
            let mask = memo.mask(for: song.genre)
            for slot in ruled.indices where ruled[slot].1.matches(song, mask: mask, history: history) {
                tallies[slot] += 1
            }
        }
        var counts: [String: Int] = [:]
        for slot in ruled.indices where tallies[slot] > 0 { counts[ruled[slot].0, default: 0] += tallies[slot] }
        return ListeningIntentAvailability(
            songCounts: counts,
            libraryGeneration: libraryGeneration,
            computedAt: history.now
        )
    }

    /// The first queue for a rule-based intent: up to `playback.songLimit`
    /// matching songs, a random sample stable for a given `seed`. Habits that
    /// are about time ("long unplayed") prefer the longest-unheard songs.
    public static func queueSongIDs<Songs: Collection>(
        for intent: ListeningIntent,
        songs: Songs,
        history: ListeningHistoryIndex,
        seed: UInt64,
        isCancelled: () -> Bool = { false }
    ) -> [String] where Songs.Element: ListeningSongTraits {
        guard let rule = intent.rule.map({ CompiledRule($0, now: history.now) }) else { return [] }
        let limit = max(0, intent.playback.songLimit)
        guard limit > 0 else { return [] }
        var generator = ListeningSeededGenerator(seed: seed)
        var memo = ListeningGenreClassifier.Memo()
        // Reservoir sampling keeps memory at `limit` whatever the library size.
        var sample: [(id: String, key: Double)] = []
        sample.reserveCapacity(limit)
        var seen = 0
        for song in songs {
            if seen.isMultiple(of: 1_024), isCancelled() { return [] }
            guard rule.matches(song, mask: memo.mask(for: song.genre), history: history) else { continue }
            seen += 1
            var key = Double(generator.next() >> 11) / Double(1 << 53)
            if intent.habit == .longUnplayed {
                // Never played first, then the longest ago; randomness only
                // breaks ties within a day.
                let age = history.lastPlayedAt[song.id].map { history.now.timeIntervalSince($0) / 86_400 } ?? 100_000
                key = age + key
            }
            if sample.count < limit {
                sample.append((song.id, key))
            } else if let minimum = sample.indices.min(by: { sample[$0].key < sample[$1].key }),
                      key > sample[minimum].key {
                sample[minimum] = (song.id, key)
            }
        }
        sample.sort { $0.key > $1.key }
        var ids = sample.map(\.id)
        if intent.playback.shuffles, intent.habit != .longUnplayed {
            ids.shuffle(using: &generator)
        }
        return ids
    }
}

/// Small deterministic generator (SplitMix64) for "stable within a day"
/// choices. Not for anything security related.
public struct ListeningSeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A stable 64-bit seed from text (FNV-1a), e.g. an album ID plus a day.
    public static func seed(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A value in 0..<1 that depends only on `text`.
    public static func unitNoise(_ text: String) -> Double {
        var generator = ListeningSeededGenerator(seed: seed(text))
        return Double(generator.next() >> 11) / Double(1 << 53)
    }
}

/// CJK genre words, matched anywhere in a folded genre tag. Data matched
/// against tags written by taggers and servers, never shown as UI copy.
enum ListeningGenreTerms {
    static let pop: [String] = ["流行", "国语", "國語", "粤语", "粵語", "华语", "華語", "港台", "ポップ", "歌谣", "歌謠"]
    static let rock: [String] = ["摇滚", "搖滾", "金属", "金屬", "朋克", "ロック"]
    static let electronic: [String] = ["电子", "電子", "舞曲", "エレクトロ", "テクノ"]
    static let classical: [String] = ["古典", "交响", "交響", "歌剧", "歌劇", "室内乐", "室內樂", "クラシック"]
    static let jazz: [String] = ["爵士", "蓝调", "藍調", "ジャズ", "ブルース"]
    static let soundtrack: [String] = ["原声", "原聲", "影视", "影視", "电影", "電影", "动漫", "動漫", "动画", "動畫", "游戏", "遊戲", "配乐", "配樂", "サウンドトラック", "アニメ"]
    static let folk: [String] = ["民谣", "民謠", "乡村", "鄉村", "民歌", "フォーク"]
    static let hipHop: [String] = ["说唱", "說唱", "嘻哈", "饶舌", "饒舌", "ヒップホップ"]
    static let easyListening: [String] = ["轻音乐", "輕音樂", "纯音乐", "純音樂", "新世纪", "新世紀", "器乐", "器樂", "钢琴", "鋼琴", "冥想", "放松", "放鬆", "ヒーリング"]
}
