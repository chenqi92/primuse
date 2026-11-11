#if os(iOS)
import PrimuseKit
import SwiftUI

/// 转轮的「调音」一面:这首歌听起来怎样。顶上一条跟着音乐跳的细频谱,下面是均衡器、音效、
/// 速度与音调、输出与音质几张卡片,都是为这个尺寸重新排的紧凑版,不是把设置页原样塞进来。
struct NowPlayingCarouselSoundFace: View {
    let context: NowPlayingCarouselFaceContext
    let appearance: NowPlayingAppearance
    let onShowSongInfo: () -> Void
    let onShowCastPicker: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingCarouselSpectrumStrip(
                isVisible: context.isSettled && context.isSurfaceExposed && scenePhase == .active,
                appearance: appearance
            )
            .padding(.horizontal, 22)
            .padding(.bottom, 6)

            NowPlayingCarouselCardStack {
                ForEach(Array(context.cards.enumerated()), id: \.element) { index, card in
                    cardView(card)
                        .nowPlayingCarouselCardEntrance(index: index, isCommitted: context.isCommitted)
                }
            }
        }
    }

    @ViewBuilder
    private func cardView(_ card: NowPlayingCarouselCard) -> some View {
        switch card {
        case .equalizer:
            NowPlayingCarouselEqualizerCard(appearance: appearance)
        case .audioEffects:
            NowPlayingCarouselEffectsCard(appearance: appearance)
        case .speedAndPitch:
            NowPlayingCarouselSpeedPitchCard(appearance: appearance)
        case .outputAndQuality:
            NowPlayingCarouselOutputCard(
                appearance: appearance,
                onShowSongInfo: onShowSongInfo,
                onShowCastPicker: onShowCastPicker
            )
        default:
            EmptyView()
        }
    }
}

// MARK: - 细频谱

/// 一排跟着音乐跳的细柱子,调均衡器、音效时看得到变化。自己持有一份频谱租约:停在这一面、播放页露在外面、
/// App 在前台、正在播时才挂 tap(和播放页背景的「声音律动」同一个服务)。Apple Music 与电台没有声音数据,
/// 整条不画;减弱动态效果、低电量、机身过热时不听,只留一道静止的底线。
private struct NowPlayingCarouselSpectrumStrip: View {
    let isVisible: Bool
    let appearance: NowPlayingAppearance

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioVisualizerService.self) private var visualizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ownerID = UUID()
    @State private var isHoldingLease = false
    @State private var feedUnavailableSongID: String?
    @State private var retryTask: Task<Void, Never>?
    @State private var runtimeRevision: UInt = 0

    private static let height: CGFloat = 24
    private static let barWidth: CGFloat = 3
    private static let spacing: CGFloat = 3

    var body: some View {
        let _ = runtimeRevision
        GeometryReader { geometry in
            let count = max(Int((geometry.size.width + Self.spacing) / (Self.barWidth + Self.spacing)), 8)
            let bands = isHoldingLease ? visualizer.bandLevels.map(Double.init) : []
            let levels = bands.isEmpty
                ? Array(repeating: Float(0), count: count)
                : PlayerVisualizerGeometry.barLevels(bands: bands, count: count).map(Float.init)
            VisualizerBarsView(
                levels: levels,
                barColor: appearance.primary.opacity(0.42),
                barWidth: Self.barWidth,
                spacing: Self.spacing,
                maxHeight: Self.height
            )
            .frame(maxWidth: .infinity)
        }
        .frame(height: hasFeed ? Self.height : 0)
        .opacity(hasFeed ? 1 : 0)
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: hasFeed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { synchronizeLease() }
        .onChange(of: shouldListen) { _, _ in synchronizeLease() }
        .onChange(of: player.currentSong?.id) { _, _ in synchronizeLease() }
        .onDisappear {
            retryTask?.cancel()
            releaseLease()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            runtimeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            runtimeRevision &+= 1
        }
    }

    private var hasFeed: Bool {
        guard !player.isAppleMusicMode, !player.isLiveRadio, player.castingRenderer == nil,
              let songID = player.currentSong?.id else { return false }
        return feedUnavailableSongID != songID
    }

    private var shouldListen: Bool {
        guard isVisible, player.isPlaying, hasFeed, !reduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return true
        default: return false
        }
    }

    private func synchronizeLease(allowRetry: Bool = true) {
        retryTask?.cancel()
        retryTask = nil
        guard shouldListen else {
            releaseLease()
            return
        }
        guard let engine = player.audioEngine.engineForVisualizer,
              let tapNode = player.audioEngine.visualizerTapNode,
              engine.isRunning else {
            releaseLease()
            scheduleRetry(allowRetry: allowRetry)
            return
        }
        visualizer.setPacing(ImmersiveFrameRateMode.fps30.spectrumPacing(
            displayMaximumFramesPerSecond: ImmersiveDisplayRefresh.maximumFramesPerSecond
        ))
        if visualizer.acquire(owner: ownerID, engine: engine, on: tapNode) {
            isHoldingLease = true
        } else {
            releaseLease()
            scheduleRetry(allowRetry: allowRetry)
        }
    }

    /// 刚开播时引擎可能还没跑起来,隔一会儿再试一次;还不行就当这首没有声音数据。
    private func scheduleRetry(allowRetry: Bool) {
        let songID = player.currentSong?.id
        guard allowRetry else {
            feedUnavailableSongID = songID
            return
        }
        retryTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled, player.currentSong?.id == songID else { return }
            retryTask = nil
            synchronizeLease(allowRetry: false)
        }
    }

    private func releaseLease() {
        guard isHoldingLease else { return }
        isHoldingLease = false
        visualizer.release(owner: ownerID)
    }
}

// MARK: - 均衡器

/// 均衡器卡:频响曲线可以直接拖(按下的那一段跟着手指上下),预设排成一条横向胶囊。
/// 频段与预设逻辑都是设置里那一套(`EqualizerService`)。
private struct NowPlayingCarouselEqualizerCard: View {
    let appearance: NowPlayingAppearance

    @Environment(AudioPlayerService.self) private var player
    @Environment(PlaybackSettingsStore.self) private var playbackSettings

    var body: some View {
        let eq = player.equalizerService
        let isBypassed = player.outputMode(for: player.currentSong) == .highFidelity
        NowPlayingCarouselCardContainer(
            card: .equalizer,
            appearance: appearance,
            subtitle: eq.isEnabled ? eq.currentPreset.localizedName : nil,
            contentPadding: false
        ) {
            Toggle(isOn: Binding(get: { eq.isEnabled }, set: { eq.setEnabled($0) }).pmAnimated(.control)) {
                Text("eq_enabled")
            }
            .labelsHidden()
            .tint(NowPlayingCarouselPanel.sound.tint)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if isBypassed {
                    NowPlayingCarouselCardNotice(
                        message: String(localized: "eq_menu_high_fidelity_unavailable"),
                        actionTitle: "eq_use_effects_output",
                        appearance: appearance
                    ) {
                        playbackSettings.outputMode = .effects
                    }
                    .padding(.horizontal, 16)
                }

                NowPlayingCarouselEQCurve(eq: eq, appearance: appearance)
                    .padding(.horizontal, 12)
                    .opacity(eq.isEnabled ? 1 : 0.45)
                    .allowsHitTesting(eq.isEnabled)
                    .pmAnimation(.control, value: eq.isEnabled)

                NowPlayingCarouselEQPresetStrip(eq: eq, appearance: appearance)

                if let lowered = eq.headroomLoweredDB, eq.isEnabled {
                    EQHeadroomNote(loweredDB: lowered)
                        .font(.caption)
                        .foregroundStyle(appearance.tertiary)
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

/// 频响曲线:十个频段连成一条平滑曲线,底下是频率。按下时认离手指最近的那一段,之后手指上下就是这一段的增益,
/// 松手前不换段。拖着的时候告诉转轮别翻页。
private struct NowPlayingCarouselEQCurve: View {
    let eq: EqualizerService
    let appearance: NowPlayingAppearance

    @Environment(\.nowPlayingCarouselControlEditing) private var reportsControlEditing
    @State private var activeBand: Int?

    private static let range = PrimuseConstants.eqMinGain...PrimuseConstants.eqMaxGain
    private static let plotHeight: CGFloat = 112
    private static let labelHeight: CGFloat = 16
    private static let horizontalInset: CGFloat = 12

    var body: some View {
        let bands = eq.bands
        let tint = NowPlayingCarouselPanel.sound.tint
        GeometryReader { geometry in
            let plot = CGRect(
                x: Self.horizontalInset,
                y: 6,
                width: max(geometry.size.width - Self.horizontalInset * 2, 1),
                height: Self.plotHeight - 12
            )
            let points = Self.points(for: bands, in: plot)
            ZStack(alignment: .topLeading) {
                grid(in: plot)

                Self.curvePath(points: points, fillTo: plot.maxY + 6)
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.32), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                Self.curvePath(points: points, fillTo: nil)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

                ForEach(points.indices, id: \.self) { index in
                    let isActive = index == activeBand
                    Circle()
                        .fill(isActive ? tint : appearance.primary.opacity(0.9))
                        .frame(width: isActive ? 14 : 6, height: isActive ? 14 : 6)
                        .shadow(color: isActive ? tint.opacity(0.5) : .clear, radius: 6)
                        .position(points[index])
                    if isActive {
                        Text(verbatim: Self.gainLabel(bands[index]))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(appearance.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .position(x: points[index].x, y: max(points[index].y - 20, 8))
                    }
                }

                ForEach(eq.bandFrequencyLabels.indices, id: \.self) { index in
                    Text(verbatim: eq.bandFrequencyLabels[index])
                        .font(.system(size: 9, weight: index == activeBand ? .bold : .medium).monospacedDigit())
                        .foregroundStyle(index == activeBand ? appearance.primary : appearance.tertiary)
                        .fixedSize()
                        .position(x: points.indices.contains(index) ? points[index].x : 0, y: Self.plotHeight + Self.labelHeight / 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(plot: plot, count: bands.count))
        }
        .frame(height: Self.plotHeight + Self.labelHeight)
        .animation(.easeOut(duration: 0.12), value: activeBand)
        .nowPlayingCarouselHorizontalRegion()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("eq_preset"))
        .accessibilityValue(Text(verbatim: eq.currentPreset.localizedName))
    }

    private func grid(in plot: CGRect) -> some View {
        Path { path in
            for fraction in [0.0, 0.25, 0.75, 1.0] {
                let y = plot.minY + plot.height * fraction
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
        }
        .stroke(appearance.primary.opacity(0.06), lineWidth: 0.5)
        .overlay {
            Path { path in
                path.move(to: CGPoint(x: plot.minX, y: plot.midY))
                path.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
            }
            .stroke(appearance.primary.opacity(0.22), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
    }

    private func drag(plot: CGRect, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let band: Int
                if let activeBand {
                    band = activeBand
                } else {
                    band = Self.nearestBand(x: value.startLocation.x, in: plot, count: count)
                    activeBand = band
                    reportsControlEditing(true)
                }
                let normalized = 1 - Float((value.location.y - plot.minY) / plot.height)
                let clamped = min(max(normalized, 0), 1)
                let gain = Self.range.lowerBound + clamped * (Self.range.upperBound - Self.range.lowerBound)
                // 半分贝一档;靠近 0 时吸到 0,拖回平直容易。
                var snapped = (gain * 2).rounded() / 2
                if abs(snapped) < 0.6 { snapped = 0 }
                if snapped != eq.bands[band] { eq.setBand(band, gain: snapped) }
            }
            .onEnded { _ in
                activeBand = nil
                reportsControlEditing(false)
            }
    }

    private static func nearestBand(x: CGFloat, in plot: CGRect, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let fraction = (x - plot.minX) / plot.width
        return min(max(Int((fraction * CGFloat(count - 1)).rounded()), 0), count - 1)
    }

    private static func points(for bands: [Float], in plot: CGRect) -> [CGPoint] {
        guard bands.count > 1 else { return [] }
        let span = range.upperBound - range.lowerBound
        return bands.enumerated().map { index, gain in
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(bands.count - 1)
            let normalized = CGFloat((gain - range.lowerBound) / span)
            return CGPoint(x: x, y: plot.maxY - plot.height * normalized)
        }
    }

    /// 经过相邻点中点的二次曲线,和预设卡上的缩略曲线同一种画法。
    private static func curvePath(points: [CGPoint], fillTo: CGFloat?) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            if let fillTo {
                path.move(to: CGPoint(x: first.x, y: fillTo))
                path.addLine(to: first)
            } else {
                path.move(to: first)
            }
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let middle = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: middle, control: previous)
            }
            path.addLine(to: last)
            if let fillTo {
                path.addLine(to: CGPoint(x: last.x, y: fillTo))
                path.closeSubpath()
            }
        }
    }

    private static func gainLabel(_ gain: Float) -> String {
        gain == 0 ? "0 dB" : String(format: "%+.1f dB", gain)
    }
}

/// 预设一条:内置的、自己存的、自定义曲线,横着滑。
private struct NowPlayingCarouselEQPresetStrip: View {
    let eq: EqualizerService
    let appearance: NowPlayingAppearance

    var body: some View {
        let presets = EQPreset.builtInPresets + eq.userPresets + [eq.customPreset]
        let selectedID = eq.currentPreset.id
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        let isSelected = preset.id == selectedID && eq.isEnabled
                        Button {
                            if !eq.isEnabled { eq.setEnabled(true) }
                            eq.applyPreset(preset)
                        } label: {
                            Text(verbatim: preset.localizedName)
                                .font(.footnote.weight(isSelected ? .semibold : .medium))
                                .lineLimit(1)
                                .foregroundStyle(isSelected ? (appearance.isLight ? Color.white : Color.black) : appearance.primary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(isSelected ? appearance.primary : appearance.primary.opacity(0.1))
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.pmPressable)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(preset.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .nowPlayingCarouselHorizontalRegion()
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            .onChange(of: selectedID) { _, id in
                pmWithAnimation(.selection) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

// MARK: - 音效

/// 音效卡:混响、压缩各一行开关,开关下面是强度滑杆。混响的强度是干湿比,压缩的强度在轻、中、重三档之间走。
private struct NowPlayingCarouselEffectsCard: View {
    let appearance: NowPlayingAppearance

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.nowPlayingCarouselControlEditing) private var reportsControlEditing

    var body: some View {
        @Bindable var effects = player.audioEffectsService
        NowPlayingCarouselCardContainer(card: .audioEffects, appearance: appearance) {
            VStack(alignment: .leading, spacing: 14) {
                effectRow(
                    symbol: "building.columns",
                    title: "reverb",
                    isOn: $effects.reverbEnabled.pmAnimated(.control)
                ) {
                    // 关着的时候挑一种房间就顺手打开,和设置页点预设格子一样。
                    Menu {
                        Picker(selection: Binding(
                            get: { effects.reverbPreset },
                            set: { preset in
                                effects.reverbPreset = preset
                                if !effects.reverbEnabled {
                                    pmWithAnimation(.control) { effects.reverbEnabled = true }
                                }
                            }
                        )) {
                            ForEach(ReverbPreset.allCases) { preset in
                                Text(verbatim: preset.localizedName).tag(preset)
                            }
                        } label: {
                            Text("reverb")
                        }
                        .pickerStyle(.inline)
                    } label: {
                        chip(effects.reverbPreset.localizedName)
                    }
                    .accessibilityLabel(Text("reverb"))
                    .accessibilityValue(Text(verbatim: effects.reverbPreset.localizedName))
                } slider: {
                    sliderRow(
                        value: $effects.reverbWetDryMix,
                        range: 0...100,
                        step: 1,
                        valueText: "\(Int(effects.reverbWetDryMix))%",
                        isEnabled: effects.reverbEnabled
                    )
                }

                Divider().overlay(appearance.primary.opacity(0.06))

                effectRow(
                    symbol: "gauge.with.dots.needle.50percent",
                    title: "compressor_enabled",
                    isOn: $effects.compressorEnabled.pmAnimated(.control)
                ) {
                    chip(compressorTitle(effects.compressorPresetId))
                } slider: {
                    sliderRow(
                        value: Binding(
                            get: { Float(Self.compressorIndex(effects.compressorPresetId)) },
                            set: { value in
                                let index = min(max(Int(value.rounded()), 0), CompressorPreset.allPresets.count - 1)
                                let preset = CompressorPreset.allPresets[index]
                                guard preset.id != effects.compressorPresetId else { return }
                                effects.applyCompressorPreset(preset)
                            }
                        ),
                        range: 0...Float(CompressorPreset.allPresets.count - 1),
                        step: 1,
                        valueText: compressorTitle(effects.compressorPresetId),
                        isEnabled: effects.compressorEnabled
                    )
                }

                if let lowered = effects.reverbHeadroomNoteDB {
                    Text("reverb_headroom_note \(String(format: "%.1f", lowered))")
                        .font(.caption)
                        .foregroundStyle(appearance.tertiary)
                }
            }
        }
    }

    private func effectRow<Chip: View, SliderContent: View>(
        symbol: String,
        title: LocalizedStringKey,
        isOn: Binding<Bool>,
        @ViewBuilder chip: () -> Chip,
        @ViewBuilder slider: () -> SliderContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appearance.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
                chip()
                Spacer(minLength: 6)
                Toggle(isOn: isOn) { Text(title) }
                    .labelsHidden()
                    .tint(NowPlayingCarouselPanel.sound.tint)
            }
            slider()
        }
    }

    private func chip(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: title)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(appearance.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(appearance.primary.opacity(0.08)))
    }

    private func sliderRow(
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        valueText: String,
        isEnabled: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step, onEditingChanged: reportsControlEditing)
                .tint(NowPlayingCarouselPanel.sound.tint)
                .nowPlayingCarouselHorizontalRegion()
            Text(verbatim: valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(appearance.secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.leading, 32)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private static func compressorIndex(_ presetID: String?) -> Int {
        CompressorPreset.allPresets.firstIndex { $0.id == presetID } ?? 1
    }

    private func compressorTitle(_ presetID: String?) -> String {
        CompressorPreset.allPresets.first { $0.id == presetID }?.localizedName
            ?? String(localized: "player_carousel_custom")
    }
}

// MARK: - 速度与音调

/// 速度与音调:两颗步进,一键还原。高保真直通时不能变速、变调,就地说明并给一键切到音效输出。
private struct NowPlayingCarouselSpeedPitchCard: View {
    let appearance: NowPlayingAppearance

    @Environment(AudioPlayerService.self) private var player
    @Environment(PlaybackSettingsStore.self) private var playbackSettings

    var body: some View {
        let canChangeRate = playbackSettings.outputMode == .effects
        let rate = Double(playbackSettings.playbackRate)
        let pitch = playbackSettings.pitchSemitones
        let pitchAvailability = PlaybackPitchPolicy.availability(
            isSpokenWord: player.currentItemIsSpokenWord,
            isLiveRadio: player.isLiveRadio,
            isAppleMusic: player.isAppleMusicMode,
            isCasting: player.castingRenderer != nil,
            isHighFidelityOutput: player.outputMode(for: player.currentSong) == .highFidelity
        )
        let pitchChoices = PlaybackPitchPolicy.choices.map(Double.init)
        let isChanged = abs(rate - 1) > 0.001 || pitch != 0

        NowPlayingCarouselCardContainer(card: .speedAndPitch, appearance: appearance) {
            Button {
                pmWithAnimation(.control) {
                    playbackSettings.playbackRate = 1
                    playbackSettings.pitchSemitones = 0
                }
            } label: {
                Label("player_carousel_reset_short", systemImage: "arrow.counterclockwise")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(appearance.primary.opacity(0.1)))
            }
            .buttonStyle(.pmPressable)
            .disabled(!isChanged)
            .opacity(isChanged ? 1 : 0.4)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                stepperRow(
                    symbol: "speedometer",
                    title: "playback_rate",
                    value: Self.rateLabel(rate),
                    canDecrease: canChangeRate && NowPlayingCarouselStepper.canStep(rate, by: -1, in: NowPlayingCarouselStepper.playbackRates),
                    canIncrease: canChangeRate && NowPlayingCarouselStepper.canStep(rate, by: 1, in: NowPlayingCarouselStepper.playbackRates)
                ) { delta in
                    let next = NowPlayingCarouselStepper.step(rate, by: delta, in: NowPlayingCarouselStepper.playbackRates)
                    playbackSettings.playbackRate = Float(next)
                }

                if pitchAvailability != .notOffered {
                    stepperRow(
                        symbol: PlaybackPitchText.symbol,
                        title: "karaoke_key",
                        value: PlaybackPitchText.valueLabel(pitch),
                        canDecrease: pitchAvailability == .available && NowPlayingCarouselStepper.canStep(Double(pitch), by: -1, in: pitchChoices),
                        canIncrease: pitchAvailability == .available && NowPlayingCarouselStepper.canStep(Double(pitch), by: 1, in: pitchChoices)
                    ) { delta in
                        let next = NowPlayingCarouselStepper.step(Double(pitch), by: delta, in: pitchChoices)
                        playbackSettings.pitchSemitones = Int(next.rounded())
                    }
                }

                if !canChangeRate {
                    NowPlayingCarouselCardNotice(
                        message: String(localized: "eq_menu_high_fidelity_unavailable"),
                        actionTitle: "eq_use_effects_output",
                        appearance: appearance
                    ) {
                        playbackSettings.outputMode = .effects
                    }
                } else if pitchAvailability == .casting, let reason = PlaybackPitchText.shortReason(pitchAvailability) {
                    NowPlayingCarouselCardNotice(message: reason, appearance: appearance)
                }
            }
        }
    }

    private func stepperRow(
        symbol: String,
        title: LocalizedStringKey,
        value: String,
        canDecrease: Bool,
        canIncrease: Bool,
        step: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(appearance.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.primary)
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                stepButton(symbol: "minus", isEnabled: canDecrease) { step(-1) }
                Text(verbatim: value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(appearance.primary)
                    .frame(minWidth: 58)
                    .contentTransition(.numericText())
                stepButton(symbol: "plus", isEnabled: canIncrease) { step(1) }
            }
            .background(Capsule().fill(appearance.primary.opacity(0.08)))
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if canIncrease { step(1) }
            case .decrement: if canDecrease { step(-1) }
            @unknown default: break
            }
        }
    }

    private func stepButton(symbol: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            pmWithAnimation(.control, action)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(appearance.primary.opacity(isEnabled ? 1 : 0.3))
                .frame(width: 38, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private static func rateLabel(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

// MARK: - 输出与音质

/// 输出与音质:现在从哪儿出声(点 AirPlay 换设备,本机的歌还能投放),这首的音质规格与回放增益(点开看歌曲信息)。
private struct NowPlayingCarouselOutputCard: View {
    let appearance: NowPlayingAppearance
    let onShowSongInfo: () -> Void
    let onShowCastPicker: () -> Void

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        NowPlayingCarouselCardContainer(card: .outputAndQuality, appearance: appearance) {
            VStack(alignment: .leading, spacing: 12) {
                outputRow
                Divider().overlay(appearance.primary.opacity(0.06))
                qualityRow
            }
        }
    }

    private var outputRow: some View {
        let device = player.equalizerService.currentOutputDevice
        let castingName = player.castingRenderer?.friendlyName
        return HStack(spacing: 12) {
            Image(systemName: castingName != nil ? "hifispeaker.fill" : (device?.kind.eqSymbolName ?? "speaker.wave.2"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(NowPlayingCarouselPanel.sound.tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(NowPlayingCarouselPanel.sound.tint.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(castingName != nil ? LocalizedStringKey("player_carousel_casting_to") : LocalizedStringKey("eq_device_current"))
                    .font(.caption)
                    .foregroundStyle(appearance.secondary)
                Text(verbatim: castingName ?? device?.eqDisplayName ?? String(localized: "eq_device_kind_builtin"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            AirPlayButton()
                .frame(width: 36, height: 36)
                .accessibilityLabel(Text("player_controls_action_airplay"))

            if !player.isAppleMusicMode {
                Button(action: onShowCastPicker) {
                    Image(systemName: "hifispeaker")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appearance.primary.opacity(castingName != nil ? 1 : 0.6))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pmPressable)
                .accessibilityLabel(Text("cast_to_device"))
            }
        }
    }

    @ViewBuilder
    private var qualityRow: some View {
        if let song = player.currentSong {
            let quality = Self.quality(for: song, plan: player.activeTranscodePlan)
            let replayGain = player.replayGainPlaybackInfo
            Button(action: onShowSongInfo) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appearance.secondary)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: quality.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(appearance.primary)
                            .lineLimit(1)
                        if !quality.spec.isEmpty {
                            Text(verbatim: quality.spec)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(appearance.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if replayGain.showsBadge {
                        ReplayGainBadge(info: replayGain, song: song, tint: appearance.secondary)
                    }
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(appearance.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pmPressable)
            .accessibilityHint(Text("song_info"))
        }
    }

    /// 标题写等级(Apple Music 写它给的档位,转码流写「服务器转码」),下面一行是规格。
    private static func quality(for song: Song, plan: SourceTranscodePlan) -> (title: String, spec: String) {
        if let stream = NowPlayingAudioInfoTextPolicy.transcodedStream(plan: plan, sourceSampleRate: song.sampleRate) {
            return (String(localized: "now_playing_audio_transcoded"), stream.specParts.joined(separator: " · "))
        }
        let title: String
        if let variants = song.audioVariants, !variants.isEmpty, let tier = variants.bestLosslessTier {
            title = PMString(tier.localizationKey)
        } else {
            title = song.audioQuality.displayName
        }
        var parts = NowPlayingAudioInfoTextPolicy.specParts(
            formatName: song.codecFormat.displayName,
            sampleRate: song.sampleRate,
            bitDepth: song.qualityBitDepth,
            bitRate: song.bitRate,
            isDSD: song.audioQuality == .dsd
        )
        if song.audioVariants?.offersDolbyAtmos == true {
            parts.append(PMString(AudioVariant.dolbyAtmos.localizationKey))
        }
        return (title, parts.joined(separator: " · "))
    }
}
#endif
