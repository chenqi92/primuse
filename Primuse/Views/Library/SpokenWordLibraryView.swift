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
    /// 归档的书:书架页最下面单独一节,不进上面三节,也不进首页与「接着听」。
    let archived: [Entry]
    let isPrepared: Bool

    /// 每本书一次:在听的、书架、已听完,与书架页从上到下的顺序一致。归档的不在里面。
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

    init(
        books: [SpokenWordBook] = [],
        songsByID: [String: Song] = [:],
        archivedBookIDs: Set<String> = [],
        isPrepared: Bool = true
    ) {
        let all = books.map { book in
            Entry(book: book, songs: book.items.compactMap { songsByID[$0.id] })
        }
        entriesByID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        archived = all.filter { archivedBookIDs.contains($0.id) }
        let entries = all.filter { !archivedBookIDs.contains($0.id) }
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
    /// 分组用到的输入:分的是哪一类、曲库里这一类内容的修订号,和有声内容那份账(进度、听完、归档)的修订号。
    struct Inputs: Equatable {
        let collection: SpokenWordCollection
        let libraryRevision: UInt64
        let storeRevision: Int
    }

    private(set) var snapshot = SpokenWordLibrarySnapshot(isPrepared: false)
    @ObservationIgnored private(set) var requestRevision: UInt = 0
    /// 当前 `snapshot` 是按哪一份输入分的。
    @ObservationIgnored private var preparedInputs: Inputs?

    var inProgress: [(SpokenWordBook, [Song])] { snapshot.inProgress }

    /// `inputs` 和上次分好的那份一样就不再重分:模型由外面持有时(首页),视图卸下再装回来
    /// 照旧用分好的书,不必整库再分一遍、也不发一份新快照让整页重画(#283)。
    func refresh(
        songs: [Song],
        positions: [String: SpokenWordStore.StoredPosition],
        finishedAt: [String: Date],
        archived: Set<String> = [],
        inputs: Inputs? = nil
    ) async {
        guard !Task.isCancelled else { return }
        if let inputs, inputs == preparedInputs, snapshot.isPrepared { return }
        requestRevision &+= 1
        let revision = requestRevision
        guard !songs.isEmpty else {
            snapshot = SpokenWordLibrarySnapshot()
            preparedInputs = inputs
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
            return SpokenWordLibrarySnapshot(books: books, songsByID: songsByID, archivedBookIDs: archived)
        }
        let result = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, revision == requestRevision, let result else { return }
        snapshot = result
        preparedInputs = inputs
    }
}

/// 按书分组的有声内容:书架上的书,或者播客那边本机下载的节目(按节目分组,一集是一章)。
enum SpokenWordCollection: Hashable, Sendable {
    case books
    case localPodcasts

    @MainActor
    func songs(in library: MusicLibrary) -> [Song] {
        switch self {
        case .books: library.spokenWordSongs
        case .localPodcasts: library.localPodcastSongs
        }
    }

    @MainActor
    func revision(in library: MusicLibrary) -> UInt64 {
        switch self {
        case .books: library.spokenWordContentRevision
        case .localPodcasts: library.localPodcastContentRevision
        }
    }
}

struct SpokenWordLibraryContent<Content: View>: View {
    var collection: SpokenWordCollection = .books
    /// 书架、播客页在惰性栈里,分好组之前先占一块转圈;首页「全部」那一面整页都包在这里,
    /// 不能等书分完组才出音乐内容,传 false 直接按未就绪的快照画,外面也不再套一层 `ZStack`。
    var showsPlaceholderUntilPrepared = true
    /// 外面持有的分组结果。首页顶部切到电台、有声书再切回来时,「全部」那一面整块卸下又装回,
    /// 自己持有的模型会跟着丢掉:书相关的区块先空着、分完组再弹出来(#283)。首页传自己的一份,
    /// 「全部」和「有声书」两面共用;不传就各自持有一份。
    var model: SpokenWordBooksModel? = nil
    @ViewBuilder var content: (SpokenWordLibrarySnapshot) -> Content

    @State private var ownBooks = SpokenWordBooksModel()

    private var books: SpokenWordBooksModel { model ?? ownBooks }

    var body: some View {
        shelf
            .spokenWordBooksRefresh(collection, model: books)
    }

    @ViewBuilder
    private var shelf: some View {
        if showsPlaceholderUntilPrepared {
            // A zero-height initial shelf can be skipped by its parent's lazy stack.
            ZStack {
                if books.snapshot.isPrepared {
                    content(books.snapshot)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        } else {
            // 首页整页:套上 ZStack 后 iPhone 上首页各区块拿不到自己的高度,横滑的一排
            // 被拉高或压扁(封面轮播上下空出一大截、「为你推荐」的卡片被裁掉上下)。
            content(books.snapshot)
        }
    }
}

/// 页面在的时候,曲库这一类内容或有声内容那份账(进度、听完、归档)一变,就让 `model` 在后台重分。
/// 只读分好的快照、不需要 `SpokenWordLibraryContent` 那层包装的页面(Mac 首页)直接挂这个。
private struct SpokenWordBooksRefresh: ViewModifier {
    let collection: SpokenWordCollection
    let model: SpokenWordBooksModel
    @Environment(MusicLibrary.self) private var library
    @State private var progressRevision = 0

    private struct RefreshIdentity: Equatable {
        let libraryRevision: UInt64
        let progressRevision: Int
    }

    func body(content: Content) -> some View {
        content
            .task(id: RefreshIdentity(libraryRevision: collection.revision(in: library), progressRevision: progressRevision)) {
                let store = SpokenWordStore.shared
                await model.refresh(
                    songs: collection.songs(in: library),
                    positions: store.positions,
                    finishedAt: store.finishedAt,
                    archived: store.archivedBookIDs,
                    inputs: .init(
                        collection: collection,
                        libraryRevision: collection.revision(in: library),
                        storeRevision: store.revision
                    )
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseSpokenWordDidChange)) { _ in
                progressRevision &+= 1
            }
    }
}

extension View {
    func spokenWordBooksRefresh(_ collection: SpokenWordCollection = .books, model: SpokenWordBooksModel) -> some View {
        modifier(SpokenWordBooksRefresh(collection: collection, model: model))
    }
}

enum SpokenWordShelfLayout: String, CaseIterable {
    /// 网格,封面下写书名;`covers` 是同一个网格只留封面(和进度),书的菜单只在长按/右键里。
    case bookshelf, covers, list

    var isGrid: Bool { self != .list }

    /// 版式键的图标。只放封面那一种是几个方块;带书名的是一个框下面一道横线,像封面下写着书名(#320、#329)。
    /// 两种网格的列数一样,不用格子的疏密来分。
    var symbol: String {
        switch self {
        case .bookshelf: "dock.rectangle"
        case .covers: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    /// 三颗键的图标画成一样高(#329):前两颗在 16 点时高 15.8,列表那颗只有 12.8,按比例放大一些。
    var symbolScale: CGFloat {
        self == .list ? 19.0 / 16.0 : 1
    }
}

enum SpokenWordShelfOrder {
    static let storageKey = "spokenWord.shelf.order"

    /// 书架给书换了 id(old → new):书架拖出来的顺序和首页「有声书」挑的书里,新 id 站到
    /// 旧 id 的位置上。两份都只在本机,旧 id 不留。
    static func carryStoredBookIDs(renames: [String: String], defaults: UserDefaults = .standard) {
        guard !renames.isEmpty else { return }
        if let raw = defaults.string(forKey: storageKey) {
            let order = decode(raw)
            let carried = SpokenWordBookRenames.carrying(order, renames: renames)
            if carried != order { defaults.set(encode(carried), forKey: storageKey) }
        }
        if let raw = defaults.string(forKey: HomeSpotlightSelection.booksStorageKey) {
            var selection = HomeSpotlightSelection.decode(raw)
            let carried = SpokenWordBookRenames.carrying(selection.pinnedIDs, renames: renames)
            if carried != selection.pinnedIDs {
                selection.pinnedIDs = carried
                defaults.set(selection.encoded(), forKey: HomeSpotlightSelection.booksStorageKey)
            }
        }
    }

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
    /// 「在本页里找」: 按书名与作者筛书架。
    @State private var findText = ""

    var body: some View {
        ScrollView {
            #if os(macOS)
            // 和电台、播客页同一种页头: 大标题一行, 查找与「首页显示哪些书」靠右。
            // 窗口工具栏在 Mac 上是藏起来的, 放在工具栏里的按钮根本露不出来。
            macHeader
            SpokenWordShelf(findText: findText)
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, 4)
                .padding(.bottom, 32)
            #else
            SpokenWordShelf(findText: findText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            #endif
        }
        #if os(macOS)
        .background(PMColor.bg.ignoresSafeArea())
        #endif
        // iPhone Duo 竖栏：书架铺到屏幕边缘，系统的玻璃胶囊浮在上面。
        .pmExtendsUnderVerticalBar()
        #if os(iOS)
        .libraryPageFind(text: $findText, prompt: "filter_spoken_word_placeholder")
        .navigationTitle("tab_spoken_word")
        #endif
        .serverCatalogPullToRefresh()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.spokenWordSongs.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    // 导航栏按钮默认跟 App 的主题色(可能跟着封面变),这一页的按钮跟有声书自己的颜色。
                    homeSpotlightButton
                        .tint(ListeningSpace.spokenWord.tint)
                }
            }
        }
        // 极简模式根页没有导航栏：大标题与「首页显示哪些书」排成页头，下面是有声书 / 播客切换。
        .minimalPageHeader {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    MinimalPageTitle("tab_spoken_word")
                    Spacer(minLength: 8)
                    MinimalHeaderActions {
                        MinimalPageFindButton()
                        if !library.spokenWordSongs.isEmpty {
                            homeSpotlightButton
                        }
                    }
                }
                MinimalSpokenSwitcher(current: .spokenWord)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
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

    #if os(iOS)
    private var homeSpotlightButton: some View {
        Button {
            showsHomeSpotlight = true
        } label: {
            Label("home_spotlight_manage_books", systemImage: "house")
        }
        .accessibilityIdentifier("spokenWord.homeSpotlight")
    }
    #endif

    #if os(macOS)
    private var macHeader: some View {
        HStack(alignment: .center, spacing: PMSpace.m) {
            Text("tab_spoken_word")
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: PMSpace.m)

            if !library.spokenWordSongs.isEmpty {
                MacLibraryFindField(text: $findText, prompt: "filter_spoken_word_placeholder")
                Button {
                    showsHomeSpotlight = true
                } label: {
                    Image(systemName: "house")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .frame(width: 32, height: 32)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.m))
                        .overlay {
                            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("home_spotlight_manage_books"))
                .accessibilityLabel(Text("home_spotlight_manage_books"))
                .accessibilityIdentifier("spokenWord.homeSpotlight")
            }
        }
        .padding(.horizontal, PMSpace.xxxl)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }
    #endif
}

/// 书架本身:在听的那本大卡、书架网格、折叠的已听完与已归档。有声页与首页的「有声」一面共用,
/// 外面的滚动容器与边距由放它的地方给。
struct SpokenWordShelf: View {
    /// 书架页「在本页里找」的输入; 首页那一面不传。
    var findText = ""
    /// 首页那一面不摆归档的书。
    var showsArchived = true
    /// 首页那一面传首页持有的分组结果(见 `SpokenWordLibraryContent.model`)。
    var model: SpokenWordBooksModel? = nil

    var body: some View {
        SpokenWordLibraryContent(model: model) { snapshot in
            SpokenWordShelfContent(snapshot: snapshot, findText: findText, showsArchived: showsArchived)
        }
    }
}

struct SpokenWordShelfContent: View {
    let snapshot: SpokenWordLibrarySnapshot
    var findText = ""
    var showsArchived = true
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage("spokenWord.shelf.showsFinished") private var showsFinished = false
    @AppStorage("spokenWord.shelf.expandsArchived") private var expandsArchived = false
    @AppStorage("spokenWord.shelf.layout") private var layout = SpokenWordShelfLayout.bookshelf
    @AppStorage("spokenWord.shelf.order") private var savedOrder = ""
    @AppStorage(HomeSpotlightSelection.booksStorageKey) private var homeSpotlightRawValue = ""
    /// 收藏的顺序;书收没收藏就看它(菜单里「收藏」「取消收藏」跟着变)。
    @AppStorage(LibraryPinStorage.defaultsKey) private var favoritePinsRawValue = ""
    /// 要整本加进歌单的那本书。
    @State private var playlistTarget: SpokenWordLibrarySnapshot.Entry?
    /// 菜单里点了「始终保持离线」,这本书却一章都不能下:说明为什么。
    @State private var offlineUnavailable: AudiobookOfflinePolicy.Availability?
    /// 书架「排序」开着: iPhone、iPad 上只有这时按住一本书是拖动, 平时长按是这本书的菜单。
    @State private var isArranging = false

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private var tint: Color { ListeningSpace.spokenWord.tint }

    private var gridColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 18, alignment: .top)]
        #else
        // Three books to a row on a phone in portrait instead of two
        // oversized ones.
        [GridItem(.adaptive(minimum: 100, maximum: 170), spacing: 14, alignment: .top)]
        #endif
    }

    /// 封面下没有书名时行距收到和列距差不多,一面封面墙;有书名时要给两行字留出呼吸。
    private var gridRowSpacing: CGFloat {
        guard layout == .covers else { return 22 }
        #if os(macOS)
        return 18
        #else
        return 14
        #endif
    }

    var body: some View {
        shelfContent(snapshot)
            // 整本书按目录顺序一次加进去;「我喜欢」也在可选的歌单里。
            .sheet(item: $playlistTarget) { entry in
                BatchAddToPlaylistSheet(songs: entry.songs)
                    #if !os(macOS)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    #endif
            }
            .alert(
                "spoken_word_keep_offline_unavailable_title",
                isPresented: Binding(
                    get: { offlineUnavailable != nil },
                    set: { if !$0 { offlineUnavailable = nil } }
                )
            ) {
                Button("ok", role: .cancel) {}
            } message: {
                Text(offlineUnavailable == .alreadyOnDevice
                     ? "spoken_word_keep_offline_on_device_message"
                     : "spoken_word_keep_offline_unsupported_message")
            }
    }

    /// 菜单里的「始终保持离线」:整本书下到本机,新加的章节也自动下。一章都不能下时不开,
    /// 弹说明(系统菜单里没有「灰但能点」的样式,所以照常显示、点了再讲原因)。
    private func keepOfflineToggle(_ book: SpokenWordBook, songs: [Song]) -> some View {
        let coordinator = AppServices.shared.alwaysDownload
        return Toggle(isOn: Binding(
            get: { coordinator.isEnabled(forBook: book.id) },
            set: { enabled in
                if enabled {
                    let availability = AudiobookOfflinePolicy.availability(coordinator.chapterKinds(for: songs))
                    guard availability == .available else {
                        offlineUnavailable = availability
                        return
                    }
                }
                coordinator.setEnabled(enabled, forBook: book.id, title: book.title, songIDs: songs.map(\.id))
            }
        )) {
            Label("playlist_always_download", systemImage: "arrow.down.circle")
        }
    }

    private func shelfContent(_ snapshot: SpokenWordLibrarySnapshot) -> some View {
        let preferred = SpokenWordShelfOrder.decode(savedOrder)
        let findQuery = LibraryFindPolicy.query(findText)
        let matches: (SpokenWordLibrarySnapshot.Entry) -> Bool = { entry in
            guard let findQuery else { return true }
            return LibraryFindPolicy.matches(findQuery, fields: [entry.book.title, entry.book.author])
        }
        let shelf = ordered(snapshot.shelf, preferred: preferred).filter(matches)
        let finished = ordered(snapshot.finished, preferred: preferred).filter(matches)
        let archived = showsArchived ? ordered(snapshot.archived, preferred: preferred).filter(matches) : []
        let nowListening = snapshot.nowListening.flatMap { matches($0) ? $0 : nil }
        return LazyVStack(alignment: .leading, spacing: 28) {
            if !snapshot.isPrepared {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            if findQuery != nil, snapshot.isPrepared,
               nowListening == nil, shelf.isEmpty, finished.isEmpty, archived.isEmpty {
                ContentUnavailableView.search(text: findText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }

            if let current = nowListening {
                SpokenWordNowListeningCard(book: current.book, songs: current.songs, tint: tint)
                    .contextMenu { bookMenu(current.book, songs: current.songs) }
                    // 铺到 iPhone Duo 竖栏底下时，静止时就在最上面、带着「继续」的这张卡照旧让开竖栏。
                    .pmClearOfVerticalBar()
            }

            if !shelf.isEmpty || !finished.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("spoken_word_shelf_section")
                            .font(sectionTitleFont)
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("spokenWord.shelf.heading")
                        Spacer(minLength: 12)
                        #if os(macOS)
                        macLayoutToggle
                        #else
                        HStack(spacing: 0) {
                            if shelf.count + finished.count + archived.count > 1 {
                                arrangeButton
                            }
                            layoutButton(.bookshelf, icon: SpokenWordShelfLayout.bookshelf.symbol, title: "spoken_word_shelf_section")
                            layoutButton(.covers, icon: SpokenWordShelfLayout.covers.symbol, title: "spoken_word_shelf_covers_only")
                            layoutButton(.list, icon: SpokenWordShelfLayout.list.symbol, title: "songs_view_list")
                        }
                        #endif
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
                                .font(sectionTitleFont)
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

                    // 在找书时听完的也直接摊开, 命中的不藏在折叠里。
                    if showsFinished || findQuery != nil {
                        bookCollection(finished)
                            .pmFadeTransition(motion: .panel)
                    }
                }
            }

            if !archived.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        pmWithAnimation(.panel) { expandsArchived.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text("spoken_word_archived_section")
                                .font(sectionTitleFont)
                            Text(verbatim: "\(archived.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(expandsArchived ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("spokenWord.shelf.archived")
                    .pmClearOfVerticalBar()

                    if expandsArchived || findQuery != nil {
                        bookCollection(archived)
                            .opacity(0.72)
                            .pmFadeTransition(motion: .panel)
                    }
                }
            }
        }
    }

    private var sectionTitleFont: Font {
        #if os(macOS)
        .system(size: 17, weight: .semibold)
        #else
        .title3.weight(.semibold)
        #endif
    }

    #if os(macOS)
    /// 和电台页的版式开关同一个样子; 44pt 见方的触控尺寸在 Mac 上把这一行撑得太高。
    private var macLayoutToggle: some View {
        HStack(spacing: 2) {
            macLayoutButton(.bookshelf, icon: SpokenWordShelfLayout.bookshelf.symbol, title: "spoken_word_shelf_section")
            macLayoutButton(.covers, icon: SpokenWordShelfLayout.covers.symbol, title: "spoken_word_shelf_covers_only")
            macLayoutButton(.list, icon: SpokenWordShelfLayout.list.symbol, title: "songs_view_list")
        }
        .padding(2)
        .frame(height: 32)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
        }
    }

    private func macLayoutButton(_ mode: SpokenWordShelfLayout, icon: String, title: LocalizedStringKey) -> some View {
        Button {
            layout = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11.5 * mode.symbolScale, weight: .medium))
                .foregroundStyle(layout == mode ? PMColor.text : PMColor.textMuted)
                .frame(width: 30, height: 26)
                .background(
                    layout == mode ? PMColor.glassBtn : .clear,
                    in: .rect(cornerRadius: PMRadius.xs)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(layout == mode ? .isSelected : [])
        .accessibilityIdentifier("spokenWord.shelf.layout.\(mode.rawValue)")
    }
    #endif

    /// 「排序」⇄「完成」。长按菜单弹在书的下方, 往下拖会划进菜单里选中某一项, 所以拖动排序单独放在这里。
    private var arrangeButton: some View {
        Button {
            pmWithAnimation(.control) { isArranging.toggle() }
        } label: {
            // 窄屏(iPhone mini)上这一行挤不下时也不折成竖排(#329),让左边的「书架」先缩。
            Text(LocalizedStringKey(isArranging ? "done" : "reorder"))
                .font(.subheadline.weight(isArranging ? .semibold : .regular))
                .foregroundStyle(isArranging ? tint : .secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("spokenWord.shelf.arrange")
    }

    private func layoutButton(_ mode: SpokenWordShelfLayout, icon: String, title: LocalizedStringKey) -> some View {
        Button {
            layout = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16 * mode.symbolScale, weight: .medium))
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
        if layout.isGrid {
            LazyVGrid(columns: gridColumns, spacing: gridRowSpacing) {
                ForEach(entries) { @Sendable entry in LazyItemCell { reorderableBookCell(entry, entries: entries) } }
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(entries) { @Sendable entry in
                    LazyItemCell {
                        reorderableBookCell(entry, entries: entries)
                            .overlay(alignment: .bottom) { Divider().padding(.leading, 66) }
                    }
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
        let allIDs = snapshot.shelf.map(\.id) + snapshot.finished.map(\.id) + snapshot.archived.map(\.id)
            + [snapshot.nowListening?.id].compactMap { $0 }
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
        SpokenWordShelfDragCell(bookID: entry.id, title: entry.book.title, isArranging: isArranging) { movedID in
            moveBook(movedID, onto: entry.id, entries: entries)
        } content: {
            bookCell(entry)
                .padding(.trailing, layout == .list ? 36 : 0)
                #if os(iOS)
                // 长按菜单挂在书本身上, 排序时被拖动层整个盖住, 按住只会拖。
                .contextMenu { bookMenu(entry.book, songs: entry.songs, entries: entries) }
                #endif
        }
        .modifier(SpokenWordBookMenuOverlay(
            alignment: layout.isGrid ? .topTrailing : .trailing,
            bookID: entry.id,
            isArranging: isArranging,
            showsMenuButton: layout != .covers
        ) {
            bookMenu(entry.book, songs: entry.songs, entries: entries)
        })
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
            if layout.isGrid {
                SpokenWordBookCoverCell(
                    book: book, coverSong: songs.first,
                    isPlaying: player.currentBookID == book.id, tint: tint,
                    showsText: layout == .bookshelf
                )
            } else {
                SpokenWordBookListRow(
                    book: book, coverSong: songs.first,
                    isPlaying: player.currentBookID == book.id, tint: tint
                )
            }
        }
        if book.items.count > 1 {
            SpokenWordBookLink(bookID: book.id) {
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
            if book.canContinue {
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
        // 一下放进「收藏」,不必先建歌单。
        let favoritePin = QuickAccessPinReference(kind: .book, itemID: book.id)
        let isFavorite = favoritePinsRawValue.isEmpty
            ? false
            : FavoriteCollectionStore.shared.isCollected(favoritePin, library: library)
        Button {
            PMHaptics.likeToggled(isLiked: !isFavorite)
            FavoriteCollectionStore.shared.setCollected(!isFavorite, favoritePin, library: library)
        } label: {
            Label(
                isFavorite ? "library_favorite_unlike" : "library_favorite_like",
                systemImage: isFavorite ? "heart.slash" : "heart"
            )
        }
        Button {
            playlistTarget = SpokenWordLibrarySnapshot.Entry(book: book, songs: songs)
        } label: {
            Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
        }
        .disabled(songs.isEmpty)
        keepOfflineToggle(book, songs: songs)
        // 归档的书不上首页,也就不给「放到首页」。
        let isArchived = store.isArchived(bookID: book.id)
        if !isArchived {
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
        }
        Button {
            store.setArchived(!isArchived, bookIDs: [book.id])
        } label: {
            if isArchived {
                Label(String(localized: "spoken_word_unarchive"), systemImage: "tray.and.arrow.up")
            } else {
                Label(String(localized: "spoken_word_archive"), systemImage: "archivebox")
            }
        }
        Button {
            // 和单曲、批量菜单同一语义:目录或文件已经说是音乐的只清掉手动记录。收听进度留着,
            // 标错了再从专辑菜单标回有声书,接着原来的地方听。
            store.move(songs, to: .music)
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

/// 书架上一本书的拖动排序。Mac 上一直拖得动(菜单在右键); iPhone、iPad 上长按是这本书的菜单,
/// 只在书架「排序」开着时拖得动。
private struct SpokenWordShelfDragCell<Content: View>: View {
    let bookID: String
    let title: String
    let isArranging: Bool
    var move: (String) -> Bool
    @ViewBuilder var content: () -> Content
    @State private var isTargeted = false

    private static var prefix: String { "primuse-spoken-word-book:" }

    var body: some View {
        Group {
            #if os(macOS)
            dragSource(content())
            #else
            if isArranging {
                // 排序时整本书只用来拖: 盖一层接住点按与长按, 不进书, 也不弹菜单。
                dragSource(content().overlay { Color.clear.contentShape(Rectangle()) })
            } else {
                content()
            }
            #endif
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

    private func dragSource(_ view: some View) -> some View {
        view.draggable(Self.prefix + bookID) {
            // Drag previews have their own host, without the shelf's environment objects.
            Label(title, systemImage: "book.closed")
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .padding(12)
                .frame(maxWidth: 220)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        #if os(macOS)
        // 整行宽的大按钮在 Mac 的书架页上和窗口一样宽, 卡片比下面的书架还抢眼;
        // 改成一条横卡: 封面与进度在左, 「继续」靠右。
        HStack(alignment: .center, spacing: PMSpace.l24) {
            details
            Button {
                if isPlayingThisBook {
                    player.togglePlayPause()
                } else if isThisBook {
                    player.resumeCurrentSpokenWordBook()
                } else {
                    SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
                }
            } label: {
                Label(
                    isPlayingThisBook ? String(localized: "pause") : String(localized: "spoken_word_continue"),
                    systemImage: isPlayingThisBook ? "pause.fill" : "play.fill"
                )
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(tint, in: .rect(cornerRadius: PMRadius.m))
                .fixedSize()
            }
            .buttonStyle(.pmPressable)
            .pmHoverLift()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: PMRadius.l14, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .contentShape(RoundedRectangle(cornerRadius: PMRadius.l14, style: .continuous))
        #else
        VStack(alignment: .leading, spacing: 14) {
            Text("spoken_word_now_listening_section")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            details

            Button {
                if isPlayingThisBook {
                    player.togglePlayPause()
                } else if isThisBook {
                    // 停着的正是这本书:别的设备已经听到了另一章(卡片上显示的那章)就从那章接着播。
                    player.resumeCurrentSpokenWordBook()
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
        #endif
    }

    private var coverWidth: CGFloat {
        #if os(macOS)
        64
        #else
        90
        #endif
    }

    @ViewBuilder
    private var details: some View {
        let content = HStack(alignment: .top, spacing: 14) {
            SpokenWordBookCover(song: songs.first, width: coverWidth, cornerRadius: 10)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                #if os(macOS)
                // 「在听」从卡片外的大标题收成卡里的一行小字, 卡片矮一截。
                Text("spoken_word_now_listening_section")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .accessibilityAddTraits(.isHeader)
                #endif
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
                SpokenWordProgressBar(value: book.fractionComplete, tint: tint)
                    .padding(.top, 2)
                    #if os(macOS)
                    .frame(maxWidth: 320)
                    #endif
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())

        if book.items.count > 1 {
            SpokenWordBookLink(bookID: book.id) {
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

/// 书与章节的听书进度条。Mac 上画成和首页「在听的书」一样的细条: 系统进度条在 Mac 上是一个个
/// AppKit 控件, 几百章的书一章一个, 还不跟书架的颜色。
struct SpokenWordProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        #if os(macOS)
        MacBookProgressBar(fraction: value, tint: tint)
        #else
        ProgressView(value: value)
            .progressViewStyle(.linear)
            .tint(tint)
        #endif
    }
}

/// 点进一本书。Mac 的详情栈只认 path 里的值: 走值导航才带返回键, 侧栏与「转到这本书」也退得掉;
/// iPhone、iPad 的各个栈没都登记这个目的地, 照旧直接给目的页。
struct SpokenWordBookLink<Label: View>: View {
    let bookID: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        #if os(macOS)
        NavigationLink(value: MacSpokenWordBookDestination(bookID: bookID), label: label)
        #else
        NavigationLink {
            SpokenWordBookDetailView(bookID: bookID)
        } label: {
            label()
        }
        #endif
    }
}

/// One book's chapters (its files, in reading order) with where the listener
/// is in each.
struct SpokenWordBookDetailView: View {
    let bookID: String
    /// 本机下载的播客节目也用这一页:一集是一章。
    var collection: SpokenWordCollection = .books
    /// Mac 详情栈给的返回; 没给时(播客页、收藏页里点进来)退回上一页。
    var onMacInlineBack: (() -> Void)? = nil

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    /// 页面开着时这本书的 id 可能变:一本没标签的书按目录成书,补读读出第一集的专辑后
    /// 整本改按专辑成书。记下最近一次看到的 id 和章节,按章节把它找回来。
    @State private var followedBookID: String?
    /// 手机头部的「自动下载」键:整本都不能下时点了讲原因;「删除所有缓存」先确认。
    @State private var autoDownloadUnavailable: AudiobookOfflinePolicy.Availability?
    @State private var confirmsCacheRemoval = false
    @Environment(SourceManager.self) private var sourceManager
    @State private var shownChapterIDs: Set<String> = []

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private func currentEntry(in snapshot: SpokenWordLibrarySnapshot) -> SpokenWordLibrarySnapshot.Entry? {
        if let entry = snapshot.entriesByID[followedBookID ?? bookID] { return entry }
        return SpokenWordBookGrouping.bookID(
            holdingMostOf: shownChapterIDs,
            among: snapshot.entriesByID.values.lazy.map(\.book)
        ).flatMap { snapshot.entriesByID[$0] }
    }

    var body: some View {
        SpokenWordLibraryContent(collection: collection) { snapshot in
            detailContent(snapshot)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .minimalNavigationDetail()
        #else
        .background(PMColor.bg.ignoresSafeArea())
        #endif
    }

    #if os(macOS)
    /// Mac 的窗口工具栏是藏起来的, 没有系统返回键: 不放这一颗只能点侧栏离开。
    private var macBackButton: some View {
        MacNavigationBackButton(accessibilityIdentifier: "spokenWord.book.back") {
            if let onMacInlineBack {
                onMacInlineBack()
            } else {
                dismiss()
            }
        }
    }
    #endif

    private func detailContent(_ snapshot: SpokenWordLibrarySnapshot) -> some View {
        let resolved = currentEntry(in: snapshot)
        return Group {
            if collection == .localPodcasts, let entry = resolved {
                // 本地节目按播客的样子排:日期、播放状态、筛选与排序。
                LocalPodcastShowDetailView(entry: entry, onMacInlineBack: onMacInlineBack)
            } else if let entry = resolved {
                let book = entry.book
                let songs = entry.songs
                let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                SpokenWordChapterList(items: book.items) {
                    header(book, songs: songs)
                } row: { index, item in
                    Button {
                        SpokenWordBookSupport.play(book, songs: songs, from: item.id, player: player)
                    } label: {
                        SpokenWordChapterItemRow(
                            item: item,
                            number: index + 1,
                            isResumeItem: item.id == book.resumeItemID && book.canContinue,
                            isPlaying: player.currentSong?.id == item.id
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .loadsOfflineAudioSnapshot(for: songsByID[item.id])
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
                        if item.position != nil {
                            Button(role: .destructive) {
                                store.clearPosition(forSongID: item.id)
                            } label: {
                                Label(
                                    String(localized: "spoken_word_clear_progress"),
                                    systemImage: "arrow.counterclockwise"
                                )
                            }
                        }
                        if let song = songsByID[item.id] {
                            SongOfflineMenuSection(song: song)
                        }
                    }
                }
                #if os(iOS)
                .navigationTitle(book.title)
                #endif
            } else if !snapshot.isPrepared {
                ProgressView()
            } else if collection == .books, library.localPodcastBookIDs.values.contains(bookID) {
                // 「转到这本书」从播放页、Mac 主窗口进来时只带着 id:本机下载的播客节目不在书架上。
                SpokenWordBookDetailView(bookID: bookID, collection: .localPodcasts, onMacInlineBack: onMacInlineBack)
            } else {
                ContentUnavailableView("tab_spoken_word", systemImage: "books.vertical")
                    #if os(macOS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        macBackButton
                            .padding(.top, 28)
                            .padding(.trailing, PMSpace.xxxl)
                    }
                    #endif
            }
        }
        .onChange(of: resolved?.id, initial: true) {
            guard let resolved else { return }
            followedBookID = resolved.id
            shownChapterIDs = Set(resolved.book.items.map(\.id))
        }
    }

    private func header(_ book: SpokenWordBook, songs: [Song]) -> some View {
        Group {
            #if os(macOS)
            macHeader(book, songs: songs)
            #else
            phoneHeader(book, songs: songs)
            #endif
        }
        // 语速键、「始终保持离线」开关这类系统控件也跟有声书的颜色,不落回 App 主题色(#313)。
        .tint(ListeningSpace.spokenWord.tint)
    }

    #if os(macOS)
    /// 和专辑、歌单详情页同一个排法: 封面在左, 标题、作者、进度与操作贴底排在右边, 返回在右上。
    private func macHeader(_ book: SpokenWordBook, songs: [Song]) -> some View {
        let tint = ListeningSpace.spokenWord.tint
        return HStack(alignment: .bottom, spacing: PMSpace.l24) {
            SpokenWordBookCover(song: songs.first, width: 132, cornerRadius: PMRadius.m10)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("tab_spoken_word")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                Text(book.title)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(PMColor.text)
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.system(size: 13))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Text(SpokenWordBookSupport.summary(book))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(PMColor.textFaint)
                if book.lastListenedAt != nil {
                    SpokenWordProgressBar(value: book.fractionComplete, tint: tint)
                        .frame(maxWidth: 320)
                }
                HStack(spacing: 8) {
                    let isPlayingBook = isPlaying(songs)
                    Button {
                        continueOrPause(book, songs: songs)
                    } label: {
                        Label(
                            continueTitle(book, isPlayingBook: isPlayingBook),
                            systemImage: isPlayingBook ? "pause.fill" : "play.fill"
                        )
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(tint, in: .rect(cornerRadius: PMRadius.m))
                        .fixedSize()
                    }
                    .buttonStyle(.pmPressable)
                    .pmHoverLift()

                    SpokenWordBookSpeedMenu(bookID: book.id)
                }
                .padding(.top, 6)
                if collection == .books {
                    SpokenWordBookOfflineRow(book: book, songs: songs)
                        .frame(maxWidth: 380, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { macBackButton }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
    #endif

    /// 正在放的是不是这本书里的一章。
    private func isCurrentBook(_ songs: [Song]) -> Bool {
        guard let currentID = player.currentSong?.id else { return false }
        return songs.contains { $0.id == currentID }
    }

    private func isPlaying(_ songs: [Song]) -> Bool {
        player.isPlaying && isCurrentBook(songs)
    }

    /// 「继续」键:正在放这本书时是「暂停」,再点一次原地接着放;
    /// 别的时候「继续」/「开始」从上次停下的地方起播(#320)。
    private func continueOrPause(_ book: SpokenWordBook, songs: [Song]) {
        if isCurrentBook(songs) {
            player.togglePlayPause()
        } else {
            SpokenWordBookSupport.play(book, songs: songs, from: nil, player: player)
        }
    }

    private func continueTitle(_ book: SpokenWordBook, isPlayingBook: Bool) -> String {
        if isPlayingBook { return String(localized: "pause") }
        return String(localized: book.canContinue ? "spoken_word_continue" : "spoken_word_start")
    }

    private func phoneHeader(_ book: SpokenWordBook, songs: [Song]) -> some View {
        phoneHeaderTop(book, songs: songs)
            .padding(.vertical, 8)
    }

    private func phoneHeaderTop(_ book: SpokenWordBook, songs: [Song]) -> some View {
        // 封面顶边对齐书名、底边对齐「继续」和语速两颗键(#320);书名折成几行、右栏变高时封面跟着长。
        SpokenWordHeaderRowLayout(preferredSide: 120, maximumSide: 170) {
            SpokenWordHeaderArtworkSlot { side in
                // 解码尺寸按最大边长取一档,边长随书名行数变时不重新解码。
                SpokenWordBookCover(song: songs.first, width: side, cornerRadius: 10, decodeSize: 170)
            }
            // 本机下载的播客节目不在「自动下载」的范围里,只给书。
            if collection == .books {
                SpokenWordBookOfflineTracker(book: book, songs: songs) { offline in
                    phoneHeaderColumn(book, songs: songs, offline: offline)
                }
            } else {
                phoneHeaderColumn(book, songs: songs, offline: nil)
            }
        }
    }

    private func phoneHeaderColumn(
        _ book: SpokenWordBook,
        songs: [Song],
        offline: SpokenWordBookOfflineStatus?
    ) -> some View {
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
                // 撑满右栏:右缘和下面章节的时长对齐。
                ProgressView(value: book.fractionComplete)
                    .progressViewStyle(.linear)
                    .tint(ListeningSpace.spokenWord.tint)
                    .frame(maxWidth: .infinity)
            }
            Spacer(minLength: 4)
            // 封面旁这一栏在 iPhone mini、放大显示或大字号下很窄:一排放不下时先让「自动下载」只剩图标、
            // 再把语速收成只剩倍数,还不行把语速和「自动下载」挪到下一行,「继续」始终是一行字。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    phoneContinueButton(book, songs: songs)
                    SpokenWordBookSpeedMenu(bookID: book.id)
                    if let offline { autoDownloadKey(book, songs: songs, offline: offline, titled: true) }
                }
                HStack(spacing: 8) {
                    phoneContinueButton(book, songs: songs)
                    SpokenWordBookSpeedMenu(bookID: book.id)
                    if let offline { autoDownloadKey(book, songs: songs, offline: offline, titled: false) }
                }
                HStack(spacing: 8) {
                    phoneContinueButton(book, songs: songs)
                    SpokenWordBookSpeedMenu(bookID: book.id, showsIcon: false)
                    if let offline { autoDownloadKey(book, songs: songs, offline: offline, titled: false) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    phoneContinueButton(book, songs: songs)
                    HStack(spacing: 8) {
                        SpokenWordBookSpeedMenu(bookID: book.id)
                        if let offline { autoDownloadKey(book, songs: songs, offline: offline, titled: false) }
                    }
                }
            }
            // 开着还没下完时写下到第几章、在等什么(#313);下完了键上是对勾,不再占一行。
            if let offline, offline.isInProgress {
                Text(offline.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            "spoken_word_keep_offline_unavailable_title",
            isPresented: Binding(
                get: { autoDownloadUnavailable != nil },
                set: { if !$0 { autoDownloadUnavailable = nil } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(autoDownloadUnavailable == .alreadyOnDevice
                 ? "spoken_word_keep_offline_on_device_message"
                 : "spoken_word_keep_offline_unsupported_message")
        }
        .confirmationDialog(
            "spoken_word_auto_download_remove_all_title",
            isPresented: $confirmsCacheRemoval,
            titleVisibility: .visible
        ) {
            if let offline {
                Button("spoken_word_auto_download_remove_all", role: .destructive) {
                    removeAllCaches(book, songs: songs, offline: offline)
                }
            }
        } message: {
            Text(offline?.isEnabled == true
                 ? "spoken_word_auto_download_remove_all_message_enabled"
                 : "spoken_word_auto_download_remove_all_message")
        }
    }

    /// 「始终保持离线」收成语速右边的一颗键(#336,照 Apple 播客的「自动下载」):
    /// 关着是下载箭头、开着是对勾;点了弹菜单开关,有下好的章节时多一项「删除所有缓存」。
    /// 菜单顶上写着已下载几章。整本都不能下时看得出不可用,点了讲原因。
    @ViewBuilder
    private func autoDownloadKey(
        _ book: SpokenWordBook,
        songs: [Song],
        offline: SpokenWordBookOfflineStatus,
        titled: Bool
    ) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: offline.isEnabled ? "checkmark.circle" : "arrow.down.circle")
                .contentTransition(.symbolEffect(.replace))
            if titled {
                Text("spoken_word_auto_download")
            }
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        if offline.availability == .available {
            Menu {
                Section {
                    Button {
                        AppServices.shared.alwaysDownload.setEnabled(
                            !offline.isEnabled,
                            forBook: book.id,
                            title: book.title,
                            songIDs: songs.map(\.id)
                        )
                    } label: {
                        Label(
                            LocalizedStringKey(offline.isEnabled
                                ? "spoken_word_auto_download_turn_off"
                                : "spoken_word_auto_download_turn_on"),
                            systemImage: offline.isEnabled ? "xmark.circle" : "arrow.down.circle"
                        )
                    }
                    if !offline.downloadedSongs.isEmpty {
                        Button(role: .destructive) {
                            confirmsCacheRemoval = true
                        } label: {
                            Label("spoken_word_auto_download_remove_all", systemImage: "trash")
                        }
                    }
                } header: {
                    Text(verbatim: offline.statusText)
                }
            } label: {
                label
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("spoken_word_auto_download"))
            .accessibilityValue(Text(verbatim: offline.statusText))
        } else {
            Button {
                autoDownloadUnavailable = offline.availability
            } label: {
                label.foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .accessibilityLabel(Text("spoken_word_auto_download"))
            .accessibilityValue(Text(verbatim: offline.statusText))
        }
    }

    /// 删掉这本书下好的章节。开着自动下载时先关掉,不然删完又会被下回来。
    private func removeAllCaches(_ book: SpokenWordBook, songs: [Song], offline: SpokenWordBookOfflineStatus) {
        if offline.isEnabled {
            AppServices.shared.alwaysDownload.setEnabled(
                false,
                forBook: book.id,
                title: book.title,
                songIDs: songs.map(\.id)
            )
        }
        sourceManager.removeOfflineDownloads(offline.downloadedSongs)
    }

    private func phoneContinueButton(_ book: SpokenWordBook, songs: [Song]) -> some View {
        let isPlayingBook = isPlaying(songs)
        return Button {
            continueOrPause(book, songs: songs)
        } label: {
            Label(
                continueTitle(book, isPlayingBook: isPlayingBook),
                systemImage: isPlayingBook ? "pause.fill" : "play.fill"
            )
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderedProminent)
        .tint(ListeningSpace.spokenWord.tint)
    }
}

// MARK: - Keep offline

/// 一本书常驻下载此刻的状况。手机书详情页那颗「自动下载」键、下面那行进度,
/// 和 Mac 上那一行「始终保持离线」(#283)读的是同一份。
struct SpokenWordBookOfflineStatus {
    let availability: AudiobookOfflinePolicy.Availability
    let isEnabled: Bool
    let progress: AudiobookOfflinePolicy.Progress
    let waitingReason: AutomaticOfflineDownloadDeferralReason?
    /// 已经下到本机的章节:「删除所有缓存」删的就是它们。
    let downloadedSongs: [Song]

    /// 开着却还没下完:页面上要写出下到第几章、在等什么(#313)。
    var isInProgress: Bool {
        availability == .available && isEnabled && !progress.isComplete
    }

    var statusText: String {
        switch availability {
        case .alreadyOnDevice:
            return String(localized: "spoken_word_keep_offline_on_device_short")
        case .unsupported:
            return String(localized: "spoken_word_keep_offline_unsupported_short")
        case .available:
            break
        }
        if isEnabled, progress.isComplete {
            return String(localized: "spoken_word_keep_offline_complete")
        }
        if isEnabled || progress.downloaded > 0 {
            let counted = String(
                format: String(localized: "spoken_word_keep_offline_progress_format"),
                progress.downloaded,
                progress.total
            )
            guard isEnabled, let waiting = Self.waitingText(waitingReason) else { return counted }
            return counted + " \u{00B7} " + waiting
        }
        return String(localized: "spoken_word_keep_offline_hint")
    }

    /// 常驻下载停着的原因,接在「已下载 N/M 章」后面。前台这一条在页面上看不到,不写。
    private static func waitingText(_ reason: AutomaticOfflineDownloadDeferralReason?) -> String? {
        guard let reason else { return nil }
        switch reason {
        case .applicationInactive, .playbackActive:
            // 书的章节在前台播放时也下;前台这一条在页面上看不到。
            return nil
        case .playbackBuffering:
            return String(localized: "spoken_word_keep_offline_waiting_buffering")
        case .networkUndetermined, .networkUnavailable:
            return String(localized: "spoken_word_keep_offline_waiting_network")
        case .expensiveNetwork:
            return String(localized: "spoken_word_keep_offline_waiting_wifi")
        case .constrainedNetwork:
            return String(localized: "spoken_word_keep_offline_waiting_low_data")
        case .lowPower:
            return String(localized: "spoken_word_keep_offline_waiting_low_power")
        case .thermalPressure:
            return String(localized: "spoken_word_keep_offline_waiting_thermal")
        case .insufficientDiskSpace:
            return String(localized: "spoken_word_keep_offline_waiting_disk")
        }
    }
}

/// 读出一本书的 `SpokenWordBookOfflineStatus` 交给 `content`:已下载几章,开着却没下完时常驻下载在等什么
/// (播放在缓冲、等 Wi-Fi、低电量……)。
struct SpokenWordBookOfflineTracker<Content: View>: View {
    let book: SpokenWordBook
    let songs: [Song]
    @ViewBuilder var content: (SpokenWordBookOfflineStatus) -> Content

    @Environment(SourceManager.self) private var sourceManager
    @Environment(AudioPlayerService.self) private var player
    @State private var downloadedIDs: Set<String> = []
    @State private var waitingReason: AutomaticOfflineDownloadDeferralReason?

    private var coordinator: AlwaysDownloadCoordinator { AppServices.shared.alwaysDownload }

    private struct ProgressKey: Equatable {
        let bookID: String
        let songIDs: [String]
        let isEnabled: Bool
        let snapshotRevision: Int
        let pinRevision: Int
    }

    private struct WaitingKey: Equatable {
        let isWaiting: Bool
        let isPlaying: Bool
        let isBuffering: Bool
        let networkGeneration: UInt64
    }

    var body: some View {
        let kinds = coordinator.chapterKinds(for: songs)
        let availability = AudiobookOfflinePolicy.availability(kinds)
        let downloadable = zip(songs, kinds).compactMap { $0.1 == .downloadable ? $0.0 : nil }
        let isEnabled = coordinator.isEnabled(forBook: book.id)
        let progress = AudiobookOfflinePolicy.progress(
            downloadableIDs: downloadable.map(\.id),
            downloadedIDs: downloadedIDs
        )
        content(SpokenWordBookOfflineStatus(
            availability: availability,
            isEnabled: isEnabled,
            progress: progress,
            waitingReason: waitingReason,
            downloadedSongs: downloadable.filter { downloadedIDs.contains($0.id) }
        ))
        .task(id: ProgressKey(
            bookID: book.id,
            songIDs: downloadable.map(\.id),
            isEnabled: isEnabled,
            snapshotRevision: sourceManager.offlineAudioSnapshotRevision,
            pinRevision: coordinator.pinRevision
        )) {
            guard !downloadable.isEmpty else {
                downloadedIDs = []
                return
            }
            let items = await sourceManager.offlineDownloadItems(in: downloadable)
            guard !Task.isCancelled else { return }
            downloadedIDs = Set(items.map(\.song.id))
        }
        // 开着还没下完时说明在等什么:播放、网络换了马上重算,电量、发热、空间这类隔一会儿再看一次。
        .task(id: WaitingKey(
            isWaiting: availability == .available && isEnabled && !progress.isComplete,
            isPlaying: player.isPlaybackActive,
            isBuffering: player.isLoading,
            networkGeneration: NetworkMonitor.shared.pathGeneration
        )) {
            guard availability == .available, isEnabled, !progress.isComplete else {
                waitingReason = nil
                return
            }
            let nextChapterBytes = downloadable.first { !downloadedIDs.contains($0.id) }?.fileSize ?? 0
            while !Task.isCancelled {
                waitingReason = coordinator.waitingReason(expectedDownloadBytes: nextChapterBytes)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

/// Mac 书籍详情页里那一行「始终保持离线」(#283):整本书下到本机,之后新加的章节也自动下,
/// 和歌单的同名开关同一套常驻下载(只在 Wi-Fi 等条件允许时下)。下面一行写已下载几章。
/// 整本书都不能下(Apple Music、本机文件夹里的原文件)时开关换成说明,点了讲原因。
/// 手机上这一行收成了头部的「自动下载」键(#336)。
struct SpokenWordBookOfflineRow: View {
    let book: SpokenWordBook
    let songs: [Song]

    @State private var showsUnavailableReason = false

    private var coordinator: AlwaysDownloadCoordinator { AppServices.shared.alwaysDownload }

    var body: some View {
        SpokenWordBookOfflineTracker(book: book, songs: songs) { status in
            row(status)
        }
    }

    private func row(_ status: SpokenWordBookOfflineStatus) -> some View {
        let availability = status.availability
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: status.progress.isComplete ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.title3)
                .foregroundStyle(availability == .available ? ListeningSpace.spokenWord.tint : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("playlist_always_download")
                    .font(.subheadline.weight(.semibold))
                Text(status.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if availability == .available {
                Toggle("", isOn: Binding(
                    get: { coordinator.isEnabled(forBook: book.id) },
                    set: { enabled in
                        coordinator.setEnabled(
                            enabled,
                            forBook: book.id,
                            title: book.title,
                            songIDs: songs.map(\.id)
                        )
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                #if os(macOS)
                .controlSize(.small)
                #endif
                .accessibilityLabel(Text("playlist_always_download"))
                .accessibilityHint(Text("spoken_word_keep_offline_hint"))
            } else {
                Button {
                    showsUnavailableReason = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("spoken_word_keep_offline_unavailable_title"))
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        // 不能开的时候整行都可点,点了讲为什么(看得出不能开,但不是点了没反应)。
        .onTapGesture {
            if availability != .available { showsUnavailableReason = true }
        }
        .alert("spoken_word_keep_offline_unavailable_title", isPresented: $showsUnavailableReason) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(availability == .alreadyOnDevice
                 ? "spoken_word_keep_offline_on_device_message"
                 : "spoken_word_keep_offline_unsupported_message")
        }
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
                    SpokenWordProgressBar(value: book.fractionComplete, tint: tint)
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

/// 书右上角(列表里是行尾)的「⋯」菜单。iPhone、iPad 上常驻, 同一份菜单也挂在长按上; 书架「排序」开着时
/// 换成一个拖动记号, 不能点。Mac 上和专辑网格一样不在每张封面上常驻一颗按钮, 指针停在这本书上才出现,
/// 同一份菜单也挂成右键菜单。「只显示封面」时不画这颗键, 菜单只留长按/右键, 排序时的拖动记号照旧。
private struct SpokenWordBookMenuOverlay<MenuItems: View>: ViewModifier {
    let alignment: Alignment
    let bookID: String
    var isArranging = false
    var showsMenuButton = true
    @ViewBuilder var menuItems: () -> MenuItems
    #if os(macOS)
    @State private var isHovered = false
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay(alignment: alignment) {
                if isHovered, showsMenuButton { badge }
            }
            .onHover { isHovered = $0 }
            .contextMenu { menuItems() }
        #else
        // 长按菜单挂在书本身上(见 `reorderableBookCell`), 托起的预览只有这本书, 不连着这颗键。
        content
            .overlay(alignment: alignment) {
                if isArranging {
                    SpokenWordBookMenuBadge(symbol: "line.3.horizontal")
                        .padding(6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else if showsMenuButton {
                    badge
                }
            }
        #endif
    }

    /// 圆底贴着封面角(列表里贴着行尾)放, 点按热区仍是 44pt 见方。标签里只放那三个点, 圆底垫在菜单键
    /// 外面: 玻璃放进 `Menu` 的标签会被撑满整个标签, 画成 44pt 的大圆。
    private var badge: some View {
        Menu {
            menuItems()
        } label: {
            SpokenWordBookMenuBadge.symbolImage("ellipsis")
                .padding(6)
                .frame(width: 44, height: 44, alignment: alignment)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(alignment: alignment) {
            SpokenWordBookMenuBadge(symbol: nil)
                .padding(6)
        }
        .accessibilityLabel(Text("more"))
        .accessibilityIdentifier("spokenWord.bookMenu." + bookID)
    }
}

/// 书右上角那颗「⋯」(排序时是拖动记号)。浅色的玻璃圆底、深色的点:iOS 26 起是 Liquid Glass,更早的系统
/// 是浅色毛玻璃加一道亮边。底始终按浅色外观画,深色模式、深色书封上也不会变成一团深灰;浅色书封上靠亮边与
/// 淡淡的投影和封面分开。降低透明度时换成不透明的浅底。手机上一排三本时封面只有一百出头宽,
/// 圆底收在 22pt, 不压过封面。
private struct SpokenWordBookMenuBadge: View {
    /// nil 只画圆底: 「⋯」的点放在 `Menu` 的标签里, 圆底垫在外面。
    var symbol: String? = "ellipsis"

    var body: some View {
        Group {
            if let symbol {
                Self.symbolImage(symbol)
            } else {
                Color.clear
            }
        }
        .frame(width: 22, height: 22)
        .modifier(SpokenWordBookMenuGlass())
        .environment(\.colorScheme, .light)
    }

    static func symbolImage(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.72))
            .frame(width: 22, height: 22)
    }
}

private struct SpokenWordBookMenuGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(white: 0.94), in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        } else {
            if #available(iOS 26.0, macOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(Color.white.opacity(0.32)).interactive(), in: Circle())
            } else {
                content
                    .background {
                        ZStack {
                            Circle().fill(.ultraThinMaterial)
                            Circle().fill(Color.white.opacity(0.38))
                        }
                    }
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
            }
        }
    }
}

/// One book on the shelf: a book-shaped cover with its progress underneath, a
/// check when it has been heard to the end.
private struct SpokenWordBookCoverCell: View {
    let book: SpokenWordBook
    let coverSong: Song?
    let isPlaying: Bool
    let tint: Color
    /// 「只显示封面」时为 false:书名和副标题不画,读屏仍照常读出来。
    var showsText = true

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
            SpokenWordProgressBar(value: book.fractionComplete, tint: tint)
                .opacity(book.lastListenedAt != nil && !book.isFinished ? 1 : 0)
                .accessibilityHidden(book.lastListenedAt == nil || book.isFinished)

            if showsText {
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
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .modifier(SpokenWordCoverOnlyAccessibility(book: book, isActive: !showsText))
    }
}

/// 只显示封面时书名不在画面上, 合并出来的读屏标签里就没有它:补上书名, 副标题与「已听完」放进值里。
private struct SpokenWordCoverOnlyAccessibility: ViewModifier {
    let book: SpokenWordBook
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .accessibilityLabel(Text(book.title))
                .accessibilityValue(Text(verbatim: value))
        } else {
            content
        }
    }

    private var value: String {
        let subtitle = SpokenWordBookSupport.subtitle(book)
        guard book.isFinished else { return subtitle }
        return [subtitle, String(localized: "spoken_word_finished")]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// A book's cover, the first item's artwork, in a square frame
/// (`SpokenWordCoverLayout`) with the artwork fitted whole inside it, never
/// cropped or stretched. Where a portrait or wide cover leaves room, a blurred
/// enlargement of the same art fills it.
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
        if let song, PodcastPlaybackSong.isEpisode(song) || SpokenWordStore.shared.isPodcast(song), let width {
            // 播客单集(订阅的,或本机下载的)不是书:封面是方的,边长取书框的高,占的还是同一块槽位。
            let side = SpokenWordCoverLayout.height(forWidth: width)
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: decodeSize ?? side,
                cornerRadius: 0,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                placeholderIcon: "antenna.radiowaves.left.and.right",
                fillsProposedSize: true
            )
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        } else {
            bookFrame(shape)
        }
    }

    private func bookFrame(_ shape: RoundedRectangle) -> some View {
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
                .bookCoverLayout(frameAspectRatio: SpokenWordCoverLayout.aspectRatio)
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

    /// 左右留白。Mac 与资料库其他页对齐到 36。
    private var inset: CGFloat {
        #if os(macOS)
        PMSpace.xxxl
        #else
        16
        #endif
    }

    var body: some View {
        let showsScrubber = SpokenWordChapterScrubber.isShown(chapterCount: items.count)
        ScrollView {
            LazyVStack(spacing: 0) {
                // 左右留白一样宽:快速拖动条只在滚动、拖动时浮出来(和系统滚动条一样),
                // 不再给它在右边一直让出一条,整页看着偏左(#336)。
                header()
                    .padding(.horizontal, inset)
                    .padding(.vertical, 16)
                    // 铺到 iPhone Duo 竖栏底下时，带着「继续」与语速的头部照旧让开竖栏。
                    .pmClearOfVerticalBar()
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(index, item)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, inset)
                        .overlay(alignment: .bottom) {
                            Divider().padding(.leading, inset + 40)
                                .padding(.trailing, inset)
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

/// 拖动条淡出的截止时间与计时任务。不参与观察:滚动时每帧都要挪截止时间。
@MainActor
final class SpokenWordScrubberAutoHide {
    var deadline = ContinuousClock.now
    var task: Task<Void, Never>?
}

/// 拖动条滑块的底:毛玻璃,阴影压得很淡,不在页面边上显得突兀(#336)。拖着时描边深一点。
/// 打开「降低透明度」时系统自己把玻璃和材质换成实底。
private struct SpokenWordScrubberThumbGlass: ViewModifier {
    let isDragging: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(isDragging ? 0.18 : 0), lineWidth: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(isDragging ? 0.18 : 0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(isDragging ? 0.08 : 0.03), radius: 2, y: 1)
        }
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
/// 和系统滚动条一样只在滚动、拖动时浮在行尾上面, 停下一会儿就淡出; 进页面时先露一下,
/// 让人知道有它。开着旁白时一直在(#336)。
struct SpokenWordChapterScrubber: View {
    /// 少于这么多章时一屏两屏就翻完了, 不需要它。
    static let minimumChapterCount = 30
    /// 停下多久后淡出。
    static let visibleDuration: Duration = .seconds(1.6)

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
    @State private var isRevealed = true
    @State private var autoHide = SpokenWordScrubberAutoHide()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var showsThumb: Bool { isRevealed || isDragging || voiceOverEnabled }

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
                .modifier(SpokenWordScrubberThumbGlass(isDragging: isDragging))
                .frame(width: 44, height: thumbHeight)
                .contentShape(Rectangle())
                .gesture(dragGesture(track: track))
                .offset(y: thumbTop)
                .opacity(showsThumb ? 1 : 0)
                .allowsHitTesting(showsThumb)
                .animation(.easeOut(duration: 0.25), value: showsThumb)
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
                reveal()
            }
        }
        .onChange(of: scroll.fraction) { _, _ in reveal() }
        .onAppear { reveal() }
        .onDisappear {
            autoHide.task?.cancel()
            autoHide.task = nil
        }
    }

    /// 露出来, 再等 `visibleDuration` 没动静就淡出。滚动时每帧都会来一次, 只挪截止时间,
    /// 不每帧新起一个计时任务。
    private func reveal() {
        autoHide.deadline = .now + Self.visibleDuration
        if !isRevealed { isRevealed = true }
        guard autoHide.task == nil else { return }
        autoHide.task = Task { @MainActor in
            while !Task.isCancelled {
                let remaining = autoHide.deadline - .now
                guard remaining > .zero else { break }
                try? await Task.sleep(for: remaining)
            }
            autoHide.task = nil
            guard !Task.isCancelled, !isDragging else { return }
            isRevealed = false
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
            // 序号、对勾、波形三种记号在这一栏里居中,上下对成一条线。
            .frame(minWidth: 28, alignment: .center)

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
                    SpokenWordProgressBar(value: item.fractionComplete, tint: ListeningSpace.spokenWord.tint)
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

#if !os(macOS)
/// 语速键给了固定高度时的样子:染色的字压在浅灰胶囊上,和 `PodcastCircleKey` 同一种底。
private struct SpokenWordSpeedKeyFace: ViewModifier {
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let height {
            content
                .foregroundStyle(.tint)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .contentShape(Capsule())
        } else {
            content
        }
    }
}

private struct SpokenWordSpeedKeyStyle: ViewModifier {
    let usesKeyFace: Bool

    func body(content: Content) -> some View {
        if usesKeyFace {
            content
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
#endif

/// A book's own speed on its page. "Default" follows the global spoken-word
/// speed; any other choice is remembered for this book only and applies at
/// once if it is playing. The local podcast page uses it per show.
struct SpokenWordBookSpeedMenu: View {
    let bookID: String
    /// 手机上的窄版面只写倍数、不带仪表图标。
    var showsIcon = true
    /// 给了就画成这么高的胶囊键,和同一排的圆键对齐(本地节目页,#336);不给是系统的描边按钮。
    var keyHeight: CGFloat? = nil

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
            #if os(macOS)
            Label(SpokenWordPlaybackRatePolicy.label(for: rate), systemImage: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.m))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
            #else
            Group {
                if showsIcon {
                    // 不用 `Label`:放在 List 行里(本机节目页)时它的图标会被染成行的强调色,
                    // 也就是 App 主题色,不跟按钮上设的播客颜色(#320)。
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                        Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate))
                    }
                } else {
                    Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate))
                }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .modifier(SpokenWordSpeedKeyFace(height: keyHeight))
            #endif
        }
        #if os(macOS)
        // 与旁边「继续」同高的一颗按钮, 不是系统的弹出菜单外观。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        #else
        .modifier(SpokenWordSpeedKeyStyle(usesKeyFace: keyHeight != nil))
        #endif
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
    /// listener left off. A finished item heard again stays finished and
    /// resumes from where its replay stopped, or from the top. CarPlay
    /// shares this and plays through its own path.
    @MainActor
    static func prepareStart(of book: SpokenWordBook, songs: [Song], from itemID: String?) -> Int? {
        guard !songs.isEmpty else { return nil }
        let startID = SpokenWordCarPlayShelfPolicy.startItemID(for: book, requested: itemID) ?? songs[0].id
        return songs.firstIndex { $0.id == startID } ?? 0
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
