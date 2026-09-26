import AudioToolbox
import AVFoundation
import Foundation
import PrimuseKit
import Synchronization

/// Lock-free single-producer / single-consumer float ring. The render thread
/// writes, one analysis task reads; neither side ever blocks or allocates.
final class KaraokeSampleRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total samples ever written / read; indexes wrap by `capacity`.
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Producer side. Overwrites the oldest samples when the reader lags.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let start = written.load(ordering: .relaxed)
        for offset in 0..<count {
            storage[(start + offset) % capacity] = samples[offset]
        }
        written.store(start + count, ordering: .releasing)
    }

    /// Consumer side: copies the newest `count` samples into `destination`
    /// when at least that many arrived since the previous read. Older unread
    /// samples are skipped; analysis only cares about "now".
    func readLatest(_ count: Int, into destination: UnsafeMutablePointer<Float>) -> Bool {
        let end = written.load(ordering: .acquiring)
        let start = end - count
        guard count <= capacity, start >= 0, end > consumed.load(ordering: .relaxed) else { return false }
        for offset in 0..<count {
            destination[offset] = storage[(start + offset) % capacity]
        }
        // A producer lapping the reader mid-copy would tear the window.
        guard written.load(ordering: .acquiring) - start <= capacity else { return false }
        consumed.store(end, ordering: .relaxed)
        return true
    }

    func reset() {
        consumed.store(written.load(ordering: .relaxed), ordering: .relaxed)
    }

    /// Samples written so far; the absolute index of the next sample.
    var totalWritten: Int {
        written.load(ordering: .acquiring)
    }

    /// The newest `count` samples and the absolute index just past them,
    /// without consuming anything.
    func latestWindow(_ count: Int) -> (samples: [Float], endIndex: Int)? {
        let end = written.load(ordering: .acquiring)
        let start = end - count
        guard count <= capacity, start >= 0 else { return nil }
        var samples = [Float](repeating: 0, count: count)
        for offset in 0..<count {
            samples[offset] = storage[(start + offset) % capacity]
        }
        guard written.load(ordering: .acquiring) - start <= capacity else { return nil }
        return (samples, end)
    }
}

/// A pre-separated vocal stem at the playback graph's sample rate, as
/// 16-bit interleaved stereo. Immutable once built, so the render thread can
/// read it through a raw pointer.
final class KaraokeStemTrack: @unchecked Sendable {
    let frames: Int
    let sampleRate: Double
    let samples: UnsafeMutablePointer<Int16>

    init(left: [Float], right: [Float], sampleRate: Double) {
        precondition(left.count == right.count)
        frames = left.count
        self.sampleRate = sampleRate
        samples = .allocate(capacity: max(1, frames * 2))
        for i in 0..<frames {
            samples[2 * i] = Int16(max(-32_768, min(32_767, (left[i] * 32_767).rounded())))
            samples[2 * i + 1] = Int16(max(-32_768, min(32_767, (right[i] * 32_767).rounded())))
        }
    }

    deinit {
        samples.deallocate()
    }

    /// Mono samples of `range` for alignment searches.
    func monoExcerpt(_ range: Range<Int>) -> [Float] {
        let scale: Float = 0.5 / 32_767
        return range.map { i in
            (Float(samples[2 * i]) + Float(samples[2 * i + 1])) * scale
        }
    }
}

/// Settings the main actor writes and the render thread reads, plus what the
/// render thread reports back. Shared across graph rebuilds.
final class KaraokeRenderControl: Sendable {
    private let activeFlag = Atomic<Bool>(false)
    private let reductionBits = Atomic<UInt32>(Float(1).bitPattern)
    private let capturesVocalFlag = Atomic<Bool>(false)
    private let bridgesStemFlag = Atomic<Bool>(false)
    private let effectivelyMonoFlag = Atomic<Bool>(false)
    private let processingFlag = Atomic<Bool>(false)
    private let discontinuityFlag = Atomic<Bool>(false)
    // Stem subtraction. The track pointer and length are published
    // separately; a zero length disables it, so the pointer is always read
    // after a non-zero length. Old tracks stay alive on the main actor for a
    // second after a swap, far longer than any render cycle.
    private let stemAddress = Atomic<UInt>(0)
    private let stemFrames = Atomic<Int>(0)
    /// Advances on every discontinuity and stem swap; a lock is only valid
    /// for the epoch it was computed in.
    private let inputEpoch = Atomic<Int>(0)
    private let lockEpoch = Atomic<Int>(-1)
    private let lockDelta = Atomic<Int>(0)
    /// Mono copy of the playback input with absolute sample indices, for
    /// aligning the stem.
    let inputRing = KaraokeSampleRing(capacity: 1 << 17)
    /// Mono estimate of the removed lead vocal, for the reference melody.
    let vocalRing = KaraokeSampleRing(capacity: 1 << 16)

    var isActive: Bool {
        get { activeFlag.load(ordering: .relaxed) }
        set { activeFlag.store(newValue, ordering: .relaxed) }
    }

    /// 0 keeps the vocal, 1 removes it.
    var reduction: Float {
        get { Float(bitPattern: reductionBits.load(ordering: .relaxed)) }
        set { reductionBits.store(min(1, max(0, newValue)).bitPattern, ordering: .relaxed) }
    }

    var capturesVocal: Bool {
        get { capturesVocalFlag.load(ordering: .relaxed) }
        set { capturesVocalFlag.store(newValue, ordering: .relaxed) }
    }

    /// With a stem loaded: reduce spectrally until it is locked (song start,
    /// after every seek), instead of letting the whole vocal through.
    var bridgesStem: Bool {
        get { bridgesStemFlag.load(ordering: .relaxed) }
        set { bridgesStemFlag.store(newValue, ordering: .relaxed) }
    }

    /// Reported by the render thread.
    var isEffectivelyMono: Bool { effectivelyMonoFlag.load(ordering: .relaxed) }
    var isProcessing: Bool { processingFlag.load(ordering: .relaxed) }

    /// The graph was flushed (seek, new song). The render thread restarts
    /// the reducer on its next cycle; resetting it here would race a render.
    func markDiscontinuity() {
        discontinuityFlag.store(true, ordering: .relaxed)
    }

    func takeDiscontinuity() -> Bool {
        discontinuityFlag.exchange(false, ordering: .relaxed)
    }

    // MARK: Stem

    /// Main actor: installs (or with nil removes) the stem to subtract.
    func installStem(_ track: KaraokeStemTrack?) {
        stemFrames.store(0, ordering: .releasing)
        inputEpoch.add(1, ordering: .releasing)
        guard let track else {
            stemAddress.store(0, ordering: .releasing)
            return
        }
        stemAddress.store(UInt(bitPattern: track.samples), ordering: .releasing)
        stemFrames.store(track.frames, ordering: .releasing)
    }

    var currentEpoch: Int { inputEpoch.load(ordering: .acquiring) }

    /// Publishes an alignment: input sample `i` lines up with stem frame
    /// `i + delta`. Ignored by the render thread if the epoch moved on.
    func publishLock(delta: Int, epoch: Int) {
        lockDelta.store(delta, ordering: .relaxed)
        lockEpoch.store(epoch, ordering: .releasing)
    }

    var isStemLocked: Bool {
        stemFrames.load(ordering: .acquiring) > 0
            && lockEpoch.load(ordering: .acquiring) == inputEpoch.load(ordering: .acquiring)
    }

    var lockedDelta: Int? {
        isStemLocked ? lockDelta.load(ordering: .relaxed) : nil
    }

    /// Render thread: the stem to subtract right now, if any.
    struct RenderStem {
        var samples: UnsafePointer<Int16>
        var frames: Int
        var delta: Int?
    }

    func renderStem() -> RenderStem? {
        let frames = stemFrames.load(ordering: .acquiring)
        guard frames > 0,
              let pointer = UnsafePointer<Int16>(bitPattern: stemAddress.load(ordering: .acquiring)) else {
            return nil
        }
        let epoch = inputEpoch.load(ordering: .acquiring)
        let delta = lockEpoch.load(ordering: .acquiring) == epoch ? lockDelta.load(ordering: .relaxed) : nil
        return RenderStem(samples: pointer, frames: frames, delta: delta)
    }

    fileprivate func advanceEpoch() {
        inputEpoch.add(1, ordering: .releasing)
    }

    func report(isEffectivelyMono: Bool, isProcessing: Bool) {
        effectivelyMonoFlag.store(isEffectivelyMono, ordering: .relaxed)
        processingFlag.store(isProcessing, ordering: .relaxed)
    }
}

/// In-process effect unit that runs `KaraokeVocalReducer` inside the
/// playback graph. It sits between the player mixer and the EQ so crossfades
/// and gapless transitions are processed as one stream.
final class KaraokeVocalReducerUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharacterCode("kvrd"),
        componentManufacturer: fourCharacterCode("Prms"),
        // This in-process DSP only uses its supplied audio buffers. Without
        // this flag, macOS rejects it when the playback host is sandboxed.
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0
    )

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(
            KaraokeVocalReducerUnit.self,
            as: componentDescription,
            name: "Primuse: Karaoke Vocal Reducer",
            version: 1
        )
    }()

    /// Instantiates the unit synchronously for the graph being built.
    static func makeNode(control: KaraokeRenderControl) -> AVAudioUnitEffect? {
        _ = registration
        let node = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        guard let unit = node.auAudioUnit as? KaraokeVocalReducerUnit else {
            plog("⚠️ Karaoke: vocal reducer unit did not instantiate in-process")
            return nil
        }
        unit.control = control
        return node
    }

    private static func fourCharacterCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// Everything the render block touches, rebuilt per allocation.
    private final class RenderResources: @unchecked Sendable {
        let reducer: KaraokeVocalReducer?
        let control: KaraokeRenderControl
        let scratch: UnsafeMutablePointer<Float>
        let vocal: UnsafeMutablePointer<Float>
        let mono: UnsafeMutablePointer<Float>
        let capacity: Int
        /// Last applied stem gain, ramped per block.
        var stemGain: Float = 0

        init(reducer: KaraokeVocalReducer?, control: KaraokeRenderControl, capacity: Int, channels: Int) {
            self.reducer = reducer
            self.control = control
            self.capacity = capacity
            scratch = .allocate(capacity: capacity * max(1, channels))
            scratch.initialize(repeating: 0, count: capacity * max(1, channels))
            vocal = .allocate(capacity: capacity)
            vocal.initialize(repeating: 0, count: capacity)
            mono = .allocate(capacity: capacity)
            mono.initialize(repeating: 0, count: capacity)
        }

        deinit {
            scratch.deallocate()
            vocal.deallocate()
            mono.deallocate()
        }
    }

    /// Box the render block reads; swapped only while render resources are
    /// (de)allocated, when the host guarantees no render is in flight.
    private final class ResourceSlot: @unchecked Sendable {
        var resources: RenderResources?
    }

    var control = KaraokeRenderControl()
    private let slot = ResourceSlot()
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4_096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    override var latency: TimeInterval {
        guard let reducer = slot.resources?.reducer, control.isActive else { return 0 }
        return Double(reducer.latencySamples) / reducer.sampleRate
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = outputBus.format
        guard inputBus.format.channelCount == format.channelCount else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        // Only deinterleaved stereo can be split into left/right spectra;
        // anything else passes through untouched.
        let reducer = format.channelCount == 2 && !format.isInterleaved
            && format.commonFormat == .pcmFormatFloat32
            ? KaraokeVocalReducer(sampleRate: format.sampleRate)
            : nil
        slot.resources = RenderResources(
            reducer: reducer,
            control: control,
            capacity: Int(maximumFramesToRender),
            channels: Int(format.channelCount)
        )
    }

    override func reset() {
        super.reset()
        control.markDiscontinuity()
    }

    override func deallocateRenderResources() {
        slot.resources = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let slot = self.slot
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            guard let resources = slot.resources else { return kAudioUnitErr_Uninitialized }
            let frames = Int(frameCount)
            guard frames <= resources.capacity else { return kAudioUnitErr_TooManyFramesToProcess }

            // Pull straight into the output buffers; give the host our own
            // memory for any channel it left without storage.
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let byteSize = UInt32(frames * MemoryLayout<Float>.stride)
            for index in 0..<buffers.count {
                if buffers[index].mData == nil {
                    buffers[index].mData = UnsafeMutableRawPointer(resources.scratch + index * resources.capacity)
                }
                buffers[index].mDataByteSize = byteSize
            }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            guard let reducer = resources.reducer,
                  buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let control = resources.control
            if control.takeDiscontinuity() {
                reducer.restartAfterDiscontinuity()
                control.vocalRing.reset()
                control.advanceEpoch()
            }

            // Stem mode: subtract the pre-separated vocal where it is locked
            // to the playback. The spectral reducer stays off meanwhile.
            if let stem = control.renderStem() {
                let startIndex = control.inputRing.totalWritten
                for i in 0..<frames {
                    resources.mono[i] = (left[i] + right[i]) * 0.5
                }
                control.inputRing.write(resources.mono, count: frames)
                let target: Float = stem.delta == nil ? 0 : control.reduction
                let from = resources.stemGain
                resources.stemGain = target
                let captures = control.capturesVocal
                if let delta = stem.delta, from > 0 || target > 0 || captures {
                    let scale: Float = 1 / 32_767
                    let step = (target - from) / Float(frames)
                    for i in 0..<frames {
                        let index = startIndex + i + delta
                        guard index >= 0, index < stem.frames else {
                            resources.vocal[i] = 0
                            continue
                        }
                        let stemLeft = Float(stem.samples[2 * index]) * scale
                        let stemRight = Float(stem.samples[2 * index + 1]) * scale
                        let gain = from + step * Float(i)
                        left[i] -= gain * stemLeft
                        right[i] -= gain * stemRight
                        resources.vocal[i] = (stemLeft + stemRight) * 0.5
                    }
                    // The separated vocal is the cleanest melody reference.
                    if captures {
                        control.vocalRing.write(resources.vocal, count: frames)
                    }
                }
                // Unlocked: the spectral reducer stands in, and hands over
                // with a crossfade once the lock lands.
                let bridges = stem.delta == nil && control.bridgesStem
                if bridges || reducer.phase != .bypassed {
                    let capturesBridge = bridges && captures
                    reducer.process(
                        left: left,
                        right: right,
                        frameCount: frames,
                        isActive: bridges,
                        reduction: control.reduction,
                        vocal: capturesBridge ? resources.vocal : nil
                    )
                    if capturesBridge {
                        control.vocalRing.write(resources.vocal, count: frames)
                    }
                }
                control.report(isEffectivelyMono: false, isProcessing: stem.delta != nil || bridges)
                return noErr
            }
            resources.stemGain = 0

            let active = control.isActive
            if !active, reducer.phase == .bypassed {
                return noErr
            }
            let captures = control.capturesVocal
            reducer.process(
                left: left,
                right: right,
                frameCount: frames,
                isActive: active,
                reduction: control.reduction,
                vocal: captures ? resources.vocal : nil
            )
            if captures {
                control.vocalRing.write(resources.vocal, count: frames)
            }
            control.report(
                isEffectivelyMono: reducer.isEffectivelyMono,
                isProcessing: reducer.phase != .bypassed
            )
            return noErr
        }
    }
}
