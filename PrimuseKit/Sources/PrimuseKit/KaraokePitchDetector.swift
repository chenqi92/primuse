import Foundation

/// One pitch reading of a short audio window.
public struct KaraokePitchEstimate: Equatable, Sendable {
    public var frequency: Double
    /// 0...1; how periodic the window was (1 − YIN aperiodicity).
    public var confidence: Double
    /// Root-mean-square level of the analysed window.
    public var level: Double

    public init(frequency: Double, confidence: Double, level: Double) {
        self.frequency = frequency
        self.confidence = confidence
        self.level = level
    }

    /// Fractional MIDI note number (A4 = 69).
    public var midiNote: Double {
        KaraokePitchDetector.midiNote(forFrequency: frequency)
    }
}

/// Monophonic pitch tracker (YIN, de Cheveigné & Kawahara 2002) for singing.
///
/// Scratch buffers are allocated once, so repeated `detect` calls do not
/// allocate. Not thread-safe: give each analysis queue its own instance.
public final class KaraokePitchDetector: @unchecked Sendable {
    public let sampleRate: Double
    public let windowSize: Int
    public let minimumFrequency: Double
    public let maximumFrequency: Double
    /// Aperiodicity threshold for accepting the first dip.
    public let threshold: Double
    /// Windows quieter than this RMS are treated as silence.
    public let silenceLevel: Double

    private let minimumLag: Int
    private let maximumLag: Int
    private let difference: UnsafeMutablePointer<Double>

    public init(
        sampleRate: Double,
        windowSize: Int = 2_048,
        minimumFrequency: Double = 70,
        maximumFrequency: Double = 1_100,
        threshold: Double = 0.15,
        silenceLevel: Double = 0.005
    ) {
        self.sampleRate = sampleRate
        self.windowSize = windowSize
        self.minimumFrequency = minimumFrequency
        self.maximumFrequency = maximumFrequency
        self.threshold = threshold
        self.silenceLevel = silenceLevel
        minimumLag = max(2, Int((sampleRate / maximumFrequency).rounded(.down)))
        maximumLag = min(windowSize / 2, Int((sampleRate / minimumFrequency).rounded(.up)))
        difference = .allocate(capacity: maximumLag + 2)
        difference.initialize(repeating: 0, count: maximumLag + 2)
    }

    deinit {
        difference.deallocate()
    }

    /// Samples the detector reads per call.
    public var requiredSampleCount: Int { windowSize }

    public static func midiNote(forFrequency frequency: Double) -> Double {
        69 + 12 * log2(frequency / 440)
    }

    public static func frequency(forMIDINote note: Double) -> Double {
        440 * pow(2, (note - 69) / 12)
    }

    /// Estimates the pitch of the first `windowSize` samples, or returns nil
    /// when the window is silent, too short or not periodic enough.
    public func detect(_ samples: UnsafeBufferPointer<Float>) -> KaraokePitchEstimate? {
        guard samples.count >= windowSize, maximumLag > minimumLag else { return nil }

        var energy = 0.0
        for index in 0..<windowSize {
            let value = Double(samples[index])
            energy += value * value
        }
        let level = (energy / Double(windowSize)).squareRoot()
        guard level >= silenceLevel else { return nil }

        // Squared-difference function over the first half of the window.
        let integration = windowSize - maximumLag
        difference[0] = 0
        for lag in 1...maximumLag {
            var sum = 0.0
            for index in 0..<integration {
                let delta = Double(samples[index]) - Double(samples[index + lag])
                sum += delta * delta
            }
            difference[lag] = sum
        }

        // Cumulative mean normalised difference.
        var runningSum = 0.0
        difference[0] = 1
        for lag in 1...maximumLag {
            runningSum += difference[lag]
            difference[lag] = runningSum > 0 ? difference[lag] * Double(lag) / runningSum : 1
        }

        var chosenLag = -1
        var lag = minimumLag
        while lag <= maximumLag {
            if difference[lag] < threshold {
                while lag + 1 <= maximumLag, difference[lag + 1] < difference[lag] {
                    lag += 1
                }
                chosenLag = lag
                break
            }
            lag += 1
        }
        guard chosenLag > 0 else { return nil }

        // Parabolic interpolation around the dip for sub-sample precision.
        var refinedLag = Double(chosenLag)
        if chosenLag > minimumLag, chosenLag < maximumLag {
            let previous = difference[chosenLag - 1]
            let current = difference[chosenLag]
            let next = difference[chosenLag + 1]
            let denominator = previous - 2 * current + next
            if abs(denominator) > 1e-12 {
                refinedLag += 0.5 * (previous - next) / denominator
            }
        }
        let frequency = sampleRate / refinedLag
        guard frequency >= minimumFrequency, frequency <= maximumFrequency else { return nil }
        let confidence = max(0, min(1, 1 - difference[chosenLag]))
        return KaraokePitchEstimate(frequency: frequency, confidence: confidence, level: level)
    }

    public func detect(_ samples: [Float]) -> KaraokePitchEstimate? {
        samples.withUnsafeBufferPointer { detect($0) }
    }
}
