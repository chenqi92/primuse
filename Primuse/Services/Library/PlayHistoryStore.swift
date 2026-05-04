import Foundation
import PrimuseKit

/// 本地播放历史 — 给「听歌统计」页用。
///
/// 跟现有的两条数据通路是互补关系:
/// - `MusicLibrary.recentPlaybackSongIDs`: 只是个 100 条的滑动窗口, 不带
///   时间戳, 给 Home 页「最近播放」用, 不能做按周/月聚合。
/// - `ScrobbleService`: 把每条播放发到 ListenBrainz / Last.fm, 但不在本地
///   留底, 用户不开 scrobble 就什么也没。
///
/// 这里用 append-only 的本地 JSON 日志, 滚动保留最近 5000 条 (够覆盖
/// 普通用户 1-2 年的高强度听歌), 给统计页的「本周 / 本月 / 全部」
/// + Top 排行 + 热力图提供原始数据。
///
/// **隐私**: 纯本地存储, 不上传不同步。
@MainActor
@Observable
final class PlayHistoryStore {
    /// 单条播放事件 — 当用户听歌超过阈值时由 AudioPlayerService 触发记入。
    struct Entry: Codable, Identifiable, Hashable {
        var id: String { "\(songID)-\(Int64(playedAt.timeIntervalSince1970))" }
        let songID: String
        let songTitle: String
        let artistName: String
        let albumTitle: String
        /// 这次开始播的 wall-clock 时间。
        let playedAt: Date
        /// 用户实际听了多长 (秒)。<阈值不会进入这里, 所以最小值
        /// 在 `recordedThresholdSec` 附近。
        let listenedSec: TimeInterval
        let sourceID: String
    }

    static let shared = PlayHistoryStore()

    /// 触发记录的最低实听时长。跟 ScrobbleService 一致 (50% or 240s
    /// 的较小值, 保底 30s)。短于这个的歌会被认为是用户跳过, 不计入
    /// 统计避免污染 Top 排行。
    static let recordedThresholdSec: TimeInterval = 30

    /// 最大保留条目数 — 滚动 evict 最老的。5000 条按平均 3 分钟一首
    /// 大约 250h = 10 天纯听歌, 实际能覆盖 1-2 年的零散听歌。
    private static let maxEntries = 5000

    private(set) var entries: [Entry] = []
    private let storeURL: URL
    private var saveTask: Task<Void, Never>?

    // 当前会话 — beginSession / tick / endSession 三段式跟 Scrobble 同步,
    // 由 AudioPlayerService 在同样的 hook 点调用。
    private var currentSong: Song?
    private var currentStartedAt: Date?
    /// 实听 high-water mark — 用 currentTime 近似, seek 回去不会让它降。
    private var currentMaxElapsed: TimeInterval = 0

    private init() {
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        self.storeURL = docs.appendingPathComponent("play_history.json")
        load()
    }

    // MARK: - Session lifecycle (AudioPlayerService 调用)

    /// 用户开始播放新歌 — 启动 session, 如果有上一首未结算的先 flush。
    func beginSession(song: Song) {
        endSession()
        currentSong = song
        currentStartedAt = Date()
        currentMaxElapsed = 0
    }

    /// 进度更新 — 跟 ScrobbleService 同步触发。维护 high-water mark
    /// (seek 回去不应让累计变小)。
    func tick(elapsed: TimeInterval) {
        guard currentSong != nil else { return }
        if elapsed > currentMaxElapsed { currentMaxElapsed = elapsed }
    }

    /// 结束 session — 用户主动停 / 切歌 / 播完。低于阈值不写入。
    func endSession() {
        guard let song = currentSong, let startedAt = currentStartedAt else { return }
        defer {
            currentSong = nil
            currentStartedAt = nil
            currentMaxElapsed = 0
        }
        guard currentMaxElapsed >= Self.recordedThresholdSec else { return }
        record(song: song, startedAt: startedAt, listenedSec: currentMaxElapsed)
    }

    // MARK: - 写入

    /// 直接写一条 entry —— 测试 / 数据导入用。普通播放走 session 三段式。
    func record(song: Song, startedAt: Date, listenedSec: TimeInterval) {
        guard listenedSec >= Self.recordedThresholdSec else { return }
        let entry = Entry(
            songID: song.id,
            songTitle: song.title,
            artistName: song.artistName ?? "",
            albumTitle: song.albumTitle ?? "",
            playedAt: startedAt,
            listenedSec: listenedSec,
            sourceID: song.sourceID
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        scheduleSave()
    }

    func clearAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - 查询 / 聚合

    enum Range: String, CaseIterable, Identifiable {
        case week, month, year, all
        var id: String { rawValue }
        var localizationKey: String {
            switch self {
            case .week: return "stats_range_week"
            case .month: return "stats_range_month"
            case .year: return "stats_range_year"
            case .all: return "stats_range_all"
            }
        }
        /// 起点 — 包含这个时刻之后的所有 entry。
        func startDate(now: Date = Date()) -> Date {
            let cal = Calendar.current
            switch self {
            case .week:
                return cal.date(byAdding: .day, value: -7, to: now) ?? now
            case .month:
                return cal.date(byAdding: .day, value: -30, to: now) ?? now
            case .year:
                return cal.date(byAdding: .day, value: -365, to: now) ?? now
            case .all:
                return .distantPast
            }
        }
    }

    func entries(in range: Range, now: Date = Date()) -> [Entry] {
        let cutoff = range.startDate(now: now)
        return entries.filter { $0.playedAt >= cutoff }
    }

    struct RankedItem: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let playCount: Int
        let totalSec: TimeInterval
    }

    /// Top 歌曲 — 按播放次数倒序。
    func topSongs(in range: Range, limit: Int = 20) -> [RankedItem] {
        let scoped = entries(in: range)
        let groups = Dictionary(grouping: scoped) { $0.songID }
        return groups
            .map { (songID, plays) -> RankedItem in
                let first = plays.first!
                return RankedItem(
                    id: songID,
                    title: first.songTitle,
                    subtitle: first.artistName,
                    playCount: plays.count,
                    totalSec: plays.reduce(0) { $0 + $1.listenedSec }
                )
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    /// Top 艺术家 —— 按累计听歌次数倒序。
    func topArtists(in range: Range, limit: Int = 20) -> [RankedItem] {
        let scoped = entries(in: range).filter { !$0.artistName.isEmpty }
        let groups = Dictionary(grouping: scoped) { $0.artistName }
        return groups
            .map { (name, plays) -> RankedItem in
                let uniqueSongs = Set(plays.map(\.songID)).count
                return RankedItem(
                    id: "artist:\(name)",
                    title: name,
                    subtitle: String(format: String(localized: "stats_unique_songs_format"), uniqueSongs),
                    playCount: plays.count,
                    totalSec: plays.reduce(0) { $0 + $1.listenedSec }
                )
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    /// Top 专辑 — 同上。
    func topAlbums(in range: Range, limit: Int = 20) -> [RankedItem] {
        let scoped = entries(in: range).filter { !$0.albumTitle.isEmpty }
        let groups = Dictionary(grouping: scoped) { "\($0.albumTitle)|\($0.artistName)" }
        return groups
            .map { (key, plays) -> RankedItem in
                let first = plays.first!
                return RankedItem(
                    id: "album:\(key)",
                    title: first.albumTitle,
                    subtitle: first.artistName,
                    playCount: plays.count,
                    totalSec: plays.reduce(0) { $0 + $1.listenedSec }
                )
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    /// 按天聚合的播放数 (热力图用)。返回 [日期: 当天播放次数],
    /// 跨度从 `range` 起点到今天, 缺失的日子值为 0。
    func dailyPlayCounts(in range: Range, now: Date = Date()) -> [(date: Date, count: Int)] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: range.startDate(now: now))
        let end = cal.startOfDay(for: now)
        let scoped = entries(in: range)
        let bucketed = Dictionary(grouping: scoped) {
            cal.startOfDay(for: $0.playedAt)
        }.mapValues(\.count)
        var result: [(Date, Int)] = []
        var cursor = start
        while cursor <= end {
            result.append((cursor, bucketed[cursor] ?? 0))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86400)
        }
        return result
    }

    /// 总览数字 (顶部摘要卡用)。
    struct Summary {
        let totalPlays: Int
        let totalSec: TimeInterval
        let activeDays: Int
        let uniqueSongs: Int
    }

    func summary(in range: Range) -> Summary {
        let scoped = entries(in: range)
        let cal = Calendar.current
        let dayBuckets = Set(scoped.map { cal.startOfDay(for: $0.playedAt) })
        return Summary(
            totalPlays: scoped.count,
            totalSec: scoped.reduce(0) { $0 + $1.listenedSec },
            activeDays: dayBuckets.count,
            uniqueSongs: Set(scoped.map(\.songID)).count
        )
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let loaded = try? decoder.decode([Entry].self, from: data) else { return }
        // 按 playedAt 降序保证插入端不变
        entries = loaded.sorted { $0.playedAt > $1.playedAt }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
