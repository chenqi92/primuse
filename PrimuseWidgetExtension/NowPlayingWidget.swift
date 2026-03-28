import SwiftUI
import WidgetKit
import PrimuseKit

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), state: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let state = PlaybackState.load()
        completion(NowPlayingEntry(date: Date(), state: state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let state = PlaybackState.load()
        let entry = NowPlayingEntry(date: Date(), state: state)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: PlaybackState?
}

struct NowPlayingWidget: Widget {
    let kind: String = "NowPlayingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the currently playing song")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        if let state = entry.state, state.currentSongID != nil {
            switch family {
            case .systemSmall:
                smallView(state: state)
            case .systemMedium:
                mediumView(state: state)
            default:
                smallView(state: state)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Not Playing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func smallView(state: PlaybackState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 80)

            Text(state.songTitle ?? "Unknown")
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)

            Text(state.artistName ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func mediumView(state: PlaybackState) -> some View {
        HStack(spacing: 12) {
            // Cover art placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                Image(systemName: "music.note")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.songTitle ?? "Unknown")
                    .font(.headline)
                    .lineLimit(2)

                Text(state.artistName ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let album = state.albumTitle {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                // Progress
                ProgressView(value: state.currentTime, total: max(state.duration, 1))
                    .tint(.blue)
            }
        }
        .padding(4)
    }
}
