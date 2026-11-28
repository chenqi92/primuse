import SwiftUI
import PrimuseKit

struct ListeningHistoryView: View {
    typealias Timeline = ListeningHistoryTimeline<PlayHistoryStore.Entry>

    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    @State private var model: Model
    @State private var calendar = ListeningCalendar.current
    @State private var today = ListeningCalendar.current.startOfDay(for: Date())
    private var store: PlayHistoryStore { .shared }

    init(model: Model = Model()) {
        _model = State(initialValue: model)
    }

    @MainActor @Observable
    final class Model {
        var timeline: Timeline?
        private(set) var visibleDays: [Timeline.Day] = []
        private(set) var visibleLimit = 100
        private(set) var paginationTriggerID: String?
        // crash-pattern: allow song-id-collection-property 仅存历史记录里按原 ID 找不到的条目映射，规模以播放历史不重复缺失曲目为界
        private(set) var resolvedSongIDs: [String: String] = [:]
        fileprivate var loaded: Request?

        func setTimeline(_ timeline: Timeline) {
            self.timeline = timeline
            updatePage()
        }

        func rowAppeared(_ id: String) {
            guard let paginationTriggerID, let timeline,
                  id == paginationTriggerID || id == visibleDays.last?.entries.last?.id else { return }
            visibleLimit = min(timeline.count, visibleLimit + 100)
            updatePage()
        }

        private func updatePage() {
            guard let timeline else { return }
            visibleDays = timeline.visibleDays(limit: visibleLimit)
            paginationTriggerID = timeline.paginationTriggerID(limit: visibleLimit)
        }
    }

    fileprivate struct Request: Equatable {
        let history: PlayHistoryStore.SnapshotRevision
        let clearedAt: Date?
        let calendar: Calendar
    }

    private var request: Request {
        Request(history: store.snapshotRevision, clearedAt: store.clearedAt, calendar: calendar)
    }

    /// 时间线出来以后才认按原 ID 找不到的歌:认的时候要扫一遍曲库歌名,时间线不等它。
    /// 曲库进了歌、删了歌才重认;这页开着时新记下的播放是本机的歌,不为它重认。
    private struct ResolutionRequest: Equatable {
        let hasTimeline: Bool
        let libraryCollection: Int
        let catalogMembership: UInt64
    }

    private var resolutionRequest: ResolutionRequest {
        ResolutionRequest(
            hasTimeline: model.timeline != nil,
            libraryCollection: library?.visibleSongCollectionRevision ?? 0,
            catalogMembership: library?.catalogHost?.revisions.membership ?? 0
        )
    }

    var body: some View {
        Group {
            if let timeline = model.timeline {
                if timeline.count == 0 {
                    ContentUnavailableView("no_recorded_playback", systemImage: "clock.arrow.circlepath")
                } else {
                    historyList
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .pmExtendsUnderVerticalBar()
        .navigationTitle("stats_title")
        .task(id: request) { await refresh(request) }
        .task(id: resolutionRequest) { await resolveMissingSongs(resolutionRequest) }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            today = calendar.startOfDay(for: Date())
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            refreshCalendar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            refreshCalendar()
        }
    }

    private var historyList: some View {
        List {
            ForEach(model.visibleDays) { day in
                Section {
                    ForEach(day.entries) { entry in
                        ListeningHistoryRow(entry: entry, resolvedSongID: model.resolvedSongIDs[entry.songID])
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onAppear { model.rowAppeared(entry.id) }
                    }
                } header: {
                    dayHeader(day)
                        .textCase(nil)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("statistics.history.list")
    }

    private func dayHeader(_ day: Timeline.Day) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayTitle(day.date)).font(.headline)
                Spacer(minLength: 16)
                daySummary(day)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(dayTitle(day.date)).font(.headline)
                daySummary(day)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func daySummary(_ day: Timeline.Day) -> some View {
        HStack(spacing: 12) {
            Text(ListeningRankText.playCount(day.playCount))
            Text(ListeningRankText.duration(day.listenedSeconds))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func dayTitle(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: today) { return String(localized: "podcast_date_today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           calendar.isDate(date, inSameDayAs: yesterday) { return String(localized: "podcast_date_yesterday") }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.component(.year, from: date) == calendar.component(.year, from: today) ? "MMMEd" : "yMMMEd"
        )
        return formatter.string(from: date)
    }

    private func refreshCalendar() {
        calendar = ListeningCalendar.current
        today = calendar.startOfDay(for: Date())
    }

    private func refresh(_ request: Request) async {
        guard model.loaded != request else { return }
        let live = store.entries
        let worker = Task.detached(priority: .userInitiated) {
            let entries = PlayHistoryArchiver.completeHistory(live: live, clearedAt: request.clearedAt)
            return Timeline(entries: entries, calendar: request.calendar,
                            playedAt: { $0.playedAt }, listenedSeconds: { $0.listenedSec })
        }
        let timeline = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, request == self.request else { return }
        model.setTimeline(timeline)
        model.loaded = request
    }

    private func resolveMissingSongs(_ request: ResolutionRequest) async {
        guard let library, request.hasTimeline else { return }
        // 曲库连着变几次(扫描进歌)时只认最后一次。
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        guard let entries = model.timeline?.days.flatMap(\.entries),
              let candidates = await PlayHistoryStore.resolveMissingSongIDs(for: entries, in: library),
              !Task.isCancelled, request == resolutionRequest else { return }
        var resolved: [String: String] = [:]
        for (historyID, ids) in candidates {
            if let match = ids.first(where: { library.unobservedVisibleSong(id: $0)?.isPlayable == true })
                ?? ids.first(where: { library.unobservedVisibleSong(id: $0) != nil }) {
                resolved[historyID] = match
            }
        }
        model.applyResolution(resolved)
    }
}

private extension ListeningHistoryView.Model {
    func applyResolution(_ resolvedSongIDs: [String: String]) {
        guard self.resolvedSongIDs != resolvedSongIDs else { return }
        self.resolvedSongIDs = resolvedSongIDs
    }
}

private struct ListeningHistoryRow: View {
    let entry: PlayHistoryStore.Entry
    var resolvedSongID: String? = nil
    @Environment(MusicLibrary.self) private var library: MusicLibrary?
    @Environment(AudioPlayerService.self) private var player: AudioPlayerService?
    @Environment(SourcesStore.self) private var sourcesStore

    var body: some View {
        let song = resolvedSong
        let canPlay = song?.isPlayable == true && player != nil
        return HStack(spacing: 0) {
            if canPlay {
                Button {
                    guard let song = resolvedSong, song.isPlayable, let player else { return }
                    Task { await player.play(queue: [song], startingAt: 0) }
                } label: {
                    historyRowLabel(entry, song: song)
                }
                .buttonStyle(.plain)
            } else {
                historyRowLabel(entry, song: song)
            }
        }
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                Divider()
            }
            .padding(.leading, 76)
            .padding(.trailing, 20)
        }
    }

    private var resolvedSong: Song? {
        if let song = library?.visibleSong(id: resolvedSongID ?? entry.songID) { return song }
        return PlayHistoryStore.shared.resolvedSong(for: entry, in: library)
    }

    private func historyRowLabel(_ entry: PlayHistoryStore.Entry, song: Song?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ListeningRankArtwork(song: song, size: 44, cornerRadius: 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.songTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !entry.artistName.isEmpty {
                    Text(entry.artistName)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                if !details(entry, song: song).isEmpty {
                    Text(details(entry, song: song))
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(entry.playedAt, style: .time)
                    .font(.subheadline.monospacedDigit())
                Text(String(format: String(localized: "stats_history_listened_format"),
                            ListeningRankText.duration(entry.listenedSec)))
                    .font(.caption)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func details(_ entry: PlayHistoryStore.Entry, song: Song?) -> String {
        [entry.albumTitle, sourcesStore.source(id: song?.sourceID ?? entry.sourceID)?.name ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
