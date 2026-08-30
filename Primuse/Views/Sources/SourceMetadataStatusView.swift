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

struct SourceMetadataStatusView: View {
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(\.dismiss) private var dismiss
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    let source: MusicSource

    @State private var items: [MetadataBackfillStatusItem] = []
    @State private var selectedFilter: MetadataBackfillStatusFilter = .all
    @State private var searchText = ""
    @State private var resultMessage: String?
    @State private var isStatusExplanationExpanded = false

    private var summary: MetadataBackfillSourceSummary {
        backfill.sourceStatusSummary(forSource: source.id)
    }

    private var filteredItems: [MetadataBackfillStatusItem] {
        items.filter { item in
            guard selectedFilter.includes(item.state) else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return item.song.title.localizedCaseInsensitiveContains(query)
                || item.song.filePath.localizedCaseInsensitiveContains(query)
                || (item.song.artistName?.localizedCaseInsensitiveContains(query) ?? false)
                || item.song.fileFormat.rawValue.localizedCaseInsensitiveContains(query)
        }
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
            // Failure records can arrive in a burst. Coalesce their observable
            // revisions so a large source is filtered and sorted once after the
            // burst instead of once per completed Range request.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            reload(force: items.isEmpty)
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
        #if os(macOS)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            modalFooter
        }
        #endif
    }

    private var wideLayout: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    diagnosticSidebar
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
                .frame(width: proxy.size.width / 3)
                .background(.regularMaterial)

                Divider()

                resultsList
            }
        }
    }

    private var compactLayout: some View {
        List {
            Section {
                diagnosticSidebar
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            resultSection
        }
        .listStyle(.plain)
    }

    private var resultsList: some View {
        List {
            resultSection
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var resultSection: some View {
        Section {
            if filteredItems.isEmpty {
                ContentUnavailableView(
                    "metadata_status_empty",
                    systemImage: "checkmark.circle",
                    description: Text("metadata_status_empty_description")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
                .listRowSeparator(.hidden)
            } else {
                ForEach(filteredItems) { item in
                    statusRow(item)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
        } header: {
            resultsControls
        }
    }

    private var diagnosticSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sourceIdentityHeader

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text(healthSummaryText)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(
                    format: String(localized: "metadata_status_list_count_format"),
                    summary.affectedCount
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            statusTrack

            DisclosureGroup(isExpanded: $isStatusExplanationExpanded) {
                Text("metadata_status_explanation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Label("metadata_status_explanation_title", systemImage: "info.circle")
                    .font(.subheadline.weight(.medium))
            }
            .tint(Color.secondary)

            actionPanel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceIdentityHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: source.type.iconName)
                    .foregroundStyle(Color.accentColor)
                Text(source.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(source.type.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(sourceIdentityText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .combine)
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

    private var statusTrack: some View {
        VStack(spacing: 0) {
            ForEach(visibleMetadataStatusFilters) { filter in
                Button {
                    selectedFilter = selectedFilter == filter ? .all : filter
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: filter.icon)
                            .foregroundStyle(filter.color)
                            .frame(width: 20)
                        Text(filter.title)
                            .font(.subheadline.weight(selectedFilter == filter ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(summary.count(for: filter).formatted())
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(selectedFilter == filter ? Color.accentColor : Color.primary)
                        if selectedFilter == filter {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(selectedFilter == filter ? Color.accentColor.opacity(0.12) : .clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(filter.title))
                .accessibilityValue(Text(summary.count(for: filter).formatted()))
                .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                .accessibilityIdentifier("metadata-status-track-\(filter.rawValue)")

                if filter != visibleMetadataStatusFilters.last {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("metadata_status_actions")
                    .font(.headline)
                Spacer()
                Button {
                    reload(force: true)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("metadata_status_refresh")
                .accessibilityLabel(Text("metadata_status_refresh"))
                .accessibilityIdentifier("metadata-status-refresh")
            }

            if backfill.isUserInitiated(forSource: source.id) {
                Button {
                    backfill.pauseUserInitiated(sourceID: source.id)
                    resultMessage = String(localized: "metadata_status_paused_message")
                    reload(force: true)
                } label: {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("metadata_status_pause")
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("metadata-status-primary-action")
            } else {
                Button {
                    let started = backfill.startUserInitiated(sourceID: source.id)
                    resultMessage = String(localized: started
                        ? "metadata_status_continue_started"
                        : "metadata_status_no_pending_work")
                    reload(force: true)
                } label: {
                    Label("metadata_status_continue", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!source.isEnabled || summary.activeQueueCount == 0)
                .accessibilityIdentifier("metadata-status-primary-action")
            }

            Button {
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
            } label: {
                Label("metadata_status_retry_failed", systemImage: "arrow.clockwise.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    }

    private var resultsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("metadata_status_result_title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(String(
                    format: String(localized: "metadata_status_list_count_format"),
                    filteredItems.count
                ))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            TextField("metadata_status_search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("metadata-status-search")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(MetadataBackfillStatusFilter.allCases) { filter in
                        filterChip(filter)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 8)
        .textCase(nil)
    }

    private func filterChip(_ filter: MetadataBackfillStatusFilter) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(filter.title)
                    .lineLimit(1)
            }
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.16),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("metadata-status-filter-\(filter.rawValue)")
    }

    private func statusRow(_ item: MetadataBackfillStatusItem) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
            GridRow(alignment: .top) {
                Image(systemName: stateIcon(item.state))
                    .foregroundStyle(stateColor(item.state))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.song.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if let artist = item.song.artistName, !artist.isEmpty {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                stateBadge(item.state)
            }

            GridRow {
                Color.clear
                    .frame(width: 20, height: 1)
                Text(displayPath(for: item.song))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayPath(for: item.song))
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
                    .gridCellColumns(2)
            }

            GridRow {
                Color.clear
                    .frame(width: 20, height: 1)
                metadataLine(item)
                    .gridCellColumns(2)
            }

            if let diagnostic = item.diagnostic {
                GridRow {
                    Color.clear
                        .frame(width: 20, height: 1)
                    diagnosticText(
                        MetadataBackfillDisplayRedactionPolicy.redact(diagnostic.reason),
                        date: diagnostic.lastAttemptAt,
                        isFailure: item.state.isFailure
                    )
                    .gridCellColumns(2)
                }
            } else if let fallback = fallbackReason(item.state) {
                GridRow {
                    Color.clear
                        .frame(width: 20, height: 1)
                    diagnosticText(fallback, date: nil, isFailure: item.state.isFailure)
                        .gridCellColumns(2)
                }
            }

            if backfill.canRereadTags(for: item.song) {
                GridRow {
                    Color.clear
                        .frame(width: 20, height: 1)
                    HStack {
                        Spacer(minLength: 0)
                        rereadButton(item)
                    }
                    .gridCellColumns(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func stateBadge(_ state: MetadataBackfillItemState) -> some View {
        Text(stateTitle(state))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(stateColor(state))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stateColor(state).opacity(0.1), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(stateColor(state).opacity(0.24), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private func metadataLine(_ item: MetadataBackfillStatusItem) -> some View {
        let reasons = workReasonText(item.workReasons)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                formatBadge(item.song.fileFormat.rawValue.uppercased())
                if !reasons.isEmpty {
                    Text(reasons)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                attemptText(item.attemptCount)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    formatBadge(item.song.fileFormat.rawValue.uppercased())
                    attemptText(item.attemptCount)
                }
                if !reasons.isEmpty {
                    Text(reasons)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func formatBadge(_ format: String) -> some View {
        Text(format)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
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
            .foregroundStyle(.secondary)
            .fixedSize()
        }
    }

    private func diagnosticText(
        _ text: String,
        date: Date?,
        isFailure: Bool
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .help(text)
    }

    private func rereadButton(_ item: MetadataBackfillStatusItem) -> some View {
        let isReading = backfill.isRereadingTags(songID: item.song.id)
        let title = isReading
            ? String(localized: "reread_song_tags_in_progress")
            : String(localized: "reread_song_tags")
        return Button {
            reread(item)
        } label: {
            HStack(spacing: 6) {
                if isReading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(title)
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .disabled(isReading)
    }

    private func displayPath(for song: Song) -> String {
        let redacted = MetadataBackfillDisplayRedactionPolicy.redact(song.filePath)
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
        items = backfill.statusItems(forSource: source.id)
    }

    private func reread(_ item: MetadataBackfillStatusItem) {
        Task {
            let result = await backfill.rereadTags(songID: item.song.id)
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
                    URL(fileURLWithPath: item.song.filePath).lastPathComponent,
                    item.song.fileFormat.rawValue.uppercased(),
                    source.name,
                    MetadataBackfillDisplayRedactionPolicy.redact(reason)
                )
            }
            reload(force: true)
        }
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

    private func workReasonText(_ reasons: MetadataBackfillWorkReasons) -> String {
        var values: [String] = []
        if reasons.contains(.duration) { values.append(String(localized: "metadata_status_reason_duration")) }
        if reasons.contains(.artwork) { values.append(String(localized: "metadata_status_reason_artwork")) }
        if reasons.contains(.title) { values.append(String(localized: "metadata_status_reason_title")) }
        if reasons.contains(.albumArtist) { values.append(String(localized: "metadata_status_reason_album_artist")) }
        if reasons.contains(.artist) { values.append(String(localized: "metadata_status_reason_artist")) }
        return values.joined(separator: String(localized: "metadata_status_reason_separator"))
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
