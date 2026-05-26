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
                    HStack(alignment: .top, spacing: 24) {
                        macHeatmapSection
                            .frame(width: 340)
                        macRankingSection
                            .frame(maxWidth: .infinity)
                    }
                    macClearSection
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 120)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationTitle("stats_title")
        .task(id: range) { logHeatmapStats() }
        .alert("stats_clear_confirm", isPresented: $showClearConfirm) {
            Button("delete", role: .destructive) { store.clearAll() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("stats_clear_message")
        }
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

    private var statsRangeSubtitle: String {
        switch range {
        case .week: return "最近 7 天 · 本地播放历史"
        case .month: return "最近 30 天 · 本地播放历史"
        case .year: return "最近 365 天 · 本地播放历史"
        }
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

    private var macSummarySection: some View {
        let s = store.summary(in: range)
        return VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                macSummaryCell(value: "\(s.totalPlays)",
                               label: String(localized: "stats_total_plays"),
                               sub: "播放次数",
                               color: PMColor.brand)
                macSummaryCell(value: formatHours(s.totalSec),
                               label: String(localized: "stats_total_time"),
                               sub: "累计时长",
                               color: PMColor.ok)
                macSummaryCell(value: "\(s.activeDays)",
                               label: String(localized: "stats_active_days"),
                               sub: "有播放的日子",
                               color: PMColor.warn)
                macSummaryCell(value: "\(s.uniqueSongs)",
                               label: String(localized: "stats_unique_songs"),
                               sub: "不重复曲目",
                               color: Color(red: 0.64, green: 0.48, blue: 0.96))
            }
        }
    }

    private func macSummaryCell(value: String, label: String, sub: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(PMColor.text)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PMColor.textMuted)
            Text(sub)
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: 10, height: 10)
                .padding(14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macHeatmapSection: some View {
        let counts = store.dailyPlayCounts(in: range)
        let maxCount = counts.map(\.count).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Label("stats_heatmap_title", systemImage: "square.grid.3x3.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
            heatmapGrid(counts: counts, maxCount: maxCount)
            heatmapLegend(maxCount: maxCount)
            Text("stats_heatmap_footer")
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
        }
        .padding(18)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macRankingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("stats_top_header", systemImage: "chart.bar.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Picker("rank_by", selection: $rankTab) {
                    ForEach(RankTab.allCases, id: \.self) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            let items = rankItems()
            if items.isEmpty {
                Text("stats_rank_empty")
                    .foregroundStyle(PMColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        rankingRow(rank: index + 1, item: item)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        if index != items.count - 1 {
                            Divider().overlay(PMColor.divider).padding(.leading, 48)
                        }
                    }
                }
                .background(PMColor.card.opacity(0.60), in: .rect(cornerRadius: 8))
            }
        }
        .padding(18)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macClearSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(role: .destructive) {
                showClearConfirm = true
            } label: {
                Label("stats_clear_action", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            Text("stats_privacy_footer")
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
        }
        .padding(16)
        .background(PMColor.card.opacity(0.60), in: .rect(cornerRadius: 12))
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
