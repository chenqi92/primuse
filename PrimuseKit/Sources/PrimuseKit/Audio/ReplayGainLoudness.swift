import Foundation

/// BS.1770 K-weighting, 400 ms windows / 100 ms hops and the R128 absolute
/// (-70 LUFS) and relative (-10 LU) gates. Windows are retained so an album
/// can be gated as one programme instead of averaging its tracks' decibels.
public struct ReplayGainLoudnessMeasurement: Codable, Equatable, Sendable {
    public let blockEnergies: [Double]
    public let peak: Double
    public let duration: Double

    public init(blockEnergies: [Double], peak: Double, duration: Double) {
        self.blockEnergies = blockEnergies
        self.peak = peak
        self.duration = duration
    }

    public var integratedLUFS: Double? {
        let absolute = pow(10, (-70 + 0.691) / 10)
        let audible = blockEnergies.filter { $0.isFinite && $0 >= absolute }
        guard !audible.isEmpty else { return nil }
        let relative = audible.reduce(0, +) / Double(audible.count) / 10
        let gated = audible.filter { $0 >= relative }
        guard !gated.isEmpty else { return nil }
        return -0.691 + 10 * log10(gated.reduce(0, +) / Double(gated.count))
    }

    public var adjustment: ReplayGainAdjustment {
        .init(gain: integratedLUFS.map { -18 - $0 }, peak: peak)
    }

    public static func album(_ tracks: [Self]) -> Self? {
        guard !tracks.isEmpty else { return nil }
        return Self(blockEnergies: tracks.flatMap(\.blockEnergies),
                    peak: tracks.map(\.peak).max() ?? 0,
                    duration: tracks.reduce(0) { $0 + $1.duration })
    }
}

public struct ReplayGainLoudnessAnalyzer: Sendable {
    private struct Biquad: Sendable {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private let sampleRate: Double
    private let weights: [Double]
    private let hopFrames: Int
    private var shelves: [Biquad]
    private var highpasses: [Biquad]
    private var hopEnergy = 0.0
    private var hopCount = 0
    private var recentHops: [Double] = []
    private var blocks: [Double] = []
    private var frames = 0
    private var peak = 0.0
    private var valid = true

    public init?(sampleRate: Double, channelWeights: [Double]) {
        guard sampleRate.isFinite, (8000...768000).contains(sampleRate),
              !channelWeights.isEmpty, channelWeights.count <= 32,
              channelWeights.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        self.sampleRate = sampleRate
        weights = channelWeights
        hopFrames = Int((sampleRate / 10).rounded())
        // Bilinear-transform form of the BS.1770 pre-filter, valid at the
        // decoder's sample rate (the published 48 kHz coefficients alone
        // would measure 44.1 / 96 kHz material incorrectly).
        let k = tan(.pi * 1681.974450955533 / sampleRate)
        let q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        let d = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / d,
                           b1: 2 * (k * k - vh) / d,
                           b2: (vh - vb * k / q + k * k) / d,
                           a1: 2 * (k * k - 1) / d,
                           a2: (1 - k / q + k * k) / d)
        let h = tan(.pi * 38.13547087602444 / sampleRate)
        let hq = 0.5003270373238773
        let hd = 1 + h / hq + h * h
        let highpass = Biquad(b0: 1, b1: -2, b2: 1,
                             a1: 2 * (h * h - 1) / hd,
                             a2: (1 - h / hq + h * h) / hd)
        shelves = Array(repeating: shelf, count: channelWeights.count)
        highpasses = Array(repeating: highpass, count: channelWeights.count)
    }

    public mutating func append(planarSamples: [[Float]]) {
        guard planarSamples.count == weights.count,
              let count = planarSamples.first?.count,
              planarSamples.allSatisfy({ $0.count == count }) else { valid = false; return }
        for frame in 0..<count {
            var energy = 0.0
            for channel in weights.indices {
                let sample = Double(planarSamples[channel][frame])
                guard sample.isFinite else { valid = false; continue }
                peak = max(peak, abs(sample))
                let filtered = highpasses[channel].process(shelves[channel].process(sample))
                energy += weights[channel] * filtered * filtered
            }
            hopEnergy += energy
            hopCount += 1
            frames += 1
            if hopCount == hopFrames {
                recentHops.append(hopEnergy)
                if recentHops.count == 4 {
                    let block = recentHops.reduce(0, +) / Double(4 * hopFrames)
                    // Below the absolute gate these windows cannot contribute
                    // to a track or to an album. Discard them at the source.
                    if block >= pow(10, (-70 + 0.691) / 10) { blocks.append(block) }
                    recentHops.removeFirst()
                }
                hopEnergy = 0
                hopCount = 0
            }
        }
    }

    public var measurement: ReplayGainLoudnessMeasurement? {
        guard valid, frames >= 4 * hopFrames, peak.isFinite else { return nil }
        return .init(blockEnergies: blocks, peak: peak, duration: Double(frames) / sampleRate)
    }
}
