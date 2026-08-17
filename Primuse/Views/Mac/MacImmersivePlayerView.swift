#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS 沉浸播放：鼠标静置 3 秒淡出，0 返回原生、1–5 切换 A–E，
/// 方向键定位，Option+方向键切歌，Esc 直接退出窗口全屏。
struct MacImmersivePlayerView: View {
    /// 已经由常规播放页加载好的带时间戳歌词，沉浸态继续沿用同一份数据。
    let lyrics: [LyricLine]
    /// 退出 macOS 全屏
    var onExitFullScreen: () -> Void
    var onToggleQueue: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
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

    @State private var showsChrome = true
    @State private var isStageReady = false
    @State private var chromeTask: Task<Void, Never>?
    @State private var hasResolvedArtwork = true
    @State private var gallerySongs: [Song] = []
    @State private var titleWallTitles: [String] = []
    @State private var showsEffectPicker = false
    @State private var activeLyricIndex: Int?
    @State private var lyricInterlude = false
    @FocusState private var acceptsKeyInput: Bool

    private var effect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: effectRawValue) ?? .defaultValue
    }

    private var presentationEffect: FullscreenPlayerEffect {
        let raw = ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: effect.rawValue,
            hasSynchronizedLyrics: hasSynchronizedLyrics,
            hasArtwork: hasResolvedArtwork
        )
        return FullscreenPlayerEffect(rawValue: raw) ?? .coverFlow
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
                if isStageReady {
                    stage(metrics: metrics)
                } else {
                    entrySurface(metrics: metrics)
                }

                if showsEffectPicker {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.16)) {
                                showsEffectPicker = false
                            }
                        }
                        .accessibilityHidden(true)
                }

                if showsChrome {
                    chrome(metrics: metrics)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showsChrome)
            .contentShape(Rectangle())
            .onTapGesture { revealChrome() }
            .onContinuousHover { phase in
                if case .active = phase { revealChrome() }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, presentationEffect.prefersLightContent ? .light : .dark)
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
        .focusable()
        .focused($acceptsKeyInput)
        .onKeyPress(phases: [.down, .repeat]) { press in
            handleKeyPress(press)
        }
        .onExitCommand {
            if showsEffectPicker {
                withAnimation(.easeOut(duration: 0.16)) {
                    showsEffectPicker = false
                }
            } else {
                onExitFullScreen()
            }
        }
        .onAppear {
            acceptsKeyInput = true
            FullscreenPlayerEffectSync.shared.install()
            refreshArtworkInputs()
        }
        .task { @MainActor in
            // 先让系统全屏切换完成首轮布局，再挂载包含大图、Canvas 和模糊的
            // 沉浸场景；避免同一帧里同时争用主线程与 GPU。
            await Task.yield()
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) { isStageReady = true }
            updateVisualizer(for: presentationEffect)
            scheduleChromeHide()
        }
        .task(id: lyricObservationIdentity) {
            await observeLyricPlayback()
        }
        .onChange(of: presentationEffect) { _, value in
            if isStageReady { updateVisualizer(for: value) }
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            refreshArtworkInputs()
            if isStageReady { updateVisualizer(for: presentationEffect) }
        }
        .onChange(of: titleWallQueueIdentity) { _, _ in
            refreshTitleWallTitles()
        }
        .background {
            MacImmersiveLibraryCountObserver {
                refreshGallerySongs()
            }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing {
                updateVisualizer(for: presentationEffect)
                scheduleChromeHide()
            } else {
                visualizer.stop()
                revealChrome()
            }
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
            chromeTask?.cancel()
            visualizer.stop()
        }
    }

    // MARK: - 画面

    private func stage(metrics: ImmersiveStageMetrics) -> some View {
        ImmersiveStageView(
            style: presentationEffect,
            platform: .macOS,
            metrics: metrics,
            track: stageTrack,
            playbackTime: { player.interpolatedTime() },
            palette: artworkPalette,
            lyricWindow: lyricWindow,
            currentLyric: currentLyric,
            nextLyric: nextLyric,
            lyricsWritingDirection: LyricWritingDirectionPolicy.resolve(
                metadataLines: lyrics.first?.metadataLines ?? []
            ),
            levels: spectrumLevels,
            galleryArtworkCount: gallerySongs.count,
            galleryArtwork: { index, side in
                guard gallerySongs.indices.contains(index) else { return AnyView(Color.clear) }
                let song = gallerySongs[index]
                return AnyView(
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: nil,
                        cornerRadius: 0,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat,
                        showsPlaceholder: false
                    )
                    .frame(width: side, height: side)
                )
            },
            titleWallTitles: titleWallTitles,
            reduceMotion: reduceMotion,
            lyricsMotionEnabled: lyricsMotionEnabled,
            lyricInterlude: lyricInterlude,
            lyricsPlaceholder: String(localized: "lyrics_empty_title"),
            controlsInset: controlsInset(metrics),
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
        case .showcase: designHeight = 104
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
                Button(action: onExitFullScreen) {
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
                .keyboardShortcut(.cancelAction)
                .help(Text("exit_full_screen"))
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)

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
                        Divider().frame(height: metrics.s(24)).opacity(0.24)
                        volumeControl
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
                volumeControl
                queueButton
            }
        case .showcase:
            macShowcaseControlSurface(metrics: metrics)
                .frame(maxWidth: .infinity, alignment: macShowcaseControlAlignment)
        }
    }

    @ViewBuilder
    private func macShowcaseControlSurface(metrics: ImmersiveStageMetrics) -> some View {
        ImmersiveGlassPill(
            horizontalPadding: metrics.s(18),
            verticalPadding: metrics.s(8)
        ) {
            transportStrip
        }
    }

    private var macShowcaseControlAlignment: Alignment {
        switch presentationEffect {
        case .radialPulse:
            .leading
        case .coverFlow, .coverGallery, .starryNight, .flowingLines, .lightRhythm, .kineticTitle, .liveWaveform:
            .trailing
        case .native:
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
                volumeControl
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

    private var effectMenu: some View {
        Button {
            chromeTask?.cancel()
            withAnimation(.easeOut(duration: 0.18)) {
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
        .fixedSize()
        .overlay(alignment: .topLeading) {
            if showsEffectPicker {
                ImmersiveEffectPickerSurface(selected: effect, palette: artworkPalette) { candidate in
                    showsEffectPicker = false
                    selectEffect(candidate)
                }
                .offset(y: 42)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }
        }
        .zIndex(showsEffectPicker ? 20 : 0)
        .help(Text("fullscreen_effect_settings_title"))
    }

    private var seekBar: some View {
        VStack(spacing: 5) {
            MacImmersiveScrubber(accent: seekTint) { fraction in
                revealChrome()
                player.seek(to: fraction * player.duration)
            }
            HStack {
                Text(player.currentTime.formattedDuration)
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
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(chromeInk)
                    .frame(width: 58, height: 58)
                    .overlay { Circle().strokeBorder(chromeInk.opacity(0.64), lineWidth: 1.4) }
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .help(Text(player.isPlaying ? "a11y_pause" : "a11y_play"))

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
        }
        .buttonStyle(.plain)
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
            Image(systemName: volumeSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chromeInk.opacity(0.70))
                .frame(width: 18)
            PMVolumeSlider(
                value: Binding(
                    get: { Double(engine.volume) },
                    set: { player.setPlaybackVolume(Float($0)) }
                ),
                isEnabled: player.isLiveRadio || player.playbackSettings.outputMode == .effects,
                accessibilityLabel: String(localized: "volume"),
                accessibilityHelp: !player.isLiveRadio && player.playbackSettings.outputMode == .highFidelity
                    ? String(localized: "volume_high_fidelity_system_hint")
                    : nil
            )
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
        .help(Text(help))
    }

    private var seekTint: Color {
        artworkPalette.primary
    }

    private var volumeSymbol: String {
        let volume = engine.volume
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.4 { return "speaker.wave.1.fill" }
        if volume < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - 数据

    private var artworkPalette: ImmersiveArtworkPalette {
        ImmersiveArtworkPalette(primary: theme.accentColor, secondary: theme.darkAccent)
    }

    private func refreshArtworkInputs() {
        if let song = player.currentSong {
            coverTintProvider.prepare([song])
        }
        refreshGallerySongs()
        refreshTitleWallTitles()
    }

    private var titleWallQueueIdentity: String {
        let count = player.queueCount
        guard count > 0 else { return "0|\(player.currentSong?.id ?? "")" }
        let indices = Set([0, max(player.currentIndex - 1, 0), player.currentIndex, min(player.currentIndex + 1, count - 1), count - 1])
        let sampledIDs = indices.sorted().compactMap { player.queuedSong(at: $0)?.id }
        return "\(count)|\(sampledIDs.joined(separator: "|"))"
    }

    private func refreshTitleWallTitles() {
        var titles: [String] = []
        titles.reserveCapacity(player.queueCount)
        for index in 0..<player.queueCount {
            guard let value = player.queuedSong(at: index)?.title
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  ServerCatalogMetadataInspectionPolicy.hasUsableTitle(value) else { continue }
            titles.append(value)
        }
        titleWallTitles = titles.isEmpty ? [songTitle] : titles
    }

    private func refreshGallerySongs() {
        let currentID = player.currentSong?.id
        let eligible = library.songs.filter { song in
            song.id != currentID
                && !(song.coverArtFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard !eligible.isEmpty else {
            gallerySongs = []
            return
        }

        let limit = min(14, eligible.count)
        let seedText = currentID ?? "primuse"
        let seed = seedText.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        let start = seed % eligible.count
        let rawStride = max(1, eligible.count / max(limit, 1))
        let step = rawStride.isMultiple(of: 2) ? rawStride + 1 : rawStride
        var selected: [Song] = []
        var seen: Set<String> = []
        var cursor = start
        var attempts = 0
        while selected.count < limit && attempts < eligible.count * 2 {
            let song = eligible[cursor % eligible.count]
            if seen.insert(song.id).inserted { selected.append(song) }
            cursor += step
            attempts += 1
        }
        if selected.count < limit {
            for song in eligible where seen.insert(song.id).inserted {
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
                offset: position - index
            )
        }
    }

    private var currentLyric: String? {
        guard let index = activeLyricIndex,
              lyrics.indices.contains(index) else { return nil }
        return lyrics[index].text
    }

    private var nextLyric: String? {
        guard let index = activeLyricIndex, index + 1 < lyrics.count else { return nil }
        return lyrics[index + 1].text
    }

    private var lyricObservationIdentity: String {
        "\(player.currentSong?.id ?? "")|\(lyrics.hashValue)"
    }

    @MainActor
    private func observeLyricPlayback() async {
        activeLyricIndex = nil
        lyricInterlude = false
        guard hasSynchronizedLyrics else { return }

        let lookahead = lyrics.contains { $0.isWordLevel }
            ? Self.wordLevelLineLookahead
            : Self.lineLevelLookahead
        while !Task.isCancelled {
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

            if activeLyricIndex != index { activeLyricIndex = index }
            if lyricInterlude != isInterlude { lyricInterlude = isInterlude }

            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
    }

    private var spectrumLevels: [CGFloat] {
        guard presentationEffect.usesRealtimeSpectrum else { return [] }
        return visualizer.bandLevels.map { min(max(CGFloat($0), 0), 1) }
    }

    private var songTitle: String {
        let value = player.currentSong?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ServerCatalogMetadataInspectionPolicy.hasUsableTitle(value)
            ? value
            : ImmersiveDemoContent.title
    }

    private var artistName: String {
        let value = player.currentSong?.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
            format: song.fileFormat.displayName,
            sampleRate: song.sampleRate,
            bitDepth: song.bitDepth
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
                Task { await player.previous() }
            } else {
                seek(by: -10)
            }
            return .handled
        }

        if press.key == .rightArrow {
            if press.modifiers.contains(.option) {
                Task { await player.next() }
            } else {
                seek(by: 10)
            }
            return .handled
        }

        let characters = press.characters.lowercased()
        if characters == "l" {
            selectEffect(.kineticTitle)
            return .handled
        }
        if characters == "0" {
            selectEffect(.native)
            return .handled
        }
        if let number = Int(characters), (1...8).contains(number) {
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
        guard player.isPlaying,
              value.usesRealtimeSpectrum,
              let audioEngine = player.audioEngine.engineForVisualizer,
              let mixer = player.audioEngine.mainMixerForVisualizer else {
            visualizer.stop()
            return
        }
        visualizer.start(engine: audioEngine, on: mixer)
    }

    private func revealChrome() {
        if !showsChrome {
            withAnimation(.easeInOut(duration: 0.22)) { showsChrome = true }
        }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        guard isStageReady,
              player.isPlaying,
              !voiceOverEnabled,
              !showsEffectPicker else { return }
        chromeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(presentationEffect.usesShowcaseChrome ? 5 : 3))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  player.isPlaying,
                  !voiceOverEnabled,
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
