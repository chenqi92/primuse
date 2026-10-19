import SwiftUI
import WidgetKit
import AppIntents
import PrimuseKit

struct NowPlayingProvider: TimelineProvider {
    /// 时间线带歌词的尺寸: 「正在播放」只有大号画歌词, 经典款的中号还写正唱到的那一句。
    var lyricFamilies: [WidgetFamily] = [.systemLarge]

    func placeholder(in context: Context) -> NowPlayingEntry {
        let now = Date()
        return NowPlayingEntry(
            date: now,
            playbackElapsed: Self.demoState.currentTime,
            playbackReferenceDate: now,
            state: Self.demoState,
            lyricsSnapshot: LyricsProvider.demo
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        // 系统 widget 画廊用 isPreview=true 调这里 —— 用户还没添加 widget,
        // 实际 PlaybackState 大概率是空, 渲染"尚未播放"空状态会让画廊看起来
        // 像功能没做完。预览阶段一律喂 demo 数据,真实使用时才走 App Group。
        let now = Date()
        if context.isPreview {
            completion(NowPlayingEntry(
                date: now,
                playbackElapsed: Self.demoState.currentTime,
                playbackReferenceDate: now,
                state: Self.demoState,
                lyricsSnapshot: LyricsProvider.demo
            ))
        } else {
            let loadedState = PlaybackState.load()
            let lyrics = lyricsSnapshot(for: loadedState, family: context.family)
            let state = WidgetLyricsPresentationPolicy.playbackStateAlignedWithLyrics(
                loadedState,
                lyrics: lyrics
            )
            let sample = Self.playbackSample(for: state, lyrics: lyrics, capturedAt: now)
            completion(NowPlayingEntry(
                date: now,
                playbackElapsed: sample.elapsed,
                playbackReferenceDate: sample.referenceDate,
                state: state,
                lyricsSnapshot: lyrics
            ))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Date()
        let loadedState = PlaybackState.load()
        let lyrics = lyricsSnapshot(for: loadedState, family: context.family)
        let state = WidgetLyricsPresentationPolicy.playbackStateAlignedWithLyrics(
            loadedState,
            lyrics: lyrics
        )
        let sample = Self.playbackSample(for: state, lyrics: lyrics, capturedAt: now)
        let lyricsBatch = lyrics.map { LyricsProvider.timelineBatch(for: $0, from: now) }
        let entries = lyricsBatch?.entries.map { lyricEntry in
            NowPlayingEntry(
                date: lyricEntry.date,
                playbackElapsed: sample.elapsed,
                playbackReferenceDate: sample.referenceDate,
                state: state,
                lyricsSnapshot: lyricEntry.snapshot
            )
        } ?? [NowPlayingEntry(
            date: now,
            playbackElapsed: sample.elapsed,
            playbackReferenceDate: sample.referenceDate,
            state: state,
            lyricsSnapshot: nil
        )]

        // 进度推进交给视图层的 timerInterval(见 PlaybackProgress), 所以这里不再用
        // 固定 5 分钟周期 reload —— 那会让 entry.date 漂移、把自走进度锚点重置成
        // 倒退。播放 / 暂停 / 切歌等离散事件已由写入侧 reloadAllTimelines() 驱动重载,
        // entry.date 此刻才贴近 currentTime 的采样时刻。
        //
        // 唯一需要主动安排的 reload 是"歌曲自然播完"那一刻: 届时写入侧若(因 App 在
        // 后台等原因)没及时回写, 也要让 widget 翻到下一状态而不是停在满条。
        var reloadDates: [Date] = []
        if let state, state.isPlaying, state.duration > 0 {
            let positionNow = sample.elapsed
                + max(0, now.timeIntervalSince(sample.referenceDate))
            if positionNow < state.duration {
                let remaining = state.duration - max(0, positionNow)
                // 留 1s 余量, 避免边界抖动。
                reloadDates.append(now.addingTimeInterval(remaining + 1))
            }
        }
        if let nextLyricsBatch = lyricsBatch?.nextReloadDate {
            reloadDates.append(nextLyricsBatch)
        }
        let policy: TimelineReloadPolicy
        if let nextReloadDate = reloadDates.min() {
            policy = .after(nextReloadDate)
        } else {
            // 暂停 / 无时长: 静态渲染, 等事件驱动重载即可。
            policy = .never
        }
        completion(Timeline(entries: entries, policy: policy))
    }

    private func lyricsSnapshot(
        for state: PlaybackState?,
        family: WidgetFamily
    ) -> LyricsSnapshot? {
        guard lyricFamilies.contains(family),
              let songID = state?.currentSongID,
              let snapshot = LyricsProvider.snapshotAlignedWithPlayback(
                LyricsSnapshot.load(),
                playback: state
              ),
              snapshot.songID == songID,
              !snapshot.lines.isEmpty else {
            return nil
        }
        return snapshot
    }

    /// A lyric snapshot carries an exact playback sample and its capture time.
    /// Reusing that pair keeps the progress clock stable when WidgetKit asks
    /// for the next bounded lyric batch. Older snapshots fall back to the
    /// playback state captured for this timeline.
    private static func playbackSample(
        for state: PlaybackState?,
        lyrics: LyricsSnapshot?,
        capturedAt now: Date
    ) -> (elapsed: TimeInterval, referenceDate: Date) {
        guard let state else { return (0, now) }
        let stateSample = (state.currentTime, state.updatedAt ?? now)
        guard let lyrics,
              lyrics.songID == state.currentSongID,
              lyrics.isPlaying == state.isPlaying,
              let position = lyrics.playbackPosition else {
            return stateSample
        }
        if let stateUpdatedAt = state.updatedAt,
           stateUpdatedAt > lyrics.updatedAt {
            return stateSample
        }
        return (position, lyrics.updatedAt)
    }

    /// 画廊预览 / placeholder 用的假数据 —— 让 widget 在用户挑选时就能
    /// 看到"长大后是啥样",而不是空 state。
    fileprivate static let demoState = PlaybackState(
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
    /// Playback position sampled at `playbackReferenceDate`.
    let playbackElapsed: TimeInterval
    /// The playback sample stays fixed while lyric-only entries advance.
    let playbackReferenceDate: Date
    let state: PlaybackState?
    let lyricsSnapshot: LyricsSnapshot?
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
            // 歌词时间线会分批续载，因此播放位置与其采样时刻由 entry 独立携带；
            // 续批不能拿新的 entry.date 重新锚定旧位置，否则进度会周期性回跳。
            let progress = PlaybackProgress(
                state: state,
                elapsed: entry.playbackElapsed,
                referenceDate: entry.playbackReferenceDate
            )
            switch family {
            case .systemSmall: SmallNowPlayingView(state: state, progress: progress)
            case .systemMedium: MediumNowPlayingView(state: state, progress: progress)
            case .systemLarge: LargeNowPlayingView(
                state: state,
                progress: progress,
                lyricsSnapshot: entry.lyricsSnapshot
            )
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

    init(state: PlaybackState, elapsed: TimeInterval, referenceDate: Date) {
        let elapsed = max(0, elapsed)
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

private struct SmallNowPlayingView: View {
    let state: PlaybackState
    let progress: PlaybackProgress

    var body: some View {
        WidgetCanvas {
            GeometryReader { geometry in
                // 封面一排 52、歌名两行约 36、歌手约 14、进度条, 加上间距共约 126pt; iPad mini 与 4.7 寸 iPhone
                // 小号的内容只有 109 / 116pt 高: 歌名先收成一行(约 108pt), 还不够(直播那一行更高)再把封面压矮。
                let footer: CGFloat = state.isLiveStream ? 12 : 2.5
                let titleLines = geometry.size.height >= 123.5 + footer ? 2 : 1
                let textHeight: CGFloat = titleLines == 2 ? 71.5 : 53.5
                let artworkHeight: CGFloat = min(52, max(34, geometry.size.height - footer - textHeight))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        WidgetPlaybackArtwork(state: state)
                            .frame(width: artworkHeight * 62 / 52, height: artworkHeight)
                        Spacer(minLength: 8)
                        WidgetPlaybackButton(state: state, size: min(36, artworkHeight))
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(titleLines)
                        Text(nowPlayingSubtitle(state))
                            .font(.system(size: 12))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)
                    }
                    if state.isLiveStream { LiveIndicatorLine() }
                    else { ProgressLine(progress: progress) }
                }
                .widgetBounds(geometry.size)
            }
        }
    }
}

private struct MediumNowPlayingView: View {
    let state: PlaybackState
    let progress: PlaybackProgress

    var body: some View {
        WidgetCanvas {
            GeometryReader { geometry in
                let side = min(112, geometry.size.height)
                // 右栏: 歌名两行约 43、歌手、进度、一排 32 高的键, 加上间距共约 117pt; iPad mini 与 4.7 寸
                // iPhone 中号的内容只有 109 / 116pt 高, 歌名收成一行, 不再把底下的键裁掉。
                let footer: CGFloat = state.isLiveStream ? 12 : 2.5
                let titleLines = geometry.size.height >= 114.5 + footer ? 2 : 1
                HStack(spacing: 16) {
                    WidgetPlaybackArtwork(state: state)
                        .frame(width: side, height: side)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(titleLines).minimumScaleFactor(0.88)
                        Text(nowPlayingSubtitle(state))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WidgetDesign.secondaryText).lineLimit(1)
                        Spacer(minLength: 0)
                        if state.isLiveStream { LiveIndicatorLine() }
                        else { ProgressLine(progress: progress) }
                        NowPlayingControls(state: state, compact: true)
                    }
                }
                .widgetBounds(geometry.size, alignment: .leading)
            }
        }
    }
}

private struct LargeNowPlayingView: View {
    let state: PlaybackState
    let progress: PlaybackProgress
    let lyricsSnapshot: LyricsSnapshot?

    var body: some View {
        WidgetCanvas(padding: 18) {
            GeometryReader { geometry in
                // 宽度上照旧按整块宽(含两边 18 的边距)的 42% 取。封面以下: 三段间距 39、进度和时长 21、
                // 一排 40 高的键, 再给歌词 / 读书进度至少留 48(读书进度最紧的一档), 共 148pt。iPad mini 大号
                // 内容只有 269.5pt 高, 封面从 128 收到约 121, 4.7 寸 iPhone 约 135, 再大的 iPhone 照旧 138。
                let widthSide: CGFloat = max(118, (geometry.size.width + 36) * 0.42)
                let coverSide: CGFloat = max(80, min(138, widthSide, geometry.size.height - 148))
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .top, spacing: 14) {
                        WidgetPlaybackArtwork(state: state)
                            .frame(width: coverSide, height: coverSide)

                        VStack(alignment: .leading, spacing: 6) {
                            NowPlayingEyebrow(state: state)
                            Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(WidgetDesign.strongText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.82)
                            Text(nowPlayingSubtitle(state))
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

                    if let spokenWord = state.spokenWord, state.isSpokenWord {
                        // 有声内容几乎没有歌词, 这块换成整本书的进度。
                        SpokenWordBookProgressPanel(info: spokenWord)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    } else if !state.isLiveStream {
                        NowPlayingLyricsPreview(snapshot: lyricsSnapshot)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    }

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

                    NowPlayingControls(state: state, compact: false, availableWidth: geometry.size.width)
                }
                .widgetBounds(geometry.size, alignment: .topLeading)
            }
        }
    }
}

private struct NowPlayingEyebrow: View {
    let state: PlaybackState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: nowPlayingSymbol(state))
                .font(.system(size: 9.5, weight: .bold))
            Text(verbatim: eyebrowText)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(WidgetDesign.tertiaryText)
    }

    private var eyebrowText: String {
        if state.isLiveStream { return PMString("ext.widget.live") }
        if state.isSpokenWord {
            return PMString(state.isPlaying ? "ext.widget.spokenWord.listening" : "ext.widget.nowPlaying.paused")
        }
        let format = state.fileFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let format, !format.isEmpty {
            // 暂停时图标已经是 pause, 文案不能还写着"正在播放 · DTS"。
            return PMString(
                state.isPlaying
                    ? "ext.widget.nowPlaying.eyebrowFormat"
                    : "ext.widget.nowPlaying.pausedEyebrowFormat",
                format.uppercased()
            )
        }
        return state.isPlaying ? PMString("ext.widget.nowPlaying.playing") : PMString("ext.widget.nowPlaying.paused")
    }
}

/// 标题下面那一行: 音乐是艺人, 有声内容是书名。
private func nowPlayingSubtitle(_ state: PlaybackState) -> String {
    if state.isSpokenWord, let spokenWord = state.spokenWord {
        let book = spokenWord.bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !book.isEmpty { return book }
    }
    return state.artistName ?? PMString("ext.widget.unknownArtist")
}

private func nowPlayingSymbol(_ state: PlaybackState) -> String {
    if state.isLiveStream { return ListeningSpace.radio.systemImage }
    if !state.isPlaying { return "pause.fill" }
    return state.isSpokenWord ? state.listeningSpace.systemImage : "waveform"
}

/// 「第 3/12 章」, 书只有一部分时为 nil。
private func spokenWordPartText(_ info: SpokenWordPlaybackInfo) -> String? {
    guard let index = info.partIndex, let count = info.partCount, count > 1 else { return nil }
    return PMString("ext.widget.spokenWord.partFormat", index, count)
}

/// 「剩 5 小时 12 分」。
func spokenWordRemainingText(_ remaining: TimeInterval?) -> String? {
    guard let remaining, remaining.isFinite, remaining >= 60 else { return nil }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute]
    formatter.maximumUnitCount = 2
    guard let text = formatter.string(from: remaining) else { return nil }
    return PMString("ext.widget.spokenWord.remainingFormat", text)
}

private func secondaryMetadata(_ state: PlaybackState) -> String {
    if state.isSpokenWord, let spokenWord = state.spokenWord {
        let parts = [spokenWord.bookAuthor, spokenWordPartText(spokenWord)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return state.artistName ?? ""
    }
    if state.isLiveStream {
        let format = state.fileFormat?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return format.isEmpty ? PMString("ext.widget.live") : format.uppercased()
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
            Text(verbatim: PMString("ext.widget.live"))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(lightText ? Color.white.opacity(0.9) : WidgetDesign.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NowPlayingControls: View {
    let state: PlaybackState
    var compact: Bool
    /// 「正在播放(经典)」那套: 按钮小一号, 次要按钮垫浅底、带一圈细线。
    var classic = false
    /// 这一排能占的宽度; 给了就在放不下时把大号的间距收窄。
    var availableWidth: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let spokenWord = state.spokenWord, state.isSpokenWord {
            spokenWordControls(spokenWord)
        } else {
            musicControls
        }
    }

    /// 听书: 后退、播放 / 暂停、前进; 随机、循环、喜欢对一本书没有意义。
    private func spokenWordControls(_ info: SpokenWordPlaybackInfo) -> some View {
        HStack(spacing: compact ? 12 : 22) {
            Button(intent: PrimuseSkipBackwardIntent()) {
                controlIcon(symbol: info.skipBackwardSymbol)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PMString("ext.widget.spokenWord.skipBackFormat", info.skipBackwardSeconds))

            // The icon shows the last snapshot; ask for the state it shows, so a
            // stale snapshot can never turn "play" into a pause.
            Button(intent: PrimuseSetPlayingIntent(value: !state.isPlaying)) {
                controlIcon(symbol: state.isPlaying ? "pause.fill" : "play.fill", prominent: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PMString(state.isPlaying ? "ext.control.pause" : "ext.control.play"))

            Button(intent: PrimuseSkipForwardIntent()) {
                controlIcon(symbol: info.skipForwardSymbol)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PMString("ext.widget.spokenWord.skipForwardFormat", info.skipForwardSeconds))
        }
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
    }

    private var musicControls: some View {
        HStack(spacing: compact ? 10 : fullSpacing) {
            if !state.isLiveStream, !compact {
                Button(intent: PrimuseShuffleAllIntent()) {
                    controlIcon(symbol: "shuffle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PMString("ext.control.shuffle"))
            }

            if !state.isLiveStream, compact, state.currentSongID != nil {
                likeToggle
            }

            if !state.isLiveStream {
                Button(intent: PrimusePreviousIntent()) {
                    controlIcon(symbol: "backward.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PMString("ext.control.previous"))
            }

            Button(intent: PrimuseSetPlayingIntent(value: !state.isPlaying)) {
                controlIcon(
                    symbol: state.isPlaying ? (state.isLiveStream ? "stop.fill" : "pause.fill") : "play.fill",
                    prominent: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PMString(state.isPlaying ? "ext.control.pause" : "ext.control.play"))

            if !state.isLiveStream {
                Button(intent: PrimuseNextIntent()) {
                    controlIcon(symbol: "forward.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PMString("ext.control.next"))

                if !compact {
                    Button(intent: PrimuseSetRepeatModeIntent(mode: nextRepeatMode)) {
                        controlIcon(
                            symbol: (state.repeatMode ?? .off) == .one ? "repeat.1" : "repeat",
                            active: (state.repeatMode ?? .off) != .off
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PMString("repeat"))

                    if state.currentSongID != nil {
                        likeToggle
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
    }

    private var likeToggle: some View {
        let isLiked = state.isLiked ?? false
        return Toggle(isOn: isLiked, intent: PrimuseSetLikedIntent(value: !isLiked)) {
            controlIcon(symbol: isLiked ? "heart.fill" : "heart", active: isLiked)
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(PMString(isLiked ? "ext.widget.unlike" : "ext.widget.like"))
    }

    private var nextRepeatMode: PrimuseIntentRepeatMode {
        switch state.repeatMode ?? .off {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    /// 大号六个键(普通款 40 + 32×5、经典款 34 + 28×5)按 14 的间距排; iPad mini 大号内容只有 269.5pt 宽,
    /// 普通款要 270, 放不下时把间距平均收窄。
    private var fullSpacing: CGFloat {
        guard let availableWidth else { return 14 }
        let keys: CGFloat = classic ? 34 + 28 * 5 : 40 + 32 * 5
        return max(8, min(14, (availableWidth - keys) / 5))
    }

    /// 播放 / 暂停是中性的毛玻璃键(#320), 不跟主题色; 打开的循环、喜欢仍按「屏幕小组件颜色」染色。
    private func controlIcon(symbol: String, prominent: Bool = false, active: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: controlSize(symbol: symbol), weight: .semibold))
            .foregroundStyle(active ? WidgetDesign.brandTint : WidgetDesign.strongText)
            .widgetAccentable(prominent || active)
            .frame(width: controlFrame(symbol: symbol), height: controlFrame(symbol: symbol))
            .background {
                if prominent {
                    WidgetGlassKeyBackground()
                } else {
                    Circle().fill(controlBackground(active: active))
                }
            }
            .overlay {
                if classic, !prominent {
                    Circle().strokeBorder(WidgetDesign.hairline, lineWidth: 1)
                }
            }
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }

    private func controlSize(symbol: String) -> CGFloat {
        if symbol.contains("play") || symbol.contains("pause") || symbol.contains("stop") { return compact ? 12 : 16 }
        return compact ? 10.5 : 12.5
    }

    private func controlFrame(symbol: String) -> CGFloat {
        let isPrimary = symbol.contains("play") || symbol.contains("pause") || symbol.contains("stop")
        if classic { return isPrimary ? (compact ? 26 : 34) : (compact ? 22 : 28) }
        if isPrimary { return compact ? 32 : 40 }
        return compact ? 26 : 32
    }

    private func controlBackground(active: Bool) -> Color {
        if active {
            return WidgetDesign.brandTint.opacity(0.22)
        }
        return classic ? Color.primary.opacity(0.06) : .clear
    }
}

/// 大号小组件里给有声内容的那一块: 整本书读到哪里、还剩多久。
private struct SpokenWordBookProgressPanel: View {
    let info: SpokenWordPlaybackInfo

    var body: some View {
        // 封面以下留给这块的高度从 iPad mini 的约 48 到大 iPhone 的 100 多不等: 排得下才带上标题和第几章
        // (第几章在封面旁那一栏也写着), 最紧时只留百分比和进度条, 不再把底下的键挤出去。
        ViewThatFits(in: .vertical) {
            panel(showsLabel: true, showsPart: true)
            panel(showsLabel: true, showsPart: false)
            panel(showsLabel: false, showsPart: false)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func panel(showsLabel: Bool, showsPart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsLabel {
                Label {
                    Text(verbatim: PMString("ext.widget.spokenWord.bookProgress"))
                } icon: {
                    Image(systemName: "book.closed.fill")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WidgetDesign.tertiaryText)
            }

            if let fraction = info.bookFraction {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(WidgetDesign.strongText)
                        .monospacedDigit()
                    if let remaining = spokenWordRemainingText(info.bookRemaining) {
                        Text(verbatim: remaining)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WidgetDesign.secondaryText)
                            .lineLimit(1)
                    }
                }
                ProgressView(value: min(1, max(0, fraction)))
                    .progressViewStyle(.linear)
                    .tint(WidgetDesign.brandTint)
                    .frame(height: 2.5)
            }
            if showsPart, let part = spokenWordPartText(info) {
                Text(verbatim: part)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetDesign.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct NowPlayingLyricsPreview: View {
    let snapshot: LyricsSnapshot?

    var body: some View {
        Group {
            if let snapshot, !snapshot.lines.isEmpty {
                AdaptiveWidgetLyricsView(
                    lines: snapshot.lines,
                    anchorIndex: snapshot.anchorIndex,
                    preferredDirection: snapshot.writingDirection,
                    typography: .compact
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // 没有歌词时不再把提示文案当成三行"假歌词"渲染(中间一行会被当作
                // 当前句加粗), 而是一段安静的占位说明。
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: PMString("ext.widget.lyricsPreview.empty1"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(WidgetDesign.secondaryText)
                    Text(verbatim: PMString("ext.widget.lyricsPreview.empty2"))
                    Text(verbatim: PMString("ext.widget.lyricsPreview.empty3"))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(WidgetDesign.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .clipped()
        .padding(.vertical, 4)

    }
}

// MARK: - 空状态 (极简: 单 icon + 一行)

private struct SmallEmptyStateView: View {
    var body: some View {
        WidgetEmptyState(symbol: "music.note", title: PMString("ext.widget.nowPlaying.empty.title"),
                         subtitle: PMString("ext.widget.nowPlaying.empty.openShort"))
    }
}
private typealias MediumEmptyStateView = SmallEmptyStateView
private typealias LargeEmptyStateView = SmallEmptyStateView

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
                Image(systemName: state.isSpokenWord ? state.listeningSpace.systemImage : "waveform")
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
                    Image(systemName: nowPlayingSymbol(state))
                        .font(.system(size: 11, weight: .semibold))
                        .widgetAccentable()
                    Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(nowPlayingSubtitle(state))
                    .font(.caption2)
                    .lineLimit(1)
                if state.isSpokenWord, let spokenWord = state.spokenWord {
                    let detail = spokenWordPartText(spokenWord) ?? spokenWord.bookAuthor ?? ""
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                } else if state.isLiveStream {
                    Text(verbatim: PMString("ext.widget.live"))
                        .font(.caption2.weight(.bold))
                        .lineLimit(1)
                } else if let album = state.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 直播流不入库, 没有"喜欢"可言; 书也不进「我喜欢」。
            if !state.isLiveStream, !state.isSpokenWord, state.currentSongID != nil {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isLiked: Bool

    var body: some View {
        Toggle(isOn: isLiked, intent: PrimuseSetLikedIntent(value: !isLiked)) {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
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
        let artist = state.isSpokenWord ? nowPlayingSubtitle(state) : (state.artistName ?? "")
        let symbol = state.isLiveStream
            ? ListeningSpace.radio.systemImage
            : (state.isPlaying ? (state.isSpokenWord ? state.listeningSpace.systemImage : "play.fill") : "pause.fill")
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

// MARK: - 封面播放(#143)
//
// 大封面、模糊封面铺底, 只留歌名、歌手和上一首 / 播放 / 下一首。和「正在播放」并列成
// 另一款让用户在小组件库里挑: 那款信息全(进度、格式、喜欢、歌词), 这款只求好看好按。
// 数据、封面文件、按钮意图都和「正在播放」同一套; 写入侧 reloadAllTimelines 一并刷新。

struct CoverPlayerWidget: Widget {
    let kind = "CoverPlayerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CoverPlayerProvider()) { entry in
            CoverPlayerWidgetView(entry: entry)
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.coverPlayer.displayName"))
        .description(PMString("ext.widget.coverPlayer.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// 不带歌词: 时间线只有一条, 播放中只在这首自然播完时翻一次, 其余等写入侧刷新。
struct CoverPlayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        Self.entry(state: NowPlayingProvider.demoState, at: Date(), sampledAt: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let now = Date()
        completion(context.isPreview
            ? Self.entry(state: NowPlayingProvider.demoState, at: now, sampledAt: nil)
            : Self.currentEntry(at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Date()
        let entry = Self.currentEntry(at: now)
        var policy = TimelineReloadPolicy.never
        if let state = entry.state, state.isPlaying, state.duration > 0 {
            let position = entry.playbackElapsed + max(0, now.timeIntervalSince(entry.playbackReferenceDate))
            if position < state.duration {
                policy = .after(now.addingTimeInterval(state.duration - max(0, position) + 1))
            }
        }
        completion(Timeline(entries: [entry], policy: policy))
    }

    private static func currentEntry(at now: Date) -> NowPlayingEntry {
        let state = PlaybackState.load()
        return entry(state: state, at: now, sampledAt: state?.updatedAt)
    }

    private static func entry(state: PlaybackState?, at now: Date, sampledAt: Date?) -> NowPlayingEntry {
        NowPlayingEntry(
            date: now,
            playbackElapsed: state?.currentTime ?? 0,
            playbackReferenceDate: sampledAt ?? now,
            state: state,
            lyricsSnapshot: nil
        )
    }
}

struct CoverPlayerWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state, state.currentSongID != nil {
            let progress = PlaybackProgress(
                state: state,
                elapsed: entry.playbackElapsed,
                referenceDate: entry.playbackReferenceDate
            )
            let prefersFullBleed = WidgetPlayerArtworkStyleStore.prefersFullBleed()
            switch family {
            case .systemMedium: CoverPlayerMediumView(state: state, prefersFullBleed: prefersFullBleed)
            case .systemLarge: CoverPlayerLargeView(
                state: state,
                progress: progress,
                prefersFullBleed: prefersFullBleed
            )
            default: CoverPlayerSmallView(state: state, prefersFullBleed: prefersFullBleed)
            }
        } else {
            SmallEmptyStateView()
        }
    }
}

/// 播放页封面选了「铺满」, 而且这一条铺得了: 全彩外观(色调、透明外观下系统换掉整块底, 封面只能
/// 摆在内容里)、有封面、是音乐(播放页给有声书、播客和电台一直用卡片)。
private func coverPlayerBleeds(
    _ state: PlaybackState,
    prefersFullBleed: Bool,
    renderingMode: WidgetRenderingMode
) -> Bool {
    prefersFullBleed
        && renderingMode == .fullColor
        && state.coverImageName?.isEmpty == false
        && state.listeningSpace == .music
}

/// 清晰的封面怎么铺在底上。卡片样式只有模糊封面; 铺满时封面贴着小组件的边画, 靠里的一侧渐隐进
/// 模糊封面, 和播放页「封面样式 › 铺满」一样连成一整块。
private enum CoverPlayerBleed {
    case none
    /// 整块就是封面, 下半截压暗(小号, 以及经典款的小号)。
    case whole
    /// 中号: 左边一块, 往右渐隐。
    case leading
    /// 大号: 上面一截铺满整宽, 往下渐隐。
    case top
}

private enum CoverPlayerBleedMetrics {
    /// 中号比整高略宽, 右栏的字照卡片样式的位置排, 正好压在渐隐的尾巴上。
    static func leadingWidth(in size: CGSize) -> CGFloat {
        min(size.height * 1.15, size.width * 0.6)
    }
    static let leadingFadeStart: CGFloat = 0.55

    /// 大号往下留出歌名、进度和按钮那一截(连下边距约 128pt), 渐隐差不多在歌名顶上收完:
    /// 封面下沿常有字, 半透明地叠在歌名后面会显得脏。
    static func topHeight(in size: CGSize) -> CGFloat {
        max(size.height * 0.55, size.height - 110)
    }
    static let topFadeStart: CGFloat = 0.5

    /// 渐隐按 smoothstep 取几个点, 不留硬边。
    static func fadeStops(from start: CGFloat) -> [Gradient.Stop] {
        let span = 1 - start
        return [
            .init(color: .black, location: start),
            .init(color: .black.opacity(0.84), location: start + span * 0.25),
            .init(color: .black.opacity(0.5), location: start + span * 0.5),
            .init(color: .black.opacity(0.16), location: start + span * 0.75),
            .init(color: .black.opacity(0), location: 1),
        ]
    }
}

/// 封面铺底一律是深色: 全彩外观下字和按钮按深色画, 浅色模式下也是白字。色调、透明外观下
/// 系统会换掉整块底, 那时照系统的来。
private struct CoverPlayerCanvas<Content: View>: View {
    let state: PlaybackState
    var padding: CGFloat = 14
    var bleed: CoverPlayerBleed = .none
    let content: Content
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    init(state: PlaybackState, padding: CGFloat = 14, bleed: CoverPlayerBleed = .none,
         @ViewBuilder content: () -> Content) {
        self.state = state
        self.padding = padding
        self.bleed = bleed
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, renderingMode == .fullColor ? .dark : colorScheme)
            .containerBackground(for: .widget) {
                CoverPlayerBackdrop(coverImageName: state.coverImageName, bleed: bleed)
            }
    }
}

private struct CoverPlayerBackdrop: View {
    let coverImageName: String?
    var bleed: CoverPlayerBleed = .none
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    WidgetDesign.canvasBase
                    if let coverImageName, !coverImageName.isEmpty {
                        if bleed == .whole {
                            WidgetCoverImageView(coverImageName: coverImageName, cornerRadius: 0, outlined: false)
                                .frame(width: size.width, height: size.height)
                            // 整块就是封面: 下半截压暗, 字和按钮压在上面。
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0), location: 0.30),
                                    .init(color: .black.opacity(0.72), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        } else {
                            WidgetCoverImageView(coverImageName: coverImageName, cornerRadius: 0)
                                .frame(width: size.width, height: size.height)
                                .scaleEffect(1.35)
                                .blur(radius: 30)
                                .saturation(1.25)
                            // 浅色封面上白字也要读得清。
                            LinearGradient(
                                colors: [.black.opacity(0.22), .black.opacity(0.48)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            sharpBleed(coverImageName, in: size)
                        }
                    } else {
                        // 单色时中性色在这块深底上是白的, 压到 0.16 才不把白字衬没。
                        LinearGradient(
                            colors: [
                                WidgetDesign.prefersMonochrome
                                    ? Color.white.opacity(0.16)
                                    : WidgetDesign.brandTint.opacity(0.55),
                                WidgetDesign.canvasBase,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }

    /// 铺满时压在模糊底上的那张清晰封面。先按自己那一块定框、裁掉, 再套渐隐蒙版。
    @ViewBuilder
    private func sharpBleed(_ coverImageName: String, in size: CGSize) -> some View {
        switch bleed {
        case .leading:
            WidgetCoverImageView(coverImageName: coverImageName, cornerRadius: 0, outlined: false)
                .frame(width: CoverPlayerBleedMetrics.leadingWidth(in: size), height: size.height)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: CoverPlayerBleedMetrics.fadeStops(from: CoverPlayerBleedMetrics.leadingFadeStart),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
        case .top:
            let height = CoverPlayerBleedMetrics.topHeight(in: size)
            // 方封面按整宽画、贴着顶边, 多出来的下半截落在渐隐段里裁掉。
            WidgetCoverImageView(coverImageName: coverImageName, cornerRadius: 0, outlined: false)
                .frame(width: size.width, height: max(size.width, height))
                .frame(width: size.width, height: height, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(
                        stops: CoverPlayerBleedMetrics.fadeStops(from: CoverPlayerBleedMetrics.topFadeStart),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            // 歌名和进度压在渐隐的尾巴上, 底下再压暗一层。
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0.5),
                    .init(color: .black.opacity(0.4), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .none, .whole:
            EmptyView()
        }
    }
}

private struct CoverPlayerArtwork: View {
    let state: PlaybackState
    var cornerRadius: CGFloat = 14

    var body: some View {
        // 封面按填满缩放, 不是方的会比框大: 先占住方框再把它叠上去裁掉, 别让它撑开布局。
        Color.clear
            .overlay {
                WidgetCoverImageView(coverImageName: state.coverImageName, cornerRadius: cornerRadius)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.30), radius: 10, x: 0, y: 5)
            .accessibilityHidden(true)
    }
}

private struct CoverPlayerTitle: View {
    let state: PlaybackState
    var titleSize: CGFloat
    var subtitleSize: CGFloat
    var alignment: HorizontalAlignment = .center

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(nowPlayingSubtitle(state))
                .font(.system(size: subtitleSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

/// 上一首 / 播放 / 下一首(听书时是后退 / 播放 / 前进, 电台只有播放), 平分整行。
private struct CoverPlayerControls: View {
    let state: PlaybackState
    var symbolSize: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if let info = state.spokenWord, state.isSpokenWord {
                control(PrimuseSkipBackwardIntent(), symbol: info.skipBackwardSymbol,
                        label: PMString("ext.widget.spokenWord.skipBackFormat", info.skipBackwardSeconds))
                playPause
                control(PrimuseSkipForwardIntent(), symbol: info.skipForwardSymbol,
                        label: PMString("ext.widget.spokenWord.skipForwardFormat", info.skipForwardSeconds))
            } else if state.isLiveStream {
                playPause
            } else {
                control(PrimusePreviousIntent(), symbol: "backward.fill", label: PMString("ext.control.previous"))
                playPause
                control(PrimuseNextIntent(), symbol: "forward.fill", label: PMString("ext.control.next"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // The icon shows the last snapshot; ask for the state it shows, so a stale
    // snapshot can never turn "play" into a pause.
    // 圆片的直径就是这一排原来的高(符号字号的两倍), 换成毛玻璃键也不把排版撑高。
    private var playPause: some View {
        Button(intent: PrimuseSetPlayingIntent(value: !state.isPlaying)) {
            WidgetGlassKeyLabel(
                symbol: state.isPlaying ? (state.isLiveStream ? "stop.fill" : "pause.fill") : "play.fill",
                diameter: symbolSize * 2,
                symbolScale: 0.46
            )
            .frame(maxWidth: .infinity, minHeight: symbolSize * 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .invalidatableContent()
        .accessibilityLabel(PMString(state.isPlaying ? "ext.control.pause" : "ext.control.play"))
    }

    private func control<Intent: AppIntent>(_ intent: Intent, symbol: String, label: String) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: symbolSize * 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 小号: 卡片样式在模糊封面上左上角摆一张方封面, 铺满时整块就是封面、下半截压暗; 下面都是歌名、
/// 歌手和三个按钮。色调、透明外观下没有封面底, 照卡片样式摆。
private struct CoverPlayerSmallView: View {
    let state: PlaybackState
    let prefersFullBleed: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let bleeds = coverPlayerBleeds(state, prefersFullBleed: prefersFullBleed, renderingMode: renderingMode)
        CoverPlayerCanvas(state: state, padding: 12, bleed: bleeds ? .whole : .none) {
            GeometryReader { geometry in
                // 歌名两行约 34、按钮 30, 加三段间距, 剩下的给封面。
                let coverSide = min(60, max(36, geometry.size.height - 80))
                VStack(alignment: .leading, spacing: 4) {
                    if !bleeds {
                        CoverPlayerArtwork(state: state, cornerRadius: 10)
                            .frame(width: coverSide, height: coverSide)
                    }
                    Spacer(minLength: 0)
                    CoverPlayerTitle(state: state, titleSize: 14, subtitleSize: 11.5, alignment: .leading)
                        .shadow(color: .black.opacity(renderingMode == .fullColor ? 0.35 : 0), radius: 3, x: 0, y: 1)
                    CoverPlayerControls(state: state, symbolSize: 15)
                }
                .widgetBounds(geometry.size, alignment: .topLeading)
            }
        }
    }
}

/// 中号: 左边整高的封面(卡片是圆角方图, 铺满时贴着上下左三条边、往右渐隐), 右边歌名、歌手,
/// 下面三个大按钮。
private struct CoverPlayerMediumView: View {
    let state: PlaybackState
    let prefersFullBleed: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let bleeds = coverPlayerBleeds(state, prefersFullBleed: prefersFullBleed, renderingMode: renderingMode)
        CoverPlayerCanvas(state: state, bleed: bleeds ? .leading : .none) {
            GeometryReader { geometry in
                HStack(spacing: 14) {
                    if bleeds {
                        // 封面画在底上, 这里只占住同样的宽度, 右栏和卡片样式对齐。
                        Color.clear
                            .frame(width: geometry.size.height, height: geometry.size.height)
                    } else {
                        CoverPlayerArtwork(state: state)
                            .frame(width: geometry.size.height, height: geometry.size.height)
                    }
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        CoverPlayerTitle(state: state, titleSize: 18, subtitleSize: 13.5)
                            .shadow(color: .black.opacity(bleeds ? 0.3 : 0), radius: 3, x: 0, y: 1)
                        Spacer(minLength: 6)
                        CoverPlayerControls(state: state, symbolSize: 20)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .widgetBounds(geometry.size, alignment: .leading)
            }
        }
    }
}

/// 大号: 上面一张大封面(卡片是居中的圆角方图, 铺满时从顶边铺满整宽、往下渐隐), 下面歌名、歌手、
/// 进度和三个按钮, 都居中。
private struct CoverPlayerLargeView: View {
    let state: PlaybackState
    let progress: PlaybackProgress
    let prefersFullBleed: Bool
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let bleeds = coverPlayerBleeds(state, prefersFullBleed: prefersFullBleed, renderingMode: renderingMode)
        CoverPlayerCanvas(state: state, padding: 18, bleed: bleeds ? .top : .none) {
            GeometryReader { geometry in
                // 封面下面: 歌名两行约 43、进度条、按钮 44, 加上四段间距共约 130。
                let side = max(80, min(geometry.size.width, geometry.size.height - 134))
                VStack(spacing: 10) {
                    if !bleeds {
                        CoverPlayerArtwork(state: state, cornerRadius: 16)
                            .frame(width: side, height: side)
                    }
                    Spacer(minLength: 0)
                    CoverPlayerTitle(state: state, titleSize: 19, subtitleSize: 14)
                        .shadow(color: .black.opacity(bleeds ? 0.35 : 0), radius: 3, x: 0, y: 1)
                    if state.isLiveStream {
                        LiveIndicatorLine()
                    } else {
                        ProgressLine(progress: progress)
                    }
                    CoverPlayerControls(state: state, symbolSize: 22)
                }
                .widgetBounds(geometry.size, alignment: .top)
            }
        }
    }
}

// MARK: - 正在播放(经典)
//
// 1.11.3(98) 之前那一版「正在播放」: 端正的方封面、斜向渐变画布, 眉题写格式, 下面已播 / 总时长
// 数字和带细圈的按钮; 小号整块是封面。87df1e49 在原 kind 上换成了唱片套样式, 有用户更喜欢旧的,
// 所以另立一款并列在小组件库里, 现有「正在播放」不动。时间线、按钮意图都和「正在播放」同一套,
// 只是中号也带歌词(写正唱到的那一句, 大号是歌词面板); 写入侧 reloadAllTimelines 一并刷新,
// 歌词更新时按 kind 单独刷。

struct NowPlayingClassicWidget: Widget {
    let kind = "NowPlayingClassicWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: NowPlayingProvider(lyricFamilies: [.systemMedium, .systemLarge])
        ) { entry in
            NowPlayingClassicWidgetView(entry: entry)
        }
        .contentMarginsDisabled()
        .configurationDisplayName(PMString("ext.widget.nowPlayingClassic.displayName"))
        .description(PMString("ext.widget.nowPlayingClassic.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct NowPlayingClassicWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let state = entry.state, state.currentSongID != nil {
            let progress = PlaybackProgress(
                state: state,
                elapsed: entry.playbackElapsed,
                referenceDate: entry.playbackReferenceDate
            )
            switch family {
            case .systemMedium: ClassicMediumNowPlayingView(
                state: state,
                progress: progress,
                lyricsSnapshot: entry.lyricsSnapshot
            )
            case .systemLarge: ClassicLargeNowPlayingView(
                state: state,
                progress: progress,
                lyricsSnapshot: entry.lyricsSnapshot
            )
            default: ClassicSmallNowPlayingView(state: state, progress: progress)
            }
        } else {
            ClassicEmptyStateView()
        }
    }
}

/// 旧版的配色: 深色是墨黑底, 浅色是米白底, 上面叠石墨—海青—主题色—琥珀和陶土色两层斜向渐变。
private enum ClassicWidgetPalette {
    static let ink = Color(red: 0.043, green: 0.067, blue: 0.071)
    static let paper = Color(red: 0.955, green: 0.958, blue: 0.945)
    static let graphite = Color(red: 0.135, green: 0.145, blue: 0.135)
    static let clay = Color(red: 0.82, green: 0.38, blue: 0.24)
}

private struct ClassicWidgetCanvas<Content: View>: View {
    var padding: CGFloat = 16
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                ClassicWidgetBackdrop()
            }
    }
}

/// 渐变和描边都画在容器背景里, 而且只在全彩外观画: 色调、透明外观下系统会换掉整块底,
/// 画在内容层里会在那两种外观下留一块发白的底(#190)。
private struct ClassicWidgetBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor {
            let tint = WidgetDesign.brandTint
            let isDark = colorScheme == .dark
            // 单色时海青、琥珀、陶土这几层色相也收掉, 只留墨黑 / 米白底和高光(#320)。
            let hue: (Color) -> Color = WidgetDesign.prefersMonochrome ? { _ in .clear } : { $0 }
            ZStack {
                isDark ? ClassicWidgetPalette.ink : ClassicWidgetPalette.paper
                if isDark {
                    LinearGradient(
                        colors: [
                            ClassicWidgetPalette.graphite.opacity(0.94),
                            hue(WidgetDesign.sea.opacity(0.20)),
                            tint.opacity(0.05),
                            hue(WidgetDesign.amber.opacity(0.14)),
                            Color.black.opacity(0.30),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.78),
                            tint.opacity(0.10),
                            hue(WidgetDesign.amber.opacity(0.12)),
                            Color.black.opacity(0.035),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                LinearGradient(
                    colors: [
                        tint.opacity(isDark ? 0.06 : 0.12),
                        .clear,
                        hue(ClassicWidgetPalette.clay.opacity(isDark ? 0.12 : 0.08)),
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
                LinearGradient(
                    colors: [
                        Color.white.opacity(isDark ? 0.12 : 0.34),
                        .clear,
                        Color.black.opacity(isDark ? 0.18 : 0.04),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay {
                // 描边跟随系统给的容器形状: macOS 与 iOS 的小组件圆角不同。
                ContainerRelativeShape()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.18 : 0.72),
                                Color.black.opacity(isDark ? 0.00 : 0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

/// 端正的方封面, 不倾斜、不带唱片。封面按填满缩放, 先占住方框再叠上去裁掉, 别让它撑开布局。
private struct ClassicArtwork: View {
    let state: PlaybackState
    var cornerRadius: CGFloat

    var body: some View {
        Color.clear
            .overlay {
                WidgetCoverImageView(coverImageName: state.coverImageName, cornerRadius: cornerRadius)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 进度条下面一行等宽小字: 已播 / 总时长。
private struct ClassicProgressBlock: View {
    let state: PlaybackState
    let progress: PlaybackProgress
    var spacing: CGFloat
    var fontSize: CGFloat

    var body: some View {
        VStack(spacing: spacing) {
            ProgressLine(progress: progress)
            HStack {
                ElapsedTimeText(progress: progress)
                Spacer()
                Text(formatTime(state.duration))
            }
            .font(.system(size: fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(WidgetDesign.tertiaryText)
        }
    }
}

/// 小号: 整块就是封面, 下半截压暗, 白字写歌名、歌手, 底下一条进度。色调、透明外观下没有
/// 封面底, 左上角摆一张小封面。
private struct ClassicSmallNowPlayingView: View {
    let state: PlaybackState
    let progress: PlaybackProgress
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        CoverPlayerCanvas(state: state, padding: 14, bleed: .whole) {
            GeometryReader { geometry in
                // 色调、透明外观下左上角那张小封面: 底下歌名两行、歌手和进度连间距约 77pt, iPad mini 小号内容
                // 只有 113pt 高, 封面按剩下的取, 不再把进度条挤出底边。
                let footer: CGFloat = state.isLiveStream ? 14 : 4.5
                let artworkSide: CGFloat = min(46, max(28, geometry.size.height - 73 - footer))
                VStack(alignment: .leading, spacing: 6) {
                    if renderingMode != .fullColor {
                        ClassicArtwork(state: state, cornerRadius: 8)
                            .frame(width: artworkSide, height: artworkSide)
                    }
                    Spacer(minLength: 0)
                    Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(nowPlayingSubtitle(state))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if state.isLiveStream {
                        LiveIndicatorLine(lightText: renderingMode == .fullColor)
                            .padding(.top, 2)
                    } else {
                        ProgressLine(progress: progress)
                            .padding(.top, 2)
                    }
                }
                .widgetBounds(geometry.size)
                .shadow(color: .black.opacity(renderingMode == .fullColor ? 0.30 : 0), radius: 3, x: 0, y: 1)
            }
        }
    }
}

/// 中号: 左边方封面, 右边眉题、歌名、歌手, 再一行正唱到的那句歌词(像锁屏歌词那样; 没有歌词、听书和
/// 电台时写专辑或书的信息), 下面进度和时长, 最底下一排紧凑按钮。
private struct ClassicMediumNowPlayingView: View {
    let state: PlaybackState
    let progress: PlaybackProgress
    let lyricsSnapshot: LyricsSnapshot?

    var body: some View {
        ClassicWidgetCanvas(padding: 14) {
            GeometryReader { geometry in
                let coverSide = min(112, geometry.size.height)
                // 右栏每样一行排满约 124pt。矮一些的中号(4.7 寸 iPhone、部分 iPad)先省掉时长那行,
                // 再矮就省掉眉题, 不让内容超出高度、上下两头被裁掉。
                let showsTimes = geometry.size.height >= 126
                let showsEyebrow = geometry.size.height >= 110
                let lyric = state.listeningSpace == .music ? classicCurrentLyric(lyricsSnapshot) : nil
                HStack(spacing: 14) {
                    ClassicArtwork(state: state, cornerRadius: 12)
                        .frame(width: coverSide, height: coverSide)

                    // 没有歌词时歌名可以写两行, 但两行要多约 20pt: 长歌名在 6.1 寸 iPhone 的中号(内容约 130pt 高)
                    // 上也会把底下的键挤出去。排不下就收成一行, 再不行才省掉时长。
                    ViewThatFits(in: .vertical) {
                        column(lyric: lyric, titleLines: lyric == nil ? 2 : 1,
                               showsEyebrow: showsEyebrow, showsTimes: showsTimes)
                        column(lyric: lyric, titleLines: 1, showsEyebrow: showsEyebrow, showsTimes: showsTimes)
                        column(lyric: lyric, titleLines: 1, showsEyebrow: showsEyebrow, showsTimes: false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .widgetBounds(geometry.size, alignment: .leading)
            }
        }
    }

    private func column(lyric: String?, titleLines: Int, showsEyebrow: Bool, showsTimes: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsEyebrow {
                NowPlayingEyebrow(state: state)
                    .padding(.bottom, 4)
            }
            Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(WidgetDesign.strongText)
                .lineLimit(titleLines)
                .minimumScaleFactor(0.86)
            Text(nowPlayingSubtitle(state))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WidgetDesign.secondaryText)
                .lineLimit(1)
                .padding(.top, 1)
            if let lyric {
                Text(verbatim: lyric)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(WidgetDesign.brandTint)
                    .widgetAccentable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 4)
            } else {
                Text(secondaryMetadata(state))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetDesign.tertiaryText)
                    .lineLimit(1)
                    .padding(.top, 3)
            }

            Spacer(minLength: 3)

            if state.isLiveStream {
                LiveIndicatorLine()
            } else if showsTimes {
                ClassicProgressBlock(state: state, progress: progress, spacing: 4, fontSize: 9.5)
            } else {
                ProgressLine(progress: progress)
            }

            NowPlayingControls(state: state, compact: true, classic: true)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 经典中号那一行歌词: 正唱到的那一句。间奏的空行接着显示上一句, 第一句还没唱到时先写第一句。
private func classicCurrentLyric(_ snapshot: LyricsSnapshot?) -> String? {
    guard let snapshot, !snapshot.lines.isEmpty else { return nil }
    let lines = snapshot.lines
    let anchor = min(max(snapshot.anchorIndex, 0), lines.count - 1)
    func text(at index: Int) -> String? {
        let text = lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    for index in stride(from: anchor, through: 0, by: -1) {
        if let text = text(at: index) { return text }
    }
    for index in (anchor + 1)..<lines.count {
        if let text = text(at: index) { return text }
    }
    return nil
}

/// 大号: 封面和歌名一排, 中间一块圆角面板放歌词(有声书换成整本书的进度), 下面进度、时长和整排按钮。
private struct ClassicLargeNowPlayingView: View {
    let state: PlaybackState
    let progress: PlaybackProgress
    let lyricsSnapshot: LyricsSnapshot?

    var body: some View {
        ClassicWidgetCanvas(padding: 18) {
            GeometryReader { geometry in
                // 旧版按整块宽度(含两边 18 的边距)取 42%。封面以下: 三段间距 39、进度和时长 21、一排 34 高的键,
                // 面板连自己的内边距至少要 56 才放得下读书进度最紧的一档, 共 150pt。iPad mini 大号内容只有
                // 269.5pt 高, 封面从 128 收到约 120, 底下的键不再被裁掉; 4.7 寸以上的 iPhone 不变。
                let widthSide: CGFloat = max(118, (geometry.size.width + 36) * 0.42)
                let coverSide: CGFloat = max(80, min(138, widthSide, geometry.size.height - 150))
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .top, spacing: 14) {
                        ClassicArtwork(state: state, cornerRadius: 14)
                            .frame(width: coverSide, height: coverSide)

                        VStack(alignment: .leading, spacing: 6) {
                            NowPlayingEyebrow(state: state)
                            Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(WidgetDesign.strongText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.82)
                            Text(nowPlayingSubtitle(state))
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

                    if let spokenWord = state.spokenWord, state.isSpokenWord {
                        SpokenWordBookProgressPanel(info: spokenWord)
                            .modifier(ClassicPanelChrome())
                            .layoutPriority(1)
                    } else if !state.isLiveStream {
                        NowPlayingLyricsPreview(snapshot: lyricsSnapshot)
                            .modifier(ClassicPanelChrome())
                            .layoutPriority(1)
                    }

                    if state.isLiveStream {
                        LiveIndicatorLine()
                    } else {
                        ClassicProgressBlock(state: state, progress: progress, spacing: 6, fontSize: 10.5)
                    }

                    NowPlayingControls(state: state, compact: false, classic: true)
                }
                .widgetBounds(geometry.size, alignment: .topLeading)
            }
        }
    }
}

/// 歌词 / 读书进度那块的圆角浅底和细描边。
private struct ClassicPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.055), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(WidgetDesign.hairline, lineWidth: 1)
            }
    }
}

private struct ClassicEmptyStateView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            ClassicWidgetCanvas(padding: 18) {
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
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        case .systemLarge:
            ClassicWidgetCanvas(padding: 22) {
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
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        default:
            ClassicWidgetCanvas(padding: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Spacer(minLength: 0)
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
}

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

/// Date-relative progress must retain the system style so WidgetKit can
/// advance it without running the extension. Custom styles receive no fraction.
struct ProgressLine: View {
    let progress: PlaybackProgress
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let fill = colorScheme == .dark ? Color.white : WidgetDesign.brandTint
        Group {
            if let range = progress.timerRange {
                // 默认会在进度条下面带一行走动的时间,两个标签都显式给空。
                ProgressView(timerInterval: range, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .labelsHidden()
            } else {
                ProgressView(value: progress.staticFraction)
            }
        }
        .progressViewStyle(.linear)
        .tint(fill)
        .frame(height: 2.5)
        .invalidatableContent()
    }
}
