#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

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

/// 均衡器卡:频响曲线可以直接调(横着扫过几段、或按住片刻再上下拖),预设收在标题行的小胶囊里,
/// 卡片不必再多一行横排预设。频段与预设逻辑都是设置里那一套(`EqualizerService`)。
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
            contentPadding: false
        ) {
            HStack(spacing: 10) {
                NowPlayingCarouselEQPresetMenu(eq: eq, appearance: appearance)
                Toggle(isOn: Binding(get: { eq.isEnabled }, set: { eq.setEnabled($0) }).pmAnimated(.control)) {
                    Text("eq_enabled")
                }
                .labelsHidden()
                .tint(NowPlayingCarouselPanel.sound.tint)
            }
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

/// 频响曲线:十个频段连成一条平滑曲线,底下是频率。曲线在能上下滚的一面里,所以竖着起手的一划只是滚动;
/// 横着起手时手指扫到哪一段就调哪一段,按住片刻再拖时只调按下的那一段,增益都跟着手指的高度
/// (起手规则见 `NowPlayingCarouselEQGesturePolicy`)。调着的时候告诉转轮别翻页。
private struct NowPlayingCarouselEQCurve: View {
    let eq: EqualizerService
    let appearance: NowPlayingAppearance

    @Environment(\.nowPlayingCarouselControlEditing) private var reportsControlEditing
    @State private var activeBand: Int?
    @State private var start: NowPlayingCarouselEQGesturePolicy.Start?
    @State private var holdFeedback = 0

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
            .gesture(NowPlayingCarouselEQCurveGesture { event in
                handle(event, plot: plot, count: bands.count)
            })
        }
        .frame(height: Self.plotHeight + Self.labelHeight)
        .animation(.easeOut(duration: 0.12), value: activeBand)
        .sensoryFeedback(.impact(weight: .light), trigger: holdFeedback)
        .sensoryFeedback(.selection, trigger: activeBand) { old, new in
            old != nil && new != nil
        }
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

    private func handle(_ event: NowPlayingCarouselEQCurveGesture.Event, plot: CGRect, count: Int) {
        switch event {
        case .began(let kind, let location):
            start = kind
            reportsControlEditing(true)
            if kind == .hold { holdFeedback &+= 1 }
            adjust(at: location, plot: plot, count: count, picksBand: true)
        case .changed(let location):
            // 按住起手的只调按下的那一段;横着扫的跟着手指换段。
            adjust(at: location, plot: plot, count: count, picksBand: start == .sweep || activeBand == nil)
        case .ended:
            guard start != nil || activeBand != nil else { return }
            start = nil
            activeBand = nil
            reportsControlEditing(false)
        }
    }

    private func adjust(at location: CGPoint, plot: CGRect, count: Int, picksBand: Bool) {
        typealias Policy = NowPlayingCarouselEQGesturePolicy
        guard count > 0 else { return }
        let band = picksBand || activeBand == nil
            ? Policy.band(atX: Double(location.x), plotMinX: Double(plot.minX), plotWidth: Double(plot.width), count: count)
            : (activeBand ?? 0)
        if activeBand != band { activeBand = band }
        let gain = Policy.gain(
            atY: Double(location.y),
            plotMinY: Double(plot.minY),
            plotHeight: Double(plot.height),
            minimum: Self.range.lowerBound,
            maximum: Self.range.upperBound
        )
        if eq.bands.indices.contains(band), gain != eq.bands[band] { eq.setBand(band, gain: gain) }
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

/// 标题行里的预设胶囊:内置的、自己存的、自定义曲线,点开一列挑。均衡器关着时挑一个就顺手打开。
private struct NowPlayingCarouselEQPresetMenu: View {
    let eq: EqualizerService
    let appearance: NowPlayingAppearance

    var body: some View {
        let presets = EQPreset.builtInPresets + eq.userPresets + [eq.customPreset]
        Menu {
            Picker(selection: Binding(
                get: { eq.currentPreset.id },
                set: { id in
                    guard let preset = presets.first(where: { $0.id == id }) else { return }
                    if !eq.isEnabled { eq.setEnabled(true) }
                    eq.applyPreset(preset)
                }
            )) {
                ForEach(presets) { preset in
                    Text(verbatim: preset.localizedName).tag(preset.id)
                }
            } label: {
                Text("eq_preset")
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: eq.currentPreset.localizedName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(eq.isEnabled ? appearance.primary : appearance.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(appearance.primary.opacity(eq.isEnabled ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .accessibilityLabel(Text("eq_preset"))
        .accessibilityValue(Text(verbatim: eq.currentPreset.localizedName))
    }
}

/// 曲线上的手势,用 UIKit 识别器做:竖着起手时立刻放弃,整面照常滚动;横着起手或按住片刻才接手,
/// 接手后整面的滚动让路。起手怎么判见 `NowPlayingCarouselEQGesturePolicy`。
private struct NowPlayingCarouselEQCurveGesture: UIGestureRecognizerRepresentable {
    enum Event {
        /// 开始调;位置在曲线自己的坐标里。
        case began(NowPlayingCarouselEQGesturePolicy.Start, CGPoint)
        case changed(CGPoint)
        /// 松手、被打断,或者这一下没调成。
        case ended
    }

    let onEvent: @MainActor (Event) -> Void

    func makeUIGestureRecognizer(context: Context) -> NowPlayingCarouselEQCurveRecognizer {
        let recognizer = NowPlayingCarouselEQCurveRecognizer()
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: NowPlayingCarouselEQCurveRecognizer, context: Context) {
        let location = context.converter.localLocation
        switch recognizer.state {
        case .began:
            onEvent(.began(recognizer.start ?? .hold, location))
        case .changed:
            onEvent(.changed(location))
        case .ended, .cancelled, .failed:
            onEvent(.ended)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// 整面的竖向滚动等曲线先表态:竖着起手时曲线马上放弃,滚动照常起步;横着起手或按住时滚动不动。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let scrollView = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scrollView.panGestureRecognizer
        }
    }
}

/// 起手前一直停在 `.possible`:手指挪出容差那一下按方向认(横着就开始、竖着就放弃),
/// 一直没挪出容差、按够了时长也开始。第二根手指落下(双指张开进全屏)时让出去。
private final class NowPlayingCarouselEQCurveRecognizer: UIGestureRecognizer {
    private(set) var start: NowPlayingCarouselEQGesturePolicy.Start?
    private var startPoint: CGPoint = .zero
    private var startTimestamp: TimeInterval = 0
    private var holdTask: Task<Void, Never>?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard (event.allTouches?.count ?? touches.count) == 1, let touch = touches.first, let view else {
            finish(cancelled: true)
            return
        }
        startPoint = touch.location(in: view)
        startTimestamp = touch.timestamp
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NowPlayingCarouselEQGesturePolicy.holdDuration))
            guard let self, !Task.isCancelled, self.state == .possible else { return }
            self.start = .hold
            self.state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let view else { return }
        switch state {
        case .possible:
            let point = touch.location(in: view)
            let decision = NowPlayingCarouselEQGesturePolicy.decision(
                translationX: Double(point.x - startPoint.x),
                translationY: Double(point.y - startPoint.y),
                heldFor: touch.timestamp - startTimestamp
            )
            switch decision {
            case .undecided:
                break
            case .begin(let kind):
                holdTask?.cancel()
                start = kind
                state = .began
            case .yield:
                holdTask?.cancel()
                state = .failed
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finish(cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finish(cancelled: true)
    }

    override func reset() {
        super.reset()
        holdTask?.cancel()
        holdTask = nil
        start = nil
    }

    private func finish(cancelled: Bool) {
        holdTask?.cancel()
        switch state {
        case .began, .changed:
            state = cancelled ? .cancelled : .ended
        case .possible:
            state = .failed
        default:
            break
        }
    }
}

// MARK: - 音效

/// 音效卡:混响、压缩各一行开关,开着时下面多一条强度滑杆。混响的强度是干湿比,压缩的强度在轻、中、重三档之间走。
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

    /// 强度滑杆只在开着时出现:关着的效果只占一行,整张卡短一截。
    @ViewBuilder
    private func sliderRow(
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        valueText: String,
        isEnabled: Bool
    ) -> some View {
        if isEnabled {
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
            .transition(.opacity.combined(with: .offset(y: -6)))
        }
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
