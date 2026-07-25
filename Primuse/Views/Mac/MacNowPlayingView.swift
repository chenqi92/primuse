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
    var onScrapeCurrentSong: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ThemeService.self) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var lastManualLyricsScroll = Date.distantPast
    @State private var lyricsAutoFollowTask: Task<Void, Never>?
    @State private var hostWindow: NSWindow?
    /// 当前主窗口是否处于 macOS 全屏。全屏时使用设计稿 SYS-05 的
    /// NP-FullScreen 双栏布局: 隐藏侧栏后放大封面、歌词和浮动控制。
    @State private var isWindowFullScreen = false

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
            backdrop

            if player.currentSong == nil {
                emptyNowPlaying
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 48)
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
                floatingControls
                if isWindowFullScreen {
                    fullscreenVolumeControl
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(isWindowFullScreen ? 24 : 16)
        }
        .overlay(alignment: .topLeading) {
            if isWindowFullScreen {
                exitFullScreenPill
                    .padding(.top, 18)
                    .padding(.leading, 22)
            }
        }
        .background {
            NowPlayingWindowResolver { window in
                hostWindow = window
                // 初始同步: 视图可能在主窗口已经全屏之后才被创建,此时早已发出的
                // didEnterFullScreen 通知收不到,只能直接读窗口的 styleMask 兜底,
                // 否则全屏下会错渲染成窗口版布局。
                if let window {
                    isWindowFullScreen = window.styleMask.contains(.fullScreen)
                }
            }
        }
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .background {
            MacNowPlayingTimeObserver { updateIndex(time: $0) }
        }
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange)) { note in
            guard let songID = note.object as? String,
                  songID == player.currentSong?.id else { return }
            Task { await reloadLyrics() }
        }
        // 监听主窗口进入/退出全屏(macOS NSWindow 通知),切换布局。
        // 校验通知来源窗口是本视图所在的 hostWindow,避免多开主窗口或设置等
        // 其他窗口的全屏事件误触发本窗口的布局切换。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            isWindowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === hostWindow else { return }
            isWindowFullScreen = false
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

    /// 1.6 重设计后的 ambient backdrop — 由 ThemeService 的动态 accent (从封面提取)
    /// 驱动多色斑模糊, 替代之前的 cover blur + ultraThinMaterial 组合, 让背景跟着
    /// 当前歌曲色调走, 跟设计稿 AmbientBackdrop 视觉一致。
    ///
    /// 关键: 两种外观都先铺不透明底，避免 overlay 穿透到后面的详情页。深色延续
    /// 高对比的 ambient backdrop；浅色用低饱和封面色斑叠在系统浅色背景上，而不是
    /// 强制显示深色播放器。
    private var backdrop: some View {
        ZStack {
            if usesLightPlayerAppearance {
                PMColor.bg
                RadialGradient(
                    colors: [theme.accentColor.opacity(0.28), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 720
                )
                RadialGradient(
                    colors: [theme.darkAccent.opacity(0.14), .clear],
                    center: .bottomTrailing,
                    startRadius: 40,
                    endRadius: 760
                )
                LinearGradient(
                    colors: [.white.opacity(0.52), .white.opacity(0.28)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                PMColor.ambientDarkBase
                AmbientBackdrop(
                    accent: theme.accentColor,
                    darkAccent: theme.darkAccent,
                    strength: 0.85,
                    forceDark: true
                )
            }
        }
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
                    colors: [theme.accentColor.opacity(0.36), .clear],
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
                        fileFormat: song.fileFormat
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(width: coverSize, height: coverSize)
                } else {
                    RoundedRectangle(cornerRadius: coverRadius)
                        .fill(.quaternary)
                        .frame(width: coverSize, height: coverSize)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: coverSize, height: mediaHeight)
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
                Text(artistAlbumLine)
                    .font(.system(size: isWindowFullScreen ? 20 : 16))
                    .foregroundStyle(playerSecondaryColor)
                    .lineLimit(1)
                    .padding(.top, 6)
                if let sourceLabel, !sourceLabel.isEmpty {
                    Text(sourceLabel)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(playerFaintColor)
                        .lineLimit(1)
                        .padding(.top, 6)
                }
            }
            .frame(width: coverSize, alignment: frameAlignment)

            artworkScrubberRow(width: coverSize)

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
                                .onTapGesture { player.seek(to: line.timestamp) }
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
                await Task.yield()
                guard !Task.isCancelled else { return }
                updateIndex(time: player.currentTime)
                scrollLyrics(to: currentIndex, proxy: proxy, animated: false)
            }
            .onDisappear {
                lyricsAutoFollowTask?.cancel()
            }
        }
    }

    private var lyricsScrollIdentity: String {
        "\(player.currentSong?.id ?? "")|\(lyrics.first?.id ?? "")|\(lyrics.count)"
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
        let opacity = lyricOpacity(isActive: isActive, distance: distance)
        let visualScale = lyricVisualScale(isActive: isActive)

        Group {
            if shouldRenderWordTimeline(line: line, index: index, isActive: isActive) {
                KaraokeLineView(
                    line: line,
                    fontSize: scaledSize,
                    weight: weight,
                    activeColor: playerPrimaryColor,
                    inactiveColor: playerSecondaryColor,
                    timeAt: { date in player.interpolatedTime(at: date) }
                )
                .shadow(color: isActive ? tint.opacity(0.32) : .clear, radius: 14)
            } else {
                Text(line.text)
                    .font(.system(size: scaledSize, weight: weight))
                    .foregroundStyle(playerPrimaryColor)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(opacity)
        .frame(minHeight: scaledSize * 1.3, alignment: .leading)
        .scaleEffect(visualScale, anchor: .leading)
        .animation(
            .smooth(duration: Self.lyricsTransitionDuration, extraBounce: 0),
            value: currentIndex
        )
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
        return isActive || abs(index - currentIndex) == 1
    }

    // MARK: - Fullscreen cover transport

    private var nowPlayingInfoLine: String {
        guard let song = player.currentSong else { return "" }
        var parts = [String(localized: "now_playing"), song.fileFormat.displayName]
        if let bitRate = song.bitRate, bitRate > 0 {
            let kbps = bitRate > 10_000 ? bitRate / 1_000 : bitRate
            parts.append("\(kbps)kbps")
        }
        if let sampleRate = song.sampleRate, sampleRate > 0 {
            parts.append(formattedSampleRate(sampleRate))
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

    private var artistAlbumLine: String {
        guard let song = player.currentSong else { return "" }
        return [song.artistName, song.albumTitle]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private func artworkScrubberRow(width: CGFloat) -> some View {
        MacNowPlayingProgressRow(width: width, accent: theme.accentColor)
    }

    private func formattedSampleRate(_ sampleRate: Int) -> String {
        let khz = Double(sampleRate) / 1_000
        if khz.rounded() == khz {
            return "\(Int(khz))kHz"
        }
        return String(format: "%.1fkHz", khz)
    }

    // MARK: - Floating controls (top-right of the window)

    private var exitFullScreenPill: some View {
        Button {
            exitFullScreen()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                Text("退出全屏")
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
        .help(Text("退出全屏"))
    }

    private var floatingControls: some View {
        HStack(spacing: 8) {
            // Heart
            Button { toggleLikedCurrent() } label: {
                circleIcon(isCurrentLiked ? "heart.fill" : "heart",
                           tint: isCurrentLiked ? Color.white : nil,
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
                               tint: player.isMusicVideoModeEnabled ? .white : nil,
                               fill: player.isMusicVideoModeEnabled ? theme.accentColor.opacity(0.9) : nil)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help(Text("MV"))
                .disabled(player.isLoading)
            }

            Button {} label: {
                circleIcon("text.bubble.fill",
                           tint: Color.white,
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
                set: { engine.volume = Float($0) }
            ), accessibilityLabel: String(localized: "volume"))
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
        .help(Text("volume"))
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

    private func exitFullScreen() {
        let window = fullScreenWindow()
        guard isWindowFullScreen || window?.styleMask.contains(.fullScreen) == true else { return }
        window?.toggleFullScreen(nil)
    }

    private func fullScreenWindow() -> NSWindow? {
        if let hostWindow, hostWindow.styleMask.contains(.fullScreen) {
            return hostWindow
        }
        if let fullScreen = NSApp.windows.first(where: { $0.styleMask.contains(.fullScreen) }) {
            return fullScreen
        }
        return hostWindow ?? NSApp.mainWindow ?? NSApp.keyWindow
    }

    // MARK: - Lyrics loading

    private func reloadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []; currentIndex = 0; return
        }
        // 先清掉上一首的内容,避免在异步加载途中显示「上首歌的歌词」。
        lyrics = []; currentIndex = 0

        let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        // 异步等待期间用户可能跳到了下一首,这时把当前结果写回去就会
        // 把"上一首的歌词"显示在新歌上。`task(id:)` 理论上会取消旧任务
        // 但 LyricsLoader 内部网络拉取不一定及时响应取消,做一道防御。
        guard player.currentSong?.id == song.id else { return }
        lyrics = loaded
        updateIndex(time: player.currentTime)
    }

    private func updateIndex(time: TimeInterval) {
        guard !lyrics.isEmpty else { return }
        // Use the same timing policy as iOS. A 10 Hz interpolated clock plus a
        // small lookahead starts the smooth transition just before the vocal
        // arrives; observing the coarse published currentTime made takeovers
        // late and visually abrupt.
        let hasWordLevelLyrics = lyrics.contains { $0.isWordLevel }
        let target = time + (hasWordLevelLyrics ? Self.wordLevelLookahead : Self.lineLevelLookahead)
        var low = 0
        var high = lyrics.count
        while low < high {
            let middle = low + (high - low) / 2
            if lyrics[middle].timestamp <= target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = max(0, low - 1)
        if currentIndex != index { currentIndex = index }
    }

    // 删除歌曲流程已移到 PlayerMoreMenu,这里不再保留 deleteCurrentSong。
}

private struct MacNowPlayingTimeObserver: View {
    @Environment(AudioPlayerService.self) private var player
    let onTimeChange: (TimeInterval) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { date in
                onTimeChange(player.interpolatedTime(at: date))
            }
    }
}

/// Owns the 0.5-second progress dependency so the large now-playing layout is
/// not reevaluated for every playback tick.
private struct MacNowPlayingProgressRow: View {
    @Environment(AudioPlayerService.self) private var player
    let width: CGFloat
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(player.currentTime.formattedDuration)
                .frame(width: 38, alignment: .trailing)
            MacNowPlayingScrubber(progress: progress, accent: accent)
            Text(player.duration.formattedDuration)
                .frame(width: 38, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.6))
        .frame(width: width)
    }

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }
}

private struct MacNowPlayingScrubber: View {
    let progress: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(1, max(0, progress))
            let width = max(0, proxy.size.width)
            let fillWidth = width * clamped
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.18))
                    .frame(height: 3)
                Capsule()
                    .fill(accent)
                    .frame(width: max(3, fillWidth), height: 3)
                Circle()
                    .fill(.primary)
                    .frame(width: 8, height: 8)
                    .shadow(color: accent.opacity(0.35), radius: 8)
                    .offset(x: min(max(0, fillWidth - 4), max(0, width - 8)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 8)
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
