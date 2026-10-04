import Foundation
import PrimuseKit

/// 年度报告自动弹出触发判定。
///
/// 规则:
/// - **时机**: 每年 1 月 (1/1 起的任意一天) 用户启动 / 切前台 app 时检查
/// - **条件**: 上一年 PlayHistory 跨度 ≥ 2 个不同月份、且够出一份报告 (避免新装用户
///   只听过 12/30 然后 1/1 弹一份基本是空白的报告)
/// - **去重**: 弹过一次后写 UserDefaults, 整年不再自动弹 (随时还能在「听歌统计」里看)
@MainActor
enum YearlyReportAutoTrigger {
    private static let lastAutoShownYearKey = "primuse.yearlyReport.lastAutoShownForYear"
    /// 跨度阈值: 上一年至少听音乐覆盖 N 个不同月份才弹。
    private static let minDistinctMonths = 2

    /// 该自动弹哪一年的报告；返回非 nil 时内部已记下「已弹」，同一年不会再返回。
    /// 报告本身由弹出的页面在后台算。
    static func yearToShow() -> Int? {
        let now = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)

        // 必须 1 月。其他月份既不弹也不更新 last shown 标记 (保留给次年 1 月弹)。
        guard currentMonth == 1 else { return nil }

        let lastYear = currentYear - 1

        // 已经弹过去年的报告 → 跳过
        let alreadyShown = UserDefaults.standard.integer(forKey: lastAutoShownYearKey)
        guard alreadyShown < lastYear else { return nil }

        // 优先读 archive (PlayHistoryArchiver 启动时归档过), 没有则从 live entries
        // 过滤当年 ── 跨年新装用户去年没数据自然不会弹。
        let entries = PlayHistoryStore.musicEntries(
            PlayHistoryArchiver.entries(forYear: lastYear),
            excluding: PlayHistoryStore.shared.spokenWordSongIDs
        )
        let distinctMonths = Set(entries.map { calendar.component(.month, from: $0.playedAt) })
        // 数据不够: 不弹, 也不记录 lastShown ── 万一下次启动数据更全 (刚归档完或
        // CloudKit 同步过来), 仍有机会弹。
        guard distinctMonths.count >= minDistinctMonths,
              entries.count >= ListeningYearReportPolicy.minimumPlays else { return nil }

        UserDefaults.standard.set(lastYear, forKey: lastAutoShownYearKey)
        return lastYear
    }
}
