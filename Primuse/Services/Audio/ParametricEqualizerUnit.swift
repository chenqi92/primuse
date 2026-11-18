import AudioToolbox
import AVFoundation
import PrimuseKit

final class ParametricEqualizerUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x70657131,
        componentManufacturer: 0x50726d73, componentFlags: AudioComponentFlags.sandboxSafe.rawValue,
        componentFlagsMask: 0
    )
    private static let registration: Void = {
        AUAudioUnit.registerSubclass(ParametricEqualizerUnit.self, as: componentDescription, name: "Primuse: Equalizer", version: 1)
    }()

    static func makeNode() -> AVAudioUnitEffect {
        _ = registration
        return AVAudioUnitEffect(audioComponentDescription: componentDescription)
    }

    let mailbox = EQRenderMailbox()
    private final class Resources: @unchecked Sendable {
        let processor: EQRealtimeProcessor
        let scratch: UnsafeMutablePointer<Float>
        let channels: Int
        let capacity: Int
        init(mailbox: EQRenderMailbox, sampleRate: Double, channels: Int, capacity: Int) {
            self.channels = channels; self.capacity = capacity
            processor = EQRealtimeProcessor(mailbox: mailbox, sampleRate: sampleRate, channels: channels)
            scratch = .allocate(capacity: channels * capacity)
            scratch.initialize(repeating: 0, count: channels * capacity)
        }
        deinit { scratch.deinitialize(count: channels * capacity); scratch.deallocate() }
    }
    private final class Slot: @unchecked Sendable { var resources: Resources? }
    private let slot = Slot()
    private var input: AUAudioUnitBus!
    private var output: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        input = try AUAudioUnitBus(format: format)
        output = try AUAudioUnitBus(format: format)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        maximumFramesToRender = 4_096
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        let format = output.format
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              input.format == format, format.channelCount > 0, format.channelCount <= 8 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        slot.resources = Resources(mailbox: mailbox, sampleRate: format.sampleRate,
                                   channels: Int(format.channelCount), capacity: Int(maximumFramesToRender))
    }

    override func deallocateRenderResources() {
        slot.resources = nil
        super.deallocateRenderResources()
    }

    override func reset() { super.reset(); mailbox.requestReset() }

    override var internalRenderBlock: AUInternalRenderBlock {
        let slot = slot
        return { flags, timestamp, frameCount, _, outputData, _, pull in
            guard let pull else { return kAudioUnitErr_NoConnection }
            guard let resources = slot.resources else { return kAudioUnitErr_Uninitialized }
            let frames = Int(frameCount)
            guard frames <= resources.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count == resources.channels else { return kAudioUnitErr_FormatNotSupported }
            for channel in 0..<buffers.count {
                if buffers[channel].mData == nil {
                    buffers[channel].mData = UnsafeMutableRawPointer(resources.scratch + channel * resources.capacity)
                }
                buffers[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.stride)
            }
            let status = pull(flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            resources.processor.beginBlock()
            for frame in 0..<frames {
                for channel in 0..<buffers.count {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    data[frame] = resources.processor.process(data[frame], channel: channel)
                }
                resources.processor.endFrame()
            }
            // A silent input can still produce an IIR tail.
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            return noErr
        }
    }
}
