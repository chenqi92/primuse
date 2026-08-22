#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 沉浸播放：56pt 安全区、五个 76pt 焦点块、8 秒静默淡出；
/// 长按选择键展开原生 + A–E，左右方向在隐藏态按 10 秒定位，Menu 退出。
struct TVImmersivePlayerView: View {
    var presentsModePickerOnAppear = false

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.resetFocus) private var resetFocus

    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var effectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient

    @State private var showsChrome = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var showsModePicker = false
    @State private var showsQueue = false
    @State private var hasResolvedArtwork = true
    @State private var gallerySongs: [TVSong] = []
    @State private var titleWallTitles: [String] = []
    @State private var activeLyricIndex: Int?
    @State private var lyricInterlude = false
    @Namespace private var chromeFocus
    @FocusState private var focusedControl: Control?
    @FocusState private var focusedEffect: FullscreenPlayerEffect?
    @FocusState private var lyricsToggleFocused: Bool
    @FocusState private var wakesChrome: Bool

    private enum Control: Hashable { case previous, playPause, next, modes, queue }

    private var effect: FullscreenPlayerEffect {
        #if DEBUG
        if TVDebugLaunch.screen == "immersivePlayer" {
            return .coverFlow
        }
        #endif
        return FullscreenPlayerEffect(rawValue: effectRawValue) ?? .defaultValue
    }

    private var presentationEffect: FullscreenPlayerEffect {
        let raw = ImmersivePresentationFallbackPolicy.effectiveEffectRawValue(
            selectedRawValue: effect.rawValue,
            hasSynchronizedLyrics: hasSynchronizedLyrics,
            hasArtwork: hasResolvedArtwork
        )
        return FullscreenPlayerEffect(rawValue: raw) ?? .coverFlow
    }

    private var artworkPalette: ImmersiveArtworkPalette {
        ImmersiveArtworkPalette(
            primary: coverDrivenAmbient ? store.nowPlaying.tint : TVColor.brand(hex: accentHex),
            secondary: coverDrivenAmbient ? store.nowPlaying.tint2 : TVColor.brandSecondary(hex: accentHex)
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = ImmersiveStageMetrics(size: geometry.size, prefersWide: true)

            ZStack {
                stage(metrics: metrics)
                    .accessibilityHidden(showsModePicker)

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
                .disabled(showsChrome)
                .accessibilityHidden(showsChrome)

                if showsChrome {
                    controls(metrics: metrics)
                        .transition(.opacity)
                        .accessibilityHidden(showsModePicker)
                }

                if showsModePicker {
                    modePicker(metrics: metrics)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(10)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.30), value: showsChrome)
            .animation(.easeInOut(duration: reduceMotion ? 0.01 : 0.26), value: showsModePicker)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.65)
                    .onEnded { _ in presentModePicker() }
            )
        }
        .ignoresSafeArea()
        .onExitCommand {
            if showsModePicker {
                if effect == .native {
                    dismiss()
                } else {
                    showsModePicker = false
                    revealChrome()
                }
            } else {
                dismiss()
            }
        }
        .onMoveCommand(perform: handleMoveCommand)
        .onPlayPauseCommand {
            revealChrome()
            store.togglePlayPause()
        }
        .fullScreenCover(isPresented: $showsQueue) {
            TVQueueView().environment(store)
        }
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            updateSpectrumAnalysis(for: presentationEffect)
            if effect == .native {
                guard presentsModePickerOnAppear else {
                    dismiss()
                    return
                }
                showsChrome = false
                showsModePicker = true
                refreshGallerySongs()
                refreshTitleWallTitles()
                return
            }
            refreshGallerySongs()
            refreshTitleWallTitles()
            scheduleChromeHide()
        }
        .task(id: lyricObservationIdentity) {
            await observeLyricPlayback()
        }
        .onDisappear {
            chromeTask?.cancel()
            store.engine.setSpectrumAnalysisEnabled(false)
        }
        .onChange(of: focusedControl) { _, _ in
            // 遥控在传输键之间移动焦点即视为有操作,重置淡出计时。
            if showsChrome { scheduleChromeHide() }
        }
        .onChange(of: focusedEffect) { _, _ in
            if showsModePicker { chromeTask?.cancel() }
        }
        .onChange(of: effectRawValue) { _, rawValue in
            if FullscreenPlayerEffect(rawValue: rawValue) == .native {
                dismiss()
            }
        }
        .onChange(of: presentationEffect) { _, newValue in
            updateSpectrumAnalysis(for: newValue)
        }
        .onChange(of: store.nowPlaying.songID) { _, _ in
            refreshGallerySongs()
            refreshTitleWallTitles()
        }
        .onChange(of: store.queueSongIDs) { _, _ in
            refreshTitleWallTitles()
        }
        .background {
            TVImmersiveLibraryCountObserver {
                refreshGallerySongs()
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
            playbackTime: { store.currentTime },
            palette: artworkPalette,
            lyricWindow: lyricWindow,
            currentLyric: currentLyric,
            nextLyric: nextLyric,
            lyricsWritingDirection: store.lyrics.first?.writingDirection ?? .natural,
            levels: presentationEffect.usesRealtimeSpectrum
                ? store.engine.spectrumLevels.map { min(max(CGFloat($0), 0), 1) }
                : [],
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
            titleWallTitles: titleWallTitles,
            reduceMotion: reduceMotion,
            lyricsMotionEnabled: lyricsMotionEnabled,
            lyricInterlude: lyricInterlude,
            lyricsPlaceholder: PMString("ext.tv.nowPlaying.noLyrics"),
            visualizerDisclosure: PMString("ext.tv.immersive.timelineDisclosure"),
            controlsInset: metrics.s(150),
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
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.5))
            }
            .padding(.horizontal, 56)
            .padding(.top, 56)

            Spacer()

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
        case .radialPulse:
            .leading
        case .coverFlow, .coverGallery, .starryNight, .flowingLines, .lightRhythm, .kineticTitle, .liveWaveform:
            .trailing
        case .native:
            .center
        }
    }

    private var tvProgress: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let fraction = store.duration > 0 ? min(1, max(0, store.currentTime / store.duration)) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16)).frame(height: 5)
                    Capsule().fill(artworkPalette.primary).frame(width: max(5, geometry.size.width * fraction), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 12)
            HStack {
                Text(store.currentTime.formattedDuration)
                Spacer()
                Text(store.duration.formattedDuration)
            }
            .font(.system(size: 20, weight: .medium, design: .monospaced))
            .foregroundStyle(ImmersiveStagePalette.text.opacity(0.48))
        }
    }

    private func transportControls(surface: ControlSurface) -> some View {
        HStack(spacing: 22) {
            controlButton(.previous, icon: "backward.fill", surface: surface, diameter: 66) { store.previous() }
            controlButton(
                .playPause,
                icon: store.isPlaying ? "pause.fill" : "play.fill",
                surface: .outlined,
                primary: true,
                diameter: 92
            ) {
                store.togglePlayPause()
            }
            .prefersDefaultFocus(true, in: chromeFocus)
            controlButton(.next, icon: "forward.fill", surface: surface, diameter: 66) { store.next() }
        }
    }

    private func modeAndQueueControls(surface: ControlSurface) -> some View {
        HStack(spacing: 16) {
            controlButton(.modes, icon: "square.grid.2x2", surface: surface, diameter: 60) {
                presentModePicker()
            }
            controlButton(.queue, icon: "list.bullet", surface: surface, diameter: 60) {
                showsQueue = true
            }
        }
    }

    private enum ControlSurface { case bare, outlined, tile }

    private func controlButton(
        _ control: Control,
        icon: String,
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
    }

    private func modePicker(metrics: ImmersiveStageMetrics) -> some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: metrics.s(24)) {
                HStack {
                    Text(PMString("ext.tv.settings.immersive"))
                        .font(.system(size: metrics.s(34), weight: .medium))
                        .foregroundStyle(ImmersiveStagePalette.ink)
                    Spacer()
                    let toggleFocused = lyricsToggleFocused
                    Button {
                        lyricsMotionEnabled.toggle()
                    } label: {
                        HStack(spacing: metrics.s(12)) {
                            Image(systemName: lyricsMotionEnabled ? "checkmark.circle.fill" : "circle")
                            Text(PMString("immersive_lyrics_motion_title"))
                        }
                        .font(.system(size: metrics.s(18), weight: .medium))
                        .foregroundStyle(lyricsMotionEnabled ? artworkPalette.primary : .white.opacity(0.72))
                        .padding(.horizontal, metrics.s(22))
                        .frame(height: metrics.s(54))
                        .background(.white.opacity(toggleFocused ? 0.18 : 0.08), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 1) }
                        .tvFocusRing(toggleFocused, radius: metrics.s(27), accent: .white, scale: 1.05, lift: 5)
                    }
                    .buttonStyle(TVBareButtonStyle())
                    .focused($lyricsToggleFocused)
                    .focusEffectDisabled()
                }

                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: metrics.s(16)),
                    count: metrics.size.width < 1200 ? 3 : 4
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: metrics.s(22)) {
                        ForEach(FullscreenEffectCollection.allCases) { collection in
                            VStack(alignment: .leading, spacing: metrics.s(10)) {
                                Text(collection.title)
                                    .font(.system(size: metrics.s(17), weight: .semibold))
                                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.50))

                                LazyVGrid(columns: columns, spacing: metrics.s(16)) {
                                    ForEach(collection.effects) { candidate in
                                        let focused = focusedEffect == candidate
                                        let selected = effect == candidate
                                        Button {
                                            selectEffect(candidate)
                                            if candidate == .native {
                                                dismiss()
                                                return
                                            }
                                            showsModePicker = false
                                            revealChrome()
                                        } label: {
                                            HStack(alignment: .top, spacing: metrics.s(12)) {
                                                Image(systemName: candidate.symbolName)
                                                    .font(.system(size: metrics.s(24), weight: .semibold))
                                                    .frame(width: metrics.s(42))
                                                VStack(alignment: .leading, spacing: metrics.s(4)) {
                                                    Text(candidate.localizedTitle)
                                                        .font(.system(size: metrics.s(17), weight: .semibold))
                                                        .lineLimit(1)
                                                        .minimumScaleFactor(0.78)
                                                    Text(candidate.localizedSubtitle)
                                                        .font(.system(size: metrics.s(12)))
                                                        .foregroundStyle(.white.opacity(0.58))
                                                        .lineLimit(2)
                                                    Label(candidate.motionDescription, systemImage: "waveform.path")
                                                        .font(.system(size: metrics.s(11)))
                                                        .foregroundStyle(artworkPalette.primary.opacity(0.82))
                                                        .lineLimit(2)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .foregroundStyle(selected ? artworkPalette.primary : .white.opacity(0.88))
                                            .padding(metrics.s(16))
                                            .frame(maxWidth: .infinity, minHeight: metrics.s(124), alignment: .topLeading)
                                            .background(.white.opacity(focused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 8))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .strokeBorder(
                                                        selected ? artworkPalette.primary : .white.opacity(0.20),
                                                        lineWidth: selected ? 2 : 1
                                                    )
                                            }
                                            .tvFocusRing(focused, radius: 8, accent: .white, scale: 1.05, lift: 6)
                                        }
                                        .buttonStyle(TVBareButtonStyle())
                                        .focused($focusedEffect, equals: candidate)
                                        .focusEffectDisabled()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, metrics.s(14))
                    .padding(.vertical, metrics.s(14))
                }
            }
            .padding(.horizontal, metrics.s(54))
            .padding(.vertical, metrics.s(38))
        }
        .focusSection()
        .onAppear { focusedEffect = effect }
        .accessibilityAddTraits(.isModal)
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

    private func refreshGallerySongs() {
        let currentID = store.nowPlaying.songID
        let eligible = store.songs.filter { song in
            song.id != currentID
                && !(song.coverRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
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
    }

    private func refreshTitleWallTitles() {
        let current = meaningful(store.nowPlaying.title, fallback: ImmersiveDemoContent.title)
        let queueTitles = store.queueSongIDs.compactMap { id -> String? in
            guard let title = store.song(id)?.title.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            return title
        }
        titleWallTitles = queueTitles.isEmpty ? [current] : queueTitles
    }

    private func meaningful(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        return trimmed.isEmpty
            || ["unknown", "unknown title", "unknown artist", "unknown album", "未知", "未知标题", "未知艺术家", "未知专辑"].contains(normalized)
            ? fallback
            : trimmed
    }

    private func formatLine(_ np: TVNowPlaying) -> String {
        var parts: [String] = []
        if np.sampleRate >= 88.2 || np.format.lowercased() == "flac" {
            parts.append("hi-res")
        }
        if np.sampleRate > 0 {
            let khz = np.sampleRate.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(np.sampleRate)) : String(format: "%.1f", np.sampleRate)
            parts.append("\(khz)kHz")
        }
        if !np.format.isEmpty { parts.append(np.format.lowercased()) }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }

    private var hasSynchronizedLyrics: Bool {
        store.lyricsFollowPlayback
    }

    private var lyricWindow: [ImmersiveStageLyric] {
        guard let index = activeLyricIndex,
              store.lyrics.indices.contains(index) else { return [] }
        let lower = max(0, index - 1)
        let upper = min(store.lyrics.count, index + 4)
        return (lower..<upper).compactMap { position in
            let text = store.lyrics[position].text.trimmingCharacters(in: .whitespacesAndNewlines)
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
              store.lyrics.indices.contains(index) else { return nil }
        return store.lyrics[index].text
    }

    private var nextLyric: String? {
        guard let index = activeLyricIndex,
              index + 1 < store.lyrics.count else { return nil }
        return store.lyrics[index + 1].text
    }

    private var lyricObservationIdentity: String {
        "\(store.nowPlaying.songID)|\(store.lyricsRevision)|\(lyricsMotionEnabled)"
    }

    @MainActor
    private func observeLyricPlayback() async {
        activeLyricIndex = nil
        lyricInterlude = false
        guard hasSynchronizedLyrics else { return }

        while !Task.isCancelled {
            let playbackTime = store.currentTime
            let index = store.currentLyricIndex
            let isInterlude: Bool
            if lyricsMotionEnabled,
               let index,
               store.lyrics.indices.contains(index) {
                let line = store.lyrics[index]
                let estimatedDuration = line.syllables.isEmpty
                    ? 3.5
                    : line.syllables.reduce(0) { $0 + max(0.05, $1.d) }
                isInterlude = playbackTime - (line.time + estimatedDuration) > 6
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

    private func updateSpectrumAnalysis(for presentation: FullscreenPlayerEffect) {
        store.engine.setSpectrumAnalysisEnabled(
            effect != .native && presentation.usesRealtimeSpectrum
        )
    }

    // MARK: - 遥控与控件淡出

    private func selectEffect(_ value: FullscreenPlayerEffect) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.01 : 0.28)) {
            effectRawValue = value.rawValue
        }
        FullscreenPlayerEffectSync.shared.select(value)
        if value == .native { dismiss() }
    }

    private func presentModePicker() {
        chromeTask?.cancel()
        showsChrome = true
        focusedEffect = effect
        showsModePicker = true
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard !showsModePicker else { return }
        if !showsChrome {
            revealChrome()
            switch direction {
            case .left: store.skipBackward()
            case .right: store.skipForward()
            default: break
            }
        } else {
            scheduleChromeHide()
        }
    }

    private func revealChrome() {
        wakesChrome = false
        withAnimation(.easeInOut(duration: 0.24)) { showsChrome = true }
        Task { @MainActor in
            await Task.yield()
            resetFocus(in: chromeFocus)
            focusedControl = .playPause
        }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeTask?.cancel()
        guard !showsModePicker, !voiceOverEnabled else { return }
        chromeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(presentationEffect.usesShowcaseChrome ? 5 : 8))
            } catch {
                return
            }
            guard !Task.isCancelled, !showsModePicker else { return }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.01 : 0.4)) { showsChrome = false }
            await Task.yield()
            wakesChrome = true
        }
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
