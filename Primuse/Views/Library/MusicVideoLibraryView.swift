import PrimuseKit
import SwiftUI

/// 资料库的「MV」分类(iPhone、iPad、Mac;电视在 `TVLibraryView` 里另有一份)。
///
/// 独立 MV 和带同名 MV 的歌排成 16:9 的视频卡片,点一张就从它开始按 MV 连着放:带同名 MV 的歌
/// 也直接出画面。iPhone、iPad 点完打开播放页;Mac 由主窗口按设置决定直接全屏还是打开播放页
/// (`MacPlaybackStartPresenter`)。
struct MusicVideoLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(MusicVideoLibrarySort.storageKey) private var sortRawValue = MusicVideoLibrarySort.recentlyAdded.rawValue
    @State private var playlistSong: Song?
    #if os(iOS)
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.librarySectionRailActive) private var sectionRailActive
    #endif

    private var sort: MusicVideoLibrarySort {
        MusicVideoLibrarySort(rawValue: sortRawValue) ?? .recentlyAdded
    }

    var body: some View {
        let songs = sort.sorted(library.musicVideoSongs)
        ScrollView {
            #if os(macOS)
            MacLibraryHeader(
                eyebrow: "library_title",
                title: String(localized: "library_music_videos_title"),
                subtitle: countText(songs.count),
                iconSystemName: "play.rectangle.fill",
                coverSong: songs.first,
                onPlay: { play(songs, shuffled: false) },
                onShuffle: { play(songs, shuffled: true) },
                makeMoreMenu: { macSortMenu }
            )
            MusicVideoGrid(songs: songs, minimumCardWidth: 230, play: { song, list in play(song, in: list) }, addToPlaylist: { playlistSong = $0 })
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.l)
                .padding(.bottom, 32)
            #else
            VStack(alignment: .leading, spacing: 22) {
                let featured = Self.featuredSong(in: library.musicVideoSongs)
                if let featured {
                    MusicVideoFeatureCard(
                        song: featured,
                        eyebrow: "music_videos_latest",
                        play: { play(featured, in: songs) }
                    )
                }
                let rest = songs.filter { $0.id != featured?.id }
                if !rest.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        gridHeader(count: songs.count)
                        MusicVideoGrid(songs: rest, minimumCardWidth: 160, play: { song, _ in play(song, in: songs) }, addToPlaylist: { playlistSong = $0 })
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            #endif
        }
        .overlay {
            if songs.isEmpty {
                ContentUnavailableView(
                    "library_music_videos_title",
                    systemImage: "play.rectangle",
                    description: Text("music_videos_empty_hint")
                )
            }
        }
        .sheet(item: $playlistSong) { song in
            AddToPlaylistSheet(song: song)
        }
        #if os(macOS)
        .background(PMColor.bg.ignoresSafeArea())
        #endif
        #if os(iOS)
        .navigationTitle("library_music_videos_title")
        .navigationBarTitleDisplayMode(.inline)
        // 全部播放、随机放在右上角,和资料库别的页一样;顶上大卡只管放它自己那一支。
        .toolbar {
            if sectionRailActive {
                // 资料库分类在 Duo 竖栏里时两颗键收进一个「⋯」,竖栏中间留给分类。
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        playbackButtons(songs, titled: true)
                    } label: {
                        PMToolbarItemLabel("a11y_more_actions", systemImage: "ellipsis", titled: true)
                    }
                    .accessibilityIdentifier("library.musicVideos.more")
                }
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    playbackButtons(songs, titled: verticalBarEdge != nil)
                }
            }
        }
        .minimalPageHeader {
            HStack(spacing: 4) {
                MinimalPageTitle("library_music_videos_title")
                Spacer(minLength: 8)
                MinimalHeaderActions {
                    playbackButtons(songs, titled: false)
                }
            }
        }
        #endif
    }

    private func countText(_ count: Int) -> String {
        "\(count.formatted()) \(String(localized: "music_videos_count"))"
    }

    /// 顶上那张大卡放最新加进来的那支,不随排序、也不随正在放的变,点了网格里的卡片版面不跳。
    private static func featuredSong(in songs: [Song]) -> Song? {
        songs.max { $0.dateAdded < $1.dateAdded }
    }

    // MARK: 播放

    private func play(_ songs: [Song], shuffled: Bool) {
        MusicVideoPlayback.play(songs, shuffled: shuffled, player: player)
    }

    private func play(_ song: Song, in songs: [Song]) {
        MusicVideoPlayback.play(song, in: songs, player: player)
    }

    // MARK: 排序

    #if os(iOS)
    @ViewBuilder
    private func playbackButtons(_ songs: [Song], titled: Bool) -> some View {
        Button { play(songs, shuffled: true) } label: {
            PMToolbarItemLabel("shuffle", systemImage: "shuffle", titled: titled)
        }
        .disabled(songs.count < 2)
        .accessibilityLabel(Text("shuffle"))
        .accessibilityIdentifier("library.musicVideos.shuffle")
        Button { play(songs, shuffled: false) } label: {
            PMToolbarItemLabel("play_all", systemImage: "play.fill", titled: titled)
        }
        .disabled(songs.isEmpty)
        .accessibilityLabel(Text("play_all"))
        .accessibilityIdentifier("library.musicVideos.playAll")
    }

    /// 网格上面一行:「全部 MV」和个数,右边排序。
    private func gridHeader(count: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("music_videos_all")
                    .font(.title3.weight(.bold))
                Text(verbatim: countText(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Menu {
                Picker("sort_by", selection: $sortRawValue) {
                    ForEach(MusicVideoLibrarySort.allCases) { option in
                        Label(option.titleKey, systemImage: option.systemImage).tag(option.rawValue)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sort.titleKey)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel(Text("sort_by"))
            .accessibilityIdentifier("library.musicVideos.sort")
        }
    }
    #endif

    #if os(macOS)
    private var macSortMenu: AnyView {
        AnyView(MacHeaderMoreMenu(sections: [
            MusicVideoLibrarySort.allCases.map { option -> MacHeaderMoreMenu.Item in
                MacHeaderMoreMenu.Item(
                    icon: option == sort ? "checkmark" : option.systemImage,
                    title: String(localized: option.titleResource),
                    action: { sortRawValue = option.rawValue }
                )
            }
        ]))
    }
    #endif
}

/// 按 MV 连着放:资料库 MV 页、首页「MV」一排、智能推荐里的 MV 共用。先开 MV 模式,
/// 之后点到带同名 MV 的歌也出画面。
@MainActor
enum MusicVideoPlayback {
    static func play(_ songs: [Song], shuffled: Bool, player: AudioPlayerService) {
        guard !songs.isEmpty else { return }
        start(ids: songs.map(\.id), index: 0, order: shuffled ? .shuffled : .asGiven, player: player)
    }

    /// 点的正是在放的那支 MV 时只是接着放、打开播放页。
    static func play(_ song: Song, in songs: [Song], player: AudioPlayerService) {
        let ids = songs.map(\.id)
        guard let index = ids.firstIndex(of: song.id) else { return }
        if player.currentSong?.id == song.id, player.isMusicVideoPlaybackActive {
            if !player.isPlaying { player.togglePlayPause() }
            showNowPlaying()
            return
        }
        start(ids: ids, index: index, order: .rotatedToStart, player: player)
    }

    private static func start(ids: [String], index: Int, order: LargeQueueRequestOrder, player: AudioPlayerService) {
        Task { await player.playMusicVideos(queueIDs: ids, startingAt: index, order: order) }
        showNowPlaying()
    }

    /// iPhone、iPad 点完直接打开播放页看画面。Mac 由 `MacPlaybackStartPresenter` 按设置处理。
    private static func showNowPlaying() {
        #if os(iOS)
        NotificationCenter.default.post(name: .primuseRequestShowNowPlaying, object: nil)
        #endif
    }
}

/// MV 页的排序。默认按添加时间,最新的在前。
enum MusicVideoLibrarySort: String, CaseIterable, Identifiable {
    case recentlyAdded
    case title
    case artist

    static let storageKey = "primuse.library.musicVideos.sort"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .recentlyAdded: "sort_date_added"
        case .title: "sort_title"
        case .artist: "sort_artist"
        }
    }

    var titleResource: String.LocalizationValue {
        switch self {
        case .recentlyAdded: "sort_date_added"
        case .title: "sort_title"
        case .artist: "sort_artist"
        }
    }

    var systemImage: String {
        switch self {
        case .recentlyAdded: "clock"
        case .title: "textformat"
        case .artist: "music.mic"
        }
    }

    func sorted(_ songs: [Song]) -> [Song] {
        switch self {
        case .recentlyAdded:
            return songs.sorted { $0.dateAdded > $1.dateAdded }
        case .title:
            return songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            return songs.sorted { lhs, rhs in
                let order = (lhs.artistName ?? "").localizedStandardCompare(rhs.artistName ?? "")
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }
}

/// MV 卡片网格。卡片各自读播放状态,换歌、暂停时只重画卡片,不重排整份列表。
private struct MusicVideoGrid: View {
    let songs: [Song]
    let minimumCardWidth: CGFloat
    let play: (Song, [Song]) -> Void
    let addToPlaylist: (Song) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumCardWidth, maximum: minimumCardWidth * 1.6), spacing: 16)],
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(songs) { song in
                MusicVideoCard(
                    song: song,
                    play: { play(song, songs) },
                    addToPlaylist: { addToPlaylist(song) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// MV 的 16:9 画面:有封面铺满裁切,没有封面按歌名配一块有层次的色块。卡片与顶上大卡共用。
struct MusicVideoThumbnail: View {
    let song: Song
    var artworkSize: CGFloat = 360
    var glyphSize: CGFloat = 28

    var body: some View {
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background { MusicVideoPlaceholderArtwork(seed: song.title, glyphSize: glyphSize) }
            .overlay {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: artworkSize,
                    cornerRadius: 0,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    showsPlaceholder: false,
                    fillsProposedSize: true
                )
            }
            .clipped()
    }
}

#if os(iOS)
/// MV 页顶上的大卡:画面铺满,底下压一层渐变写歌名、艺人,右下角一颗播放键。
/// 点哪儿都是从这一支开始放;全部播放和随机在右上角。
private struct MusicVideoFeatureCard: View {
    let song: Song
    let eyebrow: LocalizedStringKey
    let play: () -> Void

    @Environment(MusicLibrary.self) private var library

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            Button(action: play) {
                MusicVideoThumbnail(song: song, artworkSize: 720, glyphSize: 46)
                    .overlay {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0), location: 0.25),
                            .init(color: .black.opacity(0.5), location: 0.62),
                            .init(color: .black.opacity(0.82), location: 1),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .contentShape(shape)
            }
            .buttonStyle(.pmPressable)
            .accessibilityLabel(Text(verbatim: song.title))
            .accessibilityHint(Text("play"))

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow)
                        .font(.caption.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(song.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 44, height: 44)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
            .padding(16)
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
        .accessibilityIdentifier("library.musicVideos.featured")
    }
}
#endif

/// 一张 MV 卡片:16:9 的画面(没有封面时按歌名配色)、右下角时长、正在放时的标记,
/// 下面是歌名和艺人。
struct MusicVideoCard: View {
    let song: Song
    let play: () -> Void
    let addToPlaylist: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private static let cornerRadius: CGFloat = 12

    private var tint: Color {
        #if os(macOS)
        PMColor.brand
        #else
        Color.accentColor
        #endif
    }

    private var accessibilityTitle: String {
        guard let artist = library.artistDisplayName(for: song) else { return song.title }
        return song.title + ", " + artist
    }

    var body: some View {
        let isCurrent = player.currentSong?.id == song.id
        PMScrollingButton(action: play) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail(isCurrent: isCurrent)
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? tint : Color.primary)
                    .lineLimit(1)
                    .padding(.top, 8)
                Text(library.artistDisplayName(for: song) ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        .pmHoverLift()
        #endif
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityTitle))
        .accessibilityAddTraits(.isButton)
    }

    private func thumbnail(isCurrent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return MusicVideoThumbnail(song: song)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0), location: 0.62),
                    .init(color: .black.opacity(0.4), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if song.duration > 0 {
                    Text(song.duration.formattedDuration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isCurrent {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(tint, in: Circle())
                        .padding(7)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(isCurrent ? tint : Color.primary.opacity(0.06), lineWidth: isCurrent ? 2 : 0.5)
            }
            .shadow(color: .black.opacity(0.1), radius: 5, y: 3)
    }

    @ViewBuilder
    private var menu: some View {
        Button(action: play) {
            Label("play", systemImage: "play.fill")
        }
        .disabled(!song.isPlayable)
        Button {
            player.insertNextInQueue([song])
        } label: {
            Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(!song.isPlayable)
        Button {
            player.appendToQueue([song])
        } label: {
            Label("add_to_queue", systemImage: "text.badge.plus")
        }
        .disabled(!song.isPlayable)
        Button(action: addToPlaylist) {
            Label("add_to_playlist", systemImage: "music.note.list")
        }
    }
}

/// 没有封面的 MV:按歌名挑一组深色,左上角一道柔光,中间一个淡淡的电视音符,一排卡片不会是一片灰,
/// 也不会花成一块块撞色。
struct MusicVideoPlaceholderArtwork: View {
    let seed: String
    var glyphSize: CGFloat = 28

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.26, green: 0.30, blue: 0.52), Color(red: 0.10, green: 0.11, blue: 0.22)),
        (Color(red: 0.16, green: 0.40, blue: 0.46), Color(red: 0.06, green: 0.15, blue: 0.20)),
        (Color(red: 0.50, green: 0.24, blue: 0.32), Color(red: 0.17, green: 0.08, blue: 0.14)),
        (Color(red: 0.52, green: 0.36, blue: 0.20), Color(red: 0.19, green: 0.11, blue: 0.08)),
        (Color(red: 0.20, green: 0.40, blue: 0.32), Color(red: 0.07, green: 0.15, blue: 0.13)),
        (Color(red: 0.38, green: 0.28, blue: 0.54), Color(red: 0.12, green: 0.09, blue: 0.22)),
    ]

    var body: some View {
        let palette = Self.palettes[Self.index(for: seed)]
        ZStack {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0)],
                center: UnitPoint(x: 0.18, y: 0.1),
                startRadius: 0,
                endRadius: 260
            )
            Image(systemName: "music.note.tv")
                .font(.system(size: glyphSize, weight: .light))
                .foregroundStyle(.white.opacity(0.38))
        }
    }

    /// 同一首歌每次配同一组颜色;`hashValue` 每次启动都会变,这里自己算。
    static func index(for seed: String) -> Int {
        var value: UInt32 = 5381
        for scalar in seed.unicodeScalars {
            value = (value &* 33) &+ scalar.value
        }
        return Int(value % UInt32(palettes.count))
    }
}
