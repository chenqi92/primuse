#if os(tvOS)
import SwiftUI

/// tvOS 首页 — Top Shelf hero + 三行横向 shelf(对应 tvos.jsx 的 TVHomeArtboard)。
struct TVHomeView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}

    private var hero: TVAlbum {
        store.albums.first
            ?? TVAlbum(id: "_", title: "Primuse", artist: "", year: 0,
                       tint: TVColor.brand, tint2: .black, glyph: "♪")
    }
    private var heroSongs: [TVSong] { store.songs(forAlbum: hero.id) }
    private var heroSubtitle: String {
        var parts = [TVL("\(heroSongs.count) 首", "\(heroSongs.count) songs")]
        let mins = Int(heroSongs.reduce(0) { $0 + $1.duration } / 60)
        if mins > 0 { parts.append(TVL("\(mins) 分钟", "\(mins) min")) }
        if hero.year > 0 { parts.append("\(hero.year)") }
        parts.append(hero.artist)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            // Top Shelf hero 背景
            TVAmbientBackdrop(tint: hero.tint, tint2: hero.tint2, strength: 0.7)
            GeometryReader { geo in
                ZStack {
                    RadialGradient(colors: [hero.tint.opacity(0.4), .clear],
                                   center: UnitPoint(x: 0.8, y: 0.3),
                                   startRadius: 0, endRadius: geo.size.width * 0.5)
                    LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.78),
                                            .black.opacity(0.2), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .ignoresSafeArea()

            if store.albums.isEmpty {
                TVEmptyState(icon: "music.note.house", title: TVL("还没有曲库", "No music library yet")).tvPage()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    heroZone
                    if !store.recentlyPlayed.isEmpty {
                        TVRow(label: TVL("最近播放", "Recently Played")) {
                            ForEach(store.recentlyPlayed) { song in
                                TVSongCard(song: song, action: openPlayer)
                            }
                        }
                    }
                    if !store.recentlyAddedAlbums.isEmpty {
                        TVRow(label: TVL("最近添加专辑", "Recently Added")) {
                            ForEach(store.recentlyAddedAlbums) { album in
                                TVAlbumCard(album: album, action: openPlayer)
                            }
                        }
                    }
                    if !store.recommended.isEmpty {
                        TVRow(label: TVL("为你推荐", "Made for You")) {
                            ForEach(Array(store.recommended.enumerated()), id: \.offset) { _, album in
                                TVAlbumCard(album: album, action: openPlayer)
                            }
                        }
                    }
                }
                .tvPage()
            }
            }
        }
    }

    private var heroZone: some View {
        HStack(alignment: .center, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: TVL("今晚听", "Tonight's Pick"))
                Text("\(hero.artist) · \(hero.title)")
                    .font(.system(size: 84, weight: .bold)).tracking(-1.5)
                    .foregroundStyle(.white).lineLimit(2)
                    .padding(.top, 16)
                Text(heroSubtitle)
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2).frame(maxWidth: 760, alignment: .leading)
                    .padding(.top, 14)
                HStack(spacing: 16) {
                    TVPillButton(title: TVL("全部播放", "Play All"), systemImage: "play.fill", style: .solid,
                                 action: { store.playAll(shuffle: false); openPlayer() })
                    TVPillButton(title: TVL("随机播放", "Shuffle"), systemImage: "shuffle",
                                 action: { store.playAll(shuffle: true); openPlayer() })
                    TVPillButton(title: TVL("喜欢", "Love"), systemImage: "heart")
                }
                .padding(.top, 32)
            }
            Spacer(minLength: 0)
            TVArtworkView(album: hero, size: 380, radius: 18)
                .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
        }
        .frame(minHeight: 460)
        .padding(.bottom, 10)
    }
}
#endif
