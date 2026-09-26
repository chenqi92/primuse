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

    static func bookTitle(_ player: AudioPlayerService) -> String {
        if let title = player.currentSpokenWordBook?.title, !title.isEmpty { return title }
        let album = player.currentSong?.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return album.isEmpty ? (player.currentSong?.title ?? "") : album
    }

    static func author(_ player: AudioPlayerService) -> String? {
        if let author = player.currentSpokenWordBook?.author, !author.isEmpty { return author }
        guard let song = player.currentSong else { return nil }
        let name = song.albumArtistName ?? song.artistName
        return name?.isEmpty == false ? name : nil
    }

    /// The part being heard: the chapter mark's title inside a one-file
    /// book, the file's title (with the chapter mark under it, if any) in a
    /// book of several files. Nil when it would only repeat the book title.
    static func partTitle(_ player: AudioPlayerService) -> String? {
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
        return String(
            format: String(localized: "spoken_word_part_remaining_format"),
            approximateDuration(listening)
        )
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

/// The two lines under the spoken-word progress bar's times: nothing here
/// needs a second clock — the parent progress bar already observes the play
/// head, so this is drawn inside it.
struct SpokenWordBookProgressRow: View {
    let palette: SpokenWordPlayerPalette
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        if let summary = player.spokenWordNowPlayingSummary, summary.partCount != nil || summary.bookRemaining != nil {
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

    @Environment(AudioPlayerService.self) private var player
    @State private var bookmarkFeedbackToken = 0

    var body: some View {
        HStack(spacing: 8) {
            rateTile
            sleepTile
            bookmarkTile
            if showsContents { contentsTile }
        }
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
                Text("spoken_word_book_speed")
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
        .accessibilityLabel(Text("spoken_word_book_speed"))
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

    private var contentsTile: some View {
        Button(action: onContents) {
            tile {
                Image(systemName: "list.bullet")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.primary)
            } caption: {
                Text("spoken_word_contents_title")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("spoken_word_contents_title"))
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
                        .fontDesign(.serif)
                        .foregroundStyle(palette.primary)
                        .lineLimit(titleLineLimit)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: frameAlignment)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("spoken_word_go_to_book"))
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
                    Text(verbatim: author)
                        .lineLimit(1)
                        .foregroundStyle(palette.secondary)
                }
                if alignment != .center { Spacer(minLength: 0) }
                if let position = SpokenWordPlayerText.partPosition(player.spokenWordNowPlayingSummary) {
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
        }
        .contentTransition(.opacity)
        .pmAnimation(.trackChange, value: player.currentSong?.id)
    }
}

extension SpokenWordPlayerHeading where Trailing == EmptyView {
    init(
        palette: SpokenWordPlayerPalette,
        titleFont: Font = .title2,
        partFont: Font = .body,
        alignment: HorizontalAlignment = .leading,
        titleLineLimit: Int = 2,
        onOpenBook: @escaping () -> Void,
        onOpenContents: @escaping () -> Void
    ) {
        self.init(
            palette: palette,
            titleFont: titleFont,
            partFont: partFont,
            alignment: alignment,
            titleLineLimit: titleLineLimit,
            onOpenBook: onOpenBook,
            onOpenContents: onOpenContents,
            trailing: { EmptyView() }
        )
    }
}

// MARK: - Part buttons

/// The small previous / next chapter buttons either side of the big skip
/// buttons. Chapter marks first, then the neighbouring file of the book.
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
        .accessibilityLabel(Text(forward ? "spoken_word_next_chapter" : "spoken_word_previous_chapter"))
    }
}
