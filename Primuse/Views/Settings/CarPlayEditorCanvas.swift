#if os(iOS)
import PrimuseKit
import CarPlay
import SwiftUI

struct CarPlayEditorCanvas: View {
    let blocks: [CarPlayHomeBlock]
    let configuration: CarPlayLayoutConfiguration
    let selectedID: String?
    let editing: Bool
    let playerPage: Bool
    let wide: Bool
    let previewItem: CarPlayHomeItem?
    let select: (String) -> Void
    let activate: (CarPlayHomeItem) -> Void
    let drop: ([String], String?, String?) -> Bool
    let addContent: (String?) -> Void
    var catalog = CarPlayEditorCatalog.Snapshot()
    var selectedTabID: String?
    var selectTab: (String) -> Void = { _ in }
    var moveTab: ([String], String?) -> Bool = { _, _ in false }
    var editingMenu = false
    @State private var localTabID: String?
    @State private var browseKind: CarPlayMainTab.Kind?
    @State private var artist: Artist?
    @State private var assistantPage = false
    @State private var searchPage = false
    @State private var searchQuery: String?

    @State private var detail: CarPlayHomeItem?
    @State private var localPlayer: CarPlayHomeItem?

    private var screenWidth: CGFloat { wide ? 800 : 600 }
    private var screenHeight: CGFloat { screenWidth * 9 / 16 }

    var body: some View {
        GeometryReader { geometry in
            screen
                .frame(width: screenWidth, height: screenHeight)
                .environment(\.dynamicTypeSize, .large)
                .scaleEffect(geometry.size.width / screenWidth, anchor: .topLeading)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(CarPlayEditorTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(CarPlayEditorTheme.border, lineWidth: 1) }
        .onChange(of: selectedTabID) { localTabID = nil; clearNavigation() }
        .onChange(of: playerPage) { detail = nil; localPlayer = nil }
        .onChange(of: editing) { detail = nil; localPlayer = nil }
        .onChange(of: configuration.visualStyle) { detail = nil; localPlayer = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("carplay.canvas")
    }

    private var screen: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                if playerPage || localPlayer != nil { player(localPlayer ?? previewItem) }
                else if assistantPage { assistantDetail }
                else if searchPage { searchDetail }
                else if let detail { detailPage(detail) }
                else if browseKind != nil || artist != nil { browseDetail }
                else { home }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(CarPlayEditorTheme.text)
        .buttonStyle(.plain)
        .background(CarPlayEditorTheme.canvas)
    }

    private var sidebar: some View {
        VStack(spacing: 17) {
            Text(verbatim: "9:41").font(.system(size: 11, weight: .semibold))
            Image(systemName: "wifi").font(.system(size: 11))
            Image(systemName: "music.note").font(.system(size: 19, weight: .semibold))
                .foregroundStyle(CarPlayEditorTheme.background)
                .frame(width: 30, height: 30).background(CarPlayEditorTheme.accent, in: RoundedRectangle(cornerRadius: 9))
            Image(systemName: "map.fill").font(.system(size: 20)).foregroundStyle(CarPlayEditorTheme.secondary)
            Spacer()
            Image(systemName: "square.grid.2x2.fill").font(.system(size: 19))
        }
        .padding(.vertical, 14).frame(width: 54)
        .background(CarPlayEditorTheme.sidebar)
    }

    private var tabs: [CarPlayMainTab] { configuration.visibleTabs(maximumCount: CPTabBarTemplate.maximumTabCount) }
    private var activeTab: CarPlayMainTab {
        if editing { return configuration.tabs.first { $0.kind == .home } ?? CarPlayMainTab.defaults[0] }
        return tabs.first { $0.id == (localTabID ?? selectedTabID) } ?? tabs[0]
    }
    private var compactSiri: Bool {
        if #available(iOS 26.0, *) { return configuration.siriPresentation == .button }
        return false
    }

    private var home: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(tabs) { tab in
                        Button {
                            localTabID = tab.id
                            clearNavigation()
                            selectTab(tab.id)
                        } label: {
                            Text(tab.displayTitle).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 12).frame(minHeight: 38)
                                .background(activeTab.id == tab.id ? CarPlayEditorTheme.border : .clear, in: Capsule())
                        }
                        .accessibilityIdentifier("carplay.previewTab." + tab.id)
                        .draggable(editingMenu ? "carplay-tab:" + tab.id : "")
                        .dropDestination(for: String.self) { values, _ in editingMenu && moveTab(values, tab.id) }
                    }
                }.padding(3).background(CarPlayEditorTheme.surface, in: Capsule())
                if previewItem != nil {
                    Button { localPlayer = previewItem } label: { Image(systemName: "waveform").frame(width: 38, height: 38) }
                        .background(CarPlayEditorTheme.surface, in: Circle()).accessibilityLabel("carplay_now_playing")
                }
            }.padding(.vertical, 8).padding(.horizontal, 8)
            if activeTab.kind == .home { blockScroll }
            else {
                ScrollView {
                    VStack(spacing: 10) {
                        rootActions
                        tabContents(activeTab)
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }.scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder private var rootActions: some View {
        if #available(iOS 26.0, *) {
            HStack(spacing: 18) {
                if activeTab.kind != .search {
                    Button { searchPage = true } label: { headerAction("search_title", symbol: "magnifyingglass") }
                        .accessibilityIdentifier("carplay.previewSearch")
                }
                if configuration.showsSiri && compactSiri {
                    Button { assistantPage = true } label: { headerAction("Siri", symbol: "mic") }
                        .accessibilityIdentifier("carplay.previewSiri")
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 4)
        }
        if configuration.showsSiri && !compactSiri { assistantRow }
    }

    private func headerAction(_ title: LocalizedStringKey, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 23))
            Text(title).font(.system(size: 12, weight: .medium))
        }.frame(width: 74, height: 56).background(CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var assistantRow: some View {
        HStack(spacing: 8) {
            Text("carplay_ask_siri").font(.system(size: 18, weight: .medium))
            Spacer()
            Image(systemName: "mic.circle").font(.system(size: 22))
        }.padding(14).background(CarPlayEditorTheme.surface, in: Capsule())
            .accessibilityIdentifier("carplay.previewAssistantRow")
    }

    @ViewBuilder private func tabContents(_ tab: CarPlayMainTab) -> some View {
        switch tab.kind {
        case .home: EmptyView()
        case .library:
            ForEach(libraryPreviewKinds, id: \.self) { kind in
                Button { browseKind = kind } label: { menuRow(NSLocalizedString(kind.titleKey, comment: ""), symbol: kind.symbol) }
            }
        case .songs: mediaRows(Array((catalog.entries[.song] ?? []).prefix(60)))
        case .albums: mediaRows(Array((catalog.entries[.album] ?? []).prefix(60)).map { $0.configured(directly: false) })
        case .playlists: playlistRows
        case .radio: mediaRows(Array((catalog.entries[.radio] ?? []).prefix(60)))
        case .artists:
            ForEach(catalog.artists.prefix(60)) { entry in
                Button { artist = entry } label: { menuRow(entry.name, symbol: "music.mic") }
            }
            if catalog.artists.isEmpty { emptyContent }
        case .folders:
            mediaRows((CarPlayFolderLibrary.shared.index?.sourceNodes ?? []).prefix(60).map { CarPlayEditorCatalog.Snapshot.folder($0).configured(directly: false) })
        case .search: searchRows
        case .spokenWord: spokenWordRows
        case .collection:
            if let content = tab.content {
                if let folderID = content.folderID, let node = CarPlayFolderLibrary.shared.index?.node(withID: folderID) {
                    collectionRows(CarPlayEditorCatalog.Snapshot.folder(node))
                } else { collectionRows(catalog.resolve(content, directly: false)) }
            }
        }
    }

    private var playlistRows: some View {
        var block = CarPlayLayoutBlock(id: "menu.playlists", kind: .playlists, style: configuration.browseStyle)
        block.columns = configuration.visualStyle == .wall ? 3 : 2
        block.showsTitle = false
        block.playsImmediately = configuration.playsCollectionsDirectly
        let items = Array((catalog.entries[.playlist] ?? []).prefix(60)).map { $0.configured(directly: configuration.playsCollectionsDirectly) }
        return blockView(CarPlayHomeBlock(configuration: block, items: items))
    }

    /// The car's library menu, which lists spoken word once there is some.
    private var libraryPreviewKinds: [CarPlayMainTab.Kind] {
        let hasSpokenWord = !AppServices.shared.musicLibrary.spokenWordSongs.isEmpty
        return [.folders, .playlists, .songs, .albums, .artists] + (hasSpokenWord ? [.spokenWord] : []) + [.radio, .search]
    }

    /// Book titles in the order the car lists them.
    @ViewBuilder private var spokenWordRows: some View {
        let library = AppServices.shared.musicLibrary
        let books = SpokenWordBookGrouping.books(
            from: library.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: .shared) }
        )
        let listed = SpokenWordCarPlayShelfPolicy.sections(from: books, limit: 60).flatMap(\.books)
        ForEach(listed) { book in
            menuRow(book.title, symbol: CarPlayMainTab.Kind.spokenWord.symbol)
        }
        if listed.isEmpty { emptyContent }
    }

    private func menuRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 30)
            Text(title).font(.system(size: 19, weight: .medium)).lineLimit(1)
            Spacer()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(CarPlayEditorTheme.row, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyContent: some View {
        Text("carplay_no_content").font(.system(size: 16)).foregroundStyle(CarPlayEditorTheme.secondary).padding(24)
    }

    @ViewBuilder private func mediaRows(_ rows: [CarPlayHomeItem]) -> some View {
        if rows.isEmpty { emptyContent }
        ForEach(rows) { item in
            Button { open(item) } label: {
                HStack(spacing: 12) {
                    CarPlayPreviewArtwork(item: item, pixelSize: 88).frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.system(size: 17, weight: .medium)).lineLimit(1)
                        if let subtitle = item.subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(CarPlayEditorTheme.row, in: RoundedRectangle(cornerRadius: 8))
            }.disabled(!item.enabled)
        }
    }

    @ViewBuilder private func collectionRows(_ item: CarPlayHomeItem) -> some View {
        let rows = detailItems(item)
        if !rows.isEmpty {
            Button { localPlayer = item; activate(item) } label: { menuRow(String(localized: "carplay_play_all"), symbol: "play.fill") }
            Button { localPlayer = item; activate(item) } label: { menuRow(String(localized: "carplay_shuffle_all"), symbol: "shuffle") }
        }
        mediaRows(rows)
    }

    private func clearNavigation() {
        detail = nil; localPlayer = nil; browseKind = nil; artist = nil
        searchPage = false; searchQuery = nil; assistantPage = false
    }

    private func detailHeader(_ title: String) -> some View {
        HStack {
            Button {
                if assistantPage { assistantPage = false }
                else if searchPage { if searchQuery != nil { searchQuery = nil } else { searchPage = false } }
                else if detail != nil { detail = nil }
                else if artist != nil { artist = nil }
                else { browseKind = nil }
            } label: { Image(systemName: "chevron.left").padding(12) }
            Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
            Spacer()
            if !searchPage {
                Button { searchPage = true } label: { Image(systemName: "magnifyingglass").padding(12) }
            }
            if configuration.showsSiri && compactSiri && !assistantPage {
                Button { assistantPage = true } label: { Image(systemName: "mic").padding(12) }
            }
        }
    }

    private var assistantDetail: some View {
        VStack {
            detailHeader("Siri")
            assistantRow.padding(12)
            Spacer()
        }
    }

    private var searchDetail: some View {
        VStack {
            detailHeader(String(localized: "recent_searches"))
            ScrollView { VStack(spacing: 10) { searchRows }.padding(12) }
        }
    }

    @ViewBuilder private var searchRows: some View {
        if let searchQuery {
            mediaRows(Array((catalog.entries[.song] ?? []).lazy.filter {
                $0.title.localizedStandardContains(searchQuery) || ($0.subtitle?.localizedStandardContains(searchQuery) ?? false)
            }.prefix(60)))
        } else {
            let queries = UserDefaults.standard.stringArray(forKey: CloudKVSKey.recentSearches) ?? []
            if queries.isEmpty { Text("carplay_search_no_results").font(.system(size: 16)).foregroundStyle(.secondary).padding(20) }
            ForEach(Array(queries.prefix(12).enumerated()), id: \.offset) { _, query in
                Button { searchQuery = query } label: { menuRow(query, symbol: "magnifyingglass") }
            }
        }
    }

    private var browseDetail: some View {
        VStack {
            detailHeader(artist?.name ?? NSLocalizedString((browseKind ?? .library).titleKey, comment: ""))
            ScrollView {
                VStack(spacing: 10) {
                    if let artist {
                        mediaRows(Array((catalog.artistSongs[artist.id] ?? []).lazy.compactMap { catalog.lookup[.song]?[$0] }.prefix(60)))
                    } else if let browseKind { tabContents(CarPlayMainTab(kind: browseKind)) }
                }.padding(12)
            }
        }
    }

    private var blockScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    rootActions
                    ForEach(blocks.filter { $0.configuration.isVisible && $0.configuration.kind != .siri }) { block in
                        blockView(block).id(block.id)
                    }
                    if !editing {
                        Button { browseKind = .folders } label: { menuRow(String(localized: "library_browse_folder"), symbol: "folder") }
                        Button { browseKind = .library } label: { menuRow(String(localized: "library_title"), symbol: "square.stack") }
                    }
                    if editing {
                        Button { addContent(nil) } label: {
                            Label("carplay_add_module", systemImage: "plus")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(CarPlayEditorTheme.secondary)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(CarPlayEditorTheme.border, style: StrokeStyle(lineWidth: 1, dash: [4])) }
                        }
                        .dropDestination(for: String.self) { values, _ in drop(values, nil, nil) }
                    }
                }.padding(.horizontal, 12).padding(.top, editing ? 7 : 0).padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selectedID) { _, id in
                if editing, let id { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func blockView(_ block: CarPlayHomeBlock) -> some View {
        let selected = selectedID == block.id
        return VStack(alignment: .leading, spacing: 7) {
            if block.configuration.showsTitle && !editing {
                Text(block.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(CarPlayEditorTheme.secondary)
            }
            if block.items.isEmpty {
                Button { select(block.id) } label: {
                    Label("carplay_empty_module", systemImage: block.configuration.kind.symbol)
                        .font(.system(size: 14)).foregroundStyle(CarPlayEditorTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.disabled(!editing)
            } else if block.configuration.style == .list {
                VStack(spacing: 4) {
                    ForEach(block.items) { item in itemView(item, block: block) }
                }
            } else {
                let count = min(block.configuration.columns, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: count), spacing: 7) {
                    ForEach(block.items) { item in itemView(item, block: block) }
                }
            }
        }
        .padding(editing ? 8 : 0)
        .background(selected && editing ? CarPlayEditorTheme.accent.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if editing {
                RoundedRectangle(cornerRadius: 10).strokeBorder(
                    selected ? CarPlayEditorTheme.accent : CarPlayEditorTheme.border,
                    style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4]))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if editing {
                Text(block.title).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? CarPlayEditorTheme.background : CarPlayEditorTheme.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(selected ? CarPlayEditorTheme.accent : CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: 9, y: -9).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if editing && selected {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(CarPlayEditorTheme.background)
                    .frame(width: 22, height: 22).background(CarPlayEditorTheme.accent, in: Circle())
                    .offset(x: 5, y: -10).draggable("carplay-block:" + block.id)
                    .accessibilityLabel("carplay_move_module")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if editing { select(block.id) } }
        .dropDestination(for: String.self) { values, _ in drop(values, block.id, nil) }
    }

    private func itemView(_ item: CarPlayHomeItem, block: CarPlayHomeBlock) -> some View {
        Button {
            if editing { select(block.id) } else { open(item) }
        } label: {
            Group {
                if block.configuration.style == .list {
                    HStack(spacing: 9) {
                        CarPlayPreviewArtwork(item: item, pixelSize: 88).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                            if let subtitle = item.subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(CarPlayEditorTheme.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: block.configuration.playsImmediately ? "play.fill" : "chevron.right")
                            .font(.system(size: 11)).foregroundStyle(CarPlayEditorTheme.secondary)
                    }.padding(7).background(CarPlayEditorTheme.row, in: RoundedRectangle(cornerRadius: 6))
                } else if block.configuration.style == .capsules {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 19))
                        Text(item.title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).frame(height: 58)
                    .background(CarPlayEditorTheme.surface, in: Capsule())
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        CarPlayPreviewArtwork(item: item, pixelSize: 240)
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }.opacity(item.enabled ? 1 : 0.5)
        }
        .disabled(!editing && !item.enabled)
    }

    private func open(_ item: CarPlayHomeItem) {
        switch item.target {
        case .playlist(_, false), .album(_, false), .folder(_, false): detail = item
        default: localPlayer = item; activate(item)
        }
    }

    private func detailPage(_ item: CarPlayHomeItem) -> some View {
        VStack(spacing: 10) {
            detailHeader(item.title)
            ScrollView { VStack(spacing: 10) { collectionRows(item) }.padding(.horizontal, 12) }
        }
    }

    private func detailItems(_ item: CarPlayHomeItem) -> [CarPlayHomeItem] {
        if case .folder(let id, _) = item.target {
            let folders = CarPlayFolderLibrary.shared.index
            let children = (folders?.children(of: id) ?? []).prefix(30).map { CarPlayEditorCatalog.Snapshot.folder($0).configured(directly: false) }
            let songs = (folders?.songIDs(in: id, scope: .direct) ?? []).lazy.compactMap { catalog.lookup[.song]?[$0] }.prefix(30)
            return children + songs
        }
        return catalog.detail(for: item)
    }

    private func displayedItem(_ item: CarPlayHomeItem?) -> CarPlayHomeItem {
        if let item {
            if let first = catalog.detail(for: item).first { return first }
            return item
        }
        return CarPlayHomeItem(id: "empty", title: String(localized: "carplay_nothing_playing"), symbol: "music.note", target: .nowPlaying)
    }

    private func player(_ source: CarPlayHomeItem?) -> some View {
        let item = displayedItem(source)
        return VStack(spacing: 12) {
            HStack {
                if localPlayer != nil { Button { localPlayer = nil } label: { Image(systemName: "chevron.left") } }
                Text("carplay_now_playing").font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "list.bullet")
            }.padding(.horizontal, 20).padding(.top, 18)
            HStack(spacing: 24) {
                CarPlayPreviewArtwork(item: item).frame(width: 172, height: 172)
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title).font(.system(size: 23, weight: .semibold)).lineLimit(2)
                    if let subtitle = item.subtitle { Text(subtitle).font(.system(size: 15)).foregroundStyle(CarPlayEditorTheme.secondary).lineLimit(1) }
                    Capsule().fill(CarPlayEditorTheme.border).frame(height: 4)
                    HStack(spacing: 30) {
                        Image(systemName: "backward.fill")
                        Image(systemName: "play.fill").font(.system(size: 30))
                        Image(systemName: "forward.fill")
                    }.font(.system(size: 20)).frame(maxWidth: .infinity).padding(.top, 6)
                }
            }.padding(.horizontal, 24)
            if !configuration.minimalNowPlaying {
                HStack(spacing: 65) { Image(systemName: "shuffle"); Image(systemName: "repeat"); Image(systemName: "heart") }
                    .font(.system(size: 18)).foregroundStyle(CarPlayEditorTheme.secondary).padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

struct CarPlayPreviewArtwork: View {
    let item: CarPlayHomeItem
    var pixelSize = 240
    @State private var image: UIImage?
    private var identity: String {
        let library = AppServices.shared.musicLibrary
        let artwork: String
        switch item.artwork {
        case .songReference(let id, let coverRef): artwork = id + (coverRef ?? "")
        case .song(let song): artwork = song.id + (song.coverArtFileName ?? "")
        case .album(let album): artwork = album.id + "\(library.albumArtworkLookupRevision):\(library.artworkOverrideRevision)"
        case .playlist(let playlist): artwork = playlist.id + "\(playlist.updatedAt):\(library.artworkOverrideRevision):\(library.albumArtworkLookupRevision)"
        case nil: artwork = item.id
        }
        return artwork + ":\(pixelSize)"
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CarPlayEditorTheme.artwork
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else {
                    Image(systemName: item.symbol)
                        .font(.system(size: max(10, min(42, geometry.size.width * 0.3)), weight: .medium))
                        .foregroundStyle(CarPlayEditorTheme.accent.opacity(0.7))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: identity) {
            guard let artwork = item.artwork else { image = nil; return }
            let loaded = await CarPlayHomeContent.artwork(artwork, pixelSize: pixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .accessibilityHidden(true)
    }
}
#endif
