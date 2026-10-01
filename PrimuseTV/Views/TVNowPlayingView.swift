#if os(tvOS)
import AVKit
import SwiftUI
import PrimuseKit
import UIKit

private var tvDebugImmersiveLaunch: (show: Bool, picker: Bool) {
    #if DEBUG
    let screen = TVDebugLaunch.screen
    return (screen == "immersivePlayer" || screen == "immersivePicker", screen == "immersivePicker")
    #else
    return (false, false)
    #endif
}

/// 截图用:TV_SCREEN=playerShelf 打开播放页时直接升起货架,TV_SHELF_TAB 指定停在哪一栏。
private var tvDebugShelfLaunch: (show: Bool, tab: TVPlayerShelfTab) {
    #if DEBUG
    let tab = ProcessInfo.processInfo.environment["TV_SHELF_TAB"].flatMap(TVPlayerShelfTab.init(rawValue:))
    return (TVDebugLaunch.screen == "playerShelf", tab ?? .thisAlbum)
    #else
    return (false, .thisAlbum)
    #endif
}

/// tvOS 正在播放 — 左列封面+元数据+进度+传输键,右列巨幅逐字歌词(对应 TVNowPlayingArtboard)。
/// 按封面或往下走到底升起快切货架(`TVPlayerShelf`),在播放页里直接换专辑 / 艺术家 / 流派;
/// 长按封面是喜欢、前往、随机、睡眠定时与更多。Menu 键先收起货架,再离开播放页。
struct TVNowPlayingView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.resetFocus) private var resetFocus
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 进度条两端时间标签的宽度。原本写死 56pt,放得下「0:18」放不下「-3:58」,
    /// 于是「-3:5」和「8」被折成了两行;跟着系统文字大小放大只会更挤。
    /// 按 meta 字号同步缩放,并留足最长形如 -63:20 的六个等宽字符。
    @ScaledMetric(wrappedValue: 96, relativeTo: .caption) private var timeLabelWidth: CGFloat

    var isTabContent = false
    var focusRequest: TVContentFocusRequest?
    var interactionRequest = 0
    var onContentAppeared: (TVNowPlayingFocusMode) -> Void = { _ in }
    var onContentModeChanged: (TVNowPlayingFocusMode) -> Void = { _ in }
    var onProgressFocused: () -> Void = {}
    var onReturnToTabs: () -> Void = {}
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    @State private var artworkDirectionalCommands = TVImmersiveDirectionalCommandState()
    @State private var showOptions = false
    /// 按歌手名打开的艺人页(多位艺人时先选一位)。
    @State private var artistLink: TVArtistLinkPresentation?
    @State private var showShelf = tvDebugShelfLaunch.show
    @State private var shelfTab = tvDebugShelfLaunch.tab
    /// 「更多」里点了前往专辑 / 艺术家:等选项层收起后再升起货架。
    @State private var pendingShelfTab: TVPlayerShelfTab?
    @State private var showSpokenWordRate = false
    @State private var showSpokenWordSleep = false
    @State private var spokenWordBookmarkFeedback = 0
    @State private var showImmersive = tvDebugImmersiveLaunch.show
    @State private var immersiveStartsWithEffectPicker = tvDebugImmersiveLaunch.picker
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenPlayerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    /// 最近一次遥控操作的时间戳。播放中静置一段时间自动进入沉浸展示。
    /// 不用 @State 的 Date:每次移动焦点都会写它,写一次就让整个播放页(连同货架)重算一遍。
    @State private var interactionClock = TVInteractionClock()
    @Namespace private var playerFocus
    @FocusState private var focusedTransport: TVNowPlayingFocusTarget?
    @FocusState private var scrubberFocused: Bool

    /// 播放中静置多久自动进入沉浸展示(设计稿「展示屏」的待机语义)。
    private let immersiveIdleThreshold: TimeInterval = 20

    private var activePresentationCount: Int {
        [showOptions, showImmersive, showSpokenWordRate, showSpokenWordSleep, artistLink != nil]
            .filter { $0 }.count
    }

    private var fullscreenPlayerEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: fullscreenPlayerEffectRawValue) ?? .defaultValue
    }

    private func presentImmersivePlayer(isUserInitiated: Bool) {
        // 原生模式已经显示在当前页面,无需呈现后立即关闭全屏视图。
        guard fullscreenPlayerEffect != .native else { return }
        immersiveStartsWithEffectPicker = ImmersiveEffectEntryPolicy
            .tvLaunchPresentsEffectPicker(
                isUserInitiated: isUserInitiated,
                savedEffectIsNative: fullscreenPlayerEffect == .native
            )
        showImmersive = true
    }

    private func lyricLayoutDirection(
        for writingDirection: LyricWritingDirection
    ) -> LayoutDirection {
        switch writingDirection {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    var body: some View {
        ZStack {
            if store.hasNowPlaying { player } else { emptyState }
        }
        .onExitCommand {
            if showShelf {
                closeShelf(startedPlayback: false)
            } else if isTabContent {
                onReturnToTabs()
            } else {
                dismiss()
            }
        }
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            onContentAppeared(focusMode)
        }
        .task(id: focusRequest?.id) {
            guard let request = focusRequest else { return }
            await Task.yield()
            guard !Task.isCancelled, focusRequest == request else { return }
            applyFocusRequest(request)
        }
        .onChange(of: focusMode) { _, mode in
            onContentModeChanged(mode)
        }
        .fullScreenCover(isPresented: $showOptions, onDismiss: {
            guard let tab = pendingShelfTab else { return }
            pendingShelfTab = nil
            openShelf(tab)
        }) {
            TVOptionsView(onGoTo: { pendingShelfTab = $0 }).environment(store)
        }
        .fullScreenCover(item: $artistLink) { link in
            TVArtistLinkView(artists: link.artists).environment(store)
        }
        #if DEBUG
        .task {
            // 截图用:TV_SCREEN=nowPlayingArtist 模拟在播放页按下歌手名。
            guard TVDebugLaunch.screen == "nowPlayingArtist" else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let artists = linkedArtists(songID: store.nowPlaying.songID)
            if !artists.isEmpty { artistLink = TVArtistLinkPresentation(artists: artists) }
        }
        #endif
        .fullScreenCover(isPresented: $showSpokenWordRate) { TVSpokenWordRatePicker().environment(store) }
        .fullScreenCover(isPresented: $showSpokenWordSleep) { TVSpokenWordSleepPicker().environment(store) }
        .fullScreenCover(isPresented: $showImmersive) {
            TVImmersivePlayerView(
                presentsModePickerOnAppear: immersiveStartsWithEffectPicker
            )
            .environment(store)
        }
        .onChange(of: focusedTransport) { _, _ in
            // 遥控切换焦点即视为有操作,推迟自动进入沉浸展示。
            registerInteraction()
        }
        .onChange(of: scrubberFocused) { _, focused in
            if focused { onProgressFocused() }
        }
        .onChange(of: interactionRequest) { _, _ in
            registerInteraction()
        }
        .onChange(of: activePresentationCount) { _, count in
            onModalActivityChanged(count > 0)
        }
        .onChange(of: showImmersive) { _, presented in
            if !presented {
                immersiveStartsWithEffectPicker = false
                interactionClock.touch()
            }
        }
        .onDisappear {
            if activePresentationCount > 0 {
                onModalActivityChanged(false)
            }
        }
        .task(id: store.hasNowPlaying) {
            // 仅普通歌曲播放态跑空闲检测:直播 / MV 有自己的画面,不进入沉浸展示。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                // 听书不进沉浸展示:那是给音乐的画面,书的播放页本身就是要看的。
                guard store.hasNowPlaying, store.isPlaying,
                      !store.isLiveRadio, !store.isMusicVideoPlaybackActive,
                      !store.currentItemIsSpokenWord,
                      fullscreenPlayerEffect != .native,
                      !showImmersive, !showShelf, !showOptions, !scrubberFocused else { continue }
                if interactionClock.secondsSinceLastInteraction >= immersiveIdleThreshold {
                    presentImmersivePlayer(isUserInitiated: false)
                }
            }
        }
    }

    private var emptyState: some View {
        ZStack {
            TVAmbientBackdrop(strength: 0.55)
            VStack(spacing: 18) {
                Image(systemName: "play.circle").font(.system(size: 96))
                    .foregroundStyle(TVColor.textFaint)
                Text(PMString("ext.tv.nowPlaying.notPlaying")).tvFont(size: 40, weight: .bold, relativeTo: .title2).foregroundStyle(TVColor.text)
                Text(PMString("ext.tv.nowPlaying.pickASong")).tvFont(.caption).foregroundStyle(TVColor.textMuted)
            }
            .padding(.top, isTabContent ? TVSpace.pageTop / 2 : 0)
        }
    }

    private var player: some View {
        let colors = store.nowPlayingPresentationColors
        return ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 1)
            playerContent
                // 货架升起时后面的控件不参与焦点,上键不会把焦点带回传输键。
                .disabled(showShelf)
            if showShelf, supportsShelf {
                TVPlayerShelf(initialTab: shelfTab, onClose: closeShelf, onInteraction: registerInteraction)
                    .equatable()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35, extraBounce: 0), value: showShelf)
    }

    /// 货架只给音乐:电台换台在电台页,听书的目录已经在右栏。
    private var supportsShelf: Bool {
        !store.isLiveRadio && !store.currentItemIsSpokenWord
    }

    private func openShelf(_ tab: TVPlayerShelfTab) {
        guard supportsShelf else { return }
        registerInteraction()
        shelfTab = tab
        showShelf = true
    }

    private func closeShelf(startedPlayback: Bool) {
        registerInteraction()
        showShelf = false
        // 焦点回到封面:刚换的歌就在眼前,再按一下又能打开货架接着挑。
        Task { @MainActor in
            await Task.yield()
            scrubberFocused = false
            // MV 画面上 `.songPrimary` 是播放键,普通播放页上是封面。
            focusedTransport = .songPrimary
        }
    }

    @ViewBuilder
    private var playerContent: some View {
        ZStack {
            if store.isLiveRadio {
                liveRadioPlayer
            } else if store.isMusicVideoPlaybackActive {
                musicVideoFullScreenPlayer
            } else {
                LinearGradient(colors: playerScrim,
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                HStack(alignment: .top, spacing: 80) {
                    if store.currentItemIsSpokenWord {
                        // 有声内容:左边是书与听书的控件,右边是这本书的目录与书签。
                        spokenWordLeftColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focusSection()
                        TVSpokenWordContentsColumn(onInteraction: registerInteraction)
                            .frame(width: 720)
                            .frame(maxHeight: .infinity)
                    } else {
                        leftColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focusSection()
                        lyricsColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .focusScope(playerFocus)
                .padding(.horizontal, 100)
                .padding(.top, isTabContent ? TVSpace.pageTop : 80)
                .padding(.bottom, isTabContent ? TVSpace.pageBottom : 70)
            }
        }
    }

    private var liveRadioPlayer: some View {
        ZStack {
            LinearGradient(colors: playerScrim, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            HStack(spacing: 84) {
                if let station = store.currentRadioStation {
                    TVRadioArtworkView(station: station, size: 500, radius: 30, store: store)
                        .shadow(color: .black.opacity(0.55), radius: 42, y: 22)
                } else {
                    TVMusicPlaceholder(
                        tint: store.nowPlayingPresentationColors.primary,
                        tint2: store.nowPlayingPresentationColors.secondary,
                        size: 500,
                        radius: 30
                    )
                }

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.radio.title"))
                    Text(store.nowPlaying.title)
                        .tvFont(size: 72, weight: .bold, relativeTo: .largeTitle)
                        .tracking(-1.2)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2)
                        .padding(.top, 18)
                    Text(store.nowPlaying.artist)
                        .tvFont(.sectionTitle, weight: .medium)
                        .foregroundStyle(TVColor.textMuted)
                        .lineLimit(2)
                        .padding(.top, 14)

                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 13, height: 13)
                            .shadow(color: .red.opacity(0.7), radius: 8)
                        Text(PMString("ext.tv.radio.live"))
                            .tvFont(.caption, weight: .bold)
                        if store.currentTime > 0 {
                            Text("· \(TVFmt.time(store.currentTime))")
                                .tvFont(.caption, design: .monospaced)
                        }
                    }
                    .foregroundStyle(TVColor.text)
                    .padding(.top, 26)

                    if let issue = store.playbackIssue {
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .tvFont(.caption, weight: .medium)
                            .foregroundStyle(TVColor.warn)
                            .lineLimit(3)
                            .padding(.top, 22)
                    }

                    Spacer(minLength: 34)

                    HStack(spacing: 18) {
                        focusedRoundButton(
                            icon: "backward.fill",
                            size: 76,
                            accessibilityLabel: PMString("ext.control.previous"),
                            target: .previous
                        ) {
                            store.previous()
                        }
                        .disabled(!store.trackNavigationAvailability.canGoPrevious)

                        focusedRoundButton(
                            icon: radioConnectionIsActive ? "stop.fill" : "play.fill",
                            size: 76,
                            accessibilityLabel: PMString(
                                radioConnectionIsActive ? "ext.tv.radio.stop" : "ext.tv.radio.play"
                            ),
                            target: .liveRadioPrimary
                        ) {
                            store.togglePlayPause()
                        }

                        focusedRoundButton(
                            icon: "forward.fill",
                            size: 76,
                            accessibilityLabel: PMString("ext.control.next"),
                            target: .next
                        ) {
                            store.next()
                        }
                        .disabled(!store.trackNavigationAvailability.canGoNext)

                        Text(PMString(radioConnectionIsActive ? "ext.tv.radio.stop" : "ext.tv.radio.play"))
                            .tvFont(.eyebrow)
                            .foregroundStyle(TVColor.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 500, alignment: .leading)
                .focusSection()
            }
            .focusScope(playerFocus)
            .padding(.horizontal, 110)
            .padding(.top, isTabContent ? TVSpace.pageTop : 110)
            .padding(.bottom, isTabContent ? TVSpace.pageBottom : 110)
        }
    }

    private var radioConnectionIsActive: Bool {
        store.engine.status == .loading || store.engine.status == .playing
    }

    private var loadingStatus: some View {
        HStack(spacing: 14) {
            ProgressView()
            if let progress = store.engine.downloadProgress {
                Text(String(localized: "offline_downloading") + " " + progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            } else {
                Text(String(localized: "radio_buffering"))
            }
        }
        .tvFont(.caption)
        .accessibilityIdentifier("tv.playback.loading")
    }

    private var focusMode: TVNowPlayingFocusMode {
        guard store.hasNowPlaying else { return .empty }
        return store.isLiveRadio ? .liveRadio : .song
    }

    private func applyFocusRequest(_ request: TVContentFocusRequest?) {
        guard let request, case let .nowPlaying(target) = request.target else { return }
        // 货架开着时焦点归货架:弹层收起后的焦点恢复不能把它关掉;只有长按播放键
        // 跳进度才收起货架(它挡在进度条前面)。
        if showShelf {
            guard target == .scrubber else { return }
            showShelf = false
        }
        if target == .scrubber, focusMode == .song, store.duration > 0 {
            registerInteraction()
            focusedTransport = nil
            resetFocus(in: playerFocus)
            scrubberFocused = true
        } else if request.target == TVContentFocusRoutingPolicy.target(
            for: .nowPlaying, nowPlayingMode: focusMode
        ) {
            scrubberFocused = false
            focusedTransport = target
        }
    }

    private func focusedRoundButton(
        icon: String,
        size: CGFloat,
        accessibilityLabel: String,
        primary: Bool = false,
        immersiveDark: Bool = false,
        target: TVNowPlayingFocusTarget,
        action: @escaping () -> Void
    ) -> some View {
        let focused = focusedTransport == target
        return Button {
            interactionClock.touch()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(primary
                                 ? (immersiveDark ? Color(hex: "#1f1c19") : TVColor.onBrand)
                                 : (immersiveDark ? Color.white : TVColor.text))
                .frame(width: size, height: size)
                .background(primary
                            ? AnyShapeStyle(immersiveDark ? Color.white : TVColor.brand)
                            : AnyShapeStyle(immersiveDark ? Color.white.opacity(0.14) : TVColor.surfaceStrong),
                            in: Circle())
                .tvFocusRing(
                    focused,
                    radius: size / 2,
                    accent: immersiveDark ? Color.white : TVColor.focusRing,
                    scale: 1.14,
                    lift: 8
                )
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedTransport, equals: target)
        .focusEffectDisabled()
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    // MARK: 左列

    private var musicVideoFullScreenPlayer: some View {
        let np = store.nowPlaying
        return ZStack {
            TVMusicVideoSurface(player: store.engine.displayPlayer)
                .ignoresSafeArea()
                .background(.black)

            LinearGradient(
                colors: [.black.opacity(0.62), .black.opacity(0.08), .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(
                    text: PMString("ext.tv.nowPlaying.eyebrow"),
                    color: .white.opacity(0.62)
                )
                .padding(.bottom, 18)
                Text(np.title)
                    .tvFont(size: 58, weight: .bold, relativeTo: .largeTitle)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(np.artist)
                    .tvFont(.cardTitle, weight: .regular)
                    .foregroundStyle(.white.opacity(0.74))
                    .padding(.top, 8)
                Text(metadataLine(np))
                    .tvFont(.caption)
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.top, 5)

                Spacer(minLength: 0)

                if let issue = store.playbackIssue {
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .tvFont(.caption, weight: .medium)
                        .foregroundStyle(TVColor.warn)
                        .lineLimit(2)
                        .padding(.bottom, 18)
                } else if let preparing = MusicVideoPreparationStatus.shared.label(for: np.songID) {
                    Label(preparing, systemImage: "film")
                        .tvFont(.caption, weight: .medium)
                        .foregroundStyle(.white.opacity(0.74))
                        .monospacedDigit()
                        .padding(.bottom, 18)
                } else if store.isLoading {
                    loadingStatus.padding(.bottom, 18)
                }

                scrubber(immersiveDark: true)
                    .padding(.bottom, 20)
                transport(immersiveDark: true)
            }
            .focusScope(playerFocus)
            .focusSection()
            .padding(.horizontal, 100)
            .padding(.top, isTabContent ? TVSpace.pageTop : 78)
            .padding(.bottom, isTabContent ? TVSpace.pageBottom : 70)
        }
        .environment(\.colorScheme, .dark)
    }

    private var leftColumn: some View {
        let np = store.nowPlaying
        return VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: PMString("ext.tv.nowPlaying.eyebrow")).padding(.bottom, 16)
            // 按封面 = 浏览这张专辑(货架);暂停交给遥控器的播放键,确认键不再重复它。
            // 封面和长按菜单是单独的视图:这里每拍都随进度、歌词重算,菜单若跟着
            // 重建,打开期间整块会一直闪。
            TVNowPlayingArtworkButton(
                np: np,
                isPlaying: store.isPlaying,
                isAnimationVisible: activePresentationCount == 0,
                isFocused: focusedTransport == .songPrimary,
                onOpenShelf: openShelf,
                onShowMore: { showOptions = true }
            )
            .equatable()
            .focused($focusedTransport, equals: .songPrimary)
            .focusEffectDisabled()
            .onMoveCommand(perform: handleArtworkMove)
            .accessibilityLabel(Text(PMString("ext.tv.player.browse")))
            .accessibilityHint(Text(PMString("ext.tv.nowPlaying.artworkHint")))
            .accessibilityIdentifier("tv.nowPlaying.artworkControls")
            Text(np.title).tvFont(.pageTitle).tracking(-0.8)
                .foregroundStyle(TVColor.text).lineLimit(2).padding(.top, 26)
            artistLine(np).padding(.top, 8)
            if store.isMedleyActive {
                TVPillButton(title: String(format: String(localized: "medley_badge_format"), store.activeMedleySegmentSeconds),
                             systemImage: "shuffle") { store.continueCurrentMedleySongInFull() }
                    .accessibilityLabel(Text("medley_continue_full"))
                    .accessibilityIdentifier("tv.medley.continueFull")
                    .padding(.top, 12)
            }
            Text(metadataLine(np))
                .tvFont(.caption).foregroundStyle(TVColor.textFaint).padding(.top, 4)

            TVLibraryReviewControl(subject: .song(np.songID))
                .padding(.top, 16)

            if let issue = store.playbackIssue {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .tvFont(.meta, weight: .medium).foregroundStyle(TVColor.warn)
                    .lineLimit(3).frame(maxWidth: 580, alignment: .leading).padding(.top, 14)
            } else if let preparing = MusicVideoPreparationStatus.shared.label(for: np.songID) {
                Label(preparing, systemImage: "film")
                    .tvFont(.meta, weight: .medium).foregroundStyle(TVColor.textMuted)
                    .monospacedDigit().padding(.top, 14)
            } else if store.isLoading {
                loadingStatus.padding(.top, 12)
            }

            Spacer(minLength: 24)
            scrubber(immersiveDark: false).padding(.bottom, 18)
            transport(immersiveDark: false)
            shelfHandle.padding(.top, 14)
        }
    }

    /// 歌手名:曲库里找得到这位(几位)艺人时可以按,进艺人页看全部作品;找不到就是普通文字。
    @ViewBuilder
    private func artistLine(_ np: TVNowPlaying) -> some View {
        let artists = linkedArtists(songID: np.songID)
        if artists.isEmpty {
            Text(np.artist).tvFont(.rowTitle, weight: .regular).foregroundStyle(TVColor.textMuted)
        } else {
            TVFocusButton(radius: 12, scale: 1.0, lift: 0, ring: false, action: {
                artistLink = TVArtistLinkPresentation(artists: artists)
            }) { focused in
                HStack(spacing: 8) {
                    Text(np.artist).tvFont(.rowTitle, weight: .regular).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(focused ? 1 : 0)
                }
                .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(focused ? TVColor.surfaceStrong : .clear, in: Capsule())
            }
            // 字与上面的歌名对齐,高亮底色往外长。
            .padding(.leading, -12)
            .accessibilityLabel(Text(verbatim: np.artist))
            .accessibilityIdentifier("tv.nowPlaying.artist")
        }
    }

    /// 只按 id 查,不整库扫:播放页随进度每拍都会重算这一列。
    private func linkedArtists(songID: String) -> [TVArtist] {
        guard !songID.isEmpty, let song = store.library.song(id: songID) else { return [] }
        let library = store.library
        func resolve(_ name: String) -> Artist? {
            library.visibleArtist(id: MusicLibrary.hashID(ArtistIdentityPolicy.groupingKey(name)))
        }
        let names = ArtistLinkResolutionPolicy.linkCandidates(for: library.artistNames(for: song)) {
            resolve($0) != nil
        }
        return names.compactMap(resolve).map(TVArtistMapper().map)
    }

    /// 传输键下面的把手:焦点往下走到它就升起货架,和系统视频播放器下滑出面板一个手势。
    private var shelfHandle: some View {
        TVFocusButton(radius: 14, scale: 1.02, lift: 0, ring: false, action: {
            openShelf(defaultShelfTab)
        }, onFocusChanged: { focused in
            if focused { openShelf(defaultShelfTab) }
        }) { focused in
            HStack(spacing: 12) {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 26, weight: .semibold))
                Text(PMString("ext.tv.player.shelf.hint"))
                    .tvFont(.caption, weight: .medium)
            }
            .foregroundStyle(focused ? TVColor.text : TVColor.textFaint)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(Text(PMString("ext.tv.player.shelf.hint")))
    }

    /// 从传输键进货架:有队列先看「接下来」,单曲播放时看本专辑。
    private var defaultShelfTab: TVPlayerShelfTab {
        store.queueUpNextIDs.isEmpty ? .thisAlbum : .upNext
    }

    // MARK: 左列 — 有声内容

    /// 书封(竖版)、书名、正在听的一条、演播者与「第几章」,进度(带书签刻度)、
    /// 本章还剩多久与全书进度,再下面是听书的传输键和语速 / 定时 / 书签。
    private var spokenWordLeftColumn: some View {
        let np = store.nowPlaying
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 44) {
                Button {
                    registerInteraction()
                    store.togglePlayPause()
                } label: {
                    Group {
                        if let book = store.currentSpokenWordBook {
                            TVSpokenWordCover(book: book, size: 300, radius: 16)
                        } else {
                            TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                          songID: np.songID, coverRef: np.coverRef,
                                          tint: np.tint, tint2: np.tint2, glyph: np.glyph,
                                          placeholderKind: .book,
                                          size: 300,
                                          height: SpokenWordCoverLayout.height(forWidth: 300),
                                          radius: 16)
                                .bookCoverLayout()
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    .tvFocusRing(focusedTransport == .songPrimary, radius: 16,
                                 accent: TVColor.focusRing, scale: 1.03, lift: 0)
                }
                .buttonStyle(TVBareButtonStyle())
                .focused($focusedTransport, equals: .songPrimary)
                .focusEffectDisabled()
                .accessibilityLabel(Text(PMString(store.isPlaying ? "ext.control.pause" : "ext.control.play")))
                .accessibilityIdentifier("tv.nowPlaying.artworkControls")

                VStack(alignment: .leading, spacing: 12) {
                    TVEyebrow(text: String(localized: "listening_space_spoken_word"))
                    Text(TVSpokenWordText.bookTitle(store))
                        .tvFont(size: 56, weight: .bold, design: .serif, relativeTo: .largeTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if let part = TVSpokenWordText.partTitle(store) {
                        Text(part).tvFont(.body).foregroundStyle(TVColor.text.opacity(0.86)).lineLimit(2)
                    }
                    HStack(spacing: 14) {
                        if let author = TVSpokenWordText.author(store) {
                            Text(author).lineLimit(1)
                        }
                        if let position = TVSpokenWordText.partPosition(store) {
                            Text(verbatim: "·")
                            Text(position).monospacedDigit().foregroundStyle(TVColor.spokenWordSpace)
                        }
                    }
                    .tvFont(.caption, weight: .medium)
                    .foregroundStyle(TVColor.textMuted)
                    // 全书进度属于书的信息,放在书名这一块,不和本章进度条挤在一起。
                    TVSpokenWordBookProgressRow()
                        .frame(maxWidth: 560)
                        .padding(.top, 6)
                }
                .padding(.bottom, 6)
            }

            if let issue = store.playbackIssue {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .tvFont(.meta, weight: .medium).foregroundStyle(TVColor.warn)
                    .lineLimit(3).frame(maxWidth: 680, alignment: .leading).padding(.top, 14)
            } else if store.isLoading {
                loadingStatus.padding(.top, 12)
            }

            Spacer(minLength: 24)

            scrubber(immersiveDark: false)
                .overlay { TVSpokenWordBookmarkTicks().padding(.horizontal, timeLabelWidth + 16) }
            if let remaining = TVSpokenWordText.partRemaining(store) {
                Text(remaining)
                    .tvFont(.meta)
                    .monospacedDigit()
                    .foregroundStyle(TVColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            Spacer().frame(height: 22)
            spokenWordTransport
        }
    }

    /// 听书的传输键:上一章 · 后退 15 秒 · 播放 · 前进 30 秒 · 下一章,
    /// 同一行接着语速、睡眠定时、书签与更多。没有随机 / 循环 / 沉浸 / 队列:
    /// 书按顺序听,目录就在右栏。
    private var spokenWordTransport: some View {
        HStack(spacing: 18) {
            TVRoundBtn(icon: "backward.end.fill", size: 56,
                       accessibilityLabel: String(localized: "spoken_word_previous_chapter"),
                       onInteraction: registerInteraction) { store.goToPreviousSpokenWordPart() }
            focusedRoundButton(
                icon: "gobackward.15",
                size: 72,
                accessibilityLabel: String(localized: "spoken_word_skip_backward"),
                target: .previous
            ) { store.transportBackward() }
            focusedRoundButton(
                icon: store.isPlaying ? "pause.fill" : "play.fill",
                size: 84,
                accessibilityLabel: PMString(store.isPlaying ? "ext.control.pause" : "ext.control.play"),
                primary: true,
                target: .playPause
            ) { store.togglePlayPause() }
            focusedRoundButton(
                icon: "goforward.30",
                size: 72,
                accessibilityLabel: String(localized: "spoken_word_skip_forward"),
                target: .next
            ) { store.transportForward() }
            TVRoundBtn(icon: "forward.end.fill", size: 56,
                       accessibilityLabel: String(localized: "spoken_word_next_chapter"),
                       onInteraction: registerInteraction) { store.goToNextSpokenWordPart() }
                .disabled(!store.canGoToNextSpokenWordPart)
                .opacity(store.canGoToNextSpokenWordPart ? 1 : 0.4)

            Spacer(minLength: 12)

            spokenWordPill(
                title: SpokenWordPlaybackRatePolicy.label(for: store.currentSpokenWordRate),
                systemImage: "gauge.with.dots.needle.67percent",
                accessibilityLabel: String(localized: "spoken_word_book_speed")
            ) { showSpokenWordRate = true }
            spokenWordPill(
                title: spokenWordSleepTitle,
                systemImage: store.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz",
                accessibilityLabel: store.isSleepTimerActive
                    ? String(localized: "sleep_timer_active")
                    : String(localized: "sleep_timer")
            ) { showSpokenWordSleep = true }
            TVRoundBtn(icon: "bookmark", size: 64,
                       accessibilityLabel: String(localized: "spoken_word_add_bookmark"),
                       onInteraction: registerInteraction) {
                if store.addSpokenWordBookmark() { spokenWordBookmarkFeedback += 1 }
            }
            .symbolEffect(.bounce, value: spokenWordBookmarkFeedback)
            TVRoundBtn(icon: "ellipsis", size: 64,
                       onInteraction: registerInteraction) { showOptions = true }
        }
    }

    private var spokenWordSleepTitle: String {
        if let end = store.sleepTimerEndDate {
            let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
            return "\(minutes) " + String(localized: "minutes")
        }
        return TVSpokenWordText.sleepLabel(store)
    }

    private func spokenWordPill(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        TVFocusButton(radius: 32, scale: 1.08, lift: 6, action: {
            registerInteraction()
            action()
        }, onFocusChanged: { focused in
            if focused { registerInteraction() }
        }) { focused in
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 24, weight: .semibold))
                Text(title).tvFont(.caption, weight: .semibold).monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            .padding(.horizontal, 22)
            .frame(height: 64)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong),
                        in: Capsule())
        }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(title))
    }

    private var playerScrim: [Color] {
        if colorScheme == .dark {
            return [.black.opacity(0.30), .black.opacity(0.12), .black.opacity(0.42)]
        }
        return [TVColor.bg.opacity(0.28), TVColor.bg.opacity(0.08), TVColor.bg.opacity(0.48)]
    }

    private func metadataLine(_ np: TVNowPlaying) -> String {
        // 还没读出来的码率/采样率是 0,不显示,免得出现「0 kbps · 0.0 kHz」。
        var encoding: [String] = []
        if !np.format.isEmpty { encoding.append(np.format) }
        if np.bitrate > 0 { encoding.append("\(np.bitrate) kbps") }
        var parts = [np.album, encoding.joined(separator: " ")]
        if np.sampleRate > 0 {
            let khz = np.sampleRate.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(np.sampleRate)) : String(format: "%.1f", np.sampleRate)
            parts.append("\(khz) kHz")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func scrubber(immersiveDark: Bool) -> some View {
        let cur = store.currentTime
        let dur = store.duration
        let p = dur > 0 ? max(0, min(1, cur / dur)) : 0
        return HStack(spacing: 16) {
            Text(TVFmt.time(cur)).tvFont(.meta, design: .monospaced)
                .foregroundStyle(immersiveDark ? Color.white.opacity(0.60) : TVColor.textMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: timeLabelWidth, alignment: .trailing)
            TVScrubber(progress: p, tint: TVColor.brand, immersiveDark: immersiveDark,
                       currentTime: cur, duration: dur,
                       onBack: { store.skipBackward() }, onForward: { store.skipForward() },
                       onInteraction: registerInteraction,
                       onFinish: { focusedTransport = immersiveDark ? .songPrimary : .playPause },
                       focused: $scrubberFocused)
                .prefersDefaultFocus(focusRequest?.target == .nowPlaying(.scrubber), in: playerFocus)
            Text("-\(TVFmt.time(max(0, dur - cur)))").tvFont(.meta, design: .monospaced)
                .foregroundStyle(immersiveDark ? Color.white.opacity(0.60) : TVColor.textMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: timeLabelWidth, alignment: .leading)
        }
    }

    private func transport(immersiveDark: Bool) -> some View {
        let availability = store.trackNavigationAvailability
        // 有声内容:上一首 / 下一首换成后退 15 秒 / 前进 30 秒(与 iPhone、Mac 一致)。
        let isSpokenWord = store.currentItemIsSpokenWord
        let likedSongID = isSpokenWord ? nil : store.currentSongID
        let liked = likedSongID.map(store.isLiked) ?? false
        return HStack(spacing: 16) {
            Spacer()
            // 喜欢是最常按的一颗,放在传输键这一行,不再藏在「更多」里。
            if let likedSongID {
                TVRoundBtn(icon: liked ? "heart.fill" : "heart", size: 56, active: liked,
                           immersiveDark: immersiveDark,
                           accessibilityLabel: PMString(liked ? "ext.tv.options.loved" : "ext.tv.options.love"),
                           onInteraction: registerInteraction) { store.toggleLiked(likedSongID) }
            }
            TVRoundBtn(icon: "shuffle", size: 56, active: store.shuffleEnabled,
                       immersiveDark: immersiveDark,
                       onInteraction: registerInteraction) { store.toggleShuffle() }
            if store.canPlayMusicVideo {
                TVRoundBtn(icon: store.isMusicVideoModeEnabled ? "play.rectangle.fill" : "play.rectangle",
                           size: 56,
                           active: store.isMusicVideoModeEnabled,
                           immersiveDark: immersiveDark,
                           accessibilityLabel: PMString("playback"),
                           onInteraction: registerInteraction) { store.toggleMusicVideoMode() }
            }
            focusedRoundButton(
                icon: isSpokenWord ? "gobackward.15" : "backward.fill",
                size: 64,
                accessibilityLabel: isSpokenWord
                    ? String(localized: "spoken_word_skip_backward")
                    : PMString("ext.control.previous"),
                immersiveDark: immersiveDark,
                target: .previous
            ) { store.transportBackward() }
                .disabled(!isSpokenWord && !availability.canGoPrevious)
            focusedRoundButton(
                icon: store.isPlaying ? "pause.fill" : "play.fill",
                size: 76,
                accessibilityLabel: PMString(
                    store.isPlaying ? "ext.control.pause" : "ext.control.play"
                ),
                primary: true,
                immersiveDark: immersiveDark,
                target: immersiveDark ? .songPrimary : .playPause
            ) { store.togglePlayPause() }
            focusedRoundButton(
                icon: isSpokenWord ? "goforward.30" : "forward.fill",
                size: 64,
                accessibilityLabel: isSpokenWord
                    ? String(localized: "spoken_word_skip_forward")
                    : PMString("ext.control.next"),
                immersiveDark: immersiveDark,
                target: .next
            ) { store.transportForward() }
                .disabled(!isSpokenWord && !availability.canGoNext)
            TVRoundBtn(icon: store.repeatMode == .one ? "repeat.1" : "repeat", size: 56,
                       active: store.repeatMode != .off,
                       immersiveDark: immersiveDark,
                       onInteraction: registerInteraction) { store.cycleRepeatMode() }
            // 浏览 / 沉浸 / 更多在同一行——和传输键焦点左右线性可达,不再困在右上角。
            // 浏览替代原来的队列按钮:「接下来」就是货架的第一栏。
            if supportsShelf {
                TVRoundBtn(icon: "rectangle.stack", size: 56, immersiveDark: immersiveDark,
                           accessibilityLabel: PMString("ext.tv.player.browse"),
                           onInteraction: registerInteraction) { openShelf(defaultShelfTab) }
            }
            TVRoundBtn(icon: "sparkles.tv", size: 56, immersiveDark: immersiveDark,
                       onInteraction: registerInteraction) {
                presentImmersivePlayer(isUserInitiated: true)
            }
            TVRoundBtn(icon: "ellipsis", size: 56, immersiveDark: immersiveDark,
                       onInteraction: registerInteraction) { showOptions = true }
            Spacer()
        }
    }

    private func handleArtworkMove(_ direction: MoveCommandDirection) {
        guard focusedTransport == .songPrimary, activePresentationCount == 0,
              !UIAccessibility.isVoiceOverRunning,
              !UIAccessibility.isSwitchControlRunning else { return }
        let input: TVImmersiveDirectionalInput
        switch direction {
        case .left: input = .left
        case .right: input = .right
        default: return
        }
        registerInteraction()
        let action = artworkDirectionalCommands.action(
            for: input,
            at: ProcessInfo.processInfo.systemUptime,
            controlsVisible: false,
            modePickerVisible: false,
            assistiveNavigationEnabled: false
        )
        switch action {
        case .previousTrack: store.transportBackward(restartCurrentIfNeeded: false)
        case .nextTrack: store.transportForward()
        default: break
        }
    }

    private func registerInteraction() {
        interactionClock.touch()
    }

    // MARK: 右列 — 歌词

    @ViewBuilder
    private var lyricsColumn: some View {
        if store.lyrics.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "text.quote").font(.system(size: 48)).foregroundStyle(TVColor.textGhost)
                Text(PMString("ext.tv.nowPlaying.noLyrics")).tvFont(.rowTitle, weight: .regular).foregroundStyle(TVColor.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            lyricsList
        }
    }

    private var lyricsList: some View {
        let cur = store.currentLyricIndex
        let followsPlayback = store.lyricsFollowPlayback
        // 跟手机端一致:整列歌词放进可滚动容器,随播放进度平滑把当前行滚到视觉中心
        //(`scrollTo(anchor:.center)` + `.smooth`),不再按 index 重算固定窗口硬跳。
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    Color.clear.frame(height: 260)   // 顶部留白:首行也能滚到中心
                    ForEach(Array(store.lyrics.enumerated()), id: \.offset) { i, _ in
                        lyricLine(index: i, current: cur).id(i)
                    }
                    Color.clear.frame(height: 360)   // 底部留白:末行也能滚到中心
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(followsPlayback)
            .focusable(!followsPlayback)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: cur) { _, new in
                guard followsPlayback, let new else { return }
                if reduceMotion {
                    proxy.scrollTo(new, anchor: .center)
                } else {
                    withAnimation(.smooth(duration: 0.55, extraBounce: 0)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
            .onChange(of: store.lyricsRevision) {
                guard store.lyricsFollowPlayback, let current = store.currentLyricIndex else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(current, anchor: .center)
                }
            }
            .onAppear {
                guard followsPlayback, let cur else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(cur, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func lyricLine(index i: Int, current cur: Int?) -> some View {
        let ln = store.lyrics[i]
        let isCur = cur == i
        let dist = cur.map { abs(i - $0) }
        let opacity = isCur ? 1 : dist.map { max(0.42, 0.72 - Double($0) * 0.08) } ?? 0.82
        // 字号固定、靠 scaleEffect 缩放——缩放能平滑动画,直接换 font size 会硬跳。
        let scale: CGFloat = reduceMotion ? 1 : (isCur ? 1.0 : (cur == nil ? 0.90 : 0.84))
        let size: CGFloat = 48
        VStack(alignment: .leading, spacing: 6) {
            if isCur, !ln.syllables.isEmpty {
                // 逐字扫光必须按帧推进:直接读 `store.currentTime` 时一秒只有 4 个
                // 台阶(AVPlayer 周期回调的频率),扫光会四格一跳、而且平均慢半拍。
                // 这里与沉浸播放页、iPhone / Mac 用同一套做法 —— 由 TimelineView
                // 驱动重绘,时间取按墙上时钟补过的播放时钟。
                TimelineView(.animation(
                    minimumInterval: reduceMotion ? 0.10 : 1 / 30,
                    paused: !store.isPlaying
                )) { context in
                    TVKaraokeLine(
                        syllables: ln.syllables,
                        currentTime: store.interpolatedTime(at: context.date),
                        size: size,
                        tint: store.nowPlaying.tint,
                        writingDirection: ln.writingDirection
                    )
                }
            } else {
                // 普通 .lrc 无逐字时间——整行高亮;非当前行半透明。
                Text(ln.text).font(.system(size: size, weight: isCur ? .bold : .semibold))
                    .foregroundStyle(TVColor.text)
                    .shadow(color: isCur ? store.nowPlaying.tint.opacity(0.5) : .clear, radius: 16, y: 2)
                    .multilineTextAlignment(.leading)
            }
            ForEach(ln.background) { background in
                // Backing vocals sing over their own window inside this line,
                // so they follow the same clock at a smaller size.
                if isCur, !background.syllables.isEmpty {
                    TimelineView(.animation(
                        minimumInterval: reduceMotion ? 0.10 : 1 / 30,
                        paused: !store.isPlaying
                    )) { context in
                        TVKaraokeLine(
                            syllables: background.syllables,
                            currentTime: store.interpolatedTime(at: context.date),
                            size: size * 0.7,
                            tint: store.nowPlaying.tint,
                            writingDirection: background.writingDirection
                        )
                    }
                    .opacity(0.72)
                } else {
                    Text(background.text)
                        .font(.system(size: size * 0.7, weight: .semibold))
                        .foregroundStyle(TVColor.text.opacity(0.62))
                        .multilineTextAlignment(.leading)
                }
            }
            if !ln.romanization.isEmpty {
                Text(ln.romanization).tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
            }
            if !ln.translation.isEmpty {
                Text(LyricCompanionTextPolicy.displayText(ln.translation)).tvFont(.caption).italic()
                    .foregroundStyle(TVColor.textFaint)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .opacity(opacity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.5, extraBounce: 0), value: cur)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(ln.text))
        .accessibilityValue(Text(isCur ? PMString("playback") : ""))
        .accessibilityAddTraits(isCur ? [.isSelected] : [])
        .environment(\.layoutDirection, lyricLayoutDirection(for: ln.writingDirection))
    }
}

// MARK: - 逐字卡拉OK行

struct TVSyllableHighlightState: Equatable {
    let index: Int
    let progress: Double
}

enum TVSyllableHighlightPolicy {
    static func state(
        in syllables: [TVSyllable],
        at playbackTime: TimeInterval
    ) -> TVSyllableHighlightState {
        guard playbackTime.isFinite else {
            return TVSyllableHighlightState(index: 0, progress: 0)
        }

        for index in syllables.indices {
            let syllable = syllables[index]
            if playbackTime <= syllable.start {
                return TVSyllableHighlightState(index: index, progress: 0)
            }

            let nextStart = syllables.indices.contains(index + 1)
                ? syllables[index + 1].start
                : nil
            let duration = LyricSyllablePlaybackTimingPolicy.effectiveDuration(
                for: syllable.lyricSyllable,
                nextSyllableStart: nextStart
            )
            let effectiveEnd = syllable.start + duration
            if playbackTime < effectiveEnd {
                return TVSyllableHighlightState(
                    index: index,
                    progress: min(1, max(0, (playbackTime - syllable.start) / duration))
                )
            }
        }

        return TVSyllableHighlightState(index: syllables.count, progress: 0)
    }
}

struct TVKaraokeLine: View {
    let syllables: [TVSyllable]
    let currentTime: TimeInterval
    let size: CGFloat
    let tint: Color
    let writingDirection: LyricWritingDirection

    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lyricLayoutDirection: LayoutDirection {
        switch writingDirection {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    var body: some View {
        let state = TVSyllableHighlightPolicy.state(in: syllables, at: currentTime)
        TVSyllableFlowLayout(layoutDirection: lyricLayoutDirection) {
            ForEach(Array(syllables.enumerated()), id: \.offset) { i, s in
                let active = i < state.index
                let inFlight = i == state.index
                let fillT: Double = active ? 1 : (inFlight ? state.progress : 0)
                let scale = inFlight && !reduceMotion
                    ? 1 + 0.05 * sin(state.progress * .pi)
                    : 1
                Text(s.w)
                    .foregroundStyle(TVColor.textGhost)
                    .overlay(alignment: .leading) {
                        Text(s.w)
                            .foregroundStyle(TVColor.text)
                            .shadow(color: tint.opacity(0.8), radius: 12)
                            .mask {
                                GeometryReader { g in
                                    Rectangle()
                                        .frame(width: g.size.width * fillT)
                                        .frame(
                                            width: g.size.width,
                                            alignment: lyricLayoutDirection == .rightToLeft
                                                ? .trailing
                                                : .leading
                                        )
                                }
                                .environment(\.layoutDirection, .leftToRight)
                            }
                    }
                    .scaleEffect(scale, anchor: .bottom)
            }
        }
        .font(.system(size: size, weight: .bold))
        .shadow(color: tint.opacity(0.4), radius: 16, y: 2)
        .environment(\.layoutDirection, lyricLayoutDirection)
    }
}

private struct TVSyllableFlowLayout: Layout {
    let layoutDirection: LayoutDirection

    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: measure(subviews))
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = measure(subviews)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        ensureMeasurements(in: &cache, subviews: subviews)
        let idealWidth = cache.sizes.reduce(0) { $0 + $1.width }
        let availableWidth = max(0, proposal.width ?? idealWidth)
        guard availableWidth > 0 else { return .zero }

        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for size in cache.sizes {
            if rowWidth > 0, rowWidth + size.width > availableWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width
            rowHeight = max(rowHeight, size.height)
        }

        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(availableWidth, widestRow), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        ensureMeasurements(in: &cache, subviews: subviews)
        let placements = LyricFlowPlacementPolicy.placements(
            itemSizes: cache.sizes.map {
                LyricFlowItemSize(width: Double($0.width), height: Double($0.height))
            },
            containerWidth: Double(bounds.width),
            isRightToLeft: layoutDirection == .rightToLeft,
            alignment: .leading
        )

        for placement in placements {
            let index = subviews.index(subviews.startIndex, offsetBy: placement.itemIndex)
            subviews[index].place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(placement.x),
                    y: bounds.minY + CGFloat(placement.y)
                ),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func ensureMeasurements(in cache: inout Cache, subviews: Subviews) {
        if cache.sizes.count != subviews.count {
            cache.sizes = measure(subviews)
        }
    }

    private func measure(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }
}

// MARK: - MV Surface

private struct TVMusicVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TVMusicVideoLayerView {
        let view = TVMusicVideoLayerView()
        view.setPlayer(player)
        return view
    }

    func updateUIView(_ uiView: TVMusicVideoLayerView, context: Context) {
        uiView.setPlayer(player)
    }
}

private final class TVMusicVideoLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer? {
        layer as? AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer?.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setPlayer(_ player: AVPlayer) {
        playerLayer?.player = player
    }
}

// MARK: - 可聚焦进度条(Siri Remote 左右拖动 ∓10s 定位)

struct TVScrubber: View {
    let progress: Double
    let tint: Color
    var immersiveDark = false
    let currentTime: Double
    let duration: Double
    var onBack: () -> Void
    var onForward: () -> Void
    var onInteraction: () -> Void = {}
    var onFinish: () -> Void = {}
    @FocusState.Binding var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(immersiveDark
                               ? Color.white.opacity(focused ? 0.34 : 0.18)
                               : TVColor.text.opacity(focused ? 0.30 : 0.16))
                    .frame(height: focused ? 8 : 4)
                Capsule().fill(tint)
                    .frame(width: max(0, geo.size.width * progress), height: focused ? 8 : 4)
                Circle().fill(immersiveDark ? Color.white : TVColor.text)
                    .frame(width: focused ? 24 : 14, height: focused ? 24 : 14)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
                    .offset(x: max(0, geo.size.width * progress) - (focused ? 12 : 7))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 30)
        .padding(.vertical, 12).padding(.horizontal, 16)
        .contentShape(Rectangle())
        .focusable(true)
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            onInteraction()
            switch direction {
            case .left: onBack()
            case .right: onForward()
            default: break
            }
        }
        .onTapGesture(perform: onFinish)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PMString("playback")))
        .accessibilityIdentifier("tv.playback.scrubber")
        .accessibilityValue(Text("\(TVFmt.time(currentTime)) / \(TVFmt.time(duration))"))
        .accessibilityAdjustableAction { direction in
            onInteraction()
            switch direction {
            case .increment: onForward()
            case .decrement: onBack()
            @unknown default: break
            }
        }
        .onChange(of: focused) { _, value in
            if value { onInteraction() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
}

// MARK: - 圆形传输按钮

struct TVRoundBtn: View {
    let icon: String
    var size: CGFloat = 68
    var primary: Bool = false
    var active: Bool = false   // 开启态(随机/循环)——图标染品牌色
    var immersiveDark: Bool = false
    var accessibilityLabel: String?
    var onInteraction: () -> Void = {}
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: size / 2,
                      accent: immersiveDark ? Color.white : TVColor.focusRing,
                      scale: 1.14,
                      lift: 8,
                      action: {
                          onInteraction()
                          action()
                      },
                      onFocusChanged: { focused in
                          if focused { onInteraction() }
                      }) { _ in
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(primary
                                 ? (immersiveDark ? Color(hex: "#1f1c19") : TVColor.onBrand)
                                 : (active ? TVColor.brand : (immersiveDark ? Color.white : TVColor.text)))
                .frame(width: size, height: size)
                .background(primary
                            ? AnyShapeStyle(immersiveDark ? Color.white : TVColor.brand)
                            : AnyShapeStyle(immersiveDark ? Color.white.opacity(0.14) : TVColor.surfaceStrong),
                            in: Circle())
        }
        .accessibilityLabel(Text(accessibilityLabel ?? Self.defaultAccessibilityLabel(for: icon)))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private static func defaultAccessibilityLabel(for icon: String) -> String {
        switch icon {
        case "shuffle": return PMString("shuffle")
        case "repeat", "repeat.1": return PMString("repeat")
        case "list.bullet": return PMString("queue_title")
        case "ellipsis": return PMString("more")
        case "sparkles.tv": return PMString("ext.tv.settings.immersive")
        case "play.rectangle", "play.rectangle.fill": return PMString("playback")
        default: return icon
        }
    }
}
/// 播放页左列的封面按钮与长按菜单。
///
/// 播放页主体读着进度和歌词,每秒要重算好几次;长按菜单挂在主体里时,菜单内容也跟着
/// 每拍重建,系统菜单打开期间就一直闪。这里只比较封面展示需要的值,菜单读的几样状态
/// (喜欢、接下来、随机、睡眠定时)由本视图自己观察,变了才重建。
///
/// 菜单只放五行:喜欢、前往(子菜单)、随机、睡眠定时(子菜单)、更多。原来把「前往」
/// 的四个去处和两个分段标题平铺出来,十行超出封面旁的可用高度,系统菜单只能滚动显示。
private struct TVNowPlayingArtworkButton: View, @MainActor Equatable {
    @Environment(TVStore.self) private var store
    let np: TVNowPlaying
    let isPlaying: Bool
    let isAnimationVisible: Bool
    let isFocused: Bool
    let onOpenShelf: (TVPlayerShelfTab) -> Void
    let onShowMore: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.np.songID == rhs.np.songID && lhs.np.albumID == rhs.np.albumID
            && lhs.np.artist == rhs.np.artist && lhs.np.album == rhs.np.album
            && lhs.np.coverRef == rhs.np.coverRef && lhs.np.glyph == rhs.np.glyph
            && lhs.np.tint == rhs.np.tint && lhs.np.tint2 == rhs.np.tint2
            && lhs.isPlaying == rhs.isPlaying && lhs.isAnimationVisible == rhs.isAnimationVisible
            && lhs.isFocused == rhs.isFocused
    }

    var body: some View {
        Button {
            onOpenShelf(.thisAlbum)
        } label: {
            TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                          songID: np.songID, coverRef: np.coverRef,
                          tint: np.tint, tint2: np.tint2, glyph: np.glyph,
                          size: 420, radius: 20,
                          presentationRole: .animatedHero,
                          animationRequiresPlayback: true,
                          isPlaying: isPlaying,
                          isAnimationVisible: isAnimationVisible)
                .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
                .tvFocusRing(isFocused, radius: 20,
                             accent: TVColor.focusRing, scale: 1.025, lift: 0)
                .overlay(alignment: .bottomLeading) {
                    if isFocused {
                        Text(PMString("ext.tv.nowPlaying.artworkHint"))
                            .tvFont(.caption, weight: .medium)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                            .padding(14)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(TVBareButtonStyle())
        .contextMenu { menu }
    }

    /// 「前往」与货架、「更多」同一套名字和图标;其余(匹配信息、卡拉OK、串烧)在「更多」里。
    @ViewBuilder
    private var menu: some View {
        if let songID = store.currentSongID {
            let liked = store.isLiked(songID)
            Button(
                PMString(liked ? "ext.tv.options.loved" : "ext.tv.options.love"),
                systemImage: liked ? "heart.fill" : "heart"
            ) {
                store.toggleLiked(songID)
            }
        }
        Menu {
            ForEach(TVPlayerShelfTab.goToDestinations.filter { $0 != .upNext || !store.queueUpNextIDs.isEmpty }) { tab in
                Button(tab.title, systemImage: tab.systemImage) { onOpenShelf(tab) }
            }
        } label: {
            Label(PMString("ext.tv.options.section.goTo"), systemImage: "arrow.forward.circle")
        }
        Toggle(isOn: Binding(get: { store.shuffleEnabled }, set: { _ in store.toggleShuffle() })) {
            Label(PMString("shuffle"), systemImage: "shuffle")
        }
        Menu {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Toggle(isOn: Binding(
                    get: { store.sleepTimerMinutes == minutes },
                    set: { _ in store.setSleepTimer(minutes: minutes) }
                )) {
                    Text(verbatim: "\(minutes) " + String(localized: "minutes"))
                }
            }
            if store.sleepTimerMinutes > 0 {
                Button(String(localized: "cancel_timer"), systemImage: "moon.zzz") {
                    store.cancelSleepTimer()
                }
            }
        } label: {
            Label(
                store.sleepTimerMinutes > 0
                    ? PMString("ext.tv.options.sleepActive", store.sleepTimerMinutes)
                    : PMString("ext.tv.options.sleepTimer"),
                systemImage: store.sleepTimerMinutes > 0 ? "moon.zzz.fill" : "moon.zzz"
            )
        }
        Button(PMString("more"), systemImage: "ellipsis.circle", action: onShowMore)
    }
}

/// 播放页「最近一次遥控操作」的时刻。普通引用类型、不参与观察:写它不会让视图重算。
final class TVInteractionClock {
    private var lastInteraction = ProcessInfo.processInfo.systemUptime

    func touch() { lastInteraction = ProcessInfo.processInfo.systemUptime }

    var secondsSinceLastInteraction: TimeInterval {
        ProcessInfo.processInfo.systemUptime - lastInteraction
    }
}
/// 播放页按歌手名打开的那几位艺人。
struct TVArtistLinkPresentation: Identifiable {
    let id = UUID()
    let artists: [TVArtist]
}

/// 一位就直接是艺人页;几位(合唱、feat.)先列出来选一位。
struct TVArtistLinkView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let artists: [TVArtist]
    @State private var chosen: TVArtist?

    var body: some View {
        if let artist = chosen ?? (artists.count == 1 ? artists.first : nil) {
            TVArtistDetailView(artist: artist)
        } else {
            ZStack {
                TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
                TVColor.bg.opacity(0.5).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 26) {
                    Text(String(localized: "tab_artists"))
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                    HStack(spacing: 36) {
                        ForEach(artists) { artist in
                            TVArtistCard(artist: artist, size: 200, action: { chosen = artist })
                                .frame(width: 240)
                        }
                    }
                    .focusSection()
                }
                .padding(.horizontal, 60).padding(.vertical, 46)
                .tvPanel(radius: 26)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .onExitCommand { dismiss() }
        }
    }
}
#endif
