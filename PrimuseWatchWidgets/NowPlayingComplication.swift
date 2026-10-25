import SwiftUI
import UIKit
import WidgetKit

/// 表盘上的"Primuse 正在播放"复杂功能。
///
/// 支持的 family:
/// - accessoryCircular: 表盘圆形小角, 显示一个图标 (播放 / 暂停)
/// - accessoryRectangular: 矩形, 显示封面 (没有就是状态图标) + 曲目 + 艺术家 + 进度
/// - accessoryInline: 表盘顶部一行文字
/// - accessoryCorner: 表盘四角, 图标 + 沿边歌名
///
/// 圆形和矩形带这首的进度: 播放中用 ProgressView(timerInterval:) 自己走, 不额外刷新时间线。
///
/// 数据通过 `SharedNowPlayingState` 读 App Group UserDefaults。Watch app
/// 在收到 iPhone 推送的状态后写入并调 `WidgetCenter.reloadTimelines(ofKind:)`
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
            .accessoryCorner,
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
                isPlaying: true, isLiveStream: false, updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: Date(), snapshot: SharedNowPlayingState.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedNowPlayingState.read()
        let staleDate = snapshot.staleDate
        if snapshot.hasSong, now < staleDate {
            let expiry = max(now.addingTimeInterval(1), staleDate)
            let entries = [
                NowPlayingEntry(date: now, snapshot: snapshot),
                NowPlayingEntry(date: expiry, snapshot: .empty)
            ]
            completion(Timeline(entries: entries, policy: .after(expiry)))
        } else {
            completion(Timeline(
                entries: [NowPlayingEntry(date: now, snapshot: .empty)],
                policy: .after(now.addingTimeInterval(SharedNowPlayingState.Snapshot.staleInterval))
            ))
        }
    }
}

struct NowPlayingComplicationView: View {
    @Environment(\.widgetFamily) var family
    let entry: NowPlayingEntry

    var body: some View {
        content
            .containerBackground(for: .widget) {
                // 只有智能叠放里看得到这层底; 表盘上系统会把它拿掉。
                LinearGradient(
                    colors: [accent.opacity(0.55), accent.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .accessoryCorner: corner
        default: circular
        }
    }

    private var snapshot: SharedNowPlayingState.Snapshot { entry.snapshot }

    private var accent: Color {
        guard let rgb = snapshot.accentRGB else {
            return Color(red: 0.078, green: 0.490, blue: 0.541)
        }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    /// 圆形: 播放状态图标, 外圈是这首的进度 (播放中自己走, 不用刷新时间线)。
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            progressRing
            Image(systemName: iconName)
                .font(.title3)
                .widgetAccentable()
        }
    }

    @ViewBuilder
    private var progressRing: some View {
        if let interval = snapshot.playbackInterval {
            ProgressView(timerInterval: interval, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .widgetAccentable()
        } else if let fraction = snapshot.pausedFraction {
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .widgetAccentable()
        }
    }

    private var rectangular: some View {
        HStack(spacing: 6) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.hasSong ? snapshot.title : WatchString("ext.watch.nowPlaying.none"))
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()
                if !snapshot.artist.isEmpty {
                    Text(snapshot.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if snapshot.hasSong {
                    Text(WatchString("ext.watch.appName")).font(.caption2).foregroundStyle(.secondary)
                }
                linearProgress
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var linearProgress: some View {
        if let interval = snapshot.playbackInterval {
            ProgressView(timerInterval: interval, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .widgetAccentable()
        } else if let fraction = snapshot.pausedFraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .widgetAccentable()
        }
    }

    /// 有封面放封面, 没有就放状态图标。
    @ViewBuilder
    private var artwork: some View {
        if let data = snapshot.coverJPEG, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: iconName)
                        .font(.system(size: 9, weight: .bold))
                        .padding(3)
                        .background(.black.opacity(0.55), in: Circle())
                        .offset(x: 3, y: 3)
                }
        } else {
            Image(systemName: iconName)
                .font(.headline)
                .widgetAccentable()
        }
    }

    /// 表盘四角: 角上放图标, 沿边弧形写歌名。
    private var corner: some View {
        Image(systemName: iconName)
            .font(.title3)
            .widgetAccentable()
            .widgetLabel {
                Text(snapshot.hasSong ? snapshot.title : WatchString("ext.watch.appName"))
            }
    }

    private var inline: Text {
        if snapshot.hasSong {
            return Text("\(Image(systemName: iconName)) \(snapshot.title)")
        } else {
            return Text("\(Image(systemName: "music.note")) \(WatchString("ext.watch.appName"))")
        }
    }

    private var iconName: String {
        guard snapshot.hasSong else { return "music.note" }
        if snapshot.isLiveStream { return "dot.radiowaves.left.and.right" }
        return snapshot.isPlaying ? "play.fill" : "pause.fill"
    }
}
