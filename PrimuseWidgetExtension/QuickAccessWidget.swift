import SwiftUI
import WidgetKit
import PrimuseKit

struct QuickAccessProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAccessEntry {
        QuickAccessEntry(date: Date(), recentAlbums: Self.demoAlbums)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickAccessEntry) -> Void) {
        // 画廊预览喂 demo 数据,真实使用走 App Group。同 NowPlayingProvider。
        if context.isPreview {
            completion(QuickAccessEntry(date: Date(), recentAlbums: Self.demoAlbums))
        } else {
            completion(QuickAccessEntry(date: Date(), recentAlbums: RecentAlbumsStore.load()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAccessEntry>) -> Void) {
        let entry = QuickAccessEntry(date: Date(), recentAlbums: RecentAlbumsStore.load())
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    /// 画廊预览用的假专辑列表 —— 5 张,覆盖 medium (头图 + 3 缩略) 和
    /// large (头图 + 4 缩略) 两种 size 的需要。封面留 nil,WidgetCoverImageView
    /// 会落回 placeholderGradient 渐变占位。
    private static let demoAlbums: [RecentAlbumEntry] = [
        RecentAlbumEntry(id: "demo-1", title: "Double Fantasy", artistName: "John Lennon", coverImageName: nil),
        RecentAlbumEntry(id: "demo-2", title: "OK Computer", artistName: "Radiohead", coverImageName: nil),
        RecentAlbumEntry(id: "demo-3", title: "Kind of Blue", artistName: "Miles Davis", coverImageName: nil),
        RecentAlbumEntry(id: "demo-4", title: "Nevermind", artistName: "Nirvana", coverImageName: nil),
        RecentAlbumEntry(id: "demo-5", title: "Rumours", artistName: "Fleetwood Mac", coverImageName: nil),
    ]
}

struct QuickAccessEntry: TimelineEntry {
    let date: Date
    let recentAlbums: [RecentAlbumEntry]
}

struct QuickAccessWidget: Widget {
    let kind = "QuickAccessWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickAccessProvider()) { entry in
            QuickAccessWidgetView(entry: entry)
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.recent.displayName"))
        .description(PMString("ext.widget.recent.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct QuickAccessWidgetView: View {
    let entry: QuickAccessEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.recentAlbums.isEmpty {
            switch family {
            case .systemSmall: SmallQuickAccessEmptyState()
            case .systemLarge: LargeQuickAccessEmptyState()
            default: MediumQuickAccessEmptyState()
            }
        } else {
            switch family {
            case .systemSmall: SmallQuickAccessView(albums: entry.recentAlbums)
            case .systemLarge: LargeQuickAccessView(albums: entry.recentAlbums)
            default: MediumQuickAccessView(albums: entry.recentAlbums)
            }
        }
    }
}

private struct SmallQuickAccessView: View {
    let albums: [RecentAlbumEntry]
    var body: some View {
        WidgetCanvas {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    ForEach(Array(albums.prefix(3).enumerated()).reversed(), id: \.element.id) { index, album in
                        RecentAlbumCoverView(entry: album, cornerRadius: 7, placeholderIndex: index)
                            .frame(width: 65, height: 65)
                            .rotationEffect(.degrees(Double(index) * 9 - 6))
                            .offset(x: CGFloat(index) * 16 - 14, y: CGFloat(index) * -3)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(albums.first?.title ?? "")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(WidgetDesign.strongText)
                    Text(PMString("ext.widget.recent.eyebrow"))
                        .font(.system(size: 11)).foregroundStyle(WidgetDesign.secondaryText)
                }
                .lineLimit(1)
            }
        }
    }
}
private struct MediumQuickAccessView: View {
    let albums: [RecentAlbumEntry]
    var body: some View {
        WidgetCanvas(showsContours: false) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(PMString("ext.widget.recent.eyebrow"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(albums.first?.title ?? "")
                        .font(.system(size: 21, weight: .bold)).foregroundStyle(.primary)
                        .lineLimit(2).minimumScaleFactor(0.88)
                    Text(albums.first?.artistName ?? "")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                GeometryReader { geometry in
                    let side = min(100, geometry.size.height - 16)
                    ZStack {
                        ForEach(Array(albums.prefix(3).enumerated()).reversed(), id: \.element.id) { index, album in
                            RecentAlbumCoverView(entry: album, cornerRadius: 6, placeholderIndex: index)
                                .frame(width: side, height: side)
                                .rotationEffect(.degrees(Double(index) * 9 - 7))
                                .offset(x: CGFloat(index) * 17 - 12, y: CGFloat(index) * -3)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(width: 132)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(albums.prefix(3).map(\.title).joined(separator: ", "))
            }
        }
    }
}
private struct LargeQuickAccessView: View {
    let albums: [RecentAlbumEntry]
    var body: some View { AlbumGrid(albums: albums, columns: 2, showsTitles: true, rows: 2) }
}

private struct AlbumGrid: View {
    let albums: [RecentAlbumEntry]
    let columns: Int
    let showsTitles: Bool
    var rows: Int = 1
    @Environment(\.widgetFamily) private var family

    var body: some View {
        WidgetCanvas(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                WidgetSectionEyebrow(text: PMString("ext.widget.recent.eyebrow"))
                GeometryReader { geometry in
                    let rowCount = family == .systemSmall ? 2 : rows
                    let gap: CGFloat = 10
                    let width = max(1, (geometry.size.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
                    let rowHeight = max(1, (geometry.size.height - CGFloat(rowCount - 1) * gap) / CGFloat(rowCount))
                    let side = max(1, min(width, rowHeight - (showsTitles ? 35 : 0)))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .leading), count: columns), alignment: .leading, spacing: gap) {
                        ForEach(Array(albums.prefix(columns * rowCount).enumerated()), id: \.element.id) { index, album in
                            VStack(alignment: .leading, spacing: 5) {
                                RecentAlbumCoverView(entry: album, cornerRadius: 8, placeholderIndex: index)
                                    .frame(width: side, height: side)
                                if showsTitles {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title).font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(WidgetDesign.strongText)
                                        Text(album.artistName).font(.system(size: 11))
                                            .foregroundStyle(WidgetDesign.secondaryText)
                                    }
                                    .lineLimit(1)
                                }
                            }
                            .frame(width: width, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(album.title + ", " + album.artistName)
                        }
                    }
                }
            }
        }
    }
}

private struct SmallQuickAccessEmptyState: View {
    var body: some View {
        WidgetEmptyState(symbol: "square.stack", title: PMString("ext.widget.recent.empty.title"),
                         subtitle: PMString("ext.widget.recent.empty.short"))
    }
}
private typealias MediumQuickAccessEmptyState = SmallQuickAccessEmptyState
private typealias LargeQuickAccessEmptyState = SmallQuickAccessEmptyState
