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
            song: song,
            knownDuration: stored?.duration,
            position: stored?.position,
            positionUpdatedAt: stored?.updatedAt,
            finishedAt: store.finishedDate(forSongID: song.id)
        )
    }

    static func books(songs: [Song], store: SpokenWordStore) -> [SpokenWordBook] {
        SpokenWordBookGrouping.books(from: songs.map { item(for: $0, store: store) })
    }

    static func songs(_ kind: TVSpokenWordShelfKind, in library: MusicLibrary) -> [Song] {
        switch kind {
        case .books: library.spokenWordSongs
        case .localPodcasts: library.localPodcastSongs
        }
    }

    static func revision(_ kind: TVSpokenWordShelfKind, in library: MusicLibrary) -> UInt64 {
        switch kind {
        case .books: library.spokenWordContentRevision
        case .localPodcasts: library.localPodcastContentRevision
        }
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

enum TVSpokenWordShelfKind {
    /// 「有声」页的书。
    case books
    /// 播客页里本机下载的节目。
    case localPodcasts
}

/// 分好组的书。整库分一次在 A15 上要两三百毫秒,原先放在页面 body 里,存一次进度、
/// 从播放页返回都在主线程上重分一遍;现在放到后台分,曲库这一类内容和有声内容那份账
/// (进度、听完、归档)都没变就不再分。由 `TVStore` 持有,切走再切回来照旧用分好的书。
@MainActor
@Observable
final class TVSpokenWordShelfModel {
    struct Inputs: Equatable {
        let libraryRevision: UInt64
        let storeRevision: Int
    }

    private(set) var books: [SpokenWordBook] = []
    private(set) var booksByID: [String: SpokenWordBook] = [:]
    /// 分过一次了:之前的空书架不算「没有书」。
    private(set) var isPrepared = false
    @ObservationIgnored private var preparedInputs: Inputs?
    @ObservationIgnored private var requestRevision: UInt = 0

    func refresh(songs: [Song], inputs: Inputs) async {
        guard !Task.isCancelled, !(isPrepared && inputs == preparedInputs) else { return }
        requestRevision &+= 1
        let revision = requestRevision
        let store = SpokenWordStore.shared
        let positions = store.positions
        let finishedAt = store.finishedAt
        let worker = Task.detached(priority: .userInitiated) { () throws -> [SpokenWordBook] in
            let items = try songs.map { song in
                try Task.checkCancellation()
                let stored = positions[song.id]
                return SpokenWordBookItem(
                    song: song,
                    knownDuration: stored?.duration,
                    position: stored?.position,
                    positionUpdatedAt: stored?.updatedAt,
                    finishedAt: finishedAt[song.id]
                )
            }
            return SpokenWordBookGrouping.books(from: items)
        }
        let result = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, revision == requestRevision, let result else { return }
        books = result
        booksByID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        isPrepared = true
        preparedInputs = inputs
    }
}

/// 页面在的时候,曲库这一类内容或有声内容那份账一变就让 `TVStore` 里那份书架重分。
private struct TVSpokenWordShelfRefresh: ViewModifier {
    let kind: TVSpokenWordShelfKind
    @Environment(TVStore.self) private var store
    @State private var storeChanges = 0

    private struct Identity: Equatable {
        let libraryRevision: UInt64
        let storeChanges: Int
    }

    func body(content: Content) -> some View {
        let library = store.library
        content
            .task(id: Identity(libraryRevision: TVSpokenWordBooks.revision(kind, in: library), storeChanges: storeChanges)) {
                await store.spokenWordShelf(kind).refresh(
                    songs: TVSpokenWordBooks.songs(kind, in: library),
                    inputs: .init(
                        libraryRevision: TVSpokenWordBooks.revision(kind, in: library),
                        storeRevision: SpokenWordStore.shared.revision
                    )
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseSpokenWordDidChange)) { _ in
                storeChanges &+= 1
            }
    }
}

extension View {
    func tvSpokenWordShelfRefresh(_ kind: TVSpokenWordShelfKind) -> some View {
        modifier(TVSpokenWordShelfRefresh(kind: kind))
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
    @State private var showsArchived = false
    @State private var opensPlayerAfterDetailDismissal = false

    // 书封是方的:一行五本,与电台墙同一把尺子(见 `TVBrowseGridMetrics`)。
    private let gridMetrics = TVBrowseGridMetrics.spokenWord

    var body: some View {
        let spokenStore = SpokenWordStore.shared
        let shelfModel = store.spokenWordShelf(.books)
        let books = shelfModel.books
        // 归档的书只在最下面那一节,不进在听、书架和已听完。
        let archivedIDs = spokenStore.archivedBookIDs
        let active = books.filter { !archivedIDs.contains($0.id) }
        let archived = books.filter { archivedIDs.contains($0.id) }
        let listening = active.filter(\.isInProgress)
        let shelf = active.filter { !$0.isFinished }
        let finished = active.filter(\.isFinished)

        GeometryReader { geo in
            let cell = gridMetrics.cellWidth(pageWidth: geo.size.width)
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

                    if !shelfModel.isPrepared {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 520)
                    } else if books.isEmpty {
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
                            collapsibleSection(
                                title: String(localized: "spoken_word_finished"),
                                books: finished,
                                isExpanded: $showsFinished,
                                cell: cell
                            )
                        }
                        if !archived.isEmpty {
                            collapsibleSection(
                                title: String(localized: "spoken_word_archived_section"),
                                books: archived,
                                isExpanded: $showsArchived,
                                cell: cell
                            )
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
        .tvSpokenWordShelfRefresh(.books)
        .accessibilityIdentifier("tv.spokenWord.page")
    }

    private func section(title: String, books: [SpokenWordBook], cell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.text)
                .padding(.horizontal, 14)
            grid(books, cell: cell)
        }
    }

    private func collapsibleSection(
        title: String,
        books: [SpokenWordBook],
        isExpanded: Binding<Bool>,
        cell: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TVPillButton(
                title: title + " · \(books.count)",
                systemImage: isExpanded.wrappedValue ? "chevron.down" : "chevron.right",
                isSelected: isExpanded.wrappedValue
            ) {
                isExpanded.wrappedValue.toggle()
            }
            .padding(.horizontal, 14)
            if isExpanded.wrappedValue {
                grid(books, cell: cell)
            }
        }
    }

    private func grid(_ books: [SpokenWordBook], cell: CGFloat) -> some View {
        LazyVGrid(columns: gridMetrics.gridItems(cell: cell), alignment: .leading, spacing: gridMetrics.gap) {
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
                book.canContinue
                    ? String(localized: "spoken_word_continue")
                    : String(localized: "spoken_word_start"),
                systemImage: "play.fill"
            )
        }
        Button { selectedBook = book } label: {
            Label(String(localized: "tv_spoken_word_chapters"), systemImage: "list.bullet")
        }
        let isArchived = SpokenWordStore.shared.isArchived(bookID: book.id)
        Button {
            SpokenWordStore.shared.setArchived(!isArchived, bookIDs: [book.id])
        } label: {
            Label(
                isArchived ? String(localized: "spoken_word_unarchive") : String(localized: "spoken_word_archive"),
                systemImage: isArchived ? "tray.and.arrow.up" : "archivebox"
            )
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

/// 一本书的封面:用第一章的封面(有声书的章节通常共用一张)。按书的形状画成
/// 方框(`SpokenWordCoverLayout`),封面整张放进去,竖版的书封不裁也不拉伸。
struct TVSpokenWordCover: View {
    @Environment(TVStore.self) private var store
    let book: SpokenWordBook
    /// 封面宽度;高度按书的比例算。
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
            placeholderKind: .book,
            size: size,
            height: SpokenWordCoverLayout.height(forWidth: size),
            radius: radius
        )
        .bookCoverLayout()
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
                    .tvCardFocus(focused, radius: TVRadius.cover)
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
                TVSpokenWordCover(book: book, size: SpokenWordCoverLayout.width(forHeight: 220))
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
///
/// 播客页里的本地节目(自己的文件标成播客)也用这一页,但按播客的样子排:默认日期新的在上,
/// 可换旧到新、文件顺序,手机上拖过顺序的这台电视不知道(排法记在各自设备上);
/// 可只看未播放/已播放;点一集从这一集放起,播完按收听先后接着放还没听完的。
struct TVSpokenWordBookDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let bookID: String
    /// 打开时的那份;章节播放、位置变化后按 id 从曲库重新整理。
    let fallback: SpokenWordBook
    var openPlayer: () -> Void = {}

    private var isLocalPodcast: Bool {
        store.library.localPodcastBookIDs.values.contains(bookID)
    }

    private var currentBook: SpokenWordBook {
        // 播客页里本机下载的节目也用这一页。打开这一页的书架页在后台分好组,
        // 进度变了也是它重分,这里只按 id 取。
        let books = store.spokenWordShelf(isLocalPodcast ? .localPodcasts : .books).booksByID
        if let book = books[bookID] { return book }
        // 打开以后才读出第一集的专辑时,整本书从按目录成书换成按专辑成书,id 跟着变:
        // 按打开时的章节把它找回来,进度才会接着更新。
        return SpokenWordBookGrouping.bookID(
            holdingMostOf: Set(fallback.items.map(\.id)),
            among: books.values
        ).flatMap { books[$0] } ?? fallback
    }

    private var podcastSettings: LocalPodcastShowSettings {
        LocalPodcastShowSettingsStore.shared.settings(for: bookID)
    }

    var body: some View {
        let book = currentBook
        let isPodcast = isLocalPodcast
        let settings = podcastSettings
        let ordered = isPodcast ? LocalPodcastEpisodeListPolicy.ordered(book.items, settings: settings) : book.items
        let listed = isPodcast ? ordered.filter { settings.filter.includes($0) } : book.items
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
                    TVSpokenWordCover(book: book, size: 270)
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
                        title: book.canContinue
                            ? String(localized: "spoken_word_continue")
                            : String(localized: "spoken_word_start"),
                        systemImage: "play.fill",
                        style: .solid
                    ) {
                        play(book, from: isPodcast ? nil : book.resumeItemID)
                    }
                    if isPodcast {
                        podcastListControls(settings)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 440, alignment: .leading)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        TVEyebrow(text: isPodcast
                            ? String(format: String(localized: "podcast_episode_count %lld"), listed.count)
                            : String(localized: "tv_spoken_word_chapters"))
                            .padding(.bottom, 6)
                        if isPodcast, listed.isEmpty {
                            Text(String(localized: "podcast_no_matching_episodes"))
                                .tvFont(.body)
                                .foregroundStyle(TVColor.textMuted)
                                .padding(.vertical, 30)
                        }
                        // 一本书可能拆成上千个文件:分页渲染,焦点走到末尾附近再续。
                        TVPagedList(listed, id: \.id, alignment: .leading, spacing: 10) { index, item, focusChanged in
                            chapterRow(
                                item, index: index, isResume: item.id == book.resumeItemID,
                                podcastEpisodes: isPodcast ? ordered : nil,
                                order: settings.order,
                                onFocusChanged: focusChanged
                            ) {
                                play(book, from: item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, TVScrollEdgeFade.bottom)
                }
                .tvScrollEdgeFade()
                .focusSection()
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 72)
        }
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("tv.spokenWord.detail")
    }

    /// `podcastEpisodes`:本地节目时是排好的整份单集(长按「之前的都标为已播放」要用),书是 nil。
    @ViewBuilder
    private func chapterRow(
        _ item: SpokenWordBookItem,
        index: Int,
        isResume: Bool,
        podcastEpisodes: [SpokenWordBookItem]?,
        order: LocalPodcastEpisodeOrder,
        onFocusChanged: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        let isPodcast = podcastEpisodes != nil
        let row = TVFocusButton(
            radius: 16, scale: 1.02, lift: 0, ring: false,
            action: action, onFocusChanged: onFocusChanged
        ) { focused in
            HStack(spacing: 22) {
                if isPodcast {
                    // 播客按日期排,序号没有意义:没听过的一集在这里亮一个点。
                    Circle()
                        .fill(TVColor.spokenWordSpace)
                        .frame(width: 12, height: 12)
                        .opacity(!item.isFinished && item.position == nil ? 1 : 0)
                        .frame(width: 56, alignment: .trailing)
                        .accessibilityHidden(item.isFinished || item.position != nil)
                        .accessibilityLabel(Text(String(localized: "podcast_filter_unplayed")))
                } else {
                    Text(verbatim: "\(index + 1)")
                        .tvFont(.caption, design: .monospaced)
                        .foregroundStyle(TVColor.textFaint)
                        .frame(width: 56, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if isPodcast, let date = PodcastFormat.date(item.addedAt) {
                        Text(date)
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.textFaint)
                    }
                    Text(item.title).tvFont(.rowTitle)
                        .foregroundStyle(isPodcast && item.isFinished ? TVColor.textMuted : TVColor.text)
                        .lineLimit(1)
                    if item.isInProgress {
                        TVSpokenWordProgressBar(fraction: item.fractionComplete)
                            .frame(maxWidth: 360)
                    }
                }
                Spacer(minLength: 12)
                // 听完又在重听的一章仍是接着听的那一章。
                if isResume, !item.isFinished || item.position != nil {
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
        if let podcastEpisodes {
            row.contextMenu {
                Button(item.isFinished
                    ? String(localized: "podcast_mark_unplayed")
                    : String(localized: "podcast_mark_played")) {
                    SpokenWordStore.shared.markFinished(!item.isFinished, songIDs: [item.id])
                }
                let earlier = LocalPodcastEpisodeListPolicy.earlierUnfinishedIDs(
                    than: item.id, in: podcastEpisodes, order: order
                )
                if !earlier.isEmpty {
                    Button(String(localized: "podcast_mark_older_played")) {
                        SpokenWordStore.shared.markFinished(true, songIDs: earlier)
                    }
                }
            }
        } else {
            row
        }
    }

    /// 本地节目的排法与筛选:按一下换下一种,和手机上记在各自设备上。
    private func podcastListControls(_ settings: LocalPodcastShowSettings) -> some View {
        let orders = LocalPodcastEpisodeOrder.allCases.filter {
            $0 != .custom || settings.order == .custom || !settings.customOrder.isEmpty
        }
        let filters = LocalPodcastEpisodeFilter.allCases
        let orderButton = TVPillButton(title: orderTitle(settings.order), systemImage: "arrow.up.arrow.down") {
            let next = orders[((orders.firstIndex(of: settings.order) ?? 0) + 1) % orders.count]
            LocalPodcastShowSettingsStore.shared.update(bookID) { $0.order = next }
        }
        let filterButton = TVPillButton(title: filterTitle(settings.filter), systemImage: "line.3.horizontal.decrease") {
            let next = filters[((filters.firstIndex(of: settings.filter) ?? 0) + 1) % filters.count]
            LocalPodcastShowSettingsStore.shared.update(bookID) { $0.filter = next }
        }
        // 左栏只有 440 宽:两颗并排放不下的语言里上下排。
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { orderButton; filterButton }
            VStack(alignment: .leading, spacing: 16) { orderButton; filterButton }
        }
    }

    private func orderTitle(_ order: LocalPodcastEpisodeOrder) -> String {
        switch order {
        case .newestFirst: String(localized: "podcast_order_newest")
        case .oldestFirst: String(localized: "podcast_order_oldest")
        case .fileOrder: String(localized: "podcast_order_file")
        case .fileOrderReversed: String(localized: "podcast_order_file_reversed")
        case .custom: String(localized: "podcast_order_custom")
        }
    }

    private func filterTitle(_ filter: LocalPodcastEpisodeFilter) -> String {
        switch filter {
        case .all: String(localized: "podcast_filter_all")
        case .unplayed: String(localized: "podcast_filter_unplayed")
        case .played: String(localized: "podcast_played")
        }
    }

    private func play(_ book: SpokenWordBook, from itemID: String?) {
        let songIDs: [String]
        let startID: String?
        if isLocalPodcast {
            // 本地节目按它自己的排法:从这一集起,播完接着放还没听完的。
            let ordered = LocalPodcastEpisodeListPolicy.ordered(book.items, settings: podcastSettings)
            guard let first = itemID ?? LocalPodcastEpisodeListPolicy.startItemID(
                in: ordered, resumeItemID: book.resumeItemID, canContinue: book.canContinue
            ) else { return }
            songIDs = LocalPodcastEpisodeListPolicy
                .continuation(from: first, in: ordered, order: podcastSettings.order)
                .map(\.id)
            startID = first
        } else {
            songIDs = book.items.map(\.id)
            startID = itemID
        }
        guard store.playSpokenWordBook(songIDs: songIDs, startingAt: startID) else { return }
        openPlayer()
        dismiss()
    }
}
#endif
