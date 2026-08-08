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
        let now = Date()
        let state = PlaybackState.load()
        let entry = NowPlayingEntry(date: now, state: state)

        // 进度推进交给视图层的 timerInterval(见 PlaybackProgress), 所以这里不再用
        // 固定 5 分钟周期 reload —— 那会让 entry.date 漂移、把自走进度锚点重置成
        // 倒退。播放 / 暂停 / 切歌等离散事件已由写入侧 reloadAllTimelines() 驱动重载,
        // entry.date 此刻才贴近 currentTime 的采样时刻。
        //
        // 唯一需要主动安排的 reload 是"歌曲自然播完"那一刻: 届时写入侧若(因 App 在
        // 后台等原因)没及时回写, 也要让 widget 翻到下一状态而不是停在满条。
        let policy: TimelineReloadPolicy
        if let state, state.isPlaying, state.duration > 0, state.currentTime < state.duration {
            let remaining = state.duration - max(0, state.currentTime)
            // 留 1s 余量, 避免边界抖动。
            let songEnd = now.addingTimeInterval(remaining + 1)
            policy = .after(songEnd)
        } else {
            // 暂停 / 无时长: 静态渲染, 等事件驱动重载即可。
            policy = .never
        }
        completion(Timeline(entries: [entry], policy: policy))
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
        .configurationDisplayName(PMString("ext.widget.nowPlaying.displayName"))
        .description(PMString("ext.widget.nowPlaying.description"))
        .supportedFamilies(families)
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state, state.currentSongID != nil {
            // entry.date 是这条 timeline 生成的时刻, 也就是 state.currentTime 被
            // 采样的时刻。播放中时用它把进度锚成绝对时间区间, 让系统自己推进, 无需
            // 频繁 reload。
            let progress = PlaybackProgress(state: state, referenceDate: entry.date)
            switch family {
            case .systemSmall: SmallNowPlayingView(state: state, progress: progress)
            case .systemMedium: MediumNowPlayingView(state: state, progress: progress)
            case .systemLarge: LargeNowPlayingView(state: state, progress: progress)
            #if os(iOS)
            case .accessoryCircular: AccessoryCircularNowPlaying(state: state, progress: progress)
            case .accessoryRectangular: AccessoryRectangularNowPlaying(state: state)
            case .accessoryInline: AccessoryInlineNowPlaying(state: state)
            #endif
            default: SmallNowPlayingView(state: state, progress: progress)
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

// MARK: - 进度推进模型
//
// 写入侧只在离散事件(play/pause/seek/切歌)时把 currentTime 写进 App Group,
// 连续播放时不会逐秒回写。所以单纯读 state.currentTime 会让进度整首歌冻结在开播
// 时刻。这里把"采样时刻(referenceDate=entry.date)+ 当时的 currentTime + duration"
// 还原成一段绝对时间区间, 交给 SwiftUI 的 timerInterval 视图自动推进, 系统会在
// 锁屏/桌面上平滑走条而无需我们频繁 reload timeline。
struct PlaybackProgress {
    /// 播放中且 duration 有效时, 用于驱动 timerInterval 视图的绝对时间区间。
    let timerRange: ClosedRange<Date>?
    /// 静态(暂停 / 无时长)渲染用的已播秒数。
    let elapsed: TimeInterval
    /// 总时长(<=0 表示未知)。
    let duration: TimeInterval

    init(state: PlaybackState, referenceDate: Date) {
        let elapsed = max(0, state.currentTime)
        let duration = state.duration
        self.elapsed = elapsed
        self.duration = duration

        if state.isPlaying, duration > 0, elapsed < duration {
            // currentTime 是 referenceDate 时刻的播放位置, 反推开播锚点。
            let start = referenceDate.addingTimeInterval(-elapsed)
            let end = start.addingTimeInterval(duration)
            self.timerRange = start <= end ? start...end : nil
        } else {
            self.timerRange = nil
        }
    }

    /// 静态进度比例(0...1), 暂停 / 无时长时用。
    var staticFraction: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, elapsed / duration)))
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
    let progress: PlaybackProgress

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
                Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(state.artistName ?? PMString("ext.widget.unknownArtist"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                if state.isLiveStream {
                    LiveIndicatorLine(lightText: true)
                        .padding(.top, 2)
                } else {
                    ProgressLine(progress: progress)
                        .padding(.top, 2)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MediumNowPlayingView: View {
    let state: PlaybackState
    let progress: PlaybackProgress

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

                        Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.86)
                        Text(state.artistName ?? PMString("ext.widget.unknownArtist"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)
                        Text(secondaryMetadata(state))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if state.isLiveStream {
                            LiveIndicatorLine()
                        } else {
                            VStack(spacing: 5) {
                                ProgressLine(progress: progress)
                                HStack {
                                    ElapsedTimeText(progress: progress)
                                    Spacer()
                                    Text(formatTime(state.duration))
                                }
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(WidgetDesign.tertiaryText)
                            }
                        }

                        NowPlayingControls(
                            symbols: state.isLiveStream
                                ? [state.isPlaying ? "stop.fill" : "play.fill"]
                                : ["heart", "backward.fill", state.isPlaying ? "pause.fill" : "play.fill", "forward.fill", "ellipsis"],
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
    let progress: PlaybackProgress

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
                            Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(WidgetDesign.strongText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                            Text(state.artistName ?? PMString("ext.widget.unknownArtist"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(WidgetDesign.secondaryText)
                                .lineLimit(1)
                            Text(secondaryMetadata(state))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(WidgetDesign.tertiaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 歌词面板的数据源 LyricsSnapshot 仅由 macOS 的
                    // MacWidgetDataPublisher.publishLyrics 写入 (调用点在
                    // PrimuseApp 的 #if os(macOS) 守卫内),iOS 从不写入,导致
                    // Large widget 歌词面板恒占位。先在 iOS 隐藏避免误导,
                    // 待 iOS 侧接通 LyricsSnapshot 写入后再放开。
                    #if os(macOS)
                    if !state.isLiveStream {
                        NowPlayingLyricsPreview(state: state)
                            .frame(maxWidth: .infinity)
                    }
                    #endif

                    if state.isLiveStream {
                        LiveIndicatorLine()
                    } else {
                        VStack(spacing: 6) {
                            ProgressLine(progress: progress)
                            HStack {
                                ElapsedTimeText(progress: progress)
                                Spacer()
                                Text(formatTime(state.duration))
                            }
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(WidgetDesign.tertiaryText)
                        }
                    }

                    NowPlayingControls(
                        symbols: state.isLiveStream
                            ? [state.isPlaying ? "stop.fill" : "play.fill"]
                            : ["shuffle", "backward.fill", state.isPlaying ? "pause.fill" : "play.fill", "forward.fill", "repeat", "heart", "ellipsis"],
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
            Image(systemName: state.isLiveStream ? "dot.radiowaves.left.and.right" : (state.isPlaying ? "waveform" : "pause.fill"))
                .font(.system(size: 9.5, weight: .bold))
            Text(verbatim: eyebrowText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(WidgetDesign.tertiaryText)
    }

    private var eyebrowText: String {
        if state.isLiveStream { return "LIVE" }
        let format = state.fileFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let format, !format.isEmpty {
            return PMString("ext.widget.nowPlaying.eyebrowFormat", format.uppercased())
        }
        return state.isPlaying ? PMString("ext.widget.nowPlaying.playing") : PMString("ext.widget.nowPlaying.paused")
    }
}

private func secondaryMetadata(_ state: PlaybackState) -> String {
    if state.isLiveStream {
        let format = state.fileFormat?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return format.isEmpty ? "LIVE" : format.uppercased()
    }
    return state.albumTitle?.isEmpty == false
        ? state.albumTitle!
        : PMString("ext.widget.unknownAlbum")
}

private struct LiveIndicatorLine: View {
    var lightText = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text(verbatim: "LIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(lightText ? Color.white.opacity(0.9) : WidgetDesign.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if symbol.contains("play") || symbol.contains("pause") || symbol.contains("stop") { return compact ? 12 : 16 }
        return compact ? 10.5 : 12.5
    }

    private func controlFrame(symbol: String) -> CGFloat {
        if symbol.contains("play") || symbol.contains("pause") || symbol.contains("stop") { return compact ? 26 : 34 }
        return compact ? 22 : 28
    }

    private func controlBackground(symbol: String) -> Color {
        if symbol.contains("play") || symbol.contains("pause") || symbol.contains("stop") {
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
            return [PMString("ext.widget.lyricsPreview.empty1"),
                    PMString("ext.widget.lyricsPreview.empty2"),
                    PMString("ext.widget.lyricsPreview.empty3")]
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
                Text(PMString("ext.widget.nowPlaying.empty.title"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WidgetDesign.strongText)
                Text(PMString("ext.widget.nowPlaying.empty.openShort"))
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
                    Text(PMString("ext.widget.nowPlaying.empty.title"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(WidgetDesign.strongText)
                    Text(PMString("ext.widget.nowPlaying.empty.openMedium"))
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
                    Text(PMString("ext.widget.nowPlaying.empty.title"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(WidgetDesign.strongText)
                    Text(PMString("ext.widget.nowPlaying.empty.openLarge"))
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
    let progress: PlaybackProgress

    var body: some View {
        ZStack {
            if state.isLiveStream {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 20, weight: .semibold))
            } else if let range = progress.timerRange {
                // 播放中: 用 timerInterval 环让系统自动推进, 中心叠波形图标。
                ProgressView(timerInterval: range, countsDown: false) {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
            } else if progress.duration > 0 {
                // 暂停但有时长: 静态环停在当前比例。
                Gauge(value: progress.staticFraction) {
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
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: state.isLiveStream ? "dot.radiowaves.left.and.right" : (state.isPlaying ? "waveform" : "pause.fill"))
                        .font(.system(size: 11, weight: .semibold))
                        .widgetAccentable()
                    Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(state.artistName ?? PMString("ext.widget.unknownArtist"))
                    .font(.caption2)
                    .lineLimit(1)
                if state.isLiveStream {
                    Text(verbatim: "LIVE")
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                } else if let album = state.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 直播流不入库, 没有"喜欢"可言。
            if !state.isLiveStream, state.currentSongID != nil {
                AccessoryLikeToggle(isLiked: state.isLiked ?? false)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

/// 锁屏 accessory 上的喜欢按钮。
///
/// 用 `Toggle` 而不是 `Button`: SwiftUI 会在 `perform()` 跑完前先把心填上
/// (乐观更新), 点下去即刻有反馈, 不必等唤醒主 app 的往返。intent conform
/// `AudioPlaybackIntent`, 系统会把 perform() 路由到主 app 进程。
private struct AccessoryLikeToggle: View {
    let isLiked: Bool

    var body: some View {
        Toggle(isOn: isLiked, intent: PrimuseSetLikedIntent(value: !isLiked)) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .widgetAccentable()
        .accessibilityLabel(PMString(isLiked ? "ext.widget.unlike" : "ext.widget.like"))
    }
}

private struct AccessoryInlineNowPlaying: View {
    let state: PlaybackState

    var body: some View {
        let title = state.songTitle ?? PMString("ext.widget.unknownSong")
        let artist = state.artistName ?? ""
        let symbol = state.isLiveStream
            ? "dot.radiowaves.left.and.right"
            : (state.isPlaying ? "play.fill" : "pause.fill")
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
                Text(PMString("ext.widget.appName"))
                    .font(.headline)
            }
            Text(PMString("ext.widget.nowPlaying.empty.tapToPlay"))
                .font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}

private struct AccessoryInlineEmptyState: View {
    var body: some View {
        Label(PMString("ext.widget.nowPlaying.empty.inline"), systemImage: "music.note")
            .containerBackground(for: .widget) { Color.clear }
    }
}

#endif

// MARK: - 共享原件

/// 已播时长标签 ── 播放中用 `Text(timerInterval:)` 让系统逐秒推进, 暂停 / 无时长时
/// 落回静态 `formatTime`。字体 / 配色由外层 `.font` / `.foregroundStyle` 决定, 与
/// 旁边的总时长标签保持一致。
private struct ElapsedTimeText: View {
    let progress: PlaybackProgress

    var body: some View {
        if let range = progress.timerRange {
            // showsHours=false → m:ss; 从区间起点正向计时, 即已播秒数。
            Text(timerInterval: range, countsDown: false, showsHours: false)
                .monospacedDigit()
        } else {
            Text(formatTime(progress.elapsed))
        }
    }
}

/// 极细单线进度条 ── 高 2.5pt, 半透明白 track + 实白 fill。比之前的
/// `WidgetProgressBar` 更克制,贴合 Apple Music widget 的视觉重量。
///
/// 播放中走 `ProgressView(timerInterval:)`, 由系统逐帧推进; 暂停 / 无时长时落回
/// 静态比例渲染。两条路径都套同一个 `HairlineProgressStyle`, 视觉完全一致。
private struct ProgressLine: View {
    let progress: PlaybackProgress
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let track = colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)
        let fill = colorScheme == .dark ? Color.white : WidgetDesign.brandTint
        Group {
            if let range = progress.timerRange {
                ProgressView(timerInterval: range, countsDown: false)
                    .labelsHidden()
            } else {
                ProgressView(value: progress.staticFraction)
            }
        }
        .progressViewStyle(HairlineProgressStyle(track: track, fill: fill))
        .frame(height: 2.5)
    }
}

/// 把 `ProgressView`(无论 value 还是 timerInterval 形态)渲染成 2.5pt 细 capsule,
/// 复用原 `ProgressLine` 的 track/fill 配色。
private struct HairlineProgressStyle: ProgressViewStyle {
    let track: Color
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            // timerInterval 形态下 fractionCompleted 由系统逐帧推进; value 形态下
            // 取传入的静态比例。两者都收敛到 0...1。
            let fraction = CGFloat(max(0, min(1, configuration.fractionCompleted ?? 0)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2.5)
    }
}
