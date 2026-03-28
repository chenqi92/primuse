import SwiftUI
import WidgetKit
import PrimuseKit

struct QuickAccessProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickAccessEntry {
        QuickAccessEntry(date: Date(), recentAlbums: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickAccessEntry) -> Void) {
        completion(QuickAccessEntry(date: Date(), recentAlbums: []))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickAccessEntry>) -> Void) {
        let entry = QuickAccessEntry(date: Date(), recentAlbums: [])
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct QuickAccessEntry: TimelineEntry {
    let date: Date
    let recentAlbums: [RecentAlbum]

    struct RecentAlbum {
        let id: String
        let title: String
        let artistName: String
    }
}

struct QuickAccessWidget: Widget {
    let kind: String = "QuickAccessWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickAccessProvider()) { entry in
            QuickAccessWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Access")
        .description("Quick access to recent albums")
        .supportedFamilies([.systemMedium])
    }
}

struct QuickAccessWidgetView: View {
    let entry: QuickAccessEntry

    var body: some View {
        if entry.recentAlbums.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.stack")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text("No Recent Albums")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Play some music to see your recent albums here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        } else {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 8) {
                ForEach(entry.recentAlbums.prefix(4), id: \.id) { album in
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                        .aspectRatio(1, contentMode: .fit)

                        Text(album.title)
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
