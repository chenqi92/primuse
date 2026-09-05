#if os(macOS)
import AppKit
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
/// active line highlighted and pinned near the vertical center. In full
/// screen the left column also gets the SYS-05 cover transport rail.
struct MacNowPlayingView: View {
    var onClose: () -> Void
    var isScrapingCurrentSong: Bool
    var canTranscribeAudio: Bool
    var onScrapeCurrentSong: () -> Void
    var onTranscribeAudio: () -> Void
    var onToggleQueue: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ThemeService.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @Environment(\.scenePhase) private var scenePhase

    @State private var lyrics: [LyricLine] = []
    @State private var lyricsWritingDirection: LyricWritingDirection = .natural
    @State private var currentIndex: Int = -1
    @State private var activeBackgroundLineIDs: Set<String> = []
    @State private var lyricsLoadRevision: UInt = 0
    @State private var pendingLyricsOverride: PendingLyricsOverride?
    @State private var lastManualLyricsScroll = Date.distantPast
    @State private var lyricsAutoFollowTask: Task<Void, Never>?
    @State private var hostWindow: NSWindow?
    /// 当前主窗口是否处于 macOS 全屏。全屏时使用设计稿 SYS-05 的
    /// NP-FullScreen 双栏布局: 隐藏侧栏后放大封面、歌词和浮动控制。
    @State private var isWindowFullScreen = false
    @State private var showsNativeFullscreenEffectPicker = false
    /// 全屏时是否切到「沉浸展示」(共享的 ImmersiveStageView),而非常规播放页。
    @State private var showsImmersiveStage = false
    @State private var preferences = MacUIPreferences.shared
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenPlayerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsPlayerVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.tapLyricsToSeekKey)
    private var tapLyricsToSeek = PlayerAppearancePreferences.tapLyricsToSeekByDefault

    private var fullscreenPlayerEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: fullscreenPlayerEffectRawValue) ?? .defaultValue
    }

    /// 是否正在显示沉浸展示屏(仅全屏、有歌、非直播时)。
    private var isImmersiveStageActive: Bool {
        isWindowFullScreen
            && fullscreenPlayerEffect != .native
            && showsImmersiveStage
            && player.currentSong != nil
            && !player.isLiveRadio
    }

    /// 与 iOS 共用同一个键 `lyricsFontScale` (0.7..1.8),通过 CloudKVS 双向同步。
    /// 之前的 `now_playing_lyrics_base_font` 是 macOS 独有的本地键,改这里
    /// 同时让 iOS 端的 4 档预设也直接生效。
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    /// Keep lyric rows on a stable layout size and only apply a subtle active
    /// scale at render time. The previous 30/22 (fullscreen 44/28) ratio made
    /// every line takeover feel like a large zoom even though it was animated.
    private static let lyricsBaseSize: CGFloat = 25
    private static let lyricsBaseSizeFS: CGFloat = 32
    private static let lyricsActiveVisualScale: CGFloat = 1.10
    /// Match the iOS lyrics motion: the row highlight and the scroll position
    /// travel on the same smooth curve, so a line change reads as one gesture.
    private static let lyricsTransitionDuration: TimeInterval = 0.54
    private static let lyricsVisualAnchor: CGFloat = 0.42
    private static let lineLevelLookahead: TimeInterval = 0.25
    private static let wordLevelLookahead: TimeInterval = 0.10
    /// Give people enough time to browse earlier/later lyrics before playback
    /// takes control of the scroll position again. Three seconds was shorter
    /// than a typical reading pause and made the pane appear locked.
    private static let manualLyricsScrollGracePeriod: TimeInterval = 6

    private var lyricLayoutDirection: LayoutDirection {
        switch lyricsWritingDirection {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    private var isCurrentLiked: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.isLiked(songID: songID)
    }

    private var usesLightPlayerAppearance: Bool { colorScheme == .light }
    private var playerPrimaryColor: Color {
        usesLightPlayerAppearance ? .black.opacity(0.88) : .white
    }
    private var playerSecondaryColor: Color {
        usesLightPlayerAppearance ? .black.opacity(0.64) : .white.opacity(0.72)
    }
    private var playerFaintColor: Color {
        usesLightPlayerAppearance ? .black.opacity(0.46) : .white.opacity(0.5)
    }
    private var playerGlassFill: Color {
        usesLightPlayerAppearance ? .black.opacity(0.07) : .white.opacity(0.12)
    }
    private var playerGlassBorder: Color {
        usesLightPlayerAppearance ? .black.opacity(0.12) : .white.opacity(0.16)
    }

    var body: some View {
        ZStack {
            if isImmersiveStageActive {
                MacImmersivePlayerView(
                    lyrics: lyrics,
                    onExitFullScreen: { exitFullScreen() },
                    onToggleQueue: onToggleQueue
                )
                .transition(.opacity)
            } else {
                ZStack {
                    backdrop

                    if player.currentSong == nil {
                        emptyNowPlaying
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal, 48)
                    } else if player.isLiveRadio {
                        radioNowPlaying
                    } else {
                        HStack(alignment: .center, spacing: isWindowFullScreen ? 80 : 40) {
                            artworkPane
                                .frame(width: isWindowFullScreen ? 520 : 380)
                                .frame(maxHeight: .infinity)
                            lyricsPane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(.horizontal, isWindowFullScreen ? 100 : 56)
                        .padding(.top, isWindowFullScreen ? 70 : 50)
                        .padding(.bottom, isWindowFullScreen ? 80 : 60)
                    }

                    VStack(alignment: .trailing, spacing: 10) {
                        if player.isLiveRadio {
                            radioFloatingControls
                        } else {
                            floatingControls
                        }
                        if isWindowFullScreen, showsPlayerVolumeBar {
                            fullscreenVolumeControl
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(isWindowFullScreen ? 24 : 16)
                }
            }
        }
        .overlay {
            if isWindowFullScreen, showsNativeFullscreenEffectPicker {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.16)) {
                            showsNativeFullscreenEffectPicker = false
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if isWindowFullScreen, !isImmersiveStageActive {
                HStack(spacing: 10) {
                    exitFullScreenPill
                    nativeFullscreenEffectMenu
                }
                    .padding(.top, 18)
                    .padding(.leading, 22)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: isImmersiveStageActive)
        .background {
            NowPlayingWindowResolver { window in
                hostWindow = window
                // 初始同步: 视图可能在主窗口已经全屏之后才被创建,此时早已发出的
                // didEnterFullScreen 通知收不到,只能直接读窗口的 styleMask 兜底,
                // 否则全屏下会错渲染成窗口版布局。
                if let window {
                    isWindowFullScreen = window.styleMask.contains(.fullScreen)
                    if isWindowFullScreen {
                        showsImmersiveStage = fullscreenPlayerEffect != .native
                    }
                }
            }
        }
        .task(id: lyricsLoadTaskIdentity) {
            if player.isLiveRadio {
                installLyrics([])
            } else {
                await refreshLyrics()
            }
        }
        .background {
            if !isImmersiveStageActive {
                MacNowPlayingTimeObserver { updateIndex(time: $0) }
            }
        }
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange)) { note in
            guard let songID = note.object as? String,
                  songID == player.currentSong?.id else { return }
            pendingLyricsOverride = (note.userInfo?["lyrics"] as? [LyricLine]).map {
                PendingLyricsOverride(songID: songID, lyrics: $0)
            }
            lyricsLoadRevision &+= 1
        }
        // 监听主窗口进入/退出全屏(macOS NSWindow 通知),切换布局。
        // 校验通知来源窗口是本视图所在的 hostWindow,避免多开主窗口或设置等
        // 其他窗口的全屏事件误触发本窗口的布局切换。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            isWindowFullScreen = true
            showsImmersiveStage = fullscreenPlayerEffect != .native
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            showsNativeFullscreenEffectPicker = false
            showsImmersiveStage = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            showsNativeFullscreenEffectPicker = false
            isWindowFullScreen = false
            showsImmersiveStage = false
        }
        .onChange(of: fullscreenPlayerEffectRawValue) { _, rawValue in
            guard isWindowFullScreen else { return }
            let selected = FullscreenPlayerEffect(rawValue: rawValue) ?? .defaultValue
            showsImmersiveStage = selected != .native
        }
    }

    // MARK: - Sections

    private var emptyNowPlaying: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.primary.opacity(0.06))
                    .frame(width: 118, height: 118)
                Image(systemName: "music.note")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Text("player_empty_title")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(playerPrimaryColor)
                Text("player_empty_message")
                    .font(.title3)
                    .foregroundStyle(playerSecondaryColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: 520)
        }
    }

    private var radioNowPlaying: some View {
        HStack(spacing: isWindowFullScreen ? 90 : 54) {
            if let station = player.currentRadioStation {
                let size: CGFloat = isWindowFullScreen ? 520 : 380
                RadioStationArtworkView(
                    station: station,
                    size: size,
                    cornerRadius: isWindowFullScreen ? 24 : 18
                )
                .shadow(color: .black.opacity(0.30), radius: 28, y: 14)
            }

            VStack(alignment: .leading, spacing: 18) {
                Spacer()

                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("live_badge")
                        .font(.system(size: 13, weight: .bold))
                    if player.currentTime > 0 {
                        Text("·")
                        Text(player.currentTime.formattedDuration)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(playerSecondaryColor)

                Text(player.currentRadioStation?.name ?? player.currentSong?.title ?? "")
                    .font(.system(size: isWindowFullScreen ? 48 : 38, weight: .bold))
                    .foregroundStyle(playerPrimaryColor)
                    .lineLimit(2)

                Text(
                    player.radioMetadataTitle
                        ?? player.currentSong.flatMap { library.artistDisplayName(for: $0) }
                        ?? ""
                )
                    .font(.system(size: isWindowFullScreen ? 24 : 20, weight: .medium))
                    .foregroundStyle(playerSecondaryColor)
                    .lineLimit(3)

                Text(radioTechnicalSummary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(playerFaintColor)

                HStack(spacing: 12) {
                    Button { Task { await player.previous() } } label: {
                        Image(systemName: "backward.fill")
                            .frame(width: 42, height: 42)
                            .background(playerFaintColor.opacity(0.14), in: Circle())
                    }
                    .disabled(!player.canSwitchRadioStation)
                    .help(Text("radio_previous_station"))

                    Button { player.togglePlayPause() } label: {
                        Label(
                            (player.isPlaying || player.isLoading)
                                ? String(localized: "radio_stop")
                                : String(localized: "a11y_play"),
                            systemImage: (player.isPlaying || player.isLoading)
                                ? "stop.circle.fill"
                                : "play.circle.fill"
                        )
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 20)
                        .frame(height: 46)
                        .foregroundStyle(theme.onAccent)
                        .background(theme.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button { Task { await player.next() } } label: {
                        Image(systemName: "forward.fill")
                            .frame(width: 42, height: 42)
                            .background(playerFaintColor.opacity(0.14), in: Circle())
                    }
                    .disabled(!player.canSwitchRadioStation)
                    .help(Text("radio_next_station"))
                }

                Spacer()
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.horizontal, isWindowFullScreen ? 120 : 72)
        .padding(.vertical, isWindowFullScreen ? 100 : 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var radioTechnicalSummary: String {
        var parts = [player.radioStreamFormat.displayName]
        if let bitRate = player.radioBitRate, bitRate > 0 {
            parts.append("\(bitRate / 1_000) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private var radioFloatingControls: some View {
        HStack(spacing: 8) {
            if let url = player.currentRadioStation?.url {
                ShareLink(item: url) {
                    circleIcon("square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(Text("share"))
            }
            if !isWindowFullScreen {
                Button(action: onClose) { circleIcon("chevron.down") }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help(Text("close"))
            }
        }
    }

    /// 1.6 重设计后的 ambient backdrop — 由 ThemeService 的动态 accent (从封面提取)
    /// 驱动多色斑模糊, 替代之前的 cover blur + ultraThinMaterial 组合, 让背景跟着
    /// 当前歌曲色调走, 跟设计稿 AmbientBackdrop 视觉一致。
    ///
    /// 关键: 两种外观都先铺不透明底，避免 overlay 穿透到后面的详情页。深色延续
    /// 高对比的 ambient backdrop；浅色用低饱和封面色斑叠在系统浅色背景上，而不是
    /// 强制显示深色播放器。
    private var backdrop: some View {
        let strength = AppThemePreferences.normalizedAmbientStrength(preferences.ambientStrength)
        let hasArtworkTheme = theme.hasArtworkAmbient
        let lightOverlay = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: hasArtworkTheme,
            usesIncreasedContrast: colorSchemeContrast == .increased,
            strength: strength
        )
        let primaryOpacity = (usesLightPlayerAppearance
            ? (hasArtworkTheme ? 0.34 : 0.12)
            : (hasArtworkTheme ? 0.74 : 0.32)) * strength
        let secondaryOpacity = (usesLightPlayerAppearance
            ? (hasArtworkTheme ? 0.22 : 0.08)
            : (hasArtworkTheme ? 0.58 : 0.24)) * strength
        let darkOverlay = NowPlayingAmbientLegibilityPolicy.darkOverlay(
            paletteLuminance: theme.artworkLuminance,
            primaryOpacity: primaryOpacity,
            secondaryOpacity: secondaryOpacity,
            usesIncreasedContrast: colorSchemeContrast == .increased
        )

        return ZStack {
            AdaptiveNowPlayingBackdrop(
                baseColor: usesLightPlayerAppearance ? PMColor.bg : PMColor.ambientDarkBase,
                primaryAccent: theme.accentColor,
                secondaryAccent: theme.secondaryAccent,
                darkAccent: theme.darkAccent,
                primaryOpacity: primaryOpacity,
                secondaryOpacity: secondaryOpacity,
                hasArtworkPalette: hasArtworkTheme,
                isVisible: !isImmersiveStageActive && controlActiveState != .inactive,
                isSceneActive: scenePhase == .active,
                isPlaying: player.isPlaying,
                paletteVibrancy: theme.artworkVibrancy,
                paletteLuminance: theme.artworkLuminance
            )

            if usesLightPlayerAppearance {
                LinearGradient(
                    colors: [
                        .white.opacity(lightOverlay.topOpacity),
                        .white.opacity(lightOverlay.bottomOpacity)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                LinearGradient(
                    stops: [
                        .init(
                            color: .black.opacity(darkOverlay.topOpacity),
                            location: 0
                        ),
                        .init(
                            color: .black.opacity(darkOverlay.middleOpacity),
                            location: 0.55
                        ),
                        .init(
                            color: .black.opacity(darkOverlay.bottomOpacity),
                            location: 1
                        )
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
        .ignoresSafeArea()
    }

    private var artworkPane: some View {
        let coverSize: CGFloat = isWindowFullScreen ? 520 : 380
        let coverRadius: CGFloat = isWindowFullScreen ? 18 : 14
        let isShowingMusicVideo = player.isMusicVideoPlaybackActive && player.musicVideoPlayer != nil
        let mediaHeight = isShowingMusicVideo ? coverSize * 9 / 16 : coverSize
        let horizontalAlignment: HorizontalAlignment = isWindowFullScreen ? .center : .leading
        let frameAlignment: Alignment = isWindowFullScreen ? .center : .leading
        let textAlignment: TextAlignment = isWindowFullScreen ? .center : .leading

        return VStack(alignment: horizontalAlignment, spacing: isWindowFullScreen ? 32 : 18) {
            Spacer(minLength: 0)
            ZStack {
                RadialGradient(
                    colors: [theme.accentColor.opacity(0.36 * preferences.ambientStrength), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: coverSize * 0.62
                )
                .frame(width: coverSize + 40, height: mediaHeight + 40)
                .blur(radius: 30)

                if player.isMusicVideoPlaybackActive, let videoPlayer = player.musicVideoPlayer {
                    ZStack(alignment: .topTrailing) {
                        MusicVideoSurface(player: videoPlayer)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .frame(width: coverSize, height: mediaHeight)
                            .background(Color.black)

                        if !isWindowFullScreen {
                            Button {
                                showsImmersiveStage = fullscreenPlayerEffect != .native
                                fullScreenWindow()?.toggleFullScreen(nil)
                            } label: {
                                circleIcon("arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .padding(12)
                            .help(Text("full_screen_player"))
                        }
                    }
                    .frame(width: coverSize, height: mediaHeight)
                    .clipShape(RoundedRectangle(cornerRadius: coverRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: coverRadius, style: .continuous)
                            .strokeBorder(playerPrimaryColor.opacity(0.14), lineWidth: 0.5)
                    }
                } else if let song = player.currentSong {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: nil,
                        cornerRadius: coverRadius,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        presentationRole: .animatedHero,
                        animationRequiresPlayback: true,
                        isPlaying: player.isPlaying,
                        isAnimationVisible: !showsImmersiveStage
                            && scenePhase == .active
                            && controlActiveState != .inactive
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: coverSize, height: coverSize)
                } else {
                    CoverArtView(data: nil, size: coverSize, cornerRadius: coverRadius)
                }
            }
            .frame(width: coverSize, height: mediaHeight)
            .scaleEffect(
                isShowingMusicVideo || reduceMotion || player.currentSong == nil
                    ? 1
                    : (player.isPlaying ? 1 : 0.975)
            )
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.38, dampingFraction: 0.88),
                value: player.isPlaying
            )
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)

            VStack(alignment: horizontalAlignment, spacing: 0) {
                Text(nowPlayingInfoLine)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(playerFaintColor)
                    .textCase(.uppercase)
                Text(player.currentSong?.title ?? "")
                    .font(.system(size: isWindowFullScreen ? 56 : 36, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(playerPrimaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(textAlignment)
                    .padding(.top, 10)
                if let song = player.currentSong {
                    MacNowPlayingMetadata(
                        song: song,
                        alignment: horizontalAlignment,
                        foreground: playerSecondaryColor,
                        highlight: playerPrimaryColor
                    )
                    .font(.system(size: isWindowFullScreen ? 20 : 16))
                    .padding(.top, 6)
                }
                if let sourceLabel, !sourceLabel.isEmpty {
                    Text(sourceLabel)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(playerFaintColor)
                        .lineLimit(1)
                        .padding(.top, 6)
                }
            }
            .frame(width: coverSize, alignment: frameAlignment)

            if isWindowFullScreen {
                MacNowPlayingProgressRow(width: coverSize, accent: theme.accentColor)
            }

            Spacer(minLength: 0)
        }
    }

    private var lyricsPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Every row keeps the same layout height. Only the active row is
                // subtly scaled at the rendering layer, so switching lines does
                // not reflow the stack or produce a hard jump.
                LazyVStack(alignment: .leading, spacing: isWindowFullScreen ? 18 : 14) {
                    Spacer(minLength: isWindowFullScreen ? 120 : 80)
                        .frame(height: isWindowFullScreen ? 120 : 80)
                    if lyrics.isEmpty {
                        if player.currentSong == nil {
                            Color.clear.frame(height: 1)
                        } else {
                            VStack(spacing: 12) {
                                Text("no_lyrics")
                                    .font(.title3)
                                    .foregroundStyle(playerSecondaryColor)
                                Button {
                                    onScrapeCurrentSong()
                                } label: {
                                    HStack(spacing: 7) {
                                        if isScrapingCurrentSong {
                                            ProgressView()
                                                .controlSize(.small)
                                                .tint(playerPrimaryColor)
                                                .transition(.scale.combined(with: .opacity))
                                        } else {
                                            Image(systemName: "wand.and.stars")
                                                .transition(.scale.combined(with: .opacity))
                                        }
                                        Text("scrape_song")
                                    }
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(playerGlassFill, in: Capsule())
                                    .overlay { Capsule().strokeBorder(playerGlassBorder, lineWidth: 0.5) }
                                    .foregroundStyle(playerPrimaryColor)
                                    .animation(.smooth(duration: 0.2, extraBounce: 0), value: isScrapingCurrentSong)
                                }
                                .buttonStyle(.plain)
                                .disabled(isScrapingCurrentSong)

                                if canTranscribeAudio {
                                    Button {
                                        onTranscribeAudio()
                                    } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: "waveform.badge.mic")
                                            Text("ai_audio_transcription_action")
                                        }
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(PMColor.brand, in: Capsule())
                                        .foregroundStyle(Color.white)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isScrapingCurrentSong)

                                    Text("ai_audio_transcription_now_playing_detail")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(playerFaintColor)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { i, line in
                            let isActive = i == currentIndex
                            macLyricLine(
                                line: line,
                                index: i,
                                isActive: isActive,
                                fontSize: lyricLayoutFontSize
                            )
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .if(canSeekToLyricLine(line)) { view in
                                    view
                                        .onTapGesture { seekToLyricLine(line) }
                                        .accessibilityAddTraits(.isButton)
                                        .accessibilityHint(Text("player_tap_lyrics_to_seek_description"))
                                }
                        }
                    }
                    Spacer(minLength: isWindowFullScreen ? 240 : 200)
                        .frame(height: isWindowFullScreen ? 240 : 200)
                }
                .padding(.horizontal, isWindowFullScreen ? 0 : PMSpace.l24)
            }
            .pmVerticalFadeMask(
                startStop: isWindowFullScreen ? 0.18 : 0.12,
                endStop: isWindowFullScreen ? 0.82 : 0.88
            )
            .onChange(of: currentIndex) { _, new in
                guard Date().timeIntervalSince(lastManualLyricsScroll) >= Self.manualLyricsScrollGracePeriod else { return }
                scrollLyrics(to: new, proxy: proxy, animated: true)
            }
            // A macOS trackpad/mouse wheel scroll is not guaranteed to produce
            // a SwiftUI DragGesture. Observe the actual scroll phase as well so
            // auto-follow yields while the user browses the complete lyrics.
            // Programmatic scrollTo animations use `.animating` and are ignored.
            .onScrollPhaseChange { oldPhase, newPhase in
                switch newPhase {
                case .tracking, .interacting, .decelerating:
                    beginManualLyricsBrowsing()
                case .idle:
                    if oldPhase == .tracking || oldPhase == .interacting || oldPhase == .decelerating {
                        endManualLyricsBrowsing(proxy: proxy)
                    }
                case .animating:
                    break
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        beginManualLyricsBrowsing()
                    }
                    .onEnded { _ in
                        endManualLyricsBrowsing(proxy: proxy)
                    }
            )
            .task(id: lyricsScrollIdentity) {
                let targetIndex = updateIndex(time: player.currentTime)
                await Task.yield()
                guard !Task.isCancelled, let targetIndex else { return }
                scrollLyrics(to: targetIndex, proxy: proxy, animated: false)
            }
            .onDisappear {
                lyricsAutoFollowTask?.cancel()
            }
        }
    }

    private var lyricsScrollIdentity: String {
        "\(player.currentSong?.id ?? "")|\(lyricsLoadRevision)|\(lyrics.first?.id ?? "")|\(lyrics.count)"
    }

    private struct LyricsLoadTaskIdentity: Hashable {
        let songID: String?
        let revision: UInt
    }

    private struct PendingLyricsOverride {
        let songID: String
        let lyrics: [LyricLine]
    }

    private var lyricsLoadTaskIdentity: LyricsLoadTaskIdentity {
        LyricsLoadTaskIdentity(
            songID: player.currentSong?.id,
            revision: lyricsLoadRevision
        )
    }

    private func scheduleLyricsAutoFollow(proxy: ScrollViewProxy) {
        lyricsAutoFollowTask?.cancel()
        lyricsAutoFollowTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.manualLyricsScrollGracePeriod))
            guard !Task.isCancelled,
                  Date().timeIntervalSince(lastManualLyricsScroll) >= Self.manualLyricsScrollGracePeriod else { return }
            scrollLyrics(to: currentIndex, proxy: proxy, animated: true)
        }
    }

    private func beginManualLyricsBrowsing() {
        lyricsAutoFollowTask?.cancel()
        lastManualLyricsScroll = Date()
    }

    private func endManualLyricsBrowsing(proxy: ScrollViewProxy) {
        lastManualLyricsScroll = Date()
        scheduleLyricsAutoFollow(proxy: proxy)
    }

    private func scrollLyrics(to index: Int, proxy: ScrollViewProxy, animated: Bool) {
        guard lyrics.indices.contains(index) else { return }
        let update = {
            proxy.scrollTo(
                lyrics[index].id,
                anchor: UnitPoint(x: 0.5, y: Self.lyricsVisualAnchor)
            )
        }
        if animated {
            withAnimation(.smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0), update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
    }

    private var lyricLayoutFontSize: CGFloat {
        isWindowFullScreen ? Self.lyricsBaseSizeFS : Self.lyricsBaseSize
    }

    @ViewBuilder
    private func macLyricLine(line: LyricLine, index: Int, isActive: Bool, fontSize: CGFloat) -> some View {
        let scaledSize = fontSize * CGFloat(lyricsFontScale)
        // Keep weight/layout stable and express activity through render-layer
        // scale + opacity, mirroring the iOS word-level lyrics treatment.
        let weight: Font.Weight = .semibold
        let tint = theme.accentColor
        let distance = abs(index - currentIndex)
        let hasActiveBackground = line.background?.contains {
            activeBackgroundLineIDs.contains($0.id)
        } ?? false
        let opacity = lyricOpacity(
            isActive: isActive || hasActiveBackground,
            distance: distance
        )
        let visualScale = lyricVisualScale(isActive: isActive)

        VStack(alignment: .leading, spacing: 4) {
            macSingleLyricLine(
                line: line,
                index: index,
                isActive: isActive,
                fontSize: scaledSize,
                weight: weight,
                tint: tint
            )
            if let backgrounds = line.background {
                ForEach(backgrounds) { background in
                    macSingleLyricLine(
                        line: background,
                        index: index,
                        isActive: activeBackgroundLineIDs.contains(background.id),
                        fontSize: scaledSize * 0.7,
                        weight: .medium,
                        tint: tint
                    )
                    .opacity(0.72)
                }
            }
        }
        .opacity(opacity)
        .frame(minHeight: scaledSize * 1.3, alignment: .leading)
        .scaleEffect(visualScale, anchor: .leading)
        .animation(
            .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
            value: currentIndex
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    @ViewBuilder
    private func macSingleLyricLine(
        line: LyricLine,
        index: Int,
        isActive: Bool,
        fontSize: CGFloat,
        weight: Font.Weight,
        tint: Color
    ) -> some View {
        if shouldRenderWordTimeline(line: line, index: index, isActive: isActive) {
            KaraokeLineView(
                line: line,
                fontSize: fontSize,
                weight: weight,
                activeColor: playerPrimaryColor,
                inactiveColor: playerSecondaryColor,
                writingDirection: lyricsWritingDirection,
                timeAt: { date in player.interpolatedTime(at: date) },
                isPlaybackActive: player.isPlaybackActive,
                isAnimationEnabled: isActive,
                animatesSyllableBounce: false,
                isolatesAnimatedProgressFromLayout: true,
                deactivationTime: line.voice == .secondary ? line.endTime : nil
            )
            .shadow(color: isActive ? tint.opacity(0.32) : .clear, radius: 14)
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(playerPrimaryColor)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lyricVisualScale(isActive: Bool) -> CGFloat {
        isActive ? Self.lyricsActiveVisualScale : 1
    }

    private func lyricOpacity(isActive: Bool, distance: Int) -> Double {
        if isActive { return 1 }
        // Every row must remain readable when the user scrolls away from the
        // current playback position. The old distance cutoff returned zero for
        // all but the surrounding 5-6 rows, so the ScrollView did move while
        // appearing to contain no additional lyrics.
        return max(0.50, 0.78 - Double(distance) * 0.10)
    }

    private func shouldRenderWordTimeline(line: LyricLine, index: Int, isActive: Bool) -> Bool {
        guard line.isWordLevel else { return false }
        return isActive || (currentIndex >= 0 && abs(index - currentIndex) == 1)
    }

    // MARK: - Fullscreen cover transport

    private var nowPlayingInfoLine: String {
        guard let song = player.currentSong else { return "" }
        var parts = [String(localized: "now_playing"), song.fileFormat.displayName]
        if let bitRate = song.formattedBitRate {
            parts.append(bitRate)
        }
        if let sampleRate = song.formattedSampleRate {
            parts.append(sampleRate)
        }
        if let bitDepth = song.formattedBitDepth {
            parts.append(bitDepth)
        }
        return parts.joined(separator: " · ")
    }

    private var sourceLabel: String? {
        guard let song = player.currentSong else { return nil }
        if let source = sourcesStore.source(id: song.sourceID) {
            return source.name
        }
        let fallback = URL(fileURLWithPath: song.filePath).lastPathComponent
        return fallback.isEmpty ? nil : fallback
    }

    // MARK: - Floating controls (top-right of the window)

    private var exitFullScreenPill: some View {
        Button {
            exitFullScreen()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("exit_full_screen")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(playerPrimaryColor.opacity(0.88))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(playerGlassFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(playerGlassBorder, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(Text("exit_full_screen"))
    }

    private var nativeFullscreenEffectMenu: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                showsNativeFullscreenEffectPicker.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "viewfinder.rectangular")
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: fullscreenPlayerEffect.localizedTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(playerPrimaryColor.opacity(0.88))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(playerGlassFill, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(playerGlassBorder, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay(alignment: .topLeading) {
            if showsNativeFullscreenEffectPicker {
                ImmersiveEffectPickerSurface(
                    selected: fullscreenPlayerEffect,
                    palette: ImmersiveArtworkPalette(
                        primary: theme.accentColor,
                        secondary: theme.secondaryDarkAccent
                    )
                ) { candidate in
                    showsNativeFullscreenEffectPicker = false
                    selectFullscreenEffect(candidate)
                }
                .offset(y: 40)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }
        }
        .zIndex(showsNativeFullscreenEffectPicker ? 20 : 0)
        .help(Text("fullscreen_effect_settings_title"))
        .accessibilityLabel(Text("fullscreen_effect_settings_title"))
    }

    private var floatingControls: some View {
        HStack(spacing: 8) {
            // Heart
            Button { toggleLikedCurrent() } label: {
                circleIcon(isCurrentLiked ? "heart.fill" : "heart",
                           tint: isCurrentLiked ? theme.onAccent : nil,
                           fill: isCurrentLiked ? theme.accentColor : nil)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
            .disabled(player.currentSong == nil)

            // 独立 MV 始终走视频管线, 模式开关对它无意义, 不显示
            if player.canPlayMusicVideo, player.currentSong?.isStandaloneMusicVideo != true {
                Button { player.toggleMusicVideoMode() } label: {
                    circleIcon(player.isMusicVideoModeEnabled ? "play.rectangle.fill" : "play.rectangle",
                               tint: player.isMusicVideoModeEnabled ? theme.onAccent : nil,
                               fill: player.isMusicVideoModeEnabled ? theme.accentColor.opacity(0.9) : nil)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(Text("MV"))
                .disabled(player.isLoading)
            }

            // This filled icon represents the lyrics view that is already
            // active. A second click toggles it off, just like the down button.
            Button {
                onClose()
            } label: {
                circleIcon("text.bubble.fill",
                           tint: theme.onAccent,
                           fill: theme.accentColor.opacity(0.9))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_word"))
            .disabled(player.currentSong == nil)

            Button {
                onClose()
                NotificationCenter.default.post(name: .primuseFocusSearch, object: nil)
            } label: {
                circleIcon("magnifyingglass")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("search_title"))

            // Font smaller
            Button {
                lyricsFontScale = max(Self.lyricsMinScale, lyricsFontScale - 0.15)
            } label: {
                Text(verbatim: "A-")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(playerPrimaryColor.opacity(0.88))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_font_smaller"))
            .disabled(lyrics.isEmpty)

            // Font larger
            Button {
                lyricsFontScale = min(Self.lyricsMaxScale, lyricsFontScale + 0.15)
            } label: {
                Text(verbatim: "A+")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(playerPrimaryColor.opacity(0.88))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_font_larger"))
            .disabled(lyrics.isEmpty)

            // 复用底栏共享的 PlayerMoreMenu,确保两处菜单项一致。
            PlayerMoreMenu {
                circleIcon("ellipsis")
            }
            .frame(width: 36, height: 36)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("more"))

            if !isWindowFullScreen {
                Button {
                    onClose()
                } label: {
                    circleIcon("chevron.down")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(Text("close"))
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var fullscreenVolumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(playerPrimaryColor.opacity(0.82))
                .frame(width: 18)

            PMVolumeSlider(value: Binding(
                get: { Double(engine.volume) },
                set: { player.setPlaybackVolume(Float($0)) }
            ), isEnabled: player.isLiveRadio || player.playbackSettings.outputMode == .effects,
               accessibilityLabel: String(localized: "volume"),
               accessibilityHelp: !player.isLiveRadio && player.playbackSettings.outputMode == .highFidelity
                   ? String(localized: "volume_high_fidelity_system_hint")
                   : nil)
            .frame(width: 118)

            Text(verbatim: "\((engine.volume * 100).rounded().finiteInt())")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(playerSecondaryColor)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(playerGlassFill, in: Capsule())
        .overlay {
            Capsule().strokeBorder(playerGlassBorder, lineWidth: 0.5)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(!player.isLiveRadio && player.playbackSettings.outputMode == .highFidelity
            ? Text("volume_high_fidelity_system_hint")
            : Text("volume"))
    }

    private var volumeSymbol: String {
        let v = engine.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.wave.1.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// 关键: 把 36×36 frame + contentShape 放在 Button 的 label 内部
    /// (而不是包在 Button 外面),这样整个圆形区域都是 Button 的有效点击
    /// 区——之前 .frame 套在 Button 外面,Button 的实际命中区只跟图标
    /// 一样大,玻璃外圈那一圈点了没反应。
    private func circleIcon(_ symbol: String,
                            tint: Color? = nil,
                            fill: Color? = nil) -> some View {
        ZStack {
            if let fill {
                Circle().fill(fill)
            }
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? playerPrimaryColor.opacity(0.85))
        }
        .frame(width: 36, height: 36)
        .contentShape(Circle())
    }

    private func toggleLikedCurrent() {
        guard let songID = player.currentSong?.id else { return }
        library.toggleLiked(songID: songID)
    }

    private func selectFullscreenEffect(_ value: FullscreenPlayerEffect) {
        fullscreenPlayerEffectRawValue = value.rawValue
        FullscreenPlayerEffectSync.shared.select(value)
    }

    private func exitFullScreen() {
        let window = fullScreenWindow()
        guard isWindowFullScreen || window?.styleMask.contains(.fullScreen) == true else { return }
        showsNativeFullscreenEffectPicker = false
        window?.toggleFullScreen(nil)
    }

    private func fullScreenWindow() -> NSWindow? {
        hostWindow
    }

    // MARK: - Lyrics loading

    private func refreshLyrics() async {
        if let pendingLyricsOverride,
           pendingLyricsOverride.songID == player.currentSong?.id {
            self.pendingLyricsOverride = nil
            installLyrics(pendingLyricsOverride.lyrics)
            _ = updateIndex(time: player.currentTime)
            return
        }
        pendingLyricsOverride = nil
        await reloadLyrics()
    }

    private func reloadLyrics() async {
        guard let song = player.currentSong else {
            installLyrics([])
            currentIndex = -1
            return
        }
        // 先清掉上一首的内容,避免在异步加载途中显示「上首歌的歌词」。
        installLyrics([])
        currentIndex = -1

        let loaded = await LyricsLoader.load(
            for: song,
            sourceManager: sourceManager,
            sourceType: sourcesStore.source(id: song.sourceID)?.type
        )
        // 异步等待期间用户可能跳到了下一首,这时把当前结果写回去就会
        // 把"上一首的歌词"显示在新歌上。`task(id:)` 理论上会取消旧任务
        // 但 LyricsLoader 内部网络拉取不一定及时响应取消,做一道防御。
        guard !Task.isCancelled, player.currentSong?.id == song.id else { return }
        installLyrics(loaded)
        _ = updateIndex(time: player.currentTime)
    }

    private func installLyrics(_ newLyrics: [LyricLine]) {
        lyrics = newLyrics
        let resolvedDirection = LyricWritingDirectionPolicy.resolve(in: newLyrics)
        if lyricsWritingDirection != resolvedDirection {
            lyricsWritingDirection = resolvedDirection
        }
        if newLyrics.isEmpty, !activeBackgroundLineIDs.isEmpty {
            activeBackgroundLineIDs = []
        }
    }

    @discardableResult
    private func updateIndex(time: TimeInterval) -> Int? {
        updateActiveBackgroundLines(at: time)
        let hasWordLevelLyrics = lyrics.contains { $0.isWordLevel }
        guard let index = LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: time,
            lookahead: hasWordLevelLyrics
                ? Self.wordLevelLookahead
                : Self.lineLevelLookahead
        ) else {
            if currentIndex != -1 { currentIndex = -1 }
            return nil
        }
        if currentIndex != index { currentIndex = index }
        return index
    }

    private func updateActiveBackgroundLines(at time: TimeInterval) {
        var nextActiveIDs: Set<String> = []
        for line in lyrics {
            for background in line.background ?? [] where LyricVoiceTimelinePolicy.isActive(
                background,
                at: time,
                lookahead: Self.wordLevelLookahead
            ) {
                nextActiveIDs.insert(background.id)
            }
        }
        if activeBackgroundLineIDs != nextActiveIDs {
            activeBackgroundLineIDs = nextActiveIDs
        }
    }

    private func seekToLyricLine(_ line: LyricLine) {
        guard canSeekToLyricLine(line) else { return }
        player.seek(to: line.timestamp)
    }

    private func canSeekToLyricLine(_ line: LyricLine) -> Bool {
        NowPlayingInteractionPolicy.shouldSeekFromLyricTap(
            settingEnabled: tapLyricsToSeek,
            lineIsSynchronized: line.isSynchronized
        )
    }

    // 删除歌曲流程已移到 PlayerMoreMenu,这里不再保留 deleteCurrentSong。
}

@MainActor
private struct MacNowPlayingTimeObserver: View {
    @Environment(AudioPlayerService.self) private var player
    let onTimeChange: @MainActor (TimeInterval) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                await observePlaybackTime()
            }
    }

    private func observePlaybackTime() async {
        while !Task.isCancelled {
            onTimeChange(player.interpolatedTime())
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }
}

/// Owns the 0.5-second progress dependency so the large now-playing layout is
/// not reevaluated for every playback tick.
private struct MacNowPlayingProgressRow: View {
    @Environment(AudioPlayerService.self) private var player
    let width: CGFloat
    let accent: Color
    @State private var preview: TimeInterval?

    var body: some View {
        HStack(spacing: 8) {
            Text((preview ?? player.currentTime).formattedDuration)
                .frame(width: 38, alignment: .trailing)
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                interactionID: player.currentSong?.id,
                fillTint: accent,
                onPreview: { preview = $0 },
                onSeek: { player.seek(to: $0) }
            )
            Text(player.duration.formattedDuration)
                .frame(width: 38, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.6))
        .frame(width: width)
    }
}

private struct MacNowPlayingMetadata: View {
    let song: Song
    let alignment: HorizontalAlignment
    let foreground: Color
    let highlight: Color
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        let names = library.artistNames(for: song)
        VStack(alignment: alignment, spacing: 4) {
            if !names.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        if index > 0 {
                            Text(verbatim: " / ")
                                .foregroundStyle(foreground)
                        }
                        if let artist = matchingArtist(name: name, index: index) {
                            metadataLink(name, help: "go_to_artist") {
                                NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
                            }
                        } else {
                            Text(verbatim: name).foregroundStyle(foreground)
                        }
                    }
                }
            }
            if let title = trimmed(song.albumTitle) {
                if let album = matchingAlbum {
                    metadataLink(title, help: "go_to_album") {
                        NotificationCenter.default.post(name: .primuseDetailOpenAlbum, object: album)
                    }
                } else {
                    Text(verbatim: title).foregroundStyle(foreground)
                }
            }
        }
        .lineLimit(1)
    }

    private func metadataLink(_ title: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        MacNowPlayingMetadataLink(
            title: title, help: help, foreground: foreground, highlight: highlight, action: action
        )
    }

    private func matchingArtist(name: String, index: Int) -> Artist? {
        if let artist = library.visibleArtists.first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            return artist
        }
        guard index == 0, let id = song.artistID else { return nil }
        return library.visibleArtists.first { $0.id == id }
    }

    private var matchingAlbum: Album? {
        if let id = song.albumID,
           let album = library.visibleAlbums.first(where: { $0.id == id }) {
            return album
        }
        guard let title = trimmed(song.albumTitle) else { return nil }
        let artist = trimmed(song.albumArtistName ?? library.artistNames(for: song).first)
        return library.visibleAlbums.first { album in
            guard album.title.localizedCaseInsensitiveCompare(title) == .orderedSame else { return false }
            guard let artist else { return true }
            return (album.artistName ?? "").localizedCaseInsensitiveCompare(artist) == .orderedSame
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private struct MacNowPlayingMetadataLink: View {
    let title: String
    let help: LocalizedStringKey
    let foreground: Color
    let highlight: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .underline(isHovered)
                .foregroundStyle(isHovered ? highlight : foreground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { isHovered = $0 }
        .help(Text(help))
        .accessibilityHint(Text(help))
    }
}

private struct NowPlayingWindowResolver: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
#endif
