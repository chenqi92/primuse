import SwiftUI
import PrimuseKit

/// 首页「最近添加的歌曲」:按入库先后列最近加进来的歌。点一首从它开始往后放,
/// 标题旁的播放键从最新的一首放起(长按可以随机放),和「最近添加」专辑那一块一样一键收听。
/// 排布(列表、横排、网格)、横排行数与首数在界面编辑里调。
struct HomeRecentlyAddedSongsSection: View {
    /// 区块里摆出来的那几首。
    let songs: [Song]
    /// 播放键和点歌时排进队列的歌:比摆出来的多,按入库先后,最新的在前。
    let queue: [Song]
    let style: HomeSectionLayoutStyle
    var rows = 2
    var usesPadMetrics = false
    var isCompactHeight = false
    /// 界面编辑里只看版面,不响应点击。
    var isInteractive = true

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private static let tileHeight: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: style == .grid ? 14 : 10) {
            header
                .padding(.horizontal, 20)
            content
                .allowsHitTesting(isInteractive)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("home_section_recently_added_songs")
                .font(.title3)
                .fontWeight(.bold)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button { play(from: nil, shuffled: false) } label: {
                Label("home_play_recently_added", systemImage: "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(playableQueue.isEmpty)
            .contextMenu {
                Button("play", systemImage: "play.fill") { play(from: nil, shuffled: false) }
                Button("shuffle", systemImage: "shuffle") { play(from: nil, shuffled: true) }
            }
            .accessibilityIdentifier("home.recentSongs.play")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .carousel: carousel
        case .list: list
        case .grid: grid
        }
    }

    // MARK: - 横排

    private var carousel: some View {
        let rowCount = max(1, min(rows, songs.count))
        let width: CGFloat = usesPadMetrics ? 300 : 250
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(
                rows: Array(repeating: GridItem(.fixed(Self.tileHeight), spacing: 10, alignment: .top), count: rowCount),
                spacing: 10
            ) {
                ForEach(songs) { song in
                    PMScrollingButton { play(from: song) } label: {
                        tile(song)
                            .frame(width: width, height: Self.tileHeight)
                    }
                    .contextMenu { songMenu(song) }
                }
            }
            .padding(.horizontal, 20)
        }
        .pmStopsAtVerticalBar()
        .accessibilityIdentifier("home.recentSongs.carousel")
    }

    private func tile(_ song: Song) -> some View {
        HStack(spacing: 10) {
            artwork(song, size: 48, cornerRadius: 8)
            titles(song)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .background(cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 列表

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                PMScrollingButton { play(from: song) } label: { listRow(song) }
                    .contextMenu { songMenu(song) }
                if index < songs.count - 1 {
                    Divider().padding(.leading, 60)
                }
            }
        }
        .padding(.horizontal, 20)
        .accessibilityIdentifier("home.recentSongs.list")
    }

    private func listRow(_ song: Song) -> some View {
        HStack(spacing: 12) {
            artwork(song, size: 48, cornerRadius: 8)
            titles(song)
            Spacer(minLength: 8)
            Text(song.dateAdded, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - 网格

    private var grid: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
            ForEach(songs) { song in
                PMScrollingButton { play(from: song) } label: { gridCard(song) }
                    .contextMenu { songMenu(song) }
            }
        }
        .padding(.horizontal, 20)
        // iPhone Duo 竖栏:最右一列封面伸进竖栏,系统的玻璃胶囊浮在上面。
        .pmCoversExtendUnderVerticalBar()
        .accessibilityIdentifier("home.recentSongs.grid")
    }

    /// 手机竖着拿固定三列;iPad 与横屏按最窄宽度铺。
    private var gridColumns: [GridItem] {
        if usesPadMetrics {
            return [GridItem(.adaptive(minimum: 130), spacing: 14, alignment: .top)]
        }
        if isCompactHeight {
            return [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    }

    private func gridCard(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: 240,
                        cornerRadius: 0,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        fillsProposedSize: true
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
            Text(song.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 6)
            Text(artistName(song))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 零件

    private func artwork(_ song: Song, size: CGFloat, cornerRadius: CGFloat) -> some View {
        CachedArtworkView(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: size,
            cornerRadius: cornerRadius,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat
        )
    }

    private func titles(_ song: Song) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return VStack(alignment: .leading, spacing: 2) {
            Text(song.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Text(artistName(song))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func artistName(_ song: Song) -> String {
        library.artistDisplayName(for: song) ?? String(localized: "unknown_artist")
    }

    @ViewBuilder
    private func songMenu(_ song: Song) -> some View {
        Button("play", systemImage: "play.fill") { play(from: song) }
            .disabled(!song.isPlayable)
        Button("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            player.insertNextInQueue([song])
        }
        .disabled(!song.isPlayable)
        Button("add_to_queue", systemImage: "text.badge.plus") {
            player.appendToQueue([song])
        }
        .disabled(!song.isPlayable)
    }

    private var cardSurface: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    // MARK: - 播放

    private var playableQueue: [Song] {
        queue.filter(\.isPlayable)
    }

    /// 不传歌就从最新的一首放起;点的那首不在队列里(刚被删、不可播)就也从头放。
    private func play(from song: Song?, shuffled: Bool = false) {
        let songs = playableQueue
        guard !songs.isEmpty else { return }
        player.shuffleEnabled = shuffled
        if shuffled {
            let order = player.shufflePlayOrder(songs)
            Task { await player.play(queue: order, startingAt: 0) }
            return
        }
        let index = song.flatMap { picked in songs.firstIndex { $0.id == picked.id } } ?? 0
        Task { await player.play(queue: songs, startingAt: index) }
    }
}
