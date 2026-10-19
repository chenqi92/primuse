import SwiftUI
import PrimuseKit

/// 播放页背景「声音律动」(#312):在封面取色的色场上画一层跟着声音动的频谱、波形或星尘。
/// iPhone、iPad 与 Mac 的播放页共用,压在播放页那两层浅色 / 深色遮罩下面,字的可读性不靠这一层。
///
/// - 频谱来自 `AudioVisualizerService`。这一层自己持有一份租约:页面看得见、App 在前台、正在播放时才挂 tap,
///   别的时候放掉(最后一个持有者离开时服务才卸 tap)。全屏效果盖上来时播放页不算看得见,这里先放掉,
///   全屏页再按自己的帧率设置取。
/// - 发布节奏固定每秒 30 次(Mac 上 60 次),不跟全屏效果的「画面帧率」:Mac 上省电档一秒只有 10 个画面,柱子会一跳一跳。
/// - Apple Music、电台和 MV 不经过 App 的音频引擎,没有声音数据,这时整层不画,只剩色场。
/// - 暂停时原地停住;减弱动态效果、低电量模式、机身过热时不挂 tap、不动。最多每秒 30 帧(偏热时 15 帧),
///   Mac 上 60 帧(偏热时 30 帧)。
struct PlayerVisualizerBackdrop: View {
    let style: PlayerVisualizerStyle
    /// 封面主色与次色。深色外观拿它们当光,浅色外观拿 `deep` 当墨。
    let primary: Color
    let secondary: Color
    let deep: Color
    let isLight: Bool
    /// 0…1,设置里的「氛围强度」。
    let strength: Double
    let isVisible: Bool
    let isSceneActive: Bool

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioVisualizerService.self) private var visualizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ownerID = UUID()
    @State private var isHoldingLease = false
    /// 这首歌试过挂 tap 却挂不上(引擎没在跑、没有可挂的节点):整层收起,不画一排死掉的柱子。
    @State private var feedUnavailableSongID: String?
    @State private var retryTask: Task<Void, Never>?
    @State private var runtimeRevision: UInt = 0
    @State private var activeElapsed: TimeInterval = 0
    @State private var startedAt: Date?

    #if os(macOS)
    private static let pacing = ImmersiveFrameRateMode.fps60
    #else
    private static let pacing = ImmersiveFrameRateMode.fps30
    #endif

    var body: some View {
        let _ = runtimeRevision
        let moves = shouldListen
        // 频谱柱子每发布一次频谱就重画一次,用不着时间表;波形与星尘要连续走时间。
        TimelineView(.animation(minimumInterval: frameInterval, paused: !moves || style == .spectrum)) { context in
            let levels = isHoldingLease ? visualizer.bandLevels.map(Double.init) : []
            let time = elapsed(at: context.date)
            Canvas(rendersAsynchronously: true) { canvas, size in
                draw(in: &canvas, size: size, levels: levels, time: time)
            }
        }
        .opacity(hasFeed ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: hasFeed)
        .onAppear {
            updateClock(running: moves, at: .now)
            synchronizeLease()
        }
        .onChange(of: moves) { _, running in
            updateClock(running: running, at: .now)
            synchronizeLease()
        }
        .onChange(of: player.currentSong?.id) { _, _ in
            // 换歌可能重建音频图(采样率变了、切到直通),tap 要挂到新的节点上。
            synchronizeLease()
        }
        .onDisappear {
            updateClock(running: false, at: .now)
            releaseLease()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            runtimeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            runtimeRevision &+= 1
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 什么时候听、什么时候动

    private var shouldListen: Bool {
        guard isVisible, isSceneActive, player.isPlaying, hasFeed, !reduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return true
        default: return false
        }
    }

    /// 这首歌有没有声音数据可拿。Apple Music 与电台一开始就知道没有;别的要挂过才知道。
    private var hasFeed: Bool {
        guard !player.isAppleMusicMode, !player.isLiveRadio else { return false }
        guard let songID = player.currentSong?.id else { return false }
        return feedUnavailableSongID != songID
    }

    private var frameInterval: TimeInterval {
        #if os(macOS)
        // Mac 的屏幕多是 120Hz、多半插着电,波形与星尘按每秒 30 帧走看得出一格一格的。
        ProcessInfo.processInfo.thermalState == .fair ? 1.0 / 30 : 1.0 / 60
        #else
        ProcessInfo.processInfo.thermalState == .fair ? 1.0 / 15 : 1.0 / 30
        #endif
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
        visualizer.setPacing(Self.pacing.spectrumPacing(
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

    /// 只在动的时候累计时间:暂停、看不见时停在原处,接着从原处继续。
    private func updateClock(running: Bool, at date: Date) {
        if running {
            if startedAt == nil { startedAt = date }
        } else if let startedAt {
            activeElapsed += max(0, date.timeIntervalSince(startedAt))
            self.startedAt = nil
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return activeElapsed }
        return activeElapsed + max(0, date.timeIntervalSince(startedAt))
    }

    // MARK: 画

    /// 默认氛围强度 0.7 时为 1;调低变淡,调高最多再亮两成。
    private var intensity: Double {
        min(max(strength / 0.7, 0.35), 1.2)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, levels: [Double], time: TimeInterval) {
        guard size.width > 1, size.height > 1 else { return }
        switch style {
        case .spectrum: drawSpectrum(in: &canvas, size: size, levels: levels)
        case .waveform: drawWaveform(in: &canvas, size: size, levels: levels, time: time)
        case .stardust: drawStardust(in: &canvas, size: size, levels: levels, time: time)
        }
    }

    /// 底部一排柱子,低频在中间;深色外观柱子发一点光,底下一道淡淡的倒影。
    private func drawSpectrum(in canvas: inout GraphicsContext, size: CGSize, levels: [Double]) {
        let count = PlayerVisualizerGeometry.barCount(forWidth: size.width)
        let bars = PlayerVisualizerGeometry.barLevels(bands: levels, count: count)
        let gap = max(size.width * 0.006, 2)
        let width = max((size.width - gap * CGFloat(count + 1)) / CGFloat(count), 2)
        let maxHeight = size.height * 0.26
        let horizon = size.height
        var path = Path()
        for (index, level) in bars.enumerated() {
            let height = max(width * 0.5, maxHeight * CGFloat(0.03 + level * 0.97))
            let x = gap + CGFloat(index) * (width + gap)
            path.addPath(Path(
                roundedRect: CGRect(x: x, y: horizon - height, width: width, height: height + width),
                cornerRadius: width * 0.4
            ))
        }
        let top = CGPoint(x: 0, y: horizon - maxHeight)
        let bottom = CGPoint(x: 0, y: horizon)
        if isLight {
            canvas.fill(path, with: .linearGradient(
                Gradient(colors: [deep.opacity(0.30 * intensity), deep.opacity(0.10 * intensity)]),
                startPoint: top,
                endPoint: bottom
            ))
        } else {
            canvas.drawLayer { glow in
                glow.addFilter(.blur(radius: max(6, width)))
                glow.fill(path, with: .color(primary.opacity(0.40 * intensity)))
            }
            canvas.fill(path, with: .linearGradient(
                Gradient(colors: [
                    Color.white.opacity(0.42 * intensity),
                    primary.opacity(0.62 * intensity),
                    secondary.opacity(0.16 * intensity),
                ]),
                startPoint: top,
                endPoint: bottom
            ))
        }
    }

    /// 三道横贯画面的波形线,落在封面下沿到控件之间;最前面那道最粗最亮。
    private func drawWaveform(in canvas: inout GraphicsContext, size: CGSize, levels: [Double], time: TimeInterval) {
        let registers = PlayerVisualizerGeometry.registers(levels)
        let center = size.height * 0.68
        let amplitude = size.height * 0.11
        let steps = max(Int(size.width / 5), 48)
        let lines: [(width: CGFloat, opacity: Double, color: Color)] = [
            (1.0, 0.22, secondary),
            (1.6, 0.34, secondary),
            (2.6, 0.55, primary),
        ]
        for (line, spec) in lines.enumerated() {
            var path = Path()
            for step in 0...steps {
                let x = Double(step) / Double(steps)
                let offset = PlayerVisualizerGeometry.waveOffset(x: x, time: time, line: line, registers: registers)
                let point = CGPoint(x: CGFloat(x) * size.width, y: center + CGFloat(offset) * amplitude)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let stroke = StrokeStyle(lineWidth: spec.width, lineCap: .round, lineJoin: .round)
            if isLight {
                canvas.stroke(path, with: .color(deep.opacity(spec.opacity * 0.6 * intensity)), style: stroke)
            } else {
                if line == lines.count - 1 {
                    canvas.drawLayer { glow in
                        glow.addFilter(.blur(radius: 6))
                        glow.stroke(
                            path,
                            with: .color(spec.color.opacity(0.45 * intensity)),
                            style: StrokeStyle(lineWidth: spec.width * 3, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
                canvas.stroke(path, with: .color(spec.color.opacity(spec.opacity * intensity)), style: stroke)
            }
        }
    }

    /// 从底下往上飘的星尘,底部一团跟着低频明暗的光。
    private func drawStardust(in canvas: inout GraphicsContext, size: CGSize, levels: [Double], time: TimeInterval) {
        let registers = PlayerVisualizerGeometry.registers(levels)
        let energy = registers.energy
        let origin = CGPoint(x: size.width / 2, y: size.height)
        let glowRadius = max(size.width, size.height) * CGFloat(0.42 + registers.low * 0.18)
        let glowColor = isLight ? deep : primary
        canvas.fill(
            Path(ellipseIn: CGRect(
                x: origin.x - glowRadius,
                y: origin.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [
                    glowColor.opacity((isLight ? 0.10 : 0.16 + registers.low * 0.30) * intensity),
                    .clear,
                ]),
                center: origin,
                startRadius: 0,
                endRadius: glowRadius
            )
        )

        if !isLight { canvas.blendMode = .plusLighter }
        let count = size.width > 700 ? 140 : 90
        let unit = max(min(size.width, size.height) / 260, 1)
        let brightness = (isLight ? 0.30 : 0.30 + energy * 0.60) * intensity
        for index in 0..<count {
            let mote = PlayerVisualizerGeometry.mote(index: index, time: time, low: registers.low)
            guard mote.alpha > 0.01 else { continue }
            let point = CGPoint(x: CGFloat(mote.x) * size.width, y: CGFloat(mote.y) * size.height)
            let radius = CGFloat(mote.size) * unit
            let tint: Color = isLight ? deep : (index % 4 == 0 ? primary : Color.white)
            let alpha = mote.alpha * brightness
            if !isLight, index % 6 == 0 {
                let halo = radius * 3.2
                canvas.fill(
                    Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                    with: .radialGradient(
                        Gradient(colors: [tint.opacity(alpha * 0.45), .clear]),
                        center: point,
                        startRadius: 0,
                        endRadius: halo
                    )
                )
            }
            canvas.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(tint.opacity(alpha))
            )
        }
    }
}
