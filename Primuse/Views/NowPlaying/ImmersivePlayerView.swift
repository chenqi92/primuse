#if os(iOS)
import SwiftUI
import AVFAudio
import PrimuseKit

/// iOS 全屏沉浸播放。
///
/// iOS 使用点按、上下/左右滑动与捏合；控件按 3.5 秒静默时序淡出，
/// 连续 5 分钟无操作后进入低亮度 Ambient Rest，15 分钟起再降到省电档（见 `ImmersiveIdlePowerPolicy`）。
struct ImmersivePlayerView: View {
    @Binding var effect: FullscreenPlayerEffect
    let lyrics: [LyricLine]
    /// Resolved by the player, which is the only place that knows whether a
    /// translation exists for the current target language.
    let lyricCompanions: (LyricLine) -> [String]
    let lyricsWritingDirection: LyricWritingDirection
    /// 歌词结果还没回来。空歌词此时是"还不知道", 不是"没有"。
    let isResolvingLyrics: Bool
    let isSceneActive: Bool
    let onDismiss: () -> Void
    let onMinimize: () -> Void
    let onShowQueue: () -> Void
    /// 遮挡区(iPhone Duo 外屏竖排的状态栏与前置摄像头),用全屏页自己的坐标,由播放页量好交进来。
    /// 全屏播放是沉浸式、不滚动的界面,按整屏居中,只让开这一块:顶部控件排在遮挡那一侧让开,
    /// 舞台内容只有上沿落进遮挡区那段高度时才在那一侧让。没有竖栏的设备为空,排版不变。
    var occlusions: [OcclusionAvoidancePolicy.Region] = []
    /// 封面流(#191)里长按：打开正在播的这张专辑的全部歌曲。播放页给，nil 时长按不做事。
    var onShowAlbum: (() -> Void)? = nil
    /// 右上角与底部播放胶囊两侧放什么(设置 › 播放器 › 播放页按钮 › 全屏效果)。
    var chromeControls: NowPlayingEffectPlayerControls = .default
    /// 队列以外的按钮由播放页画、走播放页同一套动作(弹出的面板也挂在播放页上)。nil 时那几格空着。
    var chromeControl: ((NowPlayingControlAction, ImmersiveChromeControlPlacement, Color) -> AnyView)? = nil

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioVisualizerService.self) private var visualizer
    @Environment(MusicLibrary.self) private var library
    @Environment(CoverTintProvider.self) private var coverTintProvider
    @Environment(ThemeService.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.pmIsPhoneIdiom) private var isPhoneIdiomEnvironment
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @AppStorage(ImmersiveFrameRateMode.storageKey)
    private var frameRateRawValue = ImmersiveFrameRateMode.defaultValue.rawValue
    @State private var showsChrome = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var ambientTask: Task<Void, Never>?
    @State private var isAmbientRest = false
    /// 休憩之后又过了一阵没人碰：再暗一档，装饰动画、频谱与动态封面停下。
    @State private var isLowPower = false
    /// 休憩时防烧屏的漂移走到第几步（隔一阵挪一步，见 `ImmersiveIdlePowerPolicy.driftOffset`）。
    @State private var ambientDriftStep = 0
    @State private var ambientDriftTask: Task<Void, Never>?
    @State private var isSeeking = false
    @State private var seekPreviewTime: TimeInterval?
    @State private var hasResolvedArtwork = true
    @State private var hasEntered = false
    @State private var gallerySongs: [Song] = []
    @State private var flowNeighbors = AlbumFlowNeighbors()
    /// 封面流(#191)整排挪了几格：横向拖动时跟着手走，松手后归位或挪满一格再换歌。
    @State private var flowShift: Double = 0
    /// 这一次拖动是不是在拖封面流（横向起手）；nil 是还没定方向。
    @State private var isDraggingFlow: Bool?
    /// 认定是拖封面流那一刻的横向位移：从这里起算，整排不会一上来先跳一截。
    @State private var flowDragOrigin: CGFloat = 0
    @State private var showsEffectPicker = false
    @State private var activeLyricIndex: Int?
    @State private var lyricInterlude = false
    @State private var visualizerOwnerID = UUID()
    @State private var visualizerRetryTask: Task<Void, Never>?

    /// iPhone(含 iPhone Duo 内屏)上的全屏页。内屏的画布有五六百点高,舞台照手机的构图放大,
    /// 不走 iPad / Mac 的大画布那一套。
    private var isPhoneIdiom: Bool {
        isPhoneIdiomEnvironment || UIDevice.current.userInterfaceIdiom == .phone
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
            // 省电档里频谱停下，舞台上的频谱层停在最后一帧。
            isSceneActive: isSceneActive && !isLowPower,
            isPlaying: player.isPlaying,
            usesRealtimeSpectrum: presentationEffect.usesRealtimeSpectrum,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let safeArea = stageSafeArea(geometry.safeAreaInsets, size: geometry.size)
            let metrics = ImmersiveStageMetrics(
                size: geometry.size,
                safeArea: safeArea,
                isHandheld: isPhoneIdiom
            )
            // 控件按真实安全区排(顶上那排另外在遮挡那一侧让开),舞台内容可能被推到遮挡区下面。
            let chromeMetrics = ImmersiveStageMetrics(
                size: geometry.size,
                safeArea: geometry.safeAreaInsets,
                isHandheld: isPhoneIdiom
            )

            ZStack {
                stage(metrics: metrics)
                    // 开合、转屏让舞台换构图(竖版 / 横版)时新构图淡入。
                    .pmLayoutChangeFade(metrics.layout)
                    .scaleEffect(isAmbientRest ? 1.018 : 1)
                    .offset(ambientDriftOffset(metrics))
                    .overlay {
                        if isAmbientRest {
                            Color.black.opacity(ImmersiveIdlePowerPolicy.dimOpacity(for: isLowPower ? .lowPower : .resting))
                        }
                    }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        // 长按只在封面流里生效(打开这张专辑)；别的效果里它永远等不到时长，
                        // 手指一抬就让给点按，点按的手感不变。
                        LongPressGesture(minimumDuration: albumFlowLongPressDuration)
                            .onEnded { _ in handleAlbumFlowLongPress() }
                            .exclusively(
                                before: SpatialTapGesture()
                                    .onEnded { value in
                                        guard !isControlZone(value.location, in: geometry.size) else { return }
                                        if handleAlbumFlowTap(at: value.location, metrics: metrics) { return }
                                        handleSurfaceTap()
                                    }
                            )
                    )
                    .simultaneousGesture(surfaceDrag(in: geometry.size, metrics: metrics))
                    .simultaneousGesture(modeMagnification)

                if isAmbientRest {
                    ImmersiveAmbientRestOverlay(
                        metrics: metrics,
                        lyric: ambientRestLyric,
                        title: songTitle,
                        subtitle: stageTrack.subtitle
                    )
                    .transition(.opacity)
                }

                if showsChrome && !isAmbientRest {
                    chrome(metrics: chromeMetrics)
                        .offset(y: showsChrome ? 0 : 8)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }

                // 抽屉是这一层 ZStack 里的覆盖物而不是系统 popover: 宿主才能准确知道它
                // 开着,继续暂停控件自动隐藏与滑动切效果。舞台不被它包住,开抽屉不会重建舞台。
                if showsEffectPicker {
                    // 抽屉之外点一下就收起。舞台那层的点击要避开顶部与底部的控件带
                    // (`isControlZone`),屏幕最上面那条 72pt 于是成了点不掉抽屉的死角;
                    // 抽屉开着时整块界面只做「收起」这一件事,所以单独铺一层。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showsEffectPicker = false }
                        .accessibilityHidden(true)

                    ImmersiveEffectDrawer(
                        selection: $effect,
                        effects: ImmersiveEffectDrawer.fullscreenCases,
                        palette: artworkPalette,
                        appliesOnSettle: true,
                        viewportSize: geometry.size,
                        safeAreaInsets: safeArea,
                        onClose: { showsEffectPicker = false }
                    )
                    .pmSlideTransition(
                        edge: ImmersiveEffectDrawer.transitionEdge(for: geometry.size),
                        motion: .panel
                    )
                }
            }
            .animation(.easeInOut(duration: 0.26), value: showsChrome)
            .animation(.easeInOut(duration: 0.35), value: isAmbientRest)
            .animation(.easeInOut(duration: 1.2), value: isLowPower)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, presentationEffect.prefersLightContent ? .light : .dark)
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .opacity(hasEntered ? 1 : 0)
        .scaleEffect(hasEntered ? 1 : 1.012)
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            if isSceneActive {
                refreshArtworkInputs()
                synchronizeVisualizer()
                scheduleChromeHide()
                scheduleAmbientRest()
                withAnimation(.easeOut(duration: 0.20)) { hasEntered = true }
            } else {
                hasEntered = true
            }
        }
        .task(id: lyricObservationIdentity) {
            await observeLyricPlayback()
        }
        .onChange(of: effect) { _, _ in
            synchronizeVisualizer()
            if isSceneActive {
                revealChrome()
                scheduleAmbientRest()
            }
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            if isSceneActive { refreshArtworkInputs() }
            synchronizeVisualizer()
        }
        .background {
            ImmersiveLibraryCountObserver {
                if isSceneActive { refreshGallerySongs() }
            }
        }
        .background {
            ImmersiveQueueObserver {
                if isSceneActive { refreshFlowNeighbors() }
            }
        }
        .onChange(of: presentationEffect) { _, _ in
            synchronizeVisualizer()
            if isSceneActive { refreshFlowNeighbors() }
        }
        .onChange(of: frameRateRawValue) { _, _ in
            synchronizeVisualizer()
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            synchronizeVisualizer()
            guard isSceneActive else { return }
            if isPlaying {
                scheduleChromeHide()
            } else {
                revealChrome()
            }
        }
        .onChange(of: player.lastPlaybackError) { _, error in
            guard error != nil, isSceneActive else { return }
            exitAmbientRest()
            revealChrome()
        }
        .onChange(of: isSceneActive) { _, isActive in
            handleSceneActivityChange(isActive: isActive)
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, isEnabled in
            if isEnabled {
                chromeTask?.cancel()
                ambientTask?.cancel()
                exitAmbientRest()
                showsChrome = true
            } else if isSceneActive {
                scheduleChromeHide()
                scheduleAmbientRest()
            }
        }
        .onChange(of: showsEffectPicker) { _, isPresented in
            if isPresented {
                chromeTask?.cancel()
                ambientTask?.cancel()
                exitAmbientRest()
                // 抽屉自带标题与收起按钮,浮动控件此时只会和它抢同一块位置:
                // 竖屏的底部抽屉正好压在传输控件上,横屏的尾侧抽屉压在顶栏按钮上。
                showsChrome = false
            } else {
                if isSceneActive {
                    revealChrome()
                    scheduleAmbientRest()
                }
            }
        }
        .onDisappear {
            chromeTask?.cancel()
            ambientTask?.cancel()
            ambientDriftTask?.cancel()
            visualizerRetryTask?.cancel()
            visualizer.release(owner: visualizerOwnerID)
        }
        .accessibilityAction(.escape, onDismiss)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - 画面

    private func stage(metrics: ImmersiveStageMetrics) -> some View {
        ImmersiveStageView(
            style: presentationEffect,
            platform: .iOS,
            metrics: metrics,
            track: stageTrack,
            playbackTime: { player.interpolatedTime() },
            palette: artworkPalette,
            lyricWindow: lyricWindow,
            currentLyric: currentLyricText,
            nextLyric: nextLyricText,
            lyricsWritingDirection: lyricsWritingDirection,
            levelsProvider: { spectrumLevels },
            galleryArtworkCount: gallerySongs.count,
            galleryArtwork: { index, side in
                guard gallerySongs.indices.contains(index) else { return AnyView(Color.clear) }
                let song = gallerySongs[index]
                return AnyView(
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: side,
                        cornerRadius: 0,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        showsPlaceholder: false
                    )
                    .frame(width: side, height: side)
                )
            },
            flowBeforeCount: flowNeighbors.before.count,
            flowAfterCount: flowNeighbors.after.count,
            flowArtwork: { offset, side in
                // 0 是正在播的这张(给倒影用的静态那份)，其余是两侧的专辑。
                guard let song = offset == 0 ? player.currentSong : flowNeighbors.song(at: offset) else {
                    return AnyView(ImmersiveArtworkFallback(palette: artworkPalette))
                }
                return AnyView(
                    ZStack {
                        ImmersiveArtworkFallback(palette: artworkPalette)
                        CachedArtworkView(
                            coverRef: song.coverArtFileName,
                            songID: song.id,
                            size: side,
                            cornerRadius: 0,
                            sourceID: song.sourceID,
                            filePath: song.filePath,
                            fileFormat: song.fileFormat,
                            showsPlaceholder: false
                        )
                    }
                    .frame(width: side, height: side)
                )
            },
            flowItemID: { flowNeighbors.itemID(at: $0) },
            flowShift: flowShift,
            isRenderingActive: isSceneActive,
            reduceMotion: reduceMotion,
            lyricsMotionEnabled: lyricsMotionEnabled,
            frameRate: frameRate,
            lyricInterlude: lyricInterlude,
            lyricsPlaceholder: isResolvingLyrics
                ? String(localized: "lyrics_loading")
                : String(localized: "no_lyrics"),
            controlsInset: controlsInset(metrics),
            isResting: isAmbientRest,
            isLowPower: isLowPower,
            showsPlaybackProgress: showsChrome && !isAmbientRest
        ) { side in
            ZStack {
                ImmersiveArtworkFallback(palette: artworkPalette)
                if let song = player.currentSong {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: side,
                        cornerRadius: 0,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        presentationRole: .animatedHero,
                        animationRequiresPlayback: true,
                        isPlaying: player.isPlaying,
                        isAnimationVisible: isSceneActive && !isLowPower,
                        revisionToken: player.coverRevision,
                        onResolutionChange: { hasResolvedArtwork = $0 }
                    )
                    .opacity(hasResolvedArtwork ? 1 : 0)
                }
            }
        }
    }

    /// 画面底部要给控件让出的高度。控件淡出后也保留,避免文字来回跳。
    private func controlsInset(_ metrics: ImmersiveStageMetrics) -> CGFloat {
        switch metrics.layout {
        case .wide:
            metrics.s(presentationEffect.chromeFamily == .deck ? 184 : (presentationEffect.usesShowcaseChrome ? 112 : 142))
        case .phoneLandscape:
            metrics.s(presentationEffect.chromeFamily == .deck ? 116 : (presentationEffect.usesShowcaseChrome ? 76 : 82))
        case .phonePortrait:
            switch presentationEffect.chromeFamily {
            case .deck: metrics.s(218)
            case .standard: metrics.s(178)
            case .lyrics: metrics.s(124)
            case .spectrum: metrics.s(146)
            case .showcase: metrics.s(106)
            }
        }
    }

    // MARK: - 控件

    private func chrome(metrics: ImmersiveStageMetrics) -> some View {
        let topInset = topChromeInset(metrics)
        let bottomInset = max(metrics.safeArea.bottom + 10, 18)
        let bottomClearance = OcclusionAvoidancePolicy.sideClearance(
            regions: occlusions,
            bandMinY: Double(metrics.size.height - bottomInset) - 72,
            bandMaxY: Double(metrics.size.height),
            width: Double(metrics.size.width)
        )
        // 顶部这排圆钮只在遮挡区那一侧让开它(整屏居中的界面不为整条竖栏让位)。
        let clearance = OcclusionAvoidancePolicy.sideClearance(
            regions: occlusions,
            bandMinY: Double(topInset),
            bandMaxY: Double(topInset) + 44,
            width: Double(metrics.size.width)
        )
        return VStack(spacing: 0) {
            // 左右安全区按侧取值:折叠屏的系统竖栏只在一侧,另一侧不该陪着空出同样宽。
            topChrome(metrics: metrics)
            .padding(.leading, max(metrics.safeArea.leading + 16, 20, CGFloat(clearance.leading) + 12))
            .padding(.trailing, max(metrics.safeArea.trailing + 16, 20, CGFloat(clearance.trailing) + 12))
            .padding(.top, topInset)

            if let error = player.lastPlaybackError {
                playbackErrorBanner(error)
                    .padding(.top, 12)
            }

            Spacer()

            // 底部这排也只在遮挡区那一侧让开它(遮挡区贴着屏幕下沿时,例如外屏横握摄像头在右下角)。
            bottomChrome(metrics: metrics)
            .padding(.leading, max(metrics.safeArea.leading + 20, CGFloat(bottomClearance.leading) + 12))
            .padding(.trailing, max(metrics.safeArea.trailing + 20, CGFloat(bottomClearance.trailing) + 12))
            .padding(.bottom, bottomInset)
        }
    }

    @ViewBuilder
    private func topChrome(metrics: ImmersiveStageMetrics) -> some View {
        HStack(spacing: 10) {
            dismissChromeButton
            Spacer()
            effectChromeMenu(metrics: metrics)
            topTrailingChromeControl
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

    /// 舞台的安全区。整屏居中:舞台内容上沿落进遮挡区那段高度时,把上沿推到遮挡区下面,
    /// 两侧都不让;只有推下去要吃掉三成以上的高度时,才退回在遮挡那一侧让开。
    /// 遮挡区贴着屏幕下沿时(外屏横握摄像头在右下角的那个方向)同理:把下沿抬到它上面,抬不动再侧让。
    private func stageSafeArea(_ measured: EdgeInsets, size: CGSize) -> EdgeInsets {
        guard !occlusions.isEmpty else { return measured }
        let height = Double(size.height)
        let upper = occlusions.filter { ($0.minY + $0.maxY) / 2 < height / 2 }
        let lower = occlusions.filter { ($0.minY + $0.maxY) / 2 >= height / 2 }
        var result = measured
        let probe = ImmersiveStageMetrics(size: size, safeArea: measured, isHandheld: isPhoneIdiom)
        let contentTop = probe.stageContentTopInset(isTV: false)
        let clearance = OcclusionAvoidancePolicy.sideClearance(
            regions: upper,
            bandMinY: Double(contentTop),
            bandMaxY: height,
            width: Double(size.width)
        )
        if !clearance.isZero {
            let pushedTop = CGFloat(OcclusionAvoidancePolicy.topEdge(of: upper, height: height)) + 8
            if pushedTop - contentTop <= size.height * 0.3 {
                // 上沿 = max(安全区上沿, 保底值) + 多留的那段;把安全区上沿抬到让上沿正好落在遮挡区下面。
                result.top = max(measured.top, pushedTop - probe.stageContentTopExtra(isTV: false))
            } else {
                result.leading = max(result.leading, CGFloat(clearance.leading))
                result.trailing = max(result.trailing, CGFloat(clearance.trailing))
            }
        }
        if !lower.isEmpty {
            let pushedBottom = CGFloat(OcclusionAvoidancePolicy.bottomExtent(of: lower, height: height)) + 8
            if pushedBottom - measured.bottom <= size.height * 0.3 {
                result.bottom = max(result.bottom, pushedBottom)
            } else {
                let lowerClearance = OcclusionAvoidancePolicy.sideClearance(
                    regions: lower,
                    bandMinY: 0,
                    bandMaxY: height,
                    width: Double(size.width)
                )
                result.leading = max(result.leading, CGFloat(lowerClearance.leading))
                result.trailing = max(result.trailing, CGFloat(lowerClearance.trailing))
            }
        }
        return result
    }

    @ViewBuilder
    private func deckHeader(metrics: ImmersiveStageMetrics) -> some View {
        EmptyView()
    }

    private var outputRouteName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
            ?? String(localized: "now_playing")
    }

    private func topChromeInset(_ metrics: ImmersiveStageMetrics) -> CGFloat {
        Self.topChromeInset(metrics)
    }

    /// 顶部圆钮排的上沿。取证页（`ImmersiveStageEvidenceHost`）按同一个值画控件占位。
    static func topChromeInset(_ metrics: ImmersiveStageMetrics) -> CGFloat {
        if metrics.layout == .phonePortrait {
            return max(metrics.safeArea.top + 10, metrics.s(55))
        }
        return max(metrics.safeArea.top + 10, 18)
    }

    private var dismissChromeButton: some View {
        ImmersiveGlassActionButton(
            symbol: "chevron.down",
            label: "fullscreen_effect_exit",
            tint: chromeInk,
            diameter: 44
        ) {
            chromeTask?.cancel()
            onDismiss()
        }
    }

    /// 开关效果抽屉。抽屉自带滑入滑出的过渡曲线,这里不再包动画事务。
    private func effectChromeMenu(metrics: ImmersiveStageMetrics) -> some View {
        Button {
            showsEffectPicker.toggle()
        } label: {
            ImmersiveGlassActionLabel(
                symbol: "viewfinder.rectangular",
                tint: chromeInk,
                diameter: 44,
                isSelected: effect != .native
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("fullscreen_effect_settings_title"))
    }

    /// 右上角那一格,默认是队列。
    @ViewBuilder
    private var topTrailingChromeControl: some View {
        if let action = chromeControls.action(in: .topTrailing) {
            if action == .queue {
                queueChromeButton
            } else {
                configuredChromeControl(action, placement: .top)
            }
        }
    }

    @ViewBuilder
    private func configuredChromeControl(
        _ action: NowPlayingControlAction,
        placement: ImmersiveChromeControlPlacement
    ) -> some View {
        if let chromeControl {
            chromeControl(action, placement, chromeInk)
                // 点了按钮控件不自动藏起来,和效果页自己的按钮一样。
                .simultaneousGesture(TapGesture().onEnded { revealChrome() })
        }
    }

    /// 播放胶囊里播放键一侧那一格;只摆了一侧时另一侧留同样大的空位,播放键仍在正中。
    @ViewBuilder
    private func pillEdgeControl(_ slot: NowPlayingEffectPlayerSlot) -> some View {
        let actions = chromeControls.actions
        if actions[.pillLeading] != nil || actions[.pillTrailing] != nil {
            if let action = actions[slot], chromeControl != nil {
                configuredChromeControl(action, placement: .pill)
            } else {
                Color.clear
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
            }
        }
    }

    private var queueChromeButton: some View {
        ImmersiveGlassActionButton(
            symbol: "list.bullet",
            label: "queue",
            tint: chromeInk,
            diameter: 44
        ) {
            revealChrome()
            onShowQueue()
        }
    }

    @ViewBuilder
    private func bottomChrome(metrics: ImmersiveStageMetrics) -> some View {
        showcaseControls(metrics: metrics)
    }

    private func showcaseControls(metrics: ImmersiveStageMetrics) -> some View {
        showcaseControlSurface(metrics: metrics)
            .frame(maxWidth: .infinity, alignment: showcaseControlAlignment(metrics))
    }

    @ViewBuilder
    private func showcaseControlSurface(metrics: ImmersiveStageMetrics) -> some View {
        ImmersiveGlassPill(
            horizontalPadding: metrics.s(18),
            verticalPadding: metrics.s(8)
        ) {
            showcaseTransportRow(metrics: metrics, outlinedPlay: true)
        }
    }

    private func showcaseTransportRow(
        metrics: ImmersiveStageMetrics,
        outlinedPlay: Bool
    ) -> some View {
        HStack(spacing: metrics.s(18)) {
            pillEdgeControl(.pillLeading)
            transportButton("backward.fill", size: 17, diameter: 38, label: "a11y_previous_track") {
                Task { await player.previous() }
            }
            playPauseButton(diameter: 48, outlined: outlinedPlay)
            transportButton("forward.fill", size: 17, diameter: 38, label: "a11y_next_track") {
                Task { await player.next() }
            }
            pillEdgeControl(.pillTrailing)
        }
    }

    private func showcaseControlAlignment(_ metrics: ImmersiveStageMetrics) -> Alignment {
        Self.showcaseControlAlignment(effect: presentationEffect, metrics: metrics)
    }

    /// 底部控件胶囊靠哪一边。取证页按同一个值画控件占位。
    static func showcaseControlAlignment(
        effect: FullscreenPlayerEffect,
        metrics: ImmersiveStageMetrics
    ) -> Alignment {
        guard metrics.layout != .phonePortrait else { return .center }
        switch effect {
        case .vinylDeck, .particleBloom:
            return .leading
        case .coverGallery, .flowingLines,
             .radialPulse, .auroraVeil, .spectrumHorizon:
            return .trailing
        case .chladniPlate:
            // 板贴前缘、几乎占满整高，控件放到文字那一侧。
            return .trailing
        case .fireflySync:
            // 文字在左上，右下角是一片空着的草地。
            return .trailing
        case .native, .albumFlow:
            // 封面流的画面左右对称, 控件也居中。
            return .center
        }
    }

    private func deckControls(metrics: ImmersiveStageMetrics, showsTitle: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.s(12)) {
            if showsTitle {
                VStack(alignment: .leading, spacing: metrics.s(3)) {
                    Text(songTitle)
                        .font(.system(size: metrics.s(18), weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(artistName) · \(albumName)")
                        .font(.system(size: metrics.s(10), weight: .medium))
                        .foregroundStyle(pillInk.opacity(0.50))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
            seekBar
            HStack(spacing: metrics.s(12)) {
                transportButton("backward.fill", size: 17, diameter: 40, label: "a11y_previous_track") {
                    Task { await player.previous() }
                }
                playPauseButton(diameter: 54, outlined: true)
                transportButton("forward.fill", size: 17, diameter: 40, label: "a11y_next_track") {
                    Task { await player.next() }
                }
                Spacer(minLength: metrics.s(6))
                Text(audioMetadata.uppercased())
                    .font(.system(size: metrics.s(8), weight: .semibold, design: .monospaced))
                    .tracking(metrics.f(0.8))
                    .foregroundStyle(pillInk.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                AirPlayButton()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel(Text("cast_to_device"))
                queueButton(diameter: 36)
            }
        }
        .foregroundStyle(pillInk)
        .padding(.horizontal, metrics.s(16))
        .padding(.vertical, metrics.s(14))
        .frame(maxWidth: metrics.layout == .phoneLandscape ? 560 : 520)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: metrics.f(14), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.f(14), style: .continuous)
                .strokeBorder(pillInk.opacity(0.18), lineWidth: max(0.6, metrics.f(0.8)))
        }
    }

    private func lyricStageControls(metrics: ImmersiveStageMetrics) -> some View {
        VStack(spacing: metrics.s(8)) {
            seekBar
            HStack(spacing: metrics.s(18)) {
                Image(systemName: "quote.closing")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(artworkPalette.primary.opacity(0.82))
                Spacer()
                transportButton("backward.fill", size: 17, diameter: 38, label: "a11y_previous_track") {
                    Task { await player.previous() }
                }
                playPauseButton(diameter: 52, outlined: true)
                transportButton("forward.fill", size: 17, diameter: 38, label: "a11y_next_track") {
                    Task { await player.next() }
                }
                Spacer()
                queueButton(diameter: 34)
            }
        }
        .frame(maxWidth: 560)
    }

    private func spectrumControls(metrics: ImmersiveStageMetrics) -> some View {
        VStack(spacing: metrics.s(8)) {
            seekBar
            HStack(spacing: metrics.s(18)) {
                modeButton("shuffle", active: player.shuffleEnabled) {
                    player.shuffleEnabled.toggle()
                }
                Spacer()
                transportButton("backward.fill", size: 17, diameter: 38, label: "a11y_previous_track") {
                    Task { await player.previous() }
                }
                playPauseButton(diameter: 54, outlined: true)
                transportButton("forward.fill", size: 17, diameter: 38, label: "a11y_next_track") {
                    Task { await player.next() }
                }
                Spacer()
                modeButton(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                    advanceRepeatMode()
                }
            }
        }
        .frame(maxWidth: 620)
    }

    private var seekBar: some View {
        let displayedTime = seekPreviewTime ?? player.currentTime
        return VStack(spacing: 5) {
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                interactionID: player.currentSong?.id,
                fillTint: seekTint,
                onPreview: { preview in
                    seekPreviewTime = preview
                    isSeeking = preview != nil
                    if preview != nil {
                        registerInteraction(revealControls: true)
                    } else {
                        scheduleChromeHide()
                    }
                },
                onSeek: {
                    revealChrome()
                    player.seek(to: $0)
                }
            )

            HStack {
                Text(displayedTime.formattedDuration)
                Spacer()
                Text(player.duration.formattedDuration)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(ImmersiveStagePalette.ink.opacity(0.42))
        }
    }

    private func playPauseButton(diameter: CGFloat, outlined: Bool) -> some View {
        let emphasis = artworkPalette.primary
        return Button {
            revealChrome()
            guard !player.isLoading else { return }
            player.togglePlayPause()
        } label: {
            ZStack {
                Image(systemName: player.isPlaying || player.isLoading ? "pause.fill" : "play.fill")
                    .font(.system(size: diameter * 0.38, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(player.showsLoadingIndicator ? 0 : 1)
                if player.showsLoadingIndicator {
                    ProgressView()
                        .tint(emphasis)
                }
            }
            .foregroundStyle(emphasis)
            .frame(width: diameter, height: diameter)
            .background(outlined ? emphasis.opacity(0.06) : .clear, in: Circle())
            .overlay {
                if outlined {
                    Circle().strokeBorder(emphasis.opacity(0.72), lineWidth: 1.2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(player.showsLoadingIndicator)
        .accessibilityLabel(player.isPlaying || player.isLoading ? Text("a11y_pause") : Text("a11y_play"))
    }

    private func modeButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            revealChrome()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? artworkPalette.primary : pillInk.opacity(0.54))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

    private func queueButton(diameter: CGFloat) -> some View {
        transportButton("list.bullet", size: 15, diameter: diameter, label: "queue") {
            onShowQueue()
        }
    }

    private func advanceRepeatMode() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
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
                .foregroundStyle(pillInk.opacity(0.88))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var pillInk: Color {
        presentationEffect.prefersLightContent
            ? Color(red: 0.09, green: 0.10, blue: 0.16)
            : ImmersiveStagePalette.ink
    }

    private var seekTint: Color {
        artworkPalette.primary
    }

    private var chromeInk: Color { pillInk }

    // MARK: - 数据

    private var artworkPalette: ImmersiveArtworkPalette {
        ImmersiveArtworkPalette(primary: theme.accentColor, secondary: theme.secondaryDarkAccent)
    }

    private func refreshArtworkInputs() {
        if let song = player.currentSong {
            coverTintProvider.prepare([song])
        }
        refreshGallerySongs()
    }

    /// 封面流两侧随播放队列走：换歌、加歌、调序、开关随机都重取一次。别的效果用不上，不取。
    private func refreshFlowNeighbors() {
        let updated = presentationEffect == .albumFlow
            // 比放得下的多取一张：拖动时最外那张从画布边外滑进来。
            ? player.albumFlowNeighbors(perSide: AlbumFlowLayoutPolicy.maximumNeighborsPerSide + 1)
            : AlbumFlowNeighbors()
        guard updated != flowNeighbors else { return }
        flowNeighbors = updated
        // 换歌落地：整排已按新位置排好，拖动、点按时挪出去的那几格清零，画面不跳。
        flowShift = 0
    }

    /// 每次切歌只取一次稳定样本，避免实时频谱刷新时反复扫描整个资料库。
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
        let limit = min(12, songs.count)
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
                    documentFallback: lyricsWritingDirection
                ),
                background: ImmersiveStageBackgroundLyric.rows(
                    for: lyrics[position],
                    documentFallback: lyricsWritingDirection
                ),
                companions: lyricCompanions(lyrics[position])
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

    private var currentLyricText: String? {
        if let index = activeLyricIndex,
           lyrics.indices.contains(index) {
            return lyrics[index].text
        }
        return lyrics.first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    private var nextLyricText: String? {
        guard let index = activeLyricIndex, index + 1 < lyrics.count else { return nil }
        return lyrics[index + 1].text
    }

    private struct LyricObservationIdentity: Hashable {
        let songID: String?
        let lyricsHash: Int
        let isSceneActive: Bool
        let isPlaying: Bool
        let lyricsMotionEnabled: Bool
    }

    private var lyricObservationIdentity: LyricObservationIdentity {
        LyricObservationIdentity(
            songID: player.currentSong?.id,
            lyricsHash: lyrics.hashValue,
            isSceneActive: isSceneActive,
            isPlaying: player.isPlaying,
            lyricsMotionEnabled: lyricsMotionEnabled
        )
    }

    @MainActor
    private func observeLyricPlayback() async {
        guard isSceneActive else { return }
        guard hasSynchronizedLyrics else {
            updateLyricState(index: nil, isInterlude: false, disableAnimations: true)
            return
        }

        let lookahead = lyrics.contains { $0.isWordLevel }
            ? Self.wordLevelLineLookahead
            : Self.lineLevelLookahead
        updateLyricPlaybackPosition(lookahead: lookahead, disableAnimations: true)
        guard visualActivityPolicy.shouldPollLyrics else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  visualActivityPolicy.shouldPollLyrics else { return }
            updateLyricPlaybackPosition(lookahead: lookahead)
        }
    }

    private func updateLyricPlaybackPosition(
        lookahead: TimeInterval,
        disableAnimations: Bool = false
    ) {
        let playbackTime = player.interpolatedTime()
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
        updateLyricState(
            index: index,
            isInterlude: isInterlude,
            disableAnimations: disableAnimations
        )
    }

    private func updateLyricState(
        index: Int?,
        isInterlude: Bool,
        disableAnimations: Bool
    ) {
        let update = {
            if activeLyricIndex != index { activeLyricIndex = index }
            if lyricInterlude != isInterlude { lyricInterlude = isInterlude }
        }
        if disableAnimations {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else {
            update()
        }
    }

    /// 只转发真实采样结果；静音或无 tap 时保持零值，不生成替代循环。
    /// 由舞台叶子视图按需调用，读取被限制在消费频谱的那一层。
    private var spectrumLevels: [CGFloat] {
        guard visualActivityPolicy.shouldRunVisualizer else { return [] }
        return visualizer.bandLevels.map { min(max(CGFloat($0), 0), 1) }
    }

    private var songTitle: String {
        let value = player.currentSong?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ServerCatalogMetadataInspectionPolicy.hasUsableTitle(value)
            ? value
            : ImmersiveDemoContent.title
    }

    private var artistName: String {
        let value = player.currentSong.flatMap { library.artistDisplayName(for: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return isPlaceholderMetadata(value, localizedKey: "unknown_artist")
            ? ImmersiveDemoContent.artist
            : value
    }

    private var albumName: String {
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

    // MARK: - 手势与 Ambient Rest

    private func isControlZone(_ point: CGPoint, in size: CGSize) -> Bool {
        let topExclusion = max(CGFloat(72), CGFloat(18 + 44))
        let bottomExclusion = max(CGFloat(34), controlsInsetForHitTesting)
        return point.y < topExclusion || point.y > size.height - bottomExclusion
    }

    private var controlsInsetForHitTesting: CGFloat {
        presentationEffect.chromeFamily == .lyrics ? 34 : 112
    }

    private func surfaceDrag(in size: CGSize, metrics: ImmersiveStageMetrics) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                updateAlbumFlowDrag(value, in: size, metrics: metrics)
            }
            .onEnded { value in
                if isDraggingFlow == true {
                    finishAlbumFlowDrag(value, metrics: metrics)
                    return
                }
                isDraggingFlow = nil
                // 抽屉开着时舞台只负责"点一下收起",不再响应切歌与退出。
                guard !showsEffectPicker else { return }
                guard !isControlZone(value.startLocation, in: size) else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard max(abs(horizontal), abs(vertical)) >= 72 else {
                    registerInteraction(revealControls: true)
                    return
                }

                exitAmbientRest()
                if abs(horizontal) > abs(vertical) {
                    if horizontal < 0 {
                        Task { await player.next() }
                    } else {
                        Task { await player.previous() }
                    }
                } else if vertical < 0 {
                    onDismiss()
                } else {
                    onMinimize()
                }
            }
    }

    // MARK: - 封面流(#191)的拖动与点按

    private func albumFlowLayout(_ metrics: ImmersiveStageMetrics) -> AlbumFlowLayoutPolicy.Layout {
        ImmersiveAlbumFlowGeometry.layout(
            metrics: metrics,
            platform: .iOS,
            controlsInset: controlsInset(metrics)
        )
    }

    /// 横向起手就是在拖封面流：整排跟着手走。竖着起手照旧交给上下滑（收起 / 缩小）。
    private func updateAlbumFlowDrag(
        _ value: DragGesture.Value,
        in size: CGSize,
        metrics: ImmersiveStageMetrics
    ) {
        if isDraggingFlow == nil {
            guard presentationEffect == .albumFlow,
                  !showsEffectPicker,
                  !isControlZone(value.startLocation, in: size) else { return }
            let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
            isDraggingFlow = isHorizontal
            guard isHorizontal else { return }
            flowDragOrigin = value.translation.width
            exitAmbientRest()
        }
        guard isDraggingFlow == true else { return }
        flowShift = albumFlowLayout(metrics).dragShift(
            translation: Double(value.translation.width - flowDragOrigin),
            hasBefore: !flowNeighbors.before.isEmpty,
            hasAfter: !flowNeighbors.after.isEmpty
        )
    }

    /// 松手：拖过三分之一格或甩得够快就换到那一边，否则弹回。
    private func finishAlbumFlowDrag(_ value: DragGesture.Value, metrics: ImmersiveStageMetrics) {
        isDraggingFlow = nil
        registerInteraction(revealControls: false)
        let predicted = albumFlowLayout(metrics).dragShift(
            translation: Double(value.predictedEndTranslation.width - flowDragOrigin),
            hasBefore: true,
            hasAfter: true
        )
        let step = AlbumFlowLayoutPolicy.releaseStep(shift: flowShift, predictedShift: predicted)
        guard step != 0 else {
            withAnimation(.smooth(duration: 0.35)) { flowShift = 0 }
            return
        }
        moveAlbumFlow(by: step)
    }

    /// 整排挪 `steps` 格并换到那首。那一边有那张就先把它滑到中间，换歌落地时整排正好接上；
    /// 没有（队首、队尾）就弹回原处，照旧交给上一首 / 下一首决定去哪（例如全部循环时回到队首）。
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

    private var modeMagnification: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.08)
            .onEnded { value in
                // 抽屉就是用来挑效果的,此时再让捏合跳一档只会和转轮打架。
                guard !showsEffectPicker else { return }
                guard abs(value.magnification - 1) >= 0.10 else { return }
                let offset = value.magnification > 1 ? 1 : -1
                effect = effect.advanced(by: offset)
                registerInteraction(revealControls: true)
            }
    }

    /// 休憩层上的歌词行；没有可用歌词时为 nil，休憩层改用歌名顶上。
    private var ambientRestLyric: String? {
        guard let index = activeLyricIndex, lyrics.indices.contains(index) else { return nil }
        let value = lyrics[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 封面流以外的效果里长按永远等不到，点按照旧。
    private var albumFlowLongPressDuration: Double {
        presentationEffect == .albumFlow && onShowAlbum != nil ? 0.5 : 86_400
    }

    /// 封面流(#191)：点中间那张 = 播放 / 暂停，点两侧某一张 = 沿播放顺序跳到那首。点到别处照旧切换控件显隐。
    private func handleAlbumFlowTap(at location: CGPoint, metrics: ImmersiveStageMetrics) -> Bool {
        guard presentationEffect == .albumFlow, !showsEffectPicker, !isAmbientRest else { return false }
        let layout = albumFlowLayout(metrics)
        guard let offset = layout.offset(
            atX: Double(location.x),
            y: Double(location.y),
            before: min(flowNeighbors.before.count, layout.neighborsPerSide),
            after: min(flowNeighbors.after.count, layout.neighborsPerSide),
            tolerance: 8
        ) else { return false }
        if offset == 0 {
            player.togglePlayPause()
        } else {
            moveAlbumFlow(by: offset)
        }
        registerInteraction(revealControls: false)
        return true
    }

    /// 封面流(#191)：长按打开这张专辑的全部歌曲。
    private func handleAlbumFlowLongPress() {
        guard presentationEffect == .albumFlow, !showsEffectPicker, let onShowAlbum else { return }
        exitAmbientRest()
        onShowAlbum()
    }

    private func handleSurfaceTap() {
        // 点抽屉之外的舞台就是收起抽屉,不顺带切换控件显隐。
        if showsEffectPicker {
            showsEffectPicker = false
            return
        }
        if isAmbientRest {
            exitAmbientRest()
            revealChrome()
        } else {
            toggleChrome()
            scheduleAmbientRest()
        }
    }

    private func registerInteraction(revealControls: Bool) {
        exitAmbientRest()
        if revealControls { revealChrome() }
        scheduleAmbientRest()
    }

    private func scheduleAmbientRest() {
        ambientTask?.cancel()
        guard isSceneActive,
              !voiceOverEnabled,
              !showsEffectPicker else { return }
        ambientTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isSceneActive,
                  !voiceOverEnabled,
                  !isSeeking,
                  !showsEffectPicker else { return }
            enterAmbientRest()
        }
    }

    private func enterAmbientRest() {
        guard isSceneActive, !voiceOverEnabled, !showsEffectPicker else { return }
        chromeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.6)) {
            showsChrome = false
            isAmbientRest = true
        }
        startAmbientDrift()
        scheduleLowPower()
    }

    /// 休憩之后再过一阵还没人碰，就降到省电档。
    private func scheduleLowPower() {
        ambientTask?.cancel()
        guard let delay = ImmersiveIdlePowerPolicy.delayToNextStage(from: .resting, restsEarly: true) else { return }
        ambientTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled, isAmbientRest, isSceneActive else { return }
            withAnimation(.easeInOut(duration: 1.2)) { isLowPower = true }
            synchronizeVisualizer()
        }
    }

    /// 防烧屏：休憩时整幅画面隔一阵挪一小步，挪的那几秒缓缓过去，其余时间不重画。
    private func startAmbientDrift() {
        ambientDriftTask?.cancel()
        ambientDriftStep = 0
        guard !reduceMotion else { return }
        ambientDriftTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(ImmersiveIdlePowerPolicy.driftStepInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled, isAmbientRest else { return }
                withAnimation(.easeInOut(duration: ImmersiveIdlePowerPolicy.driftStepDuration)) {
                    ambientDriftStep += 1
                }
            }
        }
    }

    private func ambientDriftOffset(_ metrics: ImmersiveStageMetrics) -> CGSize {
        guard isAmbientRest else { return .zero }
        let step = ImmersiveIdlePowerPolicy.driftOffset(step: ambientDriftStep)
        return CGSize(width: metrics.s(8) * CGFloat(step.x), height: metrics.s(6) * CGFloat(step.y))
    }

    private func exitAmbientRest() {
        guard isAmbientRest else { return }
        ambientDriftTask?.cancel()
        let wasLowPower = isLowPower
        withAnimation(.easeInOut(duration: 0.35)) {
            isAmbientRest = false
            isLowPower = false
            ambientDriftStep = 0
        }
        if wasLowPower { synchronizeVisualizer() }
        // 从休憩里叫醒之后重新计时，下一次没人碰时照样会再休憩。
        scheduleAmbientRest()
    }

    // MARK: - 频谱与控件淡出

    private func synchronizeVisualizer(allowRetry: Bool = true) {
        visualizerRetryTask?.cancel()
        visualizerRetryTask = nil

        guard visualActivityPolicy.shouldRunVisualizer else {
            visualizer.release(owner: visualizerOwnerID)
            return
        }

        guard let engine = player.audioEngine.engineForVisualizer,
              let tapNode = player.audioEngine.visualizerTapNode,
              engine.isRunning else {
            visualizer.release(owner: visualizerOwnerID)
            scheduleVisualizerRetry(allowRetry: allowRetry)
            return
        }

        visualizer.setPacing(frameRate.spectrumPacing(
            displayMaximumFramesPerSecond: ImmersiveDisplayRefresh.maximumFramesPerSecond
        ))
        guard visualizer.acquire(
            owner: visualizerOwnerID,
            engine: engine,
            on: tapNode
        ) else {
            visualizer.release(owner: visualizerOwnerID)
            scheduleVisualizerRetry(allowRetry: allowRetry)
            return
        }
    }

    private func scheduleVisualizerRetry(allowRetry: Bool) {
        guard allowRetry else { return }
        let expectedSongID = player.currentSong?.id
        let expectedEffect = presentationEffect
        visualizerRetryTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  visualActivityPolicy.shouldRunVisualizer,
                  player.currentSong?.id == expectedSongID,
                  presentationEffect == expectedEffect else { return }
            visualizerRetryTask = nil
            synchronizeVisualizer(allowRetry: false)
        }
    }

    private func handleSceneActivityChange(isActive: Bool) {
        chromeTask?.cancel()
        ambientTask?.cancel()
        visualizerRetryTask?.cancel()
        visualizerRetryTask = nil

        ambientDriftTask?.cancel()

        guard isActive else {
            visualizer.release(owner: visualizerOwnerID)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isAmbientRest = false
                isLowPower = false
                ambientDriftStep = 0
            }
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showsChrome = true
            isAmbientRest = false
            isLowPower = false
            ambientDriftStep = 0
        }
        refreshArtworkInputs()
        synchronizeVisualizer()
        scheduleChromeHide()
        scheduleAmbientRest()
    }

    private func toggleChrome() {
        guard isSceneActive, !showsEffectPicker else { return }
        guard !voiceOverEnabled else {
            showsChrome = true
            return
        }
        if showsChrome {
            chromeTask?.cancel()
            withAnimation(.easeInOut(duration: 0.24)) { showsChrome = false }
        } else {
            revealChrome()
        }
    }

    private func revealChrome() {
        guard isSceneActive else { return }
        withAnimation(.easeInOut(duration: 0.2)) { showsChrome = true }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        // 旁白开着时控件必须一直可达,否则用户找不到退出按钮。
        guard !voiceOverEnabled,
              isSceneActive,
              player.isPlaying,
              !isSeeking,
              !showsEffectPicker else { return }
        chromeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(presentationEffect.usesShowcaseChrome ? 5 : 3.5))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  isSceneActive,
                  !voiceOverEnabled,
                  player.isPlaying,
                  !isSeeking,
                  !showsEffectPicker else { return }
            withAnimation(.easeInOut(duration: 0.26)) { showsChrome = false }
        }
    }
}

/// 封面流两侧跟着播放队列走。只在这一层读队列的几个修订号，队列变了才叫一次刷新，
/// 全屏页本身不因为队列里的每次改动重算。
private struct ImmersiveQueueObserver: View {
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

/// Keeps `library.songs` observation out of the full-screen root view.
private struct ImmersiveLibraryCountObserver: View {
    @Environment(MusicLibrary.self) private var library
    let onCountChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: library.songs.count) { _, _ in onCountChange() }
    }
}
/// 全屏效果页上由播放页画的按钮在哪一处:右上角那颗玻璃圆钮,还是底部播放胶囊里。
enum ImmersiveChromeControlPlacement {
    case top
    case pill
}

#endif
