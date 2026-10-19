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
    typealias Item = ListeningWidgetSnapshot.Item

    let entry: ListeningWidgetEntry
    @Environment(\.widgetFamily) private var family
    private var title: String { PMString("ext.widget.\(entry.kind.rawValue).title") }
    /// 和 App 首页顶部切换里电台、播客那一类用同一个图标、同一个颜色。
    private var symbol: String { entry.kind.space.systemImage }
    private var tint: Color { WidgetDesign.tint(for: entry.kind.space) }
    /// 封面的投影: 单色时是普通的暗影, 不让中性色在深色外观下变成一圈白光。
    private var shadowTint: Color { WidgetDesign.prefersMonochrome ? .black : tint }

    /// 点播放键以外的地方打开 App 的电台页 / 播客页, 方便换台、挑别的节目。
    var body: some View {
        content.widgetURL(ListeningSpaceLink.url(for: entry.kind.space))
    }

    @ViewBuilder private var content: some View {
        if let first = entry.snapshot.items.first {
            WidgetCanvas(showsContours: family == .systemSmall,
                         coverImageName: family == .systemLarge ? first.coverImageName : nil,
                         tint: family == .systemLarge ? tint : nil) {
                GeometryReader { geometry in
                    Group {
                        if family == .systemMedium {
                            if entry.kind.playsEpisodes { podcastFeature(first, height: geometry.size.height) }
                            else { radioFeature(first, height: geometry.size.height) }
                        } else if family == .systemSmall {
                            smallFeature(first, height: geometry.size.height)
                        } else {
                            largeShelf(first, size: geometry.size)
                        }
                    }
                    .widgetBounds(geometry.size)
                }
            }
        } else {
            WidgetEmptyState(symbol: symbol, title: title,
                             subtitle: PMString("ext.widget.\(entry.kind.rawValue).empty"), tint: tint)
        }
    }

    /// 小号: 封面和播放键一排, 下面名字、节目, 在播的台多一行「正在播放」, 有进度时一条进度。
    /// 封面一排 48、名字两行连节目约 53, 加上间距共约 113pt, 「正在播放」再加 18、进度加 9; iPad mini
    /// 小号的内容只有 109pt 高(4.7 寸 iPhone 116), 排不下时名字收成一行, 还不够才把封面压小。
    private func smallFeature(_ item: Item, height: CGFloat) -> some View {
        let extras: CGFloat = (isPlaying(item) ? 18 : 0) + (hasProgress(item) ? 9 : 0)
        let titleLines = height >= 113.5 + extras ? 2 : 1
        let textHeight: CGFloat = titleLines == 2 ? 65.5 : 47.5
        let side: CGFloat = min(48, max(32, height - extras - textHeight))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                artwork(item, side: side)
                Spacer(minLength: 0)
                playButton(item)
            }
            Spacer(minLength: 0)
            metadata(item, titleSize: 15, lines: titleLines)
            if isPlaying(item) { liveLine(item) }
            progress(item)
        }
    }

    @ViewBuilder private func largeShelf(_ first: Item, size: CGSize) -> some View {
        let remaining = Array(entry.snapshot.items.dropFirst().prefix(3))
        if remaining.isEmpty {
            singleFeature(first, size: size)
        } else {
            let shelfHeight: CGFloat = min(140, size.height * 0.44)
            let gap: CGFloat = 12
            let count = CGFloat(remaining.count)
            // 底下一格: 封面、7、名字(两行约 29, 一行约 14)、7、节目一行约 12。iPad mini 大号给这一排的只有
            // 约 120pt(4.7 寸 iPhone 约 128), 两行名字连 84 的封面要 139: 名字收成一行、封面按剩下的高度取,
            // 不再往上压进主角那块。
            let largestSide: CGFloat = remaining.count == 1 ? 100 : 84
            let sideCap: CGFloat = min(largestSide, (size.width - (count - 1) * gap) / count)
            let titleLines = shelfHeight >= sideCap + 55 ? 2 : 1
            let textHeight: CGFloat = titleLines == 2 ? 55 : 41
            let side: CGFloat = max(40, min(sideCap, shelfHeight - textHeight))
            let heroHeight: CGFloat = size.height - shelfHeight - 18
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if entry.kind.playsEpisodes { podcastHero(first) }
                    else { radioFeature(first, height: heroHeight) }
                }
                .frame(height: heroHeight)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(remaining) { item in
                        shelfItem(item, side: side, titleLines: titleLines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: shelfHeight, alignment: .bottom)
            }
        }
    }

    /// 只有一个台 / 一集时整块给它。封面原来只按高度的 47% 取, iPad mini 大号(内容 273.5pt 高)上在播的台
    /// 会超出底边约 12pt: 头一行 32、名字两行连节目约 65、四段间距 48 是固定的, 「正在播放」再加 24、
    /// 进度加 15, 先扣掉它们再定封面。
    private func singleFeature(_ item: Item, size: CGSize) -> some View {
        let extras: CGFloat = (isPlaying(item) ? 24 : 0) + (hasProgress(item) ? 15 : 0)
        let side: CGFloat = max(60, min(154, size.height * 0.47, size.height - 134 - extras))
        return VStack(alignment: .leading, spacing: 12) {
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
                        .shadow(color: shadowTint.opacity(0.16), radius: 6, x: 0, y: 4)
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

    private func podcastHero(_ item: Item) -> some View {
        GeometryReader { geometry in
            // 名字和封面那一排原来固定 94 高, 连上头一行、底下进度和播放键共要 160pt; iPad mini 大号这块
            // 只有约 135(4.7 寸 iPhone 约 146), 播放键会被裁掉。现在这一排按扣掉其余 66pt 后剩下的高度取,
            // 名字排得下几行就写几行(18pt 一行约 21.5)。
            let rowHeight: CGFloat = max(40, min(94, geometry.size.height - 66))
            let side: CGFloat = min(88, rowHeight - 6)
            let titleLines = rowHeight >= 90 ? 3 : (rowHeight >= 64 ? 2 : 1)
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint).widgetAccentable()
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.primary).lineLimit(titleLines)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.subtitle).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: max(1, geometry.size.width - side - 26), alignment: .leading)
                    artwork(item, side: side)
                        .rotationEffect(.degrees(5))
                        .shadow(color: shadowTint.opacity(0.16), radius: 6, x: 0, y: 4)
                }
                .frame(height: rowHeight)
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

    private func shelfItem(_ item: Item, side: CGFloat, titleLines: Int) -> some View {
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
                .foregroundStyle(.primary).lineLimit(titleLines)
            if isPlaying(item) {
                liveLine(item)
            } else if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 10))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 中号播客: 头一行 24、名字两行约 48、底下一排 32 高的进度和播放键, 加上间距共约 125pt; iPad mini 与
    /// 4.7 寸 iPhone 中号的内容只有 109 / 116pt 高, 名字收成一行。
    private func podcastFeature(_ item: Item, height: CGFloat) -> some View {
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
                .lineLimit(height >= 125 ? 2 : 1).minimumScaleFactor(0.88)
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

    /// 台名在左, 右边圆形台标套三道细环。环原来固定 118, 比 iPad mini(109)、4.7 寸 iPhone(116)中号的
    /// 内容高度还高, 现在按高度取, 台标和角上的播放键跟着等比缩。左栏台名两行连上下几行约 120pt,
    /// 矮的中号收成一行。
    private func radioFeature(_ item: Item, height: CGFloat) -> some View {
        let ringSide: CGFloat = max(60, min(118, height))
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(tint).widgetAccentable()
                Spacer(minLength: 0)
                Text(item.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary).lineLimit(height >= 121 ? 2 : 1).minimumScaleFactor(0.85)
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
                artwork(item, side: ringSide * 82 / 118).clipShape(.circle)
                playButton(item, backdrop: true)
                    .offset(x: ringSide * 38 / 118, y: ringSide * 38 / 118)
            }
            .frame(width: ringSide, height: ringSide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 只有播放键是按钮: 正在播的台点了是停、正在播的单集点了是暂停, 由 intent 在 App 里看播放器定。
    /// 别处点了按 `widgetURL` 打开 App 的电台页 / 播客页; 关掉小组件交互时整块都是打开 App。
    @ViewBuilder private func playButton(_ item: Item, backdrop: Bool = false) -> some View {
        let icon = playIcon(item, backdrop: backdrop)
        if WidgetSettings.clickableInteractionEnabled() {
            Button(intent: PrimusePlayListeningWidgetIntent(itemID: item.id, kind: entry.kind.rawValue)) { icon }
                .buttonStyle(.plain)
                .accessibilityLabel(PMString(playKeyLabel(item)) + ", " + item.title)
        } else {
            icon.accessibilityHidden(true)
        }
    }

    private func playKeyLabel(_ item: Item) -> String {
        guard isPlaying(item) else { return "ext.control.play" }
        return entry.kind == .radio ? "widget_desk_stop" : "ext.control.pause"
    }

    @ViewBuilder private func artwork(_ item: Item, side: CGFloat) -> some View {
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

    private func isPlaying(_ item: Item) -> Bool {
        entry.playingItemID == item.id
    }

    private func hasProgress(_ item: Item) -> Bool {
        (item.fractionComplete ?? 0) > 0
    }

    /// 正在播的台前面那颗状态点是红的, 跟 App 电台页一样; 单集仍是播客的颜色。播放键本身不染色。
    private var playingAccent: Color { entry.kind == .radio ? .red : tint }

    /// 正在播的台换成停止键、正在播的单集换成暂停键。键一律是中性的毛玻璃(#320), 压在封面角上
    /// (`backdrop`)时那一层更实, 什么颜色的封面上都看得清。
    private func playIcon(_ item: Item, backdrop: Bool) -> some View {
        let symbol = isPlaying(item) ? (entry.kind == .radio ? "stop.fill" : "pause.fill") : "play.fill"
        return WidgetGlassKeyLabel(symbol: symbol, diameter: 32, overArtwork: backdrop, symbolScale: 0.40)
    }

    /// 「直播」那一行; 正在播的台是红点加「正在播放」, 单集是播客色的点。
    private func liveLine(_ item: Item) -> some View {
        let playing = isPlaying(item)
        return HStack(spacing: 5) {
            Circle().fill(playing ? playingAccent : tint).frame(width: 5, height: 5).widgetAccentable()
            Text(PMString(playing ? "ext.widget.nowPlaying.playing" : "ext.widget.live"))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func metadata(_ item: Item, titleSize: CGFloat, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(WidgetDesign.strongText).lineLimit(lines)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 12))
                    .foregroundStyle(WidgetDesign.secondaryText).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func progress(_ item: Item) -> some View {
        if let fraction = item.fractionComplete, fraction > 0 {
            WidgetProgressBar(value: fraction, total: 1, tintColor: tint, height: 3)
        }
    }
}
