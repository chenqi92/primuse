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
            VStack(alignment: .leading, spacing: 16) {
                controlsRow(songs)
                MusicVideoGrid(songs: songs, minimumCardWidth: 160, play: { song, list in play(song, in: list) }, addToPlaylist: { playlistSong = $0 })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
        .minimalPageHeader {
            HStack(spacing: 4) {
                MinimalPageTitle("library_music_videos_title")
                Spacer(minLength: 8)
            }
        }
        #endif
    }

    private func countText(_ count: Int) -> String {
        "\(count.formatted()) \(String(localized: "music_videos_count"))"
    }

    // MARK: 播放

    private func play(_ songs: [Song], shuffled: Bool) {
        guard !songs.isEmpty else { return }
        let ids = songs.map(\.id)
        startPlayback(ids: ids, index: 0, order: shuffled ? .shuffled : .asGiven)
    }

    private func play(_ song: Song, in songs: [Song]) {
        let ids = songs.map(\.id)
        guard let index = ids.firstIndex(of: song.id) else { return }
        if player.currentSong?.id == song.id, player.isMusicVideoPlaybackActive {
            if !player.isPlaying { player.togglePlayPause() }
            showNowPlaying()
            return
        }
        startPlayback(ids: ids, index: index, order: .rotatedToStart)
    }

    private func startPlayback(ids: [String], index: Int, order: LargeQueueRequestOrder) {
        Task { await player.playMusicVideos(queueIDs: ids, startingAt: index, order: order) }
        showNowPlaying()
    }

    /// iPhone、iPad 点完直接打开播放页看画面。Mac 由 `MacPlaybackStartPresenter` 按设置处理。
    private func showNowPlaying() {
        #if os(iOS)
        NotificationCenter.default.post(name: .primuseRequestShowNowPlaying, object: nil)
        #endif
    }

    // MARK: 排序

    #if os(iOS)
    private func controlsRow(_ songs: [Song]) -> some View {
        HStack(spacing: 10) {
            Button { play(songs, shuffled: false) } label: {
                Label("play_all", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { play(songs, shuffled: true) } label: {
                Label("shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Menu {
                Picker("sort_by", selection: $sortRawValue) {
                    ForEach(MusicVideoLibrarySort.allCases) { option in
                        Text(option.titleKey).tag(option.rawValue)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("sort_by"))
        }
        .controlSize(.large)
        .disabled(songs.isEmpty)
        .accessibilityIdentifier("library.musicVideos.controls")
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

/// 一张 MV 卡片:16:9 的封面(没有封面时按歌名配色画一个播放图案)、右下角时长、正在放时的标记,
/// 下面是歌名和艺人。
private struct MusicVideoCard: View {
    let song: Song
    let play: () -> Void
    let addToPlaylist: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private static let cornerRadius: CGFloat = 10

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
        return Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background { MusicVideoPlaceholderArtwork(seed: song.title) }
            .overlay {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 360,
                    cornerRadius: 0,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    showsPlaceholder: false,
                    fillsProposedSize: true
                )
            }
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0), location: 0.6),
                    .init(color: .black.opacity(0.45), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if song.duration > 0 {
                    Text(song.duration.formattedDuration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isCurrent {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(tint, in: Circle())
                        .padding(8)
                }
            }
            .clipShape(shape)
            .overlay {
                if isCurrent {
                    shape.strokeBorder(tint, lineWidth: 2)
                }
            }
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

/// 没有封面的 MV:按歌名挑一组颜色,中间一个播放图案,一排卡片不会是一片灰。
private struct MusicVideoPlaceholderArtwork: View {
    let seed: String

    private static let palettes: [(Color, Color)] = [
        (Color(red: 0.20, green: 0.32, blue: 0.62), Color(red: 0.42, green: 0.18, blue: 0.52)),
        (Color(red: 0.12, green: 0.45, blue: 0.52), Color(red: 0.14, green: 0.24, blue: 0.40)),
        (Color(red: 0.58, green: 0.22, blue: 0.30), Color(red: 0.30, green: 0.14, blue: 0.36)),
        (Color(red: 0.62, green: 0.38, blue: 0.16), Color(red: 0.42, green: 0.16, blue: 0.20)),
        (Color(red: 0.18, green: 0.46, blue: 0.34), Color(red: 0.10, green: 0.26, blue: 0.32)),
        (Color(red: 0.36, green: 0.30, blue: 0.62), Color(red: 0.16, green: 0.18, blue: 0.38)),
    ]

    var body: some View {
        let palette = Self.palettes[Self.index(for: seed)]
        LinearGradient(colors: [palette.0, palette.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
            }
    }

    /// 同一首歌每次配同一组颜色;`hashValue` 每次启动都会变,这里自己算。
    private static func index(for seed: String) -> Int {
        var value: UInt32 = 5381
        for scalar in seed.unicodeScalars {
            value = (value &* 33) &+ scalar.value
        }
        return Int(value % UInt32(palettes.count))
    }
}
