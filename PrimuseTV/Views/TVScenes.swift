#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 资料库 — 简化版 Songs/Albums/Artists 三选一 grid。
struct TVLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    enum LibTab: String, Hashable, CaseIterable, Identifiable {
        case songs, albums, artists
        var id: String { rawValue }
        var titleKey: LocalizedStringKey {
            switch self {
            case .songs: return "tab_songs"
            case .albums: return "tab_albums"
            case .artists: return "tab_artists"
            }
        }
    }
    @State private var libTab: LibTab = .albums

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: TVSpace.row) {
                HStack(spacing: 24) {
                    ForEach(LibTab.allCases) { t in
                        Button { libTab = t } label: {
                            Text(t.titleKey)
                                .font(.system(size: 28, weight: libTab == t ? .semibold : .regular))
                                .foregroundStyle(libTab == t ? TVColor.text : TVColor.textMuted)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(
                                    libTab == t ? AnyShapeStyle(TVColor.brand.opacity(0.22)) : AnyShapeStyle(Color.clear),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                ScrollView(.vertical, showsIndicators: false) {
                    switch libTab {
                    case .songs: songsList
                    case .albums: albumsGrid
                    case .artists: artistsGrid
                    }
                }
            }
            .padding(.horizontal, TVSpace.pageH)
            .padding(.top, TVSpace.pageV)
            .padding(.bottom, TVSpace.pageV)
        }
    }

    private var songsList: some View {
        LazyVStack(spacing: 6) {
            ForEach(library.visibleSongs.prefix(120)) { song in
                TVFocusable {
                    HStack(spacing: 18) {
                        CachedArtworkView(
                            coverRef: song.coverArtFileName, songID: song.id,
                            size: 60, cornerRadius: 8,
                            sourceID: song.sourceID, filePath: song.filePath
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(TVColor.text)
                                .lineLimit(1)
                            Text(song.artistName ?? "—")
                                .font(.system(size: 18))
                                .foregroundStyle(TVColor.textFaint)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .background(TVColor.card)
                }
            }
        }
    }

    private var albumsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.adaptive(minimum: 240, maximum: 280), spacing: TVSpace.card), count: 1),
                  alignment: .leading, spacing: TVSpace.card) {
            ForEach(library.albums) { album in
                let song = library.songs(forAlbum: album.id).first
                TVFocusable {
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
                        if let a = album.artistName {
                            Text(a).font(.system(size: 16))
                                .foregroundStyle(TVColor.textFaint).lineLimit(1)
                        }
                    }
                    .frame(width: 240, alignment: .leading)
                }
            }
        }
    }

    private var artistsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.adaptive(minimum: 200, maximum: 240), spacing: TVSpace.card), count: 1),
                  alignment: .leading, spacing: TVSpace.card) {
            ForEach(library.visibleArtists) { artist in
                TVFocusable(radius: 100) {
                    VStack(spacing: 12) {
                        CachedArtworkView(
                            artistID: artist.id, artistName: artist.name,
                            size: 180, cornerRadius: 90
                        )
                        Text(artist.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(TVColor.text)
                            .lineLimit(1).frame(width: 200)
                    }
                }
            }
        }
    }
}

/// tvOS 搜索 — Siri Remote 触发, 简单网格结果。
struct TVSearchView: View {
    @State private var searchText: String = ""
    @Environment(MusicLibrary.self) private var library

    private var filtered: [Song] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return library.visibleSongs.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            ($0.artistName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: TVSpace.row) {
                Text("search_title")
                    .font(TVFont.pageTitle)
                    .foregroundStyle(TVColor.text)
                TextField("", text: $searchText, prompt: Text("search_prompt"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 28))
                    .foregroundStyle(TVColor.text)
                    .padding(20)
                    .background(TVColor.card, in: .rect(cornerRadius: TVRadius.card))

                if searchText.isEmpty {
                    Text("search_empty_library")
                        .font(.system(size: 22))
                        .foregroundStyle(TVColor.textFaint)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(filtered.prefix(40)) { song in
                                TVFocusable {
                                    HStack(spacing: 16) {
                                        CachedArtworkView(
                                            coverRef: song.coverArtFileName, songID: song.id,
                                            size: 60, cornerRadius: 8,
                                            sourceID: song.sourceID, filePath: song.filePath
                                        )
                                        VStack(alignment: .leading) {
                                            Text(song.title)
                                                .font(.system(size: 22, weight: .semibold))
                                                .foregroundStyle(TVColor.text)
                                            Text(song.artistName ?? "")
                                                .font(.system(size: 18))
                                                .foregroundStyle(TVColor.textFaint)
                                        }
                                        Spacer()
                                    }
                                    .padding(16)
                                    .background(TVColor.card)
                                }
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, TVSpace.pageH)
            .padding(.top, TVSpace.pageV)
        }
    }
}

/// tvOS 正在播放 — 巨幅 cover + 大歌词列表。
struct TVNowPlayingView: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        ZStack {
            TVAmbientBackdrop(strength: 0.85).ignoresSafeArea()

            if let song = player.currentSong {
                HStack(alignment: .center, spacing: 80) {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName, songID: song.id,
                        size: 520, cornerRadius: 20,
                        sourceID: song.sourceID, filePath: song.filePath
                    )
                    .shadow(color: .black.opacity(0.5), radius: 36, y: 18)

                    VStack(alignment: .leading, spacing: 18) {
                        Text(song.fileFormat.displayName.uppercased())
                            .font(.system(size: 22, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.55))
                        Text(song.title)
                            .font(.system(size: 60, weight: .bold))
                            .tracking(-0.8)
                            .foregroundStyle(.white)
                            .lineLimit(3)
                        Text(song.artistName ?? "")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                        if let album = song.albumTitle, !album.isEmpty {
                            Text(album)
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }

                        HStack(spacing: 24) {
                            TVFocusable(radius: 50) {
                                Button { Task { await player.previous() } } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.system(size: 26, weight: .semibold))
                                        .frame(width: 80, height: 80)
                                        .background(Color.white.opacity(0.16), in: Circle())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                            TVFocusable(radius: 60) {
                                Button { player.togglePlayPause() } label: {
                                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 36, weight: .bold))
                                        .frame(width: 110, height: 110)
                                        .background(TVColor.brand, in: Circle())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                            TVFocusable(radius: 50) {
                                Button { Task { await player.next() } } label: {
                                    Image(systemName: "forward.fill")
                                        .font(.system(size: 26, weight: .semibold))
                                        .frame(width: 80, height: 80)
                                        .background(Color.white.opacity(0.16), in: Circle())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 12)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, TVSpace.pageH)
            } else {
                VStack(spacing: 24) {
                    Image(systemName: "music.note")
                        .font(.system(size: 100))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("player_empty_title")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                    Text("player_empty_message")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}

/// tvOS 设置 — 简化清单, 主要项目用 NavigationLink + Focus row。
struct TVSettingsView: View {
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    Text("settings")
                        .font(TVFont.pageTitle)
                        .foregroundStyle(TVColor.text)
                        .padding(.bottom, 16)

                    settingRow(icon: "play.circle", title: "playback_settings")
                    settingRow(icon: "slider.horizontal.3", title: "equalizer")
                    settingRow(icon: "waveform.badge.plus", title: "audio_effects")
                    settingRow(icon: "music.note", title: "settings_apple_music_section")
                    settingRow(icon: "icloud", title: "icloud_sync_title")
                    settingRow(icon: "info.circle", title: "about")
                    Spacer(minLength: 80)
                }
                .padding(.horizontal, TVSpace.pageH)
                .padding(.top, TVSpace.pageV)
            }
        }
    }

    private func settingRow(icon: String, title: LocalizedStringKey) -> some View {
        TVFocusable {
            HStack(spacing: 22) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(TVColor.brand)
                    .frame(width: 60, height: 60)
                    .background(TVColor.brand.opacity(0.18), in: .rect(cornerRadius: 12))
                Text(title)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(TVColor.text)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(TVColor.card)
        }
    }
}
#endif
