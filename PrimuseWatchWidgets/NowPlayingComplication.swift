import SwiftUI
import WidgetKit

/// 表盘上的"猿音正在播放"复杂功能。
///
/// 支持的 family:
/// - accessoryCircular: 表盘圆形小角, 显示一个图标 (播放 / 暂停)
/// - accessoryRectangular: 矩形, 显示曲目 + 艺术家 + 状态图标
/// - accessoryInline: 表盘顶部一行文字
///
/// 数据通过 `SharedNowPlayingState` 读 App Group UserDefaults。Watch app
/// 在收到 iPhone 推送的状态后写入并调 `WidgetCenter.reloadAllTimelines()`
/// 强制刷新。
struct NowPlayingComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SharedNowPlayingState.widgetKind,
            provider: NowPlayingProvider()
        ) { entry in
            NowPlayingComplicationView(entry: entry)
        }
        .configurationDisplayName(WatchString("ext.watch.appName"))
        .description(WatchString("ext.watch.complication.description"))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedNowPlayingState.Snapshot
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(
            date: Date(),
            snapshot: SharedNowPlayingState.Snapshot(
                songID: "x", title: WatchString("ext.watch.demo.track"), artist: WatchString("ext.watch.demo.artist"),
                isPlaying: true, updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: Date(), snapshot: SharedNowPlayingState.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedNowPlayingState.read()
        let staleAfter: TimeInterval = 15 * 60
        if snapshot.hasSong, now.timeIntervalSince(snapshot.updatedAt) < staleAfter {
            let expiry = max(now.addingTimeInterval(1), snapshot.updatedAt.addingTimeInterval(staleAfter))
            let entries = [
                NowPlayingEntry(date: now, snapshot: snapshot),
                NowPlayingEntry(date: expiry, snapshot: .empty)
            ]
            completion(Timeline(entries: entries, policy: .after(expiry)))
        } else {
            completion(Timeline(
                entries: [NowPlayingEntry(date: now, snapshot: .empty)],
                policy: .after(now.addingTimeInterval(staleAfter))
            ))
        }
    }
}

struct NowPlayingComplicationView: View {
    @Environment(\.widgetFamily) var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: circular
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: iconName)
                .font(.title3)
        }
    }

    private var rectangular: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.headline)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.snapshot.hasSong ? entry.snapshot.title : WatchString("ext.watch.nowPlaying.none"))
                    .font(.headline)
                    .lineLimit(1)
                if !entry.snapshot.artist.isEmpty {
                    Text(entry.snapshot.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if entry.snapshot.hasSong {
                    Text(WatchString("ext.watch.appName")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var inline: Text {
        if entry.snapshot.hasSong {
            return Text("\(Image(systemName: iconName)) \(entry.snapshot.title)")
        } else {
            return Text("\(Image(systemName: "music.note")) \(WatchString("ext.watch.appName"))")
        }
    }

    private var iconName: String {
        guard entry.snapshot.hasSong else { return "music.note" }
        return entry.snapshot.isPlaying ? "play.fill" : "pause.fill"
    }
}
