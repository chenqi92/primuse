@preconcurrency import Metal
@preconcurrency import MetalKit
import PrimuseKit
import QuartzCore
import SwiftUI

// 「动态歌词」的编排与 Metal 背景：导演按这首歌挑好场景、镜头、强调与机位，每帧把频谱（读不到时用歌词的
// 字头）换成场景里的动静；背景是一个 MTKView，跑 `ImmersiveKineticShaderSource` 里对应场景的片元函数。

// MARK: - 导演

/// 一首歌的编排和此刻的动静。舞台按 @State 持有一个，背景和歌词两边每帧都来问，同一帧只算一次。
@MainActor
final class ImmersiveKineticDirector {
    struct LineMove: Equatable {
        var transition: ImmersiveKineticTransition
        /// 甩镜从哪边进来：1 从右往左，-1 从左往右。
        var side: Double
    }

    /// 逐行歌词的每个字什么时候亮。
    enum LineTiming {
        /// 跟着声音里的起音亮（有频谱时）。
        case rhythm
        /// 整句一起亮（读不到频谱时）。
        case wholeLine
    }

    private(set) var direction = ImmersiveKineticDirectionPolicy.direction(title: "", artist: "", album: "", genre: "")
    /// 机位一直平视（取证：Mac 窗口截图拍不出 3D 变换，看版式时用 `PRIMUSE_DEBUG_KINETIC=…,camera=level`）。
    private(set) var holdsLevelCamera = false
    private(set) var seedUnit = 0.0
    private var songSeed: UInt64 = 0
    private var directionKey: String?
    private var conductor = ImmersiveKineticConductor(seed: 1)
    private var drive = ImmersiveKineticDrive()
    private var lastUpdate = -Double.infinity
    private var lineMoves: [String: LineMove] = [:]
    private var lineTimings: [String: LineTiming] = [:]
    /// 听到起音的播放时间（升序，最近 30 秒）：逐行歌词按它定每个字什么时候亮。
    private var onsetTimes: [TimeInterval] = []
    private let epoch = CACurrentMediaTime()

    /// 舞台每次重算时更新：频谱（不建立观察的那份）、播放进度、台上这几句的字头。
    var levelsProvider: @MainActor () -> [CGFloat] = { [] }
    var playbackTime: @MainActor () -> TimeInterval? = { nil }
    var lyricOnsets: [TimeInterval] = []

    /// 场景时钟：从这个导演建起来算的秒数。着色器里用 float，开机以来的秒数太大，动画会一跳一跳。
    var sceneTime: TimeInterval { CACurrentMediaTime() - epoch }

    /// 换歌时按新歌重挑编排，之前记下的每句镜头作废。
    func prepare(for track: ImmersiveStageTrack) {
        let key = "\(track.title)\u{1F}\(track.artist)\u{1F}\(track.album)"
        guard key != directionKey else { return }
        directionKey = key
        var chosen = ImmersiveKineticDirectionPolicy.direction(
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre
        )
        #if DEBUG
        Self.applyDebugOverride(to: &chosen)
        holdsLevelCamera = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_KINETIC"]?.contains("camera=level") == true
        #endif
        direction = chosen
        let seed = ImmersiveRandom.seed(for: key)
        songSeed = seed
        seedUnit = Double(seed % 10_000) / 10_000
        // 接着上一首的里程与落点：换歌时旧场景还要淡出一会儿，不能一下跳回起点。
        conductor = ImmersiveKineticConductor(seed: seed, continuing: drive, at: sceneTime)
        lineMoves.removeAll()
        lineTimings.removeAll()
        onsetTimes.removeAll()
        lastUpdate = -Double.infinity
    }

    /// 背景最近一帧算出的动静，不重新计算、不读频谱：歌词跟着鼓点往前顶一下用它，在 body 里读也不会登记观察。
    var latestDrive: ImmersiveKineticDrive { drive }

    /// 这一帧的动静；同一帧里第二次来问直接给上次的结果。会读频谱，只在背景的绘制回调里调：在 SwiftUI 的
    /// body 里读会登记观察，每发布一次频谱歌词就多画一遍。
    func currentDrive() -> ImmersiveKineticDrive {
        let now = sceneTime
        guard now - lastUpdate > 0.004 else { return drive }
        lastUpdate = now
        let playback = playbackTime()
        drive = conductor.update(
            levels: levelsProvider().map(Double.init),
            lyricOnsets: lyricOnsets,
            playbackTime: playback,
            at: now
        )
        if drive.onset > 0, let playback { recordOnset(at: playback) }
        return drive
    }

    private func recordOnset(at playback: TimeInterval) {
        // 往回拖过进度：之前记的起音不再算数。
        if let last = onsetTimes.last, playback < last - 0.5 { onsetTimes.removeAll() }
        onsetTimes.append(playback)
        if let first = onsetTimes.first, first < playback - 30 {
            onsetTimes.removeAll { $0 < playback - 30 }
        }
    }

    /// 从 `start` 起听到的起音（播放时间，升序）。
    func onsets(since start: TimeInterval) -> [TimeInterval] {
        onsetTimes.filter { $0 >= start - 0.05 }
    }

    /// 这句逐行歌词的字跟节奏亮还是整句亮：快开唱时按那会儿读不读得到频谱定下来，之后不变，免得唱到一半
    /// 亮着的字又暗回去。还没到时先按此刻的情况给，不记下（换歌后的头一下可能还没认出频谱）。
    func lineTiming(for line: ImmersiveStageLyric, at time: TimeInterval) -> LineTiming {
        let key = "\(line.id)|\(line.startTime ?? -1)"
        if let known = lineTimings[key] { return known }
        let timing: LineTiming = drive.hasSpectrum ? .rhythm : .wholeLine
        if let start = line.startTime, time >= start - 0.3 {
            if lineTimings.count > 64 { lineTimings.removeAll() }
            lineTimings[key] = timing
        }
        return timing
    }

    /// 一句用哪个镜头：第一次问到它时按当时是否在副歌里定下来，之后不变，免得换到一半换了镜头。平常两个镜头
    /// 一句一换，甩镜、旋入这类有方向的一句往左一句往右。看的是背景最近一帧算出的动静，不在这里读频谱。
    func move(for line: ImmersiveStageLyric) -> LineMove {
        let key = "\(line.id)|\(line.startTime ?? -1)"
        if let known = lineMoves[key] { return known }
        let transition = drive.isClimax ? direction.climaxTransition : direction.usualTransition(forLine: line.id)
        let move = LineMove(transition: transition, side: line.id.isMultiple(of: 2) ? 1 : -1)
        if lineMoves.count > 64 { lineMoves.removeAll() }
        lineMoves[key] = move
        return move
    }

    /// 这句里每个字唱到时的动作（`ImmersiveKineticLyricsPolicy.strikes`）：同一首歌里同一句每次都一样。
    func strikes(
        for line: ImmersiveStageLyric,
        tokens: [ImmersiveKineticLyricsPolicy.Token]
    ) -> [ImmersiveKineticLyricsPolicy.Strike] {
        let seed = songSeed ^ (UInt64(truncatingIfNeeded: line.id) &* 0x9E37_79B9_7F4A_7C15)
        return ImmersiveKineticLyricsPolicy.strikes(for: tokens, accent: direction.accent, seed: seed)
    }

    #if DEBUG
    /// 取证与实机截图用：`PRIMUSE_DEBUG_KINETIC=scene=rainGlass,transition=whipPan,alternate=cubeFlip,climax=iris,
    /// accent=ripple,staging=tilted,extrude=1`，只写要固定的那几项（只写 transition 时两个平常镜头都用它）。
    private static func applyDebugOverride(to direction: inout ImmersiveKineticDirection) {
        guard let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_KINETIC"], !raw.isEmpty else { return }
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "scene": if let value = ImmersiveKineticScene(rawValue: parts[1]) { direction.scene = value }
            case "transition":
                if let value = ImmersiveKineticTransition(rawValue: parts[1]) {
                    direction.transition = value
                    direction.alternateTransition = value
                }
            case "alternate": if let value = ImmersiveKineticTransition(rawValue: parts[1]) { direction.alternateTransition = value }
            case "extrude": direction.extruded = parts[1] == "1" || parts[1] == "true"
            case "climax": if let value = ImmersiveKineticTransition(rawValue: parts[1]) { direction.climaxTransition = value }
            case "accent": if let value = ImmersiveKineticAccent(rawValue: parts[1]) { direction.accent = value }
            case "staging": if let value = ImmersiveKineticStaging(rawValue: parts[1]) { direction.staging = value }
            default: break
            }
        }
        plog("🧪 Kinetic direction override: \(direction)")
    }
    #endif
}

// MARK: - 着色器参数

/// 逐字段对应着色器里的 `KineticUniforms`，全部是 float4。
struct ImmersiveKineticUniforms {
    var frame: SIMD4<Float> = .zero
    var drive: SIMD4<Float> = .zero
    var drive2: SIMD4<Float> = .zero
    var motion: SIMD4<Float> = .zero
    var colorA: SIMD4<Float> = .zero
    var colorB: SIMD4<Float> = .zero
    var extra: SIMD4<Float> = .zero
    var drive3: SIMD4<Float> = .zero
    var events: (
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
    ) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)

    mutating func setEvents(_ events: [ImmersiveKineticDrive.Event]) {
        var packed = [SIMD4<Float>](repeating: .zero, count: 8)
        for (index, event) in events.suffix(8).enumerated() {
            packed[index] = SIMD4(Float(event.x), Float(event.y), Float(event.time), Float(event.strength))
        }
        self.events = (packed[0], packed[1], packed[2], packed[3], packed[4], packed[5], packed[6], packed[7])
    }
}

// MARK: - 渲染器

/// 着色器整份源码只编一次（整个进程共用），每个场景的管线第一次用到时再建；都在后台做，没好之前画专辑色。
@MainActor
final class ImmersiveKineticRenderer: NSObject {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static var isAvailable: Bool { device != nil && !libraryFailed }

    private static var library: MTLLibrary?
    private static var libraryLoading = false
    private static var libraryFailed = false
    private static var pipelines: [ImmersiveKineticScene: MTLRenderPipelineState] = [:]
    private static var pipelinesLoading: Set<ImmersiveKineticScene> = []
    private static var readyCallbacks: [() -> Void] = []

    private let queue: MTLCommandQueue?
    var scene: ImmersiveKineticScene = .rainGlass
    var director: ImmersiveKineticDirector?
    var colorA = SIMD4<Float>(0.08, 0.49, 0.54, 1)
    var colorB = SIMD4<Float>(0.04, 0.27, 0.29, 1)
    var progress: @MainActor () -> Double = { 0 }
    var motionAmplitude: Float = 1
    /// 管线好了要重画一帧的那个画面（停着不动时也要换掉专辑色的底）。
    weak var view: MTKView?

    override init() {
        queue = Self.device?.makeCommandQueue()
        super.init()
    }

    func render(in view: MTKView) {
        guard let queue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let pipeline = pipeline(for: scene) {
            var uniforms = uniforms(size: view.drawableSize)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ImmersiveKineticUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func uniforms(size: CGSize) -> ImmersiveKineticUniforms {
        var uniforms = ImmersiveKineticUniforms()
        let drive = director?.currentDrive() ?? ImmersiveKineticDrive()
        let time = Float(director?.sceneTime ?? 0)
        uniforms.frame = SIMD4(Float(size.width), Float(size.height), time, Float(min(max(progress(), 0), 1)))
        uniforms.drive = SIMD4(Float(drive.energy), Float(drive.bass), Float(drive.pulse), Float(drive.intensity))
        uniforms.drive2 = SIMD4(
            Float(drive.sparkle),
            Float(drive.flash),
            Float(drive.climaxLevel),
            Float(director?.seedUnit ?? 0)
        )
        uniforms.drive3 = SIMD4(Float(drive.swell), Float(drive.flow), Float(drive.travelSpeed), 0)
        uniforms.motion = SIMD4(Float(drive.travel), Float(drive.flashSeed), motionAmplitude, 0)
        uniforms.colorA = colorA
        uniforms.colorB = colorB
        // 副歌里背景慢慢推近一点、一角亮起暖光，出副歌再慢慢回去。
        uniforms.extra = SIMD4(
            Float(ImmersiveKineticDirectionPolicy.warmGlow(climaxPush: drive.climaxPush)),
            0,
            Float(ImmersiveKineticDirectionPolicy.backgroundZoom(climaxPush: drive.climaxPush)),
            0
        )
        uniforms.setEvents(drive.events)
        return uniforms
    }

    private func pipeline(for scene: ImmersiveKineticScene) -> MTLRenderPipelineState? {
        if let ready = Self.pipelines[scene] { return ready }
        Self.prepare(scene) { [weak self] in self?.redraw() }
        return nil
    }

    private func redraw() {
        guard let view else { return }
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    /// 编源码、建这个场景的管线，都在后台；好了以后在主线程回调。
    private static func prepare(_ scene: ImmersiveKineticScene, ready: @escaping @MainActor @Sendable () -> Void) {
        guard let device, !libraryFailed else { return }
        guard let library else {
            readyCallbacks.append { prepare(scene, ready: ready) }
            guard !libraryLoading else { return }
            libraryLoading = true
            device.makeLibrary(source: ImmersiveKineticShaderSource.source, options: nil) { compiled, error in
                let box = ImmersiveKineticUncheckedBox(compiled)
                let message = error.map { "\($0)" }
                Task { @MainActor in
                    Self.libraryLoading = false
                    guard let compiled = box.value else {
                        plog("⚠️ Kinetic shaders failed to compile: \(message ?? "unknown")")
                        Self.libraryFailed = true
                        Self.readyCallbacks.removeAll()
                        return
                    }
                    Self.library = compiled
                    let callbacks = Self.readyCallbacks
                    Self.readyCallbacks.removeAll()
                    callbacks.forEach { $0() }
                    // 其余场景的管线也趁空建好：换歌换场景时不必等，画面不会先空一下。
                    for other in ImmersiveKineticScene.allCases {
                        prepare(other) {}
                    }
                }
            }
            return
        }
        guard pipelines[scene] == nil, !pipelinesLoading.contains(scene) else { return }
        pipelinesLoading.insert(scene)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: ImmersiveKineticShaderSource.vertexFunction)
        descriptor.fragmentFunction = library.makeFunction(name: ImmersiveKineticShaderSource.fragmentFunction(for: scene))
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        device.makeRenderPipelineState(descriptor: descriptor) { pipeline, error in
            let box = ImmersiveKineticUncheckedBox(pipeline)
            let message = error.map { "\($0)" }
            Task { @MainActor in
                Self.pipelinesLoading.remove(scene)
                guard let pipeline = box.value else {
                    plog("⚠️ Kinetic pipeline \(scene.rawValue) failed: \(message ?? "unknown")")
                    return
                }
                Self.pipelines[scene] = pipeline
                ready()
            }
        }
    }
}

/// 把 Metal 回调线程上拿到的对象原样交回主线程。编好的库和管线建好以后只读，跨线程用是安全的。
private final class ImmersiveKineticUncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// MTKView 的代理。MetalKit 在主线程上回调。
@MainActor
final class ImmersiveKineticViewDelegate: NSObject, MTKViewDelegate {
    let renderer: ImmersiveKineticRenderer

    init(renderer: ImmersiveKineticRenderer) {
        self.renderer = renderer
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            renderer.render(in: view)
        }
    }
}

/// 画布的像素数：背景都是柔和的东西，用不着按屏幕的整倍率画——最多按 `maximumScale` 倍，电视上只画 1080p。
final class ImmersiveKineticMTKView: MTKView {
    var maximumScale: CGFloat = 1.5 {
        didSet { updateDrawableSize() }
    }

    private var screenScale: CGFloat {
        #if os(macOS)
        window?.backingScaleFactor ?? 2
        #else
        traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        #endif
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        updateDrawableSize()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }
    #endif

    func updateDrawableSize() {
        let scale = min(screenScale, maximumScale)
        let size = CGSize(
            width: max((bounds.width * scale).rounded(), 1),
            height: max((bounds.height * scale).rounded(), 1)
        )
        if drawableSize != size { drawableSize = size }
    }
}

// MARK: - 视图

/// 「动态歌词」的背景。换歌换了场景时新旧两个场景叠着淡入淡出，不是一刀切过去。设备不支持 Metal、着色器
/// 编不过时退回原来那几团柔光。
struct ImmersiveKineticSceneBackdrop: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    @Environment(\.immersiveMotionIntensity) private var motion
    let scene: ImmersiveKineticScene
    let palette: ImmersiveArtworkPalette
    let director: ImmersiveKineticDirector
    let progress: @MainActor () -> Double
    let isAnimating: Bool

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_KINETIC_STILL"] == "1" {
                ImmersiveKineticCapturableBackdrop(
                    scene: scene,
                    palette: palette,
                    director: director,
                    progress: progress
                )
            } else {
                liveBackdrop
            }
            #else
            liveBackdrop
            #endif
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var liveBackdrop: some View {
        if ImmersiveKineticRenderer.isAvailable {
            ZStack {
                ImmersiveKineticMetalView(
                    scene: scene,
                    colorA: palette.primary,
                    colorB: palette.secondary,
                    director: director,
                    progress: progress,
                    isAnimating: isAnimating,
                    framesPerSecond: framesPerSecond,
                    motionAmplitude: Float(motion.amplitude)
                )
                .id(scene)
                .transition(.opacity)
            }
            .animation(.easeInOut(duration: 1.2), value: scene)
        } else {
            ImmersiveKineticBackdrop(palette: palette, isAnimating: isAnimating)
        }
    }

    /// 安静的场景一秒三十帧就够；冲得快的那几个（隧道、激光、网格路面、雷雨）按六十帧画，三十帧下细线一帧
    /// 跨一大截，看着一格一格跳。电视一律三十帧；帧率设成更高时按设定走。
    private var framesPerSecond: Int {
        let interval = (scene.isEnergetic
            ? frameRate.minimumInterval(fastBase: 1.0 / 60, televisionFloor: 1.0 / 30)
            : frameRate.minimumInterval(base: 1.0 / 30, televisionFloor: 1.0 / 30)) ?? (1.0 / 60)
        return max(Int((1 / max(interval, 1.0 / 120)).rounded()), 1)
    }
}

#if os(macOS)
private struct ImmersiveKineticMetalView: NSViewRepresentable {
    let scene: ImmersiveKineticScene
    let colorA: Color
    let colorB: Color
    let director: ImmersiveKineticDirector
    let progress: @MainActor () -> Double
    let isAnimating: Bool
    let framesPerSecond: Int
    let motionAmplitude: Float

    func makeCoordinator() -> ImmersiveKineticViewDelegate {
        ImmersiveKineticViewDelegate(renderer: ImmersiveKineticRenderer())
    }

    func makeNSView(context: Context) -> ImmersiveKineticMTKView {
        let view = ImmersiveKineticMTKView(frame: .zero, device: ImmersiveKineticRenderer.device)
        configure(view, context: context)
        view.delegate = context.coordinator
        context.coordinator.renderer.view = view
        view.layer?.isOpaque = true
        return view
    }

    func updateNSView(_ view: ImmersiveKineticMTKView, context: Context) {
        configure(view, context: context)
        if !isAnimating { view.needsDisplay = true }
    }

    private func configure(_ view: ImmersiveKineticMTKView, context: Context) {
        ImmersiveKineticMetalViewSetup.apply(
            to: view,
            renderer: context.coordinator.renderer,
            scene: scene,
            colorA: colorA,
            colorB: colorB,
            environment: context.environment,
            director: director,
            progress: progress,
            isAnimating: isAnimating,
            framesPerSecond: framesPerSecond,
            motionAmplitude: motionAmplitude
        )
    }
}
#else
private struct ImmersiveKineticMetalView: UIViewRepresentable {
    let scene: ImmersiveKineticScene
    let colorA: Color
    let colorB: Color
    let director: ImmersiveKineticDirector
    let progress: @MainActor () -> Double
    let isAnimating: Bool
    let framesPerSecond: Int
    let motionAmplitude: Float

    func makeCoordinator() -> ImmersiveKineticViewDelegate {
        ImmersiveKineticViewDelegate(renderer: ImmersiveKineticRenderer())
    }

    func makeUIView(context: Context) -> ImmersiveKineticMTKView {
        let view = ImmersiveKineticMTKView(frame: .zero, device: ImmersiveKineticRenderer.device)
        configure(view, context: context)
        view.delegate = context.coordinator
        context.coordinator.renderer.view = view
        #if os(tvOS)
        view.maximumScale = 1
        #endif
        view.isOpaque = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ImmersiveKineticMTKView, context: Context) {
        configure(view, context: context)
        if !isAnimating { view.setNeedsDisplay() }
    }

    private func configure(_ view: ImmersiveKineticMTKView, context: Context) {
        ImmersiveKineticMetalViewSetup.apply(
            to: view,
            renderer: context.coordinator.renderer,
            scene: scene,
            colorA: colorA,
            colorB: colorB,
            environment: context.environment,
            director: director,
            progress: progress,
            isAnimating: isAnimating,
            framesPerSecond: framesPerSecond,
            motionAmplitude: motionAmplitude
        )
    }
}
#endif

/// 两个平台共用的设置：交给渲染器这一帧要用的东西，停着时改成按需重画。
@MainActor
private enum ImmersiveKineticMetalViewSetup {
    static func apply(
        to view: ImmersiveKineticMTKView,
        renderer: ImmersiveKineticRenderer,
        scene: ImmersiveKineticScene,
        colorA: Color,
        colorB: Color,
        environment: EnvironmentValues,
        director: ImmersiveKineticDirector,
        progress: @escaping @MainActor () -> Double,
        isAnimating: Bool,
        framesPerSecond: Int,
        motionAmplitude: Float
    ) {
        renderer.scene = scene
        renderer.director = director
        renderer.progress = progress
        renderer.motionAmplitude = motionAmplitude
        renderer.colorA = vector(colorA, in: environment)
        renderer.colorB = vector(colorB, in: environment)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        let base = renderer.colorB * 0.3
        view.clearColor = MTLClearColor(red: Double(base.x), green: Double(base.y), blue: Double(base.z), alpha: 1)
        if view.preferredFramesPerSecond != framesPerSecond {
            view.preferredFramesPerSecond = framesPerSecond
        }
        // 停着时（减弱动态效果、省电、暂停）只在需要时画一帧，停在当下。
        view.enableSetNeedsDisplay = !isAnimating
        view.isPaused = !isAnimating
        view.updateDrawableSize()
    }

    private static func vector(_ color: Color, in environment: EnvironmentValues) -> SIMD4<Float> {
        let resolved = color.resolve(in: environment)
        return SIMD4(resolved.red, resolved.green, resolved.blue, 1)
    }
}

#if DEBUG
// MARK: - 取证

extension ImmersiveKineticRenderer {
    /// 离屏画一帧当成图片：窗口离屏截图（`snapshot:`）拍不到 Metal 图层，取证时背景改用这个。管线还没好时为 nil。
    func snapshot(size: CGSize) -> CGImage? {
        guard let device = Self.device, let queue else { return nil }
        guard let pipeline = pipeline(for: scene) else { return nil }
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = uniforms(size: CGSize(width: width, height: height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ImmersiveKineticUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// `PRIMUSE_DEBUG_KINETIC_STILL=1` 时的背景：每 0.1 秒离屏画一帧、当成图片显示，窗口截图拍得到。
private struct ImmersiveKineticCapturableBackdrop: View {
    @Environment(\.self) private var environment
    let scene: ImmersiveKineticScene
    let palette: ImmersiveArtworkPalette
    let director: ImmersiveKineticDirector
    let progress: @MainActor () -> Double
    @State private var renderer = ImmersiveKineticRenderer()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                if let image = frame(size: proxy.size) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                } else {
                    palette.secondary.opacity(0.3)
                }
            }
        }
    }

    private func frame(size: CGSize) -> CGImage? {
        renderer.scene = scene
        renderer.director = director
        renderer.progress = progress
        let a = palette.primary.resolve(in: environment)
        let b = palette.secondary.resolve(in: environment)
        renderer.colorA = SIMD4(a.red, a.green, a.blue, 1)
        renderer.colorB = SIMD4(b.red, b.green, b.blue, 1)
        return renderer.snapshot(size: size)
    }
}
#endif
