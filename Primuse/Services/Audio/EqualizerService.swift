import AVFoundation
import Foundation
import PrimuseKit

@MainActor
@Observable
final class EqualizerService {
    private let audioEngine: AudioEngine
    var currentPreset: EQPreset = .flat
    var isEnabled: Bool = true {
        didSet { updateBypass() }
    }
    var bands: [Float] = Array(repeating: 0, count: PrimuseConstants.eqBandCount)

    init(audioEngine: AudioEngine) {
        self.audioEngine = audioEngine
    }

    func applyPreset(_ preset: EQPreset) {
        guard preset.bands.count == PrimuseConstants.eqBandCount else { return }
        currentPreset = preset
        bands = preset.bands

        for (index, gain) in preset.bands.enumerated() {
            setBand(index, gain: gain)
        }
    }

    func setBand(_ index: Int, gain: Float) {
        guard index >= 0, index < PrimuseConstants.eqBandCount else { return }
        let clampedGain = min(max(gain, PrimuseConstants.eqMinGain), PrimuseConstants.eqMaxGain)
        bands[index] = clampedGain
        audioEngine.eqNode?.bands[index].gain = clampedGain
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func reset() {
        applyPreset(.flat)
    }

    private func updateBypass() {
        guard let eqNode = audioEngine.eqNode else { return }
        for band in eqNode.bands {
            band.bypass = !isEnabled
        }
    }

    var bandFrequencyLabels: [String] {
        PrimuseConstants.eqBandFrequencies.map { freq in
            if freq >= 1000 {
                return "\(Int(freq / 1000))K"
            }
            return "\(Int(freq))"
        }
    }
}
