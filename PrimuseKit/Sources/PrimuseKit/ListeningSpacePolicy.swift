import Foundation

/// The ways of listening the app offers side by side. Each keeps its
/// own playback memory and its own rules for "continue":
/// - music plays a queue and resumes that queue;
/// - radio plays a live stream and resumes by tuning back in;
/// - spoken word plays a book and resumes each book where it was left;
/// - podcasts play subscribed episodes and resume each episode where it was
///   left. On the player they behave like spoken word (in order, skip
///   buttons, their own speed); only the library and home treat them apart.
public enum ListeningSpace: String, CaseIterable, Codable, Hashable, Sendable {
    case music
    case radio
    case spokenWord
    case podcast

    /// The space whose queue rules apply: an episode is heard the way a book
    /// chapter is.
    public var playbackFamily: ListeningSpace {
        self == .podcast ? .spokenWord : self
    }
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

/// A space's fixed colour as 0xRRGGBB, one value for light appearance and one
/// for dark. The app's chips, tabs and library, Apple TV and the widgets all
/// draw a space from here, so it reads the same colour on every screen.
public struct ListeningSpaceTint: Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(light: UInt32, dark: UInt32) {
        self.light = light
        self.dark = dark
    }

    /// Red, green and blue of `hex` in 0...1.
    public static func components(_ hex: UInt32) -> (red: Double, green: Double, blue: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

extension ListeningSpace {
    /// Radio, spoken word and podcasts have fixed hues; music has none and
    /// follows the accent the user picked.
    public var fixedTint: ListeningSpaceTint? {
        switch self {
        case .music: nil
        case .radio: ListeningSpaceTint(light: 0xD9480F, dark: 0xFF8A4C)
        case .spokenWord: ListeningSpaceTint(light: 0x0F8A6A, dark: 0x3FD1A6)
        case .podcast: ListeningSpaceTint(light: 0x7A3FC9, dark: 0xB98CFF)
        }
    }

    /// The symbol a space is named with everywhere, widgets included.
    public var systemImage: String {
        switch self {
        case .music: "music.note"
        case .radio: "dot.radiowaves.left.and.right"
        case .spokenWord: "books.vertical.fill"
        case .podcast: "antenna.radiowaves.left.and.right"
        }
    }
}

/// How the user colours radio, spoken word or podcasts: the space's own hue
/// (`fixedTint`), the app's theme colour, the colour picked from the cover
/// playing now, or a colour of their own. Stored per space as one string.
public enum ListeningSpaceTintChoice: Hashable, Sendable {
    case standard
    case theme
    case artwork
    /// RRGGBB, upper case, no `#`.
    case fixed(String)

    /// Anything unreadable (an empty or missing value included) is the space's own hue.
    public init(storedValue: String?) {
        let value = (storedValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "theme":
            self = .theme
        case "artwork":
            self = .artwork
        default:
            let hex = value.replacingOccurrences(of: "#", with: "").uppercased()
            self = hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? .fixed(hex) : .standard
        }
    }

    public var storedValue: String {
        switch self {
        case .standard: ""
        case .theme: "theme"
        case .artwork: "artwork"
        case .fixed(let hex): hex
        }
    }

    public var fixedHex: String? {
        if case .fixed(let hex) = self { return hex }
        return nil
    }

    /// 实际按哪种颜色画:「跟随封面」用这一类自己记下的封面色(`ListeningSpaceArtworkTintStore`),
    /// 当成挑好的固定色来算;这一类还没记下过封面色时用它自带的颜色。其余选项原样返回。
    public func resolvingArtwork(_ artworkHex: String?) -> ListeningSpaceTintChoice {
        guard self == .artwork else { return self }
        guard let hex = ListeningSpaceTintChoice(storedValue: artworkHex).fixedHex else { return .standard }
        return .fixed(hex)
    }
}

/// 电台、有声书、播客各记各的封面色:每一类最后一次在播时封面的主色(RRGGBB)。
/// 选了「跟随封面」的那一类按它显示,放别的内容时不跟着变(#313)。播的那一条没有封面色时清掉,
/// 回到这一类自带的颜色。App 写自己的设置,同时抄一份进 App Group 给小组件。
public enum ListeningSpaceArtworkTintStore {
    public static func key(for space: ListeningSpace) -> String {
        "primuse.listeningSpace.artworkTint.\(space.rawValue)"
    }

    public static func hex(for space: ListeningSpace, in defaults: UserDefaults) -> String? {
        guard ListeningSpaceTintPreferences.customizableSpaces.contains(space) else { return nil }
        return ListeningSpaceTintChoice(storedValue: defaults.string(forKey: key(for: space))).fixedHex
    }

    public static func store(_ hex: String?, for space: ListeningSpace, in defaults: UserDefaults) {
        guard ListeningSpaceTintPreferences.customizableSpaces.contains(space) else { return }
        if let hex = ListeningSpaceTintChoice(storedValue: hex).fixedHex {
            defaults.set(hex, forKey: key(for: space))
        } else {
            defaults.removeObject(forKey: key(for: space))
        }
    }

    /// 0...1 的 sRGB 三个通道写成 RRGGBB。
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        func channel(_ value: Double) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
    }
}

/// Where each space's colour choice is kept. The app writes its own defaults
/// and mirrors them into the App Group, where the widgets read them.
public enum ListeningSpaceTintPreferences {
    /// Music follows the theme colour and has no choice of its own.
    public static let customizableSpaces: [ListeningSpace] = [.radio, .spokenWord, .podcast]

    public static func key(for space: ListeningSpace) -> String {
        "primuse.listeningSpace.tint.\(space.rawValue)"
    }

    public static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier)
    }

    public static func choice(for space: ListeningSpace, in defaults: UserDefaults) -> ListeningSpaceTintChoice {
        guard customizableSpaces.contains(space) else { return .theme }
        return ListeningSpaceTintChoice(storedValue: defaults.string(forKey: key(for: space)))
    }

    public static func store(_ choice: ListeningSpaceTintChoice, for space: ListeningSpace, in defaults: UserDefaults) {
        guard customizableSpaces.contains(space) else { return }
        if choice == .standard {
            defaults.removeObject(forKey: key(for: space))
        } else {
            defaults.set(choice.storedValue, forKey: key(for: space))
        }
    }
}

extension ListeningSpaceTint {
    /// A colour the user picked, made to read as text and icons the way the
    /// theme colour is (`ThemeAccentContrastPolicy`): the light shade darkened
    /// to 4.5:1 on white, the dark shade lifted to 4.5:1 on black. White reads
    /// as near-black in light appearance, like the theme's "white".
    public static func legible(hex: String) -> ListeningSpaceTint? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        if value == 0xFFFFFF { return ListeningSpaceTint(light: 0x1C1C1C, dark: 0xFFFFFF) }
        let rgb = components(value)
        let source = ThemeAccentContrastPolicy.RGB(red: rgb.red, green: rgb.green, blue: rgb.blue)
        // 压到 8 位时往对比度更高的方向取整:浅色档向下、深色档向上,刚好过线的颜色不会掉回线下。
        return ListeningSpaceTint(
            light: packed(ThemeAccentContrastPolicy.legible(source, for: .light), rounding: .down),
            dark: packed(ThemeAccentContrastPolicy.legible(source, for: .dark), rounding: .up)
        )
    }

    /// 垫在白字下面的深底:色相、饱和度不变,HSB 亮度压到 `factor` 倍(三个通道同比缩放)。
    /// App 主题色的深色那一档也是这样压的(0.55),所以电台大卡用电台色和用主题色时一样深。
    public static func deepened(_ hex: UInt32, factor: Double = 0.55) -> UInt32 {
        let rgb = components(hex)
        let scale = min(max(factor, 0), 1)
        return packed(
            ThemeAccentContrastPolicy.RGB(red: rgb.red * scale, green: rgb.green * scale, blue: rgb.blue * scale),
            rounding: .toNearestOrAwayFromZero
        )
    }

    private static func packed(_ rgb: ThemeAccentContrastPolicy.RGB, rounding: FloatingPointRoundingRule) -> UInt32 {
        func channel(_ value: Double) -> UInt32 {
            UInt32((min(max(value, 0), 1) * 255).rounded(rounding))
        }
        return channel(rgb.red) << 16 | channel(rgb.green) << 8 | channel(rgb.blue)
    }
}

/// The link a widget opens when tapped outside its play button: the app's
/// page for one listening space (`primuse://open/radio`).
public enum ListeningSpaceLink {
    public static let scheme = "primuse"
    public static let host = "open"

    public static func url(for space: ListeningSpace) -> URL? {
        URL(string: "\(scheme)://\(host)/\(space.rawValue)")
    }

    public static func space(from url: URL) -> ListeningSpace? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let name = url.pathComponents.first(where: { $0 != "/" }) else { return nil }
        return ListeningSpace(rawValue: name)
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
        case .podcast:
            // An episode is the whole "book": end of episode, no end of book.
            var options: [SleepTimerOption] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60)]
            if hasChapters { options.append(.endOfChapter) }
            options.append(.endOfTrack)
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
        ownedBy space: ListeningSpace,
        current: ListeningPlayMode
    ) -> ListeningPlayMode? {
        let owner = space.playbackFamily
        switch (activeSpace.playbackFamily, owner) {
        case (_, .radio), (.music, .music), (.radio, _):
            return nil
        case (_, .podcast), (.podcast, _):
            // `playbackFamily` folds podcasts into spoken word above.
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
