#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 首页 — Top Shelf hero + 三行横向 shelf(对应 tvos.jsx 的 TVHomeArtboard)。
struct TVHomeView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    var openPlayer: () -> Void = {}

    private var heroAlbum: TVAlbum? { store.albums.first }
    private var heroSong: TVSong? { heroAlbum == nil ? store.songs.first : nil }
    private var hero: TVAlbum {
        if let heroAlbum { return heroAlbum }
        let song = heroSong
        let title = song?.title ?? "Primuse"
        let palette = song.flatMap { store.artworkColors(forSongID: $0.id) }
        return TVAlbum(
            id: "",
            title: title,
            artist: song?.artist ?? "",
            year: 0,
            tint: palette?.primary ?? TVColor.brand,
            tint2: palette?.secondary ?? Color(hex: "#1f3a5b"),
            glyph: title.isEmpty ? "♪" : String(title.prefix(1))
        )
    }
    private var heroSongs: [TVSong] {
        heroAlbum == nil ? store.songs : store.songs(forAlbum: hero.id)
    }
    private var heroHeading: String {
        hero.artist.isEmpty ? hero.title : "\(hero.artist) · \(hero.title)"
    }
    private var heroSubtitle: String {
        var parts = [PMString("ext.tv.songsCount", heroSongs.count)]
        let mins = (heroSongs.reduce(0) { $0 + $1.duration } / 60).finiteInt()
        if mins > 0 { parts.append(PMString("ext.tv.minCount", mins)) }
        if hero.year > 0 { parts.append("\(hero.year)") }
        if !hero.artist.isEmpty { parts.append(hero.artist) }
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
                    LinearGradient(colors: heroScrim,
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .ignoresSafeArea()

            if !store.hasRealLibrary {
                TVEmptyState(icon: "music.note.house", title: PMString("ext.tv.home.empty")).tvPage()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    heroZone
                    if !store.recentlyPlayed.isEmpty {
                        TVRow(label: PMString("ext.tv.home.recentlyPlayed")) {
                            ForEach(store.recentlyPlayed) { song in
                                TVSongCard(song: song, action: openPlayer)
                            }
                        }
                    } else if heroAlbum == nil {
                        TVRow(label: PMString("ext.tv.nav.library")) {
                            ForEach(Array(store.songs.prefix(15))) { song in
                                TVSongCard(song: song, action: openPlayer)
                            }
                        }
                    }
                    if !store.recentlyAddedAlbums.isEmpty {
                        TVRow(label: PMString("ext.tv.home.recentlyAdded")) {
                            ForEach(store.recentlyAddedAlbums) { album in
                                TVAlbumCard(album: album, action: openPlayer)
                            }
                        }
                    }
                    if !store.recommended.isEmpty {
                        TVRow(label: PMString("ext.tv.home.madeForYou")) {
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
                TVEyebrow(text: PMString("ext.tv.home.tonightsPick"))
                Text(heroHeading)
                    .font(.system(size: 84, weight: .bold)).tracking(-1.5)
                    .foregroundStyle(TVColor.text).lineLimit(2)
                    .padding(.top, 16)
                Text(heroSubtitle)
                    .font(.system(size: 22)).foregroundStyle(TVColor.textMuted)
                    .lineLimit(2).frame(maxWidth: 760, alignment: .leading)
                    .padding(.top, 14)
                HStack(spacing: 16) {
                    TVPillButton(title: PMString("ext.tv.home.playAll"), systemImage: "play.fill", style: .solid,
                                 action: { store.playAll(shuffle: false); openPlayer() })
                    TVPillButton(title: PMString("ext.tv.home.shuffle"), systemImage: "shuffle",
                                 action: { store.playAll(shuffle: true); openPlayer() })
                    TVPillButton(title: PMString("ext.tv.home.love"), systemImage: "heart")
                }
                .padding(.top, 32)
            }
            Spacer(minLength: 0)
            heroArtwork
                .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
        }
        .frame(minHeight: 460)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var heroArtwork: some View {
        if let heroAlbum {
            TVArtworkView(album: heroAlbum, size: 380, radius: 18)
        } else if let heroSong {
            TVArtworkView(
                coverKey: "",
                artist: heroSong.artist,
                album: "",
                songID: heroSong.id,
                coverRef: heroSong.coverRef,
                tint: hero.tint,
                tint2: hero.tint2,
                glyph: hero.glyph,
                size: 380,
                radius: 18
            )
        } else {
            TVCoverArt(
                tint: hero.tint,
                tint2: hero.tint2,
                glyph: hero.glyph,
                size: 380,
                radius: 18
            )
        }
    }

    private var heroScrim: [Color] {
        if colorScheme == .dark {
            return [.black.opacity(0.84), .black.opacity(0.66), .black.opacity(0.16), .clear]
        }
        return [TVColor.bg.opacity(0.98), TVColor.bg.opacity(0.82),
                TVColor.bg.opacity(0.26), .clear]
    }
}
#endif
