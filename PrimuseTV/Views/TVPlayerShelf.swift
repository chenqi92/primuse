#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 播放页底部的快切货架:不离开播放页就能换一张专辑、一位艺术家、一个流派。
/// 顺序按「离正在播放的这首有多近」排:接下来、本专辑、同艺术家、同流派,再是整库的
/// 专辑 / 艺术家,最后是最近播放和我喜欢。长按封面的菜单、「更多」里的「前往」
/// 与这里用同一套名字和图标(`title` / `systemImage`)。
enum TVPlayerShelfTab: String, CaseIterable, Identifiable, Hashable {
    case upNext
    case thisAlbum
    case artistAlbums
    case genres
    case albums
    case artists
    case recent
    case liked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upNext: return String(localized: "up_next")
        case .thisAlbum: return PMString("ext.tv.player.shelf.thisAlbum")
        case .artistAlbums: return PMString("ext.tv.player.shelf.moreByArtist")
        case .genres: return String(localized: "tab_genres")
        case .albums: return String(localized: "tab_albums")
        case .artists: return String(localized: "tab_artists")
        case .recent: return String(localized: "recently_played")
        case .liked: return String(localized: "sidebar_liked_songs")
        }
    }

    var systemImage: String {
        switch self {
        case .upNext: return "text.line.first.and.arrowtriangle.forward"
        case .thisAlbum: return "square.stack"
        case .artistAlbums: return "music.mic"
        case .genres: return "guitars"
        case .albums: return "square.grid.2x2"
        case .artists: return "person.2"
        case .recent: return "clock.arrow.circlepath"
        case .liked: return "heart"
        }
    }

    /// 长按封面与「更多」里「前往」列出的几栏:都围绕正在播放的这一首。
    static let goToDestinations: [TVPlayerShelfTab] = [.upNext, .thisAlbum, .artistAlbums, .genres]
}

/// 货架上的一张卡片。`queueSong` 带着它在「接下来」里的位置:同一首歌可能在队列里
/// 出现不止一次,点哪一张就跳到哪一格。
enum TVPlayerShelfItem: Identifiable {
    case queueSong(offset: Int, song: TVSong)
    case song(TVSong)
    case album(TVAlbum)
    case artist(TVArtist)
    case genre(LibraryGenre)

    var id: String {
        switch self {
        case let .queueSong(offset, song): return "q\(offset)#\(song.id)"
        case let .song(song): return "s#\(song.id)"
        case let .album(album): return "a#\(album.id)"
        case let .artist(artist): return "r#\(artist.id)"
        case let .genre(genre): return "g#\(genre.id)"
        }
    }
}

/// 正在播放的这首在曲库里的位置:专辑、艺术家、流派。换歌时算一次。
struct TVPlayerShelfContext: Equatable {
    var songID = ""
    var albumID = ""
    var artistIDs: Set<String> = []
    var genreID: String?

    @MainActor
    static func current(store: TVStore) -> TVPlayerShelfContext {
        var context = TVPlayerShelfContext()
        context.songID = store.currentSongID ?? store.nowPlaying.songID
        context.albumID = store.nowPlaying.albumID
        if !context.songID.isEmpty, let raw = store.library.song(id: context.songID) {
            context.artistIDs = Set(store.library.artistIDs(for: raw))
            if let genre = raw.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
                context.genreID = LibraryGenreIndexBuilder.normalizedID(for: genre)
            }
        }
        return context
    }

    /// 哪几栏有内容。只做 O(1) 的判断,整库列表等真的切到那一栏再建。
    @MainActor
    func availableTabs(store: TVStore) -> [TVPlayerShelfTab] {
        TVPlayerShelfTab.allCases.filter { tab in
            switch tab {
            case .upNext: return !store.queueUpNextIDs.isEmpty
            case .thisAlbum: return !albumID.isEmpty
            case .artistAlbums: return !artistIDs.isEmpty
            case .genres: return !store.library.visibleGenres.isEmpty
            case .albums: return !store.albums.isEmpty
            case .artists: return !store.artists.isEmpty
            case .recent: return !store.recentlyPlayed.isEmpty
            case .liked: return !store.library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID).isEmpty
            }
        }
    }

    /// 一栏的卡片。整库的专辑 / 艺术家 / 流派把正在播放的那一项挪到最前面:打开就
    /// 看得到、焦点直接落上去,不用为了找到它把前面几千张卡片都建出来。
    @MainActor
    func items(for tab: TVPlayerShelfTab, store: TVStore) -> [TVPlayerShelfItem] {
        switch tab {
        case .upNext:
            return store.queueUpNextIDs.enumerated().compactMap { offset, id in
                store.song(id).map { TVPlayerShelfItem.queueSong(offset: offset, song: $0) }
            }
        case .thisAlbum:
            return albumID.isEmpty ? [] : store.songs(forAlbum: albumID).map(TVPlayerShelfItem.song)
        case .artistAlbums:
            // 这位艺术家的全部专辑(含正在放的这张),正在放的在前,其余新的在前。
            var seen = Set<String>()
            var albums: [TVAlbum] = []
            for artistID in artistIDs.sorted() {
                for song in store.songs(forArtistID: artistID) {
                    guard seen.insert(song.albumID).inserted,
                          let album = store.album(song.albumID) else { continue }
                    albums.append(album)
                }
            }
            albums.sort { lhs, rhs in
                if (lhs.id == albumID) != (rhs.id == albumID) { return lhs.id == albumID }
                return lhs.year != rhs.year ? lhs.year > rhs.year
                    : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return albums.map(TVPlayerShelfItem.album)
        case .genres:
            return Self.pinned(store.library.visibleGenres, first: { $0.id == genreID })
                .map(TVPlayerShelfItem.genre)
        case .albums:
            return Self.pinned(store.albums, first: { $0.id == albumID }).map(TVPlayerShelfItem.album)
        case .artists:
            return Self.pinned(store.artists, first: { artistIDs.contains($0.id) })
                .map(TVPlayerShelfItem.artist)
        case .recent:
            return store.recentlyPlayed.map(TVPlayerShelfItem.song)
        case .liked:
            return store.library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID)
                .compactMap { store.song($0.id) }
                .map(TVPlayerShelfItem.song)
        }
    }

    private static func pinned<Element>(_ elements: [Element], first isCurrent: (Element) -> Bool) -> [Element] {
        guard let index = elements.firstIndex(where: isCurrent), index > 0 else { return elements }
        var reordered = elements
        let current = reordered.remove(at: index)
        reordered.insert(current, at: 0)
        return reordered
    }
}

/// 货架本身不看父视图的任何变化:播放页每 0.25 秒随进度重算一次,若货架跟着重算,
/// 成百上千张卡片的 ForEach 每秒要对比四遍,遥控器就会迟钝。它只跟着自己的状态
/// (当前栏、焦点、渲染范围)和正在播放的那首歌变。
struct TVPlayerShelf: View, @MainActor Equatable {
    @Environment(TVStore.self) private var store

    /// 打开时停在哪一栏;之后的切换是货架自己的状态。
    let initialTab: TVPlayerShelfTab
    /// 开始播放后收起货架(`true`),或者按 Menu 直接收起(`false`)。
    var onClose: (_ startedPlayback: Bool) -> Void
    var onInteraction: () -> Void = {}

    @State private var tab: TVPlayerShelfTab
    @State private var context = TVPlayerShelfContext()
    @State private var availableTabs: [TVPlayerShelfTab] = []
    @State private var itemsByTab: [TVPlayerShelfTab: [TVPlayerShelfItem]] = [:]
    @State private var hasLoaded = false
    @State private var renderedCount = TVLongListPagingPolicy.pageSize
    @FocusState private var focusedItemID: String?
    @FocusState private var focusedTabID: String?

    private let cardWidth: CGFloat = 220
    /// 横向 ScrollView 竖直方向会吃满剩余高度,得给定行高,货架才贴在屏幕底部。
    /// 封面 + 两行标题 + 一行副标题,再加焦点放大留的上下边。
    private var rowHeight: CGFloat { cardWidth + 160 }

    init(
        initialTab: TVPlayerShelfTab,
        onClose: @escaping (_ startedPlayback: Bool) -> Void,
        onInteraction: @escaping () -> Void = {}
    ) {
        self.initialTab = initialTab
        self.onClose = onClose
        self.onInteraction = onInteraction
        _tab = State(initialValue: initialTab)
    }

    static func == (lhs: TVPlayerShelf, rhs: TVPlayerShelf) -> Bool {
        lhs.initialTab == rhs.initialTab
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            tabRow
            itemsRow
        }
        .padding(.horizontal, 100)
        .padding(.top, 60)
        .padding(.bottom, 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                stops: [
                    // 上沿柔和过渡,卡片那一带要压得住后面的标题和进度条,不能透出来。
                    .init(color: TVColor.bg.opacity(0), location: 0),
                    .init(color: TVColor.bg.opacity(0.9), location: 0.1),
                    .init(color: TVColor.bg.opacity(0.98), location: 0.24),
                    .init(color: TVColor.bg, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .onExitCommand { onClose(false) }
        // 换歌(自然播完或在货架里点了别的)后内容跟着换;焦点不动,免得正在挑的时候被拽走。
        .task(id: store.currentSongID ?? store.nowPlaying.songID) {
            context = TVPlayerShelfContext.current(store: store)
            availableTabs = context.availableTabs(store: store)
            itemsByTab = [:]
            if !availableTabs.contains(tab), let first = availableTabs.first { tab = first }
            loadItems(for: tab)
            guard !hasLoaded else { return }
            hasLoaded = true
            await Task.yield()
            focusedItemID = itemsByTab[tab]?.first?.id
        }
        .onChange(of: tab) { _, newTab in
            renderedCount = TVLongListPagingPolicy.pageSize
            loadItems(for: newTab)
        }
        .onChange(of: focusedItemID) { _, _ in onInteraction() }
        .onChange(of: focusedTabID) { previous, focused in
            guard let focused, let item = TVPlayerShelfTab(rawValue: focused) else { return }
            onInteraction()
            // 从卡片往上(或刚打开时)进入分栏行:先落在当前这一栏,不因为正上方
            // 是别的栏就把内容换掉;在分栏行里横移才跟着焦点切换。
            if previous == nil, item != tab {
                focusedTabID = tab.rawValue
            } else if item != tab {
                tab = item
            }
        }
    }

    private func loadItems(for tab: TVPlayerShelfTab) {
        guard itemsByTab[tab] == nil else { return }
        itemsByTab[tab] = context.items(for: tab, store: store)
    }

    // MARK: 分栏

    private var tabRow: some View {
        HStack(spacing: 10) {
            ForEach(availableTabs) { item in
                // 和顶栏一样:焦点横移到哪一栏就显示哪一栏,不必再按确认(见 focusedTabID)。
                TVFocusButton(radius: 16, scale: 1.04, lift: 0, ring: false, action: {
                    tab = item
                }, focusBinding: $focusedTabID, focusID: item.rawValue) { focused in
                    Label(item.title, systemImage: item.systemImage)
                        .labelStyle(.titleAndIcon)
                        .tvFont(.rowTitle, weight: item == tab ? .bold : .medium)
                        .lineLimit(1)
                        .foregroundStyle(focused ? TVColor.bg : (item == tab ? TVColor.text : TVColor.textMuted))
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(
                            focused ? AnyShapeStyle(TVColor.text)
                                : AnyShapeStyle(item == tab ? TVColor.surfaceStrong : Color.clear),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .accessibilityAddTraits(item == tab ? [.isButton, .isSelected] : .isButton)
            }
        }
        .focusSection()
    }

    @ViewBuilder
    private var itemsRow: some View {
        let items = itemsByTab[tab] ?? []
        let shown = TVLongListPagingPolicy.clamped(limit: renderedCount, totalCount: items.count)
        if !hasLoaded {
            Color.clear.frame(height: rowHeight)
        } else if items.isEmpty {
            Text(PMString("ext.tv.player.shelf.empty"))
                .tvFont(.body)
                .foregroundStyle(TVColor.textFaint)
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 34) {
                    ForEach(0..<shown, id: \.self) { index in
                        card(items[index]) { focused in
                            guard focused else { return }
                            let next = TVLongListPagingPolicy.limit(
                                after: shown, focusedRow: index, totalCount: items.count
                            )
                            if next != renderedCount { renderedCount = next }
                        }
                        .id(items[index].id)
                    }
                }
                // 焦点放大和描边要有地方画,不然会被横向 ScrollView 裁掉。
                .padding(.vertical, 22)
                .padding(.horizontal, 14)
            }
            .scrollClipDisabled()
            .frame(height: rowHeight)
            .focusSection()
            .id(tab)
        }
    }

    // MARK: 卡片

    @ViewBuilder
    private func card(_ item: TVPlayerShelfItem, onFocusChanged: @escaping (Bool) -> Void) -> some View {
        switch item {
        case let .queueSong(offset, song):
            songCard(song, id: item.id, isCurrent: false, onFocusChanged: onFocusChanged) {
                store.playQueueItem(at: offset)
                onClose(true)
            }
        case let .song(song):
            songCard(song, id: item.id, isCurrent: song.id == context.songID,
                     onFocusChanged: onFocusChanged) {
                if song.id == context.songID {
                    onClose(false)
                } else if store.play(song, in: songIDs(in: tab, fallback: song.id)) {
                    onClose(true)
                }
            }
        case let .album(album):
            TVAlbumCard(
                album: album,
                width: cardWidth,
                subtitleOverride: album.id == context.albumID
                    ? PMString("ext.tv.nowPlaying.eyebrow") : nil,
                action: { onClose(true) },
                onFocusChanged: onFocusChanged,
                focusBinding: $focusedItemID,
                focusID: item.id
            )
        case let .artist(artist):
            artistCard(artist, id: item.id, onFocusChanged: onFocusChanged)
        case let .genre(genre):
            genreCard(genre, id: item.id, onFocusChanged: onFocusChanged)
        }
    }

    /// 本专辑 / 最近播放 / 我喜欢:点一首歌时整条列表就是新队列。
    private func songIDs(in tab: TVPlayerShelfTab, fallback: String) -> [String] {
        let ids = (itemsByTab[tab] ?? []).compactMap { item -> String? in
            if case let .song(song) = item { return song.id }
            return nil
        }
        return ids.isEmpty ? [fallback] : ids
    }

    private func songCard(
        _ song: TVSong,
        id: String,
        isCurrent: Bool,
        onFocusChanged: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        TVFocusButton(ring: false, action: action, onFocusChanged: onFocusChanged,
                      focusBinding: $focusedItemID, focusID: id) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVBrowseSongArtwork(song: song, size: cardWidth)
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent { nowPlayingBadge }
                    }
                    .tvFocusRing(focused, radius: 10, scale: 1.04, lift: 0)
                cardText(
                    title: song.title,
                    subtitle: isCurrent ? PMString("ext.tv.nowPlaying.eyebrow") : song.artist,
                    highlighted: isCurrent
                )
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .accessibilityLabel(Text(song.title))
        .accessibilityValue(Text(song.artist))
    }

    private func artistCard(
        _ artist: TVArtist,
        id: String,
        onFocusChanged: @escaping (Bool) -> Void
    ) -> some View {
        let isCurrent = context.artistIDs.contains(artist.id)
        return TVFocusButton(ring: false, action: {
            let ids = store.songs(forArtistID: artist.id).map(\.id)
            if store.playResolvedQueue(songIDs: ids, shuffled: store.shuffleEnabled) { onClose(true) }
        }, onFocusChanged: onFocusChanged, focusBinding: $focusedItemID, focusID: id) { focused in
            VStack(alignment: .leading, spacing: 0) {
                TVArtistArtworkView(artist: artist, size: cardWidth)
                    .tvFocusRing(focused, radius: cardWidth / 2, scale: 1.04, lift: 0)
                cardText(
                    title: artist.name,
                    subtitle: isCurrent ? PMString("ext.tv.nowPlaying.eyebrow")
                        : PMString("ext.tv.songsCount", artist.songCount),
                    highlighted: isCurrent
                )
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .accessibilityLabel(Text(artist.name))
    }

    /// 与专辑卡同一个版式:方形封面位(流派里三张代表封面拼成)、名字、首数。
    private func genreCard(
        _ genre: LibraryGenre,
        id: String,
        onFocusChanged: @escaping (Bool) -> Void
    ) -> some View {
        let isCurrent = genre.id == context.genreID
        return TVFocusButton(ring: false, action: {
            let ids = store.library.songs(forGenre: genre.id).map(\.id)
            if store.playResolvedQueue(songIDs: ids, shuffled: store.shuffleEnabled) { onClose(true) }
        }, onFocusChanged: onFocusChanged, focusBinding: $focusedItemID, focusID: id) { focused in
            VStack(alignment: .leading, spacing: 0) {
                genreMosaic(genre)
                    .tvFocusRing(focused, radius: TVRadius.cover, scale: 1.04, lift: 0)
                cardText(
                    title: genre.name,
                    subtitle: isCurrent ? PMString("ext.tv.nowPlaying.eyebrow")
                        : PMString("ext.tv.songsCount", genre.songCount),
                    highlighted: isCurrent
                )
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .accessibilityLabel(Text(genre.name))
    }

    /// 左边一张大封面,右边上下两张小的;不够三张就用流派名的首字补位。
    private func genreMosaic(_ genre: LibraryGenre) -> some View {
        let songs = genre.representativeSongIDs.prefix(3).compactMap { store.song($0) }
        let gap: CGFloat = 4
        let large = (cardWidth - gap) * 0.62
        let small = (cardWidth - gap) - large
        let half = (cardWidth - gap) / 2
        return HStack(spacing: gap) {
            mosaicTile(songs.first, width: large, height: cardWidth, glyph: String(genre.name.prefix(1)))
            VStack(spacing: gap) {
                mosaicTile(songs.dropFirst().first, width: small, height: half, glyph: nil)
                mosaicTile(songs.dropFirst(2).first, width: small, height: half, glyph: nil)
            }
        }
        .frame(width: cardWidth, height: cardWidth)
        // 占位封面是半透明的,垫一层不透明底,后面播放页的字不会透出来。
        .background(TVColor.bg)
        .clipShape(RoundedRectangle(cornerRadius: TVRadius.cover, style: .continuous))
    }

    @ViewBuilder
    private func mosaicTile(_ song: TVSong?, width: CGFloat, height: CGFloat, glyph: String?) -> some View {
        if let song {
            TVBrowseSongArtwork(song: song, size: max(width, height))
                .frame(width: width, height: height)
                .clipped()
        } else {
            ZStack {
                TVColor.surfaceStrong
                if let glyph {
                    Text(glyph).tvFont(size: 64, weight: .bold, relativeTo: .largeTitle)
                        .foregroundStyle(TVColor.textFaint)
                }
            }
            .frame(width: width, height: height)
        }
    }

    private func cardText(
        title: String,
        subtitle: String,
        highlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .tvFont(.cardTitle)
                .foregroundStyle(TVColor.text)
                .lineLimit(2, reservesSpace: true)
            Text(subtitle)
                .tvFont(.caption, weight: highlighted ? .semibold : .regular)
                .foregroundStyle(highlighted ? TVColor.brand : TVColor.textFaint)
                .lineLimit(1)
        }
        .padding(.top, 12).padding(.horizontal, 2)
        .frame(width: cardWidth, alignment: .leading)
    }

    private var nowPlayingBadge: some View {
        Image(systemName: store.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(TVColor.onBrand)
            .frame(width: 48, height: 48)
            .background(TVColor.brand, in: Circle())
            .padding(10)
            .accessibilityHidden(true)
    }
}
#endif
