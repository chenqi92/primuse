#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 首页 — Top Shelf hero + 三行横向 shelf(对应 tvos.jsx 的 TVHomeArtboard)。
struct TVHomeView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient
    var openPlayer: () -> Void = {}

    private var candidateAlbum: TVAlbum? {
        store.albums.first(where: { !store.songs(forAlbum: $0.id).isEmpty })
            ?? store.albums.first
    }
    private var candidateAlbumSongs: [TVSong] {
        guard let candidateAlbum else { return [] }
        return store.songs(forAlbum: candidateAlbum.id)
    }
    private var heroContent: TVHomeHeroPolicy.Content {
        TVHomeHeroPolicy.content(
            totalSongCount: store.songs.count,
            albumCount: store.albums.count,
            candidateAlbumSongCount: candidateAlbumSongs.count
        )
    }
    private var heroAlbum: TVAlbum? {
        heroContent == .album ? candidateAlbum : nil
    }
    private var heroSong: TVSong? {
        heroContent == .song ? store.songs.first : nil
    }
    private var hero: TVAlbum {
        switch heroContent {
        case .album:
            return candidateAlbum ?? placeholderHero
        case .song:
            guard let song = store.songs.first else { return placeholderHero }
            let palette = store.artworkColors(forSongID: song.id)
            let title = song.title
            return TVAlbum(
                id: "song:\(song.id)",
                title: title,
                artist: song.artist,
                year: 0,
                tint: palette?.primary ?? TVColor.brand,
                tint2: palette?.secondary ?? Color(hex: "#1f3a5b"),
                glyph: title.isEmpty ? "♪" : String(title.prefix(1))
            )
        case .empty:
            return placeholderHero
        }
    }
    private var placeholderHero: TVAlbum {
        TVAlbum(id: "_", title: "Primuse", artist: "", year: 0,
                tint: TVColor.brand, tint2: .black, glyph: "♪")
    }
    private var heroSongs: [TVSong] {
        switch heroContent {
        case .album: return candidateAlbumSongs
        case .song: return store.songs
        case .empty: return []
        }
    }
    private var heroSongCount: Int {
        TVHomeHeroPolicy.displayedSongCount(
            for: heroContent,
            totalSongCount: store.songs.count,
            candidateAlbumSongCount: candidateAlbumSongs.count
        )
    }
    private var heroHeading: String {
        hero.artist.isEmpty ? hero.title : "\(hero.artist) · \(hero.title)"
    }
    private var heroSubtitle: String {
        var parts = [PMString("ext.tv.songsCount", heroSongCount)]
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
                    RadialGradient(colors: [heroAmbientTint.opacity(0.4), .clear],
                                   center: UnitPoint(x: 0.8, y: 0.3),
                                   startRadius: 0, endRadius: geo.size.width * 0.5)
                    LinearGradient(colors: heroScrim,
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .ignoresSafeArea()

            if !store.hasRealLibrary && store.radioStations.isEmpty {
                TVEmptyState(icon: "music.note.house", title: PMString("ext.tv.home.empty")).tvPage()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if store.hasRealLibrary {
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
                    }
                    if !store.radioStations.isEmpty {
                        TVRow(
                            label: PMString("ext.tv.radio.title"),
                            sub: PMString("ext.tv.radio.stationCount", store.radioStations.count)
                        ) {
                            ForEach(store.radioStations) { station in
                                TVRadioStationCard(station: station, action: openPlayer)
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
            TVMusicPlaceholder(
                tint: hero.tint,
                tint2: hero.tint2,
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

    private var heroAmbientTint: Color {
        coverDrivenAmbient ? hero.tint : TVColor.brand(hex: accentHex)
    }
}
#endif
