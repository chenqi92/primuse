import CoreText
import SwiftUI
import PrimuseKit

// MARK: - Palette

/// The colours a spoken-word player part is drawn in. The iPhone player and
/// the Mac player each pass their own foreground tones, so the parts sit on
/// either background without knowing which it is.
struct SpokenWordPlayerPalette: Equatable {
    var primary: Color
    var secondary: Color
    var tertiary: Color
    var accent: Color
    /// Fill behind the action tiles.
    var tileFill: Color
}

// MARK: - Text

/// What the spoken-word player writes about the book: its title, the part
/// being heard and the time left. One place, so the iPhone, iPad and Mac
/// players say the same thing.
@MainActor
enum SpokenWordPlayerText {
    /// "18 分钟", "1 小时 5 分钟"; under a minute says so rather than "0 分钟".
    static func approximateDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else {
            return String(localized: "spoken_word_under_a_minute")
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        // Rounded to the minute: a countdown that ticks every second would
        // only be noise at this size.
        let rounded = (seconds / 60).rounded() * 60
        return formatter.string(from: rounded) ?? ChapterTimeFormatter.string(from: seconds)
    }

    /// 正在放的是播客单集时就是它。单集不是书:标题是这一集,署名是节目名,
    /// 「正在听的部分」只在单集带章节时是章节名。
    private static func podcastEpisode(_ player: AudioPlayerService) -> Song? {
        guard let song = player.currentSong, PodcastPlaybackSong.isEpisode(song) else { return nil }
        return song
    }

    static func isPodcastEpisode(_ player: AudioPlayerService) -> Bool {
        podcastEpisode(player) != nil
    }

    /// 正在播的播客单集,节目还订着才有详情可看(退订后单集就不在了,入口跟着收起)。
    static func openablePodcastEpisodeID(_ player: AudioPlayerService) -> String? {
        guard let episode = podcastEpisode(player),
              PodcastStore.shared.episode(id: episode.id) != nil else { return nil }
        return episode.id
    }

    /// 分享播客单集:单集自己的网页,没有就给节目的(见 `PodcastShare`)。
    static func podcastShareURL(_ player: AudioPlayerService) -> URL? {
        guard let episode = podcastEpisode(player),
              let found = PodcastStore.shared.episode(id: episode.id) else { return nil }
        return found.episode.link ?? PodcastShare.url(for: found.show)
    }

    /// 正在播的这一集所在的节目(节目页的入口)。退订了的节目没有页面可去。
    static func podcastShowID(_ player: AudioPlayerService) -> String? {
        guard let episode = podcastEpisode(player) else { return nil }
        return PodcastStore.shared.episode(id: episode.id)?.show.id
    }

    /// 标题块里节目名后面那一小段:这一集是哪天发的。
    static func podcastPublishedLine(_ player: AudioPlayerService) -> String? {
        guard let episode = podcastEpisode(player) else { return nil }
        return PodcastFormat.date(PodcastStore.shared.episode(id: episode.id)?.episode.publishedAt)
    }

    /// 两侧小键的旁白:书是上一章 / 下一章;播客有章节时按章,没有(或到了最后一章)是上一集 / 下一集。
    static func partButtonLabelKey(_ player: AudioPlayerService, forward: Bool) -> LocalizedStringKey {
        guard podcastEpisode(player) != nil else {
            return forward ? "spoken_word_next_chapter" : "spoken_word_previous_chapter"
        }
        let unit = forward ? player.podcastForwardUnit : player.podcastBackwardUnit
        switch (unit, forward) {
        case (.chapter, true): return "spoken_word_next_chapter"
        case (.chapter, false): return "spoken_word_previous_chapter"
        case (.episode, true): return "spoken_word_next_item"
        case (.episode, false): return "spoken_word_previous_item"
        }
    }

    /// 语速菜单的标题:书按本记速度,播客按节目记,别对播客说「本书」。
    static func rateTitleKey(_ player: AudioPlayerService) -> LocalizedStringKey {
        isPodcastEpisode(player) ? "playback_rate" : "spoken_word_book_speed"
    }

    /// 标题键的旁白提示:书是「前往这本书」,播客是这一集的详情。
    static func openTitleHintKey(_ player: AudioPlayerService) -> LocalizedStringKey {
        isPodcastEpisode(player) ? "podcast_player_episode_details" : "spoken_word_go_to_book"
    }

    static func bookTitle(_ player: AudioPlayerService) -> String {
        if let episode = podcastEpisode(player) { return episode.title }
        if let title = player.currentSpokenWordBook?.title, !title.isEmpty { return title }
        let album = player.currentSong?.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return album.isEmpty ? (player.currentSong?.title ?? "") : album
    }

    static func author(_ player: AudioPlayerService) -> String? {
        if let episode = podcastEpisode(player) {
            let show = episode.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return show.isEmpty ? episode.artistName : show
        }
        if let author = player.currentSpokenWordBook?.author, !author.isEmpty { return author }
        guard let song = player.currentSong else { return nil }
        let name = song.albumArtistName ?? song.artistName
        return name?.isEmpty == false ? name : nil
    }

    /// 演播:曲目的艺人和作者不是同一个人时才有(分书规则里曲目艺人就是演播,
    /// 见 `SpokenWordBookGroupingRules`)。播客单集没有这一行。
    static func narrator(_ player: AudioPlayerService) -> String? {
        guard podcastEpisode(player) == nil,
              let name = player.currentSong?.artistName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let author = author(player)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.localizedCaseInsensitiveCompare(author) == .orderedSame ? nil : name
    }

    /// The part being heard: the chapter mark's title inside a one-file
    /// book, the file's title (with the chapter mark under it, if any) in a
    /// book of several files. Nil when it would only repeat the book title.
    static func partTitle(_ player: AudioPlayerService) -> String? {
        if podcastEpisode(player) != nil {
            let chapter = player.currentChapter?.title ?? ""
            return chapter.isEmpty ? nil : chapter
        }
        guard let song = player.currentSong else { return nil }
        let isOneFileBook = (player.currentSpokenWordBook?.items.count ?? 1) <= 1
        let chapterTitle = player.currentChapter?.title
        if isOneFileBook, let chapterTitle, !chapterTitle.isEmpty { return chapterTitle }
        var title = song.title
        if let chapterTitle, !chapterTitle.isEmpty, chapterTitle != title {
            title += " · " + chapterTitle
        }
        return title == bookTitle(player) ? nil : title
    }

    /// "第 12 / 120 章"; nil for a one-file book without chapter marks.
    static func partPosition(_ summary: SpokenWordNowPlayingSummary?) -> String? {
        guard let summary, let index = summary.partIndex, let count = summary.partCount else { return nil }
        return String(format: String(localized: "spoken_word_part_position_format"), index, count)
    }

    static func partPosition(_ part: SpokenWordPartPosition?) -> String? {
        guard let part else { return nil }
        return String(format: String(localized: "spoken_word_part_position_format"), part.index, part.count)
    }

    /// "本章还剩约 18 分钟", in listening time at the book's speed.
    static func partRemaining(_ player: AudioPlayerService) -> String? {
        guard let remaining = player.spokenWordPartRemaining else { return nil }
        let listening = SpokenWordNowPlayingPolicy.listeningTime(
            forContent: remaining,
            rate: player.currentSpokenWordRate
        )
        // 没有章节的播客单集只有它自己,说「剩余」,不说「本章」。
        let isWholeEpisode = podcastEpisode(player) != nil && player.spokenWordChapters.isEmpty
        // 不到一分钟单独一句,免得拼成「本章还剩约 不到 1 分钟」。
        guard listening.isFinite, listening >= 60 else {
            let key: String.LocalizationValue = isWholeEpisode
                ? "podcast_remaining_under_minute" : "spoken_word_part_remaining_under_minute"
            return String(localized: key)
        }
        let key: String.LocalizationValue = isWholeEpisode
            ? "podcast_remaining_format" : "spoken_word_part_remaining_format"
        return String(format: String(localized: key), approximateDuration(listening))
    }

    static func bookFraction(_ fraction: Double) -> String {
        let percent = Int((min(1, max(0, fraction)) * 100).rounded(.down))
        return String(format: String(localized: "spoken_word_book_fraction_format"), percent)
    }

    /// "剩约 58 小时"; nil while a duration in the book is unknown.
    static func bookRemaining(_ summary: SpokenWordNowPlayingSummary, rate: Float) -> String? {
        guard let remaining = summary.bookRemaining else { return nil }
        let listening = SpokenWordNowPlayingPolicy.listeningTime(forContent: remaining, rate: rate)
        return String(
            format: String(localized: "spoken_word_book_remaining_format"),
            approximateDuration(listening)
        )
    }

    /// 章节位置那颗键的旁白:「第 12 / 120 章,全书 9%,剩约 58 小时」。
    static func partPositionWithBook(_ position: String, summary: SpokenWordNowPlayingSummary, rate: Float) -> String {
        [position, bookFraction(summary.bookFraction), bookRemaining(summary, rate: rate)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// What the sleep tile says while a timer is armed. Nil for a timed
    /// sleep, which draws its own countdown.
    static func sleepTileLabel(_ player: AudioPlayerService) -> String {
        if player.sleepStopAfterChapter != nil {
            return String(localized: "spoken_word_sleep_chapter_short")
        }
        if player.sleepStopAfterBook != nil {
            return String(localized: "spoken_word_sleep_book_short")
        }
        if player.sleepStopAfterSongID != nil {
            return String(localized: "spoken_word_sleep_item_short")
        }
        return String(localized: "spoken_word_sleep_short")
    }
}

// MARK: - Progress details

/// 「◔ 第 12 / 120 章 ›」:章节位置前面那一圈是全书听到哪儿。全书进度不再单占一行细条,
/// 跟下面本章的进度条叠成两道;百分比和全书还剩多久在旁白里,目录顶上那行也写着。
/// 自己一个视图,读的是存下的位置而不是播放头:几秒才动一次,也只重画这一小块。
struct SpokenWordPartPositionButton: View {
    let palette: SpokenWordPlayerPalette
    let action: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @ScaledMetric(relativeTo: .footnote) private var ringSize: CGFloat = 12

    var body: some View {
        let store = SpokenWordStore.shared
        // Registers the chip with the store, so the stored positions it reads
        // redraw it when they change.
        let _ = store.positions.count
        let _ = store.finishedAt.count
        let summary = player.spokenWordNowPlayingSummary(live: false)
        if let summary, let position = SpokenWordPlayerText.partPosition(summary) {
            // 播客单集不是书,进度条就是它自己的进度,不画全书那一圈。
            let showsRing = !SpokenWordPlayerText.isPodcastEpisode(player)
            Button(action: action) {
                HStack(spacing: 5) {
                    if showsRing {
                        SpokenWordBookRing(fraction: summary.bookFraction, color: palette.accent)
                            .frame(width: ringSize, height: ringSize)
                    }
                    Text(verbatim: position)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .fontWeight(.semibold)
                .foregroundStyle(palette.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(Text("spoken_word_contents_title"))
            .accessibilityValue(Text(verbatim: showsRing
                ? SpokenWordPlayerText.partPositionWithBook(position, summary: summary, rate: player.currentSpokenWordRate)
                : position))
        }
    }
}

/// 全书进度的那一圈:底圈是淡色的整本书,亮色弧从十二点钟方向顺时针走到听到的地方。
struct SpokenWordBookRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        let clamped = min(1, max(0, fraction))
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: lineWidth)
            Circle()
                // 刚开头也留一个点,看得出这一圈是进度。
                .trim(from: 0, to: max(0.02, clamped))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// "本章还剩约 18 分钟" on its own, for players whose progress bar lives
/// elsewhere (the Mac's bottom bar). Its own view, so the clock only
/// redraws this line.
struct SpokenWordPartRemainingLabel: View {
    let color: Color
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        if let text = SpokenWordPlayerText.partRemaining(player) {
            Text(verbatim: text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

/// Marks where the playing item's bookmarks sit, drawn over the scrubber.
struct SpokenWordBookmarkTicks: View {
    let color: Color
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let songID = player.currentSong?.id ?? ""
        let duration = player.duration > 0 ? player.duration : (player.currentSong?.duration ?? 0)
        let fractions = SpokenWordNowPlayingPolicy.bookmarkFractions(
            SpokenWordStore.shared.bookmarks(forSongID: songID),
            duration: duration
        )
        GeometryReader { proxy in
            ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 9)
                    .position(x: proxy.size.width * fraction, y: proxy.size.height / 2 - 5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Action tiles

/// The row of tiles under the spoken-word transport: speed, sleep timer,
/// bookmark and contents. They are on the page rather than in the menu
/// because a book is listened to with them.
struct SpokenWordActionTiles: View {
    /// 一块怎么画。`tiles` 是垫圆角底的方块(Mac);手机与 iPad 上不垫底,和音乐页底栏一样只有图标:
    /// `stacked` 图标在上、字在下(墨黑与播客、横屏),`inline` 图标与字排成一行(暖白)。
    enum Layout {
        case tiles
        case stacked
        case inline
    }

    let palette: SpokenWordPlayerPalette
    var layout: Layout = .tiles
    var showsContents = true
    var tileHeight: CGFloat = 56
    /// 按「播放页按钮」的配置摆哪几块、什么顺序。nil 是原来的固定摆法(Mac 用)。
    var tiles: [SpokenWordControlTile]? = nil
    /// 只放图标时不写说明;睡眠定时开着仍靠实心的强调色图标看出来,不画倒计时。
    var labelStyle: SpokenWordTileLabelStyle = .iconAndText
    let onSleep: () -> Void
    let onContents: () -> Void
    /// 播客的「接下来」。给了才有这一块(书没有队列可看)。
    var onUpNext: (() -> Void)? = nil
    /// 从右上角、播放键旁挪进这一排的文字稿、喜欢、「更多」由播放页自己画(用 `SpokenWordTileFace`),
    /// 返回 nil 时这一块不出现(没有文字稿、播客单集不能喜欢),其余几块照样平均排开。
    var customTile: ((SpokenWordControlTile) -> AnyView?)? = nil

    @Environment(AudioPlayerService.self) private var player
    @State private var bookmarkFeedbackToken = 0

    private var isPodcast: Bool { SpokenWordPlayerText.isPodcastEpisode(player) }

    var body: some View {
        HStack(spacing: layout == .tiles ? 8 : 0) {
            if let tiles {
                ForEach(tiles) { tile in
                    tileView(tile)
                }
            } else {
                rateTile
                sleepTile
                // 播客把「书签」让给「接下来」:书签仍在说明面板里,也能从那里加。
                // 目录常驻在旁边一栏时(iPad、Mac)位置够,书签留着。
                if !isPodcast || !showsContents || onUpNext == nil { bookmarkTile }
                if showsContents { contentsTile }
                if isPodcast, let onUpNext { upNextTile(onUpNext) }
            }
        }
    }

    @ViewBuilder
    private func tileView(_ tile: SpokenWordControlTile) -> some View {
        switch tile {
        case .speed: rateTile
        case .sleepTimer: sleepTile
        case .bookmark: bookmarkTile
        case .contents: contentsTile
        case .upNext:
            if isPodcast, let onUpNext { upNextTile(onUpNext) }
        case .airPlay:
            airPlayTile
        case .transcript, .like, .more:
            if let view = customTile?(tile) { view }
        }
    }

    /// 隔空播放(「播放页按钮」里打开后从右上角挪到这一排)。系统的选取键只认点在它自己身上,
    /// 所以它占满图标那一块,说明文字只是标注。
    private var airPlayTile: some View {
        tile {
            AirPlayButton()
                .frame(width: 44, height: layout == .inline ? 28 : 30)
        } caption: {
            Text("player_controls_action_airplay")
        }
    }

    private var iconFont: Font { Self.iconFont(for: layout) }

    /// 一块里图标的字号;播放页自己画的几块用同一档。
    static func iconFont(for layout: Layout) -> Font {
        switch layout {
        case .tiles: .body.weight(.semibold)
        case .stacked: .title3.weight(.light)
        case .inline: .callout
        }
    }

    /// 图标在上的一排里,「1.0×」和定时的月亮比书签、目录宽一大截,同一号字看着大一圈,收小一档(#320)。
    private var rateFont: Font {
        switch layout {
        case .tiles: .body.monospacedDigit().weight(.bold)
        case .stacked: .body.monospacedDigit().weight(.light)
        case .inline: .callout.monospacedDigit().weight(.medium)
        }
    }

    private var sleepIconFont: Font {
        layout == .stacked ? .body.weight(.light) : iconFont
    }

    private func upNextTile(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tile {
                Image(systemName: "list.bullet")
                    .font(iconFont)
                    .foregroundStyle(palette.primary)
            } caption: {
                Text("podcast_player_up_next_short")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("up_next"))
    }

    private var rateTile: some View {
        Menu {
            Picker(selection: Binding(
                get: { player.currentSpokenWordRate },
                set: { player.setSpokenWordRateForCurrentBook($0) }
            )) {
                ForEach(SpokenWordPlaybackRatePolicy.presets, id: \.self) { rate in
                    Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate)).tag(rate)
                }
            } label: {
                Text(SpokenWordPlayerText.rateTitleKey(player))
            }
        } label: {
            tile {
                Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: player.currentSpokenWordRate))
                    .font(rateFont)
                    // 方块里语速用强调色;不垫底的两套设计里它和旁边的图标同色。
                    .foregroundStyle(layout == .tiles ? palette.accent : palette.primary)
            } caption: {
                Text("spoken_word_speed_short")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(SpokenWordPlayerText.rateTitleKey(player)))
        .accessibilityValue(Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: player.currentSpokenWordRate)))
    }

    private var sleepTile: some View {
        Button(action: onSleep) {
            tile {
                Image(systemName: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(sleepIconFont)
                    .foregroundStyle(player.isSleepTimerActive ? palette.accent : palette.primary)
            } caption: {
                if let endDate = player.sleepTimerEndDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: max(0, endDate.timeIntervalSince(context.date)).formattedDuration)
                            .monospacedDigit()
                    }
                } else {
                    Text(verbatim: SpokenWordPlayerText.sleepTileLabel(player))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(player.isSleepTimerActive ? "sleep_timer_active" : "sleep_timer"))
    }

    private var bookmarkTile: some View {
        Button {
            if player.addSpokenWordBookmark() { bookmarkFeedbackToken += 1 }
        } label: {
            tile {
                Image(systemName: "bookmark")
                    .font(iconFont)
                    .foregroundStyle(palette.primary)
                    .symbolEffect(.bounce, value: bookmarkFeedbackToken)
            } caption: {
                Text("spoken_word_bookmarks_title")
            }
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .sensoryFeedback(.success, trigger: bookmarkFeedbackToken)
        #endif
        .accessibilityLabel(Text("spoken_word_add_bookmark"))
    }

    /// 书是「目录」;播客打开的是节目说明(有章节时还有章节、书签)。
    private var contentsTile: some View {
        Button(action: onContents) {
            tile {
                Image(systemName: isPodcast ? "text.alignleft" : "list.bullet")
                    .font(iconFont)
                    .foregroundStyle(palette.primary)
            } caption: {
                Text(isPodcast ? "podcast_player_notes_short" : "spoken_word_contents_title")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isPodcast ? "podcast_show_notes" : "spoken_word_contents_title"))
    }

    private func tile<Icon: View, Caption: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder caption: () -> Caption
    ) -> some View {
        SpokenWordTileFace(
            layout: layout,
            tileHeight: tileHeight,
            labelStyle: labelStyle,
            palette: palette,
            icon: icon,
            caption: caption
        )
    }
}

/// 功能块一块的样子:图标加一行说明(只放图标时不写)。`SpokenWordActionTiles` 与播放页自己画的
/// 几块(挪进这一排的文字稿、喜欢、「更多」)共用,同一排里大小、字号一样。
struct SpokenWordTileFace<Icon: View, Caption: View>: View {
    let layout: SpokenWordActionTiles.Layout
    let tileHeight: CGFloat
    let labelStyle: SpokenWordTileLabelStyle
    let palette: SpokenWordPlayerPalette
    @ViewBuilder let icon: Icon
    @ViewBuilder let caption: Caption

    private var showsCaptions: Bool { labelStyle == .iconAndText }

    var body: some View {
        switch layout {
        case .tiles:
            VStack(spacing: 3) {
                icon
                if showsCaptions {
                    caption
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .background(palette.tileFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .stacked:
            VStack(spacing: 6) {
                icon
                    .frame(height: 24)
                if showsCaptions {
                    caption
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .contentShape(Rectangle())
        case .inline:
            HStack(spacing: 6) {
                icon
                if showsCaptions {
                    caption
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Heading

/// The spoken-word player's title block: the book, the part being heard,
/// the narrator, and "第 12 / 120 章 ›" that opens the contents.
struct SpokenWordPlayerHeading<Trailing: View>: View {
    let palette: SpokenWordPlayerPalette
    var titleFont: Font = .title2
    var partFont: Font = .body
    var alignment: HorizontalAlignment = .leading
    var titleLineLimit = 2
    /// 播客:节目名单独可点,打开节目页。
    var onOpenShow: (() -> Void)? = nil
    let onOpenBook: () -> Void
    let onOpenContents: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        let frameAlignment: Alignment = alignment == .center ? .center : .leading
        VStack(alignment: alignment, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button(action: onOpenBook) {
                    Text(verbatim: SpokenWordPlayerText.bookTitle(player))
                        .font(titleFont.weight(.bold))
                        // 书名用衬线体像书脊;播客单集就是一集节目的标题。
                        .fontDesign(SpokenWordPlayerText.isPodcastEpisode(player) ? Font.Design.default : Font.Design.serif)
                        .foregroundStyle(palette.primary)
                        .lineLimit(titleLineLimit)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: frameAlignment)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(SpokenWordPlayerText.openTitleHintKey(player)))
                .layoutPriority(1)

                trailing()
            }

            if let part = SpokenWordPlayerText.partTitle(player) {
                Text(verbatim: part)
                    .font(partFont)
                    .foregroundStyle(palette.primary.opacity(0.86))
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
            }

            HStack(spacing: 10) {
                if let author = SpokenWordPlayerText.author(player) {
                    if let onOpenShow, SpokenWordPlayerText.podcastShowID(player) != nil {
                        podcastShowLink(author, action: onOpenShow)
                    } else {
                        Text(verbatim: author)
                            .lineLimit(1)
                            .foregroundStyle(palette.secondary)
                    }
                }
                if let published = SpokenWordPlayerText.podcastPublishedLine(player) {
                    Text(verbatim: published)
                        .lineLimit(1)
                        .foregroundStyle(palette.tertiary)
                        .fixedSize()
                }
                if alignment != .center { Spacer(minLength: 0) }
                SpokenWordPartPositionButton(palette: palette, action: onOpenContents)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
        .contentTransition(.opacity)
        .pmAnimation(.trackChange, value: player.currentSong?.id)
    }

    /// 节目名:点开节目页。和单集名(点开这一集)分开,两处各去各的地方。
    private func podcastShowLink(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(verbatim: name)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(palette.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("podcast_go_to_show"))
    }
}

extension SpokenWordPlayerHeading where Trailing == EmptyView {
    init(
        palette: SpokenWordPlayerPalette,
        titleFont: Font = .title2,
        partFont: Font = .body,
        alignment: HorizontalAlignment = .leading,
        titleLineLimit: Int = 2,
        onOpenShow: (() -> Void)? = nil,
        onOpenBook: @escaping () -> Void,
        onOpenContents: @escaping () -> Void
    ) {
        self.init(
            palette: palette,
            titleFont: titleFont,
            partFont: partFont,
            alignment: alignment,
            titleLineLimit: titleLineLimit,
            onOpenShow: onOpenShow,
            onOpenBook: onOpenBook,
            onOpenContents: onOpenContents,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - Part buttons

/// The small previous / next chapter buttons either side of the big skip
/// buttons. Chapter marks first, then the neighbouring file of the book.
/// 播客:有章节先按章,然后是队列里的上一集 / 下一集(不分节目)。
struct SpokenWordPartButton: View {
    let forward: Bool
    let color: Color
    var font: Font = .body

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        Button {
            if forward {
                player.goToNextSpokenWordPart()
            } else {
                player.goToPreviousSpokenWordPart()
            }
        } label: {
            Image(systemName: forward ? "forward.end.fill" : "backward.end.fill")
                .font(font)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(forward && !player.canGoToNextSpokenWordPart)
        .opacity(forward && !player.canGoToNextSpokenWordPart ? 0.35 : 1)
        .accessibilityLabel(Text(SpokenWordPlayerText.partButtonLabelKey(player, forward: forward)))
    }
}

// MARK: - Pane tabs

/// 播放页侧栏顶上那排页签:文字左对齐排开,选中的一页用正文色加粗、下面一道强调色短线,
/// 其余用次要色;放不下时横向滑动。有声内容的「目录 / 书签 / 文字稿」和 iPad 分栏右栏的
/// 「歌词 / 待播」共用。原来的系统分段控件居中飘在栏里,窄了还会钻到右上角那排按钮底下(#350)。
struct PlayerPaneTabBar<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    let items: [Item]
    @Binding var selection: Value
    var primary: Color = .primary
    var secondary: Color = .secondary
    var accent: Color = .accentColor
    /// 第一个页签左边留多少,和下面内容的左边缘对齐。
    var leadingInset: CGFloat = 16

    @Namespace private var marker

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(items) { item in
                    tab(item)
                }
            }
            .padding(.horizontal, leadingInset)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func tab(_ item: Item) -> some View {
        let isSelected = item.value == selection
        return Button {
            guard !isSelected else { return }
            pmWithAnimation(.selection) { selection = item.value }
        } label: {
            // 宽度按加粗那一版占好,选中与否字不来回挤。
            Text(verbatim: item.title)
                .fontWeight(.semibold)
                .hidden()
                .overlay {
                    Text(verbatim: item.title)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? primary : secondary)
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(accent)
                            .frame(width: 18, height: 3)
                            .matchedGeometryEffect(id: "marker", in: marker)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .pmPointingHand()
        #endif
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// 页签下面那块内容的上沿淡出:列表滑到页签下面时不再硬切掉半行。
    func playerPaneTopFade(height: CGFloat = 14) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                Rectangle()
            }
        }
    }
}

// MARK: - Full-screen transcript

/// 全屏读文稿的偏好(本机记住)。
enum SpokenWordTranscriptReaderPreferences {
    static let fontKey = "primuse.transcriptReader.font"
    static let fontWeightKey = "primuse.transcriptReader.fontWeight"
    static let fontSizeKey = "primuse.transcriptReader.fontSize"
    static let lineSpacingKey = "primuse.transcriptReader.lineSpacing"
    static let paragraphSpacingKey = "primuse.transcriptReader.paragraphSpacing"
    static let themeKey = "primuse.transcriptReader.theme"
    static let appearanceKey = "primuse.transcriptReader.appearance"
    static let highlightKey = "primuse.transcriptReader.highlight"
    static let customTextColorKey = "primuse.transcriptReader.customTextColor"
    static let customBackgroundColorKey = "primuse.transcriptReader.customBackgroundColor"
    /// 「自定义」主题深色外观那一套;空着表示和浅色外观那套一样(#313)。
    static let customDarkTextColorKey = "primuse.transcriptReader.customDarkTextColor"
    static let customDarkBackgroundColorKey = "primuse.transcriptReader.customDarkBackgroundColor"
    /// 滑动文稿时要不要把控件叫出来。默认不叫:读书时手指一滑控件就跳出来又收回去,很扰人;
    /// 点一下屏幕或暂停时才出来。
    static let revealsOnScrollKey = "primuse.transcriptReader.revealsOnScroll"
    /// 字幕并成段落读,还是每一行字幕自己一段(`SpokenWordTranscriptReadingPolicy.ParagraphMode`)。
    static let paragraphModeKey = "primuse.transcriptReader.paragraphMode"
    /// 带译文的文稿读原文、双语还是只看译文(`SpokenWordTranscriptReadingPolicy.TextMode`,#320)。
    static let textModeKey = "primuse.transcriptReader.textMode"
    /// 双语时译文的字号;0 = 跟着原文,是原文字号的 `followingTranslationScale`。
    static let translationFontSizeKey = "primuse.transcriptReader.translationFontSize"
    /// 两端对齐(同 Apple 图书):每段最后一行以外的行都排满到左右两边。
    static let justifiesTextKey = "primuse.transcriptReader.justifiesText"
    /// 正文左右两边留多宽的白。
    static let pageMarginKey = "primuse.transcriptReader.pageMargin"
    /// 右边的滚动条。默认不显示:当阅读器用时整屏只有字。
    static let showsScrollIndicatorKey = "primuse.transcriptReader.showsScrollIndicator"
    static let followingTranslationScale = 0.85
    static let fontSizeRange: ClosedRange<Double> = 14...36
    static let defaultFontSize = 20.0
    static let pageMarginRange: ClosedRange<Double> = 8...64
    static let defaultPageMargin = 24.0
    /// 页边距是默认值时正文最宽这么宽;边距每宽一点,大屏上这一栏也跟着窄一点。
    static let defaultColumnMaxWidth: CGFloat = 720
    static let defaultCustomTextHex = "3B3127"
    static let defaultCustomBackgroundHex = "EFE6D5"
    /// 这么久没碰(播放中、暂停着都一样),顶上的关闭与底下的进度、按键收起来。
    static let chromeAutoHideDelay: Duration = .seconds(3)
}

/// 文稿正文的字重。Apple 图书的中文正文是细体,看着更舒展;默认仍是常规。
/// 字体本身和歌词共用(`PlayerTextFont`,按需下载由 `PlayerTextFontLibrary` 管)。
enum SpokenWordTranscriptWeight: String, CaseIterable, Identifiable {
    case regular, light, thin

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .regular: "transcript_reader_weight_regular"
        case .light: "transcript_reader_weight_light"
        case .thin: "transcript_reader_weight_thin"
        }
    }

    var fontWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .light: .light
        case .thin: .thin
        }
    }
}

extension PlayerTextFont {
    func font(size: CGFloat, weight: SpokenWordTranscriptWeight, isAvailable: Bool = true) -> Font {
        font(size: size, weight: weight.fontWeight, isAvailable: isAvailable)
    }
}

/// 行距与段距的三档,按字号成比例。
enum SpokenWordTranscriptSpacing: String, CaseIterable, Identifiable {
    case compact, standard, relaxed

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .compact: "transcript_spacing_compact"
        case .standard: "transcript_spacing_standard"
        case .relaxed: "transcript_spacing_relaxed"
        }
    }

    func lineSpacing(fontSize: CGFloat) -> CGFloat {
        switch self {
        case .compact: fontSize * 0.2
        case .standard: fontSize * 0.45
        case .relaxed: fontSize * 0.75
        }
    }

    func paragraphSpacing(fontSize: CGFloat) -> CGFloat {
        switch self {
        case .compact: fontSize * 0.6
        case .standard: fontSize * 1.1
        case .relaxed: fontSize * 1.8
        }
    }
}

/// 朗读高亮:整句只亮正在念的那一句,整段亮正在念的整个段落;关掉则全文都是正文色、不变暗,
/// 只跟着滚动。
enum SpokenWordTranscriptHighlight: String, CaseIterable, Identifiable {
    case sentence, paragraph, off

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .sentence: "transcript_reader_highlight_sentence"
        case .paragraph: "transcript_reader_highlight_paragraph"
        case .off: "transcript_reader_highlight_off"
        }
    }
}

/// App 本身的浅色 / 深色(系统外观,或「设置 › 外观」里定的那个),由播放页外层放进环境。
/// 播放页可以整页换成深色(「播放页始终用深色」),全屏文稿还会给自己那一层定深浅,
/// 两处都会改掉环境里的 `colorScheme`;「跟随系统」要的是这个没被改过的值(#313)。
private struct AppColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    var appColorScheme: ColorScheme? {
        get { self[AppColorSchemeKey.self] }
        set { self[AppColorSchemeKey.self] = newValue }
    }
}

/// 「播放页始终用深色」开着时由播放页外层放进环境,只有从播放页里弹出的页面看得到(#320)。
private struct PlayerForcesDarkAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var playerForcesDarkAppearance: Bool {
        get { self[PlayerForcesDarkAppearanceKey.self] }
        set { self[PlayerForcesDarkAppearanceKey.self] = newValue }
    }
}

/// 常驻的播放页醒着没有(#322)。收进休眠时外层放进 false;自己走钟、又不经过播放页「可见」开关的
/// 零件(波浪进度条之类)据此停下,收着时不在看不见的地方一直画。
private struct PlayerSurfaceIsAwakeKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var playerSurfaceIsAwake: Bool {
        get { self[PlayerSurfaceIsAwakeKey.self] }
        set { self[PlayerSurfaceIsAwakeKey.self] = newValue }
    }
}

/// 播放页里读播放时钟的进度条、时间经过它(#322):醒着时读 `currentTime`(建立观察)并记下;收进
/// 休眠时给记下的值、不读时钟,看不见的进度条不再跟着 0.5 秒一跳重画,填充条也不再一直接动画。
@MainActor
final class PlayerClockSnapshot {
    private var time: TimeInterval = 0
    private var partRemaining: String?

    func time(of player: AudioPlayerService, isAwake: Bool) -> TimeInterval {
        guard isAwake else { return time }
        time = player.currentTime
        return time
    }

    /// 「本章还剩约 18 分钟」也跟着时钟走,一样冻住。
    func partRemaining(of player: AudioPlayerService, isAwake: Bool) -> String? {
        guard isAwake else { return partRemaining }
        partRemaining = SpokenWordPlayerText.partRemaining(player)
        return partRemaining
    }
}

/// 从播放页弹出的页面(目录、队列、歌曲信息……)套上它。播放页强制深色时,弹出页跟着拿到白字,
/// 弹出页的底和列表却跟着窗口还是浅色,字几乎看不见;这里把弹出页整页(底、列表、状态栏连同字)
/// 都换成深色。没开「始终用深色」时什么也不加,照旧跟着 App 的外观。
private struct PlayerPresentationColorScheme: ViewModifier {
    @Environment(\.playerForcesDarkAppearance) private var forcesDark

    @ViewBuilder
    func body(content: Content) -> some View {
        if forcesDark {
            content
                // 全屏效果页可能把环境换成了浅色,弹出页的字要和底一致。
                .environment(\.colorScheme, .dark)
                .preferredColorScheme(.dark)
        } else {
            content
        }
    }
}

/// 从播放页打开的资料库页面(专辑、书、播客节目与单集、电台详情)套上它。这些是 App 里的页面,
/// 不是播放页的面板:「播放页始终用深色」开着时也照 App 本来的外观画,浅色外观下白底黑字(#329)。
/// 弹出页的底本来就跟着窗口,这里只把播放页换掉的环境换回来;页面里再弹出的东西也不再跟着换深色。
private struct PlayerLibraryPagePresentation: ViewModifier {
    @Environment(\.playerForcesDarkAppearance) private var forcesDark
    @Environment(\.appColorScheme) private var appColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if forcesDark, let appColorScheme {
            content
                .environment(\.colorScheme, appColorScheme)
                .environment(\.playerForcesDarkAppearance, false)
        } else {
            content
        }
    }
}

extension View {
    /// 见 `PlayerPresentationColorScheme`。
    func playerPresentationColorScheme() -> some View {
        modifier(PlayerPresentationColorScheme())
    }

    /// 见 `PlayerLibraryPagePresentation`。
    func playerLibraryPagePresentation() -> some View {
        modifier(PlayerLibraryPagePresentation())
    }
}

/// 文稿页自己的浅色 / 深色,与系统设置无关;「跟随系统」时随系统。
enum SpokenWordTranscriptAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "transcript_reader_appearance_system"
        case .light: "transcript_reader_appearance_light"
        case .dark: "transcript_reader_appearance_dark"
        }
    }

    func resolved(_ systemScheme: ColorScheme) -> ColorScheme {
        switch self {
        case .system: systemScheme
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 「自定义」主题的两套颜色:浅色外观一套、深色外观一套,外观「跟随系统」时随系统换(#313)。
/// 深色那套没单独调过(两个值空着)时和浅色那套一样,所以升级前调好的颜色照旧。
struct SpokenWordTranscriptCustomColors: Equatable {
    var lightText: String
    var lightBackground: String
    var darkText: String
    var darkBackground: String

    var hasDarkVersion: Bool {
        SpokenWordTranscriptTheme.validHex(darkText) != nil
            && SpokenWordTranscriptTheme.validHex(darkBackground) != nil
    }

    /// 这个深浅下用的那一套(RRGGBB)。
    func colors(for scheme: ColorScheme) -> (text: String, background: String) {
        if scheme == .dark, hasDarkVersion { return (darkText, darkBackground) }
        return (lightText, lightBackground)
    }
}

/// 文稿页的一套颜色。
struct SpokenWordTranscriptPalette: Equatable {
    var background: Color
    var text: Color
    /// 不在念的句子与段落。
    var dimmedText: Color
    /// 搜索命中的底色;正在看的那一处更深。
    var match: Color
    var currentMatch: Color
    var colorScheme: ColorScheme

    /// 按钮与输入框的底:字色淡淡铺一层。
    var controlFill: Color { text.opacity(0.08) }
}

/// 阅读主题:几套预设(参照 Apple 图书),每套有浅色、深色两版。深色版的底不用纯黑、字不用纯白,
/// 长时间看不刺眼。「自定义」用自己挑的字色与底色,浅色、深色外观可以各调一套。
enum SpokenWordTranscriptTheme: String, CaseIterable, Identifiable {
    case original, paper, warm, quiet, green, custom

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .original: "transcript_reader_theme_original"
        case .paper: "transcript_reader_theme_paper"
        case .warm: "transcript_reader_theme_warm"
        case .quiet: "transcript_reader_theme_quiet"
        case .green: "transcript_reader_theme_green"
        case .custom: "transcript_reader_theme_custom"
        }
    }

    func palette(
        for scheme: ColorScheme,
        custom: SpokenWordTranscriptCustomColors
    ) -> SpokenWordTranscriptPalette {
        let dark = scheme == .dark
        switch self {
        case .original:
            return dark ? Self.makePalette(background: "1C1C1E", text: "D3D3D7", dark: true)
                : Self.makePalette(background: "FFFFFF", text: "1D1D1F", dark: false)
        case .paper:
            return dark ? Self.makePalette(background: "23211D", text: "D9D1C4", dark: true)
                : Self.makePalette(background: "F8F4EC", text: "2F2A24", dark: false)
        case .warm:
            return dark ? Self.makePalette(background: "2A241C", text: "DCCAAB", dark: true)
                : Self.makePalette(background: "F1E5CC", text: "4A3A27", dark: false)
        case .quiet:
            return dark ? Self.makePalette(background: "38383B", text: "C4C4C7", dark: true)
                : Self.makePalette(background: "E6E6E3", text: "3C3C3E", dark: false)
        case .green:
            return dark ? Self.makePalette(background: "1F2722", text: "C3D3BF", dark: true)
                : Self.makePalette(background: "DCEBD4", text: "2E3B2B", dark: false)
        case .custom:
            let picked = custom.colors(for: scheme)
            let background = Self.validHex(picked.background)
                ?? SpokenWordTranscriptReaderPreferences.defaultCustomBackgroundHex
            let text = Self.validHex(picked.text)
                ?? SpokenWordTranscriptReaderPreferences.defaultCustomTextHex
            return Self.makePalette(background: background, text: text, dark: Self.luminance(ofHex: background) < 0.45)
        }
    }

    private static func makePalette(background: String, text: String, dark: Bool) -> SpokenWordTranscriptPalette {
        let textColor = Color(hex: text)
        return SpokenWordTranscriptPalette(
            background: Color(hex: background),
            text: textColor,
            dimmedText: textColor.opacity(0.5),
            match: Color(hex: dark ? "6B5A1E" : "FFE38A"),
            currentMatch: Color(hex: dark ? "A8741A" : "FFB23F"),
            colorScheme: dark ? .dark : .light
        )
    }

    static func validHex(_ value: String) -> String? {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        return hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// 0 黑 ~ 1 白,自定义底色据此决定按深色还是浅色配控件。
    private static func luminance(ofHex hex: String) -> Double {
        let value = UInt64(hex, radix: 16) ?? 0
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }

    /// 取色盘选出的颜色存成六位十六进制。
    static func hex(from color: Color) -> String? {
        #if canImport(UIKit)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        #else
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let red: CGFloat = rgb.redComponent
        let green: CGFloat = rgb.greenComponent
        let blue: CGFloat = rgb.blueComponent
        #endif
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    private static func byte(_ component: CGFloat) -> Int {
        let clamped: CGFloat = min(max(component, 0), 1)
        return Int((clamped * 255).rounded())
    }
}

/// 有声书、播客的文稿全屏读:字幕一样的短行并成段落,章节名单独成段。
///
/// 跟着播放走到正在念的那一句(或那一段);自己滑开了就不再拉回,点底下的「跟随播放」再接上。
/// 点一段从那里播(暂停着也开始播)。顶上只有关闭与章节名,底下是进度与一排键:跟随播放 · 快退 · 播放 ·
/// 快进 · 菜单;3 秒不碰就收起(暂停着也收),点空白处、暂停、拖进度时再出来,上下滑动默认不叫出来(可在设置里改)。
/// 顶栏往下拖一段退出全屏。iPhone、iPad 上点屏幕左右两边只叫出或收起控件、不跳播,控件在时左右扫一下
/// 退出全屏(这两种拖法整页都跟着手指走,见 `SpokenWordTranscriptDismissDrag`);控件收起时状态栏一起藏起来(同 Apple 图书)。
/// 菜单里是目录、搜索、主题与设置、语速,以及书签与字号。字幕可以并成段落读,也可以每一行一段(设置里选)。
struct SpokenWordTranscriptReader: View {
    let lines: [LyricLine]
    let title: String
    let player: AudioPlayerService
    /// 播放页歌词翻译给出的各行译文(文件自带的优先,其次机翻),双语与只看译文时用(#320)。
    var translatedTextByLineID: [String: String] = [:]

    private typealias Policy = SpokenWordTranscriptReadingPolicy
    private typealias Row = SpokenWordTranscriptParagraphRow
    /// 文稿那一屏自己的坐标空间:点段落的位置和 `viewportFrame` 都按它算。
    private static let viewportSpace = "SpokenWordTranscriptViewport"

    private enum MenuAction { case contents, search, settings }
    private enum BookmarkNotice: Equatable { case added, exists }
    private struct SearchInput: Equatable {
        let paragraphs: [Policy.Paragraph]
        let query: String?
    }
    /// 文稿、分段方式、译文或读法一变就重新分段。
    private struct ParagraphInput: Equatable {
        let lines: [LyricLine]
        let mode: Policy.ParagraphMode
        let translations: [String: String]
        let textMode: Policy.TextMode
    }
    /// 顶上安全区的高度,和量它时的宽度(转屏时重新量)。
    private struct TopInsetSample: Equatable {
        let width: CGFloat
        let inset: CGFloat
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var environmentColorScheme
    @Environment(\.appColorScheme) private var appColorScheme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// 播放页全屏打开时外面那层给的跟手退出;没有时(Mac 的弹出页)照旧直接关。
    @Environment(\.spokenWordTranscriptDismissDrag) private var dismissDrag
    @AppStorage(SpokenWordTranscriptReaderPreferences.fontKey)
    private var fontRawValue = PlayerTextFont.system.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.fontWeightKey)
    private var fontWeightRawValue = SpokenWordTranscriptWeight.regular.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.fontSizeKey)
    private var fontSize = SpokenWordTranscriptReaderPreferences.defaultFontSize
    @AppStorage(SpokenWordTranscriptReaderPreferences.lineSpacingKey)
    private var lineSpacingRawValue = SpokenWordTranscriptSpacing.standard.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.paragraphSpacingKey)
    private var paragraphSpacingRawValue = SpokenWordTranscriptSpacing.standard.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.themeKey)
    private var themeRawValue = SpokenWordTranscriptTheme.original.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.appearanceKey)
    private var appearanceRawValue = SpokenWordTranscriptAppearance.system.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.highlightKey)
    private var highlightRawValue = SpokenWordTranscriptHighlight.sentence.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.customTextColorKey)
    private var customTextHex = SpokenWordTranscriptReaderPreferences.defaultCustomTextHex
    @AppStorage(SpokenWordTranscriptReaderPreferences.customBackgroundColorKey)
    private var customBackgroundHex = SpokenWordTranscriptReaderPreferences.defaultCustomBackgroundHex
    @AppStorage(SpokenWordTranscriptReaderPreferences.customDarkTextColorKey)
    private var customDarkTextHex = ""
    @AppStorage(SpokenWordTranscriptReaderPreferences.customDarkBackgroundColorKey)
    private var customDarkBackgroundHex = ""
    @AppStorage(SpokenWordTranscriptReaderPreferences.revealsOnScrollKey)
    private var revealsChromeOnScroll = false
    @AppStorage(SpokenWordTranscriptReaderPreferences.paragraphModeKey)
    private var paragraphModeRawValue = Policy.ParagraphMode.merged.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.textModeKey)
    private var textModeRawValue = Policy.TextMode.original.rawValue
    @AppStorage(SpokenWordTranscriptReaderPreferences.translationFontSizeKey)
    private var translationFontSize = 0.0
    @AppStorage(SpokenWordTranscriptReaderPreferences.justifiesTextKey)
    private var justifiesText = false
    @AppStorage(SpokenWordTranscriptReaderPreferences.pageMarginKey)
    private var pageMargin = SpokenWordTranscriptReaderPreferences.defaultPageMargin
    @AppStorage(SpokenWordTranscriptReaderPreferences.showsScrollIndicatorKey)
    private var showsScrollIndicator = false
    @State private var paragraphs: [Policy.Paragraph] = []
    /// 这份文稿有没有哪一行带译文;没有时设置里不给读法,也一直按原文排。
    @State private var hasTranslations = false
    @State private var currentIndex: Int?
    /// 正在念的那一句在段里的位置;只有「整句」高亮时才跟。
    @State private var currentSegment: Int?
    @State private var followsPlayback = true
    @State private var showsMenu = false
    @State private var showsSettings = false
    @State private var showsContents = false
    /// 菜单里点的项:等菜单收好再打开,不然 iPhone 上弹不出下一层。
    @State private var pendingMenuAction: MenuAction?
    @State private var chromeVisible = true
    /// 每碰一下加一,自动收起的倒计时从头算。
    @State private var chromeActivity = 0
    @State private var isScrolling = false
    @State private var isScrubbing = false
    /// 左右扫、顶栏下拉退出的途中。只在开始和松手时各写一次;这时控件不自己收起
    /// (收起会停掉横扫手势,拖到一半的整页就弹回去了)。
    @State private var isDraggingToClose = false
    @State private var isSearching = false
    @State private var searchText = ""
    /// 当前结果对应的搜索词;还在算新词的结果时不显示旧的命中数。
    @State private var searchedQuery = ""
    @State private var searchMatches: [Policy.SearchMatch] = []
    /// 按段落 id 分好的命中位置,画每一段时直接取。
    @State private var matchRangesByParagraph: [Int: [Range<Int>]] = [:]
    @State private var currentMatchIndex: Int?
    @State private var matchScrollToken = 0
    @State private var bookmarkNotice: BookmarkNotice?
    @State private var bookmarkFeedbackToken = 0
    @State private var hoverThrottle = SpokenWordTranscriptHoverThrottle()
    /// 文稿那一屏的大小与位置,判断点在不在左右两边的点按区(`SpokenWordTranscriptEdgeTapPolicy`)。
    /// 按文稿自己的坐标量:整页跟手横移、下拉时它不变,拖动时不会每帧写一次、整页重算。
    @State private var viewportFrame: CGRect = .zero
    /// 正文那一栏的宽度,两端对齐时每行排满到这么宽。
    @State private var columnWidth: CGFloat = 0
    #if os(iOS)
    /// 文稿顶上让出的高度:状态栏藏起来时安全区会变矮(没有刘海的 iPhone、iPad),正文不跟着往上跳,
    /// 一直按出现过的最高那档留。转屏(宽度变了)时重新量。
    @State private var reservedTopInset: CGFloat = 0
    @State private var reservedTopInsetWidth: CGFloat = 0
    #endif
    @FocusState private var searchFieldFocused: Bool

    private var font: PlayerTextFont { PlayerTextFont(rawValue: fontRawValue) ?? .system }
    private var fontWeight: SpokenWordTranscriptWeight {
        SpokenWordTranscriptWeight(rawValue: fontWeightRawValue) ?? .regular
    }
    private var lineSpacing: SpokenWordTranscriptSpacing {
        SpokenWordTranscriptSpacing(rawValue: lineSpacingRawValue) ?? .standard
    }
    private var paragraphSpacing: SpokenWordTranscriptSpacing {
        SpokenWordTranscriptSpacing(rawValue: paragraphSpacingRawValue) ?? .standard
    }
    private var theme: SpokenWordTranscriptTheme { SpokenWordTranscriptTheme(rawValue: themeRawValue) ?? .original }
    private var appearance: SpokenWordTranscriptAppearance {
        SpokenWordTranscriptAppearance(rawValue: appearanceRawValue) ?? .system
    }
    private var highlight: SpokenWordTranscriptHighlight {
        SpokenWordTranscriptHighlight(rawValue: highlightRawValue) ?? .sentence
    }
    private var paragraphMode: Policy.ParagraphMode {
        Policy.ParagraphMode(rawValue: paragraphModeRawValue) ?? .merged
    }
    private var textMode: Policy.TextMode {
        Policy.TextMode(rawValue: textModeRawValue) ?? .original
    }
    private var size: CGFloat {
        CGFloat(min(max(fontSize, SpokenWordTranscriptReaderPreferences.fontSizeRange.lowerBound),
                    SpokenWordTranscriptReaderPreferences.fontSizeRange.upperBound))
    }
    private var margin: CGFloat {
        CGFloat(min(max(pageMargin, SpokenWordTranscriptReaderPreferences.pageMarginRange.lowerBound),
                    SpokenWordTranscriptReaderPreferences.pageMarginRange.upperBound))
    }
    private var columnMaxWidth: CGFloat {
        SpokenWordTranscriptReaderPreferences.defaultColumnMaxWidth
            - 2 * (margin - CGFloat(SpokenWordTranscriptReaderPreferences.defaultPageMargin))
    }

    /// 主题与外观选定的明暗;主题块也按它画。「跟随系统」看 App 本身的深浅:这一页自己定过的深浅
    /// 会写回这一层的环境,拿它当「系统」就会一直停在上次选的那一档(#313)。
    private var appearanceScheme: ColorScheme { appearance.resolved(appColorScheme ?? environmentColorScheme) }

    private var customColors: SpokenWordTranscriptCustomColors {
        SpokenWordTranscriptCustomColors(
            lightText: customTextHex,
            lightBackground: customBackgroundHex,
            darkText: customDarkTextHex,
            darkBackground: customDarkBackgroundHex
        )
    }

    private var palette: SpokenWordTranscriptPalette {
        theme.palette(for: appearanceScheme, custom: customColors)
    }


    /// 没开着菜单面板、没在搜索拖动滑动时,控件才会自己收起;暂停着也收,点一下再出来。
    /// 旁白开着、文稿是空的时候一直显示。
    private var chromeMayHide: Bool {
        !paragraphs.isEmpty && !voiceOverEnabled && !isSearching && !showsMenu && !showsSettings
            && !showsContents && !isScrolling && !isScrubbing && !isDraggingToClose && bookmarkNotice == nil
    }

    var body: some View {
        let palette = self.palette
        ScrollViewReader { proxy in
            transcript(palette: palette)
                .background(palette.background.ignoresSafeArea())
                .overlay(alignment: .top) { topBar(palette: palette) }
                .overlay(alignment: .bottom) { bottomBar(palette: palette, proxy: proxy) }
                .overlay(alignment: .top) { bookmarkNoticeView(palette: palette) }
                .onChange(of: currentIndex) { _, _ in
                    scrollToCurrent(proxy, animated: true)
                }
                .onChange(of: paragraphs.count) { _, _ in
                    scrollToCurrent(proxy, animated: false)
                }
                .onChange(of: matchScrollToken) { _, _ in
                    scrollToCurrentMatch(proxy)
                }
        }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: bookmarkFeedbackToken)
        // 控件收起时状态栏(时间、电量)一起藏,读书时整屏只有字;控件出来时跟着出来(#283)。
        .statusBarHidden(!(chromeVisible || isSearching))
        .onGeometryChange(for: TopInsetSample.self) { proxy in
            TopInsetSample(width: proxy.size.width, inset: proxy.safeAreaInsets.top)
        } action: { sample in
            if sample.width != reservedTopInsetWidth {
                reservedTopInsetWidth = sample.width
                reservedTopInset = sample.inset
            } else if sample.inset > reservedTopInset {
                reservedTopInset = sample.inset
            }
        }
        #endif
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            // 鼠标一动就叫出控件,一秒最多算一次,免得整页跟着每次移动重算。
            let now = Date()
            guard !chromeVisible || now.timeIntervalSince(hoverThrottle.lastReveal) > 1 else { return }
            hoverThrottle.lastReveal = now
            revealChrome()
        }
        .sheet(isPresented: $showsSettings) {
            SpokenWordTranscriptTypographyPanel(
                fontRawValue: $fontRawValue,
                fontWeightRawValue: $fontWeightRawValue,
                fontSize: $fontSize,
                lineSpacingRawValue: $lineSpacingRawValue,
                paragraphSpacingRawValue: $paragraphSpacingRawValue,
                themeRawValue: $themeRawValue,
                appearanceRawValue: $appearanceRawValue,
                highlightRawValue: $highlightRawValue,
                customTextHex: $customTextHex,
                customBackgroundHex: $customBackgroundHex,
                customDarkTextHex: $customDarkTextHex,
                customDarkBackgroundHex: $customDarkBackgroundHex,
                revealsChromeOnScroll: $revealsChromeOnScroll,
                paragraphModeRawValue: $paragraphModeRawValue,
                colorScheme: appearanceScheme,
                offsetSong: player.currentSong,
                textModeRawValue: hasTranslations ? $textModeRawValue : nil,
                translationFontSize: $translationFontSize,
                justifiesText: $justifiesText,
                pageMargin: $pageMargin,
                showsScrollIndicator: $showsScrollIndicator
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #else
            .frame(minWidth: 440, minHeight: 600)
            #endif
        }
        .sheet(isPresented: $showsContents) {
            SpokenWordContentsView()
                .environment(player)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #else
                .frame(minWidth: 420, minHeight: 520)
                #endif
        }
        .environment(\.colorScheme, palette.colorScheme)
        #if os(iOS)
        // 整页(连同状态栏的字)换成这一套的深浅。总给一个确定的值:改回 nil 时系统不会把这一层
        // 换回去,「跟随系统」就会停在上次选的深浅上。
        .preferredColorScheme(palette.colorScheme)
        #endif
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
        .task(id: ParagraphInput(
            lines: lines,
            mode: paragraphMode,
            translations: translatedTextByLineID,
            textMode: textMode
        )) {
            let sourceLines = lines
            let translations = translatedTextByLineID
            let mode = paragraphMode
            let requestedTextMode = textMode
            let (updated, translated) = await Task.detached(priority: .userInitiated) {
                let cues = Self.cues(from: sourceLines, translations: translations)
                let translated = SpokenWordTranscriptReadingPolicy.hasTranslation(cues)
                let shown = SpokenWordTranscriptReadingPolicy.cues(
                    cues,
                    showing: translated ? requestedTextMode : .original
                )
                return (SpokenWordTranscriptReadingPolicy.paragraphs(from: shown, mode: mode), translated)
            }.value
            guard !Task.isCancelled else { return }
            paragraphs = updated
            hasTranslations = translated
            // 换章后文稿是新的,正在念的下标还是旧文稿的:立刻按当前时间重算,别让它在新文稿里
            // 亮错一段再等下一拍纠正。
            updatePlaybackPosition()
        }
        .task {
            // 和歌词页、普通文稿页同一个节奏:每 100 毫秒看一次。只有下标变了才写状态,不会多重画。
            while !Task.isCancelled {
                updatePlaybackPosition()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .task(id: "\(chromeActivity)|\(chromeVisible)|\(chromeMayHide)") {
            guard chromeVisible, chromeMayHide else { return }
            try? await Task.sleep(for: SpokenWordTranscriptReaderPreferences.chromeAutoHideDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { chromeVisible = false }
        }
        .task(id: SearchInput(paragraphs: paragraphs, query: isSearching ? searchText : nil)) {
            await runSearch()
        }
        .task(id: font) {
            PlayerTextFontLibrary.shared.prepare(font)
        }
        .task(id: bookmarkNotice) {
            guard bookmarkNotice != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { bookmarkNotice = nil }
        }
        .onChange(of: player.isPlaying) { _, playing in
            // 停下来时把控件叫回来,好继续播或者关掉。
            if !playing { revealChrome() }
        }
        #if DEBUG
        .task { await runDebugAutomation() }
        #endif
    }

    // MARK: Text

    @ViewBuilder
    private func transcript(palette: SpokenWordTranscriptPalette) -> some View {
        #if os(iOS)
        // 文稿铺到状态栏底下,顶上自己按 `reservedTopInset` 留白:状态栏藏起来、安全区变矮时正文不往上跳。
        // 外面套一层不铺过去的透明底,顶栏、搜索栏照旧排在安全区里。
        Color.clear.overlay {
            transcriptScroll(palette: palette, topPadding: 72 + reservedTopInset)
                .ignoresSafeArea(.container, edges: .top)
        }
        #else
        transcriptScroll(palette: palette, topPadding: 72)
        #endif
    }

    private func transcriptScroll(palette: SpokenWordTranscriptPalette, topPadding: CGFloat) -> some View {
        let style = rowStyle(palette: palette)
        let currentID = currentParagraphID
        let match = currentMatch
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: paragraphSpacing.paragraphSpacing(fontSize: size)) {
                ForEach(paragraphs) { paragraph in
                    Row(
                        paragraph: paragraph,
                        emphasis: emphasis(for: paragraph, currentID: currentID),
                        matches: matchRangesByParagraph[paragraph.id] ?? [],
                        currentMatch: match?.paragraphID == paragraph.id ? match?.range : nil,
                        style: style
                    )
                    .equatable()
                    .id(paragraph.id)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .named(Self.viewportSpace)) { location in
                        tapParagraph(paragraph, at: location)
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                columnWidth = width
            }
            .frame(maxWidth: columnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, margin)
            .padding(.top, topPadding)
            // 底下的进度、时间与一排键比原来高,最后一段也要能滚到它们上面。
            .padding(.bottom, 190)
            .background {
                // 段与段之间、两边的留白:点一下叫出或收起控件。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleChrome() }
            }
        }
        .scrollIndicators(showsScrollIndicator ? .automatic : .hidden)
        .scrollDismissesKeyboard(.interactively)
        // 点按位置按这一屏自己的坐标量(原来按窗口):整页跟手横移、下拉时窗口坐标每帧都在变。
        .coordinateSpace(.named(Self.viewportSpace))
        .onGeometryChange(for: CGRect.self) { proxy in
            // 就是上面那个坐标空间。
            proxy.frame(in: .local)
        } action: { frame in
            viewportFrame = frame
        }
        #if os(iOS)
        // 左右扫只在控件出来时用来退出全屏;控件收着时不接手,叫出控件交给点左右两边。
        .gesture(SpokenWordTranscriptSwipeGesture(isEnabled: !isSearching && chromeVisible) { phase in
            handleSwipe(phase)
        })
        #endif
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .interacting:
                // 自己滑了就不再拉回。控件默认不跟着滑动出来(读书时很扰人),除非设置里开了。
                followsPlayback = false
                guard revealsChromeOnScroll else { break }
                isScrolling = true
                revealChrome()
            case .idle:
                if isScrolling {
                    isScrolling = false
                    chromeActivity &+= 1
                }
            default:
                break
            }
        }
        .overlay {
            if lines.isEmpty {
                Text("transcript_reader_empty")
                    .font(.callout)
                    .foregroundStyle(palette.dimmedText)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
    }

    private func rowStyle(palette: SpokenWordTranscriptPalette) -> Row.Style {
        let isAvailable = PlayerTextFontLibrary.shared.isAvailable(font)
        let headingSize: CGFloat = size * 1.15
        let translationSize = translationFontSize > 0
            ? CGFloat(min(max(translationFontSize, SpokenWordTranscriptReaderPreferences.fontSizeRange.lowerBound),
                          SpokenWordTranscriptReaderPreferences.fontSizeRange.upperBound))
            : (size * SpokenWordTranscriptReaderPreferences.followingTranslationScale).rounded()
        return Row.Style(
            font: font.font(size: size, weight: fontWeight, isAvailable: isAvailable),
            // 章节名不跟正文的字重走,细体正文配半粗的标题。
            headingFont: font.font(size: headingSize, isAvailable: isAvailable).weight(.semibold),
            translationFont: font.font(size: translationSize, weight: fontWeight, isAvailable: isAvailable),
            lineSpacing: lineSpacing.lineSpacing(fontSize: size),
            translationLineSpacing: lineSpacing.lineSpacing(fontSize: translationSize),
            justifiedWidth: justifiesText && columnWidth > 0 ? columnWidth : nil,
            palette: palette
        )
    }

    private var currentParagraphID: Int? {
        guard let currentIndex, paragraphs.indices.contains(currentIndex) else { return nil }
        return paragraphs[currentIndex].id
    }

    private func emphasis(for paragraph: Policy.Paragraph, currentID: Int?) -> Row.Emphasis {
        guard let currentID, highlight != .off else { return .plain }
        guard paragraph.id == currentID else { return .dimmed }
        if highlight == .sentence, let currentSegment { return .segment(currentSegment) }
        return .paragraph
    }

    /// 点在屏幕左右两边只叫出或收起控件(#283:原来两侧只有正文的留白算空白处,稍偏一点就点到段落跳播了);
    /// 点在中间才从这一段播。
    private func tapParagraph(_ paragraph: Policy.Paragraph, at location: CGPoint) {
        let x = Double(location.x - viewportFrame.minX)
        if SpokenWordTranscriptEdgeTapPolicy.isEdgeTap(x: x, viewportWidth: Double(viewportFrame.width)) {
            toggleChrome()
        } else {
            play(from: paragraph)
        }
    }

    /// 点一段:从段首播;搜索时点到有命中的段,从命中的那一句播。暂停着也开始播。
    private func play(from paragraph: Policy.Paragraph) {
        guard let target = searchTarget(in: paragraph) ?? paragraph.start else { return }
        followsPlayback = true
        player.seekToTappedLine(at: target)
    }

    private func searchTarget(in paragraph: Policy.Paragraph) -> TimeInterval? {
        guard isSearching, !searchMatches.isEmpty else { return nil }
        if let currentMatchIndex, searchMatches.indices.contains(currentMatchIndex),
           paragraphID(of: searchMatches[currentMatchIndex]) == paragraph.id {
            return searchMatches[currentMatchIndex].start
        }
        return searchMatches.first { paragraphID(of: $0) == paragraph.id }?.start
    }

    private func paragraphID(of match: Policy.SearchMatch) -> Int? {
        paragraphs.indices.contains(match.paragraph) ? paragraphs[match.paragraph].id : nil
    }

    /// 按播放器外推出来的此刻时间算正在念哪一段、哪一句。`currentTime` 每半秒才更新一次,
    /// 直接拿它判断,整段换高亮最多要晚近一秒(#313)。
    private func updatePlaybackPosition() {
        let time = player.interpolatedTime()
        let lookahead = Policy.followLookahead
        let index = Policy.paragraphIndex(at: time, in: paragraphs, lookahead: lookahead)
        var segment: Int?
        if highlight == .sentence, let index {
            segment = Policy.segmentIndex(at: time, in: paragraphs[index], lookahead: lookahead)
        }
        if index != currentIndex { currentIndex = index }
        if segment != currentSegment { currentSegment = segment }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard followsPlayback, let index = currentIndex, paragraphs.indices.contains(index) else { return }
        let target = paragraphs[index].id
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.25))
            }
        } else {
            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.25))
        }
    }

    nonisolated static func cues(
        from lines: [LyricLine],
        translations: [String: String] = [:]
    ) -> [SpokenWordTranscriptReadingPolicy.Cue] {
        // 双语字幕里跟在原文后面的读音行(罗马音、拼音)不当译文,和歌词页同一套整篇判断。
        let readingIDs = lines.contains { !$0.allManualTranslations.isEmpty }
            ? LyricRomanizedReadingPolicy.readingIDs(in: lines)
            : []
        return lines.map { line in
            SpokenWordTranscriptReadingPolicy.Cue(
                text: line.text,
                start: line.isSynchronized ? line.timestamp : nil,
                end: line.isSynchronized ? line.endTimestamp : nil,
                speaker: line.voice.rawValue,
                translation: LyricCompanionTextPolicy.translation(
                    for: line,
                    translatedText: translations[line.id],
                    readingIDs: readingIDs
                )
            )
        }
    }

    // MARK: Chrome

    private func revealChrome() {
        chromeActivity &+= 1
        guard !chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = true }
    }

    private func toggleChrome() {
        if chromeVisible, chromeMayHide {
            withAnimation(.easeInOut(duration: 0.25)) { chromeVisible = false }
        } else {
            revealChrome()
        }
    }

    #if os(iOS)
    /// 控件在时左右扫:整页跟着手指横着走,露出底下的播放页;松手时扫得够远或够快就顺着那个方向滑出去、
    /// 退出全屏,不够就弹回原处,轻扫只让控件多留一会儿,见 `SpokenWordTranscriptSwipePolicy`。
    /// 跟手的位移只写进 `dismissDrag`,这一页不跟着每帧重算。
    private func handleSwipe(_ phase: SpokenWordTranscriptSwipeGesture.Phase) {
        switch phase {
        case .began(let translation):
            isDraggingToClose = true
            dismissDrag?.follow(CGSize(width: translation.width, height: 0))
        case .changed(let translation):
            dismissDrag?.follow(CGSize(width: translation.width, height: 0))
        case .cancelled:
            isDraggingToClose = false
            dismissDrag?.settle()
        case .ended(let translation, velocityX: let velocityX):
            isDraggingToClose = false
            switch SpokenWordTranscriptSwipePolicy.outcome(
                translationX: Double(translation.width),
                translationY: Double(translation.height),
                velocityX: Double(velocityX),
                chromeVisible: chromeVisible
            ) {
            case .none:
                dismissDrag?.settle()
            case .revealChrome:
                dismissDrag?.settle()
                revealChrome()
            case .dismiss:
                if let dismissDrag {
                    dismissDrag.close(translation.width < 0 ? .left : .right, velocity: velocityX)
                } else {
                    dismiss()
                }
            }
        }
    }
    #endif

    /// 顶上只有关闭键与章节名(菜单在底下那一排)。整条往下拖一段就退出全屏,和拉下一张卡片一样
    /// (见 `SpokenWordTranscriptPullDown`)。
    @ViewBuilder
    private func topBar(palette: SpokenWordTranscriptPalette) -> some View {
        let showsBar = chromeVisible || isSearching
        Group {
            if isSearching {
                searchBar(palette: palette)
            } else {
                HStack(spacing: 12) {
                    chromeButton(systemImage: "xmark", palette: palette) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text("close"))
                    Spacer(minLength: 8)
                    Text(verbatim: title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.dimmedText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // 和左边的关闭键一样宽,章节名才居中。
                    Color.clear
                        .frame(width: 38, height: 38)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .modifier(SpokenWordTranscriptPullDown(
                    drag: dismissDrag,
                    onPullingChange: { pulling in
                        isDraggingToClose = pulling
                        if pulling { revealChrome() }
                    },
                    onDismiss: { dismiss() }
                ))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background {
            LinearGradient(
                colors: [palette.background, palette.background.opacity(0.92), palette.background.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
        .opacity(showsBar ? 1 : 0)
        .allowsHitTesting(showsBar)
        .background {
            // ⌘F 直接搜。
            Button { beginSearch() } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func chromeButton(
        systemImage: String,
        palette: SpokenWordTranscriptPalette,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 38, height: 38)
                .background(palette.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// 底下那一排最右边的菜单键,菜单从它上方弹出。
    private func menuButton(palette: SpokenWordTranscriptPalette) -> some View {
        Button {
            showsMenu = true
            revealChrome()
        } label: {
            SpokenWordTranscriptKeyLabel(systemImage: "line.3.horizontal", palette: palette)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("transcript_reader_menu"))
        .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
            menuCard
                .presentationCompactAdaptation(.popover)
                .onDisappear { performPendingMenuAction() }
        }
    }

    /// 底下那一排最左边的「跟随播放」:自己滑开了才亮起来,点了回到正在念的那一句;正在跟着时按灰、不可点。
    private func followButton(palette: SpokenWordTranscriptPalette, proxy: ScrollViewProxy) -> some View {
        let isFollowing = followsPlayback || currentIndex == nil
        return Button {
            followsPlayback = true
            scrollToCurrent(proxy, animated: true)
            revealChrome()
        } label: {
            SpokenWordTranscriptKeyLabel(systemImage: "text.line.first.and.arrowtriangle.forward", palette: palette)
        }
        .buttonStyle(.plain)
        .disabled(isFollowing)
        .opacity(isFollowing ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.2), value: isFollowing)
        .accessibilityLabel(Text("transcript_follow_playback"))
    }

    /// 菜单(同 Apple 图书):目录、搜索、主题与设置、语速几行,底下一排书签与字号。
    private var menuCard: some View {
        VStack(spacing: 0) {
            menuRow("spoken_word_contents_title", systemImage: "list.bullet") { chooseMenuAction(.contents) }
            Divider()
            menuRow("transcript_reader_search", systemImage: "magnifyingglass") { chooseMenuAction(.search) }
            Divider()
            menuRow("transcript_reader_themes_settings", systemImage: "textformat.size") { chooseMenuAction(.settings) }
            Divider()
            playbackRateRow
            if let song = player.currentSong, SpokenWordTranscriptOffsetStore.shared.itemKey(for: song) != nil {
                Divider()
                SpokenWordTranscriptOffsetRow(scope: .item(song), compact: true)
                    .font(.body)
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 0) {
                menuIconButton("bookmark", label: "spoken_word_add_bookmark") {
                    addBookmark()
                    showsMenu = false
                }
                .symbolEffect(.bounce, value: bookmarkFeedbackToken)
                .disabled(player.currentSong == nil || player.isLiveRadio)
                Divider().frame(height: 28)
                menuIconButton("textformat.size.smaller", label: "transcript_reader_text_smaller") {
                    adjustFontSize(by: -2)
                }
                .disabled(fontSize <= SpokenWordTranscriptReaderPreferences.fontSizeRange.lowerBound)
                Divider().frame(height: 28)
                menuIconButton("textformat.size.larger", label: "transcript_reader_text_larger") {
                    adjustFontSize(by: 2)
                }
                .disabled(fontSize >= SpokenWordTranscriptReaderPreferences.fontSizeRange.upperBound)
            }
        }
        .frame(width: 268)
    }

    private func menuRow(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(titleKey)
                Spacer(minLength: 8)
                Image(systemName: systemImage)
                    .frame(width: 22)
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 语速:书按书记、播客一档,和播放页上的语速键改的是同一个值。在这一行里直接减、加一档,
    /// 不再从菜单卡上再弹一层下拉菜单(弹出、收回时这一行整个放大缩回,卡片跟着闪)。
    private var playbackRateRow: some View {
        let rate = player.currentSpokenWordRate
        let slower = SpokenWordPlaybackRatePolicy.adjacentPreset(to: rate, faster: false)
        let faster = SpokenWordPlaybackRatePolicy.adjacentPreset(to: rate, faster: true)
        return HStack(spacing: 2) {
            Text("spoken_word_speed_short")
            Spacer(minLength: 8)
            rateStepButton("minus", label: "transcript_reader_speed_slower", target: slower)
            Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(rate)))
                .animation(.snappy(duration: 0.2), value: rate)
                .frame(minWidth: 50)
            rateStepButton("plus", label: "transcript_reader_speed_faster", target: faster)
        }
        .font(.body)
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: rate)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("spoken_word_speed_short"))
        .accessibilityValue(Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                if let faster { player.setSpokenWordRateForCurrentBook(faster) }
            case .decrement:
                if let slower { player.setSpokenWordRateForCurrentBook(slower) }
            @unknown default:
                break
            }
        }
    }

    /// 语速那一行的减、加键;到头了变淡。
    private func rateStepButton(_ systemImage: String, label: LocalizedStringKey, target: Float?) -> some View {
        Button {
            if let target { player.setSpokenWordRateForCurrentBook(target) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.3 : 1)
        .accessibilityLabel(Text(label))
    }

    private func menuIconButton(
        _ systemImage: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func chooseMenuAction(_ action: MenuAction) {
        pendingMenuAction = action
        showsMenu = false
    }

    private func performPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        switch action {
        case .contents: showsContents = true
        case .settings: showsSettings = true
        case .search: beginSearch()
        }
    }

    private func adjustFontSize(by delta: Double) {
        let range = SpokenWordTranscriptReaderPreferences.fontSizeRange
        fontSize = min(max(fontSize + delta, range.lowerBound), range.upperBound)
    }

    private func addBookmark() {
        let added = player.addSpokenWordBookmark()
        if added { bookmarkFeedbackToken += 1 }
        withAnimation(.easeInOut(duration: 0.25)) { bookmarkNotice = added ? .added : .exists }
    }

    @ViewBuilder
    private func bookmarkNoticeView(palette: SpokenWordTranscriptPalette) -> some View {
        if let bookmarkNotice {
            let titleKey: LocalizedStringKey = bookmarkNotice == .added
                ? "transcript_reader_bookmark_added"
                : "transcript_reader_bookmark_exists"
            Label(titleKey, systemImage: bookmarkNotice == .added ? "bookmark.fill" : "bookmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 64)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// 底下:进度条、时间,以及一排键 —— 跟随播放 · 快退 · 播放 · 快进 · 菜单。
    private func bottomBar(palette: SpokenWordTranscriptPalette, proxy: ScrollViewProxy) -> some View {
        // 搜索打字时让开键盘上方那块,不跟着键盘浮上来挡字。
        let showsTransport = chromeVisible && !searchFieldFocused
        return SpokenWordTranscriptTransportBar(
            player: player,
            palette: palette,
            onScrubbingChange: { scrubbing in
                isScrubbing = scrubbing
                revealChrome()
            },
            onInteraction: { revealChrome() },
            leading: { followButton(palette: palette, proxy: proxy) },
            trailing: { menuButton(palette: palette) }
        )
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                colors: [palette.background.opacity(0), palette.background.opacity(0.92), palette.background],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        }
        .opacity(showsTransport ? 1 : 0)
        .allowsHitTesting(showsTransport)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // MARK: Search

    private var currentMatch: (paragraphID: Int, range: Range<Int>)? {
        guard let currentMatchIndex, searchMatches.indices.contains(currentMatchIndex) else { return nil }
        let match = searchMatches[currentMatchIndex]
        guard let id = paragraphID(of: match) else { return nil }
        return (id, match.range)
    }

    /// 同 Apple 播客的文稿搜索:顶上一条输入框,写着第几处 / 共几处,上下键逐处跳并标亮。
    private func searchBar(palette: SpokenWordTranscriptPalette) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.dimmedText)
                TextField("transcript_reader_search_prompt", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit { stepMatch(forward: true) }
                if let countText = matchCountText {
                    Text(verbatim: countText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(palette.dimmedText)
                        .lineLimit(1)
                        .fixedSize()
                }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(palette.dimmedText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("clear"))
                }
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(palette.controlFill, in: Capsule())
            chromeButton(systemImage: "chevron.up", palette: palette) { stepMatch(forward: false) }
                .disabled(searchMatches.isEmpty)
                .opacity(searchMatches.isEmpty ? 0.4 : 1)
                .accessibilityLabel(Text("transcript_reader_previous_match"))
            chromeButton(systemImage: "chevron.down", palette: palette) { stepMatch(forward: true) }
                .disabled(searchMatches.isEmpty)
                .opacity(searchMatches.isEmpty ? 0.4 : 1)
                .accessibilityLabel(Text("transcript_reader_next_match"))
            Button {
                endSearch()
            } label: {
                Text("done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .padding(.leading, 4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    /// 「3/12」;搜完没有是「无结果」,还在搜或没输入时不写。
    private var matchCountText: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query == searchedQuery else { return nil }
        guard let currentMatchIndex, !searchMatches.isEmpty else {
            return String(localized: "transcript_reader_search_no_results")
        }
        return String(
            format: String(localized: "transcript_reader_search_count_format"),
            currentMatchIndex + 1,
            searchMatches.count
        )
    }

    private func beginSearch() {
        withAnimation(.easeInOut(duration: 0.2)) { isSearching = true }
        revealChrome()
        Task { @MainActor in
            // 输入框出来以后再给焦点,早了键盘不弹。
            try? await Task.sleep(for: .milliseconds(150))
            searchFieldFocused = true
        }
    }

    private func endSearch() {
        searchFieldFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { isSearching = false }
        searchText = ""
        searchedQuery = ""
        searchMatches = []
        matchRangesByParagraph = [:]
        currentMatchIndex = nil
        revealChrome()
    }

    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSearching, !query.isEmpty else {
            if !searchMatches.isEmpty { searchMatches = [] }
            if !matchRangesByParagraph.isEmpty { matchRangesByParagraph = [:] }
            currentMatchIndex = nil
            searchedQuery = ""
            return
        }
        // 边打边搜,停一下再算。
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let snapshot = paragraphs
        let found = await Task.detached(priority: .userInitiated) {
            SpokenWordTranscriptReadingPolicy.searchMatches(for: query, in: snapshot)
        }.value
        guard !Task.isCancelled else { return }
        var ranges: [Int: [Range<Int>]] = [:]
        for match in found where snapshot.indices.contains(match.paragraph) {
            ranges[snapshot[match.paragraph].id, default: []].append(match.range)
        }
        searchMatches = found
        matchRangesByParagraph = ranges
        searchedQuery = query
        currentMatchIndex = Policy.initialMatchIndex(found, currentParagraph: currentIndex)
        matchScrollToken &+= 1
    }

    private func stepMatch(forward: Bool) {
        guard let next = Policy.steppedMatchIndex(currentMatchIndex, count: searchMatches.count, forward: forward)
        else { return }
        currentMatchIndex = next
        matchScrollToken &+= 1
    }

    private func scrollToCurrentMatch(_ proxy: ScrollViewProxy) {
        guard let match = currentMatch else { return }
        // 看命中的地方,不再被播放拉回去;点「跟随播放」再接上。
        followsPlayback = false
        withAnimation(.easeInOut(duration: 0.35)) {
            proxy.scrollTo(match.paragraphID, anchor: .center)
        }
    }

    #if DEBUG
    /// 无人值守截图:`PRIMUSE_DEBUG_TRANSCRIPT_READER` = `menu` | `settings` | `contents` | `search:<词>` | `bookmark`。
    /// 配 `PRIMUSE_DEBUG_PLAYER_MODE=transcriptReader` 从播放页直接打开文稿。
    private func runDebugAutomation() async {
        guard let mode = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_TRANSCRIPT_READER"] else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        switch mode {
        case "menu":
            showsMenu = true
        case "settings":
            showsSettings = true
        case "contents":
            showsContents = true
        case "bookmark":
            addBookmark()
        default:
            guard mode.hasPrefix("search:") else { return }
            beginSearch()
            searchText = String(mode.dropFirst("search:".count))
        }
    }
    #endif
}

#if os(iOS)
/// 文稿上的左右扫,控件出来时用来退出全屏(见 `SpokenWordTranscriptSwipePolicy`)。UIKit 的拖动手势挂在文稿上:
/// 只在横着走时接手,和文稿自己的上下滚动同时识别、互不抢;点段落、点空白处照旧。
/// 认定是横扫之后每一步都报出来,整页跟着手指走;被打断(控件收起停掉了手势、来电)也报,好把整页放回原处。
private struct SpokenWordTranscriptSwipeGesture: UIGestureRecognizerRepresentable {
    enum Phase {
        /// 认定是横扫,开始跟手。
        case began(CGSize)
        case changed(CGSize)
        /// 松手:位移与横向速度(点/秒)。
        case ended(CGSize, velocityX: CGFloat)
        /// 被打断或没认成。
        case cancelled
    }

    let isEnabled: Bool
    let onPhase: (Phase) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // 整页跟着这个手势走,按窗口坐标量,不受整页自己的位移影响。
        let point = recognizer.translation(in: nil)
        let translation = CGSize(width: point.x, height: point.y)
        switch recognizer.state {
        case .began:
            onPhase(.began(translation))
        case .changed:
            onPhase(.changed(translation))
        case .ended:
            onPhase(.ended(translation, velocityX: recognizer.velocity(in: nil).x))
        case .cancelled, .failed:
            onPhase(.cancelled)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = recognizer.view else { return false }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            return SpokenWordTranscriptSwipePolicy.shouldBegin(
                translationX: Double(translation.x),
                translationY: Double(translation.y),
                velocityX: Double(velocity.x),
                velocityY: Double(velocity.y)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let scrollView = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scrollView.panGestureRecognizer
        }
    }
}
#endif

/// 全屏文稿跟手退出(#320)。左右扫、顶栏往下拉时整页跟着手指走,露出底下的播放页;松手够远就顺着那个方向
/// 滑出屏幕,再不带动画地关掉全屏(不再走系统往下滑的那一下),不够就弹回原处。减弱动态效果时不跟手,
/// 够远时原地淡出再关。
///
/// 每帧变的位移只有 `SpokenWordTranscriptDismissOffset` 读:文稿可能上千段,文稿页不能跟着每帧重算。
/// 文稿页从环境里拿到的一直是同一个对象,只往里写,不读位移。
@MainActor
@Observable
final class SpokenWordTranscriptDismissDrag {
    enum Exit {
        case left, right, down
    }

    private enum Phase {
        case idle, following, closing
    }

    /// 整页此刻的位移与不透明度。
    private(set) var offset: CGSize = .zero
    private(set) var opacity: Double = 1
    /// 滑出去(或淡出)走完了,外面那层据此关掉全屏。
    private(set) var isClosed = false
    @ObservationIgnored private var phase = Phase.idle
    /// 整页连同安全区的大小,滑出去要走多远。
    @ObservationIgnored var containerSize: CGSize = .zero
    /// 减弱动态效果时为假:不跟手,关的时候淡出。
    @ObservationIgnored var followsFinger = true

    /// 拖动中:左右扫只给横向,顶栏下拉只给往下。
    func follow(_ translation: CGSize) {
        guard followsFinger, phase != .closing else { return }
        phase = .following
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = translation
        }
    }

    /// 松手不关,或手势被打断:弹回原处。
    func settle() {
        guard phase == .following else { return }
        phase = .idle
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            offset = .zero
        }
    }

    /// 顺着 `exit` 那个方向滑出屏幕再关;`velocity` 是松手时那个轴上的速度(点/秒,带正负)。
    func close(_ exit: Exit, velocity: CGFloat) {
        guard phase != .closing else { return }
        phase = .closing
        guard followsFinger else {
            withAnimation(.easeOut(duration: 0.2)) {
                opacity = 0
            } completion: {
                self.isClosed = true
            }
            return
        }
        let measured = max(containerSize.width, containerSize.height)
        // 还没量到时也一定滑得出去。
        let travel = (measured > 0 ? measured : 2000) + 1
        let target: CGSize
        let remaining: CGFloat
        let speed: CGFloat
        switch exit {
        case .left:
            target = CGSize(width: -travel, height: 0)
            remaining = travel + offset.width
            speed = -velocity
        case .right:
            target = CGSize(width: travel, height: 0)
            remaining = travel - offset.width
            speed = velocity
        case .down:
            target = CGSize(width: 0, height: travel)
            remaining = travel - offset.height
            speed = velocity
        }
        withAnimation(.easeOut(duration: Self.exitDuration(remaining: remaining, speed: speed))) {
            offset = target
        } completion: {
            self.isClosed = true
        }
    }

    /// 接着松手时的速度走:ease-out 起步约是平均速度的 1.7 倍。慢慢拖过去松手的、甩得飞快的,
    /// 都落在 0.25–0.3 秒里。
    private static func exitDuration(remaining: CGFloat, speed: CGFloat) -> Double {
        guard remaining > 0, speed > 0 else { return 0.3 }
        return min(max(Double(remaining / speed) * 1.7, 0.25), 0.3)
    }
}

private struct SpokenWordTranscriptDismissDragKey: EnvironmentKey {
    static let defaultValue: SpokenWordTranscriptDismissDrag? = nil
}

extension EnvironmentValues {
    var spokenWordTranscriptDismissDrag: SpokenWordTranscriptDismissDrag? {
        get { self[SpokenWordTranscriptDismissDragKey.self] }
        set { self[SpokenWordTranscriptDismissDragKey.self] = newValue }
    }
}

/// 全屏文稿顶栏往下拉退出:整页跟着往下走,拉过原来那段距离松手就接着滑下去再关,不够就弹回。
/// 没有 `drag`(Mac 的弹出页)时不跟手,拉够了直接关,和原来一样。
/// 被系统打断(来电、拉下通知中心)时拖动走不到 onEnded,靠 `isPulling` 复位把整页放回原处。
private struct SpokenWordTranscriptPullDown: ViewModifier {
    let drag: SpokenWordTranscriptDismissDrag?
    /// 开始拉、拉完(或被打断)各报一次。
    let onPullingChange: (Bool) -> Void
    let onDismiss: () -> Void
    @GestureState private var isPulling = false

    func body(content: Content) -> some View {
        content
            .gesture(
                // 整页跟着这个手势走,本地坐标会跟着手指一起动,改用全局坐标。
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .updating($isPulling) { _, pulling, _ in
                        pulling = true
                    }
                    .onChanged { value in
                        drag?.follow(CGSize(width: 0, height: max(0, value.translation.height)))
                    }
                    .onEnded { value in
                        let translation = value.translation
                        guard translation.height > 60, abs(translation.width) < translation.height else {
                            drag?.settle()
                            return
                        }
                        if let drag {
                            drag.close(.down, velocity: value.velocity.height)
                        } else {
                            onDismiss()
                        }
                    }
            )
            .onChange(of: isPulling) { _, pulling in
                onPullingChange(pulling)
                if !pulling { drag?.settle() }
            }
    }
}

#if os(iOS)
/// 套在播放页全屏打开的文稿外面:给文稿页一个跟手退出用的 `SpokenWordTranscriptDismissDrag`,把全屏的底换成透明
/// (整页挪开时露出下面的播放页;文稿页自己铺满了底色),滑出去之后不带动画地关掉全屏。
struct SpokenWordTranscriptInteractiveDismiss: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag = SpokenWordTranscriptDismissDrag()

    func body(content: Content) -> some View {
        content
            .modifier(SpokenWordTranscriptDismissOffset(drag: drag))
            .environment(\.spokenWordTranscriptDismissDrag, drag)
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(
                    width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                    height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                )
            } action: { size in
                drag.containerSize = size
            }
            .onChange(of: reduceMotion, initial: true) { _, reduce in
                drag.followsFinger = !reduce
            }
            .onChange(of: drag.isClosed) { _, closed in
                guard closed else { return }
                // 整页已经滑出屏幕(或淡掉了),关全屏时不再走系统往下滑的那一下。改写弹出它的那个开关
                // (不用环境里的 dismiss),事务里关掉动画。
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isPresented = false
                }
            }
            .presentationBackground(.clear)
    }
}

/// 每帧只重算这一层:把跟手的位移和淡出套到整页上,文稿页本身不重建。
private struct SpokenWordTranscriptDismissOffset: ViewModifier {
    let drag: SpokenWordTranscriptDismissDrag

    func body(content: Content) -> some View {
        content
            // 整页当一块挪,里面自己带动画的零件不各走各的。
            .geometryGroup()
            .offset(drag.offset)
            .opacity(drag.opacity)
    }
}
#endif

/// 鼠标移动叫出控件的节流时间。改它不触发重画,所以是个引用。
private final class SpokenWordTranscriptHoverThrottle {
    var lastReveal = Date.distantPast
}

/// 全屏文稿的一段。只有自己的输入变了才重画:跟着念换句时只有正在念的那一段动。
private struct SpokenWordTranscriptParagraphRow: View, Equatable {
    enum Emphasis: Equatable {
        /// 没在播,或文稿不带时间:全是正文色。
        case plain
        /// 不是正在念的段。
        case dimmed
        /// 整段高亮。
        case paragraph
        /// 只亮段里的这一句。
        case segment(Int)
    }

    struct Style: Equatable {
        var font: Font
        var headingFont: Font
        var translationFont: Font
        var lineSpacing: CGFloat
        var translationLineSpacing: CGFloat
        /// 两端对齐时那一栏的宽度;nil 是左对齐。
        var justifiedWidth: CGFloat?
        var palette: SpokenWordTranscriptPalette
    }

    let paragraph: SpokenWordTranscriptReadingPolicy.Paragraph
    let emphasis: Emphasis
    let matches: [Range<Int>]
    let currentMatch: Range<Int>?
    let style: Style

    var body: some View {
        VStack(alignment: .leading, spacing: style.lineSpacing + 4) {
            Text(attributedText)
                .font(paragraph.isHeading ? style.headingFont : style.font)
                .lineSpacing(style.lineSpacing)
                .modifier(SpokenWordTranscriptJustification(width: justifiedWidth, text: paragraph.text))
                .frame(maxWidth: .infinity, alignment: .leading)
            // 双语:这一段的译文排在原文下面,字小一号、颜色淡一档(#320)。
            if let translation = paragraph.translation {
                Text(verbatim: translation)
                    .font(style.translationFont)
                    .lineSpacing(style.translationLineSpacing)
                    .foregroundStyle(translationColor)
                    .modifier(SpokenWordTranscriptJustification(width: justifiedWidth, text: translation))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 章节名和上一段多隔开一点,读起来是新的一章。
        .padding(.top, paragraph.isHeading ? style.lineSpacing + 12 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(paragraph.isHeading ? .isHeader : [])
        .animation(.easeInOut(duration: 0.25), value: emphasis)
    }

    /// 章节名不摊开。搜到的段也照常排:命中处的底色是跟着整行画的,一个字一个字挪开画时不一定跟着走。
    private var justifiedWidth: CGFloat? {
        paragraph.isHeading || !matches.isEmpty ? nil : style.justifiedWidth
    }

    /// 正在念的段(和没在播时)译文比原文淡一些;别的段跟原文一样压暗。
    private var translationColor: Color {
        switch emphasis {
        case .plain, .paragraph, .segment:
            style.palette.text.opacity(0.72)
        case .dimmed:
            style.palette.dimmedText
        }
    }

    private var attributedText: AttributedString {
        let palette = style.palette
        var text = AttributedString(paragraph.text)
        let characterCount = text.characters.count
        let base: Color
        switch emphasis {
        case .plain, .paragraph:
            base = palette.text
        case .dimmed, .segment:
            base = palette.dimmedText
        }
        text.foregroundColor = base
        if case let .segment(index) = emphasis,
           paragraph.segments.indices.contains(index),
           let range = Self.range(paragraph.segments[index].range, in: text, count: characterCount) {
            let spoken: Color = palette.text
            text[range].foregroundColor = spoken
        }
        for match in matches {
            guard let range = Self.range(match, in: text, count: characterCount) else { continue }
            let fill: Color = match == currentMatch ? palette.currentMatch : palette.match
            text[range].backgroundColor = fill
        }
        return text
    }

    /// 按字符数的位置换成富文本里的位置;越界(拼字形时少算多算了一个)就不标。
    private static func range(
        _ offsets: Range<Int>,
        in text: AttributedString,
        count: Int
    ) -> Range<AttributedString.Index>? {
        guard offsets.lowerBound >= 0, !offsets.isEmpty, offsets.upperBound <= count else { return nil }
        let characters = text.characters
        let lower = characters.index(characters.startIndex, offsetBy: offsets.lowerBound)
        let upper = characters.index(lower, offsetBy: offsets.count)
        return lower..<upper
    }
}

/// 有栏宽时给这段字套上两端对齐的画法;没有时照常左对齐。
private struct SpokenWordTranscriptJustification: ViewModifier {
    let width: CGFloat?
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if let width {
            content.textRenderer(SpokenWordTranscriptJustifiedRenderer(width: width, units: Array(text.utf16)))
        } else {
            content
        }
    }
}

/// 两端对齐(同 Apple 图书)。`Text` 只有居左、居中、居右,这里在画的时候把每一行(段末那行和换行前那行除外)
/// 差的宽度摊开:挨着汉字、假名的字缝各摊一份,西文摊在空格上,一行里只有一个长单词时才摊进字母之间。
/// 只挪字的位置不改折行,段落高度不变。
private struct SpokenWordTranscriptJustifiedRenderer: TextRenderer {
    /// 这一栏的宽度,每行排满到这么宽。
    let width: CGFloat
    /// 这段字的 UTF-16,按字形对应的位置认空格、汉字与换行。
    let units: [UInt16]

    /// 差得比这还多的行不摊开(多半是换行前的短行),摊开了字稀得没法读。
    private static let maximumStretchRatio: CGFloat = 0.3

    private enum Kind { case space, ideograph, lineBreak, other }

    private struct Glyph {
        let slice: Text.Layout.RunSlice
        let bounds: CGRect
        let kind: Kind
    }

    func sizeThatFits(proposal: ProposedViewSize, text: TextProxy) -> CGSize {
        // 字框占满整栏:摊开后的行画到栏的右沿,不能落到字框外面。
        let size = text.sizeThatFits(proposal)
        guard let proposed = proposal.width, proposed.isFinite else { return size }
        return CGSize(width: max(size.width, proposed), height: size.height)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // 字形对应的位置从这段字的第一个字算起。
        let base = layout.lazy.flatMap { $0 }.flatMap(\.characterIndices).min()
        for (index, line) in layout.enumerated() {
            guard index < layout.count - 1,
                  let base,
                  let glyphs = justifiedGlyphs(in: line, base: base) else {
                context.draw(line)
                continue
            }
            for (slice, offset) in glyphs {
                var shifted = context
                shifted.translateBy(x: offset, y: 0)
                shifted.draw(slice)
            }
        }
    }

    /// 这一行每个字形往右挪多少;不该摊开的行返回 nil。
    private func justifiedGlyphs(
        in line: Text.Layout.Line,
        base: Text.Layout.CharacterIndex
    ) -> [(Text.Layout.RunSlice, CGFloat)]? {
        var glyphs: [Glyph] = []
        var lastCharacter = 0
        for run in line {
            for slice in run {
                let offsets = slice.characterIndices.map { base.distance(to: $0) }
                let glyphKind = offsets.first.map(characterKind(at:)) ?? .other
                guard glyphKind != .lineBreak else { return nil }
                lastCharacter = max(lastCharacter, offsets.max() ?? 0)
                glyphs.append(Glyph(slice: slice, bounds: slice.typographicBounds.rect, kind: glyphKind))
            }
        }
        // 下一个字是换行:这一行是这一小段的最后一行。
        if characterKind(at: lastCharacter + 1) == .lineBreak { return nil }

        glyphs.sort { $0.bounds.minX < $1.bounds.minX }
        guard let first = glyphs.firstIndex(where: { $0.kind != .space }),
              let last = glyphs.lastIndex(where: { $0.kind != .space }),
              first < last else { return nil }
        let left = glyphs[first].bounds.minX
        let extra = width - (glyphs[last].bounds.maxX - left)
        guard extra > 0.5, extra <= width * Self.maximumStretchRatio else { return nil }

        var weights = (first..<last).map { Self.weight(glyphs[$0].kind, glyphs[$0 + 1].kind) }
        if weights.allSatisfy({ $0 == 0 }) {
            weights = Array(repeating: 1, count: weights.count)
        }
        let total = weights.reduce(0, +)

        var offset = -left
        return glyphs.indices.map { index in
            if index > first, index <= last {
                offset += extra * weights[index - first - 1] / total
            }
            return (glyphs[index].slice, offset)
        }
    }

    /// 两个相邻字形之间这道缝分多少。空格两边的缝都分;挨着汉字的缝分;西文单词里的字母之间不分。
    private static func weight(_ lhs: Kind, _ rhs: Kind) -> CGFloat {
        if lhs == .space || rhs == .space { return 1 }
        if lhs == .ideograph || rhs == .ideograph { return 1 }
        return 0
    }

    private func characterKind(at offset: Int) -> Kind {
        guard units.indices.contains(offset) else { return .other }
        switch units[offset] {
        case 0x0A, 0x0D, 0x2028, 0x2029:
            return .lineBreak
        case 0x09, 0x20, 0xA0, 0x3000:
            return .space
        case 0x2E80...0x2FFF, 0x3001...0x303F, 0x3040...0x30FF, 0x3100...0x312F, 0x31F0...0x31FF,
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
             // 扩展区的汉字是一对代理项,前一半落在这一段。
             0xD840...0xD87F:
            return .ideograph
        default:
            return .other
        }
    }
}

/// 文稿页底下的进度、时间与一排键。单独成一个视图:播放时钟只让这一块重画。
/// 两头的键由文稿页给(左边跟随播放、右边菜单),和中间三颗同一种画法。
private struct SpokenWordTranscriptTransportBar<Leading: View, Trailing: View>: View {
    let player: AudioPlayerService
    let palette: SpokenWordTranscriptPalette
    let onScrubbingChange: (Bool) -> Void
    let onInteraction: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var previewTime: TimeInterval?

    var body: some View {
        let displayedTime = previewTime ?? player.currentTime
        VStack(spacing: 2) {
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                interactionID: player.currentSong?.id,
                fillTint: palette.text,
                trackStyle: ProgressSlider.TrackStyle(
                    restingHeight: 3,
                    draggingHeight: 6,
                    trackColor: palette.text.opacity(0.15)
                ),
                onPreview: { time in
                    let wasScrubbing = previewTime != nil
                    previewTime = time
                    if wasScrubbing != (time != nil) { onScrubbingChange(time != nil) }
                },
                onSeek: { time in
                    player.seek(to: time)
                    onInteraction()
                }
            )
            HStack(spacing: 0) {
                Text(verbatim: displayedTime.formattedDuration)
                Spacer(minLength: 4)
                Text(verbatim: "-\(max(0, player.duration - displayedTime).formattedDuration)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.dimmedText)
            HStack(spacing: 0) {
                leading()
                Spacer(minLength: 4)
                transportButton(player.spokenWordSkipBackwardSymbol, label: "a11y_skip_backward") {
                    player.skipSpokenWordBackward()
                }
                transportButton(
                    player.isPlaying ? "pause.fill" : "play.fill",
                    label: player.isPlaying ? "a11y_pause" : "a11y_play",
                    isPrimary: true
                ) {
                    player.togglePlayPause()
                }
                transportButton(player.spokenWordSkipForwardSymbol, label: "a11y_skip_forward") {
                    player.skipSpokenWordForward()
                }
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    private func transportButton(
        _ systemImage: String,
        label: LocalizedStringKey,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            onInteraction()
        } label: {
            SpokenWordTranscriptKeyLabel(systemImage: systemImage, palette: palette, isPrimary: isPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// 文稿页底下那一排键共用的样子:播放键大一号,其余一样大;两头的跟随播放与菜单键也用它。
private struct SpokenWordTranscriptKeyLabel: View {
    let systemImage: String
    let palette: SpokenWordTranscriptPalette
    var isPrimary = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: isPrimary ? 28 : 21, weight: .semibold))
            .foregroundStyle(palette.text)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: isPrimary ? 60 : 52, height: 48)
            .contentShape(Rectangle())
    }
}

/// 「主题与设置」:外观、阅读主题、字体、字重、字号、行距、段距、分段方式、朗读高亮,以及滑动时要不要叫出控件。
/// 改了文稿那边立刻跟着变。
struct SpokenWordTranscriptTypographyPanel: View {
    @Binding var fontRawValue: String
    @Binding var fontWeightRawValue: String
    @Binding var fontSize: Double
    @Binding var lineSpacingRawValue: String
    @Binding var paragraphSpacingRawValue: String
    @Binding var themeRawValue: String
    @Binding var appearanceRawValue: String
    @Binding var highlightRawValue: String
    @Binding var customTextHex: String
    @Binding var customBackgroundHex: String
    @Binding var customDarkTextHex: String
    @Binding var customDarkBackgroundHex: String
    @Binding var revealsChromeOnScroll: Bool
    @Binding var paragraphModeRawValue: String
    /// 主题块按这个明暗画,和文稿那边看到的一样。
    let colorScheme: ColorScheme
    /// 「文稿时间」里「这一集 / 这本书」那一行调的是它;nil 时只有「所有文稿」。
    var offsetSong: Song? = nil
    /// 原文 / 双语 / 只看译文;这份文稿没有译文时是 nil,不给这一项(#320)。
    var textModeRawValue: Binding<String>? = nil
    /// 双语时译文的字号,0 = 跟着原文。
    @Binding var translationFontSize: Double
    @Binding var justifiesText: Bool
    @Binding var pageMargin: Double
    @Binding var showsScrollIndicator: Bool

    @Environment(\.dismiss) private var dismiss
    /// 「自定义」下面两个取色器改的是哪一套;打开时对准文稿此刻用的那一套。
    @State private var editsDarkCustom: Bool?

    private var customColors: SpokenWordTranscriptCustomColors {
        SpokenWordTranscriptCustomColors(
            lightText: customTextHex,
            lightBackground: customBackgroundHex,
            darkText: customDarkTextHex,
            darkBackground: customDarkBackgroundHex
        )
    }

    private var fontLibrary: PlayerTextFontLibrary { .shared }

    private var selectedFont: PlayerTextFont {
        PlayerTextFont(rawValue: fontRawValue) ?? .system
    }

    private var selectedWeight: SpokenWordTranscriptWeight {
        SpokenWordTranscriptWeight(rawValue: fontWeightRawValue) ?? .regular
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("transcript_reader_appearance") {
                    Picker("transcript_reader_appearance", selection: $appearanceRawValue) {
                        ForEach(SpokenWordTranscriptAppearance.allCases) { appearance in
                            Text(appearance.titleKey).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    themeGrid
                        .padding(.vertical, 4)
                    if themeRawValue == SpokenWordTranscriptTheme.custom.rawValue {
                        customColorRows
                    }
                } header: {
                    Text("transcript_reader_theme")
                } footer: {
                    if themeRawValue == SpokenWordTranscriptTheme.custom.rawValue {
                        Text("transcript_reader_custom_versions_footer")
                    }
                }
                Section {
                    PlayerTextFontPicker(selection: $fontRawValue, sampleWeight: selectedWeight.fontWeight)
                } header: {
                    Text("transcript_font")
                } footer: {
                    if let message = fontLibrary.failureMessage(for: selectedFont) {
                        Text(verbatim: message)
                    }
                }
                Section("transcript_reader_weight") {
                    Picker("transcript_reader_weight", selection: $fontWeightRawValue) {
                        ForEach(SpokenWordTranscriptWeight.allCases) { weight in
                            Text(weight.titleKey).tag(weight.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("transcript_font_size") {
                    fontSizeSlider($fontSize)
                }
                if let textModeRawValue {
                    translationSection(textModeRawValue)
                }
                Section {
                    if let offsetSong, SpokenWordTranscriptOffsetStore.shared.itemKey(for: offsetSong) != nil {
                        SpokenWordTranscriptOffsetRow(scope: .item(offsetSong))
                    }
                    SpokenWordTranscriptOffsetRow(scope: .all)
                } header: {
                    Text("transcript_offset_title")
                } footer: {
                    Text("transcript_offset_footer")
                }
                Section("transcript_line_spacing") {
                    spacingPicker("transcript_line_spacing", selection: $lineSpacingRawValue)
                }
                Section("transcript_paragraph_spacing") {
                    spacingPicker("transcript_paragraph_spacing", selection: $paragraphSpacingRawValue)
                }
                Section("transcript_reader_page_margin") {
                    Slider(
                        value: $pageMargin,
                        in: SpokenWordTranscriptReaderPreferences.pageMarginRange,
                        step: 4
                    )
                    .accessibilityLabel(Text("transcript_reader_page_margin"))
                }
                Section {
                    Toggle("transcript_reader_justify", isOn: $justifiesText)
                    Toggle("transcript_reader_scroll_indicator", isOn: $showsScrollIndicator)
                } footer: {
                    Text("transcript_reader_justify_footer")
                }
                Section {
                    Picker("transcript_reader_paragraphs", selection: $paragraphModeRawValue) {
                        ForEach(SpokenWordTranscriptReadingPolicy.ParagraphMode.allCases, id: \.self) { mode in
                            Text(paragraphModeTitleKey(mode)).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("transcript_reader_paragraphs")
                } footer: {
                    Text("transcript_reader_paragraphs_footer")
                }
                Section("transcript_reader_highlight") {
                    Picker("transcript_reader_highlight", selection: $highlightRawValue) {
                        ForEach(SpokenWordTranscriptHighlight.allCases) { highlight in
                            Text(highlight.titleKey).tag(highlight.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    Toggle("transcript_reader_reveal_on_scroll", isOn: $revealsChromeOnScroll)
                } footer: {
                    #if os(iOS)
                    Text("transcript_reader_reveal_on_scroll_footer_swipe")
                    #else
                    Text("transcript_reader_reveal_on_scroll_footer")
                    #endif
                }
            }
            .navigationTitle("transcript_reader_themes_settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
    }

    private func fontSizeSlider(_ value: Binding<Double>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "textformat.size.smaller")
                .foregroundStyle(.secondary)
            Slider(value: value, in: SpokenWordTranscriptReaderPreferences.fontSizeRange, step: 1)
            Image(systemName: "textformat.size.larger")
                .foregroundStyle(.secondary)
        }
    }

    /// 带译文的文稿:原文 / 双语 / 只看译文;双语时译文字号可以跟着原文,也可以单独调(#320)。
    @ViewBuilder
    private func translationSection(_ textMode: Binding<String>) -> some View {
        Section {
            Picker("transcript_reader_text_mode", selection: textMode) {
                ForEach(SpokenWordTranscriptReadingPolicy.TextMode.allCases, id: \.self) { mode in
                    Text(textModeTitleKey(mode)).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if textMode.wrappedValue == SpokenWordTranscriptReadingPolicy.TextMode.bilingual.rawValue {
                Toggle("lyrics_translation_font_follows_original", isOn: Binding(
                    get: { translationFontSize <= 0 },
                    set: { follows in
                        // 改成单独调时从此刻看到的大小起步,不低于滑杆的最小一档。
                        translationFontSize = follows
                            ? 0
                            : max(
                                SpokenWordTranscriptReaderPreferences.fontSizeRange.lowerBound,
                                (fontSize * SpokenWordTranscriptReaderPreferences.followingTranslationScale).rounded()
                            )
                    }
                ))
                if translationFontSize > 0 {
                    fontSizeSlider($translationFontSize)
                        .accessibilityLabel(Text("lyrics_translation_font_size"))
                }
            }
        } header: {
            Text("transcript_reader_text_mode")
        } footer: {
            Text("transcript_reader_text_mode_footer")
        }
    }

    private func textModeTitleKey(_ mode: SpokenWordTranscriptReadingPolicy.TextMode) -> LocalizedStringKey {
        switch mode {
        case .original: "transcript_reader_text_original"
        case .bilingual: "transcript_reader_text_bilingual"
        case .translation: "transcript_reader_text_translation"
        }
    }

    /// 两排各三块。不用 LazyVGrid:放在表单的分区里会反复量尺寸。
    private var themeGrid: some View {
        let themes = SpokenWordTranscriptTheme.allCases
        let half = (themes.count + 1) / 2
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(themes.prefix(half)) { themeTile($0) }
            }
            HStack(spacing: 10) {
                ForEach(themes.dropFirst(half)) { themeTile($0) }
            }
        }
    }

    /// 浅色、深色外观各一套:先挑改哪一套,再是文字与背景两个取色器。深色那套没调过时显示浅色那套的颜色,
    /// 一改就把两样都存下来;调过的可以一键改回「和浅色外观一样」。
    @ViewBuilder
    private var customColorRows: some View {
        let editsDark = editsDarkCustom ?? (colorScheme == .dark)
        Picker("transcript_reader_appearance", selection: Binding(
            get: { editsDark },
            set: { editsDarkCustom = $0 }
        )) {
            Text("transcript_reader_appearance_light").tag(false)
            Text("transcript_reader_appearance_dark").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        let shown = customColors.colors(for: editsDark ? .dark : .light)
        ColorPicker(
            "transcript_reader_custom_text_color",
            selection: customColorBinding(shown.text, isDark: editsDark, isText: true),
            supportsOpacity: false
        )
        ColorPicker(
            "transcript_reader_custom_background_color",
            selection: customColorBinding(shown.background, isDark: editsDark, isText: false),
            supportsOpacity: false
        )
        if editsDark, customColors.hasDarkVersion {
            Button("transcript_reader_custom_dark_reset") {
                customDarkTextHex = ""
                customDarkBackgroundHex = ""
            }
        }
    }

    private func customColorBinding(_ shownHex: String, isDark: Bool, isText: Bool) -> Binding<Color> {
        Binding(
            get: { Color(hex: SpokenWordTranscriptTheme.validHex(shownHex) ?? "808080") },
            set: { color in
                guard let value = SpokenWordTranscriptTheme.hex(from: color) else { return }
                if isDark {
                    // 深色那套头一回调:另一样先沿用浅色那套的颜色,两样一起存下来。
                    let current = customColors.colors(for: .dark)
                    customDarkTextHex = isText ? value : current.text
                    customDarkBackgroundHex = isText ? current.background : value
                } else if isText {
                    customTextHex = value
                } else {
                    customBackgroundHex = value
                }
            }
        )
    }

    private func themeTile(_ theme: SpokenWordTranscriptTheme) -> some View {
        let palette = theme.palette(for: colorScheme, custom: customColors)
        let isSelected = theme.rawValue == themeRawValue
        return Button {
            themeRawValue = theme.rawValue
        } label: {
            VStack(spacing: 6) {
                Text(verbatim: "Aa")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(palette.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : palette.text.opacity(0.18),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .overlay(alignment: .topTrailing) {
                        if theme == .custom {
                            Image(systemName: "paintpalette")
                                .font(.caption2)
                                .foregroundStyle(palette.text.opacity(0.7))
                                .padding(6)
                        }
                    }
                Text(theme.titleKey)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func paragraphModeTitleKey(_ mode: SpokenWordTranscriptReadingPolicy.ParagraphMode) -> LocalizedStringKey {
        switch mode {
        case .merged: "transcript_reader_paragraphs_merged"
        case .perCue: "transcript_reader_paragraphs_per_line"
        }
    }

    private func spacingPicker(_ titleKey: LocalizedStringKey, selection: Binding<String>) -> some View {
        Picker(titleKey, selection: selection) {
            ForEach(SpokenWordTranscriptSpacing.allCases) { spacing in
                Text(spacing.titleKey).tag(spacing.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// 文稿时间偏移的一行:− 秒数 +(#320)。正数是文稿往后挪,晚一点出来。
/// 「这一集 / 这本书」改的是当前这一项自己的那层,「所有文稿」改全局那层。
struct SpokenWordTranscriptOffsetRow: View {
    enum Scope {
        case item(Song)
        case all
    }

    let scope: Scope
    var compact = false

    private var store: SpokenWordTranscriptOffsetStore { .shared }

    private var itemKey: String? {
        guard case .item(let song) = scope else { return nil }
        return store.itemKey(for: song)
    }

    private var delay: TimeInterval {
        switch scope {
        case .item:
            return itemKey.flatMap(store.itemDelay(forKey:)) ?? 0
        case .all:
            return store.globalDelay
        }
    }

    private var titleKey: LocalizedStringKey {
        switch scope {
        case .all:
            return "transcript_offset_all"
        case .item(let song):
            if compact { return "transcript_offset_title" }
            let isPodcast = PodcastPlaybackSong.isEpisode(song) || SpokenWordStore.shared.isPodcast(song)
            return isPodcast ? "transcript_offset_this_episode" : "transcript_offset_this_book"
        }
    }

    var body: some View {
        let limit = SpokenWordTranscriptOffsetPolicy.limit
        HStack(spacing: 2) {
            Text(titleKey)
            Spacer(minLength: 8)
            stepButton("minus", label: "transcript_offset_earlier", disabled: delay <= -limit) {
                set(delay - SpokenWordTranscriptOffsetPolicy.step)
            }
            Text(verbatim: Self.valueText(delay))
                .monospacedDigit()
                .foregroundStyle(delay == 0 ? .secondary : .primary)
                .contentTransition(.numericText(value: delay))
                .animation(.snappy(duration: 0.2), value: delay)
                .frame(minWidth: 64)
                .contextMenu {
                    Button("transcript_offset_reset") { set(0) }
                        .disabled(delay == 0)
                }
            stepButton("plus", label: "transcript_offset_later", disabled: delay >= limit) {
                set(delay + SpokenWordTranscriptOffsetPolicy.step)
            }
        }
        .disabled(isUnavailable)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: delay)
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(titleKey))
        .accessibilityValue(Text(verbatim: Self.valueText(delay)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(delay + SpokenWordTranscriptOffsetPolicy.step)
            case .decrement: set(delay - SpokenWordTranscriptOffsetPolicy.step)
            @unknown default: break
            }
        }
    }

    private var isUnavailable: Bool {
        if case .item = scope { return itemKey == nil }
        return false
    }

    private func set(_ value: TimeInterval) {
        switch scope {
        case .all:
            store.setGlobalDelay(value)
        case .item:
            guard let itemKey else { return }
            store.setItemDelay(value, forKey: itemKey)
        }
    }

    private func stepButton(
        _ systemImage: String,
        label: LocalizedStringKey,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .accessibilityLabel(Text(label))
    }

    /// 「+1.5 秒」「−0.5 秒」「0 秒」。
    static func valueText(_ delay: TimeInterval) -> String {
        let number = delay.formatted(
            .number
                .precision(.fractionLength(0...1))
                .sign(strategy: .always(includingZero: false))
        )
        return String(format: String(localized: "transcript_offset_seconds_format"), number)
    }
}
