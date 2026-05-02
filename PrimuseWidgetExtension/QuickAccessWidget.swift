import SwiftUI
import WidgetKit
import PrimuseKit

struct QuickAccessProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAccessEntry {
        QuickAccessEntry(date: Date(), recentAlbums: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickAccessEntry) -> Void) {
        completion(QuickAccessEntry(date: Date(), recentAlbums: RecentAlbumsStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAccessEntry>) -> Void) {
        let entry = QuickAccessEntry(date: Date(), recentAlbums: RecentAlbumsStore.load())
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
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
                .containerBackground(for: .widget) { Color.clear }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("最近播放")
        .description("把最近播放的专辑直接放到桌面上")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct QuickAccessWidgetView: View {
    let entry: QuickAccessEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.recentAlbums.isEmpty {
            switch family {
            case .systemLarge:
                LargeQuickAccessEmptyState()
            default:
                MediumQuickAccessEmptyState()
            }
        } else {
            switch family {
            case .systemLarge:
                LargeQuickAccessView(albums: entry.recentAlbums)
            default:
                MediumQuickAccessView(albums: entry.recentAlbums)
            }
        }
    }
}

private struct MediumQuickAccessView: View {
    let albums: [RecentAlbumEntry]

    private var featuredAlbum: RecentAlbumEntry { albums[0] }
    private var supportingAlbums: [RecentAlbumEntry] { Array(albums.dropFirst().prefix(3)) }

    var body: some View {
        ZStack {
            WidgetArtworkBackdrop(
                coverImageName: featuredAlbum.coverImageName,
                blurRadius: 30,
                shadeOpacity: 0.55
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    WidgetSectionEyebrow(text: "最近播放")
                    Spacer()
                    WidgetStatusPill(text: "\(albums.count) 张", systemImage: "square.stack.3d.up")
                }

                HStack(spacing: 12) {
                    RecentAlbumCoverView(entry: featuredAlbum, cornerRadius: 18)
                        .frame(width: 82, height: 82)
                        .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(featuredAlbum.title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(2)
                        Text(featuredAlbum.artistName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(Array(supportingAlbums.enumerated()), id: \.element.id) { index, album in
                        RecentAlbumCoverView(entry: album, cornerRadius: 14, placeholderIndex: index + 1)
                            .frame(width: 38, height: 38)
                    }
                    Spacer()
                    Text("继续上次的氛围")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WidgetDesign.tertiaryText)
                }
            }
            .padding(16)
        }
    }
}

private struct LargeQuickAccessView: View {
    let albums: [RecentAlbumEntry]

    private var featuredAlbum: RecentAlbumEntry { albums[0] }
    private var secondaryAlbums: [RecentAlbumEntry] { Array(albums.dropFirst().prefix(4)) }

    var body: some View {
        ZStack {
            WidgetArtworkBackdrop(
                coverImageName: featuredAlbum.coverImageName,
                blurRadius: 34,
                shadeOpacity: 0.58
            )

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        WidgetSectionEyebrow(text: "正在收听")
                        Spacer()
                        WidgetStatusPill(text: "继续播放", systemImage: "play.fill")
                    }

                    RecentAlbumCoverView(entry: featuredAlbum, cornerRadius: 22)
                        .frame(height: 122)
                        .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 8)

                    Text(featuredAlbum.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)

                    Text(featuredAlbum.artistName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WidgetDesign.secondaryText)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            WidgetSectionEyebrow(text: "音乐库")
                            Text("最近播放")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(WidgetDesign.strongText)
                        }
                        Spacer()
                        Text("\(min(albums.count, 5)) 项")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                    }

                    let columns = [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ]

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(secondaryAlbums.enumerated()), id: \.element.id) { index, album in
                            compactAlbumCard(album: album, index: index + 1)
                        }
                    }

                    Spacer()
                }
            }
            .padding(18)
        }
    }

    private func compactAlbumCard(album: RecentAlbumEntry, index: Int) -> some View {
        WidgetPanel(padding: 10, cornerRadius: 18) {
            HStack(spacing: 10) {
                RecentAlbumCoverView(entry: album, cornerRadius: 14, placeholderIndex: index)
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)
                    Text(album.artistName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(WidgetDesign.tertiaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct MediumQuickAccessEmptyState: View {
    var body: some View {
        WidgetCanvas(padding: 18) {
            HStack(spacing: 16) {
                WidgetEmptyStateIcon(systemName: "square.stack.3d.up", size: 78)

                VStack(alignment: .leading, spacing: 6) {
                    Text("最近播放会自动出现")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                    Text("开始播放后，最近专辑会直接同步到桌面。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WidgetDesign.secondaryText)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct LargeQuickAccessEmptyState: View {
    var body: some View {
        WidgetCanvas(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetSectionEyebrow(text: "最近播放")
                    Text("把最近迷上的专辑留在桌面")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 0)

                HStack(alignment: .top, spacing: 18) {
                    WidgetEmptyStateIcon(systemName: "square.stack.3d.up.fill", size: 96)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("暂无最近播放")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(WidgetDesign.strongText)
                        Text("最近播放会自动同步到这里，让你回到桌面时也能延续上一段聆听。")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
