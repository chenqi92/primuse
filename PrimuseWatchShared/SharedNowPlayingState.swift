import Foundation

/// Watch app 与 Watch Widget Extension 共享的 Now Playing 快照。
///
/// 通过 App Group `group.com.welape.yuanyin` 共享 ── Watch app 收到 iPhone
/// 推来的状态后写一份到这个 UserDefaults; Widget Provider 读这份生成
/// timeline entry。
///
/// 注意 watchOS 上 Widget 跟 iOS Widget 一样必须经过 App Group 才能跨进程
/// 读到 Watch app 写入的数据 ── 各自的标准 UserDefaults 是隔离的。
enum SharedNowPlayingState {
    static let appGroup = "group.com.welape.yuanyin"
    static let widgetKind = "PrimuseWatchNowPlaying"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    static func write(songID: String, title: String, artist: String, isPlaying: Bool) {
        guard let d = defaults else { return }
        d.set(songID, forKey: "wnp.songID")
        d.set(title, forKey: "wnp.title")
        d.set(artist, forKey: "wnp.artist")
        d.set(isPlaying, forKey: "wnp.isPlaying")
        d.set(Date().timeIntervalSince1970, forKey: "wnp.updatedAt")
    }

    static func read() -> Snapshot {
        guard let d = defaults else { return .empty }
        return Snapshot(
            songID: d.string(forKey: "wnp.songID") ?? "",
            title: d.string(forKey: "wnp.title") ?? "",
            artist: d.string(forKey: "wnp.artist") ?? "",
            isPlaying: d.bool(forKey: "wnp.isPlaying"),
            updatedAt: Date(timeIntervalSince1970: d.double(forKey: "wnp.updatedAt"))
        )
    }

    struct Snapshot: Sendable {
        let songID: String
        let title: String
        let artist: String
        let isPlaying: Bool
        let updatedAt: Date

        static let empty = Snapshot(songID: "", title: "", artist: "", isPlaying: false, updatedAt: .distantPast)
        var hasSong: Bool { !songID.isEmpty }
    }
}
