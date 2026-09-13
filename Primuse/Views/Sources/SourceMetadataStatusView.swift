import Foundation
import PrimuseKit
import SwiftUI

private let visibleMetadataStatusFilters: [MetadataBackfillStatusFilter] = [
    .pending,
    .retry,
    .sourceProblem,
    .unreadable,
    .incomplete,
]

private extension MetadataBackfillStatusFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "metadata_status_filter_all"
        case .pending: "metadata_status_pending"
        case .retry: "metadata_status_retry"
        case .sourceProblem: "metadata_status_source_problem"
        case .unreadable: "metadata_status_unreadable"
        case .incomplete: "metadata_status_incomplete"
        }
    }

    var icon: String {
        switch self {
        case .all: "line.3.horizontal.decrease.circle"
        case .pending: "clock"
        case .retry: "arrow.clockwise.circle"
        case .sourceProblem: "externaldrive.badge.exclamationmark"
        case .unreadable: "waveform.badge.exclamationmark"
        case .incomplete: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .all: .accentColor
        case .pending: .blue
        case .retry: .orange
        case .sourceProblem, .unreadable: .red
        case .incomplete: .secondary
        }
    }
}

// MARK: - Visual tokens

/// 这一页原本每块区域各写各的圆角、描边和留白, 视觉上像几块拼贴。统一成一套
/// 卡片令牌后, 侧栏诊断卡、筛选轨道、结果行共用同一种圆角 / 描边 / 底色节奏。
private enum TagStatusStyle {
    static let cardCorner: CGFloat = 16
    static let rowCorner: CGFloat = 13
    static let chipCorner: CGFloat = 9
    static let glyphSize: CGFloat = 27
    static let glyphGap: CGFloat = 10
    /// 正文相对图标列的缩进, 让路径 / 徽标 / 诊断整齐地挂在标题下方。
    static let contentIndent: CGFloat = glyphSize + glyphGap

    static var cardFill: Color { Color.primary.opacity(0.045) }
    static var cardStroke: Color { Color.primary.opacity(0.075) }
    static var fieldFill: Color { Color.primary.opacity(0.06) }
}

private struct TagStatusCard: ViewModifier {
    var padding: CGFloat = 14
    var corner: CGFloat = TagStatusStyle.cardCorner

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                TagStatusStyle.cardFill,
                in: RoundedRectangle(cornerRadius: corner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(TagStatusStyle.cardStroke, lineWidth: 1)
            }
    }
}

private extension View {
    func tagStatusCard(
        padding: CGFloat = 14,
        corner: CGFloat = TagStatusStyle.cardCorner
    ) -> some View {
        modifier(TagStatusCard(padding: padding, corner: corner))
    }
}

/// 健康度分布条的一段。数量为 0 的状态不参与绘制。
private struct TagStatusDistributionSegment: Identifiable {
    let filter: MetadataBackfillStatusFilter
    let count: Int
    var id: String { filter.rawValue }
}

private struct TagStatusDistributionBar: View {
    let segments: [TagStatusDistributionSegment]
    var height: CGFloat = 7

    var body: some View {
        let total: Int = max(1, segments.reduce(0) { $0 + $1.count })
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let gapCount: CGFloat = CGFloat(max(0, segments.count - 1))
            let available: CGFloat = max(0, proxy.size.width - spacing * gapCount)
            HStack(spacing: spacing) {
                ForEach(segments) { segment in
                    let fraction: CGFloat = CGFloat(segment.count) / CGFloat(total)
                    let width: CGFloat = max(4, available * fraction)
                    Capsule(style: .continuous)
                        .fill(segment.filter.color)
                        .frame(width: width)
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
        }
        .frame(height: height)
        .clipShape(Capsule(style: .continuous))
        .background(Color.primary.opacity(0.07), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

struct SourceMetadataStatusView: View {
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(\.dismiss) private var dismiss
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let source: MusicSource

    @State private var sourceItems: [MetadataBackfillStatusDisplayItem] = []
    @State private var projectedItems: [MetadataBackfillStatusDisplayItem] = []
    @State private var visibleItemCount = 0
    @State private var selectedFilter: MetadataBackfillStatusFilter = .all
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var projectionGeneration: UInt64 = 0
    @State private var projectionTask: Task<Void, Never>?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var isProjecting = false
    @State private var resultMessage: String?
    @State private var batchRereadTask: Task<Void, Never>?
    @State private var batchProgress: MetadataTagRereadProgress?
    @State private var showsExplanation = false

    private var summary: MetadataBackfillSourceSummary {
        backfill.sourceStatusSummary(forSource: source.id)
    }

    private var usesTwoColumnLayout: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        Group {
            if usesTwoColumnLayout {
                wideLayout
            } else {
                compactLayout
            }
        }
        .navigationTitle("metadata_status_title")
        .task(id: backfill.statusRevision) {
            reload(force: !backfill.hasStatusDisplaySnapshot(forSource: source.id))
        }
        .onChange(of: selectedFilter) { _, _ in
            scheduleProjection(resetVisibleWindow: true)
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearchProjection(for: newValue)
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            projectionTask?.cancel()
            batchRereadTask?.cancel()
        }
        .alert(
            "metadata_status_result_title",
            isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil } }
            )
        ) {
            Button("done", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
        #if os(iOS)
        .toolbar {
            if !usesTwoColumnLayout {
                ToolbarItem(placement: .topBarTrailing) {
                    compactBatchRereadButton
                }
            }
            if !usesTwoColumnLayout, showsCompactPrimaryAction {
                ToolbarItem(placement: .topBarTrailing) {
                    compactPrimaryActionButton
                }
            }
        }
        #endif
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            modalFooter
        }
        #endif
    }

    // MARK: - Layouts

    private var wideLayout: some View {
        GeometryReader { proxy in
            let rawWidth: CGFloat = proxy.size.width * 0.34
            let sidebarWidth: CGFloat = min(max(rawWidth, 268), 344)
            HStack(spacing: 0) {
                ScrollView {
                    diagnosticSidebar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                }
                .frame(width: sidebarWidth)
                .background(.regularMaterial)

                Divider()

                resultsList
            }
        }
    }

    private var compactLayout: some View {
        List {
            compactOverviewCard
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            compactResultsControls
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            resultRows

            explanationSection
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 20, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: Text("metadata_status_search")
        )
        #else
        .searchable(text: $searchText, prompt: Text("metadata_status_search"))
        #endif
    }

    private var resultsList: some View {
        List {
            Section {
                resultRows
            } header: {
                wideResultsControls
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var resultRows: some View {
        if let progress = batchProgress {
            batchProgressCard(progress)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if isProjecting, projectedItems.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if projectedItems.isEmpty {
            ContentUnavailableView(
                "metadata_status_empty",
                systemImage: "checkmark.circle",
                description: Text("metadata_status_empty_description")
            )
            .frame(maxWidth: .infinity, minHeight: 220)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(projectedItems.prefix(visibleItemCount)) { item in
                statusRow(item, compact: !usesTwoColumnLayout)
                    .tagStatusCard(padding: 12, corner: TagStatusStyle.rowCorner)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if visibleItemCount < projectedItems.count {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .id("metadata-status-page-\(visibleItemCount)")
                    .onAppear {
                        loadNextPage()
                    }
            }
        }
    }

    // MARK: - Sidebar (regular width)

    private var diagnosticSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceIdentityCard
            healthCard
            statusTrack
            actionPanel
            explanationSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceIdentityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                sourceGlyph

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(source.type.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            locationLine(textStyle: .caption)
        }
        .tagStatusCard()
        .accessibilityElement(children: .combine)
    }

    private var sourceGlyph: some View {
        Image(systemName: source.type.iconName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 34, height: 34)
            .background(
                Color.accentColor.opacity(0.13),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private func locationLine(textStyle: Font.TextStyle) -> some View {
        Text(sourceIdentityText)
            .font(.system(textStyle, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                healthGlyph

                VStack(alignment: .leading, spacing: 3) {
                    Text(healthSummaryText)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(affectedCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !distributionSegments.isEmpty {
                TagStatusDistributionBar(segments: distributionSegments)
            }

            MetadataReadingStatusView(sourceID: source.id)
        }
        .tagStatusCard()
    }

    private var healthGlyph: some View {
        Image(systemName: healthIcon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(healthTint)
            .frame(width: 30, height: 30)
            .background(
                healthTint.opacity(0.14),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var healthTint: Color {
        if summary.problemCount > 0 { return .orange }
        if summary.activeQueueCount > 0 { return .blue }
        return .green
    }

    private var healthIcon: String {
        if summary.problemCount > 0 { return "exclamationmark.triangle.fill" }
        if summary.activeQueueCount > 0 { return "clock.fill" }
        return "checkmark.circle.fill"
    }

    private var distributionSegments: [TagStatusDistributionSegment] {
        visibleMetadataStatusFilters.compactMap { filter in
            let count = summary.count(for: filter)
            guard count > 0 else { return nil }
            return TagStatusDistributionSegment(filter: filter, count: count)
        }
    }

    private var affectedCountText: String {
        String(
            format: String(localized: "metadata_status_list_count_format"),
            summary.affectedCount
        )
    }

    private var resultCountText: String {
        String(
            format: String(localized: "metadata_status_list_count_format"),
            projectedItems.count
        )
    }

    private var compactOverviewCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                sourceGlyph

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(source.type.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if summary.retryableCount > 0 {
                    compactRetryActionButton
                }
            }

            locationLine(textStyle: .caption2)

            Divider()
                .opacity(0.6)

            HStack(alignment: .top, spacing: 9) {
                healthGlyph

                VStack(alignment: .leading, spacing: 3) {
                    Text(healthSummaryText)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(affectedCountText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !distributionSegments.isEmpty {
                TagStatusDistributionBar(segments: distributionSegments, height: 6)
            }

            MetadataReadingStatusView(sourceID: source.id)
        }
        .tagStatusCard()
    }

    private var sourceIdentityText: String {
        let location = source.connectionSummary
            ?? source.basePath
            ?? source.host
            ?? String(localized: "metadata_status_location_unknown")
        let safeLocation = MetadataBackfillDisplayRedactionPolicy.redact(location)
        return "\(safeLocation) · \(String(source.id.prefix(8)))"
    }

    private var healthSummaryText: String {
        guard summary.affectedCount > 0 else {
            return String(localized: "metadata_status_health_clear")
        }
        return String(
            format: String(localized: "metadata_status_health_summary_format"),
            summary.activeQueueCount,
            summary.problemCount
        )
    }

    private var showsCompactPrimaryAction: Bool {
        backfill.isUserInitiated(forSource: source.id) || summary.activeQueueCount > 0
    }

    // MARK: - Filter track

    private var statusTrack: some View {
        VStack(spacing: 0) {
            ForEach(visibleMetadataStatusFilters) { filter in
                Button {
                    selectedFilter = selectedFilter == filter ? .all : filter
                } label: {
                    statusTrackLabel(filter)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(filter.title))
                .accessibilityValue(Text(summary.count(for: filter).formatted()))
                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                .accessibilityIdentifier("metadata-status-track-\(filter.rawValue)")

                if filter != visibleMetadataStatusFilters.last {
                    Divider()
                        .padding(.leading, 12 + TagStatusStyle.contentIndent)
                        .opacity(0.5)
                }
            }
        }
        .background(
            TagStatusStyle.cardFill,
            in: RoundedRectangle(cornerRadius: TagStatusStyle.cardCorner, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: TagStatusStyle.cardCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TagStatusStyle.cardCorner, style: .continuous)
                .strokeBorder(TagStatusStyle.cardStroke, lineWidth: 1)
        }
    }

    private func statusTrackLabel(_ filter: MetadataBackfillStatusFilter) -> some View {
        let isSelected = selectedFilter == filter
        let count = summary.count(for: filter)
        return HStack(spacing: TagStatusStyle.glyphGap) {
            filterGlyph(filter, dimmed: count == 0)

            Text(filter.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(count == 0 ? Color.secondary : Color.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(count.formatted())
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    (isSelected ? Color.accentColor : Color.primary).opacity(isSelected ? 0.14 : 0.07),
                    in: Capsule(style: .continuous)
                )

            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 10)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.10) : .clear)
    }

    private func filterGlyph(_ filter: MetadataBackfillStatusFilter, dimmed: Bool) -> some View {
        Image(systemName: filter.icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(dimmed ? Color.secondary : filter.color)
            .frame(width: TagStatusStyle.glyphSize, height: TagStatusStyle.glyphSize)
            .background(
                (dimmed ? Color.secondary : filter.color).opacity(dimmed ? 0.08 : 0.14),
                in: RoundedRectangle(cornerRadius: TagStatusStyle.chipCorner, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Compact controls

    /// 这一排只放筛选。批量重读被钉在滚动条右端时, 圆形按钮既和胶囊形状打架,
    /// 又会让横滑的胶囊直接撞上去, 所以移到导航栏当独立动作。
    private var compactResultsControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(compactVisibleFilters) { filter in
                    compactFilterChip(filter)
                }

                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(resultCountText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 1)
            .padding(.trailing, 16)
        }
        .textCase(nil)
    }

    private var compactVisibleFilters: [MetadataBackfillStatusFilter] {
        MetadataBackfillStatusFilter.allCases.filter { filter in
            filter == .all || filter == selectedFilter || summary.count(for: filter) > 0
        }
    }

    private func compactFilterChip(_ filter: MetadataBackfillStatusFilter) -> some View {
        let isSelected = selectedFilter == filter
        let count = summary.count(for: filter)
        return Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filter.icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : filter.color)
                Text(filter.title)
                    .lineLimit(1)
                Text(count.formatted())
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : TagStatusStyle.fieldFill,
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.38) : TagStatusStyle.cardStroke,
                        lineWidth: 1
                    )
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(filter.title))
        .accessibilityValue(Text(count.formatted()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("metadata-status-filter-\(filter.rawValue)")
    }

    // MARK: - Actions

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("metadata_status_actions")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    reload(force: true)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("metadata_status_refresh")
                .accessibilityLabel(Text("metadata_status_refresh"))
                .accessibilityIdentifier("metadata-status-refresh")
            }

            primaryActionButton
            retryActionButton
        }
        .tagStatusCard()
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if backfill.isUserInitiated(forSource: source.id) {
            Button {
                performPrimaryAction()
            } label: {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("metadata_status_pause")
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("metadata-status-primary-action")
        } else {
            Button {
                performPrimaryAction()
            } label: {
                Label("metadata_status_continue", systemImage: "play.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!source.isEnabled || summary.activeQueueCount == 0)
            .accessibilityIdentifier("metadata-status-primary-action")
        }
    }

    private var compactPrimaryActionButton: some View {
        let isRunning = backfill.isUserInitiated(forSource: source.id)
        return Button {
            performPrimaryAction()
        } label: {
            Image(systemName: isRunning ? "pause.fill" : "play.fill")
        }
        .disabled(!isRunning && (!source.isEnabled || summary.activeQueueCount == 0))
        .help(isRunning ? "metadata_status_pause" : "metadata_status_continue")
        .accessibilityLabel(Text(isRunning ? "metadata_status_pause" : "metadata_status_continue"))
        .accessibilityIdentifier("metadata-status-primary-action")
    }

    private var retryActionButton: some View {
        Button {
            retryFailedItems()
        } label: {
            Label("metadata_status_retry_failed", systemImage: "arrow.clockwise")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(
            !source.isEnabled
                || summary.retryableCount == 0
                || backfill.isUserInitiated(forSource: source.id)
        )
        .accessibilityIdentifier("metadata-status-secondary-action")
    }

    private var compactRetryActionButton: some View {
        Button {
            retryFailedItems()
        } label: {
            Label("retry", systemImage: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(Color.orange)
                .background(Color.orange.opacity(0.13), in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(
            !source.isEnabled
                || summary.retryableCount == 0
                || backfill.isUserInitiated(forSource: source.id)
        )
        .accessibilityIdentifier("metadata-status-secondary-action")
        .accessibilityLabel(Text("metadata_status_retry_failed"))
    }

    /// 搜索框里的词还没落到 `debouncedSearchText` 时列表仍是上一批结果, 此时
    /// 批量重读会读到用户没看到的那批歌, 所以一并算作不可用。
    private var isBatchRereadDisabled: Bool {
        batchRereadTask != nil || backfill.batchRereadingSourceIDs.contains(source.id)
            || isProjecting || projectedItems.isEmpty || !source.isEnabled
            || searchText.trimmingCharacters(in: .whitespacesAndNewlines) != debouncedSearchText
    }

    private var isBatchRereading: Bool {
        backfill.batchRereadingSourceIDs.contains(source.id)
    }

    private var batchRefreshButton: some View {
        Button {
            rereadFilteredItems()
        } label: {
            ZStack {
                Circle()
                    .fill(TagStatusStyle.fieldFill)
                    .frame(width: 30, height: 30)
                if isBatchRereading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.semibold))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isBatchRereadDisabled)
        .help("metadata_status_reread_filtered")
        .accessibilityLabel(Text("metadata_status_reread_filtered"))
        .accessibilityIdentifier("metadata-status-reread-filtered")
    }

    private var compactBatchRereadButton: some View {
        Button {
            rereadFilteredItems()
        } label: {
            if isBatchRereading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(isBatchRereadDisabled)
        .help("metadata_status_reread_filtered")
        .accessibilityLabel(Text("metadata_status_reread_filtered"))
        .accessibilityIdentifier("metadata-status-reread-filtered")
    }

    // MARK: - Results header (regular width)

    private var wideResultsControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Text("metadata_status_result_title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(resultCountText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                batchRefreshButton
            }

            searchField

            if selectedFilter != .all {
                activeFilterChip
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 结果行现在是带底色的卡片, 吸顶的表头必须有自己的背景, 否则滚动时
        // 卡片会从标题和搜索框下面透出来。
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
        .textCase(nil)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("metadata_status_search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("clear"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(TagStatusStyle.fieldFill, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(TagStatusStyle.cardStroke, lineWidth: 1)
        }
        .accessibilityIdentifier("metadata-status-search")
    }

    /// 侧栏轨道已经承担筛选, 结果区只保留一枚"当前筛选"标记, 点按即可回到全部,
    /// 避免两处筛选控件互相打架。
    private var activeFilterChip: some View {
        Button {
            selectedFilter = .all
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selectedFilter.icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selectedFilter.color)
                Text(selectedFilter.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("metadata_status_filter"))
        .accessibilityValue(Text(selectedFilter.title))
        .accessibilityIdentifier("metadata-status-filter-all")
    }

    private func batchProgressCard(_ progress: MetadataTagRereadProgress) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(batchProgressText(progress))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if batchRereadTask != nil {
                    Button("cancel") { batchRereadTask?.cancel() }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                }
            }

            if batchRereadTask != nil, progress.total > 0 {
                ProgressView(
                    value: Double(progress.processed),
                    total: Double(max(1, progress.total))
                )
                .progressViewStyle(.linear)
            }
        }
        .tagStatusCard(padding: 11, corner: TagStatusStyle.rowCorner)
    }

    // MARK: - Result rows

    private func statusRow(
        _ item: MetadataBackfillStatusDisplayItem,
        compact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: TagStatusStyle.glyphGap) {
                stateGlyph(item.state)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(compact ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                        .lineLimit(2)
                    if let artist = item.artistName, !artist.isEmpty {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                stateBadge(item.state)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(displayPath(for: item.filePath))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayPath(for: item.filePath))
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)

                metadataLine(item)

                diagnosticCallout(item)
            }
            .padding(.leading, TagStatusStyle.contentIndent)
        }
        .accessibilityElement(children: .contain)
    }

    private func stateGlyph(_ state: MetadataBackfillItemState) -> some View {
        let color = stateColor(state)
        return Image(systemName: stateIcon(state))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: TagStatusStyle.glyphSize, height: TagStatusStyle.glyphSize)
            .background(
                color.opacity(0.14),
                in: RoundedRectangle(cornerRadius: TagStatusStyle.chipCorner, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private func stateBadge(_ state: MetadataBackfillItemState) -> some View {
        Text(stateTitle(state))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateColor(state))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor(state).opacity(0.12), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(stateColor(state).opacity(0.22), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    /// 格式、尝试次数与缺失字段统一成同一排小标签; 缺失字段在"可播放但不完整"
    /// 状态下是已确认的结论, 因此用红色标出。
    private func metadataLine(_ item: MetadataBackfillStatusDisplayItem) -> some View {
        let reasons = workReasonValues(displayWorkReasons(for: item))
        let highlightsUnavailableFields = item.state == .playableIncomplete
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                formatBadge(item.fileFormat)
                attemptText(item.attemptCount)
                Spacer(minLength: 0)
            }

            if !reasons.isEmpty {
                reasonChips(reasons, highlighted: highlightsUnavailableFields)
            }
        }
    }

    @ViewBuilder
    private func reasonChips(_ reasons: [String], highlighted: Bool) -> some View {
        let tint: Color = highlighted ? .red : .secondary
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                ForEach(reasons, id: \.self) { reason in
                    reasonChip(reason, tint: tint, highlighted: highlighted)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(reasons, id: \.self) { reason in
                    reasonChip(reason, tint: tint, highlighted: highlighted)
                }
            }
        }
    }

    private func reasonChip(_ reason: String, tint: Color, highlighted: Bool) -> some View {
        Text(reason)
            .font(.caption2.weight(highlighted ? .semibold : .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                tint.opacity(highlighted ? 0.11 : 0.09),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .fixedSize()
    }

    private func formatBadge(_ format: String) -> some View {
        Text(format)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .fixedSize()
    }

    @ViewBuilder
    private func attemptText(_ count: Int) -> some View {
        if count > 0 {
            Text(String(
                format: String(localized: "metadata_status_attempt_format"),
                count
            ))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .fixedSize()
        }
    }

    /// 诊断原因、时间与"重新读取"合并到一块带色底的说明框里, 让每行最重要的
    /// "为什么出现在这里 / 现在能做什么"始终成对出现。
    @ViewBuilder
    private func diagnosticCallout(_ item: MetadataBackfillStatusDisplayItem) -> some View {
        let isFailure = item.state.isFailure
        let tint: Color = isFailure ? .red : .secondary
        let canReread = backfill.canRereadTags(
            songID: item.songID,
            expectedSourceID: source.id
        )

        if let diagnostic = item.diagnostic {
            diagnosticBox(
                text: MetadataBackfillDisplayRedactionPolicy.redact(diagnostic.reason),
                date: diagnostic.lastAttemptAt,
                tint: tint,
                isFailure: isFailure,
                reread: canReread ? item : nil
            )
        } else if let fallback = fallbackReason(item.state) {
            diagnosticBox(
                text: fallback,
                date: nil,
                tint: tint,
                isFailure: isFailure,
                reread: canReread ? item : nil
            )
        }
    }

    private func diagnosticBox(
        text: String,
        date: Date?,
        tint: Color,
        isFailure: Bool,
        reread: MetadataBackfillStatusDisplayItem?
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let reread {
                rereadButton(reread)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            tint.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .help(text)
    }

    private func rereadButton(_ item: MetadataBackfillStatusDisplayItem) -> some View {
        let isReading = backfill.isRereadingTags(songID: item.songID)
        let title = isReading
            ? String(localized: "reread_song_tags_in_progress")
            : String(localized: "reread_song_tags")
        return Button {
            reread(item)
        } label: {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(width: 27, height: 27)
                if isReading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2.weight(.bold))
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isReading)
        .help(title)
        .accessibilityLabel(Text(title))
    }

    // MARK: - Explanation

    private var explanationSection: some View {
        DisclosureGroup(isExpanded: $showsExplanation) {
            Text("metadata_status_explanation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("metadata_status_explanation_title", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
        }
        .tagStatusCard(padding: 12)
    }

    // MARK: - Data

    private func displayPath(for filePath: String) -> String {
        let redacted = MetadataBackfillDisplayRedactionPolicy.redact(filePath)
        let path: String
        if let components = URLComponents(string: redacted),
           let scheme = components.scheme,
           ["http", "https", "file"].contains(scheme.lowercased()),
           !components.path.isEmpty {
            path = components.path
        } else {
            path = redacted
        }

        guard let basePath = source.basePath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              !basePath.isEmpty else {
            return path
        }

        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedPath == basePath || normalizedPath.hasPrefix("\(basePath)/") else {
            return path
        }
        let relative = normalizedPath.dropFirst(basePath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "/" : "/\(relative)"
    }

    private func reload(force: Bool) {
        if force { backfill.refreshStatusSnapshot() }
        sourceItems = backfill.statusDisplayItems(forSource: source.id)
        scheduleProjection(resetVisibleWindow: false)
    }

    private func scheduleSearchProjection(for value: String) {
        searchDebounceTask?.cancel()
        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            debouncedSearchText = query
            scheduleProjection(resetVisibleWindow: true)
        }
    }

    private func scheduleProjection(resetVisibleWindow: Bool) {
        projectionTask?.cancel()
        projectionGeneration = projectionGeneration == .max ? 1 : projectionGeneration + 1
        let generation = projectionGeneration
        let snapshot = sourceItems
        let filter = selectedFilter
        let query = debouncedSearchText
        let previousVisibleCount = visibleItemCount
        isProjecting = true

        let worker = Task.detached(priority: .userInitiated) {
            MetadataBackfillStatusProjectionPolicy.project(
                snapshot,
                filter: filter,
                query: query
            )
        }
        projectionTask = Task { @MainActor in
            let projection = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, projectionGeneration == generation else { return }
            projectedItems = projection
            let initialCount = MetadataBackfillStatusPaginationPolicy.initialVisibleCount(
                totalCount: projection.count
            )
            if resetVisibleWindow {
                visibleItemCount = initialCount
            } else {
                visibleItemCount = min(
                    projection.count,
                    max(initialCount, previousVisibleCount)
                )
            }
            isProjecting = false
        }
    }

    private func loadNextPage() {
        visibleItemCount = MetadataBackfillStatusPaginationPolicy.nextVisibleCount(
            currentCount: visibleItemCount,
            totalCount: projectedItems.count
        )
    }

    private func performPrimaryAction() {
        if backfill.isUserInitiated(forSource: source.id) {
            backfill.pauseUserInitiated(sourceID: source.id)
            resultMessage = String(localized: "metadata_status_paused_message")
        } else {
            let started = backfill.startUserInitiated(sourceID: source.id)
            resultMessage = String(localized: started
                ? "metadata_status_continue_started"
                : "metadata_status_no_pending_work")
        }
        reload(force: true)
    }

    private func retryFailedItems() {
        let reopened = backfill.retryFailed(
            forSource: source.id,
            startImmediately: false
        )
        if reopened > 0 {
            _ = backfill.startUserInitiated(sourceID: source.id)
            resultMessage = String(
                format: String(localized: "metadata_status_retry_started_format"),
                reopened
            )
        } else {
            resultMessage = String(localized: "metadata_status_no_retryable_work")
        }
        reload(force: true)
    }

    private func reread(_ item: MetadataBackfillStatusDisplayItem) {
        Task {
            let result = await backfill.rereadTags(
                songID: item.songID,
                expectedSourceID: source.id
            )
            switch result {
            case .completed(let kind):
                resultMessage = kind.localizedRereadResult
            case .alreadyReading:
                resultMessage = String(localized: "reread_song_tags_in_progress")
            case .unsupported:
                resultMessage = String(localized: "reread_song_tags_unsupported")
            case .failed(let reason):
                resultMessage = String(
                    format: String(localized: "reread_song_tags_failed_detail_format"),
                    URL(fileURLWithPath: item.filePath).lastPathComponent,
                    item.fileFormat,
                    source.name,
                    MetadataBackfillDisplayRedactionPolicy.redact(reason)
                )
            }
            reload(force: true)
        }
    }

    private func rereadFilteredItems() {
        guard batchRereadTask == nil else { return }
        let songIDs = projectedItems.map(\.songID)
        batchRereadTask = Task { @MainActor in
            defer { batchRereadTask = nil }
            let result = await backfill.rereadTags(songIDs: songIDs, expectedSourceID: source.id) {
                batchProgress = $0
            }
            reload(force: true)
            guard !Task.isCancelled else { return }
            resultMessage = String(
                format: String(localized: "metadata_status_reread_result_format"),
                Int64(result.completed), Int64(result.failed), Int64(result.skipped)
            )
        }
    }

    private func batchProgressText(_ progress: MetadataTagRereadProgress) -> String {
        if progress.isCancelled {
            return String(localized: "reread_song_tags_failure_cancelled")
        }
        if batchRereadTask == nil {
            return String(
                format: String(localized: "metadata_status_reread_result_format"),
                Int64(progress.completed), Int64(progress.failed), Int64(progress.skipped)
            )
        }
        return String(
            format: String(localized: "metadata_status_reread_progress_format"),
            Int64(progress.processed), Int64(progress.total)
        )
    }

    private func stateTitle(_ state: MetadataBackfillItemState) -> LocalizedStringKey {
        switch state {
        case .pendingInspection: "metadata_status_state_pending"
        case .waitingForWiFi: "backfill_waiting_for_wifi"
        case .retryPending: "metadata_status_state_retry"
        case .sourceUnavailable: "metadata_status_state_source_unavailable"
        case .fileUnavailable: "metadata_status_state_file_unavailable"
        case .unreadableTags: "metadata_status_state_unreadable"
        case .playableIncomplete: "metadata_status_state_incomplete"
        case .stalled: "metadata_status_state_stalled"
        }
    }

    private func stateIcon(_ state: MetadataBackfillItemState) -> String {
        switch state {
        case .pendingInspection: "clock"
        case .waitingForWiFi: "wifi.exclamationmark"
        case .retryPending: "arrow.clockwise.circle"
        case .sourceUnavailable: "externaldrive.badge.exclamationmark"
        case .fileUnavailable: "doc.badge.ellipsis"
        case .unreadableTags: "waveform.badge.exclamationmark"
        case .playableIncomplete: "info.circle"
        case .stalled: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private func stateColor(_ state: MetadataBackfillItemState) -> Color {
        switch state {
        case .pendingInspection: .blue
        case .waitingForWiFi, .retryPending: .orange
        case .sourceUnavailable, .fileUnavailable, .unreadableTags: .red
        case .playableIncomplete: .secondary
        case .stalled: .purple
        }
    }

    private func workReasonValues(_ reasons: MetadataBackfillWorkReasons) -> [String] {
        var values: [String] = []
        if reasons.contains(.duration) { values.append(String(localized: "metadata_status_reason_duration")) }
        if reasons.contains(.artwork) { values.append(String(localized: "metadata_status_reason_artwork")) }
        if reasons.contains(.title) { values.append(String(localized: "metadata_status_reason_title")) }
        if reasons.contains(.albumArtist) { values.append(String(localized: "metadata_status_reason_album_artist")) }
        if reasons.contains(.artist) { values.append(String(localized: "metadata_status_reason_artist")) }
        return values
    }

    private func displayWorkReasons(
        for item: MetadataBackfillStatusDisplayItem
    ) -> MetadataBackfillWorkReasons {
        var reasons = item.workReasons
        // `playableIncomplete` closes the duration inspection leg to avoid an
        // endless retry loop, but the missing duration still explains the row
        // to the user and therefore remains visible as a confirmed red field.
        if item.state == .playableIncomplete, item.hasMissingDuration {
            reasons.insert(.duration)
        }
        return reasons
    }

    private func fallbackReason(_ state: MetadataBackfillItemState) -> String? {
        switch state {
        case .pendingInspection:
            String(localized: "metadata_status_pending_reason")
        case .waitingForWiFi:
            String(localized: "backfill_waiting_for_wifi")
        case .retryPending:
            String(localized: "metadata_status_retry_reason")
        case .sourceUnavailable:
            String(localized: "metadata_status_source_unavailable_reason")
        case .fileUnavailable:
            String(localized: "metadata_status_file_unavailable_reason")
        case .unreadableTags:
            String(localized: "reread_song_tags_failure_no_supported_metadata")
        case .playableIncomplete:
            String(localized: "metadata_status_incomplete_unverified_reason")
        case .stalled:
            String(localized: "metadata_status_stalled_reason")
        }
    }

    #if os(macOS)
    private var modalFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                Button("done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }
    #endif
}
