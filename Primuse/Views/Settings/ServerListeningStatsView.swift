import PrimuseKit
import SwiftUI

/// 一个服务器源（Navidrome、Emby……）自己记下的播放，和听歌统计同一种版式：
/// 几个数字和一份榜单，不画图。服务器记的是所有客户端的播放，所以不和本机记录相加。
struct ServerListeningStatsView: View {
    let source: MusicSource

    @Environment(ServerListeningStatsService.self) private var statsService
    @State private var range: ServerListeningStatsRange = .month
    @State private var rankTab: RankTab = .tracks
    @State private var isRankingExpanded = false
    @State private var manualRefreshTask: Task<Void, Never>?

    private static let collapsedRankCount = 10

    private enum RankTab: String, CaseIterable {
        case tracks
        case artists
        case albums

        var label: String {
            switch self {
            case .tracks: String(localized: "stats_rank_songs")
            case .artists: String(localized: "stats_rank_artists")
            case .albums: String(localized: "stats_rank_albums")
            }
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: RecapStyle.sectionSpacing) {
                header

                if let presentation {
                    figuresSection(presentation)
                    rankingSection(presentation)
                } else if statsService.isRefreshing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("stats_server_loading")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    ContentUnavailableView(
                        "stats_server_unavailable_title",
                        systemImage: "server.rack",
                        description: Text("stats_server_unavailable_desc")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(.horizontal, RecapStyle.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 56)
            .frame(maxWidth: RecapStyle.maximumContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
        .scrollIndicators(.hidden)
        #endif
        // iPhone Duo 竖栏：滚动内容铺到屏幕边缘，系统的玻璃胶囊浮在上面。
        .pmExtendsUnderVerticalBar()
        .background { RecapBackdrop(tint: nil) }
        .navigationTitle(Text(verbatim: source.name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: activationID) {
            await statsService.activate(source: source)
        }
        .onChange(of: rankTab) { _, _ in isRankingExpanded = false }
        .onChange(of: range) { _, _ in isRankingExpanded = false }
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

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: source.type.iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: source.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                    Text(verbatim: updatedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                refreshButton
            }
            // 铺到 iPhone Duo 竖栏底下时，最上面带按钮的这一行照旧让开竖栏。
            .pmClearOfVerticalBar()

            if statsService.isStale || statsService.errorMessage != nil {
                statusNote
            }

            if isEventHistory {
                RecapPillPicker(options: ServerListeningStatsRange.allCases, selection: $range, scrolls: true) { item in
                    Text(LocalizedStringKey("stats_range_\(item.rawValue)"))
                }
            }
        }
    }

    private var updatedLine: String {
        var parts = [String(localized: "stats_server_authoritative")]
        if let fetchedAt = statsService.snapshot?.fetchedAt {
            parts.append(
                String(localized: "stats_server_last_updated") + " "
                    + fetchedAt.formatted(.dateTime.month().day().hour().minute())
            )
        }
        return parts.joined(separator: " · ")
    }

    private var refreshButton: some View {
        Button {
            manualRefreshTask?.cancel()
            let selectedSource = source
            manualRefreshTask = Task { @MainActor in
                await statsService.refresh(source: selectedSource)
            }
        } label: {
            Group {
                if statsService.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 36, height: 36)
            .background(.primary.opacity(0.07), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(statsService.isRefreshing)
        .accessibilityLabel(Text("stats_server_refresh"))
        .help(Text("stats_server_refresh"))
        .settingsAnchor("stats.serverRefresh")
    }

    private var statusNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                if statsService.isStale {
                    Text(verbatim: staleDescription)
                        .font(.subheadline.weight(.semibold))
                }
                if let error = statsService.errorMessage {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .recapPanel(cornerRadius: 16, padding: 14)
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

    // MARK: - 数字

    private func figuresSection(_ presentation: ServerListeningStatsPresentation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: playsLabel(presentation))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(verbatim: presentation.totalPlays.formatted())
                    .font(.system(size: 58, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: lastPlayedLine(presentation.lastPlayedAt))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)

            RecapFigureRow(figures: figures(presentation))

            Label {
                Text(boundaryKey(presentation))
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figures(_ presentation: ServerListeningStatsPresentation) -> [RecapFigureRow.Figure] {
        var figures: [RecapFigureRow.Figure] = [
            .init(id: "tracks", value: presentation.uniqueTracks.formatted(), label: String(localized: "stats_unique_songs")),
        ]
        if let activeDays = presentation.activeDays {
            figures.append(.init(id: "days", value: activeDays.formatted(), label: String(localized: "stats_active_days")))
        }
        if let duration = presentation.totalListenedSeconds {
            figures.append(.init(id: "duration", value: RecapHeroDuration.format(duration), label: String(localized: "stats_total_duration")))
        }
        if let allTime = presentation.allTimePlayCount {
            figures.append(.init(id: "allTime", value: allTime.formatted(), label: String(localized: "stats_server_all_time_plays")))
        }
        return figures
    }

    private func playsLabel(_ presentation: ServerListeningStatsPresentation) -> String {
        if presentation.temporalDetail == .aggregate {
            return String(localized: "stats_all_time_total")
        }
        return presentation.allTimePlayCount == nil
            ? String(localized: "stats_total_plays")
            : String(localized: "stats_server_recorded_plays")
    }

    private func lastPlayedLine(_ date: Date?) -> String {
        let value = date?.formatted(date: .abbreviated, time: .shortened)
            ?? String(localized: "stats_server_never_played")
        return String(localized: "stats_server_last_played") + " · " + value
    }

    private func boundaryKey(_ presentation: ServerListeningStatsPresentation) -> LocalizedStringKey {
        if presentation.temporalDetail == .aggregate { return "stats_server_aggregate_boundary" }
        return presentation.allTimePlayCount == nil
            ? "stats_server_event_boundary"
            : "stats_server_navidrome_history_boundary"
    }

    // MARK: - 榜单

    private func rankingSection(_ presentation: ServerListeningStatsPresentation) -> some View {
        let items: [ServerListeningStatsRankedItem] = switch rankTab {
        case .tracks: presentation.topTracks
        case .artists: presentation.topArtists
        case .albums: presentation.topAlbums
        }
        let visible = isRankingExpanded ? items : Array(items.prefix(Self.collapsedRankCount))
        return VStack(alignment: .leading, spacing: 14) {
            RecapSectionHeader(title: "stats_recap_top_title") {
                RecapPillPicker(options: RankTab.allCases, selection: $rankTab, compact: true) { tab in
                    Text(verbatim: tab.label)
                }
                .settingsAnchor("stats.serverRank")
            }

            if items.isEmpty {
                Text("stats_rank_empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Rectangle()
                                .fill(.primary.opacity(0.07))
                                .frame(height: 0.5)
                                .padding(.leading, 40)
                        }
                        rankRow(item, position: index)
                    }
                }
                if items.count > Self.collapsedRankCount {
                    Button {
                        pmWithAnimation(.list) { isRankingExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isRankingExpanded ? LocalizedStringKey("update_show_less") : LocalizedStringKey("see_all"))
                            Image(systemName: isRankingExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func rankRow(_ item: ServerListeningStatsRankedItem, position: Int) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(position + 1)")
                .font(.system(size: position == 0 ? 22 : 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(position == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(position == 0 ? .headline : .subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(ListeningRankText.playCount(item.playCount))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .fixedSize()
        }
        .padding(.vertical, position == 0 ? 12 : 9)
        .accessibilityElement(children: .combine)
    }
}
