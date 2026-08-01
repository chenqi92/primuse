#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 歌单 — 4 列磁贴网格(对应 tvos.jsx 的 TVPlaylistsArtboard)。
struct TVPlaylistsView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}

    private let cols = 4
    private let gap: CGFloat = 36

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            GeometryReader { geo in
                let contentW = geo.size.width - TVSpace.pageH * 2
                let cell = (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        VStack(alignment: .leading, spacing: 6) {
                            TVEyebrow(text: PMString("ext.tv.playlists.eyebrow"))
                            Text(PMString("ext.tv.playlists.title", store.playlists.count))
                                .font(TVFont.pageTitle).foregroundStyle(TVColor.text)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols),
                                  alignment: .leading, spacing: gap) {
                            ForEach(store.playlists) { p in
                                TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                            }
                        }
                    }
                    .tvPage()
                }
            }
        }
    }
}

/// 歌单磁贴 — 智能歌单右上角标、我喜欢的整块爱心覆层。
struct TVPlaylistCard: View {
    @Environment(TVStore.self) private var store
    let playlist: TVPlaylist
    var width: CGFloat = 300
    var action: () -> Void = {}

    var body: some View {
        let cover = store.album(playlist.coverAlbumID)
        let coverSong = store.song(playlist.coverSongID)
        let h = width * 0.8
        TVFocusButton(radius: TVRadius.card, scale: 1.08, lift: 12,
                      action: { playTapped() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    TVArtworkView(coverKey: cover?.id ?? "", artist: cover?.artist ?? "",
                                  album: cover?.title ?? "", songID: coverSong?.id ?? playlist.coverSongID,
                                  coverRef: coverSong?.coverRef ?? playlist.coverRef,
                                  tint: cover?.tint ?? TVColor.brand,
                                  tint2: cover?.tint2 ?? .black, glyph: cover?.glyph ?? "♪",
                                  placeholderKind: .playlist,
                                  size: width, height: h)
                    if playlist.kind == .smart {
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles").font(.system(size: 13))
                                    Text(PMString("ext.tv.playlists.smart")).font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.5), in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(12)
                    }
                    if playlist.kind == .liked {
                        LinearGradient(colors: [TVColor.brand.opacity(0.8), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "heart.fill").font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .frame(width: width, height: h)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(PMString("ext.tv.songsCount", playlist.count)).font(.system(size: 16))
                        .foregroundStyle(TVColor.textFaint)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    /// 点击歌单卡片:播放歌单**自身**的曲目(我喜欢的 / 普通歌单),而不是封面取材的那张专辑。
    /// 智能歌单在 tvOS 上尚未求值(无真实歌曲),点击不做任何事,避免静默打开空播放页。
    private func playTapped() {
        // 智能歌单 / 空歌单:无可播放内容,play(playlist:) 返回 false,忽略点击
        //(不退化为播专辑、不打开空播放页),续播队列即该歌单全部曲目。
        guard store.play(playlist: playlist) else { return }
        action()
    }
}
#endif
