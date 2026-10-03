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

    /// "本章还剩约 18 分钟", in listening time at the book's speed.
    static func partRemaining(_ player: AudioPlayerService) -> String? {
        guard let remaining = player.spokenWordPartRemaining else { return nil }
        let listening = SpokenWordNowPlayingPolicy.listeningTime(
            forContent: remaining,
            rate: player.currentSpokenWordRate
        )
        // 没有章节的播客单集只有它自己,说「剩余」,不说「本章」。
        let key: String.LocalizationValue = podcastEpisode(player) != nil && player.spokenWordChapters.isEmpty
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

/// Whole-book progress: a thin bar, the percentage and the time left in the
/// book. Part of the book's title block, apart from the scrubber and the
/// volume, which are about the part being heard. Reads stored positions, not
/// the clock, so it moves every few seconds and its host never redraws per tick.
struct SpokenWordBookProgressRow: View {
    let palette: SpokenWordPlayerPalette
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let store = SpokenWordStore.shared
        // Registers the row with the store, so the stored positions it reads
        // redraw it when they change.
        let _ = store.positions.count
        let _ = store.finishedAt.count
        // 播客单集不是书,进度条就是它自己的进度,不再另起一行「全书」。
        if !PodcastPlaybackSong.isEpisode(player.currentSong),
           let summary = player.spokenWordNowPlayingSummary(live: false),
           summary.partCount != nil || summary.bookRemaining != nil {
            HStack(spacing: 10) {
                Text(verbatim: SpokenWordPlayerText.bookFraction(summary.bookFraction))
                    .lineLimit(1)
                    .fixedSize()
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.tertiary.opacity(0.35))
                        Capsule()
                            .fill(palette.secondary)
                            .frame(width: max(3, proxy.size.width * summary.bookFraction))
                    }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
                if let remaining = SpokenWordPlayerText.bookRemaining(summary, rate: player.currentSpokenWordRate) {
                    Text(verbatim: remaining)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(palette.tertiary)
            .accessibilityElement(children: .combine)
        }
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
    let palette: SpokenWordPlayerPalette
    var showsContents = true
    var tileHeight: CGFloat = 56
    let onSleep: () -> Void
    let onContents: () -> Void
    /// 播客的「接下来」。给了才有这一块(书没有队列可看)。
    var onUpNext: (() -> Void)? = nil

    @Environment(AudioPlayerService.self) private var player
    @State private var bookmarkFeedbackToken = 0

    private var isPodcast: Bool { SpokenWordPlayerText.isPodcastEpisode(player) }

    var body: some View {
        HStack(spacing: 8) {
            rateTile
            sleepTile
            // 播客把「书签」让给「接下来」:书签仍在说明面板里,也能从那里加。
            // 目录常驻在旁边一栏时(iPad、Mac)位置够,书签留着。
            if !isPodcast || !showsContents || onUpNext == nil { bookmarkTile }
            if showsContents { contentsTile }
            if isPodcast, let onUpNext { upNextTile(onUpNext) }
        }
    }

    private func upNextTile(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tile {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
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
                    .font(.body.monospacedDigit().weight(.bold))
                    .foregroundStyle(palette.accent)
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
                    .font(.body.weight(.semibold))
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
                    .font(.body.weight(.semibold))
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
                    .font(.body.weight(.semibold))
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
    /// Whole-book progress under the narrator line.
    var showsBookProgress = true
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
                if let position = SpokenWordPlayerText.partPosition(player.spokenWordNowPlayingSummary(live: false)) {
                    Button(action: onOpenContents) {
                        HStack(spacing: 3) {
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
                    .accessibilityValue(Text(verbatim: position))
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: frameAlignment)

            if showsBookProgress {
                SpokenWordBookProgressRow(palette: palette)
                    .padding(.top, 2)
            }
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
        showsBookProgress: Bool = true,
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
            showsBookProgress: showsBookProgress,
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
