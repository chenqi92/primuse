import AppIntents
import Foundation
import PrimuseKit

/// 猿音的 App Intents 集合 ── iOS 16+ Shortcuts / Siri 入口 + iOS 17+
/// Live Activity / iOS 18 Control Center 按钮入口。
///
/// 跟老 SiriKit (`INPlayMediaIntent`, 见 `PlayMediaIntentHandler`) 并存:
/// - 老 SiriKit 主要给 CarPlay 语音 / 系统媒体快捷键 (锁屏 / 灵动岛) 用,
///   API 受 Apple 媒体 intent schema 约束。
/// - 这里的 App Intents 是面向用户在 Shortcuts.app 里搭流程, 也支持 Siri
///   直接说"用猿音 [动作]"。可以自由定义参数和返回值。
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

// MARK: - Like

/// 锁屏 widget / Live Activity 的喜欢按钮。
///
/// 用 `SetValueIntent` 的同款"目标状态"语义而不是纯 toggle: SwiftUI
/// `Toggle(isOn:intent:)` 会在 `perform()` 跑完前先乐观地把心填上, 所以
/// intent 必须写入一个确定的目标值。无条件取反的话, 用户连点两次就会跟
/// 乐观 UI 反相。
struct PrimuseSetLikedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Liked"
    static let description = IntentDescription("Add or remove the current song from Liked.")

    @Parameter(title: "Liked")
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

    @Parameter(title: "Title")
    var query: String

    @Parameter(title: "Artist", description: "Optional, narrows the match if multiple songs share a title.")
    var artist: String?

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let description = await PrimuseIntentBridge.shared.playSong(query, artist)
        guard let description else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "No matching song in your library.")))
        }
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: description)))
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
/// `.applicationName` token, 跟 app 显示名拼起来 (例如 "用 猿音 暂停")。
#if os(macOS) && !PRIMUSE_WIDGET_EXTENSION
struct PrimuseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PrimusePlayPauseIntent(),
            phrases: [
                "用 \(.applicationName) 播放",
                "用 \(.applicationName) 暂停",
                "Toggle \(.applicationName)",
            ],
            shortTitle: "Play / Pause",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PrimuseNextIntent(),
            phrases: [
                "用 \(.applicationName) 下一首",
                "Next track in \(.applicationName)",
            ],
            shortTitle: "Next",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PrimusePreviousIntent(),
            phrases: [
                "用 \(.applicationName) 上一首",
                "Previous track in \(.applicationName)",
            ],
            shortTitle: "Previous",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: PrimuseShuffleAllIntent(),
            phrases: [
                "用 \(.applicationName) 随机播放",
                "Shuffle \(.applicationName)",
            ],
            shortTitle: "Shuffle",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: PrimusePlaySongIntent(),
            phrases: [
                "用 \(.applicationName) 播放歌曲",
                "Play a song in \(.applicationName)",
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: PrimusePlayPlaylistIntent(),
            phrases: [
                "用 \(.applicationName) 播放歌单",
                "Play a playlist in \(.applicationName)",
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: PrimuseResumePlaybackIntent(),
            phrases: [
                "用 \(.applicationName) 继续播放",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PrimusePlayRadioIntent(),
            phrases: [
                "用 \(.applicationName) 播放电台",
                "用 \(.applicationName) 播放 \(\.$station)",
                "用 \(.applicationName) 播放电台 \(\.$station)",
                "用 \(.applicationName) 播放電台 \(\.$station)",
                "Play radio in \(.applicationName)",
                "Play \(\.$station) in \(.applicationName)",
                "Spiele \(\.$station) in \(.applicationName)",
                "Écouter \(\.$station) dans \(.applicationName)",
                "\(.applicationName)에서 \(\.$station) 재생",
                "\(.applicationName)で\(\.$station)ラジオをかけて",
            ],
            shortTitle: "Play Radio",
            systemImageName: "radio"
        )
        AppShortcut(
            intent: PrimusePlaySongRadioIntent(),
            phrases: [
                "用 \(.applicationName) 播放相似歌曲",
                "Play similar songs in \(.applicationName)",
            ],
            shortTitle: "Similar Songs",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PrimuseSearchRadioIntent(),
            phrases: [
                "用 \(.applicationName) 搜索电台",
                "用 \(.applicationName) 搜索电台 \(\.$station)",
                "用 \(.applicationName) 搜尋電台 \(\.$station)",
                "Search radio in \(.applicationName)",
                "Search for \(\.$station) radio in \(.applicationName)",
                "Suche \(\.$station) Radio in \(.applicationName)",
                "Rechercher la radio \(\.$station) dans \(.applicationName)",
                "\(.applicationName)에서 \(\.$station) 라디오 검색",
                "\(.applicationName)で\(\.$station)ラジオをさがして",
            ],
            shortTitle: "Search Radio",
            systemImageName: "magnifyingglass"
        )
    }
}
#endif
