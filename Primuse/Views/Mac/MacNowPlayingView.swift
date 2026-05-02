#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native "now playing" full-area view. Shown inline inside the main
/// window — covers the detail pane while the sidebar and the bottom mini
/// bar stay visible. No sheet, no drag-to-dismiss, no GeometryReader hacks.
///
/// Visual: built on `.regularMaterial` (the same surface used by sheets,
/// popovers and other macOS chrome) plus a very subtle cover-art tint, so
/// it reads as part of the same window instead of a black popup glued on
/// top. Text uses `.primary` / `.secondary` so it follows the user's
/// light/dark appearance.
///
/// Layout: artwork on the left, scrolling lyrics on the right with the
/// active line highlighted and pinned near the vertical center. Transport
/// stays in the mini bar — duplicating it here would just fight the user.
struct MacNowPlayingView: View {
    var onClose: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager

    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    /// 歌词基准字号,用户可在 NowPlaying 内通过 +/- 调整。当前播放行
    /// 字号 = base + 5。
    @AppStorage("now_playing_lyrics_base_font") private var lyricsBaseFontSize: Double = 17

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backdrop

            // 把 artwork / 歌词从 1:1 平分改为 fixed-vs-flex,
            // 让封面只占左侧一块、歌词区域吃掉剩余宽度。
            HStack(alignment: .top, spacing: 36) {
                artworkPane
                    .frame(width: 380)
                    .frame(maxHeight: .infinity)
                lyricsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 24)

            HStack(spacing: 8) {
                // 歌词字号 +/- (Apple Music 风格的浮动控件)
                Button {
                    lyricsBaseFontSize = max(12, lyricsBaseFontSize - 2)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(Text("lyrics_font_smaller"))
                .disabled(lyrics.isEmpty)

                Button {
                    lyricsBaseFontSize = min(28, lyricsBaseFontSize + 2)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(Text("lyrics_font_larger"))
                .disabled(lyrics.isEmpty)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(Text("close"))
                .keyboardShortcut(.cancelAction)
            }
            .padding(18)
        }
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, t in updateIndex(time: t) }
    }

    // MARK: - Sections

    /// Window-toned backdrop with a faint cover tint on top — keeps the
    /// view feeling like part of the same surface as the sidebar / mini
    /// bar instead of a black overlay. Falls back to plain material when
    /// nothing is playing.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            if let song = player.currentSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: nil,
                    cornerRadius: 0,
                    sourceID: song.sourceID,
                    filePath: song.filePath
                )
                .blur(radius: 90)
                .opacity(0.35)
                .scaleEffect(1.4)
                .clipped()
                .allowsHitTesting(false)
            }
        }
    }

    private var artworkPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            Group {
                if let song = player.currentSong {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: nil,
                        cornerRadius: 14,
                        sourceID: song.sourceID,
                        filePath: song.filePath
                    )
                    .aspectRatio(1, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(maxWidth: 460)
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(player.currentSong?.title ?? "")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(player.currentSong?.artistName ?? "")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = player.currentSong?.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var lyricsPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 80).frame(height: 80)
                    if lyrics.isEmpty {
                        Text(player.currentSong == nil ? "" : String(localized: "no_lyrics"))
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { i, line in
                            Text(line.text)
                                .font(.system(size: i == currentIndex ? lyricsBaseFontSize + 5 : lyricsBaseFontSize,
                                              weight: i == currentIndex ? .semibold : .regular))
                                .foregroundStyle(i == currentIndex ? .primary : .secondary)
                                .opacity(i == currentIndex ? 1 : 0.6)
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .animation(.easeInOut(duration: 0.25), value: currentIndex)
                        }
                    }
                    Spacer(minLength: 200).frame(height: 200)
                }
                .padding(.horizontal, 24)
            }
            .onChange(of: currentIndex) { _, new in
                guard !lyrics.isEmpty, new < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lyrics[new].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Lyrics loading

    private func reloadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []; currentIndex = 0; return
        }
        let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        lyrics = loaded
        currentIndex = 0
        updateIndex(time: player.currentTime)
    }

    private func updateIndex(time: TimeInterval) {
        guard !lyrics.isEmpty else { return }
        for i in (0..<lyrics.count).reversed() where time >= lyrics[i].timestamp {
            if currentIndex != i { currentIndex = i }
            return
        }
        if currentIndex != 0 { currentIndex = 0 }
    }
}
#endif
