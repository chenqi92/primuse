import SwiftUI
import WidgetKit
import PrimuseKit

struct ListeningWidgetEntry: TimelineEntry {
    let date: Date
    let kind: ListeningWidgetKind
    let snapshot: ListeningWidgetSnapshot
    /// 正在播的那个台 / 那一集, 跟 App 里一样标出来: 台的键换成停止, 单集换成暂停。
    var playingItemID: String? = nil
}

struct ListeningWidgetProvider: TimelineProvider {
    let kind: ListeningWidgetKind

    func placeholder(in context: Context) -> ListeningWidgetEntry { preview }
    func getSnapshot(in context: Context, completion: @escaping (ListeningWidgetEntry) -> Void) {
        completion(context.isPreview ? preview : current)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningWidgetEntry>) -> Void) {
        let next = WidgetSettings.nextRefreshDate().map { TimelineReloadPolicy.after($0) } ?? .never
        completion(Timeline(entries: [current], policy: next))
    }
    private var current: ListeningWidgetEntry {
        .init(date: Date(), kind: kind, snapshot: kind.load() ?? .init(items: []),
              playingItemID: Self.playingItemID(kind))
    }

    /// 起播、暂停、切台、换集时播放器把正在播的是什么连同播放状态写进 App Group 并刷新全部小组件,
    /// 这里照着读。关掉「正在播放」的数据同步时播放状态不外传, 也就不标。
    private static func playingItemID(_ kind: ListeningWidgetKind) -> String? {
        guard WidgetSettings.syncEnabled(),
              WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) else { return nil }
        return kind.playingItemID(in: PlaybackState.load())
    }
    private var preview: ListeningWidgetEntry {
        let titles = kind.playsEpisodes ? ["The Art of Listening", "A Little Curiosity", "Slow Mornings"] : ["Jazz Radio", "Classical", "Late Night"]
        // 最近播放里也有听完的单集,进度条是满的。
        let fractions: [Double?] = switch kind {
        case .podcast: [0.38, nil, nil]
        case .recentPodcast: [0.38, 1, nil]
        case .radio: [nil, nil, nil]
        }
        return .init(date: Date(), kind: kind, snapshot: .init(items: titles.enumerated().map {
            .init(id: "preview-\($0.offset)", title: $0.element,
                  subtitle: kind.playsEpisodes ? "Primuse Podcasts" : "Live Radio",
                  fractionComplete: fractions[$0.offset])
        }))
    }
}

struct PodcastWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ListeningWidgetKind.podcast.widgetKind, provider: ListeningWidgetProvider(kind: .podcast)) {
            ListeningWidgetView(entry: $0)
        }
        .configurationDisplayName(PMString("ext.widget.podcast.title"))
        .description(PMString("ext.widget.podcast.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// 最近听过的播客单集(听完的也在),按最后一次听的时间排。
struct RecentPodcastWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ListeningWidgetKind.recentPodcast.widgetKind,
                            provider: ListeningWidgetProvider(kind: .recentPodcast)) {
            ListeningWidgetView(entry: $0)
        }
        .configurationDisplayName(PMString("ext.widget.recentPodcast.title"))
        .description(PMString("ext.widget.recentPodcast.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct RadioWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ListeningWidgetKind.radio.widgetKind, provider: ListeningWidgetProvider(kind: .radio)) {
            ListeningWidgetView(entry: $0)
        }
        .configurationDisplayName(PMString("ext.widget.radio.title"))
        .description(PMString("ext.widget.radio.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct ListeningWidgetView: View {
    let entry: ListeningWidgetEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var title: String { PMString("ext.widget.\(entry.kind.rawValue).title") }
    /// 和 App 首页顶部切换里电台、播客那一类用同一个图标、同一个颜色。
    private var symbol: String { entry.kind.space.systemImage }
    private var tint: Color { WidgetDesign.tint(for: entry.kind.space) }

    /// 点播放键以外的地方打开 App 的电台页 / 播客页, 方便换台、挑别的节目。
    var body: some View {
        content.widgetURL(ListeningSpaceLink.url(for: entry.kind.space))
    }

    @ViewBuilder private var content: some View {
        if let first = entry.snapshot.items.first {
            WidgetCanvas(showsContours: family == .systemSmall,
                         coverImageName: family == .systemLarge ? first.coverImageName : nil,
                         tint: family == .systemLarge ? tint : nil) {
                if family == .systemMedium {
                    if entry.kind.playsEpisodes { podcastFeature(first) }
                    else { radioFeature(first) }
                } else if family == .systemSmall {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            artwork(first, side: 48)
                            Spacer(minLength: 0)
                            playButton(first)
                        }
                        Spacer(minLength: 0)
                        metadata(first, titleSize: 15, lines: 2)
                        if isPlaying(first) { liveLine(first) }
                        progress(first)
                    }
                } else {
                    largeShelf(first)
                }
            }
        } else {
            WidgetEmptyState(symbol: symbol, title: title,
                             subtitle: PMString("ext.widget.\(entry.kind.rawValue).empty"), tint: tint)
        }
    }

    private func largeShelf(_ first: ListeningWidgetSnapshot.Item) -> some View {
        GeometryReader { geometry in
            let remaining = Array(entry.snapshot.items.dropFirst().prefix(3))
            if remaining.isEmpty {
                singleFeature(first, side: min(154, geometry.size.height * 0.47))
                    .widgetBounds(geometry.size)
            } else {
                let shelfHeight = min(140, geometry.size.height * 0.44)
                VStack(alignment: .leading, spacing: 18) {
                    Group {
                        if entry.kind.playsEpisodes { podcastHero(first) }
                        else { radioFeature(first) }
                    }
                    .frame(height: geometry.size.height - shelfHeight - 18)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(remaining) { item in
                            shelfItem(item, side: min(remaining.count == 1 ? 100 : 84,
                                                     (geometry.size.width - CGFloat(remaining.count - 1) * 12) / CGFloat(remaining.count)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(height: shelfHeight, alignment: .bottom)
                }
                .widgetBounds(geometry.size)
            }
        }
    }

    private func singleFeature(_ item: ListeningWidgetSnapshot.Item, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).widgetAccentable()
                Spacer(minLength: 0)
                playButton(item)
            }
            Group {
                if entry.kind == .radio {
                    artwork(item, side: side).clipShape(.circle)
                        .overlay { Circle().strokeBorder(tint.opacity(0.20), lineWidth: 1) }
                } else {
                    artwork(item, side: side).rotationEffect(.degrees(5))
                        .shadow(color: tint.opacity(0.16), radius: 6, x: 0, y: 4)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            metadata(item, titleSize: 20, lines: 2)
            if isPlaying(item) { liveLine(item) }
            progress(item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func podcastHero(_ item: ListeningWidgetSnapshot.Item) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).widgetAccentable()
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.primary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.subtitle).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: max(1, geometry.size.width - 114), alignment: .leading)
                    artwork(item, side: 88)
                        .rotationEffect(.degrees(5))
                        .shadow(color: tint.opacity(0.16), radius: 6, x: 0, y: 4)
                }
                .frame(height: 94)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    progress(item)
                    Spacer(minLength: 0)
                    playButton(item)
                }
            }
            .widgetBounds(geometry.size)
        }
    }

    private func shelfItem(_ item: ListeningWidgetSnapshot.Item, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomTrailing) {
                if entry.kind == .radio {
                    artwork(item, side: side).clipShape(.circle)
                        .overlay { Circle().strokeBorder(tint.opacity(0.18), lineWidth: 1) }
                } else {
                    artwork(item, side: side)
                }
                playButton(item, backdrop: true)
                    .offset(x: 5, y: 5)
            }
            Text(item.title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary).lineLimit(2)
            if isPlaying(item) {
                liveLine(item)
            } else if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 10))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func podcastFeature(_ item: ListeningWidgetSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                artwork(item, side: 24)
                Text(item.subtitle.isEmpty ? title : item.subtitle)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: symbol).foregroundStyle(tint).widgetAccentable()
            }
            Text(item.title)
                .font(.system(size: 20, weight: .bold)).foregroundStyle(.primary)
                .lineLimit(2).minimumScaleFactor(0.88)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if let fraction = item.fractionComplete, fraction > 0 {
                    progress(item)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                playButton(item)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func radioFeature(_ item: ListeningWidgetSnapshot.Item) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(tint).widgetAccentable()
                Spacer(minLength: 0)
                Text(item.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary).lineLimit(2).minimumScaleFactor(0.85)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                liveLine(item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            ZStack {
                ForEach(0..<3) { ring in
                    Circle().strokeBorder(tint.opacity(0.10), lineWidth: 1)
                        .padding(CGFloat(ring) * 8)
                }
                artwork(item, side: 82).clipShape(.circle)
                playButton(item, backdrop: true)
                    .offset(x: 38, y: 38)
            }
            .frame(width: 118, height: 118)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 只有播放键是按钮: 正在播的台点了是停、正在播的单集点了是暂停, 由 intent 在 App 里看播放器定。
    /// 别处点了按 `widgetURL` 打开 App 的电台页 / 播客页; 关掉小组件交互时整块都是打开 App。
    @ViewBuilder private func playButton(_ item: ListeningWidgetSnapshot.Item, backdrop: Bool = false) -> some View {
        let icon = playIcon(item, backdrop: backdrop)
        if WidgetSettings.clickableInteractionEnabled() {
            Button(intent: PrimusePlayListeningWidgetIntent(itemID: item.id, kind: entry.kind.rawValue)) { icon }
                .buttonStyle(.plain)
                .accessibilityLabel(PMString(playKeyLabel(item)) + ", " + item.title)
        } else {
            icon.accessibilityHidden(true)
        }
    }

    private func playKeyLabel(_ item: ListeningWidgetSnapshot.Item) -> String {
        guard isPlaying(item) else { return "ext.control.play" }
        return entry.kind == .radio ? "widget_desk_stop" : "ext.control.pause"
    }

    @ViewBuilder private func artwork(_ item: ListeningWidgetSnapshot.Item, side: CGFloat) -> some View {
        Group {
            if item.coverImageName != nil {
                WidgetCoverImageView(coverImageName: item.coverImageName, cornerRadius: 10)
            } else {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().strokeBorder(tint.opacity(0.15), lineWidth: 1)
                        .frame(width: side * 0.85, height: side * 0.85)
                        .offset(x: side * 0.30, y: -side * 0.28)
                    if side >= 48, !item.title.isEmpty {
                        Text(String(item.title.prefix(1)))
                            .font(.system(size: side * 0.38, weight: .bold, design: .rounded))
                            .foregroundStyle(tint).widgetAccentable()
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: side * 0.35, weight: .medium))
                            .foregroundStyle(tint).widgetAccentable()
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// 封面角上播放键垫的那圈底色。色调、透明外观下它会被渲染成一块实心白片(#190),只在全彩时画。
    private var playIconBackdrop: AnyShapeStyle {
        renderingMode == .fullColor ? AnyShapeStyle(.background) : AnyShapeStyle(Color.clear)
    }

    private func isPlaying(_ item: ListeningWidgetSnapshot.Item) -> Bool {
        entry.playingItemID == item.id
    }

    /// 正在播的台用红色, 跟 App 电台页一样; 单集仍是播客的颜色。
    private var playingAccent: Color { entry.kind == .radio ? .red : tint }

    /// 正在播的台换成红色停止键, 跟 App 电台页一样; 正在播的单集换成暂停键。
    private func playIcon(_ item: ListeningWidgetSnapshot.Item, backdrop: Bool) -> some View {
        let playing = isPlaying(item)
        let accent = playing ? playingAccent : tint
        let symbol = playing ? (entry.kind == .radio ? "stop.fill" : "pause.fill") : "play.fill"
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(accent).widgetAccentable()
            .frame(width: 32, height: 32)
            .background(accent.opacity(0.10), in: .circle)
            .background(backdrop ? playIconBackdrop : AnyShapeStyle(Color.clear), in: .circle)
            .overlay { if backdrop { Circle().strokeBorder(tint.opacity(0.12), lineWidth: 1) } }
            .contentShape(.circle)
    }

    /// 「直播」那一行; 正在播的台是红点加「正在播放」, 单集是播客色的点。
    private func liveLine(_ item: ListeningWidgetSnapshot.Item) -> some View {
        let playing = isPlaying(item)
        return HStack(spacing: 5) {
            Circle().fill(playing ? playingAccent : tint).frame(width: 5, height: 5).widgetAccentable()
            Text(PMString(playing ? "ext.widget.nowPlaying.playing" : "ext.widget.live"))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func metadata(_ item: ListeningWidgetSnapshot.Item, titleSize: CGFloat, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(WidgetDesign.strongText).lineLimit(lines)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 12))
                    .foregroundStyle(WidgetDesign.secondaryText).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func progress(_ item: ListeningWidgetSnapshot.Item) -> some View {
        if let fraction = item.fractionComplete, fraction > 0 {
            WidgetProgressBar(value: fraction, total: 1, tintColor: tint, height: 3)
        }
    }
}
