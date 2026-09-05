import PrimuseKit
import SwiftUI

struct ServerListeningStatsView: View {
    let source: MusicSource

    @Environment(ServerListeningStatsService.self) private var statsService
    @State private var range: ServerListeningStatsRange = .month
    @State private var rankTab: RankTab = .tracks
    @State private var manualRefreshTask: Task<Void, Never>?
    #if os(macOS)
    @State private var expandedRanks: Set<RankTab> = []
    #endif

    private struct HeatmapDay {
        let date: Date
        let playCount: Int
    }

    private enum RankTab: String, CaseIterable {
        case tracks
        case artists
        case albums

        var localizationKey: LocalizedStringKey {
            switch self {
            case .tracks: "stats_rank_songs"
            case .artists: "stats_rank_artists"
            case .albums: "stats_rank_albums"
            }
        }
    }

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            mobileBody
            #endif
        }
        .task(id: activationID) {
            await statsService.activate(source: source)
        }
        .onDisappear {
            manualRefreshTask?.cancel()
            statsService.cancel()
        }
    }

    private var activationID: String {
        "\(source.id):\(ServerListeningStatsFingerprint.configuration(for: source))"
    }

    private var presentation: ServerListeningStatsPresentation? {
        guard statsService.sourceID == source.id else { return nil }
        return statsService.presentation(range: range)
    }

    private var isEventHistory: Bool {
        statsService.snapshot?.payload.temporalDetail == .events
    }

    #if !os(macOS)
    private var mobileBody: some View {
        Form {
            serverStatusSection

            if isEventHistory {
                Section {
                    rangePicker
                }
            }

            if let presentation {
                summarySection(presentation)
                capabilityBoundarySection(presentation)
                if presentation.temporalDetail == .events {
                    heatmapSection(presentation)
                }
                rankingSection(presentation)
            } else if statsService.isRefreshing {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("stats_server_loading")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView(
                        "stats_server_unavailable_title",
                        systemImage: "chart.bar.xaxis",
                        description: Text("stats_server_unavailable_desc")
                    )
                }
            }

            Section {
                refreshButton
            }
        }
        .navigationTitle("stats_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var serverStatusSection: some View {
        Section {
            LabeledContent("stats_server_source", value: source.name)
            if let fetchedAt = statsService.snapshot?.fetchedAt {
                LabeledContent("stats_server_last_updated") {
                    Text(fetchedAt, format: .dateTime.year().month().day().hour().minute())
                }
            }
            if statsService.isStale {
                Label(staleDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let error = statsService.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("stats_server_authoritative")
        }
    }

    private func summarySection(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        Section("stats_server_summary") {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                summaryCell(
                    value: presentation.totalPlays.formatted(),
                    label: String(localized: "stats_total_plays"),
                    icon: "play.fill",
                    color: .blue
                )
                summaryCell(
                    value: presentation.uniqueTracks.formatted(),
                    label: String(localized: "stats_unique_songs"),
                    icon: "music.note",
                    color: .purple
                )
                if let activeDays = presentation.activeDays {
                    summaryCell(
                        value: activeDays.formatted(),
                        label: String(localized: "stats_active_days"),
                        icon: "calendar",
                        color: .green
                    )
                }
                summaryCell(
                    value: lastPlayedText(presentation.lastPlayedAt),
                    label: String(localized: "stats_server_last_played"),
                    icon: "clock",
                    color: .orange
                )
                if let duration = presentation.totalListenedSeconds {
                    summaryCell(
                        value: formatDuration(duration),
                        label: String(localized: "stats_total_duration"),
                        icon: "timer",
                        color: .teal
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func summaryCell(
        value: String,
        label: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 10))
    }

    private func capabilityBoundarySection(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        Section {
            Label(
                presentation.temporalDetail == .aggregate
                    ? "stats_server_aggregate_boundary"
                    : "stats_server_event_boundary",
                systemImage: "info.circle"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func heatmapSection(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        Section {
            serverHeatmap(presentation: presentation, cellSize: 14)
                .padding(.vertical, 4)
        } header: {
            Text("stats_heatmap_title")
        } footer: {
            Text("stats_server_heatmap_footer")
        }
    }

    private func rankingSection(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        Section {
            rankPicker
            rankedRows(presentation)
        } header: {
            Text("stats_top_header")
        }
    }
    #endif

    #if os(macOS)
    private var macBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                macHeader
                if statsService.isStale || statsService.errorMessage != nil {
                    macStatusBanner
                }

                if let presentation {
                    macSummaryGrid(presentation)
                    macBoundaryCard(presentation)
                    if presentation.temporalDetail == .events {
                        macHeatmapCard(presentation)
                    }
                    macRankingCard(presentation)
                } else if statsService.isRefreshing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("stats_server_loading")
                            .foregroundStyle(PMColor.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 80)
                    .macStatsCard()
                } else {
                    ContentUnavailableView(
                        "stats_server_unavailable_title",
                        systemImage: "chart.bar.xaxis",
                        description: Text("stats_server_unavailable_desc")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    .macStatsCard()
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 100)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationTitle("stats_title")
    }

    private var macHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 54, height: 54)
                    .background(PMColor.brand.opacity(0.10), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("stats_title")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                    Text(source.name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(PMColor.text)
                }
                Spacer()
                if statsService.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                refreshButton
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            HStack(spacing: 10) {
                Text("stats_server_authoritative")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PMColor.brand.opacity(0.08), in: .capsule)
                if let fetchedAt = statsService.snapshot?.fetchedAt {
                    Label {
                        Text(fetchedAt, format: .dateTime.month().day().hour().minute())
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .help(String(localized: "stats_server_last_updated") + ": "
                          + fetchedAt.formatted(.dateTime.year().month().day().hour().minute()))
                }
                Spacer()
                if isEventHistory {
                    rangePicker.frame(maxWidth: 420)
                }
            }
        }
    }

    private var macStatusBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PMColor.warn)
            VStack(alignment: .leading, spacing: 4) {
                if statsService.isStale {
                    Text(staleDescription)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PMColor.text)
                }
                if let error = statsService.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(PMColor.textMuted)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PMColor.warn.opacity(0.10), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PMColor.warn.opacity(0.28), lineWidth: 0.5)
        }
    }

    private func macSummaryGrid(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                macSummaryCells(presentation)
                    .frame(minWidth: 180)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                macSummaryCells(presentation)
            }
        }
    }

    @ViewBuilder
    private func macSummaryCells(_ presentation: ServerListeningStatsPresentation) -> some View {
        macSummaryCell(
            presentation.totalPlays.formatted(),
            label: "stats_total_plays", icon: "play.fill",
            detail: presentation.temporalDetail == .aggregate ? String(localized: "stats_all_time_total") : nil
        )
        macSummaryCell(
            presentation.uniqueTracks.formatted(),
            label: "stats_unique_songs", icon: "music.note"
        )
        if let activeDays = presentation.activeDays {
            macSummaryCell(activeDays.formatted(), label: "stats_active_days", icon: "calendar")
        }
        macSummaryCell(
            presentation.lastPlayedAt?.formatted(.dateTime.year().month().day())
                ?? String(localized: "stats_server_never_played"),
            label: "stats_server_last_played", icon: "clock",
            detail: presentation.lastPlayedAt?.formatted(date: .omitted, time: .shortened),
            isDate: true
        )
        if let duration = presentation.totalListenedSeconds {
            macSummaryCell(formatDuration(duration), label: "stats_total_duration", icon: "timer")
        }
    }

    private func macSummaryCell(
        _ value: String, label: LocalizedStringKey, icon: String, detail: String? = nil, isDate: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(PMColor.brand.opacity(0.8))
            }
            Text(verbatim: value)
                .font(.system(size: isDate ? 22 : 32, weight: .bold, design: isDate ? .default : .monospaced))
                .foregroundStyle(PMColor.text)
                .lineLimit(isDate ? 2 : 1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 39, alignment: .leading)
            Text(verbatim: detail ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .macStatsCard()
        .accessibilityElement(children: .combine)
    }

    private func macBoundaryCard(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        Label(
            presentation.temporalDetail == .aggregate
                ? "stats_server_aggregate_boundary"
                : "stats_server_event_boundary",
            systemImage: "info.circle"
        )
        .font(.system(size: 11))
        .foregroundStyle(PMColor.textMuted)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private func macHeatmapCard(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("stats_heatmap_title")
                .font(.headline)
                .foregroundStyle(PMColor.text)
            serverHeatmap(presentation: presentation, cellSize: 16)
            Text("stats_server_heatmap_footer")
                .font(.caption)
                .foregroundStyle(PMColor.textMuted)
        }
        .padding(18)
        .macStatsCard()
    }

    private func macRankingCard(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                macRankColumn(title: "stats_top_songs", tab: .tracks, items: presentation.topTracks)
                    .frame(minWidth: 260)
                macRankColumn(title: "stats_top_artists", tab: .artists, items: presentation.topArtists)
                    .frame(minWidth: 260)
                macRankColumn(title: "stats_top_albums", tab: .albums, items: presentation.topAlbums)
                    .frame(minWidth: 260)
            }
            VStack(spacing: 14) {
                macRankColumn(title: "stats_top_songs", tab: .tracks, items: presentation.topTracks)
                macRankColumn(title: "stats_top_artists", tab: .artists, items: presentation.topArtists)
                macRankColumn(title: "stats_top_albums", tab: .albums, items: presentation.topAlbums)
            }
        }
        .settingsAnchor("stats.serverRank")
    }

    private func macRankColumn(
        title: LocalizedStringKey, tab: RankTab, items: [ServerListeningStatsRankedItem]
    ) -> some View {
        let expanded = expandedRanks.contains(tab)
        let visibleItems = expanded ? items : Array(items.prefix(6))
        let maximum = max(items.map(\.playCount).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Text("stats_total_plays")
                    .font(.system(size: 10))
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.bottom, 12)

            if items.isEmpty {
                Text("stats_rank_empty")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    macRankRow(item, rank: index + 1, maximum: maximum)
                }
            }
            if items.count > 6 {
                Button {
                    if expanded { expandedRanks.remove(tab) } else { expandedRanks.insert(tab) }
                } label: {
                    HStack(spacing: 5) {
                        Text(expanded ? "update_show_less" : "see_all")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(PMColor.brand.opacity(0.07), in: .rect(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(18)
        .macStatsCard()
        .accessibilityElement(children: .contain)
    }

    private func macRankRow(_ item: ServerListeningStatsRankedItem, rank: Int, maximum: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%02d", rank))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(rank <= 3 ? PMColor.brand : PMColor.textFaint)
                .frame(width: 20, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(PMColor.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(item.playCount.formatted())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(PMColor.text)
                        .fixedSize()
                }
                GeometryReader { geometry in
                    Capsule().fill(PMColor.brand.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(PMColor.brand.opacity(rank <= 3 ? 0.70 : 0.40))
                                .frame(width: geometry.size.width * CGFloat(item.playCount) / CGFloat(maximum))
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 9)
        .help([item.title, item.subtitle].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
    }
    #endif

    private var rangePicker: some View {
        Picker("stats_range", selection: $range) {
            Text("stats_range_week").tag(ServerListeningStatsRange.week)
            Text("stats_range_month").tag(ServerListeningStatsRange.month)
            Text("stats_range_year").tag(ServerListeningStatsRange.year)
            Text("stats_range_all").tag(ServerListeningStatsRange.all)
        }
        .pickerStyle(.segmented)
    }

    private var rankPicker: some View {
        Picker("stats_top_header", selection: $rankTab) {
            ForEach(RankTab.allCases, id: \.self) { tab in
                Text(tab.localizationKey).tag(tab)
            }
        }
        .settingsAnchor("stats.serverRank")
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private func rankedRows(
        _ presentation: ServerListeningStatsPresentation
    ) -> some View {
        let items = rankedItems(presentation)
        if items.isEmpty {
            Text("stats_rank_empty")
                .foregroundStyle(.secondary)
        } else {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(index < 3 ? Color.accentColor : .secondary)
                        .frame(width: 24, alignment: .leading)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(String(
                        format: String(localized: "stats_play_count_format"),
                        item.playCount
                    ))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func rankedItems(
        _ presentation: ServerListeningStatsPresentation
    ) -> [ServerListeningStatsRankedItem] {
        switch rankTab {
        case .tracks: presentation.topTracks
        case .artists: presentation.topArtists
        case .albums: presentation.topAlbums
        }
    }

    private var refreshButton: some View {
        Button {
            manualRefreshTask?.cancel()
            let selectedSource = source
            manualRefreshTask = Task { @MainActor in
                await statsService.refresh(source: selectedSource)
            }
        } label: {
            Label("stats_server_refresh", systemImage: "arrow.clockwise")
        }
        .settingsAnchor("stats.serverRefresh")
        .disabled(statsService.isRefreshing)
    }

    private var staleDescription: String {
        let order: [ServerListeningStatsStaleReason] = [
            .expired, .clockChanged, .recoveredBackup, .refreshFailed,
        ]
        return order.filter(statsService.staleReasons.contains).map { reason in
            switch reason {
            case .expired: String(localized: "stats_server_stale_expired")
            case .clockChanged: String(localized: "stats_server_stale_clock")
            case .recoveredBackup: String(localized: "stats_server_stale_backup")
            case .refreshFailed: String(localized: "stats_server_stale_refresh")
            }
        }.joined(separator: " · ")
    }

    private func lastPlayedText(_ date: Date?) -> String {
        guard let date else { return String(localized: "stats_server_never_played") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        return String(
            format: String(localized: "stats_hours_minutes_format"),
            totalMinutes / 60,
            totalMinutes % 60
        )
    }

    @ViewBuilder
    private func serverHeatmap(
        presentation: ServerListeningStatsPresentation,
        cellSize: CGFloat
    ) -> some View {
        let days = completeDailyCounts(presentation)
        let weeks = groupByWeek(days)
        let maximum = days.map(\.playCount).max() ?? 0

        if days.isEmpty {
            Text("stats_rank_empty")
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(weeks.indices, id: \.self) { index in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { weekday in
                                if let day = weeks[index][weekday] {
                                    heatmapCell(day, maximum: maximum, size: cellSize)
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
    }

    private func heatmapCell(
        _ day: HeatmapDay,
        maximum: Int,
        size: CGFloat
    ) -> some View {
        let intensity: Double = {
            guard maximum > 0, day.playCount > 0 else { return 0 }
            return max(
                0.15,
                log(Double(day.playCount) + 1) / log(Double(maximum) + 1)
            )
        }()
        return RoundedRectangle(cornerRadius: 3)
            .fill(
                day.playCount == 0
                    ? Color.secondary.opacity(0.10)
                    : Color.accentColor.opacity(intensity)
            )
            .frame(width: size, height: size)
            .accessibilityLabel(day.date.formatted(date: .long, time: .omitted))
            .accessibilityValue(String(
                format: String(localized: "stats_play_count_format"),
                day.playCount
            ))
    }

    private func completeDailyCounts(
        _ presentation: ServerListeningStatsPresentation
    ) -> [HeatmapDay] {
        guard presentation.temporalDetail == .events else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let counts = Dictionary(
            uniqueKeysWithValues: presentation.dailyCounts.map {
                (calendar.startOfDay(for: $0.date), $0.playCount)
            }
        )
        guard let start = presentation.appliedRange.startDate(relativeTo: today, calendar: calendar)
                ?? counts.keys.min() else { return [] }

        var result: [HeatmapDay] = []
        var day = calendar.startOfDay(for: start)
        while day <= today {
            result.append(HeatmapDay(
                date: day,
                playCount: counts[day] ?? 0
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    private func groupByWeek(
        _ days: [HeatmapDay]
    ) -> [[Int: HeatmapDay]] {
        let calendar = Calendar.current
        var weeks: [[Int: HeatmapDay]] = []
        var current: [Int: HeatmapDay] = [:]
        var previousKey: Int?

        for day in days {
            let parts = calendar.dateComponents(
                [.weekday, .weekOfYear, .yearForWeekOfYear],
                from: day.date
            )
            let key = (parts.yearForWeekOfYear ?? 0) * 100
                + (parts.weekOfYear ?? 0)
            if let previousKey, previousKey != key {
                weeks.append(current)
                current = [:]
            }
            current[(parts.weekday ?? 1) - 1] = day
            previousKey = key
        }
        if !current.isEmpty {
            weeks.append(current)
        }
        return weeks
    }
}

#if os(macOS)
private extension View {
    func macStatsCard() -> some View {
        background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
    }
}
#endif
