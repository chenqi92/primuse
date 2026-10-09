#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS 沉浸播放：鼠标静置 3 秒淡出，0 返回原生、1–5 切换 A–E，
/// 方向键定位，Option+方向键切歌，Esc 直接退出窗口全屏。
/// 15 分钟没动鼠标、没按键就进省电档：压暗、停下装饰动画与频谱，叠上时钟和当前歌词。
struct MacImmersivePlayerView: View {
    /// 已经由常规播放页加载好的带时间戳歌词，沉浸态继续沿用同一份数据。
    let lyrics: [LyricLine]
    /// 翻译任务给出的译文（按行 id），和常规播放页同一份。
    var translatedTextByLineID: [String: String] = [:]
    /// 是否由这层自己忽略窗口安全区。
    ///
    /// 作为播放页里的一层时必须交给宿主（传 false）：在这里再忽略一次，扩出来的
    /// 尺寸会被共用的 ZStack 吸收，整棵内容树跟着比窗口还高 —— 顶部那排按钮被顶出
    /// 上边界只剩半截，底栏被推到 Dock 底下，而且回到常规全屏也不会自己复原。
    /// 只有把这份视图当成窗口根内容用时（截图取证那条路径）才需要自己忽略。
    var ignoresWindowSafeArea = true
    /// 退出 macOS 全屏
    var onExitFullScreen: () -> Void
    var onToggleQueue: () -> Void
    #if DEBUG
    var usesDemoEvidenceContent = false
    var debugEffectOverride: FullscreenPlayerEffect?
    #endif

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioVisualizerService.self) private var visualizer
    @Environment(MusicLibrary.self) private var library
    @Environment(CoverTintProvider.self) private var coverTintProvider
    @Environment(ThemeService.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var effectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @AppStorage(ImmersiveFrameRateMode.storageKey)
    private var frameRateRawValue = ImmersiveFrameRateMode.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsPlayerVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault

    @State private var showsChrome = true
    @State private var isStageReady = false
    @State private var chromeTask: Task<Void, Never>?
    @State private var hasResolvedArtwork = true
    @State private var gallerySongs: [Song] = []
    @State private var flowNeighbors = AlbumFlowNeighbors()
    /// 封面流(#191)整排挪了几格：点两侧某张时先滑过去，换歌落地后归零。
    @State private var flowShift: Double = 0
    /// 省电档（`ImmersiveIdlePowerPolicy`）。
    @State private var isLowPower = false
    @State private var idleTask: Task<Void, Never>?
    /// 省电时防烧屏的漂移走到第几步。
    @State private var restDriftStep = 0
    @State private var restDriftTask: Task<Void, Never>?
    @State private var showsEffectPicker = false
    @State private var scrubPreview: TimeInterval?
    @State private var activeLyricIndex: Int?
    @State private var lyricInterlude = false
    @State private var isPresentationActive = false
    @State private var isWindowVisible = false

    private var isRenderingActive: Bool { isPresentationActive && isWindowVisible }
    @State private var visualizerOwnerID = UUID()
    @FocusState private var acceptsKeyInput: Bool

    private var effect: FullscreenPlayerEffect {
        #if DEBUG
        if let debugEffectOverride { return debugEffectOverride }
        #endif
        return FullscreenPlayerEffect(rawValue: effectRawValue) ?? .defaultValue
    }

    private var frameRate: ImmersiveFrameRateMode {
        ImmersiveFrameRateMode(storedValue: frameRateRawValue)
    }

    private var presentationEffect: FullscreenPlayerEffect {
        let raw = ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: effect.rawValue,
            hasSynchronizedLyrics: hasSynchronizedLyrics,
            hasArtwork: hasResolvedArtwork
        )
        return FullscreenPlayerEffect(rawValue: raw) ?? .coverGallery
    }

    private var visualActivityPolicy: NowPlayingVisualActivityPolicy {
        NowPlayingVisualActivityPolicy(
            isSceneActive: isRenderingActive,
            isPlaying: player.isPlaying,
            usesRealtimeSpectrum: presentationEffect.usesRealtimeSpectrum,
            reduceMotion: reduceMotion
        )
    }

    private var chromeInk: Color {
        presentationEffect.prefersLightContent
            ? Color(red: 0.09, green: 0.10, blue: 0.16)
            : ImmersiveStagePalette.ink
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ImmersiveStageMetrics(size: geometry.size, safeArea: geometry.safeAreaInsets, prefersWide: true)

            ZStack {
                if isStageReady && isRenderingActive {
                    stage(metrics: metrics)
                        .scaleEffect(isLowPower ? 1.018 : 1)
                        .offset(restDriftOffset(metrics))
                        .overlay {
                            if isLowPower {
                                Color.black.opacity(ImmersiveIdlePowerPolicy.dimOpacity(for: .lowPower))
                            }
                        }
                } else {
                    entrySurface(metrics: metrics)
                }

                if isLowPower && isStageReady && isRenderingActive {
                    ImmersiveAmbientRestOverlay(
                        metrics: metrics,
                        lyric: restLyric,
                        title: stageTrack.title,
                        subtitle: stageTrack.subtitle
                    )
                    .transition(.opacity)
                }

                if showsChrome && isRenderingActive {
                    chrome(metrics: metrics)
                        .transition(.opacity)
                }

                // 遮罩压在顶栏之上：面板一开就接管整块界面，点面板之外的任何地方
                // （包括顶栏那排按钮）都只是把它收起来。
                if showsEffectPicker {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeEffectPicker() }
                        .accessibilityHidden(true)

                    // 面板贴着顶栏左边那个效果按钮展开。
                    MacImmersiveEffectPicker(
                        selected: effect,
                        effects: FullscreenPlayerEffect.allCases,
                        palette: artworkPalette,
                        onSelect: { candidate in
                            closeEffectPicker()
                            selectEffect(candidate)
                        },
                        onClose: { closeEffectPicker() }
                    )
                    .padding(.top, 64)
                    .padding(.leading, 26)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(
                        .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity)
                    )
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showsChrome)
            .animation(.easeInOut(duration: 1.2), value: isLowPower)
            .contentShape(Rectangle())
            .onTapGesture { location in handleSurfaceClick(at: location, metrics: metrics) }
            .onContinuousHover { phase in
                if case .active = phase { revealChrome() }
            }
        }
        .ignoresSafeArea(edges: ignoresWindowSafeArea ? .all : [])
        .macPlaybackErrorFeedback()
        .environment(\.colorScheme, presentationEffect.prefersLightContent ? .light : .dark)
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
        .focusable()
        .focused($acceptsKeyInput)
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleKeyPress(press)
        }
        .onExitCommand {
            if showsEffectPicker {
                closeEffectPicker()
            } else {
                beginExitFullScreen()
            }
        }
        .onAppear {
            activatePresentation()
            acceptsKeyInput = true
            FullscreenPlayerEffectSync.shared.install()
            refreshArtworkInputs()
        }
        .onRenderingVisibilityChange { visible in
            isWindowVisible = visible
            updateVisualizer(for: presentationEffect)
            if visible {
                scheduleChromeHide()
                scheduleLowPower()
            } else {
                chromeTask?.cancel()
                idleTask?.cancel()
            }
        }
        .task(id: isRenderingActive) { @MainActor in
            guard isRenderingActive else { return }
            // 先让系统全屏切换完成首轮布局，再挂载包含大图、Canvas 和模糊的
            // 沉浸场景；避免同一帧里同时争用主线程与 GPU。
            await Task.yield()
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled, isRenderingActive else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { isStageReady = true }
            updateVisualizer(for: presentationEffect)
            scheduleChromeHide()
            scheduleLowPower()
        }
        .task(id: lyricObservationIdentity) {
            await observeLyricPlayback()
        }
        .onChange(of: presentationEffect) { _, value in
            if isStageReady { updateVisualizer(for: value) }
            refreshFlowNeighbors()
        }
        .onChange(of: frameRateRawValue) { _, _ in
            if isStageReady { updateVisualizer(for: presentationEffect) }
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            refreshArtworkInputs()
            if isStageReady { updateVisualizer(for: presentationEffect) }
        }
        .background {
            MacImmersiveLibraryCountObserver {
                refreshGallerySongs()
            }
        }
        .background {
            MacImmersiveQueueObserver {
                refreshFlowNeighbors()
            }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing {
                updateVisualizer(for: presentationEffect)
                scheduleChromeHide()
            } else {
                visualizer.release(owner: visualizerOwnerID)
                revealChrome()
            }
        }
        .onChange(of: player.lastPlaybackError) { _, error in
            guard error != nil else { return }
            revealChrome()
        }
        .onChange(of: showsEffectPicker) { _, isPresented in
            if isPresented {
                chromeTask?.cancel()
                showsChrome = true
            } else {
                revealChrome()
            }
        }
        .onDisappear {
            deactivatePresentation()
        }
    }

    // MARK: - 画面

    private func stage(metrics: ImmersiveStageMetrics) -> some View {
        ImmersiveStageView(
            style: presentationEffect,
            platform: .macOS,
            metrics: metrics,
            track: stageTrack,
            playbackTime: { lyricPlaybackTime },
            palette: artworkPalette,
            lyricWindow: lyricWindow,
            currentLyric: currentLyric,
            nextLyric: nextLyric,
            lyricsWritingDirection: LyricWritingDirectionPolicy.resolve(in: lyrics),
            levelsProvider: { spectrumLevels },
            galleryArtworkCount: gallerySongs.count,
            galleryArtwork: { index, side in
                guard gallerySongs.indices.contains(index) else { return AnyView(Color.clear) }
                let song = gallerySongs[index]
                return AnyView(
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: min(side, 320),
                        cornerRadius: 0,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        showsPlaceholder: false,
                        fillsProposedSize: true
                    )
                    .frame(width: side, height: side)
                )
            },
            flowBeforeCount: flowNeighbors.before.count,
            flowAfterCount: flowNeighbors.after.count,
            flowArtwork: { offset, side in
                // 0 是正在播的这张(给倒影用的静态那份)，其余是封面流两侧的专辑。
                guard let song = offset == 0 ? player.currentSong : flowNeighbors.song(at: offset) else {
                    return AnyView(ImmersiveArtworkFallback(palette: artworkPalette))
                }
                return AnyView(
                    ZStack {
                        ImmersiveArtworkFallback(palette: artworkPalette)
                        CachedArtworkView(
                            coverRef: song.coverArtFileName,
                            songID: song.id,
                            size: min(side, 480),
                            cornerRadius: 0,
                            sourceID: song.sourceID,
                            filePath: song.filePath,
                            fileFormat: song.fileFormat,
                            showsPlaceholder: false,
                            fillsProposedSize: true
                        )
                    }
                    .frame(width: side, height: side)
                )
            },
            flowItemID: { flowNeighbors.itemID(at: $0) },
            flowShift: flowShift,
            isRenderingActive: isRenderingActive,
            reduceMotion: reduceMotion,
            lyricsMotionEnabled: lyricsMotionEnabled,
            frameRate: frameRate,
            lyricInterlude: lyricInterlude,
            lyricsPlaceholder: String(localized: "no_lyrics"),
            controlsInset: controlsInset(metrics),
            isResting: isLowPower,
            isLowPower: isLowPower,
            showsPlaybackProgress: showsChrome,
            chromeBlurRadius: 52
        ) { side in
            ZStack {
                ImmersiveArtworkFallback(palette: artworkPalette)
                if let song = player.currentSong {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: nil,
                        cornerRadius: 0,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        presentationRole: .animatedHero,
                        animationRequiresPlayback: true,
                        isPlaying: player.isPlaying && isRenderingActive,
                        isAnimationVisible: isRenderingActive && !showsEffectPicker && !isLowPower,
                        onResolutionChange: { hasResolvedArtwork = $0 }
                    )
                    .frame(width: side, height: side)
                    .opacity(hasResolvedArtwork ? 1 : 0)
                }
            }
        }
    }

    /// 原生全屏动画结束后的轻量过渡帧。它只使用文本和静态渐变，
    /// 给复杂场景留出一个稳定布局周期后再淡入。
    private func entrySurface(metrics: ImmersiveStageMetrics) -> some View {
        ZStack {
            artworkPalette.secondary

            RadialGradient(
                stops: [
                    .init(color: artworkPalette.primary.opacity(0.72), location: 0),
                    .init(color: artworkPalette.secondary.opacity(0.28), location: 0.44),
                    .init(color: artworkPalette.secondary.opacity(0), location: 1),
                ],
                center: .center,
                startRadius: 0,
                endRadius: max(metrics.size.width, metrics.size.height) * 0.72
            )

            VStack(spacing: metrics.s(12)) {
                Text("now_playing")
                    .font(.system(size: metrics.s(14), weight: .medium, design: .monospaced))
                    .tracking(metrics.f(2.4))
                    .foregroundStyle(artworkPalette.primary.opacity(0.78))
                Text(songTitle)
                    .font(.system(size: metrics.s(42), weight: .semibold))
                    .foregroundStyle(ImmersiveStagePalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(artistName)
                    .font(.system(size: metrics.s(18), weight: .medium))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.56))
                    .lineLimit(1)
            }
            .padding(.horizontal, metrics.s(72))
        }
        .accessibilityHidden(true)
    }

    private func controlsInset(_ metrics: ImmersiveStageMetrics) -> CGFloat {
        let designHeight: CGFloat
        switch presentationEffect.chromeFamily {
        case .deck: designHeight = 216
        case .standard: designHeight = 178
        case .lyrics: designHeight = 136
        case .spectrum: designHeight = 116
        case .showcase: designHeight = 172
        }
        let chromeHeight = metrics.s(designHeight)
        let safeBottom = max(metrics.safeArea.bottom, metrics.s(18))
        return min(metrics.size.height * 0.32, chromeHeight + safeBottom)
    }

    private func chrome(metrics: ImmersiveStageMetrics) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                effectMenu
                Spacer()
                Button(action: beginExitFullScreen) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("exit_full_screen")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(chromeInk.opacity(0.9))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .overlay { Capsule().strokeBorder(chromeInk.opacity(0.24), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .pmPointingHand()
                .keyboardShortcut(.cancelAction)
                .help(Text("exit_full_screen"))
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)

            if let error = player.lastPlaybackError {
                playbackErrorBanner(error)
                    .padding(.top, 12)
            }

            Spacer()

            macBottomChrome(metrics: metrics)
                .padding(.horizontal, max(metrics.safeArea.leading, metrics.safeArea.trailing) + metrics.s(78))
                .padding(.bottom, max(metrics.safeArea.bottom + metrics.s(30), metrics.s(34)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func macBottomChrome(metrics: ImmersiveStageMetrics) -> some View {
        switch presentationEffect.chromeFamily {
        case .standard:
            HStack {
                Spacer(minLength: metrics.size.width * 0.38)
                VStack(spacing: metrics.s(15)) {
                    seekBar
                    HStack(spacing: metrics.s(14)) {
                        modeButton("shuffle", active: player.shuffleEnabled) {
                            player.shuffleEnabled.toggle()
                        }
                        transportStrip
                        modeButton(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                            advanceRepeatMode()
                        }
                        if showsPlayerVolumeBar {
                            Divider().frame(height: metrics.s(24)).opacity(0.24)
                            volumeControl
                        }
                        queueButton
                    }
                }
                .frame(maxWidth: metrics.s(820))
            }
        case .deck:
            controlDeck(metrics: metrics, maxWidth: metrics.s(860), showsTrackTitle: false)
                .frame(maxWidth: .infinity)
        case .lyrics:
            HStack {
                VStack(spacing: metrics.s(12)) {
                    seekBar
                    HStack {
                        transportStrip
                        Spacer()
                        queueButton
                    }
                }
                .frame(width: min(metrics.size.width * 0.28, metrics.s(480)))
                Spacer()
            }
        case .spectrum:
            HStack(spacing: metrics.s(20)) {
                transportStrip
                Text(player.currentTime.formattedDuration)
                    .font(.system(size: metrics.s(12), design: .monospaced))
                    .foregroundStyle(chromeInk.opacity(0.48))
                MacImmersiveScrubber(accent: seekTint) { fraction in
                    revealChrome()
                    player.seek(to: fraction * player.duration)
                }
                Text(player.duration.formattedDuration)
                    .font(.system(size: metrics.s(12), design: .monospaced))
                    .foregroundStyle(chromeInk.opacity(0.48))
                if showsPlayerVolumeBar {
                    volumeControl
                }
                queueButton
            }
        case .showcase:
            macShowcaseControlSurface(metrics: metrics)
                .frame(maxWidth: .infinity, alignment: macShowcaseControlAlignment)
        }
    }

    /// 展示型效果 (标题墙 / 封面流 / 星空…) 右下角那块浮动控件。
    ///
    /// 排成一行而不是"进度条上、按钮下"两行:`ImmersiveGlassPill` 的底是
    /// `Capsule`,圆角等于高度的一半,套在两行内容上两端就会鼓成两个大半圆,
    /// 看着像一块突兀的厚板。一行之后胶囊的形状才成立,按钮也跟着 metrics
    /// 缩放,不会在 4K 屏上显得又小又散。
    @ViewBuilder
    private func macShowcaseControlSurface(metrics: ImmersiveStageMetrics) -> some View {
        ImmersiveGlassPill(
            horizontalPadding: metrics.s(22),
            verticalPadding: metrics.s(10)
        ) {
            HStack(spacing: metrics.s(16)) {
                showcaseTransport(metrics: metrics)

                Text((scrubPreview ?? player.currentTime).formattedDuration)
                    .font(.system(size: metrics.s(11), weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(chromeInk.opacity(0.52))

                MacImmersiveScrubber(accent: seekTint) { fraction in
                    revealChrome()
                    player.seek(to: fraction * player.duration)
                }
                .frame(minWidth: metrics.s(120))

                Text(player.duration.formattedDuration)
                    .font(.system(size: metrics.s(11), weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(chromeInk.opacity(0.52))
            }
            .frame(width: min(metrics.s(520), metrics.size.width * 0.44))
        }
    }

    /// 展示型效果专用的传输键 —— 比 `transportStrip` 小一号,且尺寸跟着
    /// metrics 走,好让它在一行胶囊里不至于把高度撑起来。
    private func showcaseTransport(metrics: ImmersiveStageMetrics) -> some View {
        HStack(spacing: metrics.s(10)) {
            transportButton(
                "backward.fill",
                size: metrics.s(14),
                diameter: metrics.s(34),
                label: "a11y_previous_track"
            ) {
                Task { await player.previous() }
            }

            Button {
                revealChrome()
                guard !player.isLoading else { return }
                player.togglePlayPause()
            } label: {
                ZStack {
                    Image(systemName: player.isPlaying || player.isLoading ? "pause.fill" : "play.fill")
                        .font(.system(size: metrics.s(17), weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(player.showsLoadingIndicator ? 0 : 1)
                    if player.showsLoadingIndicator {
                        ProgressView()
                            .controlSize(.small)
                            .tint(chromeInk)
                    }
                }
                .foregroundStyle(chromeInk)
                .frame(width: metrics.s(42), height: metrics.s(42))
                .overlay {
                    Circle().strokeBorder(chromeInk.opacity(0.64), lineWidth: metrics.f(1.2))
                }
            }
            .buttonStyle(.plain)
            .pmPointingHand()
            .disabled(player.showsLoadingIndicator)
            .help(Text(player.isPlaying || player.isLoading ? "a11y_pause" : "a11y_play"))

            transportButton(
                "forward.fill",
                size: metrics.s(14),
                diameter: metrics.s(34),
                label: "a11y_next_track"
            ) {
                Task { await player.next() }
            }
        }
    }

    private var macShowcaseControlAlignment: Alignment {
        switch presentationEffect {
        case .radialPulse, .vinylDeck, .particleBloom:
            .leading
        case .coverGallery, .flowingLines,
             .auroraVeil, .spectrumHorizon:
            .trailing
        case .native, .albumFlow:
            .center
        }
    }

    private func controlDeck(
        metrics: ImmersiveStageMetrics,
        maxWidth: CGFloat,
        showsTrackTitle: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: metrics.s(14)) {
            if showsTrackTitle {
                Text(songTitle)
                    .font(.system(size: metrics.s(20), weight: .semibold))
            }
            seekBar
            HStack(spacing: metrics.s(14)) {
                transportStrip
                Spacer()
                Text(audioMetadata.uppercased())
                    .font(.system(size: metrics.s(11), weight: .medium, design: .monospaced))
                    .tracking(metrics.f(0.8))
                    .foregroundStyle(chromeInk.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                if showsPlayerVolumeBar {
                    volumeControl
                }
                queueButton
            }
        }
        .padding(.horizontal, metrics.s(24))
        .padding(.vertical, metrics.s(18))
        .frame(maxWidth: maxWidth)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: metrics.f(12), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.f(12), style: .continuous)
                .strokeBorder(chromeInk.opacity(0.18), lineWidth: max(0.6, metrics.f(0.8)))
        }
    }

    /// 沉浸页原本不显示播放错误: 网络 / 解码失败后只剩一个被禁用的播放键,
    /// 用户分不清"还在加载"和"已经失败"。与标准播放页同款的提示胶囊。
    private func playbackErrorBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.red.opacity(0.82), in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var effectMenu: some View {
        Button {
            chromeTask?.cancel()
            pmWithAnimation(.panel) {
                showsEffectPicker.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Text(verbatim: effect.localizedTitle)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(chromeInk.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .overlay { Capsule().strokeBorder(chromeInk.opacity(0.24), lineWidth: 0.75) }
        }
        .buttonStyle(.plain)
        .pmPointingHand()
        .fixedSize()
        .help(Text("fullscreen_effect_settings_title"))
    }

    private func closeEffectPicker() {
        pmWithAnimation(.panel) {
            showsEffectPicker = false
        }
    }

    private var seekBar: some View {
        VStack(spacing: 0) {
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                interactionID: player.currentSong?.id,
                fillTint: seekTint,
                onPreview: {
                    scrubPreview = $0
                    revealChrome()
                },
                onSeek: {
                    revealChrome()
                    player.seek(to: $0)
                }
            )
            HStack {
                Text((scrubPreview ?? player.currentTime).formattedDuration)
                Spacer()
                Text(player.duration.formattedDuration)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(chromeInk.opacity(0.45))
        }
    }

    private var transportStrip: some View {
        HStack(spacing: 14) {
            transportButton("backward.fill", size: 18, diameter: 46, label: "a11y_previous_track") {
                Task { await player.previous() }
            }
            Button {
                revealChrome()
                guard !player.isLoading else { return }
                player.togglePlayPause()
            } label: {
                ZStack {
                    Image(systemName: player.isPlaying || player.isLoading ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                        .opacity(player.showsLoadingIndicator ? 0 : 1)
                    if player.showsLoadingIndicator {
                        ProgressView()
                            .controlSize(.small)
                            .tint(chromeInk)
                    }
                }
                .foregroundStyle(chromeInk)
                .frame(width: 58, height: 58)
                .overlay { Circle().strokeBorder(chromeInk.opacity(0.64), lineWidth: 1.4) }
            }
            .buttonStyle(.plain)
            .pmPointingHand()
            .disabled(player.showsLoadingIndicator)
            .help(Text(player.isPlaying || player.isLoading ? "a11y_pause" : "a11y_play"))

            transportButton("forward.fill", size: 18, diameter: 46, label: "a11y_next_track") {
                Task { await player.next() }
            }
        }
    }

    private var queueButton: some View {
        Button {
            revealChrome()
            onToggleQueue()
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(chromeInk.opacity(0.88))
                .frame(width: 42, height: 42)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pmPointingHand()
        .help(Text("queue"))
        .accessibilityLabel(Text("queue"))
    }

    private func modeButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            revealChrome()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? artworkPalette.primary : chromeInk.opacity(0.54))
                .frame(width: 36, height: 36)
                .playbackToggleHighlight(
                    isActive: active,
                    tint: artworkPalette.primary,
                    diameter: 30
                )
        }
        .buttonStyle(.plain)
        .pmPointingHand()
        .accessibilityValue(Text(active ? "a11y_value_on" : "a11y_value_off"))
    }

    private func advanceRepeatMode() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            PMVolumeSymbol()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chromeInk.opacity(0.70))
                .frame(width: 18)
            PMPlaybackVolumeSlider(tint: seekTint)
            .frame(width: 118)
        }
        .frame(height: 44)
    }

    private func transportButton(
        _ symbol: String,
        size: CGFloat,
        diameter: CGFloat,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            revealChrome()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(chromeInk.opacity(0.9))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .overlay { Circle().strokeBorder(chromeInk.opacity(0.28), lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
        .pmPointingHand()
        .accessibilityLabel(Text(label))
    }

    private func glassButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(chromeInk.opacity(0.9))
                .frame(width: 34, height: 32)
                .overlay { Capsule().strokeBorder(chromeInk.opacity(0.24), lineWidth: 0.75) }
        }
        .buttonStyle(.plain)
        .pmPointingHand()
        .help(Text(help))
    }

    private var seekTint: Color {
        artworkPalette.primary
    }

    // MARK: - 数据

    private var artworkPalette: ImmersiveArtworkPalette {
        ImmersiveArtworkPalette(primary: theme.accentColor, secondary: theme.secondaryDarkAccent)
    }

    private func refreshArtworkInputs() {
        #if DEBUG
        if usesDemoEvidenceContent {
            gallerySongs = []
            return
        }
        #endif
        if let song = player.currentSong {
            coverTintProvider.prepare([song])
        }
        refreshGallerySongs()
    }

    /// 封面流两侧随播放队列走：换歌、加歌、调序、开关随机都重取一次。别的效果用不上，不取。
    private func refreshFlowNeighbors() {
        #if DEBUG
        if usesDemoEvidenceContent { return }
        #endif
        let updated = presentationEffect == .albumFlow
            // 比放得下的多取一张，换歌滑动时最外那张从画布边外进来。
            ? player.albumFlowNeighbors(perSide: AlbumFlowLayoutPolicy.maximumNeighborsPerSide + 1)
            : AlbumFlowNeighbors()
        guard updated != flowNeighbors else { return }
        flowNeighbors = updated
        // 换歌落地：整排已按新位置排好，点按时挪出去的那几格清零，画面不跳。
        flowShift = 0
    }

    private func refreshGallerySongs() {
        refreshFlowNeighbors()
        let currentID = player.currentSong?.id
        // Stride through the library and test each stop, instead of filtering
        // the whole library first: that copied and trimmed every song on the
        // main thread at each song change.
        let songs = library.songs
        guard !songs.isEmpty else {
            gallerySongs = []
            return
        }
        let limit = min(14, songs.count)
        let seedText = currentID ?? "primuse"
        let seed = seedText.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let rawStride = max(1, songs.count / max(limit, 1))
        let step = rawStride.isMultiple(of: 2) ? rawStride + 1 : rawStride
        var selected: [Song] = []
        var seen: Set<String> = []
        var cursor = seed % songs.count
        var attempts = 0
        while selected.count < limit && attempts < min(songs.count * 2, limit * 400) {
            let song = songs[cursor % songs.count]
            if song.id != currentID,
               !(song.coverArtFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               seen.insert(song.id).inserted {
                selected.append(song)
            }
            cursor += step + attempts % 7
            attempts += 1
        }
        if selected.count < limit {
            // Few songs carry artwork: take the first ones in order, which is
            // what a short library got before.
            for song in songs.prefix(20_000) where song.id != currentID
                && !(song.coverArtFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && seen.insert(song.id).inserted {
                selected.append(song)
                if selected.count == limit { break }
            }
        }
        gallerySongs = selected
        coverTintProvider.prepare(selected)
    }

    private var stageTrack: ImmersiveStageTrack {
        #if DEBUG
        if usesDemoEvidenceContent {
            return ImmersiveDemoContent.track
        }
        #endif
        let queueCount = player.queueCount
        let nextIndex = player.currentIndex + 1
        let nextTitle = player.queuedSong(at: nextIndex)?.title ?? ""
        return ImmersiveStageTrack(
            title: songTitle,
            artist: artistName,
            album: albumName,
            format: audioMetadata,
            isPlaying: player.isPlaying,
            progress: 0,
            trackNumber: player.currentSong?.trackNumber
                ?? (queueCount <= 99 && player.queuedSong(at: player.currentIndex) != nil ? player.currentIndex + 1 : nil),
            trackCount: queueCount <= 99 && queueCount > 0 ? queueCount : nil,
            elapsed: 0,
            duration: player.duration,
            source: player.isAppleMusicMode ? "Apple Music" : String(localized: "local_import_source_name"),
            nextTitle: nextTitle,
            queueSummary: "\(queueCount) \(String(localized: "songs_count"))",
            genre: player.currentSong?.genre ?? "",
            year: player.currentSong?.year
        )
    }

    private static let lineLevelLookahead: TimeInterval = 0.25
    private static let wordLevelLineLookahead: TimeInterval = 0.10

    private var hasSynchronizedLyrics: Bool {
        LyricPlaybackPositionPolicy.shouldFollowPlayback(in: lyrics)
    }

    private var lyricWindow: [ImmersiveStageLyric] {
        guard let index = activeLyricIndex,
              lyrics.indices.contains(index) else { return [] }
        let lower = max(0, index - 1)
        let upper = min(lyrics.count, index + 4)
        let documentDirection = LyricWritingDirectionPolicy.resolve(in: lyrics)
        return (lower..<upper).compactMap { position in
            let text = lyrics[position].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ImmersiveStageLyric(
                id: position,
                text: text,
                isActive: position == index,
                offset: position - index,
                syllables: lyrics[position].syllables,
                startTime: lyrics[position].isSynchronized ? lyrics[position].timestamp : nil,
                endTime: immersiveLineEnd(at: position),
                writingDirection: LyricWritingDirectionPolicy.resolvePresentationDirection(
                    for: lyrics[position],
                    documentFallback: documentDirection
                ),
                background: ImmersiveStageBackgroundLyric.rows(
                    for: lyrics[position],
                    documentFallback: documentDirection
                ),
                companions: LyricCompanionTextPolicy.texts(
                    for: lyrics[position],
                    translatedText: translatedTextByLineID[lyrics[position].id]
                        ?? lyrics[position].manualTranslation?.text
                ).map(LyricCompanionTextPolicy.displayText)
            )
        }
    }

    private func immersiveLineEnd(at position: Int) -> TimeInterval? {
        let line = lyrics[position]
        guard line.isSynchronized else { return nil }
        if let explicit = line.endTime, explicit > line.timestamp { return explicit }
        if lyrics.indices.contains(position + 1) {
            let next = lyrics[position + 1].timestamp
            if next > line.timestamp { return next }
        }
        return line.timestamp + 3.5
    }

    private var currentLyric: String? {
        if let index = activeLyricIndex,
           lyrics.indices.contains(index) {
            return lyrics[index].text
        }
        return lyrics.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    private var nextLyric: String? {
        guard let index = activeLyricIndex, index + 1 < lyrics.count else { return nil }
        return lyrics[index + 1].text
    }

    private var lyricObservationIdentity: String {
        "\(player.currentSong?.id ?? "")|\(lyrics.hashValue)|\(isRenderingActive)|\(player.isPlaying)"
    }

    private var lyricPlaybackTime: TimeInterval {
        #if DEBUG
        if usesDemoEvidenceContent { return 0 }
        #endif
        return player.interpolatedTime()
    }

    @MainActor
    private func observeLyricPlayback() async {
        guard isRenderingActive else { return }
        activeLyricIndex = nil
        lyricInterlude = false
        guard hasSynchronizedLyrics else { return }

        let lookahead = lyrics.contains { $0.isWordLevel }
            ? Self.wordLevelLineLookahead
            : Self.lineLevelLookahead
        while !Task.isCancelled {
            guard isRenderingActive else { return }
            let playbackTime = lyricPlaybackTime
            let index = LyricPlaybackPositionPolicy.activeLineIndex(
                in: lyrics,
                at: playbackTime,
                lookahead: lookahead
            )
            let isInterlude: Bool
            if lyricsMotionEnabled,
               let index,
               lyrics.indices.contains(index) {
                let line = lyrics[index]
                let estimatedEnd = line.syllables?.last?.end ?? (line.timestamp + 3.5)
                isInterlude = playbackTime - estimatedEnd > 6
            } else {
                isInterlude = false
            }

            if activeLyricIndex != index { activeLyricIndex = index }
            if lyricInterlude != isInterlude { lyricInterlude = isInterlude }

            guard visualActivityPolicy.shouldPollLyrics else { return }

            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    /// 由舞台叶子视图按需调用，读取被限制在消费频谱的那一层。
    private var spectrumLevels: [CGFloat] {
        guard visualActivityPolicy.shouldRunVisualizer else { return [] }
        return visualizer.bandLevels.map { min(max(CGFloat($0), 0), 1) }
    }

    private var songTitle: String {
        #if DEBUG
        if usesDemoEvidenceContent { return ImmersiveDemoContent.title }
        #endif
        let value = player.currentSong?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ServerCatalogMetadataInspectionPolicy.hasUsableTitle(value)
            ? value
            : ImmersiveDemoContent.title
    }

    private var artistName: String {
        #if DEBUG
        if usesDemoEvidenceContent { return ImmersiveDemoContent.artist }
        #endif
        let value = player.currentSong.flatMap { library.artistDisplayName(for: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isPlaceholderMetadata(value, localizedKey: "unknown_artist")
            ? ImmersiveDemoContent.artist
            : value
    }

    private var albumName: String {
        #if DEBUG
        if usesDemoEvidenceContent { return ImmersiveDemoContent.album }
        #endif
        let value = player.currentSong?.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isPlaceholderMetadata(value, localizedKey: "unknown_album")
            ? ImmersiveDemoContent.album
            : value
    }

    private func isPlaceholderMetadata(_ value: String, localizedKey: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        let localized = Bundle.main.localizedString(forKey: localizedKey, value: "", table: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == localized
            || ["unknown", "unknown artist", "unknown album", "未知", "未知艺术家", "未知专辑"].contains(normalized)
    }

    private var audioMetadata: String {
        guard let song = player.currentSong else { return ImmersiveDemoContent.format }
        return ImmersiveAudioSpec.line(
            format: song.codecFormat.displayName,
            sampleRate: song.sampleRate,
            bitDepth: song.qualityBitDepth,
            audioVariants: song.audioVariants
        )
    }

    // MARK: - 键鼠与控件淡出

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        revealChrome()

        if press.key == .space {
            player.togglePlayPause()
            return .handled
        }

        if press.key == .leftArrow {
            if press.modifiers.contains(.option) {
                if presentationEffect == .albumFlow {
                    moveAlbumFlow(by: -1)
                } else {
                    Task { await player.previous() }
                }
            } else {
                seek(by: -10)
            }
            return .handled
        }

        if press.key == .rightArrow {
            if press.modifiers.contains(.option) {
                if presentationEffect == .albumFlow {
                    moveAlbumFlow(by: 1)
                } else {
                    Task { await player.next() }
                }
            } else {
                seek(by: 10)
            }
            return .handled
        }

        let characters = press.characters.lowercased()
        if characters == "l" {
            selectEffect(.flowingLines)
            return .handled
        }
        if characters == "0" {
            selectEffect(.native)
            return .handled
        }
        if let number = Int(characters),
           (1...9).contains(number),
           FullscreenPlayerEffect.immersiveCases.indices.contains(number - 1) {
            selectEffect(FullscreenPlayerEffect.immersiveCases[number - 1])
            return .handled
        }
        return .ignored
    }

    private func seek(by delta: TimeInterval) {
        guard player.duration > 0 else { return }
        player.seek(to: min(player.duration, max(0, player.currentTime + delta)))
    }

    private func selectEffect(_ value: FullscreenPlayerEffect) {
        // 整个场景树包含实时模糊和 Canvas；直接换组，避免隐式动画逐层插值。
        effectRawValue = value.rawValue
        FullscreenPlayerEffectSync.shared.select(value)
    }

    private func updateVisualizer(for value: FullscreenPlayerEffect) {
        guard isRenderingActive,
              !isLowPower,
              player.isPlaying,
              value.usesRealtimeSpectrum,
              let audioEngine = player.audioEngine.engineForVisualizer,
              let tapNode = player.audioEngine.visualizerTapNode else {
            visualizer.release(owner: visualizerOwnerID)
            return
        }
        visualizer.setPacing(frameRate.spectrumPacing(
            displayMaximumFramesPerSecond: ImmersiveDisplayRefresh.maximumFramesPerSecond
        ))
        guard visualizer.acquire(
            owner: visualizerOwnerID,
            engine: audioEngine,
            on: tapNode
        ) else {
            visualizer.release(owner: visualizerOwnerID)
            return
        }
    }

    private func activatePresentation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresentationActive = true }
    }

    private func deactivatePresentation() {
        chromeTask?.cancel()
        idleTask?.cancel()
        restDriftTask?.cancel()
        visualizer.release(owner: visualizerOwnerID)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresentationActive = false }
    }

    private func beginExitFullScreen() {
        guard isPresentationActive else { return }
        deactivatePresentation()
        onExitFullScreen()
    }

    private func revealChrome() {
        exitLowPower()
        if !showsChrome {
            withAnimation(.easeInOut(duration: 0.22)) { showsChrome = true }
        }
        scheduleChromeHide()
        scheduleLowPower()
    }

    // MARK: - 省电

    /// 15 分钟没动鼠标、没按键：压暗、停下装饰动画与频谱，叠上时钟和当前歌词。动一下鼠标就回来。
    private func scheduleLowPower() {
        idleTask?.cancel()
        guard isRenderingActive,
              !voiceOverEnabled,
              let delay = ImmersiveIdlePowerPolicy.delayToNextStage(from: .awake, restsEarly: false) else { return }
        idleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isRenderingActive,
                  isStageReady,
                  !voiceOverEnabled,
                  scrubPreview == nil,
                  !showsEffectPicker else { return }
            enterLowPower()
        }
    }

    private func enterLowPower() {
        chromeTask?.cancel()
        withAnimation(.easeInOut(duration: 1.2)) {
            showsChrome = false
            isLowPower = true
        }
        updateVisualizer(for: presentationEffect)
        restDriftTask?.cancel()
        restDriftStep = 0
        guard !reduceMotion else { return }
        // 防烧屏：隔一阵挪一小步，挪的那几秒缓缓过去，其余时间不重画。
        restDriftTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(ImmersiveIdlePowerPolicy.driftStepInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled, isLowPower else { return }
                withAnimation(.easeInOut(duration: ImmersiveIdlePowerPolicy.driftStepDuration)) {
                    restDriftStep += 1
                }
            }
        }
    }

    private func exitLowPower() {
        guard isLowPower else { return }
        restDriftTask?.cancel()
        withAnimation(.easeInOut(duration: 0.35)) {
            isLowPower = false
            restDriftStep = 0
        }
        updateVisualizer(for: presentationEffect)
    }

    private func restDriftOffset(_ metrics: ImmersiveStageMetrics) -> CGSize {
        guard isLowPower else { return .zero }
        let step = ImmersiveIdlePowerPolicy.driftOffset(step: restDriftStep)
        return CGSize(width: metrics.s(8) * CGFloat(step.x), height: metrics.s(6) * CGFloat(step.y))
    }

    /// 省电层上的歌词行：只认正在唱的那一句，还没唱到第一句时让歌名顶上。
    private var restLyric: String? {
        guard let index = activeLyricIndex, lyrics.indices.contains(index) else { return nil }
        let value = lyrics[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 封面流(#191)的点按

    /// 点中间那张 = 播放 / 暂停，点两侧某张 = 沿播放顺序跳到那首；点别处照旧只把控件叫出来。
    /// 省电时第一下只是叫醒。
    private func handleSurfaceClick(at location: CGPoint, metrics: ImmersiveStageMetrics) {
        let wasLowPower = isLowPower
        revealChrome()
        guard !wasLowPower,
              presentationEffect == .albumFlow,
              isStageReady,
              !showsEffectPicker else { return }
        let layout = ImmersiveAlbumFlowGeometry.layout(
            metrics: metrics,
            platform: .macOS,
            controlsInset: controlsInset(metrics)
        )
        guard let offset = layout.offset(
            atX: Double(location.x),
            y: Double(location.y),
            before: min(flowNeighbors.before.count, layout.neighborsPerSide),
            after: min(flowNeighbors.after.count, layout.neighborsPerSide),
            tolerance: 4
        ) else { return }
        if offset == 0 {
            player.togglePlayPause()
        } else {
            moveAlbumFlow(by: offset)
        }
    }

    /// 整排挪 `steps` 格并换到那首。那一边有那张就先把它滑到中间，换歌落地时整排正好接上；
    /// 没有（队首、队尾）就弹回原处，照旧交给上一首 / 下一首决定去哪。
    private func moveAlbumFlow(by steps: Int) {
        guard steps != 0 else { return }
        let available = steps > 0 ? flowNeighbors.after.count : flowNeighbors.before.count
        let startCenter = flowNeighbors.centerID
        withAnimation(.smooth(duration: 0.42)) {
            flowShift = abs(steps) <= available ? Double(steps) : 0
        }
        Task { @MainActor in
            let moved = await player.skipAlongQueue(by: steps)
            // 换歌那一刻已经把整排接好；没换过去（音乐源连不上、队列到头）就弹回来。
            guard flowNeighbors.centerID == startCenter else { return }
            if moved { refreshFlowNeighbors() }
            if flowShift != 0 {
                withAnimation(.smooth(duration: 0.35)) { flowShift = 0 }
            }
        }
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        guard isRenderingActive,
              isStageReady,
              player.isPlaying,
              !voiceOverEnabled,
              scrubPreview == nil,
              !showsEffectPicker else { return }
        chromeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(presentationEffect.usesShowcaseChrome ? 5 : 3))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isRenderingActive,
                  player.isPlaying,
                  !voiceOverEnabled,
                  scrubPreview == nil,
                  !showsEffectPicker else { return }
            withAnimation(.easeInOut(duration: 0.26)) { showsChrome = false }
        }
    }
}

/// 可点击 / 拖动定位的进度条。松手时把 0...1 比例回调出去做 seek。
private struct MacImmersiveScrubber: View {
    let accent: Color
    let onSeek: (Double) -> Void

    @Environment(AudioPlayerService.self) private var player
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let fraction = dragFraction ?? playbackFraction
            let fillWidth = width * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(ImmersiveStagePalette.text.opacity(0.18)).frame(height: 4)
                Capsule().fill(accent).frame(width: max(4, fillWidth), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: accent.opacity(0.4), radius: 6)
                    .offset(x: min(max(0, fillWidth - 6), width - 12))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        let fraction = min(1, max(0, value.location.x / width))
                        dragFraction = nil
                        onSeek(fraction)
                    }
            )
        }
        .frame(height: 16)
    }

    private var playbackFraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }
}

/// Scopes the large library array observation to an inert zero-size child.
/// Metadata-only publications no longer invalidate the full immersive root.
/// 封面流两侧跟着播放队列走。只在这一层读队列的几个修订号，队列变了才叫一次刷新，
/// 沉浸页本身不因为队列里的每次改动重算。
private struct MacImmersiveQueueObserver: View {
    @Environment(AudioPlayerService.self) private var player
    let onChange: () -> Void

    private var revision: [Int] {
        [
            player.queueGeneration,
            player.queueEntries.count,
            player.currentIndex,
            player.shuffleEnabled ? 1 : 0,
            player.shufflePosition,
        ]
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: revision) { _, _ in onChange() }
    }
}

private struct MacImmersiveLibraryCountObserver: View {
    @Environment(MusicLibrary.self) private var library
    let onCountChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: library.songs.count) { _, _ in onCountChange() }
    }
}
#endif
