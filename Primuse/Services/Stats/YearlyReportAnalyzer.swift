import Foundation
import PrimuseKit

/// 年度报告数据分析器 ── 从 entries 派生所有指标 + 判定音乐人格。
///
/// 纯计算, 输入 `entries` + 可选的 `library` (用于反查 song.year / song.genre,
/// PlayHistoryStore.Entry 不存这些字段), 输出一份完整的 `YearlyReportData`
/// 给 UI 用。
enum YearlyReportAnalyzer {
    /// 主入口。后台 Task 调用即可, 1w 条 entries 内 < 100ms。
    @MainActor
    static func analyze(year: Int, entries: [PlayHistoryStore.Entry], library: MusicLibrary, sourcesStore: SourcesStore? = nil) -> YearlyReportData {
        let songLookup: [String: Song] = Dictionary(
            library.songs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var data = Self.compute(year: year, entries: entries, songLookup: songLookup)

        // 把 source 显示信息烘到 SourceBreakdown, UI 层不用 @Environment 也能
        // 显示正确名字 / 图标。分享 ImageRenderer 拍快照时尤其重要 ── 它不
        // 继承 SwiftUI environment, 没烘的话 SourcesCard 会 crash。
        if let sourcesStore {
            let sourceLookup: [String: MusicSource] = Dictionary(
                sourcesStore.allSources.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            data.sourceBreakdown = data.sourceBreakdown.map { item in
                var resolved = item
                if let source = sourceLookup[item.sourceID] {
                    resolved.displayName = source.name
                    resolved.iconSymbol = symbolName(for: source.type)
                }
                return resolved
            }
        }
        return data
    }

    private static func symbolName(for type: MusicSourceType) -> String {
        switch type {
        case .local: return "iphone"
        case .synology, .qnap, .ugreen, .fnos: return "externaldrive.fill"
        case .smb, .webdav, .ftp, .sftp, .nfs, .upnp: return "network"
        case .baiduPan, .aliyunDrive, .oneDrive, .dropbox, .googleDrive, .s3: return "icloud.fill"
        case .jellyfin, .emby, .plex: return "play.tv.fill"
        }
    }

    /// 比较两年总时长 → 同比百分比 (正 = 增长, 负 = 减少)。
    @MainActor
    static func yearOverYearGrowth(currentYear: Int) -> Double? {
        let lastYearEntries = PlayHistoryArchiver.entries(forYear: currentYear - 1)
        let currentEntries = PlayHistoryArchiver.entries(forYear: currentYear)
        let prev = lastYearEntries.reduce(0.0) { $0 + $1.listenedSec }
        let curr = currentEntries.reduce(0.0) { $0 + $1.listenedSec }
        guard prev > 0 else { return nil }
        return (curr - prev) / prev
    }

    // MARK: - Pure compute

    nonisolated static func compute(year: Int, entries: [PlayHistoryStore.Entry], songLookup: [String: Song]) -> YearlyReportData {
        guard !entries.isEmpty else {
            return YearlyReportData(year: year, isEmpty: true)
        }

        let totalSec = entries.reduce(0.0) { $0 + $1.listenedSec }
        let totalEntries = entries.count
        let uniqueSongCount = Set(entries.map(\.songID)).count
        let uniqueArtistCount = Set(entries.map(\.artistName).filter { !$0.isEmpty }).count

        // Top artists / songs / albums
        let artistGroups = Dictionary(grouping: entries, by: \.artistName)
        let topArtists: [YearlyReportData.RankedItem] = artistGroups
            .compactMap { name, plays in
                guard !name.isEmpty else { return nil }
                let totalListened = plays.reduce(0.0) { $0 + $1.listenedSec }
                return YearlyReportData.RankedItem(
                    id: "artist:\(name)",
                    title: name,
                    subtitle: nil,
                    playCount: plays.count,
                    totalSec: totalListened
                )
            }
            .sorted { $0.playCount > $1.playCount }

        let songGroups = Dictionary(grouping: entries, by: \.songID)
        let topSongs: [YearlyReportData.RankedItem] = songGroups
            .compactMap { id, plays -> YearlyReportData.RankedItem? in
                guard let first = plays.first else { return nil }
                return YearlyReportData.RankedItem(
                    id: "song:\(id)",
                    title: first.songTitle,
                    subtitle: first.artistName.isEmpty ? nil : first.artistName,
                    playCount: plays.count,
                    totalSec: plays.reduce(0.0) { $0 + $1.listenedSec }
                )
            }
            .sorted { $0.playCount > $1.playCount }

        let albumGroups = Dictionary(grouping: entries) { e -> String in
            "\(e.albumTitle)|\(e.artistName)"
        }
        let topAlbums: [YearlyReportData.RankedItem] = albumGroups
            .compactMap { key, plays -> YearlyReportData.RankedItem? in
                guard let first = plays.first, !first.albumTitle.isEmpty else { return nil }
                return YearlyReportData.RankedItem(
                    id: "album:\(key)",
                    title: first.albumTitle,
                    subtitle: first.artistName.isEmpty ? nil : first.artistName,
                    playCount: plays.count,
                    totalSec: plays.reduce(0.0) { $0 + $1.listenedSec }
                )
            }
            .sorted { $0.playCount > $1.playCount }

        // 首播之歌
        let firstSongEntry = entries.min(by: { $0.playedAt < $1.playedAt })

        // 单歌最多次
        let mostPlayedSongEntry = topSongs.first

        // 最长连听: 相邻 entries 间隔 < 5min 视为同一段。
        let connectedSessions = computeLongestSession(entries: entries)

        // 最晚一次
        let latestEntry = entries.max(by: { $0.playedAt < $1.playedAt })

        // 24h 时段分布 (0-23 各小时的总秒数)
        let calendar = Calendar.current
        var hourBuckets = Array(repeating: 0.0, count: 24)
        for e in entries {
            let h = calendar.component(.hour, from: e.playedAt)
            hourBuckets[h] += e.listenedSec
        }
        let peakHour = hourBuckets.indices.max(by: { hourBuckets[$0] < hourBuckets[$1] }) ?? 0
        // 18-06 占比 → DayCycle
        let nightSec = (18..<24).reduce(0.0) { $0 + hourBuckets[$1] }
            + (0..<6).reduce(0.0) { $0 + hourBuckets[$1] }
        let nightRatio = totalSec > 0 ? nightSec / totalSec : 0

        // 月份分布
        var monthBuckets = Array(repeating: 0.0, count: 12)
        for e in entries {
            let m = calendar.component(.month, from: e.playedAt)
            if m >= 1, m <= 12 { monthBuckets[m - 1] += e.listenedSec }
        }
        let peakMonthIndex = monthBuckets.indices.max(by: { monthBuckets[$0] < monthBuckets[$1] }) ?? 0
        // 该月 Top 1 歌
        let peakMonthEntries = entries.filter { calendar.component(.month, from: $0.playedAt) == peakMonthIndex + 1 }
        let peakMonthTopSong: String? = {
            let groups = Dictionary(grouping: peakMonthEntries, by: \.songID)
            let top = groups.max(by: { $0.value.count < $1.value.count })
            return top?.value.first?.songTitle
        }()

        // 音乐源分布
        let sourceGroups = Dictionary(grouping: entries, by: \.sourceID)
        let sourceBreakdown: [YearlyReportData.SourceBreakdown] = sourceGroups
            .map { id, plays in
                YearlyReportData.SourceBreakdown(
                    sourceID: id,
                    playCount: plays.count,
                    totalSec: plays.reduce(0.0) { $0 + $1.listenedSec }
                )
            }
            .sorted { $0.totalSec > $1.totalSec }

        // ===== 人格判定 =====

        // E/L: Top 5 艺术家累计占比
        let top5ArtistShare: Double = {
            let total = artistGroups.values.reduce(0) { $0 + $1.count }
            guard total > 0 else { return 0 }
            let top5 = topArtists.prefix(5).reduce(0) { $0 + $1.playCount }
            return Double(top5) / Double(total)
        }()
        let exploration: MusicPersonality.Exploration = top5ArtistShare < 0.35 ? .explorer : .loyalist

        // O/F: 不同 genre 数 (从 library 反查)
        var genreSet: Set<String> = []
        for entry in entries {
            if let genre = songLookup[entry.songID]?.genre, !genre.isEmpty {
                genreSet.insert(genre.lowercased())
            }
        }
        let diversity: MusicPersonality.Diversity = genreSet.count >= 6 ? .omnivore : .focused

        // N/V: year 中位数
        let songYears: [Int] = entries.compactMap { songLookup[$0.songID]?.year }
            .filter { $0 > 1900 && $0 <= calendar.component(.year, from: Date()) }
        let recencyCutoff = year - 5
        let recency: MusicPersonality.Recency
        if songYears.isEmpty {
            recency = .new   // 没数据时倾向 new (大多数人新歌占比高)
        } else {
            let sorted = songYears.sorted()
            let median = sorted[sorted.count / 2]
            recency = median >= recencyCutoff ? .new : .vintage
        }

        // D/M
        let dayCycle: MusicPersonality.DayCycle = nightRatio > 0.55 ? .moon : .day

        let personality = MusicPersonality(
            exploration: exploration,
            diversity: diversity,
            recency: recency,
            dayCycle: dayCycle
        )

        return YearlyReportData(
            year: year,
            isEmpty: false,
            totalSec: totalSec,
            totalEntries: totalEntries,
            uniqueSongCount: uniqueSongCount,
            uniqueArtistCount: uniqueArtistCount,
            topArtists: Array(topArtists.prefix(10)),
            topSongs: Array(topSongs.prefix(10)),
            topAlbums: Array(topAlbums.prefix(10)),
            firstSong: firstSongEntry.map { entryToBrief($0) },
            mostPlayedSong: mostPlayedSongEntry,
            longestSession: connectedSessions,
            latestEntry: latestEntry.map { entryToBrief($0) },
            hourDistribution: hourBuckets,
            peakHour: peakHour,
            nightRatio: nightRatio,
            monthDistribution: monthBuckets,
            peakMonth: peakMonthIndex + 1,
            peakMonthTopSong: peakMonthTopSong,
            sourceBreakdown: sourceBreakdown,
            personality: personality
        )
    }

    // MARK: - Helpers

    nonisolated private static func entryToBrief(_ entry: PlayHistoryStore.Entry) -> YearlyReportData.EntryBrief {
        YearlyReportData.EntryBrief(
            songID: entry.songID,
            songTitle: entry.songTitle,
            artistName: entry.artistName,
            playedAt: entry.playedAt
        )
    }

    /// 最长连听 session: 相邻 entries 间隔 ≤ 5 分钟视为同一段, 计算总秒数。
    nonisolated private static func computeLongestSession(entries: [PlayHistoryStore.Entry]) -> YearlyReportData.SessionInfo? {
        let sorted = entries.sorted(by: { $0.playedAt < $1.playedAt })
        guard !sorted.isEmpty else { return nil }
        let gapThreshold: TimeInterval = 5 * 60   // 5 分钟

        var bestStart: Date = sorted[0].playedAt
        var bestEnd: Date = sorted[0].playedAt.addingTimeInterval(sorted[0].listenedSec)
        var bestSec: TimeInterval = sorted[0].listenedSec
        var bestSongCount = 1

        var currentStart = bestStart
        var currentEnd = bestEnd
        var currentSec = bestSec
        var currentSongCount = 1

        for i in 1..<sorted.count {
            let entry = sorted[i]
            let gap = entry.playedAt.timeIntervalSince(currentEnd)
            if gap <= gapThreshold {
                currentEnd = entry.playedAt.addingTimeInterval(entry.listenedSec)
                currentSec += entry.listenedSec
                currentSongCount += 1
            } else {
                if currentSec > bestSec {
                    bestStart = currentStart
                    bestEnd = currentEnd
                    bestSec = currentSec
                    bestSongCount = currentSongCount
                }
                currentStart = entry.playedAt
                currentEnd = entry.playedAt.addingTimeInterval(entry.listenedSec)
                currentSec = entry.listenedSec
                currentSongCount = 1
            }
        }
        if currentSec > bestSec {
            bestStart = currentStart
            bestEnd = currentEnd
            bestSec = currentSec
            bestSongCount = currentSongCount
        }

        return YearlyReportData.SessionInfo(
            startedAt: bestStart,
            endedAt: bestEnd,
            totalSec: bestSec,
            songCount: bestSongCount
        )
    }
}

// MARK: - Data model

struct YearlyReportData: Sendable, Identifiable {
    var id: Int { year }
    let year: Int
    let isEmpty: Bool

    // 总览
    var totalSec: TimeInterval = 0
    var totalEntries: Int = 0
    var uniqueSongCount: Int = 0
    var uniqueArtistCount: Int = 0

    // Top
    var topArtists: [RankedItem] = []
    var topSongs: [RankedItem] = []
    var topAlbums: [RankedItem] = []

    // 关键时刻
    var firstSong: EntryBrief?
    var mostPlayedSong: RankedItem?
    var longestSession: SessionInfo?
    var latestEntry: EntryBrief?

    // 时段
    var hourDistribution: [Double] = []
    var peakHour: Int = 0
    var nightRatio: Double = 0

    // 月份
    var monthDistribution: [Double] = []
    var peakMonth: Int = 1
    var peakMonthTopSong: String?

    // 音乐源
    var sourceBreakdown: [SourceBreakdown] = []

    // 人格
    var personality: MusicPersonality?

    struct RankedItem: Sendable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let playCount: Int
        let totalSec: TimeInterval
    }

    struct EntryBrief: Sendable {
        let songID: String
        let songTitle: String
        let artistName: String
        let playedAt: Date
    }

    struct SessionInfo: Sendable {
        let startedAt: Date
        let endedAt: Date
        let totalSec: TimeInterval
        let songCount: Int
    }

    struct SourceBreakdown: Sendable, Identifiable {
        var id: String { sourceID }
        let sourceID: String
        let playCount: Int
        let totalSec: TimeInterval
        /// 已 resolve 的 source 显示名 (analyze 时从 SourcesStore 烘到 data,
        /// 这样 UI 层不用 @Environment, 分享 ImageRenderer 拍快照也能正常工作)。
        var displayName: String = "未知音乐源"
        /// SF Symbol 名 (e.g. "iphone" / "externaldrive.fill" / "network" /
        /// "icloud.fill" / "play.tv.fill" / "music.note"), 同样 analyze 时填。
        var iconSymbol: String = "music.note"
    }
}

extension YearlyReportData {
    /// 总秒数 → "X 小时 Y 分" 文案。
    var totalDurationDisplay: String {
        let hours = Int(totalSec / 3600)
        let minutes = Int(totalSec.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分钟"
    }

    /// 主导时段 → 文案 (清晨 / 正午 / 黄昏 / 深夜)
    var timeOfDayLabel: String {
        switch peakHour {
        case 5...8: return "清晨"
        case 9...13: return "上午"
        case 14...17: return "下午"
        case 18...22: return "傍晚"
        default: return "深夜"
        }
    }

    /// 主导时段 → asset name (timeofday_dawn / noon / dusk / night)
    var timeOfDayAsset: String {
        switch peakHour {
        case 5...8: return "timeofday_dawn"
        case 9...14: return "timeofday_noon"
        case 15...18: return "timeofday_dusk"
        default: return "timeofday_night"
        }
    }
}
