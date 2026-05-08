import Foundation
import PrimuseKit

/// 把 `PlayHistoryStore` 的 entries 按年份归档到独立 JSON 文件。
///
/// **为什么需要归档**: PlayHistoryStore 上限 5000 条 FIFO evict, 重度听歌
/// 用户跨年时早期月份的 entries 会被裁掉, 年度报告就看不到完整一年的数据。
/// 归档保证每个跨过的年都有独立 JSON 留底, 可以无限期回查。
///
/// 文件路径: `Application Support/Primuse/yearly-archives/year-<YYYY>.json`
///
/// 触发时机:
/// 1. App 启动时检查 `lastArchivedYear`, 把上次归档之后到当前年-1 之间的
///    每个年份都归档一次。
/// 2. 12/28 之后启动也预归档当前年 (防止用户在 12/31 当天没开 app 跨年)。
///
/// 大小: 2k 条 entries 约 200KB JSON, 很小。
@MainActor
enum PlayHistoryArchiver {
    private static let directoryName = "yearly-archives"
    private static let lastArchivedYearKey = "primuse.playHistory.lastArchivedYear"

    struct ArchivedYear: Codable, Sendable {
        let year: Int
        let entries: [PlayHistoryStore.Entry]
        let archivedAt: Date
    }

    /// 启动时调一次。
    static func runIfNeeded(history: PlayHistoryStore = .shared) {
        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        let currentDay = calendar.component(.day, from: now)
        let lastArchivedYear = UserDefaults.standard.integer(forKey: lastArchivedYearKey)

        let entries = history.entries
        let entriesByYear = Dictionary(grouping: entries) {
            calendar.component(.year, from: $0.playedAt)
        }

        // 第一次跑 (lastArchivedYear == 0): 从最早 entry 所在年开始, 把往年都
        // 归档一次。之后每次启动只归档新跨过的年。
        let firstYearToConsider: Int
        if lastArchivedYear == 0 {
            firstYearToConsider = entriesByYear.keys.min() ?? currentYear
        } else {
            firstYearToConsider = lastArchivedYear + 1
        }

        // 归档完整跨过的年 (current-1 及之前)
        if firstYearToConsider < currentYear {
            for year in firstYearToConsider..<currentYear {
                let yearEntries = entriesByYear[year] ?? []
                archive(year: year, entries: yearEntries)
            }
        }

        // 12/28 之后预归档当前年。即便已归档过, 后续 entries 增加时再归档一次
        // 覆盖之前的版本 ── 文件 atomic write, 不会留半成品。
        if currentMonth == 12 && currentDay >= 28 {
            let yearEntries = entriesByYear[currentYear] ?? []
            archive(year: currentYear, entries: yearEntries)
        }

        // lastArchivedYear 标记到 currentYear - 1 (完整年)。当前年随时可能再来
        // entries, 不算"完成归档"。
        UserDefaults.standard.set(max(currentYear - 1, lastArchivedYear), forKey: lastArchivedYearKey)
    }

    /// 加载某年的 archive。返回 nil 表示没归档过。
    static func loadArchive(year: Int) -> ArchivedYear? {
        let url = archiveURL(for: year)
        guard let data = try? Data(contentsOf: url),
              let archive = try? makeDecoder().decode(ArchivedYear.self, from: data)
        else { return nil }
        return archive
    }

    /// 列出所有已归档的年份, 倒序 (最近年份在前)。
    static func availableArchivedYears() -> [Int] {
        let dir = archiveDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        let years: [Int] = names.compactMap { name in
            // year-2026.json
            guard name.hasPrefix("year-"), name.hasSuffix(".json") else { return nil }
            let stem = name.dropFirst("year-".count).dropLast(".json".count)
            return Int(stem)
        }
        return years.sorted(by: >)
    }

    /// 给定年份, 优先返回 archive 的 entries; 没归档则从 live store 过滤当年。
    /// 适合 YearlyReportAnalyzer 用 ── 不关心数据来源, 只要拿到该年所有 entries。
    static func entries(forYear year: Int, history: PlayHistoryStore = .shared) -> [PlayHistoryStore.Entry] {
        if let archive = loadArchive(year: year) {
            return archive.entries
        }
        let calendar = Calendar.current
        return history.entries.filter { calendar.component(.year, from: $0.playedAt) == year }
    }

    // MARK: - Internals

    private static func archive(year: Int, entries: [PlayHistoryStore.Entry]) {
        let archive = ArchivedYear(year: year, entries: entries, archivedAt: Date())
        let url = archiveURL(for: year)
        do {
            try ensureDirectory()
            let data = try makeEncoder().encode(archive)
            try data.write(to: url, options: .atomic)
            plog("📦 PlayHistoryArchiver: archived year=\(year), entries=\(entries.count)")
        } catch {
            plog("⚠️ PlayHistoryArchiver: archive year=\(year) failed: \(error.localizedDescription)")
        }
    }

    private static func archiveURL(for year: Int) -> URL {
        archiveDirectory().appendingPathComponent("year-\(year).json")
    }

    private static func archiveDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: archiveDirectory(), withIntermediateDirectories: true)
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
