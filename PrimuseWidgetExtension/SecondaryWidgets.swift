import SwiftUI
import WidgetKit
import PrimuseKit

// The four "secondary" home-screen widgets — lyrics, listening stats, music
// sources and year-in-review. Each reads its own App Group snapshot (written by
// the main app) and falls back to demo content for the system gallery preview.
// Styling reuses WidgetDesign so they sit consistently next to the shipping
// Now Playing / Recently Played widgets.

private func reloadPolicy() -> TimelineReloadPolicy {
    if let next = WidgetSettings.nextRefreshDate() {
        return .after(next)
    }
    return .never
}

// MARK: - Lyrics

private extension LyricsSnapshot {
    /// Copy with a recomputed current-line index — lets the widget timeline
    /// advance the highlight without re-reading the App Group.
    func with(anchorIndex newIndex: Int) -> LyricsSnapshot {
        var copy = self
        copy.anchorIndex = newIndex
        return copy
    }
}

struct LyricsEntry: TimelineEntry {
    let date: Date
    let snapshot: LyricsSnapshot?
}

struct LyricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsEntry {
        LyricsEntry(date: Date(), snapshot: Self.demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsEntry) -> Void) {
        let snap = context.isPreview ? Self.demo : LyricsSnapshot.load()
        completion(LyricsEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsEntry>) -> Void) {
        let now = Date()
        let loaded = LyricsSnapshot.load()
        guard let snap = loaded, !snap.lines.isEmpty else {
            completion(Timeline(entries: [LyricsEntry(date: now, snapshot: loaded)], policy: reloadPolicy()))
            return
        }

        // The app only re-writes this snapshot on song change, so `anchorIndex`
        // is frozen at the line that was current when it was saved. To make the
        // highlight track playback, project forward from `updatedAt`: the saved
        // anchor line was current at that instant, so the playback position now
        // is roughly `lines[anchorIndex].time + (date - updatedAt)`. We emit one
        // entry per upcoming line so WidgetKit advances the highlight on cue.
        let entries = Self.timelineEntries(for: snap, from: now)
        completion(Timeline(entries: entries, policy: reloadPolicy()))
    }

    /// Builds entries whose `anchorIndex` advances as playback progresses,
    /// computed purely from the saved line timings + `updatedAt`. Paused
    /// snapshots yield a single static entry.
    static func timelineEntries(for snap: LyricsSnapshot, from now: Date) -> [LyricsEntry] {
        // Playback position (seconds) that the saved anchor corresponds to.
        let anchorIndex = min(max(snap.anchorIndex, 0), snap.lines.count - 1)
        let anchorTime = snap.lines[anchorIndex].time

        guard snap.isPlaying else {
            return [LyricsEntry(date: now, snapshot: snap)]
        }

        // Position at `now`, then the line index that should be current.
        let elapsed = max(0, now.timeIntervalSince(snap.updatedAt))
        let positionNow = anchorTime + elapsed
        let currentIndex = Self.lineIndex(for: positionNow, in: snap.lines)

        var entries: [LyricsEntry] = [LyricsEntry(date: now, snapshot: snap.with(anchorIndex: currentIndex))]

        // One future entry per remaining line transition, capped to keep the
        // timeline small. Each fires when that line is due to become current.
        let maxFutureEntries = 12
        var added = 0
        var i = currentIndex + 1
        while i < snap.lines.count && added < maxFutureEntries {
            let lineStart = snap.lines[i].time
            let secondsUntil = lineStart - positionNow
            if secondsUntil > 0 {
                let date = now.addingTimeInterval(secondsUntil)
                entries.append(LyricsEntry(date: date, snapshot: snap.with(anchorIndex: i)))
                added += 1
            }
            i += 1
        }
        return entries
    }

    /// Index of the last line whose start time is <= position (0 if none yet).
    private static func lineIndex(for position: TimeInterval, in lines: [WidgetLyricLine]) -> Int {
        var idx = 0
        for (i, line) in lines.enumerated() where line.time <= position { idx = i }
        return idx
    }

    static let demo = LyricsSnapshot(
        songID: "demo", title: PMString("ext.widget.demo.songTitle"), artist: PMString("ext.widget.demo.track"), coverImageName: nil,
        lines: [
            WidgetLyricLine(time: 0, text: PMString("ext.widget.demo.lyric1")),
            WidgetLyricLine(time: 3, text: PMString("ext.widget.demo.lyric2")),
            WidgetLyricLine(time: 6, text: PMString("ext.widget.demo.lyric3")),
            WidgetLyricLine(time: 9, text: PMString("ext.widget.demo.lyric4")),
        ],
        anchorIndex: 1, isPlaying: true
    )
}

struct LyricsWidget: Widget {
    let kind = "LyricsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LyricsProvider()) { entry in
            LyricsWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.lyrics.displayName"))
        .description(PMString("ext.widget.lyrics.description"))
        .supportedFamilies([.systemMedium])
    }
}

struct LyricsWidgetView: View {
    let entry: LyricsEntry

    var body: some View {
        if let snap = entry.snapshot, !snap.lines.isEmpty {
            content(snap)
        } else {
            WidgetCanvas(padding: 18) {
                HStack(spacing: 14) {
                    WidgetEmptyStateIcon(systemName: "quote.bubble", size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PMString("ext.widget.lyrics.empty.title"))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(WidgetDesign.strongText)
                        Text(PMString("ext.widget.lyrics.empty.subtitle"))
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    private func content(_ snap: LyricsSnapshot) -> some View {
        let tint = WidgetDesign.brandTint
        let idx = min(max(snap.anchorIndex, 0), snap.lines.count - 1)
        let window = (max(0, idx - 1)..<min(snap.lines.count, idx + 2))
        return WidgetCanvas(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    WidgetCoverImageView(coverImageName: snap.coverImageName, cornerRadius: 5, placeholderIndex: 0)
                        .frame(width: 24, height: 24)
                    Text(snap.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(1)
                    Text("· \(snap.artist)")
                        .font(.system(size: 10))
                        .foregroundStyle(WidgetDesign.tertiaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 10)

                ForEach(Array(window), id: \.self) { i in
                    let isCurrent = i == idx
                    Text(snap.lines[i].text)
                        .font(.system(size: isCurrent ? 18 : 13, weight: isCurrent ? .bold : .medium))
                        .foregroundStyle(isCurrent ? tint : WidgetDesign.tertiaryText)
                        .lineLimit(1)
                        .padding(.bottom, 5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Listening stats

struct StatsEntry: TimelineEntry {
    let date: Date
    let snapshot: ListeningStatsSnapshot?
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), snapshot: Self.demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        let snap = context.isPreview ? Self.demo : ListeningStatsSnapshot.load()
        completion(StatsEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        let entry = StatsEntry(date: Date(), snapshot: ListeningStatsSnapshot.load())
        completion(Timeline(entries: [entry], policy: reloadPolicy()))
    }

    static let demo = ListeningStatsSnapshot(
        totalPlays: 246, totalSeconds: 17 * 3600,
        dailyCounts: [1, 0, 4, 2, 8, 12, 5, 0, 3, 6, 9, 1, 0, 4, 7, 5, 10, 12, 3, 6, 4, 0, 8, 11, 2, 5, 9, 1, 4, 6],
        topSongTitle: PMString("ext.widget.demo.topSong"),
        topSongArtist: PMString("ext.widget.demo.topArtist")
    )
}

struct ListeningStatsWidget: Widget {
    let kind = "ListeningStatsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatsProvider()) { entry in
            StatsWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.stats.displayName"))
        .description(PMString("ext.widget.stats.description"))
        .supportedFamilies([.systemMedium])
    }
}

struct StatsWidgetView: View {
    let entry: StatsEntry

    var body: some View {
        let snap = entry.snapshot ?? ListeningStatsSnapshot(totalPlays: 0, totalSeconds: 0,
                                                            dailyCounts: [], topSongTitle: nil, topSongArtist: nil)
        let tint = WidgetDesign.brandTint
        let counts = Array(snap.dailyCounts.suffix(30))
        return WidgetCanvas(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    WidgetSectionEyebrow(text: PMString("ext.widget.stats.eyebrow"))
                    Spacer()
                    Text(PMString("ext.widget.stats.last30Days"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(WidgetDesign.tertiaryText)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(snap.totalPlays)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(tint)
                        Text(PMString("ext.widget.stats.plays"))
                            .font(.system(size: 10))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                        Text("\(snap.totalHours)h")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(WidgetDesign.strongText)
                            .padding(.top, 8)
                        Text(PMString("ext.widget.stats.totalTime"))
                            .font(.system(size: 10))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(9), spacing: 3), count: 15), spacing: 3) {
                            ForEach(Array(counts.enumerated()), id: \.offset) { _, value in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(value == 0 ? Color.primary.opacity(0.10)
                                          : tint.opacity(0.30 + min(Double(value), 12) * 0.05))
                                    .frame(width: 9, height: 9)
                            }
                        }
                        if let title = snap.topSongTitle {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(PMString("ext.widget.stats.topThisMonth"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(WidgetDesign.secondaryText)
                                Text("\(title)\(snap.topSongArtist.map { " · \($0)" } ?? "")")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(WidgetDesign.tertiaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Music sources

struct SourcesEntry: TimelineEntry {
    let date: Date
    let snapshot: SourcesSnapshot?
}

struct SourcesProvider: TimelineProvider {
    func placeholder(in context: Context) -> SourcesEntry {
        SourcesEntry(date: Date(), snapshot: Self.demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (SourcesEntry) -> Void) {
        let snap = context.isPreview ? Self.demo : SourcesSnapshot.load()
        completion(SourcesEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SourcesEntry>) -> Void) {
        let entry = SourcesEntry(date: Date(), snapshot: SourcesSnapshot.load())
        completion(Timeline(entries: [entry], policy: reloadPolicy()))
    }

    static let demo = SourcesSnapshot(
        totalIndexed: 10737,
        sources: [
            WidgetSourceEntry(id: "1", name: PMString("src.displayName.baiduPan"), iconName: "externaldrive.connected.to.line.below", songCount: 4200, status: .online),
            WidgetSourceEntry(id: "2", name: "Apple Music", iconName: "music.note", songCount: 1800, status: .online),
            WidgetSourceEntry(id: "3", name: "cqNas", iconName: "server.rack", songCount: 3100, status: .scanning),
            WidgetSourceEntry(id: "4", name: "Synology", iconName: "externaldrive", songCount: 1637, status: .online),
        ]
    )
}

struct MusicSourcesWidget: Widget {
    let kind = "MusicSourcesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SourcesProvider()) { entry in
            SourcesWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.sources.displayName"))
        .description(PMString("ext.widget.sources.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SourcesWidgetView: View {
    let entry: SourcesEntry
    @Environment(\.widgetFamily) private var family

    private func statusColor(_ status: WidgetSourceStatus) -> Color {
        switch status {
        case .online:    return WidgetDesign.fern
        case .scanning:  return WidgetDesign.amber
        case .attention: return WidgetDesign.rose
        case .disabled:  return WidgetDesign.tertiaryText
        }
    }

    var body: some View {
        let snap = entry.snapshot ?? SourcesSnapshot(totalIndexed: 0, sources: [])
        let shown = Array(snap.sources.prefix(family == .systemSmall ? 4 : 6))
        return WidgetCanvas(padding: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    WidgetSectionEyebrow(text: PMString("ext.widget.sources.eyebrow"))
                    Spacer()
                    Text("\(snap.sourceCount)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(WidgetDesign.tertiaryText)
                }
                Text("\(snap.totalIndexed)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(WidgetDesign.fern)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.top, 8)
                Text(PMString("ext.widget.sources.indexed"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(WidgetDesign.tertiaryText)
                    .padding(.bottom, 8)

                ForEach(shown) { source in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(source.status))
                            .frame(width: 6, height: 6)
                        Text(source.name)
                            .font(.system(size: 10))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)
                        if family == .systemMedium {
                            Spacer(minLength: 4)
                            Text("\(source.songCount)")
                                .font(.system(size: 9.5, design: .rounded))
                                .foregroundStyle(WidgetDesign.tertiaryText)
                        }
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Year in review (Wrapped)

struct WrappedEntry: TimelineEntry {
    let date: Date
    let snapshot: WrappedSnapshot?
}

struct WrappedProvider: TimelineProvider {
    func placeholder(in context: Context) -> WrappedEntry {
        WrappedEntry(date: Date(), snapshot: Self.demo)
    }

    func getSnapshot(in context: Context, completion: @escaping (WrappedEntry) -> Void) {
        let snap = context.isPreview ? Self.demo : WrappedSnapshot.load()
        completion(WrappedEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WrappedEntry>) -> Void) {
        let entry = WrappedEntry(date: Date(), snapshot: WrappedSnapshot.load())
        completion(Timeline(entries: [entry], policy: reloadPolicy()))
    }

    static let demo = WrappedSnapshot(
        year: 2026,
        totalHours: 847,
        topArtist: PMString("ext.widget.demo.topArtist"),
        topSong: PMString("ext.widget.demo.topSong")
    )
}

struct YearInReviewWidget: Widget {
    let kind = "YearInReviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WrappedProvider()) { entry in
            WrappedWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.wrapped.displayName"))
        .description(PMString("ext.widget.wrapped.description"))
        .supportedFamilies([.systemMedium])
    }
}

struct WrappedWidgetView: View {
    let entry: WrappedEntry

    var body: some View {
        let tint = WidgetDesign.brandTint
        ZStack {
            LinearGradient(
                colors: [tint, Color(red: 0.16, green: 0.11, blue: 0.22), Color.black],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.white.opacity(0.22), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 220
            )
            if let snap = entry.snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    Text("PRIMUSE WRAPPED")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(PMString("ext.widget.wrapped.headline", verbatimYear(snap.year), snap.totalHours))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 6)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text(snap.topArtist.map { PMString("ext.widget.wrapped.topArtist", $0) } ?? PMString("ext.widget.wrapped.viewReport"))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.88))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("PRIMUSE WRAPPED")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(PMString("ext.widget.wrapped.empty.title"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text(PMString("ext.widget.wrapped.empty.subtitle"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 4)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    /// Year without a grouping separator (2026, not 2,026).
    private func verbatimYear(_ year: Int) -> String { String(year) }
}
