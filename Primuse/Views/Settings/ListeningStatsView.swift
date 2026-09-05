import SwiftUI
import PrimuseKit
import Charts

/// 听歌统计 — 本地播放历史的可视化。数据来源 PlayHistoryStore (纯本地,
/// 不上传)。包含:
/// - 时间段选择 (本周 / 本月 / 本年 / 全部)
/// - 摘要数字 (播放次数 / 总时长 / 活跃天数 / 不重复曲目)
/// - 日历活跃度、时长趋势与播放时段
/// - Top 排行 (歌曲 / 艺术家 / 专辑 三个 tab)
struct ListeningStatsView: View {
    @Environment(SourcesStore.self) private var sourcesStore
    @AppStorage("stats.selectedServerSourceID")
    private var selectedServerSourceID = ""
    #if os(macOS)
    @State private var range: PlayHistoryStore.Range = .year
    @State private var heatmapWidth: CGFloat = 0
    #else
    @State private var range: PlayHistoryStore.Range = .month
    @State private var activityChart: MobileActivityChart = .duration
    #endif
    @State private var heatmapYear: Int?
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
            #if os(macOS)
            if !serverSources.isEmpty {
                statsSourcePicker
                Divider()
            }
            #endif

            if let source = selectedServerSource {
                ServerListeningStatsView(source: source)
            } else {
                localBody
            }
        }
        .navigationTitle("stats_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !serverSources.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        sourcePicker
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedServerSource?.name ?? String(localized: "stats_source_local"))
                                .lineLimit(1)
                                .frame(maxWidth: 110)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                    }
                    .accessibilityLabel("stats_data_source")
                    .accessibilityValue(selectedServerSource?.name ?? String(localized: "stats_source_local"))
                    .settingsAnchor("stats.source")
                }
            }
        }
        #endif
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
        let snapshot = makeStatsSnapshot(rankLimit: 20)
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
                summarySection(snapshot: snapshot)
                mobileActivitySection(timeline: snapshot.timeline)
                mobileChartsSection(timeline: snapshot.timeline)
                rankingSection(snapshot: snapshot)
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
            sourcePicker
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

    private var sourcePicker: some View {
        Picker("stats_data_source", selection: $selectedServerSourceID) {
            Text("stats_source_local").tag("")
            ForEach(serverSources) { source in
                Text(source.name).tag(source.id)
            }
        }
    }

    #if os(macOS)
    private var macBody: some View {
        let snapshot = makeStatsSnapshot()
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                macStatsHeader(snapshot: snapshot)

                if store.entries.isEmpty {
                    macEmptyState
                } else {
                    macSummarySection(snapshot: snapshot)
                    macHeatmapCard(timeline: snapshot.timeline)
                    macActivityCharts(timeline: snapshot.timeline)
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

    private func macStatsHeader(snapshot: StatsSnapshot) -> some View {
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
                            heatmapYear = nil
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
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            Text(statsRangeSubtitle(days: snapshot.dailyStats))
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
    }

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

    private func macSummarySection(snapshot: StatsSnapshot) -> some View {
        let s = snapshot.summary
        let days = max(snapshot.dailyStats.count, 1)
        let totalMin = Int(s.totalSec / 60)
        let coverage = (Double(s.activeDays) / Double(days) * 100).rounded().finiteInt()
        let coverLabel = String(localized: "stats_coverage")
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

    private func macHeatmapCard(timeline: ListeningActivityTimeline) -> some View {
        let calendar = Calendar.current
        let weeks = makeMacHeatmapWeeks(timeline: timeline, calendar: calendar)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("stats_calendar_title")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Text(LocalizedStringKey(range.localizationKey))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(PMColor.brand.opacity(0.10), in: .capsule)
                if range == .all && timeline.availableYears.count > 1 {
                    Picker("stats_range_year", selection: Binding(
                        get: { heatmapYear ?? calendar.component(.year, from: Date()) },
                        set: { heatmapYear = $0 }
                    )) {
                        ForEach(timeline.availableYears, id: \.self) { year in
                            Text(verbatim: String(year)).tag(year)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                } else {
                    Text(verbatim: String(calendar.component(.year, from: timeline.yearInterval.start)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(PMColor.textMuted)
                }
            }
            macHeatmapGrid(weeks: weeks, calendar: calendar)
            HStack {
                Text("stats_calendar_hint")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textMuted)
                macHeatmapLegend
            }
        }
        .padding(18)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func macHeatmapGrid(weeks: [MacHeatmapWeek], calendar: Calendar) -> some View {
        let gap: CGFloat = 3
        let weekdayWidth: CGFloat = 20
        let n = CGFloat(max(weeks.count, 1))
        let cell = max(3, (heatmapWidth - weekdayWidth - 8 - gap * (n - 1)) / n)
        let weekdaySymbols = macWeekdaySymbols(calendar: calendar)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Color.clear.frame(width: weekdayWidth, height: 12)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(weeks.indices, id: \.self) { weekIndex in
                        let label = macMonthLabel(for: weeks, weekIndex: weekIndex, calendar: calendar)
                        Color.clear
                            .frame(width: cell, height: 12)
                            .overlay(alignment: .leading) {
                                if let label {
                                    Text(verbatim: label)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(PMColor.textMuted)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { heatmapWidth = $0 }
    }

    private func macHeatmapCell(_ cell: MacHeatmapCell, size: CGFloat) -> some View {
        let outlined = cell.isSelected && (range == .week || range == .month)
        let fill: Color
        if cell.isFuture && cell.isInDisplayRange {
            fill = PMColor.divider.opacity(0.32)
        } else if let day = cell.day {
            fill = heatColor(count: day.count).opacity(cell.isSelected ? 1 : 0.23)
        } else {
            fill = PMColor.divider.opacity(0.34)
        }
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay {
                if outlined || (cell.isFuture && cell.isInDisplayRange) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(outlined ? PMColor.brand.opacity(0.65) : PMColor.cardBorder,
                                      lineWidth: outlined ? 1 : 0.5)
                }
            }
            .help(macHeatmapTooltip(for: cell))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(macHeatmapTooltip(for: cell))
    }

    private func macHeatmapTooltip(for cell: MacHeatmapCell) -> String {
        let date = cell.date.formatted(date: .long, time: .omitted)
        guard !cell.isFuture, let day = cell.day else { return "\(date)\n—" }
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

    private func macActivityCharts(timeline: ListeningActivityTimeline) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                macDurationChart(timeline: timeline).frame(minWidth: 360)
                macHourlyChart(timeline: timeline).frame(minWidth: 320)
            }
            VStack(spacing: 14) {
                macDurationChart(timeline: timeline)
                macHourlyChart(timeline: timeline)
            }
        }
    }

    private func macDurationChart(timeline: ListeningActivityTimeline) -> some View {
        macChartCard(title: "stats_trend_title",
                     subtitle: timeline.trendUsesMonths ? "stats_trend_monthly" : "stats_trend_daily") {
            Chart(timeline.trend) { day in
                BarMark(
                    x: .value(String(localized: "stats_range"), day.date, unit: timeline.trendUsesMonths ? .month : .day),
                    y: .value(String(localized: "stats_chart_minutes"), day.totalSec / 60)
                )
                .foregroundStyle(PMColor.brand.gradient)
                .cornerRadius(3)
                .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue(formatHours(day.totalSec))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: timeline.trendUsesMonths
                                   ? (range == .all && timeline.availableYears.count > 1
                                      ? .dateTime.year().month(.abbreviated) : .dateTime.month(.abbreviated))
                                   : .dateTime.month().day())
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .chartYScale(domain: 0...max(1, (timeline.trend.map { $0.totalSec / 60 }.max() ?? 0) * 1.12))
            .overlay { if timeline.hourlyCounts.reduce(0, +) == 0 { macChartEmptyState } }
        }
    }

    private func macHourlyChart(timeline: ListeningActivityTimeline) -> some View {
        macChartCard(title: "stats_hourly_title", subtitle: "stats_hourly_hint") {
            Chart(Array(timeline.hourlyCounts.enumerated()), id: \.offset) { hour, count in
                BarMark(
                    x: .value(String(localized: "stats_chart_hour"), hour),
                    y: .value(String(localized: "stats_total_plays"), count),
                    width: .fixed(8)
                )
                    .foregroundStyle(PMColor.brand.opacity(0.78).gradient)
                    .cornerRadius(2)
                    .accessibilityLabel(String(format: "%02d:00–%02d:00", hour, hour + 1))
                    .accessibilityValue(String(format: String(localized: "stats_play_count_format"), count))
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    if let hour = value.as(Int.self) {
                        AxisValueLabel(anchor: hour == 23 ? .topTrailing : (hour == 0 ? .topLeading : .top)) {
                            Text(String(format: "%02d:00", hour))
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .chartYScale(domain: 0...max(1, Double(timeline.hourlyCounts.max() ?? 0) * 1.12))
            .overlay { if timeline.hourlyCounts.reduce(0, +) == 0 { macChartEmptyState } }
        }
    }

    private var macChartEmptyState: some View {
        Text("stats_chart_no_activity")
            .font(.system(size: 12))
            .foregroundStyle(PMColor.textMuted)
            .padding(10)
            .background(PMColor.card, in: .rect(cornerRadius: 8))
    }

    private func macChartCard<Content: View>(
        title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(PMColor.text)
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(PMColor.textMuted)
            content()
                .frame(height: 160)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    // MARK: Top 三栏 (STATS-03)

    private func macTopCards(snapshot: StatsSnapshot) -> some View {
        HStack(alignment: .top, spacing: 14) {
            macTopCard(title: String(localized: "stats_top_songs"), items: snapshot.topSongs)
            macTopCard(title: String(localized: "stats_top_artists"), items: snapshot.topArtists)
            macTopCard(title: String(localized: "stats_top_albums"), items: snapshot.topAlbums)
        }
    }

    private typealias MacDailyStat = ListeningActivityTimeline.Day

    private struct MacHeatmapCell: Identifiable {
        let date: Date
        let day: MacDailyStat?
        let isFuture: Bool
        let isInDisplayRange: Bool
        let isSelected: Bool
        var id: Date { date }
    }

    private struct MacHeatmapWeek: Identifiable {
        let start: Date
        let cells: [MacHeatmapCell]
        var id: Date { start }
    }

    private func makeMacHeatmapWeeks(
        timeline: ListeningActivityTimeline,
        calendar: Calendar
    ) -> [MacHeatmapWeek] {
        let today = calendar.startOfDay(for: Date())
        let cells = timeline.calendarDays.map { day in
            let selected = day.date >= timeline.selectedStart && day.date <= today
            return MacHeatmapCell(
                date: day.date,
                day: day,
                isFuture: day.date > today,
                isInDisplayRange: day.date >= timeline.yearInterval.start && day.date < timeline.yearInterval.end,
                isSelected: selected
            )
        }
        return stride(from: 0, to: cells.count, by: 7).map { index in
            MacHeatmapWeek(start: cells[index].date, cells: Array(cells[index..<min(index + 7, cells.count)]))
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

    private struct StatsSnapshot {
        let summary: PlayHistoryStore.Summary
        let timeline: ListeningActivityTimeline
        var dailyStats: [ListeningActivityTimeline.Day] { timeline.dailyStats }
        let previousPlayCount: Int?
        let heavyRotationCount: Int
        let topSongs: [PlayHistoryStore.RankedItem]
        let topArtists: [PlayHistoryStore.RankedItem]
        let topAlbums: [PlayHistoryStore.RankedItem]
    }

    /// 同一次 SwiftUI 渲染共享统计结果，避免标题、摘要、热力图和三个榜单
    /// 分别再次过滤完整播放历史。
    private func makeStatsSnapshot(rankLimit: Int = 6) -> StatsSnapshot {
        let now = Date()
        let currentStart = statsRangeStartDate(now: now)
        let previousInterval = statsPreviousRangeInterval(now: now, currentStart: currentStart)
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
        let timeline = ListeningActivityTimeline(
            events: store.entries.map { .init(date: $0.playedAt, seconds: $0.listenedSec) },
            selectedStart: range == .all ? nil : currentStart,
            displayYear: heatmapYear,
            now: now,
            calendar: calendar
        )
        let playsBySong = Dictionary(grouping: scopedEntries, by: \.songID)
        let summary = PlayHistoryStore.Summary(
            totalPlays: scopedEntries.count,
            totalSec: scopedEntries.reduce(0) { $0 + $1.listenedSec },
            activeDays: dayBuckets.count,
            uniqueSongs: playsBySong.count
        )

        return StatsSnapshot(
            summary: summary,
            timeline: timeline,
            previousPlayCount: range == .all ? nil : previousPlayCount,
            heavyRotationCount: playsBySong.values.lazy.filter { $0.count >= 5 }.count,
            topSongs: rankedSongs(playsBySong, limit: rankLimit),
            topArtists: rankedArtists(scopedEntries, limit: rankLimit),
            topAlbums: rankedAlbums(scopedEntries, limit: rankLimit)
        )
    }

    private func statsRangeStartDate(now: Date) -> Date {
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

    private func statsPreviousRangeInterval(now: Date, currentStart: Date) -> DateInterval? {
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

    private func summarySection(snapshot: StatsSnapshot) -> some View {
        Section {
            let s = snapshot.summary
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

    private func logHeatmapStats() {
        let timeline = makeStatsSnapshot().timeline
        plog("stats range=\(range.rawValue) days=\(timeline.dailyStats.count) activeDays=\(timeline.dailyStats.filter { $0.count > 0 }.count)")
    }

    private func rankingSection(snapshot: StatsSnapshot) -> some View {
        Section {
            Picker("rank_by", selection: $rankTab) {
                ForEach(RankTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .settingsAnchor("stats.rank")
            .pickerStyle(.segmented)

            let items = rankItems(snapshot: snapshot)
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

    private func rankItems(snapshot: StatsSnapshot) -> [PlayHistoryStore.RankedItem] {
        switch rankTab {
        case .songs: return snapshot.topSongs
        case .artists: return snapshot.topArtists
        case .albums: return snapshot.topAlbums
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

#if !os(macOS)
private extension ListeningStatsView {
    enum MobileActivityChart: String, CaseIterable {
        case duration, hourly

        var title: LocalizedStringKey {
            self == .duration ? "stats_trend_title" : "stats_hourly_title"
        }
    }

    func mobileActivitySection(timeline: ListeningActivityTimeline) -> some View {
        Section {
            MobileListeningActivityView(
                counts: timeline.dailyStats.map { (date: $0.date, count: $0.count) },
                range: ServerListeningStatsRange(rawValue: range.rawValue) ?? .month
            )
            .padding(.vertical, 4)
        } header: {
            Text("stats_heatmap_title")
        } footer: {
            Text("stats_heatmap_footer")
        }
    }

    func mobileChartsSection(timeline: ListeningActivityTimeline) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Picker("stats_title", selection: $activityChart) {
                    ForEach(MobileActivityChart.allCases, id: \.self) { chart in
                        Text(chart.title).tag(chart)
                    }
                }
                .pickerStyle(.segmented)

                Text(activityChart == .hourly ? "stats_hourly_hint"
                     : (timeline.trendUsesMonths ? "stats_trend_monthly" : "stats_trend_daily"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Group {
                    if activityChart == .duration {
                        mobileDurationChart(timeline: timeline)
                    } else {
                        mobileHourlyChart(timeline: timeline)
                    }
                }
                .frame(height: 160)
                .overlay {
                    if timeline.hourlyCounts.reduce(0, +) == 0 {
                        Text("stats_chart_no_activity")
                            .font(.caption)
                            .padding(8)
                            .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    func mobileDurationChart(timeline: ListeningActivityTimeline) -> some View {
        Chart(timeline.trend) { day in
            BarMark(
                x: .value(String(localized: "stats_range"), day.date, unit: timeline.trendUsesMonths ? .month : .day),
                y: .value(String(localized: "stats_chart_minutes"), day.totalSec / 60),
                width: .ratio(0.7)
            )
            .foregroundStyle(Color.accentColor.gradient)
            .cornerRadius(2)
            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
            .accessibilityValue(formatHours(day.totalSec))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: timeline.trendUsesMonths
                               ? (range == .all && timeline.availableYears.count > 1
                                  ? .dateTime.year(.twoDigits).month(.abbreviated) : .dateTime.month(.abbreviated))
                               : .dateTime.month().day())
            }
        }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .chartYScale(domain: 0...max(1, (timeline.trend.map { $0.totalSec / 60 }.max() ?? 0) * 1.12))
    }

    func mobileHourlyChart(timeline: ListeningActivityTimeline) -> some View {
        Chart(Array(timeline.hourlyCounts.enumerated()), id: \.offset) { hour, count in
            BarMark(
                x: .value(String(localized: "stats_chart_hour"), hour),
                y: .value(String(localized: "stats_total_plays"), count),
                width: .fixed(6)
            )
            .foregroundStyle(Color.accentColor.opacity(0.8).gradient)
            .cornerRadius(2)
            .accessibilityLabel(String(format: "%02d:00–%02d:00", hour, hour + 1))
            .accessibilityValue(String(format: String(localized: "stats_play_count_format"), count))
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                if let hour = value.as(Int.self) {
                    AxisValueLabel(anchor: hour == 23 ? .topTrailing : (hour == 0 ? .topLeading : .top)) {
                        Text(String(format: "%02d:00", hour))
                    }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .chartYScale(domain: 0...max(1, Double(timeline.hourlyCounts.max() ?? 0) * 1.12))
    }
}

struct MobileListeningActivityView: View {
    let counts: [(date: Date, count: Int)]
    let range: ServerListeningStatsRange

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedYear: Int?
    @State private var selectedDay: Date?
    @State private var expandedMonth: Date?

    var body: some View {
        let model = ListeningActivityCalendar(counts: counts, now: Date(), calendar: .current)
        let year = selectedYear.flatMap { model.availableYears.contains($0) ? $0 : nil }
            ?? model.calendar.component(.year, from: model.today)
        let maximum = counts.filter {
            range != .all || model.calendar.component(.year, from: $0.date) == year
        }.map(\.count).max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if range == .week {
                    let days = model.days(in: .weekOfYear, containing: model.today)
                    Text(dateRangeLabel(days: days))
                        .font(.subheadline.weight(.medium))
                } else if range == .month {
                    Text(model.today, format: .dateTime.year().month(.wide))
                        .font(.subheadline.weight(.medium))
                } else if range == .all && model.availableYears.count > 1 {
                    Text("stats_calendar_title")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text(verbatim: String(year))
                        .font(.subheadline.weight(.medium).monospacedDigit())
                }
                Spacer(minLength: 8)
                if range == .all && model.availableYears.count > 1 {
                    Picker("stats_range_year", selection: Binding(
                        get: { year }, set: { selectedYear = $0; selectedDay = nil }
                    )) {
                        ForEach(model.availableYears, id: \.self) { item in
                            Text(verbatim: String(item)).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            switch range {
            case .week:
                weekStrip(model: model, maximum: maximum)
            case .month:
                monthGrid(date: model.today, model: model, maximum: maximum)
                dayDetail(model: model)
            case .year, .all:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14),
                                         count: dynamicTypeSize.isAccessibilitySize ? 2 : 3), spacing: 16) {
                    ForEach(model.months(in: year), id: \.self) { month in
                        Button { selectedDay = nil; expandedMonth = month } label: {
                            miniMonth(date: month, model: model, maximum: maximum)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(month.formatted(.dateTime.year().month(.wide)))
                        .accessibilityValue(playCountLabel(model.days(in: .month, containing: month).compactMap(\.count).reduce(0, +)))
                    }
                }
            }
            legend
        }
        .onChange(of: range) { _, _ in
            selectedYear = nil
            selectedDay = nil
            expandedMonth = nil
        }
        .sheet(isPresented: Binding(get: { expandedMonth != nil }, set: { if !$0 { expandedMonth = nil } })) {
            if let month = expandedMonth {
                NavigationStack {
                    Form {
                        Section {
                            monthGrid(date: month, model: model, maximum: maximum)
                            dayDetail(model: model)
                        } footer: {
                            Text("stats_heatmap_footer")
                        }
                    }
                    .navigationTitle(month.formatted(.dateTime.year().month(.wide)))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") { expandedMonth = nil }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func weekStrip(model: ListeningActivityCalendar, maximum: Int) -> some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(model.days(in: .weekOfYear, containing: model.today)) { day in
                VStack(spacing: 7) {
                    Text(day.date, format: .dateTime.weekday(.narrow))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 6) {
                        Text(model.calendar.component(.day, from: day.date), format: .number.grouping(.never))
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(day.count.map { $0.formatted() } ?? "—")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background(fill(day, maximum: maximum), in: .rect(cornerRadius: 8))
                    .overlay {
                        if model.calendar.isDate(day.date, inSameDayAs: model.today) {
                            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.date.formatted(date: .long, time: .omitted))
                .accessibilityValue(day.count.map(playCountLabel) ?? "—")
            }
        }
    }

    private func monthGrid(date: Date, model: ListeningActivityCalendar, maximum: Int) -> some View {
        let cells = model.monthCells(containing: date)
        let count = ((cells.lastIndex { $0 != nil } ?? 0) / 7 + 1) * 7
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
            ForEach(0..<7, id: \.self) { offset in
                Text(model.calendar.veryShortStandaloneWeekdaySymbols[(model.calendar.firstWeekday - 1 + offset) % 7])
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
            ForEach(0..<count, id: \.self) { index in
                if let day = cells[index] {
                    Button { selectedDay = day.date } label: {
                        Text(model.calendar.component(.day, from: day.date), format: .number.grouping(.never))
                            .font(.callout.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundStyle(day.count == nil ? .secondary : .primary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(fill(day, maximum: maximum), in: .rect(cornerRadius: 7))
                            .overlay {
                                if day.date == selectedDay || (selectedDay == nil && day.date == model.today) {
                                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(day.count == nil)
                    .accessibilityLabel(day.date.formatted(date: .long, time: .omitted))
                    .accessibilityValue(day.count.map(playCountLabel) ?? "—")
                } else {
                    Color.clear.frame(height: 40).accessibilityHidden(true)
                }
            }
        }
    }

    private func miniMonth(date: Date, model: ListeningActivityCalendar, maximum: Int) -> some View {
        let cells = model.monthCells(containing: date)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(date, format: .dateTime.month(.abbreviated))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(cells.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(cells[index].map { fill($0, maximum: maximum) } ?? .clear)
                        .frame(height: 9)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
    }

    private func dayDetail(model: ListeningActivityCalendar) -> some View {
        let fallback = expandedMonth.flatMap {
            model.days(in: .month, containing: $0).last(where: { $0.count != nil })?.date ?? $0
        } ?? model.today
        let date = selectedDay ?? fallback
        let count = model.days(in: .month, containing: date).first { $0.date == date }?.count
        return ViewThatFits(in: .horizontal) {
            HStack {
                Text(date, format: .dateTime.month().day().weekday())
                Spacer()
                Text(count.map(playCountLabel) ?? "—")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(date, format: .dateTime.month().day().weekday())
                Text(count.map(playCountLabel) ?? "—")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func fill(_ day: ListeningActivityCalendar.Day, maximum: Int) -> Color {
        guard let count = day.count else { return Color.secondary.opacity(0.035) }
        guard count > 0, maximum > 0 else { return Color.secondary.opacity(0.10) }
        return Color.accentColor.opacity(0.16 + 0.44 * log(Double(count) + 1) / log(Double(maximum) + 1))
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("stats_legend_less")
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(level == 0 ? Color.secondary.opacity(0.10) : Color.accentColor.opacity(0.16 + Double(level) * 0.11))
                    .frame(width: 10, height: 10)
            }
            Text("stats_legend_more")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func playCountLabel(_ count: Int) -> String {
        String(format: String(localized: "stats_play_count_format"), count)
    }

    private func dateRangeLabel(days: [ListeningActivityCalendar.Day]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return "\(first.date.formatted(.dateTime.month().day())) – \(last.date.formatted(.dateTime.month().day()))"
    }
}
#endif
