import Foundation
import Testing
@testable import PrimuseKit

@Suite("Music Haptics Analyzer")
struct MusicHapticsAnalyzerTests {
    private let sampleRate = 48_000.0
    private let hopDuration = 0.02

    private func makeSine(frequency: Double, amplitude: Float, count: Int, phaseOffset: Double = 0) -> [Float] {
        (0..<count).map { idx in
            Float(Double(amplitude) * sin(2.0 * .pi * frequency * Double(idx) / sampleRate + phaseOffset))
        }
    }

    private func makeMixed(_ components: [(frequency: Double, amplitude: Float)], count: Int) -> [Float] {
        var samples = Array(repeating: Float(0), count: count)
        for comp in components {
            let phaseStep = 2.0 * .pi * comp.frequency / sampleRate
            for i in 0..<count {
                samples[i] += Float(Double(comp.amplitude) * sin(phaseStep * Double(i)))
            }
        }
        return samples
    }

    @Test("Silence and disabled state produce zero haptic output without phantom buzz")
    func silenceAndDisabled() {
        let analyzer = MusicHapticsAnalyzer(fftSize: 2048)
        let silence = Array(repeating: Float(0), count: 2048)
        let enabledConfig = MusicHapticsConfiguration(isEnabled: true, intensity: 0.8, style: .balanced)

        let frame = analyzer.analyzeWindow(silence, sampleRate: sampleRate, deltaTime: hopDuration, configuration: enabledConfig)
        #expect(frame.isSilent)
        #expect(frame.continuousIntensity == 0)
        #expect(frame.transients.isEmpty)

        // Disabled config always returns silent even on loud audio
        let loudBass = makeSine(frequency: 65, amplitude: 0.6, count: 2048)
        let disabledConfig = MusicHapticsConfiguration(isEnabled: false, intensity: 1.0, style: .immersive)
        let disabledFrame = analyzer.analyzeWindow(loudBass, sampleRate: sampleRate, deltaTime: hopDuration, configuration: disabledConfig)
        #expect(disabledFrame == .silent)

        // Zero intensity returns silent
        let zeroConfig = MusicHapticsConfiguration(isEnabled: true, intensity: 0.0, style: .balanced)
        let zeroFrame = analyzer.analyzeWindow(loudBass, sampleRate: sampleRate, deltaTime: hopDuration, configuration: zeroConfig)
        #expect(zeroFrame == .silent)
    }

    @Test("Sustained sub-bass produces smooth continuous texture with low sharpness, while high frequency raises sharpness")
    func continuousTextureAndSpectralSharpness() {
        let bassAnalyzer = MusicHapticsAnalyzer(fftSize: 2048)
        let brightAnalyzer = MusicHapticsAnalyzer(fftSize: 2048)
        let config = MusicHapticsConfiguration(isEnabled: true, intensity: 0.85, style: .balanced)

        let bassWindow = makeSine(frequency: 65, amplitude: 0.45, count: 2048)
        let brightWindow = makeMixed([(3200, 0.25), (5200, 0.20)], count: 2048)

        var bassFrame: MusicHapticsFrame = .silent
        var brightFrame: MusicHapticsFrame = .silent
        for _ in 0..<25 {
            bassFrame = bassAnalyzer.analyzeWindow(bassWindow, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
            brightFrame = brightAnalyzer.analyzeWindow(brightWindow, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        }

        #expect(!bassFrame.isSilent)
        #expect(bassFrame.continuousIntensity > 0.25)
        #expect(bassFrame.bandEnergies.low > bassFrame.bandEnergies.high)
        #expect(brightFrame.bandEnergies.high > brightFrame.bandEnergies.low)
        #expect(brightFrame.continuousSharpness > bassFrame.continuousSharpness + 0.15)
    }

    @Test("Kick, snare, and hi-hat onsets classify into distinct transient kinds with distinct sharpness")
    func transientClassification() {
        let config = MusicHapticsConfiguration(isEnabled: true, intensity: 0.9, style: .rhythmFocus)
        let quietBed = makeSine(frequency: 440, amplitude: 0.015, count: 2048)

        // 1. Kick onset (low 65 Hz burst)
        let kickAnalyzer = MusicHapticsAnalyzer(fftSize: 2048)
        for _ in 0..<8 {
            _ = kickAnalyzer.analyzeWindow(quietBed, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        }
        let kickBurst = makeMixed([(55, 0.55), (90, 0.35)], count: 2048)
        let kickFrame = kickAnalyzer.analyzeWindow(kickBurst, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        #expect(kickFrame.transients.first?.kind == .kick)
        let kickSharpness = kickFrame.transients.first?.sharpness ?? 1

        // 2. Snare onset (mid + high burst)
        let snareAnalyzer = MusicHapticsAnalyzer(fftSize: 2048)
        for _ in 0..<8 {
            _ = snareAnalyzer.analyzeWindow(quietBed, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        }
        let snareBurst = makeMixed([(320, 0.35), (750, 0.30), (3400, 0.28), (5200, 0.22)], count: 2048)
        let snareFrame = snareAnalyzer.analyzeWindow(snareBurst, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        #expect(snareFrame.transients.first?.kind == .snare)
        let snareSharpness = snareFrame.transients.first?.sharpness ?? 0

        // 3. Hi-hat onset (high-only burst)
        let hatAnalyzer = MusicHapticsAnalyzer(fftSize: 2048)
        for _ in 0..<8 {
            _ = hatAnalyzer.analyzeWindow(quietBed, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        }
        let hatBurst = makeMixed([(4800, 0.25), (6200, 0.25), (7400, 0.20)], count: 2048)
        let hatFrame = hatAnalyzer.analyzeWindow(hatBurst, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        #expect(hatFrame.transients.first?.kind == .hiHat)
        let hatSharpness = hatFrame.transients.first?.sharpness ?? 0

        #expect(kickSharpness < snareSharpness)
        #expect(snareSharpness < hatSharpness)
    }

    @Test("Minimum event spacing deduplicates rapid back-to-back transients")
    func transientDeduplication() {
        let analyzer = MusicHapticsAnalyzer(fftSize: 2048)
        let config = MusicHapticsConfiguration(isEnabled: true, intensity: 0.85, style: .balanced)
        let quiet = makeSine(frequency: 300, amplitude: 0.015, count: 2048)
        let kick = makeMixed([(60, 0.6), (100, 0.3)], count: 2048)

        for _ in 0..<8 {
            _ = analyzer.analyzeWindow(quiet, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        }

        // Fire three consecutive 20 ms hops of loud kick (only the first should emit a kick within 130 ms cooldown)
        let f1 = analyzer.analyzeWindow(kick, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        let f2 = analyzer.analyzeWindow(kick, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        let f3 = analyzer.analyzeWindow(kick, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        let totalKicks = [f1, f2, f3].flatMap(\.transients).filter { $0.kind == .kick }.count
        #expect(totalKicks == 1)
    }

    @Test("Style presets and user intensity meaningfully shape haptic dynamics")
    func stylePresetsAndIntensityScaling() {
        let bassWindow = makeMixed([(65, 0.45), (450, 0.12)], count: 2048)

        func steadyIntensity(style: MusicHapticsStyle, intensity: Double) -> Float {
            let analyzer = MusicHapticsAnalyzer(fftSize: 2048)
            let cfg = MusicHapticsConfiguration(isEnabled: true, intensity: intensity, style: style)
            var last: MusicHapticsFrame = .silent
            for _ in 0..<25 {
                last = analyzer.analyzeWindow(bassWindow, sampleRate: sampleRate, deltaTime: hopDuration, configuration: cfg)
            }
            return last.continuousIntensity
        }

        let bassFocusHigh = steadyIntensity(style: .bassFocus, intensity: 0.9)
        let subtleHigh = steadyIntensity(style: .subtle, intensity: 0.9)
        let balancedLow = steadyIntensity(style: .balanced, intensity: 0.25)
        let balancedHigh = steadyIntensity(style: .balanced, intensity: 0.95)

        #expect(bassFocusHigh > subtleHigh + 0.12)
        #expect(balancedHigh > balancedLow * 2.0)
    }

    @Test("Steady 120 BPM pulse builds beat confidence while reset clears state cleanly")
    func beatTrackingAndReset() {
        let analyzer = MusicHapticsAnalyzer(fftSize: 2048)
        let config = MusicHapticsConfiguration(isEnabled: true, intensity: 0.85, style: .rhythmFocus)
        let quiet = makeSine(frequency: 240, amplitude: 0.015, count: 2048)
        let kick = makeMixed([(60, 0.65), (95, 0.35)], count: 2048)

        // 120 BPM = 0.50 s per beat = every 25 hops at 20 ms/hop. Run for 6 seconds (12 beats).
        var lastFrame: MusicHapticsFrame = .silent
        for hop in 0..<300 {
            let isBeat = hop >= 10 && ((hop - 10) % 25 == 0)
            let window = isBeat ? kick : quiet
            lastFrame = analyzer.analyzeWindow(window, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        }

        #expect(lastFrame.beatConfidence >= 0.45)
        if let bpm = lastFrame.estimatedBPM {
            #expect(abs(bpm - 120.0) < 12.0)
        } else {
            Issue.record("Expected estimatedBPM for steady 120 BPM pulse")
        }

        // Reset must clear beat confidence, BPM, and continuous envelope.
        analyzer.reset()
        let silence = Array(repeating: Float(0), count: 2048)
        let afterReset = analyzer.analyzeWindow(silence, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config)
        #expect(afterReset.isSilent)
        #expect(afterReset.beatConfidence == 0)
        #expect(afterReset.estimatedBPM == nil)
    }

    @Test("Fade-out smoothly reduces continuous intensity to silence")
    func fadeOutEnvelope() {
        let analyzer = MusicHapticsAnalyzer(fftSize: 2048)
        let config = MusicHapticsConfiguration(isEnabled: true, intensity: 0.85, style: .balanced)
        let loud = makeSine(frequency: 70, amplitude: 0.5, count: 2048)
        let silence = Array(repeating: Float(0), count: 2048)

        var peak: Float = 0
        for _ in 0..<20 {
            peak = max(peak, analyzer.analyzeWindow(loud, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config).continuousIntensity)
        }
        #expect(peak > 0.3)

        var faded = peak
        for _ in 0..<30 {
            faded = analyzer.analyzeWindow(silence, sampleRate: sampleRate, deltaTime: hopDuration, configuration: config).continuousIntensity
        }
        #expect(faded < peak * 0.15)
    }
}
