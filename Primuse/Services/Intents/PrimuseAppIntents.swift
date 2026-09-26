import AppIntents
import Foundation
import PrimuseKit

/// Primuse 的 App Intents 集合 ── iOS 16+ Shortcuts / Siri 入口 + iOS 17+
/// Live Activity / iOS 18 Control Center 按钮入口。
///
/// 跟老 SiriKit (`INPlayMediaIntent`, 见 `PlayMediaIntentHandler`) 并存:
/// - 老 SiriKit 主要给 CarPlay 语音 / 系统媒体快捷键 (锁屏 / 灵动岛) 用,
///   API 受 Apple 媒体 intent schema 约束。
/// - 这里的 App Intents 是面向用户在 Shortcuts.app 里搭流程, 也支持 Siri
///   直接说"用 Primuse [动作]"。可以自由定义参数和返回值。
///
/// **跨进程注意**:
/// 这份文件同时被 widget extension target 引用 (供 Control Widget /
/// Lock Screen Live Activity 按钮 引用 intent 类型), 所以 `perform()` 里
/// 不能直接 `AppServices.shared.xxx` —— widget 进程没这个符号会 link
/// 不过。改走 `PrimuseIntentBridge` 闭包, 主 app 启动时把真正的实现注入。
/// 所有 intent 都 conform `AudioPlaybackIntent`, 系统会把 `perform()`
/// 路由到主 app 进程跑(必要时唤醒主 app), 那时 bridge 已经注入完毕。

// MARK: - Play / Pause / Skip

struct PrimusePlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static let description = IntentDescription("Toggle Primuse playback.")

    @MainActor
    func perform() async throws -> some IntentResult {
        PrimuseIntentBridge.shared.togglePlayPause()
        return .result()
    }
}

/// Control Center toggle 专用 ── `ControlWidgetToggle` 要求 intent conform
/// `SetValueIntent`, 系统会把"用户想要的目标状态" (true = 想播放) 直接
/// 注入到 `value` 上。跟上面纯 toggle 的 `PrimusePlayPauseIntent` 不同步
/// 共存,各自给不同 surface (Shortcuts vs Control Center)。
struct PrimuseSetPlayingIntent: AudioPlaybackIntent, SetValueIntent {
    static let title: LocalizedStringResource = "Set Playing"
    static let description = IntentDescription("Start or pause Primuse playback.")

    @Parameter(title: "Playing")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        PrimuseIntentBridge.shared.setPlaying(value)
        return .result()
    }
}

struct PrimuseNextIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skip to the next track in Primuse.")

    @MainActor
    func perform() async throws -> some IntentResult {
        await PrimuseIntentBridge.shared.next()
        return .result()
    }
}

struct PrimusePreviousIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Go back to the previous track in Primuse.")

    @MainActor
    func perform() async throws -> some IntentResult {
        await PrimuseIntentBridge.shared.previous()
        return .result()
    }
}

/// 有声内容播放时小组件上替换「上一首 / 下一首」的两个键: 按用户设置的秒数后退 / 前进。
struct PrimuseSkipBackwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Back"
    static let description = IntentDescription("Go back a few seconds in the book playing in Primuse.")
    /// 只给小组件按键用, 不出现在快捷指令里。
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PrimuseIntentBridge.shared.skipBackward()
        return .result()
    }
}

struct PrimuseSkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Go forward a few seconds in the book playing in Primuse.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        PrimuseIntentBridge.shared.skipForward()
        return .result()
    }
}

/// 「继续收听」小组件点一本书: 从上次停下的地方接着播, 与书架上点「继续」同一条路。
struct PrimuseResumeSpokenWordBookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Continue Listening"
    static let description = IntentDescription("Continue a book in Primuse from where you left off.")
    static let isDiscoverable = false

    /// `SpokenWordBook.id`。
    @Parameter(title: "Book")
    var bookID: String

    init() {}
    init(bookID: String) { self.bookID = bookID }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await PrimuseIntentBridge.shared.resumeSpokenWordBook(bookID)
        return .result()
    }
}

enum PrimuseSkipDirection: String, AppEnum {
    case next, previous
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: LocalizedStringResource("Direction", table: "SettingsSearch"))
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: DisplayRepresentation(title: LocalizedStringResource("Next", table: "SettingsSearch")),
        .previous: DisplayRepresentation(title: LocalizedStringResource("Previous", table: "SettingsSearch"))
    ]
}

struct PrimuseSkipTrackIntent: AudioPlaybackIntent {
    static let title = LocalizedStringResource("Skip Track", table: "SettingsSearch")
    @Parameter(title: LocalizedStringResource("Direction", table: "SettingsSearch"), default: .next) var direction: PrimuseSkipDirection
    static var parameterSummary: some ParameterSummary { Summary("Play the \(\.$direction) track", table: "SettingsSearch") }

    @MainActor
    func perform() async throws -> some IntentResult {
        switch direction {
        case .next: await PrimuseIntentBridge.shared.next()
        case .previous: await PrimuseIntentBridge.shared.previous()
        }
        return .result()
    }
}

// MARK: - Like

/// 锁屏 widget / Live Activity 的喜欢按钮。
///
/// 用 `SetValueIntent` 的同款"目标状态"语义而不是纯 toggle: SwiftUI
/// `Toggle(isOn:intent:)` 会在 `perform()` 跑完前先乐观地把心填上, 所以
/// intent 必须写入一个确定的目标值。无条件取反的话, 用户连点两次就会跟
/// 乐观 UI 反相。
struct PrimuseSetLikedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "intent_set_liked_title"
    static let description = IntentDescription("intent_set_liked_description")

    @Parameter(title: "intent_set_liked_parameter")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        await PrimuseIntentBridge.shared.setLiked(value)
        return .result()
    }
}

// MARK: - Play by name

struct PrimusePlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription(
        "Find a song by title (and optional artist) and play it."
    )

    /// `requestValueDialog` 让系统在没值时自己问一句;短语 "Play a song in
    /// Primuse" 本身不带参数占位,不给这句提示时 Siri 只会甩一个通用问法。
    @Parameter(
        title: "Title",
        requestValueDialog: IntentDialog("Which song? Tell Siri the song title.")
    )
    var query: String

    @Parameter(title: "Artist", description: "Optional, narrows the match if multiple songs share a title.")
    var artist: String?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await PrimuseIntentBridge.shared.playSong(query, artist)
        return .result(dialog: IntentDialog(
            LocalizedStringResource(stringLiteral: PrimuseSongIntentDialog.text(for: outcome))
        ))
    }
}

/// 把点歌结果翻成一句给 Siri 念的话。键沿用整句英文:这份文件也编进小组件
/// 进程,那里查不到本地化表时至少还能念出一句能读懂的英文,而不是键名。
enum PrimuseSongIntentDialog {
    static func text(for outcome: PrimuseSongIntentOutcome) -> String {
        switch outcome {
        case .playing(let description):
            return description
        case .missingTitle:
            return String(localized: "Which song? Tell Siri the song title.")
        case .libraryNotReady:
            return String(localized: "Primuse is still loading your library. Try again in a moment.")
        case .libraryEmpty:
            return String(localized: "Your Primuse library is empty.")
        case .notFound:
            return String(localized: "No matching song in your library.")
        case .unavailable:
            return String(localized: "Open Primuse once, then try again.")
        }
    }
}

struct PrimusePlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Find a playlist by name and play it.")

    @Parameter(title: "Name")
    var name: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "Please specify a playlist name.")))
        }
        let description = await PrimuseIntentBridge.shared.playPlaylist(trimmed)
        guard let description else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "No matching playlist in your library.")))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: description)))
    }
}

struct PrimuseShuffleAllIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Shuffle the entire library and start playing.")

    @MainActor
    func perform() async throws -> some IntentResult {
        await PrimuseIntentBridge.shared.shuffleLibrary()
        return .result()
    }
}

struct PrimuseResumePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Playback"
    static let description = IntentDescription("Resume the current Primuse song or radio station.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resumed = await PrimuseIntentBridge.shared.resumePlayback()
        let message = resumed
            ? "Resuming playback."
            : "There is no Primuse playback session to resume."
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: message)))
    }
}

struct PrimusePlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Find an album in Primuse and play it in track order.")

    @Parameter(title: "Album")
    var name: String

    @Parameter(title: "Artist", description: "Optional, narrows albums with the same name.")
    var artist: String?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let description = await PrimuseIntentBridge.shared.playAlbum(name, artist) else {
            return .result(dialog: IntentDialog("No matching album in your library."))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: description)))
    }
}

struct PrimusePlayArtistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Artist"
    static let description = IntentDescription("Find an artist in Primuse and play their songs.")

    @Parameter(title: "Artist")
    var name: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let description = await PrimuseIntentBridge.shared.playArtist(name) else {
            return .result(dialog: IntentDialog("No matching artist in your library."))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: description)))
    }
}

struct PrimusePlayGenreIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Genre"
    static let description = IntentDescription("Play songs matching a genre in Primuse.")

    @Parameter(title: "Genre")
    var name: String

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let description = await PrimuseIntentBridge.shared.playGenre(name) else {
            return .result(dialog: IntentDialog("No matching genre in your library."))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: description)))
    }
}

struct PrimusePlaySongRadioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Similar Songs"
    static let description = IntentDescription("Build a song radio from the current Primuse song.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let description = await PrimuseIntentBridge.shared.playSongRadio() else {
            return .result(dialog: IntentDialog("Play a song first, then try again."))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: description)))
    }
}

enum PrimuseIntentRepeatMode: String, AppEnum {
    case off
    case all
    case one

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Repeat Mode")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off",
        .all: "Repeat All",
        .one: "Repeat One",
    ]

    var playerValue: RepeatMode {
        switch self {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }
}

struct PrimuseSetRepeatModeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Repeat Mode"
    static let description = IntentDescription("Change the Primuse repeat mode.")

    @Parameter(title: "Mode")
    var mode: PrimuseIntentRepeatMode

    init() {}
    init(mode: PrimuseIntentRepeatMode) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult {
        PrimuseIntentBridge.shared.setRepeatMode(mode.playerValue)
        return .result()
    }
}

struct PrimuseSetPlaybackSpeedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let description = IntentDescription("Set Primuse playback speed from 0.5 to 2 times.")

    @Parameter(title: "Speed", inclusiveRange: (0.5, 2.0))
    var speed: Double

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let effective = PrimuseIntentBridge.shared.setPlaybackSpeed(speed)
        return .result(dialog: IntentDialog(
            "Playback speed set to \(effective.formatted()) times."
        ))
    }
}

// MARK: - App Shortcuts (Siri phrases)

/// 给系统注册一组语音短语让 Siri 直接说出来。Apple 要求每个 phrase 必须含
/// `.applicationName` token, 跟 app 显示名拼起来 (例如 "用 Primuse 暂停")。
#if os(macOS) && !PRIMUSE_WIDGET_EXTENSION
struct PrimuseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PrimusePlayPauseIntent(),
            phrases: [
                "Play or pause in \(.applicationName)",
            ],
            shortTitle: "Play / Pause",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PrimuseSkipTrackIntent(),
            phrases: ["Play the \(\.$direction) track in \(.applicationName)"],
            shortTitle: LocalizedStringResource("Skip Track", table: "SettingsSearch"),
            systemImageName: "forward.end"
        )
        AppShortcut(
            intent: PrimuseOpenSettingIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open a setting in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Open Setting", table: "SettingsSearch"),
            systemImageName: "gearshape"
        )
        AppShortcut(
            intent: PrimuseShuffleAllIntent(),
            phrases: [
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Shuffle",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PrimusePlaySongIntent(),
            phrases: [
                "Play a song in \(.applicationName)",
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PrimusePlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PrimuseResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PrimusePlayRadioIntent(),
            phrases: [
                "Play \(\.$station) in \(.applicationName)",
            ],
            shortTitle: "Play Radio",
            systemImageName: "radio"
        )
        AppShortcut(
            intent: PrimusePlaySongRadioIntent(),
            phrases: [
                "Play similar songs in \(.applicationName)",
            ],
            shortTitle: "Similar Songs",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PrimuseSearchRadioIntent(),
            phrases: [
                "Search for \(\.$station) radio in \(.applicationName)",
            ],
            shortTitle: "Search Radio",
            systemImageName: "magnifyingglass"
        )
    }
}
#endif
