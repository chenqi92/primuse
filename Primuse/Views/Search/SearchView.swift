import SwiftUI
import MusicKit
import PrimuseKit

struct LibrarySearchScope: Equatable {
    enum Kind {
        case playlist, smartPlaylist, folder, source, songs, album, artist, genre

        var title: String {
            switch self {
            case .playlist: String(localized: "tab_playlists")
            case .smartPlaylist: String(localized: "smart_playlists_section")
            case .folder: String(localized: "library_browse_folder")
            case .source: String(localized: "source_label")
            case .songs: String(localized: "tab_songs")
            case .album: String(localized: "tab_albums")
            case .artist: String(localized: "tab_artists")
            case .genre: String(localized: "tab_genres")
            }
        }

        var systemImage: String {
            switch self {
            case .playlist: "music.note.list"
            case .smartPlaylist: "sparkles"
            case .folder: "folder.fill"
            case .source: "externaldrive.fill"
            case .songs: "music.note"
            case .album: "square.stack.fill"
            case .artist: "music.mic"
            case .genre: "guitars.fill"
            }
        }

        var color: Color {
            switch self {
            case .playlist: .purple
            case .smartPlaylist: .indigo
            case .folder: .orange
            case .source: .teal
            case .songs: .blue
            case .album: .pink
            case .artist: .blue
            case .genre: .green
            }
        }
    }

    let title: String
    let songIDs: Set<String>
    var includesSubfolders = false
    var kind: Kind = .playlist
    var detail: String? = nil

    func songs(in visibleSongs: [PrimuseKit.Song]) -> [PrimuseKit.Song] {
        visibleSongs.filter { songIDs.contains($0.id) }
    }

    static func folder(
        node: LibraryFolderNode,
        index: LibraryFolderIndex,
        title: (LibraryFolderNode) -> String
    ) -> Self {
        let kind: Kind
        switch node.kind {
        case .source: kind = .source
        case .playlist: kind = .playlist
        case .librarySongs, .notInPlaylist: kind = .songs
        default: kind = .folder
        }
        var ancestors: [String] = []
        var parentID = node.parentID
        while let id = parentID, let parent = index.node(withID: id) {
            ancestors.append(title(parent))
            parentID = parent.parentID
        }
        return Self(
            title: title(node),
            songIDs: Set(index.songIDs(in: node.id, scope: .descendants)),
            includesSubfolders: node.kind == .folder || node.kind == .scanRoot
                || (node.kind == .source && index.children(of: node.id).contains {
                    $0.kind == .folder || $0.kind == .scanRoot
                }),
            kind: kind,
            detail: ancestors.isEmpty ? nil : ancestors.reversed().joined(separator: " › ")
        )
    }
}

#if os(iOS)
@MainActor
final class LibrarySearchNavigation {
    private struct Entry {
        let owner: UUID
        let tab: Int
        let resolve: @MainActor () -> LibrarySearchScope?
    }

    private var entries: [Entry] = []

    func register(owner: UUID, tab: Int, resolve: @escaping @MainActor () -> LibrarySearchScope?) {
        remove(owner: owner)
        entries.append(Entry(owner: owner, tab: tab, resolve: resolve))
    }

    func remove(owner: UUID) {
        entries.removeAll { $0.owner == owner }
    }

    func scope(for tab: Int) -> LibrarySearchScope? {
        guard tab == 1 else { return nil }
        return entries.last { $0.tab == tab }?.resolve()
    }
}

private struct LibrarySearchNavigationKey: EnvironmentKey {
    static let defaultValue: LibrarySearchNavigation? = nil
}

private struct LibrarySearchTabKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var librarySearchNavigation: LibrarySearchNavigation? {
        get { self[LibrarySearchNavigationKey.self] }
        set { self[LibrarySearchNavigationKey.self] = newValue }
    }

    var librarySearchTab: Int {
        get { self[LibrarySearchTabKey.self] }
        set { self[LibrarySearchTabKey.self] = newValue }
    }
}

private struct LibrarySearchContextModifier: ViewModifier {
    @Environment(\.librarySearchNavigation) private var navigation
    @Environment(\.librarySearchTab) private var tab
    @State private var owner = UUID()
    let resolve: @MainActor () -> LibrarySearchScope?

    func body(content: Content) -> some View {
        content
            .onAppear { navigation?.register(owner: owner, tab: tab, resolve: resolve) }
            .onDisappear { navigation?.remove(owner: owner) }
    }
}

extension View {
    func librarySearchContext(_ resolve: @escaping @MainActor () -> LibrarySearchScope?) -> some View {
        modifier(LibrarySearchContextModifier(resolve: resolve))
    }
}
#endif

struct SearchScopeSwitchButton: View {
    private enum Selection: Hashable {
        case global
        case current
    }

    @Binding var scope: LibrarySearchScope?
    let context: LibrarySearchScope

    private var selection: Binding<Selection> {
        Binding(
            get: { scope == nil ? .global : .current },
            set: { selection in
                scope = selection == .global ? nil : context
            }
        )
    }

    var body: some View {
        Menu {
            Picker("search_scope", selection: selection) {
                Label("search_global", systemImage: "globe")
                    .tag(Selection.global)
                Label {
                    Text(verbatim: context.title)
                } icon: {
                    Image(systemName: context.kind.systemImage)
                }
                .tag(Selection.current)
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(verbatim: scope?.title ?? String(localized: "search_global"))
            } icon: {
                Image(systemName: scope?.kind.systemImage ?? "globe")
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .help(scope?.title ?? String(localized: "search_global"))
        .accessibilityLabel(Text("search_scope"))
        .accessibilityValue(Text(scope?.title ?? String(localized: "search_global")))
        .accessibilityIdentifier("search.scope.menu")
    }
}

#if os(iOS)
struct SearchScopeCard: View {
    let scope: LibrarySearchScope
    /// 卡片右侧的关闭键: 直接撤掉这个范围回到全局搜索, 不必再去菜单里切。
    var onClear: (() -> Void)? = nil

    /// 这张卡排在结果区外面、不参与滚动。手机横屏时结果区本来就只剩两百多点,
    /// 再顶掉一百多点就只看得到一行半歌, 所以紧凑高度下压成一条: 图标 + 范围名。
    @Environment(\.pmHeightClass) private var heightClass

    var body: some View {
        let cardCorner = heightClass.value(18, compact: 12)
        let rowAlignment: VerticalAlignment = heightClass.pick(.top, compact: .center)
        HStack(alignment: rowAlignment, spacing: 8) {
            scopeSummary(rowAlignment: rowAlignment)
            if let onClear {
                clearButton(onClear)
            }
        }
        .padding(heightClass.value(14, compact: 8))
        .background(scope.kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: cardCorner))
        .overlay {
            RoundedRectangle(cornerRadius: cardCorner)
                .strokeBorder(scope.kind.color.opacity(0.24), lineWidth: 1)
        }
    }

    /// 关闭键不能并进卡片的合并无障碍元素里, 否则读屏时按不到它。
    private func clearButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: heightClass.value(22, compact: 18)))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 紧凑高度下卡片只有 28 点高的一条, 点按区域照旧 44 点, 但不把卡片撑高。
        .padding(.vertical, heightClass.value(0, compact: -8))
        .padding(.trailing, -6)
        .accessibilityLabel(Text("search_global"))
        .accessibilityIdentifier("search.scope.clear")
    }

    private func scopeSummary(rowAlignment: VerticalAlignment) -> some View {
        let iconSide = heightClass.value(44, compact: 28)
        let iconCorner = heightClass.value(12, compact: 8)
        return HStack(alignment: rowAlignment, spacing: 12) {
            Image(systemName: scope.kind.systemImage)
                .font(.system(size: heightClass.value(20, compact: 13), weight: .semibold))
                .foregroundStyle(scope.kind.color)
                .frame(width: iconSide, height: iconSide)
                .background(scope.kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: iconCorner))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                if !heightClass.isCompact {
                    Text(String(format: String(localized: "search_scope_title_format"), scope.kind.title))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: scope.title)
                    .font(.headline)
                    .lineLimit(heightClass.pick(2, compact: 1))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = scope.detail, !detail.isEmpty, !heightClass.isCompact {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if scope.includesSubfolders, !heightClass.isCompact {
                    Label("search_scope_includes_subfolders", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.scope.card")
    }
}
#endif

enum SearchCatalogPolicy {
    static func albums(
        query: String,
        visibleAlbums: [PrimuseKit.Album],
        relatedAlbums: [PrimuseKit.Album]
    ) -> [PrimuseKit.Album] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let directMatches = LibrarySearchWorker.compute(
            query: query,
            songs: [],
            albums: visibleAlbums,
            cache: LibrarySearchCache(),
            includeLyrics: false,
            songLimit: 0,
            albumLimit: visibleAlbums.count
        ).albumResults
        let visibleIDs = Set(visibleAlbums.map(\.id))
        var seen = Set(directMatches.map(\.id))
        return directMatches + relatedAlbums.filter {
            visibleIDs.contains($0.id) && seen.insert($0.id).inserted
        }
    }
}

@MainActor
private final class SearchWorkCoordinator {
    var searchTask: Task<Void, Never>?
    var intelligenceTask: Task<Void, Never>?
    var lyricsCache = LibrarySearchCache()
    var generation = 0

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        intelligenceTask?.cancel()
        intelligenceTask = nil
    }
}

#if os(iOS)
private enum SearchCatalogDestination: Hashable {
    case albums, artists
}

private struct SearchAlbumResultsView: View {
    let albums: [PrimuseKit.Album]

    @Environment(\.pmHeightClass) private var heightClass

    var body: some View {
        // 和资料库的专辑网格用同一套断点, 手机横屏下一起收到 100。
        let columns = [GridItem(.adaptive(minimum: heightClass.value(150, compact: 100)), spacing: 16)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: heightClass.value(22, compact: 14)) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        AlbumCardView(album: album)
                    }
                    .buttonStyle(.plain)
                    .mediaZoomSource(.album, id: album.id)
                }
            }
            .padding(20)
        }
        .navigationTitle(Text("tab_albums"))
        .minimalNavigationDetail()
    }
}
#endif

private struct SemanticLibrarySearchResult: Identifiable, Sendable {
    let song: PrimuseKit.Song
    let relatedConcept: String

    var id: String { song.id }
}

private enum SemanticSearchFeedback: Equatable {
    case idle
    case loading
    case success(provider: String, resultCount: Int, fallbackDepth: Int)
    case noMatches(provider: String, fallbackDepth: Int)
    case failed

    var isVisible: Bool { self != .idle }
}

#if os(macOS)
private enum MacSearchResultFilter: Hashable {
    case all
    case songs
    case albums
    case artists
    case lyrics
    case appleMusic
}
#endif

private struct SearchLibraryRevisionObserver: View {
    @Environment(MusicLibrary.self) private var library
    let onRevisionChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: library.searchRevision) { _, _ in onRevisionChange() }
            .onChange(of: library.lyricsSearchRevision) { _, _ in onRevisionChange() }
    }
}

@MainActor
enum SearchHistoryStore {
    static let key = CloudKVSKey.recentSearches
    static let didChangeNotification = Notification.Name("primuse.searchHistory.didChange")
    private static let limit = 12

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        var queries = load()
        queries.removeAll { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
        queries.insert(trimmedQuery, at: 0)
        save(Array(queries.prefix(limit)))
    }

    static func save(_ queries: [String]) {
        UserDefaults.standard.set(queries, forKey: key)
        CloudKVSSync.shared.markChanged(key: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

struct SearchView: View {
    @Environment(AudioPlayerService.self) private var player
    /// 搜索结果这一层导航栈的 zoom 命名空间。
    @Namespace private var searchZoomNamespace
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage(AppleMusicFeatureSettings.catalogSearchEnabledKey)
    private var appleMusicCatalogSearchEnabled = true
    @AppStorage(SearchResultSectionLayout.orderKey)
    private var resultSectionOrderRawValue = ""
    @AppStorage(SearchResultSectionLayout.hiddenKey)
    private var hiddenResultSectionsRawValue = ""
    @State private var showsResultLayoutEditor = false
    #if os(iOS)
    @Environment(\.appNavigationMode) private var appNavigationMode
    #endif
    /// 手机横屏时结果区只剩两百多点, 范围卡片与专辑架都要收一档。
    @Environment(\.pmHeightClass) private var heightClass
    @Binding var searchText: String
    @Binding private var scope: LibrarySearchScope?
    /// 用户刚点了搜索入口(底部标签 / iPad 侧栏)。消费掉就置回 false,
    /// 视图重建时不会再弹一次键盘。
    @Binding private var activatesSearchField: Bool
    @State private var isSearchFieldPresented = false
    /// 极简导航的自绘顶栏上点了「调整搜索结果」。同样消费掉就置回 false。
    @Binding private var requestsResultLayoutEditor: Bool
    private let contextualScope: LibrarySearchScope?
    let onShowInLibrary: (PrimuseKit.Song) -> Void
    @State private var searchResults: [LibrarySearchResult] = []
    @State private var matchingAlbums: [PrimuseKit.Album] = []
    @State private var semanticResults: [SemanticLibrarySearchResult] = []
    @State private var recentSearches: [String] = []
    /// Task handles, generation tokens and the reusable lyrics index are
    /// operational state. Keeping them outside SwiftUI rendering state avoids
    /// extra full-page evaluations on every debounce/cancellation/cache fill.
    @State private var workCoordinator = SearchWorkCoordinator()
    /// 是否正在跑一次搜索 (含 debounce + detached worker)。用来在结果还没
    /// 出来时显示 loading 占位, 避免 200ms+ 窗口里先闪一下 "无匹配" 再
    /// 跳到结果。
    @State private var isSearching: Bool = false
    @State private var isIntelligenceSearching: Bool = false
    @State private var semanticSearchFeedback: SemanticSearchFeedback = .idle
    /// 当前已经渲染的结果对应的 query。如果它与 searchText 不一致, 说明
    /// 屏幕上还是上一轮的旧结果, ContentUnavailableView 不该出来。
    @State private var renderedQuery: String = ""
    @State private var intelligenceRenderedQuery: String = ""
    @State private var selection = SongSelectionModel()
    #if os(macOS)
    @State private var macResultFilter: MacSearchResultFilter = .all
    /// 「全部」页结果区的宽度, 决定并排几栏、一排放几张封面。先给一个常见值,
    /// 量到真实宽度后再排一次。
    @State private var macResultsWidth: CGFloat = 960
    #endif

    init(
        searchText: Binding<String>,
        scope: Binding<LibrarySearchScope?> = .constant(nil),
        activatesSearchField: Binding<Bool> = .constant(false),
        requestsResultLayoutEditor: Binding<Bool> = .constant(false),
        contextualScope: LibrarySearchScope? = nil,
        onShowInLibrary: @escaping (PrimuseKit.Song) -> Void = { _ in }
    ) {
        self._searchText = searchText
        self._scope = scope
        self._activatesSearchField = activatesSearchField
        self._requestsResultLayoutEditor = requestsResultLayoutEditor
        self.contextualScope = contextualScope
        self.onShowInLibrary = onShowInLibrary
    }

    private var usesMinimalNavigation: Bool {
        #if os(iOS)
        appNavigationMode == .minimal
        #else
        false
        #endif
    }

    private var visibleSemanticResults: [SemanticLibrarySearchResult] {
        guard intelligenceRenderedQuery == searchText,
              renderedQuery == searchText else { return [] }
        let composition = LibrarySearchCompositionPolicy.compose(
            primaryResultIDs: searchResults.map(\.song.id),
            intelligentResultIDs: semanticResults.map(\.song.id),
            intelligentAvailable: hasUsableIntelligentResponse
        )
        let supplementIDs = Set(composition.intelligentSupplementIDs)
        return semanticResults.filter { supplementIDs.contains($0.song.id) }
    }

    private var hasUsableIntelligentResponse: Bool {
        switch semanticSearchFeedback {
        case .success, .noMatches:
            return true
        case .loading:
            return !semanticResults.isEmpty
        case .idle, .failed:
            return false
        }
    }

    private var appleMusicSearchEnabled: Bool {
        scope == nil && AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
            catalogSearchEnabled: appleMusicCatalogSearchEnabled,
            sourceInstalled: library.appleMusicSourceInstalled,
            disabledSourceIDs: library.disabledSourceIDs
        )
    }

    private var visibleAppleMusicSearchResults: [MusicKit.Song] {
        appleMusicSearchEnabled ? appleMusic.searchResults : []
    }

    private var resultLayout: SearchResultLayout {
        SearchResultLayout(
            orderRawValue: resultSectionOrderRawValue,
            hiddenRawValue: hiddenResultSectionsRawValue
        )
    }

    /// 结果区按用户排的顺序出场的块。Apple Music 另看曲库搜索开关与源是否可用。
    private var orderedResultSections: [SearchResultSection] {
        let layout = resultLayout
        return layout.order.filter { section in
            section == .appleMusic ? appleMusicSearchEnabled : layout.shows(section)
        }
    }

    private var resultLayoutEditor: SearchResultLayoutEditor {
        SearchResultLayoutEditor(
            showsIntelligentRow: intelligence.isSemanticSearchConfigured,
            showsAppleMusicRow: AppleMusicCatalogSearchAvailabilityPolicy.isEnabled(
                catalogSearchEnabled: true,
                sourceInstalled: library.appleMusicSourceInstalled,
                disabledSourceIDs: library.disabledSourceIDs
            )
        )
    }

    /// “全选”只圈用户在当前筛选下真正看得到的本地歌曲，顺序跟屏幕上一致。
    /// Apple Music 在线结果不是本地曲库条目，不参与多选。
    private var selectableSongIDs: [String] {
        let sections = orderedResultSections
        #if os(macOS)
        switch macResultFilter {
        case .albums, .artists, .appleMusic:
            return []
        case .lyrics:
            return searchResults
                .filter { $0.matchKind == .lyrics }
                .map(\.song.id)
        case .songs:
            return sections.flatMap { section -> [String] in
                if let kind = section.libraryMatchKind {
                    return searchResults
                        .filter { $0.matchKind == kind }
                        .map(\.song.id)
                }
                return section == .intelligent
                    ? visibleSemanticResults.prefix(40).map(\.song.id)
                    : []
            }
        case .all:
            return macAllShownSongIDs
        }
        #else
        return sections.flatMap { section -> [String] in
            if let kind = section.libraryMatchKind {
                let bucket = searchResults.filter { $0.matchKind == kind }
                return bucket.prefix(scope == nil ? 40 : bucket.count).map(\.song.id)
            }
            return section == .intelligent
                ? visibleSemanticResults.prefix(40).map(\.song.id)
                : []
        }
        #endif
    }

    var body: some View {
        // macOS: 不再自带 NavigationStack —— SearchView 已经渲染在
        // MacDetailContainer 的栈里, 点专辑/艺术家结果时直接 push 到主栈,
        // 跟从专辑网格点进去走同一条导航 (返回按钮 / 路由复位都一致), 不会
        // 被困在搜索页自己的嵌套栈里。iOS 仍需要自己的 NavigationStack。
        Group {
            #if os(macOS)
            macBody
            #else
            NavigationStack {
                iosBody
            }
            #endif
        }
        .mediaZoomNamespace(searchZoomNamespace)
        .songBatchActions(
            selection: selection,
            orderedIDs: { selectableSongIDs },
            resolve: { library.song(id: $0) }
        )
        .onChange(of: renderedQuery) { _, _ in
            // 换了一轮结果，之前选中的歌多半已经不在屏幕上了。
            selection.prune(to: Set(selectableSongIDs))
        }
        .onChange(of: semanticResults.map(\.id)) { _, _ in
            selection.prune(to: Set(selectableSongIDs))
        }
        .onAppear {
            loadRecentSearches()
            if searchText.isEmpty {
                // 搜索词可能是在别的页面清掉的, 这时本页收不到变化;
                // Apple Music 的结果存在共享服务里, 不清就会带着上一轮的计数。
                appleMusic.clearCatalogSearchResults()
            }
            resumeSearchIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudKVSSync.externalChangeNotification)) { note in
            guard let key = note.userInfo?["key"] as? String,
                  key == SearchHistoryStore.key else { return }
            loadRecentSearches()
        }
        .onReceive(NotificationCenter.default.publisher(for: SearchHistoryStore.didChangeNotification)) { _ in
            loadRecentSearches()
        }
        .onChange(of: scope) { _, _ in
            selection.deactivate()
            searchResults = []
            matchingAlbums = []
            semanticResults = []
            renderedQuery = ""
            workCoordinator.lyricsCache = LibrarySearchCache()
            performSearch(query: searchText)
            performAppleMusicSearch(query: searchText)
        }
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
            performAppleMusicSearch(query: newValue)
        }
        .onChange(of: hiddenResultSectionsRawValue) { _, _ in
            // 关掉的块不再查、也不再占歌; 重搜一遍, 歌才会落回还开着的那几块。
            performSearch(query: searchText)
        }
        .onChange(of: appleMusicSearchEnabled) { _, isEnabled in
            if isEnabled {
                performAppleMusicSearch(query: searchText)
            } else {
                appleMusic.clearCatalogSearchResults()
            }
        }
        .background {
            SearchLibraryRevisionObserver {
                workCoordinator.lyricsCache = LibrarySearchCache()
                if !searchText.isEmpty {
                    performSearch(query: searchText)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseLibrarySearchIndexDidChange)) { _ in
            guard !searchText.isEmpty else { return }
            performSearch(query: searchText)
        }
        .onDisappear { workCoordinator.cancelSearch() }
    }

    @ViewBuilder
    private var iosBody: some View {
        if usesMinimalNavigation {
            iosSearchContent
                .floatingInputPanelClearance()
        } else {
            iosSearchContent
                .searchable(
                    text: $searchText,
                    isPresented: $isSearchFieldPresented,
                    prompt: Text(searchPrompt)
                )
                .onSubmit(of: .search) { addRecentSearch(searchText) }
                .floatingInputPanelClearance()
                .onChange(of: activatesSearchField, initial: true) { _, requested in
                    guard requested else { return }
                    activatesSearchField = false
                    // 点进搜索就直接弹出键盘。刚切过来的这一帧搜索框还没挂上,
                    // 当场设 true 会被忽略, 所以放到下一轮主线程再激活。
                    Task { @MainActor in isSearchFieldPresented = true }
                }
        }
    }

    private var iosSearchContent: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if let scope {
                // 与范围菜单里选「全局搜索」走同一条路: 不带动画, 结果表整批换掉。
                SearchScopeCard(scope: scope) { self.scope = nil }
                    .padding(.horizontal, 16)
                    .padding(.vertical, heightClass.value(10, compact: 4))
            }
            #endif
            iosSearchResults
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(usesMinimalNavigation ? Text("") : Text("search_title"))
        .toolbarTitleDisplayMode(usesMinimalNavigation ? .inline : .inlineLarge)
        #if os(iOS)
        .minimalNavigationRoot()
        .toolbar {
            if !usesMinimalNavigation, let contextualScope {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchScopeSwitchButton(scope: $scope, context: contextualScope)
                        .labelStyle(.iconOnly)
                }
            }
            // 放在最后, 始终贴着右边缘; 有范围按钮时它排在左边。
            if !usesMinimalNavigation {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchResultLayoutButton { showsResultLayoutEditor = true }
                }
            }
        }
        .sheet(isPresented: $showsResultLayoutEditor) {
            resultLayoutEditor
        }
        .onChange(of: requestsResultLayoutEditor) { _, requested in
            guard requested else { return }
            requestsResultLayoutEditor = false
            showsResultLayoutEditor = true
        }
        #endif
        .navigationDestination(for: PrimuseKit.Album.self) {
            AlbumDetailView(album: $0)
                .mediaZoomDestination(.album, id: $0.id)
        }
        .navigationDestination(for: PrimuseKit.Artist.self) {
            ArtistDetailView(artist: $0)
                .mediaZoomDestination(.artist, id: $0.id)
        }
        #if os(iOS)
        .navigationDestination(for: SearchCatalogDestination.self) { destination in
            switch destination {
            case .albums:
                SearchAlbumResultsView(albums: matchingAlbums)
            case .artists:
                ArtistListView(artists: matchingArtists)
                    .navigationTitle(Text("tab_artists"))
                    .minimalNavigationDetail()
            }
        }
        #endif
    }

    private var iosSearchResults: some View {
        // 只给"不随击键翻转"的几支补淡入: 旧分支瞬间消失、新分支自己淡进来,
        // 两棵子树不并存。搜索中占位 ⇄ 结果表每敲一键就翻一次, 保持硬切。
        Group {
            if searchText.isEmpty {
                if library.visibleSongs.isEmpty {
                    EmptyStateView(
                        titleKey: "search_empty_library",
                        descriptionKey: "search_empty_library_desc",
                        systemImage: "magnifyingglass"
                    )
                    .pmAppearFade(.contentAppear)
                } else {
                    recentSearchView
                        .pmAppearFade(.contentAppear)
                }
            } else if isSearching && renderedQuery != searchText {
                searchingPlaceholder
            } else if searchResults.isEmpty
                        && matchingAlbums.isEmpty
                        && matchingArtists.isEmpty
                        && visibleSemanticResults.isEmpty
                        && visibleAppleMusicSearchResults.isEmpty
                        && !semanticSearchFeedback.isVisible {
                if isSearching || renderedQuery != searchText {
                    searchingPlaceholder
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .pmAppearFade(.contentAppear)
                }
            } else {
                searchResultsView
            }
        }
    }

    private var searchPrompt: String {
        guard let scope else { return String(localized: "search_prompt") }
        return String(format: String(localized: "search_scope_prompt_format"), scope.title)
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            macSearchHeader
            macSearchContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .simultaneousGesture(
            TapGesture().onEnded {
                NotificationCenter.default.post(name: .primuseDismissSearchFocus, object: nil)
            }
        )
        .onSubmit(of: .search) { addRecentSearch(searchText) }
        .onChange(of: macResultFilter) { _, _ in
            selection.prune(to: Set(selectableSongIDs))
        }
        .onChange(of: appleMusicSearchEnabled) { _, isEnabled in
            if !isEnabled, macResultFilter == .appleMusic {
                macResultFilter = .all
            }
        }
        .onChange(of: hiddenResultSectionsRawValue) { _, _ in
            if !macFilterIsAvailable(macResultFilter) {
                macResultFilter = .all
            }
        }
        // 注意: Album/Artist 的 navigationDestination 由 MacDetailContainer 的
        // NavigationStack 统一注册, 这里不再重复声明 (否则会重复 destination)。
    }

    /// 过滤芯片 + 右端的「调整搜索结果」。输入框只有标题栏上那一个, 页面里不再
    /// 摆一个只能看、不能打字的仿制品。没有搜索词时芯片上的计数没有意义, 只留按钮。
    private var macSearchHeader: some View {
        HStack(spacing: 8) {
            if searchText.isEmpty {
                Spacer(minLength: 0)
            } else {
                macFilterChips
            }
            macResultLayoutButton
        }
        .padding(.horizontal, PMSpace.xxxl)
        .padding(.top, PMSpace.l)
        .padding(.bottom, PMSpace.m)
    }

    private var macFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                macFilterChip(
                    .all,
                    title: "\(String(localized: "search_chip_all")) · \(macTotalResultCount)"
                )
                if macFilterIsAvailable(.songs) {
                    macFilterChip(
                        .songs,
                        title: "\(String(localized: "tab_songs")) · \(macSongResultCount)"
                    )
                }
                if macFilterIsAvailable(.albums) {
                    macFilterChip(
                        .albums,
                        title: "\(String(localized: "tab_albums")) · \(matchingAlbums.count)"
                    )
                }
                if macFilterIsAvailable(.artists) {
                    macFilterChip(
                        .artists,
                        title: "\(String(localized: "tab_artists")) · \(matchingArtists.count)"
                    )
                }
                if macFilterIsAvailable(.lyrics) {
                    macFilterChip(.lyrics, title: String(
                        format: String(localized: "search_lyrics_hits_format"),
                        searchResults.filter { $0.matchKind == .lyrics }.count
                    ))
                }
                if macFilterIsAvailable(.appleMusic) {
                    macFilterChip(
                        .appleMusic,
                        title: "Apple Music · \(visibleAppleMusicSearchResults.count)"
                    )
                }
            }
            .padding(.vertical, 1)
        }
    }

    @ViewBuilder
    private var macSearchContent: some View {
        // 与 iOS 同构: 只给不随击键翻转的几支补淡入, 搜索中占位 ⇄ 结果保持硬切。
        if searchText.isEmpty {
            if library.visibleSongs.isEmpty {
                EmptyStateView(
                    titleKey: "search_empty_library",
                    descriptionKey: "search_empty_library_desc",
                    systemImage: "magnifyingglass"
                )
                .pmAppearFade(.contentAppear)
            } else {
                macRecentSearchView
                    .pmAppearFade(.contentAppear)
            }
        } else if isSearching && renderedQuery != searchText {
            macSearchingPlaceholder
        } else if searchResults.isEmpty
                    && matchingAlbums.isEmpty
                    && matchingArtists.isEmpty
                    && visibleSemanticResults.isEmpty
                    && visibleAppleMusicSearchResults.isEmpty
                    && !semanticSearchFeedback.isVisible {
            if isSearching || renderedQuery != searchText {
                macSearchingPlaceholder
            } else {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .pmAppearFade(.contentAppear)
            }
        } else {
            macSearchResultsView
        }
    }

    private var macRecentSearchView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    macSectionLabel("recent_searches")
                    if recentSearches.isEmpty {
                        Text("search_prompt")
                            .font(.system(size: 12.5))
                            .foregroundStyle(PMColor.textFaint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .pmCard(cornerRadius: 10)
                    } else {
                        HStack(alignment: .top) {
                            MacSearchFlowLayout(spacing: 8, rowSpacing: 8) {
                                ForEach(recentSearches, id: \.self) { query in
                                    macRecentSearchChip(query)
                                }
                            }
                            Spacer(minLength: 16)
                            Button("clear_all", role: .destructive, action: clearRecentSearches)
                                .font(.system(size: 11.5))
                                .buttonStyle(.plain)
                                .foregroundStyle(PMColor.bad)
                        }
                    }
                }

                HStack(spacing: 14) {
                    macSummaryTile(value: "\(library.visibleSongs.count)", label: "tab_songs", icon: "music.note")
                    macSummaryTile(value: "\(library.visibleAlbums.count)", label: "tab_albums", icon: "square.stack")
                    macSummaryTile(value: "\(library.visibleArtists.count)", label: "tab_artists", icon: "music.mic")
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.bottom, 100)
        }
        .background(PMColor.bg)
    }

    @ViewBuilder
    private var macSearchResultsView: some View {
        if macResultFilter == .all {
            macAllSearchResultsView
        } else if macSelectedFilterHasContent {
            macFilteredSearchResultsView
        } else {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PMColor.bg)
        }
    }

    /// 「全部」页。第一排是最佳匹配大卡, 旁边放用户排在最前、且有结果的那一块;
    /// 往下专辑、艺术家、Apple Music 各占一整排封面, 歌曲类的几块按宽度并排成栏。
    /// 排法见 `SearchResultPageLayout`, 「全选」圈的歌也按同一份计划取。
    private var macAllSearchResultsView: some View {
        let model = macAllResultsModel
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 30) {
                macTopRow(model)
                ForEach(model.plan.rows) { row in
                    macResultRow(row, model: model)
                }
                macRecentSearchInlineSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width.rounded()
            } action: { width in
                macResultsWidth = width
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.bottom, 100)
        }
        .background(PMColor.bg)
    }

    /// 最佳匹配: 名字和搜索词完全一样的艺术家、专辑优先, 其次是排第一的歌。
    private enum MacTopMatch {
        case artist(PrimuseKit.Artist)
        case album(PrimuseKit.Album)
        case song(LibrarySearchResult)

        var artistID: String? {
            if case .artist(let artist) = self { return artist.id }
            return nil
        }

        var albumID: String? {
            if case .album(let album) = self { return album.id }
            return nil
        }

        var songID: String? {
            if case .song(let result) = self { return result.song.id }
            return nil
        }
    }

    /// 一次渲染里要反复用到的东西只算一次: matchingArtists 每读一次都要把整库艺术家过一遍。
    private struct MacAllResultsModel {
        let artists: [PrimuseKit.Artist]
        let topMatch: MacTopMatch?
        let plan: SearchResultPageLayout.Plan
        let width: CGFloat
    }

    private var macAllResultsModel: MacAllResultsModel {
        let artists = matchingArtists
        let topMatch = macTopMatch(artists: artists)
        var present = Set<SearchResultSection>()
        var withItems = Set<SearchResultSection>()
        for section in orderedResultSections {
            if macItemCount(section, artists: artists, excluding: nil) > 0 {
                present.insert(section)
            } else if section == .appleMusic
                        || (section == .intelligent && semanticSearchFeedback.isVisible) {
                // Apple Music 没结果时有一张状态卡, 智能补充有进度/失败提示。
                present.insert(section)
            }
            // 放到最佳匹配旁边的那块, 扣掉最佳匹配本身之后还得有东西。
            if macItemCount(section, artists: artists, excluding: topMatch) > 0 {
                withItems.insert(section)
            }
        }
        let plan = SearchResultPageLayout.plan(
            order: orderedResultSections,
            present: present,
            withItems: withItems,
            hasTopMatch: topMatch != nil,
            width: Double(macResultsWidth)
        )
        return MacAllResultsModel(artists: artists, topMatch: topMatch, plan: plan, width: macResultsWidth)
    }

    private func macTopMatch(artists: [PrimuseKit.Artist]) -> MacTopMatch? {
        let query = renderedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        func matchesQuery(_ text: String) -> Bool {
            text.compare(query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
        if let artist = artists.first(where: { matchesQuery($0.name) }) { return .artist(artist) }
        if let album = matchingAlbums.first(where: { matchesQuery($0.title) }) { return .album(album) }
        if let result = searchResults.first { return .song(result) }
        if let album = matchingAlbums.first { return .album(album) }
        if let artist = artists.first { return .artist(artist) }
        return nil
    }

    private func macItemCount(
        _ section: SearchResultSection,
        artists: [PrimuseKit.Artist],
        excluding topMatch: MacTopMatch?
    ) -> Int {
        switch section {
        case .albums:
            return matchingAlbums.filter { $0.id != topMatch?.albumID }.count
        case .artists:
            return artists.filter { $0.id != topMatch?.artistID }.count
        case .metadata, .path, .lyrics, .fuzzy:
            return searchResults.filter {
                $0.matchKind == section.libraryMatchKind && $0.song.id != topMatch?.songID
            }.count
        case .intelligent:
            return visibleSemanticResults.filter { $0.song.id != topMatch?.songID }.count
        case .appleMusic:
            return visibleAppleMusicSearchResults.count
        }
    }

    /// 某一块在「全部」页实际露出来的歌。渲染和「全选」都从这里取, 两边对得上。
    private func macShownSearchResults(
        _ section: SearchResultSection,
        width: CGFloat,
        besideTopMatch: Bool,
        excluding topMatch: MacTopMatch?
    ) -> (shown: [LibrarySearchResult], total: Int, columns: Int) {
        guard let kind = section.libraryMatchKind else { return ([], 0, 1) }
        let matches = searchResults.filter {
            $0.matchKind == kind && $0.song.id != topMatch?.songID
        }
        let columns = SearchResultPageLayout.columnCount(for: Double(width))
        let limit = SearchResultPageLayout.previewCount(
            for: section,
            innerColumns: columns,
            besideTopMatch: besideTopMatch
        )
        return (Array(matches.prefix(limit)), matches.count, columns)
    }

    private func macShownSemanticResults(
        width: CGFloat,
        besideTopMatch: Bool,
        excluding topMatch: MacTopMatch?
    ) -> (shown: [SemanticLibrarySearchResult], total: Int, columns: Int) {
        let results = visibleSemanticResults.filter { $0.song.id != topMatch?.songID }
        let columns = SearchResultPageLayout.columnCount(for: Double(width))
        let limit = SearchResultPageLayout.previewCount(
            for: .intelligent,
            innerColumns: columns,
            besideTopMatch: besideTopMatch
        )
        return (Array(results.prefix(limit)), results.count, columns)
    }

    /// 「全部」页上看得到的本地歌曲, 按屏幕上的先后。
    private var macAllShownSongIDs: [String] {
        let model = macAllResultsModel
        var ids: [String] = []
        func collect(_ section: SearchResultSection, width: CGFloat, besideTopMatch: Bool) {
            let excluded = besideTopMatch ? model.topMatch : nil
            if section == .intelligent {
                ids += macShownSemanticResults(
                    width: width,
                    besideTopMatch: besideTopMatch,
                    excluding: excluded
                ).shown.map(\.song.id)
            } else {
                ids += macShownSearchResults(
                    section,
                    width: width,
                    besideTopMatch: besideTopMatch,
                    excluding: excluded
                ).shown.map(\.song.id)
            }
        }
        if let neighbor = model.plan.heroNeighbor {
            collect(
                neighbor,
                width: CGFloat(SearchResultPageLayout.heroNeighborWidth(totalWidth: Double(model.width))),
                besideTopMatch: true
            )
        }
        for row in model.plan.rows {
            let width = CGFloat(SearchResultPageLayout.blockWidth(
                totalWidth: Double(model.width),
                blocksInRow: row.sections.count
            ))
            for section in row.sections {
                collect(section, width: width, besideTopMatch: false)
            }
        }
        return ids
    }

    @ViewBuilder
    private func macTopRow(_ model: MacAllResultsModel) -> some View {
        if let topMatch = model.topMatch {
            if Double(model.width) >= SearchResultPageLayout.heroMinimumWidth {
                HStack(alignment: .top, spacing: CGFloat(SearchResultPageLayout.columnSpacing)) {
                    macHeroCard(topMatch)
                        .frame(width: CGFloat(SearchResultPageLayout.heroCardWidth))
                    if let neighbor = model.plan.heroNeighbor {
                        macResultBlock(
                            neighbor,
                            width: CGFloat(SearchResultPageLayout.heroNeighborWidth(
                                totalWidth: Double(model.width)
                            )),
                            besideTopMatch: true,
                            model: model
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                macCompactTopMatch(topMatch)
                    .frame(maxWidth: 680, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func macResultRow(_ row: SearchResultPageLayout.Row, model: MacAllResultsModel) -> some View {
        let width = CGFloat(SearchResultPageLayout.blockWidth(
            totalWidth: Double(model.width),
            blocksInRow: row.sections.count
        ))
        if row.sections.count == 1, let section = row.sections.first {
            macResultBlock(section, width: width, besideTopMatch: false, model: model)
        } else {
            HStack(alignment: .top, spacing: CGFloat(SearchResultPageLayout.columnSpacing)) {
                ForEach(row.sections) { section in
                    macResultBlock(section, width: width, besideTopMatch: false, model: model)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder
    private func macResultBlock(
        _ section: SearchResultSection,
        width: CGFloat,
        besideTopMatch: Bool,
        model: MacAllResultsModel
    ) -> some View {
        let excluded = besideTopMatch ? model.topMatch : nil
        switch section {
        case .albums:
            macAlbumShelf(width: width, excluding: excluded)
        case .artists:
            macArtistShelf(model.artists, width: width, excluding: excluded)
        case .appleMusic:
            macAppleMusicShelf(width: width)
        case .metadata, .path, .lyrics, .fuzzy:
            macSongBlock(section, width: width, besideTopMatch: besideTopMatch, excluding: excluded)
        case .intelligent:
            macSemanticBlock(width: width, besideTopMatch: besideTopMatch, excluding: excluded)
        }
    }

    private func macBlockHeader(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        seeAll: MacSearchResultFilter?
    ) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
            }
            macSectionLabel(title)
            Spacer(minLength: 8)
            if let seeAll {
                Button("see_all") { macResultFilter = seeAll }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.brand)
            }
        }
        .frame(height: 16)
    }

    /// 把条目按栏竖着排; 条目不够时空栏也占位, 栏宽和别的行对齐。
    private func macColumns<Item: Identifiable, Content: View>(
        _ items: [Item],
        columns: Int,
        spacing: CGFloat,
        rowSpacing: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let chunks = SearchResultPageLayout.columnMajorChunks(items, columns: columns)
        return HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<max(columns, 1), id: \.self) { index in
                VStack(spacing: rowSpacing) {
                    if chunks.indices.contains(index) {
                        ForEach(chunks[index]) { item in
                            content(item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    // MARK: 最佳匹配

    @ViewBuilder
    private func macHeroCard(_ match: MacTopMatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            macBlockHeader("search_top_match", seeAll: nil)
            switch match {
            case .artist(let artist):
                NavigationLink(value: artist) { macHeroCardBody(match) }
                    .buttonStyle(.plain)
            case .album(let album):
                NavigationLink(value: album) { macHeroCardBody(match) }
                    .buttonStyle(.plain)
            case .song(let result):
                Button {
                    playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
                } label: {
                    macHeroCardBody(match)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    showInLibraryButton(for: result.song)
                }
            }
        }
    }

    private func macHeroCardBody(_ match: MacTopMatch) -> some View {
        let title: String
        let subtitle: String
        let kind: LocalizedStringKey
        switch match {
        case .artist(let artist):
            title = artist.name
            subtitle = "\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))"
            kind = "search_top_match_kind_artist"
        case .album(let album):
            title = album.title
            subtitle = [album.artistName, album.year.map(String.init)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            kind = "search_top_match_kind_album"
        case .song(let result):
            title = result.song.title
            subtitle = library.artistDisplayName(for: result.song) ?? ""
            kind = "search_top_match_kind_song"
        }
        let isSong = match.songID != nil

        return VStack(alignment: .leading, spacing: 16) {
            macHeroArtwork(match)
                .shadow(color: Color.black.opacity(0.28), radius: 12, y: 5)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(kind)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(PMColor.glassBtn, in: Capsule())
                        .overlay { Capsule().strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
                    if !subtitle.isEmpty {
                        Text(verbatim: subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                }
            }
            // 给右下角的圆形按钮让出位置。
            .padding(.trailing, 44)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: isSong ? "play.fill" : "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(PMColor.brand, in: Circle())
                .shadow(color: PMColor.brand.opacity(0.35), radius: 8, y: 3)
                .padding(16)
        }
        .pmCard(cornerRadius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .pmHoverLift(cornerRadius: 14)
    }

    @ViewBuilder
    private func macHeroArtwork(_ match: MacTopMatch) -> some View {
        switch match {
        case .artist(let artist):
            ArtistArtworkView(artist: artist, size: 112, cornerRadius: 56)
        case .album(let album):
            AlbumArtworkView(album: album, size: 112, cornerRadius: 10)
        case .song(let result):
            CachedArtworkView(
                coverRef: result.song.coverArtFileName,
                songID: result.song.id,
                size: 112,
                cornerRadius: 10,
                sourceID: result.song.sourceID,
                filePath: result.song.filePath,
                fileFormat: result.song.fileFormat
            )
        }
    }

    /// 窄窗口下最佳匹配旁边放不下别的块, 退回横向的一条。
    @ViewBuilder
    private func macCompactTopMatch(_ match: MacTopMatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            macBlockHeader("search_top_match", seeAll: nil)
            switch match {
            case .artist(let artist):
                NavigationLink(value: artist) {
                    macTopCard(
                        title: artist.name,
                        subtitle: "\(artist.songCount) \(String(localized: "songs_count"))",
                        systemImage: "music.mic",
                        artist: artist
                    )
                }
                .buttonStyle(.plain)
            case .album(let album):
                NavigationLink(value: album) {
                    macTopCard(
                        title: album.title,
                        subtitle: "\(album.artistName ?? "") · \(String(localized: "tab_albums"))",
                        systemImage: "square.stack",
                        album: album
                    )
                }
                .buttonStyle(.plain)
            case .song(let result):
                Button {
                    playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
                } label: {
                    macTopCard(
                        title: result.song.title,
                        subtitle: library.artistDisplayName(for: result.song) ?? "",
                        systemImage: "music.note",
                        song: result.song
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    showInLibraryButton(for: result.song)
                }
            }
        }
    }

    // MARK: 整排封面

    /// 专辑、艺术家、Apple Music 封面的最小宽度与间距。一排放得下几个就放几个, 不留半排。
    private static let macShelfItemMinimumWidth: CGFloat = 146
    private static let macShelfSpacing: CGFloat = 20

    private func macShelfColumns(for width: CGFloat) -> Int {
        SearchResultPageLayout.shelfItemCount(
            width: Double(width),
            minimumItemWidth: Double(Self.macShelfItemMinimumWidth),
            spacing: Double(Self.macShelfSpacing)
        )
    }

    private func macShelfGrid(columns: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.macShelfSpacing, alignment: .top),
            count: max(columns, 1)
        )
    }

    @ViewBuilder
    private func macAlbumShelf(width: CGFloat, excluding topMatch: MacTopMatch?) -> some View {
        let albums = matchingAlbums.filter { $0.id != topMatch?.albumID }
        let columns = macShelfColumns(for: width)
        let shown = Array(albums.prefix(columns))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                macBlockHeader("tab_albums", seeAll: albums.count > shown.count ? .albums : nil)
                LazyVGrid(columns: macShelfGrid(columns: columns), alignment: .leading, spacing: 22) {
                    ForEach(shown) { album in
                        macAlbumCard(album)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func macArtistShelf(
        _ artists: [PrimuseKit.Artist],
        width: CGFloat,
        excluding topMatch: MacTopMatch?
    ) -> some View {
        let candidates = artists.filter { $0.id != topMatch?.artistID }
        let columns = macShelfColumns(for: width)
        let shown = Array(candidates.prefix(columns))
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                macBlockHeader("tab_artists", seeAll: candidates.count > shown.count ? .artists : nil)
                LazyVGrid(columns: macShelfGrid(columns: columns), alignment: .leading, spacing: 14) {
                    ForEach(shown) { artist in
                        macArtistCard(artist)
                    }
                }
            }
        }
    }

    private func macAppleMusicShelf(width: CGFloat) -> some View {
        let songs = visibleAppleMusicSearchResults
        let columns = macShelfColumns(for: width)
        let shown = Array(songs.prefix(columns))
        return VStack(alignment: .leading, spacing: 12) {
            macBlockHeader(
                "search_apple_music_catalog_section",
                systemImage: "applelogo",
                seeAll: songs.count > shown.count ? .appleMusic : nil
            )
            if shown.isEmpty {
                // 未授权、搜索中、出错或真没结果时, 这张状态卡说明原因。
                HStack(spacing: 10) {
                    macAppleMusicBadge(size: 20)
                    Text(appleMusicStatusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                    Spacer()
                }
                .padding(14)
                .pmCard(cornerRadius: 10)
                .frame(maxWidth: 680, alignment: .leading)
            } else {
                LazyVGrid(columns: macShelfGrid(columns: columns), alignment: .leading, spacing: 22) {
                    ForEach(shown, id: \.id) { song in
                        macAppleMusicCard(song)
                    }
                }
            }
            if let error = appleMusic.lastPlaybackError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .pmRowBackground(cornerRadius: 6)
            }
        }
    }

    private func macAppleMusicBadge(size: CGFloat) -> some View {
        Image(systemName: "applelogo")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.98, green: 0.14, blue: 0.23), in: .rect(cornerRadius: size * 0.22))
    }

    private func macAppleMusicCard(_ song: MusicKit.Song) -> some View {
        Button {
            Task { await appleMusic.play(song) }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: song.artwork?.url(width: 300, height: 300)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                                    .pmFadeTransition(motion: .contentAppear)
                            } else {
                                RoundedRectangle(cornerRadius: 10).fill(PMColor.rowHover)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        macAppleMusicBadge(size: 18)
                            .padding(6)
                    }
                Text(song.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pmHoverLift()
    }

    // MARK: 歌曲类的几块

    @ViewBuilder
    private func macSongBlock(
        _ section: SearchResultSection,
        width: CGFloat,
        besideTopMatch: Bool,
        excluding topMatch: MacTopMatch?
    ) -> some View {
        let result = macShownSearchResults(
            section,
            width: width,
            besideTopMatch: besideTopMatch,
            excluding: topMatch
        )
        if !result.shown.isEmpty {
            let isLyrics = section == .lyrics
            VStack(alignment: .leading, spacing: 10) {
                macBlockHeader(
                    section.title,
                    seeAll: result.total > result.shown.count ? (isLyrics ? .lyrics : .songs) : nil
                )
                macColumns(
                    result.shown,
                    columns: result.columns,
                    spacing: isLyrics ? 12 : 16,
                    rowSpacing: isLyrics ? 12 : 4
                ) { item in
                    macSongBlockItem(item)
                }
            }
        }
    }

    @ViewBuilder
    private func macSemanticBlock(
        width: CGFloat,
        besideTopMatch: Bool,
        excluding topMatch: MacTopMatch?
    ) -> some View {
        let result = macShownSemanticResults(
            width: width,
            besideTopMatch: besideTopMatch,
            excluding: topMatch
        )
        if semanticSearchFeedback.isVisible || !result.shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                macBlockHeader(
                    "search_ai_section",
                    systemImage: "sparkles",
                    seeAll: result.total > result.shown.count ? .songs : nil
                )
                semanticFeedbackRow
                    .padding(.horizontal, 10)
                macColumns(result.shown, columns: result.columns, spacing: 16, rowSpacing: 4) { item in
                    macSemanticResultRow(item)
                        .songSelectable(
                            songID: item.song.id,
                            selection: selection,
                            orderedIDs: { selectableSongIDs },
                            defaultAction: { playSong(item.song) }
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func macSongBlockItem(_ result: LibrarySearchResult) -> some View {
        if result.matchKind == .lyrics, let snippet = result.lyricSnippet {
            macLyricsResultCard(result: result, snippet: snippet)
                .songSelectable(
                    songID: result.song.id,
                    selection: selection,
                    orderedIDs: { selectableSongIDs },
                    defaultAction: {
                        playSong(result.song, lyricsHint: snippet, matchKind: result.matchKind)
                    }
                )
        } else {
            macSongResultRow(result)
                .songSelectable(
                    songID: result.song.id,
                    selection: selection,
                    orderedIDs: { selectableSongIDs },
                    defaultAction: {
                        playSong(result.song, matchKind: result.matchKind)
                    }
                )
        }
    }

    /// 一组歌曲结果。「全部」页每组只露几条, 「歌曲」筛选下全部列出。
    @ViewBuilder
    private func macSongSection(_ section: SearchResultSection, showsAllResults: Bool) -> some View {
        switch section {
        case .metadata:
            macSongBucket(kind: .metadata, title: "search_section_metadata", showsAllResults: showsAllResults)
        case .path:
            macSongBucket(kind: .path, title: "search_section_path", showsAllResults: showsAllResults)
        case .lyrics:
            macSongBucket(kind: .lyrics, title: "search_section_lyrics", showsAllResults: showsAllResults)
        case .fuzzy:
            macSongBucket(kind: .fuzzy, title: "search_section_fuzzy", showsAllResults: showsAllResults)
        case .intelligent:
            macSemanticSection(limit: showsAllResults ? 40 : 6)
        case .albums, .artists, .appleMusic:
            EmptyView()
        }
    }

    private var macFilteredSearchResultsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                switch macResultFilter {
                case .songs:
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(orderedResultSections) { section in
                            macSongSection(section, showsAllResults: true)
                        }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                case .albums:
                    macAlbumsSection(showsAllResults: true)
                case .artists:
                    macArtistsSection()
                case .lyrics:
                    LazyVStack(alignment: .leading, spacing: 14) {
                        macSongBucket(
                            kind: .lyrics,
                            title: "search_section_lyrics",
                            showsAllResults: true
                        )
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                case .appleMusic:
                    macAppleMusicSection(showsAllResults: true)
                        .frame(maxWidth: 900, alignment: .leading)
                case .all:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.bottom, 100)
        }
        .background(PMColor.bg)
    }

    private var macSearchingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("search_running")
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PMColor.bg)
    }

    @ViewBuilder
    private func macAlbumsSection(showsAllResults: Bool = false) -> some View {
        if !matchingAlbums.isEmpty {
            let albums = showsAllResults
                ? matchingAlbums
                : Array(matchingAlbums.prefix(6))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("tab_albums").font(.title3.weight(.bold))
                    Spacer()
                    if !showsAllResults && matchingAlbums.count > albums.count {
                        Button("see_all") { macResultFilter = .albums }
                            .buttonStyle(.plain)
                            .foregroundStyle(PMColor.brand)
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 146, maximum: 210), spacing: 20)], alignment: .leading, spacing: 22) {
                    ForEach(albums) { album in
                        macAlbumCard(album)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func macAppleMusicSection(showsAllResults: Bool = false) -> some View {
        let results = showsAllResults
            ? visibleAppleMusicSearchResults
            : Array(visibleAppleMusicSearchResults.prefix(5))
        VStack(alignment: .leading, spacing: 10) {
            macSectionLabel("search_apple_music_catalog_section")
            HStack(spacing: 10) {
                Image(systemName: "applelogo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Color(red: 0.98, green: 0.14, blue: 0.23), in: .rect(cornerRadius: 4))
                Text(appleMusicStatusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                Spacer()
            }
            .padding(14)
            .pmCard(cornerRadius: 10)

            if let error = appleMusic.lastPlaybackError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .pmRowBackground(cornerRadius: 6)
            }

            ForEach(results, id: \.id) { song in
                Button {
                    Task { await appleMusic.play(song) }
                } label: {
                    HStack(spacing: 10) {
                        AsyncImage(url: song.artwork?.url(width: 64, height: 64)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                                    .pmFadeTransition(motion: .contentAppear)
                            } else {
                                RoundedRectangle(cornerRadius: 5).fill(PMColor.rowHover)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(PMColor.text)
                                .lineLimit(1)
                            Text(song.artistName)
                                .font(.system(size: 10.5))
                                .foregroundStyle(PMColor.textFaint)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .pmRowBackground(cornerRadius: 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var macRecentSearchInlineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            macSectionLabel("recent_searches")
            MacSearchFlowLayout(spacing: 8, rowSpacing: 8) {
                ForEach(recentSearches.prefix(8), id: \.self) { query in
                    macRecentSearchChip(query)
                }
            }
        }
    }

    private func macRecentSearchChip(_ query: String) -> some View {
        HStack(spacing: 6) {
            Button {
                addRecentSearch(query)
                searchText = query
            } label: {
                Text(verbatim: query)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Button {
                removeRecentSearch(query)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 12, height: 12)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("delete"))
        }
        .font(.system(size: 11))
        .foregroundStyle(PMColor.textMuted)
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 24)
        .background(PMColor.glassBtn, in: Capsule())
        .overlay { Capsule().strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
    }

    @ViewBuilder
    private func macSongBucket(
        kind: LibrarySearchMatchKind,
        title: LocalizedStringKey,
        showsAllResults: Bool = false
    ) -> some View {
        let matches = searchResults.filter { $0.matchKind == kind }
        let bucket = showsAllResults
            ? matches
            : Array(matches.prefix(kind == .lyrics ? 3 : 6))
        if !bucket.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                macSectionLabel(title)
                ForEach(bucket) { result in
                    macSongBlockItem(result)
                }
            }
        }
    }

    @ViewBuilder
    private func macSemanticSection(limit: Int = 6) -> some View {
        let results = Array(visibleSemanticResults.prefix(limit))
        if semanticSearchFeedback.isVisible || !results.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    macSectionLabel("search_ai_section")
                }
                semanticFeedbackRow
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                ForEach(results) { result in
                    macSemanticResultRow(result)
                        .songSelectable(
                            songID: result.song.id,
                            selection: selection,
                            orderedIDs: { selectableSongIDs },
                            defaultAction: { playSong(result.song) }
                        )
                }
            }
        }
    }

    private func macArtistsSection(showsAllResults: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("tab_artists").font(.title3.weight(.bold))
                Spacer()
                if !showsAllResults && matchingArtists.count > 6 {
                    Button("see_all") { macResultFilter = .artists }
                        .buttonStyle(.plain)
                        .foregroundStyle(PMColor.brand)
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 146, maximum: 210), spacing: 20)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(showsAllResults ? matchingArtists : Array(matchingArtists.prefix(6))) { artist in
                    macArtistCard(artist)
                }
            }
        }
    }

    private func macAlbumCard(_ album: PrimuseKit.Album) -> some View {
        NavigationLink(value: album) {
            VStack(alignment: .leading, spacing: 7) {
                AlbumArtworkView(album: album, cornerRadius: 10)
                    .aspectRatio(1, contentMode: .fit)
                Text(album.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(album.artistName ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                Text(verbatim: [
                    album.year.map(String.init),
                    "\(album.songCount) \(String(localized: "songs_count"))"
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .pmHoverLift()
    }

    private func macArtistCard(_ artist: PrimuseKit.Artist) -> some View {
        NavigationLink(value: artist) {
            VStack(alignment: .leading, spacing: 7) {
                ArtistArtworkView(
                    artist: artist,
                    cornerRadius: 999
                )
                .aspectRatio(1, contentMode: .fit)
                Text(artist.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text("\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        // hover 记在修饰符里, 卡片 body 不会重算 —— matchingArtists
        // 是没有缓存的整库计算属性, 划过时绝不能触发重新求值。
        .pmHoverLift()
    }

    private func macSemanticResultRow(_ result: SemanticLibrarySearchResult) -> some View {
        Button {
            playSong(result.song)
        } label: {
            HStack(spacing: 12) {
                CachedArtworkView(
                    coverRef: result.song.coverArtFileName,
                    songID: result.song.id,
                    size: 32,
                    cornerRadius: 5,
                    sourceID: result.song.sourceID,
                    filePath: result.song.filePath,
                    fileFormat: result.song.fileFormat
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.song.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: String(
                        format: String(localized: "search_ai_reason_format"),
                        result.relatedConcept
                    ))
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                    searchResultPath(for: result.song)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .pmRowBackground(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            showInLibraryButton(for: result.song)
        }
    }

    private func macTopCard(title: String,
                            subtitle: String,
                            systemImage: String,
                            album: PrimuseKit.Album? = nil,
                            song: PrimuseKit.Song? = nil,
                            artist: PrimuseKit.Artist? = nil) -> some View {
        HStack(spacing: 16) {
            Group {
                if let artist {
                    ArtistArtworkView(artist: artist, size: 80, cornerRadius: 40)
                } else if let song {
                    CachedArtworkView(coverRef: song.coverArtFileName,
                                      songID: song.id,
                                      size: 80,
                                      cornerRadius: 10,
                                      sourceID: song.sourceID,
                                      filePath: song.filePath,
                                      fileFormat: song.fileFormat)
                } else if let album {
                    AlbumArtworkView(album: album, size: 80, cornerRadius: 10)
                } else {
                    Circle()
                        .fill(PMColor.rowHover)
                        .frame(width: 80, height: 80)
                        .overlay { Image(systemName: systemImage).foregroundStyle(PMColor.textFaint) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                if let song {
                    searchResultPath(for: song)
                }
            }
            Spacer()
            Image(systemName: album == nil && artist == nil ? "play.fill" : "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(PMColor.brand, in: Circle())
        }
        .padding(16)
        .pmCard(cornerRadius: 12)
    }

    private func macSongResultRow(_ result: LibrarySearchResult) -> some View {
        Button {
            playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
        } label: {
            HStack(spacing: 12) {
                CachedArtworkView(coverRef: result.song.coverArtFileName,
                                  songID: result.song.id,
                                  size: 32,
                                  cornerRadius: 5,
                                  sourceID: result.song.sourceID,
                                  filePath: result.song.filePath,
                                  fileFormat: result.song.fileFormat)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.song.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(library.artistDisplayName(for: result.song) ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                    searchResultPath(for: result.song)
                }
                Spacer()
                Text(formatSearchTime(result.song.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .pmRowBackground(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .contextMenu {
            showInLibraryButton(for: result.song)
            Divider()
            Button {
                selection.activate(seed: result.song.id)
            } label: {
                Label("batch_select", systemImage: "checkmark.circle")
            }
        }
    }

    /// 歌词命中做成引文卡: 摘句在前, 歌名在后, 一眼能看出是哪一句对上了。
    private func macLyricsResultCard(result: LibrarySearchResult, snippet: String) -> some View {
        Button {
            playSong(result.song, lyricsHint: snippet, matchKind: .lyrics)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(PMColor.brand)
                    Spacer(minLength: 8)
                    if let timestamp = result.lyricTimestamp {
                        Text(verbatim: String(
                            format: String(localized: "search_match_time_format"),
                            formatSearchTime(timestamp)
                        ))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PMColor.brand)
                    }
                }
                Text(snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    CachedArtworkView(
                        coverRef: result.song.coverArtFileName,
                        songID: result.song.id,
                        size: 26,
                        cornerRadius: 4,
                        sourceID: result.song.sourceID,
                        filePath: result.song.filePath,
                        fileFormat: result.song.fileFormat
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.song.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                            .lineLimit(1)
                        Text(library.artistDisplayName(for: result.song) ?? "")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(1)
                        searchResultPath(for: result.song)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PMColor.rowHover, in: .rect(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(Text("search_jump_to_lyrics_context"))
        .contextMenu {
            showInLibraryButton(for: result.song)
            Divider()
            Button {
                selection.activate(seed: result.song.id)
            } label: {
                Label("batch_select", systemImage: "checkmark.circle")
            }
        }
    }

    private func macSummaryTile(value: String, label: LocalizedStringKey, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.brand)
            Text(verbatim: value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(PMColor.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .pmCard(cornerRadius: 12)
    }

    private func macSectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private func macSectionLabelText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    /// 筛选按钮对应的那几块还开着没有。关掉的块不再单独给一个筛选按钮。
    private func macFilterIsAvailable(_ filter: MacSearchResultFilter) -> Bool {
        let layout = resultLayout
        switch filter {
        case .all:
            return true
        case .songs:
            let songSections: [SearchResultSection] = [.metadata, .path, .lyrics, .fuzzy, .intelligent]
            return songSections.contains(where: layout.shows)
        case .albums:
            return layout.shows(.albums)
        case .artists:
            return layout.shows(.artists)
        case .lyrics:
            return layout.shows(.lyrics)
        case .appleMusic:
            return appleMusicSearchEnabled
        }
    }

    private var macResultLayoutButton: some View {
        Button {
            showsResultLayoutEditor.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(showsResultLayoutEditor ? .white : PMColor.textMuted)
                .frame(width: 32, height: 26)
                .background(
                    showsResultLayoutEditor
                        ? AnyShapeStyle(PMColor.brand)
                        : AnyShapeStyle(PMColor.glassBtn),
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(
                        showsResultLayoutEditor ? .clear : PMColor.cardBorder,
                        lineWidth: 0.5
                    )
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("search_layout_title"))
        .accessibilityLabel(Text("search_layout_title"))
        .accessibilityIdentifier("search.layout.button")
        .popover(isPresented: $showsResultLayoutEditor, arrowEdge: .bottom) {
            resultLayoutEditor
        }
    }

    private func chipText(_ title: String, active: Bool) -> some View {
        Text(verbatim: title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? .white : PMColor.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                active ? AnyShapeStyle(PMColor.brand) : AnyShapeStyle(PMColor.glassBtn),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(active ? .clear : PMColor.cardBorder, lineWidth: 0.5)
            }
            // 只盯选中态: 芯片文案里嵌着实时计数, 结果流入时不能跟着动。
            .pmAnimation(.hover, value: active)
    }

    private func macFilterChip(
        _ filter: MacSearchResultFilter,
        title: String
    ) -> some View {
        Button {
            macResultFilter = filter
        } label: {
            chipText(title, active: macResultFilter == filter)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(macResultFilter == filter ? .isSelected : [])
    }

    private var macSelectedFilterHasContent: Bool {
        switch macResultFilter {
        case .all:
            return true
        case .songs:
            return !searchResults.isEmpty
                || !visibleSemanticResults.isEmpty
                || semanticSearchFeedback.isVisible
        case .albums:
            return !matchingAlbums.isEmpty
        case .artists:
            return !matchingArtists.isEmpty
        case .lyrics:
            return searchResults.contains { $0.matchKind == .lyrics }
        case .appleMusic:
            return appleMusicSearchEnabled
        }
    }

    private var macSongResultCount: Int {
        searchResults.count + visibleSemanticResults.count
    }

    private var macTotalResultCount: Int {
        macSongResultCount
            + matchingAlbums.count
            + matchingArtists.count
            + visibleAppleMusicSearchResults.count
    }

    private var appleMusicStatusText: String {
        switch appleMusic.authState {
        case .notDetermined:
            return AppleMusicAuthorizationGuidance.searchNotDeterminedNotice
        case .denied, .restricted:
            return String(localized: "apple_music_notice_denied")
        case .authorized:
            guard appleMusicSearchEnabled else {
                return String(localized: "search_apple_music_catalog_disabled")
            }
            if appleMusic.isSearching {
                return String(localized: "search_apple_music_loading")
            }
            if let error = appleMusic.lastSearchError {
                return error
            }
            return String(
                format: String(localized: "search_apple_music_synced_results_format"),
                visibleAppleMusicSearchResults.count
            )
        }
    }

    #endif

    private var matchingArtists: [PrimuseKit.Artist] {
        let query = renderedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope == nil, !query.isEmpty, resultLayout.shows(.artists) else { return [] }
        var artists = library.visibleArtists.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var seen = Set(artists.map(\.id))
        for result in searchResults {
            for id in library.artistIDs(for: result.song) {
                guard seen.insert(id).inserted,
                      let artist = library.visibleArtist(id: id) else { continue }
                artists.append(artist)
            }
        }
        return artists
    }

    @ViewBuilder
    private var semanticFeedbackRow: some View {
        // 状态由异步搜索裸赋值推动: 各态自己淡进来, 不做交叉淡入。
        switch semanticSearchFeedback {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("search_ai_loading")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .pmAppearFade(.control)
        case .success(let provider, let resultCount, let fallbackDepth):
            Label(
                String(
                    format: String(localized: fallbackDepth > 0
                                   ? "search_ai_success_fallback_format"
                                   : "search_ai_success_format"),
                    provider.isEmpty ? String(localized: "ai_provider_default_name") : provider,
                    resultCount
                ),
                systemImage: fallbackDepth > 0 ? "arrow.trianglehead.branch" : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
            .pmAppearFade(.control)
        case .noMatches(let provider, let fallbackDepth):
            Label(
                String(
                    format: String(localized: fallbackDepth > 0
                                   ? "search_ai_no_matches_fallback_format"
                                   : "search_ai_no_matches_format"),
                    provider.isEmpty ? String(localized: "ai_provider_default_name") : provider
                ),
                systemImage: "sparkles"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .pmAppearFade(.control)
        case .failed:
            Label("search_ai_failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .pmAppearFade(.control)
        }
    }

    private func formatSearchTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var recentSearchView: some View {
        List {
            if !recentSearches.isEmpty {
                Section {
                    ForEach(recentSearches, id: \.self) { query in
                        Button {
                            addRecentSearch(query)
                            searchText = query
                        } label: {
                            Label(query, systemImage: "clock")
                        }
                    }
                    .onDelete(perform: deleteRecentSearches)
                } header: {
                    HStack {
                        Text("recent_searches")
                        Spacer()
                        Button("clear_all", role: .destructive, action: clearRecentSearches)
                            .font(.caption)
                    }
                }
            }

            Section {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                    Text("\(scope?.songIDs.count ?? library.visibleSongs.count) \(String(localized: "tab_songs"))")
                    if scope == nil {
                        Spacer()
                        Text("\(library.visibleAlbums.count) \(String(localized: "tab_albums"))")
                        Text("·")
                        Text("\(library.visibleArtists.count) \(String(localized: "tab_artists"))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(scope?.title ?? String(localized: "library"))
            }
        }
    }

    private var searchResultsView: some View {
        List {
            // 旧结果仍在屏上, 但新一轮搜索还在跑 — 顶部加一条细 progress,
            // 让用户知道结果会刷新, 而不是误以为屏幕卡住。
            if isSearching && renderedQuery != searchText {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("search_running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(orderedResultSections) { section in
                resultSection(section)
            }
        }
        .listStyle(.plain)
        // 结果表够宽时, 歌曲行把专辑与时长排成对齐列。
        .songRowColumnsContainer()
    }

    /// 结果表里的一块。先后与显隐由右上角的「调整搜索结果」决定。
    @ViewBuilder
    private func resultSection(_ section: SearchResultSection) -> some View {
        switch section {
        case .albums:
            albumShelfSection
        case .artists:
            artistsSection
        case .metadata:
            // Songs grouped by match kind — 用户能一眼区分"标题/艺术家命中"、
            // "路径命中"、"歌词命中"和"拼音/模糊命中"。
            // 每组限 40 条 (worker 整体也限 120), 防止单组撑满屏。
            songSection(kind: .metadata, titleKey: "search_section_metadata")
        case .path:
            songSection(kind: .path, titleKey: "search_section_path")
        case .lyrics:
            songSection(kind: .lyrics, titleKey: "search_section_lyrics")
        case .fuzzy:
            songSection(kind: .fuzzy, titleKey: "search_section_fuzzy")
        case .intelligent:
            semanticSongSection
        case .appleMusic:
            // Apple Music 启用时即使没结果也显示 section 标题, 让用户一眼看到
            // "为什么没有 Apple Music 推荐" (未授权 / 搜索失败 / 真没结果)。
            appleMusicSection
        }
    }

    @ViewBuilder
    private var albumShelfSection: some View {
        if !matchingAlbums.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    // 卡宽决定整条专辑架的高度(封面是正方形), 紧凑高度下收一档,
                    // 免得这一条就把结果区吃掉大半。
                    let albumCardWidth = heightClass.value(142, compact: 104)
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(matchingAlbums.prefix(8)) { album in
                            NavigationLink(value: album) {
                                AlbumCardView(album: album).frame(width: albumCardWidth)
                            }
                            .buttonStyle(.plain)
                            .mediaZoomSource(.album, id: album.id)
                        }
                    }
                    .padding(.vertical, heightClass.value(8, compact: 4))
                }
                .listRowSeparator(.hidden)
            } header: {
                HStack {
                    Text("tab_albums")
                    Spacer()
                    #if os(iOS)
                    NavigationLink("see_all", value: SearchCatalogDestination.albums)
                    .textCase(nil)
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private var artistsSection: some View {
        // matchingArtists 每次读都要把全部艺术家过一遍, 这一块只算一次。
        let artists = matchingArtists
        if !artists.isEmpty {
            Section("tab_artists") {
                ForEach(artists.prefix(3)) { artist in
                    NavigationLink(value: artist) {
                        HStack(spacing: 12) {
                            ArtistArtworkView(artist: artist, size: 44, cornerRadius: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).font(.subheadline).lineLimit(1)
                                Text("\(artist.songCount) \(String(localized: "songs_count"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .mediaZoomSource(.artist, id: artist.id)
                }
                if artists.count > 3 {
                    #if os(iOS)
                    NavigationLink("see_all", value: SearchCatalogDestination.artists)
                    #endif
                }
            }
        }
    }

    @ViewBuilder
    private var appleMusicSection: some View {
        Section {
            switch appleMusic.authState {
            case .notDetermined:
                Label(AppleMusicAuthorizationGuidance.searchNotDeterminedNotice, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            case .denied, .restricted:
                Label("apple_music_notice_denied", systemImage: "lock.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .authorized:
                if appleMusic.isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("search_apple_music_loading").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let err = appleMusic.lastSearchError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                } else if visibleAppleMusicSearchResults.isEmpty {
                    if appleMusic.lastSearchHitCount == 0 {
                        Label("apple_music_notice_no_results", systemImage: "magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // hitCount == -1 表示还没搜过, 不显示状态 (避免空 section)
                } else {
                    ForEach(visibleAppleMusicSearchResults, id: \.id) { song in
                        appleMusicRow(song)
                    }
                }
                if let err = appleMusic.lastPlaybackError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            HStack {
                Image(systemName: "applelogo")
                Text("search_section_apple_music")
            }
        }
    }

    /// 一组按 matchKind 过滤的歌曲 Section。空组直接 noop, 不显示标题。
    @ViewBuilder
    private func songSection(kind: LibrarySearchMatchKind, titleKey: LocalizedStringKey) -> some View {
        let matches = searchResults.filter { $0.matchKind == kind }
        let bucket = matches.prefix(scope == nil ? 40 : matches.count)
        if !bucket.isEmpty {
            Section {
                ForEach(Array(bucket)) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        SongRowView(
                            song: result.song,
                            isPlaying: player.currentSong?.id == result.song.id,
                            selection: selection,
                            queueSwipeActionsEnabled: false,
                            context: SongRowView.context(for: result.song, sourcesStore: sourcesStore, backfill: backfill)
                        )
                        // Keep playback taps on the view that owns the context menu.
                        // An ancestor gesture otherwise becomes the List cell's
                        // competing hit target and prevents the row's long press.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
                        }
                        searchResultPath(for: result.song, leadingPadding: 54)
                        if result.matchKind == .lyrics, let snippet = result.lyricSnippet {
                            // 歌词命中: 把命中的句子(含上下文)展开, 让用户一眼看到为什么命中。
                            VStack(alignment: .leading, spacing: 3) {
                                if let timestamp = result.lyricTimestamp {
                                    Text(verbatim: String(
                                        format: String(localized: "search_match_time_format"),
                                        formatSearchTime(timestamp)
                                    ))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tint)
                                }
                                Text(snippet)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.leading, 54)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playSong(result.song, lyricsHint: snippet, matchKind: result.matchKind)
                            }
                        }
                    }
                    .songSelectable(
                        songID: result.song.id,
                        selection: selection,
                        orderedIDs: { selectableSongIDs }
                    )
                    .searchResultSwipeActions(
                        queueActionsEnabled: result.song.isPlayable
                            && !selection.isActive,
                        onInsertNext: { player.insertNextInQueue([result.song]) },
                        onAppendToQueue: { player.appendToQueue([result.song]) }
                    ) {
                        showInLibraryButton(for: result.song)
                    }
                    .accessibilityAction(named: Text("show_in_library")) {
                        onShowInLibrary(result.song)
                    }
                }
            } header: {
                Text(titleKey)
            }
        }
    }

    @ViewBuilder
    private var semanticSongSection: some View {
        let results = Array(visibleSemanticResults.prefix(40))
        if semanticSearchFeedback.isVisible || !results.isEmpty {
            Section {
                semanticFeedbackRow
                ForEach(results) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        SongRowView(
                            song: result.song,
                            isPlaying: player.currentSong?.id == result.song.id,
                            selection: selection,
                            queueSwipeActionsEnabled: false,
                            context: SongRowView.context(
                                for: result.song,
                                sourcesStore: sourcesStore,
                                backfill: backfill
                            )
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { playSong(result.song) }

                        Text(verbatim: String(
                            format: String(localized: "search_ai_reason_format"),
                            result.relatedConcept
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 54)
                        searchResultPath(for: result.song, leadingPadding: 54)
                    }
                    .songSelectable(
                        songID: result.song.id,
                        selection: selection,
                        orderedIDs: { selectableSongIDs }
                    )
                    .searchResultSwipeActions(
                        queueActionsEnabled: result.song.isPlayable
                            && !selection.isActive,
                        onInsertNext: { player.insertNextInQueue([result.song]) },
                        onAppendToQueue: { player.appendToQueue([result.song]) }
                    ) {
                        showInLibraryButton(for: result.song)
                    }
                    .accessibilityAction(named: Text("show_in_library")) {
                        onShowInLibrary(result.song)
                    }
                }
            } header: {
                Label("search_ai_section", systemImage: "sparkles")
            }
        }
    }

    private func appleMusicRow(_ song: MusicKit.Song) -> some View {
        Button {
            Task { await appleMusic.play(song) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: song.artwork?.url(width: 88, height: 88)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                            .pmFadeTransition(motion: .contentAppear)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline).lineLimit(1)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "applelogo").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func searchResultPath(
        for song: PrimuseKit.Song,
        leadingPadding: CGFloat = 0
    ) -> some View {
        if let path = SongPathPresentationPolicy.displayPath(
            filePath: song.filePath,
            sourceID: song.sourceID,
            sourceType: sourcesStore.source(id: song.sourceID)?.type
        ) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(verbatim: path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.leading, leadingPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: String(
                format: String(localized: "search_result_path_accessibility_format"),
                path
            )))
        }
    }

    /// 视图重新出现时补跑当前 query。两种丢状态场景:(1) iPhone 切 tab 时
    /// onDisappear 取消了搜索 task, isSearching 被 defer 置回 false, 但 renderedQuery
    /// 仍是旧值;(2) iPad detail 重建导致 @State(searchResults/renderedQuery) 清零,
    /// 而 searchText 由 ContentView 持有保留非空。两种情况都没有任何 task 在跑,
    /// body 会永久落在 searchingPlaceholder 分支。这里检测到"有词、结果对不上、
    /// 且当前没在搜"时重新触发, 让结果恢复。
    private func resumeSearchIfNeeded() {
        guard !searchText.isEmpty, !isSearching, renderedQuery != searchText else { return }
        performSearch(query: searchText)
        performAppleMusicSearch(query: searchText)
    }

    private func performAppleMusicSearch(query: String) {
        guard appleMusicSearchEnabled else {
            appleMusic.clearCatalogSearchResults()
            return
        }
        appleMusic.search(query: query)
    }

    private func performSearch(query: String) {
        workCoordinator.cancelSearch()
        workCoordinator.generation += 1
        guard !query.isEmpty else {
            searchResults = []
            matchingAlbums = []
            semanticResults = []
            isSearching = false
            isIntelligenceSearching = false
            semanticSearchFeedback = .idle
            renderedQuery = ""
            intelligenceRenderedQuery = ""
            return
        }

        let scopedSearch = scope != nil
        let layout = resultLayout
        let matchKinds = layout.matchKinds
        let songsSnapshot = scope?.songs(in: library.visibleSongs) ?? library.visibleSongs
        let albumsSnapshot = scopedSearch || !layout.shows(.albums) ? [] : library.visibleAlbums
        let cacheSnapshot = workCoordinator.lyricsCache
        let metadataRevisionKey = "\(library.visibleSongCollectionRevision):\(library.searchRevision)"

        let myGen = workCoordinator.generation
        isSearching = true

        performSemanticSearch(
            query: query,
            songsSnapshot: songsSnapshot,
            metadataRevisionKey: metadataRevisionKey,
            generation: myGen
        )

        workCoordinator.searchTask = Task {
            // 不管成功 / 取消 / 出错都要把 isSearching 关回去, 否则 UI 卡在
            // loading 状态。用 generation 防止旧 task 的 defer 覆盖新一轮
            // performSearch 设的状态 — 新 task 已 bump generation 时, 旧 task
            // defer 看到 gen 不匹配就不动 state。
            defer {
                if myGen == workCoordinator.generation {
                    isSearching = false
                }
            }
            // Debounce 200ms
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            // The persistent index limits global matches before membership filtering.
            // Search the scope directly so matches outside it cannot crowd out its songs.
            let indexed: LibraryIndexedSearchOutput?
            if scopedSearch {
                indexed = nil
            } else {
                indexed = await LibrarySearchIndex.shared.search(
                    query: query,
                    songs: songsSnapshot,
                    albums: albumsSnapshot,
                    metadataRevisionKey: metadataRevisionKey,
                    matchKinds: matchKinds
                )
            }
            guard !Task.isCancelled else { return }

            let output: LibrarySearchOutput
            if var indexed {
                // The first persistent lyrics build is intentionally gradual.
                // Until it has examined the current song set, merge only the
                // old literal-lyrics path (no metadata/pinyin ICU scan) so the
                // feature remains complete during migration.
                if !indexed.lyricsIndexComplete, matchKinds.contains(.lyrics) {
                    let fallbackWorker = Task.detached(priority: .utility) {
                        LibrarySearchWorker.compute(
                            query: query,
                            songs: songsSnapshot,
                            albums: [],
                            cache: cacheSnapshot,
                            includeMetadata: false,
                            includeLyrics: true,
                            albumLimit: 0
                        )
                    }
                    let fallback = await withTaskCancellationHandler {
                        await fallbackWorker.value
                    } onCancel: {
                        fallbackWorker.cancel()
                    }
                    indexed.output = mergeIndexedSearch(
                        indexed.output,
                        literalFallback: fallback
                    )
                }
                output = indexed.output
            } else {
                // FTS5/trigram is unavailable only on an unsupported SQLite
                // runtime. Keep the corrected cancellable worker as a safe
                // compatibility fallback.
                let fallbackWorker = Task.detached(priority: .userInitiated) {
                    LibrarySearchWorker.compute(
                        query: query,
                        songs: songsSnapshot,
                        albums: albumsSnapshot,
                        cache: cacheSnapshot,
                        matchKinds: matchKinds,
                        songLimit: scopedSearch ? songsSnapshot.count : 120
                    )
                }
                output = await withTaskCancellationHandler {
                    await fallbackWorker.value
                } onCancel: {
                    fallbackWorker.cancel()
                }
            }
            guard !Task.isCancelled else { return }
            let catalogWorker = Task.detached(priority: .userInitiated) {
                SearchCatalogPolicy.albums(
                    query: query,
                    visibleAlbums: albumsSnapshot,
                    relatedAlbums: output.albumResults
                )
            }
            let albums = await withTaskCancellationHandler {
                await catalogWorker.value
            } onCancel: {
                catalogWorker.cancel()
            }
            guard !Task.isCancelled, myGen == workCoordinator.generation else { return }
            searchResults = output.songResults
            matchingAlbums = albums
            workCoordinator.lyricsCache = output.cache
            renderedQuery = query
            isSearching = false
        }
    }

    private func performSemanticSearch(
        query: String,
        songsSnapshot: [PrimuseKit.Song],
        metadataRevisionKey: String,
        generation: Int
    ) {
        // 智能补充这块关掉了就不去问 AI, 省下一次联网。
        guard scope == nil,
              resultLayout.shows(.intelligent),
              intelligence.isSemanticSearchConfigured else {
            semanticResults = []
            intelligenceRenderedQuery = query
            isIntelligenceSearching = false
            semanticSearchFeedback = .idle
            return
        }

        isIntelligenceSearching = true
        semanticSearchFeedback = .loading
        semanticResults = []
        workCoordinator.intelligenceTask = Task {
            defer {
                if generation == workCoordinator.generation {
                    isIntelligenceSearching = false
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(550))
            } catch {
                return
            }
            guard !Task.isCancelled, generation == workCoordinator.generation else { return }
            intelligenceRenderedQuery = query
            var streamedTerms: [String] = []
            let outcome = await intelligence.semanticSearchOutcome(
                for: query,
                onStreamEvent: { event in
                    guard !Task.isCancelled,
                          generation == workCoordinator.generation else { return }
                    switch event {
                    case .reset:
                        streamedTerms = []
                        semanticResults = []
                    case .term(let term):
                        guard !streamedTerms.contains(where: {
                            $0.caseInsensitiveCompare(term) == .orderedSame
                        }) else { return }
                        streamedTerms.append(term)
                        let results = await semanticLibraryMatches(
                            plan: AISemanticSearchPlan(expandedTerms: streamedTerms),
                            songsSnapshot: songsSnapshot,
                            metadataRevisionKey: metadataRevisionKey
                        )
                        guard !Task.isCancelled,
                              generation == workCoordinator.generation else { return }
                        semanticResults = results
                    case .completed:
                        break
                    }
                }
            )
            guard !Task.isCancelled, generation == workCoordinator.generation else { return }
            switch outcome {
            case .unavailable:
                semanticResults = []
                semanticSearchFeedback = .idle
            case .failed:
                semanticResults = []
                semanticSearchFeedback = .failed
            case .empty(let providerName, let fallbackDepth):
                semanticResults = []
                semanticSearchFeedback = .noMatches(
                    provider: providerName,
                    fallbackDepth: fallbackDepth
                )
            case .success(let execution):
                let results = await semanticLibraryMatches(
                    plan: execution.plan,
                    songsSnapshot: songsSnapshot,
                    metadataRevisionKey: metadataRevisionKey
                )
                guard !Task.isCancelled, generation == workCoordinator.generation else { return }
                semanticResults = results
                semanticSearchFeedback = results.isEmpty
                    ? .noMatches(
                        provider: execution.providerName,
                        fallbackDepth: execution.fallbackDepth
                    )
                    : .success(
                        provider: execution.providerName,
                        resultCount: results.count,
                        fallbackDepth: execution.fallbackDepth
                    )
            }
            intelligenceRenderedQuery = query
        }
    }

    private func semanticLibraryMatches(
        plan: AISemanticSearchPlan,
        songsSnapshot: [PrimuseKit.Song],
        metadataRevisionKey: String
    ) async -> [SemanticLibrarySearchResult] {
        let concepts = AISemanticLibraryAggregationPolicy.concepts(from: plan)
        var candidates: [AISemanticLibraryMatchCandidate] = []
        var songsByID: [String: PrimuseKit.Song] = [:]
        for (conceptOrder, concept) in concepts.enumerated() {
            guard !Task.isCancelled else { return [] }
            let indexed = await LibrarySearchIndex.shared.search(
                query: concept,
                songs: songsSnapshot,
                albums: [],
                metadataRevisionKey: metadataRevisionKey,
                songLimit: 12,
                albumLimit: 0
            )

            let matches: [LibrarySearchResult]
            if let indexed {
                matches = indexed.output.songResults
            } else {
                let fallbackWorker = Task.detached(priority: .utility) {
                    LibrarySearchWorker.compute(
                        query: concept,
                        songs: songsSnapshot,
                        albums: [],
                        cache: LibrarySearchCache(),
                        includeMetadata: true,
                        includeLyrics: false,
                        songLimit: 12,
                        albumLimit: 0
                    ).songResults
                }
                matches = await withTaskCancellationHandler {
                    await fallbackWorker.value
                } onCancel: {
                    fallbackWorker.cancel()
                }
            }

            for match in matches {
                songsByID[match.song.id] = match.song
                candidates.append(AISemanticLibraryMatchCandidate(
                    songID: match.song.id,
                    title: match.song.title,
                    score: match.score,
                    relatedConcept: concept,
                    conceptOrder: conceptOrder
                ))
            }
        }
        return AISemanticLibraryAggregationPolicy.rankedMatches(candidates).compactMap { match in
            guard let song = songsByID[match.songID] else { return nil }
            return SemanticLibrarySearchResult(
                song: song,
                relatedConcept: match.relatedConcept
            )
        }
    }

    private func mergeIndexedSearch(
        _ indexed: LibrarySearchOutput,
        literalFallback: LibrarySearchOutput
    ) -> LibrarySearchOutput {
        var results = indexed.songResults
        var ids = Set(results.map(\.id))
        for result in literalFallback.songResults where !ids.contains(result.id) {
            ids.insert(result.id)
            results.append(result)
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.song.title.localizedCaseInsensitiveCompare(rhs.song.title) == .orderedAscending
        }
        return LibrarySearchOutput(
            songResults: Array(results.prefix(120)),
            albumResults: indexed.albumResults,
            cache: literalFallback.cache
        )
    }

    private var searchingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("search_running")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(iOS)
        .background(Color(.systemBackground))
        #else
        .background(Color(NSColor.windowBackgroundColor))
        #endif
    }

    private func playSong(_ song: PrimuseKit.Song, lyricsHint: String? = nil, matchKind: LibrarySearchMatchKind? = nil) {
        guard let insertedIndex = player.insertNextInQueue([song]) else { return }
        // 歌词命中: 让 NowPlayingView 加载完歌词后自动 seek 到那行;
        // 同时打开全屏 NowPlayingView 让用户能立刻看到上下文。
        if matchKind == .lyrics, let snippet = lyricsHint, !snippet.isEmpty {
            player.requestLyricsJump(songID: song.id, snippet: snippet)
            NotificationCenter.default.post(name: .primuseRequestShowNowPlaying, object: nil)
        }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.playFromQueue(at: insertedIndex) }
        addRecentSearch(searchText)
    }

    private func showInLibraryButton(for song: PrimuseKit.Song) -> some View {
        Button {
            onShowInLibrary(song)
        } label: {
            Label("show_in_library", systemImage: "music.note.list")
        }
    }

    private func loadRecentSearches() {
        recentSearches = SearchHistoryStore.load()
    }

    private func addRecentSearch(_ query: String) {
        SearchHistoryStore.record(query)
    }

    private func deleteRecentSearches(at offsets: IndexSet) {
        recentSearches.remove(atOffsets: offsets)
        saveRecentSearches()
    }

    private func clearRecentSearches() {
        recentSearches.removeAll()
        saveRecentSearches()
    }

    private func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        saveRecentSearches()
    }

    private func saveRecentSearches() {
        SearchHistoryStore.save(recentSearches)
    }
}

private extension View {
    @ViewBuilder
    func searchResultSwipeActions<LibraryAction: View>(
        queueActionsEnabled: Bool,
        onInsertNext: @escaping () -> Void,
        onAppendToQueue: @escaping () -> Void,
        @ViewBuilder showInLibrary: @escaping () -> LibraryAction
    ) -> some View {
        #if os(iOS)
        if queueActionsEnabled {
            self
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(action: onInsertNext) {
                        Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(.accentColor)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(action: onAppendToQueue) {
                        Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .tint(.green)

                    showInLibrary()
                        .tint(.accentColor)
                }
        } else {
            self.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                showInLibrary()
                    .tint(.accentColor)
            }
        }
        #else
        self.swipeActions(edge: .trailing, allowsFullSwipe: false) {
            showInLibrary()
                .tint(.accentColor)
        }
        #endif
    }
}

#if os(macOS)
private struct MacSearchFlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 480
        let rows = rows(in: maxWidth, subviews: subviews)
        return CGSize(width: maxWidth, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + rowSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func rows(in maxWidth: CGFloat, subviews: Subviews) -> (height: CGFloat, count: Int) {
        guard subviews.isEmpty == false else { return (0, 0) }

        var x: CGFloat = 0
        var height: CGFloat = 0
        var lineHeight: CGFloat = 0
        var count = 1

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                height += lineHeight + rowSpacing
                x = 0
                lineHeight = 0
                count += 1
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        height += lineHeight
        return (height, count)
    }
}
#endif
