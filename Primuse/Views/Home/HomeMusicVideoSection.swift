import SwiftUI
import PrimuseKit

enum HomeMusicVideoMetrics {
    /// 一张 MV 卡多宽:手机上露出一张半,iPad 宽一档。骨架估高也按它。
    static func cardWidth(usesPadMetrics: Bool) -> CGFloat {
        usesPadMetrics ? 300 : 246
    }
}

/// 首页「MV」:按常听的艺人、新加进来的挑几支 MV 横着排(`MusicVideoRecommendationPolicy`),
/// 点一支从它开始按 MV 连着放,和资料库 MV 页一样。曲库里没有 MV 时首页不画这一块。
struct HomeMusicVideoSection<Trailing: View>: View {
    let limit: Int
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

    private var refreshKey: String {
        [
            String(library.musicVideoSongs.count),
            library.musicVideoSongs.first?.id ?? "",
            favoriteArtistIDs.prefix(12).joined(separator: ","),
            String(recentlyPlayedIDs.count),
            String(limit),
            String(HomeHeroRecommendationPolicy.dayStamp(Date())),
        ].joined(separator: "#")
    }

    var body: some View {
        let width = HomeMusicVideoMetrics.cardWidth(usesPadMetrics: usesPadMetrics)
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

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(picks) { song in
                        MusicVideoCard(
                            song: song,
                            play: { MusicVideoPlayback.play(song, in: picks, player: player) },
                            addToPlaylist: { playlistSong = song }
                        )
                        .frame(width: width)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }
            .pmStopsAtVerticalBar()
            .allowsHitTesting(isInteractive)
            .accessibilityIdentifier("home.musicVideos.shelf")
        }
        .task(id: refreshKey) { refresh() }
        .sheet(item: $playlistSong) { song in
            AddToPlaylistSheet(song: song)
        }
    }

    private func refresh() {
        let songs = library.musicVideoSongs
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = MusicVideoRecommendationPolicy.recommended(
            songs.map { .init(id: $0.id, artistID: $0.artistID, dateAdded: $0.dateAdded) },
            favoriteArtistIDs: favoriteArtistIDs,
            recentlyPlayedIDs: recentlyPlayedIDs,
            now: Date(),
            day: HomeHeroRecommendationPolicy.dayStamp(Date()),
            limit: limit
        )
        let next = ids.compactMap { byID[$0] }
        if next.map(\.id) != picks.map(\.id) { picks = next }
    }
}
