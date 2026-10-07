import SwiftUI
import WidgetKit
import PrimuseKit

struct ListeningDeskEntry: TimelineEntry {
    let date: Date
    let state: PlaybackState?
    let albums: [RecentAlbumEntry]
    let podcast: ListeningWidgetSnapshot.Item?
    let radio: ListeningWidgetSnapshot.Item?
}

struct ListeningDeskProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListeningDeskEntry { Self.preview }

    func getSnapshot(in context: Context, completion: @escaping (ListeningDeskEntry) -> Void) {
        completion(context.isPreview ? Self.preview : current)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningDeskEntry>) -> Void) {
        let entry = current
        let next = WidgetSettings.nextRefreshDate(from: entry.date)
        completion(Timeline(entries: [entry], policy: next.map(TimelineReloadPolicy.after) ?? .never))
    }

    private var current: ListeningDeskEntry {
        guard WidgetSettings.syncEnabled() else {
            return .init(date: Date(), state: nil, albums: [], podcast: nil, radio: nil)
        }
        let scope = WidgetSettings.sharedDataScope()
        var state = WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) ? PlaybackState.load() : nil
        if !scope.includesCover { state?.coverImageName = nil }
        if !scope.includesProgress { state?.duration = 0; state?.currentTime = 0 }
        let albums = WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey) ? RecentAlbumsStore.load() : []
        return .init(date: Date(), state: state,
                     albums: albums.map { .init(id: $0.id, title: $0.title, artistName: $0.artistName,
                                               coverImageName: scope.includesCover ? $0.coverImageName : nil) },
                     podcast: ListeningWidgetKind.podcast.load()?.items.first,
                     radio: ListeningWidgetKind.radio.load()?.items.first)
    }

    static var preview: ListeningDeskEntry {
        .init(date: Date(), state: PlaybackState(currentSongID: "preview", songTitle: "Beautiful Boy",
                                               artistName: "John Lennon", albumTitle: "Double Fantasy", fileFormat: "FLAC",
                                               coverArtData: nil, coverImageName: nil, isPlaying: true,
                                               currentTime: 88, duration: 248, queueSongIDs: []),
              albums: [.init(id: "1", title: "Kind of Blue", artistName: "Miles Davis", coverImageName: nil),
                       .init(id: "2", title: "Rumours", artistName: "Fleetwood Mac", coverImageName: nil)],
              podcast: .init(id: "preview-podcast", title: "The Art of Listening", subtitle: "Primuse Podcasts"),
              radio: .init(id: "preview-radio", title: "Jazz Radio", subtitle: "Live Radio"))
    }
}

struct ListeningDeskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ListeningDeskWidget", provider: ListeningDeskProvider()) { entry in
            ListeningDeskView(entry: entry)
        }
        .configurationDisplayName(PMString("ext.widget.desk.title"))
        .description(PMString("ext.widget.desk.description"))
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct ListeningDeskView: View {
    let entry: ListeningDeskEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var large: Bool { family == .systemLarge }

    var body: some View {
        WidgetCanvas(padding: 16) {
            VStack(alignment: .leading, spacing: large ? 14 : 10) {
                if large {
                    HStack {
                        Text(PMString("ext.widget.desk.title"))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Spacer()
                        Image(systemName: "hifispeaker.2").foregroundStyle(WidgetDesign.brandTint).widgetAccentable()
                    }
                }
                hero.frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    destination(entry.podcast, kind: .podcast)
                    destination(entry.radio, kind: .radio)
                }
                if large, !entry.albums.isEmpty { recentAlbums }
            }
        }
        .widgetURL(URL(string: "primuse://"))
    }

    private var hero: some View {
        HStack(spacing: large ? 18 : 12) {
            Group {
                if let state = entry.state, state.currentSongID != nil {
                    WidgetPlaybackArtwork(state: state)
                } else {
                    WidgetRecordSleeve(coverImageName: nil)
                }
            }
            .frame(width: large ? 118 : 74, height: large ? 118 : 74)
            VStack(alignment: .leading, spacing: large ? 7 : 4) {
                if let state = entry.state, state.currentSongID != nil {
                    Text(PMString(state.isPlaying ? "ext.widget.nowPlaying.playing" : "ext.widget.nowPlaying.paused"))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                        .font(.system(size: large ? 20 : 16, weight: .bold))
                        .lineLimit(2).minimumScaleFactor(0.88)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state.currentSongID)
                    Text(state.spokenWord?.bookTitle ?? state.artistName ?? PMString("ext.widget.unknownArtist"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if large {
                        HStack(spacing: 12) {
                            WidgetPlaybackButton(state: state, size: 36)
                            if !state.isLiveStream {
                                Button(intent: PrimuseNextIntent()) {
                                    Image(systemName: "forward.fill").font(.system(size: 14)).frame(width: 32, height: 36)
                                }.buttonStyle(.plain).accessibilityLabel(PMString("ext.control.next"))
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } else {
                    Text(PMString("ext.widget.nowPlaying.empty.title"))
                        .font(.system(size: large ? 20 : 16, weight: .bold)).lineLimit(2)
                    Text(PMString("ext.widget.nowPlaying.empty.openShort"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !large, let state = entry.state, state.currentSongID != nil {
                WidgetPlaybackButton(state: state)
            }
        }
        .overlay(alignment: .bottom) {
            if large, let state = entry.state, state.duration > 0 {
                ProgressLine(progress: .init(state: state, elapsed: state.currentTime, referenceDate: state.updatedAt ?? entry.date))
                    .offset(y: 7)
            }
        }
    }

    @ViewBuilder private func destination(_ item: ListeningWidgetSnapshot.Item?, kind: ListeningWidgetKind) -> some View {
        if let item, WidgetSettings.clickableInteractionEnabled() {
            Button(intent: PrimusePlayListeningWidgetIntent(itemID: item.id, kind: kind.rawValue)) {
                destinationLabel(item, kind: kind)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PMString("ext.control.play") + ", " + item.title)
        } else {
            destinationLabel(item, kind: kind)
        }
    }

    private func destinationLabel(_ item: ListeningWidgetSnapshot.Item?, kind: ListeningWidgetKind) -> some View {
        let tint = kind == .podcast ? Color.purple : WidgetDesign.brandTint
        return HStack(spacing: 8) {
            if large, let item {
                WidgetCoverImageView(coverImageName: item.coverImageName, cornerRadius: 6)
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: kind == .podcast ? "mic" : "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(tint).widgetAccentable()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(PMString("ext.widget.\(kind.rawValue).title"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if large {
                    Text(item?.title ?? PMString("ext.widget.nowPlaying.empty.openShort"))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if item != nil, !large {
                Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(tint).widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: large ? 62 : 22)
        .padding(10)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var recentAlbums: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(PMString("ext.widget.recent.eyebrow"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(entry.albums.first?.title ?? "")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            ForEach(Array(entry.albums.prefix(3).enumerated()), id: \.element.id) { index, album in
                RecentAlbumCoverView(entry: album, cornerRadius: 5)
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(Double(index - 1) * 5))
            }
        }
        .padding(.top, 3)
    }
}
