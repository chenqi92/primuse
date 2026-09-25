import SwiftUI
import PrimuseKit

enum LibrarySection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case recommendations, favorites, playlists, artists, genres, albums, songs, spokenWord, folders, radio, statistics

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .recommendations: return "library_recommendations_title"
        case .favorites: return "library_quick_access"
        case .folders: return "library_browse_folder"
        case .statistics: return "stats_title"
        case .playlists: return "tab_playlists"
        case .artists: return "tab_artists"
        case .genres: return "tab_genres"
        case .albums: return "tab_albums"
        case .songs: return "tab_songs"
        case .spokenWord: return "tab_spoken_word"
        case .radio: return "radio_title"
        }
    }

    var icon: String {
        switch self {
        case .recommendations: return "sparkles"
        case .favorites: return "heart.fill"
        case .folders: return "folder.fill"
        case .statistics: return "chart.bar.fill"
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .genres: return "tag.fill"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        case .spokenWord: return "books.vertical.fill"
        case .radio: return "radio.fill"
        }
    }

    var color: Color {
        switch self {
        case .recommendations: return Color(red: 0.71, green: 0.48, blue: 0.40)
        case .favorites: return .pink
        case .folders: return .orange
        case .statistics: return .green
        case .playlists: return .red
        case .artists: return .pink
        case .genres: return .teal
        case .albums: return .purple
        case .songs: return .blue
        case .spokenWord: return .brown
        case .radio: return .orange
        }
    }

    var localizedTitle: String {
        switch self {
        case .recommendations: return String(localized: "library_recommendations_title")
        case .favorites: return String(localized: "library_quick_access")
        case .folders: return String(localized: "library_browse_folder")
        case .statistics: return String(localized: "stats_title")
        case .playlists: return String(localized: "tab_playlists")
        case .artists: return String(localized: "tab_artists")
        case .genres: return String(localized: "tab_genres")
        case .albums: return String(localized: "tab_albums")
        case .songs: return String(localized: "tab_songs")
        case .spokenWord: return String(localized: "tab_spoken_word")
        case .radio: return String(localized: "radio_title")
        }
    }
}

enum LibraryDisplayConfiguration {
    static let quickAccessLimitKey = "primuse.library.quickAccessLimit.v1"
    static let sectionOrderKey = "primuse.library.sectionOrder.v1"
    static let hiddenSectionsKey = "primuse.library.hiddenSections.v1"

    static let defaultQuickAccessLimit = 5
    static let quickAccessLimitRange = 1...12
    static let defaultSectionOrder: [LibrarySection] = [
        .recommendations,
        .favorites,
        .songs,
        .spokenWord,
        .albums,
        .artists,
        .genres,
        .playlists,
        .folders,
        .radio,
        .statistics,
    ]

    static func normalizedQuickAccessLimit(_ value: Int) -> Int {
        min(max(value, quickAccessLimitRange.lowerBound), quickAccessLimitRange.upperBound)
    }

    static func decodeSectionOrder(_ rawValue: String) -> [LibrarySection] {
        let stored: [LibrarySection]
        if let data = rawValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([LibrarySection].self, from: data) {
            stored = decoded
        } else {
            stored = []
        }

        var seen = Set<LibrarySection>()
        var result = stored.filter { seen.insert($0).inserted }
        for missing in defaultSectionOrder where !seen.contains(missing) {
            guard let defaultIndex = defaultSectionOrder.firstIndex(of: missing) else { continue }
            let insertionIndex = result.firstIndex { section in
                guard let sectionDefaultIndex = defaultSectionOrder.firstIndex(of: section) else {
                    return false
                }
                return sectionDefaultIndex > defaultIndex
            }
            if let insertionIndex {
                result.insert(missing, at: insertionIndex)
            } else {
                result.append(missing)
            }
            seen.insert(missing)
        }
        return result
    }

    static func encodeSectionOrder(_ sections: [LibrarySection]) -> String {
        guard let data = try? JSONEncoder().encode(sections) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeHiddenSections(_ rawValue: String) -> Set<LibrarySection> {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LibrarySection].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    static func encodeHiddenSections(_ sections: Set<LibrarySection>) -> String {
        let ordered = defaultSectionOrder.filter(sections.contains)
        guard let data = try? JSONEncoder().encode(ordered) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func visibleSections(orderRawValue: String, hiddenRawValue: String) -> [LibrarySection] {
        let hidden = decodeHiddenSections(hiddenRawValue)
        return decodeSectionOrder(orderRawValue).filter { !hidden.contains($0) }
    }
}

enum LibraryDeepLink: Equatable, Sendable {
    case root
    case section(LibrarySection)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case song(String)
}

typealias LibraryPinKind = QuickAccessPinKind
typealias LibraryPinReference = QuickAccessPinReference

enum LibraryPinStorage {
    static let defaultsKey = "primuse.library.quickAccess.v1"
    static let likedSongsPin = LibraryPinReference(
        kind: .playlist,
        itemID: MusicLibrary.likedSongsPlaylistID
    )

    static func decode(
        _ rawValue: String,
        maximumCount: Int = LibraryDisplayConfiguration.defaultQuickAccessLimit
    ) -> [LibraryPinReference] {
        QuickAccessPinStorageCodec.decode(
            rawValue,
            defaultPins: [likedSongsPin],
            maximumCount: LibraryDisplayConfiguration.normalizedQuickAccessLimit(maximumCount)
        )
    }

    static func encode(
        _ pins: [LibraryPinReference],
        maximumCount: Int = LibraryDisplayConfiguration.defaultQuickAccessLimit
    ) -> String {
        QuickAccessPinStorageCodec.encode(
            pins,
            maximumCount: LibraryDisplayConfiguration.normalizedQuickAccessLimit(maximumCount)
        )
    }

    /// Artist IDs changed key once (case/width/diacritic folding). A pinned
    /// artist follows its new ID; the legacy pin is kept so nothing the user
    /// chose disappears. Storage is rewritten at the widest configured limit,
    /// the display limit still applies when the page decodes it.
    @discardableResult
    static func migrateArtistIdentities(
        renames: [String: String],
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !renames.isEmpty else { return false }
        let rawValue = defaults.string(forKey: defaultsKey) ?? ""
        guard !rawValue.isEmpty else { return false }
        let ceiling = LibraryDisplayConfiguration.quickAccessLimitRange.upperBound
        let pins = decode(rawValue, maximumCount: ceiling)
        var existingArtistIDs = Set(
            pins.filter { $0.kind == .artist }.map(\.itemID)
        )

        var updated: [LibraryPinReference] = []
        updated.reserveCapacity(pins.count)
        var changed = false
        for pin in pins {
            updated.append(pin)
            guard pin.kind == .artist,
                  let currentID = renames[pin.itemID],
                  !existingArtistIDs.contains(currentID) else { continue }
            existingArtistIDs.insert(currentID)
            updated.append(LibraryPinReference(kind: .artist, itemID: currentID))
            changed = true
        }
        guard changed else { return false }
        defaults.set(encode(updated, maximumCount: ceiling), forKey: defaultsKey)
        return true
    }
}

private struct LibraryArtworkPreviewSelection: Sendable {
    var revision = ""
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var radioStations: [RadioStation] = []
    var albumFallbackSongs: [String: [Song]] = [:]
    var artistFallbackSongs: [String: [Song]] = [:]
}

@MainActor
private final class LibraryArtworkPreviewSessionStore {
    private struct InFlight {
        let build: SessionStableSnapshotBuild
        let task: Task<LibraryArtworkPreviewSelection, Never>
    }

    static let shared = LibraryArtworkPreviewSessionStore()

    private var cache = SessionStableSnapshotCache<LibraryArtworkPreviewSelection>()
    private var inFlight: InFlight?

    func cachedSelection(for revision: String) -> LibraryArtworkPreviewSelection? {
        cache.cachedValue(for: revision)
    }

    func invalidateForManualRefresh() {
        cache.invalidateForManualRefresh()
        inFlight?.task.cancel()
    }

    func selection(
        for revision: String,
        build: @escaping @Sendable (String) -> LibraryArtworkPreviewSelection
    ) async -> LibraryArtworkPreviewSelection? {
        if let cached = cache.cachedValue(for: revision) {
            return cached
        }

        let operation: InFlight
        if let current = inFlight,
           current.build.revision == revision,
           cache.isCurrentBuild(current.build) {
            operation = current
        } else if let current = inFlight {
            current.task.cancel()
            _ = await current.task.value
            guard !Task.isCancelled else { return nil }
            if inFlight?.build == current.build {
                inFlight = nil
            }
            return await selection(for: revision, build: build)
        } else {
            let buildContext = cache.beginBuild(for: revision)
            operation = InFlight(
                build: buildContext,
                task: Task.detached(priority: .utility) {
                    build(buildContext.randomSeed)
                }
            )
            inFlight = operation
        }

        let value = await operation.task.value
        let accepted = cache.commit(value, for: operation.build)
        if inFlight?.build == operation.build {
            inFlight = nil
        }
        if accepted { return value }
        return cache.cachedValue(for: revision)
    }
}

private enum LibraryArtworkPreviewBuilder {
    static func hasReference(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func songHasArtworkHint(_ song: Song) -> Bool {
        hasReference(song.coverArtFileName)
            || (song.sourceID == AppleMusicLibraryIdentity.sourceID && !song.filePath.isEmpty)
    }

    static func select<Item>(
        _ items: [Item],
        maximumCount: Int = 3,
        randomSeed: String,
        id: (Item) -> String,
        hasArtworkHint: (Item) -> Bool
    ) -> [Item] {
        let selectedIDs = LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: items.map {
                LibraryArtworkPreviewCandidate(
                    id: id($0),
                    hasArtworkHint: hasArtworkHint($0)
                )
            },
            maximumCount: maximumCount,
            randomSeed: randomSeed
        )
        let itemsByID = Dictionary(items.map { (id($0), $0) }) { first, _ in first }
        return selectedIDs.compactMap { itemsByID[$0] }
    }
}

/// 资料库浏览区的一段: 要么是整幅的「快速访问」货架, 要么是一串等高的分类入口。
private struct LibraryBrowseRun: Identifiable {
    let id: String
    let isQuickAccess: Bool
    let sections: [LibrarySection]
}

struct LibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(RadioStationsStore.self) private var radioStationsStore
    #if os(iOS)
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.pmHeightClass) private var heightClass
    #endif
    @Binding private var deepLink: LibraryDeepLink?
    private let rootSection: LibrarySection?
    private let onActiveSectionChange: (LibrarySection?) -> Void
    @State private var navigationPath = NavigationPath()
    /// 资料库这一层导航栈的 zoom 命名空间。
    @Namespace private var libraryZoomNamespace
    @State private var songLocationRequest: SongLibraryLocationRequest?
    @State private var didRestorePersistedPage = false
    @State private var showQuickAccessEditor = false
    @AppStorage("primuse.navigation.libraryPage.v1")
    private var persistedPageID = ""
    @AppStorage(LibraryPinStorage.defaultsKey)
    private var quickAccessRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.quickAccessLimitKey)
    private var configuredQuickAccessLimit = LibraryDisplayConfiguration.defaultQuickAccessLimit
    @AppStorage(LibraryDisplayConfiguration.sectionOrderKey)
    private var sectionOrderRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.hiddenSectionsKey)
    private var hiddenSectionsRawValue = ""
    @AppStorage(QuickAccessCoverStyle.storageKey) private var quickAccessCoverStyle = QuickAccessCoverStyle.automatic
    @State private var artworkPreviewSelection = LibraryArtworkPreviewSelection()

    private var songs: [Song] { library.visibleSongs }
    private var albums: [Album] { library.visibleAlbums }
    private var artists: [Artist] { library.visibleArtists }
    private var genres: [LibraryGenre] { library.visibleGenres }
    private var regularPlaylists: [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }
    private var hasContent: Bool {
        !songs.isEmpty
            || !albums.isEmpty
            || !artists.isEmpty
            || !regularPlaylists.isEmpty
            || !library.smartPlaylists.isEmpty
            || !radioStationsStore.stations.isEmpty
    }
    private var storedPins: [LibraryPinReference] {
        LibraryPinStorage.decode(quickAccessRawValue, maximumCount: quickAccessLimit)
    }
    private var visiblePins: [LibraryPinReference] {
        storedPins.filter(pinExists)
    }
    private var likedPlaylist: Playlist {
        library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
            ?? Playlist(
                id: MusicLibrary.likedSongsPlaylistID,
                name: String(localized: "playlist_liked_name")
            )
    }
    private var quickAccessLimit: Int {
        LibraryDisplayConfiguration.normalizedQuickAccessLimit(configuredQuickAccessLimit)
    }
    private var visibleLibrarySections: [LibrarySection] {
        LibraryDisplayConfiguration.visibleSections(
            orderRawValue: sectionOrderRawValue,
            hiddenRawValue: hiddenSectionsRawValue
        )
        // 「有声内容」只在真的有的时候出现: 绝大多数曲库一本有声书也没有,
        // 给它们摆一个永远空着的入口是噪音。
        .filter { $0 != .spokenWord || !library.spokenWordSongs.isEmpty }
    }
    private var artworkPreviewRevision: String {
        // 电台部分用存储里缓存的摘要：这个属性一次刷新要被求值好几遍，
        // 原来每遍都把上千个台逐个拼成一长串，再拿长串去比较。
        let radioSignature = radioStationsStore.artworkRevision
        return [
            String(library.visibleSongCollectionRevision),
            String(library.albumArtworkLookupRevision),
            String(library.sourceSyncCompletionRevision),
            String(library.playlistCollectionRevision),
            String(library.artworkOverrideRevision),
            quickAccessRawValue,
            radioSignature,
        ].joined(separator: "#")
    }

    init(
        deepLink: Binding<LibraryDeepLink?> = .constant(nil),
        rootSection: LibrarySection? = nil,
        onActiveSectionChange: @escaping (LibrarySection?) -> Void = { _ in }
    ) {
        self._deepLink = deepLink
        self.rootSection = rootSection
        self.onActiveSectionChange = onActiveSectionChange
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
            .navigationTitle(rootSection?.title ?? "library_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            #if os(iOS)
            .minimalNavigationRoot()
            #endif
            .navigationDestination(for: LibrarySection.self) { section in
                sectionDestination(section)
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
                    .mediaZoomDestination(.album, id: album.id)
                    .onAppear {
                        persistedPageID = "album:\(album.id)"
                        onActiveSectionChange(.albums)
                    }
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(artist: artist)
                    .mediaZoomDestination(.artist, id: artist.id)
                    .onAppear {
                        persistedPageID = "artist:\(artist.id)"
                        onActiveSectionChange(.artists)
                    }
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
                    .mediaZoomDestination(.playlist, id: playlist.id)
                    .onAppear {
                        persistedPageID = "playlist:\(playlist.id)"
                        onActiveSectionChange(.playlists)
                    }
            }
            .onAppear {
                sanitizeStoredPins()
                if deepLink == nil, rootSection == nil {
                    restorePersistedPageIfNeeded()
                } else {
                    applyDeepLink(deepLink)
                }
            }
            .onChange(of: deepLink) { _, newValue in
                applyDeepLink(newValue)
            }
            .onChange(of: navigationPath.count) { _, count in
                if didRestorePersistedPage && count == 0 {
                    persistedPageID = ""
                    onActiveSectionChange(nil)
                }
            }
            .task(id: library.visibleSongCollectionRevision) {
                let version = SongListSnapshotVersion(
                    collectionRevision: library.visibleSongCollectionRevision,
                    replacementToken: library.songReplacementToken
                )
                let songsSnapshot = library.visibleSongs
                guard !songsSnapshot.isEmpty else { return }
                do {
                    // Coalesce scanner bursts, then prepare the default order
                    // while the user is still on the library hub. SongListView
                    // reuses the same in-flight/cached snapshot on navigation.
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await SongListSnapshotStore.shared.snapshot(
                    scopeKey: SongListSnapshotStore.libraryScopeKey,
                    version: version,
                    order: .title,
                    songs: songsSnapshot
                )
            }
            .sheet(isPresented: $showQuickAccessEditor) {
                LibraryQuickAccessEditor(
                    pinsRawValue: $quickAccessRawValue,
                    maximumCount: quickAccessLimit
                )
            }
        }
        .mediaZoomNamespace(libraryZoomNamespace)
    }

    @ViewBuilder
    private var rootContent: some View {
        if let rootSection {
            destination(for: rootSection)
        } else if hasContent {
            libraryHub
        } else {
            emptyLibraryState
        }
    }

    private func sectionDestination(_ section: LibrarySection) -> some View {
        destination(for: section)
            .navigationTitle(section.title)
            .toolbarTitleDisplayMode(.inline)
            #if os(iOS)
            .minimalNavigationRoot()
            .navigationBarBackButtonHidden(appNavigationMode == .minimal)
            #endif
            .onAppear {
                persistedPageID = "section:\(section.rawValue)"
                onActiveSectionChange(section)
            }
    }

    private var libraryHub: some View {
        let previewRevision = artworkPreviewRevision
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                browseLibrarySection
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .task(id: previewRevision) {
            await refreshArtworkPreviews(for: previewRevision)
        }
        .refreshable {
            LibraryArtworkPreviewSessionStore.shared.invalidateForManualRefresh()
            artworkPreviewSelection = LibraryArtworkPreviewSelection()
            await refreshArtworkPreviews(for: artworkPreviewRevision)
        }
        .onAppear {
            if navigationPath.isEmpty {
                onActiveSectionChange(nil)
            }
        }
    }

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("library_quick_access") {
                Button("edit") {
                    showQuickAccessEditor = true
                }
                .font(.subheadline.weight(.medium))
            }

            if usesMinimalSectionControls {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)],
                    alignment: .leading,
                    spacing: 24
                ) {
                    quickAccessItems
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        quickAccessItems
                    }
                    .padding(.horizontal, 16)
                }
                .pmStopsAtVerticalBar()
                .contentMargins(.horizontal, 0, for: .scrollContent)
            }
        }
    }

    private var quickAccessItems: some View {
        Group {
            ForEach(visiblePins) { pin in
                pinnedItemCard(pin)
            }

            Button {
                showQuickAccessEditor = true
            } label: {
                addQuickAccessLabel
            }
            .buttonStyle(.plain)
        }
    }

    /// 手机横屏 (纵向紧凑) 下分类入口排两列。Mac 没有纵向尺寸等级, 恒为 false。
    private var usesCompactBrowseLayout: Bool {
        #if os(iOS)
        heightClass.isCompact
        #else
        false
        #endif
    }

    /// 分类入口的列数。竖屏与 iPad 仍是一列(与原来的竖排完全一致); 手机横屏下
    /// 行宽有 700 多点, 一列只放得下一张 72pt 高的卡片, 右边整片空着。
    private var browseCategoryColumns: [GridItem] {
        usesCompactBrowseLayout
            ? [GridItem(.adaptive(minimum: 300), spacing: 0, alignment: .top)]
            : [GridItem(.flexible())]
    }

    private var browseLibrarySection: some View {
        Group {
            if !visibleLibrarySections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("library_browse")

                    LazyVStack(spacing: 10) {
                        ForEach(browseRuns) { run in
                            if run.isQuickAccess {
                                quickAccessSection
                                    .padding(.vertical, 8)
                            } else {
                                LazyVGrid(columns: browseCategoryColumns, spacing: 10) {
                                    ForEach(run.sections) { section in
                                        NavigationLink(value: section) {
                                            libraryCategoryRow(section)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 把连续的分类入口并成一段, 让它们共用一个网格。
    ///
    /// 「快速访问」不是等高的入口卡片, 而是一条整幅的横向货架 —— 混进两列网格
    /// 会把它所在的那一行撑到两百多点, 旁边的入口卡片跟着被吊在半空。所以货架
    /// 始终独占一行, 只有入口卡片进网格; 用户排的分区顺序不变。
    private var browseRuns: [LibraryBrowseRun] {
        var runs: [LibraryBrowseRun] = []
        var pending: [LibrarySection] = []

        func flushPending() {
            guard let first = pending.first else { return }
            runs.append(LibraryBrowseRun(
                id: "categories:\(first.rawValue)",
                isQuickAccess: false,
                sections: pending
            ))
            pending.removeAll()
        }

        for section in visibleLibrarySections {
            if section == .favorites {
                flushPending()
                runs.append(LibraryBrowseRun(
                    id: "quickAccess",
                    isQuickAccess: true,
                    sections: []
                ))
            } else {
                pending.append(section)
            }
        }
        flushPending()
        return runs
    }

    private func sectionHeader<Trailing: View>(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(titleKey)
                .font(.title3.weight(.bold))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
    }

    private func sectionHeader(_ titleKey: LocalizedStringKey) -> some View {
        sectionHeader(titleKey) {
            EmptyView()
        }
    }

    private func likedArtwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.pink, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .pink.opacity(0.18), radius: 8, y: 4)
    }

    private func quickAccessLabel<Artwork: View>(
        title: String,
        subtitle: String,
        @ViewBuilder artwork: @escaping (CGFloat) -> Artwork
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if usesMinimalSectionControls {
                GeometryReader { geometry in
                    artwork(geometry.size.width)
                }
                .aspectRatio(1, contentMode: .fit)
            } else {
                artwork(116)
                    .frame(width: 116, height: 116)
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(usesMinimalSectionControls ? 2 : 1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: usesMinimalSectionControls ? nil : 116, alignment: .leading)
        .frame(maxWidth: usesMinimalSectionControls ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var addQuickAccessLabel: some View {
        quickAccessLabel(
            title: String(localized: "library_add_quick_access"),
            subtitle: "\(visiblePins.count)/\(quickAccessLimit)"
        ) { size in
            ZStack {
                RoundedRectangle(cornerRadius: quickAccessCoverStyle == .circle ? size / 2 : 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
                RoundedRectangle(cornerRadius: quickAccessCoverStyle == .circle ? size / 2 : 16, style: .continuous)
                    .stroke(
                        Color.secondary.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func pinnedItemCard(_ pin: LibraryPinReference) -> some View {
        switch pin.kind {
        case .album:
            if let album = library.visibleAlbum(id: pin.itemID) {
                NavigationLink(value: album) {
                    quickAccessLabel(
                        title: album.title,
                        subtitle: album.artistName ?? String(localized: "unknown_artist")
                    ) { size in
                        QuickAccessArtworkView(item: .album(album), size: size, cornerRadius: 16) {
                            libraryAlbumArtwork(album, size: size, cornerRadius: 16, showsPlaceholder: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .mediaZoomSource(.album, id: album.id)
            }
        case .artist:
            if let artist = library.visibleArtist(id: pin.itemID) {
                NavigationLink(value: artist) {
                    quickAccessLabel(
                        title: artist.name,
                        subtitle: countText(artist.albumCount, unitKey: "albums_count")
                    ) { size in
                        QuickAccessArtworkView(item: .artist(artist), size: size, cornerRadius: 16) {
                            libraryArtistArtwork(artist, size: size, cornerRadius: size / 2, showsPlaceholder: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .mediaZoomSource(.artist, id: artist.id)
            }
        case .playlist:
            if pin.itemID == MusicLibrary.likedSongsPlaylistID {
                NavigationLink(value: likedPlaylist) {
                    quickAccessLabel(
                        title: String(localized: "sidebar_liked_songs"),
                        subtitle: countText(
                            library.songCount(forPlaylist: MusicLibrary.likedSongsPlaylistID),
                            unitKey: "songs_count"
                        )
                    ) { size in
                        QuickAccessArtworkView(item: .playlist(likedPlaylist), size: size, cornerRadius: 16) {
                            likedArtwork(size: size, cornerRadius: 16)
                        }
                    }
                }
                .buttonStyle(.plain)
                .mediaZoomSource(.playlist, id: likedPlaylist.id)
            } else if let playlist = regularPlaylists.first(where: { $0.id == pin.itemID }) {
                NavigationLink(value: playlist) {
                    quickAccessLabel(
                        title: playlist.name,
                        subtitle: countText(
                            library.songCount(forPlaylist: playlist.id),
                            unitKey: "songs_count"
                        )
                    ) { size in
                        QuickAccessArtworkView(item: .playlist(playlist), size: size, cornerRadius: 16) {
                            playlistArtwork(playlist, size: size, cornerRadius: 16)
                        }
                    }
                }
                .buttonStyle(.plain)
                .mediaZoomSource(.playlist, id: playlist.id)
            }
        }
    }

    private func libraryCategoryRow(_ section: LibrarySection) -> some View {
        HStack(spacing: 13) {
            Image(systemName: section.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(categoryCountText(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            categoryPreview(section)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 72)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func categoryPreview(_ section: LibrarySection) -> some View {
        switch section {
        case .favorites, .folders, .statistics:
            EmptyView()
        case .recommendations:
            overlappingPreview(previewSongs) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .songs:
            overlappingPreview(previewSongs) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .spokenWord:
            overlappingPreview(Array(library.spokenWordSongs.prefix(3))) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .albums:
            artworkPreview(
                previewAlbums,
                placeholderIcon: "square.stack",
                cornerRadius: 7
            ) { album in
                libraryAlbumArtwork(
                    album,
                    size: 36,
                    cornerRadius: 7,
                    showsPlaceholder: false
                )
            }
        case .artists:
            artworkPreview(
                previewArtists,
                placeholderIcon: "music.mic",
                cornerRadius: 18
            ) { artist in
                libraryArtistArtwork(
                    artist,
                    size: 36,
                    cornerRadius: 18,
                    showsPlaceholder: false
                )
            }
        case .genres:
            overlappingPreview(previewGenreSongs) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .playlists:
            overlappingPreview(previewPlaylists) { playlist in
                playlistArtwork(playlist, size: 36, cornerRadius: 7)
            }
        case .radio:
            overlappingPreview(previewRadioStations) { station in
                RadioStationArtworkView(station: station, size: 36, cornerRadius: 7)
            }
        }
    }

    private var hasCurrentArtworkPreviewSelection: Bool {
        artworkPreviewSelection.revision == artworkPreviewRevision
    }

    private var previewSongs: [Song] {
        hasCurrentArtworkPreviewSelection
            ? artworkPreviewSelection.songs
            : Array(songs.prefix(3))
    }

    private var previewAlbums: [Album] {
        hasCurrentArtworkPreviewSelection
            ? artworkPreviewSelection.albums
            : Array(albums.prefix(3))
    }

    private var previewArtists: [Artist] {
        hasCurrentArtworkPreviewSelection
            ? artworkPreviewSelection.artists
            : Array(artists.prefix(3))
    }

    private var previewGenreSongs: [Song] {
        genres.prefix(3).compactMap { genre in
            genre.representativeSongIDs.lazy.compactMap { library.visibleSong(id: $0) }.first
        }
    }

    private var previewPlaylists: [Playlist] {
        hasCurrentArtworkPreviewSelection
            ? artworkPreviewSelection.playlists
            : Array(regularPlaylists.prefix(3))
    }

    private var previewRadioStations: [RadioStation] {
        hasCurrentArtworkPreviewSelection
            ? artworkPreviewSelection.radioStations
            : Array(radioStationsStore.stations.prefix(3))
    }

    private func albumFallbackSongs(_ album: Album) -> [Song] {
        if hasCurrentArtworkPreviewSelection {
            return artworkPreviewSelection.albumFallbackSongs[album.id] ?? []
        }
        return library.preferredArtworkSong(forAlbumID: album.id).map { [$0] } ?? []
    }

    private func artistFallbackSongs(_ artist: Artist) -> [Song] {
        guard hasCurrentArtworkPreviewSelection else { return [] }
        return artworkPreviewSelection.artistFallbackSongs[artist.id] ?? []
    }

    private func libraryAlbumArtwork(
        _ album: Album,
        size: CGFloat,
        cornerRadius: CGFloat,
        showsPlaceholder: Bool
    ) -> some View {
        ZStack {
            if showsPlaceholder {
                artworkPlaceholder(
                    size: size,
                    cornerRadius: cornerRadius,
                    icon: "square.stack"
                )
            }

            ForEach(Array(albumFallbackSongs(album).reversed())) { song in
                fallbackSongArtwork(song, size: size)
            }

            AlbumArtworkView(
                album: album,
                size: size,
                cornerRadius: cornerRadius,
                showsPlaceholder: false
            )
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func libraryArtistArtwork(
        _ artist: Artist,
        size: CGFloat,
        cornerRadius: CGFloat,
        showsPlaceholder: Bool
    ) -> some View {
        ZStack {
            if showsPlaceholder {
                artworkPlaceholder(
                    size: size,
                    cornerRadius: cornerRadius,
                    icon: "music.mic"
                )
            }

            ForEach(Array(artistFallbackSongs(artist).reversed())) { song in
                fallbackSongArtwork(song, size: size)
            }

            ArtistArtworkView(
                artist: artist,
                size: size,
                cornerRadius: cornerRadius,
                showsPlaceholder: false
            )
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func artworkPlaceholder(
        size: CGFloat,
        cornerRadius: CGFloat,
        icon: String
    ) -> some View {
        CachedArtworkView(
            coverRef: nil,
            songID: nil,
            size: size,
            cornerRadius: cornerRadius,
            placeholderIcon: icon,
            showsPlaceholder: true
        )
    }

    private func fallbackSongArtwork(_ song: Song, size: CGFloat) -> some View {
        CachedArtworkView(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: size,
            cornerRadius: 0,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat,
            showsPlaceholder: false
        )
    }

    private func overlappingPreview<Item: Identifiable, Content: View>(
        _ items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        HStack(spacing: -10) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
            } else {
                ForEach(items) { item in
                    content(item)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
            }
        }
        .frame(width: 68, alignment: .trailing)
    }

    private func artworkPreview<Item: Identifiable, Content: View>(
        _ items: [Item],
        placeholderIcon: String,
        cornerRadius: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        ZStack(alignment: .trailing) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                Image(systemName: placeholderIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 36, height: 36)

            HStack(spacing: -10) {
                ForEach(items) { item in
                    content(item)
                }
            }
        }
        .frame(width: 68, height: 36, alignment: .trailing)
    }

    @ViewBuilder
    private func playlistArtwork(_ playlist: Playlist, size: CGFloat, cornerRadius: CGFloat) -> some View {
        PlaylistArtworkView(playlist: playlist, size: size, cornerRadius: cornerRadius)
    }

    @MainActor
    private func refreshArtworkPreviews(for revision: String) async {
        if artworkPreviewSelection.revision == revision { return }
        if let cached = LibraryArtworkPreviewSessionStore.shared.cachedSelection(
            for: revision
        ) {
            artworkPreviewSelection = cached
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(280))
        } catch {
            return
        }
        guard !Task.isCancelled, artworkPreviewRevision == revision else { return }
        let songsSnapshot = songs
        let albumsSnapshot = albums
        let artistsSnapshot = artists
        let playlistsSnapshot = regularPlaylists
        let radioSnapshot = radioStationsStore.stations
        let pinnedAlbumIDs = Set(visiblePins.compactMap { pin in
            pin.kind == .album ? pin.itemID : nil
        })
        let pinnedArtistIDs = Set(visiblePins.compactMap { pin in
            pin.kind == .artist ? pin.itemID : nil
        })

        let albumOverrideIDs = Set(albumsSnapshot.compactMap { album -> String? in
            let presentation = library.artworkPresentation(
                for: LibraryArtworkOwner(kind: .album, id: album.id)
            )
            return presentation.uploadedContentID != nil || presentation.selectedSong != nil
                ? album.id
                : nil
        })
        let artistOverrideIDs = Set(artistsSnapshot.compactMap { artist -> String? in
            let presentation = library.artworkPresentation(
                for: LibraryArtworkOwner(kind: .artist, id: artist.id)
            )
            return presentation.uploadedContentID != nil || presentation.selectedSong != nil
                ? artist.id
                : nil
        })
        let playlistOverrideIDs = Set(playlistsSnapshot.compactMap { playlist -> String? in
            let presentation = library.artworkPresentation(
                for: LibraryArtworkOwner(kind: .playlist, id: playlist.id)
            )
            return presentation.uploadedContentID != nil || presentation.selectedSong != nil
                ? playlist.id
                : nil
        })
        let playlistIDsWithMemberArtworkHint = Set(playlistsSnapshot.compactMap { playlist -> String? in
            library.songs(forPlaylist: playlist.id).contains(
                where: LibraryArtworkPreviewBuilder.songHasArtworkHint
            ) ? playlist.id : nil
        })

        let selection = await LibraryArtworkPreviewSessionStore.shared.selection(
            for: revision
        ) { randomSeed in
            let songsWithArtworkHint = songsSnapshot.filter(
                LibraryArtworkPreviewBuilder.songHasArtworkHint
            )
            let albumIDsWithSongArtworkHint = Set(songsWithArtworkHint.compactMap(\.albumID))
            let artistIDsWithSongArtworkHint = Set(songsWithArtworkHint.compactMap(\.artistID))

            let selectedSongs = LibraryArtworkPreviewBuilder.select(
                songsSnapshot,
                randomSeed: "\(randomSeed)#songs",
                id: \Song.id,
                hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
            )
            let selectedAlbums = LibraryArtworkPreviewBuilder.select(
                albumsSnapshot,
                randomSeed: "\(randomSeed)#albums",
                id: \Album.id
            ) { album in
                albumOverrideIDs.contains(album.id)
                    || MetadataAssetStore.shared.hasAlbumCover(forAlbumID: album.id)
                    || albumIDsWithSongArtworkHint.contains(album.id)
            }
            let selectedArtists = LibraryArtworkPreviewBuilder.select(
                artistsSnapshot,
                randomSeed: "\(randomSeed)#artists",
                id: \Artist.id
            ) { artist in
                artistOverrideIDs.contains(artist.id)
                    || LibraryArtworkPreviewBuilder.hasReference(artist.thumbnailPath)
                    || MetadataAssetStore.shared.hasArtistImage(forArtistID: artist.id)
                    || artistIDsWithSongArtworkHint.contains(artist.id)
            }
            let selectedPlaylists = LibraryArtworkPreviewBuilder.select(
                playlistsSnapshot,
                randomSeed: "\(randomSeed)#playlists",
                id: \Playlist.id
            ) { playlist in
                playlistOverrideIDs.contains(playlist.id)
                    || (
                        playlist.hasDedicatedCoverArt
                            && LibraryArtworkPreviewBuilder.hasReference(playlist.coverArtPath)
                    )
                    || playlistIDsWithMemberArtworkHint.contains(playlist.id)
            }
            let selectedRadioStations = LibraryArtworkPreviewBuilder.select(
                radioSnapshot,
                randomSeed: "\(randomSeed)#radio",
                id: \RadioStation.id
            ) { station in
                station.logoData.map(ArtworkImageCompatibility.isCompleteImage) == true
                    || LibraryArtworkPreviewBuilder.hasReference(station.logoFileName)
            }

            let fallbackAlbumIDs = pinnedAlbumIDs.union(selectedAlbums.map(\.id))
            let albumGroups = Dictionary(grouping: songsSnapshot.filter { song in
                song.albumID.map(fallbackAlbumIDs.contains) == true
            }) { $0.albumID ?? "" }
            let albumFallbackSongs = albumGroups.mapValues { albumSongs in
                LibraryArtworkPreviewBuilder.select(
                    albumSongs,
                    randomSeed: "\(randomSeed)#album#\(albumSongs.first?.albumID ?? "")",
                    id: \Song.id,
                    hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
                )
            }

            let fallbackArtistIDs = pinnedArtistIDs.union(selectedArtists.map(\.id))
            let artistGroups = Dictionary(grouping: songsSnapshot.filter { song in
                song.artistID.map(fallbackArtistIDs.contains) == true
            }) { $0.artistID ?? "" }
            let artistFallbackSongs = artistGroups.mapValues { artistSongs in
                LibraryArtworkPreviewBuilder.select(
                    artistSongs,
                    randomSeed: "\(randomSeed)#artist#\(artistSongs.first?.artistID ?? "")",
                    id: \Song.id,
                    hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
                )
            }

            return LibraryArtworkPreviewSelection(
                revision: revision,
                songs: selectedSongs,
                albums: selectedAlbums,
                artists: selectedArtists,
                playlists: selectedPlaylists,
                radioStations: selectedRadioStations,
                albumFallbackSongs: albumFallbackSongs,
                artistFallbackSongs: artistFallbackSongs
            )
        }

        guard !Task.isCancelled,
              artworkPreviewRevision == revision,
              let selection else { return }
        artworkPreviewSelection = selection
    }

    private func categoryCountText(_ section: LibrarySection) -> String {
        switch section {
        case .favorites:
            return String(localized: "library_quick_access")
        case .folders:
            return countText(songs.count, unitKey: "songs_count")
        case .statistics:
            return String(localized: "stats_section_label")
        case .recommendations:
            return String(localized: "library_recommendations_subtitle")
        case .songs:
            // 「歌曲」只数音乐,有声内容在有声那一页按书计。
            return countText(library.musicSongs.count, unitKey: "songs_count")
        case .spokenWord:
            return countText(library.spokenWordSongs.count, unitKey: "songs_count")
        case .albums:
            return countText(albums.count, unitKey: "albums_count")
        case .artists:
            return countText(artists.count, unitKey: "artists_count")
        case .genres:
            return countText(genres.count, unitKey: "genres_count")
        case .playlists:
            return countText(
                regularPlaylists.count + library.smartPlaylists.count,
                unitKey: "playlists_count"
            )
        case .radio:
            return countText(radioStationsStore.stations.count, unitKey: "radio_stations_count")
        }
    }

    private func countText(_ count: Int, unitKey: String.LocalizationValue) -> String {
        "\(count.formatted()) \(String(localized: unitKey))"
    }

    private var usesMinimalSectionControls: Bool {
        #if os(iOS)
        appNavigationMode == .minimal
        #else
        false
        #endif
    }

    @ViewBuilder
    private func destination(for section: LibrarySection) -> some View {
        switch section {
        case .favorites:
            ScrollView {
                quickAccessSection
                    .padding(.vertical, 16)
            }
        case .folders:
            HomeFolderManagementView(usesInlineControls: usesMinimalSectionControls)
        case .statistics:
            ListeningStatsView(usesInlineSourcePicker: usesMinimalSectionControls)
        case .recommendations:
            AIRecommendationLibraryView()
        case .songs:
            SongListView(locationRequest: $songLocationRequest)
        case .spokenWord:
            SpokenWordLibraryView()
        case .albums:
            AlbumGridView()
        case .artists:
            ArtistListView(artists: artists)
        case .genres:
            GenreLibraryView()
        case .playlists:
            PlaylistListView()
        case .radio:
            RadioStationsView()
        }
    }

    private var emptyLibraryState: some View {
        ContentUnavailableView {
            Label("welcome_title", systemImage: "music.note.list")
        } description: {
            Text("welcome_desc")
        } actions: {
            // 两个按钮等宽：文案长度不同，让宽度跟着文字走会让它们上下参差。
            // 图标沿用各自在设置页与电台页已有的符号，和上方标题的图标呼应。
            VStack(spacing: 12) {
                manageSourcesButton
                    .buttonStyle(.borderedProminent)

                NavigationLink(value: LibrarySection.radio) {
                    Label("radio_manage", systemImage: "radio")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            // 空状态是整屏留白，不限宽的话按钮在 iPad 与桌面上会拉成一条横杠。
            .frame(maxWidth: 280)
        }
    }

    private var manageSourcesLabel: some View {
        Label(
            "manage_sources",
            systemImage: "externaldrive.connected.to.line.below"
        )
        .frame(maxWidth: .infinity)
    }

    /// iOS 上跳到「设置 › 音乐源」，而不是把音乐源页推进资料库自己的导航栈。
    ///
    /// 这个按钮只活在空状态里，而空状态在扫到第一首歌的那一刻就会被换成资料库
    /// 主页 —— 那时用户正停在被它推出来的音乐源页上。承载 NavigationLink 的视图
    /// 从层级里消失之后，推出去的那一页就成了没有主人的页面，返回键跟着不见，
    /// 用户被困在里面。设置页自己的导航栈根视图不会中途换掉，音乐源页也本来就
    /// 住在那里，所以两个入口（这里和首页）都汇到那一处。
    @ViewBuilder
    private var manageSourcesButton: some View {
        #if os(iOS)
        Button {
            SettingsNavigation.shared.open(SettingsPage.sources.id)
        } label: {
            manageSourcesLabel
        }
        #else
        NavigationLink {
            SourcesContentView()
        } label: {
            manageSourcesLabel
        }
        #endif
    }

    private func pinExists(_ pin: LibraryPinReference) -> Bool {
        switch pin.kind {
        case .album:
            return library.visibleAlbum(id: pin.itemID) != nil
        case .artist:
            return library.visibleArtist(id: pin.itemID) != nil
        case .playlist:
            if pin.itemID == MusicLibrary.likedSongsPlaylistID { return true }
            return regularPlaylists.contains { $0.id == pin.itemID }
        }
    }

    private func sanitizeStoredPins() {
        let sanitized = storedPins.filter(pinExists)
        guard sanitized != storedPins else { return }
        quickAccessRawValue = LibraryPinStorage.encode(
            sanitized,
            maximumCount: quickAccessLimit
        )
    }

    private func applyDeepLink(_ link: LibraryDeepLink?) {
        guard let link else { return }
        didRestorePersistedPage = true
        var path = NavigationPath()
        switch link {
        case .root:
            songLocationRequest = nil
            persistedPageID = ""
            onActiveSectionChange(nil)
        case .section(let section):
            persistedPageID = "section:\(section.rawValue)"
            path.append(section)
            onActiveSectionChange(section)
        case .album(let album):
            path.append(album)
        case .artist(let artist):
            path.append(artist)
        case .playlist(let playlist):
            path.append(playlist)
        case .song(let songID):
            songLocationRequest = SongLibraryLocationRequest(songID: songID)
            persistedPageID = "section:\(LibrarySection.songs.rawValue)"
            path.append(LibrarySection.songs)
        }
        navigationPath = path
        deepLink = nil
    }

    private func restorePersistedPageIfNeeded() {
        guard !didRestorePersistedPage else { return }
        didRestorePersistedPage = true
        var path = NavigationPath()
        if let rawValue = identifier(in: persistedPageID, after: "section:"),
           let section = LibrarySection(rawValue: rawValue),
           visibleLibrarySections.contains(section) {
            path.append(section)
        } else if let itemID = identifier(in: persistedPageID, after: "album:"),
                  let album = albums.first(where: { $0.id == itemID }) {
            path.append(album)
        } else if let itemID = identifier(in: persistedPageID, after: "artist:"),
                  let artist = artists.first(where: { $0.id == itemID }) {
            path.append(artist)
        } else if let itemID = identifier(in: persistedPageID, after: "playlist:") {
            if let playlist = library.playlists.first(where: { $0.id == itemID }) {
                path.append(playlist)
            } else if itemID == MusicLibrary.likedSongsPlaylistID {
                path.append(likedPlaylist)
            } else {
                persistedPageID = ""
                return
            }
        } else {
            persistedPageID = ""
            return
        }
        navigationPath = path
    }

    private func identifier(in value: String, after prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

/// 快捷收藏编辑页里一条已固定项背后的真实对象。解析一次存起来，行渲染时不再
/// 回头去整库里线性查找。
private enum QuickAccessPinTarget: Sendable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

private struct QuickAccessResolvedPin: Identifiable, Sendable {
    let pin: LibraryPinReference
    /// 固定项指向的对象可能已经不在资料库里（源被移除、歌被删）。保留这一行
    /// 但不渲染，`onMove` 的下标才能继续跟 `pins` 对齐。
    let target: QuickAccessPinTarget?
    let matchesQuery: Bool
    var id: String { pin.id }
}

/// 一次整库筛选的产物。这部分放到后台算完再整体交给视图;已固定的那几条则在
/// 主线程同步解析(都是 O(1) 查找),勾选后立刻出现,不用等后台那一轮。
private struct QuickAccessEditorContent: Sendable {
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var playlistSongCounts: [String: Int] = [:]
}

/// 整库筛选的实际工作。写成文件作用域的自由函数，明确不带任何 actor 隔离，
/// 可以直接在后台任务里跑。
private func buildQuickAccessEditorContent(
    pins: [LibraryPinReference],
    albums: [Album],
    artists: [Artist],
    playlists: [Playlist],
    playlistSongCounts: [String: Int],
    query: String
) -> QuickAccessEditorContent {
    let pinnedAlbumIDs = Set(pins.lazy.filter { $0.kind == .album }.map(\.itemID))
    let pinnedArtistIDs = Set(pins.lazy.filter { $0.kind == .artist }.map(\.itemID))
    let pinnedPlaylistIDs = Set(pins.lazy.filter { $0.kind == .playlist }.map(\.itemID))

    return QuickAccessEditorContent(
        albums: QuickAccessCandidatePolicy.filtered(
            albums,
            id: \.id,
            pinnedIDs: pinnedAlbumIDs,
            query: query,
            searchFields: { [$0.title, $0.artistName] }
        ),
        artists: QuickAccessCandidatePolicy.filtered(
            artists,
            id: \.id,
            pinnedIDs: pinnedArtistIDs,
            query: query,
            searchFields: { [$0.name] }
        ),
        playlists: QuickAccessCandidatePolicy.filtered(
            playlists,
            id: \.id,
            pinnedIDs: pinnedPlaylistIDs,
            query: query,
            searchFields: { [$0.name] }
        ),
        playlistSongCounts: playlistSongCounts
    )
}

private struct LibraryQuickAccessEditor: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Binding var pinsRawValue: String
    let maximumCount: Int
    @State private var searchText = ""
    /// 固定列表解码一次就留着。它此前是计算属性，而整库筛选会对每一张专辑 /
    /// 每一位艺术家各读一次 —— 每读一次就是一次 JSON 解码，上万条就是上万次，
    /// 打开这个页面因此明显卡顿。
    @State private var pinState = PinState()
    @State private var content = QuickAccessEditorContent()
    @State private var isBuilding = false

    private struct PinState {
        var rawValue: String?
        var pins: [LibraryPinReference] = []
        var identifiers: Set<LibraryPinReference> = []

        mutating func update(rawValue: String, maximumCount: Int) {
            guard self.rawValue != rawValue else { return }
            self.rawValue = rawValue
            pins = LibraryPinStorage.decode(rawValue, maximumCount: maximumCount)
            identifiers = Set(pins)
        }
    }

    private var pins: [LibraryPinReference] { pinState.pins }

    /// 已固定的那几条(上限个位数)当场解析:专辑与艺术家走资料库的 O(1) 查找,
    /// 歌单只有几十条。放在主线程同步做, 勾选之后这一段立刻更新, 不用等后台
    /// 那一轮整库筛选。顺序与 `pins` 严格一致, `onMove` 的下标才对得上。
    private var resolvedPins: [QuickAccessResolvedPin] {
        pins.map { pin in
            switch pin.kind {
            case .album:
                guard let album = library.visibleAlbum(id: pin.itemID) else {
                    return QuickAccessResolvedPin(pin: pin, target: nil, matchesQuery: false)
                }
                return QuickAccessResolvedPin(
                    pin: pin,
                    target: .album(album),
                    matchesQuery: QuickAccessCandidatePolicy.matches(
                        query: searchText,
                        fields: [album.title, album.artistName]
                    )
                )
            case .artist:
                guard let artist = library.visibleArtist(id: pin.itemID) else {
                    return QuickAccessResolvedPin(pin: pin, target: nil, matchesQuery: false)
                }
                return QuickAccessResolvedPin(
                    pin: pin,
                    target: .artist(artist),
                    matchesQuery: QuickAccessCandidatePolicy.matches(
                        query: searchText,
                        fields: [artist.name]
                    )
                )
            case .playlist:
                let playlist = pin.itemID == MusicLibrary.likedSongsPlaylistID
                    ? likedPlaylist
                    : library.playlists.first(where: { $0.id == pin.itemID })
                guard let playlist else {
                    return QuickAccessResolvedPin(pin: pin, target: nil, matchesQuery: false)
                }
                return QuickAccessResolvedPin(
                    pin: pin,
                    target: .playlist(playlist),
                    matchesQuery: QuickAccessCandidatePolicy.matches(
                        query: searchText,
                        fields: [playlist.name]
                    )
                )
            }
        }
    }

    private var likedPlaylist: Playlist {
        library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
            ?? Playlist(
                id: MusicLibrary.likedSongsPlaylistID,
                name: String(localized: "playlist_liked_name")
            )
    }

    /// 只要输入变了就重算一次。把资料库的两个版本号读进来，资料库在后台扫描
    /// 期间更新时这一页也跟着刷新。
    private var rebuildKey: String {
        [
            String(library.searchRevision),
            String(library.playlistCollectionRevision),
            pinsRawValue,
            searchText,
        ].joined(separator: "\u{1F}")
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty || resolvedPins.contains(where: \.matchesQuery) {
                    Section {
                        if pins.isEmpty {
                            Label("library_quick_access_selected_empty", systemImage: "pin")
                                .foregroundStyle(.secondary)
                        } else if searchText.isEmpty {
                            ForEach(resolvedPins) { resolved in
                                selectedPinRow(resolved)
                            }
                            .onMove(perform: movePins)
                        } else {
                            ForEach(resolvedPins.filter(\.matchesQuery)) { resolved in
                                selectedPinRow(resolved)
                            }
                        }
                    } header: {
                        HStack {
                            Text("library_quick_access_selected")
                            Spacer()
                            Text(verbatim: "\(pins.count)/\(maximumCount)")
                                .monospacedDigit()
                        }
                    } footer: {
                        Text("library_quick_access_limit_description")
                    }
                }

                if isBuilding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("library_quick_access_loading").foregroundStyle(.secondary)
                    }
                }

                if !content.albums.isEmpty {
                    Section("tab_albums") {
                        ForEach(content.albums) { album in
                            pinButton(
                                LibraryPinReference(kind: .album, itemID: album.id)
                            ) {
                                AlbumArtworkView(album: album, size: 42, cornerRadius: 7)
                            } title: {
                                Text(album.title)
                            } subtitle: {
                                Text(album.artistName ?? String(localized: "unknown_artist"))
                            }
                        }
                    }
                }

                if !content.artists.isEmpty {
                    Section("tab_artists") {
                        ForEach(content.artists) { artist in
                            pinButton(
                                LibraryPinReference(kind: .artist, itemID: artist.id)
                            ) {
                                ArtistArtworkView(
                                    artist: artist,
                                    size: 42,
                                    cornerRadius: 21
                                )
                            } title: {
                                Text(artist.name)
                            } subtitle: {
                                Text(verbatim: "\(artist.albumCount) \(String(localized: "albums_count"))")
                            }
                        }
                    }
                }

                if !content.playlists.isEmpty {
                    Section("tab_playlists") {
                        ForEach(content.playlists) { playlist in
                            pinButton(
                                LibraryPinReference(kind: .playlist, itemID: playlist.id)
                            ) {
                                editorPlaylistArtwork(playlist)
                            } title: {
                                Text(playlist.name)
                            } subtitle: {
                                Text(playlistSubtitle(playlist))
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: Text("library_quick_access_search_prompt")
            )
            #else
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("library_quick_access_search_prompt")
            )
            #endif
            .navigationTitle("library_edit_quick_access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(searchText.isEmpty ? .active : .inactive))
            #endif
        }
        .onChange(of: pinsRawValue, initial: true) { _, newValue in
            pinState.update(rawValue: newValue, maximumCount: maximumCount)
        }
        .task(id: rebuildKey) {
            await rebuildContent()
        }
    }

    /// 整库筛选。专辑与艺术家来自资料库已经排好序的集合，歌单来自用户排定的
    /// 顺序 —— 这里一律保持原顺序，既省掉一次 localizedCompare 全表排序，也不会
    /// 把用户排好的歌单顺序又打乱一次。
    private func rebuildContent() async {
        let query = searchText
        let currentPins = LibraryPinStorage.decode(pinsRawValue, maximumCount: maximumCount)
        let albumsSnapshot = library.visibleAlbums
        let artistsSnapshot = library.visibleArtists
        let liked = likedPlaylist
        let playlistsSnapshot = [liked] + library.playlists.filter {
            $0.id != MusicLibrary.likedSongsPlaylistID
        }
        var songCounts: [String: Int] = [:]
        songCounts.reserveCapacity(playlistsSnapshot.count)
        for playlist in playlistsSnapshot {
            songCounts[playlist.id] = library.songCount(forPlaylist: playlist.id)
        }

        isBuilding = true
        let built = await Task.detached(priority: .userInitiated) {
            buildQuickAccessEditorContent(
                pins: currentPins,
                albums: albumsSnapshot,
                artists: artistsSnapshot,
                playlists: playlistsSnapshot,
                playlistSongCounts: songCounts,
                query: query
            )
        }.value
        guard !Task.isCancelled else { return }
        content = built
        isBuilding = false
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        // 后台那一轮还没落地时(刚固定了一个新歌单)直接现算一次, 不显示 0。
        String(
            format: String(localized: "carplay_playlist_song_count_format"),
            content.playlistSongCounts[playlist.id]
                ?? library.songCount(forPlaylist: playlist.id)
        )
    }

    @ViewBuilder
    private func selectedPinRow(_ resolved: QuickAccessResolvedPin) -> some View {
        switch resolved.target {
        case .album(let album):
            pinButton(resolved.pin) {
                AlbumArtworkView(album: album, size: 42, cornerRadius: 7)
            } title: {
                Text(album.title)
            } subtitle: {
                Text(album.artistName ?? String(localized: "unknown_artist"))
            }
        case .artist(let artist):
            pinButton(resolved.pin) {
                ArtistArtworkView(
                    artist: artist,
                    size: 42,
                    cornerRadius: 21
                )
            } title: {
                Text(artist.name)
            } subtitle: {
                Text(verbatim: "\(artist.albumCount) \(String(localized: "albums_count"))")
            }
        case .playlist(let playlist):
            pinButton(resolved.pin) {
                editorPlaylistArtwork(playlist)
            } title: {
                Text(playlist.name)
            } subtitle: {
                Text(playlistSubtitle(playlist))
            }
        case nil:
            EmptyView()
        }
    }

    private func pinButton<Artwork: View, Title: View, Subtitle: View>(
        _ pin: LibraryPinReference,
        @ViewBuilder artwork: () -> Artwork,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        let isSelected = pinState.identifiers.contains(pin)
        let canSelect = isSelected || pins.count < maximumCount

        return Button {
            toggle(pin)
        } label: {
            HStack(spacing: 12) {
                artwork()

                VStack(alignment: .leading, spacing: 2) {
                    title()
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    subtitle()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelect)
        .opacity(canSelect ? 1 : 0.45)
    }

    @ViewBuilder
    private func editorPlaylistArtwork(_ playlist: Playlist) -> some View {
        if playlist.id == MusicLibrary.likedSongsPlaylistID {
            likedEditorArtwork
        } else {
            PlaylistArtworkView(playlist: playlist, size: 42, cornerRadius: 7)
        }
    }

    private var likedEditorArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.pink, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "heart.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 42, height: 42)
    }

    private func toggle(_ pin: LibraryPinReference) {
        var updated = pins
        if let index = updated.firstIndex(of: pin) {
            updated.remove(at: index)
        } else if updated.count < maximumCount {
            updated.append(pin)
        }
        pinsRawValue = LibraryPinStorage.encode(updated, maximumCount: maximumCount)
    }

    private func movePins(from source: IndexSet, to destination: Int) {
        guard searchText.isEmpty else { return }
        var updated = pins
        updated.move(fromOffsets: source, toOffset: destination)
        pinsRawValue = LibraryPinStorage.encode(updated, maximumCount: maximumCount)
    }
}

private struct GenreVisualPalette {
    let leading: Color
    let trailing: Color
}

private enum GenreVisualStyle {
    private static let palettes: [GenreVisualPalette] = [
        .init(
            leading: Color(red: 0.16, green: 0.46, blue: 0.43),
            trailing: Color(red: 0.05, green: 0.19, blue: 0.27)
        ),
        .init(
            leading: Color(red: 0.66, green: 0.27, blue: 0.39),
            trailing: Color(red: 0.25, green: 0.08, blue: 0.22)
        ),
        .init(
            leading: Color(red: 0.64, green: 0.42, blue: 0.12),
            trailing: Color(red: 0.25, green: 0.14, blue: 0.06)
        ),
        .init(
            leading: Color(red: 0.37, green: 0.31, blue: 0.68),
            trailing: Color(red: 0.13, green: 0.10, blue: 0.30)
        ),
        .init(
            leading: Color(red: 0.18, green: 0.43, blue: 0.66),
            trailing: Color(red: 0.06, green: 0.16, blue: 0.33)
        ),
        .init(
            leading: Color(red: 0.61, green: 0.26, blue: 0.18),
            trailing: Color(red: 0.25, green: 0.09, blue: 0.07)
        ),
    ]

    static func palette(for genreID: String) -> GenreVisualPalette {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in genreID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palettes[Int(hash % UInt64(palettes.count))]
    }
}

struct GenreLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var searchText = ""
    #if os(iOS)
    @Environment(\.pmHeightClass) private var heightClass
    #endif
    #if os(macOS)
    @State private var selectedGenreID: String?
    #endif

    private var filteredGenres: [LibraryGenre] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.visibleGenres
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
            .navigationDestination(for: LibraryGenre.self) { genre in
                GenreDetailView(genre: genre)
            }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iosBody: some View {
        if library.visibleGenres.isEmpty {
            EmptyStateView(
                titleKey: "no_genres",
                descriptionKey: "no_genres_desc",
                systemImage: "tag"
            )
            .pmAppearFade(.contentAppear)
        } else {
            // 手机横屏下卡片降一档: 竖屏 2 列 × 142 高, 横屏 4-5 列 × 112 高,
            // 一屏能看到两行而不是一行半。
            let cardMinimumWidth = heightClass.value(156, compact: 124)
            let cardHeight = heightClass.value(142, compact: 112)
            ScrollView {
                if filteredGenres.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 80)
                        .pmAppearFade(.contentAppear)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(filteredGenres) { genre in
                            NavigationLink(value: genre) {
                                LibraryGenreCard(genre: genre, height: cardHeight)
                            }
                            .buttonStyle(.pmPressable)
                        }
                    }
                    .padding(16)
                    // 只在"有结果 ↔ 没结果"这一层重建时淡入一次, 逐键过滤的网格本身不动。
                    .pmAppearFade(.contentAppear)
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("genre_search_placeholder")
            )
        }
    }
    #endif

    #if os(macOS)
    private var selectedGenre: LibraryGenre? {
        if let selectedGenreID,
           let genre = filteredGenres.first(where: { $0.id == selectedGenreID }) {
            return genre
        }
        return filteredGenres.first
    }

    @ViewBuilder
    private var macBody: some View {
        if library.visibleGenres.isEmpty {
            ContentUnavailableView(
                "no_genres",
                systemImage: "tag",
                description: Text("no_genres_desc")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PMColor.bg.ignoresSafeArea())
        } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("tab_genres")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PMColor.text)

                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(PMColor.textFaint)
                            TextField(
                                "",
                                text: $searchText,
                                prompt: Text("genre_search_placeholder")
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(PMColor.glassBtn, in: RoundedRectangle(cornerRadius: PMRadius.s))
                        .overlay {
                            RoundedRectangle(cornerRadius: PMRadius.s)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                    if filteredGenres.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                ForEach(filteredGenres) { genre in
                                    macGenreRow(genre)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 24)
                        }
                    }
                }
                .frame(width: 280)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(PMColor.bg)

                Rectangle().fill(PMColor.divider).frame(width: 0.5)

                if let selectedGenre {
                    // 淡入挂在 .id 里面: 换流派时身份重建, 修饰符的状态才会跟着重置。
                    GenreDetailView(genre: selectedGenre)
                        .pmAppearFade()
                        .id(selectedGenre.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    private func macGenreRow(_ genre: LibraryGenre) -> some View {
        let selected = selectedGenre?.id == genre.id
        return Button {
            selectedGenreID = genre.id
        } label: {
            HStack(spacing: 10) {
                GenreArtworkMosaic(genre: genre, artworkSize: 30)
                    .frame(width: 52, height: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: genre.name)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: "\(genre.albumCount) \(String(localized: "albums_count")) · \(genre.songCount) \(String(localized: "songs_count"))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .pmRowBackground(selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif
}

private struct LibraryGenreCard: View {
    let genre: LibraryGenre
    /// 卡片高度由调用处按纵向尺寸等级给, 卡片自己不读环境 —— 它也编进 Mac target。
    var height: CGFloat = 142

    var body: some View {
        let palette = GenreVisualStyle.palette(for: genre.id)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [palette.leading, palette.trailing],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GenreArtworkMosaic(genre: genre, artworkSize: 66)
                .frame(width: 116, height: 86)
                .offset(x: 62, y: 12)
                .opacity(0.88)

            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: genre.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(verbatim: "\(genre.albumCount) \(String(localized: "albums_count")) · \(genre.songCount) \(String(localized: "songs_count"))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
            }
            .padding(13)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: genre.name))
        .accessibilityValue(Text(verbatim: "\(genre.albumCount) \(String(localized: "albums_count")), \(genre.songCount) \(String(localized: "songs_count"))"))
    }
}

private struct GenreArtworkMosaic: View {
    @Environment(MusicLibrary.self) private var library
    let genre: LibraryGenre
    let artworkSize: CGFloat

    private var songs: [Song] {
        genre.representativeSongIDs.compactMap { library.visibleSong(id: $0) }
    }

    var body: some View {
        ZStack {
            if songs.isEmpty {
                RoundedRectangle(cornerRadius: artworkSize * 0.18, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: artworkSize * 0.28, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                    .frame(width: artworkSize, height: artworkSize)
            } else {
                ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: artworkSize,
                        cornerRadius: artworkSize * 0.16,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: artworkSize * 0.16)
                            .stroke(.white.opacity(0.28), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.26), radius: artworkSize * 0.07, y: artworkSize * 0.04)
                    .rotationEffect(.degrees((Double(index) - Double(songs.count - 1) / 2) * 7))
                    .offset(x: (CGFloat(index) - CGFloat(songs.count - 1) / 2) * artworkSize * 0.34)
                    .zIndex(Double(index))
                }
            }
        }
    }
}

private struct GenreDetailView: View {
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(CoverTintProvider.self) private var coverTints
    @Environment(\.colorScheme) private var colorScheme
    #endif
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    let genre: LibraryGenre
    @State private var selection = SongSelectionModel()

    /// 手机横屏 (纵向紧凑) 才压缩 hero。Mac 没有纵向尺寸等级, 恒为 false。
    private var usesCompactHero: Bool {
        #if os(iOS)
        heightClass.isCompact
        #else
        false
        #endif
    }

    private var songs: [Song] { library.songs(forGenre: genre.id) }
    private var playableSongs: [Song] { songs.filteredPlayable() }

    #if os(iOS)
    /// 风格没有自己的封面, 用它的第一首代表曲 —— 也就是马赛克里最上面那张。
    private var artworkTintSong: Song? {
        genre.representativeSongIDs.lazy.compactMap { library.visibleSong(id: $0) }.first
            ?? songs.first
    }

    /// 取不到封面色时退回这个风格原来的固定配色, 风格之间仍然分得开。
    private var tint: LibraryDetailTintStyle {
        let artworkColor = artworkTintSong.flatMap { coverTints.tint(forSongID: $0.id) }
        return .artwork(
            artworkColor ?? GenreVisualStyle.palette(for: genre.id).leading,
            colorScheme: colorScheme
        )
    }
    #endif

    private var albums: [Album] {
        library.albums(forGenre: genre.id).sorted { lhs, rhs in
            let lhsYear = lhs.year ?? Int.min
            let rhsYear = rhs.year ?? Int.min
            if lhsYear != rhsYear { return lhsYear > rhsYear }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            ImmersiveLibraryDetailScrollView { insets in
                hero(insets: insets)
            } content: {
                VStack(alignment: .leading, spacing: 28) {
                    if !albums.isEmpty { albumShelf }
                    if !songs.isEmpty { songSection }
                }
                .padding(.top, 28)
                .padding(.bottom, BottomChromeClearancePolicy.clearance(
                    legacyOverlayActive: legacyBottomChromeOverlayActive,
                    legacy: 64,
                    baseline: 16
                ))
            }
            .navigationTitle("")
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero(insets: ImmersiveLibraryDetailInsets())

                    if !albums.isEmpty { albumShelf }
                    if !songs.isEmpty { songSection }
                }
                .padding(.bottom, 64)
            }
            .background(PMColor.bg.ignoresSafeArea())
            .navigationTitle(Text(verbatim: genre.name))
            #endif
        }
        .toolbarTitleDisplayMode(.inline)
        #if os(iOS)
        .libraryDetailTint(from: artworkTintSong)
        .minimalNavigationDetail()
        .librarySearchContext {
            LibrarySearchScope(title: genre.name, songIDs: Set(songs.map(\.id)), kind: .genre)
        }
        #endif
        .songBatchActions(
            selection: selection,
            orderedIDs: { songs.map(\.id) },
            resolve: { library.song(id: $0) }
        )
    }

    /// 竖屏的 `topInset + 100` 是照着状态栏 + 导航栏标定的; 手机横屏顶部安全区塌成 0,
    /// 那 100 就白占了整块首屏。紧凑高度下顶部留白、标题字号、马赛克都降一档,
    /// hero 压到 170pt 以内, 专辑架和第一首歌才露得出来。结构不变。
    private func hero(insets: ImmersiveLibraryDetailInsets) -> some View {
        let compact = usesCompactHero
        let heroTopPadding: CGFloat = compact ? 28 : 100
        let heroBottomPadding: CGFloat = compact ? 14 : 28
        let blockSpacing: CGFloat = compact ? 10 : 16
        let titleLineLimit = compact ? 1 : 2
        let mosaicWidth: CGFloat = compact ? 150 : 220
        let mosaicHeight: CGFloat = compact ? 100 : 150
        let mosaicArtworkSize: CGFloat = compact ? 80 : 116

        return VStack(alignment: .leading, spacing: blockSpacing) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: genre.name)
                    #if os(macOS)
                    .font(.system(size: 42, weight: .bold))
                    #else
                    .font(compact ? Font.title.weight(.bold) : Font.largeTitle.weight(.bold))
                    #endif
                    .foregroundStyle(.white)
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(compact ? 0.82 : 1)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    verbatim:
                        "\(albums.count) \(String(localized: "albums_count")) · \(songs.count) \(String(localized: "songs_count"))"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.74))
            }

            HStack(spacing: 10) {
                LibraryDetailActionButton(
                    title: "play",
                    systemImage: "play.fill",
                    emphasized: true,
                    disabled: playableSongs.isEmpty,
                    action: playAll
                )
                LibraryDetailActionButton(
                    title: "shuffle",
                    systemImage: "shuffle",
                    disabled: playableSongs.count < 2,
                    action: shuffleAll
                )
            }

            LibraryReviewSection(
                subject: .genre(genre.id),
                compact: true,
                onArtwork: true
            )
        }
        // 渐变底图铺满整幅屏幕, 文字与按钮按侧留在安全区内 —— 横屏两侧不一定相等。
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + heroTopPadding)
        .padding(.bottom, heroBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            heroBackdrop(
                insets: insets,
                mosaicWidth: mosaicWidth,
                mosaicHeight: mosaicHeight,
                mosaicArtworkSize: mosaicArtworkSize
            )
        }
        .clipped()
    }

    /// 头图底: 整页底色打底, 右上角压那叠代表封面, 再往下化进页面底色 ——
    /// 接下去的专辑架和歌曲列表用的就是这个颜色, 所以看不出头图在哪儿结束。
    private func heroBackdrop(
        insets: ImmersiveLibraryDetailInsets,
        mosaicWidth: CGFloat,
        mosaicHeight: CGFloat,
        mosaicArtworkSize: CGFloat
    ) -> some View {
        #if os(iOS)
        let leading = tint.top
        let trailing = tint.bottom
        let fade = LinearGradient(
            stops: [
                .init(color: .black.opacity(0.05), location: 0),
                .init(color: tint.top.opacity(0.42), location: 0.55),
                .init(color: tint.top, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        #else
        let palette = GenreVisualStyle.palette(for: genre.id)
        let leading = palette.leading
        let trailing = palette.trailing
        let fade = LinearGradient(
            colors: [.black.opacity(0.05), .black.opacity(0.76)],
            startPoint: .top,
            endPoint: .bottom
        )
        #endif

        return LinearGradient(
            colors: [leading, trailing],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            GenreArtworkMosaic(genre: genre, artworkSize: mosaicArtworkSize)
                .frame(width: mosaicWidth, height: mosaicHeight)
                .padding(.top, insets.top + 12)
                .padding(.trailing, insets.trailing + 16)
                .opacity(0.8)
                .accessibilityHidden(true)
        }
        .overlay { fade }
    }

    private var albumShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailSectionTitle("albums_section")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album).frame(width: 142)
                        }
                        .buttonStyle(.plain)
                        .mediaZoomSource(.album, id: album.id)
                    }
                }
                .padding(.horizontal, 20)
            }
            .pmStopsAtVerticalBar()
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }

    private var songSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailSectionTitle("all_songs_section")

            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRowView(
                        song: song,
                        isPlaying: player.currentSong?.id == song.id,
                        selection: selection,
                        context: SongRowView.context(
                            for: song,
                            sourcesStore: sourcesStore,
                            backfill: backfill
                        )
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { playSong(song) }
                    .songSelectable(
                        songID: song.id,
                        selection: selection,
                        orderedIDs: { songs.map(\.id) }
                    )

                    if index != songs.count - 1 {
                        Divider().padding(.leading, 66)
                    }
                }
            }
            #if os(iOS)
            .songRowColumnsContainer()
            .libraryDetailSection(tint: tint)
            #else
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.06), lineWidth: 0.5)
            }
            #endif
            .padding(.horizontal, 20)
        }
    }

    private func detailSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 20)
    }

    private func playAll() {
        guard !playableSongs.isEmpty else { return }
        Task { await player.play(queue: playableSongs, startingAt: 0) }
    }

    private func shuffleAll() {
        let queue = playableSongs.shuffled()
        guard !queue.isEmpty else { return }
        player.shuffleEnabled = true
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func playSong(_ song: Song) {
        guard let index = playableSongs.firstIndex(where: { $0.id == song.id }) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queue: playableSongs, startingAt: index) }
    }
}

#Preview {
    LibraryView()
        .environment(MusicLibrary())
}
