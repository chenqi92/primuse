#if os(tvOS)
import SwiftUI

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
                            TVEyebrow(text: TVL("歌单", "Playlists"))
                            Text(TVL("你的歌单 · \(store.playlists.count)", "Your Playlists · \(store.playlists.count)"))
                                .font(TVFont.pageTitle).foregroundStyle(.white)
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
        let h = width * 0.8
        TVFocusButton(radius: TVRadius.card, scale: 1.08, lift: 12,
                      action: { if let a = store.album(playlist.coverAlbumID) { store.play(album: a) }; action() }) { _ in
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    TVArtworkView(coverKey: cover?.id ?? "", artist: cover?.artist ?? "",
                                  album: cover?.title ?? "", tint: cover?.tint ?? TVColor.brand,
                                  tint2: cover?.tint2 ?? .black, glyph: cover?.glyph ?? "♪",
                                  size: width, height: h)
                    if playlist.kind == .smart {
                        VStack {
                            HStack {
                                Spacer()
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles").font(.system(size: 13))
                                    Text(TVL("智能", "Smart")).font(.system(size: 14, weight: .medium))
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
                        .foregroundStyle(.white).lineLimit(1)
                    Text(TVL("\(playlist.count) 首", "\(playlist.count) songs")).font(.system(size: 16))
                        .foregroundStyle(TVColor.textFaint)
                }
                .padding(.top, 12).padding(.horizontal, 2)
                .frame(width: width, alignment: .leading)
            }
            .frame(width: width, alignment: .leading)
        }
    }
}
#endif
