import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(CoverTintProvider.self) private var tintProvider

    private var hasContent: Bool { homeSnapshot.hasContent }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        case 18..<22: return String(localized: "greeting_evening")
        default: return String(localized: "greeting_night")
        }
    }

    @Environment(AppUpdateChecker.self) private var updateChecker
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showUpdateSheet: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if hasContent {
                        contentView
                    } else {
                        emptyView
                    }
                }
                .padding(.bottom, 100)
            }
            .task {
                await refreshHomeSnapshotAfterPresentationIfNeeded()
            }
            .onChange(of: library.searchRevision) { _, _ in
                scheduleDebouncedHomeRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
                refreshHomeSnapshot(force: true)
            }
            .onDisappear {
                homeRefreshDebounceTask?.cancel()
                homeRefreshDebounceTask = nil
            }
            .navigationTitle("home_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            // 更新提示改成 sheet 弹框 ── 之前内嵌在首页顶部当 banner 用,
            // 用户更想要"弹框"的 modal 体感, 也避免占用首页空间。
            // checker.availableUpdate 从 nil 变非 nil 时自动弹出。
            .onChange(of: updateChecker.availableUpdate) { _, newValue in
                showUpdateSheet = newValue != nil
            }
            .onAppear {
                if updateChecker.availableUpdate != nil { showUpdateSheet = true }
            }
            // 改用 fullScreenCover + 透明背景实现居中 modal 弹框, 替代之前
            // 的底部 sheet (sheet 视觉上像"双层弹框", 用户反馈丑)。
            // macOS 没有 fullScreenCover, 退化成普通 sheet。
            #if os(iOS)
            .fullScreenCover(isPresented: $showUpdateSheet) {
                UpdateBannerSheet()
            }
            #else
            .sheet(isPresented: $showUpdateSheet) {
                UpdateBannerSheet()
            }
            #endif
        }
    }

    // MARK: - Content

    // Section toggles. Hero is mandatory (always shown).
    @AppStorage("primuse.home.showStatsGlimpse") private var showStatsGlimpse: Bool = true
    @AppStorage("primuse.home.showForYou") private var showForYou: Bool = true
    @AppStorage("primuse.home.showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("primuse.home.showRecentlyAdded") private var showRecentlyAdded: Bool = true
    @AppStorage("primuse.home.showContinueListening") private var showContinueListening: Bool = true
    @AppStorage("primuse.home.showQuickAccess") private var showQuickAccess: Bool = true
    @AppStorage("primuse.home.showPlaylists") private var showPlaylists: Bool = true
    @AppStorage(HomeSectionConfiguration.orderKey) private var homeSectionOrderRawValue = ""
    @AppStorage(LibraryPinStorage.defaultsKey) private var quickAccessRawValue = ""
    @State private var homeSnapshot = HomeSnapshot()
    @State private var lastHomeSnapshotSignature: HomeSnapshotSignature?
    // Debounce for `searchRevision`-driven refreshes. MusicLibrary bumps
    // `searchRevision` on *every* upsert batch during a scan, so a large
    // library scan would otherwise fire refreshHomeSnapshot(force:) dozens
    // of times — each one a full main-thread resort/regroup/recommend.
    // Coalesce the storm and only recompute once it settles.
    @State private var homeRefreshDebounceTask: Task<Void, Never>?
    // Backfill currently publishes at most once every two seconds. Keep this
    // window longer than that interval so a continuous large-library job does
    // not rebuild recommendations and album groupings on the main actor while
    // the user is scrolling; the snapshot refreshes once the burst settles.
    private static let homeRefreshDebounce: Duration = .seconds(3)
    @State private var recommendationTask: Task<Void, Never>?
    @State private var libraryHighlightsTask: Task<Void, Never>?

    private struct HomeSnapshotSignature: Equatable {
        let libraryRevision: Int
        let visibleSongCount: Int
        let visibleAlbumCount: Int
        let visibleArtistCount: Int
        let recentSongIDs: [String]
        let dayStamp: Int
    }

    private struct HomeAlbumTile: Identifiable, Sendable {
        let album: Album
        let artworkSong: Song?

        var id: String { album.id }
    }

    private struct HomeAlbumAccumulator: Sendable {
        var latestDate: Date
        var firstSong: Song
        var firstCoveredSong: Song?
    }

    private struct HomePlaylistTile: Identifiable {
        let playlist: Playlist
        let artworkSong: Song?
        let songCount: Int

        var id: String { playlist.id }
    }

    private enum HomeQuickItem: Identifiable {
        case album(Album)
        case artist(Artist)
        case playlist(HomePlaylistTile)

        var id: String {
            switch self {
            case .album(let album): "album:\(album.id)"
            case .artist(let artist): "artist:\(artist.id)"
            case .playlist(let tile): "playlist:\(tile.id)"
            }
        }
    }

    private struct HomeSnapshot {
        var hasContent = false
        var statsGlimpse: PlayHistoryStore.Summary?
        var forYouResults: [MusicDiscoveryResult] = []
        var recentSongs: [Song] = []
        var heroCoverSongs: [Song] = []
        var recentlyAddedAlbums: [HomeAlbumTile] = []
        var topArtists: [Artist] = []
        var topArtistsHasHistory = false
        var playlists: [HomePlaylistTile] = []
        var quickItems: [HomeQuickItem] = []
        var likedPlaylist: Playlist?
    }

    private var homeSectionOrder: [HomeSectionKind] {
        HomeSectionConfiguration.decode(homeSectionOrderRawValue)
    }

    private var likedPlaylist: Playlist {
        homeSnapshot.likedPlaylist
            ?? Playlist(
                id: MusicLibrary.likedSongsPlaylistID,
                name: String(localized: "playlist_liked_name")
            )
    }

    private var contentView: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            libraryHeroSection

            ForEach(homeSectionOrder) { section in
                homeSectionContent(section)
            }
        }
    }

    @ViewBuilder
    private func homeSectionContent(_ section: HomeSectionKind) -> some View {
        switch section {
        case .continueListening:
            if showContinueListening, !homeSnapshot.recentSongs.isEmpty {
                continueListeningSection
            }
        case .quickAccess:
            if showQuickAccess {
                quickAccessSection
            }
        case .forYou:
            if showForYou, !homeSnapshot.forYouResults.isEmpty {
                forYouSection
            }
        case .playlists:
            if showPlaylists, !homeSnapshot.playlists.isEmpty {
                playlistsSection
            }
        case .topArtists:
            if showTopArtists, !homeSnapshot.topArtists.isEmpty {
                artistsSection
            }
        case .recentlyAdded:
            if showRecentlyAdded, !homeSnapshot.recentlyAddedAlbums.isEmpty {
                recentlyAddedAlbumsSection
            }
        case .stats:
            if showStatsGlimpse, let summary = homeSnapshot.statsGlimpse {
                statsGlimpseSection(summary)
            }
        }
    }

    /// Coalesce `searchRevision` storms (scan batches) into a single
    /// recompute. Each call cancels the pending one and restarts the
    /// timer, so only the last revision in a burst actually rebuilds the
    /// snapshot. Uses `force: true` to bypass signature dedup the same way
    /// the previous direct call did — the debounce is what suppresses the
    /// redundant work now.
    private func scheduleDebouncedHomeRefresh() {
        homeRefreshDebounceTask?.cancel()
        homeRefreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.homeRefreshDebounce)
            guard !Task.isCancelled else { return }
            refreshHomeSnapshot(force: true)
        }
    }

    private var homeSnapshotSignature: HomeSnapshotSignature {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayStamp = (components.year ?? 0) * 10_000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
        return HomeSnapshotSignature(
            libraryRevision: library.searchRevision,
            visibleSongCount: library.visibleSongs.count,
            visibleAlbumCount: library.visibleAlbums.count,
            visibleArtistCount: library.visibleArtists.count,
            recentSongIDs: Array(library.recentPlaybackSongIDsForSync.prefix(30)),
            dayStamp: dayStamp
        )
    }

    /// 先把已有快照交给 SwiftUI 画出首帧，再检查资料库是否需要刷新。
    /// `.task` 在 tab 切入时会先同步执行到第一个 suspension point；旧实现
    /// 直接在这里做全库计算，导致导航动画必须等计算结束才显示首页。
    private func refreshHomeSnapshotAfterPresentationIfNeeded() async {
        await Task.yield()
        if homeSnapshot.hasContent {
            try? await Task.sleep(for: .milliseconds(180))
        }
        guard !Task.isCancelled else { return }
        refreshHomeSnapshot(force: false)
    }

    private func refreshHomeSnapshot(force: Bool) {
        let signature = homeSnapshotSignature
        guard force || signature != lastHomeSnapshotSignature else { return }

        let visibleSongIDs = Set(library.visibleSongs.map(\.id))
        let visibleAlbumIDs = Set(library.visibleAlbums.map(\.id))
        let retainedRecommendations = homeSnapshot.forYouResults.filter {
            visibleSongIDs.contains($0.song.id)
        }
        let retainedHeroCovers = homeSnapshot.heroCoverSongs.filter {
            visibleSongIDs.contains($0.id)
        }
        let retainedRecentlyAddedAlbums = homeSnapshot.recentlyAddedAlbums.filter {
            visibleAlbumIDs.contains($0.id)
        }
        let recommendationInput = showForYou
            ? MusicDiscoveryEngine.recommendationInput(in: library)
            : nil
        // Array copies are copy-on-write and therefore cheap on the main actor.
        // The detached worker below is the only place that traverses them.
        let visibleSongs = library.visibleSongs
        let visibleAlbums = library.visibleAlbums

        let startedAt = Date()
        let snapshot = makeHomeSnapshot(
            forYouResults: retainedRecommendations,
            heroCoverSongs: retainedHeroCovers,
            recentlyAddedAlbums: retainedRecentlyAddedAlbums
        )
        homeSnapshot = snapshot
        lastHomeSnapshotSignature = signature

        // Kick off background tint extraction for the visible cards.
        // Idempotent — cached songs are skipped.
        tintProvider.prepare(snapshot.forYouResults.map(\.song))
        tintProvider.prepare(Array(snapshot.recentSongs.prefix(15)))

        scheduleLibraryHighlightsRefresh(
            songs: visibleSongs,
            albums: visibleAlbums,
            recentSongs: snapshot.recentSongs,
            signature: signature
        )

        if let recommendationInput {
            scheduleRecommendationRefresh(
                input: recommendationInput,
                signature: signature
            )
        } else {
            recommendationTask?.cancel()
            recommendationTask = nil
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        #if DEBUG
        plog(String(format: "🏠 home snapshot main %.0fms songs=%d albums=%d artists=%d",
                    elapsed * 1000,
                    signature.visibleSongCount,
                    signature.visibleAlbumCount,
                    signature.visibleArtistCount))
        #else
        if elapsed > 0.08 {
            plog(String(format: "🏠 home snapshot refresh %.0fms songs=%d albums=%d artists=%d",
                        elapsed * 1000,
                        signature.visibleSongCount,
                        signature.visibleAlbumCount,
                        signature.visibleArtistCount))
        }
        #endif
    }

    /// Hero 封面和最近专辑都需要遍历整库；它们与推荐一样不应该参与
    /// Tab 切换首帧。保留旧快照，后台算完后再一次性发布。
    private func scheduleLibraryHighlightsRefresh(
        songs: [Song],
        albums: [Album],
        recentSongs: [Song],
        signature: HomeSnapshotSignature
    ) {
        libraryHighlightsTask?.cancel()
        libraryHighlightsTask = Task { @MainActor in
            let payload = await Task.detached(priority: .utility) {
                let startedAt = Date()
                let heroCoverSongs = Self.makeHeroCoverSongs(
                    songs: songs,
                    recentSongs: recentSongs
                )
                let albumTiles = Self.makeRecentlyAddedAlbumTiles(
                    songs: songs,
                    albums: albums,
                    limit: 12
                )
                return (
                    heroCoverSongs,
                    albumTiles,
                    Date().timeIntervalSince(startedAt)
                )
            }.value

            guard !Task.isCancelled, homeSnapshotSignature == signature else { return }
            homeSnapshot.heroCoverSongs = payload.0
            homeSnapshot.recentlyAddedAlbums = payload.1

            #if DEBUG
            if payload.2 > 0.02 {
                plog(String(
                    format: "🏠 library highlights background %.0fms songs=%d",
                    payload.2 * 1000,
                    songs.count
                ))
            }
            #endif
        }
    }

    /// 推荐是首页快照里唯一仍需约 200ms 的部分。输入在主线程快速复制，
    /// 真正的归一化和全库评分放到 detached task；完成后只回主线程发布
    /// 12 条结果。旧快照在此期间继续显示。
    private func scheduleRecommendationRefresh(
        input: MusicDiscoveryEngine.RecommendationInput,
        signature: HomeSnapshotSignature
    ) {
        recommendationTask?.cancel()
        recommendationTask = Task { @MainActor in
            let payload = await Task.detached(priority: .utility) {
                let startedAt = Date()
                let results = MusicDiscoveryEngine.dailyRecommendations(from: input, limit: 12)
                return (results, Date().timeIntervalSince(startedAt))
            }.value

            guard !Task.isCancelled, homeSnapshotSignature == signature else { return }
            homeSnapshot.forYouResults = payload.0
            tintProvider.prepare(payload.0.map(\.song))

            #if DEBUG
            if payload.1 > 0.05 {
                plog(String(
                    format: "🏠 recommendations background %.0fms songs=%d",
                    payload.1 * 1000,
                    input.songs.count
                ))
            }
            #endif
        }
    }

    private func makeHomeSnapshot(
        forYouResults: [MusicDiscoveryResult],
        heroCoverSongs: [Song],
        recentlyAddedAlbums: [HomeAlbumTile]
    ) -> HomeSnapshot {
        let snapshotStartedAt = Date()
        let recentSongs = makeRecentSongs()
        let summary = PlayHistoryStore.shared.summary(in: .week)
        let topArtistHistory = PlayHistoryStore.shared.topArtists(in: .month, limit: 8)
        let allPlaylists = library.playlists
        let likedPlaylist = allPlaylists.first {
            $0.id == MusicLibrary.likedSongsPlaylistID
        }
        let regularPlaylists = allPlaylists
            .filter { $0.id != MusicLibrary.likedSongsPlaylistID }
            .sorted { $0.updatedAt > $1.updatedAt }
        let playlistTiles = regularPlaylists.prefix(10).map(makeHomePlaylistTile)
        let baseFinishedAt = Date()

        let heroFinishedAt = Date()
        let albumsFinishedAt = Date()
        let topArtists = topArtistsForHome(history: topArtistHistory)
        let artistsFinishedAt = Date()
        let quickItems = makeHomeQuickItems(regularPlaylists: regularPlaylists)
        let quickFinishedAt = Date()

        let snapshot = HomeSnapshot(
            hasContent: !library.visibleSongs.isEmpty,
            statsGlimpse: summary.totalPlays > 0 ? summary : nil,
            forYouResults: forYouResults,
            recentSongs: recentSongs,
            heroCoverSongs: heroCoverSongs,
            recentlyAddedAlbums: recentlyAddedAlbums,
            topArtists: topArtists,
            topArtistsHasHistory: !topArtistHistory.isEmpty,
            playlists: playlistTiles,
            quickItems: quickItems,
            likedPlaylist: likedPlaylist
        )

        #if DEBUG
        let total = quickFinishedAt.timeIntervalSince(snapshotStartedAt)
        plog(String(
            format: "🏠 snapshot parts total=%.0fms base=%.0f hero=%.0f albums=%.0f artists=%.0f quick=%.0f",
            total * 1000,
            baseFinishedAt.timeIntervalSince(snapshotStartedAt) * 1000,
            heroFinishedAt.timeIntervalSince(baseFinishedAt) * 1000,
            albumsFinishedAt.timeIntervalSince(heroFinishedAt) * 1000,
            artistsFinishedAt.timeIntervalSince(albumsFinishedAt) * 1000,
            quickFinishedAt.timeIntervalSince(artistsFinishedAt) * 1000
        ))
        #endif

        return snapshot
    }

    private func makeHomePlaylistTile(_ playlist: Playlist) -> HomePlaylistTile {
        let songs = library.songs(forPlaylist: playlist.id)
        return HomePlaylistTile(
            playlist: playlist,
            artworkSong: songs.first,
            songCount: songs.count
        )
    }

    private func makeHomeQuickItems(
        regularPlaylists: [Playlist]
    ) -> [HomeQuickItem] {
        let albumsByID = Dictionary(
            library.visibleAlbums.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let artistsByID = Dictionary(
            library.visibleArtists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let playlistsByID = Dictionary(
            regularPlaylists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return LibraryPinStorage.decode(quickAccessRawValue).compactMap { pin in
            switch pin.kind {
            case .album:
                return albumsByID[pin.itemID].map(HomeQuickItem.album)
            case .artist:
                return artistsByID[pin.itemID].map(HomeQuickItem.artist)
            case .playlist:
                return playlistsByID[pin.itemID]
                    .map(makeHomePlaylistTile)
                    .map(HomeQuickItem.playlist)
            }
        }
    }

    nonisolated private static func makeRecentlyAddedAlbumTiles(
        songs: [Song],
        albums: [Album],
        limit: Int
    ) -> [HomeAlbumTile] {
        // 旧实现先在 MusicLibrary 内把全库按专辑分组一次，再回到这里二次
        // 分组并逐专辑排序。万首库上仅这一段就会占用主线程约 40ms。
        // 单次遍历同时收集最近日期、第一首歌和第一首带封面的歌，结果与旧
        // 规则一致，但不再创建两套包含所有歌曲的临时数组。
        var accumulators: [String: HomeAlbumAccumulator] = [:]
        accumulators.reserveCapacity(albums.count)

        for song in songs {
            guard let albumID = song.albumID, !albumID.isEmpty else { continue }
            let hasCover = song.coverArtFileName?.isEmpty == false

            if var accumulator = accumulators[albumID] {
                if song.dateAdded > accumulator.latestDate {
                    accumulator.latestDate = song.dateAdded
                }
                if Self.homeAlbumSongPrecedes(song, accumulator.firstSong) {
                    accumulator.firstSong = song
                }
                if hasCover {
                    if let firstCoveredSong = accumulator.firstCoveredSong {
                        if Self.homeAlbumSongPrecedes(song, firstCoveredSong) {
                            accumulator.firstCoveredSong = song
                        }
                    } else {
                        accumulator.firstCoveredSong = song
                    }
                }
                accumulators[albumID] = accumulator
            } else {
                accumulators[albumID] = HomeAlbumAccumulator(
                    latestDate: song.dateAdded,
                    firstSong: song,
                    firstCoveredSong: hasCover ? song : nil
                )
            }
        }

        return albums
            .sorted {
                let left = accumulators[$0.id]?.latestDate ?? .distantPast
                let right = accumulators[$1.id]?.latestDate ?? .distantPast
                return left > right
            }
            .prefix(limit)
            .map { album in
                let accumulator = accumulators[album.id]
                return HomeAlbumTile(
                    album: album,
                    artworkSong: accumulator?.firstCoveredSong ?? accumulator?.firstSong
                )
            }
    }

    nonisolated private static func homeAlbumSongPrecedes(_ lhs: Song, _ rhs: Song) -> Bool {
        let leftTrack = lhs.trackNumber ?? Int.max
        let rightTrack = rhs.trackNumber ?? Int.max
        if leftTrack != rightTrack { return leftTrack < rightTrack }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    // MARK: - Stats Glimpse

    @ViewBuilder
    private func statsGlimpseSection(_ summary: PlayHistoryStore.Summary) -> some View {
        NavigationLink {
            ListeningStatsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("stats_title")
                        .font(.subheadline.weight(.semibold))
                    Text(String(
                        format: String(localized: "home_stats_glimpse_format"),
                        summary.totalPlays,
                        formattedDuration(summary.totalSec),
                        summary.activeDays
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.thinMaterial)
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// Compact "Xh Ym" / "Ym" formatter for the stats glimpse line.
    /// Uses DateComponentsFormatter so locale-correct strings come
    /// out for Chinese / English without extra plumbing.
    private func formattedDuration(_ totalSec: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = totalSec >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, totalSec)) ?? "—"
    }

    /// Soft gradient tinted background pulled from a song's cover.
    /// Falls back to ultra-thin material when the tint hasn't been
    /// extracted yet (or the cover failed to load) — gives every
    /// card a consistent shape without blocking on extraction.
    @ViewBuilder
    private func tintedCardBackground(for song: Song) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let tint = tintProvider.tint(forSongID: song.id) {
            shape.fill(LinearGradient(
                colors: [tint.opacity(0.22), tint.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    // MARK: - Library Hero / Today's Pick

    /// 用户库里随机抽 4 首带封面的歌, 在 hero 右侧错落拼贴。每次进入页面
    /// 重新洗一组, 让 hero 有「在看自己音乐」的存在感。挑过封面的, 没封面
    /// 的歌跳过 (放占位太单调)。 Used as cold-start fallback when no
    /// `todaysPick` can be derived (e.g. zero playback history AND no
    /// covered library songs at all).
    /// Daily-stable pick — yyyymmdd hash mod available pool. Stays
    /// the same all day so the user gets a "today's hero" feel
    /// without it shuffling on every refresh. Computed lazily from
    /// the cached home snapshot; recent songs are the cold-start
    /// fallback when forYou is empty.
    private var todaysPick: Song? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let stamp = (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
        let pool: [Song] = !forYouPicks.isEmpty ? forYouPicks
            : Array(homeSnapshot.recentSongs.filter { $0.coverArtFileName?.isEmpty == false }.prefix(20))
        guard !pool.isEmpty else { return nil }
        let idx = abs(stamp) % pool.count
        return pool[idx]
    }

    /// Hero 顶部 ── 一直走 libraryMixHeroFallback (问候语 + 4 张封面拼贴 +
    /// 随机播放 / 全部播放两个按钮)。
    /// 之前的 todaysPickHero (今日精选大封面 + Play / Shuffle) 视觉上不够干净,
    /// 用户反馈不好看, 暂时不用; 代码保留方便将来需要时切回去。
    @ViewBuilder
    private var libraryHeroSection: some View {
        libraryMixHeroFallback
    }

    @ViewBuilder
    private func todaysPickHero(pick: Song) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CachedArtworkView(
                    coverRef: pick.coverArtFileName,
                    songID: pick.id,
                    size: 96, cornerRadius: 12,
                    sourceID: pick.sourceID,
                    filePath: pick.filePath,
                    fileFormat: pick.fileFormat
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("home_todays_pick_title")
                        .font(.title3).fontWeight(.bold)
                        .lineLimit(1)
                    Text(pick.title)
                        .font(.subheadline).fontWeight(.medium)
                        .lineLimit(1)
                    Text(pick.artistName ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    playSong(pick)
                } label: {
                    Label("play", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())

                Button {
                    playLibrary(shuffled: true)
                } label: {
                    Label("shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(heroTintGradient(for: pick))
        }
        .padding(.horizontal, 16)
        .task(id: pick.id) {
            // Make sure the hero's tint gets extracted right away
            // even if it isn't part of the forYou row.
            tintProvider.prepare([pick])
        }
    }

    /// Hero background gradient: same per-song tint pattern as the
    /// list cards but stronger (Hero's bigger surface = bigger
    /// visual presence, can carry more saturation). Falls back to
    /// thinMaterial while extraction is pending.
    /// 返回 ShapeStyle 而不是 View, 让 RoundedRectangle.fill(_:) 能直接接住。
    /// (View 不能传给 fill, fill 要 ShapeStyle。)
    private func heroTintGradient(for song: Song) -> AnyShapeStyle {
        if let tint = tintProvider.tint(forSongID: song.id) {
            return AnyShapeStyle(LinearGradient(
                colors: [tint.opacity(0.32), tint.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        } else {
            return AnyShapeStyle(Material.thin)
        }
    }

    /// Cold-start: no songs eligible for the today's pick. Keep the
    /// old library-mix CTA so the user always has something to tap.
    private var libraryMixHeroFallback: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("home_library_mix_title")
                        .font(.title3)
                        .fontWeight(.bold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                heroCoverCollage
            }

            HStack(spacing: 10) {
                Button {
                    playLibrary(shuffled: true)
                } label: {
                    Label("shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())

                Button {
                    playLibrary(shuffled: false)
                } label: {
                    Label("play_all", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.thinMaterial)
        }
        .padding(.horizontal, 16)
    }

    /// 4 张封面错落叠放 — 用 ZStack 加旋转 + 偏移, 跟 Spotify Mix /
    /// Apple Music「For You」拼贴风格一致。封面来自最近添加 + 最近播放
    /// 的随机抽样, 每次 view 出现重洗一次。
    @ViewBuilder
    private var heroCoverCollage: some View {
        let size: CGFloat = 50
        let radius: CGFloat = 8
        ZStack {
            // 4 张依次叠, 角度 + 偏移让它们看起来散开
            ForEach(Array(homeSnapshot.heroCoverSongs.prefix(4).enumerated()), id: \.element.id) { index, song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: size,
                    cornerRadius: radius,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .rotationEffect(.degrees(coverRotation(for: index)))
                .offset(coverOffset(for: index))
                .zIndex(Double(4 - index))
            }
            if homeSnapshot.heroCoverSongs.isEmpty {
                Image(systemName: "music.note.list")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110, height: 80)
    }

    private func coverRotation(for index: Int) -> Double {
        switch index {
        case 0: return -10
        case 1: return -3
        case 2: return 5
        case 3: return 12
        default: return 0
        }
    }

    private func coverOffset(for index: Int) -> CGSize {
        switch index {
        case 0: return CGSize(width: -28, height: 0)
        case 1: return CGSize(width: -10, height: -4)
        case 2: return CGSize(width: 10, height: 2)
        case 3: return CGSize(width: 28, height: 0)
        default: return .zero
        }
    }

    nonisolated private static func makeHeroCoverSongs(
        songs: [Song],
        recentSongs: [Song]
    ) -> [Song] {
        // 优先最近播放, 不够再补最近添加, 都过滤出有 cover 的歌, 最后随机
        // 抽 4 首。结果跟随首页快照刷新,避免每次 tab 回首页都重排。
        let added = songs.sorted { $0.dateAdded > $1.dateAdded }.prefix(60)
        // 用 seen-set 按 id 去重: recentSongs 自身可能含重复 id (脏快照/跨源未彻底
        // 去重), 否则下方 ForEach(id: \.element.id) 会因重复 id 触发 SwiftUI 告警/崩溃。
        var pool: [Song] = []
        var seenIDs = Set<String>()
        for song in recentSongs + added where seenIDs.insert(song.id).inserted {
            pool.append(song)
        }
        let withCover = pool.filter { $0.coverArtFileName?.isEmpty == false }
        return Array(withCover.shuffled().prefix(4))
    }

    // MARK: - Quick Access

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home_section_quick_access")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 20)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10),
                    count: 3
                ),
                spacing: 14
            ) {
                NavigationLink(value: likedPlaylist) {
                    quickAccessDockLabel(
                        title: String(localized: "sidebar_liked_songs")
                    ) {
                        likedSongsArtwork(size: 52)
                    }
                }
                .buttonStyle(.plain)

                ForEach(homeSnapshot.quickItems) { item in
                    homeQuickDockItem(item)
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.primary.opacity(0.06), lineWidth: 0.5)
                    }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func homeQuickDockItem(_ item: HomeQuickItem) -> some View {
        switch item {
        case .album(let album):
            NavigationLink(value: album) {
                quickAccessDockLabel(title: album.title) {
                    CachedArtworkView(
                        albumID: album.id,
                        albumTitle: album.title,
                        artistName: album.artistName,
                        size: 52,
                        cornerRadius: 9
                    )
                }
            }
            .buttonStyle(.plain)
        case .artist(let artist):
            NavigationLink(value: artist) {
                quickAccessDockLabel(title: artist.name) {
                    CachedArtworkView(
                        artistID: artist.id,
                        artistName: artist.name,
                        size: 52,
                        cornerRadius: 26
                    )
                }
            }
            .buttonStyle(.plain)
        case .playlist(let tile):
            NavigationLink(value: tile.playlist) {
                quickAccessDockLabel(title: tile.playlist.name) {
                    homePlaylistArtwork(tile, size: 52, cornerRadius: 9)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func quickAccessDockLabel<Artwork: View>(
        title: String,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        VStack(spacing: 7) {
            artwork()
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .top)
        .contentShape(Rectangle())
    }

    private func likedSongsArtwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.pink, Color.accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Playlists

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home_section_playlists")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                let displayed = Array(homeSnapshot.playlists.prefix(sizeClass == .regular ? 5 : 4))
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, tile in
                    NavigationLink(value: tile.playlist) {
                        playlistListRow(tile)
                    }
                    .buttonStyle(.plain)

                    if index < displayed.count - 1 {
                        Divider()
                            .padding(.leading, 66)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func homePlaylistArtwork(
        _ tile: HomePlaylistTile,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        if let song = tile.artworkSong {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: size,
                cornerRadius: cornerRadius,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
        } else {
            StoredCoverArtView(
                fileName: tile.playlist.coverArtPath,
                size: size,
                cornerRadius: cornerRadius
            )
        }
    }

    private func playlistListRow(_ tile: HomePlaylistTile) -> some View {
        let playlist = tile.playlist
        return HStack(spacing: 12) {
            homePlaylistArtwork(tile, size: 54, cornerRadius: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    "\(tile.songCount) "
                        + String(localized: "songs_count")
                        + " · "
                        + playlist.updatedAt.formatted(.relative(presentation: .named))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    // MARK: - For You

    /// Local recommendation engine output, cached inside `homeSnapshot`
    /// so tab switches do not rebuild / reshuffle recommendations.
    private var forYouPicks: [Song] { homeSnapshot.forYouResults.map(\.song) }

    private var forYouSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home_for_you_title")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(homeSnapshot.forYouResults) { result in
                        let song = result.song
                        Button { playSong(song) } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    DiscoveryReasonsView(reasons: result.reasons, maxCount: 1)

                                    Text(song.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)

                                    Text(song.artistName ?? String(localized: "unknown_artist"))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    Spacer(minLength: 4)

                                    Label("play", systemImage: "play.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                CachedArtworkView(
                                    coverRef: song.coverArtFileName,
                                    songID: song.id,
                                    size: sizeClass == .regular ? 136 : 124,
                                    cornerRadius: 13,
                                    sourceID: song.sourceID,
                                    filePath: song.filePath,
                                    fileFormat: song.fileFormat
                                )
                                .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
                            }
                            .padding(14)
                            .frame(
                                width: sizeClass == .regular ? 372 : 316,
                                height: sizeClass == .regular ? 176 : 164
                            )
                            .background(recommendationCardBackground(for: song))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }

    @ViewBuilder
    private func recommendationCardBackground(for song: Song) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if let tint = tintProvider.tint(forSongID: song.id) {
            shape.fill(
                LinearGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            // Repeated live Material blurs create off-screen render passes
            // while the horizontal row moves. A stable system surface keeps
            // the same card hierarchy until the batched tint result arrives.
            shape.fill(homeCardSurface)
        }
    }

    // MARK: - Continue Listening (formerly Recently Played)

    private var continueListeningSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("home_continue_listening")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            let songs = homeSnapshot.recentSongs
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(
                    rows: [
                        GridItem(.fixed(60), spacing: 10),
                        GridItem(.fixed(60)),
                    ],
                    spacing: 10
                ) {
                    ForEach(songs.prefix(12), id: \.id) { song in
                        Button { playSong(song) } label: {
                            continueListeningRow(song)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func continueListeningRow(_ song: Song) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 48,
                cornerRadius: 8,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(song.artistName ?? String(localized: "unknown_artist"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 6)
        .frame(width: sizeClass == .regular ? 300 : 250, height: 60)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(homeCardSurface)
        }
        .contentShape(Rectangle())
    }

    private var homeCardSurface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func makeRecentSongs() -> [Song] {
        let recent = library.recentlyPlayedSongs(limit: 30)
        if !recent.isEmpty { return recent }
        return Array(library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(30))
    }

    // MARK: - Recently Added Albums

    /// 最近添加 ── 改成 2 列竖向 list 卡片样式 (跟 forYou 横滑大封面错开,
    /// 避免两个 section 视觉一样导致用户混淆)。
    /// 每行: 小封面 + 标题 + 艺术家。点行播放整张专辑。
    private var recentlyAddedAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_added")
                .font(.title3).fontWeight(.bold)
                .padding(.horizontal, 20)

            // iPad regular size class 多列展开,iPhone / 小窗保持 2 列
            LazyVGrid(
                columns: sizeClass == .regular
                    ? [GridItem(.adaptive(minimum: 220), spacing: 12)]
                    : [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ],
                spacing: 12
            ) {
                ForEach(homeSnapshot.recentlyAddedAlbums.prefix(sizeClass == .regular ? 12 : 6)) { tile in
                    Button { playAlbum(tile.album) } label: {
                        recentlyAddedRow(tile: tile)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// 一行的紧凑卡片: 小封面 + 标题 / 艺术家 (2 行 lineLimit)。
    @ViewBuilder
    private func recentlyAddedRow(tile: HomeAlbumTile) -> some View {
        let album = tile.album
        let albumSong = tile.artworkSong
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: albumSong?.coverArtFileName,
                songID: albumSong?.id ?? "",
                size: 56, cornerRadius: 6,
                sourceID: albumSong?.sourceID,
                filePath: albumSong?.filePath,
                fileFormat: albumSong?.fileFormat
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.artistName ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        #if os(iOS)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        #else
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        #endif
    }

    // MARK: - Top Artists

    /// Eight artists, ranked by recent listening — falls back to
    /// alphabetical library order when the user has no playback
    /// history yet (fresh install / no songs cleared the 30s
    /// scrobble threshold). Section title swaps between
    /// "frequently listened" and the generic "artists" depending
    /// which path produced the data.
    private var artistsSection: some View {
        let displayed = homeSnapshot.topArtists
        let titleKey: LocalizedStringKey = homeSnapshot.topArtistsHasHistory ? "home_top_artists_title" : "tab_artists"

        return VStack(alignment: .leading, spacing: 10) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(displayed) { artist in
                        NavigationLink(value: artist) {
                            VStack(spacing: 6) {
                                CachedArtworkView(artistID: artist.id, artistName: artist.name,
                                                  size: 80, cornerRadius: 40)
                                Text(artist.name).font(.caption).lineLimit(1).frame(width: 80)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Map RankedItem (history) to the actual library Artist objects
    /// (NavigationLink needs the Artist value, not the ranked stub).
    /// Match by artist name. Top up with alphabetical leftovers when
    /// history doesn't fill the row.
    private func topArtistsForHome(history: [PlayHistoryStore.RankedItem]) -> [Artist] {
        guard !history.isEmpty else {
            return Array(library.visibleArtists.prefix(8))
        }
        let byName = Dictionary(library.visibleArtists.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Artist] = []
        var seen = Set<String>()
        for item in history {
            if let a = byName[item.title], !seen.contains(a.id) {
                result.append(a)
                seen.insert(a.id)
            }
        }
        if result.count < 8 {
            for a in library.visibleArtists where !seen.contains(a.id) {
                result.append(a)
                seen.insert(a.id)
                if result.count >= 8 { break }
            }
        }
        return result
    }



    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)
            EmptyStateView(
                titleKey: "welcome_title",
                descriptionKey: "home_empty_desc",
                systemImage: "externaldrive.badge.plus",
                actionLabel: "manage_sources",
                action: { switchToSettingsTab?() }
            )
            .padding(.horizontal, 24)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func playAlbum(_ album: Album) {
        // Get songs for the tapped album directly
        var queueSongs = library.songs(forAlbum: album.id)

        // Build queue: tapped album's songs first, then supplement
        if queueSongs.count < 20 {
            let existingIDs = Set(queueSongs.map(\.id))
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }.shuffled()
            queueSongs.append(contentsOf: extra)
        }
        queueSongs = queueSongs.filteredPlayable()
        // The playable filter may drop the album's first track (cloud
        // Phase A bare song). Pull `firstSong` from the filtered list so
        // we never hand the player an entry that isn't in its queue.
        guard let firstSong = queueSongs.first else { return }

        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: 0)
        Task { await player.play(song: firstSong) }
    }

    private func playSong(_ song: Song) {
        plog("🏠 playSong TAPPED: '\(song.title)' id=\(song.id.prefix(12)) path=\(song.filePath)")

        // Build queue from recently played songs, supplemented by library
        var queueSongs = library.recentlyPlayedSongs(limit: 50)
        plog("🏠 recentlyPlayed queue: \(queueSongs.count) songs, first3=\(queueSongs.prefix(3).map(\.title))")

        // If tapped song isn't in recent list, prepend it
        if !queueSongs.contains(where: { $0.id == song.id }) {
            queueSongs.insert(song, at: 0)
            plog("🏠 song not in recent, prepended")
        }

        // Supplement with library songs if queue is too small
        if queueSongs.count < 20 {
            let existingIDs = Set(queueSongs.map(\.id))
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }
            queueSongs.append(contentsOf: extra)
        }

        // Drop non-playable entries so auto-advance can't land on a Phase A
        // bare song. The tapped song itself was already filtered to
        // playable by SongRowView's tap intercept; if it slipped through
        // (recently-played list with stale data) bail rather than crash
        // on an empty queue or play a song that isn't in the queue.
        queueSongs = queueSongs.filteredPlayable()
        guard let startIndex = queueSongs.firstIndex(where: { $0.id == song.id }) else {
            plog("🏠 tapped song dropped by playable filter — skipping")
            return
        }
        plog("🏠 setQueue: \(queueSongs.count) songs, startIndex=\(startIndex), songAtIndex='\(queueSongs[startIndex].title)'")
        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: startIndex)
        let resolved = queueSongs[startIndex]
        plog("🏠 calling player.play(song: '\(resolved.title)')")
        Task { await player.play(song: resolved) }
    }

    private func playLibrary(shuffled: Bool) {
        // Skip cloud songs that haven't been backfilled yet — they have no
        // duration / cover / metadata and would land in the queue with a
        // blank progress bar. Once backfill catches up they become eligible.
        let candidates = library.visibleSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }

        let queueSongs = shuffled ? candidates.shuffled() : candidates
        guard let firstSong = queueSongs.first else { return }

        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: 0)
        Task { await player.play(song: firstSong) }
    }
}
