#if os(tvOS)
import SwiftUI

/// tvOS 搜索 — 左列查询框 + 屏幕键盘,右列实时结果(对应 TVSearchArtboard)。
struct TVSearchView: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void = {}

    @State private var query: String = ""
    @FocusState private var inputActive: Bool

    private var matchedSongs: [TVSong] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return store.songs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
    }
    private var topArtist: TVArtist? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return store.artists.first { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var suggestions: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let names = store.artists.map(\.name)
        let hits = q.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(q) }
        return Array((hits.isEmpty ? names : hits).prefix(4))
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: store.albums.first?.tint ?? TVColor.brand,
                              tint2: store.albums.first?.tint2 ?? .black, strength: 0.4)
            HStack(alignment: .top, spacing: 60) {
                leftColumn
                rightColumn
            }
            .tvPage()
        }
    }

    // MARK: 左列 — 搜索框(选中唤出系统键盘,支持语音听写)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: TVL("搜索", "Search")).padding(.bottom, 16)

            // 真实可聚焦 TextField:tvOS 上选中它会自动唤出全屏系统键盘(含语音听写)。
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(inputActive ? TVColor.brand : .white.opacity(0.55))
                TextField(TVL("搜索歌曲、专辑、艺术家", "Search songs, albums, artists"), text: $query)
                    .focused($inputActive)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    // 关掉 tvOS TextField 自带的亮白系统焦点高亮(太晃眼),
                    // 焦点视觉只用下面的低调底 + 品牌色描边。
                    .focusEffectDisabled()
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            // 低调填充 + 聚焦时品牌色描边,不再用晃眼的亮白底。
            .background(Color.white.opacity(inputActive ? 0.10 : 0.06),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(inputActive ? TVColor.brand : .white.opacity(0.10),
                                  lineWidth: inputActive ? 2.5 : 1)
            }
            .padding(.bottom, 14)

            Text(TVL("选中搜索框唤出系统键盘,可用语音听写输入", "Select the search field to open the keyboard, or use voice dictation"))
                .font(.system(size: 15)).foregroundStyle(TVColor.textGhost)
                .padding(.bottom, 28)

            if query.trimmingCharacters(in: .whitespaces).isEmpty, !suggestions.isEmpty {
                Text(TVL("建议", "Suggestions")).font(.system(size: 18)).foregroundStyle(TVColor.textMuted)
                    .padding(.bottom, 10)
                VStack(spacing: 4) {
                    ForEach(suggestions, id: \.self) { s in
                        TVFocusButton(radius: 10, accent: .white, scale: 1.02, lift: 0,
                                      action: { query = s }) { focused in
                            HStack {
                                Text(s).font(.system(size: 22)).foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .frame(maxWidth: .infinity)
                            .background(focused ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 右列 — 结果

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: TVL("顶部匹配", "Top Result")).padding(.bottom, 16)
            if let artist = topArtist {
                TVFocusButton(radius: 16, scale: 1.02, lift: 4, action: openPlayer) { focused in
                    HStack(spacing: 20) {
                        TVCoverArt(tint: artist.tint, tint2: artist.tint2, glyph: artist.glyph,
                                   size: 92, radius: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.name).font(.system(size: 32, weight: .bold)).foregroundStyle(.white)
                            Text(TVL("艺术家 · \(artist.songCount) 首", "Artist · \(artist.songCount) songs"))
                                .font(.system(size: 18)).foregroundStyle(TVColor.textFaint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20).frame(maxWidth: .infinity)
                    .background(focused ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                }
            } else {
                Text(TVL("输入以搜索曲库", "Type to search your library")).font(.system(size: 22)).foregroundStyle(TVColor.textFaint)
            }

            TVEyebrow(text: TVL("歌曲", "Songs")).padding(.top, 28).padding(.bottom, 16)
            VStack(spacing: 6) {
                ForEach(matchedSongs.prefix(6)) { song in
                    TVSearchSongRow(song: song, action: openPlayer)
                }
                if matchedSongs.isEmpty {
                    Text(TVL("没有匹配的歌曲", "No matching songs")).font(.system(size: 18)).foregroundStyle(TVColor.textGhost)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TVSearchSongRow: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var action: () -> Void = {}

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: 10, scale: 1.02, lift: 0,
                      action: { store.play(song); action() }) { focused in
            HStack(spacing: 16) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 56, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    Text("\(song.artist) · \(store.albumOf(song)?.title ?? "")")
                        .font(.system(size: 16)).foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(TVColor.textFaint)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        }
    }
}
#endif
