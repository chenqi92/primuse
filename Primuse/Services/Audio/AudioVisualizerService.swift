import Accelerate
import AVFoundation
import Foundation
import os.lock

/// 实时音频频谱可视化器 —— 在 AudioEngine 的 mainMixerNode 上挂 tap, 拿到
/// 输出 buffer 做 FFT, 把 1024 点频谱压成 32 个频段强度发布给 UI。
///
/// **音频线程安全**:
/// tap callback 跑在音频实时线程, 严格限制只做 memcpy + 翻 atomic flag,
/// 不允许 Swift Array 分配 / 类型绑定 / FFT / MainActor hop ── 这些都会把
/// 音频线程拖慢甚至抢占,在 iOS 26 上会触发硬崩溃。FFT + 发布到 UI 全部
/// 在另起的 background Task 里跑。
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
    nonisolated static let fftSize = 1024

    /// 0...1 归一化的频段强度。bandLevels.count == bandCount 永远成立。
    /// UI 用 .animation(.linear(duration: 0.07), value: bandLevels) 即可平滑过渡。
    private(set) var bandLevels: [Float] = Array(repeating: 0, count: bandCount)

    private weak var engine: AVAudioEngine?
    private var tappedNode: AVAudioMixerNode?
    private let buffer = SharedSampleBuffer(capacity: fftSize)
    private var pollTask: Task<Void, Never>?
    private var ownerIDs: Set<UUID> = []
    private let compatibilityOwnerID = UUID()
    private var pollGeneration: UInt64 = 0

    func start(engine: AVAudioEngine, on node: AVAudioMixerNode) {
        _ = acquire(owner: compatibilityOwnerID, engine: engine, on: node)
    }

    func stop() {
        release(owner: compatibilityOwnerID)
    }

    @discardableResult
    func acquire(owner: UUID, engine: AVAudioEngine, on node: AVAudioMixerNode) -> Bool {
        guard engine.isRunning else { return false }

        if let currentEngine = self.engine,
           currentEngine === engine,
           tappedNode === node,
           pollTask != nil {
            ownerIDs.insert(owner)
            return true
        }

        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0 else {
            plog("⚠️ Visualizer skipped: invalid mixer format sr=\(format.sampleRate) ch=\(format.channelCount)")
            return false
        }

        ownerIDs.insert(owner)
        stopPipeline()
        self.engine = engine

        // tap 闭包只 memcpy + 翻 flag, 完全不 alloc 不 hop actor。
        let buffer = self.buffer
        AudioVisualizerTap.install(
            on: node,
            bufferSize: AVAudioFrameCount(Self.fftSize),
            format: format,
            buffer: buffer
        )
        self.tappedNode = node

        // 用 detached Task 周期性拉 buffer 做 FFT, 跟音频线程完全解耦。
        // 25Hz 节流, 落到 main actor 才更新 @Observable bandLevels。
        let analyzer = FFTAnalyzer(
            log2n: Int(log2(Double(Self.fftSize))),
            bandCount: Self.bandCount
        )
        pollGeneration &+= 1
        let generation = pollGeneration
        pollTask = Task.detached(priority: .userInitiated) { [weak self, buffer, analyzer] in
            var samples = [Float](repeating: 0, count: Self.fftSize)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { break }
                guard buffer.copyLatest(into: &samples) else { continue }
                let levels = analyzer.bandLevels(samples: samples, bandCount: Self.bandCount)
                await MainActor.run { [weak self] in
                    guard let self, self.pollGeneration == generation else { return }
                    self.bandLevels = levels
                }
            }
        }
        return true
    }

    func release(owner: UUID) {
        guard ownerIDs.remove(owner) != nil,
              ownerIDs.isEmpty else { return }
        stopPipeline()
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
        buffer.discardLatest()
        bandLevels = Array(repeating: 0, count: Self.bandCount)
    }
}

/// `installTap` must be created outside the `@MainActor` visualizer service.
/// Otherwise Swift can inherit MainActor isolation for the tap closure, and
/// AVAudioEngine will trip the iOS 26 concurrency runtime when it invokes the
/// closure on Core Audio's realtime queue.
private enum AudioVisualizerTap {
    static func install(
        on node: AVAudioMixerNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat,
        buffer: SharedSampleBuffer
    ) {
        node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { audioBuffer, _ in
            buffer.fill(from: audioBuffer)
        }
    }
}

// MARK: - Audio-thread-safe sample buffer

/// 共享缓冲: 音频线程写,后台 Task 读。用 os_unfair_lock 替代 Swift actor —
/// actor hop 在音频线程不允许。Lock 失败时直接 drop frame (轮询 tick 下一帧
/// 会取最新数据)。
private final class SharedSampleBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private var hasFresh = false
    private var lock = os_unfair_lock_s()
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// 音频线程调用。AVAudioPCMBuffer 第 0 声道前 capacity 个样本拷进共享缓冲。
    /// 失败 (锁忙 / 格式不对) 直接返回, 不在音频线程做任何复杂的事。
    func fill(from buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let frames = min(Int(buffer.frameLength), capacity)
        guard frames > 0 else { return }
        guard os_unfair_lock_trylock(&lock) else { return }  // 锁忙就放弃这一帧
        memcpy(storage, ch[0], frames * MemoryLayout<Float>.size)
        if frames < capacity {
            // 不足 capacity 时把尾部置零, FFT 自然就少高频能量, 视觉上正常
            memset(storage.advanced(by: frames), 0, (capacity - frames) * MemoryLayout<Float>.size)
        }
        hasFresh = true
        os_unfair_lock_unlock(&lock)
    }

    /// 后台 Task 调用。目标数组由轮询任务一次性预分配，避免每个 FFT tick
    /// 创建快照；音频线程写入的也是独立裸缓冲，不会触发 Array 写时复制。
    func copyLatest(into destination: inout [Float]) -> Bool {
        guard destination.count >= capacity else { return false }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard hasFresh else { return false }
        destination.withUnsafeMutableBufferPointer { target in
            guard let base = target.baseAddress else { return }
            memcpy(base, storage, capacity * MemoryLayout<Float>.size)
        }
        hasFresh = false
        return true
    }

    func discardLatest() {
        os_unfair_lock_lock(&lock)
        hasFresh = false
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - FFT analyzer (跑在 background Task, 不在音频线程)

private final class FFTAnalyzer: @unchecked Sendable {
    private let log2n: vDSP_Length
    private let n: Int
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
        self.log2n = vDSP_Length(log2n)
        self.n = 1 << log2n
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

    func bandLevels(samples: [Float], bandCount: Int) -> [Float] {
        guard samples.count >= n, fft != nil else {
            return Array(repeating: 0, count: bandCount)
        }
        if bands.count != bandCount {
            bands = Array(repeating: 0, count: bandCount)
            spectrallySmoothed = Array(repeating: 0, count: bandCount)
            temporallySmoothed = Array(repeating: 0, count: bandCount)
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
        let minBin = 2
        let maxBin = binCount - 1
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

        for index in 0..<bandCount {
            let old = temporallySmoothed[index]
            let target = spectrallySmoothed[index]
            let response: Float = target >= old ? 0.72 : 0.18
            temporallySmoothed[index] = old + (target - old) * response
        }
        return temporallySmoothed.withUnsafeBufferPointer { Array($0) }
    }
}
