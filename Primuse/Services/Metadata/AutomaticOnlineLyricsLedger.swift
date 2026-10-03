import Foundation

// MARK: - Tier4: 普通源的自动在线歌词兜底
//
// iOS / macOS 的 LyricsLoader(Tier4)与 Apple TV 播放时的在线歌词兜底共用这两样:
// 什么时候允许自动去问(开关 + 有能用的歌词源),以及同一首歌多久问一次。

/// 同一进程内，每首歌 6 小时只自动问一次在线歌词，避免没歌词的歌每次播放都打一轮网络请求。手动刮削不经过这里。
actor AutomaticOnlineLyricsLedger {
    static let shared = AutomaticOnlineLyricsLedger()

    private static let cooldown: TimeInterval = 6 * 60 * 60
    private static let pruneThreshold = 2048

    private var lastAttempt: [String: Date] = [:]

    /// 最近 6 小时没问过就登记并返回 true；问过返回 false。
    func shouldAttempt(songID: String) -> Bool {
        let now = Date()
        if let previous = lastAttempt[songID],
           now.timeIntervalSince(previous) < Self.cooldown {
            return false
        }
        lastAttempt[songID] = now
        if lastAttempt.count > Self.pruneThreshold {
            lastAttempt = lastAttempt.filter { now.timeIntervalSince($0.value) < Self.cooldown }
        }
        return true
    }
}

// MARK: - Tier3: 源里确认没有同名歌词 / 文字稿

/// 播放页每次展开都会重新加载歌词。源里确认没有同名歌词文件（文件不存在、空文件、
/// 读不出文字）的那一首，30 分钟内不再去源里取：没有文字稿的有声书每点开一次播放页
/// 就对 NAS 打一个 404，既白跑网络，结果回来时又要重画整页。
/// 只记确定的「没有」，连不上、超时这类不记。键里带着扫描记下的歌词文件名，
/// 重扫找到了歌词，键也就换了；刮削、编辑写进缓存的歌词在这一层之前就命中了。
actor LyricsSidecarMissLedger {
    static let shared = LyricsSidecarMissLedger()

    private static let lifetime: TimeInterval = 30 * 60
    private static let pruneThreshold = 512

    private var misses: [String: Date] = [:]

    func isRecentMiss(_ key: String) -> Bool {
        guard let recorded = misses[key] else { return false }
        if Date().timeIntervalSince(recorded) < Self.lifetime { return true }
        misses[key] = nil
        return false
    }

    func recordMiss(_ key: String) {
        let now = Date()
        misses[key] = now
        if misses.count > Self.pruneThreshold {
            misses = misses.filter { now.timeIntervalSince($0.value) < Self.lifetime }
        }
    }
}

/// 自动在线歌词的开关与来源门槛：「找不到歌词时自动在线获取」关着、或者没有一个
/// 能用的歌词源时，一律不发请求。
enum AutomaticOnlineLyricsGate {
    static func allowsAutomaticFetch(settings: ScraperSettings) -> Bool {
        guard settings.autoFetchOnlineLyrics else { return false }
        let hasLyricsServers = !LyricsAPIServerSettings.load().servers.isEmpty
        return settings.enabledSources.contains { config in
            guard config.type.supportsLyrics else { return false }
            // 歌词服务器源开着但一个地址都没填，等于没有。
            if config.type == .lyricsServer { return hasLyricsServers }
            return true
        }
    }
}
