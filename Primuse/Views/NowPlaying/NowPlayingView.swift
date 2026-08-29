import AVKit
import SwiftUI
import Translation
import PrimuseKit
#if os(iOS)
import UIKit
import MediaPlayer
#elseif os(macOS)
import AppKit
#endif

private struct NowPlayingAppearance {
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast

    var isLight: Bool { colorScheme == .light }
    private var usesIncreasedContrast: Bool { contrast == .increased }

    var primary: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.96 : 0.88)
        }
        return .white
    }

    var secondary: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.78 : 0.64)
        }
        return .white.opacity(usesIncreasedContrast ? 0.88 : 0.72)
    }

    var tertiary: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.64 : 0.48)
        }
        return .white.opacity(usesIncreasedContrast ? 0.72 : 0.52)
    }

    var faint: Color {
        if isLight {
            return .black.opacity(usesIncreasedContrast ? 0.52 : 0.38)
        }
        return .white.opacity(usesIncreasedContrast ? 0.60 : 0.38)
    }

    var divider: Color {
        primary.opacity(usesIncreasedContrast ? 0.18 : 0.10)
    }

    var track: Color {
        primary.opacity(usesIncreasedContrast ? 0.28 : 0.18)
    }

    var backgroundBase: Color {
        isLight
            ? Color(red: 0.94, green: 0.945, blue: 0.955)
            : Color(red: 0.035, green: 0.043, blue: 0.055)
    }

    var artworkAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.38 : 0.46) : 0.88
    }

    var fallbackAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.09 : 0.13) : 0.34
    }

    var artworkLowerAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.26 : 0.32) : 0.70
    }

    var fallbackLowerAccentOpacity: Double {
        isLight ? (usesIncreasedContrast ? 0.06 : 0.09) : 0.26
    }

    var pastLyricOpacity: Double {
        usesIncreasedContrast ? 0.56 : (isLight ? 0.40 : 0.32)
    }

    var futureLyricOpacity: Double {
        usesIncreasedContrast ? 0.70 : (isLight ? 0.56 : 0.46)
    }

    var inactiveSyllableOpacity: Double {
        usesIncreasedContrast ? 0.58 : (isLight ? 0.46 : 0.42)
    }
}

#if os(iOS)
private struct WindowSafeAreaInsetsReader: UIViewRepresentable {
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
        uiView.publishIfNeeded()
    }

    final class ReaderView: UIView {
        var onChange: ((UIEdgeInsets) -> Void)?
        private var lastInsets: UIEdgeInsets?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishIfNeeded()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            publishIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishIfNeeded()
        }

        func publishIfNeeded() {
            guard let window else { return }
            let insets = window.safeAreaInsets
            guard insets != lastInsets else { return }
            lastInsets = insets
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(insets)
            }
        }
    }
}
#endif

struct NowPlayingView: View {
    private enum AmbientBackdropTuning {
        static let transitionDuration = 0.5
    }

    var onOpenAlbum: ((Album) -> Void)? = nil
    var onOpenArtist: ((Artist) -> Void)? = nil
    var onMinimize: (() -> Void)? = nil
    var onTopMinimizeDragChanged: ((CGFloat) -> Void)? = nil
    var onTopMinimizeDragEnded: ((Bool) -> Void)? = nil
    var onLeadingMinimizeDragChanged: ((CGFloat) -> Void)? = nil
    var onLeadingMinimizeDragEnded: ((Bool) -> Void)? = nil
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsPlayerVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault

    /// Apple Music 歌的 catalog URL ── 用来给"在 Apple Music 打开"按钮跳转。
    /// 跳转后用户能看到 Apple Music 自家的歌词 / 添加收藏 / 看艺人页等
    /// 我们没办法对 DRM 流提供的能力。
    private var appleMusicCatalogURL: URL? {
        guard let song = player.currentSong, player.isAppleMusicMode else { return nil }
        return AppServices.shared.appleMusicLibrary.catalogURL(for: song)
    }
    @State private var showLyrics = false
    @State private var activeMinimizeDragAxis: NowPlayingDismissGesturePolicy.Axis?
    @State private var activeMinimizeDragStartLocation: CGPoint?
    @State private var isLyricsImmersive = false
    @State private var isFullscreenPlayerPresented = false
    @State private var immersiveControlsState = ImmersiveControlsState.inactive
    @State private var immersiveControlsAutoHideTask: Task<Void, Never>?
    @State private var showsImmersiveEffectPicker = false
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsWritingDirection: LyricWritingDirection = .natural
    @State private var lyricsRevision: UInt = 0
    @State private var lyricsLoadRevision: UInt = 0
    @State private var isResolvingScrapeTarget = false
    @State private var scrapeAlertMessage: String?
    @State private var showNoScraperSourceAlert = false
    /// Freeze the canonical song identity used by the scrape sheet. MusicKit
    /// can temporarily expose a catalog ID while the library row uses an
    /// `i.*` ID; reading `player.currentSong` again inside the sheet could then
    /// save the chosen lyrics under a different song on each presentation.
    @State private var scrapeTargetSong: Song?
    @State private var showAddToPlaylist = false
    @State private var showCastPicker = false
    @State private var showSongInfo = false
    @State private var showSleepTimer = false
    @State private var showDeleteConfirm = false
    @State private var deleteErrorMessage: String?
    @State private var showTagEditor = false
    /// 歌词编辑跟标签编辑平级；打开时冻结目标，避免自然切歌后写错歌曲。
    @State private var lyricsEditorTargetSong: Song?
    @State private var lyricsEditorAutoStartsAudioTranscription = false
    @State private var showSimilarSongs = false
    @State private var showMusicVideoFullScreen = false
    #if os(iOS)
    @State private var windowSafeAreaInsets = UIEdgeInsets.zero
    #endif
    @State private var fullScreenMusicVideoPlayer: AVPlayer?
    @Environment(ThemeService.self) private var theme
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var isVisualSceneActive: Bool {
        #if os(iOS)
        scenePhase == .active
        #else
        true
        #endif
    }

    private var isScrapingCurrentSong: Bool {
        guard let songID = player.currentSong?.id else { return isResolvingScrapeTarget }
        return isResolvingScrapeTarget || scraperService.isSingleScrapeActive(
            songID: songID,
            purposes: [.metadataApply, .lyricsApply]
        )
    }

    private var isScrapeActionUnavailable: Bool {
        isResolvingScrapeTarget
            || scraperService.isScraping
            || scraperService.isSingleScraping
    }

    // 父持有 @AppStorage 仅为了 onChange 触发 CloudKVS 同步;实际渲染字号由
    // LyricsScrollView 子 view 自己读 AppStorage("lyricsFontScale")。
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenPlayerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue

    private var fullscreenPlayerEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: fullscreenPlayerEffectRawValue) ?? .defaultValue
    }

    private var fullscreenPlayerEffectBinding: Binding<FullscreenPlayerEffect> {
        Binding(
            get: { fullscreenPlayerEffect },
            set: { newValue in
                fullscreenPlayerEffectRawValue = newValue.rawValue
                FullscreenPlayerEffectSync.shared.select(newValue)
            }
        )
    }

    /// Whether the current song is in any playlist (not a dedicated "favorites" concept)
    private var isInAnyPlaylist: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.playlists.contains { library.contains(songID: songID, inPlaylist: $0.id) }
    }

    /// 当前歌是否已经被加进「我喜欢」── heart 按钮渲染态 & toggle 目标。
    /// 跟 isInAnyPlaylist 是两回事: "加任意歌单"是 moreMenu 里的 add_to_playlist,
    /// "喜欢"是 heart 按钮 toggle 这个固定 system 歌单。
    private var isCurrentLiked: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.isLiked(songID: songID)
    }

    /// Resolve the currently playing song back to the library entities used by
    /// the detail screens. Older scans may not have persisted artistID/albumID,
    /// so retain a normalized-name fallback instead of silently hiding links.
    private var currentArtists: [Artist] {
        guard let song = player.currentSong else { return [] }
        let artistsByID = Dictionary(
            library.visibleArtists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return library.artistNames(for: song).compactMap { name in
            let id = MusicLibrary.hashID(name.lowercased())
            if let artist = artistsByID[id] { return artist }
            return library.visibleArtists.first {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    private var currentArtist: Artist? {
        currentArtists.first
    }

    private var currentArtistDisplayName: String {
        guard let song = player.currentSong else { return "" }
        return library.artistDisplayName(for: song) ?? ""
    }

    private var currentAlbum: Album? {
        guard let song = player.currentSong else { return nil }
        if let albumID = song.albumID,
           let album = library.visibleAlbums.first(where: { $0.id == albumID }) {
            return album
        }
        let albumTitle = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !albumTitle.isEmpty else { return nil }
        let artistName = (song.albumArtistName ?? library.artistNames(for: song).first)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return library.visibleAlbums.first {
            let titleMatches = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(albumTitle) == .orderedSame
            let albumArtist = $0.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let artistMatches = artistName.isEmpty || albumArtist.isEmpty
                || albumArtist.localizedCaseInsensitiveCompare(artistName) == .orderedSame
            return titleMatches && artistMatches
        }
    }

    private func toggleLikedCurrent() {
        guard let songID = player.currentSong?.id else { return }
        library.toggleLiked(songID: songID)
    }

    private func presentImmersiveLyrics() {
        if fullscreenPlayerEffect == .native {
            withAnimation(.easeInOut(duration: 0.3)) {
                showLyrics = true
                isLyricsImmersive = true
                immersiveControlsState = immersiveControlsState.applying(.present)
            }
            scheduleImmersiveControlsAutoHide()
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                isFullscreenPlayerPresented = true
            }
        }
    }

    private func applyFullscreenEffectPresentation(_ effect: FullscreenPlayerEffect) {
        if effect == .native, isFullscreenPlayerPresented {
            withAnimation(.easeInOut(duration: 0.24)) {
                isFullscreenPlayerPresented = false
                showLyrics = true
                isLyricsImmersive = true
                immersiveControlsState = immersiveControlsState.applying(.present)
            }
            scheduleImmersiveControlsAutoHide()
        } else if effect != .native, isLyricsImmersive {
            immersiveControlsAutoHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.24)) {
                isLyricsImmersive = false
                immersiveControlsState = immersiveControlsState.applying(.dismiss)
                isFullscreenPlayerPresented = true
            }
        }
    }

    private func dismissFullscreenPlayer() {
        guard isFullscreenPlayerPresented else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isFullscreenPlayerPresented = false
        }
    }

    private func minimizeFullscreenPlayer() {
        guard isFullscreenPlayerPresented else { return }
        dismissFullscreenPlayer()
        onMinimize?()
    }

    private func dismissImmersiveLyrics() {
        immersiveControlsAutoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) {
            isLyricsImmersive = false
            immersiveControlsState = immersiveControlsState.applying(.dismiss)
        }
    }

    private func setStandardLyricsVisible(_ isVisible: Bool) {
        immersiveControlsAutoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) {
            showLyrics = isVisible
            isLyricsImmersive = false
            immersiveControlsState = immersiveControlsState.applying(.dismiss)
        }
    }

    private func toggleStandardLyrics() {
        setStandardLyricsVisible(!showLyrics)
    }

    private func handleImmersiveContentTap() {
        withAnimation(.easeInOut(duration: 0.2)) {
            immersiveControlsState = immersiveControlsState.applying(.contentTap)
        }
        if immersiveControlsState.isVisible {
            scheduleImmersiveControlsAutoHide()
        } else {
            immersiveControlsAutoHideTask?.cancel()
        }
    }

    private func lockImmersiveControls() {
        immersiveControlsAutoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            immersiveControlsState = immersiveControlsState.applying(.lock)
        }
    }

    private func unlockImmersiveControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            immersiveControlsState = immersiveControlsState.applying(.unlock)
        }
        scheduleImmersiveControlsAutoHide()
    }

    private func scheduleImmersiveControlsAutoHide() {
        immersiveControlsAutoHideTask?.cancel()
        guard isVisualSceneActive,
              isLyricsImmersive,
              immersiveControlsState.isVisible,
              !showsImmersiveEffectPicker else { return }
        immersiveControlsAutoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isVisualSceneActive,
                  isLyricsImmersive,
                  !showsImmersiveEffectPicker else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                immersiveControlsState = immersiveControlsState.applying(.autoHide)
            }
        }
    }

    @ViewBuilder
    private func lyricsFullScreenButton(font: Font, trailing: CGFloat = 0) -> some View {
        Button { presentImmersiveLyrics() } label: {
            nowPlayingActionIcon(
                symbol: "viewfinder.rectangular",
                tint: appearance.primary
            )
        }
        .frame(width: 44, height: 44)
        .buttonStyle(.plain)
        .disabled(player.currentSong == nil)
        .padding(.trailing, trailing)
        .accessibilityLabel(Text("full_screen_player"))
    }

    private func nowPlayingActionIcon(
        symbol: String,
        tint: Color,
        isSelected: Bool = false
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 38, height: 38)
            .background(appearance.primary.opacity(isSelected ? 0.10 : 0.065), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(appearance.primary.opacity(isSelected ? 0.24 : 0.14), lineWidth: 0.75)
            }
    }


    /// Top safe area height (dynamic island / status bar)
    private var topSafeArea: CGFloat {
        #if os(iOS)
        windowSafeAreaInsets.top
        #else
        // macOS 没有 dynamic island / 状态栏 safe area, 标题栏由窗口 chrome
        // 负责, NowPlayingView 内容直接顶到窗口客户区上沿即可。
        0
        #endif
    }

    private var bottomSafeArea: CGFloat {
        #if os(iOS)
        windowSafeAreaInsets.bottom
        #else
        0
        #endif
    }

    private func resolvedSafeAreaInsets(for geo: GeometryProxy) -> EdgeInsets {
        #if os(iOS)
        let windowInsets = windowSafeAreaInsets
        let logicalLeading = layoutDirection == .rightToLeft
            ? windowInsets.right
            : windowInsets.left
        let logicalTrailing = layoutDirection == .rightToLeft
            ? windowInsets.left
            : windowInsets.right
        return EdgeInsets(
            top: max(geo.safeAreaInsets.top, windowInsets.top),
            leading: max(geo.safeAreaInsets.leading, logicalLeading),
            bottom: max(geo.safeAreaInsets.bottom, windowInsets.bottom),
            trailing: max(geo.safeAreaInsets.trailing, logicalTrailing)
        )
        #else
        return geo.safeAreaInsets
        #endif
    }

    /// iPad 横屏(regular size class + 宽 > 高)启用左右双栏 —— 左封面 + 控件,
    /// 右常驻歌词。其它(iPhone / iPad 竖屏 / 分屏小窗 compact)还走原来的
    /// 上下结构,showLyrics 切歌词 / 封面模式。
    private func shouldUseWideLayout(geo: GeometryProxy) -> Bool {
        sizeClass == .regular && geo.size.width > geo.size.height
    }

    private func playerMinimizeDragGesture(
        containerWidth: CGFloat,
        verticalStartMaximumY: CGFloat
    ) -> some Gesture {
        // The player moves with this gesture, so a local coordinate space would
        // also move under the finger and feed the offset back into translation.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                let isRTL = layoutDirection == .rightToLeft
                if activeMinimizeDragStartLocation != value.startLocation {
                    activeMinimizeDragStartLocation = value.startLocation
                    activeMinimizeDragAxis = nil
                }
                let startDistance = NowPlayingDismissGesturePolicy.distanceFromLeadingEdge(
                    startX: Double(value.startLocation.x),
                    containerWidth: Double(containerWidth),
                    layoutIsRightToLeft: isRTL
                )
                let towardCenter = NowPlayingDismissGesturePolicy.translationTowardCenter(
                    translationX: Double(value.translation.width),
                    layoutIsRightToLeft: isRTL
                )
                let axis = activeMinimizeDragAxis
                    ?? NowPlayingDismissGesturePolicy.recognizedAxis(
                        startY: Double(value.startLocation.y),
                        startDistanceFromLeadingEdge: startDistance,
                        translationTowardCenter: towardCenter,
                        translationY: Double(value.translation.height),
                        verticalStartMaximumY: Double(verticalStartMaximumY)
                    )
                guard let axis else { return }
                activeMinimizeDragAxis = axis

                switch axis {
                case .horizontal:
                    onLeadingMinimizeDragChanged?(CGFloat(max(0, towardCenter)))
                case .vertical:
                    onTopMinimizeDragChanged?(max(0, value.translation.height))
                }
            }
            .onEnded { value in
                let axis = activeMinimizeDragAxis
                activeMinimizeDragAxis = nil
                activeMinimizeDragStartLocation = nil
                guard let axis else { return }

                let isRTL = layoutDirection == .rightToLeft
                let startDistance = NowPlayingDismissGesturePolicy.distanceFromLeadingEdge(
                    startX: Double(value.startLocation.x),
                    containerWidth: Double(containerWidth),
                    layoutIsRightToLeft: isRTL
                )
                let towardCenter = NowPlayingDismissGesturePolicy.translationTowardCenter(
                    translationX: Double(value.translation.width),
                    layoutIsRightToLeft: isRTL
                )
                let predictedTowardCenter = NowPlayingDismissGesturePolicy.translationTowardCenter(
                    translationX: Double(value.predictedEndTranslation.width),
                    layoutIsRightToLeft: isRTL
                )

                switch axis {
                case .horizontal:
                    let shouldDismiss = NowPlayingDismissGesturePolicy.shouldDismissFromLeadingEdge(
                        startX: startDistance,
                        translationX: towardCenter,
                        translationY: Double(value.translation.height),
                        predictedEndTranslationX: predictedTowardCenter
                    )
                    if let onLeadingMinimizeDragEnded {
                        onLeadingMinimizeDragEnded(shouldDismiss)
                    } else if shouldDismiss {
                        onMinimize?()
                    }
                case .vertical:
                    let shouldDismiss = NowPlayingDismissGesturePolicy.shouldDismissFromTop(
                        startY: Double(value.startLocation.y),
                        translationX: Double(value.translation.width),
                        translationY: Double(value.translation.height),
                        predictedEndTranslationY: Double(value.predictedEndTranslation.height),
                        maximumStartY: Double(verticalStartMaximumY)
                    )
                    if let onTopMinimizeDragEnded {
                        onTopMinimizeDragEnded(shouldDismiss)
                    } else if shouldDismiss {
                        onMinimize?()
                    }
                }
            }
    }

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 60, geo.size.height * 0.38)
            let safeInsets = resolvedSafeAreaInsets(for: geo)
            let verticalDismissStartMaximumY = showLyrics
                ? CGFloat(NowPlayingDismissGesturePolicy.topStartMaximumY)
                : max(
                    CGFloat(NowPlayingDismissGesturePolicy.topStartMaximumY),
                    geo.size.height * 0.62
                )
            let landscapeMode = NowPlayingLandscapePolicy.mode(
                viewportWidth: Double(geo.size.width),
                viewportHeight: Double(geo.size.height),
                isMusicVideoActive: player.isMusicVideoPlaybackActive,
                areLyricsVisible: showLyrics,
                areLyricsImmersive: isLyricsImmersive
            )
            let playerLayoutMode = NowPlayingPlayerLayoutPolicy.mode(
                viewportWidth: Double(geo.size.width),
                viewportHeight: Double(geo.size.height),
                prefersWideColumns: shouldUseWideLayout(geo: geo)
            )

            ZStack {
                #if os(iOS)
                WindowSafeAreaInsetsReader { insets in
                    guard insets != windowSafeAreaInsets else { return }
                    windowSafeAreaInsets = insets
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                #endif

                if !isFullscreenPlayerPresented {
                    ZStack {
                        // Opaque base — prevents content bleeding through
                        appearance.backgroundBase.ignoresSafeArea()
                        // Dynamic background from cover colors — fully opaque
                        backgroundGradient.ignoresSafeArea()

                        if player.isLiveRadio {
                            liveRadioLayout(geo: geo)
                        } else {
                            switch landscapeMode {
                            case .musicVideo:
                                if let videoPlayer = player.musicVideoPlayer {
                                    landscapeMusicVideoLayout(videoPlayer: videoPlayer)
                                } else {
                                    portraitLayout(geo: geo, artSize: artSize)
                                }
                            case .immersiveLyrics:
                                immersiveLandscapeLyricsLayout(geo: geo)
                            case .standardLyrics:
                                standardLandscapeLyricsLayout(geo: geo)
                            case .none:
                                switch playerLayoutMode {
                                case .portrait:
                                    portraitLayout(geo: geo, artSize: artSize)
                                case .compactLandscape:
                                    compactLandscapePlayerLayout(
                                        geo: geo,
                                        safeInsets: safeInsets
                                    )
                                case .wideLandscape:
                                    wideLandscapeLayout(geo: geo)
                                }
                            }
                        }

                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        playerMinimizeDragGesture(
                            containerWidth: geo.size.width,
                            verticalStartMaximumY: verticalDismissStartMaximumY
                        )
                    )
                    .transition(.opacity)
                }

                #if os(iOS)
                if isFullscreenPlayerPresented {
                    ImmersivePlayerView(
                        effect: fullscreenPlayerEffectBinding,
                        lyrics: lyrics,
                        lyricsWritingDirection: lyricsWritingDirection,
                        isSceneActive: isVisualSceneActive,
                        onDismiss: dismissFullscreenPlayer,
                        onMinimize: minimizeFullscreenPlayer,
                        onShowQueue: { showQueue = true }
                    )
                    .zIndex(100)
                }
                #endif
            }
        }
        .onAppear { FullscreenPlayerEffectSync.shared.install() }
        .onChange(of: isVisualSceneActive) { _, isActive in
            if isActive {
                if isLyricsImmersive, immersiveControlsState.isVisible {
                    scheduleImmersiveControlsAutoHide()
                }
            } else {
                immersiveControlsAutoHideTask?.cancel()
                activeMinimizeDragAxis = nil
                activeMinimizeDragStartLocation = nil
            }
        }
        .onChange(of: showsImmersiveEffectPicker) { _, isPresented in
            if isPresented {
                immersiveControlsAutoHideTask?.cancel()
            } else if isLyricsImmersive, immersiveControlsState.isVisible {
                scheduleImmersiveControlsAutoHide()
            }
        }
        .onChange(of: fullscreenPlayerEffectRawValue) { _, rawValue in
            guard let effect = FullscreenPlayerEffect(rawValue: rawValue) else { return }
            applyFullscreenEffectPresentation(effect)
        }
        .task(id: player.currentSong?.id) {
            consumeAutomaticScrapeCompletion()
            if player.isLiveRadio {
                lyrics = []
            } else {
                await loadLyrics()
            }
            consumeAutomaticScrapeCompletion()
        }
        .onChange(of: scraperService.singleScrapeCompletionRevision) { _, _ in
            consumeAutomaticScrapeCompletion()
        }
        .sheet(isPresented: $showQueue) {
            QueueView(player: player)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $scrapeTargetSong) { song in
            ScrapeOptionsView(song: song) { u in
                CachedArtworkView.invalidateCache(for: u.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
                player.syncSongMetadata(u)
                player.forceRefreshNowPlayingArtwork()
                Task { await loadLyrics() }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.currentSong {
                AddToPlaylistSheet(song: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showTagEditor) {
            if let song = player.currentSong {
                TagEditorView(song: song) { updated in
                    // 元数据变更后,封面缓存可能 stale; 同步路径由 PrimuseApp
                    // 监听 songReplacementToken 统一处理 player / theme,
                    // 这里只重拉歌词(标题改了可能影响 LRC 命中)。
                    Task { await loadLyrics() }
                    _ = updated
                }
                .presentationDetents([.large])
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $lyricsEditorTargetSong) { song in
            LyricsEditorSheet(
                song: song,
                autoStartsAudioTranscription: lyricsEditorAutoStartsAudioTranscription
            ) { updated in
                // 编辑期间若已经自然切歌，不要用旧歌的落盘结果刷新新歌歌词。
                guard player.currentSong?.id == updated.id else { return }
                Task { await loadLyrics() }
            }
        }
        #else
        .sheet(item: $lyricsEditorTargetSong) { song in
            LyricsEditorSheet(
                song: song,
                autoStartsAudioTranscription: lyricsEditorAutoStartsAudioTranscription
            ) { updated in
                // 编辑期间若已经自然切歌，不要用旧歌的落盘结果刷新新歌歌词。
                guard player.currentSong?.id == updated.id else { return }
                Task { await loadLyrics() }
            }
            .presentationDetents([.large])
        }
        #endif
        .similarSongsPanel(isPresented: $showSimilarSongs, seed: player.currentSong)
        .sheet(isPresented: $showCastPicker) {
            CastDevicePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #if os(iOS)
        .fullScreenCover(
            isPresented: $showMusicVideoFullScreen,
            onDismiss: finishMusicVideoFullScreenDismissal
        ) {
            if let videoPlayer = fullScreenMusicVideoPlayer ?? player.musicVideoPlayer {
                MusicVideoFullScreenView(player: videoPlayer) {
                    dismissMusicVideoFullScreen()
                }
            } else {
                Color.black
                    .ignoresSafeArea()
            }
        }
        .onChange(of: player.isMusicVideoPlaybackActive) { _, active in
            if active, let videoPlayer = player.musicVideoPlayer {
                fullScreenMusicVideoPlayer = videoPlayer
            } else {
                dismissMusicVideoFullScreenIfNeeded()
            }
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            if player.isMusicVideoPlaybackActive, let videoPlayer = player.musicVideoPlayer {
                fullScreenMusicVideoPlayer = videoPlayer
            } else {
                dismissMusicVideoFullScreenIfNeeded()
            }
        }
        .onChange(of: player.isMusicVideoModeEnabled) { _, enabled in
            // 独立 MV 不受模式开关影响(始终播视频), 关模式不退全屏
            if !enabled, player.currentSong?.isStandaloneMusicVideo != true {
                dismissMusicVideoFullScreen()
            }
        }
        .onChange(of: player.musicVideoAudioFallbackToken) { _, _ in
            dismissMusicVideoFullScreen()
        }
        #endif
        .confirmationDialog(String(localized: "sleep_timer"), isPresented: $showSleepTimer) {
            Button("5 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 5) }
            Button("15 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 15) }
            Button("30 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 30) }
            Button("45 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 45) }
            Button("60 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 60) }
            if !player.isLiveRadio {
                Button(String(localized: "sleep_at_track_end")) { player.scheduleSleepAtTrackEnd() }
                    .disabled(player.currentSong == nil)
            }
            if player.isSleepTimerActive {
                Button(String(localized: "cancel_timer"), role: .destructive) { player.cancelSleep() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(
                   get: { scrapeAlertMessage != nil },
                   set: { if !$0 { scrapeAlertMessage = nil } }
               )) {
            Button("done", role: .cancel) {}
        } message: {
            Text(scrapeAlertMessage ?? "")
        }
        .alert(String(localized: "delete_song"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "delete"), role: .destructive) {
                deleteCurrentSong()
            }
        } message: {
            Text(String(localized: "delete_song_message"))
        }
        .alert(
            String(localized: "delete_song_failed_title"),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        .onChange(of: showLyrics) { _, isVisible in
            if !isVisible, isLyricsImmersive {
                dismissImmersiveLyrics()
            }
        }
        .onDisappear {
            immersiveControlsAutoHideTask?.cancel()
        }
        // Handoff —— 用户在当前设备播,旁边的 Mac / iPad 在 Spotlight / 任务
        // 切换器底部出现"在 Primuse 中继续"的 chip。打开后通过 ContentView
        // 的 onContinueUserActivity 拿到完整队列上下文,在另一台设备上无缝接
        // 着播下去 (同一首歌、同样的队列顺序、相同的播放位置、同样的播放/
        // 暂停状态)。
        //
        // 队列截 50 首是 payload size 安全垫: NSUserActivity userInfo 总
        // 大小 ~128KB,单 song.id (SHA256 hex) 64 字符,50 首 ~3.2KB,余量
        // 充裕。窗口以 currentIndex 为基准 (前 5 首上下文 + 之后 45 首),
        // 保证当前歌一定在 payload 内, 超出的尾部由 receiver 进入队列后下一
        // 首靠 setQueue 自然推进继续 ── 主接力点是当前歌 + 接下来几首。
        .userActivity(
            "com.welape.yuanyin.nowplaying",
            isActive: player.currentSong != nil && !player.isLiveRadio
        ) { activity in
            guard let song = player.currentSong, !player.isLiveRadio else { return }
            let by = library.artistDisplayName(for: song).map { " — \($0)" } ?? ""
            activity.title = "\(song.title)\(by)"
            activity.isEligibleForHandoff = true
            // 不把 song.id 暴露给搜索 / 公开索引,handoff 直接拿去就好
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false

            // 以 currentIndex 为基准取窗口而非整队列前 50 首: 长队列后段接力
            // 时, 整队前缀里根本不含当前歌, receiver 会找不到 songID 落入兜底
            // (整库从头播)。这里保证当前歌 + 接下来几首都在 payload 里 ——
            // 当前歌前 5 首给点上下文, 之后 45 首是真正的接力窗口。
            let queueIDs: [String] = {
                let q = player.queue
                guard !q.isEmpty else { return [] }
                let idx = min(max(player.currentIndex, 0), q.count - 1)
                let lower = max(0, idx - 5)
                let upper = min(q.count, lower + 50)
                return Array(q[lower..<upper].map(\.id))
            }()
            activity.userInfo = [
                "songID": song.id,
                "queueIDs": queueIDs,
                // currentTime + snapshotTime 一起记录, receiver 用 (now -
                // snapshot) 推算"如果还在播,实际应该到哪里了",避免接力
                // 时听见同一段刚播过的内容。
                "currentTime": player.handoffPlaybackTimeSnapshot(),
                "snapshotTime": Date().timeIntervalSinceReferenceDate,
                "isPlaying": player.isPlaying,
                "shuffleEnabled": player.shuffleEnabled,
                "repeatMode": player.repeatMode.rawValue,
            ]
            activity.requiredUserInfoKeys = ["songID"]
        }
    }

    @ViewBuilder
    private func liveRadioLayout(geo: GeometryProxy) -> some View {
        let artworkSize = min(geo.size.width * (geo.size.width > geo.size.height ? 0.30 : 0.72), 430)

        VStack(spacing: 0) {
            Capsule()
                .fill(appearance.tertiary)
                .frame(width: 48, height: 5)
                .padding(.top, topSafeArea + 6)

            if let error = player.lastPlaybackError {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.82), in: Capsule())
                    .padding(.top, 14)
            }

            Spacer(minLength: 18)

            if let station = player.currentRadioStation {
                RadioStationArtworkView(
                    station: station,
                    size: artworkSize,
                    cornerRadius: max(18, artworkSize * 0.06)
                )
                .shadow(color: .black.opacity(0.34), radius: 28, y: 14)
            }

            Spacer(minLength: 24)

            VStack(spacing: 8) {
                Text(player.currentRadioStation?.name ?? player.currentSong?.title ?? "")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)

                Text(player.radioMetadataTitle ?? currentArtistDisplayName)
                    .font(.body)
                    .foregroundStyle(appearance.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                HStack(spacing: 7) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text("LIVE")
                        .font(.caption.weight(.bold))
                    if player.currentTime > 0 {
                        Text("·")
                        Text(player.currentTime.formattedDuration)
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(appearance.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel(Text("radio_live"))
            }
            .padding(.horizontal, 32)

            HStack(spacing: 38) {
                Button {
                    Task { await player.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .disabled(!player.canSwitchRadioStation)
                .accessibilityLabel(Text("radio_previous_station"))

                Button { player.togglePlayPause() } label: {
                    Image(systemName: (player.isPlaying || player.isLoading) ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 68))
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(Text((player.isPlaying || player.isLoading) ? "radio_stop" : "a11y_play"))

                Button {
                    Task { await player.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .disabled(!player.canSwitchRadioStation)
                .accessibilityLabel(Text("radio_next_station"))
            }
            .foregroundStyle(appearance.primary)
            .padding(.top, 24)

            if showsPlayerVolumeBar {
                playerVolumeRow
                    .frame(maxWidth: 460)
                    .padding(.horizontal, 36)
                    .padding(.top, 18)
            }

            HStack(spacing: 10) {
                AirPlayButton()
                    .frame(width: 36, height: 36)
                Text(radioTechnicalSummary)
                    .font(.caption2)
                    .foregroundStyle(appearance.faint)
                if let url = player.currentRadioStation?.url {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(Text("share"))
                }
            }
            .padding(.top, 10)
            .padding(.bottom, max(bottomSafeArea, 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var radioTechnicalSummary: String {
        var parts: [String] = [player.radioStreamFormat.displayName]
        if let bitRate = player.radioBitRate, bitRate > 0 {
            parts.append("\(bitRate / 1_000) kbps")
        }
        return parts.joined(separator: " · ")
    }

    private var playerVolumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(appearance.tertiary)
            #if os(iOS) && !targetEnvironment(simulator)
            SystemVolumeSlider()
                .frame(maxWidth: .infinity)
                .frame(height: SystemVolumeSlider.compactHeight)
                .offset(y: SystemVolumeSlider.verticalOffset)
            #else
            VolumeSlider(value: Binding(
                get: { Double(player.audioEngine.volume) },
                set: { player.setPlaybackVolume(Float($0)) }
            ))
            #endif
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(appearance.tertiary)
        }
        // Keep the route-owned MPVolumeView stable when switching between
        // artwork and lyrics without suppressing the player's entrance spring.
        .animation(nil, value: showLyrics)
    }

    // MARK: - Compact phone landscape

    @ViewBuilder
    private func compactLandscapePlayerLayout(
        geo: GeometryProxy,
        safeInsets: EdgeInsets
    ) -> some View {
        let contentWidth = max(0, geo.size.width - safeInsets.leading - safeInsets.trailing - 32)
        let contentHeight = max(0, geo.size.height - safeInsets.top - safeInsets.bottom - 28)
        let artworkColumnWidth = min(max(contentWidth * 0.36, 164), 252)
        let artworkSize = min(artworkColumnWidth, contentHeight)

        ZStack(alignment: .top) {
            HStack(spacing: 24) {
                artworkOrMusicVideo(size: artworkSize, cornerRadius: 14)
                    .scaleEffect(player.isPlaying ? 1 : 0.96)
                    .shadow(color: .black.opacity(0.30), radius: 18, y: 8)
                    .animation(
                        .spring(response: 0.5, dampingFraction: 0.75),
                        value: player.isPlaying
                    )
                    .onTapGesture { setStandardLyricsVisible(true) }
                    .frame(width: artworkColumnWidth, height: contentHeight)

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(player.currentSong?.title ?? "")
                                    .font(.headline.weight(.bold))
                                    .lineLimit(1)
                                    .foregroundStyle(appearance.primary)
                                if let song = player.currentSong,
                                   song.audioQuality != .standard {
                                    AudioQualityBadge(quality: song.audioQuality)
                                }
                            }
                            nowPlayingMetadataLinks(font: .subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        musicVideoToggleButton(font: .body, trailing: 0)
                        lyricsFullScreenButton(font: .body, trailing: 0)
                        Button { toggleLikedCurrent() } label: {
                            nowPlayingActionIcon(
                                symbol: isCurrentLiked ? "heart.fill" : "heart",
                                tint: isCurrentLiked ? .red : appearance.secondary,
                                isSelected: isCurrentLiked
                            )
                        }
                        .frame(width: 40, height: 40)
                        .disabled(player.currentSong == nil)
                        .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                        moreMenu
                    }

                    PlaybackProgressBar()
                        .padding(.top, 4)

                    HStack(spacing: 0) {
                        ctrlBtn("shuffle", active: player.shuffleEnabled) {
                            player.shuffleEnabled.toggle()
                        }
                        Spacer(minLength: 6)
                        Button { Task { await player.previous() } } label: {
                            Image(systemName: "backward.fill")
                                .font(.title3)
                                .foregroundStyle(appearance.primary)
                        }
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("a11y_previous_track")
                        Spacer(minLength: 6)
                        Button { player.togglePlayPause() } label: {
                            ZStack {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 52))
                                    .opacity(0)
                                if player.isLoading {
                                    ProgressView().tint(appearance.primary)
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 52))
                                        .foregroundStyle(appearance.primary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                            }
                        }
                        .disabled(player.isLoading)
                        .accessibilityLabel(player.isPlaying
                            ? String(localized: "a11y_pause")
                            : String(localized: "a11y_play"))
                        Spacer(minLength: 6)
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .foregroundStyle(appearance.primary)
                        }
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("a11y_next_track")
                        Spacer(minLength: 6)
                        ctrlBtn(
                            player.repeatMode == .one ? "repeat.1" : "repeat",
                            active: player.repeatMode != .off
                        ) {
                            switch player.repeatMode {
                            case .off: player.repeatMode = .all
                            case .all: player.repeatMode = .one
                            case .one: player.repeatMode = .off
                            }
                        }
                    }
                    .frame(height: 56)

                    if showsPlayerVolumeBar {
                        playerVolumeRow
                            .padding(.top, 3)
                    }

                    HStack(spacing: 12) {
                        Button { toggleStandardLyrics() } label: {
                            Image(systemName: "quote.bubble")
                                .foregroundStyle(appearance.tertiary)
                        }
                        .frame(width: 40, height: 40)
                        .accessibilityLabel(Text("a11y_open_lyrics"))

                        AirPlayButton()
                            .frame(width: 34, height: 34)
                            .frame(width: 40, height: 40)

                        Button { showQueue = true } label: {
                            Image(systemName: "list.bullet")
                                .foregroundStyle(appearance.tertiary)
                        }
                        .frame(width: 40, height: 40)
                        .accessibilityLabel("a11y_queue")

                        Spacer(minLength: 0)

                        if let song = player.currentSong {
                            Text(song.fileFormat.displayName)
                                .font(.caption2)
                                .foregroundStyle(appearance.faint)
                        }
                    }
                    .frame(height: 40)
                }
                .frame(maxWidth: .infinity, maxHeight: contentHeight)
            }
            .padding(.leading, safeInsets.leading + 16)
            .padding(.trailing, safeInsets.trailing + 16)
            .padding(.top, safeInsets.top + 22)
            .padding(.bottom, safeInsets.bottom + 6)

            Capsule()
                .fill(appearance.tertiary)
                .frame(width: 48, height: 5)
                .padding(.top, safeInsets.top + 6)
        }
    }

    // MARK: - iPad 横屏 layout (左封面 / 右歌词)
    //
    // 常规横屏下封面 + 歌词并排显示；用户点按右侧歌词后进入全屏歌词模式。
    // 封面这一侧复用原 portrait 模式的所有控件子组件(PlaybackProgressBar,
    // ctrlBtn, VolumeSlider, AirPlayButton, moreMenu), 只是改成一个独立
    // VStack 钉到左半屏。歌词复用 `lyricsFullView`。

    @ViewBuilder
    private func wideLandscapeLayout(geo: GeometryProxy) -> some View {
        let halfWidth = geo.size.width / 2
        // 左侧封面留 80pt 内边距,大小不超过列高 60%。这套尺寸在 iPad Pro
        // 13" 横屏 (1366x1024) 下封面 ~ 580pt,既不显空也不溢出。
        let artSize = min(halfWidth - 80, geo.size.height * 0.6)

        HStack(spacing: 0) {
            wideLeftPane(artSize: artSize)
                .frame(width: halfWidth)

            // 中缝细分隔,跟随播放器前景色并保持低对比度
            Rectangle()
                .fill(appearance.divider)
                .frame(width: 1)
                .padding(.vertical, 40)

            wideRightPane()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func wideLeftPane(artSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 顶部 grabber —— 跟 portrait 模式对齐,留出下拉关闭手势的视觉提示
            Capsule()
                .fill(appearance.tertiary)
                .frame(width: 48, height: 5)
                .padding(.top, topSafeArea + 6)
                .padding(.bottom, 10)

            if let error = player.lastPlaybackError {
                Text(error)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.red.opacity(0.8), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            artworkOrMusicVideo(size: artSize, cornerRadius: 16)
            .scaleEffect(player.isPlaying ? 1.0 : 0.92)
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

            Spacer()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(player.currentSong?.title ?? "")
                            .font(.title2).fontWeight(.bold).lineLimit(1)
                            .foregroundStyle(appearance.primary)
                        if let song = player.currentSong, song.audioQuality != .standard {
                            AudioQualityBadge(quality: song.audioQuality)
                        }
                    }
                    nowPlayingMetadataLinks(font: .title3)
                }
                Spacer()
                musicVideoToggleButton(font: .title2, trailing: 6)
                lyricsFullScreenButton(font: .title2, trailing: 2)
                Button { toggleLikedCurrent() } label: {
                    nowPlayingActionIcon(
                        symbol: isCurrentLiked ? "heart.fill" : "heart",
                        tint: isCurrentLiked ? .red : appearance.secondary,
                        isSelected: isCurrentLiked
                    )
                }
                .frame(width: 44, height: 44)
                .disabled(player.currentSong == nil)
                .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                moreMenu
            }
            .padding(.horizontal, 36).padding(.top, 18)

            PlaybackProgressBar()
                .padding(.horizontal, 36).padding(.top, 10)

            HStack(spacing: 0) {
                Spacer()
                ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
                Spacer()
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill").font(.title).foregroundStyle(appearance.primary)
                }
                .frame(width: 56, height: 56)
                .accessibilityLabel("a11y_previous_track")
                Spacer()
                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 60)).opacity(0)
                        if player.isLoading {
                            ProgressView().controlSize(.large).tint(appearance.primary)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 60)).foregroundStyle(appearance.primary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                }
                .disabled(player.isLoading)
                .accessibilityLabel(player.isPlaying
                    ? String(localized: "a11y_pause")
                    : String(localized: "a11y_play"))
                Spacer()
                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").font(.title).foregroundStyle(appearance.primary)
                }
                .frame(width: 56, height: 56)
                .accessibilityLabel("a11y_next_track")
                Spacer()
                ctrlBtn(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                    switch player.repeatMode {
                    case .off: player.repeatMode = .all
                    case .all: player.repeatMode = .one
                    case .one: player.repeatMode = .off
                    }
                }
                Spacer()
            }
            .padding(.top, 14)

            if showsPlayerVolumeBar {
                playerVolumeRow
                    .padding(.horizontal, 36).padding(.top, 12)
            }

            // 底部 bar —— 没有歌词切换按钮(歌词永远在右栏可见),保留 AirPlay
            // 和队列入口
            HStack {
                Spacer()
                AirPlayButton()
                    .frame(width: 36, height: 36)
                    .frame(width: 44, height: 44)
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet").foregroundStyle(appearance.secondary)
                }
                .frame(width: 44, height: 44)
                .accessibilityLabel("a11y_queue")
            }
            .font(.body).padding(.horizontal, 80).padding(.top, 14)

            if let song = player.currentSong {
                HStack(spacing: 4) {
                    Text(song.fileFormat.displayName)
                    if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                    if sourcesStore.sources.count > 1,
                       let source = sourcesStore.source(id: song.sourceID) {
                        Text("·")
                        Image(systemName: source.type.iconName)
                        Text(source.name)
                    }
                }
                .font(.caption2).foregroundStyle(appearance.faint)
                .padding(.top, 6).padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }
        }
    }

    @ViewBuilder
    private func wideRightPane() -> some View {
        VStack(spacing: 0) {
            // 跟左栏 grabber 顶端对齐
            Spacer().frame(height: topSafeArea + 21)
            lyricsFullView
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func standardLandscapeLyricsLayout(geo: GeometryProxy) -> some View {
        let safeInsets = resolvedSafeAreaInsets(for: geo)
        let baseHorizontalPadding = max(72, geo.size.width * 0.10)
        ZStack {
            lyricsFullView
                .padding(.leading, max(baseHorizontalPadding, safeInsets.leading + 18))
                .padding(.trailing, max(baseHorizontalPadding, safeInsets.trailing + 18))
                .padding(.top, 56)
                .padding(.bottom, 88)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { setStandardLyricsVisible(false) } label: {
                        HStack(spacing: 10) {
                            CachedArtworkView(
                                coverRef: player.currentSong?.coverArtFileName,
                                songID: player.currentSong?.id ?? "",
                                size: 40,
                                cornerRadius: 7,
                                sourceID: player.currentSong?.sourceID,
                                filePath: player.currentSong?.filePath,
                                fileFormat: player.currentSong?.fileFormat,
                                revisionToken: player.coverRevision
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(player.currentSong?.title ?? "")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(currentArtistDisplayName)
                                    .font(.caption)
                                    .foregroundStyle(appearance.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(appearance.primary)
                        .padding(.trailing, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("a11y_close_lyrics"))

                    Spacer()

                    lyricsFullScreenButton(font: .title3)

                    Button { toggleLikedCurrent() } label: {
                        nowPlayingActionIcon(
                            symbol: isCurrentLiked ? "heart.fill" : "heart",
                            tint: isCurrentLiked ? .red : appearance.secondary,
                            isSelected: isCurrentLiked
                        )
                    }
                    .frame(width: 44, height: 44)
                    .buttonStyle(.plain)
                    .disabled(player.currentSong == nil)
                    .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))

                    immersiveMoreMenu
                }
                .padding(.leading, max(safeInsets.leading, 18))
                .padding(.trailing, max(safeInsets.trailing, 18))
                .padding(.top, max(safeInsets.top, 10))

                Spacer()

                floatingPlaybackDock
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(safeInsets.bottom, 10))
            }
        }
    }

    @ViewBuilder
    private func immersiveLandscapeLyricsLayout(geo: GeometryProxy) -> some View {
        let safeInsets = resolvedSafeAreaInsets(for: geo)
        let playerWidth = min(max(geo.size.width * 0.34, 260), 410)
        let artSize = min(max(0, playerWidth - 52), geo.size.height * 0.56)

        immersiveLyricsExperience(isLandscape: true) {
            HStack(spacing: 28) {
                VStack(spacing: 18) {
                    Spacer(minLength: 0)

                    artworkOrMusicVideo(size: artSize, cornerRadius: 18)
                        .scaleEffect(player.isPlaying ? 1 : 0.96)
                        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
                        .animation(.spring(response: 0.5, dampingFraction: 0.76), value: player.isPlaying)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.currentSong?.title ?? "")
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                            .foregroundStyle(appearance.primary)
                        nowPlayingMetadataLinks(font: .subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(width: playerWidth)
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(appearance.primary.opacity(0.09), lineWidth: 0.5)
                }

                lyricsFullView
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.leading, max(safeInsets.leading, 24))
            .padding(.trailing, max(safeInsets.trailing, 24))
            .padding(.top, max(safeInsets.top, 18))
            .padding(.bottom, max(safeInsets.bottom, 18))
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleImmersiveContentTap() }
            }
        }
    }

    @ViewBuilder
    private func landscapeMusicVideoLayout(videoPlayer: AVPlayer) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            MusicVideoSurface(player: videoPlayer)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            #if os(iOS)
            Button {
                MusicVideoOrientationController.enterPortrait()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.50), in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .padding(.trailing, 20)
            .accessibilityLabel(Text("exit_landscape_video"))
            #endif
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }

    // MARK: - 原 portrait layout (iPhone + iPad 竖屏 + 分屏小窗)

    @ViewBuilder
    private func portraitLayout(geo: GeometryProxy, artSize: CGFloat) -> some View {
        // MV 是 16:9，若沿用方形封面按高度推导出的宽度，会在竖屏里显得
        // 明显偏小。视频改为尽量吃满屏宽；方形封面仍保持原来的视觉尺度。
        let mediaWidth = player.isMusicVideoPlaybackActive
            ? min(max(0, geo.size.width - 20), 720)
            : artSize

        VStack(spacing: 0) {
                    // Grabber handle (system-matching dimensions)
                    if !showLyrics || !isLyricsImmersive {
                        Capsule()
                            .fill(appearance.tertiary)
                            .frame(width: 48, height: 5)
                            .frame(maxWidth: .infinity)
                            .frame(height: 5)
                            .padding(.top, topSafeArea + 6)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 10)
                    }

                    // Playback error toast
                    if (!showLyrics || !isLyricsImmersive),
                       let error = player.lastPlaybackError {
                        Text(error)
                            .font(.caption).fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.red.opacity(0.8), in: Capsule())
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if showLyrics {
                        // LYRICS MODE: compact header at top
                        if !isLyricsImmersive {
                            HStack(spacing: 10) {
                            // Explicit button rather than a hidden tap gesture:
                            // the artwork itself is now a discoverable way back.
                            Button { setStandardLyricsVisible(false) } label: {
                                HStack(spacing: 10) {
                                    CachedArtworkView(
                                        coverRef: player.currentSong?.coverArtFileName,
                                        songID: player.currentSong?.id ?? "",
                                        size: 44, cornerRadius: 6,
                                        sourceID: player.currentSong?.sourceID,
                                        filePath: player.currentSong?.filePath,
                                        fileFormat: player.currentSong?.fileFormat,
                                        revisionToken: player.coverRevision
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(player.currentSong?.title ?? "")
                                            .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                                            .foregroundStyle(appearance.primary)
                                        Text(currentArtistDisplayName)
                                            .font(.caption).foregroundStyle(appearance.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .accessibilityLabel(Text("a11y_close_lyrics"))

                            Spacer()

                            musicVideoToggleButton(font: .title3, trailing: 4)
                            lyricsFullScreenButton(font: .title3)

                            Button { toggleLikedCurrent() } label: {
                                nowPlayingActionIcon(
                                    symbol: isCurrentLiked ? "heart.fill" : "heart",
                                    tint: isCurrentLiked ? .red : appearance.secondary,
                                    isSelected: isCurrentLiked
                                )
                            }
                            .frame(width: 44, height: 44)
                            .disabled(player.currentSong == nil)
                            .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))

                            // More menu
                            moreMenu
                            }
                            .padding(.horizontal, 20).padding(.bottom, 6)
                            .transition(.opacity)
                        }

                        // Full screen lyrics
                        if isLyricsImmersive {
                            immersiveLyricsExperience(isLandscape: false) {
                                lyricsFullView
                            }
                            .transition(.opacity)
                        } else {
                            lyricsFullView
                                .transition(.opacity)
                        }
                    } else {
                        // PLAYER MODE
                        Spacer()

                        // Artwork
                        artworkOrMusicVideo(size: mediaWidth, cornerRadius: 12)
                        .scaleEffect(
                            player.isMusicVideoPlaybackActive
                                ? 1.0
                                : (player.isPlaying ? 1.0 : 0.9)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                        .onTapGesture {
                            // 视频画面本身不再充当「打开歌词」的隐藏入口，避免用户
                            // 想点 MV 时意外切走；封面模式仍保留原交互。
                            guard !player.isMusicVideoPlaybackActive else { return }
                            setStandardLyricsVisible(true)
                        }
                        .transition(.opacity)

                        Spacer()
                    }

                    // Song info (player mode only — in lyrics mode it's in the top bar)
                    if !showLyrics {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(player.currentSong?.title ?? "")
                                    .font(.title3).fontWeight(.bold).lineLimit(1)
                                    .foregroundStyle(appearance.primary)
                                nowPlayingMetadataLinks(font: .body)
                            }
                            Spacer()

                            musicVideoToggleButton(font: .title2, trailing: 6)
                            lyricsFullScreenButton(font: .title2, trailing: 2)

                            // Like button
                            Button { toggleLikedCurrent() } label: {
                                nowPlayingActionIcon(
                                    symbol: isCurrentLiked ? "heart.fill" : "heart",
                                    tint: isCurrentLiked ? .red : appearance.secondary,
                                    isSelected: isCurrentLiked
                                )
                            }
                            .frame(width: 44, height: 44)
                            .disabled(player.currentSong == nil)
                            .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))

                            // More menu
                            moreMenu
                        }
                        .padding(.horizontal, 26).padding(.top, 12)
                    }

                    // Progress — 抽成独立子 view 隔离 player.currentTime 的高频
                    // 重算,避免触发父 body re-render(进而让 toolbar Menu 的 submenu
                    // 被强制关闭)。SwiftUI Observation 是 per-body 追踪——子 view
                    // 自己读 player.currentTime,父 view body 完全不读高频属性。
                    if !showLyrics || !isLyricsImmersive {
                        PlaybackProgressBar()
                            .padding(.horizontal, 26).padding(.top, 8)

                        // Controls
                        HStack(spacing: 0) {
                        Spacer()
                        ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
                        Spacer()
                        Button { Task { await player.previous() } } label: {
                            Image(systemName: "backward.fill").font(.title).foregroundStyle(appearance.primary)
                        }
                        .frame(width: 56, height: 56)
                        .accessibilityLabel("a11y_previous_track")
                        Spacer()
                        Button { player.togglePlayPause() } label: {
                            ZStack {
                                // Anchor sizing so the button doesn't reflow.
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 56)).opacity(0)
                                if player.isLoading {
                                    ProgressView()
                                        .controlSize(.large)
                                        .tint(appearance.primary)
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 56)).foregroundStyle(appearance.primary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                            }
                        }
                        .disabled(player.isLoading)
                        .accessibilityLabel(player.isPlaying
                            ? String(localized: "a11y_pause")
                            : String(localized: "a11y_play"))
                        Spacer()
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill").font(.title).foregroundStyle(appearance.primary)
                        }
                        .frame(width: 56, height: 56)
                        .accessibilityLabel("a11y_next_track")
                        Spacer()
                        ctrlBtn(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                            switch player.repeatMode {
                            case .off: player.repeatMode = .all
                            case .all: player.repeatMode = .one
                            case .one: player.repeatMode = .off
                            }
                        }
                        Spacer()
                        }
                        .padding(.top, 12)

                        if showsPlayerVolumeBar {
                            playerVolumeRow
                                .padding(.horizontal, 26).padding(.top, 10)
                        }

                        // Bottom bar —— 三个槽位都是 44×44, HStack 的两个 Spacer 才
                        // 会把 AirPlay 分到正中, 左右图标到 padding 边的距离也才相等
                        HStack {
                        Button { toggleStandardLyrics() } label: {
                            Image(systemName: showLyrics ? "photo" : "quote.bubble")
                                .foregroundStyle(showLyrics ? appearance.primary : appearance.tertiary)
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel(Text(showLyrics ? "a11y_close_lyrics" : "a11y_open_lyrics"))
                        Spacer()
                        AirPlayButton()
                            .frame(width: 36, height: 36)
                            .frame(width: 44, height: 44)
                        Spacer()
                        Button { showQueue = true } label: {
                            Image(systemName: "list.bullet").foregroundStyle(appearance.tertiary)
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("a11y_queue")
                        }
                        .font(.body).padding(.horizontal, 46).padding(.top, 12)

                        // Format & source
                        if let song = player.currentSong {
                            HStack(spacing: 4) {
                                Text(song.fileFormat.displayName)
                                if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                                if sourcesStore.sources.count > 1,
                                   let source = sourcesStore.source(id: song.sourceID) {
                                    Text("·")
                                    Image(systemName: source.type.iconName)
                                    Text(source.name)
                                }
                            }
                            .font(.caption2).foregroundStyle(appearance.faint).padding(.top, 4).padding(.bottom, 6)
                        }
                    }
                }
    }

    @ViewBuilder
    private func immersiveLyricsExperience<Content: View>(
        isLandscape: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())

            if immersiveControlsState.isLocked || !immersiveControlsState.isVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { handleImmersiveContentTap() }
            }

            immersiveLyricsChrome(isLandscape: isLandscape)
        }
    }

    @ViewBuilder
    private func immersiveLyricsChrome(isLandscape: Bool) -> some View {
        if immersiveControlsState.showsPrimaryControls {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ImmersiveGlassActionButton(
                        symbol: "lock",
                        label: "immersive_lock_controls",
                        tint: appearance.primary,
                        diameter: 44
                    ) {
                        lockImmersiveControls()
                    }

                    Spacer()

                    immersiveEffectMenu

                    ImmersiveGlassActionButton(
                        symbol: isCurrentLiked ? "heart.fill" : "heart",
                        label: isCurrentLiked ? "a11y_unlike" : "a11y_like",
                        tint: isCurrentLiked ? .red : appearance.primary,
                        diameter: 44,
                        isSelected: isCurrentLiked
                    ) {
                        toggleLikedCurrent()
                    }
                    .disabled(player.currentSong == nil)

                    immersiveMoreMenu

                    ImmersiveGlassActionButton(
                        symbol: "arrow.down.right.and.arrow.up.left",
                        label: "lyrics_exit_full_screen",
                        tint: appearance.primary,
                        diameter: 44
                    ) {
                        dismissImmersiveLyrics()
                    }
                }
                .padding(.horizontal, isLandscape ? 24 : 20)
                .padding(.top, max(topSafeArea, 10) + (isLandscape ? 0 : 8))

                Spacer()

                floatingPlaybackDock
                    .frame(maxWidth: isLandscape ? 440 : 520)
                    .padding(.horizontal, isLandscape ? 28 : 20)
                    .padding(.bottom, max(bottomSafeArea, 12) + (isLandscape ? 0 : 8))
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .zIndex(2)
        } else if immersiveControlsState.showsUnlockControl {
            HStack {
                Button { unlockImmersiveControls() } label: {
                    Label("immersive_unlock_controls", systemImage: "lock.open.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appearance.primary)
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("immersive_unlock_controls"))

                Spacer()
            }
            .padding(.leading, isLandscape ? max(24, topSafeArea) : 20)
            .transition(.opacity.combined(with: .move(edge: .leading)))
            .zIndex(2)
        }
    }

    private var floatingPlaybackDock: some View {
        VStack(spacing: 8) {
            PlaybackProgressBar()

            HStack(spacing: 34) {
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill")
                        .frame(width: 44, height: 36)
                }
                .accessibilityLabel("a11y_previous_track")

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(player.isLoading)
                .accessibilityLabel(player.isPlaying
                    ? String(localized: "a11y_pause")
                    : String(localized: "a11y_play"))

                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 44, height: 36)
                }
                .accessibilityLabel("a11y_next_track")
            }
            .font(.title3)
            .foregroundStyle(appearance.primary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(appearance.primary.opacity(0.10), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func artworkOrMusicVideo(size: CGFloat, cornerRadius: CGFloat) -> some View {
        if player.isMusicVideoPlaybackActive, let videoPlayer = player.musicVideoPlayer {
            ZStack(alignment: .topTrailing) {
                MusicVideoSurface(player: videoPlayer)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(width: size, height: size * 9 / 16)
                    .background(Color.black)

                #if os(iOS)
                Button {
                    presentMusicVideoFullScreen(videoPlayer)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(0.44), in: Circle())
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel(Text("full_screen_player"))
                #endif
            }
            .frame(width: size, height: size * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
        } else {
            CachedArtworkView(
                coverRef: player.currentSong?.coverArtFileName,
                songID: player.currentSong?.id ?? "",
                size: size, cornerRadius: cornerRadius,
                sourceID: player.currentSong?.sourceID,
                filePath: player.currentSong?.filePath,
                fileFormat: player.currentSong?.fileFormat,
                presentationRole: .animatedHero,
                animationRequiresPlayback: true,
                isPlaying: player.isPlaying,
                isAnimationVisible: !showQueue && !isFullscreenPlayerPresented,
                revisionToken: player.coverRevision
            )
        }
    }

    @ViewBuilder
    private func musicVideoToggleButton(font: Font, trailing: CGFloat) -> some View {
        // 独立 MV 始终走视频管线, 模式开关对它无意义, 不显示
        if player.canPlayMusicVideo, player.currentSong?.isStandaloneMusicVideo != true {
            Button { player.toggleMusicVideoMode() } label: {
                Image(systemName: player.isMusicVideoModeEnabled ? "play.rectangle.fill" : "play.rectangle")
                    .font(font)
                    .foregroundStyle(player.isMusicVideoModeEnabled ? appearance.primary : appearance.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(player.currentSong == nil || player.isLoading)
            .padding(.trailing, trailing)
            .accessibilityLabel(Text(player.isMusicVideoModeEnabled ? "Disable MV" : "Enable MV"))
        }
    }

    private func deleteCurrentSong() {
        guard let song = player.currentSong,
              SourceFileDeletionPolicy.shouldShowDeleteAction(
                  for: sourcesStore.source(id: song.sourceID)?.type
              )
        else { return }
        Task {
            // Move off the deleted song AND drop every queue entry that
            // points at it before touching the files. Otherwise the stale
            // entries linger in the queue (played / up-next), and repeat-all
            // wrap, previous(), or tapping the row would re-play a song whose
            // file is already gone + tombstoned → resolveURL throws.
            let remainingQueue = player.queue.filter { $0.id != song.id }
            if remainingQueue.isEmpty {
                // This was the only thing queued — replaying it via next()
                // would just decode the file we're about to delete. Tear the
                // queue down instead.
                player.stop()
                player.clearQueue()
            } else {
                // Skip to a different track first so playback keeps going,
                // then rebuild the queue without the deleted song. setQueue
                // resets currentIndex, bumps the queue generation, and (when
                // shuffle is on) rebuilds the shuffle order around the new
                // current song.
                await player.next()
                let newSongID = player.currentSong?.id
                let anchorIndex = remainingQueue.firstIndex { $0.id == newSongID } ?? 0
                player.setQueue(remainingQueue, startAt: anchorIndex)
            }
            let retainedSongs = library.songs.filter { $0.id != song.id }
            let deleteSidecars = sourceManager.shouldDeleteSidecars(for: song, retaining: retainedSongs)
            let result = await sourceManager.deleteSourceFilesAndCaches(
                for: song,
                deleteSidecars: deleteSidecars
            )
            guard result.shouldRemoveLibraryRecord else {
                deleteErrorMessage = deletionFailureMessage(result)
                return
            }
            // Remove from library and keep the source badge in sync.
            let remaining = library.deleteSong(song)
            sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
        }
    }

    private func deletionFailureMessage(_ result: SongFileDeletionResult) -> String {
        let summary = String(localized: "delete_song_failed_message")
        guard let detail = result.failedPaths.first?.message, !detail.isEmpty else { return summary }
        return "\(summary)\n\(detail)"
    }

    #if os(iOS)
    private func presentMusicVideoFullScreen(_ videoPlayer: AVPlayer) {
        fullScreenMusicVideoPlayer = videoPlayer
        showMusicVideoFullScreen = true
    }

    private func dismissMusicVideoFullScreenIfNeeded() {
        guard showMusicVideoFullScreen else {
            fullScreenMusicVideoPlayer = nil
            return
        }
        guard player.isMusicVideoModeEnabled || player.currentSong?.isStandaloneMusicVideo == true,
              player.currentSong != nil,
              player.currentSong?.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            dismissMusicVideoFullScreen()
            return
        }
    }

    private func dismissMusicVideoFullScreen() {
        guard showMusicVideoFullScreen else {
            finishMusicVideoFullScreenDismissal()
            return
        }
        // Keep the AVPlayer-backed cover stable until UIKit has actually
        // removed its presentation host. Clearing its content while the cover
        // and the window scene are rotating can leave an invisible modal view
        // above the portrait UI that consumes every tap.
        showMusicVideoFullScreen = false
    }

    private func finishMusicVideoFullScreenDismissal() {
        fullScreenMusicVideoPlayer = nil
        // fullScreenCover's onDismiss runs after the modal presentation has
        // been removed. Restore orientation here rather than from the close
        // button/onDisappear so geometry changes cannot race cover teardown.
        MusicVideoOrientationController.restorePreviousOrientation()
    }
    #endif

    // MARK: - More Menu

    private var moreMenu: some View {
        makeMoreMenu()
    }

    private var immersiveMoreMenu: some View {
        makeMoreMenu(immersiveChrome: true)
    }

    private var immersiveEffectMenu: some View {
        Button {
            immersiveControlsAutoHideTask?.cancel()
            showsImmersiveEffectPicker = true
        } label: {
            ImmersiveGlassActionLabel(
                symbol: "viewfinder.rectangular",
                tint: appearance.primary,
                diameter: 44,
                isSelected: fullscreenPlayerEffect != .native
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsImmersiveEffectPicker, arrowEdge: .top) {
            ImmersiveEffectPickerPanel(
                selected: fullscreenPlayerEffect,
                palette: ImmersiveArtworkPalette(
                    primary: theme.accentColor,
                    secondary: theme.darkAccent
                )
            ) { candidate in
                showsImmersiveEffectPicker = false
                fullscreenPlayerEffectBinding.wrappedValue = candidate
            }
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(Text("fullscreen_effect_settings_title"))
    }

    private func makeMoreMenu(immersiveChrome: Bool = false) -> some View {
        let snapshot = NowPlayingMoreMenuSnapshot(
            songID: player.currentSong?.id,
            hasSong: player.currentSong != nil,
            isScrapingCurrentSong: isScrapeActionUnavailable,
            isAppleMusicMode: player.isAppleMusicMode,
            canDeleteSourceFile: player.currentSong.map {
                SourceFileDeletionPolicy.shouldShowDeleteAction(
                    for: sourcesStore.source(id: $0.sourceID)?.type
                )
            } ?? false,
            appleMusicCatalogURL: appleMusicCatalogURL,
            showsLyricsPreferences: showLyrics,
            albumID: currentAlbum?.id,
            artistID: currentArtist?.id,
            canOpenAlbum: currentAlbum != nil && onOpenAlbum != nil,
            canOpenArtist: currentArtist != nil && onOpenArtist != nil,
            shareText: player.currentSong.map {
                "\($0.title) - \(library.artistDisplayName(for: $0) ?? "")"
            },
            castingRendererName: player.castingRenderer?.friendlyName,
            isSleepTimerActive: player.isSleepTimerActive,
            lyricsFontScale: lyricsFontScale,
            playbackRate: playbackSettings.playbackRate,
            isLyricsTranslationEnabled: LyricsTranslationSettingsStore.shared.isEnabled,
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast
        )

        return NowPlayingMoreMenu(
            snapshot: snapshot,
            lyricsFontScale: $lyricsFontScale,
            playbackRate: Binding(
                get: { playbackSettings.playbackRate },
                set: { playbackSettings.playbackRate = $0 }
            ),
            immersiveChrome: immersiveChrome,
            onAddToPlaylist: { showAddToPlaylist = true },
            onScrape: { openScrapeForCurrentSong() },
            onShowSimilarSongs: { showSimilarSongs = true },
            onEditTags: { showTagEditor = true },
            onEditLyrics: {
                lyricsEditorAutoStartsAudioTranscription = false
                lyricsEditorTargetSong = player.currentSong
            },
            onShowSongInfo: { showSongInfo = true },
            onOpenAlbum: {
                guard let album = currentAlbum else { return }
                onOpenAlbum?(album)
            },
            onOpenArtist: {
                guard let artist = currentArtist else { return }
                onOpenArtist?(artist)
            },
            onOpenInAppleMusic: {
                guard let url = appleMusicCatalogURL else { return }
                openURL(url)
            },
            onShowCastPicker: { showCastPicker = true },
            onToggleLyricsTranslation: {
                LyricsTranslationSettingsStore.shared.isEnabled.toggle()
            },
            onShowSleepTimer: { showSleepTimer = true },
            onDelete: { showDeleteConfirm = true }
        )
        .equatable()
    }

    // MARK: - Ambient background from cover dominant color

    private var backgroundGradient: some View {
        GeometryReader { geo in
            let radius = max(geo.size.width, geo.size.height) * 0.82
            let hasArtworkTheme = theme.colorID != "default"
            let strength = AppThemePreferences.normalizedAmbientStrength(ambientStrength)
            let accentOpacity = (hasArtworkTheme
                ? appearance.artworkAccentOpacity
                : appearance.fallbackAccentOpacity) * strength
            let lowerAccentOpacity = (hasArtworkTheme
                ? appearance.artworkLowerAccentOpacity
                : appearance.fallbackLowerAccentOpacity) * strength
            let lightOverlay = AmbientLightOverlayPolicy.resolve(
                hasArtworkTheme: hasArtworkTheme,
                usesIncreasedContrast: colorSchemeContrast == .increased,
                strength: strength
            )

            ZStack {
                appearance.backgroundBase

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
                    endRadius: radius * 0.9
                )

                if appearance.isLight {
                    // Keep a stable light surface for dark controls without
                    // washing the cover-driven hue back to near-neutral.
                    LinearGradient(
                        colors: [
                            .white.opacity(lightOverlay.topOpacity),
                            .white.opacity(lightOverlay.bottomOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    // Dark appearance keeps the immersive artwork field but
                    // protects white lyrics and transport controls.
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.18), location: 0),
                            .init(color: .black.opacity(0.22), location: 0.56),
                            .init(color: .black.opacity(0.28), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .animation(
            .easeInOut(duration: AmbientBackdropTuning.transitionDuration),
            value: theme.colorID
        )
        .allowsHitTesting(false)
    }

    // MARK: - Full Lyrics

    private var lyricsFullView: some View {
        LyricsScrollView(
            lyrics: lyrics,
            lyricsWritingDirection: lyricsWritingDirection,
            lyricsRevision: lyricsRevision,
            player: player,
            songID: player.currentSong?.id,
            isSceneActive: isVisualSceneActive,
            isScrapingCurrentSong: isScrapingCurrentSong,
            canTranscribeAudio: canTranscribeCurrentSongAudio,
            isScrapeActionUnavailable: isScrapeActionUnavailable,
            onAutomaticScrape: { startAutomaticLyricsScrape() },
            onTranscribeAudio: { openAudioTranscriptionEditor() },
            onBackgroundTap: {
                if isLyricsImmersive {
                    // ScrollView owns the reliable surface gesture. Routing the
                    // immersive tap through it avoids the scroll recognizer
                    // swallowing the outer ZStack tap after chrome auto-hides.
                    handleImmersiveContentTap()
                } else {
                    setStandardLyricsVisible(false)
                }
            }
        )
    }

    /// Artist and album are independent buttons, matching the interaction users
    /// expect from Apple Music/Spotify-style now-playing screens.
    @ViewBuilder
    private func nowPlayingMetadataLinks(font: Font) -> some View {
        let artistName = currentArtistDisplayName
        HStack(spacing: 6) {
            if currentArtists.count == 1,
               let artist = currentArtist,
               onOpenArtist != nil {
                Button { onOpenArtist?(artist) } label: {
                    Text(artistName).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("go_to_artist"))
            } else if currentArtists.count > 1, onOpenArtist != nil {
                Menu {
                    ForEach(currentArtists) { artist in
                        Button(artist.name) { onOpenArtist?(artist) }
                    }
                } label: {
                    Text(artistName).lineLimit(1)
                }
                .accessibilityLabel(Text("go_to_artist"))
            } else if !artistName.isEmpty {
                Text(artistName).lineLimit(1)
            }

            if !artistName.isEmpty,
               player.currentSong?.albumTitle?.isEmpty == false {
                Text("·")
            }

            if let album = currentAlbum, onOpenAlbum != nil {
                Button { onOpenAlbum?(album) } label: {
                    Text(album.title).lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("go_to_album"))
            } else if let albumTitle = player.currentSong?.albumTitle, !albumTitle.isEmpty {
                Text(albumTitle).lineLimit(1)
            }
        }
        .font(font)
        .foregroundStyle(appearance.secondary)
    }

    // MARK: - Helpers

    private func ctrlBtn(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body)
                .foregroundStyle(active ? themedControlAccent : appearance.tertiary)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Self.iconA11yLabel(icon))
        .accessibilityValue(active
            ? String(localized: "a11y_value_on")
            : String(localized: "a11y_value_off"))
    }

    private var themedControlAccent: Color {
        guard theme.colorID != "default" else { return appearance.primary }
        return appearance.isLight ? theme.darkAccent : theme.accentColor
    }

    /// SF Symbol -> VoiceOver 标签的映射, 用在 transport 控件上。
    private static func iconA11yLabel(_ icon: String) -> LocalizedStringKey {
        switch icon {
        case "shuffle": return "a11y_shuffle"
        case "repeat", "repeat.1": return "a11y_repeat"
        default: return "a11y_button_generic"
        }
    }

    private func loadLyrics() async {
        lyricsLoadRevision &+= 1
        let loadRevision = lyricsLoadRevision
        guard let song = player.currentSong else { setLyrics([]); return }
        let loadStart = Date()

        // Apple Music 优先走 MusicKit 原生 catalog 歌词。先查
        // MetadataAssetStore songID cache 命中直接显示 (cache 一份避免每次切
        // 歌都走 catalog 网络); miss 再问 MusicKit, 拿到 TTML 解析后写回 cache。
        // 全失败 → setLyrics([])，emptyLyricsView 仍允许用户走和 macOS 相同的
        // 在线歌词刮削链路，而不是只能跳转 Apple Music。
        if song.sourceID == AppleMusicLibraryService.systemSourceID {
            if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id),
               !cached.isEmpty {
                plog(String(format: "📜 Apple Music lyrics cache hit '%@' (%d lines)",
                            song.title, cached.count))
                setLyricsIfCurrent(cached, for: song, loadRevision: loadRevision)
                return
            }
            do {
                if let lyrics = try await AppServices.shared.appleMusicLibrary
                    .fetchLyrics(forAmID: song.filePath),
                   !lyrics.isEmpty {
                    guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
                    _ = await MetadataAssetStore.shared.cacheLyrics(lyrics, forSongID: song.id, force: true)
                    plog(String(format: "📜 Apple Music lyrics fetched '%@' in %.0fms (%d lines)",
                                song.title, Date().timeIntervalSince(loadStart) * 1000, lyrics.count))
                    setLyricsIfCurrent(lyrics, for: song, loadRevision: loadRevision)
                    return
                } else {
                    plog("📜 Apple Music lyrics: no official lyrics for '\(song.title)'")
                }
            } catch {
                plog("⚠️Apple Music lyrics fetch failed for '\(song.title)': \(error.localizedDescription)")
            }
            setLyricsIfCurrent([], for: song, loadRevision: loadRevision)
            return
        }

        // Tier 1a: songID hash cache —— 即使 NAS path 也读 (stale-while-revalidate)。
        // 历史污染 cache 现在通过 trustedSource:false + sidecar 写后回写 cache
        // 在根源上修复, 这里允许 cache hit 立即显示, 后台再校验。
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !cached.isEmpty {
            plog(String(format: "📜 loadLyrics '%@' Tier1a hit (songID hash) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, cached.count))
            guard setLyricsIfCurrent(cached, for: song, loadRevision: loadRevision) else { return }
            // NAS path 时, 后台校验 cache 是否 stale (NAS sidecar 才是真相)。
            // 静默成功 = no-op; 若发现差异会 update UI + cache。
            if (song.lyricsFileName ?? "").contains("/") {
                runLyricsTier3Fetch(
                    song: song,
                    currentCache: cached,
                    loadRevision: loadRevision
                )
            }
            return
        }

        let lyricsRefIsRemote = (song.lyricsFileName ?? "").contains("/")

        // Tier 1b: legacy named ref (only for non-NAS path)
        if !lyricsRefIsRemote,
           let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier1b hit (named ref) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, cached.count))
            setLyricsIfCurrent(cached, for: song, loadRevision: loadRevision); return
        }

        // Tier 2: Check local audio cache for a lyrics sidecar (filesystem only, zero network)
        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return }
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier2 hit (audio cache sidecar) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, parsed.count))
            setLyricsIfCurrent(parsed, for: song, loadRevision: loadRevision); return
        }

        // Tier 3: 首次必走 (无 cache, 无本地 sidecar)
        guard setLyricsIfCurrent([], for: song, loadRevision: loadRevision) else { return }
        plog(String(format: "📜 loadLyrics '%@' miss Tier1+2, falling to Tier3 (NAS fetch)", song.title))
        runLyricsTier3Fetch(song: song, currentCache: nil, loadRevision: loadRevision)
    }

    /// Tier 3 NAS fetch + 校验。currentCache != nil 时为 stale-while-revalidate
    /// 模式: 已 setLyrics(currentCache), 这里只在 fingerprint 不一致时 update UI。
    private func runLyricsTier3Fetch(
        song: Song,
        currentCache: [LyricLine]?,
        loadRevision: UInt
    ) {
        let capturedSourceManager = sourceManager
        let capturedScraperService = scraperService
        let songID = song.id
        let songTitle = song.title
        let isRefresh = currentCache != nil

        Task {
            let tier3Start = Date()
            do {
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                let connector = try await capturedSourceManager.auxiliaryConnector(for: song)
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                let connectMs = Date().timeIntervalSince(tier3Start) * 1000

                // 服务端歌词 (Subsonic getLyricsBySongId 等) —— 服务端曲库源不是
                // "同目录歌词 sidecar" 模型, 走 connector 的 ServerLyricsConnector 能力。
                // 服务端源在此终结: 即使服务端没歌词也不去 fetchRange sidecar
                // (对 Subsonic 那会拉到音频流, 既浪费又解析失败)。
                if let server = connector as? ServerLyricsConnector {
                    if let raw = await server.fetchServerLyrics(for: song.filePath) {
                        guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                        let parsed = LyricsParser.parseText(raw)
                        if !parsed.isEmpty {
                            if let currentCache,
                               Self.lyricsFingerprint(parsed) == Self.lyricsFingerprint(currentCache) {
                                return
                            }
                            _ = await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: songID)
                            plog(String(format: "📜 loadLyrics '%@' server-lyrics OK in %.0fms (%d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, parsed.count))
                            if isCurrentLyricsLoad(loadRevision, songID: songID) {
                                setLyrics(parsed)
                            }
                            return
                        }
                    }
                    plog(String(format: "📜 loadLyrics '%@' server-lyrics empty (connect=%.0fms)", songTitle, connectMs))

                    // Airsonic and other read-only servers often delegate
                    // lyrics to an external provider. A provider-side 404 is
                    // not a terminal app result: fall through to the same
                    // title-compatible online lyrics pipeline used by manual
                    // scraping, then bind the result to this local song ID.
                    if let online = await capturedScraperService.fetchOnlineLyrics(
                        title: song.title,
                        artist: song.artistName,
                        album: song.albumTitle,
                        duration: song.duration > 0 ? song.duration : nil
                    ), !online.isEmpty {
                        guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                        _ = await MetadataAssetStore.shared.cacheLyrics(
                            online,
                            forSongID: songID,
                            force: true
                        )
                        plog(String(format: "📜 loadLyrics '%@' online fallback OK in %.0fms (%d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, online.count))
                        if isCurrentLyricsLoad(loadRevision, songID: songID) {
                            setLyrics(online)
                        }
                    }
                    return
                }

                let songDir = (song.filePath as NSString).deletingLastPathComponent
                let baseName = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                let lyricsPath: String
                if let ref = song.lyricsFileName, ref.contains("/") {
                    lyricsPath = ref
                } else {
                    lyricsPath = (songDir as NSString).appendingPathComponent("\(baseName).lrc")
                }

                let fetchStart = Date()
                let lyricsData = try await connector.fetchRange(
                    path: lyricsPath,
                    offset: 0,
                    length: 256 * 1024,
                    priority: .background
                )
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                let fetchMs = Date().timeIntervalSince(fetchStart) * 1000
                guard let lyricsContent = String(data: lyricsData, encoding: .utf8) else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 sidecar not utf8 (connect=%.0fms fetch=%.0fms)", songTitle, connectMs, fetchMs))
                    return
                }
                let parsed = LyricsParser.parse(lyricsContent)
                guard !parsed.isEmpty else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 sidecar empty after parse (connect=%.0fms fetch=%.0fms %dB)", songTitle, connectMs, fetchMs, lyricsData.count))
                    return
                }

                // Refresh 模式: cache 与 NAS 一致就静默退出, 不写盘不 update UI
                if let currentCache,
                   Self.lyricsFingerprint(parsed) == Self.lyricsFingerprint(currentCache) {
                    plog(String(format: "📜 lyrics refresh '%@' cache fresh, no update (%.0fms)", songTitle, Date().timeIntervalSince(tier3Start) * 1000))
                    return
                }

                let wrote = await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: songID)
                if !wrote {
                    // 写入被「不降级」拦截 (现存字级, NAS 是行级 sidecar 自动
                    // 写回的) —— UI 保持原 cache 显示, 不切到行级。
                    plog(String(format: "📜 lyrics refresh '%@' SKIP downgrade (%.0fms, cache word-level kept)", songTitle, Date().timeIntervalSince(tier3Start) * 1000))
                    return
                }
                if isRefresh {
                    plog(String(format: "📜 lyrics refresh '%@' cache STALE → updated (%.0fms, %d→%d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, currentCache?.count ?? 0, parsed.count))
                } else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 OK in %.0fms (connect=%.0fms fetch=%.0fms %dB %d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, connectMs, fetchMs, lyricsData.count, parsed.count))
                }
                if isCurrentLyricsLoad(loadRevision, songID: songID) {
                    setLyrics(parsed)
                }
            } catch {
                guard isCurrentLyricsLoad(loadRevision, songID: songID) else { return }
                if isRefresh {
                    // refresh 失败不影响 user, 已经显示了 cache
                    plog(String(format: "📜 lyrics refresh '%@' FAILED in %.0fms (cache still shown): %@", songTitle, Date().timeIntervalSince(tier3Start) * 1000, error.localizedDescription))
                } else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 FAILED in %.0fms: %@", songTitle, Date().timeIntervalSince(tier3Start) * 1000, error.localizedDescription))
                }
            }
        }
    }

    /// Lyrics 内容 fingerprint, 用于 stale-while-revalidate 比较。
    /// LyricLine.id 是 UUID() 每次 parse 不同, 不能直接 ==。这里取
    /// 行数 + 首尾 timestamp + 首尾 text, 足够区分内容差异。
    private static func lyricsFingerprint(_ lines: [LyricLine]) -> String {
        guard let first = lines.first, let last = lines.last else { return "empty" }
        return "\(lines.count)|\(first.timestamp)|\(first.text)|\(last.timestamp)|\(last.text)"
    }

    /// loadLyrics 的同步 tier (Tier1a/1b/2 + Apple Music) 在 await 之后写歌词
    /// 前的统一守卫: 切歌时 .task(id:) 会 cancel 旧任务, 但取消是协作式的, actor
    /// 跳跃的 await 不是取消点。除 song identity 外还校验 load revision，避免同一
    /// 首歌的旧 Tier 3 请求晚到后覆盖刚刮削出来的新歌词。
    @discardableResult
    private func setLyricsIfCurrent(
        _ value: [LyricLine],
        for song: Song,
        loadRevision: UInt
    ) -> Bool {
        guard isCurrentLyricsLoad(loadRevision, songID: song.id) else { return false }
        setLyrics(value)
        return true
    }

    private func isCurrentLyricsLoad(_ loadRevision: UInt, songID: String) -> Bool {
        !Task.isCancelled
            && lyricsLoadRevision == loadRevision
            && player.currentSong?.id == songID
    }

    private func setLyrics(_ value: [LyricLine]) {
        lyricsWritingDirection = LyricWritingDirectionPolicy.resolve(in: value)
        lyrics = value
        lyricsRevision &+= 1
        let wordLevelCount = value.filter { $0.isWordLevel }.count
        plog("📜 setLyrics: lines=\(value.count) wordLevelLines=\(wordLevelCount) direction=\(String(describing: lyricsWritingDirection)) firstSyllables=\(value.first?.syllables?.count ?? -1)")
        // currentLineIndex / hasWordLevelLyrics 已迁移到 LyricsScrollView 子 view,
        // 子 view 自己 onChange(of: songID) 重置 + computed property 算 hasWord。
        consumePendingLyricsJump(from: value)
    }

    /// 搜索页点歌词命中结果时, player 上挂了一个 pending hint。歌词刚加载
    /// 完就在这里 fuzzy match 找对应行的 timestamp 并 seek。命中即清, 一次性。
    /// songID 必须匹配当前 currentSong, 避免用户快速切歌时 jump 到别首。
    private func consumePendingLyricsJump(from lines: [LyricLine]) {
        guard let hint = player.pendingLyricsJump,
              let currentID = player.currentSong?.id,
              hint.songID == currentID,
              !lines.isEmpty else { return }
        // snippet 可能包含上下文行 ("...prev\nmatch\nnext..."), 提取最长一行做匹配。
        let needle = hint.snippet
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .max(by: { $0.count < $1.count }) ?? hint.snippet
        guard !needle.isEmpty else { player.clearPendingLyricsJump(); return }
        if let match = lines.first(where: { $0.text.localizedCaseInsensitiveContains(needle) }) {
            player.seek(to: max(0, match.timestamp - 0.3))
            // 用户来这是为了看歌词上下文, 默认切到歌词面板
            setStandardLyricsVisible(true)
        }
        player.clearPendingLyricsJump()
    }



    /// Always open the candidate/preview sheet. Apple Music used to run a
    /// lyrics-only automatic scrape immediately here, which meant tapping the
    /// nominally manual action silently overwrote the cached lyrics and could
    /// choose a different provider result on every tap.
    private func openScrapeForCurrentSong() {
        guard let displayedSong = player.currentSong else { return }
        guard !isScrapeActionUnavailable else { return }

        scraperSettings.performSingleSongScrapeAction(
            from: .nowPlayingOptions,
            onProceed: { openScrapeForCurrentSongWithEnabledSource(displayedSong) },
            onRequireSource: { showNoScraperSourceAlert = true }
        )
    }

    private func openScrapeForCurrentSongWithEnabledSource(_ displayedSong: Song) {
        guard displayedSong.sourceID == AppleMusicLibraryIdentity.sourceID else {
            scrapeTargetSong = displayedSong
            return
        }

        // Resolve the transient MusicKit catalog identity before presenting
        // the sheet. Await alias preservation first so an older cached lyric
        // cannot race with the user's later Apply action.
        isResolvingScrapeTarget = true
        Task { @MainActor in
            defer { isResolvingScrapeTarget = false }
            let canonical = AppServices.shared.appleMusicLibrary.canonicalLibrarySong(for: displayedSong)
            if canonical.id != displayedSong.id {
                _ = await MetadataAssetStore.shared.preserveLyricsAlias(
                    fromSongID: displayedSong.id,
                    toSongID: canonical.id
                )
                guard player.currentSong?.id == displayedSong.id
                        || player.currentSong?.id == canonical.id else { return }
                player.adoptCanonicalAppleMusicSong(canonical, replacing: displayedSong.id)
            } else {
                guard player.currentSong?.id == canonical.id else { return }
            }
            scrapeTargetSong = canonical
        }
    }

    /// The empty lyrics state is an explicit one-tap automatic action. Keep it
    /// separate from the scrape icons, whose contract is to present the
    /// automatic/manual candidate sheet.
    private func startAutomaticLyricsScrape() {
        guard let displayedSong = player.currentSong,
              !isScrapeActionUnavailable else { return }

        scraperSettings.performSingleSongScrapeAction(
            from: .nowPlayingAutomaticLyrics,
            onProceed: { startAutomaticLyricsScrapeWithEnabledSource(displayedSong) },
            onRequireSource: { showNoScraperSourceAlert = true }
        )
    }

    private var canTranscribeCurrentSongAudio: Bool {
        guard let song = player.currentSong else { return false }
        return intelligence.isAudioTranscriptionConfigured
            && AIAudioTranscriptionPolicy.supportsInput(format: song.fileFormat)
            && song.sourceID != AppleMusicLibraryIdentity.sourceID
            && song.cueSheetPath == nil
            && (song.duration <= 0
                || song.duration <= AIAudioTranscriptionPolicy.maximumDuration)
    }

    private func openAudioTranscriptionEditor() {
        guard canTranscribeCurrentSongAudio, let song = player.currentSong else { return }
        lyricsEditorAutoStartsAudioTranscription = true
        lyricsEditorTargetSong = song
    }

    private func startAutomaticLyricsScrapeWithEnabledSource(_ displayedSong: Song) {
        // Invalidate an in-flight Tier 3 lookup for this same song before the
        // scraper starts. Otherwise that older request can finish after the
        // freshly scraped cache write and replace the new lyrics.
        lyricsLoadRevision &+= 1

        guard displayedSong.sourceID == AppleMusicLibraryIdentity.sourceID else {
            handleAutomaticScrapeStart(
                scraperService.startSingleScrape(song: displayedSong, in: library)
            )
            return
        }

        isResolvingScrapeTarget = true
        Task { @MainActor in
            defer { isResolvingScrapeTarget = false }
            let song = AppServices.shared.appleMusicLibrary.canonicalLibrarySong(for: displayedSong)
            if song.id != displayedSong.id {
                _ = await MetadataAssetStore.shared.preserveLyricsAlias(
                    fromSongID: displayedSong.id,
                    toSongID: song.id
                )
                if player.currentSong?.id == displayedSong.id
                    || player.currentSong?.id == song.id {
                    player.adoptCanonicalAppleMusicSong(song, replacing: displayedSong.id)
                }
            }
            handleAutomaticScrapeStart(
                scraperService.startOnlineLyricsOnlyScrape(song: song, in: library)
            )
        }
    }

    private func handleAutomaticScrapeStart(
        _ result: MusicScraperService.SingleScrapeStartResult
    ) {
        switch result {
        case .started, .joined:
            break
        case .busy:
            scrapeAlertMessage = String(localized: "intent_scrape_busy")
        case .noScraperSource:
            showNoScraperSourceAlert = true
        }
    }

    private func consumeAutomaticScrapeCompletion() {
        guard let songID = player.currentSong?.id,
              let completion = scraperService.consumeSingleScrapeCompletion(
                songID: songID,
                purposes: [.metadataApply, .lyricsApply]
              ) else { return }

        guard let result = completion.result else {
            scrapeAlertMessage = String(localized: "scrape_song_failed")
            return
        }

        let updatedSong = result.song
        CachedArtworkView.invalidateCache(for: updatedSong.id)
        if let oldRef = result.originalSong.coverArtFileName {
            CachedArtworkView.invalidateCache(for: oldRef)
        }
        player.syncSongMetadata(updatedSong)
        player.forceRefreshNowPlayingArtwork()

        if player.currentSong?.id == updatedSong.id {
            if let scrapedLyrics = result.lyrics, !scrapedLyrics.isEmpty {
                lyricsLoadRevision &+= 1
                setLyrics(scrapedLyrics)
            } else {
                Task { await loadLyrics() }
            }
        }
        scrapeAlertMessage = automaticScrapeSummary(
            original: result.originalSong,
            updated: updatedSong,
            coverFound: result.coverData != nil,
            lyricsFound: result.lyrics?.isEmpty == false,
            lyricsOnly: completion.activity.key.purpose == .lyricsApply
        )
    }

    /// The empty-lyrics button applies results immediately, so its completion
    /// alert must describe every tier instead of treating lyrics as the sole
    /// success signal. The regular scrape sheet already provides a detailed
    /// before/after preview; this is the compact equivalent for one-tap use.
    private func automaticScrapeSummary(
        original: Song,
        updated: Song,
        coverFound: Bool,
        lyricsFound: Bool,
        lyricsOnly: Bool
    ) -> String {
        let lyricsStatus = lyricsFound
            ? String(localized: "lyrics_found")
            : String(localized: "no_results")
        let accuracyNotice = String(localized: "scrape_accuracy_notice")
        if lyricsOnly {
            return [
                "\(String(localized: "lyrics_word")): \(lyricsStatus)",
                accuracyNotice,
            ].joined(separator: "\n\n")
        }

        var metadataChanges: [String] = []
        if original.title != updated.title {
            metadataChanges.append(String(localized: "title_changed"))
        }
        if original.artistName != updated.artistName {
            metadataChanges.append(String(localized: "artist_changed"))
        }
        if original.albumTitle != updated.albumTitle {
            metadataChanges.append(String(localized: "album_changed"))
        }
        let otherMetadataChanged = original.year != updated.year
            || original.genre != updated.genre
            || original.trackNumber != updated.trackNumber
            || original.discNumber != updated.discNumber
        if metadataChanges.isEmpty, otherMetadataChanged {
            metadataChanges.append(String(localized: "scrape_metadata_updated"))
        }

        let metadataStatus = metadataChanges.isEmpty
            ? String(localized: "unchanged")
            : metadataChanges.joined(separator: " · ")
        let coverStatus = coverFound
            ? String(localized: "cover_found")
            : String(localized: "no_results")

        return [
            "\(String(localized: "metadata")): \(metadataStatus)",
            "\(String(localized: "cover")): \(coverStatus)",
            "\(String(localized: "lyrics_word")): \(lyricsStatus)",
            "",
            accuracyNotice,
        ].joined(separator: "\n")
    }

    private func fmt(_ t: TimeInterval) -> String {
        t.formattedDuration
    }
}

struct MusicVideoFullScreenView: View {
    let player: AVPlayer
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            MusicVideoSurface(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
            .padding(.trailing, 24)
            .accessibilityLabel(Text("close"))
        }
        #if os(iOS)
        .statusBarHidden(true)
        .onAppear {
            MusicVideoOrientationController.enterLandscape()
        }
        #endif
    }
}

struct MusicVideoSurface: View {
    let player: AVPlayer

    var body: some View {
        PlatformMusicVideoSurface(player: player)
            .id(ObjectIdentifier(player))
    }
}

#if os(iOS)
/// Uses the public scene-geometry API to make MV fullscreen behave like a video
/// player on iPhone. The previous orientation is restored when the cover closes,
/// so the rest of the app does not get stranded in landscape.
@MainActor
private enum MusicVideoOrientationController {
    private static var restoreMask: UIInterfaceOrientationMask?

    static func enterLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = foregroundWindowScene else { return }

        if restoreMask == nil {
            restoreMask = mask(for: scene.interfaceOrientation)
        }
        request([.landscapeLeft, .landscapeRight], in: scene)
    }

    static func enterPortrait() {
        guard let scene = foregroundWindowScene else { return }
        request(.portrait, in: scene)
    }

    static func restorePreviousOrientation() {
        guard let restoreMask,
              UIDevice.current.userInterfaceIdiom == .phone,
              let scene = foregroundWindowScene else { return }
        self.restoreMask = nil
        request(restoreMask, in: scene)
    }

    private static var foregroundWindowScene: UIWindowScene? {
        let applicationScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter {
                $0.activationState == .foregroundActive
                    && $0.session.role == .windowApplication
            }
        // CarPlay and external-display scenes can be foreground-active at the
        // same time as the phone. Only the main application scene may receive
        // phone orientation requests; prefer its key window when available.
        return applicationScenes.first { $0.keyWindow != nil }
            ?? applicationScenes.first
    }

    private static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    private static func request(_ orientations: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            plog("⚠️ MV orientation request failed: \(error.localizedDescription)")
        }
    }
}

private struct PlatformMusicVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> MusicVideoLayerView {
        let view = MusicVideoLayerView()
        view.setPlayer(player)
        return view
    }

    func updateUIView(_ uiView: MusicVideoLayerView, context: Context) {
        uiView.setPlayer(player)
    }
}

private final class MusicVideoLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var currentPlayer: AVPlayer?

    var playerLayer: AVPlayerLayer? {
        layer as? AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer?.videoGravity = .resizeAspect
        backgroundColor = .black
        observeApplicationState()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func setPlayer(_ player: AVPlayer) {
        currentPlayer = player
        playerLayer?.player = UIApplication.shared.applicationState == .background ? nil : player
    }

    private func observeApplicationState() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground() {
        playerLayer?.player = nil
    }

    @objc private func applicationWillEnterForeground() {
        playerLayer?.player = currentPlayer
    }
}
#elseif os(macOS)
private struct PlatformMusicVideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> MusicVideoLayerView {
        let view = MusicVideoLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: MusicVideoLayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

private final class MusicVideoLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif

// MARK: - Custom Progress Slider (thin, no thumb)

struct ProgressSlider: View {
    let value: TimeInterval
    let total: TimeInterval
    let fillTint: Color?
    let onSeek: (TimeInterval) -> Void

    init(
        value: TimeInterval,
        total: TimeInterval,
        fillTint: Color? = nil,
        onSeek: @escaping (TimeInterval) -> Void
    ) {
        self.value = value
        self.total = total
        self.fillTint = fillTint
        self.onSeek = onSeek
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(ThemeService.self) private var theme

    @State private var isDragging = false
    @State private var dragValue: TimeInterval?

    private var safeTotal: TimeInterval { total.sanitizedDuration }
    private var displayValue: TimeInterval { (dragValue ?? value).sanitizedDuration }
    private var progress: CGFloat {
        guard safeTotal > 0 else { return 0 }
        let fraction = displayValue / safeTotal
        guard fraction.isFinite else { return 0 }
        return CGFloat(max(0, min(1, fraction)))
    }

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var fillColor: Color {
        if let fillTint { return fillTint }
        guard theme.colorID != "default" else { return appearance.primary }
        return appearance.isLight ? theme.darkAccent : theme.accentColor
    }

    private func seekValue(for locationX: CGFloat, width: CGFloat) -> TimeInterval? {
        guard width > 0, safeTotal > 0 else { return nil }
        let fraction = locationX / width
        guard fraction.isFinite else { return nil }
        return Double(max(0, min(1, fraction))) * safeTotal
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = isDragging ? 8 : 5

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(appearance.track)
                    .frame(height: trackHeight)

                // Filled track
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(0, min(width, width * progress)), height: trackHeight)
            }
            .frame(height: 20) // tap area
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        dragValue = seekValue(for: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        if let seekTime = seekValue(for: gesture.location.x, width: width) {
                            onSeek(seekTime)
                        }
                        dragValue = nil
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Volume Slider (thin, matching ProgressSlider style)

#if os(iOS)
/// iOS exposes output volume as read-only on `AVAudioSession`; `MPVolumeView`
/// is the supported interactive control. Its slider observes hardware-button,
/// Control Center, Bluetooth and AirPlay volume changes, so the value rendered
/// here always describes the route that is actually producing sound. This also
/// works for MusicKit playback, which bypasses Primuse's `AVAudioEngine`.
struct SystemVolumeSlider: UIViewRepresentable {
    static let compactHeight: CGFloat = 24
    static let verticalOffset: CGFloat = 1.5

    final class Coordinator {
        var styleKey: StyleKey?
    }

    struct StyleKey: Equatable {
        let isLight: Bool
        let usesIncreasedContrast: Bool
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        UIView.performWithoutAnimation {
            view.showsVolumeSlider = true
            // The row owns the compact height, while MPVolumeView remains free
            // to lay out its private slider hierarchy. Forcing the internal
            // UISlider's frame can make the track disappear on newer iOS.
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            styleSlider(in: view)
            view.layoutIfNeeded()
        }
        context.coordinator.styleKey = currentStyleKey
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        let styleKey = currentStyleKey
        guard context.coordinator.styleKey != styleKey || findSlider(in: uiView) == nil else {
            return
        }
        UIView.performWithoutAnimation {
            styleSlider(in: uiView)
            uiView.setNeedsLayout()
            uiView.layoutIfNeeded()
        }
        context.coordinator.styleKey = styleKey
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MPVolumeView,
        context: Context
    ) -> CGSize? {
        // SwiftUI first asks an HStack child for an unspecified ideal width.
        // Returning no intrinsic width here collapsed the actual UIKit view to
        // zero even though the outer `.frame(maxWidth: .infinity)` still filled
        // the row, leaving only the speaker icons visible.
        let intrinsicWidth = uiView.intrinsicContentSize.width
        let width = proposal.width ?? max(intrinsicWidth, 1)
        return CGSize(width: width, height: Self.compactHeight)
    }

    private func styleSlider(in volumeView: MPVolumeView) {
        volumeView.backgroundColor = .clear
        volumeView.subviews
            .compactMap { $0 as? UIButton }
            .forEach { $0.isHidden = true }

        guard let slider = findSlider(in: volumeView) else {
            return
        }
        let foreground = playerUIColor
        slider.minimumTrackTintColor = foreground
        slider.maximumTrackTintColor = foreground.withAlphaComponent(
            colorSchemeContrast == .increased ? 0.30 : 0.20
        )
        slider.thumbTintColor = foreground
        slider.setThumbImage(thumbImage(diameter: 12, color: foreground), for: .normal)
        slider.setThumbImage(thumbImage(diameter: 14, color: foreground), for: .highlighted)
        slider.accessibilityLabel = String(localized: "volume")
    }

    private var playerUIColor: UIColor {
        colorScheme == .light
            ? UIColor.black.withAlphaComponent(colorSchemeContrast == .increased ? 0.96 : 0.88)
            : UIColor.white
    }

    private var currentStyleKey: StyleKey {
        StyleKey(
            isLight: colorScheme == .light,
            usesIncreasedContrast: colorSchemeContrast == .increased
        )
    }

    private func thumbImage(diameter: CGFloat, color: UIColor) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider {
            return slider
        }
        for subview in view.subviews {
            if let slider = findSlider(in: subview) {
                return slider
            }
        }
        return nil
    }
}
#endif

struct VolumeSlider: View {
    @Binding var value: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var isDragging = false
    @State private var localValue: Double?

    private var displayValue: Double { localValue ?? value }
    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = CGFloat(max(0, min(1, displayValue)))
            let trackHeight: CGFloat = isDragging ? 8 : 5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(appearance.track)
                    .frame(height: trackHeight)

                Capsule()
                    .fill(appearance.primary)
                    .frame(width: max(0, min(width, width * progress)), height: trackHeight)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        localValue = Double(max(0, min(1, gesture.location.x / width)))
                        value = localValue!
                    }
                    .onEnded { _ in
                        localValue = nil
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Song Info Sheet

struct SongInfoSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var showSimilarSongs = false
    private let history = PlayHistoryStore.shared

    private var playbackStats: PlayHistoryStore.SongPlaybackStats {
        history.playbackStats(forSongID: song.id)
    }

    private var sourceName: String? {
        sourcesStore.source(id: song.sourceID)?.name
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        legacyBody
        #endif
    }

    private var legacyBody: some View {
        NavigationStack {
            List {
                infoRow(String(localized: "title_label"), song.title)
                if let artist = library.artistDisplayName(for: song) {
                    infoRow(String(localized: "artist_label"), artist)
                }
                if let album = song.albumTitle { infoRow(String(localized: "album_label"), album) }
                if let genre = song.genre { infoRow(String(localized: "genre_label"), genre) }
                if let year = song.year { infoRow(String(localized: "year_label"), "\(year)") }
                if let disc = song.discNumber { infoRow(String(localized: "disc_label"), "\(disc)") }
                if let track = song.trackNumber { infoRow(String(localized: "track_label"), "\(track)") }

                Section(String(localized: "playback_info")) {
                    infoRow(String(localized: "stats_play_count"), playbackStats.playCount.formatted())
                    infoRow(
                        String(localized: "last_played_label"),
                        playbackStats.lastPlayedAt?.formatted(date: .abbreviated, time: .shortened)
                            ?? String(localized: "no_recorded_playback")
                    )
                    Text(playbackHistoryNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section(String(localized: "library_info")) {
                    infoRow(String(localized: "date_added_label"), song.dateAdded.formatted(date: .long, time: .omitted))
                    if let lastModified = song.lastModified {
                        infoRow(String(localized: "last_modified_label"), lastModified.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let sourceName {
                        infoRow(String(localized: "source_label"), sourceName)
                    }
                }

                Section(String(localized: "technical_info")) {
                    infoRow(String(localized: "format_label"), song.fileFormat.displayName)
                    if let quality = song.qualitySpecText {
                        infoRow(String(localized: "audio_quality_label"), quality)
                    }
                    if let bitRate = song.formattedBitRate {
                        infoRow(String(localized: "songs_column_bitrate"), bitRate)
                    }
                    if let fileSize = formattedFileSize {
                        infoRow(String(localized: "file_size_label"), fileSize)
                    }
                    infoRow(String(localized: "duration_label"), formatDuration(song.duration))
                }

                Section {
                    Button {
                        showSimilarSongs = true
                    } label: {
                        Label(String(localized: "similar_songs"), systemImage: "sparkles")
                    }
                }
            }
            .navigationTitle(String(localized: "song_info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showSimilarSongs) {
                SimilarSongsSheet(seed: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 120,
                    cornerRadius: 8,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .shadow(color: .black.opacity(0.20), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text("song_info")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(PMColor.textFaint)
                    Text(song.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(2)
                    Text(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                        .font(.system(size: 13))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                    Text(song.albumTitle ?? "—")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                PMRoundBtn(icon: "xmark", size: 26, iconSize: 11, style: .glass,
                           help: "done") {
                    dismiss()
                }
            }
            .padding(22)
            .background(PMColor.card.opacity(0.54))

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [
                        GridItem(.fixed(120), spacing: 18, alignment: .leading),
                        GridItem(.flexible(), spacing: 18, alignment: .leading),
                    ], alignment: .leading, spacing: 8) {
                        ForEach(macInfoRows, id: \.label) { row in
                            Text(row.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(PMColor.textMuted)
                            Text(row.value)
                                .font(row.monospace
                                      ? .system(size: 12.5, design: .monospaced)
                                      : .system(size: 12.5))
                                .foregroundStyle(PMColor.text)
                                .lineLimit(row.monospace ? 3 : 1)
                                .textSelection(.enabled)
                        }
                    }
                    Text(playbackHistoryNote)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Button {
                    showSimilarSongs = true
                } label: {
                    Label(String(localized: "similar_songs"), systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(String(localized: "done")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.brand, in: .rect(cornerRadius: 6))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 620)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PMColor.bg.opacity(0.84))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .similarSongsPanel(isPresented: $showSimilarSongs, seed: song)
    }

    private var macInfoRows: [(label: String, value: String, monospace: Bool)] {
        var rows: [(String, String, Bool)] = [
            (String(localized: "title_label"), song.title, false),
        ]
        if let artist = library.artistDisplayName(for: song) {
            rows.append((String(localized: "artist_label"), artist, false))
        }
        if let album = song.albumTitle { rows.append((String(localized: "album_label"), album, false)) }
        if let genre = song.genre { rows.append((String(localized: "genre_label"), genre, false)) }
        if let year = song.year { rows.append((String(localized: "year_label"), "\(year)", false)) }
        if let disc = song.discNumber { rows.append((String(localized: "disc_label"), "\(disc)", false)) }
        if let track = song.trackNumber { rows.append((String(localized: "track_label"), "\(track)", false)) }
        rows.append((String(localized: "stats_play_count"), playbackStats.playCount.formatted(), false))
        rows.append((String(localized: "last_played_label"), playbackStats.lastPlayedAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "no_recorded_playback"), false))
        rows.append((String(localized: "date_added_label"), song.dateAdded.formatted(date: .long, time: .omitted), false))
        if let lastModified = song.lastModified {
            rows.append((String(localized: "last_modified_label"), lastModified.formatted(date: .abbreviated, time: .shortened), false))
        }
        rows.append((String(localized: "format_label"), song.fileFormat.displayName, false))
        if let quality = song.qualitySpecText {
            rows.append((String(localized: "audio_quality_label"), quality, false))
        }
        if let bitRate = song.formattedBitRate {
            rows.append((String(localized: "songs_column_bitrate"), bitRate, false))
        }
        if let fileSize = formattedFileSize {
            rows.append((String(localized: "file_size_label"), fileSize, false))
        }
        rows.append((String(localized: "duration_label"), formatDuration(song.duration), false))
        if let sourceName {
            rows.append((String(localized: "source_label"), sourceName, false))
        }
        rows.append((String(localized: "file_location_label"), song.filePath, true))
        return rows.map { ($0.0, $0.1, $0.2) }
    }
    #endif

    private var playbackHistoryNote: String {
        String(format: String(localized: "playback_history_note"),
            Int(PlayHistoryStore.recordedThresholdSec),
            PlayHistoryStore.maxRetainedEntries)
    }

    private var formattedFileSize: String? {
        guard song.fileSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        t.formattedDuration
    }
}

// MARK: - Add to Playlist Sheet

struct AddToPlaylistSheet: View {
    let song: Song
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    private var editablePlaylists: [Playlist] {
        library.playlists.filter { isEditablePlaylist($0.id) }
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        legacyBody
        #endif
    }

    private var legacyBody: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Label(String(localized: "new_playlist"), systemImage: "plus.circle.fill")
                    }
                }

                Section(String(localized: "playlists_title")) {
                    if editablePlaylists.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "no_playlists"), systemImage: "music.note.list")
                        }
                    } else {
                        ForEach(editablePlaylists) { playlist in
                            playlistRow(playlist: playlist)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "add_to_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .alert(String(localized: "new_playlist"), isPresented: $showNewPlaylist) {
                TextField(String(localized: "playlist_name"), text: $newPlaylistName)
                Button(String(localized: "cancel"), role: .cancel) { newPlaylistName = "" }
                Button(String(localized: "create")) {
                    guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let pl = library.createPlaylist(name: newPlaylistName)
                    library.add(songID: song.id, toPlaylist: pl.id)
                    newPlaylistName = ""
                }
            }
        }
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("add_to_playlist")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "\(song.title) · \(library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                PMRoundBtn(icon: "xmark", size: 24, iconSize: 10.5, style: .plain,
                           help: "cancel") { dismiss() }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            Button {
                showNewPlaylist = true
            } label: {
                Label(String(localized: "new_playlist"), systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.brand)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    if editablePlaylists.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "no_playlists"), systemImage: "music.note.list")
                        }
                        .padding(.vertical, 48)
                    } else {
                        ForEach(editablePlaylists) { playlist in
                            macPlaylistRow(playlist)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                Spacer()
                Button(String(localized: "cancel")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                Button(String(localized: "done")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 26)
                    .background(PMColor.brand, in: .rect(cornerRadius: 5))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 380, height: 480)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PMColor.bg.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .alert(String(localized: "new_playlist"), isPresented: $showNewPlaylist) {
            TextField(String(localized: "playlist_name"), text: $newPlaylistName)
            Button(String(localized: "cancel"), role: .cancel) { newPlaylistName = "" }
            Button(String(localized: "create")) {
                guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                let pl = library.createPlaylist(name: newPlaylistName)
                library.add(songID: song.id, toPlaylist: pl.id)
                newPlaylistName = ""
            }
        }
    }

    private func macPlaylistRow(_ playlist: Playlist) -> some View {
        let isAdded = library.contains(songID: song.id, inPlaylist: playlist.id)
        let count = library.songs(forPlaylist: playlist.id).count

        return Button {
            guard isEditablePlaylist(playlist.id) else { return }
            if isAdded {
                library.remove(songID: song.id, fromPlaylist: playlist.id)
            } else {
                library.add(songID: song.id, toPlaylist: playlist.id)
            }
        } label: {
            HStack(spacing: 10) {
                PlaylistArtworkView(playlist: playlist, size: 32, cornerRadius: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text("\(count) \(String(localized: "songs_count"))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                }

                Spacer()

                if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .pmRowBackground(selected: isAdded, cornerRadius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    @ViewBuilder
    private func playlistRow(playlist: Playlist) -> some View {
        let isAdded = library.contains(songID: song.id, inPlaylist: playlist.id)
        Button {
            guard isEditablePlaylist(playlist.id) else { return }
            if isAdded {
                library.remove(songID: song.id, fromPlaylist: playlist.id)
            } else {
                library.add(songID: song.id, toPlaylist: playlist.id)
            }
        } label: {
            HStack {
                PlaylistArtworkView(playlist: playlist, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.body)
                    let count = library.songs(forPlaylist: playlist.id).count
                    Text("\(count) \(String(localized: "songs_count"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isAdded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isAdded ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func isEditablePlaylist(_ playlistID: String) -> Bool {
        !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID)
            && playlistID != MusicLibrary.likedSongsPlaylistID
    }
}

#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        applyAppearance(to: v)
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        applyAppearance(to: uiView)
    }

    private func applyAppearance(to view: AVRoutePickerView) {
        let foreground = colorScheme == .light
            ? UIColor.black.withAlphaComponent(colorSchemeContrast == .increased ? 0.96 : 0.88)
            : UIColor.white
        view.tintColor = foreground.withAlphaComponent(colorSchemeContrast == .increased ? 0.72 : 0.52)
        view.activeTintColor = foreground
    }
}
#else
/// macOS 上 AVRoutePickerView 是 NSView, tint / activeTint API 也不一样。
/// 但 NowPlayingView 的 iOS 全屏播放器 (含 AirPlay 按钮) 在 macOS 上不会出现
/// (Mac 用 MacNowPlayingView), 这里给一个能编译的占位空视图, 避免 import
/// 链断开。真用到再走 AVRoutePickerView (NSView) 适配。
struct AirPlayButton: View {
    var body: some View { Color.clear.frame(width: 44, height: 44) }
}
#endif

// MARK: - Stable native More menu

/// Only state that can legitimately change the native menu's contents. Playback
/// progress and lyric scroll state are intentionally absent, so their frequent
/// updates cannot invalidate an already-presented menu.
private struct NowPlayingMoreMenuSnapshot: Equatable {
    let songID: String?
    let hasSong: Bool
    let isScrapingCurrentSong: Bool
    let isAppleMusicMode: Bool
    let canDeleteSourceFile: Bool
    let appleMusicCatalogURL: URL?
    let showsLyricsPreferences: Bool
    let albumID: String?
    let artistID: String?
    let canOpenAlbum: Bool
    let canOpenArtist: Bool
    let shareText: String?
    let castingRendererName: String?
    let isSleepTimerActive: Bool
    let lyricsFontScale: Double
    let playbackRate: Float
    let isLyricsTranslationEnabled: Bool
    let colorScheme: ColorScheme
    let colorSchemeContrast: ColorSchemeContrast
}

/// Keeps the existing SwiftUI `Menu` interaction and visual design, while using
/// an equatable update boundary to stop unrelated parent updates from rebuilding
/// the menu hierarchy and resetting its internal scroll position.
private struct NowPlayingMoreMenu: View, @MainActor Equatable {
    let snapshot: NowPlayingMoreMenuSnapshot
    @Binding var lyricsFontScale: Double
    @Binding var playbackRate: Float
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    let immersiveChrome: Bool

    let onAddToPlaylist: () -> Void
    let onScrape: () -> Void
    let onShowSimilarSongs: () -> Void
    let onEditTags: () -> Void
    let onEditLyrics: () -> Void
    let onShowSongInfo: () -> Void
    let onOpenAlbum: () -> Void
    let onOpenArtist: () -> Void
    let onOpenInAppleMusic: () -> Void
    let onShowCastPicker: () -> Void
    let onToggleLyricsTranslation: () -> Void
    let onShowSleepTimer: () -> Void
    let onDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.immersiveChrome == rhs.immersiveChrome
    }

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(
            colorScheme: snapshot.colorScheme,
            contrast: snapshot.colorSchemeContrast
        )
    }

    var body: some View {
        Menu {
            Section {
                Button(action: onAddToPlaylist) {
                    Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                }
                .disabled(!snapshot.hasSong)

                Button(action: onScrape) {
                    Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                }
                .disabled(!snapshot.hasSong || snapshot.isScrapingCurrentSong)

                Button(action: onShowSimilarSongs) {
                    Label(String(localized: "similar_songs"), systemImage: "sparkles")
                }
                .disabled(!snapshot.hasSong)

                if !snapshot.isAppleMusicMode {
                    Button(action: onEditTags) {
                        Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                    }
                    .disabled(!snapshot.hasSong)

                    Button(action: onEditLyrics) {
                        Label(String(localized: "lyrics_editor_menu"), systemImage: "quote.bubble")
                    }
                    .disabled(!snapshot.hasSong)
                }
            }

            Section {
                Button(action: onShowSongInfo) {
                    Label(String(localized: "song_info"), systemImage: "info.circle")
                }
                .disabled(!snapshot.hasSong)

                if snapshot.canOpenAlbum {
                    Button(action: onOpenAlbum) {
                        Label(String(localized: "go_to_album"), systemImage: "square.stack")
                    }
                }

                if snapshot.canOpenArtist {
                    Button(action: onOpenArtist) {
                        Label(String(localized: "go_to_artist"), systemImage: "music.mic")
                    }
                }

                if snapshot.appleMusicCatalogURL != nil {
                    Button(action: onOpenInAppleMusic) {
                        Label(
                            String(localized: "apple_music_open_in_app"),
                            systemImage: "arrow.up.right.square"
                        )
                    }
                }

                if let shareText = snapshot.shareText {
                    ShareLink(item: shareText) {
                        Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section {
                Button(action: onShowCastPicker) {
                    if let rendererName = snapshot.castingRendererName {
                        Label(
                            String(
                                format: String(localized: "cast_casting_to_format"),
                                rendererName
                            ),
                            systemImage: "airplayaudio"
                        )
                    } else {
                        Label(String(localized: "cast_to_device"), systemImage: "airplayaudio")
                    }
                }
                .disabled(!snapshot.hasSong || snapshot.isAppleMusicMode)
            }

            if snapshot.showsLyricsPreferences {
                Section {
                    Picker(selection: $lyricsFontScale) {
                        Text("lyrics_font_small").tag(0.85)
                        Text("lyrics_font_medium").tag(1.0)
                        Text("lyrics_font_large").tag(1.2)
                        Text("lyrics_font_xlarge").tag(1.5)
                    } label: {
                        Label(String(localized: "lyrics_font_size"), systemImage: "textformat.size")
                    }
                    .pickerStyle(.menu)

                    Button(action: onToggleLyricsTranslation) {
                        Label(
                            snapshot.isLyricsTranslationEnabled
                                ? String(localized: "lyrics_translation_off")
                                : String(localized: "lyrics_translation_on"),
                            systemImage: snapshot.isLyricsTranslationEnabled
                                ? "character.bubble.fill"
                                : "character.bubble"
                        )
                    }
                }
            }

            Section {
                Toggle(isOn: $lyricsMotionEnabled) {
                    Label(
                        String(localized: "immersive_lyrics_motion_title"),
                        systemImage: "text.line.first.and.arrowtriangle.forward"
                    )
                }

                Button(action: onShowSleepTimer) {
                    Label(
                        snapshot.isSleepTimerActive
                            ? String(localized: "sleep_timer_active")
                            : String(localized: "sleep_timer"),
                        systemImage: snapshot.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz"
                    )
                }

                if !snapshot.isAppleMusicMode {
                    Picker(selection: $playbackRate) {
                        Text("0.5×").tag(Float(0.5))
                        Text("0.75×").tag(Float(0.75))
                        Text(String(localized: "playback_rate_normal")).tag(Float(1.0))
                        Text("1.25×").tag(Float(1.25))
                        Text("1.5×").tag(Float(1.5))
                        Text("1.75×").tag(Float(1.75))
                        Text("2.0×").tag(Float(2.0))
                    } label: {
                        Label(
                            snapshot.playbackRate == 1.0
                                ? String(localized: "playback_rate")
                                : String(
                                    format: "%@ %.2fx",
                                    String(localized: "playback_rate"),
                                    snapshot.playbackRate
                                ),
                            systemImage: "speedometer"
                        )
                    }
                    .pickerStyle(.menu)
                }
            }

            if snapshot.canDeleteSourceFile {
                Section {
                    Button(role: .destructive, action: onDelete) {
                        Label(String(localized: "delete_song"), systemImage: "trash")
                    }
                    .disabled(!snapshot.hasSong)
                }
            }
        } label: {
            if immersiveChrome {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(appearance.primary.opacity(0.88))
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                        Circle().fill(.black.opacity(0.16))
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.20), lineWidth: 0.8)
                    }
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(width: 38, height: 38)
                    .background(appearance.primary.opacity(0.065), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(appearance.primary.opacity(0.14), lineWidth: 0.75)
                    }
                    .frame(width: 44, height: 44)
            }
        }
    }
}

// MARK: - LyricsScrollView (隔离的歌词渲染子 view)

/// Reserves the largest footprint a lyric row can occupy while its render-layer
/// emphasis animates. `scaleEffect` deliberately does not affect SwiftUI layout;
/// without this stable envelope a wrapped active row can draw outside its
/// measured frame even though its layout never moved.
private struct LyricsScaleEnvelopeLayout: Layout {
    let maximumScale: CGFloat
    let horizontalAnchor: UnitPoint

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let childProposal = ProposedViewSize(width: proposal.width, height: nil)
        let childSize = subview.sizeThatFits(childProposal)
        return CGSize(
            width: proposal.width ?? childSize.width,
            height: childSize.height * max(1, maximumScale)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let childSize = subview.sizeThatFits(childProposal)
        subview.place(
            at: CGPoint(
                x: bounds.minX + bounds.width * horizontalAnchor.x,
                y: bounds.midY
            ),
            anchor: UnitPoint(x: horizontalAnchor.x, y: 0.5),
            proposal: ProposedViewSize(width: childSize.width, height: childSize.height)
        )
    }
}

/// 把歌词渲染抽出来作为独立 View,避免行切换 (`currentLineIndex` 变化) 让
/// 整个 NowPlayingView 的 body 重算,从而触发 SwiftUI Menu 内嵌的 Picker(.menu)
/// submenu 在父重算时被强制关闭(选字号弹框还没来得及选就消失)。
///
/// 通过把 currentLineIndex 等内部状态封装在子 view 里,行切换只让本 view 重算,
/// 父 view 的 Menu / sheet 不受影响。
private enum LyricsTranslationActivity: Equatable {
    case idle
    case intelligentLoading
    case intelligentCached
    case intelligentSuccess(provider: String, fallbackDepth: Int)
    case systemFallback
    case systemPreparationRequired
    case systemUnavailable
}

struct LyricsScrollView: View {
    let lyrics: [LyricLine]
    let lyricsWritingDirection: LyricWritingDirection
    let lyricsRevision: UInt
    let player: AudioPlayerService
    let songID: String?
    let isSceneActive: Bool
    let isScrapingCurrentSong: Bool
    let canTranscribeAudio: Bool
    let isScrapeActionUnavailable: Bool
    let onAutomaticScrape: () -> Void
    let onTranscribeAudio: () -> Void
    let onBackgroundTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @AppStorage(PlayerAppearancePreferences.lyricsAlignmentKey)
    private var lyricsAlignmentRawValue = PlayerLyricsAlignment.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.lyricsColorModeKey)
    private var lyricsColorModeRawValue = PlayerLyricsColorMode.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.customLyricsColorHexKey)
    private var customLyricsColorHex = PlayerAppearancePreferences.defaultCustomLyricsColorHex
    @AppStorage(PlayerAppearancePreferences.gradientLyricsStartColorHexKey)
    private var gradientLyricsStartColorHex = PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
    @AppStorage(PlayerAppearancePreferences.gradientLyricsEndColorHexKey)
    private var gradientLyricsEndColorHex = PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
    @AppStorage(PlayerAppearancePreferences.blursInactiveLyricsKey)
    private var blursInactiveLyrics = PlayerAppearancePreferences.blursInactiveLyricsByDefault
    @State private var lyricsPinchScale: CGFloat = 1.0
    @State private var isPinchingLyrics = false
    @State private var currentLineIndex = -1
    @State private var activeInterludeAfterLineIndex: Int? = nil
    @State private var visualPlaybackTime: TimeInterval = 0
    @State private var isRestoringVisualPosition = false
    @State private var isManuallyBrowsingLyrics = false
    /// Row taps and the surface tap are simultaneous gestures. Remember the
    /// row event briefly so tapping lyrics seeks only, while tapping unused
    /// space can switch the normal Now Playing surface back to artwork.
    @State private var lastLyricRowTapAt: Date = .distantPast

    // 用户手动拖动歌词时, 暂时冻结自动滚动 ── 否则刚拖到想看的位置, 下一帧
    // auto follow 又把视图拽回当前行, 等于不能浏览。lastUserScrollTime 静止
    // 超过 manualScrollGracePeriod 后恢复 auto follow。
    @State private var lastUserScrollTime: Date = .distantPast
    /// 歌词在手动浏览保护期结束时必须主动归位。旧实现只在歌词索引
    /// 下一次变化时尝试 scrollTo，遇到长句/间奏就会长期停在错误位置。
    @State private var lineAutoFollowResumeTask: Task<Void, Never>? = nil
    private static let manualScrollGracePeriod: TimeInterval = 3.0

    // Translation —— system translation framework。切歌只自动使用已安装且
    // 源语言明确的语言对；可能出现系统 UI 的准备流程必须由用户显式触发。
    @State private var translatedTextByLineID: [String: String] = [:]
    @State private var translationSettings = LyricsTranslationSettingsStore.shared
    @State private var translationActivity: LyricsTranslationActivity = .idle

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    /// Keep every row on one stable layout size. Current-line emphasis is a
    /// render-layer scale, so a takeover does not reflow the surrounding rows.
    private static let lyricsLayoutBaseSize: CGFloat = 26
    private static let lyricsHorizontalPadding: CGFloat = 24

    private var visualActivityPolicy: NowPlayingVisualActivityPolicy {
        NowPlayingVisualActivityPolicy(
            isSceneActive: isSceneActive,
            isPlaying: player.isPlaying,
            usesRealtimeSpectrum: false,
            reduceMotion: reduceMotion
        )
    }

    private var effectiveLyricsScale: Double {
        let combined = lyricsFontScale * Double(lyricsPinchScale)
        return min(max(combined, Self.lyricsMinScale), Self.lyricsMaxScale)
    }

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var hasWordLevelLyrics: Bool {
        lyrics.contains { $0.isWordLevel }
    }

    private var hasSynchronizedLyrics: Bool {
        lyrics.contains { $0.isSynchronized }
    }

    private var lyricsAlignment: PlayerLyricsAlignment {
        PlayerLyricsAlignment(rawValue: lyricsAlignmentRawValue) ?? .defaultValue
    }

    private var lyricsColorMode: PlayerLyricsColorMode {
        PlayerLyricsColorMode(rawValue: lyricsColorModeRawValue) ?? .defaultValue
    }

    private var lyricLayoutDirection: LayoutDirection {
        switch lyricsWritingDirection {
        case .natural:
            return inheritedLayoutDirection
        case .leftToRight:
            return .leftToRight
        case .rightToLeft:
            return .rightToLeft
        }
    }

    private var lyricsScaleAnchor: UnitPoint {
        lyricsAlignment.scaleAnchor(in: lyricLayoutDirection)
    }

    private func currentLyricStyle(opacity: Double = 1) -> AnyShapeStyle {
        let resolvedOpacity = min(max(opacity, 0), 1)
        switch lyricsColorMode {
        case .defaultColor:
            return AnyShapeStyle(appearance.primary.opacity(resolvedOpacity))
        case .custom:
            return AnyShapeStyle(
                lyricsColor(
                    from: customLyricsColorHex,
                    fallback: PlayerAppearancePreferences.defaultCustomLyricsColorHex
                )
                .opacity(resolvedOpacity)
            )
        case .gradient:
            let startPoint: UnitPoint = lyricLayoutDirection == .rightToLeft ? .trailing : .leading
            let endPoint: UnitPoint = lyricLayoutDirection == .rightToLeft ? .leading : .trailing
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        lyricsColor(
                            from: gradientLyricsStartColorHex,
                            fallback: PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
                        )
                        .opacity(resolvedOpacity),
                        lyricsColor(
                            from: gradientLyricsEndColorHex,
                            fallback: PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
                        )
                        .opacity(resolvedOpacity),
                    ],
                    startPoint: startPoint,
                    endPoint: endPoint
                )
            )
        }
    }

    private func lyricsColor(from storedHex: String, fallback: String) -> Color {
        Color(
            hex: PlayerAppearancePreferences.normalizedLyricsColorHex(
                storedHex,
                fallback: fallback
            )
        )
    }

    var body: some View {
        Group {
            if lyrics.isEmpty {
                emptyLyricsView
            } else if hasWordLevelLyrics {
                smoothWordLyricsView
            } else {
                lineLevelLyricsView
            }
        }
        .overlay(alignment: .topTrailing) {
            translationStatusBadge
                .padding(.top, 8)
                .padding(.trailing, 12)
        }
        .task(id: playbackFollowTaskIdentity) {
            guard hasSynchronizedLyrics else {
                currentLineIndex = -1
                activeInterludeAfterLineIndex = nil
                return
            }
            guard visualActivityPolicy.shouldPollLyrics else {
                updateCurrentLine(disableAnimations: true)
                return
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      visualActivityPolicy.shouldPollLyrics else { break }
                updateCurrentLine()
            }
        }
        .onChange(of: player.currentTime) { _, _ in
            if hasSynchronizedLyrics, isSceneActive, !player.isPlaying {
                updateCurrentLine(disableAnimations: true)
            }
        }
        .onChange(of: isSceneActive) { _, isActive in
            if !isActive {
                lineAutoFollowResumeTask?.cancel()
                updateCurrentLine(disableAnimations: true)
            }
        }
        .onChange(of: songID) { _, _ in
            // 换歌后先等待新歌首句时间戳，再恢复高亮与自动滚动。
            currentLineIndex = -1
            activeInterludeAfterLineIndex = nil
            lastLyricRowTapAt = .distantPast
            lastUserScrollTime = .distantPast
            lyricsPinchScale = 1
            isPinchingLyrics = false
            lineAutoFollowResumeTask?.cancel()
        }
        .lyricsTranslationTaskIfAvailable(
            songID: songID,
            lyricsRevision: lyricsRevision,
            lyrics: lyrics,
            settings: translationSettings,
            translatedTextByLineID: $translatedTextByLineID,
            activity: $translationActivity
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { _ in
                    let eventTime = Date()
                    Task { @MainActor in
                        await Task.yield()
                        guard LyricsBackgroundTapPolicy.shouldHandle(
                            hasLyrics: !lyrics.isEmpty,
                            isPinching: isPinchingLyrics,
                            rowTapTimeDistance: lastLyricRowTapAt.timeIntervalSince(eventTime)
                        ) else { return }
                        onBackgroundTap()
                    }
                }
        )
    }

    @ViewBuilder
    private var translationStatusBadge: some View {
        switch translationActivity {
        case .idle:
            EmptyView()
        case .intelligentLoading:
            Label("lyrics_translation_ai_loading", systemImage: "sparkles")
                .lyricsTranslationStatusBadgeStyle()
        case .intelligentCached:
            Label("lyrics_translation_ai_cached", systemImage: "checkmark.circle.fill")
                .lyricsTranslationStatusBadgeStyle()
        case .intelligentSuccess(let provider, let fallbackDepth):
            Label(
                String(
                    format: String(localized: fallbackDepth > 0
                                   ? "lyrics_translation_ai_fallback_success_format"
                                   : "lyrics_translation_ai_success_format"),
                    provider.isEmpty ? String(localized: "ai_provider_default_name") : provider
                ),
                systemImage: fallbackDepth > 0
                    ? "arrow.trianglehead.branch" : "checkmark.circle.fill"
            )
            .lyricsTranslationStatusBadgeStyle()
        case .systemFallback:
            Label("lyrics_translation_ai_system_fallback", systemImage: "arrow.uturn.backward.circle")
                .lyricsTranslationStatusBadgeStyle()
        case .systemPreparationRequired:
            Button {
                lastLyricRowTapAt = Date()
                translationSettings.requestSystemTranslationPreparation()
            } label: {
                Label(String(localized: "Translate Lyrics"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .lyricsTranslationStatusBadgeStyle()
        case .systemUnavailable:
            Label("lyrics_translation_unavailable", systemImage: "exclamationmark.triangle")
                .lyricsTranslationStatusBadgeStyle()
        }
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            Text("no_lyrics")
                .font(.title3)
                .foregroundStyle(appearance.faint)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { emptyLyricsActions }
                VStack(spacing: 10) { emptyLyricsActions }
            }
            if canTranscribeAudio {
                Text("ai_audio_transcription_now_playing_detail")
                    .font(.caption2)
                    .foregroundStyle(appearance.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var emptyLyricsActions: some View {
        Button { onAutomaticScrape() } label: {
            HStack(spacing: 7) {
                if isScrapingCurrentSong {
                    ProgressView()
                        .controlSize(.small)
                        .tint(appearance.primary)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "wand.and.stars")
                        .transition(.scale.combined(with: .opacity))
                }
                Text("scrape_song")
            }
            .font(.subheadline)
            .animation(.smooth(duration: 0.2, extraBounce: 0), value: isScrapingCurrentSong)
        }
        .buttonStyle(.bordered)
        .tint(appearance.primary)
        .disabled(isScrapeActionUnavailable)

        if canTranscribeAudio {
            Button { onTranscribeAudio() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "waveform.badge.mic")
                    Text("ai_audio_transcription_action")
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(appearance.primary)
            .disabled(isScrapeActionUnavailable)
        }
    }

    private var lineLevelLyricsView: some View {
        GeometryReader { geo in
            let layoutWidth = lyricLayoutWidth(in: geo.size.width)
            let textWidth = lyricTextWidth(in: geo.size.width)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Give the first and last rows enough physical room to
                        // reach the same visual anchor as every middle row.
                        Spacer().frame(height: geo.size.height * Self.lyricsVisualAnchor)

                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            let activity = lineLevelRowVisualActivity(index: index)
                            LyricsScaleEnvelopeLayout(
                                maximumScale: Self.lyricsActiveVisualScale,
                                horizontalAnchor: lyricsScaleAnchor
                            ) {
                                lyricsRow(
                                    line: line,
                                    index: index,
                                    dimmedByAmbient: true,
                                    availableWidth: textWidth,
                                    visualScale: CGFloat(activity.scale)
                                )
                            }
                                .id(LyricsScrollTarget.line(id: line.id))
                                .opacity(activity.opacity)
                                .blur(radius: inactiveLyricBlurRadius(for: index))
                                // Match the word-level path: highlight, scale,
                                // and scroll all travel on one curve instead of
                                // snapping the row style before scrolling it.
                                .animation(
                                    .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
                                    value: currentLineIndex
                                )
                                .padding(.vertical, 2)

                            if LyricPlaybackPositionPolicy.hasLongInterlude(
                                afterLine: index,
                                in: lyrics
                            ) {
                                interludeMarker(afterLine: index)
                                    .id(LyricsScrollTarget.interlude(afterLineID: line.id))
                            }
                        }

                        Spacer().frame(height: geo.size.height * (1 - Self.lyricsVisualAnchor))
                    }
                    .frame(width: layoutWidth, alignment: .topLeading)
                    .padding(.horizontal, Self.lyricsHorizontalPadding)
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            isPinchingLyrics = true
                            lyricsPinchScale = value.magnification
                        }
                        .onEnded { value in
                            let next = lyricsFontScale * Double(value.magnification)
                            lyricsFontScale = min(max(next, Self.lyricsMinScale), Self.lyricsMaxScale)
                            lyricsPinchScale = 1.0
                            isPinchingLyrics = false
                        }
                )
                // 监听任意拖动手势 → 刷新 lastUserScrollTime, 让 onChange 里的 auto
                // scrollTo 暂时退让, 用户能往上往下浏览其他歌词。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in
                            beginLineManualBrowsing()
                        }
                        .onEnded { _ in
                            endLineManualBrowsing(proxy: proxy)
                        }
                )

                // DragGesture.onEnded describes the finger, not the actual
                // ScrollView. Momentum can continue afterwards, and an
                // interrupted gesture may never deliver onEnded. Observe the
                // native scroll phase so auto-follow always resumes from the
                // latest lyric after scrolling really becomes idle.
                .onScrollPhaseChange { oldPhase, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        beginLineManualBrowsing()
                    case .idle:
                        if oldPhase == .tracking
                            || oldPhase == .interacting
                            || oldPhase == .decelerating {
                            endLineManualBrowsing(proxy: proxy)
                        }
                    case .animating:
                        // Programmatic scrollTo animation is auto-follow, not
                        // a reason to enter manual browsing mode.
                        break
                    }
                }
                .onChange(of: playbackScrollTarget) { _, target in
                    guard isSceneActive,
                          !isRestoringVisualPosition,
                          !isPinchingLyrics,
                          let target else { return }
                    // 用户手动滚动后 manualScrollGracePeriod 内不要把视图拽回当前行,
                    // 否则刚拖到想看的位置又被自动 scrollTo 弹回, 等同不能浏览。
                    guard Date().timeIntervalSince(lastUserScrollTime) >= Self.manualScrollGracePeriod
                    else { return }
                    scroll(to: target, proxy: proxy, animated: true)
                }
                .onChange(of: lyricsFontScale) { _, _ in
                    scheduleLineAutoFollowResume(proxy: proxy, delay: 0)
                }
                .task(id: lineLevelScrollIdentity) {
                    guard isSceneActive else { return }
                    isRestoringVisualPosition = true
                    defer { isRestoringVisualPosition = false }
                    let target = updateCurrentLine(disableAnimations: true)
                    // Publish the active row first, then allow SwiftUI to lay
                    // out that state before issuing the initial scroll request.
                    await Task.yield()
                    guard !Task.isCancelled, let target else { return }
                    scroll(to: target, proxy: proxy, animated: false)
                }
                .onDisappear {
                    lineAutoFollowResumeTask?.cancel()
                    isManuallyBrowsingLyrics = false
                }
            }
        }
        .clipped()
        .mask(lyricsViewportFadeMask)
    }

    private var smoothWordLyricsView: some View {
        GeometryReader { geo in
            let layoutWidth = lyricLayoutWidth(in: geo.size.width)
            let textWidth = lyricTextWidth(in: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Spacer().frame(height: geo.size.height * Self.lyricsVisualAnchor)

                        wordLevelBadge

                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            let activity = rowVisualActivity(index: index)
                            LyricsScaleEnvelopeLayout(
                                maximumScale: Self.lyricsActiveVisualScale,
                                horizontalAnchor: lyricsScaleAnchor
                            ) {
                                lyricsRow(
                                    line: line,
                                    index: index,
                                    dimmedByAmbient: true,
                                    availableWidth: textWidth,
                                    visualScale: CGFloat(activity.scale)
                                )
                            }
                            .id(LyricsScrollTarget.line(id: line.id))
                            .opacity(activity.opacity)
                            .blur(radius: inactiveLyricBlurRadius(for: index))
                            .animation(
                                .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
                                value: currentLineIndex
                            )
                            .padding(.vertical, 2)

                            if LyricPlaybackPositionPolicy.hasLongInterlude(
                                afterLine: index,
                                in: lyrics
                            ) {
                                interludeMarker(afterLine: index)
                                    .id(LyricsScrollTarget.interlude(afterLineID: line.id))
                            }
                        }

                        Spacer().frame(height: geo.size.height * (1 - Self.lyricsVisualAnchor))
                    }
                    .frame(width: layoutWidth, alignment: .topLeading)
                    .padding(.horizontal, Self.lyricsHorizontalPadding)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { _ in beginLineManualBrowsing() }
                        .onEnded { _ in endLineManualBrowsing(proxy: proxy) }
                )
                .onScrollPhaseChange { oldPhase, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        beginLineManualBrowsing()
                    case .idle:
                        if oldPhase == .tracking
                            || oldPhase == .interacting
                            || oldPhase == .decelerating {
                            endLineManualBrowsing(proxy: proxy)
                        }
                    case .animating:
                        break
                    }
                }
                .onChange(of: playbackScrollTarget) { _, target in
                    guard isSceneActive,
                          !isRestoringVisualPosition,
                          !isPinchingLyrics,
                          let target,
                          Date().timeIntervalSince(lastUserScrollTime) >= Self.manualScrollGracePeriod
                    else { return }
                    scroll(to: target, proxy: proxy, animated: true)
                }
                .onChange(of: lyricsFontScale) { _, _ in
                    scheduleLineAutoFollowResume(proxy: proxy, delay: 0)
                }
                .task(id: lyricsPresentationIdentity) {
                    guard isSceneActive else { return }
                    isRestoringVisualPosition = true
                    defer { isRestoringVisualPosition = false }
                    let target = updateCurrentLine(disableAnimations: true)
                    await Task.yield()
                    guard !Task.isCancelled, let target else { return }
                    scroll(to: target, proxy: proxy, animated: false)
                }
                .onDisappear {
                    lineAutoFollowResumeTask?.cancel()
                    isManuallyBrowsingLyrics = false
                }
            }
        }
        .clipped()
        .mask(lyricsViewportFadeMask)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    isPinchingLyrics = true
                    lyricsPinchScale = value.magnification
                }
                .onEnded { value in
                    let next = lyricsFontScale * Double(value.magnification)
                    lyricsFontScale = min(max(next, Self.lyricsMinScale), Self.lyricsMaxScale)
                    lyricsPinchScale = 1.0
                    isPinchingLyrics = false
                }
        )
    }

    private var lineLevelScrollIdentity: String {
        lyricsPresentationIdentity
    }

    private var lyricsPresentationIdentity: String {
        "\(songID ?? "")|\(lyricsRevision)|\(isSceneActive)"
    }

    private enum LyricsScrollTarget: Hashable {
        case line(id: String)
        case interlude(afterLineID: String)
    }

    private var playbackScrollTarget: LyricsScrollTarget? {
        if let index = activeInterludeAfterLineIndex,
           lyrics.indices.contains(index) {
            return .interlude(afterLineID: lyrics[index].id)
        }
        guard lyrics.indices.contains(currentLineIndex) else { return nil }
        return .line(id: lyrics[currentLineIndex].id)
    }

    private struct PlaybackFollowTaskIdentity: Hashable {
        let songID: String?
        let lyricsRevision: UInt
        let isPlaying: Bool
        let isSceneActive: Bool
        let reduceMotion: Bool
    }

    private var playbackFollowTaskIdentity: PlaybackFollowTaskIdentity {
        PlaybackFollowTaskIdentity(
            songID: songID,
            lyricsRevision: lyricsRevision,
            isPlaying: player.isPlaying,
            isSceneActive: isSceneActive,
            reduceMotion: reduceMotion
        )
    }

    private func beginLineManualBrowsing() {
        lineAutoFollowResumeTask?.cancel()
        lastUserScrollTime = Date()
        guard !isManuallyBrowsingLyrics else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            isManuallyBrowsingLyrics = true
        }
    }

    private func endLineManualBrowsing(proxy: ScrollViewProxy) {
        lastUserScrollTime = Date()
        scheduleLineAutoFollowResume(proxy: proxy)
    }

    private func scheduleLineAutoFollowResume(
        proxy: ScrollViewProxy,
        delay: TimeInterval = Self.manualScrollGracePeriod
    ) {
        lineAutoFollowResumeTask?.cancel()
        guard isSceneActive else { return }
        lineAutoFollowResumeTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled,
                  isSceneActive,
                  !isPinchingLyrics,
                  Date().timeIntervalSince(lastUserScrollTime) >= delay else { return }
            withAnimation(.smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0)) {
                isManuallyBrowsingLyrics = false
            }
            guard let target = playbackScrollTarget else { return }
            scroll(to: target, proxy: proxy, animated: true)
        }
    }

    private var lyricsViewportFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func scroll(
        to target: LyricsScrollTarget,
        proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let update = {
            proxy.scrollTo(
                target,
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

    private func interludeMarker(afterLine index: Int) -> some View {
        let isActive = activeInterludeAfterLineIndex == index
        return Image(systemName: "ellipsis")
            .font(.title3.weight(.semibold))
            .foregroundStyle(appearance.secondary)
            .symbolEffect(
                .variableColor.iterative,
                isActive: isActive && !reduceMotion
            )
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .opacity(isActive ? 0.9 : appearance.futureLyricOpacity * 0.65)
            .animation(.smooth(duration: 0.3, extraBounce: 0), value: isActive)
            .accessibilityHidden(true)
    }

    private var wordLevelBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption2)
            Text("lyrics_word_level_badge")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(appearance.secondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(appearance.primary.opacity(0.10)))
        .padding(.bottom, 4)
    }

    /// dimmedByAmbient: 统一动效模式调用时传 true ── 表明行整体明暗由外层
    /// opacity 接管, row 内部不要再按 isActive 离散切换颜色,否则跟外层
    /// .opacity multiply 会双重叠加 + 跳变。
    @ViewBuilder
    private func lyricsRow(
        line: LyricLine,
        index: Int,
        dimmedByAmbient: Bool = false,
        timelineTime: TimeInterval? = nil,
        availableWidth: CGFloat,
        visualScale: CGFloat = 1
    ) -> some View {
        let isActive = index == currentLineIndex
        let fontSize = Self.lyricsLayoutBaseSize * CGFloat(effectiveLyricsScale)
        // weight 在统一动效模式下固定 .semibold。active 行已有 scale + opacity
        // 强调, weight 瞬时跳变只会让切句增加视觉颗粒感。
        let weight: Font.Weight = dimmedByAmbient ? .semibold : (isActive ? .bold : .semibold)
        let alignment = lyricsAlignment.horizontalAlignment
        let frameAlignment = lyricsAlignment.frameAlignment

        VStack(alignment: alignment, spacing: 4) {
            singleLineContent(
                line: line,
                isActive: isActive,
                index: index,
                fontSize: fontSize,
                weight: weight,
                textAlignment: lyricsAlignment.textAlignment,
                dimmedByAmbient: dimmedByAmbient,
                timelineTime: timelineTime
            )
                .contentShape(Rectangle())
                .onTapGesture { seekToLyricLine(line) }
                .frame(width: availableWidth, alignment: frameAlignment)

            // 歌词翻译 — 在原文下面以略小的字号显示, 仅当启用且当前行有翻译。
            // 字号取原文的 0.65 + medium weight, 视觉上是 secondary。
            if let translated = translatedTextByLineID[line.id], !translated.isEmpty {
                Text(translated)
                    .font(.system(size: fontSize * 0.65, weight: .medium))
                    .foregroundStyle(
                        dimmedByAmbient
                            ? appearance.secondary
                            : isActive ? appearance.secondary
                            : index < currentLineIndex
                                ? appearance.primary.opacity(appearance.pastLyricOpacity * 0.72)
                                : appearance.primary.opacity(appearance.futureLyricOpacity * 0.72)
                    )
                    .multilineTextAlignment(lyricsAlignment.textAlignment)
                    // 长翻译在窄屏 / 大字号下要 wrap 多行。不加 fixedSize 时 SwiftUI
                    // 会优先单行 + 截断显示省略号。
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { seekToLyricLine(line) }
                    .frame(width: availableWidth, alignment: frameAlignment)
            }

            if let bgs = line.background {
                ForEach(bgs) { bg in
                    singleLineContent(
                        line: bg,
                        isActive: isActive,
                        index: index,
                        fontSize: fontSize * 0.7,
                        weight: .medium,
                        textAlignment: lyricsAlignment.textAlignment,
                        dimmedByAmbient: dimmedByAmbient,
                        timelineTime: timelineTime
                    )
                        .opacity(0.7)
                        .contentShape(Rectangle())
                        .onTapGesture { seekToLyricLine(line) }
                        .frame(width: availableWidth, alignment: frameAlignment)
                }
            }
        }
        .frame(width: availableWidth, alignment: frameAlignment)
        // Active emphasis stays a render-layer transform so playback changes
        // never reflow surrounding rows. The stable text width reserves the
        // maximum scale, and the anchor follows the selected alignment.
        .scaleEffect(visualScale, anchor: lyricsScaleAnchor)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    private func seekToLyricLine(_ line: LyricLine) {
        lastLyricRowTapAt = Date()
        guard line.isSynchronized else { return }
        player.seek(to: line.timestamp)
    }

    @ViewBuilder
    private func singleLineContent(
        line: LyricLine,
        isActive: Bool,
        index: Int,
        fontSize: CGFloat,
        weight: Font.Weight,
        textAlignment: TextAlignment,
        dimmedByAmbient: Bool = false,
        timelineTime: TimeInterval? = nil
    ) -> some View {
        if line.isWordLevel {
            let animatesWords = shouldRenderWordTimeline(
                line: line,
                index: index,
                isActive: isActive,
                dimmedByAmbient: dimmedByAmbient
            )
            let usesLiveTimeline = animatesWords
                && visualActivityPolicy.shouldRunWordTimeline
            let fixedPlaybackTime = usesLiveTimeline
                ? timelineTime
                : (timelineTime ?? visualPlaybackTime)
            // dimmedByAmbient 模式: KaraokeLineView 内部用固定 active=1.0 / inactive=0.4
            // 对比, 外层 ambient opacity 接管 row 整体明暗。这样无论 row 处于 future /
            // active / past, syllable 扫光的对比度都一致, 只是整体亮度被 ambient
            // 平滑过渡。
            let inactiveOpacity: Double = dimmedByAmbient ? appearance.inactiveSyllableOpacity
                : (isActive
                    ? appearance.inactiveSyllableOpacity
                    : (index < currentLineIndex
                        ? appearance.pastLyricOpacity
                        : appearance.futureLyricOpacity))
            let activeOpacity: Double = dimmedByAmbient ? 1.0
                : (isActive ? 1.0 : inactiveOpacity)
            KaraokeLineView(
                line: line,
                fontSize: fontSize,
                weight: weight,
                activeStyle: isActive
                    ? currentLyricStyle(opacity: activeOpacity)
                    : AnyShapeStyle(appearance.primary.opacity(activeOpacity)),
                inactiveColor: appearance.primary.opacity(inactiveOpacity),
                textAlignment: textAlignment,
                writingDirection: lyricsWritingDirection,
                timeAt: { date in player.interpolatedTime(at: date) },
                fixedTime: fixedPlaybackTime,
                isAnimationEnabled: animatesWords,
                animatesSyllableBounce: visualActivityPolicy.shouldRunWordTimeline,
                deactivationTime: dimmedByAmbient ? wordLevelDeactivationTime(for: index) : nil
            )
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(lyricLineStyle(
                    isActive: isActive,
                    index: index,
                    dimmedByAmbient: dimmedByAmbient
                ))
                .multilineTextAlignment(textAlignment)
                // 长歌词在窄屏 / 放大字号下需要 wrap 多行。不加 fixedSize 时 SwiftUI
                // 在某些 layout 约束下会单行 + 省略号; 而靠近当前行时切到 KaraokeLineView
                // (它有 fixedSize) 会展开多行 → 视觉上"省略号展开收起"的跳动。
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lyricLineStyle(
        isActive: Bool,
        index: Int,
        dimmedByAmbient: Bool
    ) -> AnyShapeStyle {
        if isActive {
            return currentLyricStyle()
        }
        if dimmedByAmbient {
            return AnyShapeStyle(appearance.primary)
        }
        return AnyShapeStyle(
            index < currentLineIndex
                ? appearance.primary.opacity(appearance.pastLyricOpacity)
                : appearance.primary.opacity(appearance.futureLyricOpacity)
        )
    }

    /// 字级模式 row 的视觉状态。
    private struct RowActivity {
        var opacity: Double
        var scale: Double
    }

    /// 字级模式专用。scale 只在 active 切换时离散变化 (1.0 ↔ lyricsActiveVisualScale),
    /// 且由 lyricsRow 用 scaleEffect (渲染层) 应用 ── 不改字号/布局, 不会引发
    /// 行宽行高重排, 因此既不会每秒重排 60 次, 也不会和自动滚动反馈打满主线程。
    /// 实际明暗 + 大小过渡都由外层 .animation(value: currentLineIndex) 平滑插值。
    private func rowVisualActivity(index: Int) -> RowActivity {
        guard index >= 0, index < lyrics.count else {
            return RowActivity(opacity: appearance.futureLyricOpacity, scale: 1.0)
        }
        return RowActivity(
            opacity: index == currentLineIndex
                ? 1.0
                : (index < currentLineIndex
                    ? appearance.pastLyricOpacity
                    : appearance.futureLyricOpacity),
            scale: index == currentLineIndex ? Self.lyricsActiveVisualScale : 1.0
        )
    }

    /// 行级歌词保留原有的过去/未来明暗层次，只把离散字号切换改成与
    /// 逐字歌词一致的渲染层缩放。这样不改变布局，也能让切句三种动效同步。
    private func lineLevelRowVisualActivity(index: Int) -> RowActivity {
        guard hasSynchronizedLyrics else {
            return RowActivity(opacity: 1.0, scale: 1.0)
        }
        guard index >= 0, index < lyrics.count else {
            return RowActivity(opacity: appearance.futureLyricOpacity, scale: 1.0)
        }
        let isActive = index == currentLineIndex
        let opacity = isActive
            ? 1.0
            : (index < currentLineIndex
                ? appearance.pastLyricOpacity
                : appearance.futureLyricOpacity)
        return RowActivity(
            opacity: opacity,
            scale: isActive ? Self.lyricsActiveVisualScale : 1.0
        )
    }

    private func lyricLayoutWidth(in viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - Self.lyricsHorizontalPadding * 2)
    }

    private func lyricTextWidth(in viewportWidth: CGFloat) -> CGFloat {
        CGFloat(LyricRowLayoutPolicy.unscaledContentWidth(
            viewportWidth: Double(viewportWidth),
            horizontalPadding: Double(Self.lyricsHorizontalPadding),
            maximumVisualScale: Double(Self.lyricsActiveVisualScale)
        ))
    }

    private func inactiveLyricBlurRadius(for index: Int) -> CGFloat {
        CGFloat(LyricDepthEffectPolicy.blurRadius(
            forRow: index,
            activeRow: currentLineIndex,
            isEnabled: blursInactiveLyrics
                && !reduceTransparency
                && !isManuallyBrowsingLyrics
                && !isPinchingLyrics,
            isSynchronized: hasSynchronizedLyrics
        ))
    }

    private func shouldRenderWordTimeline(line: LyricLine, index: Int, isActive: Bool, dimmedByAmbient: Bool = false) -> Bool {
        guard line.isWordLevel else { return false }
        // dimmedByAmbient 模式 (字级歌词): 只让 active 行走 KaraokeLineView 扫光,
        // 相邻 ±1 行也走普通 Text。
        //
        // 原因: KaraokeLineView 内部 inactive syllable 用较低透明度的语义前景色实现
        // 双层 Text 的"扫光底色对比"; 而 row 外层 ambient opacity 在非 active 行
        // 也是 0.4。两者 multiply → 0.16, 比远行 (普通 Text × 0.4 = 0.4) 显著
        // 暗一档 ── 用户看到的"下一行比下下行还暗"就是这个双重 multiply 造成。
        //
        // 代价: 下一行失去"提前 100ms 预热扫光"的细节, 行真正切到 active 时才
        // 启动扫光。lookahead 100ms 在视觉上几乎不可察觉, 取舍合理。
        if dimmedByAmbient { return isActive }
        return isActive || abs(index - currentLineIndex) == 1
    }

    private func wordLevelDeactivationTime(for index: Int) -> TimeInterval? {
        guard hasWordLevelLyrics, lyrics.indices.contains(index + 1) else { return nil }
        let currentStart = lyrics[index].timestamp
        let nextTakeover = lyrics[index + 1].timestamp - Self.wordLevelLineLookahead
        return max(currentStart, nextTakeover)
    }

    /// 行级歌词 LRC 文件的 timestamp 通常是「演唱开始那一刻」,但 LRC 制作过程
    /// 中作者按 spacebar 记录会有人为反应延迟(常见 200-400ms),用户感受是
    /// 「头两个字唱完才高亮这一行」。给行级判断加 250ms lookahead 提前切换。
    /// 字级歌词 syllable 粒度精度本来就高,但行切换时也需要一点预热时间;
    /// 否则下一行会在第一个字开唱时才从普通行切成逐字 Timeline,跨行会显得顿。
    private static let lineLevelLookahead: TimeInterval = 0.25
    private static let wordLevelLineLookahead: TimeInterval = 0.10
    /// Line-level and word-level takeovers share one curve so scrolling,
    /// highlight, and scale read as a single continuous gesture.
    private static let lyricsTransitionDuration: TimeInterval = 0.54
    /// Keep the active line in the upper-middle of the compact phone viewport.
    /// 42% left too little room for upcoming lyrics once the header and bottom
    /// controls were present, which made a missed follow update more obvious.
    private static let lyricsVisualAnchor: CGFloat = 0.36
    /// Active rows render larger without changing their measured layout.
    /// LyricRowLayoutPolicy reserves this scale horizontally to prevent overflow.
    private static let lyricsActiveVisualScale: CGFloat = 1.08
    @discardableResult
    private func updateCurrentLine(
        disableAnimations: Bool = false
    ) -> LyricsScrollTarget? {
        guard hasSynchronizedLyrics else {
            if currentLineIndex != -1 { currentLineIndex = -1 }
            if activeInterludeAfterLineIndex != nil {
                activeInterludeAfterLineIndex = nil
            }
            return nil
        }
        let time = player.interpolatedTime()
        if !visualActivityPolicy.shouldRunWordTimeline {
            visualPlaybackTime = time
        }
        let lookahead = hasWordLevelLyrics
            ? Self.wordLevelLineLookahead
            : Self.lineLevelLookahead
        guard let position = LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: time,
            lookahead: lookahead
        ) else {
            let clearActiveLine = {
                if currentLineIndex != -1 { currentLineIndex = -1 }
                if activeInterludeAfterLineIndex != nil {
                    activeInterludeAfterLineIndex = nil
                }
            }
            if disableAnimations {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, clearActiveLine)
            } else {
                clearActiveLine()
            }
            return nil
        }

        let activeIndex: Int
        let interludeAfterLineIndex: Int?
        let scrollTarget: LyricsScrollTarget
        switch position {
        case .line(let index):
            guard lyrics.indices.contains(index) else { return nil }
            activeIndex = index
            interludeAfterLineIndex = nil
            scrollTarget = .line(id: lyrics[index].id)
        case .interlude(let index):
            guard lyrics.indices.contains(index) else { return nil }
            activeIndex = index
            interludeAfterLineIndex = index
            scrollTarget = .interlude(afterLineID: lyrics[index].id)
        }

        let update = {
            if currentLineIndex != activeIndex {
                currentLineIndex = activeIndex
            }
            if activeInterludeAfterLineIndex != interludeAfterLineIndex {
                activeInterludeAfterLineIndex = interludeAfterLineIndex
            }
        }
        if disableAnimations {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
            }
        } else {
            update()
        }
        return scrollTarget
    }
}

private extension View {
    func lyricsTranslationStatusBadgeStyle() -> some View {
        font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    func lyricsTranslationTaskIfAvailable(
        songID: String?,
        lyricsRevision: UInt,
        lyrics: [LyricLine],
        settings: LyricsTranslationSettingsStore,
        translatedTextByLineID: Binding<[String: String]>,
        activity: Binding<LyricsTranslationActivity>
    ) -> some View {
        if #available(iOS 18.0, *) {
            modifier(
                LyricsTranslationTaskModifier(
                    songID: songID,
                    lyricsRevision: lyricsRevision,
                    lyrics: lyrics,
                    settings: settings,
                    translatedTextByLineID: translatedTextByLineID,
                    activity: activity
                )
            )
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct LyricsTranslationTaskModifier: ViewModifier {
    @Environment(MusicIntelligenceService.self) private var intelligence
    let songID: String?
    let lyricsRevision: UInt
    let lyrics: [LyricLine]
    let settings: LyricsTranslationSettingsStore
    @Binding var translatedTextByLineID: [String: String]
    @Binding var activity: LyricsTranslationActivity

    @State private var translationConfig: TranslationSession.Configuration?
    @State private var preparedGroups: [LyricTranslationGroup] = []
    @State private var activeGroupIndex = 0
    @State private var preparedIdentity: TranslationTaskIdentity?

    private struct TranslationTaskIdentity: Hashable {
        let songID: String?
        let lyricsRevision: UInt
        let isEnabled: Bool
        let targetLanguageCode: String
        let mode: LyricsTranslationMode
        let systemPreparationRequestRevision: UInt
        let regionRevision: UInt64
    }

    private var translationTaskIdentity: TranslationTaskIdentity {
        TranslationTaskIdentity(
            songID: songID,
            lyricsRevision: lyricsRevision,
            isEnabled: settings.isEnabled,
            targetLanguageCode: LyricsTranslationSettingsStore.normalizedLanguageCode(
                settings.targetLanguageCode
            ),
            mode: settings.mode,
            systemPreparationRequestRevision: settings.systemPreparationRequestRevision,
            regionRevision: intelligence.regionAvailability.revision
        )
    }

    func body(content: Content) -> some View {
        content
            .task(id: translationTaskIdentity) {
                let identity = translationTaskIdentity
                await prepareTranslation(for: identity)
            }
            .translationTask(translationConfig) { session in
                await runTranslation(session: session)
            }
    }

    /// 按检测到的源语言拆分歌词。Translation 的一个 batch 只能对应一个
    /// source/target 语言对，混合语言放进同一自动检测 batch 会导致整批失败。
    private func prepareTranslation(for identity: TranslationTaskIdentity) async {
        translationConfig = nil
        preparedGroups = []
        activeGroupIndex = 0
        preparedIdentity = nil
        translatedTextByLineID = [:]
        activity = .idle

        guard identity.isEnabled, !lyrics.isEmpty else { return }
        let explicitlyRequested = settings.consumeSystemTranslationPreparationRequest(
            revision: identity.systemPreparationRequestRevision
        )

        let lyricTexts = lyrics.map(\.text)
        let fallbackSourceLanguageCode = LyricsTranslationSettingsStore.detectedLyricsLanguageCode(
            for: lyricTexts
        )
        let candidates = lyrics.map { line in
            LyricTranslationCandidate(
                id: line.id,
                text: line.text,
                sourceLanguageCode: LyricsTranslationSettingsStore.detectedLanguageCode(
                    for: line.text,
                    fallbackLanguageCode: fallbackSourceLanguageCode
                )
            )
        }
        let groups = LyricTranslationGroupingPolicy.groups(
            candidates: candidates,
            targetLanguageCode: identity.targetLanguageCode,
            fallbackSourceLanguageCode: fallbackSourceLanguageCode
        )
        guard !groups.isEmpty else { return }

        let cache = LyricsTranslationCache.shared
        let usesIntelligentProvider = identity.mode == .intelligentWithSystemFallback
            && intelligence.shouldExposeRemoteConfiguration
        let preferredCacheProvider: LyricsTranslationCache.ProviderNamespace =
            usesIntelligentProvider ? .intelligent : .system
        var hits: [String: String] = [:]
        var uncachedGroups: [LyricTranslationGroup] = []

        for group in groups {
            let pending = group.candidates.filter { candidate in
                if let translated = cache.translation(
                    for: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode,
                    provider: preferredCacheProvider
                ) {
                    hits[candidate.id] = translated
                    return false
                }
                return true
            }
            if !pending.isEmpty {
                uncachedGroups.append(
                    LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: pending
                    )
                )
            }
        }

        translatedTextByLineID = hits
        guard !uncachedGroups.isEmpty else {
            if preferredCacheProvider == .intelligent, !hits.isEmpty {
                activity = .intelligentCached
            }
            return
        }

        if usesIntelligentProvider {
            activity = .intelligentLoading
            let pendingCandidates = uncachedGroups.flatMap(\.candidates)
            if let execution = await intelligence.translateLyrics(
                pendingCandidates,
                targetLanguageCode: identity.targetLanguageCode
            ), !Task.isCancelled, translationTaskIdentity == identity {
                var cachePairs: [(source: String, sourceLang: String?, translated: String)] = []
                for group in uncachedGroups {
                    for candidate in group.candidates {
                        guard let translated = execution.translations[candidate.id] else { continue }
                        cachePairs.append((candidate.text, group.sourceLanguageCode, translated))
                    }
                }
                LyricsTranslationCache.shared.bulkSet(
                    cachePairs,
                    targetLang: identity.targetLanguageCode,
                    provider: .intelligent
                )
                translatedTextByLineID.merge(execution.translations) { _, new in new }
                let translatedIDs = Set(execution.translations.keys)
                uncachedGroups = uncachedGroups.compactMap { group in
                    let remaining = group.candidates.filter {
                        !translatedIDs.contains($0.id)
                    }
                    guard !remaining.isEmpty else { return nil }
                    return LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: remaining
                    )
                }
                if uncachedGroups.isEmpty {
                    activity = .intelligentSuccess(
                        provider: execution.providerName,
                        fallbackDepth: execution.fallbackDepth
                    )
                    return
                }
            }
            guard !Task.isCancelled, translationTaskIdentity == identity else { return }
            activity = .systemFallback

            var systemPendingGroups: [LyricTranslationGroup] = []
            for group in uncachedGroups {
                let pending = group.candidates.filter { candidate in
                    if let translated = cache.translation(
                        for: candidate.text,
                        sourceLang: group.sourceLanguageCode,
                        targetLang: identity.targetLanguageCode,
                        provider: .system
                    ) {
                        hits[candidate.id] = translated
                        return false
                    }
                    return true
                }
                if !pending.isEmpty {
                    systemPendingGroups.append(LyricTranslationGroup(
                        id: group.id,
                        sourceLanguageCode: group.sourceLanguageCode,
                        candidates: pending
                    ))
                }
            }
            translatedTextByLineID.merge(hits) { _, new in new }
            uncachedGroups = systemPendingGroups
            guard !uncachedGroups.isEmpty else { return }
        }

        var systemGroups: [LyricTranslationGroup] = []
        var deferredSystemLineCount = 0
        for group in uncachedGroups {
            if !explicitlyRequested, cache.isPairMarkedFailed(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            ) {
                deferredSystemLineCount += group.candidates.count
                continue
            }

            let pending = explicitlyRequested ? group.candidates : group.candidates.filter { candidate in
                if cache.isMarkedFailed(
                    source: candidate.text,
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode
                ) {
                    deferredSystemLineCount += 1
                    return false
                }
                return true
            }
            guard !pending.isEmpty else { continue }
            systemGroups.append(
                LyricTranslationGroup(
                    id: group.id,
                    sourceLanguageCode: group.sourceLanguageCode,
                    candidates: pending
                )
            )
        }
        if deferredSystemLineCount > 0 {
            plog("Lyrics translation cooldown skipped \(deferredSystemLineCount) lines")
        }
        guard !systemGroups.isEmpty else {
            if deferredSystemLineCount > 0 { activity = .systemPreparationRequired }
            return
        }

        let target = Locale.Language(identifier: identity.targetLanguageCode)
        var installedGroups: [LyricTranslationGroup] = []
        var preparationRequiredGroups: [LyricTranslationGroup] = []
        var unsupportedSystemLineCount = 0
        var shouldOfferPreparation = deferredSystemLineCount > 0
        for group in systemGroups {
            guard !Task.isCancelled else { return }
            if group.sourceLanguageCode == nil, !explicitlyRequested {
                preparationRequiredGroups.append(group)
                continue
            }
            do {
                guard let text = group.candidates.first?.text else { continue }
                let status = try await Self.translationAvailabilityStatus(
                    sourceLanguageCode: group.sourceLanguageCode,
                    sampleText: text,
                    targetLanguageCode: target.minimalIdentifier
                )

                switch status {
                case .installed:
                    if group.sourceLanguageCode == nil {
                        preparationRequiredGroups.append(group)
                    } else {
                        installedGroups.append(group)
                    }
                case .supported:
                    preparationRequiredGroups.append(group)
                    plog(
                        "Lyrics translation language pair requires explicit download: "
                            + "\(group.sourceLanguageCode ?? "auto") -> "
                            + identity.targetLanguageCode
                    )
                case .unsupported:
                    unsupportedSystemLineCount += group.candidates.count
                    plog(
                        "Lyrics translation pair unsupported: "
                            + "\(group.sourceLanguageCode ?? "auto") -> "
                            + identity.targetLanguageCode
                    )
                @unknown default:
                    unsupportedSystemLineCount += group.candidates.count
                    plog("Lyrics translation availability returned an unknown status")
                }
            } catch {
                cache.markPairFailed(
                    sourceLang: group.sourceLanguageCode,
                    targetLang: identity.targetLanguageCode
                )
                shouldOfferPreparation = true
                plog("Lyrics translation language detection failed: \(error.localizedDescription)")
            }
        }

        guard !Task.isCancelled, translationTaskIdentity == identity else { return }
        translatedTextByLineID.merge(hits) { _, new in new }
        var availableGroups = LyricTranslationGroupingPolicy.automaticSessionGroups(
            installed: installedGroups
        )
        if explicitlyRequested,
           let explicitGroup = LyricTranslationGroupingPolicy.explicitlyRequestedSessionGroup(
               preparationRequired: preparationRequiredGroups
           ) {
            availableGroups.append(explicitGroup)
            preparationRequiredGroups.removeAll { $0.id == explicitGroup.id }
        }
        if !preparationRequiredGroups.isEmpty || shouldOfferPreparation {
            activity = .systemPreparationRequired
        }
        guard !availableGroups.isEmpty else {
            if preparationRequiredGroups.isEmpty,
               !shouldOfferPreparation,
               unsupportedSystemLineCount > 0 {
                activity = .systemUnavailable
            }
            return
        }

        preparedGroups = availableGroups
        activeGroupIndex = 0
        preparedIdentity = identity
        activateGroup(at: 0, identity: identity)
    }

    /// Translation's availability reference is not Sendable in the current
    /// SDK. Keep it entirely inside this nonisolated operation and return only
    /// its Sendable status to the view's main-actor state machine.
    private nonisolated static func translationAvailabilityStatus(
        sourceLanguageCode: String?,
        sampleText: String,
        targetLanguageCode: String
    ) async throws -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        let target = Locale.Language(identifier: targetLanguageCode)
        if let sourceLanguageCode {
            return await availability.status(
                from: Locale.Language(identifier: sourceLanguageCode),
                to: target
            )
        }
        return try await availability.status(for: sampleText, to: target)
    }

    /// 为下一组建立 session。同一语言配置再次启用时必须 invalidate 配置版本，
    /// 才能让 SwiftUI 重新运行 translationTask。
    private func activateGroup(at index: Int, identity: TranslationTaskIdentity) {
        guard preparedIdentity == identity, preparedGroups.indices.contains(index) else {
            translationConfig = nil
            return
        }

        activeGroupIndex = index
        let group = preparedGroups[index]
        let source = group.sourceLanguageCode.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: identity.targetLanguageCode)
        var next = TranslationSession.Configuration(source: source, target: target)

        if var current = translationConfig,
           current.source == next.source,
           current.target == next.target {
            current.invalidate()
            next = current
        }
        translationConfig = next
    }

    /// 一次只翻译同一源语言的行。失败进入短时间冷却，避免用户取消下载或系统
    /// 临时错误后，同一首歌立即再次抢占系统展示链。
    private func runTranslation(session: TranslationSession) async {
        guard let identity = preparedIdentity,
              identity == translationTaskIdentity,
              preparedGroups.indices.contains(activeGroupIndex) else {
            return
        }

        let groupIndex = activeGroupIndex
        let group = preparedGroups[groupIndex]
        let requests = group.candidates.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        guard !requests.isEmpty else { return }

        var newCachePairs: [(source: String, sourceLang: String?, translated: String)] = []
        var newStateUpdates: [String: String] = [:]
        var translationFailed = false
        do {
            for try await response in session.translate(batch: requests) {
                guard !Task.isCancelled else { return }
                let id = response.clientIdentifier ?? ""
                let translated = response.targetText
                if !id.isEmpty { newStateUpdates[id] = translated }
                let detectedSourceLanguageCode = LyricsTranslationSettingsStore
                    .normalizedLanguageCode(response.sourceLanguage.minimalIdentifier)
                newCachePairs.append(
                    (
                        source: response.sourceText,
                        sourceLang: group.sourceLanguageCode,
                        translated: translated
                    )
                )
                if group.sourceLanguageCode != detectedSourceLanguageCode {
                    newCachePairs.append(
                        (
                            source: response.sourceText,
                            sourceLang: detectedSourceLanguageCode,
                            translated: translated
                        )
                    )
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            translationFailed = true
            LyricsTranslationCache.shared.markFailed(
                sources: group.candidates.compactMap { candidate in
                    newStateUpdates[candidate.id] == nil ? candidate.text : nil
                },
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
            LyricsTranslationCache.shared.markPairFailed(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
            plog("Lyrics translation failed: \(error.localizedDescription)")
        }

        if !newCachePairs.isEmpty {
            LyricsTranslationCache.shared.bulkSet(
                newCachePairs,
                targetLang: identity.targetLanguageCode,
                provider: .system
            )
        }
        if !translationFailed {
            LyricsTranslationCache.shared.clearPairFailure(
                sourceLang: group.sourceLanguageCode,
                targetLang: identity.targetLanguageCode
            )
        }

        guard !Task.isCancelled,
              preparedIdentity == identity,
              translationTaskIdentity == identity,
              activeGroupIndex == groupIndex else { return }

        if !newStateUpdates.isEmpty {
            translatedTextByLineID.merge(newStateUpdates) { _, new in new }
        }

        guard !translationFailed else {
            activity = .systemPreparationRequired
            translationConfig = nil
            preparedGroups = []
            preparedIdentity = nil
            return
        }

        let nextIndex = groupIndex + 1
        if preparedGroups.indices.contains(nextIndex) {
            activateGroup(at: nextIndex, identity: identity)
        } else {
            translationConfig = nil
        }
    }
}

// MARK: - PlaybackProgressBar (隔离 player.currentTime 高频读)

/// 进度条 + 双端时间标签。父 NowPlayingView body 不直接读 `player.currentTime`,
/// 把高频属性的 Observation 追踪限制在本 view 内。这样 currentTime 每 0.5s 变化
/// 只重算本 view,不会让父 body 重算 → 父 view 里的 SwiftUI Menu submenu (字号
/// 选择)在用户操作期间不会被强制关闭。
fileprivate struct PlaybackProgressBar: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var appearance: NowPlayingAppearance {
        NowPlayingAppearance(colorScheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        Group {
            if player.isLiveRadio {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("LIVE").fontWeight(.bold)
                    Spacer()
                    Text(player.currentTime.formattedDuration).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(appearance.secondary)
            } else {
                VStack(spacing: 4) {
                    ProgressSlider(
                        value: player.currentTime,
                        total: player.duration,
                        onSeek: { player.seek(to: $0) }
                    )
                    HStack {
                        Text(player.currentTime.formattedDuration); Spacer()
                        Text("-\(max(0, player.duration - player.currentTime).formattedDuration)")
                    }
                    .font(.caption2).foregroundStyle(appearance.tertiary).monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Cast Device Picker

/// 投屏目标设备选择。读 DLNARendererService.discoveredRenderers, 显示 LAN 内
/// 所有 MediaRenderer; 顶部"本机播放"项 = 取消投屏 (stopCasting); 选中其它项
/// = startCasting。当前已投屏的设备旁打 checkmark。
struct CastDevicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayerService.self) private var player
    @Environment(DLNARendererService.self) private var renderer

    var body: some View {
        #if os(macOS)
        macBody
            .task {
                renderer.refreshRemoteRenderers()
            }
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        let remoteRenderers = renderer.discoveredRenderers.values.sorted { $0.friendlyName < $1.friendlyName }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "tv.and.hifispeaker.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 30, height: 30)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text("cast_to_device")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text("cast_lan_devices")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                Button {
                    renderer.refreshRemoteRenderers()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 24, height: 24)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
                .help(Text("refresh"))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    macLocalRendererRow

                    if remoteRenderers.isEmpty {
                        macScanningState
                    } else {
                        ForEach(remoteRenderers) { dev in
                            macRendererRow(dev)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            #if os(macOS)
            .pmForceHideScrollers()
            #endif
            .frame(minHeight: 260, maxHeight: 340)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack(spacing: 10) {
                Text("settings_dlna_enable")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                Spacer()
                if player.isCastingMode {
                    Button {
                        Task {
                            await player.stopCasting()
                            dismiss()
                        }
                    } label: {
                        Text("cast_local_subtitle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(PMColor.glassBtn, in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(width: 380)
        // 当作为 popover/sheet 弹出时, SwiftUI 系统已经包了 chrome (圆角材质 +
        // 边框 + 阴影 + 箭头), 这里不再画自己的 rounded rect + material + shadow,
        // 否则跟系统 chrome 叠成双层框 (用户截图里那一圈外框就是这么来的)。
    }

    private var macLocalRendererRow: some View {
        Button {
            Task {
                await player.stopCasting()
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                macRendererIcon("macbook.and.iphone")
                VStack(alignment: .leading, spacing: 2) {
                    Text("cast_local_device")
                        .font(.system(size: 12.5, weight: !player.isCastingMode ? .semibold : .medium))
                        .foregroundStyle(PMColor.text)
                    Text("cast_local_subtitle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                }
                Spacer()
                if !player.isCastingMode {
                    Text("casting_connected")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .pmRowBackground(selected: !player.isCastingMode, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func macRendererRow(_ dev: RemoteRenderer) -> some View {
        let selected = player.castingRenderer?.udn == dev.udn
        return Button {
            Task {
                await player.startCasting(to: dev)
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                macRendererIcon(rendererSymbol(for: dev))
                VStack(alignment: .leading, spacing: 2) {
                    Text(dev.friendlyName)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(rendererSubtitle(for: dev))
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Text("casting_connected")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .pmRowBackground(selected: selected, cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var macScanningState: some View {
        VStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("cast_scanning")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PMColor.textMuted)
            Text("cast_dlna_required_hint")
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    private func macRendererIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PMColor.brand)
            .frame(width: 32, height: 32)
            .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 6))
    }

    private func rendererSymbol(for dev: RemoteRenderer) -> String {
        let text = [dev.friendlyName, dev.modelName, dev.manufacturer]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if text.contains("tv") || text.contains("bravia") { return "tv" }
        if text.contains("speaker") || text.contains("sonos") || text.contains("音箱") { return "hifispeaker.fill" }
        if text.contains("nas") || text.contains("synology") || text.contains("群晖") { return "externaldrive.fill" }
        return "desktopcomputer"
    }

    private func rendererSubtitle(for dev: RemoteRenderer) -> String {
        if let model = dev.modelName, let maker = dev.manufacturer {
            return "\(maker) · \(model)"
        }
        if let model = dev.modelName { return model }
        return dev.host
    }
    #endif

    private var iosBody: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await player.stopCasting(); dismiss() }
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("cast_local_device")
                                    .font(.body)
                                Text("cast_local_subtitle")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !player.isCastingMode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                let remoteRenderers = renderer.discoveredRenderers.values.sorted { $0.friendlyName < $1.friendlyName }
                if remoteRenderers.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("cast_scanning")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("cast_dlna_required_hint")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                } else {
                    Section {
                        ForEach(remoteRenderers) { dev in
                            Button {
                                Task { await player.startCasting(to: dev); dismiss() }
                            } label: {
                                HStack {
                                    Image(systemName: "tv.and.hifispeaker.fill")
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dev.friendlyName)
                                            .font(.body)
                                            .lineLimit(1)
                                        if let model = dev.modelName {
                                            Text(dev.manufacturer.map { "\($0) · \(model)" } ?? model)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text(dev.host)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if player.castingRenderer?.udn == dev.udn {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("cast_lan_devices")
                    }
                }
            }
            .navigationTitle("cast_picker_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { renderer.refreshRemoteRenderers() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("refresh"))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "done")) { dismiss() }
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { renderer.refreshRemoteRenderers() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("refresh"))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
                #endif
            }
            .task {
                // 进 sheet 立刻主动扫一遍, 不等下一次周期触发
                renderer.refreshRemoteRenderers()
            }
        }
    }
}
