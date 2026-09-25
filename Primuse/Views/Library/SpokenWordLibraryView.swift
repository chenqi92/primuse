import PrimuseKit
import SwiftUI

/// The audiobooks, 评书/相声 series, radio dramas and lectures in the library,
/// as a bookshelf.
///
/// They are kept out of the songs, albums and artists surfaces — one book is a
/// single item that buries a music library — and listed here instead. Items
/// that share an album form one book, so a 200-episode series is one cover
/// with its own progress rather than 200 rows.
///
/// Three parts: the book being listened to as a large "now listening" card
/// with one Continue button, the unfinished books as a cover grid, and the
/// finished ones folded away underneath.
struct SpokenWordLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage("spokenWord.shelf.showsFinished") private var showsFinished = false

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private var books: [SpokenWordBook] {
        // `revision` is read so the shelf refreshes when a position is stored,
        // a chapter is finished or an item is reclassified.
        _ = store.revision
        return SpokenWordBookGrouping.books(
            from: library.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
    }

    private var tint: Color { ListeningSpace.spokenWord.tint }

    private var gridColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16, alignment: .top)]
        #endif
    }

    var body: some View {
        let all = books
        let songsByID = Dictionary(
            library.spokenWordSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let current = SpokenWordBookSupport.nowListening(in: all)
        let shelf = all.filter { !$0.isFinished && $0.id != current?.id }
        let finished = all.filter(\.isFinished)
            .sorted { ($0.lastListenedAt ?? .distantPast) > ($1.lastListenedAt ?? .distantPast) }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let current {
                    SpokenWordNowListeningCard(
                        book: current,
                        songs: current.items.compactMap { songsByID[$0.id] },
                        tint: tint
                    )
                    .contextMenu {
                        bookMenu(current, songs: current.items.compactMap { songsByID[$0.id] })
                    }
                }

                if !shelf.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("spoken_word_shelf_section")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: gridColumns, spacing: 22) {
                            ForEach(shelf) { book in
                                bookCell(book, songsByID: songsByID)
                            }
                        }
                    }
                }

                if !finished.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            pmWithAnimation(.panel) { showsFinished.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Text("spoken_word_finished")
                                    .font(.title3.weight(.semibold))
                                Text(verbatim: "\(finished.count)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showsFinished ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(.isHeader)

                        if showsFinished {
                            LazyVGrid(columns: gridColumns, spacing: 22) {
                                ForEach(finished) { book in
                                    bookCell(book, songsByID: songsByID)
                                }
                            }
                            .pmFadeTransition(motion: .panel)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("tab_spoken_word")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if all.isEmpty {
                ContentUnavailableView(
                    "tab_spoken_word",
                    systemImage: "books.vertical",
                    description: Text("spoken_word_empty_hint")
                )
            }
        }
    }

    @ViewBuilder
    private func bookCell(_ book: SpokenWordBook, songsByID: [String: Song]) -> some View {
        let songs = book.items.compactMap { songsByID[$0.id] }
        let cell = SpokenWordBookCoverCell(
            book: book,
            coverSong: songs.first,
            isPlaying: player.currentBookID == book.id,
            tint: tint
        )
        if book.items.count > 1 {
            NavigationLink {
                SpokenWordBookDetailView(bookID: book.id)
            } label: {
                cell
            }
            .buttonStyle(.pmPressable)
            .contextMenu { bookMenu(book, songs: songs) }
        } else {
            Button {
                SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
            } label: {
                cell
            }
            .buttonStyle(.pmPressable)
            .contentShape(Rectangle())
            .contextMenu { bookMenu(book, songs: songs) }
        }
    }

    @ViewBuilder
    private func bookMenu(_ book: SpokenWordBook, songs: [Song]) -> some View {
        Button {
            SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
        } label: {
            if book.isInProgress {
                Label(String(localized: "spoken_word_continue"), systemImage: "play.fill")
            } else {
                Label(String(localized: "spoken_word_start"), systemImage: "play.fill")
            }
        }
        Button {
            store.markFinished(!book.isFinished, songIDs: book.items.map(\.id))
        } label: {
            if book.isFinished {
                Label(String(localized: "spoken_word_mark_unfinished"), systemImage: "circle")
            } else {
                Label(String(localized: "spoken_word_mark_finished"), systemImage: "checkmark.circle")
            }
        }
        Button {
            store.setKind(.music, forSongIDs: book.items.map(\.id))
            library.refreshContentClassification()
        } label: {
            Label(String(localized: "mark_as_music"), systemImage: "music.note")
        }
        if book.lastListenedAt != nil {
            Button(role: .destructive) {
                for item in book.items { store.clearPosition(forSongID: item.id) }
                store.markFinished(false, songIDs: book.items.map(\.id))
            } label: {
                Label(
                    String(localized: "spoken_word_clear_progress"),
                    systemImage: "arrow.counterclockwise"
                )
            }
        }
    }
}

/// The book being listened to: large cover, where the listener is, and one
/// button that picks up exactly there (or pauses it while it plays).
private struct SpokenWordNowListeningCard: View {
    let book: SpokenWordBook
    let songs: [Song]
    let tint: Color

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let isThisBook = player.currentBookID == book.id
        let isPlayingThisBook = isThisBook && player.isPlaying
        VStack(alignment: .leading, spacing: 14) {
            Text("spoken_word_now_listening_section")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            details

            Button {
                if isThisBook {
                    player.togglePlayPause()
                } else {
                    SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
                }
            } label: {
                Group {
                    if isPlayingThisBook {
                        Label(String(localized: "pause"), systemImage: "pause.fill")
                    } else {
                        Label(String(localized: "spoken_word_continue"), systemImage: "play.fill")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(tint)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var details: some View {
        let content = HStack(alignment: .top, spacing: 14) {
            SpokenWordCover(song: songs.first, size: 112, cornerRadius: 12)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author = book.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let position = SpokenWordBookSupport.chapterPosition(book) {
                    Text(position)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let remaining = book.remainingDuration {
                    Text(String(
                        format: String(localized: "spoken_word_remaining_format"),
                        ChapterTimeFormatter.string(from: remaining)
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                ProgressView(value: book.fractionComplete)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())

        if book.items.count > 1 {
            NavigationLink {
                SpokenWordBookDetailView(bookID: book.id)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }
}

/// One book's chapters (its files, in reading order) with where the listener
/// is in each.
struct SpokenWordBookDetailView: View {
    let bookID: String

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private var book: SpokenWordBook? {
        _ = store.revision
        let items = library.spokenWordSongs
            .map { SpokenWordBookSupport.item(for: $0, store: store) }
        return SpokenWordBookGrouping.books(from: items).first { $0.id == bookID }
    }

    var body: some View {
        let songsByID = Dictionary(
            library.spokenWordSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        Group {
            if let book {
                let songs = book.items.compactMap { songsByID[$0.id] }
                List {
                    Section {
                        header(book, songs: songs)
                            .listRowSeparator(.hidden)
                    }
                    Section {
                        ForEach(Array(book.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                SpokenWordBookSupport.play(book, songs: songs, from: item.id, player: player)
                            } label: {
                                SpokenWordChapterItemRow(
                                    item: item,
                                    number: index + 1,
                                    isResumeItem: item.id == book.resumeItemID && book.isInProgress,
                                    isPlaying: player.currentSong?.id == item.id
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    store.markFinished(!item.isFinished, songIDs: [item.id])
                                } label: {
                                    Label(
                                        item.isFinished
                                            ? String(localized: "spoken_word_mark_unfinished")
                                            : String(localized: "spoken_word_mark_finished"),
                                        systemImage: item.isFinished ? "circle" : "checkmark.circle"
                                    )
                                }
                                Button {
                                    // Everything before this chapter counts as
                                    // heard: the usual way to pick up a series
                                    // that was started elsewhere.
                                    let earlier = book.items.prefix(index).map(\.id)
                                    store.markFinished(true, songIDs: Array(earlier))
                                } label: {
                                    Label(
                                        String(localized: "spoken_word_mark_previous_finished"),
                                        systemImage: "checkmark.circle.badge.questionmark"
                                    )
                                }
                                .disabled(index == 0)
                                if item.isInProgress {
                                    Button(role: .destructive) {
                                        store.clearPosition(forSongID: item.id)
                                    } label: {
                                        Label(
                                            String(localized: "spoken_word_clear_progress"),
                                            systemImage: "arrow.counterclockwise"
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .navigationTitle(book.title)
            } else {
                ContentUnavailableView("tab_spoken_word", systemImage: "books.vertical")
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .minimalNavigationDetail()
        #endif
    }

    private func header(_ book: SpokenWordBook, songs: [Song]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            SpokenWordCover(song: songs.first, size: 96, cornerRadius: 10)
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                if let author = book.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(SpokenWordBookSupport.summary(book))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if book.lastListenedAt != nil {
                    ProgressView(value: book.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(ListeningSpace.spokenWord.tint)
                }
                HStack(spacing: 8) {
                    Button {
                        SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
                    } label: {
                        Group {
                            if book.isInProgress {
                                Label(String(localized: "spoken_word_continue"), systemImage: "play.fill")
                            } else {
                                Label(String(localized: "spoken_word_start"), systemImage: "play.fill")
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ListeningSpace.spokenWord.tint)

                    SpokenWordBookSpeedMenu(bookID: book.id)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Rows

/// One book on the shelf: a square cover with its progress underneath, a
/// check when it has been heard to the end.
private struct SpokenWordBookCoverCell: View {
    let book: SpokenWordBook
    let coverSong: Song?
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    SpokenWordCover(song: coverSong, size: 200, cornerRadius: 10, fillsProposedSize: true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if book.isFinished {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, tint)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .padding(6)
                            .accessibilityLabel(Text("spoken_word_finished"))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Circle().fill(tint))
                            .padding(6)
                    }
                }

            // Always laid out so covers line up whether a book is started or
            // not; only drawn once there is progress to show.
            ProgressView(value: book.fractionComplete)
                .progressViewStyle(.linear)
                .tint(tint)
                .opacity(book.lastListenedAt != nil && !book.isFinished ? 1 : 0)
                .accessibilityHidden(book.lastListenedAt == nil || book.isFinished)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isPlaying ? tint : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(SpokenWordBookSupport.subtitle(book))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A book's cover: the first item's artwork, or the default cover.
private struct SpokenWordCover: View {
    let song: Song?
    let size: CGFloat
    let cornerRadius: CGFloat
    var fillsProposedSize = false

    var body: some View {
        CachedArtworkView(
            coverRef: song?.coverArtFileName,
            songID: song?.id,
            size: size,
            cornerRadius: cornerRadius,
            sourceID: song?.sourceID,
            filePath: song?.filePath,
            fileFormat: song?.fileFormat,
            fillsProposedSize: fillsProposedSize
        )
    }
}

private struct SpokenWordChapterItemRow: View {
    let item: SpokenWordBookItem
    let number: Int
    let isResumeItem: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if item.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else if isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(ListeningSpace.spokenWord.tint)
                } else {
                    Text("\(number)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 28, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(isPlaying ? ListeningSpace.spokenWord.tint : (item.isFinished ? .secondary : .primary))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if isResumeItem {
                        Text("spoken_word_resume_here")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ListeningSpace.spokenWord.tint)
                    }
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if item.isInProgress {
                    ProgressView(value: item.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(ListeningSpace.spokenWord.tint)
                        .frame(maxWidth: 200)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if item.isInProgress, let position = item.position, item.duration > 0 {
            return String(
                format: String(localized: "spoken_word_remaining_format"),
                ChapterTimeFormatter.string(from: max(0, item.duration - position))
            )
        }
        return item.duration > 0 ? ChapterTimeFormatter.string(from: item.duration) : ""
    }
}

/// A book's own speed on its page. "Default" follows the global spoken-word
/// speed; any other choice is remembered for this book only and applies at
/// once if it is playing.
private struct SpokenWordBookSpeedMenu: View {
    let bookID: String

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        _ = SpokenWordStore.shared.revision
        let hasOwnRate = SpokenWordStore.shared.playbackRate(forBookID: bookID) != nil
        let rate = player.spokenWordRate(forBookID: bookID)
        let globalRate = SpokenWordPlaybackRatePolicy.clamped(player.playbackSettings.spokenWordPlaybackRate)
        return Menu {
            Button {
                player.setSpokenWordRate(nil, forBookID: bookID)
            } label: {
                let title = String(
                    format: String(localized: "spoken_word_book_speed_default_format"),
                    SpokenWordPlaybackRatePolicy.label(for: globalRate)
                )
                if hasOwnRate {
                    Text(verbatim: title)
                } else {
                    Label(title, systemImage: "checkmark")
                }
            }
            Divider()
            ForEach(SpokenWordPlaybackRatePolicy.presets, id: \.self) { preset in
                Button {
                    player.setSpokenWordRate(preset, forBookID: bookID)
                } label: {
                    let title = SpokenWordPlaybackRatePolicy.label(for: preset)
                    if hasOwnRate, abs(preset - rate) < 0.001 {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: title)
                    }
                }
            }
        } label: {
            Label(SpokenWordPlaybackRatePolicy.label(for: rate), systemImage: "gauge.with.dots.needle.67percent")
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text("spoken_word_book_speed"))
        .accessibilityValue(Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate)))
    }
}

// MARK: - Support

enum SpokenWordBookSupport {
    @MainActor
    static func item(for song: Song, store: SpokenWordStore) -> SpokenWordBookItem {
        let stored = store.position(forSongID: song.id)
        return SpokenWordBookItem(
            id: song.id,
            title: song.title,
            albumTitle: song.albumTitle,
            albumArtist: song.albumArtistName,
            artist: song.artistName,
            discNumber: song.discNumber,
            trackNumber: song.trackNumber,
            duration: song.duration > 0 ? song.duration : (stored?.duration ?? 0),
            fileName: song.filePath,
            position: stored?.position,
            positionUpdatedAt: stored?.updatedAt,
            finishedAt: store.finishedDate(forSongID: song.id)
        )
    }

    /// Plays the book as the queue, so finishing one chapter continues into
    /// the next one rather than into unrelated music. Starts from `itemID`,
    /// or from where the listener left off.
    @MainActor
    static func play(
        _ book: SpokenWordBook,
        songs: [Song],
        from itemID: String?,
        player: AudioPlayerService
    ) {
        guard let index = prepareStart(of: book, songs: songs, from: itemID) else { return }
        Task { await player.play(queue: songs, startingAt: index) }
    }

    /// The queue index playing `book` starts at: `itemID`, or where the
    /// listener left off. A finished item that is replayed starts again from
    /// the beginning, so its finished mark is lifted here. CarPlay shares
    /// this and plays through its own path.
    @MainActor
    static func prepareStart(of book: SpokenWordBook, songs: [Song], from itemID: String?) -> Int? {
        guard !songs.isEmpty else { return nil }
        let startID = SpokenWordCarPlayShelfPolicy.startItemID(for: book, requested: itemID) ?? songs[0].id
        let index = songs.firstIndex { $0.id == startID } ?? 0
        if SpokenWordStore.shared.isFinished(songID: songs[index].id) {
            SpokenWordStore.shared.markFinished(false, songIDs: [songs[index].id])
        }
        return index
    }

    /// The "now listening" book: the in-progress one heard most recently.
    static func nowListening(in books: [SpokenWordBook]) -> SpokenWordBook? {
        books.filter(\.isInProgress)
            .max { ($0.lastListenedAt ?? .distantPast) < ($1.lastListenedAt ?? .distantPast) }
    }

    /// "Chapter 3 of 12" for the item Continue starts from; nil for a
    /// single-item book or when every item is finished.
    static func chapterPosition(_ book: SpokenWordBook) -> String? {
        guard book.chapterCount > 1,
              let resumeID = book.resumeItemID,
              let index = book.items.firstIndex(where: { $0.id == resumeID }) else { return nil }
        return String(
            format: String(localized: "spoken_word_chapter_position_format"),
            index + 1,
            book.chapterCount
        )
    }

    static func subtitle(_ book: SpokenWordBook) -> String {
        var parts: [String] = []
        if let author = book.author { parts.append(author) }
        if book.chapterCount > 1 {
            parts.append(String(
                format: String(localized: "spoken_word_book_progress_format"),
                book.finishedCount,
                book.chapterCount
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// The header line under the author: chapter progress and total length.
    static func summary(_ book: SpokenWordBook) -> String {
        var parts: [String] = []
        if book.chapterCount > 1 {
            parts.append(String(
                format: String(localized: "spoken_word_book_progress_format"),
                book.finishedCount,
                book.chapterCount
            ))
        }
        if book.totalDuration > 0 {
            parts.append(ChapterTimeFormatter.string(from: book.totalDuration))
        }
        return parts.joined(separator: " · ")
    }
}
