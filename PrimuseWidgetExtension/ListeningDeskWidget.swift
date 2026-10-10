import SwiftUI
import WidgetKit
import AppIntents
import PrimuseKit

/// One of the desk's two tiles: what it shows and what a tap plays.
struct ListeningDeskTile {
    enum Action {
        case listening(id: String, kind: ListeningWidgetKind)
        case book(id: String)
        case album(key: String)
    }

    let content: PrimuseListeningDeskTileContent
    var title: String?
    var coverImageName: String?
    var action: Action?
    /// 电台格放的正是在播的那个台: 跟电台小组件一样标出来, 点了是停。
    var isPlaying = false
}

struct ListeningDeskEntry: TimelineEntry {
    let date: Date
    let state: PlaybackState?
    let albums: [RecentAlbumEntry]
    let leading: ListeningDeskTile
    let trailing: ListeningDeskTile
    /// 电台的上一首 / 下一首是切台, 跟 App 一样只有一个台时不出这两个键。
    var canSwitchStation = false
}

struct ListeningDeskProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ListeningDeskEntry {
        Self.preview(for: PrimuseListeningDeskConfigurationIntent())
    }

    func snapshot(for configuration: PrimuseListeningDeskConfigurationIntent, in context: Context) async -> ListeningDeskEntry {
        context.isPreview ? Self.preview(for: configuration) : Self.current(for: configuration)
    }

    func timeline(for configuration: PrimuseListeningDeskConfigurationIntent, in context: Context) async -> Timeline<ListeningDeskEntry> {
        let entry = Self.current(for: configuration)
        let next = WidgetSettings.nextRefreshDate(from: entry.date)
        return Timeline(entries: [entry], policy: next.map(TimelineReloadPolicy.after) ?? .never)
    }

    private static func current(for configuration: PrimuseListeningDeskConfigurationIntent) -> ListeningDeskEntry {
        let leading = configuration.leading
        let trailing = configuration.trailing
        guard WidgetSettings.syncEnabled() else {
            return .init(date: Date(), state: nil, albums: [],
                         leading: .init(content: leading), trailing: .init(content: trailing))
        }
        let scope = WidgetSettings.sharedDataScope()
        var state = WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) ? PlaybackState.load() : nil
        if !scope.includesCover { state?.coverImageName = nil }
        if !scope.includesProgress { state?.duration = 0; state?.currentTime = 0 }
        let albums = (WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey) ? RecentAlbumsStore.load() : [])
            .map { scope.includesCover ? $0 : $0.withoutCover() }
        return .init(date: Date(), state: state, albums: albums,
                     leading: tile(leading, index: 0, albums: albums, scope: scope, state: state),
                     trailing: tile(trailing, index: leading == trailing ? 1 : 0, albums: albums, scope: scope, state: state),
                     canSwitchStation: (ListeningWidgetKind.radio.load()?.items.count ?? 0) > 1)
    }

    /// The `index`-th item of a kind. Both tiles set to the same kind show its
    /// first two items rather than the same one twice.
    private static func tile(_ content: PrimuseListeningDeskTileContent, index: Int,
                             albums: [RecentAlbumEntry], scope: WidgetSharedDataScope,
                             state: PlaybackState?) -> ListeningDeskTile {
        switch content {
        case .podcast, .radio:
            let kind: ListeningWidgetKind = content == .podcast ? .podcast : .radio
            guard let items = kind.load()?.items, items.indices.contains(index) else { return .init(content: content) }
            let item = items[index]
            return .init(content: content, title: item.title, coverImageName: item.coverImageName,
                         action: .listening(id: item.id, kind: kind),
                         isPlaying: kind == .radio && state?.playingRadioStationID == item.id)
        case .music:
            // Books and podcast shows are recorded as albums too; this tile is music.
            let music = albums.filter { $0.listeningSpace == .music }
            guard music.indices.contains(index) else { return .init(content: content) }
            let album = music[index]
            return .init(content: content, title: album.title, coverImageName: album.coverImageName,
                         action: .album(key: album.id))
        case .audiobook:
            guard let books = SpokenWordShelfSnapshot.load()?.books, books.indices.contains(index) else {
                return .init(content: content)
            }
            let book = books[index]
            return .init(content: content, title: book.title,
                         coverImageName: scope.includesCover ? book.coverImageName : nil,
                         action: .book(id: book.id))
        }
    }

    private static func preview(for configuration: PrimuseListeningDeskConfigurationIntent) -> ListeningDeskEntry {
        let leading = configuration.leading
        let trailing = configuration.trailing
        return .init(date: Date(), state: PlaybackState(currentSongID: "preview", songTitle: "Beautiful Boy",
                                                        artistName: "John Lennon", albumTitle: "Double Fantasy", fileFormat: "FLAC",
                                                        coverArtData: nil, coverImageName: nil, isPlaying: true,
                                                        currentTime: 88, duration: 248, queueSongIDs: []),
                     albums: [.init(id: "1", title: "Kind of Blue", artistName: "Miles Davis", coverImageName: nil),
                              .init(id: "2", title: "Rumours", artistName: "Fleetwood Mac", coverImageName: nil)],
                     leading: previewTile(leading, index: 0),
                     trailing: previewTile(trailing, index: leading == trailing ? 1 : 0),
                     canSwitchStation: true)
    }

    private static func previewTile(_ content: PrimuseListeningDeskTileContent, index: Int) -> ListeningDeskTile {
        let titles: [String]
        switch content {
        case .podcast: titles = ["The Art of Listening", "A Little Curiosity"]
        case .radio: titles = ["Jazz Radio", "Classical"]
        case .music: titles = ["Kind of Blue", "Rumours"]
        case .audiobook: titles = ["Pride and Prejudice", "The Odyssey"]
        }
        return .init(content: content, title: titles[min(index, titles.count - 1)])
    }
}

struct ListeningDeskWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ListeningDeskWidget", intent: PrimuseListeningDeskConfigurationIntent.self,
                               provider: ListeningDeskProvider()) { entry in
            ListeningDeskView(entry: entry)
        }
        .configurationDisplayName(PMString("ext.widget.desk.title"))
        .description(PMString("ext.widget.desk.description"))
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

extension PrimuseListeningDeskTileContent {
    var symbol: String {
        switch self {
        case .podcast: "mic"
        case .radio: "dot.radiowaves.left.and.right"
        case .music: "music.note"
        case .audiobook: "book"
        }
    }

    var label: String {
        switch self {
        case .podcast: PMString("ext.widget.podcast.title")
        case .radio: PMString("ext.widget.radio.title")
        case .music: PMString("ext.widget.desk.music")
        case .audiobook: PMString("ext.widget.desk.audiobook")
        }
    }

    /// The app's hue for each way of listening (`ListeningSpace.tint`): music
    /// follows the brand accent; radio matches the radio widget.
    func tint(dark: Bool) -> Color {
        switch self {
        case .podcast: .purple
        case .radio: dark ? Color(red: 1, green: 0.65, blue: 0.36) : Color(red: 0.74, green: 0.34, blue: 0.16)
        case .music: WidgetDesign.brandTint
        case .audiobook: dark ? Color(red: 0.25, green: 0.82, blue: 0.65) : Color(red: 0.06, green: 0.54, blue: 0.42)
        }
    }
}

struct ListeningDeskView: View {
    let entry: ListeningDeskEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
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
                    destination(entry.leading)
                    destination(entry.trailing)
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
                    if large { transport(state) }
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

    /// 上一首、播放 / 暂停、下一首。有声书和播客换成按设置秒数的后退 / 前进, 电台是切台。
    private func transport(_ state: PlaybackState) -> some View {
        HStack(spacing: 12) {
            if let info = state.spokenWord, state.isSpokenWord {
                transportButton(PrimuseSkipBackwardIntent(), symbol: info.skipBackwardSymbol,
                                label: PMString("ext.widget.spokenWord.skipBackFormat", info.skipBackwardSeconds))
                WidgetPlaybackButton(state: state, size: 36)
                transportButton(PrimuseSkipForwardIntent(), symbol: info.skipForwardSymbol,
                                label: PMString("ext.widget.spokenWord.skipForwardFormat", info.skipForwardSeconds))
            } else if state.isLiveStream {
                if entry.canSwitchStation {
                    transportButton(PrimusePreviousIntent(), symbol: "backward.fill",
                                    label: PMString("widget_desk_previous_station"))
                }
                WidgetPlaybackButton(state: state, size: 36)
                if entry.canSwitchStation {
                    transportButton(PrimuseNextIntent(), symbol: "forward.fill",
                                    label: PMString("widget_desk_next_station"))
                }
            } else {
                transportButton(PrimusePreviousIntent(), symbol: "backward.fill", label: PMString("ext.control.previous"))
                WidgetPlaybackButton(state: state, size: 36)
                transportButton(PrimuseNextIntent(), symbol: "forward.fill", label: PMString("ext.control.next"))
            }
            Spacer(minLength: 0)
        }
    }

    private func transportButton<Intent: AppIntent>(_ intent: Intent, symbol: String, label: String) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 32, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func destination(_ tile: ListeningDeskTile) -> some View {
        if let action = tile.action, WidgetSettings.clickableInteractionEnabled() {
            Group {
                switch action {
                case .listening(let id, let kind):
                    Button(intent: PrimusePlayListeningWidgetIntent(itemID: id, kind: kind.rawValue)) { destinationLabel(tile) }
                case .book(let id):
                    Button(intent: PrimuseResumeSpokenWordBookIntent(bookID: id)) { destinationLabel(tile) }
                case .album(let key):
                    Button(intent: PrimusePlayRecentAlbumIntent(albumKey: key)) { destinationLabel(tile) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PMString(tile.isPlaying ? "widget_desk_stop" : "ext.control.play")
                                + ", " + (tile.title ?? tile.content.label))
        } else {
            destinationLabel(tile)
        }
    }

    private func destinationLabel(_ tile: ListeningDeskTile) -> some View {
        let tint = tile.content.tint(dark: colorScheme == .dark)
        return HStack(spacing: 8) {
            if large, tile.title != nil {
                tileArtwork(tile)
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: tile.content.symbol)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(tint).widgetAccentable()
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if tile.isPlaying {
                        Circle().fill(Color.red).frame(width: 5, height: 5).widgetAccentable()
                    }
                    Text(tile.content.label)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                if large {
                    Text(tile.title ?? PMString("ext.widget.nowPlaying.empty.openShort"))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if tile.title != nil, !large {
                Image(systemName: tile.isPlaying ? "stop.fill" : "play.fill").font(.system(size: 9))
                    .foregroundStyle(tile.isPlaying ? Color.red : tint).widgetAccentable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: large ? 62 : 22)
        .padding(10)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Books keep their portrait shape; everything else is square.
    @ViewBuilder private func tileArtwork(_ tile: ListeningDeskTile) -> some View {
        if tile.content == .audiobook {
            WidgetBookCover(coverImageName: tile.coverImageName,
                            width: SpokenWordCoverLayout.width(forHeight: 34), cornerRadius: 5)
        } else {
            WidgetCoverImageView(coverImageName: tile.coverImageName, cornerRadius: 6)
        }
    }

    private var recentAlbums: some View {
        HStack(spacing: 10) {
            // 左边写的是第一张的名字,点它也播第一张。
            playAlbum(entry.albums.first) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(PMString("ext.widget.recent.eyebrow"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(entry.albums.first?.title ?? "")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            ForEach(Array(entry.albums.prefix(3).enumerated()), id: \.element.id) { index, album in
                playAlbum(album) {
                    RecentAlbumCoverView(entry: album, cornerRadius: 5)
                }
                .frame(width: 38, height: 38)
                .rotationEffect(.degrees(Double(index - 1) * 5))
            }
        }
        .padding(.top, 3)
    }

    /// 一张最近播放的专辑点了就播它;关掉小组件交互时保持原样, 点了只打开 App。
    @ViewBuilder private func playAlbum<Content: View>(_ album: RecentAlbumEntry?,
                                                      @ViewBuilder content: () -> Content) -> some View {
        if let album, WidgetSettings.clickableInteractionEnabled() {
            Button(intent: PrimusePlayRecentAlbumIntent(albumKey: album.id)) { content() }
                .buttonStyle(.plain)
                .accessibilityLabel(PMString("ext.control.play") + ", " + album.title)
        } else {
            content()
        }
    }
}
