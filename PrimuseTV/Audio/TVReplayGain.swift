#if os(tvOS)
import AVFoundation
import Foundation
import Observation
import PrimuseKit

@MainActor @Observable
final class TVReplayGainSettings {
    static let shared = TVReplayGainSettings()
    private let defaults: UserDefaults
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "primuse.tv.replayGain.enabled") } }
    var mode: ReplayGainMode { didSet { defaults.set(mode.rawValue, forKey: "primuse.tv.replayGain.mode") } }
    var preampDB: Double { didSet { defaults.set(ReplayGainPolicy.sanitizedPreamp(preampDB), forKey: "primuse.tv.replayGain.preamp") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "primuse.tv.replayGain.enabled")
        mode = defaults.string(forKey: "primuse.tv.replayGain.mode").flatMap(ReplayGainMode.init(rawValue:)) ?? .automatic
        preampDB = ReplayGainPolicy.sanitizedPreamp(defaults.double(forKey: "primuse.tv.replayGain.preamp"))
    }
}

/// A separate programme gain keeps the medley deck's fade independent. The
/// audio tap can amplify PCM; AVPlayer.volume itself is limited to 0...1.
final class TVReplayGainControl: @unchecked Sendable {
    private let lock = NSLock()
    private var target: Float = 1

    func setGain(_ gain: Float) {
        lock.lock()
        target = gain.isFinite ? min(ReplayGainPolicy.maximumLinearGain, max(0, gain)) : 1
        lock.unlock()
    }

    var gain: Float {
        lock.lock()
        defer { lock.unlock() }
        return target
    }
}

final class TVReplayGainRenderer: @unchecked Sendable {
    private let control: TVReplayGainControl
    private var current: Float = 1
    private var format = AudioStreamBasicDescription()

    init(control: TVReplayGainControl = TVReplayGainControl()) { self.control = control }

    func setGain(_ gain: Float) { control.setGain(gain) }

    func configure(_ format: AudioStreamBasicDescription) {
        self.format = format
        current = control.gain
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let gain = control.gain
        guard frames > 0, format.mFormatID == kAudioFormatLinearPCM else { return }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        let initial = current
        let step = (gain - initial) / Float(max(frames, Int(format.mSampleRate * 0.05)))
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        for buffer in list {
            guard let data = buffer.mData else { continue }
            let channels = Int(buffer.mNumberChannels)
            for frame in 0..<frames {
                let multiplier = initial + step * Float(frame + 1)
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    switch (floating, format.mBitsPerChannel) {
                    case (true, 32): data.assumingMemoryBound(to: Float.self)[index] *= multiplier
                    case (true, 64): data.assumingMemoryBound(to: Double.self)[index] *= Double(multiplier)
                    case (false, 16):
                        let samples = data.assumingMemoryBound(to: Int16.self)
                        samples[index] = Int16(max(-32768, min(32767, Float(samples[index]) * multiplier)))
                    case (false, 32):
                        let samples = data.assumingMemoryBound(to: Int32.self)
                        samples[index] = Int32(max(-2147483648, min(2147483647, Double(samples[index]) * Double(multiplier))))
                    default: break
                    }
                }
            }
        }
        current = initial + step * Float(frames)
    }
}
#endif
