#if os(iOS)
import PrimuseKit
import SwiftUI

/// 转轮的「发现」一面:从这首歌出发。这张专辑(点曲目直接放)、这位艺人在曲库里的其他专辑和歌、相似歌曲
/// (本机算法加 Last.fm 命中的曲库内歌曲),有简介时各露几行。
struct NowPlayingCarouselExploreFace: View {
    let context: NowPlayingCarouselFaceContext
    let appearance: NowPlayingAppearance
    let state: NowPlayingCarouselState
    let onOpenAlbum: (Album) -> Void
    let onOpenArtist: (Artist) -> Void
    let onShowAllSimilar: () -> Void

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        if player.currentSong == nil {
            NowPlayingCarouselEmptyNote(
                symbol: "music.note",
                title: "player_carousel_nothing_playing",
                message: nil,
                appearance: appearance
            )
            .frame(maxHeight: .infinity)
        } else {
            NowPlayingCarouselCardStack {
                ForEach(context.cards) { card in
                    cardView(card)
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(_ card: NowPlayingCarouselCard) -> some View {
        switch card {
        case .album:
            NowPlayingCarouselAlbumCard(appearance: appearance, onOpenAlbum: onOpenAlbum)
        case .artist:
            NowPlayingCarouselArtistCard(appearance: appearance, onOpenAlbum: onOpenAlbum, onOpenArtist: onOpenArtist)
        case .similarSongs:
            NowPlayingCarouselSimilarCard(
                isSettled: context.isSettled,
                state: state,
                appearance: appearance,
                onShowAll: onShowAllSimilar
            )
        default:
            EmptyView()
        }
    }
}

// MARK: - 简介摘录

/// 专辑、艺人卡里的简介:露三行,点一下就地展开全文、再点收起。
private struct NowPlayingCarouselInsightExcerpt: View {
    let text: String
    let appearance: NowPlayingAppearance

    @State private var isExpanded = false

    var body: some View {
        Button {
            pmWithAnimation(.list) { isExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: text)
                    .font(.footnote)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(isExpanded ? LocalizedStringKey("player_carousel_show_less") : LocalizedStringKey("more"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(isExpanded ? LocalizedStringKey("player_carousel_show_less") : LocalizedStringKey("more")))
    }
}

/// 存在曲库里的那段简介(用户写的、AI 填的、从音乐源读回来的都算)。没有就是 nil。
@MainActor
private func carouselInsightSummary(for subject: LibraryInsightSubject, in library: MusicLibrary) -> String? {
    let summary = LibraryInsightStore.shared.record(for: subject, in: library)?.summary
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return summary.isEmpty ? nil : summary
}

// MARK: - 专辑

/// 专辑卡:封面、专辑名、年份,下面是曲目,正在放的那首高亮。点曲目从这首开始放整张;点卡头整屏打开专辑。
private struct NowPlayingCarouselAlbumCard: View {
    let appearance: NowPlayingAppearance
    let onOpenAlbum: (Album) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var showsAllTracks = false

    /// 曲目多时先列这么多首(以正在放的那首为中心),其余点「全部」展开。
    private static let collapsedTrackCount = 8

    var body: some View {
        let song = player.currentSong
        let album = song.flatMap {
            library.linkedAlbum(for: $0) ?? AppServices.shared.appleMusicLibrary.catalogAlbum(forCatalogOnlySong: $0)
        }
        let tracks = album.map { library.songs(forAlbum: $0.id) } ?? []

        NowPlayingCarouselCardContainer(card: .album, appearance: appearance, contentPadding: false) {
            if let album {
                VStack(alignment: .leading, spacing: 10) {
                    header(album, trackCount: tracks.count)
                        .padding(.horizontal, 16)
                    if let summary = carouselInsightSummary(for: LibraryInsightBatchItem.album(album).subject, in: library) {
                        NowPlayingCarouselInsightExcerpt(text: summary, appearance: appearance)
                            .padding(.horizontal, 16)
                    }
                    if !tracks.isEmpty {
                        trackList(tracks, currentID: song?.id)
                    }
                }
            } else {
                NowPlayingCarouselEmptyNote(
                    symbol: "square.stack",
                    title: "player_carousel_no_album",
                    message: nil,
                    appearance: appearance
                )
            }
        }
    }

    private func header(_ album: Album, trackCount: Int) -> some View {
        Button { onOpenAlbum(album) } label: {
            HStack(spacing: 14) {
                // 和曲库的专辑格一样:专辑自己没缓存封面时用专辑里的歌的封面。
                AlbumArtworkView(album: album, size: 72, cornerRadius: 10)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: album.title)
                        .font(.headline)
                        .foregroundStyle(appearance.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let artist = album.artistName, !artist.isEmpty {
                        Text(verbatim: artist)
                            .font(.subheadline)
                            .foregroundStyle(appearance.secondary)
                            .lineLimit(1)
                    }
                    let facts = Self.facts(album, trackCount: trackCount)
                    if !facts.isEmpty {
                        Text(verbatim: facts)
                            .font(.caption)
                            .foregroundStyle(appearance.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(appearance.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pmPressable)
        .accessibilityHint(Text("go_to_album"))
    }

    @ViewBuilder
    private func trackList(_ tracks: [Song], currentID: String?) -> some View {
        let visible = showsAllTracks ? tracks : Self.window(of: tracks, around: currentID)
        VStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { _, track in
                let number = track.trackNumber ?? ((tracks.firstIndex { $0.id == track.id } ?? 0) + 1)
                Button { play(tracks, startingAt: track) } label: {
                    NowPlayingCarouselSongRow(
                        song: track,
                        detail: nil,
                        leading: .trackNumber(number),
                        isCurrent: track.id == currentID,
                        appearance: appearance,
                        horizontalPadding: 16
                    )
                }
                .buttonStyle(NowPlayingCarouselRowButtonStyle(appearance: appearance, inset: 6))
            }
            if tracks.count > Self.collapsedTrackCount {
                Button {
                    pmWithAnimation(.list) { showsAllTracks.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showsAllTracks
                             ? LocalizedStringKey("player_carousel_show_less")
                             : LocalizedStringKey("player_carousel_all_tracks \(tracks.count)"))
                        Image(systemName: showsAllTracks ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 收起时列出来的几首:正在放的那首尽量排在第二、三行,前后各带几首。
    private static func window(of tracks: [Song], around currentID: String?) -> [Song] {
        guard tracks.count > collapsedTrackCount else { return tracks }
        let current = tracks.firstIndex { $0.id == currentID } ?? 0
        let start = min(max(current - 2, 0), tracks.count - collapsedTrackCount)
        return Array(tracks[start..<(start + collapsedTrackCount)])
    }

    private static func facts(_ album: Album, trackCount: Int) -> String {
        var facts: [String] = []
        if let year = album.year, year > 0 { facts.append(String(year)) }
        if trackCount > 0 { facts.append(String(localized: "player_carousel_song_count \(trackCount)")) }
        return facts.joined(separator: " · ")
    }

    private func play(_ songs: [Song], startingAt song: Song) {
        let queue = songs.filteredPlayable()
        guard !queue.isEmpty else { return }
        let index = queue.firstIndex { $0.id == song.id } ?? 0
        Task { await player.play(queue: queue, startingAt: index) }
    }
}

// MARK: - 艺人

/// 艺人卡:照片、名字,这位艺人在曲库里的其他专辑(横着滑)和几首别的歌。点卡头去艺人页。
private struct NowPlayingCarouselArtistCard: View {
    let appearance: NowPlayingAppearance
    let onOpenAlbum: (Album) -> Void
    let onOpenArtist: (Artist) -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    private static let albumLimit = 12
    private static let songLimit = 5

    var body: some View {
        let song = player.currentSong
        let artist = song.flatMap { library.linkedArtists(for: $0).first }

        NowPlayingCarouselCardContainer(card: .artist, appearance: appearance, contentPadding: false) {
            if let artist, let song {
                let catalog = Self.catalog(of: artist, excluding: song, in: library)
                VStack(alignment: .leading, spacing: 12) {
                    header(artist, catalog: catalog)
                        .padding(.horizontal, 16)
                    if let summary = carouselInsightSummary(for: LibraryInsightBatchItem.artist(artist).subject, in: library) {
                        NowPlayingCarouselInsightExcerpt(text: summary, appearance: appearance)
                            .padding(.horizontal, 16)
                    }
                    if !catalog.albums.isEmpty {
                        albumShelf(catalog.albums)
                    }
                    if !catalog.otherSongs.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(catalog.otherSongs) { track in
                                Button { play(catalog.otherSongs, startingAt: track) } label: {
                                    NowPlayingCarouselSongRow(
                                        song: track,
                                        detail: track.albumTitle,
                                        leading: .artwork,
                                        isCurrent: false,
                                        appearance: appearance,
                                        horizontalPadding: 16
                                    )
                                }
                                .buttonStyle(NowPlayingCarouselRowButtonStyle(appearance: appearance, inset: 6))
                            }
                        }
                    }
                }
            } else {
                NowPlayingCarouselEmptyNote(
                    symbol: "music.mic",
                    title: "player_carousel_no_artist",
                    message: nil,
                    appearance: appearance
                )
            }
        }
    }

    private func header(_ artist: Artist, catalog: Catalog) -> some View {
        Button { onOpenArtist(artist) } label: {
            HStack(spacing: 14) {
                ArtistArtworkView(artist: artist, size: 60, cornerRadius: 30)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: artist.name)
                        .font(.headline)
                        .foregroundStyle(appearance.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: Self.facts(songCount: catalog.songCount, albumCount: catalog.albumCount))
                        .font(.caption)
                        .foregroundStyle(appearance.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(appearance.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pmPressable)
        .accessibilityHint(Text("go_to_artist"))
    }

    private func albumShelf(_ albums: [Album]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    Button { onOpenAlbum(album) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            AlbumArtworkView(album: album, size: 96, cornerRadius: 10)
                            .frame(width: 96, height: 96)
                            Text(verbatim: album.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(appearance.primary)
                                .lineLimit(1)
                            if let year = album.year, year > 0 {
                                Text(verbatim: String(year))
                                    .font(.caption2)
                                    .foregroundStyle(appearance.tertiary)
                            }
                        }
                        .frame(width: 96, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pmPressable)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .nowPlayingCarouselHorizontalRegion()
    }

    struct Catalog {
        var albums: [Album]
        var otherSongs: [Song]
        var songCount: Int
        var albumCount: Int
    }

    /// 这位艺人的其他专辑(不含正在放的这张,新的在前)和不在这张专辑里的几首歌。
    private static func catalog(of artist: Artist, excluding song: Song, in library: MusicLibrary) -> Catalog {
        let songs = library.songs(forArtist: artist.id)
        var albumIDs: [String] = []
        var seenAlbumIDs = Set<String>()
        for track in songs {
            guard let albumID = track.albumID, seenAlbumIDs.insert(albumID).inserted else { continue }
            albumIDs.append(albumID)
        }
        let albums = albumIDs
            .filter { $0 != song.albumID }
            .compactMap { library.visibleAlbum(id: $0) }
            .sorted { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.title < $1.title }
        let others = songs.lazy
            .filter { $0.id != song.id && $0.albumID != song.albumID }
            .prefix(songLimit)
        return Catalog(
            albums: Array(albums.prefix(albumLimit)),
            otherSongs: Array(others),
            songCount: songs.count,
            albumCount: albumIDs.count
        )
    }

    private static func facts(songCount: Int, albumCount: Int) -> String {
        var facts: [String] = []
        if songCount > 0 { facts.append(String(localized: "player_carousel_song_count \(songCount)")) }
        if albumCount > 0 { facts.append(String(localized: "player_carousel_album_count \(albumCount)")) }
        return facts.joined(separator: " · ")
    }

    private func play(_ songs: [Song], startingAt song: Song) {
        let queue = songs.filteredPlayable()
        guard !queue.isEmpty else { return }
        let index = queue.firstIndex { $0.id == song.id } ?? 0
        Task { await player.play(queue: queue, startingAt: index) }
    }
}

// MARK: - 相似歌曲

/// 相似歌曲:本机按标签算的、Last.fm 听众重叠里曲库有的,两路轮流排(同专辑、同艺人限量),和「更多 › 相似歌曲」
/// 同一份数据。两颗大按钮直接放相似混合或歌曲电台;列表点哪首就从哪首开始放这一串。
private struct NowPlayingCarouselSimilarCard: View {
    let isSettled: Bool
    let state: NowPlayingCarouselState
    let appearance: NowPlayingAppearance
    let onShowAll: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    /// 这张卡挂上时的那首歌。在这里点歌播放后列表不跟着换,免得点到一半整列都变了。
    @State private var seed: Song?
    @State private var localResults: [MusicDiscoveryResult]?
    @State private var lastFmSongs: [Song] = []
    @State private var isLoadingLastFm = false
    @State private var isBuildingRadio = false

    private static let visibleCount = 8

    var body: some View {
        let mixed = mixedResults
        NowPlayingCarouselCardContainer(
            card: .similarSongs,
            appearance: appearance,
            subtitle: seed.map { String(localized: "player_carousel_similar_seed \($0.title)") },
            contentPadding: false
        ) {
            if !mixed.isEmpty {
                Button(action: onShowAll) {
                    Text("player_carousel_see_all")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.secondary)
                }
                .buttonStyle(.plain)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if localResults != nil {
                    if mixed.isEmpty, !isLoadingLastFm {
                        NowPlayingCarouselEmptyNote(
                            symbol: "sparkles",
                            title: "similar_songs_empty",
                            message: "similar_songs_empty_desc",
                            appearance: appearance
                        )
                    } else {
                        HStack(spacing: 10) {
                            NowPlayingCarouselCapsuleButton(
                                title: "start_similar_mix",
                                symbol: "play.fill",
                                isProminent: true,
                                appearance: appearance
                            ) {
                                guard let seed else { return }
                                startQueue(queue(startingWith: seed))
                            }
                            NowPlayingCarouselCapsuleButton(
                                title: "start_song_radio",
                                symbol: "dot.radiowaves.left.and.right",
                                isProminent: false,
                                isBusy: isBuildingRadio,
                                appearance: appearance
                            ) {
                                startRadio()
                            }
                        }
                        .padding(.horizontal, 16)

                        VStack(spacing: 0) {
                            ForEach(mixed.prefix(Self.visibleCount)) { result in
                                Button { startQueue(queue(startingWith: result.song)) } label: {
                                    NowPlayingCarouselSongRow(
                                        song: result.song,
                                        detail: detail(for: result),
                                        leading: .artwork,
                                        isCurrent: player.currentSong?.id == result.song.id,
                                        appearance: appearance,
                                        horizontalPadding: 16,
                                        showsDuration: false
                                    )
                                }
                                .buttonStyle(NowPlayingCarouselRowButtonStyle(appearance: appearance, inset: 6))
                            }
                        }
                    }
                    if isLoadingLastFm {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("similar_loading")
                                .font(.caption)
                                .foregroundStyle(appearance.secondary)
                        }
                        .padding(.horizontal, 16)
                    } else if !lastFmSongs.isEmpty {
                        Text("similar_source_lastfm")
                            .font(.caption2)
                            .foregroundStyle(appearance.tertiary)
                            .padding(.horizontal, 16)
                    }
                } else {
                    NowPlayingCarouselLoadingRows(appearance: appearance)
                        .padding(.horizontal, 16)
                }
            }
        }
        .onAppear {
            if seed == nil { seed = player.currentSong }
        }
        .task(id: TaskKey(seedID: seed?.id, isSettled: isSettled)) {
            await loadLocal()
        }
        .task(id: TaskKey(seedID: seed?.id, isSettled: isSettled)) {
            await loadLastFm()
        }
    }

    private struct TaskKey: Equatable {
        let seedID: String?
        let isSettled: Bool
    }

    /// 两路轮流排出来的那一串(不含种子歌)。
    private var mixedResults: [MusicDiscoveryResult] {
        guard let seed, let localResults else { return [] }
        let lastFm = lastFmSongs.map { MusicDiscoveryResult(song: $0, score: 0, reasons: []) }
        return MusicDiscoveryEngine.mixed(
            seed: seed,
            sources: [lastFm, localResults],
            limit: 40,
            limits: .similarList
        )
    }

    private func detail(for result: MusicDiscoveryResult) -> String {
        if result.reasons.isEmpty { return "Last.fm" }
        return String(localized: LocalizedStringResource(stringLiteral: result.primaryReason.localizationKey))
    }

    private func loadLocal() async {
        guard let seed else {
            localResults = []
            return
        }
        if let cached = state.similarResults[seed.id] {
            localResults = cached
            return
        }
        // 整库扫描在主线程上,只在停稳后才算,转动途中不卡。
        guard isSettled else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        let computed = MusicDiscoveryEngine.similarSongs(to: seed, in: library, limit: 30)
        state.similarResults[seed.id] = computed
        localResults = computed
    }

    private func loadLastFm() async {
        guard let seed else { return }
        if let cached = state.lastFmSimilar[seed.id] {
            lastFmSongs = cached
            return
        }
        guard isSettled, !LastFmCredentialsStore.effectiveAPIKey().isEmpty else { return }
        isLoadingLastFm = true
        defer { isLoadingLastFm = false }
        let candidates = try? await AppServices.shared.similarTracks.fetchSimilar(
            to: seed,
            limit: 30,
            library: library.musicSongs,
            excluding: library.dislikedSongIDs,
            includeUnmatched: false
        )
        guard !Task.isCancelled else { return }
        let songs = (candidates ?? []).compactMap(\.librarySong)
        state.lastFmSimilar[seed.id] = songs
        lastFmSongs = songs
    }

    /// 从 `first` 开始,后面接两路轮流排的相似歌曲。
    private func queue(startingWith first: Song) -> [Song] {
        guard let seed, let localResults else { return [first] }
        let lastFm = lastFmSongs.map { MusicDiscoveryResult(song: $0, score: 0, reasons: []) }
        let tail = MusicDiscoveryEngine.mixed(
            seed: first,
            sources: [lastFm, localResults],
            excluding: first.id == seed.id ? [] : [seed.id],
            limit: 40,
            limits: .similarList
        )
        return ([first] + tail.map(\.song)).filteredPlayable()
    }

    private func startQueue(_ queue: [Song]) {
        guard !queue.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func startRadio() {
        guard let seed, !isBuildingRadio else { return }
        isBuildingRadio = true
        Task { @MainActor in
            await Task.yield()
            let queue = await SongRadioBuilder.queue(from: seed, in: library, limit: 48).filteredPlayable()
            isBuildingRadio = false
            startQueue(queue)
        }
    }
}
#endif
