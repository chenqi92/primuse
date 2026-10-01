#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// 屏幕顶部的歌词岛 —— 见 `DesktopLyricsIslandController`。
///
/// 视觉上刻意不做成一块纯黑的播放器面板：
/// - 本体是和刘海连成一片的墨黑，封面的颜色只以「光」的形式出现 —— 底边一道
///   跟着进度走的光缝、岛下方一圈晕光、展开后从卡片底部透上来的低亮度光池；
/// - 收起时宽度跟着当前这句歌词呼吸，换句时整块随之伸缩；
/// - 展开后歌词是主角，播放信息收成顶上一行，进度就是底边那道光缝本身。
/// 系统状态（耳机、音量、电源）来时暂时占住这一行，几秒后退回歌词。
struct DesktopLyricsIslandView: View {
    let state: DesktopLyricsIslandState
    var onToggleDesktop: () -> Void = {}
    var onClose: () -> Void = {}
    var onAlwaysOnTopChange: (Bool) -> Void = { _ in }

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ThemeService.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var inheritedLayoutDirection

    @State private var lyricsLoadRevision: UInt = 0
    @State private var pendingLyricsOverride: PendingLyricsOverride?

    /// 与浮动桌面歌词共用颜色设置：用户挑了颜色就用它，否则在墨黑底上用白字。
    @AppStorage("desktopLyricsColor") private var colorHex: String = "#FFFFFF"
    @AppStorage("desktopLyricsUsesArtworkColor") private var usesArtworkColor = true
    @AppStorage(MacLyricsVisibilityPreferences.desktopKey) private var desktopLyricsVisible = false

    private var metrics: DesktopLyricsIslandMetrics { state.metrics }

    var body: some View {
        let size = islandSize
        island(size: size)
            .opacity(state.peeking ? 0.14 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: size, initial: true) { _, newSize in
                state.islandSize = newSize
            }
            .task(id: lyricsLoadTaskIdentity) { await refreshLyrics() }
            .background {
                DesktopLyricsTimeObserver { updateIndex(time: $0) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange)) { note in
                guard let songID = note.object as? String,
                      songID == player.currentSong?.id else { return }
                pendingLyricsOverride = (note.userInfo?["lyrics"] as? [LyricLine]).map {
                    PendingLyricsOverride(songID: songID, lyrics: $0)
                }
                lyricsLoadRevision &+= 1
            }
    }

    // MARK: - Silhouette

    private func island(size: CGSize) -> some View {
        let radius = bottomRadius(for: size)
        return ZStack(alignment: .top) {
            compactLayer
                .opacity(state.presented && !state.expanded ? 1 : 0)
            if state.presented && state.expanded {
                expandedLayer
                    .frame(width: metrics.expandedWidth, height: metrics.expandedHeight, alignment: .top)
                    .transition(expandedTransition)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(IslandSilhouette(bottomRadius: radius, shoulder: 0))
        .background(alignment: .top) {
            IslandSilhouette(bottomRadius: radius, shoulder: shoulder)
                .fill(Color.black)
                .padding(.horizontal, -shoulder)
                .shadow(
                    color: glowColor.opacity(glowOpacity),
                    radius: state.expanded ? 26 : 12,
                    y: state.expanded ? 10 : 4
                )
        }
        .animation(morphAnimation, value: size)
        .animation(morphAnimation, value: radius)
    }

    private var islandSize: CGSize {
        guard state.presented else { return metrics.tuckedSize }
        if state.expanded { return metrics.expandedSize }
        if case .idle = compactLine { return metrics.restingSize }
        return metrics.compactSize(textWidth: compactTextWidth)
    }

    private func bottomRadius(for size: CGSize) -> CGFloat {
        if state.presented && state.expanded { return 26 }
        return metrics.hasNotch ? min(15, size.height * 0.42) : min(size.height / 2, 17)
    }

    private var shoulder: CGFloat {
        state.expanded ? 12 : (metrics.hasNotch ? 7 : 6)
    }

    private var morphAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8)
    }

    private var expandedTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)),
            removal: .opacity
        )
    }

    private var lineTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 9)),
            removal: .opacity.combined(with: .offset(y: -9))
        )
    }

    // MARK: - Light

    /// 封面给的光：自动取色开着时是封面主色，关掉时是主题色。
    private var glowColor: Color { theme.accentColor }

    /// 描在墨黑底上的细线（光缝、声线）要比取色原值亮一些，深色封面才看得见。
    private var lightColors: [Color] {
        [
            theme.accentColor.mix(with: .white, by: 0.28),
            theme.secondaryAccent.mix(with: .white, by: 0.42)
        ]
    }

    private var glowOpacity: Double {
        guard state.presented, hasSomethingPlaying else { return 0 }
        guard player.isPlaying else { return 0.12 }
        return state.expanded ? 0.28 : 0.24
    }

    private var lyricTint: Color {
        usesArtworkColor ? .white : (Color.fromHexString(colorHex) ?? .white)
    }

    private func activityTint(_ tint: DesktopLyricsIslandActivity.Tint) -> Color {
        switch tint {
        case .neutral: return .white
        case .charging: return Color(red: 0.36, green: 0.86, blue: 0.47)
        case .warning: return Color(red: 1.0, green: 0.42, blue: 0.36)
        }
    }

    // MARK: - Compact

    /// 收起时这一行显示什么。
    private enum CompactLine: Equatable {
        case lyric(String)
        case nowPlaying(title: String, artist: String?)
        case activity(DesktopLyricsIslandActivity)
        case idle
    }

    private var hasSomethingPlaying: Bool {
        player.currentSong != nil || player.currentRadioStation != nil
    }

    private var compactLine: CompactLine {
        if let activity = state.activity { return .activity(activity) }
        guard hasSomethingPlaying, let title = displayTitle else { return .idle }
        if !player.isLiveRadio,
           let line = activeLyricLine,
           !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .lyric(line.text)
        }
        // 前奏、间奏、没有歌词、电台：这一行改成歌名和歌手。
        return .nowPlaying(title: title, artist: compactSubtitle)
    }

    /// 换句的过渡按这个键走；连续调音量时键不变，只更新读数。
    private var compactLineKey: String {
        switch compactLine {
        case .lyric: return "lyric-\(state.currentIndex)"
        case .nowPlaying(let title, _): return "playing-\(player.currentSong?.id ?? "")-\(title)"
        case .activity(let activity):
            switch activity.kind {
            case .volume: return "activity-volume"
            case .output, .power: return "activity-\(activity.symbol)-\(activity.title)"
            }
        case .idle: return "idle"
        }
    }

    private var lyricFontSize: CGFloat { metrics.hasNotch ? 14 : 13 }

    /// 电平条在普通屏胶囊里的长度；刘海屏上它铺满垂下来的那一行。
    private static let flatMeterWidth: CGFloat = 112

    /// 这一行文字要多宽。直接用 AppKit 量，不绕 SwiftUI 布局回传 —— 岛的外形
    /// 要先知道目标宽度才能做形变动画，靠布局回传会晚一帧还可能来回震。
    private var compactTextWidth: CGFloat {
        switch compactLine {
        case .lyric(let text):
            return Self.textWidth(text, size: lyricFontSize, weight: .semibold) + 4
        case .nowPlaying(let title, let artist):
            var width = Self.textWidth(title, size: 13, weight: .semibold)
            if let artist {
                width += 8 + Self.textWidth(artist, size: 12, weight: .regular)
            }
            return width + 4
        case .activity(let activity):
            if activity.level != nil {
                guard !metrics.hasNotch else { return 0 }
                let trailing = activity.trailing.map {
                    Self.textWidth($0, size: 11, weight: .semibold) + 4
                } ?? 0
                return Self.flatMeterWidth + max(0, trailing - metrics.glyphWidth)
            }
            return Self.textWidth(activity.caption, size: 11.5, weight: .medium)
                + 7 + Self.textWidth(activity.title, size: 13, weight: .semibold) + 4
        case .idle:
            return 0
        }
    }

    private static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @ViewBuilder
    private var compactLayer: some View {
        if metrics.hasNotch {
            notchedCompact
        } else {
            flatCompact
        }
    }

    /// 刘海屏：顶部那条左封面、右声线，歌词从刘海正下方垂下来一行。
    private var notchedCompact: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leadingGlyph
                    .frame(width: metrics.wingWidth, height: metrics.topBand)
                Spacer(minLength: 0)
                trailingGlyph
                    .frame(width: metrics.wingWidth, height: metrics.topBand)
            }
            .frame(width: metrics.compactMinWidth, height: metrics.topBand)

            compactCenter
                .frame(maxWidth: .infinity)
                .frame(height: metrics.stripHeight)
                .padding(.horizontal, metrics.horizontalPadding)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .bottom) { compactSeam }
    }

    /// 普通屏：一枚挂在屏幕顶边的胶囊，封面、歌词、声线排成一行。
    private var flatCompact: some View {
        HStack(spacing: metrics.innerSpacing) {
            leadingGlyph
                .frame(width: metrics.artworkSide, height: metrics.artworkSide)
            compactCenter
                .frame(maxWidth: .infinity)
            trailingGlyph
                .frame(minWidth: metrics.glyphWidth)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: metrics.compactHeight)
        .overlay(alignment: .bottom) { compactSeam }
    }

    /// 左翼：封面；系统状态来时换成它的图标。两个分支叠在同一个 ZStack 里交替，
    /// 过渡期间不会在外层 HStack 里占出两个位置。
    private var leadingGlyph: some View {
        ZStack {
            if let activity = state.activity {
                Image(systemName: activity.symbol)
                    .font(.system(size: metrics.artworkSide * 0.72, weight: .semibold))
                    .foregroundStyle(activityTint(activity.tint))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: metrics.artworkSide, height: metrics.artworkSide)
                    .transition(.opacity)
            } else if hasSomethingPlaying {
                artwork(side: metrics.artworkSide, cornerRadius: metrics.artworkSide * 0.28)
                    .transition(.opacity)
            } else {
                Image("BrandGlyph")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: metrics.artworkSide * 0.8, height: metrics.artworkSide * 0.8)
                    .transition(.opacity)
            }
        }
    }

    /// 右翼：声线；系统状态来时换成读数（音量百分比），没有读数就亮一颗同色小点。
    private var trailingGlyph: some View {
        ZStack {
            if let activity = state.activity {
                if let trailing = activity.trailing {
                    Text(verbatim: trailing)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                } else {
                    Circle()
                        .fill(activityTint(activity.tint))
                        .frame(width: 6, height: 6)
                        .transition(.opacity)
                }
            } else {
                IslandVoiceLine(
                    isPlaying: player.isPlaying && hasSomethingPlaying,
                    colors: lightColors
                )
                .frame(width: metrics.glyphWidth, height: 12)
                .transition(.opacity)
            }
        }
    }

    private var compactCenter: some View {
        ZStack {
            compactLineView
                .id(compactLineKey)
                .transition(lineTransition)
        }
        .animation(.easeOut(duration: 0.28), value: compactLineKey)
    }

    @ViewBuilder
    private var compactLineView: some View {
        switch compactLine {
        case .lyric(let text):
            Text(text)
                .font(.system(size: lyricFontSize, weight: .semibold))
                .foregroundStyle(lyricTint)
                .lineLimit(1)
                .truncationMode(.tail)
                .environment(\.layoutDirection, lyricLayoutDirection)
        case .nowPlaying(let title, let artist):
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                if let artist {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        case .activity(let activity):
            if let level = activity.level {
                IslandLevelMeter(level: level, tint: activityTint(activity.tint))
                    .frame(width: metrics.hasNotch ? nil : Self.flatMeterWidth, height: 5)
                    .frame(maxWidth: metrics.hasNotch ? .infinity : nil)
                    .accessibilityLabel(Text(verbatim: activity.caption))
                    .accessibilityValue(Text(verbatim: activity.trailing ?? ""))
            } else {
                HStack(spacing: 7) {
                    Text(verbatim: activity.caption)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(verbatim: activity.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(activityTint(activity.tint))
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
        case .idle:
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// 收起时底边那道光缝就是播放进度。电台和系统状态占住这一行时不画。
    @ViewBuilder
    private var compactSeam: some View {
        if state.activity == nil, player.currentSong != nil, !player.isLiveRadio {
            IslandProgressSeam(colors: lightColors, thickness: 2)
                .frame(height: 2)
                .padding(.horizontal, metrics.hasNotch ? 16 : 14)
                .padding(.bottom, 3)
                .opacity(player.isPlaying ? 1 : 0.45)
        }
    }

    // MARK: - Expanded

    private var expandedLayer: some View {
        ZStack(alignment: .top) {
            lightPool
            VStack(spacing: 0) {
                Color.clear.frame(height: metrics.expandedContentTop)
                header
                    .frame(height: 44)
                    .padding(.horizontal, 18)
                lyricsBlock
                    .frame(height: 64)
                    .padding(.horizontal, 24)
                footer
                    .frame(height: 34)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            }
        }
    }

    /// 用主题色铺低亮度的光池，避免浅色封面把岛面洗白。
    private var lightPool: some View {
        ZStack(alignment: .bottom) {
            RadialGradient(
                colors: [glowColor.opacity(0.18), .clear],
                center: UnitPoint(x: 0.35, y: 1),
                startRadius: 0,
                endRadius: metrics.expandedWidth * 0.65
            )
            RadialGradient(
                colors: [theme.secondaryAccent.opacity(0.1), .clear],
                center: UnitPoint(x: 0.7, y: 1),
                startRadius: 0,
                endRadius: metrics.expandedWidth * 0.45
            )
        }
        .frame(width: metrics.expandedWidth, height: metrics.expandedHeight, alignment: .bottom)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.28),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(player.isPlaying ? 1 : 0.6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 11) {
            artwork(side: 38, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle ?? String(localized: "desktop_lyrics_no_song"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.52))
                }
            }
            .lineLimit(1)
            .contentTransition(.opacity)
            .pmAnimation(.trackChange, value: player.currentSong?.id)
            Spacer(minLength: 8)
            transport
        }
    }

    private var transport: some View {
        HStack(spacing: 6) {
            if player.currentItemIsSpokenWord, !player.isLiveRadio {
                islandButton(player.spokenWordSkipBackwardSymbol, size: 14, help: "a11y_skip_backward") {
                    player.skipSpokenWordBackward()
                }
            } else if !player.isLiveRadio || player.canSwitchRadioStation {
                islandButton("backward.fill", size: 14,
                             help: player.isLiveRadio ? "radio_previous_station" : "previous_song") {
                    Task { await player.previous() }
                }
            }

            Button {
                guard !(player.isLoading && !player.isLiveRadio) else { return }
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 32, height: 32)
                    if player.showsLoadingIndicator && !player.isLiveRadio {
                        ProgressView().controlSize(.small).tint(.black)
                            .pmFadeTransition(motion: .control)
                    } else {
                        Image(systemName: playSymbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .contentTransition(.symbolEffect(.replace))
                            .offset(x: playSymbol == "play.fill" ? 1 : 0)
                            .pmFadeTransition(motion: .control)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(IslandControlButtonStyle(prominent: true))
            .pmPointingHand()
            .disabled(player.showsLoadingIndicator && !player.isLiveRadio)
            .help(Text(playHelpKey))
            .accessibilityLabel(Text(playHelpKey))

            if player.currentItemIsSpokenWord, !player.isLiveRadio {
                islandButton(player.spokenWordSkipForwardSymbol, size: 14, help: "a11y_skip_forward") {
                    player.skipSpokenWordForward()
                }
            } else if !player.isLiveRadio || player.canSwitchRadioStation {
                islandButton("forward.fill", size: 14,
                             help: player.isLiveRadio ? "radio_next_station" : "next_song") {
                    Task { await player.next() }
                }
            }
        }
    }

    private var playSymbol: String {
        if player.isLiveRadio && (player.isPlaying || player.isLoading) { return "stop.fill" }
        return player.isPlaying || player.isLoading ? "pause.fill" : "play.fill"
    }

    private var playHelpKey: LocalizedStringKey {
        if player.isLiveRadio && (player.isPlaying || player.isLoading) { return "radio_stop" }
        return player.isPlaying || player.isLoading ? "pause" : "play"
    }

    private var lyricsBlock: some View {
        VStack(spacing: 6) {
            ZStack {
                expandedCurrentLine
                    .id(state.currentIndex)
                    .transition(lineTransition)
            }
            .frame(maxWidth: .infinity)
            if !player.isLiveRadio, let next = nextLyricLine,
               !next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(next.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .environment(\.layoutDirection, lyricLayoutDirection)
                    .id(state.currentIndex + 1)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.3), value: state.currentIndex)
    }

    @ViewBuilder
    private var expandedCurrentLine: some View {
        if !player.isLiveRadio,
           let line = activeLyricLine,
           !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if line.isWordLevel {
                KaraokeLineView(
                    line: line,
                    fontSize: 17,
                    weight: .semibold,
                    activeColor: lyricTint,
                    inactiveColor: .white.opacity(0.3),
                    textAlignment: .center,
                    writingDirection: lyricsWritingDirection,
                    timeAt: { date in player.interpolatedTime(at: date) },
                    isPlaybackActive: player.isPlaying,
                    deactivationTime: line.voice == .secondary ? line.endTime : nil
                )
                .lineLimit(2)
            } else {
                Text(line.text)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(lyricTint)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .environment(\.layoutDirection, lyricLayoutDirection)
            }
        } else if player.isLiveRadio {
            Text(player.currentRadioStation?.name ?? "")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        } else if hasSomethingPlaying, state.lyrics.isEmpty {
            Text("no_lyrics")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        } else {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying && !reduceMotion)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if player.isLiveRadio {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("live_badge")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            } else if player.currentSong != nil {
                IslandScrubber(colors: lightColors)
            } else {
                Spacer(minLength: 0)
            }
            islandButton(
                state.alwaysOnTop ? "pin.fill" : "pin",
                size: 11,
                help: "lyrics_island_always_on_top",
                selected: state.alwaysOnTop
            ) {
                onAlwaysOnTopChange(!state.alwaysOnTop)
            }
            .accessibilityIdentifier("lyricsIsland.alwaysOnTop")
            .accessibilityValue(Text(
                state.alwaysOnTop
                    ? "desktop_widget_sync_status_enabled"
                    : "desktop_widget_sync_status_disabled"
            ))
            islandButton(
                desktopLyricsVisible ? "text.bubble.fill" : "text.bubble",
                size: 12,
                help: desktopLyricsVisible ? "hide_desktop_lyrics" : "show_desktop_lyrics",
                selected: desktopLyricsVisible
            ) {
                onToggleDesktop()
            }
            .accessibilityIdentifier("lyricsIsland.desktopLyrics")
            .accessibilityValue(Text(
                desktopLyricsVisible
                    ? "desktop_widget_sync_status_enabled"
                    : "desktop_widget_sync_status_disabled"
            ))
            islandButton("xmark", size: 11, help: "hide_lyrics_island") {
                onClose()
            }
        }
    }

    private func islandButton(
        _ symbol: String,
        size: CGFloat,
        help: LocalizedStringKey,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(selected ? theme.accentColor.mix(with: .white, by: 0.45) : .white)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandControlButtonStyle())
        .pmPointingHand()
        .help(Text(help))
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func artwork(side: CGFloat, cornerRadius: CGFloat) -> some View {
        if player.isLiveRadio, let station = player.currentRadioStation {
            RadioStationArtworkView(station: station, size: side, cornerRadius: cornerRadius)
        } else if let song = player.currentSong {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: side,
                cornerRadius: cornerRadius,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                revisionToken: player.coverRevision
            )
            .artworkCrossfade()
        } else {
            CoverArtView(data: nil, size: side, cornerRadius: cornerRadius)
        }
    }

    // MARK: - Now playing text

    private var displayTitle: String? {
        if let title = player.currentSong?.title, !title.isEmpty { return title }
        return player.currentRadioStation?.name
    }

    private var compactSubtitle: String? {
        if player.isLiveRadio {
            let name = player.currentRadioStation?.name
            return name == displayTitle ? nil : name
        }
        guard let song = player.currentSong,
              let artist = library.artistDisplayName(for: song),
              !artist.isEmpty else { return nil }
        return artist
    }

    private var headerSubtitle: String? {
        if player.isLiveRadio { return compactSubtitle }
        let parts = [compactSubtitle, player.currentSong?.albumTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Lyrics state

    private var lyricsWritingDirection: LyricWritingDirection {
        LyricWritingDirectionPolicy.resolve(in: state.lyrics)
    }

    private var lyricLayoutDirection: LayoutDirection {
        switch lyricsWritingDirection {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

    private var activeLyricLine: LyricLine? {
        guard state.lyrics.indices.contains(state.currentIndex) else { return nil }
        return state.lyrics[state.currentIndex]
    }

    private var nextLyricLine: LyricLine? {
        let next = state.currentIndex + 1
        guard !state.lyrics.isEmpty, next < state.lyrics.count else { return nil }
        return state.lyrics[next]
    }

    private struct LyricsLoadTaskIdentity: Hashable {
        let songID: String?
        let isLiveRadio: Bool
        let revision: UInt
    }

    private struct PendingLyricsOverride {
        let songID: String
        let lyrics: [LyricLine]
    }

    private var lyricsLoadTaskIdentity: LyricsLoadTaskIdentity {
        LyricsLoadTaskIdentity(
            songID: player.currentSong?.id,
            isLiveRadio: player.isLiveRadio,
            revision: lyricsLoadRevision
        )
    }

    private func refreshLyrics() async {
        if let pendingLyricsOverride,
           pendingLyricsOverride.songID == player.currentSong?.id {
            self.pendingLyricsOverride = nil
            state.lyrics = pendingLyricsOverride.lyrics
            state.lyricsSongID = pendingLyricsOverride.songID
            updateIndex(time: player.currentTime)
            return
        }
        pendingLyricsOverride = nil
        // 面板重建（再次上岛）时同一首歌的歌词已经在状态里，不必清空重读 ——
        // 否则会先闪一下歌名再换回歌词。歌词被改过会带着新的修订号进来，照常重读。
        if lyricsLoadRevision == 0,
           let songID = player.currentSong?.id,
           state.lyricsSongID == songID,
           !player.isLiveRadio {
            updateIndex(time: player.currentTime)
            return
        }
        await reloadLyrics()
    }

    private func reloadLyrics() async {
        // 直播电台没有歌词可跟。
        guard let song = player.currentSong, !player.isLiveRadio else {
            state.lyrics = []
            state.lyricsSongID = nil
            state.currentIndex = -1
            return
        }
        state.lyrics = []
        state.lyricsSongID = nil
        state.currentIndex = -1
        let loaded = await LyricsLoader.load(
            for: song,
            sourceManager: sourceManager,
            sourceType: sourcesStore.source(id: song.sourceID)?.type
        )
        guard !Task.isCancelled, player.currentSong?.id == song.id else { return }
        state.lyrics = loaded
        state.lyricsSongID = song.id
        updateIndex(time: player.currentTime)
    }

    private func updateIndex(time: TimeInterval) {
        let index = LyricPlaybackPositionPolicy.activeLineIndex(in: state.lyrics, at: time) ?? -1
        if state.currentIndex != index { state.currentIndex = index }
    }
}

// MARK: - Pieces

private struct IslandControlButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        IslandControlLabel(configuration: configuration, prominent: prominent)
    }
}

private struct IslandControlLabel: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pointerOffset = CGSize.zero

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [.white.opacity(prominent ? 0.1 : 0.14), .clear],
                center: .center,
                startRadius: 0,
                endRadius: side * 0.8
            )
            .frame(width: side * 1.6, height: side * 1.6)
            .scaleEffect(reduceMotion ? 1 : (isHighlighted ? 1 : 0.7))
            .opacity(isHighlighted ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            configuration.label
                .opacity(isEnabled ? (prominent || hovering ? 1 : 0.88) : 0.45)
                .scaleEffect(controlScale)
                .offset(controlOffset)
                .shadow(color: .white.opacity(isHighlighted ? 0.16 : 0), radius: prominent ? 8 : 4)
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard isEnabled else { return }
                hovering = true
                guard !reduceMotion else { return }
                let travel: CGFloat = prominent ? 1.5 : 2
                pointerOffset = CGSize(
                    width: max(-1, min(1, (location.x - side / 2) / (side / 2))) * travel,
                    height: max(-1, min(1, (location.y - side / 2) / (side / 2))) * travel
                )
            case .ended:
                hovering = false
                pointerOffset = .zero
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                hovering = false
                pointerOffset = .zero
            }
        }
        .animation(hoverAnimation, value: hovering)
        .animation(hoverAnimation, value: pointerOffset)
        .animation(pressAnimation, value: configuration.isPressed)
    }

    private var isHighlighted: Bool { isEnabled && (hovering || configuration.isPressed) }
    private var side: CGFloat { prominent ? 32 : 28 }

    private var controlScale: CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        if configuration.isPressed { return prominent ? 0.94 : 0.9 }
        return hovering ? (prominent ? 1.035 : 1.1) : 1
    }

    private var controlOffset: CGSize {
        guard isEnabled, hovering, !reduceMotion, !configuration.isPressed else { return .zero }
        return CGSize(width: pointerOffset.width, height: pointerOffset.height - 0.7)
    }

    private var hoverAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.3, dampingFraction: 0.72)
    }

    private var pressAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.68)
    }
}

/// 岛的外形：底边两角圆，顶边两肩向外翻出去贴住屏幕上沿 —— 和刘海本身的
/// 收边方式一样，看上去是刘海长大了，而不是一块贴在屏幕顶上的卡片。
struct IslandSilhouette: Shape {
    var bottomRadius: CGFloat
    var shoulder: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, shoulder) }
        set {
            bottomRadius = newValue.first
            shoulder = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height))
        let bodyWidth = rect.width - s * 2
        let r = max(0, min(bottomRadius, bodyWidth / 2, rect.height - s))
        let left = rect.minX + s
        let right = rect.maxX - s
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + s),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        path.addArc(
            tangent1End: CGPoint(x: left, y: rect.maxY),
            tangent2End: CGPoint(x: left + r, y: rect.maxY),
            radius: r
        )
        path.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: right, y: rect.maxY),
            tangent2End: CGPoint(x: right, y: rect.maxY - r),
            radius: r
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + s))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// 右翼那道「声线」：播放时几条正弦叠出一段起伏，暂停时拉成一条直线。
/// 不是频谱 —— 那要在音频输出上常驻一个 tap，岛是常驻的，不值得。
private struct IslandVoiceLine: View {
    let isPlaying: Bool
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isPlaying || reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { canvas, size in
                canvas.stroke(
                    Self.wave(in: size, phase: phase, amplitude: isPlaying ? 1 : 0),
                    with: .linearGradient(
                        Gradient(colors: colors),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    ),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .opacity(isPlaying ? 1 : 0.5)
        .accessibilityHidden(true)
    }

    private static func wave(in size: CGSize, phase: Double, amplitude: Double) -> Path {
        var path = Path()
        let steps = 28
        let midY = Double(size.height) / 2
        let height = Double(size.height) * 0.42 * amplitude
        for step in 0...steps {
            let x = Double(step) / Double(steps)
            // 两端收成零，看上去是一段从中间鼓起来的声线，而不是被裁断的波形。
            let envelope = sin(Double.pi * x)
            let primary = sin(x * 5.4 * Double.pi + phase * 5.2) * 0.62
            let secondary = sin(x * 9.8 * Double.pi - phase * 3.3) * 0.38
            let y = midY + (primary + secondary) * height * envelope
            let point = CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y))
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// 底边的光缝：一条暗轨，亮的那段是已播放的部分，头上带一颗晕开的光点。
/// 自己读播放时间，时间每跳一次只重画这一小块。
private struct IslandProgressSeam: View {
    @Environment(AudioPlayerService.self) private var player
    let colors: [Color]
    var thickness: CGFloat = 2
    /// 拖动中由外面给出的位置；nil 时跟播放时间走。
    var overrideFraction: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let head = width * CGFloat(fraction)
            let glow = thickness * 3.2
            // 亮段和光点都挂在暗轨的 overlay 上：它们不参与尺寸计算，光点再大也
            // 撑不高这条缝。
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: width, height: thickness)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(thickness, head), height: thickness)
                }
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(colors.last ?? .white)
                        .frame(width: glow, height: glow)
                        .blur(radius: thickness * 0.9)
                        .offset(x: head - glow / 2)
                }
                .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private var fraction: Double {
        if let overrideFraction { return min(max(overrideFraction, 0), 1) }
        guard player.duration.isFinite, player.duration > 0 else { return 0 }
        return min(max(player.currentTime / player.duration, 0), 1)
    }
}

/// 展开后的进度：两端时间 + 可以按住拖动的光缝。拖动只在松手时 seek 一次。
private struct IslandScrubber: View {
    @Environment(AudioPlayerService.self) private var player
    let colors: [Color]
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.format(displayedTime))
                .frame(minWidth: 32, alignment: .trailing)
            GeometryReader { proxy in
                IslandProgressSeam(
                    colors: colors,
                    thickness: hovering || dragFraction != nil ? 4 : 2.5,
                    overrideFraction: dragFraction
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard proxy.size.width > 0 else { return }
                            dragFraction = min(max(Double(value.location.x / proxy.size.width), 0), 1)
                        }
                        .onEnded { _ in
                            if let dragFraction, player.duration > 0 {
                                player.seek(to: dragFraction * player.duration)
                            }
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering = $0 }
            .pmAnimation(.hover, value: hovering)
            Text(Self.format(player.duration))
                .frame(minWidth: 32, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.45))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("desktop_lyrics_island_progress"))
        .accessibilityValue(Text(verbatim: "\(Self.format(player.currentTime)) / \(Self.format(player.duration))"))
    }

    private var displayedTime: TimeInterval {
        if let dragFraction, player.duration > 0 { return dragFraction * player.duration }
        return player.currentTime
    }

    private static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = time.finiteInt()
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 音量电平：暗轨上一段白光，读数变化时顺滑地伸缩。
private struct IslandLevelMeter: View {
    let level: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.height, proxy.size.width * CGFloat(min(max(level, 0), 1))))
                    .opacity(level <= 0.001 ? 0 : 1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}
#endif
