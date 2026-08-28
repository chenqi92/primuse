import PrimuseKit
import SwiftUI

private enum MetadataStatusFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case retry
    case unreadable

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "metadata_status_filter_all"
        case .pending: "metadata_status_filter_pending"
        case .retry: "metadata_status_filter_retry"
        case .unreadable: "metadata_status_filter_unreadable"
        }
    }

    func includes(_ state: MetadataBackfillItemState) -> Bool {
        switch self {
        case .all:
            true
        case .pending:
            state == .pendingInspection || state == .waitingForWiFi
        case .retry:
            state == .retryPending || state == .sourceUnavailable
                || state == .fileUnavailable || state == .stalled
        case .unreadable:
            state == .unreadableTags || state == .playableIncomplete
        }
    }
}

struct SourceMetadataStatusView: View {
    @Environment(MetadataBackfillService.self) private var backfill

    let source: MusicSource

    @State private var items: [MetadataBackfillStatusItem] = []
    @State private var selectedFilter: MetadataStatusFilter = .all
    @State private var searchText = ""
    @State private var resultMessage: String?

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

    var body: some View {
        List {
            Section {
                sourceIdentityHeader
                summaryGrid
                Text("metadata_status_explanation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("metadata_status_actions") {
                if backfill.isUserInitiated(forSource: source.id) {
                    Button {
                        backfill.pauseUserInitiated(sourceID: source.id)
                        resultMessage = String(localized: "metadata_status_paused_message")
                        reload(force: true)
                    } label: {
                        Label("metadata_status_pause", systemImage: "pause.circle")
                    }
                } else {
                    Button {
                        let started = backfill.startUserInitiated(sourceID: source.id)
                        resultMessage = String(localized: started
                            ? "metadata_status_continue_started"
                            : "metadata_status_no_pending_work")
                        reload(force: true)
                    } label: {
                        Label("metadata_status_continue", systemImage: "play.circle")
                    }
                    .disabled(!source.isEnabled || summary.activeQueueCount == 0)
                }

                if summary.retryableCount > 0 {
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
                    }
                    .disabled(!source.isEnabled)
                }

                Button {
                    reload(force: true)
                } label: {
                    Label("metadata_status_refresh", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            Section {
                Picker("metadata_status_filter", selection: $selectedFilter) {
                    ForEach(MetadataStatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)

                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "metadata_status_empty",
                        systemImage: "checkmark.circle",
                        description: Text("metadata_status_empty_description")
                    )
                } else {
                    ForEach(filteredItems) { item in
                        statusRow(item)
                    }
                }
            } header: {
                Text(String(
                    format: String(localized: "metadata_status_list_count_format"),
                    filteredItems.count
                ))
            }
        }
        .navigationTitle("metadata_status_title")
        .searchable(text: $searchText, prompt: "metadata_status_search")
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
    }

    private var sourceIdentityHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: source.type.iconName)
                    .foregroundStyle(Color.accentColor)
                Text(source.name)
                    .font(.headline)
                Spacer()
                Text(source.type.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(sourceIdentityText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var sourceIdentityText: String {
        let location = source.connectionSummary
            ?? source.basePath
            ?? source.host
            ?? String(localized: "metadata_status_location_unknown")
        return "\(location) · \(String(source.id.prefix(8)))"
    }

    private var summaryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            summaryTile("metadata_status_pending", count: summary.activeQueueCount, color: .blue)
            summaryTile("metadata_status_retry", count: summary.retryPendingCount, color: .orange)
            summaryTile("metadata_status_source_problem", count: summary.sourceUnavailableCount + summary.fileUnavailableCount, color: .red)
            summaryTile("metadata_status_unreadable", count: summary.unreadableTagsCount, color: .red)
            summaryTile("metadata_status_incomplete", count: summary.playableIncompleteCount, color: .secondary)
            if summary.stalledCount > 0 {
                summaryTile("metadata_status_stalled", count: summary.stalledCount, color: .purple)
            }
        }
    }

    private func summaryTile(
        _ title: LocalizedStringKey,
        count: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count.formatted())
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(_ item: MetadataBackfillStatusItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: stateIcon(item.state))
                    .foregroundStyle(stateColor(item.state))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.song.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                    if let artist = item.song.artistName, !artist.isEmpty {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(stateTitle(item.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stateColor(item.state))
                    .multilineTextAlignment(.trailing)
            }

            Text(item.song.filePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 7) {
                Text(item.song.fileFormat.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                let reasons = workReasonText(item.workReasons)
                if !reasons.isEmpty {
                    Text(reasons)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if item.attemptCount > 0 {
                    Text(String(
                        format: String(localized: "metadata_status_attempt_format"),
                        item.attemptCount
                    ))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }

            if let diagnostic = item.diagnostic {
                Text(diagnostic.reason)
                    .font(.caption)
                    .foregroundStyle(item.state.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(diagnostic.lastAttemptAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let fallback = fallbackReason(item.state) {
                Text(fallback)
                    .font(.caption)
                    .foregroundStyle(item.state.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if backfill.canRereadTags(for: item.song) {
                let rereadTitle = backfill.isRereadingTags(songID: item.song.id)
                    ? String(localized: "reread_song_tags_in_progress")
                    : String(localized: "reread_song_tags")
                Button {
                    reread(item)
                } label: {
                    Label(rereadTitle, systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(backfill.isRereadingTags(songID: item.song.id))
            }
        }
        .padding(.vertical, 3)
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
                    reason
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
            String(localized: "song_details_incomplete_message")
        case .stalled:
            String(localized: "metadata_status_stalled_reason")
        }
    }
}
