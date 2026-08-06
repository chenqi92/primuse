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

// MARK: - App Shortcuts (Siri phrases)

/// 给系统注册一组语音短语让 Siri 直接说出来。Apple 要求每个 phrase 必须含
/// `.applicationName` token, 跟 app 显示名拼起来 (例如 "用 猿音 暂停")。
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
    }
}
