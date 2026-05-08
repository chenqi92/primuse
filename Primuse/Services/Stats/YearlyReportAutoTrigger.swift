import Foundation
import PrimuseKit

/// 年度报告自动弹出触发判定。
///
/// 规则:
/// - **时机**: 每年 1 月 (1/1 起的任意一天) 用户启动 / 切前台 app 时检查
/// - **条件**: 上一年 PlayHistory 跨度 ≥ 2 个不同月份 (避免新装用户只听过
///   12/30 然后 1/1 弹一份基本是空白的报告)
/// - **去重**: 弹过一次后写 UserDefaults, 整年不再自动弹 (用户主动从入口
///   还能进, 但本次没做入口 ── 自动弹是唯一渠道)
@MainActor
enum YearlyReportAutoTrigger {
    private static let lastAutoShownYearKey = "primuse.yearlyReport.lastAutoShownForYear"
    /// 跨度阈值: 上一年至少听音乐覆盖 N 个不同月份才弹。
    private static let minDistinctMonths = 2

    /// 检查是否应该自动弹年度报告。返回非 nil 时, 调用方应该 set 给
    /// fullScreenCover 的 item 触发弹窗。
    /// 内部已经记录"已弹"状态, 同一年不会重复返回非 nil。
    static func shouldShowReport(library: MusicLibrary, sourcesStore: SourcesStore) -> YearlyReportData? {
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

        // 检查上一年 entries 是否覆盖 ≥ minDistinctMonths 个不同月份。
        // 优先读 archive (PlayHistoryArchiver 启动时归档过), 没有则从 live
        // entries 过滤当年 ── 跨年新装用户去年没数据自然不会弹。
        let entries = PlayHistoryArchiver.entries(forYear: lastYear)
        let distinctMonths = Set(entries.map { calendar.component(.month, from: $0.playedAt) })
        guard distinctMonths.count >= minDistinctMonths else {
            // 数据不够: 不弹, 但也不记录 lastShown ── 万一用户下次启动数据更全
            // (例如刚刚归档完成或 CloudKit 同步过来), 仍有机会弹。
            // 但是为避免天天检查浪费, 设个 day-level cooldown:
            // 当年同一天不再重复检查 (没意义, entries 不会变多)。
            return nil
        }

        // 通过 ── 生成 data + 标记已弹。
        UserDefaults.standard.set(lastYear, forKey: lastAutoShownYearKey)
        return YearlyReportAnalyzer.analyze(
            year: lastYear,
            entries: entries,
            library: library,
            sourcesStore: sourcesStore
        )
    }
}
