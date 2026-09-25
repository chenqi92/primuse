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
/// **隐私**: 默认本地存储; 用户开启 iCloud「听歌统计」频道后才进入私有
/// CloudKit 同步。
@MainActor
@Observable
final class PlayHistoryStore {
    /// 单条播放事件 — 当用户听歌超过阈值时由 AudioPlayerService 触发记入。
    struct Entry: Codable, Identifiable, Hashable, Sendable {
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

        var listeningEvent: HomeListeningEvent {
            HomeListeningEvent(
                songID: songID, playedAt: playedAt, listenedSeconds: listenedSec,
                songTitle: songTitle, artistName: artistName, albumTitle: albumTitle
            )
        }
    }

    static let shared = PlayHistoryStore()

    /// 触发记录的最低实听时长。跟 ScrobbleService 一致 (50% or 240s
    /// 的较小值, 保底 30s)。短于这个的歌会被认为是用户跳过, 不计入
    /// 统计避免污染 Top 排行。
    static let recordedThresholdSec: TimeInterval = 30

    /// 最大保留条目数 — 滚动 evict 最老的。5000 条按平均 3 分钟一首
    /// 大约 250h = 10 天纯听歌, 实际能覆盖 1-2 年的零散听歌。
    static let maxRetainedEntries = 5000

    private(set) var entries: [Entry] = []
    /// Songs the library currently counts as spoken word, kept in step by
    /// `MusicLibrary`. Books are not music: they stay in `entries` (and in
    /// sync) but are left out of every music ranking, summary and
    /// recommendation seed, and are totalled on their own instead.
    /// Classified at read time, so a correction applies to past plays too.
    var spokenWordSongIDs: Set<String> = []

    /// The plays that were music.
    var musicEntries: [Entry] {
        Self.musicEntries(entries, excluding: spokenWordSongIDs)
    }

    nonisolated static func musicEntries(_ entries: [Entry], excluding spokenWordSongIDs: Set<String>) -> [Entry] {
        spokenWordSongIDs.isEmpty ? entries : entries.filter { !spokenWordSongIDs.contains($0.songID) }
    }

    /// Seconds spent on spoken word in `range` (calendar windows, like the
    /// stats page).
    func spokenWordListeningSeconds(in range: Range, now: Date = Date(), calendar: Calendar = ListeningCalendar.current) -> TimeInterval {
        guard !spokenWordSongIDs.isEmpty else { return 0 }
        let cutoff = range.statisticsStartDate(now: now, calendar: calendar)
        return Self.listenedSeconds(entries.filter {
            $0.playedAt >= cutoff && $0.playedAt <= now && spokenWordSongIDs.contains($0.songID)
        })
    }

    nonisolated static func listenedSeconds(_ entries: [Entry]) -> TimeInterval {
        entries.reduce(0) { $0 + ($1.listenedSec.isFinite ? max(0, $1.listenedSec) : 0) }
    }
    /// 单调递增, `entries` 每变一次就 +1。云同步用它判断预先编码好的
    /// payload 还配不配得上当前这份历史。
    @ObservationIgnored private(set) var revision = 0
    private let storeURL: URL
    private var saveTask: Task<Void, Never>?

    // 当前会话 — beginSession / tick / endSession 三段式跟 Scrobble 同步,
    // 由 AudioPlayerService 在同样的 hook 点调用。
    private var currentSong: Song?
    private var currentStartedAt: Date?
    /// 实听累计秒数 — 由播放时钟按真实播放增量累加。不能用播放位置的
    /// high-water mark: 那样把进度条拖过阈值再切歌也会记成一次完整播放,
    /// 实听时长还会被记成拖到的位置。
    private var currentListenedSec: TimeInterval = 0

    private init() {
        #if os(tvOS)
        let docs = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
        #else
        let docs = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        self.storeURL = docs.appendingPathComponent("play_history.json")
        clearedAt = UserDefaults.standard.object(forKey: Self.clearedAtDefaultsKey) as? Date
        load()
    }

    // MARK: - Session lifecycle (AudioPlayerService 调用)

    /// 用户开始播放新歌 — 启动 session, 如果有上一首未结算的先 flush。
    /// Set while a medley plays: slices of songs are not listens, and counting
    /// them would crowd the stats and the recommendations with every song
    /// the medley touched.
    var isRecordingSuspended = false

    func beginSession(song: Song) {
        endSession()
        guard !isRecordingSuspended else { return }
        currentSong = song
        currentStartedAt = Date()
        currentListenedSec = 0
    }

    /// 进度更新 — 跟 ScrobbleService 同步触发, 传本次 tick 真实播放了多少秒。
    /// 拖进度条跳过的区间不算实听, 回拖重听的区间也不会重复计。
    func tick(playedDelta: TimeInterval) {
        guard currentSong != nil, playedDelta.isFinite, playedDelta > 0 else { return }
        currentListenedSec += playedDelta
    }

    /// 结束 session — 用户主动停 / 切歌 / 播完。低于阈值不写入。
    func endSession() {
        guard let song = currentSong, let startedAt = currentStartedAt else { return }
        defer {
            currentSong = nil
            currentStartedAt = nil
            currentListenedSec = 0
        }
        guard currentListenedSec >= Self.recordedThresholdSec else { return }
        record(song: song, startedAt: startedAt, listenedSec: currentListenedSec)
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
        if entries.count > Self.maxRetainedEntries {
            entries.removeLast(entries.count - Self.maxRetainedEntries)
        }
        scheduleSave()
        notifyChanged()
    }

    /// 用户最近一次「清空听歌记录」的时刻。清空必须作为事实同步出去: 光把本机
    /// 表清空, 云端那份、别的设备那份下一轮又会整份并回来。早于这一刻的记录在
    /// 哪台设备上都不再算数。
    private(set) var clearedAt: Date? {
        didSet { UserDefaults.standard.set(clearedAt, forKey: Self.clearedAtDefaultsKey) }
    }
    private static let clearedAtDefaultsKey = "primuse.listeningStats.clearedAt"

    func clearAll() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: storeURL)
        clearedAt = Date()
        notifyChanged()
    }

    // MARK: - Cloud sync hooks

    var entriesForSync: [Entry] { entries }

    func mergeRemoteEntries(_ remoteEntries: [Entry], remoteClearedAt: Date? = nil) {
        if let remoteClearedAt, remoteClearedAt > (clearedAt ?? .distantPast) {
            clearedAt = remoteClearedAt
        }
        let cutoff = clearedAt ?? .distantPast
        let survivingRemote = remoteEntries.filter { $0.playedAt >= cutoff }
        let survivingLocal = entries.filter { $0.playedAt >= cutoff }
        guard !survivingRemote.isEmpty || survivingLocal.count != entries.count else { return }
        let previous = entries
        let before = Set(entries.map(\.id))
        var mergedByID = Dictionary(
            survivingLocal.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.playedAt >= rhs.playedAt ? lhs : rhs }
        )
        for entry in survivingRemote {
            mergedByID[entry.id] = entry
        }
        let merged = mergedByID.values.sorted { $0.playedAt > $1.playedAt }
        entries = Array(merged.prefix(Self.maxRetainedEntries))
        guard entries != previous else { return }
        guard Set(entries.map(\.id)) != before else {
            // 同一批 id, 但实听时长以远端为准被改写了。不广播 (否则跟远端
            // 来回触发), 可 revision 必须动: 任何按 revision 缓存这份历史的
            // 编码结果都已经过期。改写过的时长同样要落盘, 否则下次冷启动
            // 又会读回旧值。
            revision &+= 1
            scheduleSave()
            return
        }
        scheduleSave()
        notifyChanged(origin: "remote")
    }

    func clearFromRemote() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        try? FileManager.default.removeItem(at: storeURL)
        notifyChanged(origin: "remote")
    }

    /// CloudKit 游标马上要落盘: 攒着的那次两秒写现在就写, 免得进程在这两秒里
    /// 被杀, 刚并进来的远端记录丢了却再也拉不回来。
    func flushPendingSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    // MARK: - 查询 / 聚合

    enum Range: String, CaseIterable, Identifiable, Sendable {
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
        var calendarComponent: Calendar.Component? {
            switch self {
            case .week: return .weekOfYear
            case .month: return .month
            case .year: return .year
            case .all: return nil
            }
        }

        func startDate(now: Date = Date(), calendar: Calendar = ListeningCalendar.current) -> Date {
            let days: Int
            switch self {
            case .week: days = 7
            case .month: days = 30
            case .year: days = 365
            case .all: return .distantPast
            }
            return calendar.date(byAdding: .day, value: -days, to: now) ?? now
        }

        func statisticsStartDate(now: Date = Date(), calendar: Calendar = ListeningCalendar.current) -> Date {
            ListeningCalendar.interval(component: calendarComponent, now: now, calendar: calendar).start
        }
    }

    // Discovery uses these rolling windows for "not recently played". Calendar
    // statistics must not make yesterday's songs stale when a new month starts.
    func entries(in range: Range, now: Date = Date()) -> [Entry] {
        let cutoff = range.startDate(now: now)
        return entries.filter { $0.playedAt >= cutoff && $0.playedAt <= now }
    }

    func statisticsEntries(in range: Range, now: Date = Date(), calendar: Calendar = ListeningCalendar.current) -> [Entry] {
        let cutoff = range.statisticsStartDate(now: now, calendar: calendar)
        return entries.filter { $0.playedAt >= cutoff && $0.playedAt <= now }
    }

    struct SongPlaybackStats: Equatable, Sendable {
        let playCount: Int
        let lastPlayedAt: Date?
    }

    /// 播放次数只统计已经通过 session 阈值的记录，且受当前历史保留窗口限制。
    func playbackStats(forSongID songID: String) -> SongPlaybackStats {
        var count = 0
        var lastPlayedAt: Date?
        for entry in entries where entry.songID == songID {
            count += 1
            if let currentLastPlayedAt = lastPlayedAt {
                if entry.playedAt > currentLastPlayedAt {
                    lastPlayedAt = entry.playedAt
                }
            } else {
                lastPlayedAt = entry.playedAt
            }
        }
        return SongPlaybackStats(playCount: count, lastPlayedAt: lastPlayedAt)
    }

    struct RankedItem: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let subtitle: String
        let playCount: Int
        let totalSec: TimeInterval
        /// 封面取哪首歌的：这一项里听得最多的那首。
        var artworkSongID: String? = nil
    }

    // Rankings and summaries are music only; see `spokenWordSongIDs`.
    func topSongs(in range: Range, limit: Int = 20) -> [RankedItem] {
        Self.rankedItems(from: musicEntries(in: range), category: .songs, limit: limit)
    }

    func topArtists(in range: Range, limit: Int = 20) -> [RankedItem] {
        Self.rankedItems(from: musicEntries(in: range), category: .artists, limit: limit)
    }

    func topAlbums(in range: Range, limit: Int = 20) -> [RankedItem] {
        Self.rankedItems(from: musicEntries(in: range), category: .albums, limit: limit)
    }

    func musicEntries(in range: Range, now: Date = Date()) -> [Entry] {
        Self.musicEntries(entries(in: range, now: now), excluding: spokenWordSongIDs)
    }

    nonisolated static func rankedItems(from entries: [Entry], category: HomeListeningCategory, limit: Int) -> [RankedItem] {
        HomeListeningRanking.ranks(
            events: entries.map(\.listeningEvent), songs: [:], folders: nil,
            period: .all, category: category
        ).prefix(limit).map { rank in
            RankedItem(
                id: category == .songs ? (rank.songIDs.first ?? rank.id) : rank.id,
                title: rank.title,
                subtitle: category == .artists
                    ? String(format: String(localized: "stats_unique_songs_format"), rank.songIDs.count)
                    : rank.subtitle,
                playCount: rank.playCount,
                totalSec: rank.listenedSeconds,
                artworkSongID: rank.artworkSongID
            )
        }
    }

    /// 按天聚合的播放数 (热力图用)。返回 [日期: 当天播放次数],
    /// 跨度从 `range` 起点到今天, 缺失的日子值为 0。
    func dailyPlayCounts(in range: Range, now: Date = Date()) -> [(date: Date, count: Int)] {
        let cal = ListeningCalendar.current
        let end = cal.startOfDay(for: now)
        let scoped = entries(in: range, now: now)
        // `.all` 没有固定起点 —— 从最早一条记录那天开始; 同时兜底最多回看 ~2 年,
        // 避免极端长的历史把热力图撑出成千上万列。
        let rawStart: Date
        if range == .all {
            rawStart = scoped.map(\.playedAt).min().map { cal.startOfDay(for: $0) } ?? end
        } else {
            rawStart = cal.startOfDay(for: range.startDate(now: now))
        }
        let floor = cal.date(byAdding: .day, value: -740, to: end) ?? rawStart
        let start = max(rawStart, floor)
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
    struct Summary: Sendable {
        let totalPlays: Int
        let totalSec: TimeInterval
        let activeDays: Int
        let uniqueSongs: Int
    }

    func summary(in range: Range) -> Summary {
        Self.summary(for: musicEntries(in: range))
    }

    func statisticsSummary(in range: Range) -> Summary {
        Self.summary(for: Self.musicEntries(statisticsEntries(in: range), excluding: spokenWordSongIDs))
    }

    nonisolated static func summary(for entries: [Entry], calendar: Calendar = ListeningCalendar.current) -> Summary {
        Summary(
            totalPlays: entries.count,
            totalSec: listenedSeconds(entries),
            activeDays: Set(entries.map { calendar.startOfDay(for: $0.playedAt) }).count,
            uniqueSongs: Set(entries.map(\.songID)).count
        )
    }

    // MARK: - Persistence

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    func remapSongIDs(_ replacements: [String: String]) {
        guard entries.contains(where: { replacements[$0.songID] != nil }) else { return }
        entries = entries.map { entry in
            Entry(songID: replacements[entry.songID] ?? entry.songID,
                  songTitle: entry.songTitle, artistName: entry.artistName,
                  albumTitle: entry.albumTitle, playedAt: entry.playedAt,
                  listenedSec: entry.listenedSec, sourceID: entry.sourceID)
        }
        flush()
        notifyChanged()
    }

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

    /// `origin` 让 CloudKit 的观察者分得清这是本机播放还是远端并进来的, 后者
    /// 不能再当成本机改动传回云端。
    private func notifyChanged(origin: String = "local") {
        revision &+= 1
        NotificationCenter.default.post(
            name: .primuseListeningStatsDidChange,
            object: nil,
            userInfo: ["origin": origin]
        )
    }
}

extension Notification.Name {
    static let primuseListeningStatsDidChange = Notification.Name("primuse.listeningStatsDidChange")
}
