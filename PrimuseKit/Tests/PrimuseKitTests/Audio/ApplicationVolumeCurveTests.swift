import Foundation
import Testing
@testable import PrimuseKit

@Suite("Application volume curve")
struct ApplicationVolumeCurveTests {
    @Test("Position and gain round-trip and stay in range")
    func roundTrip() {
        for step in 0...20 {
            let position = Double(step) / 20
            let gain = ApplicationVolumeCurve.gain(forPosition: position)
            #expect(abs(ApplicationVolumeCurve.position(forGain: gain) - position) < 1e-6)
        }
        #expect(ApplicationVolumeCurve.gain(forPosition: -1) == 0)
        #expect(ApplicationVolumeCurve.gain(forPosition: 2) == 1)
        #expect(ApplicationVolumeCurve.position(forGain: .nan) == 1)
        #expect(ApplicationVolumeCurve.gain(forPosition: .infinity) == 1)
    }

    @Test("Half the slider is about -12 dB, leaving the quiet end room to fine-tune")
    func lowEndResolution() {
        let half = 20 * log10(Double(ApplicationVolumeCurve.gain(forPosition: 0.5)))
        #expect(abs(half - (-12.04)) < 0.05)
        let tenth = 20 * log10(Double(ApplicationVolumeCurve.gain(forPosition: 0.1)))
        #expect(abs(tenth - (-40)) < 0.05)
    }
}
