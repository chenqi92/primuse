import SwiftUI
import PrimuseKit

/// 听歌统计 — 本地播放历史的可视化。数据来源 PlayHistoryStore (纯本地,
/// 不上传)。包含:
/// - 时间段选择 (本周 / 本月 / 本年 / 全部)
/// - 摘要数字 (播放次数 / 总时长 / 活跃天数 / 不重复曲目)
/// - 热力图 (GitHub-style 7×N 格子, 颜色深度对应当日播放次数)
/// - Top 排行 (歌曲 / 艺术家 / 专辑 三个 tab)
struct ListeningStatsView: View {
    @Environment(SourcesStore.self) private var sourcesStore
    @AppStorage("stats.selectedServerSourceID")
    private var selectedServerSourceID = ""
    #if os(macOS)
    @State private var range: PlayHistoryStore.Range = .year
    #else
    @State private var range: PlayHistoryStore.Range = .month
    #endif
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
        VStack(spacing: 0) {
            if !serverSources.isEmpty {
                statsSourcePicker
                Divider()
            }

            if let source = selectedServerSource {
                ServerListeningStatsView(source: source)
            } else {
                localBody
            }
        }
        .onChange(of: serverSourceIDs, initial: true) { _, validIDs in
            if !selectedServerSourceID.isEmpty,
               !validIDs.contains(selectedServerSourceID) {
                selectedServerSourceID = ""
            }
        }
    }

    @ViewBuilder
    private var localBody: some View {
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
                .settingsAnchor("stats.range")
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

    private var serverSources: [MusicSource] {
        sourcesStore.sources.filter {
            $0.isEnabled
                && !$0.isDeleted
                && $0.type.serverListeningStatsCapability != .unavailable
        }
    }

    private var serverSourceIDs: [String] {
        serverSources.map(\.id)
    }

    private var selectedServerSource: MusicSource? {
        serverSources.first { $0.id == selectedServerSourceID }
    }

    private var statsSourcePicker: some View {
        HStack(spacing: 12) {
            Label("stats_data_source", systemImage: "server.rack")
                .font(.subheadline.weight(.medium))
            Spacer()
            Picker("stats_data_source", selection: $selectedServerSourceID) {
                Text("stats_source_local").tag("")
                ForEach(serverSources) { source in
                    Text(source.name).tag(source.id)
                }
            }
            .settingsAnchor("stats.source")
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 48)
        #if os(macOS)
        .background(PMColor.bgElev.opacity(0.72))
        #else
        .background(.regularMaterial)
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        let snapshot = makeMacStatsSnapshot()
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                macStatsHeader(snapshot: snapshot)

                if store.entries.isEmpty {
                    macEmptyState
                } else {
                    macSummarySection(snapshot: snapshot)
                    macHeatmapCard(days: snapshot.dailyStats)
                    macTopCards(snapshot: snapshot)
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

    private func macStatsHeader(snapshot: MacStatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("stats_section_label")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(PMColor.textMuted)
                    Text("stats_title")
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
            Text(statsRangeSubtitle(days: snapshot.dailyStats))
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
    }

    /// 设计稿副标题: "2026 年 1 月 1 日 — 今天 · 365 天"。起点取热力图首日,
    /// 天数取整个区间天数。
    private func statsRangeSubtitle(days: [MacDailyStat]) -> String {
        let start = days.first?.date ?? Date()
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .none
        return String(
            format: String(localized: "stats_range_subtitle_format"),
            df.string(from: start),
            days.count
        )
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

    private func macSummarySection(snapshot: MacStatsSnapshot) -> some View {
        let s = snapshot.summary
        let days = max(snapshot.dailyStats.count, 1)
        let totalMin = Int(s.totalSec / 60)
        let coverage = (Double(s.activeDays) / Double(days) * 100).rounded().finiteInt()
        let coverLabel = (range == .week || range == .month)
            ? String(localized: "stats_coverage")
            : String(localized: "stats_year_coverage")
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
            macSummaryCell(value: decimal(s.totalPlays),
                           label: String(localized: "stats_total_plays"),
                           sub: playsDeltaSub(previous: snapshot.previousPlayCount, current: s.totalPlays))
            macSummaryCell(value: "\(totalMin / 60)h \(totalMin % 60)m",
                           label: String(localized: "stats_total_duration"),
                           sub: String(
                               format: String(localized: "stats_minutes_format"),
                               totalMin
                           ))
            macSummaryCell(value: decimal(s.activeDays),
                           label: String(localized: "stats_active_days"),
                           sub: String(
                               format: String(localized: "stats_coverage_format"),
                               coverage,
                               coverLabel
                           ))
            macSummaryCell(value: decimal(s.uniqueSongs),
                           label: String(localized: "stats_unique_songs"),
                           sub: String(
                               format: String(localized: "stats_heavy_rotation_format"),
                               snapshot.heavyRotationCount
                           ))
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
    private func playsDeltaSub(previous: Int?, current: Int) -> String {
        guard let previous else {
            return String(localized: "stats_all_time_total")
        }
        guard previous > 0 else { return String(localized: "stats_no_previous_comparison") }
        let pct = ((Double(current) - Double(previous)) / Double(previous) * 100)
            .rounded()
            .finiteInt()
        let vs: String
        switch range {
        case .week:  vs = String(localized: "stats_previous_week")
        case .month: vs = String(localized: "stats_previous_month")
        case .year:  vs = String(localized: "stats_previous_year")
        case .all:   vs = ""
        }
        return String(
            format: String(localized: "stats_comparison_format"),
            "\(pct >= 0 ? "+" : "")\(pct)%",
            vs
        )
    }

    private func decimal(_ n: Int) -> String { n.formatted(.number) }

    // MARK: 热力图 (STATS-02)

    private func macHeatmapCard(days: [MacDailyStat]) -> some View {
        let calendar = Calendar.current
        let weeks = makeMacHeatmapWeeks(
            days: days,
            calendar: calendar,
            displayEnd: macHeatmapDisplayEnd(now: Date(), calendar: calendar)
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("stats_heatmap_style_title")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Text(verbatim: String(
                    format: String(localized: "stats_heatmap_dimensions_format"),
                    weeks.count,
                    days.count
                ))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
            }
            macHeatmapGrid(weeks: weeks, calendar: calendar)
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
    private func macHeatmapGrid(weeks: [MacHeatmapWeek], calendar: Calendar) -> some View {
        let gap: CGFloat = 3
        let maxCell: CGFloat = 16
        let weekdayWidth: CGFloat = 20
        let weekdaySymbols = macWeekdaySymbols(calendar: calendar)
        return GeometryReader { geo in
            let n = CGFloat(max(weeks.count, 1))
            let gridWidth = max(0, geo.size.width - weekdayWidth - 8)
            let cell = min(maxCell, max(6, (gridWidth - gap * (n - 1)) / n))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Color.clear.frame(width: weekdayWidth, height: 12)
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(weeks.indices, id: \.self) { weekIndex in
                            let label = macMonthLabel(
                                for: weeks,
                                weekIndex: weekIndex,
                                calendar: calendar
                            )
                            Color.clear
                                .frame(width: cell, height: 12)
                                .overlay(alignment: .leading) {
                                    if let label {
                                        Text(verbatim: label)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(PMColor.textFaint)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: gap) {
                        ForEach(weekdaySymbols.indices, id: \.self) { index in
                            Text(verbatim: weekdaySymbols[index])
                                .font(.system(size: 9))
                                .foregroundStyle(PMColor.textFaint)
                                .frame(width: weekdayWidth, height: cell, alignment: .trailing)
                        }
                    }
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(weeks) { week in
                            VStack(spacing: gap) {
                                ForEach(week.cells) { heatmapCell in
                                    macHeatmapCell(heatmapCell, size: cell)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 12 + 6 + maxCell * 7 + gap * 6)
    }

    private func macHeatmapCell(_ cell: MacHeatmapCell, size: CGFloat) -> some View {
        let fill: Color
        if let day = cell.day {
            fill = heatColor(count: day.count)
        } else if cell.isFuture && cell.isInDisplayRange {
            fill = PMColor.divider.opacity(0.52)
        } else {
            fill = PMColor.divider.opacity(0.34)
        }
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay {
                if cell.isFuture && cell.isInDisplayRange {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(PMColor.cardBorder.opacity(0.7), lineWidth: 0.5)
                }
            }
            .help(macHeatmapTooltip(for: cell))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(macHeatmapTooltip(for: cell))
    }

    private func macHeatmapTooltip(for cell: MacHeatmapCell) -> String {
        let date = cell.date.formatted(date: .long, time: .omitted)
        guard let day = cell.day else { return "\(date)\n—" }
        let plays = String(
            format: String(localized: "stats_play_count_format"),
            day.count
        )
        return "\(date)\n\(plays) · \(formatHours(day.totalSec))"
    }

    private func macWeekdaySymbols(calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        let symbols = formatter.veryShortWeekdaySymbols ?? [
            String(localized: "weekday_sunday_short"),
            String(localized: "weekday_monday_short"),
            String(localized: "weekday_tuesday_short"),
            String(localized: "weekday_wednesday_short"),
            String(localized: "weekday_thursday_short"),
            String(localized: "weekday_friday_short"),
            String(localized: "weekday_saturday_short")
        ]
        let start = min(max(calendar.firstWeekday - 1, 0), 6)
        return Array(symbols[start...] + symbols[..<start])
    }

    private func macMonthLabel(
        for weeks: [MacHeatmapWeek],
        weekIndex: Int,
        calendar: Calendar
    ) -> String? {
        let week = weeks[weekIndex]
        let labelDate: Date?
        if weekIndex == 0 {
            labelDate = week.cells.first(where: \.isInDisplayRange)?.date
        } else {
            labelDate = week.cells.first(where: {
                $0.isInDisplayRange && calendar.component(.day, from: $0.date) == 1
            })?.date
        }
        guard let labelDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: labelDate)
    }

    private var macHeatmapLegend: some View {
        HStack(spacing: 6) {
            Spacer()
            Text("stats_heatmap_less").font(.system(size: 10.5)).foregroundStyle(PMColor.textFaint)
            ForEach([0, 2, 6, 10, 14], id: \.self) { v in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(heatColor(count: v))
                    .frame(width: 10, height: 10)
            }
            Text("stats_heatmap_more").font(.system(size: 10.5)).foregroundStyle(PMColor.textFaint)
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

    private func macTopCards(snapshot: MacStatsSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            macTopCard(title: String(localized: "stats_top_songs"), items: snapshot.topSongs)
            macTopCard(title: String(localized: "stats_top_artists"), items: snapshot.topArtists)
            macTopCard(title: String(localized: "stats_top_albums"), items: snapshot.topAlbums)
        }
    }

    private struct MacDailyStat: Identifiable {
        let date: Date
        let count: Int
        let totalSec: TimeInterval
        var id: Date { date }
    }

    private struct MacHeatmapCell: Identifiable {
        let date: Date
        let day: MacDailyStat?
        let isFuture: Bool
        let isInDisplayRange: Bool
        var id: Date { date }
    }

    private struct MacHeatmapWeek: Identifiable {
        let start: Date
        let cells: [MacHeatmapCell]
        var id: Date { start }
    }

    private struct MacStatsSnapshot {
        let summary: PlayHistoryStore.Summary
        let dailyStats: [MacDailyStat]
        let previousPlayCount: Int?
        let heavyRotationCount: Int
        let topSongs: [PlayHistoryStore.RankedItem]
        let topArtists: [PlayHistoryStore.RankedItem]
        let topAlbums: [PlayHistoryStore.RankedItem]
    }

    /// 同一次 SwiftUI 渲染共享统计结果，避免标题、摘要、热力图和三个榜单
    /// 分别再次过滤完整播放历史。
    private func makeMacStatsSnapshot() -> MacStatsSnapshot {
        let now = Date()
        let currentStart = macRangeStartDate(now: now)
        let previousInterval = macPreviousRangeInterval(now: now, currentStart: currentStart)
        var scopedEntries: [PlayHistoryStore.Entry] = []
        var previousPlayCount = 0
        for entry in store.entries {
            if entry.playedAt >= currentStart, entry.playedAt <= now {
                scopedEntries.append(entry)
            } else if let previousInterval, previousInterval.contains(entry.playedAt) {
                previousPlayCount += 1
            }
        }

        let calendar = Calendar.current
        let dayBuckets = Dictionary(grouping: scopedEntries) {
            calendar.startOfDay(for: $0.playedAt)
        }
        let dailyStats = makeDailyStats(
            dayBuckets: dayBuckets,
            now: now,
            currentStart: currentStart
        )
        let playsBySong = Dictionary(grouping: scopedEntries, by: \.songID)
        let summary = PlayHistoryStore.Summary(
            totalPlays: scopedEntries.count,
            totalSec: scopedEntries.reduce(0) { $0 + $1.listenedSec },
            activeDays: dayBuckets.count,
            uniqueSongs: playsBySong.count
        )

        return MacStatsSnapshot(
            summary: summary,
            dailyStats: dailyStats,
            previousPlayCount: range == .all ? nil : previousPlayCount,
            heavyRotationCount: playsBySong.values.lazy.filter { $0.count >= 5 }.count,
            topSongs: rankedSongs(playsBySong, limit: 6),
            topArtists: rankedArtists(scopedEntries, limit: 6),
            topAlbums: rankedAlbums(scopedEntries, limit: 6)
        )
    }

    private func makeDailyStats(
        dayBuckets: [Date: [PlayHistoryStore.Entry]],
        now: Date,
        currentStart: Date
    ) -> [MacDailyStat] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: now)
        let rawStart: Date
        if range == .all {
            rawStart = dayBuckets.keys.min() ?? end
        } else {
            rawStart = calendar.startOfDay(for: currentStart)
        }
        let floor = calendar.date(byAdding: .day, value: -740, to: end) ?? rawStart
        var cursor = max(rawStart, floor)
        var result: [MacDailyStat] = []
        while cursor <= end {
            let entries = dayBuckets[cursor] ?? []
            result.append(MacDailyStat(
                date: cursor,
                count: entries.count,
                totalSec: entries.reduce(0) { $0 + $1.listenedSec }
            ))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)
                ?? cursor.addingTimeInterval(86_400)
        }
        return result
    }

    private func macRangeStartDate(now: Date) -> Date {
        let calendar = Calendar.current
        switch range {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start ?? now
        case .year:
            return calendar.dateInterval(of: .year, for: now)?.start ?? now
        case .all:
            return .distantPast
        }
    }

    private func macPreviousRangeInterval(now: Date, currentStart: Date) -> DateInterval? {
        let calendar = Calendar.current
        let component: Calendar.Component
        switch range {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .all: return nil
        }
        guard let start = calendar.date(byAdding: component, value: -1, to: currentStart),
              let end = calendar.date(byAdding: component, value: -1, to: now) else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }

    private func makeMacHeatmapWeeks(
        days: [MacDailyStat],
        calendar: Calendar,
        displayEnd: Date
    ) -> [MacHeatmapWeek] {
        guard let firstDay = days.first?.date,
              let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start,
              let lastWeekStart = calendar.dateInterval(of: .weekOfYear, for: displayEnd)?.start else {
            return []
        }

        let statsByDate = Dictionary(uniqueKeysWithValues: days.map {
            (calendar.startOfDay(for: $0.date), $0)
        })
        let displayStart = calendar.startOfDay(for: firstDay)
        let normalizedDisplayEnd = calendar.startOfDay(for: displayEnd)
        let today = calendar.startOfDay(for: Date())
        var result: [MacHeatmapWeek] = []
        var weekStart = firstWeekStart
        while weekStart <= lastWeekStart {
            let cells = (0..<7).compactMap { offset -> MacHeatmapCell? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else {
                    return nil
                }
                let normalizedDate = calendar.startOfDay(for: date)
                return MacHeatmapCell(
                    date: normalizedDate,
                    day: statsByDate[normalizedDate],
                    isFuture: normalizedDate > today,
                    isInDisplayRange: normalizedDate >= displayStart
                        && normalizedDate <= normalizedDisplayEnd
                )
            }
            result.append(MacHeatmapWeek(start: weekStart, cells: cells))
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart),
                  next > weekStart else { break }
            weekStart = next
        }
        return result
    }

    /// Keep the calendar silhouette stable while the selected period is still
    /// in progress. Future cells are visual placeholders only; summaries and
    /// daily statistics still stop at today.
    private func macHeatmapDisplayEnd(now: Date, calendar: Calendar) -> Date {
        let interval: DateInterval?
        switch range {
        case .week:
            interval = calendar.dateInterval(of: .weekOfYear, for: now)
        case .month:
            interval = calendar.dateInterval(of: .month, for: now)
        case .year, .all:
            interval = calendar.dateInterval(of: .year, for: now)
        }
        guard let end = interval?.end else { return calendar.startOfDay(for: now) }
        return calendar.date(byAdding: .day, value: -1, to: end)
            ?? calendar.startOfDay(for: now)
    }

    private func rankedSongs(
        _ groups: [String: [PlayHistoryStore.Entry]],
        limit: Int
    ) -> [PlayHistoryStore.RankedItem] {
        groups.compactMap { songID, plays in
            plays.first.map {
                PlayHistoryStore.RankedItem(
                    id: songID,
                    title: $0.songTitle,
                    subtitle: $0.artistName,
                    playCount: plays.count,
                    totalSec: plays.reduce(0) { $0 + $1.listenedSec }
                )
            }
        }
        .sorted { $0.playCount > $1.playCount }
        .prefix(limit)
        .map { $0 }
    }

    private func rankedArtists(
        _ entries: [PlayHistoryStore.Entry],
        limit: Int
    ) -> [PlayHistoryStore.RankedItem] {
        Dictionary(grouping: entries.lazy.filter { !$0.artistName.isEmpty }, by: \.artistName)
            .map { name, plays in
                PlayHistoryStore.RankedItem(
                    id: "artist:\(name)",
                    title: name,
                    subtitle: String(
                        format: String(localized: "stats_unique_songs_format"),
                        Set(plays.map(\.songID)).count
                    ),
                    playCount: plays.count,
                    totalSec: plays.reduce(0) { $0 + $1.listenedSec }
                )
            }
            .sorted { $0.playCount > $1.playCount }
            .prefix(limit)
            .map { $0 }
    }

    private func rankedAlbums(
        _ entries: [PlayHistoryStore.Entry],
        limit: Int
    ) -> [PlayHistoryStore.RankedItem] {
        Dictionary(
            grouping: entries.lazy.filter { !$0.albumTitle.isEmpty },
            by: { "\($0.albumTitle)|\($0.artistName)" }
        )
        .compactMap { key, plays in
            plays.first.map {
                PlayHistoryStore.RankedItem(
                    id: "album:\(key)",
                    title: $0.albumTitle,
                    subtitle: $0.artistName,
                    playCount: plays.count,
                    totalSec: plays.reduce(0) { $0 + $1.listenedSec }
                )
            }
        }
        .sorted { $0.playCount > $1.playCount }
        .prefix(limit)
        .map { $0 }
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
        #if os(macOS)
        let counts = makeMacStatsSnapshot().dailyStats.map {
            (date: $0.date, count: $0.count)
        }
        #else
        let counts = store.dailyPlayCounts(in: range)
        #endif
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
            .settingsAnchor("stats.rank")
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
            .settingsAnchor("stats.clear")
        } footer: {
            Text("stats_privacy_footer")
        }
    }

    // MARK: - Format helpers

    private func formatHours(_ sec: TimeInterval) -> String {
        if sec < 60 {
            return String(format: String(localized: "stats_seconds_format"), sec.finiteInt())
        }
        let totalMin = (sec / 60).finiteInt()
        if totalMin < 60 {
            return String(format: String(localized: "stats_minutes_format"), totalMin)
        }
        let hours = totalMin / 60
        let minutes = totalMin % 60
        return String(format: String(localized: "stats_hours_minutes_format"), hours, minutes)
    }
}
