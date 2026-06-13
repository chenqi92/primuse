#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 资料库 — 筛选条 + 网格(对应 tvos.jsx 的 TVLibraryArtboard)。
struct TVLibraryView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", artists = "艺术家", songs = "歌曲", playlists = "歌单", smart = "智能歌单"
        var id: String { rawValue }
        var display: String {
            switch self {
            case .all: return PMString("ext.tv.library.filter.all")
            case .artists: return PMString("ext.tv.library.filter.artists")
            case .songs: return PMString("ext.tv.library.filter.songs")
            case .playlists: return PMString("ext.tv.library.filter.playlists")
            case .smart: return PMString("ext.tv.library.filter.smart")
            }
        }
    }
    @State private var filter: Filter = .all

    private let cols = 5
    private let gap: CGFloat = 36

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            GeometryReader { geo in
                let contentW = geo.size.width - TVSpace.pageH * 2
                let cell = (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        filterStrip
                        grid(cell: cell).focusSection()
                    }
                    .tvPage()
                }
            }
        }
    }

    private var title: String {
        switch filter {
        case .all: return PMString("ext.tv.library.title.albums", store.albums.count)
        case .artists: return PMString("ext.tv.library.title.artists", store.artists.count)
        case .songs: return PMString("ext.tv.library.title.songs", TVFmt.count(store.songs.count))
        case .playlists: return PMString("ext.tv.library.title.playlists", store.playlists.filter { $0.kind != .smart }.count)
        case .smart: return PMString("ext.tv.library.title.smart", store.playlists.filter { $0.kind == .smart }.count)
        }
    }

    private var filterStrip: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                TVEyebrow(text: PMString("ext.tv.library.eyebrow"))
                Text(title).font(TVFont.pageTitle).foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                ForEach(Filter.allCases) { f in
                    TVFocusButton(radius: 28, accent: .white, scale: 1.06, lift: 4,
                                  action: { filter = f }) { _ in
                        Text(f.display)
                            .font(.system(size: 18, weight: f == filter ? .bold : .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 26).padding(.vertical, 12)
                            .background(f == filter ? AnyShapeStyle(TVColor.brand)
                                                    : AnyShapeStyle(Color.white.opacity(0.12)),
                                        in: Capsule())
                    }
                }
            }
            // 筛选条独立成焦点区:从右上角某个筛选项往下能跳到下方网格(否则横纵混在一起跳不下去)。
            .focusSection()
        }
    }

    @ViewBuilder
    private func grid(cell: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols)
        switch filter {
        case .all:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.albums) { a in
                    TVAlbumCard(album: a, width: cell,
                                subtitleOverride: "\(a.artist) · \(a.year)", action: openPlayer)
                }
            }
        case .artists:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.artists) { artist in
                    TVArtistCard(artist: artist, size: cell * 0.82, action: openPlayer)
                        .frame(width: cell)
                }
            }
        case .songs:
            LazyVStack(spacing: 10) {
                ForEach(store.songs) { song in
                    TVSongRow(song: song, action: openPlayer)
                }
            }
        case .playlists:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.playlists.filter { $0.kind != .smart }) { p in
                    TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                }
            }
        case .smart:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.playlists.filter { $0.kind == .smart }) { p in
                    TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                }
            }
        }
    }
}

/// 歌曲行 — 封面 + 标题/艺术家 + 时长。
struct TVSongRow: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var action: () -> Void = {}

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: TVRadius.card, scale: 1.02, lift: 0,
                      action: { store.play(song); action() }) { focused in
            HStack(spacing: 18) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 64, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(song.artist).font(.system(size: 18))
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.isLiked(song.id) {
                    Image(systemName: "heart.fill").font(.system(size: 18))
                        .foregroundStyle(TVColor.brand)
                }
                Text(song.format).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TVColor.textGhost)
                Text(TVFmt.time(song.duration)).font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : TVColor.card)
        }
    }
}
#endif
