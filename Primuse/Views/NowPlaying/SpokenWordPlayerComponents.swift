import CoreText
import SwiftUI
import PrimuseKit

// MARK: - Palette

/// The colours a spoken-word player part is drawn in. The iPhone player and
/// the Mac player each pass their own foreground tones, so the parts sit on
/// either background without knowing which it is.
struct SpokenWordPlayerPalette {
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
    /// 一块怎么画。`tiles` 是垫圆角底的方块(iPad、Mac、横屏);有声书竖版的两套设计不垫底:
    /// 墨黑是图标在上、字在下,暖白是图标与字排成一行。
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
    let onSleep: () -> Void
    let onContents: () -> Void
    /// 播客的「接下来」。给了才有这一块(书没有队列可看)。
    var onUpNext: (() -> Void)? = nil

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
        }
    }

    private var iconFont: Font {
        switch layout {
        case .tiles: .body.weight(.semibold)
        case .stacked: .title3.weight(.light)
        case .inline: .callout
        }
    }

    private var rateFont: Font {
        switch layout {
        case .tiles: .body.monospacedDigit().weight(.bold)
        case .stacked: .title3.monospacedDigit().weight(.light)
        case .inline: .callout.monospacedDigit().weight(.medium)
        }
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
                    .font(iconFont)
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

    @ViewBuilder
    private func tile<Icon: View, Caption: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder caption: () -> Caption
    ) -> some View {
        switch layout {
        case .tiles:
            VStack(spacing: 3) {
                icon()
                caption()
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .background(palette.tileFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .stacked:
            VStack(spacing: 6) {
                icon()
                    .frame(height: 24)
                caption()
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .contentShape(Rectangle())
        case .inline:
            HStack(spacing: 6) {
                icon()
                caption()
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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

// MARK: - Full-screen transcript

/// 全屏读文稿的偏好(本机记住)。
enum SpokenWordTranscriptReaderPreferences {
    static let fontKey = "primuse.transcriptReader.font"
    static let fontSizeKey = "primuse.transcriptReader.fontSize"
    static let lineSpacingKey = "primuse.transcriptReader.lineSpacing"
    static let paragraphSpacingKey = "primuse.transcriptReader.paragraphSpacing"
    static let themeKey = "primuse.transcriptReader.theme"
    static let appearanceKey = "primuse.transcriptReader.appearance"
    static let highlightKey = "primuse.transcriptReader.highlight"
    static let customTextColorKey = "primuse.transcriptReader.customTextColor"
    static let customBackgroundColorKey = "primuse.transcriptReader.customBackgroundColor"
    static let fontSizeRange: ClosedRange<Double> = 14...36
    static let defaultFontSize = 20.0
    static let defaultCustomTextHex = "3B3127"
    static let defaultCustomBackgroundHex = "EFE6D5"
    /// 播放中这么久没碰,顶上的关闭、菜单与底下的进度收起来。
    static let chromeAutoHideDelay: Duration = .seconds(3)
}

/// 文稿的字体。中文的几种排在前面(同 Apple 图书):苹方系统自带;宋体、楷体、圆体在 iOS 上要按需下载,
/// 下好之前与下载失败时先用系统字体显示。
enum SpokenWordTranscriptFont: String, CaseIterable, Identifiable {
    case system, pingFang, songti, kaiti, yuanti, serif, rounded, georgia, palatino, charter, iowan

    var id: String { rawValue }

    /// 中文字体的 PostScript 名:显示与下载都认它。
    var postScriptName: String? {
        switch self {
        case .pingFang: "PingFangSC-Regular"
        case .songti: "STSongti-SC-Regular"
        case .kaiti: "STKaitiSC-Regular"
        case .yuanti: "STYuanti-SC-Regular"
        default: nil
        }
    }

    /// `isAvailable` 为 false(还没下好、下载失败)时用系统字体。
    func font(size: CGFloat, isAvailable: Bool = true) -> Font {
        if let postScriptName {
            return isAvailable ? .custom(postScriptName, size: size) : .system(size: size)
        }
        switch self {
        case .serif: return .system(size: size, design: .serif)
        case .rounded: return .system(size: size, design: .rounded)
        case .georgia: return .custom("Georgia", size: size)
        case .palatino: return .custom("Palatino", size: size)
        case .charter: return .custom("Charter", size: size)
        case .iowan: return .custom("Iowan Old Style", size: size)
        default: return .system(size: size)
        }
    }

    /// 系统那几种与中文字体按语言叫,其余是字体本身的名字。
    var title: Text {
        switch self {
        case .system: Text("transcript_font_system")
        case .pingFang: Text("transcript_reader_font_pingfang")
        case .songti: Text("transcript_reader_font_songti")
        case .kaiti: Text("transcript_reader_font_kaiti")
        case .yuanti: Text("transcript_reader_font_yuanti")
        case .serif: Text("transcript_font_serif")
        case .rounded: Text("transcript_font_rounded")
        case .georgia: Text(verbatim: "Georgia")
        case .palatino: Text(verbatim: "Palatino")
        case .charter: Text(verbatim: "Charter")
        case .iowan: Text(verbatim: "Iowan")
        }
    }

    /// 字体块上的样字:中文字体写一个「字」,其余写 Aa。
    var sample: String { postScriptName == nil ? "Aa" : "\u{5B57}" }
}

/// 按需下载的中文字体。宋体、楷体、圆体在 iOS 上不预装,选了才去系统字体库里下;
/// 下过的字体每次启动后也要再走一遍同一个接口才能用(这次很快,不再联网)。
@MainActor
@Observable
final class SpokenWordTranscriptFontLibrary {
    enum State: Equatable {
        case available
        case needsDownload
        case downloading(Double)
        case failed
    }

    static let shared = SpokenWordTranscriptFontLibrary()

    private var states: [String: State] = [:]

    func state(of font: SpokenWordTranscriptFont) -> State {
        guard let name = font.postScriptName else { return .available }
        if let state = states[name] { return state }
        return Self.isInstalled(name) ? .available : .needsDownload
    }

    func isAvailable(_ font: SpokenWordTranscriptFont) -> Bool {
        state(of: font) == .available
    }

    /// 还不能用就去下载(或激活已经下过的)。正在下的不重复发起;失败过的再点一次重试。
    func prepare(_ font: SpokenWordTranscriptFont) {
        guard let name = font.postScriptName else { return }
        switch state(of: font) {
        case .available, .downloading:
            return
        case .needsDownload, .failed:
            break
        }
        states[name] = .downloading(0)
        Task {
            let succeeded = await Self.activate(postScriptName: name) { fraction in
                Task { @MainActor in self.updateProgress(fraction, for: name) }
            }
            states[name] = succeeded ? .available : .failed
        }
    }

    private func updateProgress(_ fraction: Double, for name: String) {
        guard case .downloading = states[name] else { return }
        states[name] = .downloading(fraction)
    }

    nonisolated static func isInstalled(_ postScriptName: String) -> Bool {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return (CTFontCopyPostScriptName(font) as String) == postScriptName
    }

    /// 系统的进度回调在 CoreText 自己的队列上跑,所以这里不带主线程隔离。
    private nonisolated static func activate(
        postScriptName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontNameAttribute as String: postScriptName] as CFDictionary
        )
        let once = SpokenWordTranscriptFontActivation()
        return await withCheckedContinuation { continuation in
            let started = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(
                [descriptor] as CFArray,
                nil
            ) { state, parameters in
                switch state {
                case .downloading:
                    let info = parameters as NSDictionary
                    if let percent = info[kCTFontDescriptorMatchingPercentage as String] as? Double {
                        progress(min(max(percent / 100, 0), 1))
                    }
                case .didFinish:
                    if once.claim() {
                        continuation.resume(returning: SpokenWordTranscriptFontLibrary.isInstalled(postScriptName))
                    }
                default:
                    break
                }
                return true
            }
            if !started, once.claim() {
                continuation.resume(returning: false)
            }
        }
    }
}

/// 下载结束只能报一次:续体恢复两次会直接崩。
private final class SpokenWordTranscriptFontActivation: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
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

/// 朗读高亮:整句只亮正在念的那一行字幕,整段亮正在念的整个段落。
enum SpokenWordTranscriptHighlight: String, CaseIterable, Identifiable {
    case sentence, paragraph

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .sentence: "transcript_reader_highlight_sentence"
        case .paragraph: "transcript_reader_highlight_paragraph"
        }
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
/// 长时间看不刺眼。「自定义」用自己挑的字色与底色,不分深浅。
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
        customTextHex: String,
        customBackgroundHex: String
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
            let background = Self.validHex(customBackgroundHex)
                ?? SpokenWordTranscriptReaderPreferences.defaultCustomBackgroundHex
            let text = Self.validHex(customTextHex)
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
/// 跟着播放走到正在念的那一句(或那一段);自己滑开了就不再拉回,点「跟随播放」再接上。
/// 点一段从那里播(暂停着也开始播)。顶上的关闭与菜单、底下的进度与播放键,播放中 3 秒不碰就收起,
/// 点空白处、滑动、拖进度时再出来。菜单里是目录、搜索、书签,以及主题、外观、字体排版与高亮方式。
struct SpokenWordTranscriptReader: View {
    let lines: [LyricLine]
    let title: String
    let player: AudioPlayerService

    private typealias Policy = SpokenWordTranscriptReadingPolicy
    private typealias Row = SpokenWordTranscriptParagraphRow

    private enum MenuAction { case contents, search, settings }
    private enum BookmarkNotice: Equatable { case added, exists }
    private struct SearchInput: Equatable {
        let paragraphs: [Policy.Paragraph]
        let query: String?
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @AppStorage(SpokenWordTranscriptReaderPreferences.fontKey)
    private var fontRawValue = SpokenWordTranscriptFont.system.rawValue
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
    @State private var paragraphs: [Policy.Paragraph] = []
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
    @FocusState private var searchFieldFocused: Bool

    private var font: SpokenWordTranscriptFont { SpokenWordTranscriptFont(rawValue: fontRawValue) ?? .system }
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
    private var size: CGFloat {
        CGFloat(min(max(fontSize, SpokenWordTranscriptReaderPreferences.fontSizeRange.lowerBound),
                    SpokenWordTranscriptReaderPreferences.fontSizeRange.upperBound))
    }

    /// 主题与外观选定的明暗;主题块也按它画。
    private var appearanceScheme: ColorScheme { appearance.resolved(systemColorScheme) }

    private var palette: SpokenWordTranscriptPalette {
        theme.palette(for: appearanceScheme, customTextHex: customTextHex, customBackgroundHex: customBackgroundHex)
    }

    #if os(iOS)
    /// 外观不跟随系统(或自定义的底色定了深浅)时整页换过去,状态栏的字也跟着变。
    private var preferredScheme: ColorScheme? {
        theme == .custom || appearance != .system ? palette.colorScheme : nil
    }
    #endif

    /// 播放中、没开着菜单面板、没在搜索拖动滑动时,控件才会自己收起。旁白开着时一直显示。
    private var chromeMayHide: Bool {
        player.isPlaying && !voiceOverEnabled && !isSearching && !showsMenu && !showsSettings
            && !showsContents && !isScrolling && !isScrubbing && bookmarkNotice == nil
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
                fontSize: $fontSize,
                lineSpacingRawValue: $lineSpacingRawValue,
                paragraphSpacingRawValue: $paragraphSpacingRawValue,
                themeRawValue: $themeRawValue,
                appearanceRawValue: $appearanceRawValue,
                highlightRawValue: $highlightRawValue,
                customTextHex: $customTextHex,
                customBackgroundHex: $customBackgroundHex,
                colorScheme: appearanceScheme
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
        .preferredColorScheme(preferredScheme)
        #endif
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
        .task(id: lines) {
            let cues = Self.cues(from: lines)
            let updated = await Task.detached(priority: .userInitiated) {
                SpokenWordTranscriptReadingPolicy.paragraphs(from: cues)
            }.value
            guard !Task.isCancelled else { return }
            paragraphs = updated
        }
        .task {
            while !Task.isCancelled {
                updatePlaybackPosition()
                try? await Task.sleep(for: .milliseconds(400))
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
            SpokenWordTranscriptFontLibrary.shared.prepare(font)
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

    private func transcript(palette: SpokenWordTranscriptPalette) -> some View {
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
                    .onTapGesture { play(from: paragraph) }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 72)
            .padding(.bottom, 150)
            .background {
                // 段与段之间、两边的留白:点一下叫出或收起控件。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleChrome() }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .interacting:
                followsPlayback = false
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
        let isAvailable = SpokenWordTranscriptFontLibrary.shared.isAvailable(font)
        let headingSize: CGFloat = size * 1.15
        return Row.Style(
            font: font.font(size: size, isAvailable: isAvailable),
            headingFont: font.font(size: headingSize, isAvailable: isAvailable).weight(.semibold),
            lineSpacing: lineSpacing.lineSpacing(fontSize: size),
            palette: palette
        )
    }

    private var currentParagraphID: Int? {
        guard let currentIndex, paragraphs.indices.contains(currentIndex) else { return nil }
        return paragraphs[currentIndex].id
    }

    private func emphasis(for paragraph: Policy.Paragraph, currentID: Int?) -> Row.Emphasis {
        guard let currentID else { return .plain }
        guard paragraph.id == currentID else { return .dimmed }
        if highlight == .sentence, let currentSegment { return .segment(currentSegment) }
        return .paragraph
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

    private func updatePlaybackPosition() {
        let time = player.currentTime
        let index = Policy.paragraphIndex(at: time, in: paragraphs)
        var segment: Int?
        if highlight == .sentence, let index {
            segment = Policy.segmentIndex(at: time, in: paragraphs[index])
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

    static func cues(from lines: [LyricLine]) -> [SpokenWordTranscriptReadingPolicy.Cue] {
        lines.map { line in
            SpokenWordTranscriptReadingPolicy.Cue(
                text: line.text,
                start: line.isSynchronized ? line.timestamp : nil,
                end: line.isSynchronized ? line.endTimestamp : nil,
                speaker: line.voice.rawValue
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
                    menuButton(palette: palette)
                }
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

    private func menuButton(palette: SpokenWordTranscriptPalette) -> some View {
        chromeButton(systemImage: "line.3.horizontal", palette: palette) {
            showsMenu = true
            revealChrome()
        }
        .accessibilityLabel(Text("transcript_reader_menu"))
        .popover(isPresented: $showsMenu, arrowEdge: .top) {
            menuCard
                .presentationCompactAdaptation(.popover)
                .onDisappear { performPendingMenuAction() }
        }
    }

    /// 菜单(同 Apple 图书):目录、搜索、主题与设置三行,底下一排书签与字号。
    private var menuCard: some View {
        VStack(spacing: 0) {
            menuRow("spoken_word_contents_title", systemImage: "list.bullet") { chooseMenuAction(.contents) }
            Divider()
            menuRow("transcript_reader_search", systemImage: "magnifyingglass") { chooseMenuAction(.search) }
            Divider()
            menuRow("transcript_reader_themes_settings", systemImage: "textformat.size") { chooseMenuAction(.settings) }
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

    private func bottomBar(palette: SpokenWordTranscriptPalette, proxy: ScrollViewProxy) -> some View {
        // 搜索打字时让开键盘上方那块,不跟着键盘浮上来挡字。
        let showsTransport = chromeVisible && !searchFieldFocused
        return VStack(spacing: 10) {
            if !followsPlayback, currentIndex != nil {
                Button {
                    followsPlayback = true
                    scrollToCurrent(proxy, animated: true)
                } label: {
                    Label("transcript_follow_playback", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            SpokenWordTranscriptTransportBar(
                player: player,
                palette: palette,
                onScrubbingChange: { scrubbing in
                    isScrubbing = scrubbing
                    revealChrome()
                },
                onInteraction: { revealChrome() }
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
        }
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
        var lineSpacing: CGFloat
        var palette: SpokenWordTranscriptPalette
    }

    let paragraph: SpokenWordTranscriptReadingPolicy.Paragraph
    let emphasis: Emphasis
    let matches: [Range<Int>]
    let currentMatch: Range<Int>?
    let style: Style

    var body: some View {
        Text(attributedText)
            .font(paragraph.isHeading ? style.headingFont : style.font)
            .lineSpacing(style.lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 章节名和上一段多隔开一点,读起来是新的一章。
            .padding(.top, paragraph.isHeading ? style.lineSpacing + 12 : 0)
            .accessibilityAddTraits(paragraph.isHeading ? .isHeader : [])
            .animation(.easeInOut(duration: 0.25), value: emphasis)
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

/// 文稿页底下的进度与播放键。单独成一个视图:播放时钟只让这一块重画。
private struct SpokenWordTranscriptTransportBar: View {
    let player: AudioPlayerService
    let palette: SpokenWordTranscriptPalette
    let onScrubbingChange: (Bool) -> Void
    let onInteraction: () -> Void

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
                    .frame(minWidth: 64, alignment: .leading)
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
                Text(verbatim: "-\(max(0, player.duration - displayedTime).formattedDuration)")
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(palette.dimmedText)
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
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 28 : 21, weight: .semibold))
                .foregroundStyle(palette.text)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: isPrimary ? 60 : 52, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// 「主题与设置」:外观、阅读主题、字体、字号、行距、段距、朗读高亮。改了文稿那边立刻跟着变。
struct SpokenWordTranscriptTypographyPanel: View {
    @Binding var fontRawValue: String
    @Binding var fontSize: Double
    @Binding var lineSpacingRawValue: String
    @Binding var paragraphSpacingRawValue: String
    @Binding var themeRawValue: String
    @Binding var appearanceRawValue: String
    @Binding var highlightRawValue: String
    @Binding var customTextHex: String
    @Binding var customBackgroundHex: String
    /// 主题块按这个明暗画,和文稿那边看到的一样。
    let colorScheme: ColorScheme

    @Environment(\.dismiss) private var dismiss

    private var fontLibrary: SpokenWordTranscriptFontLibrary { .shared }

    private var selectedFont: SpokenWordTranscriptFont {
        SpokenWordTranscriptFont(rawValue: fontRawValue) ?? .system
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
                Section("transcript_reader_theme") {
                    themeGrid
                        .padding(.vertical, 4)
                    if themeRawValue == SpokenWordTranscriptTheme.custom.rawValue {
                        ColorPicker(
                            "transcript_reader_custom_text_color",
                            selection: colorBinding($customTextHex),
                            supportsOpacity: false
                        )
                        ColorPicker(
                            "transcript_reader_custom_background_color",
                            selection: colorBinding($customBackgroundHex),
                            supportsOpacity: false
                        )
                    }
                }
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(SpokenWordTranscriptFont.allCases) { font in
                                fontChip(font)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("transcript_font")
                } footer: {
                    if fontLibrary.state(of: selectedFont) == .failed {
                        Text("transcript_reader_font_download_failed")
                    }
                }
                Section("transcript_font_size") {
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: SpokenWordTranscriptReaderPreferences.fontSizeRange, step: 1)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("transcript_line_spacing") {
                    spacingPicker("transcript_line_spacing", selection: $lineSpacingRawValue)
                }
                Section("transcript_paragraph_spacing") {
                    spacingPicker("transcript_paragraph_spacing", selection: $paragraphSpacingRawValue)
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

    private func themeTile(_ theme: SpokenWordTranscriptTheme) -> some View {
        let palette = theme.palette(
            for: colorScheme,
            customTextHex: customTextHex,
            customBackgroundHex: customBackgroundHex
        )
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

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: SpokenWordTranscriptTheme.validHex(hex.wrappedValue) ?? "808080") },
            set: { color in
                if let value = SpokenWordTranscriptTheme.hex(from: color) { hex.wrappedValue = value }
            }
        )
    }

    private func fontChip(_ font: SpokenWordTranscriptFont) -> some View {
        let isSelected = font.rawValue == fontRawValue
        let state = fontLibrary.state(of: font)
        return Button {
            fontRawValue = font.rawValue
            fontLibrary.prepare(font)
        } label: {
            VStack(spacing: 4) {
                Text(verbatim: font.sample)
                    .font(font.font(size: 22, isAvailable: state == .available))
                font.title
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(minWidth: 64)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .overlay(alignment: .topTrailing) {
                fontStateBadge(state)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(fontStateAccessibilityText(state))
    }

    /// 要下载的标朵云,下载中画一圈进度,失败标个感叹号。
    @ViewBuilder
    private func fontStateBadge(_ state: SpokenWordTranscriptFontLibrary.State) -> some View {
        switch state {
        case .available:
            EmptyView()
        case .needsDownload:
            Image(systemName: "icloud.and.arrow.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(5)
        case let .downloading(fraction):
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.05, fraction))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            .padding(5)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(5)
        }
    }

    private func fontStateAccessibilityText(_ state: SpokenWordTranscriptFontLibrary.State) -> Text {
        switch state {
        case .available: Text(verbatim: "")
        case .needsDownload: Text("transcript_reader_font_needs_download")
        case .downloading: Text("transcript_reader_font_downloading")
        case .failed: Text("transcript_reader_font_download_failed")
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
