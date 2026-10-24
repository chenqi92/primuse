#if os(tvOS)
import SwiftUI
import PrimuseKit
import UIKit

enum TVImmersiveDirectionalInput: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

enum TVImmersiveDirectionalAction: Equatable, Sendable {
    case previousTrack
    case nextTrack
    case revealControls
    case standardNavigation
    case none
}

struct TVImmersiveDirectionalCommandState: Equatable, Sendable {
    private let quietInterval: TimeInterval
    private var lastObservedTrackEventUptime: TimeInterval?

    init(quietInterval: TimeInterval = 0.45) {
        self.quietInterval = quietInterval
    }

    mutating func action(
        for input: TVImmersiveDirectionalInput,
        at uptime: TimeInterval,
        controlsVisible: Bool,
        modePickerVisible: Bool,
        assistiveNavigationEnabled: Bool
    ) -> TVImmersiveDirectionalAction {
        if modePickerVisible || controlsVisible {
            return .standardNavigation
        }
        if assistiveNavigationEnabled {
            return .revealControls
        }
        switch input {
        case .up, .down:
            return .revealControls
        case .left:
            return acceptsTrackEvent(at: uptime) ? .previousTrack : .none
        case .right:
            return acceptsTrackEvent(at: uptime) ? .nextTrack : .none
        }
    }

    private mutating func acceptsTrackEvent(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite else { return false }
        defer { lastObservedTrackEventUptime = uptime }
        guard let previous = lastObservedTrackEventUptime else { return true }
        guard uptime >= previous else { return false }
        return uptime - previous >= quietInterval
    }
}

struct TVImmersivePresentationActivity: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        case appeared
        case queuePresented
        case queueDismissed
        case dismissalRequested
        case disappeared
    }

    private(set) var isMounted = false
    private(set) var isRenderingActive = false

    mutating func handle(_ event: Event) {
        switch event {
        case .appeared:
            isMounted = true
            isRenderingActive = true
        case .queuePresented:
            isRenderingActive = false
        case .queueDismissed:
            isRenderingActive = isMounted
        case .dismissalRequested, .disappeared:
            isMounted = false
            isRenderingActive = false
        }
    }
}

enum TVImmersiveChromeMotionPolicy {
    static func duration(_ standardDuration: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.01 : standardDuration
    }
}

enum TVImmersiveScreenWakePolicy {
    /// - Parameter systemIdleAllowed: 省电档里又暂停着（`ImmersiveIdlePowerPolicy.holdsScreenAwake`），
    ///   把屏保与休眠交还给系统。
    static func shouldHoldLease(isMounted: Bool, sceneIsActive: Bool, systemIdleAllowed: Bool = false) -> Bool {
        isMounted && sceneIsActive && !systemIdleAllowed
    }
}

@MainActor
private enum TVImmersiveScreenWakeCoordinator {
    private static var owners: Set<UUID> = []

    static func update(ownerID: UUID, shouldHold: Bool) {
        owners = NowPlayingInteractionPolicy.updatedScreenWakeOwners(
            owners,
            ownerID: ownerID,
            shouldHold: shouldHold
        )
        let shouldDisableIdleTimer = !owners.isEmpty
        guard UIApplication.shared.isIdleTimerDisabled != shouldDisableIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldDisableIdleTimer
    }
}

private struct TVImmersiveScreenWakeLeaseModifier: ViewModifier {
    let isMounted: Bool
    var systemIdleAllowed = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var ownerID = UUID()

    private var shouldHoldLease: Bool {
        TVImmersiveScreenWakePolicy.shouldHoldLease(
            isMounted: isMounted,
            sceneIsActive: scenePhase == .active,
            systemIdleAllowed: systemIdleAllowed
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                TVImmersiveScreenWakeCoordinator.update(
                    ownerID: ownerID,
                    shouldHold: shouldHoldLease
                )
            }
            .onChange(of: shouldHoldLease) { _, shouldHold in
                TVImmersiveScreenWakeCoordinator.update(
                    ownerID: ownerID,
                    shouldHold: shouldHold
                )
            }
            .onDisappear {
                TVImmersiveScreenWakeCoordinator.update(ownerID: ownerID, shouldHold: false)
            }
    }
}

/// tvOS 沉浸播放：56pt 安全区、按需显示的次级控制栏与 8 秒静默淡出；
/// 长按选择键展开效果选择，控件隐藏时左右单次切歌，Menu 退出。
/// 15 分钟没碰遥控器就进省电档：压暗、停下装饰动画与频谱，叠上时钟和当前歌词；暂停着就把屏保交还给系统。
struct TVImmersivePlayerView: View {
    var presentsModePickerOnAppear = false

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @Environment(\.resetFocus) private var resetFocus

    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var effectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @AppStorage(ImmersiveFrameRateMode.storageKey)
    private var frameRateRawValue = ImmersiveFrameRateMode.defaultValue.rawValue
    @AppStorage(ImmersiveMotionIntensity.storageKey)
    private var motionIntensityRawValue = ImmersiveMotionIntensity.defaultValue.rawValue
    @AppStorage(ImmersiveEffectRotationMode.storageKey)
    private var rotationModeRawValue = ImmersiveEffectRotationMode.defaultValue.rawValue
    @AppStorage(ImmersiveEffectRotationScope.storageKey)
    private var rotationScopeRawValue = ImmersiveEffectRotationScope.defaultValue.rawValue
    @State private var rotator = ImmersiveEffectRotator()
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient

    @State private var showsChrome = true
    @State private var showsSeekControls = false
    @State private var chromeTask: Task<Void, Never>?
    @State private var lyricObservationTask: Task<Void, Never>?
    @State private var directionalCommandState = TVImmersiveDirectionalCommandState()
    @State private var presentationActivity = TVImmersivePresentationActivity()
    @State private var showsModePicker = false
    /// 控件排 / 风格选择器正在收起:先不接焦点,焦点落到别处以后才开始淡出(见 `yieldChromeFocus`)。
    @State private var chromeYieldsFocus = false
    @State private var modePickerYieldsFocus = false
    @State private var showsQueue = false
    @State private var hasResolvedArtwork = true
    @State private var gallerySongs: [TVSong] = []
    /// 封面流(#191)两侧：队列里刚放过的与接下来的几首；画的时候再转成界面值。
    @State private var flowNeighbors = AlbumFlowNeighbors()
    /// 省电档（`ImmersiveIdlePowerPolicy`）。
    @State private var isLowPower = false
    @State private var idleTask: Task<Void, Never>?
    /// 省电时防烧屏的漂移走到第几步。
    @State private var restDriftStep = 0
    @State private var restDriftTask: Task<Void, Never>?
    @State private var activeLyricIndex: Int?
    @State private var lyricInterlude = false
    @Namespace private var chromeFocus
    @FocusState private var focusedControl: Control?
    @FocusState private var scrubberFocused: Bool
    @FocusState private var wakesChrome: Bool

    private enum Control: Hashable { case previous, playPause, next, modes, queue }

    private var effect: FullscreenPlayerEffect {
        #if DEBUG
        if TVDebugLaunch.screen == "immersivePlayer" {
            if let rawValue = ProcessInfo.processInfo.environment["TV_IMMERSIVE_EFFECT"],
               let requested = FullscreenPlayerEffect(rawValue: rawValue),
               !requested.isNative {
                return requested
            }
            return .coverGallery
        }
        #endif
        return FullscreenPlayerEffect(rawValue: effectRawValue) ?? .defaultValue
    }

    /// 眼前显示的效果:自动轮换换上来的那一种,没轮换时就是所选的。
    private var displayedEffect: FullscreenPlayerEffect {
        rotator.displayedEffect(selected: effect)
    }

    private var rotationMode: ImmersiveEffectRotationMode {
        ImmersiveEffectRotationMode(storedValue: rotationModeRawValue)
    }

    private var rotationSchedule: ImmersiveEffectRotationSchedule {
        ImmersiveEffectRotationSchedule(
            mode: rotationMode,
            displayedEffect: displayedEffect.rawValue,
            isRunning: presentationActivity.isRenderingActive && store.isPlaying && !isLowPower
                && !showsModePicker && !showsQueue
        )
    }

    private var presentationEffect: FullscreenPlayerEffect {
        let raw = ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: displayedEffect.rawValue,
            hasSynchronizedLyrics: hasSynchronizedLyrics,
            hasArtwork: hasResolvedArtwork
        )
        return FullscreenPlayerEffect(rawValue: raw) ?? .coverGallery
    }

    private var artworkPalette: ImmersiveArtworkPalette {
        let playbackColors = store.nowPlayingPresentationColors
        return ImmersiveArtworkPalette(
            primary: coverDrivenAmbient ? playbackColors.primary : TVColor.brand(hex: accentHex),
            secondary: coverDrivenAmbient ? playbackColors.secondary : TVColor.brandSecondary(hex: accentHex)
        )
    }

    private var assistiveNavigationEnabled: Bool {
        voiceOverEnabled || switchControlEnabled
    }

    /// 实际用的帧率与动效强度:电视发热时临时封顶,不改设置(Apple TV 没有低电量模式)。
    private var renderBudget: ImmersiveRenderBudget {
        ImmersiveDeviceConditions.shared.budget(
            frameRate: ImmersiveFrameRateMode(storedValue: frameRateRawValue),
            intensity: ImmersiveMotionIntensity(storedValue: motionIntensityRawValue)
        )
    }

    /// 顶部说明:跟着声音动的效果这首没有频谱、因发热临时降了档。
    private var stageNoticeItems: [ImmersiveStageNoticeItem] {
        var items: [ImmersiveStageNoticeItem] = []
        if presentationEffect.usesRealtimeSpectrum, store.isPlaying, store.engine.isSpectrumSourceUnavailable {
            items.append(.spectrumUnavailable)
        }
        if let power = renderBudget.noticeItem {
            items.append(power)
        }
        return items
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ImmersiveStageMetrics(size: geometry.size, prefersWide: true)

            ZStack {
                stage(metrics: metrics)
                    .scaleEffect(isLowPower ? 1.018 : 1)
                    .offset(restDriftOffset(metrics))
                    .overlay {
                        if isLowPower {
                            Color.black.opacity(ImmersiveIdlePowerPolicy.dimOpacity(for: .lowPower))
                        }
                    }
                    // 换效果时那一下柔焦。
                    .modifier(ImmersiveSoftFocusEffect(
                        softFocus: rotator.softFocus,
                        scale: rotator.focusScale,
                        maximumBlur: metrics.s(22)
                    ))
                    .accessibilityHidden(showsModePicker)

                if isLowPower {
                    TVImmersiveAwayClock(
                        metrics: metrics,
                        title: stageTrack.title,
                        artist: stageTrack.artist
                    )
                    .transition(.opacity)
                }

                // 常驻的透明唤醒层避免焦点树在淡出时被重建；显示控件时禁用，
                // 隐藏控件时承接选择键且关闭系统焦点特效。
                Button {
                    revealChrome()
                } label: {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(TVBareButtonStyle())
                .focused($wakesChrome)
                .focusEffectDisabled()
                .disabled((showsChrome && !chromeYieldsFocus) || (showsModePicker && !modePickerYieldsFocus))
                .accessibilityHidden(showsChrome || showsModePicker)

                if showsChrome {
                    // 选择器盖在上面时这排键看不见,也不能再拿焦点:否则打开选择器后焦点还停在
                    // 「沉浸风格」键上,遥控器只有朝网格那一侧按才进得去。
                    controls(metrics: metrics)
                        .transition(.opacity)
                        .disabled((showsModePicker && !modePickerYieldsFocus) || chromeYieldsFocus)
                        .accessibilityHidden(showsModePicker)
                }

                // 顶部正中:没有实时频谱、临时降档时写明原因。右上角是「返回」提示。
                ImmersiveStageNotice(
                    items: stageNoticeItems,
                    isChromeVisible: showsChrome,
                    isSuppressed: isLowPower || showsModePicker || showsQueue,
                    isTelevision: true
                )
                .padding(.top, 56)
                .padding(.horizontal, 320)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if showsModePicker {
                    modePicker
                        .disabled(modePickerYieldsFocus)
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.30), value: showsChrome)
            .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.26), value: showsModePicker)
            .animation(.easeInOut(duration: reduceMotion ? 0.01 : 1.2), value: isLowPower)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.65)
                    .onEnded { _ in presentModePicker() }
            )
        }
        .ignoresSafeArea()
        .modifier(TVImmersiveScreenWakeLeaseModifier(
            isMounted: presentationActivity.isMounted,
            systemIdleAllowed: !ImmersiveIdlePowerPolicy.holdsScreenAwake(
                stage: isLowPower ? .lowPower : .awake,
                isPlaying: store.isPlaying
            )
        ))
        .onExitCommand {
            // 省电时和屏保一样：第一下只是叫醒，不直接退出全屏页。
            if isLowPower {
                exitLowPower()
                scheduleLowPower()
            } else if showsModePicker {
                guard !modePickerYieldsFocus else { return }
                if effect == .native {
                    dismissImmersivePlayer(reason: "menu-picker-native")
                } else {
                    yieldModePickerFocus()
                    revealChrome()
                }
            } else {
                dismissImmersivePlayer(reason: "menu")
            }
        }
        .onMoveCommand(perform: handleMoveCommand)
        .modifier(TVRemoteTransportModifier(
            shortcutsEnabled: presentationActivity.isRenderingActive && !showsQueue && !showsModePicker
        ) { command in
            guard presentationActivity.isRenderingActive else { return }
            switch command {
            case .togglePlayback:
                revealChrome()
                store.togglePlayPause()
            case .nextTrack:
                revealChrome()
                store.transportForward()
            case .seek:
                guard !store.isLiveRadio, store.duration > 0 else { return }
                showsSeekControls = true
                revealChrome(preferScrubber: true)
            }
        })
        .fullScreenCover(isPresented: $showsQueue, onDismiss: {
            resumePresentation(after: .queueDismissed)
        }) {
            TVQueueView().environment(store)
        }
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            presentationActivity.handle(.appeared)
            let initialPresentation = ImmersiveEffectEntryPolicy.initialPresentation(
                isNativeEffect: effect == .native,
                presentsEffectPicker: presentsModePickerOnAppear
            )
            pdiag("tv immersive appear effect=\(effectRawValue) picker=\(presentsModePickerOnAppear)")
            if initialPresentation.dismissesPlayer {
                dismissImmersivePlayer(reason: "appear-native")
                return
            }
            if initialPresentation.startsPresentationWork {
                resumePresentationWork()
            }
            if initialPresentation.showsEffectPicker {
                chromeTask?.cancel()
                showsChrome = false
                showsModePicker = true
                if !initialPresentation.startsPresentationWork {
                    refreshGallerySongs()
                }
            }
        }
        .onDisappear {
            pdiag("tv immersive disappear effect=\(effectRawValue)")
            suspendPresentation(for: .disappeared)
        }
        .onChange(of: focusedControl) { _, control in
            if control != nil { closeModePickerAfterFocusYielded() }
            // 遥控在传输键之间移动焦点即视为有操作,重置淡出计时。
            if showsChrome, !chromeYieldsFocus {
                scheduleChromeHide()
                scheduleLowPower()
            }
        }
        .onChange(of: wakesChrome) { _, focused in
            if focused { hideChromeAfterFocusYielded() }
        }
        .onChange(of: scrubberFocused) { _, _ in
            scheduleChromeHide()
        }
        .onChange(of: effectRawValue) { _, _ in
            // 所选效果变了(这里选的,或别的设备同步过来的):回到所选的那一种。
            rotator.reset()
            if effect == .native, presentationActivity.isMounted {
                dismissImmersivePlayer(reason: "effect-became-native")
            }
        }
        .onChange(of: rotationModeRawValue) { _, _ in
            if !rotationMode.isEnabled { rotator.reset() }
        }
        .task(id: rotationSchedule) {
            guard let interval = rotationSchedule.interval else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            advanceRotation()
        }
        .onChange(of: presentationEffect) { _, newValue in
            updateSpectrumAnalysis(for: newValue)
            refreshFlowNeighbors()
        }
        .onChange(of: frameRateRawValue) { _, _ in
            updateSpectrumAnalysis(for: presentationEffect)
        }
        .onChange(of: renderBudget.frameRate) { _, _ in
            // 发热开始或解除:频谱的发布节奏跟着实际帧率走。
            updateSpectrumAnalysis(for: presentationEffect)
        }
        .onChange(of: showsModePicker) { _, _ in
            updateSpectrumAnalysis(for: presentationEffect)
        }
        .onChange(of: store.nowPlaying.songID) { _, _ in
            refreshGallerySongs()
            if rotationMode == .perSong, presentationActivity.isRenderingActive,
               !showsModePicker, !showsQueue {
                advanceRotation()
            } else if presentationActivity.isRenderingActive {
                rotator.settleAfterSongChange(on: presentationEffect, isEnabled: !reduceMotion && !isLowPower)
            }
        }
        .onChange(of: lyricObservationIdentity) { _, _ in
            guard presentationActivity.isRenderingActive else { return }
            restartLyricObservation()
        }
        .onChange(of: voiceOverEnabled) { _, _ in
            assistiveNavigationDidChange()
        }
        .onChange(of: switchControlEnabled) { _, _ in
            assistiveNavigationDidChange()
        }
        .background {
            TVImmersiveLibraryCountObserver {
                refreshGallerySongs()
            }
        }
        .background {
            TVImmersiveQueueObserver {
                refreshFlowNeighbors()
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    // MARK: - 画面

    private func stage(metrics: ImmersiveStageMetrics) -> some View {
        let np = store.nowPlaying
        return ImmersiveStageView(
            style: presentationEffect,
            platform: .tvOS,
            metrics: metrics,
            track: stageTrack,
            playbackTime: { lyricPlaybackTime },
            palette: artworkPalette,
            lyricWindow: lyricWindow,
            currentLyric: currentLyric,
            nextLyric: nextLyric,
            lyricsWritingDirection: store.lyrics.first?.writingDirection ?? .natural,
            levelsProvider: { spectrumLevels },
            scheduledLevelsProvider: scheduledSpectrumLevelsProvider,
            galleryArtworkCount: gallerySongs.count,
            galleryArtwork: { index, side in
                guard gallerySongs.indices.contains(index) else { return AnyView(Color.clear) }
                let song = gallerySongs[index]
                let album = store.album(song.albumID)
                let colors = store.artworkColors(forSongID: song.id)
                return AnyView(
                    TVArtworkView(
                        coverKey: song.albumID,
                        artist: song.artist,
                        album: album?.title ?? "",
                        songID: song.id,
                        coverRef: song.coverRef,
                        tint: colors?.primary ?? album?.tint ?? np.tint,
                        tint2: colors?.secondary ?? album?.tint2 ?? np.tint2,
                        glyph: album?.glyph ?? "music.note",
                        size: side,
                        radius: 0
                    )
                    .frame(width: side, height: side)
                )
            },
            flowBeforeCount: flowNeighbors.before.count,
            flowAfterCount: flowNeighbors.after.count,
            flowArtwork: { offset, side in
                // 0 是正在播的这张(给倒影用的静态那份)，其余是封面流两侧的专辑。
                let source = offset == 0
                    ? store.library.song(id: np.songID)
                    : flowNeighbors.song(at: offset)
                guard let source else {
                    return AnyView(ImmersiveArtworkFallback(palette: artworkPalette))
                }
                let song = store.songs.mapper.map(source)
                let album = store.album(song.albumID)
                let colors = store.artworkColors(forSongID: song.id)
                return AnyView(
                    TVArtworkView(
                        coverKey: song.albumID,
                        artist: song.artist,
                        album: album?.title ?? "",
                        songID: song.id,
                        coverRef: song.coverRef,
                        tint: colors?.primary ?? album?.tint ?? np.tint,
                        tint2: colors?.secondary ?? album?.tint2 ?? np.tint2,
                        glyph: album?.glyph ?? "music.note",
                        size: side,
                        radius: 0
                    )
                    .frame(width: side, height: side)
                    // 卡片滑进滑出中间时会在曲库封面和这首的封面之间换图:旧图淡出、新图淡入,
                    // 不让新图读出来之前先闪一下占位。
                    .id(song.id)
                    .transition(.opacity)
                )
            },
            flowItemID: { flowNeighbors.itemID(at: $0) },
            // 选择器几乎整屏盖住舞台:停下背后的整套动画,选择器里的预览和焦点动画才不掉帧。
            isRenderingActive: presentationActivity.isRenderingActive && !showsModePicker,
            reduceMotion: reduceMotion,
            lyricsMotionEnabled: lyricsMotionEnabled,
            frameRate: renderBudget.frameRate,
            motionIntensity: renderBudget.intensity,
            lyricInterlude: lyricInterlude,
            lyricsPlaceholder: PMString("ext.tv.nowPlaying.noLyrics"),
            visualizerDisclosure: PMString("ext.tv.immersive.timelineDisclosure"),
            controlsInset: metrics.s(150),
            isResting: isLowPower,
            isLowPower: isLowPower,
            showsPlaybackProgress: showsChrome,
            chromeBlurRadius: 60
        ) { side in
            if np.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ImmersiveArtworkFallback(
                    palette: artworkPalette
                )
            } else {
                ZStack {
                    ImmersiveArtworkFallback(
                        palette: artworkPalette
                    )
                    TVArtworkView(
                        coverKey: np.albumID,
                        artist: np.artist,
                        album: np.album,
                        songID: np.songID,
                        coverRef: np.coverRef,
                        tint: np.tint,
                        tint2: np.tint2,
                        glyph: np.glyph,
                        size: side,
                        radius: 0,
                        presentationRole: .animatedHero,
                        animationRequiresPlayback: true,
                        isPlaying: store.isPlaying,
                        isAnimationVisible: !showsModePicker && !showsQueue && !isLowPower,
                        onResolutionChange: { hasResolvedArtwork = $0 }
                    )
                    .opacity(hasResolvedArtwork ? 1 : 0)
                }
            }
        }
    }

    // MARK: - 控件

    private func controls(metrics: ImmersiveStageMetrics) -> some View {
        VStack {
            HStack {
                Spacer()
                Label(PMString("ext.tv.immersive.exitHint"), systemImage: "arrow.uturn.backward")
                    // 展示屏的字号统一走 metrics 等比缩放,与同屏其它文字保持一致
                    .font(.system(size: metrics.s(20), weight: .medium))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.5))
            }
            .padding(.horizontal, 56)
            .padding(.top, 56)

            Spacer()

            if showsSeekControls, !store.isLiveRadio, store.duration > 0 {
                tvProgress
                    .frame(maxWidth: 1200)
                    .padding(.horizontal, 112)
                    .padding(.bottom, 24)
            }

            tvBottomControls(metrics: metrics)
                .padding(.horizontal, 112)
                .padding(.bottom, 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusScope(chromeFocus)
    }

    @ViewBuilder
    private func tvBottomControls(metrics: ImmersiveStageMetrics) -> some View {
        tvShowcaseControlSurface(metrics: metrics)
            .frame(maxWidth: .infinity, alignment: tvShowcaseControlAlignment)
    }

    @ViewBuilder
    private func tvShowcaseControlSurface(metrics: ImmersiveStageMetrics) -> some View {
        ImmersiveGlassPill(
            horizontalPadding: metrics.s(22),
            verticalPadding: metrics.s(10),
            clipsContent: false
        ) {
            HStack(spacing: metrics.s(18)) {
                transportControls(surface: .bare)
                Divider()
                    .frame(height: metrics.s(48))
                    .overlay(.white.opacity(0.22))
                modeAndQueueControls(surface: .bare)
            }
        }
    }

    private var tvShowcaseControlAlignment: Alignment {
        switch presentationEffect {
        case .radialPulse, .vinylDeck, .particleBloom:
            .leading
        case .coverGallery, .flowingLines,
             .auroraVeil, .spectrumHorizon:
            .trailing
        case .chladniPlate:
            // 板贴前缘、几乎占满整高，控件放到歌词那一侧。
            .trailing
        case .fireflySync:
            // 非竖屏歌词居中在上面那截夜空，右下角是一片空着的草地。
            .trailing
        case .flyBrain:
            // 歌词列在前缘、底下是数据来源，控件放到大脑那一侧的下方。
            .trailing
        case .native, .albumFlow, .kineticLyrics:
            .center
        }
    }

    private var tvProgress: some View {
        VStack(spacing: 10) {
            TVScrubber(
                progress: store.duration > 0 ? min(1, max(0, store.currentTime / store.duration)) : 0,
                tint: TVColor.brand, immersiveDark: true,
                currentTime: store.currentTime, duration: store.duration,
                onBack: { store.skipBackward() }, onForward: { store.skipForward() },
                onInteraction: scheduleChromeHide,
                onFinish: { revealChrome() }, focused: $scrubberFocused
            )
            HStack {
                Text(store.currentTime.formattedDuration)
                Spacer()
                Text(store.duration.formattedDuration)
            }
            .tvFont(.meta, weight: .medium, design: .monospaced)
            .foregroundStyle(ImmersiveStagePalette.text.opacity(0.48))
        }
    }

    private func transportControls(surface: ControlSurface) -> some View {
        let availability = store.trackNavigationAvailability
        // 有声内容:上一首 / 下一首换成后退 15 秒 / 前进 30 秒。
        let isSpokenWord = store.currentItemIsSpokenWord
        return HStack(spacing: 22) {
            controlButton(
                .previous,
                icon: isSpokenWord ? "gobackward.15" : "backward.fill",
                accessibilityLabel: isSpokenWord
                    ? String(localized: "spoken_word_skip_backward")
                    : PMString("ext.control.previous"),
                surface: surface,
                diameter: 66
            ) { store.transportBackward() }
                .disabled(!isSpokenWord && !availability.canGoPrevious)
            controlButton(
                .playPause,
                icon: store.isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: PMString(
                    store.isPlaying ? "ext.control.pause" : "ext.control.play"
                ),
                surface: surface,
                diameter: 66
            ) {
                store.togglePlayPause()
            }
            controlButton(
                .next,
                icon: isSpokenWord ? "goforward.30" : "forward.fill",
                accessibilityLabel: isSpokenWord
                    ? String(localized: "spoken_word_skip_forward")
                    : PMString("ext.control.next"),
                surface: surface,
                diameter: 66
            ) { store.transportForward() }
                .disabled(!isSpokenWord && !availability.canGoNext)
        }
    }

    private func modeAndQueueControls(surface: ControlSurface) -> some View {
        HStack(spacing: 16) {
            controlButton(
                .modes,
                icon: "square.grid.2x2",
                accessibilityLabel: PMString("ext.tv.settings.immersive"),
                surface: surface,
                diameter: 60
            ) {
                presentModePicker()
            }
            controlButton(
                .queue,
                icon: "list.bullet",
                accessibilityLabel: PMString("queue_title"),
                surface: surface,
                diameter: 60
            ) {
                presentQueue()
            }
        }
    }

    private enum ControlSurface { case bare, outlined, tile }

    private func controlButton(
        _ control: Control,
        icon: String,
        accessibilityLabel: String,
        surface: ControlSurface = .tile,
        primary: Bool = false,
        diameter: CGFloat = 76,
        action: @escaping () -> Void
    ) -> some View {
        let focused = focusedControl == control
        let radius = surface == .tile ? 10.0 : diameter / 2
        return Button {
            scheduleChromeHide()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: primary ? 31 : 27, weight: .medium))
                .foregroundStyle(Color.white.opacity(focused ? 1 : 0.86))
                .frame(width: diameter, height: diameter)
                .background {
                    if surface == .tile {
                        RoundedRectangle(cornerRadius: radius)
                            .fill(.black.opacity(focused ? 0.34 : 0.22))
                    } else if focused {
                        Circle().fill(.white.opacity(0.10))
                    }
                }
                .overlay {
                    if surface == .tile {
                        RoundedRectangle(cornerRadius: radius)
                            .strokeBorder(
                                primary ? artworkPalette.primary.opacity(0.76) : .white.opacity(0.24),
                                lineWidth: primary ? 1.8 : 1
                            )
                    } else if surface == .outlined {
                        Circle()
                            .strokeBorder(artworkPalette.primary.opacity(0.72), lineWidth: primary ? 2.4 : 1.2)
                    }
                }
                .tvFocusRing(focused, radius: radius, accent: .white, scale: 1.10, lift: 7)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedControl, equals: control)
        .focusEffectDisabled()
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    /// 沉浸模式里的风格切换直接复用设置页那套带效果预览的选择器,
    /// 不再另画一套只有图标和文字的简版列表——两处入口看到的应当是同一个页面。
    private var modePicker: some View {
        TVFullscreenEffectPicker(
            // 高亮眼前显示的那一种;选了就记成所选的效果,轮换换上来的作废。
            selectedRawValue: Binding(
                get: { rotator.highlightedEffect(selected: effect).rawValue },
                set: { value in
                    if value != displayedEffect.rawValue {
                        rotator.beginManualChange(from: displayedEffect, reduceMotion: reduceMotion)
                    } else {
                        rotator.reset()
                    }
                    effectRawValue = value
                }
            ),
            lyricsMotionEnabled: $lyricsMotionEnabled,
            onDismiss: finishModePicker
        )
    }

    private func finishModePicker() {
        // 选的是「原生」:原生就是播放页本身,全屏页上没有可放的,直接退出。从别的效果换成原生时
        // effectRawValue 的 onChange 随后也会来退,它看到已经不在挂载状态就不再重复。本来就是
        // 原生、又点了一次「原生」时值没变,没有那次 onChange —— 以前这里只收起选择器,
        // 全屏页就空着停在那里,只有按 Menu 才回得去。
        guard effect != .native else {
            showsModePicker = false
            if presentationActivity.isMounted { dismissImmersivePlayer(reason: "picker-native") }
            return
        }
        yieldModePickerFocus()
        if lyricObservationTask == nil { resumePresentationWork() }
        revealChrome()
    }

    /// 收起风格选择器的第一步:选择器不再接焦点、控件排接回来;焦点落到控件排上以后
    /// (`closeModePickerAfterFocusYielded`)再淡出,理由同 `scheduleChromeHide`。
    /// 一直等不到焦点也不把选择器晾在屏幕上:稍后不带动画直接拿掉。
    private func yieldModePickerFocus() {
        modePickerYieldsFocus = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            closeModePickerAfterFocusYielded(animated: false)
        }
    }

    private func closeModePickerAfterFocusYielded(animated: Bool = true) {
        guard showsModePicker, modePickerYieldsFocus else { return }
        if animated {
            showsModePicker = false
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { showsModePicker = false }
        }
        // 选择器开着时淡出计时不走(`scheduleChromeHide` 的守卫),这会儿才重新开始。
        scheduleChromeHide()
    }

    // MARK: - 数据

    private var stageTrack: ImmersiveStageTrack {
        let np = store.nowPlaying
        return ImmersiveStageTrack(
            title: meaningful(np.title, fallback: ImmersiveDemoContent.title),
            artist: meaningful(np.artist, fallback: ImmersiveDemoContent.artist),
            album: meaningful(np.album, fallback: ImmersiveDemoContent.album),
            format: formatLine(np),
            isPlaying: store.isPlaying,
            progress: 0,
            trackNumber: 1,
            trackCount: store.queueUpNextIDs.count + 1,
            elapsed: 0,
            duration: store.duration,
            source: "Primuse TV",
            queueSummary: PMString("ext.tv.songsCount", store.queueUpNextIDs.count + 1)
        )
    }

    /// 封面流两侧随播放队列走。别的效果用不上，不取。
    private func refreshFlowNeighbors() {
        let updated = presentationEffect == .albumFlow
            // 比放得下的多取一张，换歌滑动时最外那张从画布边外进来。
            ? store.albumFlowNeighbors(perSide: AlbumFlowLayoutPolicy.maximumNeighborsPerSide + 1)
            : AlbumFlowNeighbors()
        if updated != flowNeighbors { flowNeighbors = updated }
    }

    private func refreshGallerySongs() {
        refreshFlowNeighbors()
        let currentID = store.nowPlaying.songID
        // 在曲库原始数组上筛,只把最后选中的十几首转成界面值,不为整库逐首转换。
        let library = store.songs
        let eligible = library.source.filter { song in
            song.id != currentID
                && !(song.coverArtFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard !eligible.isEmpty else {
            gallerySongs = []
            return
        }

        let limit = min(14, eligible.count)
        let seedText = currentID.isEmpty ? "primuse" : currentID
        let seed = seedText.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let start = seed % eligible.count
        let rawStride = max(1, eligible.count / max(limit, 1))
        let step = rawStride.isMultiple(of: 2) ? rawStride + 1 : rawStride
        var selected: [TVSong] = []
        var seen: Set<String> = []
        var cursor = start
        var attempts = 0
        while selected.count < limit && attempts < eligible.count * 2 {
            let song = eligible[cursor % eligible.count]
            if seen.insert(song.id).inserted { selected.append(library.mapper.map(song)) }
            cursor += step
            attempts += 1
        }
        if selected.count < limit {
            for song in eligible where seen.insert(song.id).inserted {
                selected.append(library.mapper.map(song))
                if selected.count == limit { break }
            }
        }
        gallerySongs = selected
    }

    private func meaningful(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        return trimmed.isEmpty
            || ["unknown", "unknown title", "unknown artist", "unknown album", "未知", "未知标题", "未知艺术家", "未知专辑"].contains(normalized)
            ? fallback
            : trimmed
    }

    /// 与 iPhone 沉浸页同一套规格串:格式按读出来的编码(M4A 里的 ALAC / AAC),
    /// hi-res 按采样率与实际位深判,不再见 FLAC 就写 hi-res。
    private func formatLine(_ np: TVNowPlaying) -> String {
        let playingSampleRate = np.sampleRate > 0 ? Int((np.sampleRate * 1_000).rounded()) : nil
        guard let song = store.library.song(id: np.songID) else {
            return ImmersiveAudioSpec.line(format: np.format, sampleRate: playingSampleRate, bitDepth: nil)
        }
        return ImmersiveAudioSpec.line(
            format: song.codecFormat.displayName,
            sampleRate: song.sampleRate.flatMap { $0 > 0 ? $0 : nil } ?? playingSampleRate,
            bitDepth: song.qualityBitDepth,
            audioVariants: song.audioVariants
        )
    }

    private var hasSynchronizedLyrics: Bool {
        store.lyricsFollowPlayback
    }

    private var lyricWindow: [ImmersiveStageLyric] {
        guard let index = activeLyricIndex,
              store.lyrics.indices.contains(index) else { return [] }
        let lower = max(0, index - 1)
        let upper = min(store.lyrics.count, index + 4)
        let romanization = TVLyricsRomanizationController.shared
        return (lower..<upper).compactMap { position in
            // 按「罗马音显示」换过正文或附属罗马音；时间仍按原来那一行。
            let line = romanization.displayLine(store.lyrics[position], songID: store.currentSongID)
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ImmersiveStageLyric(
                id: position,
                text: text,
                isActive: position == index,
                offset: position - index,
                syllables: immersiveSyllables(for: line),
                startTime: line.isSynchronized ? line.time : nil,
                endTime: immersiveLineEnd(at: position, line: line),
                writingDirection: line.writingDirection,
                background: line.background.compactMap { background in
                    let text = background.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return ImmersiveStageBackgroundLyric(
                        id: background.id,
                        text: text,
                        syllables: immersiveSyllables(for: background),
                        startTime: background.isSynchronized ? background.time : nil,
                        endTime: background.syllables.last.map {
                            LyricSyllablePlaybackTimingPolicy.effectiveEnd(for: $0.lyricSyllable)
                        },
                        writingDirection: background.writingDirection
                    )
                },
                companions: [
                    line.romanization,
                    line.translation,
                ].map(LyricCompanionTextPolicy.displayText)
            )
        }
    }

    private func immersiveLineEnd(at position: Int, line: TVLyricLine) -> TimeInterval? {
        guard line.isSynchronized else { return nil }
        if store.lyrics.indices.contains(position + 1) {
            let next = store.lyrics[position + 1].time
            if next > line.time { return next }
        }
        guard let lastSyllable = line.syllables.last else { return line.time + 3.5 }
        return max(
            line.time + 3.5,
            LyricSyllablePlaybackTimingPolicy.effectiveEnd(for: lastSyllable.lyricSyllable)
        )
    }

    private var currentLyric: String? {
        if let index = activeLyricIndex,
           store.lyrics.indices.contains(index) {
            return store.lyrics[index].text
        }
        return store.lyrics.first {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text
    }

    private func immersiveSyllables(for line: TVLyricLine) -> [LyricSyllable]? {
        guard !line.syllables.isEmpty else { return nil }
        return line.syllables.map(\.lyricSyllable)
    }

    private var nextLyric: String? {
        guard let index = activeLyricIndex,
              index + 1 < store.lyrics.count else { return nil }
        return store.lyrics[index + 1].text
    }

    private var lyricObservationIdentity: String {
        "\(store.nowPlaying.songID)|\(store.lyricsRevision)|\(lyricsMotionEnabled)"
    }

    private var lyricPlaybackTime: TimeInterval {
        #if DEBUG
        if TVDebugLaunch.screen == "immersivePlayer",
           let rawValue = ProcessInfo.processInfo.environment["TV_EVIDENCE_PLAYBACK_TIME"],
           let value = TimeInterval(rawValue), value.isFinite {
            return max(0, value)
        }
        #endif
        // 与 iPhone / Mac 的 `player.interpolatedTime()` 对齐:歌词扫光按帧推进,
        // 不能只吃 AVPlayer 每 0.25 秒一次的回调值。
        return store.interpolatedTime()
    }

    @MainActor
    private func observeLyricPlayback() async {
        guard hasSynchronizedLyrics else { return }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            updateLyricPlaybackPosition()
        }
    }

    private func updateLyricPlaybackPosition(disablesAnimations: Bool = false) {
        var index: Int?
        var isInterlude = false
        if hasSynchronizedLyrics {
            let playbackTime = lyricPlaybackTime
            index = LyricPlaybackPositionPolicy.activeLineIndex(
                in: store.lyrics,
                at: playbackTime,
                lookahead: 0.25,
                timestamp: \.time
            )
            if lyricsMotionEnabled,
               let index,
               store.lyrics.indices.contains(index) {
                let line = store.lyrics[index]
                let estimatedEnd = line.syllables.last.map {
                    LyricSyllablePlaybackTimingPolicy.effectiveEnd(for: $0.lyricSyllable)
                } ?? (line.time + 3.5)
                isInterlude = playbackTime - estimatedEnd > 6
            }
        }

        let update = {
            if activeLyricIndex != index { activeLyricIndex = index }
            if lyricInterlude != isInterlude { lyricInterlude = isInterlude }
        }
        if disablesAnimations {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        } else {
            update()
        }
    }

    private func restartLyricObservation() {
        lyricObservationTask?.cancel()
        lyricObservationTask = nil
        guard presentationActivity.isRenderingActive else { return }
        // 进全屏、换歌、从队列回来时当场定好当前句，不带过渡。等观察任务头一回报要晚几帧，
        // 那几帧舞台会先摆出歌词第一行（不少 LRC 是「歌名 - 歌手」），再和真正的当前句叠着淡入淡出。
        updateLyricPlaybackPosition(disablesAnimations: true)
        lyricObservationTask = Task { @MainActor in
            await observeLyricPlayback()
        }
    }

    /// 由舞台叶子视图按需调用，频谱的读取与重算都限制在消费它的那一层。
    private var spectrumLevels: [CGFloat] {
        guard presentationEffect.usesRealtimeSpectrum else { return [] }
        return store.engine.spectrumLevels.map { min(max(CGFloat($0), 0), 1) }
    }

    /// 由 TimelineView 定节奏的层（沙画、萤火、神经共鸣、星尘粒子、涟漪）读这一份，不建立观察；
    /// 否则每发布一次频谱就在时间表之外多画一遍，电视上的帧率上限不起作用。
    /// 频谱环、能量光晕这些靠发布驱动重画的层仍读 `spectrumLevels`。
    private var scheduledSpectrumLevelsProvider: @MainActor () -> [CGFloat] {
        guard presentationEffect.usesRealtimeSpectrum else { return { [] } }
        let engine = store.engine
        return { @MainActor in
            engine.latestSpectrumLevels.map { min(max(CGFloat($0), 0), 1) }
        }
    }

    private func updateSpectrumAnalysis(for presentation: FullscreenPlayerEffect) {
        var pacing = renderBudget.frameRate.spectrumPacing(
            displayMaximumFramesPerSecond: ImmersiveDisplayRefresh.maximumFramesPerSecond
        )
        // 环形声谱的整屏光晕和整块模糊的那层频谱环都随频谱发布重画，每发布一次系统都要整屏重新
        // 模糊、合成一遍。60 帧档下 A15 发热后 GPU 几乎一直满载（大头在系统合成），回调只剩 33 次；
        // 电视上这个效果每秒最多发布 30 次。
        if presentation == .radialPulse {
            pacing = pacing.limited(toFramesPerSecond: 30)
        }
        store.engine.setSpectrumPacing(pacing)
        store.engine.setSpectrumAnalysisEnabled(
            presentationActivity.isRenderingActive
                && !isLowPower
                && !showsModePicker
                && effect != .native
                && presentation.usesRealtimeSpectrum
        )
    }

    // MARK: - 生命周期、遥控与控件淡出

    private func resumePresentation(after event: TVImmersivePresentationActivity.Event) {
        presentationActivity.handle(event)
        guard presentationActivity.isRenderingActive else { return }
        resumePresentationWork()
    }

    private func resumePresentationWork() {
        refreshGallerySongs()
        restartLyricObservation()
        updateSpectrumAnalysis(for: presentationEffect)
        if assistiveNavigationEnabled {
            revealChrome()
        } else {
            scheduleChromeHide()
        }
        scheduleLowPower()
    }

    private func suspendPresentation(for event: TVImmersivePresentationActivity.Event) {
        presentationActivity.handle(event)
        lyricObservationTask?.cancel()
        lyricObservationTask = nil
        chromeTask?.cancel()
        chromeTask = nil
        idleTask?.cancel()
        idleTask = nil
        restDriftTask?.cancel()
        restDriftTask = nil
        if isLowPower {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isLowPower = false
                restDriftStep = 0
            }
        }
        store.engine.setSpectrumAnalysisEnabled(false)
    }

    /// `reason` 记进诊断日志:全屏效果「进去一秒又退回来」时(看板 PRIM-40)要知道是谁关的;
    /// 没有这一行的关闭来自外面(播放页把 `showImmersive` 放回了 false)。
    private func dismissImmersivePlayer(reason: StaticString) {
        pdiag("tv immersive dismiss reason=\(reason) effect=\(effectRawValue)")
        suspendPresentation(for: .dismissalRequested)
        dismiss()
    }

    private func presentQueue() {
        suspendPresentation(for: .queuePresented)
        showsQueue = true
    }

    /// 自动轮换到下一种(#312)。不叫出控件:轮换是给不碰遥控器时看的。
    private func advanceRotation() {
        rotator.advance(
            selected: effect,
            scope: ImmersiveEffectRotationScope(storedValue: rotationScopeRawValue),
            reduceMotion: reduceMotion
        )
    }

    private func selectEffect(_ value: FullscreenPlayerEffect) {
        if value != displayedEffect {
            rotator.beginManualChange(from: displayedEffect, reduceMotion: reduceMotion)
        } else {
            rotator.reset()
        }
        withAnimation(.easeInOut(duration: TVImmersiveChromeMotionPolicy.duration(
            0.28,
            reduceMotion: reduceMotion
        ))) {
            effectRawValue = value.rawValue
        }
        FullscreenPlayerEffectSync.shared.select(value)
        if value == .native {
            dismissImmersivePlayer(reason: "picked-native")
        } else if lyricObservationTask == nil {
            resumePresentationWork()
        }
    }

    private func presentModePicker() {
        guard presentationActivity.isRenderingActive else { return }
        chromeTask?.cancel()
        chromeYieldsFocus = false
        modePickerYieldsFocus = false
        showsChrome = true
        showsModePicker = true
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        // 省电时第一下只是叫醒，不在黑着的屏幕上切歌。
        if isLowPower {
            exitLowPower()
            scheduleLowPower()
            return
        }
        scheduleLowPower()
        let input: TVImmersiveDirectionalInput
        switch direction {
        case .left: input = .left
        case .right: input = .right
        case .up: input = .up
        case .down: input = .down
        default: return
        }
        let action = directionalCommandState.action(
            for: input,
            at: ProcessInfo.processInfo.systemUptime,
            controlsVisible: showsChrome,
            modePickerVisible: showsModePicker,
            assistiveNavigationEnabled: assistiveNavigationEnabled
        )
        switch action {
        case .previousTrack:
            // 封面流里左边那张就是上一首：直接回到它，不先回到这首开头。
            store.transportBackward(restartCurrentIfNeeded: presentationEffect != .albumFlow)
        case .nextTrack:
            store.transportForward()
        case .revealControls:
            revealChrome()
        case .standardNavigation:
            if !showsModePicker { scheduleChromeHide() }
        case .none:
            break
        }
    }

    private func revealChrome(preferScrubber: Bool = false) {
        guard presentationActivity.isRenderingActive else { return }
        exitLowPower()
        scheduleLowPower()
        wakesChrome = false
        chromeYieldsFocus = false
        withAnimation(.easeInOut(duration: TVImmersiveChromeMotionPolicy.duration(
            0.24,
            reduceMotion: reduceMotion
        ))) {
            showsChrome = true
        }
        Task { @MainActor in
            await Task.yield()
            guard presentationActivity.isRenderingActive else { return }
            resetFocus(in: chromeFocus)
            if preferScrubber {
                focusedControl = nil
                scrubberFocused = true
            } else {
                scrubberFocused = false
                focusedControl = .playPause
            }
        }
        scheduleChromeHide()
    }

    private func assistiveNavigationDidChange() {
        guard presentationActivity.isRenderingActive else { return }
        if assistiveNavigationEnabled {
            revealChrome()
        } else {
            scheduleChromeHide()
        }
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        chromeTask = nil
        #if DEBUG
        if TVDebugLaunch.screen == "immersivePlayer",
           ProcessInfo.processInfo.environment["TV_IMMERSIVE_EFFECT"] != nil {
            return
        }
        #endif
        guard presentationActivity.isRenderingActive,
              !showsModePicker, !scrubberFocused,
              !assistiveNavigationEnabled else { return }
        chromeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(presentationEffect.usesShowcaseChrome ? 5 : 8))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  presentationActivity.isRenderingActive,
                  !showsModePicker, !scrubberFocused,
                  !assistiveNavigationEnabled else { return }
            yieldChromeFocus()
        }
    }

    /// 控件排淡出的第一步:控件排不再接焦点,焦点交给唤醒层;焦点到了(`wakesChrome`)
    /// 再由 `hideChromeAfterFocusYielded` 淡出。淡出放完那一下控件排才真正拿掉,焦点要是
    /// 还停在里面、又正好碰上一次焦点更新(电视主线程忙时常有),UIKit 会判定「焦点项所在的
    /// 视图在焦点切换途中被移除」而断言闪退。一直等不到焦点也不把控件排留着:稍后不带动画直接拿掉。
    private func yieldChromeFocus() {
        guard showsChrome else { return }
        chromeYieldsFocus = true
        Task { @MainActor in
            await Task.yield()
            guard presentationActivity.isRenderingActive, chromeYieldsFocus else { return }
            wakesChrome = true
            try? await Task.sleep(for: .milliseconds(750))
            hideChromeAfterFocusYielded(animated: false)
        }
    }

    private func hideChromeAfterFocusYielded(animated: Bool = true) {
        guard showsChrome, chromeYieldsFocus else { return }
        var transaction = Transaction(animation: animated ? .easeInOut(duration: TVImmersiveChromeMotionPolicy.duration(
            0.4,
            reduceMotion: reduceMotion
        )) : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            showsChrome = false
            showsSeekControls = false
        }
    }
}

extension TVImmersivePlayerView {
    // MARK: - 省电

    /// 15 分钟没碰遥控器：压暗、停下装饰动画与频谱，叠上慢慢漂动的暗时钟（只带歌名和艺人）。按任意键就回来。
    fileprivate func scheduleLowPower() {
        idleTask?.cancel()
        idleTask = nil
        guard presentationActivity.isRenderingActive,
              !assistiveNavigationEnabled,
              let idleDelay = ImmersiveIdlePowerPolicy.delayToNextStage(from: .awake, restsEarly: false) else { return }
        let delay = Self.debugIdleDelay ?? idleDelay
        idleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  presentationActivity.isRenderingActive,
                  !showsModePicker,
                  !scrubberFocused,
                  !assistiveNavigationEnabled else { return }
            enterLowPower()
        }
    }

    /// 截图用:TV_IMMERSIVE_IDLE_SECONDS=8 几秒后就进暗屏,看时钟漂动。
    private static var debugIdleDelay: TimeInterval? {
        #if DEBUG
        ProcessInfo.processInfo.environment["TV_IMMERSIVE_IDLE_SECONDS"].flatMap(Double.init)
        #else
        nil
        #endif
    }

    private func enterLowPower() {
        chromeTask?.cancel()
        chromeTask = nil
        focusedControl = nil
        withAnimation(.easeInOut(duration: TVImmersiveChromeMotionPolicy.duration(1.2, reduceMotion: reduceMotion))) {
            showsChrome = false
            showsSeekControls = false
            isLowPower = true
        }
        updateSpectrumAnalysis(for: presentationEffect)
        Task { @MainActor in
            await Task.yield()
            guard presentationActivity.isRenderingActive else { return }
            wakesChrome = true
        }
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

    fileprivate func exitLowPower() {
        guard isLowPower else { return }
        restDriftTask?.cancel()
        restDriftTask = nil
        withAnimation(.easeInOut(duration: TVImmersiveChromeMotionPolicy.duration(0.35, reduceMotion: reduceMotion))) {
            isLowPower = false
            restDriftStep = 0
        }
        updateSpectrumAnalysis(for: presentationEffect)
    }

    fileprivate func restDriftOffset(_ metrics: ImmersiveStageMetrics) -> CGSize {
        guard isLowPower else { return .zero }
        let step = ImmersiveIdlePowerPolicy.driftOffset(step: restDriftStep)
        return CGSize(width: metrics.s(8) * CGFloat(step.x), height: metrics.s(6) * CGFloat(step.y))
    }
}

/// 15 分钟没碰遥控器以后的暗屏层：一只很暗的时钟，下面只留歌名和艺人。人多半已经离开屏幕，
/// 歌词不再跟着唱；整块在屏幕上慢慢漂、碰到边就折回，不在一处久留（防烧屏，也不晃眼）。
/// 「减弱动态效果」打开时不漂，隔一阵淡出、换个位置再淡入。
private struct TVImmersiveAwayClock: View {
    var metrics: ImmersiveStageMetrics
    var title: String
    var artist: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blockSize: CGSize = .zero
    @State private var position: CGPoint?
    @State private var isShown = true

    /// 每秒漂多少点（1920 宽的画布上横穿一趟一分半左右）。
    private static let speed: CGFloat = 14
    /// 「减弱动态效果」时多久换一次位置。
    private static let hopInterval: Duration = .seconds(90)

    private struct DriftKey: Equatable {
        var bounds: CGSize
        var block: CGSize
        var reduceMotion: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            block
                .onGeometryChange(for: CGSize.self) { $0.size } action: { blockSize = $0 }
                .opacity(position == nil || !isShown ? 0 : 1)
                .offset(x: (position ?? .zero).x, y: (position ?? .zero).y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .task(id: DriftKey(bounds: geometry.size, block: roundedBlockSize, reduceMotion: reduceMotion)) {
                    guard blockSize != .zero else { return }
                    // 范围在开工时按现量的块大小算。第一轮的 id 是块还没量到时定的，
                    // 那时按 0 算出的范围会把块的左上角放到贴底处，歌名艺人全在屏幕外。
                    let area = movableArea(in: geometry.size)
                    if reduceMotion {
                        await hop(in: area)
                    } else {
                        await drift(in: area)
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: metrics.s(10)) {
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: metrics.s(50), weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ImmersiveStagePalette.ink.opacity(0.46))
            }
            VStack(alignment: .leading, spacing: metrics.s(4)) {
                Text(title)
                    .font(.system(size: metrics.s(20), weight: .medium))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.36))
                Text(artist)
                    .font(.system(size: metrics.s(16)))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.26))
            }
            .lineLimit(1)
        }
        .frame(maxWidth: metrics.s(560), alignment: .leading)
        .fixedSize()
    }

    /// 分钟数变宽变窄时差几个点，不必为此重算漂移路线。
    private var roundedBlockSize: CGSize {
        CGSize(width: (blockSize.width / 40).rounded(.up) * 40, height: (blockSize.height / 20).rounded(.up) * 20)
    }

    /// 时钟块左上角能走到的范围：四边留出页边，再扣掉块自己的大小。
    private func movableArea(in size: CGSize) -> CGRect {
        let margin = max(metrics.s(48), 40)
        let block = roundedBlockSize
        return CGRect(
            x: margin,
            y: margin,
            width: max(0, size.width - margin * 2 - block.width),
            height: max(0, size.height - margin * 2 - block.height)
        )
    }

    /// 匀速直线漂，碰到哪条边就把那个方向折回来，一段一段地交给动画。
    private func drift(in area: CGRect) async {
        var point = position.map { clamped($0, to: area) }
            ?? CGPoint(x: area.minX + area.width * 0.08, y: area.maxY - area.height * 0.08)
        let angle = Double.random(in: 0.35...0.75) * .pi / 2
        var direction = CGVector(dx: cos(angle), dy: -sin(angle))
        if position == nil {
            position = point
        }
        while !Task.isCancelled {
            let timeX = direction.dx > 0
                ? (area.maxX - point.x) / (direction.dx * Self.speed)
                : (point.x - area.minX) / (-direction.dx * Self.speed)
            let timeY = direction.dy > 0
                ? (area.maxY - point.y) / (direction.dy * Self.speed)
                : (point.y - area.minY) / (-direction.dy * Self.speed)
            let seconds = max(1, min(timeX, timeY))
            let next = clamped(CGPoint(
                x: point.x + direction.dx * Self.speed * seconds,
                y: point.y + direction.dy * Self.speed * seconds
            ), to: area)
            withAnimation(.linear(duration: Double(seconds))) { position = next }
            do {
                try await Task.sleep(for: .seconds(Double(seconds)))
            } catch {
                return
            }
            point = next
            if timeX <= timeY { direction.dx = -direction.dx }
            if timeY <= timeX { direction.dy = -direction.dy }
        }
    }

    /// 不漂的时候：隔一阵淡出，换到随机的一处再淡入。
    private func hop(in area: CGRect) async {
        // 屏幕或块的大小变了，原来的位置可能已经出界，先收回范围里。
        position = clamped(position ?? CGPoint(x: area.minX, y: area.maxY), to: area)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.hopInterval)
                withAnimation(.easeInOut(duration: 1.2)) { isShown = false }
                try await Task.sleep(for: .seconds(1.3))
            } catch {
                return
            }
            position = CGPoint(
                x: CGFloat.random(in: area.minX...max(area.minX, area.maxX)),
                y: CGFloat.random(in: area.minY...max(area.minY, area.maxY))
            )
            withAnimation(.easeInOut(duration: 1.2)) { isShown = true }
        }
    }

    private func clamped(_ point: CGPoint, to area: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, area.minX), area.maxX),
            y: min(max(point.y, area.minY), area.maxY)
        )
    }
}

/// 封面流两侧跟着播放队列走：接下来的那串一变（换歌、加歌、开关随机）就刷新一次。
private struct TVImmersiveQueueObserver: View {
    @Environment(TVStore.self) private var store
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: store.queueUpNextIDs) { _, _ in onChange() }
    }
}

private struct TVImmersiveLibraryCountObserver: View {
    @Environment(TVStore.self) private var store
    let onCountChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: store.songs.count) { _, _ in onCountChange() }
    }
}
#endif
