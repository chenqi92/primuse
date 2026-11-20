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
    @Environment(\.lyricsTypeface) private var lyricsTypeface

    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoadRevision: UInt = 0
    @State private var currentLyricIndex = -1
    /// 对唱两人时间重叠时同时在唱的几行(`currentLyricIndex` 是其中最早开口的那一行);只有一行在唱时为 nil。
    @State private var concurrentLyricRows: LyricActiveRows?
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
        .modifier(ExternalDisplayLyricsReload(songID: player.currentSong?.id) {
            Task { await loadLyrics() }
        })
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
        .pmAnimation(.ambient, value: theme.colorID)
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
        // 对唱分左右(和 iPhone 歌词页同一规则):主声部靠左,另一声部靠右。
        let isDuet = KaraokeDuetGatePolicy.hasDuetParts(lyrics)

        return VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(lower..<upper), id: \.self) { realIndex in
                let line = lyrics[realIndex]
                let current = realIndex == index || concurrentLyricRows?.contains(realIndex) == true
                let distance = abs(realIndex - index)
                let isTrailing = LyricDuetLayoutPolicy.side(for: line.voice, preferred: .leading, isDuet: isDuet) == .trailing
                VStack(alignment: isTrailing ? .trailing : .leading, spacing: 6) {
                    lyricsTypeface.text(line.text, size: current ? 42 : 28, weight: current ? .bold : .semibold)
                        .currentLyricColor(
                            current ? Color.white : Color.white.opacity(max(0.18, 0.58 - Double(distance) * 0.14)),
                            isActive: current
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(isTrailing ? .trailing : .leading)
                        .minimumScaleFactor(0.74)
                        .shadow(color: current ? theme.accentColor.opacity(0.42) : .clear, radius: 18)

                    ForEach(line.background ?? []) { background in
                        let isBackgroundActive = LyricVoiceTimelinePolicy.isActive(
                            background,
                            at: player.currentTime
                        )
                        lyricsTypeface.text(background.text, size: current ? 28 : 22, weight: .medium)
                            .foregroundStyle(
                                Color.white.opacity(isBackgroundActive ? 0.82 : 0.38)
                            )
                            .lineLimit(2)
                            .multilineTextAlignment(isTrailing ? .trailing : .leading)
                            .minimumScaleFactor(0.74)
                    }
                }
                .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    private func updateLyricIndex(for time: TimeInterval) {
        guard !lyrics.isEmpty else {
            currentLyricIndex = -1
            concurrentLyricRows = nil
            return
        }
        // 对唱两人同时在唱时停在最早开口的那一行,另一行一起亮着。
        let rows = LyricConcurrentVoicePolicy.activeRows(in: lyrics, at: time)
        let nextIndex = rows?.anchor ?? -1
        let concurrent = rows?.isConcurrent == true ? rows : nil
        if nextIndex != currentLyricIndex {
            currentLyricIndex = nextIndex
        }
        if concurrent != concurrentLyricRows {
            concurrentLyricRows = concurrent
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
        lyricsLoadRevision &+= 1
        let revision = lyricsLoadRevision
        guard let song = player.currentSong else {
            lyrics = []
            currentLyricIndex = -1
            return
        }
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id)
        guard !Task.isCancelled, player.currentSong?.id == song.id,
              lyricsLoadRevision == revision else { return }
        // 和主屏同一份显示时间轴:整轨 CUE 分轨换到这一轨的时间、按这首的偏移平移(#426)。
        lyrics = SpokenWordTranscriptOffsetStore.shared.presenting(cached ?? [], for: player.currentSong)
        updateLyricIndex(for: player.currentTime)
    }
}

/// 外接屏只读主屏取回来写进缓存的歌词。切歌那一刻主屏多半还在取，缓存好了(或在主屏上
/// 换了一份歌词)再读一次，不然新放的歌在外接屏上一直没有歌词。
private struct ExternalDisplayLyricsReload: ViewModifier {
    let songID: String?
    let reload: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidCache).receive(on: DispatchQueue.main)) { note in
                guard let songID, note.userInfo?["songID"] as? String == songID else { return }
                reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange).receive(on: DispatchQueue.main)) { note in
                guard let songID, note.object as? String == songID else { return }
                reload()
            }
    }
}

#if os(iOS)
/// 外接屏选了「全屏效果」：和播放页全屏同一套舞台，不出控件、不进休憩
/// (见 `ImmersivePlayerView.presentsOnExternalDisplay`)。效果在设置里单独选，没选过跟着播放页。
struct ExternalDisplayImmersiveView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ExternalDisplayContentMode.effectStorageKey) private var effectRawValue = ""
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var playerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.simulatesWordLyricsKey)
    private var simulatesWordLyrics = PlayerAppearancePreferences.simulatesWordLyricsByDefault

    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoadRevision: UInt = 0
    @State private var isResolvingLyrics = true

    private var displayedLyrics: (lines: [LyricLine], isSimulated: Bool) {
        let shouldSimulate = simulatesWordLyrics
            && !lyrics.contains(where: \.containsWordLevelContent)
            && !player.currentItemIsSpokenWord
        guard shouldSimulate else { return (lyrics, false) }
        _ = WordLyricsAlignmentService.shared.alignmentRevision
        let overlay = WordLyricsAlignmentService.shared.overlay(for: player.currentSong, lines: lyrics)
        let timed = SimulatedWordLyricsPolicy.presentation(
            of: lyrics,
            enabled: true,
            isSpokenWord: player.currentItemIsSpokenWord,
            overlay: overlay
        )
        return (timed.lines, timed.isSimulated)
    }

    private var effect: Binding<FullscreenPlayerEffect> {
        Binding(
            get: {
                FullscreenPlayerEffect.externalDisplayEffect(
                    storedValue: effectRawValue,
                    playerEffectValue: playerEffectRawValue
                )
            },
            set: { effectRawValue = $0.rawValue }
        )
    }

    var body: some View {
        let presentation = displayedLyrics
        ImmersivePlayerView(
            effect: effect,
            lyrics: presentation.lines,
            showsSimulatedWordTiming: presentation.isSimulated,
            lyricCompanions: {
                LyricsScrollView.companionTexts(for: $0, translatedTextByLineID: [:])
            },
            lyricsWritingDirection: LyricWritingDirectionPolicy.resolve(in: presentation.lines),
            isResolvingLyrics: isResolvingLyrics,
            // 外接屏不接受触摸，系统可能一直把它当成「在前台但不活跃」；退到后台才停下来。
            isSceneActive: scenePhase != .background,
            onDismiss: {},
            onMinimize: {},
            onShowQueue: {},
            presentsOnExternalDisplay: true
        )
        .task(id: player.currentSong?.id) { await loadLyrics() }
        .onChange(of: simulatesWordLyrics) { _, _ in triggerExternalAlignmentIfNeeded() }
        .onChange(of: lyrics.count) { _, _ in triggerExternalAlignmentIfNeeded() }
        .modifier(ExternalDisplayLyricsReload(songID: player.currentSong?.id) {
            Task { await loadLyrics() }
        })
    }

    private func triggerExternalAlignmentIfNeeded() {
        guard simulatesWordLyrics,
              !player.currentItemIsSpokenWord,
              !lyrics.contains(where: \.containsWordLevelContent),
              let song = player.currentSong else { return }
        let capturedSourceManager = sourceManager
        WordLyricsAlignmentService.shared.alignIfNeeded(
            song: song,
            lines: lyrics,
            playbackTime: player.interpolatedTime()
        ) {
            await WordLyricsAlignmentService.localAudioFile(for: song, sourceManager: capturedSourceManager)
        }
    }

    private func loadLyrics() async {
        lyricsLoadRevision &+= 1
        let revision = lyricsLoadRevision
        guard let songID = player.currentSong?.id else {
            lyrics = []
            isResolvingLyrics = false
            return
        }
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID)
        guard !Task.isCancelled, player.currentSong?.id == songID,
              lyricsLoadRevision == revision else { return }
        lyrics = SpokenWordTranscriptOffsetStore.shared.presenting(cached ?? [], for: player.currentSong)
        isResolvingLyrics = false
    }
}
#endif

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
