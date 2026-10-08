import SwiftUI
import WidgetKit
import AppIntents
import PrimuseKit

struct NowPlayingProvider: TimelineProvider {
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
            let lyrics = Self.lyricsSnapshot(for: loadedState, family: context.family)
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
        let lyrics = Self.lyricsSnapshot(for: loadedState, family: context.family)
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

    private static func lyricsSnapshot(
        for state: PlaybackState?,
        family: WidgetFamily
    ) -> LyricsSnapshot? {
        guard family == .systemLarge,
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    WidgetPlaybackArtwork(state: state)
                        .frame(width: 62, height: 52)
                    Spacer(minLength: 8)
                    WidgetPlaybackButton(state: state, size: 36)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WidgetDesign.strongText)
                        .lineLimit(2)
                    Text(nowPlayingSubtitle(state))
                        .font(.system(size: 12))
                        .foregroundStyle(WidgetDesign.secondaryText)
                        .lineLimit(1)
                }
                if state.isLiveStream { LiveIndicatorLine() }
                else { ProgressLine(progress: progress) }
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
                HStack(spacing: 16) {
                    WidgetPlaybackArtwork(state: state)
                        .frame(width: side, height: side)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.songTitle ?? PMString("ext.widget.unknownSong"))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(WidgetDesign.strongText)
                            .lineLimit(2).minimumScaleFactor(0.88)
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
        GeometryReader { geometry in
            let coverSide = min(138, max(118, geometry.size.width * 0.42))

            WidgetCanvas(padding: 18) {
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

                    NowPlayingControls(state: state, compact: false)
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
    if state.isLiveStream { return "dot.radiowaves.left.and.right" }
    if !state.isPlaying { return "pause.fill" }
    return state.isSpokenWord ? "book.fill" : "waveform"
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
        HStack(spacing: compact ? 10 : 14) {
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

    private func controlIcon(symbol: String, prominent: Bool = false, active: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: controlSize(symbol: symbol), weight: .semibold))
            .foregroundStyle(active ? WidgetDesign.brandTint : WidgetDesign.strongText)
            .frame(width: controlFrame(symbol: symbol), height: controlFrame(symbol: symbol))
            .background(controlBackground(prominent: prominent, active: active), in: .circle)
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }

    private func controlSize(symbol: String) -> CGFloat {
        if symbol.contains("play") || symbol.contains("pause") || symbol.contains("stop") { return compact ? 12 : 16 }
        return compact ? 10.5 : 12.5
    }

    private func controlFrame(symbol: String) -> CGFloat {
        if symbol.contains("play") || symbol.contains("pause") || symbol.contains("stop") { return compact ? 32 : 40 }
        return compact ? 26 : 32
    }

    private func controlBackground(prominent: Bool, active: Bool) -> Color {
        if prominent || active {
            return WidgetDesign.brandTint.opacity(0.22)
        }
        return .clear
    }
}

/// 大号小组件里给有声内容的那一块: 整本书读到哪里、还剩多久。
private struct SpokenWordBookProgressPanel: View {
    let info: SpokenWordPlaybackInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: PMString("ext.widget.spokenWord.bookProgress"))
            } icon: {
                Image(systemName: "book.closed.fill")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(WidgetDesign.tertiaryText)

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
            if let part = spokenWordPartText(info) {
                Text(verbatim: part)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WidgetDesign.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

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
                Image(systemName: state.isSpokenWord ? "book.fill" : "waveform")
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
            ? "dot.radiowaves.left.and.right"
            : (state.isPlaying ? (state.isSpokenWord ? "book.fill" : "play.fill") : "pause.fill")
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
            switch family {
            case .systemMedium: CoverPlayerMediumView(state: state)
            case .systemLarge: CoverPlayerLargeView(state: state, progress: progress)
            default: CoverPlayerSmallView(state: state)
            }
        } else {
            SmallEmptyStateView()
        }
    }
}

/// 封面铺底一律是深色: 全彩外观下字和按钮按深色画, 浅色模式下也是白字。色调、透明外观下
/// 系统会换掉整块底, 那时照系统的来。
private struct CoverPlayerCanvas<Content: View>: View {
    let state: PlaybackState
    var padding: CGFloat = 14
    var sharpCover = false
    let content: Content
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    init(state: PlaybackState, padding: CGFloat = 14, sharpCover: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.state = state
        self.padding = padding
        self.sharpCover = sharpCover
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, renderingMode == .fullColor ? .dark : colorScheme)
            .containerBackground(for: .widget) {
                CoverPlayerBackdrop(coverImageName: state.coverImageName, sharp: sharpCover)
            }
    }
}

private struct CoverPlayerBackdrop: View {
    let coverImageName: String?
    var sharp = false
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .fullColor {
            GeometryReader { geometry in
                ZStack {
                    WidgetDesign.canvasBase
                    if let coverImageName, !coverImageName.isEmpty {
                        if sharp {
                            WidgetCoverImageView(coverImageName: coverImageName, cornerRadius: 0)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                            // 小号整块就是封面: 下半截压暗, 字和按钮压在上面。
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
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .scaleEffect(1.35)
                                .blur(radius: 30)
                                .saturation(1.25)
                            // 浅色封面上白字也要读得清。
                            LinearGradient(
                                colors: [.black.opacity(0.22), .black.opacity(0.48)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    } else {
                        LinearGradient(
                            colors: [WidgetDesign.brandTint.opacity(0.55), WidgetDesign.canvasBase],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .accessibilityHidden(true)
        } else {
            Color.clear
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    private var playPause: some View {
        Button(intent: PrimuseSetPlayingIntent(value: !state.isPlaying)) {
            Image(systemName: state.isPlaying ? (state.isLiveStream ? "stop.fill" : "pause.fill") : "play.fill")
                .font(.system(size: symbolSize * 1.3, weight: .semibold))
                .foregroundStyle(.primary)
                .widgetAccentable()
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
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

/// 小号: 整块就是封面, 下半截压暗后放歌名、歌手和三个按钮。色调、透明外观下没有封面底,
/// 改在左上角摆一张小封面。
private struct CoverPlayerSmallView: View {
    let state: PlaybackState
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        CoverPlayerCanvas(state: state, padding: 12, sharpCover: true) {
            VStack(alignment: .leading, spacing: 4) {
                if renderingMode != .fullColor {
                    CoverPlayerArtwork(state: state, cornerRadius: 8)
                        .frame(width: 46, height: 46)
                }
                Spacer(minLength: 0)
                CoverPlayerTitle(state: state, titleSize: 14, subtitleSize: 11.5, alignment: .leading)
                    .shadow(color: .black.opacity(renderingMode == .fullColor ? 0.35 : 0), radius: 3, x: 0, y: 1)
                CoverPlayerControls(state: state, symbolSize: 15)
            }
        }
    }
}

/// 中号: 左边整高的封面, 右边歌名、歌手, 下面三个大按钮。
private struct CoverPlayerMediumView: View {
    let state: PlaybackState

    var body: some View {
        CoverPlayerCanvas(state: state) {
            GeometryReader { geometry in
                HStack(spacing: 14) {
                    CoverPlayerArtwork(state: state)
                        .frame(width: geometry.size.height, height: geometry.size.height)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        CoverPlayerTitle(state: state, titleSize: 18, subtitleSize: 13.5)
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

/// 大号: 上面一张大封面, 下面歌名、歌手、进度和三个按钮, 都居中。
private struct CoverPlayerLargeView: View {
    let state: PlaybackState
    let progress: PlaybackProgress

    var body: some View {
        CoverPlayerCanvas(state: state, padding: 18) {
            GeometryReader { geometry in
                // 封面下面: 歌名两行约 43、进度条、按钮 44, 加上四段间距共约 130。
                let side = max(80, min(geometry.size.width, geometry.size.height - 134))
                VStack(spacing: 10) {
                    CoverPlayerArtwork(state: state, cornerRadius: 16)
                        .frame(width: side, height: side)
                    Spacer(minLength: 0)
                    CoverPlayerTitle(state: state, titleSize: 19, subtitleSize: 14)
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
