import SwiftUI
import WidgetKit
import PrimuseKit

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), state: Self.demoState)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        // 系统 widget 画廊用 isPreview=true 调这里 —— 用户还没添加 widget,
        // 实际 PlaybackState 大概率是空, 渲染"尚未播放"空状态会让画廊看起来
        // 像功能没做完。预览阶段一律喂 demo 数据,真实使用时才走 App Group。
        if context.isPreview {
            completion(NowPlayingEntry(date: Date(), state: Self.demoState))
        } else {
            completion(NowPlayingEntry(date: Date(), state: PlaybackState.load()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = NowPlayingEntry(date: Date(), state: PlaybackState.load())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    /// 画廊预览 / placeholder 用的假数据 —— 让 widget 在用户挑选时就能
    /// 看到"长大后是啥样",而不是空 state。
    private static let demoState = PlaybackState(
        currentSongID: "demo",
        songTitle: "Beautiful Boy",
        artistName: "John Lennon",
        albumTitle: "Double Fantasy",
        fileFormat: "FLAC",
        coverArtData: nil,
        coverImageName: nil,
        isPlaying: true,
        currentTime: 88,
        duration: 248,
        queueSongIDs: ["demo-2", "demo-3", "demo-4"]
    )
}

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let state: PlaybackState?
}

struct NowPlayingWidget: Widget {
    let kind = "NowPlayingWidget"

    // 锁屏/灵动岛 accessory 家族是 iOS/watchOS 专有, 原生 macOS 的 WidgetFamily
    // 没有这些 case。
    private var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge,
         .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("正在播放")
        .description("快速查看当前歌曲和播放进度")
        .supportedFamilies(families)
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state, state.currentSongID != nil {
            switch family {
            case .systemSmall: SmallNowPlayingView(state: state)
            case .systemMedium: MediumNowPlayingView(state: state)
            case .systemLarge: LargeNowPlayingView(state: state)
            #if os(iOS)
            case .accessoryCircular: AccessoryCircularNowPlaying(state: state)
            case .accessoryRectangular: AccessoryRectangularNowPlaying(state: state)
            case .accessoryInline: AccessoryInlineNowPlaying(state: state)
            #endif
            default: SmallNowPlayingView(state: state)
            }
        } else {
            switch family {
            case .systemSmall: SmallEmptyStateView()
            case .systemMedium: MediumEmptyStateView()
            case .systemLarge: LargeEmptyStateView()
            #if os(iOS)
            case .accessoryCircular: AccessoryCircularEmptyState()
            case .accessoryRectangular: AccessoryRectangularEmptyState()
            case .accessoryInline: AccessoryInlineEmptyState()
            #endif
            default: SmallEmptyStateView()
            }
        }
    }
}

// MARK: - Home Screen widgets
//
// 设计目标:
// - 封面主导, 文字最少, 装饰最少
// - 单一进度条贴在底部, 极细 + 半透明白
// - 文字粗细对比强: 标题用 .bold(.body), 艺术家用 .secondary
// - 没有封面时落回多色唱片占位, 不再整块品牌紫

private struct SmallNowPlayingView: View {
    let state: PlaybackState

    var body: some View {
        ZStack {
            // 封面填满整个 widget 当背景。.scaleEffect 是 WidgetArtworkBackdrop
            // 同款手法,防止 blur 边缘露出透明。
            WidgetCoverImageView(
                coverImageName: state.coverImageName,
                cornerRadius: 0,
                placeholderIndex: 0
            )
            .scaleEffect(1.05)
            // 底部偏暗的渐变保证标题可读
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                Text(state.songTitle ?? "未知歌曲")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(state.artistName ?? "未知艺术家")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                ProgressLine(value: state.currentTime, total: state.duration)
                    .padding(.top, 2)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MediumNowPlayingView: View {
    let state: PlaybackState

    var body: some View {
        GeometryReader { geometry in
            let coverSide = min(112, max(88, geometry.size.height - 32))

            WidgetCanvas(padding: 16) {
                HStack(spacing: 16) {
                    WidgetCoverImageView(
                        coverImageName: state.coverImageName,
                        cornerRadius: 12,
                        placeholderIndex: 0
                    )
                    .frame(width: coverSide, height: coverSide)

                    VStack(alignment: .leading, spacing: 6) {
                        NowPlayingEyebrow(state: state)

                        Text(state.songTitle ?? "未知歌曲")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.86)
                        Text(state.artistName ?? "未知艺术家")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)
                        Text(state.albumTitle?.isEmpty == false ? state.albumTitle! : "未知专辑")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        VStack(spacing: 5) {
                            ProgressLine(value: state.currentTime, total: state.duration)
                            HStack {
                                Text(formatTime(state.currentTime))
                                Spacer()
                                Text(formatTime(state.duration))
                            }
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                        }

                        NowPlayingControls(
                            symbols: ["heart", "backward.fill", state.isPlaying ? "pause.fill" : "play.fill", "forward.fill", "ellipsis"],
                            compact: true
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LargeNowPlayingView: View {
    let state: PlaybackState

    var body: some View {
        GeometryReader { geometry in
            let coverSide = min(138, max(118, geometry.size.width * 0.42))

            WidgetCanvas(padding: 18) {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .top, spacing: 14) {
                        WidgetCoverImageView(
                            coverImageName: state.coverImageName,
                            cornerRadius: 14,
                            placeholderIndex: 0
                        )
                        .frame(width: coverSide, height: coverSide)

                        VStack(alignment: .leading, spacing: 6) {
                            NowPlayingEyebrow(state: state)
                            Text(state.songTitle ?? "未知歌曲")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(WidgetDesign.strongText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                            Text(state.artistName ?? "未知艺术家")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(WidgetDesign.secondaryText)
                                .lineLimit(1)
                            Text(state.albumTitle?.isEmpty == false ? state.albumTitle! : "未知专辑")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(WidgetDesign.tertiaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    NowPlayingLyricsPreview(state: state)
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 6) {
                        ProgressLine(value: state.currentTime, total: state.duration)
                        HStack {
                            Text(formatTime(state.currentTime))
                            Spacer()
                            Text(formatTime(state.duration))
                        }
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(WidgetDesign.tertiaryText)
                    }

                    NowPlayingControls(
                        symbols: ["shuffle", "backward.fill", state.isPlaying ? "pause.fill" : "play.fill", "forward.fill", "repeat", "heart", "ellipsis"],
                        compact: false
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NowPlayingEyebrow: View {
    let state: PlaybackState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 9.5, weight: .bold))
            Text(verbatim: eyebrowText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(WidgetDesign.tertiaryText)
    }

    private var eyebrowText: String {
        let format = state.fileFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let format, !format.isEmpty {
            return "正在播放 · \(format.uppercased())"
        }
        return state.isPlaying ? "正在播放" : "已暂停"
    }
}

private struct NowPlayingControls: View {
    let symbols: [String]
    var compact: Bool

    var body: some View {
        HStack(spacing: compact ? 10 : 14) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                Image(systemName: symbol)
                    .font(.system(size: controlSize(symbol: symbol), weight: .semibold))
                    .foregroundStyle(WidgetDesign.strongText)
                    .frame(width: controlFrame(symbol: symbol), height: controlFrame(symbol: symbol))
                    .background(controlBackground(symbol: symbol), in: .circle)
                    .overlay {
                        Circle().strokeBorder(WidgetDesign.hairline, lineWidth: symbol.contains("play") || symbol.contains("pause") ? 0 : 1)
                    }
                    .accessibilityHidden(true)
                    .id("\(index)-\(symbol)")
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
    }

    private func controlSize(symbol: String) -> CGFloat {
        if symbol.contains("play") || symbol.contains("pause") { return compact ? 12 : 16 }
        return compact ? 10.5 : 12.5
    }

    private func controlFrame(symbol: String) -> CGFloat {
        if symbol.contains("play") || symbol.contains("pause") { return compact ? 26 : 34 }
        return compact ? 22 : 28
    }

    private func controlBackground(symbol: String) -> Color {
        if symbol.contains("play") || symbol.contains("pause") {
            return WidgetDesign.brandTint.opacity(0.22)
        }
        return Color.primary.opacity(0.06)
    }
}

private struct NowPlayingLyricsPreview: View {
    let state: PlaybackState

    private var lines: [String] {
        guard let snapshot = LyricsSnapshot.load(),
              snapshot.songID == state.currentSongID,
              snapshot.lines.isEmpty == false else {
            return ["暂无歌词预览", "播放含歌词的曲目后", "这里会跟随更新"]
        }

        let start = max(0, snapshot.anchorIndex - 1)
        return Array(snapshot.lines.dropFirst(start).prefix(3)).map(\.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(verbatim: line)
                    .font(.system(size: index == 1 ? 12.5 : 11.5, weight: index == 1 ? .semibold : .medium))
                    .foregroundStyle(index == 1 ? WidgetDesign.strongText : WidgetDesign.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.055), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(WidgetDesign.hairline, lineWidth: 1)
        }
    }
}

// MARK: - 空状态 (极简: 单 icon + 一行)

private struct SmallEmptyStateView: View {
    var body: some View {
        WidgetCanvas(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Spacer()
                WidgetEmptyStateIcon(systemName: "music.note", size: 42)
                Text("尚未播放")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WidgetDesign.strongText)
                Text("打开猿音继续")
                    .font(.system(size: 11))
                    .foregroundStyle(WidgetDesign.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct MediumEmptyStateView: View {
    var body: some View {
        WidgetCanvas(padding: 18) {
            HStack(spacing: 16) {
                WidgetEmptyStateIcon(systemName: "music.note", size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("尚未播放")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(WidgetDesign.strongText)
                    Text("打开猿音继续上次的旋律")
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetDesign.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct LargeEmptyStateView: View {
    var body: some View {
        WidgetCanvas(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                WidgetEmptyStateIcon(systemName: "music.note", size: 78)
                VStack(alignment: .leading, spacing: 6) {
                    Text("尚未播放")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(WidgetDesign.strongText)
                    Text("连接你的音乐源,这里会显示当前歌曲和播放进度。")
                        .font(.system(size: 13))
                        .foregroundStyle(WidgetDesign.secondaryText)
                        .lineLimit(3)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Lock Screen / Accessory families
//
// iOS 16+ 锁屏小组件渲染时,SwiftUI 自动套一个 `widgetAccentable` / 渲染模式
// (full color / accented / vibrant)。这里所有的图标 / 文字都用系统材质,
// 让 vibrant 渲染模式下穿透时颜色协调,不要硬塞 RGB。
//
// 整块是 iOS/watchOS 专有 (accessory 家族 + Gauge accessory 样式), macOS 不编译。

#if os(iOS)

private struct AccessoryCircularNowPlaying: View {
    let state: PlaybackState

    var body: some View {
        let total = max(state.duration, 0.01)
        let progress = state.duration > 0
            ? max(0, min(1, state.currentTime / total))
            : 0
        ZStack {
            if state.duration > 0 {
                Gauge(value: progress) {
                    Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
        }
        .widgetAccentable()
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryRectangularNowPlaying: View {
    let state: PlaybackState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .widgetAccentable()
                Text(state.songTitle ?? "未知歌曲")
                    .font(.headline)
                    .lineLimit(1)
            }
            Text(state.artistName ?? "未知艺术家")
                .font(.caption2)
                .lineLimit(1)
            if let album = state.albumTitle, !album.isEmpty {
                Text(album)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryInlineNowPlaying: View {
    let state: PlaybackState

    var body: some View {
        let title = state.songTitle ?? "未知歌曲"
        let artist = state.artistName ?? ""
        let symbol = state.isPlaying ? "play.fill" : "pause.fill"
        Label {
            if artist.isEmpty {
                Text(title)
            } else {
                Text("\(title) — \(artist)")
            }
        } icon: {
            Image(systemName: symbol)
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryCircularEmptyState: View {
    var body: some View {
        Image(systemName: "music.note")
            .font(.system(size: 22, weight: .semibold))
            .widgetAccentable()
            .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryRectangularEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .widgetAccentable()
                Text("猿音")
                    .font(.headline)
            }
            Text("点击开始播放")
                .font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryInlineEmptyState: View {
    var body: some View {
        Label("猿音 — 暂未播放", systemImage: "music.note")
            .containerBackground(for: .widget) { Color.clear }
    }
}

#endif

// MARK: - 共享原件

/// 极细单线进度条 ── 高 2.5pt, 半透明白 track + 实白 fill。比之前的
/// `WidgetProgressBar` 更克制,贴合 Apple Music widget 的视觉重量。
private struct ProgressLine: View {
    let value: TimeInterval
    let total: TimeInterval
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let progress: CGFloat = total > 0
                ? CGFloat(max(0, min(1, value / total)))
                : 0
            let track = colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)
            let fill = colorScheme == .dark ? Color.white : WidgetDesign.brandTint
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 2.5)
    }
}
