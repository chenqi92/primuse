#if os(tvOS)
import SwiftUI
import PrimuseKit

// MARK: - 书的整理(与 iPhone / Mac 的 SpokenWordBookSupport 同一套规则)

/// 电视端的有声书整理。分组与排序用 PrimuseKit 的 `SpokenWordBookGrouping`,
/// 位置与「听完」来自与 iPhone / Mac 共用的 `SpokenWordStore`。
@MainActor
enum TVSpokenWordBooks {
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

    static func books(songs: [Song], store: SpokenWordStore) -> [SpokenWordBook] {
        SpokenWordBookGrouping.books(from: songs.map { item(for: $0, store: store) })
    }

    /// 作者 · 已听完几章。
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

    static func remaining(_ book: SpokenWordBook) -> String? {
        guard let remaining = book.remainingDuration, remaining > 0 else { return nil }
        return String(
            format: String(localized: "spoken_word_remaining_format"),
            duration(remaining)
        )
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(60, seconds)) ?? TVFmt.time(seconds)
    }
}

// MARK: - 「有声」页

/// tvOS「有声」一级页:「在听」一排大卡 + 书架封面网格 + 收起的「已听完」。
/// 选一本书就按章节顺序把整本书放进队列,从上次听到的那一章、那一秒接着播。
struct TVSpokenWordView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}
    /// 书的详情页(章节列表)弹层在不在:TVRoot 据此停掉播放快捷键、压住焦点换页。
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    @State private var selectedBook: SpokenWordBook?
    @State private var showsFinished = false
    @State private var opensPlayerAfterDetailDismissal = false

    private let columns = 5
    private let gap: CGFloat = 36

    var body: some View {
        let spokenStore = SpokenWordStore.shared
        let books = TVSpokenWordBooks.books(songs: store.library.spokenWordSongs, store: spokenStore)
        let listening = books.filter(\.isInProgress)
        let shelf = books.filter { !$0.isFinished }
        let finished = books.filter(\.isFinished)

        GeometryReader { geo in
            let contentW = geo.size.width - TVSpace.pageH * 2 - 28
            let cell = max(160, (contentW - gap * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 34) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text(String(localized: "listening_space_spoken_word"))
                            .tvFont(.pageTitle)
                            .foregroundStyle(TVColor.text)
                        if !books.isEmpty {
                            Text(String(format: String(localized: "tv_spoken_word_book_count"), books.count))
                                .tvFont(.caption)
                                .foregroundStyle(TVColor.textFaint)
                        }
                    }
                    .padding(.horizontal, 14)

                    if books.isEmpty {
                        TVEmptyState(
                            icon: "books.vertical",
                            title: String(localized: "tab_spoken_word"),
                            subtitle: String(localized: "spoken_word_empty_hint")
                        )
                        .frame(maxWidth: .infinity, minHeight: 520)
                    } else {
                        if !listening.isEmpty {
                            TVRow(label: String(localized: "tv_spoken_word_listening")) {
                                ForEach(listening) { book in
                                    TVSpokenWordListeningCard(book: book) { play(book) }
                                        .contextMenu { bookMenu(book) }
                                }
                            }
                        }
                        if !shelf.isEmpty {
                            section(
                                title: String(localized: "tv_spoken_word_bookshelf"),
                                books: shelf,
                                cell: cell
                            )
                        }
                        if !finished.isEmpty {
                            finishedSection(finished, cell: cell)
                        }
                    }
                }
                .padding(.horizontal, TVSpace.pageH - 14)
                .padding(.top, TVSpace.pageTop + 8)
                .padding(.bottom, TVSpace.pageBottom)
            }
            .focusSection()
        }
        .background(TVColor.bg)
        .fullScreenCover(item: $selectedBook, onDismiss: finishDetailDismissal) { book in
            TVSpokenWordBookDetailView(
                bookID: book.id,
                fallback: book,
                openPlayer: { opensPlayerAfterDetailDismissal = true }
            )
            .environment(store)
        }
        .onChange(of: selectedBook != nil) { _, active in onModalActivityChanged(active) }
        .onDisappear {
            if selectedBook != nil { onModalActivityChanged(false) }
        }
        .accessibilityIdentifier("tv.spokenWord.page")
    }

    private func section(title: String, books: [SpokenWordBook], cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.text)
                .padding(.horizontal, 14)
            grid(books, cell: cell)
        }
    }

    private func finishedSection(_ books: [SpokenWordBook], cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TVPillButton(
                title: String(localized: "spoken_word_finished") + " · \(books.count)",
                systemImage: showsFinished ? "chevron.down" : "chevron.right",
                isSelected: showsFinished
            ) {
                showsFinished.toggle()
            }
            .padding(.horizontal, 14)
            if showsFinished {
                grid(books, cell: cell)
            }
        }
    }

    private func grid(_ books: [SpokenWordBook], cell: CGFloat) -> some View {
        let items = Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: columns)
        return LazyVGrid(columns: items, alignment: .leading, spacing: gap) {
            ForEach(books) { book in
                TVSpokenWordBookCard(book: book, width: cell) { play(book) }
                    .contextMenu { bookMenu(book) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func bookMenu(_ book: SpokenWordBook) -> some View {
        Button { play(book) } label: {
            Label(
                book.isInProgress
                    ? String(localized: "spoken_word_continue")
                    : String(localized: "spoken_word_start"),
                systemImage: "play.fill"
            )
        }
        Button { selectedBook = book } label: {
            Label(String(localized: "tv_spoken_word_chapters"), systemImage: "list.bullet")
        }
    }

    private func play(_ book: SpokenWordBook) {
        if store.playSpokenWordBook(songIDs: book.items.map(\.id), startingAt: book.resumeItemID) {
            openPlayer()
        }
    }

    private func finishDetailDismissal() {
        onModalActivityChanged(false)
        if opensPlayerAfterDetailDismissal {
            opensPlayerAfterDetailDismissal = false
            openPlayer()
        }
    }
}

// MARK: - 卡片

/// 一本书的封面:用第一章的封面(有声书的章节通常共用一张)。
struct TVSpokenWordCover: View {
    @Environment(TVStore.self) private var store
    let book: SpokenWordBook
    let size: CGFloat
    var radius: CGFloat = TVRadius.cover

    var body: some View {
        let songID = book.resumeItem?.id ?? book.items.first?.id ?? ""
        let song = store.song(songID)
        let palette = store.artworkColors(forSongID: songID)
        TVArtworkView(
            coverKey: song?.albumID ?? "",
            artist: book.author ?? song?.artist ?? "",
            album: book.title,
            songID: songID,
            coverRef: song?.coverRef,
            tint: palette?.primary ?? TVColor.spokenWordSpace,
            tint2: palette?.secondary ?? .black,
            glyph: book.title.isEmpty ? "♪" : String(book.title.prefix(1)),
            size: size,
            radius: radius
        )
    }
}

/// 进度条:听完的显示满格和对勾。
struct TVSpokenWordProgressBar: View {
    let fraction: Double
    var finished = false

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(TVColor.divider)
                    Capsule().fill(TVColor.spokenWordSpace)
                        .frame(width: geo.size.width * max(0, min(1, fraction)))
                }
            }
            .frame(height: 6)
            if finished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TVColor.spokenWordSpace)
            }
        }
    }
}

/// 书架上的一本书:封面、进度条、书名、作者与章节进度。
struct TVSpokenWordBookCard: View {
    let book: SpokenWordBook
    let width: CGFloat
    var action: () -> Void

    var body: some View {
        TVFocusButton(ring: false, action: action) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVSpokenWordCover(book: book, size: width)
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                VStack(alignment: .leading, spacing: 8) {
                    if book.isInProgress || book.isFinished {
                        TVSpokenWordProgressBar(fraction: book.fractionComplete, finished: book.isFinished)
                    }
                    Text(book.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2, reservesSpace: true)
                    Text(TVSpokenWordBooks.subtitle(book)).tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                        .lineLimit(1)
                }
                .padding(.top, 14).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「在听」里的大卡:封面 + 书名、当前章节、剩余时长、进度和「继续」。
struct TVSpokenWordListeningCard: View {
    let book: SpokenWordBook
    var action: () -> Void

    var body: some View {
        TVFocusButton(radius: TVRadius.card, scale: 1.04, lift: 8, action: action) { focused in
            HStack(alignment: .center, spacing: 28) {
                TVSpokenWordCover(book: book, size: 220)
                VStack(alignment: .leading, spacing: 10) {
                    Text(book.title).tvFont(.sectionTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2)
                    if let chapter = book.resumeItem?.title, book.chapterCount > 1 {
                        Text(chapter).tvFont(.body)
                            .foregroundStyle(TVColor.textMuted)
                            .lineLimit(1)
                    } else if let author = book.author {
                        Text(author).tvFont(.body)
                            .foregroundStyle(TVColor.textMuted)
                            .lineLimit(1)
                    }
                    if let remaining = TVSpokenWordBooks.remaining(book) {
                        Text(remaining).tvFont(.caption)
                            .foregroundStyle(TVColor.textFaint)
                    }
                    Spacer(minLength: 0)
                    TVSpokenWordProgressBar(fraction: book.fractionComplete)
                    Label(String(localized: "spoken_word_continue"), systemImage: "play.fill")
                        .tvFont(.caption, weight: .semibold)
                        .foregroundStyle(focused ? TVColor.onBrand : TVColor.spokenWordSpace)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(
                            focused ? AnyShapeStyle(TVColor.spokenWordSpace)
                                    : AnyShapeStyle(TVColor.spokenWordSpace.opacity(0.14)),
                            in: Capsule()
                        )
                }
                .frame(width: 420, height: 220, alignment: .leading)
            }
            .padding(22)
            .background(focused ? TVColor.surfaceStrong : TVColor.card,
                        in: RoundedRectangle(cornerRadius: TVRadius.card, style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 书的详情(章节列表)

/// 一本书的章节:从哪一章点下去就从哪一章播,整本书仍是队列。
struct TVSpokenWordBookDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let bookID: String
    /// 打开时的那份;章节播放、位置变化后按 id 从曲库重新整理。
    let fallback: SpokenWordBook
    var openPlayer: () -> Void = {}

    private var currentBook: SpokenWordBook {
        TVSpokenWordBooks.books(songs: store.library.spokenWordSongs, store: SpokenWordStore.shared)
            .first { $0.id == bookID } ?? fallback
    }

    var body: some View {
        let book = currentBook
        let palette = store.artworkColors(forSongID: book.items.first?.id ?? "")
        ZStack {
            TVAmbientBackdrop(
                tint: palette?.primary ?? TVColor.spokenWordSpace,
                tint2: palette?.secondary ?? TVColor.bgDeep,
                strength: 0.55
            )
            TVColor.bg.opacity(0.34).ignoresSafeArea()
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 22) {
                    TVSpokenWordCover(book: book, size: 320)
                    Text(book.title)
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    let subtitle = TVSpokenWordBooks.subtitle(book)
                    if !subtitle.isEmpty {
                        Text(subtitle).tvFont(.body).foregroundStyle(TVColor.textMuted)
                    }
                    if let remaining = TVSpokenWordBooks.remaining(book) {
                        Text(remaining).tvFont(.caption).foregroundStyle(TVColor.textFaint)
                    }
                    TVSpokenWordProgressBar(fraction: book.fractionComplete, finished: book.isFinished)
                        .frame(width: 320)
                    TVPillButton(
                        title: book.isInProgress
                            ? String(localized: "spoken_word_continue")
                            : String(localized: "spoken_word_start"),
                        systemImage: "play.fill",
                        style: .solid
                    ) {
                        play(book, from: book.resumeItemID)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 440, alignment: .leading)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        TVEyebrow(text: String(localized: "tv_spoken_word_chapters"))
                            .padding(.bottom, 6)
                        ForEach(Array(book.items.enumerated()), id: \.element.id) { index, item in
                            chapterRow(item, index: index, isResume: item.id == book.resumeItemID) {
                                play(book, from: item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .focusSection()
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 72)
        }
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("tv.spokenWord.detail")
    }

    private func chapterRow(
        _ item: SpokenWordBookItem,
        index: Int,
        isResume: Bool,
        action: @escaping () -> Void
    ) -> some View {
        TVFocusButton(radius: 16, scale: 1.02, lift: 0, ring: false, action: action) { focused in
            HStack(spacing: 22) {
                Text(verbatim: "\(index + 1)")
                    .tvFont(.caption, design: .monospaced)
                    .foregroundStyle(TVColor.textFaint)
                    .frame(width: 56, alignment: .trailing)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).tvFont(.rowTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                    if item.isInProgress {
                        TVSpokenWordProgressBar(fraction: item.fractionComplete)
                            .frame(maxWidth: 360)
                    }
                }
                Spacer(minLength: 12)
                if isResume, !item.isFinished {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(TVColor.spokenWordSpace)
                } else if item.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(TVColor.spokenWordSpace)
                        .accessibilityLabel(Text(String(localized: "spoken_word_finished")))
                }
                if item.duration > 0 {
                    Text(TVFmt.time(item.duration))
                        .tvFont(.meta, design: .monospaced)
                        .foregroundStyle(TVColor.textFaint)
                }
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 84)
            .background(focused ? TVColor.surfaceStrong : TVColor.card,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
    }

    private func play(_ book: SpokenWordBook, from itemID: String?) {
        guard store.playSpokenWordBook(songIDs: book.items.map(\.id), startingAt: itemID) else { return }
        openPlayer()
        dismiss()
    }
}
#endif
