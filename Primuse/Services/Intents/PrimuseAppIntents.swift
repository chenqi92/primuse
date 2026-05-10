import AppIntents
import Foundation
import PrimuseKit

/// 猿音的 App Intents 集合 ── iOS 16+ Shortcuts / Siri 入口。
///
/// 跟老 SiriKit (`INPlayMediaIntent`, 见 `PlayMediaIntentHandler`) 并存:
/// - 老 SiriKit 主要给 CarPlay 语音 / 系统媒体快捷键 (锁屏 / 灵动岛) 用,
///   API 受 Apple 媒体 intent schema 约束。
/// - 这里的 App Intents 是面向用户在 Shortcuts.app 里搭流程, 也支持 Siri
///   直接说"用猿音 [动作]"。可以自由定义参数和返回值。
///
/// 所有 intent 的 perform 都在 main actor 上跑 ── AudioPlayerService /
/// MusicLibrary 都是 @MainActor, 直接调它们的方法。

// MARK: - Play / Pause / Skip

struct PrimusePlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play / Pause"
    static let description = IntentDescription("Toggle Primuse playback.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.playerService.togglePlayPause()
        return .result()
    }
}

struct PrimuseNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skip to the next track in Primuse.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppServices.shared.playerService.next(caller: "AppIntent")
        return .result()
    }
}

struct PrimusePreviousIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Go back to the previous track in Primuse.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppServices.shared.playerService.previous()
        return .result()
    }
}

// MARK: - Play by name

struct PrimusePlaySongIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription(
        "Find a song by title (and optional artist) and play it."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Title")
    var query: String

    @Parameter(title: "Artist", description: "Optional, narrows the match if multiple songs share a title.")
    var artist: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = AppServices.shared.musicLibrary
        let player = AppServices.shared.playerService

        let candidates = matchingSongs(in: library.visibleSongs, title: query, artist: artist)
        guard let song = candidates.first else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "No matching song in your library.")))
        }

        // 拿命中歌曲做队列起点, 后续整库相关歌曲跟在后面 ── 让"播完一首会
        // 自动接下去"。简单做法: 把 candidates + library 其他歌按 candidates 排序拼起来。
        let queue = candidates + library.visibleSongs.filter { s in !candidates.contains(where: { $0.id == s.id }) }
        player.setQueue(queue, startAt: 0)
        await player.play(song: song, caller: "AppIntent")

        let response = "Playing \(song.title)" + (song.artistName.map { " by \($0)" } ?? "")
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: response)))
    }

    /// 模糊匹配 ── title 包含 + (可选) artist 包含, 都不区分大小写。
    /// 优先返回精确 title 匹配。
    private func matchingSongs(in songs: [Song], title: String, artist: String?) -> [Song] {
        let titleLower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleLower.isEmpty else { return [] }
        let artistLower = artist?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let filtered = songs.filter { s in
            let titleMatch = s.title.lowercased().contains(titleLower)
            guard titleMatch else { return false }
            if let artistLower, !artistLower.isEmpty {
                return (s.artistName ?? "").lowercased().contains(artistLower)
            }
            return true
        }
        // 精确 title 匹配排前
        return filtered.sorted { a, b in
            let aExact = a.title.lowercased() == titleLower
            let bExact = b.title.lowercased() == titleLower
            if aExact != bExact { return aExact }
            return false
        }
    }
}

struct PrimusePlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Find a playlist by name and play it.")
    static let openAppWhenRun = false

    @Parameter(title: "Name")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = AppServices.shared.musicLibrary
        let player = AppServices.shared.playerService

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "Please specify a playlist name.")))
        }
        // 精确名匹配优先, 否则模糊包含。
        let lists = library.playlists
        let exact = lists.first(where: { $0.name.lowercased() == trimmed })
        let target = exact ?? lists.first(where: { $0.name.lowercased().contains(trimmed) })
        guard let playlist = target else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "No matching playlist in your library.")))
        }

        let songs = library.songs(forPlaylist: playlist.id)
        guard let first = songs.first else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "Playlist is empty.")))
        }

        player.setQueue(songs, startAt: 0)
        await player.play(song: first, caller: "AppIntent")
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "Playing playlist \(playlist.name).")))
    }
}

struct PrimuseShuffleAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Shuffle the entire library and start playing.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let library = AppServices.shared.musicLibrary
        let player = AppServices.shared.playerService
        let pool = library.visibleSongs.shuffled()
        guard let first = pool.first else { return .result() }
        player.setQueue(pool, startAt: 0)
        await player.play(song: first, caller: "AppIntent")
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
    }
}
