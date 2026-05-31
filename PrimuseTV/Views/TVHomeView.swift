#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 首页 — 上方 Top Shelf hero (1920×440 banner 风) + 下方多行水平滚动条。
struct TVHomeView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        ZStack {
            TVAmbientBackdrop(accent: TVColor.brand, strength: 0.8)
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: TVSpace.row) {
                    topShelf
                    if !library.recentlyAddedAlbums(limit: 12).isEmpty {
                        section(titleKey: "recently_added") {
                            albumRow(library.recentlyAddedAlbums(limit: 12))
                        }
                    }
                    let recent = library.recentlyPlayedSongs(limit: 12)
                    if !recent.isEmpty {
                        section(titleKey: "recently_played") {
                            songRow(recent)
                        }
                    }
                    if !library.visibleArtists.isEmpty {
                        section(titleKey: "tab_artists") {
                            artistRow(Array(library.visibleArtists.prefix(12)))
                        }
                    }
                    Spacer(minLength: TVSpace.row)
                }
                .padding(.horizontal, TVSpace.pageH)
                .padding(.top, TVSpace.pageV)
                .padding(.bottom, TVSpace.pageV)
            }
        }
    }

    // MARK: - Top shelf hero

    private var topShelf: some View {
        let hero = library.recentlyPlayedSongs(limit: 1).first
            ?? library.visibleSongs.first(where: { $0.coverArtFileName?.isEmpty == false })

        return HStack(alignment: .center, spacing: 60) {
            // 大封面
            Group {
                if let hero {
                    CachedArtworkView(
                        coverRef: hero.coverArtFileName, songID: hero.id,
                        size: 380, cornerRadius: TVRadius.cover,
                        sourceID: hero.sourceID, filePath: hero.filePath
                    )
                } else {
                    RoundedRectangle(cornerRadius: TVRadius.cover)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 380, height: 380)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 96))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 30, y: 16)

            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringKey("greeting_afternoon").uppercased())
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Text("home_dashboard_title")
                    .font(.system(size: 72, weight: .bold))
                    .tracking(-1)
                    .foregroundStyle(.white)
                Text("home_dashboard_subtitle")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                HStack(spacing: 16) {
                    TVFocusable(radius: TVRadius.pill) {
                        Label("play_all", systemImage: "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    TVFocusable(radius: TVRadius.pill) {
                        Label("shuffle", systemImage: "shuffle")
                            .font(.system(size: 24, weight: .semibold))
                            .padding(.horizontal, 32)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.18), in: Capsule())
                            .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                            .foregroundStyle(.white)
                    }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 40)
    }

    // MARK: - Section helper

    @ViewBuilder
    private func section<Content: View>(titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(titleKey)
                .font(TVFont.sectionTitle)
                .foregroundStyle(TVColor.text)
            content()
        }
    }

    private func albumRow(_ albums: [Album]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TVSpace.card) {
                ForEach(albums) { album in
                    let song = library.songs(forAlbum: album.id).first
                    TVFocusable(radius: TVRadius.cover) {
                        VStack(alignment: .leading, spacing: 10) {
                            CachedArtworkView(
                                coverRef: song?.coverArtFileName, songID: song?.id ?? "",
                                size: 240, cornerRadius: TVRadius.cover,
                                sourceID: song?.sourceID, filePath: song?.filePath
                            )
                            Text(album.title)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(TVColor.text)
                                .lineLimit(1)
                            if let artist = album.artistName {
                                Text(artist)
                                    .font(.system(size: 16))
                                    .foregroundStyle(TVColor.textFaint)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 240, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func songRow(_ songs: [Song]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TVSpace.card) {
                ForEach(songs) { song in
                    TVFocusable(radius: TVRadius.cover) {
                        VStack(alignment: .leading, spacing: 10) {
                            CachedArtworkView(
                                coverRef: song.coverArtFileName, songID: song.id,
                                size: 200, cornerRadius: TVRadius.cover,
                                sourceID: song.sourceID, filePath: song.filePath
                            )
                            Text(song.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(TVColor.text)
                                .lineLimit(1)
                            Text(song.artistName ?? "")
                                .font(.system(size: 14))
                                .foregroundStyle(TVColor.textFaint)
                                .lineLimit(1)
                        }
                        .frame(width: 200, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func artistRow(_ artists: [Artist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TVSpace.card) {
                ForEach(artists) { artist in
                    TVFocusable(radius: 100) {
                        VStack(spacing: 12) {
                            CachedArtworkView(
                                artistID: artist.id, artistName: artist.name,
                                size: 180, cornerRadius: 90
                            )
                            Text(artist.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(TVColor.text)
                                .lineLimit(1)
                                .frame(width: 200)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}
#endif
