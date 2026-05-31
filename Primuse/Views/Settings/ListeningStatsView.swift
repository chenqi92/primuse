import SwiftUI
import PrimuseKit

/// 听歌统计 — 本地播放历史的可视化。数据来源 PlayHistoryStore (纯本地,
/// 不上传)。包含:
/// - 时间段选择 (本周 / 本月 / 本年 / 全部)
/// - 摘要数字 (播放次数 / 总时长 / 活跃天数 / 不重复曲目)
/// - 热力图 (GitHub-style 7×N 格子, 颜色深度对应当日播放次数)
/// - Top 排行 (歌曲 / 艺术家 / 专辑 三个 tab)
struct ListeningStatsView: View {
    @State private var range: PlayHistoryStore.Range = .month
    @State private var rankTab: RankTab = .songs
    @State private var showClearConfirm = false
    private let store = PlayHistoryStore.shared

    enum RankTab: String, CaseIterable {
        case songs, artists, albums
        var label: String {
            switch self {
            case .songs: return String(localized: "stats_rank_songs")
            case .artists: return String(localized: "stats_rank_artists")
            case .albums: return String(localized: "stats_rank_albums")
            }
        }
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        Form {
            Section {
                Picker("stats_range", selection: $range) {
                    ForEach(PlayHistoryStore.Range.allCases) { r in
                        Text(LocalizedStringKey(r.localizationKey)).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }

            if store.entries.isEmpty {
                emptySection
            } else {
                summarySection
                heatmapSection
                rankingSection
                clearSection
            }
        }
        .navigationTitle("stats_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("stats_clear_confirm", isPresented: $showClearConfirm) {
            Button("delete", role: .destructive) { store.clearAll() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("stats_clear_message")
        }
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                macStatsHeader

                if store.entries.isEmpty {
                    macEmptyState
                } else {
                    macSummarySection
                    macHeatmapCard
                    macTopCards
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationTitle("stats_title")
        .task(id: range) { logHeatmapStats() }
    }

    private var macStatsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("统计")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(PMColor.textMuted)
                    Text("听歌统计")
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(PMColor.text)
                }
                Spacer()
                HStack(spacing: 5) {
                    ForEach(PlayHistoryStore.Range.allCases) { item in
                        let selected = item == range
                        Button {
                            range = item
                        } label: {
                            Text(LocalizedStringKey(item.localizationKey))
                                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? .white : PMColor.text)
                                .padding(.horizontal, 12)
                                .frame(height: 26)
                                .background(selected ? PMColor.brand : PMColor.glassBtn, in: .capsule)
                                .overlay {
                                    Capsule().strokeBorder(selected ? .clear : PMColor.cardBorder, lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(statsRangeSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
    }

    /// 设计稿副标题: "2026 年 1 月 1 日 — 今天 · 365 天"。起点取热力图首日,
    /// 天数取整个区间天数。
    private var statsRangeSubtitle: String {
        let counts = store.dailyPlayCounts(in: range)
        let start = counts.first?.date ?? Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy 年 M 月 d 日"
        return "\(df.string(from: start)) — 今天 · \(counts.count) 天"
    }

    private var macEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(PMColor.textFaint)
            Text("stats_empty_title")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text("stats_empty_desc")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 96)
        .background(PMColor.card.opacity(0.60), in: .rect(cornerRadius: 12))
    }

    // MARK: 摘要四卡 (STATS-04)

    private var macSummarySection: some View {
        let s = store.summary(in: range)
        let counts = store.dailyPlayCounts(in: range)
        let days = max(counts.count, 1)
        let totalMin = Int(s.totalSec / 60)
        let coverage = Int((Double(s.activeDays) / Double(days) * 100).rounded())
        let coverLabel = (range == .week || range == .month) ? "覆盖率" : "全年覆盖率"
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            macSummaryCell(value: decimal(s.totalPlays),
                           label: "总播放",
                           sub: playsDeltaSub(currentStart: counts.first?.date, spanDays: days, current: s.totalPlays))
            macSummaryCell(value: "\(totalMin / 60)h \(totalMin % 60)m",
                           label: "总时长",
                           sub: "\(decimal(totalMin)) 分钟")
            macSummaryCell(value: decimal(s.activeDays),
                           label: "活跃天数",
                           sub: "\(coverage)% \(coverLabel)")
            macSummaryCell(value: decimal(s.uniqueSongs),
                           label: "不重复曲目",
                           sub: "其中 \(heavyRotationCount()) 首播放 ≥ 5 次")
        }
    }

    private func macSummaryCell(value: String, label: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .tracking(-0.6)
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(verbatim: label)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .padding(.top, 4)
            Text(verbatim: sub)
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .padding(.top, 6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    /// 总播放卡副标题 —— 跟上一个等长周期比的增减。`.all` 没有"上一周期"。
    private func playsDeltaSub(currentStart: Date?, spanDays: Int, current: Int) -> String {
        guard range != .all, let curStart = currentStart,
              let prevStart = Calendar.current.date(byAdding: .day, value: -spanDays, to: curStart) else {
            return "全部历史累计"
        }
        let prev = store.entries.filter { $0.playedAt >= prevStart && $0.playedAt < curStart }.count
        guard prev > 0 else { return "暂无往期对比" }
        let pct = Int((Double(current - prev) / Double(prev) * 100).rounded())
        let vs: String
        switch range {
        case .week:  vs = "上周"
        case .month: vs = "上月"
        case .year:  vs = "去年"
        case .all:   vs = ""
        }
        return "\(pct >= 0 ? "+" : "")\(pct)% vs \(vs)"
    }

    /// 区间内播放 ≥ 5 次的歌曲数 (不重复曲目卡副标题用)。
    private func heavyRotationCount() -> Int {
        Dictionary(grouping: store.entries(in: range)) { $0.songID }
            .values.filter { $0.count >= 5 }.count
    }

    private func decimal(_ n: Int) -> String { n.formatted(.number) }

    // MARK: 热力图 (STATS-02)

    private var macHeatmapCard: some View {
        let counts = store.dailyPlayCounts(in: range)
        let weeks = groupByWeek(counts: counts, cal: Calendar.current)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "GitHub 风格热力图")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Text(verbatim: "7×\(weeks.count) = \(counts.count) 天")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
            }
            macHeatmapGrid(weeks: weeks)
            macHeatmapMonths(counts: counts)
            macHeatmapLegend
        }
        .padding(18)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    /// 7 行 × N 周。格子边长按卡片宽度平分 (上限 16pt), 满一年时正好铺满整行;
    /// 区间短 (本周/本月) 时不会被拉成巨大方块, 靠左排列。
    private func macHeatmapGrid(weeks: [[Int: (date: Date, count: Int)]]) -> some View {
        let gap: CGFloat = 3
        let maxCell: CGFloat = 16
        return GeometryReader { geo in
            let n = CGFloat(max(weeks.count, 1))
            let cell = min(maxCell, max(6, (geo.size.width - gap * (n - 1)) / n))
            HStack(alignment: .top, spacing: gap) {
                ForEach(weeks.indices, id: \.self) { wIdx in
                    let column = weeks[wIdx]
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { dow in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(column[dow].map { heatColor(count: $0.count) } ?? Color.clear)
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: maxCell * 7 + gap * 6)
    }

    private func macHeatmapMonths(counts: [(date: Date, count: Int)]) -> some View {
        let cal = Calendar.current
        var seen = Set<Int>()
        var labels: [String] = []
        for c in counts {
            let comp = cal.dateComponents([.year, .month], from: c.date)
            let key = (comp.year ?? 0) * 100 + (comp.month ?? 0)
            if seen.insert(key).inserted {
                labels.append("\(comp.month ?? 0)月")
            }
        }
        return HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { i in
                Text(verbatim: labels[i])
                    .font(.system(size: 10))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var macHeatmapLegend: some View {
        HStack(spacing: 6) {
            Spacer()
            Text(verbatim: "少").font(.system(size: 10.5)).foregroundStyle(PMColor.textFaint)
            ForEach([0, 2, 6, 10, 14], id: \.self) { v in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(heatColor(count: v))
                    .frame(width: 10, height: 10)
            }
            Text(verbatim: "多").font(.system(size: 10.5)).foregroundStyle(PMColor.textFaint)
        }
    }

    /// 设计稿色阶: 0 灰底; 1...2 / 3...6 / 7...10 / ≥11 四档品牌色透明度。
    private func heatColor(count: Int) -> Color {
        let a = PMColor.brand
        switch count {
        case 0: return PMColor.divider
        case 1..<3: return a.opacity(0.28)
        case 3..<7: return a.opacity(0.52)
        case 7..<11: return a.opacity(0.78)
        default: return a
        }
    }

    // MARK: Top 三栏 (STATS-03)

    private var macTopCards: some View {
        HStack(alignment: .top, spacing: 14) {
            macTopCard(title: "Top 歌曲", items: store.topSongs(in: range, limit: 6))
            macTopCard(title: "Top 艺术家", items: store.topArtists(in: range, limit: 6))
            macTopCard(title: "Top 专辑", items: store.topAlbums(in: range, limit: 6))
        }
    }

    private func macTopCard(title: String, items: [PlayHistoryStore.RankedItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .padding(.bottom, 10)
            if items.isEmpty {
                Text("stats_rank_empty")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx != 0 {
                        Rectangle().fill(PMColor.divider).frame(height: 0.5)
                    }
                    macTopRow(rank: idx + 1, item: item)
                        .padding(.vertical, 5)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func macTopRow(rank: Int, item: PlayHistoryStore.RankedItem) -> some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text("\(item.playCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
        }
    }
    #endif

    // MARK: - Sections

    private var emptySection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("stats_empty_title").font(.headline)
                Text("stats_empty_desc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }

    private var summarySection: some View {
        Section {
            let s = store.summary(in: range)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                summaryCell(value: "\(s.totalPlays)",
                            label: String(localized: "stats_total_plays"),
                            icon: "play.fill",
                            color: .accentColor)
                summaryCell(value: formatHours(s.totalSec),
                            label: String(localized: "stats_total_time"),
                            icon: "clock.fill",
                            color: .green)
                summaryCell(value: "\(s.activeDays)",
                            label: String(localized: "stats_active_days"),
                            icon: "calendar",
                            color: .orange)
                summaryCell(value: "\(s.uniqueSongs)",
                            label: String(localized: "stats_unique_songs"),
                            icon: "music.note",
                            color: .purple)
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryCell(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption).foregroundStyle(color)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
    }

    private var heatmapSection: some View {
        Section {
            let counts = store.dailyPlayCounts(in: range)
            let maxCount = counts.map(\.count).max() ?? 0
            VStack(alignment: .leading, spacing: 8) {
                Text("stats_heatmap_title").font(.subheadline.weight(.medium))
                heatmapGrid(counts: counts, maxCount: maxCount)
                heatmapLegend(maxCount: maxCount)
            }
            .padding(.vertical, 4)
        } footer: {
            Text("stats_heatmap_footer")
        }
        // 把每次 range 切换后的格子数 / 列数 dump 到日志, 用户拉日志能看到。
        .task(id: range) { logHeatmapStats() }
    }

    private func logHeatmapStats() {
        let counts = store.dailyPlayCounts(in: range)
        let cal = Calendar.current
        let weeks = Set(counts.map { cell -> Int in
            let comp = cal.dateComponents([.weekOfYear, .yearForWeekOfYear], from: cell.date)
            return (comp.yearForWeekOfYear ?? 0) * 100 + (comp.weekOfYear ?? 0)
        }).count
        let nonZero = counts.filter { $0.count > 0 }.count
        plog("📊 stats heatmap range=\(range.rawValue) cells=\(counts.count) weekCols=\(weeks) activeDays=\(nonZero)")
    }

    @ViewBuilder
    private func heatmapGrid(counts: [(date: Date, count: Int)], maxCount: Int) -> some View {
        // 按周分列, 周日为每列首行 (符合 iOS 中文区习惯, 也是 GitHub 用的)
        let cal = Calendar.current
        let weeks = groupByWeek(counts: counts, cal: cal)
        let cellSize: CGFloat = 14
        let cellSpacing: CGFloat = 3

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(weeks.indices, id: \.self) { wIdx in
                    let column = weeks[wIdx]
                    VStack(spacing: cellSpacing) {
                        // 7 行 (周日到周六), 缺失的日子留空
                        ForEach(0..<7, id: \.self) { dow in
                            if let cell = column[dow] {
                                heatmapCell(count: cell.count, maxCount: maxCount, size: cellSize)
                            } else {
                                Color.clear.frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func heatmapCell(count: Int, maxCount: Int, size: CGFloat) -> some View {
        let intensity: Double = {
            guard maxCount > 0, count > 0 else { return 0 }
            // log scale 让单次播放也能可见, 高频日子不会把低频压成全无色
            let ratio = log(Double(count) + 1) / log(Double(maxCount) + 1)
            return max(0.15, ratio)
        }()
        return RoundedRectangle(cornerRadius: 3)
            .fill(count == 0 ? Color.secondary.opacity(0.10) : Color.accentColor.opacity(intensity))
            .frame(width: size, height: size)
    }

    private func heatmapLegend(maxCount: Int) -> some View {
        HStack(spacing: 4) {
            Text("stats_legend_less").font(.caption2).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { i in
                let intensity = Double(i) * 0.22 + (i == 0 ? 0.10 : 0.15)
                RoundedRectangle(cornerRadius: 2)
                    .fill(i == 0 ? Color.secondary.opacity(0.10) : Color.accentColor.opacity(intensity))
                    .frame(width: 10, height: 10)
            }
            Text("stats_legend_more").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            if maxCount > 0 {
                Text(String(format: String(localized: "stats_legend_max_format"), maxCount))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 按周拆分: 返回 [[dayOfWeek(0=周日..6=周六): cell]], 每个内层是一周。
    private func groupByWeek(counts: [(date: Date, count: Int)],
                              cal: Calendar) -> [[Int: (date: Date, count: Int)]] {
        guard !counts.isEmpty else { return [] }
        var weeks: [[Int: (Date, Int)]] = []
        var currentWeek: [Int: (Date, Int)] = [:]
        var lastWeekOfYear: Int = -1

        for cell in counts {
            let comp = cal.dateComponents([.weekday, .weekOfYear, .yearForWeekOfYear], from: cell.date)
            let dow = (comp.weekday ?? 1) - 1  // weekday: 1=Sunday → 0
            let weekKey = (comp.yearForWeekOfYear ?? 0) * 100 + (comp.weekOfYear ?? 0)
            if weekKey != lastWeekOfYear {
                if !currentWeek.isEmpty { weeks.append(currentWeek) }
                currentWeek = [:]
                lastWeekOfYear = weekKey
            }
            currentWeek[dow] = (cell.date, cell.count)
        }
        if !currentWeek.isEmpty { weeks.append(currentWeek) }
        return weeks
    }

    private var rankingSection: some View {
        Section {
            Picker("rank_by", selection: $rankTab) {
                ForEach(RankTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            let items = rankItems()
            if items.isEmpty {
                Text("stats_rank_empty").foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    rankingRow(rank: index + 1, item: item)
                }
            }
        } header: {
            Text("stats_top_header")
        }
    }

    private func rankItems() -> [PlayHistoryStore.RankedItem] {
        switch rankTab {
        case .songs: return store.topSongs(in: range)
        case .artists: return store.topArtists(in: range)
        case .albums: return store.topAlbums(in: range)
        }
    }

    private func rankingRow(rank: Int, item: PlayHistoryStore.RankedItem) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(rank <= 3 ? Color.accentColor : .secondary)
                .frame(width: 24, alignment: .leading)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: String(localized: "stats_play_count_format"), item.playCount))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Text(formatHours(item.totalSec))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("stats_clear_action")
                }
            }
        } footer: {
            Text("stats_privacy_footer")
        }
    }

    // MARK: - Format helpers

    private func formatHours(_ sec: TimeInterval) -> String {
        if sec < 60 {
            return String(format: String(localized: "stats_seconds_format"), Int(sec))
        }
        let totalMin = Int(sec / 60)
        if totalMin < 60 {
            return String(format: String(localized: "stats_minutes_format"), totalMin)
        }
        let hours = totalMin / 60
        let minutes = totalMin % 60
        return String(format: String(localized: "stats_hours_minutes_format"), hours, minutes)
    }
}
