#if os(iOS) || os(macOS)
import Foundation
import Synchronization

/// Single control-thread producer and single audio-thread consumer. Three fixed slots transfer
/// ownership atomically; a producer can never overwrite the slot the audio thread is reading.
public final class EQRenderMailbox: @unchecked Sendable {
    private final class Slot {
        let coefficients = UnsafeMutablePointer<EQBiquad>.allocate(capacity: ParametricEQ.maximumFilters)
        var count = 0
        var gain = 1.0
        init() { coefficients.initialize(repeating: EQBiquad(), count: ParametricEQ.maximumFilters) }
        deinit { coefficients.deinitialize(count: ParametricEQ.maximumFilters); coefficients.deallocate() }
    }
    private let slots = [Slot(), Slot(), Slot()]
    private let middle = Atomic<Int>(1)
    private var writing = 2
    private var reading = 0
    private let resetRequested = Atomic<Bool>(false)

    public init() {}

    public func publish(_ configuration: EQRenderConfiguration) {
        precondition(configuration.filters.count <= ParametricEQ.maximumFilters)
        let slot = slots[writing]
        slot.count = configuration.filters.count
        slot.gain = configuration.linearGain
        for index in 0..<slot.count { slot.coefficients[index] = configuration.filters[index] }
        writing = middle.exchange(writing | 4, ordering: .acquiringAndReleasing) & 3
    }

    public func requestReset() { resetRequested.store(true, ordering: .releasing) }

    fileprivate func takeReset() -> Bool { resetRequested.exchange(false, ordering: .acquiringAndReleasing) }

    fileprivate func consume(into chain: EQFilterChain, includeCurrent: Bool = false) -> Bool {
        if middle.load(ordering: .acquiring) & 4 != 0 {
            reading = middle.exchange(reading, ordering: .acquiringAndReleasing) & 3
        } else if !includeCurrent { return false }
        let slot = slots[reading]
        chain.configure(coefficients: slot.coefficients, count: slot.count, gain: slot.gain)
        return true
    }
}

private final class EQFilterChain {
    struct State { var z1 = 0.0; var z2 = 0.0 }
    let coefficients = UnsafeMutablePointer<EQBiquad>.allocate(capacity: ParametricEQ.maximumFilters)
    let states: UnsafeMutablePointer<State>
    let channels: Int
    var count = 0
    var gain = 1.0

    init(channels: Int) {
        self.channels = channels
        coefficients.initialize(repeating: EQBiquad(), count: ParametricEQ.maximumFilters)
        states = .allocate(capacity: channels * ParametricEQ.maximumFilters)
        states.initialize(repeating: State(), count: channels * ParametricEQ.maximumFilters)
    }

    deinit {
        coefficients.deinitialize(count: ParametricEQ.maximumFilters); coefficients.deallocate()
        states.deinitialize(count: channels * ParametricEQ.maximumFilters); states.deallocate()
    }

    func reset() {
        for i in 0..<(channels * ParametricEQ.maximumFilters) { states[i] = State() }
    }

    func configure(coefficients input: UnsafePointer<EQBiquad>, count: Int, gain: Double) {
        self.count = count; self.gain = gain
        for i in 0..<count { coefficients[i] = input[i] }
        reset()
    }

    @inline(__always) func process(_ input: Double, channel: Int) -> Double {
        var x = input * gain
        for i in 0..<count {
            let c = coefficients[i]
            let index = channel * ParametricEQ.maximumFilters + i
            let y = c.b0 * x + states[index].z1
            states[index].z1 = c.b1 * x - c.a1 * y + states[index].z2
            states[index].z2 = c.b2 * x - c.a2 * y
            x = y
        }
        if !x.isFinite { reset(); return 0 }
        return x
    }
}

/// Allocate before starting audio; process is allocation-free and owns all mutable filter state.
public final class EQRealtimeProcessor {
    private let mailbox: EQRenderMailbox
    private var active: EQFilterChain
    private var incoming: EQFilterChain
    private let warmupFrames: Int
    private let fadeFrames: Int
    private var transitionFrame: Int?
    private var initialized = false
    public let channels: Int

    public init(mailbox: EQRenderMailbox, sampleRate: Double, channels: Int) {
        self.mailbox = mailbox; self.channels = channels
        active = EQFilterChain(channels: channels)
        incoming = EQFilterChain(channels: channels)
        warmupFrames = max(1, Int(sampleRate * 0.02))
        fadeFrames = max(1, Int(sampleRate * 0.04))
    }

    public func beginBlock() {
        if mailbox.takeReset() { active.reset(); incoming.reset() }
        if !initialized {
            _ = mailbox.consume(into: active, includeCurrent: true)
            initialized = true
        } else if transitionFrame == nil, mailbox.consume(into: incoming) {
            transitionFrame = 0
        }
    }

    /// Call for every channel in a frame, followed by endFrame exactly once.
    @inline(__always) public func process(_ input: Float, channel: Int) -> Float {
        let x = input.isFinite ? Double(input) : 0
        let old = active.process(x, channel: channel)
        guard let frame = transitionFrame else { return Float(old) }
        let new = incoming.process(x, channel: channel)
        let t = min(1, max(0, Double(frame - warmupFrames) / Double(fadeFrames)))
        return Float(old * (1 - t) + new * t)
    }

    @inline(__always) public func endFrame() {
        guard let frame = transitionFrame else { return }
        if frame >= warmupFrames + fadeFrames {
            swap(&active, &incoming)
            transitionFrame = nil
        } else { transitionFrame = frame + 1 }
    }
}
#endif
