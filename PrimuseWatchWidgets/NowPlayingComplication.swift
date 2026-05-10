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
        .configurationDisplayName("猿音")
        .description("快速看到正在播放的曲目")
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
                songID: "x", title: "曲目名", artist: "艺术家",
                isPlaying: true, updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: Date(), snapshot: SharedNowPlayingState.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // 单条 entry, policy=.never ── Watch app 在每次状态变化时主动调
        // WidgetCenter.reloadAllTimelines(), 不需要 widget 自己排时间线。
        let entry = NowPlayingEntry(date: Date(), snapshot: SharedNowPlayingState.read())
        completion(Timeline(entries: [entry], policy: .never))
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
                Text(entry.snapshot.hasSong ? entry.snapshot.title : "暂无播放")
                    .font(.headline)
                    .lineLimit(1)
                if !entry.snapshot.artist.isEmpty {
                    Text(entry.snapshot.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if entry.snapshot.hasSong {
                    Text("猿音").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var inline: Text {
        if entry.snapshot.hasSong {
            return Text("\(Image(systemName: iconName)) \(entry.snapshot.title)")
        } else {
            return Text("\(Image(systemName: "music.note")) 猿音")
        }
    }

    private var iconName: String {
        guard entry.snapshot.hasSong else { return "music.note" }
        return entry.snapshot.isPlaying ? "play.fill" : "pause.fill"
    }
}
