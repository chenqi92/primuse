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
    private enum AmbientBackdropTuning {
        static let neutralBase = Color(red: 0.035, green: 0.043, blue: 0.055)
        static let artworkAccentOpacity = 0.76
        static let fallbackAccentOpacity = 0.30
        static let artworkLowerAccentOpacity = 0.56
        static let fallbackLowerAccentOpacity = 0.22
    }

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(ThemeService.self) private var theme
    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(\.layoutDirection) private var inheritedLayoutDirection

    @State private var lyrics: [LyricLine] = []
    @State private var currentLyricIndex = 0
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength

    private var lyricsWritingDirection: LyricWritingDirection {
        LyricWritingDirectionPolicy.resolve(in: lyrics)
    }

    private var lyricLayoutDirection: LayoutDirection {
        switch lyricsWritingDirection {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                externalBackdrop(size: geo.size)

                if player.currentSong != nil {
                    activeBody(geo: geo)
                } else {
                    idleBody
                }
            }
        }
        .task(id: player.currentSong?.id) { await loadLyrics() }
        .background {
            ExternalDisplayLyricTimeObserver { time in
                updateLyricIndex(for: time)
            }
        }
    }

    private func externalBackdrop(size: CGSize) -> some View {
        let radius = max(size.width, size.height) * 0.78
        let hasArtworkTheme = theme.colorID != "default"
        let strength = AppThemePreferences.normalizedAmbientStrength(ambientStrength)
        let accentOpacity = (hasArtworkTheme
            ? AmbientBackdropTuning.artworkAccentOpacity
            : AmbientBackdropTuning.fallbackAccentOpacity) * strength
        let lowerAccentOpacity = (hasArtworkTheme
            ? AmbientBackdropTuning.artworkLowerAccentOpacity
            : AmbientBackdropTuning.fallbackLowerAccentOpacity) * strength

        return ZStack {
            AmbientBackdropTuning.neutralBase

            RadialGradient(
                colors: [theme.accentColor.opacity(accentOpacity), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: radius
            )

            RadialGradient(
                colors: [theme.accentColor.opacity(lowerAccentOpacity), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: radius * 0.92
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .black.opacity(0.34), location: 0.58),
                    .init(color: .black.opacity(0.42), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
        .allowsHitTesting(false)
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
                    fileFormat: player.currentSong?.fileFormat,
                    revisionToken: player.coverRevision
                )
                .shadow(color: .black.opacity(0.40), radius: 48, y: 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            // 右: 标题 + 歌词
            VStack(alignment: .leading, spacing: 24) {
                Text(String(localized: "external_display_label"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .textCase(.uppercase)

                VStack(alignment: .leading, spacing: 10) {
                    Text(player.currentSong?.title ?? "")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(4)
                        .lineLimit(2)
                    Text(
                        player.currentSong.flatMap { library.artistDisplayName(for: $0) }
                            ?? ""
                    )
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
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.74)
                    .shadow(color: current ? theme.accentColor.opacity(0.42) : .clear, radius: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    private func updateLyricIndex(for time: TimeInterval) {
        guard !lyrics.isEmpty else {
            currentLyricIndex = 0
            return
        }

        var lower = 0
        var upper = lyrics.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lyrics[middle].timestamp <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let nextIndex = max(0, lower - 1)
        if nextIndex != currentLyricIndex {
            currentLyricIndex = nextIndex
        }
    }

    private var idleBody: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note")
                .font(.system(size: 96, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(String(localized: "app_name"))
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(.white)
            Text(String(localized: "external_display_idle"))
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
        updateLyricIndex(for: player.currentTime)
    }
}

/// 仅这个零尺寸观察器跟随播放时间；外接屏主体只在歌词行真正变化时刷新。
private struct ExternalDisplayLyricTimeObserver: View {
    @Environment(AudioPlayerService.self) private var player
    let onTimeChange: (TimeInterval) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: player.currentTime) { _, time in
                onTimeChange(time)
            }
    }
}
