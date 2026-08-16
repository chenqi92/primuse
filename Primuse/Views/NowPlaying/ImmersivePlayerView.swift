#if os(iOS)
import SwiftUI
import AVFAudio
import PrimuseKit

/// iOS 全屏沉浸播放。
///
/// iOS 使用点按、上下/左右滑动、捏合与底边拖动；控件按 3.5 秒静默时序淡出，
/// 连续 5 分钟无操作后进入低亮度 Ambient Rest。
struct ImmersivePlayerView: View {
    @Binding var effect: FullscreenPlayerEffect
    let lyrics: [LyricLine]
    let onDismiss: () -> Void
    let onMinimize: () -> Void
    let onShowQueue: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioVisualizerService.self) private var visualizer
    @Environment(MusicLibrary.self) private var library
    @Environment(CoverTintProvider.self) private var coverTintProvider
    @Environment(ThemeService.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @State private var showsChrome = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var ambientTask: Task<Void, Never>?
    @State private var isAmbientRest = false
    @State private var ambientDrift = false
    @State private var isSeeking = false
    @State private var hasResolvedArtwork = true
    @State private var hasEntered = false
    @State private var gallerySongs: [Song] = []
    @State private var showsEffectPicker = false
    @State private var activeLyricIndex: Int?
    @State private var lyricInterlude = false

    private var presentationEffect: FullscreenPlayerEffect {
        let raw = ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: effect.rawValue,
            hasSynchronizedLyrics: hasSynchronizedLyrics,
            hasArtwork: hasResolvedArtwork
        )
        return FullscreenPlayerEffect(rawValue: raw) ?? .coverFlow
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ImmersiveStageMetrics(size: geometry.size, safeArea: geometry.safeAreaInsets)

            ZStack {
                stage(metrics: metrics)
                    .scaleEffect(isAmbientRest ? 1.018 : 1)
                    .offset(
                        x: isAmbientRest ? (ambientDrift ? metrics.s(8) : -metrics.s(8)) : 0,
                        y: isAmbientRest ? (ambientDrift ? -metrics.s(6) : metrics.s(6)) : 0
                    )
                    .overlay {
                        if isAmbientRest { Color.black.opacity(0.60) }
                    }

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                guard !isControlZone(value.location, in: geometry.size) else { return }
                                handleSurfaceTap()
                            }
                    )
                    .simultaneousGesture(surfaceDrag(in: geometry.size))
                    .simultaneousGesture(modeMagnification)

                if isAmbientRest {
                    ambientRestOverlay(metrics: metrics)
                        .transition(.opacity)
                }

                if showsChrome && !isAmbientRest {
                    chrome(metrics: metrics)
                        .offset(y: showsChrome ? 0 : 8)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }

                bottomEdgeSeekArea(in: geometry.size)
            }
            .animation(.easeInOut(duration: 0.26), value: showsChrome)
            .animation(.easeInOut(duration: 0.35), value: isAmbientRest)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, presentationEffect.prefersLightContent ? .light : .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .opacity(hasEntered ? 1 : 0)
        .scaleEffect(hasEntered ? 1 : 1.012)
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            refreshArtworkInputs()
            updateVisualizer(for: presentationEffect)
            scheduleChromeHide()
            scheduleAmbientRest()
            withAnimation(.easeOut(duration: 0.20)) { hasEntered = true }
        }
        .task(id: lyricObservationIdentity) {
            await observeLyricPlayback()
        }
        .onChange(of: effect) { _, _ in
            updateVisualizer(for: presentationEffect)
            revealChrome()
            scheduleAmbientRest()
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            refreshArtworkInputs()
            updateVisualizer(for: presentationEffect)
        }
        .background {
            ImmersiveLibraryCountObserver {
                refreshGallerySongs()
            }
        }
        .onChange(of: presentationEffect) { _, newValue in
            updateVisualizer(for: newValue)
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying {
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
                ambientTask?.cancel()
                showsChrome = true
                exitAmbientRest()
            } else {
                revealChrome()
                scheduleAmbientRest()
            }
        }
        .onDisappear {
            chromeTask?.cancel()
            ambientTask?.cancel()
            visualizer.stop()
        }
        .accessibilityAction(.escape, onDismiss)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                player.seek(to: min(player.duration, player.currentTime + 10))
            case .decrement:
                player.seek(to: max(0, player.currentTime - 10))
            @unknown default:
                break
            }
            registerInteraction(revealControls: true)
        }
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
            levels: spectrumLevels,
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
            reduceMotion: reduceMotion,
            lyricsMotionEnabled: lyricsMotionEnabled,
            lyricInterlude: lyricInterlude,
            lyricsPlaceholder: String(localized: "lyrics_empty_title"),
            controlsInset: controlsInset(metrics)
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
        VStack(spacing: 0) {
            topChrome(metrics: metrics)
            .padding(.horizontal, max(max(metrics.safeArea.leading, metrics.safeArea.trailing) + 16, 20))
            .padding(.top, topChromeInset(metrics))

            Spacer()

            bottomChrome(metrics: metrics)
            .padding(.horizontal, max(metrics.safeArea.leading, metrics.safeArea.trailing) + 20)
            .padding(.bottom, max(metrics.safeArea.bottom + 10, 18))
        }
    }

    @ViewBuilder
    private func topChrome(metrics: ImmersiveStageMetrics) -> some View {
        HStack(spacing: 10) {
            dismissChromeButton
            Spacer()
            effectChromeMenu
            queueChromeButton
        }
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

    private var effectChromeMenu: some View {
        Button {
            showsEffectPicker = true
        } label: {
            ImmersiveGlassActionLabel(
                symbol: "viewfinder.rectangular",
                tint: chromeInk,
                diameter: 44,
                isSelected: effect != .native
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsEffectPicker, arrowEdge: .top) {
            ImmersiveEffectPickerPanel(selected: effect) { candidate in
                effect = candidate
                showsEffectPicker = false
            }
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(Text("fullscreen_effect_settings_title"))
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
            transportButton("backward.fill", size: 17, diameter: 38, label: "a11y_previous_track") {
                Task { await player.previous() }
            }
            playPauseButton(diameter: 48, outlined: outlinedPlay)
            transportButton("forward.fill", size: 17, diameter: 38, label: "a11y_next_track") {
                Task { await player.next() }
            }
        }
    }

    private func showcaseControlAlignment(_ metrics: ImmersiveStageMetrics) -> Alignment {
        guard metrics.layout != .phonePortrait else { return .center }
        switch presentationEffect {
        case .radialPulse:
            return .leading
        case .coverFlow, .coverGallery, .starryNight, .flowingLines, .lightRhythm, .kineticTitle, .liveWaveform:
            return .trailing
        case .native:
            return .center
        }
    }

    private func deepFieldControls(metrics: ImmersiveStageMetrics) -> some View {
        let portrait = metrics.layout == .phonePortrait
        return VStack(spacing: 0) {
            seekBar
            HStack(spacing: metrics.s(20)) {
                modeButton("shuffle", active: player.shuffleEnabled) {
                    player.shuffleEnabled.toggle()
                }
                transportButton("backward.fill", size: 18, diameter: 42, label: "a11y_previous_track") {
                    Task { await player.previous() }
                }
                playPauseButton(diameter: 56, outlined: true)
                transportButton("forward.fill", size: 18, diameter: 42, label: "a11y_next_track") {
                    Task { await player.next() }
                }
                modeButton(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                    advanceRepeatMode()
                }
            }
            .padding(.top, metrics.s(portrait ? 29 : 12))

            HStack(spacing: metrics.s(14)) {
                Text(audioMetadata.uppercased())
                    .font(.system(size: metrics.s(8), weight: .medium, design: .monospaced))
                    .tracking(metrics.f(0.8))
                    .foregroundStyle(ImmersiveStagePalette.accent200.opacity(0.92))
                    .padding(.horizontal, metrics.s(10))
                    .padding(.vertical, metrics.s(6))
                    .background(
                        ImmersiveStagePalette.accent600.opacity(0.46),
                        in: RoundedRectangle(cornerRadius: metrics.f(4), style: .continuous)
                    )
                Spacer()
                effectShortcutButton("textformat.size", target: .kineticTitle)
                effectShortcutButton("waveform", target: .liveWaveform)
                AirPlayButton()
                    .frame(width: 34, height: 34)
                    .accessibilityLabel(Text("cast_to_device"))
                queueButton(diameter: 34)
            }
            .padding(.top, metrics.s(portrait ? 65 : 12))
        }
        .padding(.bottom, portrait ? metrics.s(14) : 0)
        .frame(maxWidth: metrics.layout == .phoneLandscape ? 500 : 560)
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
                    .foregroundStyle(ImmersiveStagePalette.accent300.opacity(0.82))
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
        VStack(spacing: 5) {
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                fillTint: seekTint,
                onSeek: {
                    revealChrome()
                    player.seek(to: $0)
                }
            )

            HStack {
                Text(player.currentTime.formattedDuration)
                Spacer()
                Text(player.duration.formattedDuration)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(ImmersiveStagePalette.ink.opacity(0.42))
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    isSeeking = true
                    registerInteraction(revealControls: true)
                }
                .onEnded { _ in
                    isSeeking = false
                    scheduleChromeHide()
                }
        )
    }

    private func playPauseButton(diameter: CGFloat, outlined: Bool) -> some View {
        let emphasis = ImmersiveStagePalette.accent300
        return Button {
            revealChrome()
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * 0.38, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
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
        .disabled(player.isLoading)
        .accessibilityLabel(player.isPlaying ? Text("a11y_pause") : Text("a11y_play"))
    }

    private func modeButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            revealChrome()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? ImmersiveStagePalette.accent300 : pillInk.opacity(0.54))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

    private func effectShortcutButton(
        _ symbol: String,
        target: FullscreenPlayerEffect
    ) -> some View {
        Button {
            effect = target
            revealChrome()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(pillInk.opacity(0.58))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(target.titleKey))
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
        presentationEffect.prefersLightContent ? ImmersiveStagePalette.accent700 : ImmersiveStagePalette.accent300
    }

    private var chromeInk: Color { pillInk }

    // MARK: - 数据

    private var artworkPalette: ImmersiveArtworkPalette {
        if let songID = player.currentSong?.id,
           let extracted = coverTintProvider.palette(forSongID: songID) {
            return extracted
        }
        return ImmersiveArtworkPalette(primary: theme.accentColor, secondary: theme.darkAccent)
    }

    private func refreshArtworkInputs() {
        if let song = player.currentSong {
            coverTintProvider.prepare([song])
        }
        refreshGallerySongs()
    }

    /// 每次切歌只取一次稳定样本，避免实时频谱刷新时反复扫描整个资料库。
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

        let limit = min(12, eligible.count)
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
        return (lower..<upper).map { position in
            ImmersiveStageLyric(
                id: position,
                text: lyrics[position].text,
                isActive: position == index,
                offset: position - index
            )
        }
    }

    private var currentLyricText: String? {
        guard let index = activeLyricIndex,
              lyrics.indices.contains(index) else { return nil }
        return lyrics[index].text
    }

    private var nextLyricText: String? {
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

    /// 只转发真实采样结果；静音或无 tap 时保持零值，不生成替代循环。
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

    // MARK: - 手势与 Ambient Rest

    private func bottomEdgeSeekArea(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Color.clear
                .contentShape(Rectangle())
                .frame(height: 34)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            isSeeking = true
                            exitAmbientRest()
                            chromeTask?.cancel()
                        }
                        .onEnded { value in
                            let width = max(size.width, 1)
                            let fraction = min(1, max(0, value.location.x / width))
                            player.seek(to: fraction * player.duration)
                            isSeeking = false
                            registerInteraction(revealControls: false)
                        }
                )
                .accessibilityHidden(true)
        }
        .allowsHitTesting(!showsChrome && !isAmbientRest)
    }

    private func isControlZone(_ point: CGPoint, in size: CGSize) -> Bool {
        let topExclusion = max(CGFloat(72), CGFloat(18 + 44))
        let bottomExclusion = max(CGFloat(34), controlsInsetForHitTesting)
        return point.y < topExclusion || point.y > size.height - bottomExclusion
    }

    private var controlsInsetForHitTesting: CGFloat {
        presentationEffect.chromeFamily == .lyrics ? 34 : 112
    }

    private func surfaceDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
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

    private var modeMagnification: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.08)
            .onEnded { value in
                guard abs(value.magnification - 1) >= 0.10 else { return }
                let offset = value.magnification > 1 ? 1 : -1
                effect = effect.advanced(by: offset)
                registerInteraction(revealControls: true)
            }
    }

    private func ambientRestOverlay(metrics: ImmersiveStageMetrics) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: metrics.s(12)) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: metrics.s(metrics.isPortrait ? 62 : 54), weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(ambientRestText)
                    .font(.system(size: metrics.s(metrics.isPortrait ? 24 : 22), weight: .medium))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.78))
                    .lineLimit(2)
                Text(stageTrack.subtitle)
                    .font(.system(size: metrics.s(14)))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.42))
                    .lineLimit(1)
            }
            .padding(.horizontal, max(metrics.safeArea.leading + 28, metrics.s(30)))
            .padding(.bottom, max(metrics.safeArea.bottom + 38, metrics.s(54)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var ambientRestText: String {
        if let index = activeLyricIndex, lyrics.indices.contains(index) {
            let value = lyrics[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return songTitle
    }

    private func handleSurfaceTap() {
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
        guard !UIAccessibility.isVoiceOverRunning, !showsEffectPicker else { return }
        ambientTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                return
            }
            guard !Task.isCancelled, !isSeeking, !showsEffectPicker else { return }
            enterAmbientRest()
        }
    }

    private func enterAmbientRest() {
        guard !showsEffectPicker else { return }
        chromeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.6)) {
            showsChrome = false
            isAmbientRest = true
        }
        guard !reduceMotion else { return }
        ambientDrift = false
        withAnimation(.linear(duration: 90).repeatForever(autoreverses: true)) {
            ambientDrift = true
        }
    }

    private func exitAmbientRest() {
        guard isAmbientRest else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            isAmbientRest = false
            ambientDrift = false
        }
    }

    // MARK: - 频谱与控件淡出

    private func updateVisualizer(for effect: FullscreenPlayerEffect) {
        guard player.isPlaying,
              effect.usesRealtimeSpectrum,
              let engine = player.audioEngine.engineForVisualizer,
              let mixer = player.audioEngine.mainMixerForVisualizer else {
            visualizer.stop()
            return
        }
        visualizer.start(engine: engine, on: mixer)
    }

    private func toggleChrome() {
        guard !showsEffectPicker else { return }
        if showsChrome {
            chromeTask?.cancel()
            withAnimation(.easeInOut(duration: 0.24)) { showsChrome = false }
        } else {
            revealChrome()
        }
    }

    private func revealChrome() {
        withAnimation(.easeInOut(duration: 0.2)) { showsChrome = true }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        // 旁白开着时控件必须一直可达,否则用户找不到退出按钮。
        guard !UIAccessibility.isVoiceOverRunning,
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
                  player.isPlaying,
                  !isSeeking,
                  !showsEffectPicker else { return }
            withAnimation(.easeInOut(duration: 0.26)) { showsChrome = false }
        }
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
#endif
