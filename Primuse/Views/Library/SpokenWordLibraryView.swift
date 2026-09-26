import PrimuseKit
import SwiftUI

struct SpokenWordLibrarySnapshot: Sendable {
    struct Entry: Identifiable, Sendable {
        let book: SpokenWordBook
        let songs: [Song]
        var id: String { book.id }
    }

    let entriesByID: [String: Entry]
    let inProgress: [(SpokenWordBook, [Song])]
    let nowListening: Entry?
    let shelf: [Entry]
    let finished: [Entry]
    let isPrepared: Bool

    /// 每本书一次:在听的、书架、已听完,与书架页从上到下的顺序一致。
    var allEntries: [Entry] {
        (nowListening.map { [$0] } ?? []) + shelf + finished
    }

    /// 同上,再按书架页里拖出来的顺序(`spokenWord.shelf.order`)排 —— 首页「有声书」
    /// 没挑过时的「自定义顺序」就是书架的顺序。
    func allEntries(shelfOrder rawValue: String) -> [Entry] {
        let preferred = SpokenWordShelfOrder.decode(rawValue)
        guard !preferred.isEmpty else { return allEntries }
        return SpokenWordShelfOrder.orderedIDs(allEntries.map(\.id), preferred: preferred)
            .compactMap { entriesByID[$0] }
    }

    init(books: [SpokenWordBook] = [], songsByID: [String: Song] = [:], isPrepared: Bool = true) {
        let entries = books.map { book in
            Entry(book: book, songs: book.items.compactMap { songsByID[$0.id] })
        }
        entriesByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let progressing = entries.filter { $0.book.isInProgress }
        inProgress = progressing.map { ($0.book, $0.songs) }
        let current = progressing.max {
            ($0.book.lastListenedAt ?? .distantPast) < ($1.book.lastListenedAt ?? .distantPast)
        }
        nowListening = current
        shelf = entries.filter { !$0.book.isFinished && $0.id != current?.id }
        finished = entries.filter { $0.book.isFinished }.sorted {
            ($0.book.lastListenedAt ?? .distantPast) > ($1.book.lastListenedAt ?? .distantPast)
        }
        self.isPrepared = isPrepared
    }
}

@MainActor
@Observable
final class SpokenWordBooksModel {
    private(set) var snapshot = SpokenWordLibrarySnapshot(isPrepared: false)
    @ObservationIgnored private(set) var requestRevision: UInt = 0

    var inProgress: [(SpokenWordBook, [Song])] { snapshot.inProgress }

    func refresh(
        songs: [Song],
        positions: [String: SpokenWordStore.StoredPosition],
        finishedAt: [String: Date]
    ) async {
        guard !Task.isCancelled else { return }
        requestRevision &+= 1
        let revision = requestRevision
        guard !songs.isEmpty else {
            snapshot = SpokenWordLibrarySnapshot()
            return
        }
        // Build sections and chapter queues together, so scrolling and opening
        // a book only read an immutable snapshot on the UI executor.
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let items = try songs.map { song in
                try Task.checkCancellation()
                let position = positions[song.id]
                return SpokenWordBookItem(
                    song: song,
                    knownDuration: position?.duration,
                    position: position?.position,
                    positionUpdatedAt: position?.updatedAt,
                    finishedAt: finishedAt[song.id]
                )
            }
            let books = SpokenWordBookGrouping.books(from: items)
            try Task.checkCancellation()
            return SpokenWordLibrarySnapshot(books: books, songsByID: songsByID)
        }
        let result = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, revision == requestRevision, let result else { return }
        snapshot = result
    }
}

struct SpokenWordLibraryContent<Content: View>: View {
    @ViewBuilder var content: (SpokenWordLibrarySnapshot) -> Content

    @Environment(MusicLibrary.self) private var library
    @State private var books = SpokenWordBooksModel()
    @State private var progressRevision = 0

    private struct RefreshIdentity: Equatable {
        let libraryRevision: UInt64
        let progressRevision: Int
    }

    var body: some View {
        content(books.snapshot)
            .task(id: RefreshIdentity(libraryRevision: library.spokenWordContentRevision, progressRevision: progressRevision)) {
                let store = SpokenWordStore.shared
                await books.refresh(songs: library.spokenWordSongs, positions: store.positions, finishedAt: store.finishedAt)
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseSpokenWordDidChange)) { _ in
                progressRevision &+= 1
            }
    }
}

enum SpokenWordShelfLayout: String, CaseIterable {
    case bookshelf, list
}

enum SpokenWordShelfOrder {
    static func decode(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func orderedIDs(_ available: [String], preferred: [String]) -> [String] {
        var remaining = Set(available)
        let saved = preferred.filter { remaining.remove($0) != nil }
        return saved + available.filter { remaining.remove($0) != nil }
    }

    static func moving(_ id: String, onto target: String, visible: [String],
                       preferred: [String], allIDs: [String]) -> [String]? {
        guard id != target, let from = visible.firstIndex(of: id),
              let to = visible.firstIndex(of: target) else { return nil }
        var moved = visible
        moved.remove(at: from)
        moved.insert(id, at: to)
        // Preserve the slots of the other section, the current book, and
        // temporarily unavailable sources when reordering only the visible shelf.
        var seen = Set<String>()
        let all = (preferred + allIDs).filter { seen.insert($0).inserted }
        let visibleSet = Set(visible)
        var iterator = moved.makeIterator()
        return all.map { visibleSet.contains($0) ? (iterator.next() ?? $0) : $0 }
    }
}

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
    @State private var showsHomeSpotlight = false

    var body: some View {
        ScrollView {
            SpokenWordShelf()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        // iPhone Duo 竖栏：书架铺到屏幕边缘，系统的玻璃胶囊浮在上面。
        .pmExtendsUnderVerticalBar()
        .navigationTitle("tab_spoken_word")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !library.spokenWordSongs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsHomeSpotlight = true
                    } label: {
                        Label("home_spotlight_manage_books", systemImage: "house")
                    }
                    .accessibilityIdentifier("spokenWord.homeSpotlight")
                }
            }
        }
        #if os(iOS)
        // 顶部 tab 外壳里有声是根页,系统导航栏不在:「首页显示哪些书」交给 tab 条。
        .minimalRootActions {
            if !library.spokenWordSongs.isEmpty {
                Button {
                    showsHomeSpotlight = true
                } label: {
                    Label("home_spotlight_manage_books", systemImage: "house")
                }
                .accessibilityIdentifier("spokenWord.homeSpotlight")
            }
        }
        #endif
        .sheet(isPresented: $showsHomeSpotlight) {
            NavigationStack { HomeSpotlightManagementView(section: .audiobooks) }
            #if os(macOS)
                .frame(minWidth: 460, minHeight: 520)
            #endif
        }
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
    var body: some View {
        SpokenWordLibraryContent { snapshot in
            SpokenWordShelfContent(snapshot: snapshot)
        }
    }
}

struct SpokenWordShelfContent: View {
    let snapshot: SpokenWordLibrarySnapshot
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage("spokenWord.shelf.showsFinished") private var showsFinished = false
    @AppStorage("spokenWord.shelf.layout") private var layout = SpokenWordShelfLayout.bookshelf
    @AppStorage("spokenWord.shelf.order") private var savedOrder = ""
    @AppStorage(HomeSpotlightSelection.booksStorageKey) private var homeSpotlightRawValue = ""

    private var store: SpokenWordStore { SpokenWordStore.shared }

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
        shelfContent(snapshot)
    }

    private func shelfContent(_ snapshot: SpokenWordLibrarySnapshot) -> some View {
        let preferred = SpokenWordShelfOrder.decode(savedOrder)
        let shelf = ordered(snapshot.shelf, preferred: preferred)
        let finished = ordered(snapshot.finished, preferred: preferred)
        return LazyVStack(alignment: .leading, spacing: 28) {
            if !snapshot.isPrepared {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            if let current = snapshot.nowListening {
                SpokenWordNowListeningCard(book: current.book, songs: current.songs, tint: tint)
                    .contextMenu { bookMenu(current.book, songs: current.songs) }
                    // 铺到 iPhone Duo 竖栏底下时，静止时就在最上面、带着「继续」的这张卡照旧让开竖栏。
                    .pmClearOfVerticalBar()
            }

            if !shelf.isEmpty || !finished.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("spoken_word_shelf_section")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("spokenWord.shelf.heading")
                        Spacer(minLength: 12)
                        HStack(spacing: 0) {
                            layoutButton(.bookshelf, icon: "square.grid.2x2", title: "spoken_word_shelf_section")
                            layoutButton(.list, icon: "list.bullet", title: "songs_view_list")
                        }
                    }
                    // 行尾的两颗版式键不钻到 iPhone Duo 竖栏的按钮底下。
                    .pmClearOfVerticalBar()
                    if !shelf.isEmpty { bookCollection(shelf) }
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
                    .pmClearOfVerticalBar()

                    if showsFinished {
                        bookCollection(finished)
                            .pmFadeTransition(motion: .panel)
                    }
                }
            }
        }
    }

    private func layoutButton(_ mode: SpokenWordShelfLayout, icon: String, title: LocalizedStringKey) -> some View {
        Button {
            layout = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(layout == mode ? tint : .secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(layout == mode ? .isSelected : [])
        .accessibilityIdentifier("spokenWord.shelf.layout.\(mode.rawValue)")
    }

    @ViewBuilder
    private func bookCollection(_ entries: [SpokenWordLibrarySnapshot.Entry]) -> some View {
        if layout == .bookshelf {
            LazyVGrid(columns: gridColumns, spacing: 22) {
                ForEach(entries) { entry in reorderableBookCell(entry, entries: entries) }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    reorderableBookCell(entry, entries: entries)
                        .overlay(alignment: .bottom) { Divider().padding(.leading, 66) }
                }
            }
        }
    }

    private func ordered(_ entries: [SpokenWordLibrarySnapshot.Entry], preferred: [String]) -> [SpokenWordLibrarySnapshot.Entry] {
        guard !preferred.isEmpty else { return entries }
        return SpokenWordShelfOrder.orderedIDs(entries.map(\.id), preferred: preferred)
            .compactMap { snapshot.entriesByID[$0] }
    }

    private func moveBook(_ id: String, onto target: String, entries: [SpokenWordLibrarySnapshot.Entry]) -> Bool {
        let allIDs = snapshot.shelf.map(\.id) + snapshot.finished.map(\.id) + [snapshot.nowListening?.id].compactMap { $0 }
        guard let moved = SpokenWordShelfOrder.moving(
            id, onto: target, visible: entries.map(\.id),
            preferred: SpokenWordShelfOrder.decode(savedOrder), allIDs: allIDs
        ) else { return false }
        savedOrder = SpokenWordShelfOrder.encode(moved)
        return true
    }

    private func moveBook(_ id: String, by offset: Int, entries: [SpokenWordLibrarySnapshot.Entry]) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries.indices.contains(index + offset) else { return }
        _ = moveBook(id, onto: entries[index + offset].id, entries: entries)
    }

    private func reorderableBookCell(_ entry: SpokenWordLibrarySnapshot.Entry,
                                     entries: [SpokenWordLibrarySnapshot.Entry]) -> some View {
        SpokenWordShelfDragCell(bookID: entry.id, title: entry.book.title) { movedID in
            moveBook(movedID, onto: entry.id, entries: entries)
        } content: {
            bookCell(entry)
                .padding(.trailing, layout == .list ? 36 : 0)
        }
        .overlay(alignment: layout == .bookshelf ? .topTrailing : .trailing) {
            Menu {
                bookMenu(entry.book, songs: entry.songs, entries: entries)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.regularMaterial, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("more"))
            .accessibilityIdentifier("spokenWord.bookMenu." + entry.id)
        }
        .accessibilityAction(named: Text("home_edit_move_up")) { moveBook(entry.id, by: -1, entries: entries) }
        .accessibilityAction(named: Text("home_edit_move_down")) { moveBook(entry.id, by: 1, entries: entries) }
    }

    @ViewBuilder
    private func bookCell(_ entry: SpokenWordLibrarySnapshot.Entry) -> some View {
        let book = entry.book
        let songs = entry.songs
        #if DEBUG
        let _ = SpokenWordShelfDiagnostics.didBuildCell?(book.id)
        #endif
        let cell = Group {
            if layout == .bookshelf {
                SpokenWordBookCoverCell(
                    book: book, coverSong: songs.first,
                    isPlaying: player.currentBookID == book.id, tint: tint
                )
            } else {
                SpokenWordBookListRow(
                    book: book, coverSong: songs.first,
                    isPlaying: player.currentBookID == book.id, tint: tint
                )
            }
        }
        if book.items.count > 1 {
            NavigationLink {
                SpokenWordBookDetailView(bookID: book.id)
            } label: {
                cell
            }
            .buttonStyle(.pmPressable)
            .accessibilityIdentifier("spokenWord.book." + book.id)
        } else {
            Button {
                SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
            } label: {
                cell
            }
            .buttonStyle(.pmPressable)
            .contentShape(Rectangle())
            .accessibilityIdentifier("spokenWord.book." + book.id)
        }
    }

    @ViewBuilder
    private func bookMenu(_ book: SpokenWordBook, songs: [Song], entries: [SpokenWordLibrarySnapshot.Entry] = []) -> some View {
        if entries.count > 1 {
            Section {
                Button("home_edit_move_up", systemImage: "arrow.up") { moveBook(book.id, by: -1, entries: entries) }
                    .disabled(entries.first?.id == book.id)
                Button("home_edit_move_down", systemImage: "arrow.down") { moveBook(book.id, by: 1, entries: entries) }
                    .disabled(entries.last?.id == book.id)
            }
        }
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
        // 首页的「有声书」一排放哪些书。Mac 首页挑过就放挑中的,没挑过仍只列在听的书。
        let homeSelection = HomeSpotlightSelection.decode(homeSpotlightRawValue)
        let isOnHome = homeSelection.isPinned(book.id)
        Button {
            var updated = homeSelection
            updated.togglePin(book.id)
            homeSpotlightRawValue = updated.encoded()
        } label: {
            Label(
                String(localized: isOnHome ? "home_spotlight_remove" : "home_spotlight_add"),
                systemImage: isOnHome ? "house.slash" : "house"
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

private struct SpokenWordShelfDragCell<Content: View>: View {
    let bookID: String
    let title: String
    var move: (String) -> Bool
    @ViewBuilder var content: () -> Content
    @State private var isTargeted = false

    private static var prefix: String { "primuse-spoken-word-book:" }

    var body: some View {
        content()
            .draggable(Self.prefix + bookID) {
                // Drag previews have their own host, without the shelf's environment objects.
                Label(title, systemImage: "book.closed")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .padding(12)
                    .frame(maxWidth: 220)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .dropDestination(for: String.self) { values, _ in
                guard values.count == 1, let value = values.first, value.hasPrefix(Self.prefix) else { return false }
                return move(String(value.dropFirst(Self.prefix.count)))
            } isTargeted: { isTargeted = $0 }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(ListeningSpace.spokenWord.tint.opacity(isTargeted ? 0.7 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
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

    var body: some View {
        SpokenWordLibraryContent { snapshot in
            detailContent(snapshot)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .minimalNavigationDetail()
        #endif
    }

    private func detailContent(_ snapshot: SpokenWordLibrarySnapshot) -> some View {
        Group {
            if let entry = snapshot.entriesByID[bookID] {
                let book = entry.book
                let songs = entry.songs
                SpokenWordChapterList(items: book.items) {
                    header(book, songs: songs)
                } row: { index, item in
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
                .navigationTitle(book.title)
            } else if !snapshot.isPrepared {
                ProgressView()
            } else {
                ContentUnavailableView("tab_spoken_word", systemImage: "books.vertical")
            }
        }
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

private struct SpokenWordBookListRow: View {
    let book: SpokenWordBook
    let coverSong: Song?
    let isPlaying: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            SpokenWordBookCover(song: coverSong, width: 54, cornerRadius: 6, decodeSize: 160)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isPlaying ? tint : .primary)
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(SpokenWordBookSupport.summary(book))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if book.isInProgress {
                    ProgressView(value: book.fractionComplete)
                        .tint(tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isPlaying {
                Image(systemName: "waveform")
                    .foregroundStyle(tint)
            } else if book.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(tint)
                    .accessibilityLabel(Text("spoken_word_finished"))
            }
            if book.chapterCount > 1 {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

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
                .overlay(alignment: .topLeading) {
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

struct SpokenWordChapterList<Header: View, Row: View>: View {
    let items: [SpokenWordBookItem]
    @ViewBuilder var header: () -> Header
    @ViewBuilder var row: (Int, SpokenWordBookItem) -> Row

    @State private var position = ScrollPosition(idType: String.self)
    @State private var scroll = SpokenWordChapterScrollState()

    var body: some View {
        let showsScrubber = SpokenWordChapterScrubber.isShown(chapterCount: items.count)
        ScrollView {
            LazyVStack(spacing: 0) {
                header()
                    .padding(16)
                    .padding(.trailing, showsScrubber ? 28 : 0)
                    // 铺到 iPhone Duo 竖栏底下时，带着「继续」与语速的头部照旧让开竖栏。
                    .pmClearOfVerticalBar()
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(index, item)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.leading, 16)
                        .padding(.trailing, showsScrubber ? SpokenWordChapterScrubber.reservedWidth : 16)
                        .overlay(alignment: .bottom) {
                            Divider().padding(.leading, 56)
                                .padding(.trailing, showsScrubber ? SpokenWordChapterScrubber.reservedWidth : 16)
                        }
                        // 有快速拖动条时它停在竖栏左侧，行尾连竖栏那一条一起让开。
                        .pmClearOfVerticalBar(showsScrubber)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .scrollIndicators(showsScrubber ? .hidden : .automatic)
        .onScrollGeometryChange(for: Double.self) { geometry in
            SpokenWordChapterScrubber.scrollFraction(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                contentHeight: geometry.contentSize.height
                    + geometry.contentInsets.top + geometry.contentInsets.bottom,
                visibleHeight: geometry.containerSize.height
            )
        } action: { _, fraction in
            scroll.update(fraction: fraction)
        }
        .accessibilityIdentifier("spokenWord.chapters")
        .overlay(alignment: .trailing) {
            if showsScrubber {
                SpokenWordChapterScrubber(scroll: scroll, count: items.count, title: { items[$0].title }) { index in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        if index == 0 {
                            position.scrollTo(edge: .top)
                        } else if index == items.count - 1 {
                            position.scrollTo(edge: .bottom)
                        } else {
                            position.scrollTo(id: items[index].id, anchor: .top)
                        }
                    }
                }
                // 拖动条固定不动：iPhone Duo 竖栏时和字母索引一样停在竖栏左侧。
                .pmClearOfVerticalBar()
            }
        }
        // iPhone Duo 竖栏：章节行铺到屏幕边缘，系统的玻璃胶囊浮在上面。
        .pmExtendsUnderVerticalBar()
    }
}

/// Where the chapter list is scrolled to, kept apart from the page so a
/// scroll frame redraws only the scrubber.
@MainActor
@Observable
final class SpokenWordChapterScrollState {
    var fraction: Double = 0

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
    static let reservedWidth: CGFloat = 48

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

    @State private var coordinateSpaceID = UUID()
    @GestureState private var isDragging = false
    @State private var dragStartFraction: Double?
    @State private var dragFraction: Double?
    @State private var scrubbedIndex: Int?
    @State private var hapticTrigger = 0

    private let thumbHeight: CGFloat = 64
    private let verticalInset: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let track = max(1, geometry.size.height - verticalInset * 2 - thumbHeight)
            let fraction = dragFraction ?? scroll.fraction
            let thumbTop = verticalInset + track * CGFloat(min(1, max(0, fraction)))

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 14) {
                    Image(systemName: "chevron.up")
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isDragging ? ListeningSpace.spokenWord.tint : .secondary)
                .frame(width: 26, height: 56)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(isDragging ? 0.22 : 0.1), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(isDragging ? 0.16 : 0.06), radius: 4, y: 2)
                .frame(width: 44, height: thumbHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture(track: track))
                .offset(y: thumbTop)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("tv_spoken_word_chapters"))
                .accessibilityValue(Text(verbatim: "\(Self.index(forFraction: fraction, count: count) + 1) / \(count)"))
                .accessibilityAdjustableAction { direction in
                    let index = Self.index(forFraction: scroll.fraction, count: count)
                    let step = max(1, count / 20)
                    switch direction {
                    case .increment: onScrub(min(count - 1, index + step))
                    case .decrement: onScrub(max(0, index - step))
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("spokenWord.chapterScrubber")

                if let scrubbedIndex {
                    bubble(for: scrubbedIndex)
                        .offset(x: -48, y: bubbleTop(thumbTop: thumbTop, height: geometry.size.height))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
        }
        .coordinateSpace(name: coordinateSpaceID)
        .frame(width: 44)
        .sensoryFeedback(.selection, trigger: hapticTrigger)
        .onChange(of: isDragging) { _, active in
            if !active {
                dragStartFraction = nil
                dragFraction = nil
                scrubbedIndex = nil
            }
        }
    }

    private func dragGesture(track: CGFloat) -> some Gesture {
        // The track stays fixed while the thumb moves under the finger.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceID))
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { value in
                let start = dragStartFraction ?? scroll.fraction
                if dragStartFraction == nil { dragStartFraction = start }
                let fraction = min(1, max(0, start + Double(value.translation.height / track)))
                dragFraction = fraction
                let index = Self.index(forFraction: fraction, count: count)
                let previousIndex = scrubbedIndex
                scrubbedIndex = index
                guard abs(value.translation.height) > 1, index != previousIndex else { return }
                if previousIndex.map({ $0 / 10 }) != index / 10 {
                    hapticTrigger &+= 1
                }
                onScrub(index)
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
        .frame(width: 220, alignment: .trailing)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 气泡与滑块中线对齐, 但不越出列表上下缘。
    private func bubbleTop(thumbTop: CGFloat, height: CGFloat) -> CGFloat {
        let bubbleHeight: CGFloat = 52
        let centered = thumbTop + thumbHeight / 2 - bubbleHeight / 2
        return min(max(0, centered), max(0, height - bubbleHeight))
    }
}

struct SpokenWordChapterItemRow: View {
    let item: SpokenWordBookItem
    let number: Int
    let isResumeItem: Bool
    let isPlaying: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
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

            VStack(alignment: .leading, spacing: 4) {
                let titleLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                titleLayout {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(isPlaying ? ListeningSpace.spokenWord.tint : (item.isFinished ? .secondary : .primary))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                if isResumeItem {
                    Text("spoken_word_resume_here")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ListeningSpace.spokenWord.tint)
                }
                if item.isInProgress {
                    ProgressView(value: item.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(ListeningSpace.spokenWord.tint)
                        .frame(maxWidth: 200)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
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

#if DEBUG && os(iOS)
/// Isolated chapter fixtures for touch regression, without adding media to the user's library.
struct SpokenWordChapterEvidenceHost: View {
    @State private var selected = ""
    private let items: [SpokenWordBookItem] = {
        let count = Int(ProcessInfo.processInfo.environment["PRIMUSE_CHAPTER_COUNT"] ?? "1000") ?? 1000
        return (1...max(1, count)).map { number in
            SpokenWordBookItem(
                id: "chapter-\(number)",
                title: "第\(number)章 " + (number % 3 == 0 ? "远方的故事与漫长旅途中再次相遇的人们" : "山河故人"),
                duration: number % 7 == 0 ? 0 : 1325,
                position: number == 2 ? 240 : nil,
                finishedAt: number == 1 ? .distantPast : nil
            )
        }
    }()

    var body: some View {
        NavigationStack {
            SpokenWordChapterList(items: items) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "山河故人").font(.title2.bold())
                    Text(verbatim: "\(items.count) 章").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } row: { index, item in
                Button { selected = item.id } label: {
                    SpokenWordChapterItemRow(item: item, number: index + 1, isResumeItem: index == 1, isPlaying: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("spokenWord.chapter.\(index + 1)")
                .contextMenu {
                    Button("spoken_word_mark_finished") { selected = "finished-\(item.id)" }
                }
            }
            .navigationTitle("tv_spoken_word_chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Text(verbatim: selected)
                    .accessibilityIdentifier("spokenWord.selectedChapter")
            }
        }
        .dynamicTypeSize(ProcessInfo.processInfo.environment["PRIMUSE_CHAPTER_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
    }
}
#endif

#if DEBUG
@MainActor
enum SpokenWordShelfDiagnostics {
    static var didBuildCell: ((String) -> Void)?
}
#endif

#if DEBUG && os(iOS)
struct SpokenWordShelfEvidenceHost: View {
    @State private var snapshot = SpokenWordLibrarySnapshot(isPrepared: false)
    private let defaults = UserDefaults(suiteName: "primuse.bookshelf-evidence")!

    var body: some View {
        NavigationStack {
            ScrollView {
                SpokenWordShelfContent(snapshot: snapshot)
                    .padding(.horizontal, 16)
            }
            .navigationTitle("spoken_word_shelf_section")
            .navigationBarTitleDisplayMode(.inline)
        }
        .defaultAppStorage(defaults)
        .task {
            if ProcessInfo.processInfo.environment["PRIMUSE_SHELF_RESET"] == "1" {
                defaults.removePersistentDomain(forName: "primuse.bookshelf-evidence")
            }
            let count = Int(ProcessInfo.processInfo.environment["PRIMUSE_SHELF_COUNT"] ?? "2000") ?? 2000
            snapshot = await Task.detached {
                let items = (0..<count).flatMap { book in
                    (0..<2).map { chapter in
                        SpokenWordBookItem(id: "shelf-\(book)-\(chapter)", title: "第\(chapter + 1)章",
                                          albumTitle: String(format: "书籍 %04d · 故事", book), trackNumber: chapter,
                                          duration: 300)
                    }
                }
                return SpokenWordLibrarySnapshot(books: SpokenWordBookGrouping.books(from: items))
            }.value
        }
    }
}
#endif
