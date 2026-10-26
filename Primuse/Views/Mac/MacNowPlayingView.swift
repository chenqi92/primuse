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
    /// 设置里选的歌词字体(#332)。
    @Environment(\.lyricsTypeface) private var lyricsTypeface

    /// 显示与机翻用的那份：关掉「显示歌词自带的译文」时去掉文件带的译文。
    @State private var lyrics: [LyricLine] = []
    /// 读到的原文档，开关变化时从它重新得出 `lyrics`。
    @State private var loadedLyrics: [LyricLine] = []
    @State private var lyricsWritingDirection: LyricWritingDirection = .natural
    @State private var currentIndex: Int = -1
    /// 正在走的那段前奏或间奏的提示点;不在间奏里(或关掉了提示点)是 nil。滚动停在它上面。
    @State private var activeInterludeAnchor: MacLyricsScrollAnchor?
    @State private var activeBackgroundLineIDs: Set<String> = []
    @State private var lyricsLoadRevision: UInt = 0
    /// Bumped whenever the installed lyric lines change, so translation
    /// restarts for new lyrics even within the same song.
    @State private var lyricsTranslationRevision: UInt = 0
    @State private var lyricTranslationsByLineID: [String: String] = [:]
    @State private var lyricsTranslationActivity: LyricsTranslationActivity = .idle
    /// 自动生成的罗马音与双语 LRC 里的读音行。
    @State private var lyricRomanizationOverlay: LyricRomanizationOverlay = .empty
    /// 歌词列表与沉浸层显示的那份：按罗马音设置换过正文或附属罗马音；翻译、跳转仍用 `lyrics`。
    @State private var romanizedLyrics: [LyricLine] = []
    @State private var romanizedLyricsWritingDirection: LyricWritingDirection = .natural
    /// 最近一次真正跑完的歌词加载对应的世代。跟当前世代不一致就说明还在加载。
    /// 用世代号而不是手工置一个 Bool: `reloadLyrics` 有多条退出路径, 漏掉任何
    /// 一条都会把歌词区永久钉在加载态。
    @State private var settledLyricsIdentity: LyricsLoadTaskIdentity?
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
    @State private var showsRadioSleepTimer = false
    @State private var showsSpokenWordSleepTimer = false
    @State private var radioDetailStationID: String?
    /// 播客单集的详情或节目页:标题键「转到这本书」对单集是空页,换成这两页。
    @State private var podcastSheet: PodcastPlayerSheetTarget?
    /// 右栏目录面板该翻到哪一页(播客的「接下来」块)。
    @State private var contentsRequestedTab: SpokenWordContentsView.Tab?
    /// 有声内容的文稿全屏读(`SpokenWordTranscriptReader`)。
    @State private var showsTranscriptReader = false
    /// 从文字稿那一页打开的生成面板(#314)。
    @State private var transcriptGenerationSong: Song?
    /// 右上角那排浮动按钮的下沿、有声内容右栏的上沿,都在 `surfaceSpace` 里量。
    /// 封面那一栏比窗口可用高度高时,整排内容被居中、上下留白一起被吃掉,右栏顶上的
    /// 「目录 / 书签 / 文稿」就顶进按钮那一排底下(#350)。窗口越矮、标题折行越多越明显。
    @State private var floatingControlsBottom: CGFloat = 0
    @State private var spokenWordPaneTop: CGFloat = 0
    /// 按钮排自己多宽(拖窗口宽度时不变),用来算封面那一栏左边让多少。
    @State private var floatingControlsWidth: CGFloat = 0
    @State private var preferences = MacUIPreferences.shared
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenPlayerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsPlayerVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.audioInfoModeKey)
    private var audioInfoModeRawValue = PlayerAppearancePreferences.audioInfoModeByDefault.rawValue
    @AppStorage(PlayerAppearancePreferences.tapLyricsToSeekKey)
    private var tapLyricsToSeek = PlayerAppearancePreferences.tapLyricsToSeekByDefault
    @AppStorage(PlayerAppearancePreferences.showsLyricsSourceKey)
    private var showsLyricsSource = PlayerAppearancePreferences.showsLyricsSourceByDefault
    @AppStorage(PlayerAppearancePreferences.showsLyricsInterludeKey)
    private var showsLyricsInterlude = PlayerAppearancePreferences.showsLyricsInterludeByDefault
    @AppStorage(PlayerAppearancePreferences.showsLyricsInterludeAlwaysKey)
    private var showsLyricsInterludeAlways = PlayerAppearancePreferences.showsLyricsInterludeAlwaysByDefault

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
    /// 译文(和注音)行自己的字号;0 = 跟原文一起缩放(#320)。
    @AppStorage(CloudKVSKey.lyricsTranslationFontScale) private var lyricsTranslationFontScale: Double = 0

    private static let surfaceSpace = "macNowPlayingSurface"
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
        switch romanizedLyricsWritingDirection {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    private var isCurrentLiked: Bool {
        guard let song = player.currentSong else { return false }
        if PodcastPlaybackSong.isEpisode(song) { return PodcastStore.shared.isLiked(episodeID: song.id) }
        return library.isLiked(songID: song.id)
    }

    private var isSpokenWord: Bool {
        player.currentItemIsSpokenWord && !player.isLiveRadio
    }

    private var spokenWordPalette: SpokenWordPlayerPalette {
        SpokenWordPlayerPalette(
            primary: playerPrimaryColor,
            secondary: playerSecondaryColor,
            tertiary: playerFaintColor,
            accent: theme.accentColor,
            tileFill: playerGlassFill
        )
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
        // 尺寸钉死在容器上。常规播放页和沉浸层共用同一个 ZStack,任何一层把它撑得
        // 比窗口高,顶部那两排 overlay 贴的就是被撑出去的边缘 —— 全屏里按钮只剩
        // 半截就是这么来的,而窗口那侧的几何完全正常,所以从 NSWindow 看不出来。
        // GeometryReader 给的是容器的真实尺寸,固定成它之后,子层再怎么扩张也只
        // 影响自己的绘制,不会把这棵树顶出去。
        GeometryReader { proxy in
            playerSurface(width: proxy.size.width)
                .frame(width: proxy.size.width, height: proxy.size.height)
                // 顶部这几层必须挂在尺寸钉死之后。挂在 `playerSurface` 上时它们贴的是
                // 内容撑出来的自然尺寸（实测 1048 高，而容器只有 861），`.frame` 居中
                // 裁剪之后就跑到窗口上方去了 —— 全屏里按钮只剩半截正是这么来的。
                .overlay(alignment: .topTrailing) { topRightControls }
                .overlay { fullscreenEffectScrim }
                .overlay(alignment: .topLeading) { topLeftControls }
                .overlay(alignment: .topLeading) { fullscreenEffectPanel }
                // 按钮排和右栏在这里量,播放页整页滑入滑出时读数不跟着变。
                .coordinateSpace(.named(Self.surfaceSpace))
                .pmLogFrame("nowPlaying")
        }
        // Translation lives here rather than on the lyrics pane, which is
        // removed while the immersive stage is showing.
        .lyricsTranslationTaskIfAvailable(
            songID: player.currentSong?.id,
            songContext: .init(
                title: player.currentSong?.title,
                artist: player.currentSong?.artistName,
                isSpokenWord: isSpokenWord
            ),
            lyricsRevision: lyricsTranslationRevision,
            lyrics: lyrics,
            settings: LyricsTranslationSettingsStore.shared,
            player: player,
            translatedTextByLineID: $lyricTranslationsByLineID,
            activity: $lyricsTranslationActivity
        )
        .lyricsRomanizationTask(
            songID: player.currentSong?.id,
            songContext: .init(title: player.currentSong?.title, artist: player.currentSong?.artistName),
            lyricsRevision: lyricsTranslationRevision,
            lyrics: lyrics,
            overlay: $lyricRomanizationOverlay
        )
    }

    /// 播放页本体。尺寸由 `body` 钉死,这里不再自己伸展。
    private func playerSurface(width: CGFloat) -> some View {
        ZStack {
            if isImmersiveStageActive {
                MacImmersivePlayerView(
                    lyrics: romanizedLyrics,
                    translatedTextByLineID: lyricTranslationsByLineID,
                    // 安全区由这棵树的宿主决定,沉浸层不能自己再忽略一次。
                    ignoresWindowSafeArea: false,
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
                                .frame(width: artworkColumnWidth)
                                .frame(maxHeight: .infinity)
                            if isSpokenWord {
                                // 有声内容的右栏是这本书的目录、书签与文字稿。
                                // 顶上让出按钮排的高度,分段排在按钮下面。
                                SpokenWordContentsView(
                                    presentation: .embedded(spokenWordPalette),
                                    textTab: AnyView(spokenWordTextTab),
                                    requestedTab: $contentsRequestedTab
                                )
                                .pmLogFrame("spokenWordPane")
                                .padding(.top, max(0, floatingControlsBottom - spokenWordPaneTop))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                // 量的是让位之前的上沿,让多少不会反过来改它。
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.frame(in: .named(Self.surfaceSpace)).minY
                                } action: { spokenWordPaneTop = $0 }
                                .sheet(isPresented: $showsTranscriptReader) {
                                    SpokenWordTranscriptReader(
                                        lines: lyrics,
                                        title: player.currentSong?.title ?? "",
                                        player: player,
                                        translatedTextByLineID: lyricTranslationsByLineID
                                    )
                                }
                                .sheet(item: $transcriptGenerationSong) { song in
                                    SpokenTranscriptGenerationSheet(song: song, dismissesOnStart: true)
                                        .environment(AppServices.shared.musicIntelligence)
                                }
                            } else {
                                lyricsPane
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .padding(.leading, artworkLeadingPadding(surfaceWidth: width))
                        .padding(.trailing, isWindowFullScreen ? 100 : 56)
                        .padding(.top, isWindowFullScreen ? 70 : 50)
                        .padding(.bottom, isWindowFullScreen ? 80 : 60)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: isImmersiveStageActive)
        .onChange(of: isImmersiveStageActive) { _, active in
            #if DEBUG
            // 沉浸层进出时记一次窗口几何:顶部被裁 + 底栏下沉是同一个病,
            // 要看的是 contentMinSize 有没有被内容撑过屏幕高度。
            if let hostWindow {
                PMWindowFrameGuard.logGeometry(
                    hostWindow,
                    label: active ? "immersive-on" : "immersive-off"
                )
            }
            #endif
        }
        .background {
            NowPlayingWindowResolver { window in
                // 解析回调每轮视图更新都会来一次。无条件写回这几个 @State 等于把
                // 全屏与沉浸展示的开关钉死在「窗口此刻是什么样」,视图自己刚改的值
                // 下一帧就被抹掉;只在真的变了时才写。
                if hostWindow !== window { hostWindow = window }
                // 初始同步: 视图可能在主窗口已经全屏之后才被创建,此时早已发出的
                // didEnterFullScreen 通知收不到,只能直接读窗口的 styleMask 兜底,
                // 否则全屏下会错渲染成窗口版布局。
                guard let window else { return }
                let isFullScreen = window.styleMask.contains(.fullScreen)
                guard isFullScreen != isWindowFullScreen else { return }
                isWindowFullScreen = isFullScreen
                if isFullScreen {
                    showsImmersiveStage = fullscreenPlayerEffect != .native
                }
            }
        }
        .task(id: lyricsLoadTaskIdentity) {
            let identity = lyricsLoadTaskIdentity
            if player.isLiveRadio {
                installLyrics([])
            } else {
                await refreshLyrics()
            }
            // 被换歌顶掉的旧任务恢复执行时不能写回旧世代 —— 那会让新一轮加载
            // 被误判成已完成, 空态又闪出来。
            guard lyricsLoadTaskIdentity == identity else { return }
            settledLyricsIdentity = identity
        }
        .background {
            if !isImmersiveStageActive {
                MacNowPlayingTimeObserver { updateIndex(time: $0) }
            }
        }
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        .onChange(of: lyricsTranslationFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsTranslationFontScale)
        }
        .onChange(of: LyricsTranslationSettingsStore.shared.showsBundledTranslations) { _, _ in
            installLyrics(loadedLyrics)
        }
        .onChange(of: lyricRomanizationOverlay) { _, _ in refreshRomanizedLyrics() }
        .onChange(of: LyricsRomanizationSettingsStore.shared.displayMode) { _, _ in refreshRomanizedLyrics() }
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

    /// 右上角那排浮动控件。
    @ViewBuilder
    private var topRightControls: some View {
        if !isImmersiveStageActive {
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
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.surfaceSpace)).maxY
            } action: { floatingControlsBottom = $0 }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { floatingControlsWidth = $0 }
            .padding(floatingControlsInset)
            .pmLogFrame("topRight")
        }
    }

    private var floatingControlsInset: CGFloat { isWindowFullScreen ? 24 : 16 }

    private var artworkColumnWidth: CGFloat { isWindowFullScreen ? 520 : 380 }

    /// 封面那一栏左边留多少。窗口窄到右上角那排按钮要伸进封面那一栏时,随宽度把这份留白
    /// 一点点收掉、封面往左让,最多收到一半;够宽时照旧。
    private func artworkLeadingPadding(surfaceWidth: CGFloat) -> CGFloat {
        let standard: CGFloat = isWindowFullScreen ? 100 : 56
        let room = surfaceWidth - floatingControlsWidth - floatingControlsInset - 12 - artworkColumnWidth
        return min(standard, max(standard / 2, room))
    }

    /// 全屏时左上角的退出与效果入口。
    @ViewBuilder
    private var topLeftControls: some View {
        if isWindowFullScreen, !isImmersiveStageActive {
            HStack(spacing: 10) {
                exitFullScreenPill
                // 全屏效果是给音乐的可视化, 有声内容不给入口。
                if !(player.currentItemIsSpokenWord && !player.isLiveRadio) {
                    nativeFullscreenEffectButton
                }
            }
            .padding(.top, 18)
            .padding(.leading, 22)
        }
    }

    /// 效果面板开着时铺在下面的遮罩，点它就收起。
    @ViewBuilder
    private var fullscreenEffectScrim: some View {
        if isWindowFullScreen, !isImmersiveStageActive, showsNativeFullscreenEffectPicker {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closeFullscreenEffectPicker() }
                .accessibilityHidden(true)
        }
    }

    /// 面板贴着左上角那个按钮展开，而不是从窗口边上推一条抽屉过来。
    @ViewBuilder
    private var fullscreenEffectPanel: some View {
        if isWindowFullScreen, !isImmersiveStageActive, showsNativeFullscreenEffectPicker {
            MacImmersiveEffectPicker(
                selected: fullscreenPlayerEffect,
                effects: FullscreenPlayerEffect.allCases,
                palette: ImmersiveArtworkPalette(
                    primary: theme.accentColor,
                    secondary: theme.secondaryDarkAccent
                ),
                onSelect: { candidate in
                    closeFullscreenEffectPicker()
                    selectFullscreenEffect(candidate)
                },
                onClose: { closeFullscreenEffectPicker() }
            )
            .padding(.top, 58)
            .padding(.leading, 22)
            .transition(
                .scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity)
            )
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
                        .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .pmAnimation(.control, value: player.isPlaying || player.isLoading)

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
            // 「刚播过」: 这个台最近放过的标题, 在电台详情页里 (共用 iPhone 那一页)。
            if let station = player.currentRadioStation {
                Button { radioDetailStationID = station.id } label: {
                    circleIcon("clock.arrow.circlepath")
                }
                .buttonStyle(.plain)
                .pmGlassControl(Circle())
                .help(Text("radio_detail_heard_title"))
                .sheet(item: Binding(
                    get: { radioDetailStationID.map(MacRadioDetailTarget.init) },
                    set: { radioDetailStationID = $0?.id }
                )) { target in
                    RadioStationDetailView(stationID: target.id)
                        .frame(minWidth: 420, minHeight: 540)
                }
            }
            // 电台没有「更多」菜单, 睡眠定时直接放在这排。
            Button { showsRadioSleepTimer.toggle() } label: {
                circleIcon(player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz",
                           tint: player.isSleepTimerActive ? theme.onAccent : nil,
                           fill: player.isSleepTimerActive ? theme.accentColor.opacity(0.9) : nil)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .pmGlassControl(Circle())
            .help(player.isSleepTimerActive ? Text("sleep_timer_active") : Text("sleep_timer"))
            .popover(isPresented: $showsRadioSleepTimer, arrowEdge: .bottom) {
                MacSleepTimerPopover {
                    showsRadioSleepTimer = false
                }
                .focusEffectDisabled()
            }
            if let url = player.currentRadioStation?.url {
                ShareLink(item: url) {
                    circleIcon("square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .pmGlassControl(Circle())
                .help(Text("share"))
            }
            if !isWindowFullScreen {
                Button(action: onClose) { circleIcon("chevron.down") }
                    .buttonStyle(.plain)
                    .pmGlassControl(Circle())
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
        let usesIncreasedContrast = colorSchemeContrast == .increased
        var lightOverlay = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: hasArtworkTheme,
            usesIncreasedContrast: usesIncreasedContrast,
            strength: strength
        )
        var primaryOpacity = (usesLightPlayerAppearance
            ? (hasArtworkTheme ? 0.34 : 0.12)
            : (hasArtworkTheme ? 0.74 : 0.32)) * strength
        var secondaryOpacity = (usesLightPlayerAppearance
            ? (hasArtworkTheme ? 0.22 : 0.08)
            : (hasArtworkTheme ? 0.58 : 0.24)) * strength
        // 浅色外观把氛围强度调过默认值:和手机一样往封面颜色上靠,封面色太深时停在文字还看得清的地方(#69)。
        if usesLightPlayerAppearance, hasArtworkTheme,
           PlayerBackdropSettingsStore.shared.effectiveSource != .liquid,
           strength > AppThemePreferences.defaultAmbientStrength {
            let defaultStrength = AppThemePreferences.defaultAmbientStrength
            let defaultOverlay = AmbientLightOverlayPolicy.resolve(
                hasArtworkTheme: true,
                usesIncreasedContrast: usesIncreasedContrast,
                strength: defaultStrength
            )
            let levels = NowPlayingLightAmbientPolicy.levels(
                atDefault: NowPlayingLightAmbientLevels(
                    primaryOpacity: 0.34 * defaultStrength,
                    secondaryOpacity: 0.22 * defaultStrength,
                    overlayTopOpacity: defaultOverlay.topOpacity,
                    overlayBottomOpacity: defaultOverlay.bottomOpacity
                ),
                vivid: usesIncreasedContrast
                    ? NowPlayingLightAmbientLevels(
                        primaryOpacity: 0.56, secondaryOpacity: 0.40,
                        overlayTopOpacity: 0.20, overlayBottomOpacity: 0.08
                    )
                    : NowPlayingLightAmbientLevels(
                        primaryOpacity: 0.72, secondaryOpacity: 0.52,
                        overlayTopOpacity: 0.06, overlayBottomOpacity: 0
                    ),
                strength: strength,
                defaultStrength: defaultStrength,
                primaryLuma: theme.artworkAccentLuma,
                secondaryLuma: theme.artworkSecondaryLuma,
                usesIncreasedContrast: usesIncreasedContrast
            )
            primaryOpacity = levels.primaryOpacity
            secondaryOpacity = levels.secondaryOpacity
            lightOverlay = AmbientLightOverlay(
                topOpacity: levels.overlayTopOpacity,
                bottomOpacity: levels.overlayBottomOpacity
            )
        }
        let darkOverlay = NowPlayingAmbientLegibilityPolicy.darkOverlay(
            paletteLuminance: theme.artworkLuminance,
            primaryOpacity: primaryOpacity,
            secondaryOpacity: secondaryOpacity,
            usesIncreasedContrast: usesIncreasedContrast
        )

        return ZStack {
            if PlayerBackdropSettingsStore.shared.effectiveSource == .liquid {
                // 设置里选了「流动色彩」:换成几团跟着封面颜色缓缓流动的光(#189)。
                LiquidArtworkBackdrop(
                    palette: theme.liquidPalette,
                    isLight: usesLightPlayerAppearance,
                    strength: strength,
                    isVisible: !isImmersiveStageActive && controlActiveState != .inactive,
                    isSceneActive: scenePhase == .active,
                    isPlaying: player.isPlaying
                )
            } else {
                AdaptiveNowPlayingBackdrop(
                    baseColor: usesLightPlayerAppearance ? PMColor.bg : PMColor.ambientDarkBase,
                    primaryAccent: theme.accentColor,
                    secondaryAccent: theme.secondaryAccent,
                    darkAccent: theme.darkAccent,
                    primaryOpacity: primaryOpacity,
                    secondaryOpacity: secondaryOpacity,
                    hasArtworkPalette: hasArtworkTheme,
                    // 背景图铺满时色场被盖住，停掉它的动画时钟。
                    isVisible: !isImmersiveStageActive && controlActiveState != .inactive
                        && !PlayerBackdropResolver.shared.isShowingImage,
                    isSceneActive: scenePhase == .active,
                    isPlaying: player.isPlaying,
                    paletteVibrancy: theme.artworkVibrancy,
                    paletteLuminance: theme.artworkLuminance
                )
            }

            if PlayerBackdropSettingsStore.shared.effectiveSource == .visualizer {
                // 设置里选了「声音律动」:色场上再画一层跟着声音动的频谱、波形或星尘(#312)。
                PlayerVisualizerBackdrop(
                    style: PlayerBackdropSettingsStore.shared.settings.visualizerStyle,
                    primary: theme.accentColor,
                    secondary: theme.secondaryAccent,
                    deep: theme.darkAccent,
                    isLight: usesLightPlayerAppearance,
                    strength: strength,
                    isVisible: !isImmersiveStageActive && controlActiveState != .inactive,
                    isSceneActive: scenePhase == .active
                )
            }

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

            // 设置里选了封面模糊 / 专辑封底 / 自选图片时铺在色场上面。
            PlayerBackdropImageHost(
                song: player.isLiveRadio ? nil : player.currentSong,
                isLight: usesLightPlayerAppearance,
                strength: strength,
                usesIncreasedContrast: colorSchemeContrast == .increased,
                isSurfaceVisible: !isImmersiveStageActive && controlActiveState != .inactive
                    && scenePhase == .active,
                allowsLoading: true
            )
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
                            .pmGlassControl(Circle())
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
                } else if isSpokenWord {
                    // 方形书框,比方形槽位略小一圈,把高度让给下面的功能块。
                    SpokenWordBookCover(
                        song: player.currentSong,
                        width: (coverSize * 0.96).rounded(),
                        cornerRadius: coverRadius * 0.6,
                        decodeSize: coverSize
                    )
                    .frame(width: coverSize, height: coverSize * 0.96, alignment: frameAlignment)
                    // 和手机上点封面一样,右栏翻到文字稿那一页。
                    .contentShape(Rectangle())
                    .onTapGesture { contentsRequestedTab = .text }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("spoken_word_text_tab"))
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
                    .artworkCrossfade()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: coverSize, height: coverSize)
                    .overlay(alignment: .bottom) {
                        MusicVideoPreparationBadge(songID: song.id)
                    }
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

            if isSpokenWord {
                spokenWordDetails(alignment: horizontalAlignment, frameAlignment: frameAlignment, width: coverSize)
            } else {
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
                    .font(.system(size: isWindowFullScreen ? 36 : 24))
                    .padding(.top, 6)
                }
                MacNowPlayingSpokenWordRow(foreground: playerSecondaryColor)
                .font(.system(size: isWindowFullScreen ? 15 : 13))
                .padding(.top, 8)
                if let sourceLabel, !sourceLabel.isEmpty {
                    Text(sourceLabel)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(playerFaintColor)
                        .lineLimit(1)
                        .padding(.top, 6)
                        .pmFadeTransition()
                }
            }
            .frame(width: coverSize, alignment: frameAlignment)
            .contentTransition(.opacity)
            .pmAnimation(.trackChange, value: player.currentSong?.id)

            if let song = player.currentSong {
                LibraryReviewSection(
                    subject: .song(song.id),
                    compact: true,
                    onArtwork: true
                )
                .frame(width: coverSize, alignment: frameAlignment)
            }
            }

            if isWindowFullScreen {
                MacNowPlayingProgressRow(width: coverSize, accent: theme.accentColor)
            }

            Spacer(minLength: 0)
        }
    }

    /// 播客标题块里的节目名:弹出节目页。
    private var openCurrentPodcastShow: (() -> Void)? {
        guard SpokenWordPlayerText.isPodcastEpisode(player) else { return nil }
        return {
            if let showID = SpokenWordPlayerText.podcastShowID(player) {
                podcastSheet = .show(showID)
            }
        }
    }

    /// 有声内容的左栏下半截:书名、正在听的章、演播者与「第几章」(前面那一圈是全书进度),
    /// 语速 / 定时 / 书签三块(目录在右栏)。窗口模式下进度条在底栏,这里只补本章还剩多久。
    private func spokenWordDetails(
        alignment: HorizontalAlignment,
        frameAlignment: Alignment,
        width: CGFloat
    ) -> some View {
        VStack(alignment: alignment, spacing: isWindowFullScreen ? 18 : 12) {
            SpokenWordPlayerHeading(
                palette: spokenWordPalette,
                titleFont: .system(size: isWindowFullScreen ? 48 : 30),
                partFont: .system(size: isWindowFullScreen ? 22 : 16),
                alignment: alignment,
                onOpenShow: openCurrentPodcastShow,
                onOpenBook: {
                    if PodcastPlaybackSong.isEpisode(player.currentSong) {
                        if let episodeID = SpokenWordPlayerText.openablePodcastEpisodeID(player) {
                            podcastSheet = .episode(episodeID)
                        }
                    } else if let bookID = player.currentBookID {
                        NotificationCenter.default.post(name: .primuseDetailOpenSpokenWordBook, object: bookID)
                    }
                },
                onOpenContents: {}
            )
            .sheet(item: $podcastSheet) { target in
                NowPlayingPodcastSheet(target: target)
            }

            SpokenWordPartRemainingLabel(color: playerSecondaryColor)

            SpokenWordActionTiles(
                palette: spokenWordPalette,
                showsContents: false,
                tileHeight: isWindowFullScreen ? 58 : 50,
                onSleep: { showsSpokenWordSleepTimer = true },
                onContents: {},
                // 目录面板常驻右栏:「接下来」只是把它翻到那一页。
                onUpNext: { contentsRequestedTab = .upNext }
            )
            .popover(isPresented: $showsSpokenWordSleepTimer, arrowEdge: .bottom) {
                MacSleepTimerPopover {
                    showsSpokenWordSleepTimer = false
                }
                .focusEffectDisabled()
            }
        }
        .frame(width: width, alignment: frameAlignment)
    }

    /// 歌词最上面的「逐字」与来源标签,和手机播放页同一套(#357)。来源看读到的原文档:
    /// 显示用的那份按设置去过译文、换过罗马音。文字稿不标来源。
    @ViewBuilder
    private var lyricsInfoBadges: some View {
        let showsWordLevel = lyrics.contains(where: \.containsWordLevelContent)
        let source = showsLyricsSource && !isSpokenWord ? LyricsSourceBadge.resolve(loadedLyrics) : nil
        if showsWordLevel || source != nil {
            LyricsInfoBadges(
                showsWordLevel: showsWordLevel,
                source: source,
                foreground: playerSecondaryColor,
                fill: playerGlassFill
            )
            .padding(.top, lyricsRowSpacing)
            .padding(.bottom, 4)
        }
    }

    private var lyricsPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Every row keeps the same layout height. Only the active row is
                // subtly scaled at the rendering layer, so switching lines does
                // not reflow the stack or produce a hard jump.
                // 行间距由每一行自己在上面留(`lyricsRowSpacing`):收起的间奏提示点高度为 0,
                // 不再多出一份间距。
                LazyVStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: isWindowFullScreen ? 120 : 80)
                        .frame(height: isWindowFullScreen ? 120 : 80)
                    if lyrics.isEmpty {
                        if player.currentSong == nil || isLoadingLyrics {
                            Color.clear.frame(height: 1)
                                .padding(.top, lyricsRowSpacing)
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
                                    .pmAnimation(.control, value: isScrapingCurrentSong)
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
                            // 成对分支不能做交叉淡入: 这里的父容器是 LazyVStack,
                            // 过渡期间离场的那支还占着布局, 会把空态顶下去再弹回。
                            // 用 pmAppearFade —— 旧分支瞬间消失, 空态自己淡进来。
                            .pmAppearFade(.contentAppear)
                            .padding(.top, lyricsRowSpacing)
                        }
                    } else {
                        lyricsInfoBadges
                        let isDuet = KaraokeDuetGatePolicy.hasDuetParts(lyrics)
                        // 提示点各占一行、和歌词行同在一个 ForEach 里:惰性堆栈里还没建出来的行
                        // 也能按这个身份滚过去。没轮到的提示点收起,不显示也不占位置。
                        // `scrollTo` 找目标时从第一格起逐格往后看:格子上不挂 `.id`,每格先只包一层,
                        // 排到屏幕上才建这一行,免得长文稿每换一句就把前面几百行全建一遍。
                        ForEach(lyricsListEntries) { entry in
                            MacDeferredLyricRow {
                                switch entry.kind {
                                case .line(let i, let line):
                                    macLyricLine(
                                        line: line,
                                        index: i,
                                        isActive: i == currentIndex,
                                        fontSize: lyricLayoutFontSize,
                                        isDuet: isDuet
                                    )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .if(canSeekToLyricLine(line)) { view in
                                            view
                                                .onTapGesture { seekToLyricLine(line) }
                                                .accessibilityAddTraits(.isButton)
                                                .accessibilityHint(Text("player_tap_lyrics_to_seek_description"))
                                        }
                                        .padding(.top, lyricsRowSpacing)
                                case .interlude(let window, let voice):
                                    macInterludeMarker(
                                        window,
                                        isActive: activeInterludeAnchor == entry.id,
                                        voice: voice,
                                        isDuet: isDuet
                                    )
                                }
                            }
                        }
                    }
                    Spacer(minLength: isWindowFullScreen ? 240 : 200)
                        .frame(height: isWindowFullScreen ? 240 : 200)
                        .padding(.top, lyricsRowSpacing)
                }
                .padding(.horizontal, isWindowFullScreen ? 0 : PMSpace.l24)
            }
            .pmVerticalFadeMask(
                startStop: isWindowFullScreen ? 0.18 : 0.12,
                endStop: isWindowFullScreen ? 0.82 : 0.88
            )
            .onChange(of: lyricsScrollAnchor) { _, new in
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
                let target = updateIndex(time: player.currentTime, animated: false)
                await Task.yield()
                guard !Task.isCancelled, let target else { return }
                scrollLyrics(to: target, proxy: proxy, animated: false)
            }
            .onDisappear {
                lyricsAutoFollowTask?.cancel()
            }
        }
        .overlay(alignment: .top) {
            lyricsTranslationStatus
                .padding(.top, 12)
        }
    }

    /// Only the states that need the listener: a model download, the
    /// explicit system-translation step, or a pair nothing here can translate.
    @ViewBuilder
    private var lyricsTranslationStatus: some View {
        Group {
            switch lyricsTranslationActivity {
            case .localModelRequired:
                LocalTranslationModelBadge()
            case .systemPreparationRequired:
                Button {
                    LyricsTranslationSettingsStore.shared.requestSystemTranslationPreparation()
                } label: {
                    Label(String(localized: "Translate Lyrics"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.plain)
            case .systemUnavailable:
                Label("lyrics_translation_unavailable", systemImage: "exclamationmark.triangle")
            case .intelligentNotReady(let readiness):
                Label(readiness.systemFallbackNotice, systemImage: "sparkles")
            case .baiduNotReady(let issue):
                Label(issue.notice, systemImage: "character.bubble")
            case .spokenWordTranslationRequestable(let itemID):
                Button {
                    LyricsTranslationSettingsStore.shared.requestSpokenWordTranslation(itemID: itemID)
                } label: {
                    Label(String(localized: "lyrics_translation_spoken_word_request"), systemImage: "character.bubble")
                }
                .buttonStyle(.plain)
            default:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(playerPrimaryColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(playerGlassFill, in: Capsule())
        .overlay { Capsule().strokeBorder(playerGlassBorder, lineWidth: 0.5) }
        .opacity(showsLyricsTranslationStatus ? 1 : 0)
        .allowsHitTesting(showsLyricsTranslationStatus)
    }

    private var showsLyricsTranslationStatus: Bool {
        switch lyricsTranslationActivity {
        case .localModelRequired:
            if case .downloading = LocalLyricsTranslationService.shared.modelState { return true }
            return LocalLyricsTranslationService.shared.modelState != .ready
        case .systemPreparationRequired, .systemUnavailable, .intelligentNotReady, .baiduNotReady,
             .spokenWordTranslationRequestable:
            return true
        default:
            return false
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

    /// 歌词还在加载。换歌时 `reloadLyrics` 会先清空歌词, 这段空窗期不该露出
    /// 「无歌词 + 刮词按钮」, 否则每首歌都要硬闪一下空态再切回歌词。
    private var isLoadingLyrics: Bool {
        settledLyricsIdentity != lyricsLoadTaskIdentity
    }

    private func scheduleLyricsAutoFollow(proxy: ScrollViewProxy) {
        lyricsAutoFollowTask?.cancel()
        lyricsAutoFollowTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.manualLyricsScrollGracePeriod))
            guard !Task.isCancelled,
                  Date().timeIntervalSince(lastManualLyricsScroll) >= Self.manualLyricsScrollGracePeriod else { return }
            scrollLyrics(to: lyricsScrollAnchor, proxy: proxy, animated: true)
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

    private func scrollLyrics(to target: MacLyricsScrollAnchor?, proxy: ScrollViewProxy, animated: Bool) {
        guard let target else { return }
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

    private var lyricLayoutFontSize: CGFloat {
        isWindowFullScreen ? Self.lyricsBaseSizeFS : Self.lyricsBaseSize
    }

    /// 歌词列表里的一行:一句歌词,或某一句后面(第一句前面)的间奏提示点。
    private enum MacLyricsScrollAnchor: Hashable {
        case intro
        case line(String)
        case interlude(afterLineID: String)
    }

    private struct MacLyricsListEntry: Identifiable {
        enum Kind {
            case line(index: Int, line: LyricLine)
            /// 提示点跟着它挨着的那一句站在同一侧(对唱时跟那一句那边)。
            case interlude(LyricPlaybackPositionPolicy.InterludeWindow, voice: LyricVoice)
        }

        let id: MacLyricsScrollAnchor
        let kind: Kind
    }

    /// 歌词行与提示点按显示顺序排开。前奏够长时第一句上面一行点,长间奏时那一句下面一行点,
    /// 门槛与 iPhone 歌词页同一套(Kit `LyricPlaybackPositionPolicy`)。
    private var lyricsListEntries: [MacLyricsListEntry] {
        var entries: [MacLyricsListEntry] = []
        entries.reserveCapacity(lyrics.count + 1)
        if showsLyricsInterlude,
           let first = lyrics.first,
           let intro = LyricPlaybackPositionPolicy.introWindow(in: lyrics) {
            entries.append(MacLyricsListEntry(id: .intro, kind: .interlude(intro, voice: first.voice)))
        }
        for (index, line) in lyrics.enumerated() {
            // 显示用罗马音设置换过的那一行(行 id、时间都不变);时间窗仍按原文算。
            let shown = romanizedLyrics.indices.contains(index) && romanizedLyrics[index].id == line.id
                ? romanizedLyrics[index]
                : line
            entries.append(MacLyricsListEntry(id: .line(line.id), kind: .line(index: index, line: shown)))
            if showsLyricsInterlude,
               let window = LyricPlaybackPositionPolicy.interludeWindow(afterLine: index, in: lyrics) {
                entries.append(MacLyricsListEntry(
                    id: .interlude(afterLineID: line.id),
                    kind: .interlude(window, voice: line.voice)
                ))
            }
        }
        return entries
    }

    /// 自动跟随停在哪:间奏里停在提示点上,否则是当前这一句。
    private var lyricsScrollAnchor: MacLyricsScrollAnchor? {
        if let activeInterludeAnchor { return activeInterludeAnchor }
        guard lyrics.indices.contains(currentIndex) else { return nil }
        return .line(lyrics[currentIndex].id)
    }

    private var lyricsLookahead: TimeInterval {
        lyrics.contains { $0.isWordLevel } ? Self.wordLevelLookahead : Self.lineLevelLookahead
    }

    /// 歌词行与行之间的距离。每一行(和展开的提示点)在自己上面留这么多。
    private var lyricsRowSpacing: CGFloat {
        isWindowFullScreen ? 18 : 14
    }

    /// 前奏与长间奏里的三个点(和 iPhone 歌词页同一个 `LyricInterludeDots`),大小跟着歌词字号。
    /// 默认只在这段间奏真正开始后才展开出现,下一句开唱时收起;没轮到的不占位置也看不见。
    /// 展开、收起与滚动走同一条曲线(见 `updateIndex`)。设了「没轮到也显示」就每段都留一行,
    /// 没轮到时淡淡地摆着。
    private func macInterludeMarker(
        _ window: LyricPlaybackPositionPolicy.InterludeWindow,
        isActive: Bool,
        voice: LyricVoice,
        isDuet: Bool
    ) -> some View {
        let isTrailing = LyricDuetLayoutPolicy.side(
            for: voice,
            preferred: .leading,
            isDuet: isDuet
        ) == .trailing
        let scaledSize = lyricLayoutFontSize * CGFloat(lyricsFontScale)
        let lookahead = lyricsLookahead
        let markerHeight = (scaledSize * 0.92).rounded()
        let spacing = lyricsRowSpacing
        return LyricInterludeDots(
            isActive: isActive,
            isPlaying: player.isPlaying,
            phase: {
                LyricPlaybackPositionPolicy.phase(
                    of: window,
                    at: player.interpolatedTime(),
                    lookahead: lookahead
                )
            },
            tint: playerPrimaryColor,
            restingOpacity: showsLyricsInterludeAlways ? 0.3 : 0,
            dotSize: (scaledSize * 0.31).rounded(),
            spacing: (scaledSize * 0.27).rounded()
        )
        .frame(maxWidth: .infinity, alignment: isTrailing ? .trailing : .leading)
        .frame(height: markerHeight)
        // 展开时自带上面那份行间距,和歌词行一样。
        .padding(.top, spacing)
        .opacity(isActive || showsLyricsInterludeAlways ? 1 : 0)
        .frame(height: isActive || showsLyricsInterludeAlways ? markerHeight + spacing : 0, alignment: .top)
        .allowsHitTesting(false)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    @ViewBuilder
    private func macLyricLine(
        line: LyricLine,
        index: Int,
        isActive: Bool,
        fontSize: CGFloat,
        isDuet: Bool
    ) -> some View {
        let scaledSize = fontSize * CGFloat(lyricsFontScale)
        // 对唱时对唱声部的行摆到另一侧（与 iPhone 歌词页同一规则）。
        let isTrailing = LyricDuetLayoutPolicy.side(
            for: line.voice,
            preferred: .leading,
            isDuet: isDuet
        ) == .trailing
        let horizontal: HorizontalAlignment = isTrailing ? .trailing : .leading
        let frameAlignment: Alignment = isTrailing ? .trailing : .leading
        let textAlignment: TextAlignment = isTrailing ? .trailing : .leading
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

        VStack(alignment: horizontal, spacing: 4) {
            macSingleLyricLine(
                line: line,
                index: index,
                isActive: isActive,
                fontSize: scaledSize,
                weight: weight,
                tint: tint,
                textAlignment: textAlignment
            )
            macLyricCompanions(
                for: line,
                fontSize: lyricsTranslationFontScale > 0
                    ? fontSize * CGFloat(lyricsTranslationFontScale)
                    : scaledSize,
                textAlignment: textAlignment
            )
            if let backgrounds = line.background {
                ForEach(backgrounds) { background in
                    macSingleLyricLine(
                        line: background,
                        index: index,
                        isActive: activeBackgroundLineIDs.contains(background.id),
                        fontSize: scaledSize * 0.7,
                        weight: .medium,
                        tint: tint,
                        textAlignment: textAlignment
                    )
                    .opacity(0.72)
                }
            }
        }
        .opacity(opacity)
        .frame(minHeight: scaledSize * 1.3, alignment: frameAlignment)
        .scaleEffect(visualScale, anchor: isTrailing ? .trailing : .leading)
        .animation(
            .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
            value: currentIndex
        )
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    /// Romanization, translations written in the lyrics, and the translation
    /// task's result, smaller and dimmer under the sung line.
    @ViewBuilder
    private func macLyricCompanions(
        for line: LyricLine,
        fontSize: CGFloat,
        textAlignment: TextAlignment
    ) -> some View {
        let companions = LyricCompanionTextPolicy.texts(
            for: line,
            translatedText: lyricTranslationsByLineID[line.id]
        )
        ForEach(companions.indices, id: \.self) { slot in
            Text(LyricCompanionTextPolicy.displayText(companions[slot]))
                .font(lyricsTypeface.font(size: fontSize * 0.62, weight: .medium))
                .foregroundStyle(playerSecondaryColor)
                .lineSpacing(1)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func macSingleLyricLine(
        line: LyricLine,
        index: Int,
        isActive: Bool,
        fontSize: CGFloat,
        weight: Font.Weight,
        tint: Color,
        textAlignment: TextAlignment
    ) -> some View {
        if shouldRenderWordTimeline(line: line, index: index, isActive: isActive) {
            KaraokeLineView(
                line: line,
                fontSize: fontSize,
                weight: weight,
                activeColor: playerPrimaryColor,
                inactiveColor: playerSecondaryColor,
                textAlignment: textAlignment,
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
                .font(lyricsTypeface.font(size: fontSize, weight: weight))
                .foregroundStyle(playerPrimaryColor)
                .lineSpacing(2)
                .multilineTextAlignment(textAlignment)
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
        var parts = [String(localized: "now_playing")]
        if player.iCloudDownloadingSongID == song.id {
            parts.append(String(localized: "playback_icloud_downloading"))
            return parts.joined(separator: " · ")
        }
        // 规格跟 iPhone 用同一个「播放页显示音频信息」档位。
        guard PlayerAppearancePreferences.audioInfoMode(rawValue: audioInfoModeRawValue)
            .showsSummary(for: song.audioQuality) else {
            return parts.joined(separator: " · ")
        }
        parts.append(song.codecFormat.displayName)
        if let bitRate = song.formattedBitRate {
            parts.append(bitRate)
        }
        // 输出设备被设成别的采样率(重采样)时写成「44.1 → 48 kHz」。
        if let sampleRate = OutputSampleRateTextPolicy.text(
            sourceSampleRate: song.sampleRate,
            outputSampleRate: player.audioEngine.observedOutputSampleRate
        ) {
            parts.append(sampleRate)
        }
        if let bitDepth = song.formattedBitDepth {
            parts.append(bitDepth)
        }
        // 设置里开了独占输出：拿到了写「独占」，没拿到写「未能独占」。
        if let exclusive = player.audioEngine.exclusiveOutputStatus.nowPlayingLabel {
            parts.append(exclusive)
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
        .pmGlassControl(Capsule())
        .help(Text("exit_full_screen"))
    }

    private var nativeFullscreenEffectButton: some View {
        Button {
            pmWithAnimation(.panel) {
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
        .pmPointingHand()
        .fixedSize()
        .pmGlassControl(Capsule())
        .help(Text("fullscreen_effect_settings_title"))
        .accessibilityLabel(Text("fullscreen_effect_settings_title"))
    }

    private var floatingControls: some View {
        HStack(spacing: 8) {
            // Heart —— 有声书的每个文件也能加进「我喜欢」;播客单集记在播客自己的喜欢里。
            if player.currentSong != nil {
                Button { toggleLikedCurrent() } label: {
                    circleIcon(isCurrentLiked ? "heart.fill" : "heart",
                               tint: isCurrentLiked ? theme.onAccent : nil,
                               fill: isCurrentLiked ? theme.accentColor : nil)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .pmGlassControl(Circle())
                .help(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                .disabled(player.currentSong == nil)
            }

            // 独立 MV 始终走视频管线, 模式开关对它无意义, 不显示
            if player.canPlayMusicVideo, player.currentSong?.isStandaloneMusicVideo != true {
                Button { player.toggleMusicVideoMode() } label: {
                    circleIcon(player.isMusicVideoModeEnabled ? "play.rectangle.fill" : "play.rectangle",
                               tint: player.isMusicVideoModeEnabled ? theme.onAccent : nil,
                               fill: player.isMusicVideoModeEnabled ? theme.accentColor.opacity(0.9) : nil)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .pmGlassControl(Circle())
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
            .pmGlassControl(Circle())
            .help(Text("lyrics_word"))
            .disabled(player.currentSong == nil)

            Button {
                onClose()
                NotificationCenter.default.post(name: .primuseFocusSearch, object: nil)
            } label: {
                circleIcon("magnifyingglass")
            }
            .buttonStyle(.plain)
            .pmGlassControl(Circle())
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
            .pmGlassControl(Circle())
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
            .pmGlassControl(Circle())
            .help(Text("lyrics_font_larger"))
            .disabled(lyrics.isEmpty)

            // 复用底栏共享的 PlayerMoreMenu,确保两处菜单项一致。
            PlayerMoreMenu {
                circleIcon("ellipsis")
            }
            .frame(width: 36, height: 36)
            .fixedSize()
            .pmGlassControl(Circle())
            .help(Text("more"))

            if !isWindowFullScreen {
                Button {
                    onClose()
                } label: {
                    circleIcon("chevron.down")
                }
                .buttonStyle(.plain)
                .pmGlassControl(Circle())
                .help(Text("close"))
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var fullscreenVolumeControl: some View {
        HStack(spacing: 8) {
            PMVolumeSymbol()
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(playerPrimaryColor.opacity(0.82))
                .frame(width: 18)

            PMPlaybackVolumeSlider(tint: theme.accentColor)
            .frame(width: 118)

            PMVolumePercentage()
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
        .pmGlassControl(Capsule())
        .help(!player.isLiveRadio && player.playbackSettings.outputMode == .highFidelity
            ? Text("volume_high_fidelity_system_hint")
            : Text("volume"))
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

    /// 有声内容右栏的文字稿那一页。没有文字稿时写明没有、能生成就给生成,生成中在这里看进度(#314)。
    @ViewBuilder
    private var spokenWordTextTab: some View {
        if lyrics.isEmpty, !isLoadingLyrics, let song = player.currentSong {
            SpokenTranscriptEmptyState(
                content: SpokenTranscriptEmptyState.Content(
                    song: song,
                    onOpenGeneration: { transcriptGenerationSong = player.currentSong },
                    onShowNotes: SpokenWordPlayerText.isPodcastEpisode(player)
                        ? { contentsRequestedTab = .notes }
                        : nil
                ),
                palette: spokenWordPalette
            )
        } else {
            lyricsPane.overlay(alignment: .topTrailing) {
                if !lyrics.isEmpty { transcriptReaderButton }
            }
        }
    }

    /// 文字稿页右上角:全屏读、调字体与间距。
    private var transcriptReaderButton: some View {
        Button {
            showsTranscriptReader = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pmGlassControl(Circle())
        .help(Text("transcript_read_fullscreen"))
        .padding(8)
    }

    private func toggleLikedCurrent() {
        guard let song = player.currentSong else { return }
        if PodcastPlaybackSong.isEpisode(song) {
            player.toggleLikeForCurrentPodcastEpisode()
            return
        }
        library.toggleLiked(songID: song.id)
    }

    private func selectFullscreenEffect(_ value: FullscreenPlayerEffect) {
        fullscreenPlayerEffectRawValue = value.rawValue
        FullscreenPlayerEffectSync.shared.select(value)
    }

    private func closeFullscreenEffectPicker() {
        pmWithAnimation(.panel) {
            showsNativeFullscreenEffectPicker = false
        }
    }

    private func exitFullScreen() {
        guard let window = fullScreenWindow() else { return }
        guard isWindowFullScreen || window.styleMask.contains(.fullScreen) else { return }
        showsNativeFullscreenEffectPicker = false
        // 进入全屏时补过一次 `.fullScreenPrimary`:SwiftUI 的 WindowGroup 不带它,
        // 而少了它 `toggleFullScreen` 会静默什么都不做 —— 退出这一侧同样要补,
        // 否则窗口重新配置之后按钮和 Esc 走到这里都像是「没反应」。
        if !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        window.toggleFullScreen(nil)
        #if DEBUG
        plog("🖥 退出全屏: mask=\(window.styleMask.rawValue) cb=\(window.collectionBehavior.rawValue)")
        #endif
    }

    private func fullScreenWindow() -> NSWindow? {
        // 宿主窗口正常情况下已经解析好了;万一还没有(或视图刚被重建),退出全屏这件事
        // 不能就这么点不动 —— 按钮只在全屏里出现,直接找那个处于全屏的窗口兜底。
        if let hostWindow { return hostWindow }
        return NSApp.windows.first { $0.styleMask.contains(.fullScreen) }
    }

    // MARK: - Lyrics loading

    private func refreshLyrics() async {
        if let pendingLyricsOverride,
           pendingLyricsOverride.songID == player.currentSong?.id {
            self.pendingLyricsOverride = nil
            installLyrics(pendingLyricsOverride.lyrics)
            _ = updateIndex(time: player.currentTime, animated: false)
            return
        }
        pendingLyricsOverride = nil
        await reloadLyrics()
    }

    private func reloadLyrics() async {
        guard let song = player.currentSong else {
            installLyrics([])
            currentIndex = -1
            activeInterludeAnchor = nil
            return
        }
        // 先清掉上一首的内容,避免在异步加载途中显示「上首歌的歌词」。
        installLyrics([])
        currentIndex = -1
        activeInterludeAnchor = nil

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
        _ = updateIndex(time: player.currentTime, animated: false)
    }

    private func installLyrics(_ loaded: [LyricLine]) {
        loadedLyrics = loaded
        // 文稿按这一集 / 这本书的偏移平移时间轴(#320);音乐原样。
        let newLyrics = SpokenWordTranscriptOffsetStore.shared.presenting(
            LyricBundledTranslationPolicy.presentation(
                of: loaded,
                showsBundledTranslations: LyricsTranslationSettingsStore.shared.showsBundledTranslations
            ).lines,
            for: player.currentSong
        )
        if lyrics != newLyrics {
            lyricsTranslationRevision &+= 1
        }
        lyrics = newLyrics
        let resolvedDirection = LyricWritingDirectionPolicy.resolve(in: newLyrics)
        if lyricsWritingDirection != resolvedDirection {
            lyricsWritingDirection = resolvedDirection
        }
        if newLyrics.isEmpty, !activeBackgroundLineIDs.isEmpty {
            activeBackgroundLineIDs = []
        }
        refreshRomanizedLyrics()
    }

    /// 按罗马音设置得出显示用的那份歌词（与 iPhone 播放页同一套规则）。
    private func refreshRomanizedLyrics() {
        let mode = LyricsRomanizationSettingsStore.shared.displayMode
        let display = LyricRomanizationDisplayPolicy.displayLines(
            lyrics,
            overlay: lyricRomanizationOverlay,
            mode: mode
        )
        if display != romanizedLyrics { romanizedLyrics = display }
        let direction = mode == .romanizationOnly && display != lyrics
            ? LyricWritingDirectionPolicy.resolve(in: display)
            : lyricsWritingDirection
        if direction != romanizedLyricsWritingDirection { romanizedLyricsWritingDirection = direction }
    }

    /// 按播放时间更新当前句与正在走的提示点,返回该滚到哪(和 iPhone 歌词页的 `updateCurrentLine` 同一套分支)。
    /// 提示点展开或收起会把下面几句推开、拉回,`animated` 时和滚动走同一条曲线;刚装上歌词时直接到位。
    @discardableResult
    private func updateIndex(time: TimeInterval, animated: Bool = true) -> MacLyricsScrollAnchor? {
        updateActiveBackgroundLines(at: time)
        let index: Int
        let interlude: MacLyricsScrollAnchor?
        switch LyricPlaybackPositionPolicy.scrollTarget(
            in: lyrics,
            at: time,
            lookahead: lyricsLookahead
        ) {
        case .line(let line)?:
            index = line
            interlude = nil
        case .interlude(let line)?:
            index = line
            // 关掉了间奏提示点就没有那一行可停,照旧停在上一句。
            interlude = showsLyricsInterlude && lyrics.indices.contains(line)
                ? .interlude(afterLineID: lyrics[line].id)
                : nil
        case .intro?:
            // 第一句还没开始:没有当前句;关掉了提示点就像原来一样停在开头不动。
            index = -1
            interlude = showsLyricsInterlude ? .intro : nil
        case nil:
            index = -1
            interlude = nil
        }
        if activeInterludeAnchor != interlude {
            let update = {
                if currentIndex != index { currentIndex = index }
                activeInterludeAnchor = interlude
            }
            if animated {
                withAnimation(.smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0), update)
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, update)
            }
        } else if currentIndex != index {
            currentIndex = index
        }
        if let interlude { return interlude }
        return lyrics.indices.contains(index) ? .line(lyrics[index].id) : nil
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
        player.seekToTappedLine(at: line.timestamp)
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
    @AppStorage(PlayerAppearancePreferences.progressStyleKey)
    private var progressStyleRawValue = NowPlayingProgressStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.progressGlowKey)
    private var progressGlows = PlayerAppearancePreferences.progressGlowByDefault
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
                trackStyle: .forProgressStyle(
                    PlayerAppearancePreferences.progressStyle(rawValue: progressStyleRawValue),
                    glows: progressGlows
                ),
                isPlaying: player.isPlaying,
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
    @Environment(AudioPlayerService.self) private var player
    @State private var podcastSheet: PodcastPlayerSheetTarget?
    @AppStorage(PlayerAppearancePreferences.showsAlbumInSubtitleKey)
    private var showsAlbumInSubtitle = PlayerAppearancePreferences.showsAlbumInSubtitleByDefault

    /// 「歌名下显示专辑名」关掉时音乐只写艺人(和 iPhone 同一个开关);有声书、播客这一栏是
    /// 书名、节目名,照旧。
    private var showsAlbumLine: Bool {
        showsAlbumInSubtitle || podcastShowID != nil || bookID != nil
            || PodcastPlaybackSong.isEpisode(song)
            || (player.currentSong?.id == song.id && player.currentItemIsSpokenWord)
    }

    /// 正在播的有声内容所在的书; 艺人页与专辑页只收音乐, 对它是空的。
    /// 播客单集没有书, 专辑那一栏是节目名, 点开的是节目页。
    private var bookID: String? {
        guard player.currentSong?.id == song.id,
              player.currentItemIsSpokenWord, !player.isLiveRadio,
              !PodcastPlaybackSong.isEpisode(song) else { return nil }
        return player.currentBookID
    }

    private var podcastShowID: String? {
        guard player.currentSong?.id == song.id else { return nil }
        return SpokenWordPlayerText.podcastShowID(player)
    }

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
            if showsAlbumLine, let title = trimmed(song.albumTitle) {
                if let podcastShowID {
                    metadataLink(title, help: "podcast_go_to_show") {
                        podcastSheet = .show(podcastShowID)
                    }
                } else if let bookID {
                    metadataLink(title, help: "spoken_word_go_to_book") {
                        NotificationCenter.default.post(name: .primuseDetailOpenSpokenWordBook, object: bookID)
                    }
                } else if PodcastPlaybackSong.isEpisode(song) {
                    Text(verbatim: title).foregroundStyle(foreground)
                } else if let album = matchingAlbum {
                    metadataLink(title, help: "go_to_album") {
                        NotificationCenter.default.post(name: .primuseDetailOpenAlbum, object: album)
                    }
                } else {
                    Text(verbatim: title).foregroundStyle(foreground)
                }
            }
        }
        .lineLimit(1)
        .sheet(item: $podcastSheet) { target in
            NowPlayingPodcastSheet(target: target)
        }
    }

    private func metadataLink(_ title: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        MacNowPlayingMetadataLink(
            title: title, help: help, foreground: foreground, highlight: highlight, action: action
        )
    }

    private func matchingArtist(name: String, index: Int) -> Artist? {
        if let artist = library.visibleArtist(named: name) {
            return artist
        }
        guard index == 0, let id = song.artistID else { return nil }
        return library.visibleArtist(id: id)
    }

    private var matchingAlbum: Album? {
        library.linkedAlbum(for: song)
            // 曲库里一首都没有的 Apple Music 专辑按目录现拼一张。
            ?? AppServices.shared.appleMusicLibrary.catalogAlbum(forCatalogOnlySong: song)
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

/// 有声内容的一行小控件, 跟 iPhone 播放页 `nowPlayingChapterLink` 同一套:
/// 当前章节 (点开章节与书签)、上一章/下一章、加书签、听书速度。
/// 音乐且不带章节时整行不出现。单独成视图, 章节随播放头变化只重算这一行。
private struct MacNowPlayingSpokenWordRow: View {
    let foreground: Color

    @Environment(AudioPlayerService.self) private var player
    @State private var showsChapterList = false
    @State private var bookmarkFeedbackToken = 0

    private var store: SpokenWordStore { SpokenWordStore.shared }

    var body: some View {
        let isSpokenWord = player.currentItemIsSpokenWord && !player.isLiveRadio
        if player.hasChapters || isSpokenWord {
            HStack(spacing: 14) {
                if player.hasChapters || hasCurrentBookmarks {
                    Button { showsChapterList = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: player.hasChapters ? "list.bullet.indent" : "bookmark")
                                .font(.caption)
                            if player.hasChapters {
                                Text(verbatim: player.currentChapter?.title
                                    ?? String(localized: "chapters_title"))
                                    .lineLimit(1)
                            } else {
                                Text("spoken_word_bookmarks_title")
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("spoken_word_chapters_and_bookmarks"))
                    .accessibilityLabel(Text("chapters_title"))
                    .layoutPriority(1)
                }

                if player.hasChapters {
                    Button { player.seekToPreviousChapter() } label: {
                        Image(systemName: "backward.end")
                            .frame(minWidth: 24, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(player.currentChapterIndex == nil)
                    .help(Text("spoken_word_previous_chapter"))

                    Button { player.seekToNextChapter() } label: {
                        Image(systemName: "forward.end")
                            .frame(minWidth: 24, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled((player.currentChapterIndex ?? -1) + 1 >= player.spokenWordChapters.count)
                    .help(Text("spoken_word_next_chapter"))
                }

                if isSpokenWord {
                    Button {
                        if player.addSpokenWordBookmark() { bookmarkFeedbackToken += 1 }
                    } label: {
                        Image(systemName: "bookmark")
                            .symbolEffect(.bounce, value: bookmarkFeedbackToken)
                            .frame(minWidth: 24, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("spoken_word_add_bookmark"))

                    Menu {
                        Picker(selection: rateBinding) {
                            ForEach(SpokenWordPlaybackRatePolicy.presets, id: \.self) { rate in
                                Text(verbatim: SpokenWordPlaybackRatePolicy.label(for: rate)).tag(rate)
                            }
                        } label: {
                            Text("spoken_word_playback_rate")
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(verbatim: SpokenWordPlaybackRatePolicy.label(
                            for: rateAdjustable ? player.currentSpokenWordRate : 1
                        ))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!rateAdjustable)
                    .help(Text("spoken_word_playback_rate"))
                }
            }
            .foregroundStyle(foreground)
            .sheet(isPresented: $showsChapterList) {
                SpokenWordContentsView()
                    .frame(minWidth: 380, minHeight: 440)
            }
        }
    }

    /// 高保真直通输出不能变速, 速度菜单那时只显示 1× 且不可点。
    private var rateAdjustable: Bool {
        player.playbackSettings.outputMode == .effects
    }

    private var hasCurrentBookmarks: Bool {
        guard let songID = player.currentSong?.id else { return false }
        _ = store.revision
        return !store.bookmarks(forSongID: songID).isEmpty
    }

    private var rateBinding: Binding<Float> {
        Binding(
            get: { player.currentSpokenWordRate },
            set: { player.setSpokenWordRateForCurrentBook($0) }
        )
    }
}

/// `.sheet(item:)` 要一个 Identifiable; 电台详情只认 id。
private struct MacRadioDetailTarget: Identifiable {
    let id: String
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

/// 惰性歌词列表的一格:只存怎么建这一行,真正排到屏幕上才调用。
private struct MacDeferredLyricRow<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View { content() }
}
#endif
