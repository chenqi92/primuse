import SwiftUI
import WidgetKit
import PrimuseKit

struct ListeningWidgetEntry: TimelineEntry {
    let date: Date
    let kind: ListeningWidgetKind
    let snapshot: ListeningWidgetSnapshot
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
        .init(date: Date(), kind: kind, snapshot: kind.load() ?? .init(items: []))
    }
    private var preview: ListeningWidgetEntry {
        let titles = kind == .podcast ? ["The Art of Listening", "A Little Curiosity", "Slow Mornings"] : ["Jazz Radio", "Classical", "Late Night"]
        return .init(date: Date(), kind: kind, snapshot: .init(items: titles.enumerated().map {
            .init(id: "preview-\($0.offset)", title: $0.element,
                  subtitle: kind == .podcast ? "Primuse Podcasts" : "Live Radio",
                  fractionComplete: kind == .podcast && $0.offset == 0 ? 0.38 : nil)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    private var title: String { PMString("ext.widget.\(entry.kind.rawValue).title") }
    private var symbol: String { entry.kind == .podcast ? "mic" : "dot.radiowaves.left.and.right" }
    private var tint: Color {
        if colorScheme == .dark {
            return entry.kind == .podcast ? Color(red: 0.75, green: 0.60, blue: 0.95) : Color(red: 1, green: 0.65, blue: 0.36)
        }
        return entry.kind == .podcast ? Color(red: 0.49, green: 0.32, blue: 0.68) : Color(red: 0.74, green: 0.34, blue: 0.16)
    }

    var body: some View {
        if let first = entry.snapshot.items.first {
            WidgetCanvas(showsContours: family == .systemSmall,
                         coverImageName: family == .systemLarge ? first.coverImageName : nil,
                         tint: family == .systemLarge ? tint : nil) {
                if family == .systemMedium {
                    action(first) {
                        if entry.kind == .podcast { podcastFeature(first) }
                        else { radioFeature(first) }
                    }
                } else if family == .systemSmall {
                    action(first) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                artwork(first, side: 48)
                                Spacer(minLength: 0)
                                playIcon
                            }
                            Spacer(minLength: 0)
                            metadata(first, titleSize: 15, lines: 2)
                            progress(first)
                        }
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
                action(first) { singleFeature(first, side: min(154, geometry.size.height * 0.47)) }
                    .widgetBounds(geometry.size)
            } else {
                let shelfHeight = min(140, geometry.size.height * 0.44)
                VStack(alignment: .leading, spacing: 18) {
                    action(first) {
                        if entry.kind == .podcast { podcastHero(first) }
                        else { radioFeature(first) }
                    }
                    .frame(height: geometry.size.height - shelfHeight - 18)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(remaining) { item in
                            action(item) {
                                shelfItem(item, side: min(remaining.count == 1 ? 100 : 84,
                                                         (geometry.size.width - CGFloat(remaining.count - 1) * 12) / CGFloat(remaining.count)))
                            }
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
                playIcon
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
                    playIcon
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
                playIcon
                    .background(playIconBackdrop, in: .circle)
                    .overlay { Circle().strokeBorder(tint.opacity(0.12), lineWidth: 1) }
                    .offset(x: 5, y: 5)
            }
            Text(item.title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary).lineLimit(2)
            if !item.subtitle.isEmpty {
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
                Image(systemName: "mic").foregroundStyle(tint).widgetAccentable()
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
                playIcon
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
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 5, height: 5).widgetAccentable()
                    Text(PMString("ext.widget.live")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            ZStack {
                ForEach(0..<3) { ring in
                    Circle().strokeBorder(tint.opacity(0.10), lineWidth: 1)
                        .padding(CGFloat(ring) * 8)
                }
                artwork(item, side: 82).clipShape(.circle)
                playIcon
                    .background(playIconBackdrop, in: .circle)
                    .offset(x: 38, y: 38)
            }
            .frame(width: 118, height: 118)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private func action<Content: View>(_ item: ListeningWidgetSnapshot.Item, @ViewBuilder content: () -> Content) -> some View {
        if WidgetSettings.clickableInteractionEnabled() {
            Button(intent: PrimusePlayListeningWidgetIntent(itemID: item.id, kind: entry.kind.rawValue)) { content() }
                .buttonStyle(.plain)
                .accessibilityLabel(PMString("ext.control.play") + ", " + item.title)
        } else {
            content()
        }
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

    private var playIcon: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint).widgetAccentable()
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.10), in: .circle)
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
