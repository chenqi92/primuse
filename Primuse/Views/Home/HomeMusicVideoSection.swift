import SwiftUI
import PrimuseKit

enum HomeMusicVideoMetrics {
    /// 一张 MV 卡多宽:手机上露出一张半,iPad 宽一档。骨架估高也按它。
    static func cardWidth(usesPadMetrics: Bool) -> CGFloat {
        usesPadMetrics ? 300 : 246
    }
}

/// 首页「MV」:按常听的艺人、新加进来的挑几支 MV(`MusicVideoRecommendationPolicy`),
/// 横着排、两列网格或列表(界面编辑里选),点一支从它开始按 MV 连着放,和资料库 MV 页一样。
/// 曲库里没有 MV 时首页不画这一块。
struct HomeMusicVideoSection<Trailing: View>: View {
    let limit: Int
    var style: HomeSectionLayoutStyle = .carousel
    let usesPadMetrics: Bool
    /// 常听的艺人,越靠前越常听(首页「常听艺人」那一份)。
    let favoriteArtistIDs: [String]
    /// 最近放过的歌,刚看过的排到后面。
    let recentlyPlayedIDs: Set<String>
    /// 界面编辑里只看版面,不响应点击。
    var isInteractive = true
    @ViewBuilder let trailing: () -> Trailing

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @State private var picks: [Song] = []
    @State private var playlistSong: Song?

    var body: some View {
        let width = HomeMusicVideoMetrics.cardWidth(usesPadMetrics: usesPadMetrics)
        let request = MusicVideoRecommendationPolicy.Request(
            catalogRevision: library.musicVideoContentRevision, favoriteArtistIDs: favoriteArtistIDs,
            recentlyPlayedIDs: recentlyPlayedIDs, day: HomeHeroRecommendationPolicy.dayStamp(Date()), limit: limit
        )
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("home_section_music_videos")
                    .font(.title3)
                    .fontWeight(.bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 20)

            Group {
                switch style {
                case .carousel:
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(picks) { song in
                                card(song).frame(width: width)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                    }
                    .pmStopsAtVerticalBar()
                case .grid:
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 18) {
                        ForEach(picks) { song in card(song) }
                    }
                    .padding(.horizontal, 20)
                    .pmCoversExtendUnderVerticalBar()
                case .list:
                    VStack(spacing: 0) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { index, song in
                            MusicVideoListRow(
                                song: song,
                                play: { MusicVideoPlayback.play(song, in: picks, player: player) },
                                addToPlaylist: { playlistSong = song }
                            )
                            if index < picks.count - 1 {
                                Divider().padding(.leading, 140)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .allowsHitTesting(isInteractive)
            .accessibilityIdentifier("home.musicVideos.shelf")
        }
        .task(id: request) {
            let next = await request.picks(from: library.musicVideoSongs, now: Date())
            guard !Task.isCancelled else { return }
            picks = next
        }
        .sheet(item: $playlistSong) { song in
            AddToPlaylistSheet(song: song)
        }
    }

    private func card(_ song: Song) -> some View {
        MusicVideoCard(
            song: song,
            play: { MusicVideoPlayback.play(song, in: picks, player: player) },
            addToPlaylist: { playlistSong = song }
        )
    }

    /// 手机两列;iPad 按最窄宽度铺。
    private var gridColumns: [GridItem] {
        if usesPadMetrics {
            return [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 2)
    }

}

/// 首页 MV 列表的一行:左边一小块画面(带时长),右边歌名、艺人。点一行从它开始放。
struct MusicVideoListRow: View {
    let song: Song
    let play: () -> Void
    let addToPlaylist: () -> Void

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let isCurrent = player.currentSong?.id == song.id
        PMScrollingButton(action: play) {
            HStack(spacing: 12) {
                MusicVideoThumbnail(song: song, artworkSize: 240, glyphSize: 18)
                    .frame(width: 128)
                    .overlay(alignment: .bottomTrailing) {
                        if song.duration > 0 {
                            Text(song.duration.formattedDuration)
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.black.opacity(0.5), in: Capsule())
                                .padding(5)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                    Text(library.artistDisplayName(for: song) ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isCurrent && player.isPlaying ? "speaker.wave.2.fill" : "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .contextMenu {
            Button(action: play) { Label("play", systemImage: "play.fill") }
                .disabled(!song.isPlayable)
            Button { player.insertNextInQueue([song]) } label: {
                Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(!song.isPlayable)
            Button { player.appendToQueue([song]) } label: {
                Label("add_to_queue", systemImage: "text.badge.plus")
            }
            .disabled(!song.isPlayable)
            Button(action: addToPlaylist) { Label("add_to_playlist", systemImage: "music.note.list") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: song.title))
        .accessibilityAddTraits(.isButton)
    }
}
