import PrimuseKit
import SwiftUI

/// The audiobooks, 评书/相声 series, radio dramas and lectures in the library,
/// as a bookshelf.
///
/// They are kept out of the songs, albums and artists surfaces — one book is a
/// single item that buries a music library — and listed here instead. Items
/// that share an album form one book, so a 200-episode series is one row with
/// its own progress rather than 200 rows; what is being listened to comes
/// first.
struct SpokenWordLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private var books: [SpokenWordBook] {
        // `revision` is read so the shelf refreshes when a position is stored,
        // a chapter is finished or an item is reclassified.
        _ = store.revision
        return SpokenWordBookGrouping.books(
            from: library.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
    }

    var body: some View {
        let all = books
        let inProgress = all.filter(\.isInProgress)
        let songsByID = Dictionary(
            library.spokenWordSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        List {
            if !inProgress.isEmpty {
                Section("spoken_word_continue_section") {
                    ForEach(inProgress) { book in
                        bookRow(book, songsByID: songsByID, showsContinue: true)
                    }
                }
            }
            Section(inProgress.isEmpty ? "" : String(localized: "spoken_word_all_section")) {
                ForEach(all.sorted {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }) { book in
                    bookRow(book, songsByID: songsByID, showsContinue: false)
                }
            }
        }
        .listStyle(.plain)
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
    private func bookRow(
        _ book: SpokenWordBook,
        songsByID: [String: Song],
        showsContinue: Bool
    ) -> some View {
        let songs = book.items.compactMap { songsByID[$0.id] }
        if book.items.count > 1 {
            NavigationLink {
                SpokenWordBookDetailView(bookID: book.id)
            } label: {
                SpokenWordBookRow(
                    book: book,
                    coverSong: songs.first,
                    isPlaying: songs.contains { $0.id == player.currentSong?.id }
                )
            }
            .contextMenu { bookMenu(book, songs: songs) }
        } else {
            Button {
                SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
            } label: {
                SpokenWordBookRow(
                    book: book,
                    coverSong: songs.first,
                    isPlaying: songs.contains { $0.id == player.currentSong?.id }
                )
            }
            .buttonStyle(.plain)
            // A plain button only takes hits on its content's own shape, so the
            // row's padding would otherwise be dead space.
            .contentShape(Rectangle())
            .contextMenu { bookMenu(book, songs: songs) }
        }
    }

    @ViewBuilder
    private func bookMenu(_ book: SpokenWordBook, songs: [Song]) -> some View {
        Button {
            SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
        } label: {
            Label(
                book.isInProgress
                    ? String(localized: "spoken_word_continue")
                    : String(localized: "spoken_word_start"),
                systemImage: "play.fill"
            )
        }
        Button {
            store.markFinished(!book.isFinished, songIDs: book.items.map(\.id))
        } label: {
            Label(
                book.isFinished
                    ? String(localized: "spoken_word_mark_unfinished")
                    : String(localized: "spoken_word_mark_finished"),
                systemImage: book.isFinished ? "circle" : "checkmark.circle"
            )
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
            if let cover = songs.first {
                CachedArtworkView(
                    coverRef: cover.coverArtFileName,
                    songID: cover.id,
                    size: 96,
                    cornerRadius: 10,
                    sourceID: cover.sourceID,
                    filePath: cover.filePath,
                    fileFormat: cover.fileFormat
                )
            }
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
                        .tint(Color.accentColor)
                }
                Button {
                    SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
                } label: {
                    Label(
                        book.isInProgress
                            ? String(localized: "spoken_word_continue")
                            : String(localized: "spoken_word_start"),
                        systemImage: "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Rows

private struct SpokenWordBookRow: View {
    let book: SpokenWordBook
    let coverSong: Song?
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let song = coverSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 52,
                    cornerRadius: 8,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.body)
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                    .lineLimit(1)

                Text(SpokenWordBookSupport.subtitle(book))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if book.lastListenedAt != nil, !book.isFinished {
                    ProgressView(value: book.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                        .frame(maxWidth: 220)
                    if let remaining = book.remainingDuration {
                        Text(String(
                            format: String(localized: "spoken_word_remaining_format"),
                            ChapterTimeFormatter.string(from: remaining)
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            if book.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("spoken_word_finished"))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
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
                        .foregroundStyle(Color.accentColor)
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
                    .foregroundStyle(isPlaying ? Color.accentColor : (item.isFinished ? .secondary : .primary))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if isResumeItem {
                        Text("spoken_word_resume_here")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if item.isInProgress {
                    ProgressView(value: item.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
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
        guard !songs.isEmpty else { return }
        let startID = itemID ?? book.resumeItemID ?? songs[0].id
        let index = songs.firstIndex { $0.id == startID } ?? 0
        // A finished item that is replayed starts again from the beginning.
        if SpokenWordStore.shared.isFinished(songID: songs[index].id) {
            SpokenWordStore.shared.markFinished(false, songIDs: [songs[index].id])
        }
        Task { await player.play(queue: songs, startingAt: index) }
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
