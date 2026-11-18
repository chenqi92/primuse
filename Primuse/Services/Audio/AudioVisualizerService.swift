import Accelerate
import AVFoundation
import Dispatch
import Foundation
import PrimuseKit

/// 实时音频频谱可视化器 —— 在 AudioEngine 的 mainMixerNode 上挂 tap, 拿到
/// 输出 buffer 做 FFT, 把 1024 点频谱压成 32 个频段强度发布给 UI。
///
/// **音频线程安全**:
/// tap callback 跑在音频实时线程, 严格限制只做 memcpy + trylock,
/// 不允许 Swift Array 分配 / 类型绑定 / FFT / MainActor hop ── 这些都会把
/// 音频线程拖慢甚至抢占,在 iOS 26 上会触发硬崩溃。FFT + 发布到 UI 全部
/// 在另起的 background Task 里跑。
///
/// **发布节奏**: tap 不管请求多大, 实测 macOS 都是 100 ms 才回调一次 (4800 帧)。
/// 整批写进采样环, 「省电」档每到一批分析最新一窗; 其余档由
/// `SpectrumPlayoutCursor` 在两批之间匀速推进读取位置, 按所选帧率发布。
///
/// 启停语义:
/// - iOS 沉浸式视图通过 owner lease 获取和释放频谱，最后一个 owner 离开时
///   才卸 tap，避免一个 inactive Scene 停掉另一个 active Scene 的频谱。
/// - `start(engine:on:)` / `stop()` 保留为单 owner 兼容入口。
@MainActor
@Observable
final class AudioVisualizerService {
    // nonisolated 让 detached Task 和 SwiftUI 视图都能直接读, 不用 hop main actor。
    nonisolated static let bandCount = 32
    nonisolated static let spectrumFFTExponent = 10
    /// 时间平滑系数是按「每 100 ms 分析一次」调出来的, 分析更勤时按真实间隔折算。
    nonisolated static let smoothingReferenceInterval: TimeInterval = 0.1

    /// 0...1 归一化的频段强度。bandLevels.count == bandCount 永远成立。
    /// UI 用 .animation(.linear(duration: 0.07), value: bandLevels) 即可平滑过渡。
    private(set) var bandLevels: [Float] = Array(repeating: 0, count: bandCount)

    enum Feed: Hashable { case spectrum, bassPulse }
    private(set) var bassPulse = PlayerBackdropBassPulse()

    private weak var engine: AVAudioEngine?
    private var tappedNode: AVAudioNode?
    private var ring: SpectrumSampleRing?
    private var sampleRate: Double = 0
    private var pacing = ImmersiveFrameRateMode.defaultValue
        .spectrumPacing(displayMaximumFramesPerSecond: 60)
    private var pollTask: Task<Void, Never>?
    private var owners: [UUID: Feed] = [:]
    private let compatibilityOwnerID = UUID()
    private var pollGeneration: UInt64 = 0

    func start(engine: AVAudioEngine, on node: AVAudioMixerNode) {
        _ = acquire(owner: compatibilityOwnerID, engine: engine, on: node)
    }

    func stop() {
        release(owner: compatibilityOwnerID)
    }

    /// 全屏页按「画面帧率」设置给出发布节奏；多个 owner 时以最后一次为准。
    func setPacing(_ value: SpectrumPublishPacing) {
        guard pacing != value else { return }
        pacing = value
        guard pollTask != nil else { return }
        startPolling()
    }

    @discardableResult
    func acquire(owner: UUID, engine: AVAudioEngine, on node: AVAudioNode, feed: Feed = .spectrum) -> Bool {
        guard engine.isRunning else { return false }

        if let currentEngine = self.engine,
           currentEngine === engine,
           tappedNode === node,
           pollTask != nil {
            if owners[owner] != feed {
                let previous = Set(owners.values)
                owners[owner] = feed
                if Set(owners.values) != previous { startPolling() }
            }
            return true
        }

        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            plog("⚠️ Visualizer skipped: invalid tap format sr=\(format.sampleRate) ch=\(format.channelCount)")
            return false
        }

        owners[owner] = feed
        stopPipeline()
        self.engine = engine
        let activeRing = SpectrumSampleRing()
        ring = activeRing

        // tap 闭包只 memcpy + trylock, 完全不 alloc 不 hop actor。
        AudioVisualizerTap.install(
            on: node,
            bufferSize: AVAudioFrameCount(1 << Self.spectrumFFTExponent),
            format: format,
            ring: activeRing
        )
        self.tappedNode = node
        sampleRate = format.sampleRate
        startPolling()
        return true
    }

    func release(owner: UUID) {
        guard let removed = owners.removeValue(forKey: owner) else { return }
        if owners.isEmpty {
            stopPipeline()
        } else if !owners.values.contains(removed) {
            startPolling()
        }
    }

    /// 用 detached Task 周期性取窗做 FFT, 跟音频线程完全解耦；落到 main actor
    /// 才更新 @Observable bandLevels。换节奏时整个任务连同分析器重建, 旧任务
    /// 可能还没退出, 两个任务不能共用一个分析器。
    private func startPolling() {
        pollTask?.cancel()
        pollGeneration &+= 1
        guard let ring = self.ring else { return }
        let generation = pollGeneration
        let sampleRate = self.sampleRate
        let pacing = self.pacing
        let spectrum = owners.values.contains(.spectrum)
            ? FFTAnalyzer(log2n: Self.spectrumFFTExponent, bandCount: Self.bandCount) : nil
        let bass = owners.values.contains(.bassPulse) ? FFTAnalyzer.forBass(sampleRate: sampleRate) : nil
        if bass == nil { bassPulse = PlayerBackdropBassPulse() }
        let initialPulse = bassPulse
        pollTask = Task.detached(priority: .userInitiated) { [weak self, ring] in
            var pulse = initialPulse
            var previousBassEnd: Int64?
            var cursor = SpectrumPlayoutCursor()
            var analyzedWritten: Int64 = 0
            let interval = Duration.seconds(pacing.pollInterval)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                let state = ring.state()
                let windowEnd: Int64
                var elapsed: TimeInterval?
                switch pacing {
                case .onArrival:
                    guard state.written > 0, state.written != analyzedWritten else { continue }
                    analyzedWritten = state.written
                    windowEnd = state.written
                case .paced:
                    guard let step = cursor.advance(
                        state: state,
                        nowUptime: DispatchTime.now().uptimeNanoseconds,
                        sampleRate: sampleRate
                    ) else { continue }
                    windowEnd = step.end
                    if step.advancedFrames > 0 {
                        elapsed = Double(step.advancedFrames) / sampleRate
                    }
                }
                let levels = spectrum.map {
                    $0.readWindow(from: ring, endingAt: windowEnd)
                    return $0.bandLevels(bandCount: Self.bandCount, sampleRate: sampleRate, elapsed: elapsed)
                }
                if let bass {
                    bass.readWindow(from: ring, endingAt: windowEnd)
                    let frames = previousBassEnd.map { windowEnd - $0 } ?? Int64(bass.size)
                    pulse.update(power: bass.bassPower(sampleRate: sampleRate), elapsed: Double(frames) / sampleRate)
                    previousBassEnd = windowEnd
                }
                let currentPulse = bass == nil ? nil : pulse
                await MainActor.run { [weak self] in
                    guard let self, self.pollGeneration == generation else { return }
                    if let levels { self.bandLevels = levels }
                    if let currentPulse { self.bassPulse = currentPulse }
                }
            }
        }
    }

    private func stopPipeline() {
        pollGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        if let node = tappedNode {
            node.removeTap(onBus: 0)
        }
        tappedNode = nil
        engine = nil
        ring = nil
        bassPulse = PlayerBackdropBassPulse()
        bandLevels = Array(repeating: 0, count: Self.bandCount)
    }
}

/// `installTap` must be created outside the `@MainActor` visualizer service.
/// Otherwise Swift can inherit MainActor isolation for the tap closure, and
/// AVAudioEngine will trip the iOS 26 concurrency runtime when it invokes the
/// closure on Core Audio's realtime queue.
private enum AudioVisualizerTap {
    static func install(
        on node: AVAudioNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        ring: SpectrumSampleRing
    ) {
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { audioBuffer, _ in
            // 第 0 声道整批写进采样环；锁忙就丢这一批, 不在音频线程上等。
            guard let channels = audioBuffer.floatChannelData else { return }
            ring.write(channels[0], frameCount: Int(audioBuffer.frameLength), stride: audioBuffer.stride)
        }
    }
}

// MARK: - FFT analyzer (跑在 background Task, 不在音频线程)

final class FFTAnalyzer: @unchecked Sendable {
    let size: Int
    private var samples: [Float]
    private var window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private var roots: [Float]
    private var bands: [Float]
    private var spectrallySmoothed: [Float]
    private var temporallySmoothed: [Float]

    init(log2n: Int, bandCount: Int) {
        self.size = 1 << log2n
        self.samples = Array(repeating: 0, count: 1 << log2n)
        var w = [Float](repeating: 0, count: 1 << log2n)
        vDSP_hann_window(&w, vDSP_Length(1 << log2n), Int32(vDSP_HANN_NORM))
        self.window = w
        self.fft = vDSP.FFT(log2n: vDSP_Length(log2n), radix: .radix2, ofType: DSPSplitComplex.self)
        self.windowed = Array(repeating: 0, count: 1 << log2n)
        self.real = Array(repeating: 0, count: (1 << log2n) / 2)
        self.imag = Array(repeating: 0, count: (1 << log2n) / 2)
        self.magnitudes = Array(repeating: 0, count: (1 << log2n) / 2)
        self.roots = Array(repeating: 0, count: (1 << log2n) / 2)
        self.bands = Array(repeating: 0, count: bandCount)
        self.spectrallySmoothed = Array(repeating: 0, count: bandCount)
        self.temporallySmoothed = Array(repeating: 0, count: bandCount)
    }

    static func forBass(sampleRate: Double) -> FFTAnalyzer {
        // About 45 ms at every output rate resolves sub-bass as well as the kick.
        let exponent = Int(log2(min(max(sampleRate, 8_000), 768_000) * 0.045).rounded())
        return FFTAnalyzer(log2n: exponent, bandCount: 0)
    }

    func readWindow(from ring: SpectrumSampleRing, endingAt end: Int64) {
        guard fft != nil else { return }
        let n = size
        samples.withUnsafeMutableBufferPointer {
            ring.copyWindow(endingAt: end, count: n, into: $0.baseAddress!)
        }
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        windowed.withUnsafeBytes { ptr in
            ptr.bindMemory(to: DSPComplex.self).baseAddress.map { src in
                real.withUnsafeMutableBufferPointer { realBuf in
                    imag.withUnsafeMutableBufferPointer { imagBuf in
                        var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(src, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                fft?.forward(input: split, output: &split)
            }
        }

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
    }

    func bassPower(sampleRate: Double) -> Double {
        let binWidth = sampleRate / Double(size)
        // Index zero packs DC and Nyquist in vDSP's real FFT.
        let lower = max(1, Int((30 / binWidth).rounded()))
        let upper = min(magnitudes.count - 1, Int((160 / binWidth).rounded()))
        guard lower <= upper else { return 0 }
        let sum = magnitudes[lower...upper].reduce(0, +)
        return Double(sum) * 4 / Double(size * size)
    }

    func bandLevels(
        bandCount: Int,
        sampleRate: Double = 0,
        elapsed: TimeInterval? = nil
    ) -> [Float] {
        guard fft != nil else {
            return Array(repeating: 0, count: bandCount)
        }
        if bands.count != bandCount {
            bands = Array(repeating: 0, count: bandCount)
            spectrallySmoothed = Array(repeating: 0, count: bandCount)
            temporallySmoothed = Array(repeating: 0, count: bandCount)
        }
        let n = size
        var count = Int32(n / 2)
        vvsqrtf(&roots, magnitudes, &count)
        // vDSP 的正向 FFT 不会替我们按 N 归一化。少这一步时大部分音乐内容
        // 都会超过 0 dB 后被夹成 1，表现成整排音符同时顶满、毫无层次。
        var fftScale = Float(2) / Float(n)
        roots.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            vDSP_vsmul(
                baseAddress,
                1,
                &fftScale,
                baseAddress,
                1,
                vDSP_Length(n / 2)
            )
        }

        let binCount = n / 2
        // 频段按可听范围映射。直通图的 tap 拿到的是 88.2 / 96 kHz 的原样采样,
        // 若仍按 bin 序号等分,近一半频段会落在 20 kHz 以上的空白区,
        // 画面只剩左侧几根柱子在动。
        let binWidth = sampleRate > 0 ? Float(sampleRate) / Float(n) : 0
        let minBin = binWidth > 0 ? max(1, Int((94 / binWidth).rounded())) : 2
        let maxBin = binWidth > 0
            ? min(binCount - 1, max(minBin + bandCount, Int(20_000 / binWidth)))
            : binCount - 1
        let logMin = log(Float(minBin))
        let logMax = log(Float(maxBin))
        let step = (logMax - logMin) / Float(bandCount)
        for b in 0..<bandCount {
            let lo = Int(exp(logMin + Float(b) * step))
            let hi = max(lo + 1, Int(exp(logMin + Float(b + 1) * step)))
            let upper = min(hi, binCount)
            var sum: Float = 0
            for i in lo..<upper { sum += roots[i] }
            let avg = sum / Float(max(1, upper - lo))
            let db = 20 * log10f(max(1e-7, avg))
            let normalized = min(max((db + 72) / 64, 0), 1)
            // 低电平适度展开、底噪直接归零；既保留弱乐器，又避免静音时
            // 一圈短柱不停颤动。
            bands[b] = normalized < 0.035 ? 0 : powf(normalized, 0.72)
        }

        if bandCount > 2 {
            spectrallySmoothed[0] = bands[0]
            spectrallySmoothed[bandCount - 1] = bands[bandCount - 1]
            for index in 1..<(bandCount - 1) {
                spectrallySmoothed[index] = bands[index - 1] * 0.18
                    + bands[index] * 0.64
                    + bands[index + 1] * 0.18
            }
        } else {
            for index in 0..<bandCount { spectrallySmoothed[index] = bands[index] }
        }

        let reference = AudioVisualizerService.smoothingReferenceInterval
        let attack = SpectrumTemporalSmoothing.blend(base: 0.72, elapsed: elapsed, reference: reference)
        let decay = SpectrumTemporalSmoothing.blend(base: 0.18, elapsed: elapsed, reference: reference)
        for index in 0..<bandCount {
            let old = temporallySmoothed[index]
            let target = spectrallySmoothed[index]
            let response: Float = target >= old ? attack : decay
            temporallySmoothed[index] = old + (target - old) * response
        }
        return temporallySmoothed.withUnsafeBufferPointer { Array($0) }
    }
}
