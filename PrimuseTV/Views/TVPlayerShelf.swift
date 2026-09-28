#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 播放页底部的快切货架:不离开播放页就能换一张专辑、一位艺术家、一个流派。
/// 顺序按「离正在播放的这首有多近」排:接下来、本专辑、同艺术家,再是整库的
/// 专辑 / 艺术家 / 流派,最后是最近播放和我喜欢。
enum TVPlayerShelfTab: String, CaseIterable, Identifiable, Hashable {
    case upNext
    case thisAlbum
    case artistAlbums
    case albums
    case artists
    case genres
    case recent
    case liked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upNext: return String(localized: "up_next")
        case .thisAlbum: return PMString("ext.tv.player.shelf.thisAlbum")
        case .artistAlbums: return PMString("ext.tv.player.shelf.moreByArtist")
        case .albums: return String(localized: "tab_albums")
        case .artists: return String(localized: "tab_artists")
        case .genres: return String(localized: "tab_genres")
        case .recent: return String(localized: "recently_played")
        case .liked: return String(localized: "sidebar_liked_songs")
        }
    }
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

/// 货架内容。打开货架和换歌时算一次,不放进 body:播放进度每跳一下播放页都会重算,
/// 整库专辑 / 艺术家列表不该跟着一遍遍过。
struct TVPlayerShelfContent {
    var items: [TVPlayerShelfTab: [TVPlayerShelfItem]] = [:]
    /// 本专辑 / 最近播放 / 我喜欢:点一首歌时整条列表就是新队列。
    var songIDs: [TVPlayerShelfTab: [String]] = [:]
    /// 每一栏里「正在播放的那一项」,打开时焦点先落在它上面。
    var currentItemIDs: [TVPlayerShelfTab: String] = [:]
    var artistIDs: Set<String> = []
    var genreID: String?

    var availableTabs: [TVPlayerShelfTab] {
        TVPlayerShelfTab.allCases.filter { !(items[$0] ?? []).isEmpty }
    }

    @MainActor
    static func build(store: TVStore) -> TVPlayerShelfContent {
        var content = TVPlayerShelfContent()
        let np = store.nowPlaying
        let currentSongID = store.currentSongID ?? np.songID
        let raw = currentSongID.isEmpty ? nil : store.library.song(id: currentSongID)

        content.items[.upNext] = store.queueUpNextIDs.enumerated().compactMap { offset, id in
            store.song(id).map { TVPlayerShelfItem.queueSong(offset: offset, song: $0) }
        }

        if !np.albumID.isEmpty {
            let songs = store.songs(forAlbum: np.albumID)
            content.items[.thisAlbum] = songs.map(TVPlayerShelfItem.song)
            content.songIDs[.thisAlbum] = songs.map(\.id)
            if let current = songs.first(where: { $0.id == currentSongID }) {
                content.currentItemIDs[.thisAlbum] = TVPlayerShelfItem.song(current).id
            }
        }

        if let raw {
            content.artistIDs = Set(store.library.artistIDs(for: raw))
            if let genre = raw.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
                content.genreID = LibraryGenreIndexBuilder.normalizedID(for: genre)
            }
        }
        // 同艺术家:这位艺术家的全部专辑(含正在放的这张),新的在前。
        var seenAlbumIDs = Set<String>()
        var artistAlbums: [TVAlbum] = []
        for artistID in content.artistIDs.sorted() {
            for song in store.songs(forArtistID: artistID) {
                guard seenAlbumIDs.insert(song.albumID).inserted,
                      let album = store.album(song.albumID) else { continue }
                artistAlbums.append(album)
            }
        }
        artistAlbums.sort { lhs, rhs in
            lhs.year != rhs.year ? lhs.year > rhs.year
                : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        content.items[.artistAlbums] = artistAlbums.map(TVPlayerShelfItem.album)

        let albums = store.albums
        content.items[.albums] = albums.map(TVPlayerShelfItem.album)
        if !np.albumID.isEmpty, albums.contains(where: { $0.id == np.albumID }) {
            content.currentItemIDs[.albums] = "a#\(np.albumID)"
            content.currentItemIDs[.artistAlbums] = "a#\(np.albumID)"
        }

        let artists = store.artists
        content.items[.artists] = artists.map(TVPlayerShelfItem.artist)
        if let current = artists.first(where: { content.artistIDs.contains($0.id) }) {
            content.currentItemIDs[.artists] = TVPlayerShelfItem.artist(current).id
        }

        let genres = store.library.visibleGenres
        content.items[.genres] = genres.map(TVPlayerShelfItem.genre)
        if let genreID = content.genreID, genres.contains(where: { $0.id == genreID }) {
            content.currentItemIDs[.genres] = "g#\(genreID)"
        }

        let recent = store.recentlyPlayed
        content.items[.recent] = recent.map(TVPlayerShelfItem.song)
        content.songIDs[.recent] = recent.map(\.id)

        let liked = store.library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID)
            .compactMap { store.song($0.id) }
        content.items[.liked] = liked.map(TVPlayerShelfItem.song)
        content.songIDs[.liked] = liked.map(\.id)
        return content
    }
}

struct TVPlayerShelf: View {
    @Environment(TVStore.self) private var store
    @Binding var tab: TVPlayerShelfTab
    /// 开始播放后收起货架(`true`),或者按 Menu 直接收起(`false`)。
    var onClose: (_ startedPlayback: Bool) -> Void
    var onInteraction: () -> Void = {}

    @State private var content = TVPlayerShelfContent()
    @State private var hasLoaded = false
    @State private var renderedCount = TVLongListPagingPolicy.pageSize
    @FocusState private var focusedItemID: String?
    @FocusState private var focusedTabID: String?

    private let cardWidth: CGFloat = 220
    /// 横向 ScrollView 竖直方向会吃满剩余高度,得给定行高,货架才贴在屏幕底部。
    /// 封面 + 两行标题 + 一行副标题,再加焦点放大留的上下边。
    private var rowHeight: CGFloat { cardWidth + 160 }

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
            content = TVPlayerShelfContent.build(store: store)
            let available = content.availableTabs
            if !available.contains(tab), let first = available.first { tab = first }
            guard !hasLoaded else { return }
            hasLoaded = true
            renderedCount = initialRenderedCount(for: tab)
            await Task.yield()
            focusedItemID = content.currentItemIDs[tab] ?? content.items[tab]?.first?.id
        }
        .onChange(of: tab) { _, newTab in
            renderedCount = initialRenderedCount(for: newTab)
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

    // MARK: 分栏

    private var tabRow: some View {
        HStack(spacing: 10) {
            ForEach(content.availableTabs) { item in
                // 和顶栏一样:焦点横移到哪一栏就显示哪一栏,不必再按确认(见 focusedTabID)。
                TVFocusButton(radius: 16, scale: 1.04, lift: 0, ring: false, action: {
                    tab = item
                }, focusBinding: $focusedTabID, focusID: item.rawValue) { focused in
                    Text(item.title)
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
        let items = content.items[tab] ?? []
        let shown = TVLongListPagingPolicy.clamped(limit: renderedCount, totalCount: items.count)
        if !hasLoaded {
            Color.clear.frame(height: rowHeight)
        } else if items.isEmpty {
            Text(PMString("ext.tv.player.shelf.empty"))
                .tvFont(.body)
                .foregroundStyle(TVColor.textFaint)
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 34) {
                        ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { index, item in
                            card(item) { focused in
                                guard focused else { return }
                                renderedCount = TVLongListPagingPolicy.limit(
                                    after: shown, focusedRow: index, totalCount: items.count
                                )
                            }
                            .id(item.id)
                        }
                    }
                    // 焦点放大和描边要有地方画,不然会被横向 ScrollView 裁掉。
                    .padding(.vertical, 22)
                    .padding(.horizontal, 14)
                }
                .scrollClipDisabled()
                .frame(height: rowHeight)
                .onAppear {
                    if let id = content.currentItemIDs[tab] { proxy.scrollTo(id, anchor: .leading) }
                }
            }
            .focusSection()
            .id(tab)
            .transition(.opacity)
        }
    }

    private func initialRenderedCount(for tab: TVPlayerShelfTab) -> Int {
        let items = content.items[tab] ?? []
        guard let currentID = content.currentItemIDs[tab],
              let index = items.firstIndex(where: { $0.id == currentID }) else {
            return TVLongListPagingPolicy.pageSize
        }
        return TVLongListPagingPolicy.limit(
            after: TVLongListPagingPolicy.pageSize, focusedRow: index, totalCount: items.count
        )
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
            songCard(song, id: item.id, isCurrent: song.id == store.currentSongID,
                     onFocusChanged: onFocusChanged) {
                if song.id == store.currentSongID {
                    onClose(false)
                } else if store.play(song, in: content.songIDs[tab] ?? [song.id]) {
                    onClose(true)
                }
            }
        case let .album(album):
            TVAlbumCard(
                album: album,
                width: cardWidth,
                subtitleOverride: album.id == store.nowPlaying.albumID
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
        let isCurrent = content.artistIDs.contains(artist.id)
        return TVFocusButton(ring: false, action: {
            let ids = store.songs(forArtistID: artist.id).map(\.id)
            if store.playResolvedQueue(songIDs: ids, shuffled: store.shuffleEnabled) { onClose(true) }
        }, onFocusChanged: onFocusChanged, focusBinding: $focusedItemID, focusID: id) { focused in
            VStack(spacing: 0) {
                TVArtistArtworkView(artist: artist, size: cardWidth - 20)
                    .tvFocusRing(focused, radius: (cardWidth - 20) / 2, scale: 1.05, lift: 0)
                    .padding(.horizontal, 10)
                cardText(
                    title: artist.name,
                    subtitle: isCurrent ? PMString("ext.tv.nowPlaying.eyebrow")
                        : PMString("ext.tv.songsCount", artist.songCount),
                    highlighted: isCurrent,
                    alignment: .center
                )
            }
            .frame(width: cardWidth)
        }
        .accessibilityLabel(Text(artist.name))
    }

    private func genreCard(
        _ genre: LibraryGenre,
        id: String,
        onFocusChanged: @escaping (Bool) -> Void
    ) -> some View {
        let isCurrent = genre.id == content.genreID
        let width = cardWidth * 1.4
        return TVFocusButton(radius: 18, scale: 1.04, lift: 0, action: {
            let ids = store.library.songs(forGenre: genre.id).map(\.id)
            if store.playResolvedQueue(songIDs: ids, shuffled: store.shuffleEnabled) { onClose(true) }
        }, onFocusChanged: onFocusChanged, focusBinding: $focusedItemID, focusID: id) { focused in
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ForEach(genre.representativeSongIDs.prefix(3), id: \.self) { songID in
                        if let song = store.song(songID) {
                            TVBrowseSongArtwork(song: song, size: 82)
                        }
                    }
                }
                .frame(height: 82, alignment: .leading)
                Text(genre.name)
                    .tvFont(.cardTitle)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(2, reservesSpace: true)
                Text(isCurrent ? PMString("ext.tv.nowPlaying.eyebrow")
                     : PMString("ext.tv.songsCount", genre.songCount))
                    .tvFont(.caption, weight: isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? TVColor.brand : TVColor.textMuted)
                    .lineLimit(1)
            }
            .padding(24)
            .frame(width: width, height: cardWidth + 60, alignment: .topLeading)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
        .accessibilityLabel(Text(genre.name))
    }

    private func cardText(
        title: String,
        subtitle: String,
        highlighted: Bool,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title)
                .tvFont(.cardTitle)
                .foregroundStyle(TVColor.text)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            Text(subtitle)
                .tvFont(.caption, weight: highlighted ? .semibold : .regular)
                .foregroundStyle(highlighted ? TVColor.brand : TVColor.textFaint)
                .lineLimit(1)
        }
        .padding(.top, 12).padding(.horizontal, 2)
        .frame(width: cardWidth, alignment: alignment == .center ? .center : .leading)
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
