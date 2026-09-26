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

    var body: some View {
        ScrollView {
            SpokenWordShelf()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .navigationTitle("tab_spoken_word")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if library.spokenWordSongs.isEmpty {
                ContentUnavailableView(
                    "tab_spoken_word",
                    systemImage: "books.vertical",
                    description: Text("spoken_word_empty_hint")
                )
            }
        }
    }
}

/// 书架本身:在听的那本大卡、书架网格、折叠的已听完。有声页与首页的「有声」一面共用,
/// 外面的滚动容器与边距由放它的地方给。
struct SpokenWordShelf: View {
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
        [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 18, alignment: .top)]
        #else
        // Book covers are taller than they are wide: three to a row on a
        // phone in portrait instead of two oversized ones.
        [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 14, alignment: .top)]
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
            SpokenWordBookCover(song: songs.first, width: 90, cornerRadius: 10)
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
    /// 滚动位置单独放在一个可观察对象里: 每帧写它只会让滑块重画, 不会让整页
    /// (连同上面的分书)跟着重算。
    @State private var chapterScroll = SpokenWordChapterScrollState()

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
                let showsScrubber = SpokenWordChapterScrubber.isShown(chapterCount: book.items.count)
                ScrollViewReader { proxy in
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
                                // 给右缘的滑块让出位置, 长标题不会压在它下面。
                                .padding(.trailing, showsScrubber ? SpokenWordChapterScrubber.reservedWidth : 0)
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
                #if os(iOS)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    SpokenWordChapterScrubber.scrollFraction(
                        offset: geometry.contentOffset.y + geometry.contentInsets.top,
                        contentHeight: geometry.contentSize.height
                            + geometry.contentInsets.top + geometry.contentInsets.bottom,
                        visibleHeight: geometry.containerSize.height
                    )
                } action: { _, fraction in
                    chapterScroll.update(fraction: fraction)
                }
                .onScrollPhaseChange { _, phase in
                    chapterScroll.isScrolling = phase != .idle
                }
                .overlay(alignment: .trailing) {
                    if showsScrubber {
                        let items = book.items
                        SpokenWordChapterScrubber(
                            scroll: chapterScroll,
                            count: items.count,
                            title: { items[$0].title }
                        ) { index in
                            proxy.scrollTo(items[index].id, anchor: .top)
                        }
                    }
                }
                #endif
                }
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
            SpokenWordBookCover(song: songs.first, width: 96, cornerRadius: 10)
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

/// One book on the shelf: a book-shaped cover with its progress underneath, a
/// check when it has been heard to the end.
private struct SpokenWordBookCoverCell: View {
    let book: SpokenWordBook
    let coverSong: Song?
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpokenWordBookCover(song: coverSong, cornerRadius: 10, decodeSize: 240)
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

/// A book's cover, the first item's artwork, drawn the shape books are:
/// a portrait frame (`SpokenWordCoverLayout`) with the artwork fitted whole
/// inside it, never cropped to a square or stretched. Where a square or wide
/// cover leaves room, a blurred enlargement of the same art fills it.
/// Shared by the shelf, the book page and the home cards.
struct SpokenWordBookCover: View {
    let song: Song?
    /// Fixed width, height following the book shape; nil takes the width
    /// the container offers (a grid cell).
    var width: CGFloat? = nil
    var cornerRadius: CGFloat = 10
    /// Decode bucket; defaults to the frame's longer side.
    var decodeSize: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .aspectRatio(SpokenWordCoverLayout.aspectRatio, contentMode: .fit)
            .if(width != nil) { view in
                view.frame(width: width!, height: SpokenWordCoverLayout.height(forWidth: width!))
            }
            .overlay {
                CachedArtworkView(
                    coverRef: song?.coverArtFileName,
                    songID: song?.id,
                    size: decodeSize ?? width.map { SpokenWordCoverLayout.height(forWidth: $0) } ?? 200,
                    cornerRadius: 0,
                    sourceID: song?.sourceID,
                    filePath: song?.filePath,
                    fileFormat: song?.fileFormat,
                    placeholderIcon: "book.closed",
                    fillsProposedSize: true
                )
                .bookCoverLayout()
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
    }
}

/// Where the chapter list is scrolled to, kept apart from the page so a
/// scroll frame redraws only the scrubber.
@MainActor
@Observable
final class SpokenWordChapterScrollState {
    var fraction: Double = 0
    var isScrolling = false

    func update(fraction newValue: Double) {
        // Sub-pixel changes are not worth a redraw.
        guard abs(newValue - fraction) > 0.0005 else { return }
        fraction = newValue
    }
}

/// 章节很多时, 章节列表右缘的快速拖动条: 滑块跟着列表位置走, 按住拖动时
/// 列表跟手跳到对应章节, 旁边的气泡报出第几章与章节名。只抓滑块本身, 列表其余
/// 部分的点按和滚动照旧。
struct SpokenWordChapterScrubber: View {
    /// 少于这么多章时一屏两屏就翻完了, 不需要它。
    static let minimumChapterCount = 30
    /// 行尾给滑块留的宽度。
    static let reservedWidth: CGFloat = 14

    static func isShown(chapterCount: Int) -> Bool {
        #if os(iOS)
        chapterCount >= minimumChapterCount
        #else
        // Mac 的滚动条本身就能拖。
        false
        #endif
    }

    /// 0 在顶, 1 在底。
    static func scrollFraction(offset: Double, contentHeight: Double, visibleHeight: Double) -> Double {
        let scrollable = contentHeight - visibleHeight
        guard scrollable > 1, offset.isFinite else { return 0 }
        return min(1, max(0, offset / scrollable))
    }

    static func index(forFraction fraction: Double, count: Int) -> Int {
        guard count > 1, fraction.isFinite else { return 0 }
        return Int((min(1, max(0, fraction)) * Double(count - 1)).rounded())
    }

    let scroll: SpokenWordChapterScrollState
    let count: Int
    let title: (Int) -> String
    let onScrub: (Int) -> Void

    @State private var dragStartFraction: Double?
    @State private var dragFraction: Double?
    @State private var scrubbedIndex: Int?
    @State private var hapticTrigger = 0

    private let thumbHeight: CGFloat = 48
    private let verticalInset: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let track = max(1, geometry.size.height - verticalInset * 2 - thumbHeight)
            let fraction = dragFraction ?? scroll.fraction
            let thumbTop = verticalInset + track * CGFloat(min(1, max(0, fraction)))
            let isDragging = dragFraction != nil

            ZStack(alignment: .topTrailing) {
                Capsule()
                    .fill(ListeningSpace.spokenWord.tint)
                    .frame(width: isDragging ? 8 : 5, height: thumbHeight)
                    .opacity(isDragging || scroll.isScrolling ? 0.95 : 0.4)
                    // 比看到的滑块宽得多的抓取区, 手指不用对得很准。
                    .frame(width: 36, height: thumbHeight + 16)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(track: track))
                    .offset(y: thumbTop - 8)

                if let scrubbedIndex {
                    bubble(for: scrubbedIndex)
                        .offset(x: -40, y: bubbleTop(thumbTop: thumbTop, height: geometry.size.height))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(width: 280)
        .sensoryFeedback(.selection, trigger: hapticTrigger)
        .pmAnimation(.control, value: scrubbedIndex == nil)
        // 读屏用户照常滚列表; 这条只是给手指的捷径。
        .accessibilityHidden(true)
    }

    private func dragGesture(track: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = dragStartFraction ?? scroll.fraction
                if dragStartFraction == nil { dragStartFraction = start }
                let fraction = min(1, max(0, start + Double(value.translation.height / track)))
                dragFraction = fraction
                let index = Self.index(forFraction: fraction, count: count)
                guard index != scrubbedIndex else { return }
                scrubbedIndex = index
                hapticTrigger &+= 1
                onScrub(index)
            }
            .onEnded { _ in
                dragStartFraction = nil
                dragFraction = nil
                scrubbedIndex = nil
            }
    }

    private func bubble(for index: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(verbatim: "\(index + 1) / \(count)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(ListeningSpace.spokenWord.tint)
            Text(verbatim: title(index))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .trailing)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
    }

    /// 气泡与滑块中线对齐, 但不越出列表上下缘。
    private func bubbleTop(thumbTop: CGFloat, height: CGFloat) -> CGFloat {
        let bubbleHeight: CGFloat = 52
        let centered = thumbTop + thumbHeight / 2 - bubbleHeight / 2
        return min(max(0, centered), max(0, height - bubbleHeight))
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
            song: song,
            knownDuration: stored?.duration,
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
