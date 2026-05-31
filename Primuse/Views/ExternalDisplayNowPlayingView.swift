import SwiftUI
import PrimuseKit

/// 外接屏专属"现在播放"页 —— `externalDisplayNonInteractive` 屏不接受触摸,
/// 所以这里只渲染信息,不放任何按钮。播控全部留在主屏 (iPad NowPlayingView)。
///
/// 设计:
/// - 左 1/2: 巨幅封面(占屏高 80%), 加封面色 ambient gradient
/// - 右 1/2: 标题 + 艺术家 + 大字滚动歌词
/// - 没在播任何歌时: 简单 brand 占位, 不留空白
struct ExternalDisplayNowPlayingView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(ThemeService.self) private var theme
    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicScraperService.self) private var scraperService

    @State private var lyrics: [LyricLine] = []

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 跟主屏 NowPlayingView 一样的封面色 ambient,统一视觉
                Color.black.ignoresSafeArea()
                LinearGradient(
                    colors: [theme.darkAccent, theme.darkAccent.opacity(0.55), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: theme.colorID)

                if player.currentSong != nil {
                    activeBody(geo: geo)
                } else {
                    idleBody
                }
            }
        }
        .task(id: player.currentSong?.id) { await loadLyrics() }
    }

    @ViewBuilder
    private func activeBody(geo: GeometryProxy) -> some View {
        let artSize = min(520, min(geo.size.width * 0.40, geo.size.height * 0.72))

        HStack(spacing: 80) {
            // 左: 封面
            VStack {
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: artSize,
                    cornerRadius: 20,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath,
                    revisionToken: player.coverRevision
                )
                .shadow(color: .black.opacity(0.40), radius: 48, y: 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            // 右: 标题 + 歌词
            VStack(alignment: .leading, spacing: 24) {
                Text("外接显示器 · 第二屏")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)

                VStack(alignment: .leading, spacing: 10) {
                    Text(player.currentSong?.title ?? "")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(4)
                        .lineLimit(2)
                    Text(player.currentSong?.artistName ?? "")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                        .lineLimit(1)
                    if let album = player.currentSong?.albumTitle, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(.white.opacity(0.50))
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, 16)

                if !lyrics.isEmpty {
                    externalLyrics
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 100)
        .padding(.vertical, 80)
    }

    private var externalLyrics: some View {
        let index = currentLyricIndex
        let lower = max(0, index - 2)
        let upper = min(lyrics.count, index + 6)

        return VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(lower..<upper), id: \.self) { realIndex in
                let line = lyrics[realIndex]
                let current = realIndex == index
                let distance = abs(realIndex - index)
                Text(line.text)
                    .font(.system(size: current ? 42 : 28, weight: current ? .bold : .semibold))
                    .foregroundStyle(current ? Color.white : Color.white.opacity(max(0.18, 0.58 - Double(distance) * 0.14)))
                    .lineLimit(2)
                    .minimumScaleFactor(0.74)
                    .shadow(color: current ? theme.accentColor.opacity(0.42) : .clear, radius: 18)
            }
        }
    }

    private var currentLyricIndex: Int {
        guard !lyrics.isEmpty else { return 0 }
        var result = 0
        for index in lyrics.indices where lyrics[index].timestamp <= player.currentTime {
            result = index
        }
        return result
    }

    private var idleBody: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("猿音")
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
            Text("从主屏开始播放")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// 复用 NowPlayingView 的 Tier1a (songID hash cache) 路径。外接屏只读
    /// 不写,所以不需要参与 scrape / Tier2/3 fallback —— 主屏 NowPlayingView
    /// 已经处理,把 cache 填好后,这里能立刻读到。
    private func loadLyrics() async {
        guard let song = player.currentSong else { lyrics = []; return }
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !cached.isEmpty {
            lyrics = cached
        } else {
            lyrics = []
        }
    }
}
