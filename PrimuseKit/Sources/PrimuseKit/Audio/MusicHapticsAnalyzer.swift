import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// User-selectable tactile profiles shaping continuous texture and rhythmic accents (#469).
public enum MusicHapticsStyle: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case balanced
    case bassFocus
    case rhythmFocus
    case subtle
    case immersive

    public var id: String { rawValue }

    public var parameters: MusicHapticsStyleParameters {
        switch self {
        case .balanced:
            MusicHapticsStyleParameters(
                continuousGain: 0.72,
                continuousBassWeight: 0.56,
                continuousMidWeight: 0.30,
                continuousHighWeight: 0.14,
                continuousSharpnessBase: 0.16,
                continuousSharpnessSpectralScale: 0.44,
                kickThreshold: 1.45,
                snareThreshold: 1.65,
                hiHatThreshold: 2.05,
                kickGain: 0.90,
                snareGain: 0.74,
                hiHatGain: 0.34,
                bassAttackGain: 0.58,
                transientMinSpacingSeconds: 0.060,
                attackTimeSeconds: 0.042,
                releaseTimeSeconds: 0.175
            )
        case .bassFocus:
            MusicHapticsStyleParameters(
                continuousGain: 0.88,
                continuousBassWeight: 0.78,
                continuousMidWeight: 0.17,
                continuousHighWeight: 0.05,
                continuousSharpnessBase: 0.08,
                continuousSharpnessSpectralScale: 0.24,
                kickThreshold: 1.22,
                snareThreshold: 2.00,
                hiHatThreshold: 2.65,
                kickGain: 1.00,
                snareGain: 0.50,
                hiHatGain: 0.18,
                bassAttackGain: 0.78,
                transientMinSpacingSeconds: 0.070,
                attackTimeSeconds: 0.036,
                releaseTimeSeconds: 0.220
            )
        case .rhythmFocus:
            MusicHapticsStyleParameters(
                continuousGain: 0.44,
                continuousBassWeight: 0.48,
                continuousMidWeight: 0.34,
                continuousHighWeight: 0.18,
                continuousSharpnessBase: 0.22,
                continuousSharpnessSpectralScale: 0.48,
                kickThreshold: 1.25,
                snareThreshold: 1.40,
                hiHatThreshold: 1.70,
                kickGain: 0.98,
                snareGain: 0.88,
                hiHatGain: 0.46,
                bassAttackGain: 0.65,
                transientMinSpacingSeconds: 0.050,
                attackTimeSeconds: 0.028,
                releaseTimeSeconds: 0.115
            )
        case .subtle:
            MusicHapticsStyleParameters(
                continuousGain: 0.40,
                continuousBassWeight: 0.60,
                continuousMidWeight: 0.28,
                continuousHighWeight: 0.12,
                continuousSharpnessBase: 0.12,
                continuousSharpnessSpectralScale: 0.30,
                kickThreshold: 1.80,
                snareThreshold: 2.05,
                hiHatThreshold: 2.55,
                kickGain: 0.56,
                snareGain: 0.42,
                hiHatGain: 0.20,
                bassAttackGain: 0.38,
                transientMinSpacingSeconds: 0.085,
                attackTimeSeconds: 0.060,
                releaseTimeSeconds: 0.240
            )
        case .immersive:
            MusicHapticsStyleParameters(
                continuousGain: 0.94,
                continuousBassWeight: 0.52,
                continuousMidWeight: 0.32,
                continuousHighWeight: 0.16,
                continuousSharpnessBase: 0.18,
                continuousSharpnessSpectralScale: 0.56,
                kickThreshold: 1.30,
                snareThreshold: 1.50,
                hiHatThreshold: 1.85,
                kickGain: 1.00,
                snareGain: 0.86,
                hiHatGain: 0.42,
                bassAttackGain: 0.72,
                transientMinSpacingSeconds: 0.055,
                attackTimeSeconds: 0.032,
                releaseTimeSeconds: 0.195
            )
        }
    }
}

public struct MusicHapticsStyleParameters: Equatable, Sendable {
    public let continuousGain: Float
    public let continuousBassWeight: Float
    public let continuousMidWeight: Float
    public let continuousHighWeight: Float
    public let continuousSharpnessBase: Float
    public let continuousSharpnessSpectralScale: Float
    public let kickThreshold: Float
    public let snareThreshold: Float
    public let hiHatThreshold: Float
    public let kickGain: Float
    public let snareGain: Float
    public let hiHatGain: Float
    public let bassAttackGain: Float
    public let transientMinSpacingSeconds: TimeInterval
    public let attackTimeSeconds: TimeInterval
    public let releaseTimeSeconds: TimeInterval
}

public struct MusicHapticsConfiguration: Equatable, Sendable {
    public static let defaultIntensity: Double = 0.75
    public static let intensityRange: ClosedRange<Double> = 0.0...1.0

    public var isEnabled: Bool
    public var intensity: Double
    public var style: MusicHapticsStyle

    public init(
        isEnabled: Bool = false,
        intensity: Double = MusicHapticsConfiguration.defaultIntensity,
        style: MusicHapticsStyle = .balanced
    ) {
        self.isEnabled = isEnabled
        self.intensity = Self.clampedIntensity(intensity)
        self.style = style
    }

    public static func clampedIntensity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultIntensity }
        return min(intensityRange.upperBound, max(intensityRange.lowerBound, value))
    }
}

/// Multi-band normalized energy telemetry for testing and live visualizers.
public struct MusicHapticsBandEnergies: Equatable, Sendable {
    public let low: Float   // 20–180 Hz
    public let mid: Float   // 180–2000 Hz
    public let high: Float  // 2000–8000 Hz

    public static let zero = MusicHapticsBandEnergies(low: 0, mid: 0, high: 0)

    public init(low: Float, mid: Float, high: Float) {
        self.low = low
        self.mid = mid
        self.high = high
    }
}

/// Layer B rhythmic transient accent synthesized from spectral flux onsets.
public struct MusicHapticsTransient: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case kick
        case snare
        case bassAttack
        case hiHat
    }

    public let kind: Kind
    public let intensity: Float
    public let sharpness: Float

    public init(kind: Kind, intensity: Float, sharpness: Float) {
        self.kind = kind
        self.intensity = min(1, max(0, intensity))
        self.sharpness = min(1, max(0, sharpness))
    }
}

/// Output of one real-time analysis hop (~20 ms): Layer A continuous parameters +
/// Layer B deduplicated rhythmic transients + Layer C beat/energy state.
public struct MusicHapticsFrame: Equatable, Sendable {
    public let continuousIntensity: Float
    public let continuousSharpness: Float
    public let transients: [MusicHapticsTransient]
    public let bandEnergies: MusicHapticsBandEnergies
    public let beatConfidence: Float
    public let estimatedBPM: Double?
    public let isSilent: Bool

    public static let silent = MusicHapticsFrame(
        continuousIntensity: 0,
        continuousSharpness: 0.15,
        transients: [],
        bandEnergies: .zero,
        beatConfidence: 0,
        estimatedBPM: nil,
        isSilent: true
    )

    public init(
        continuousIntensity: Float,
        continuousSharpness: Float,
        transients: [MusicHapticsTransient],
        bandEnergies: MusicHapticsBandEnergies,
        beatConfidence: Float,
        estimatedBPM: Double?,
        isSilent: Bool
    ) {
        self.continuousIntensity = min(1, max(0, continuousIntensity))
        self.continuousSharpness = min(1, max(0, continuousSharpness))
        self.transients = transients
        self.bandEnergies = bandEnergies
        self.beatConfidence = min(1, max(0, beatConfidence))
        self.estimatedBPM = estimatedBPM
        self.isSilent = isSilent
    }
}

/// Real-time multi-band audio-to-haptics analyzer (#469).
///
/// Architecture:
/// - **Multi-Band FFT (vDSP)**: Extracts Low (20–180 Hz), Mid (180–2000 Hz), High (2000–8000 Hz)
///   energies, positive spectral flux per band, and normalized spectral centroid with zero per-hop
///   heap allocations after initialization.
/// - **Layer A (Continuous Texture)**: Rolling adaptive loudness normalization + macro-dynamic
///   contour + asymmetric attack/release envelope smoothing driving continuous intensity and
///   spectral sharpness.
/// - **Layer B (Transient Accents)**: Adaptive spectral-flux onset detectors for kicks, bass
///   attacks, snares, and hi-hats with priority selection and per-band + global spacing guards.
/// - **Layer C (Tempo / Beat Confidence)**: Lightweight inter-onset interval tracker that gently
///   reinforces beat-aligned accents on rhythmic tracks and smoothly decays to neutral on ambient
///   or irregular material.
///
/// Owners must call `analyzeWindow` from a single serialized queue or task.
public final class MusicHapticsAnalyzer: @unchecked Sendable {
    public let fftSize: Int
    private let log2n: Int
    private let halfSize: Int

    // Pre-allocated DSP scratch buffers (zero heap allocation per hop).
    private var inputBuffer: [Float]
    private var hannWindow: [Float]
    private var windowedBuffer: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var magnitudesSq: [Float]
    private var magnitudes: [Float]
    private var previousMagnitudes: [Float]
    #if canImport(Accelerate)
    private let fft: vDSP.FFT<DSPSplitComplex>?
    #endif

    // Layer C adaptive dynamics & normalization state.
    private var elapsedTime: TimeInterval = 0
    private var hasPreviousSpectrum = false
    private var rollingEnergyRef: Float = 0.06
    private var macroEnergySlow: Float = 0.06
    private var macroEnergyMedium: Float = 0.0
    private var smoothedContinuousIntensity: Float = 0
    private var smoothedContinuousSharpness: Float = 0.22
    private var smoothedLow: Float = 0
    private var smoothedMid: Float = 0
    private var smoothedHigh: Float = 0

    // Adaptive spectral flux baselines & rising-edge trackers.
    private var lowFluxMean: Float = 0.002
    private var lowFluxDev: Float = 0.001
    private var prevLowFlux: Float = 0

    private var midFluxMean: Float = 0.002
    private var midFluxDev: Float = 0.001
    private var prevMidFlux: Float = 0

    private var highFluxMean: Float = 0.0015
    private var highFluxDev: Float = 0.0008
    private var prevHighFlux: Float = 0

    // Transient spacing / deduplication timestamps.
    private var lastTransientTime: TimeInterval = -10
    private var lastTransientKind: MusicHapticsTransient.Kind?
    private var lastKickTime: TimeInterval = -10
    private var lastSnareTime: TimeInterval = -10
    private var lastBassAttackTime: TimeInterval = -10
    private var lastHiHatTime: TimeInterval = -10

    // Lightweight beat confidence tracker (fixed ring of 16 recent rhythmic onsets).
    private static let onsetHistoryCapacity = 16
    private var onsetTimes: [TimeInterval] = Array(repeating: 0, count: onsetHistoryCapacity)
    private var onsetCount: Int = 0
    private var onsetWriteIndex: Int = 0
    private var estimatedBeatPeriod: TimeInterval?
    private var beatConfidence: Float = 0
    private var lastStrongBeatTime: TimeInterval = -10

    // Silence threshold (~ -55 dBFS).
    private static let silenceRMSThreshold: Float = 0.0018

    public static func preferredFFTSize(forSampleRate sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 2048 }
        if sampleRate >= 88_200 { return 4096 }
        if sampleRate <= 24_000 { return 1024 }
        return 2048
    }

    public init(fftSize: Int = 2048) {
        let clampedExp = min(13, max(9, Int(log2(Double(max(512, fftSize))).rounded())))
        self.log2n = clampedExp
        self.fftSize = 1 << clampedExp
        self.halfSize = self.fftSize / 2
        self.inputBuffer = Array(repeating: 0, count: self.fftSize)
        self.hannWindow = Array(repeating: 0, count: self.fftSize)
        self.windowedBuffer = Array(repeating: 0, count: self.fftSize)
        self.realBuffer = Array(repeating: 0, count: self.halfSize)
        self.imagBuffer = Array(repeating: 0, count: self.halfSize)
        self.magnitudesSq = Array(repeating: 0, count: self.halfSize)
        self.magnitudes = Array(repeating: 0, count: self.halfSize)
        self.previousMagnitudes = Array(repeating: 0, count: self.halfSize)

        #if canImport(Accelerate)
        vDSP_hann_window(&self.hannWindow, vDSP_Length(self.fftSize), Int32(vDSP_HANN_NORM))
        self.fft = vDSP.FFT(log2n: vDSP_Length(clampedExp), radix: .radix2, ofType: DSPSplitComplex.self)
        #else
        let denom = Float(max(1, self.fftSize - 1))
        for i in 0..<self.fftSize {
            self.hannWindow[i] = 0.5 * (1.0 - cosf(2.0 * .pi * Float(i) / denom))
        }
        #endif
    }

    /// Resets all adaptive envelopes, flux baselines, transient cooldowns, and tempo tracking.
    /// Call on track change, seek, pause, interruption, or playback rate change.
    public func reset() {
        elapsedTime = 0
        hasPreviousSpectrum = false
        rollingEnergyRef = 0.06
        macroEnergySlow = 0.06
        macroEnergyMedium = 0
        smoothedContinuousIntensity = 0
        smoothedContinuousSharpness = 0.22
        smoothedLow = 0
        smoothedMid = 0
        smoothedHigh = 0
        lowFluxMean = 0.002
        lowFluxDev = 0.001
        prevLowFlux = 0
        midFluxMean = 0.002
        midFluxDev = 0.001
        prevMidFlux = 0
        highFluxMean = 0.0015
        highFluxDev = 0.0008
        prevHighFlux = 0
        lastTransientTime = -10
        lastTransientKind = nil
        lastKickTime = -10
        lastSnareTime = -10
        lastBassAttackTime = -10
        lastHiHatTime = -10
        onsetCount = 0
        onsetWriteIndex = 0
        estimatedBeatPeriod = nil
        beatConfidence = 0
        lastStrongBeatTime = -10
        for i in 0..<halfSize {
            previousMagnitudes[i] = 0
            magnitudes[i] = 0
        }
    }

    public func analyzeWindow(
        _ samples: [Float],
        sampleRate: Double,
        deltaTime: TimeInterval,
        configuration: MusicHapticsConfiguration
    ) -> MusicHapticsFrame {
        samples.withUnsafeBufferPointer { ptr in
            analyzeWindow(ptr, sampleRate: sampleRate, deltaTime: deltaTime, configuration: configuration)
        }
    }

    public func analyzeWindow(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        deltaTime: TimeInterval,
        configuration: MusicHapticsConfiguration
    ) -> MusicHapticsFrame {
        let userIntensity = Float(MusicHapticsConfiguration.clampedIntensity(configuration.intensity))
        guard configuration.isEnabled, userIntensity > 0.001,
              sampleRate.isFinite, sampleRate > 0,
              !samples.isEmpty else {
            return .silent
        }

        let dt = deltaTime.isFinite && deltaTime > 0 ? min(deltaTime, 0.25) : 0.02
        elapsedTime += dt
        let params = configuration.style.parameters

        // Copy samples into pre-allocated input buffer (right-aligned if shorter so newest samples sit at end).
        let copyCount = min(samples.count, fftSize)
        if copyCount < fftSize {
            let pad = fftSize - copyCount
            for i in 0..<pad { inputBuffer[i] = 0 }
            if let base = samples.baseAddress {
                inputBuffer.withUnsafeMutableBufferPointer { dst in
                    (dst.baseAddress! + pad).update(from: base, count: copyCount)
                }
            }
        } else if let base = samples.baseAddress {
            let srcOffset = samples.count - fftSize
            inputBuffer.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: base + srcOffset, count: fftSize)
            }
        }

        // Compute time-domain RMS and recent tail RMS for accurate silence gating and attack punch.
        let rms = computeRMS(buffer: inputBuffer, start: 0, count: fftSize)
        let tailCount = min(fftSize, max(128, Int(sampleRate * 0.015)))
        let tailRMS = computeRMS(buffer: inputBuffer, start: fftSize - tailCount, count: tailCount)
        let activeRMS = max(rms, tailRMS)

        if activeRMS < Self.silenceRMSThreshold {
            let decayAlpha = smoothingAlpha(dt: dt, tau: max(0.05, params.releaseTimeSeconds * 0.55))
            smoothedContinuousIntensity *= (1 - decayAlpha)
            if smoothedContinuousIntensity < 0.01 { smoothedContinuousIntensity = 0 }
            smoothedLow *= (1 - decayAlpha)
            smoothedMid *= (1 - decayAlpha)
            smoothedHigh *= (1 - decayAlpha)
            decayBeatConfidence(dt: dt)
            hasPreviousSpectrum = false
            return MusicHapticsFrame(
                continuousIntensity: smoothedContinuousIntensity,
                continuousSharpness: smoothedContinuousSharpness,
                transients: [],
                bandEnergies: MusicHapticsBandEnergies(low: smoothedLow, mid: smoothedMid, high: smoothedHigh),
                beatConfidence: beatConfidence,
                estimatedBPM: estimatedBeatPeriod.map { 60.0 / $0 },
                isSilent: smoothedContinuousIntensity < 0.01
            )
        }

        // Compute windowed magnitude spectrum.
        computeMagnitudeSpectrum()

        // Frequency bin ranges: Low (20–180 Hz), Mid (180–2000 Hz), High (2000–8000 Hz).
        let binWidth = sampleRate / Double(fftSize)
        let lowLo = max(1, Int(floor(20.0 / binWidth)))
        let lowHi = min(halfSize - 1, max(lowLo, Int(ceil(180.0 / binWidth))))
        let midLo = min(halfSize - 1, lowHi + 1)
        let midHi = min(halfSize - 1, max(midLo, Int(ceil(2000.0 / binWidth))))
        let highLo = min(halfSize - 1, midHi + 1)
        let highHi = min(halfSize - 1, max(highLo, Int(ceil(8000.0 / binWidth))))

        let lowStats = bandEnergyAndFlux(from: lowLo, through: lowHi)
        let midStats = bandEnergyAndFlux(from: midLo, through: midHi)
        let highStats = bandEnergyAndFlux(from: highLo, through: highHi)

        // Spectral centroid across 40–8000 Hz normalized into 0...1 (log-mapped for perceptual linearity).
        let centroidNormalized = computeNormalizedSpectralCentroid(from: lowLo, through: highHi, binWidth: binWidth)

        // Save spectrum for next hop's positive spectral flux.
        for i in 0..<halfSize { previousMagnitudes[i] = magnitudes[i] }
        let hadPrevious = hasPreviousSpectrum
        hasPreviousSpectrum = true

        // Layer C: Rolling adaptive normalization (preserves macro build-ups/drops while adapting to mastering loudness).
        let refTau: TimeInterval = activeRMS > rollingEnergyRef ? 1.8 : 5.5
        let refAlpha = smoothingAlpha(dt: dt, tau: refTau)
        rollingEnergyRef = max(0.012, min(0.65, rollingEnergyRef + (activeRMS - rollingEnergyRef) * refAlpha))

        let medAlpha = smoothingAlpha(dt: dt, tau: 0.45)
        macroEnergyMedium += (activeRMS - macroEnergyMedium) * medAlpha
        let slowAlpha = smoothingAlpha(dt: dt, tau: 4.5)
        macroEnergySlow = max(0.012, macroEnergySlow + (activeRMS - macroEnergySlow) * slowAlpha)

        // Macro contour in ~0.55...1.35: lets breakdowns soften and choruses/drops swell naturally.
        let macroRatio = clamp(macroEnergyMedium / max(macroEnergySlow, 0.012), min: 0.55, max: 1.38)

        // Normalize per-band energy against adaptive reference with perceptual compression.
        let normScale = max(rollingEnergyRef * 1.15, 0.018)
        let normLow = perceptualCurve(lowStats.energy / (normScale * 0.95))
        let normMid = perceptualCurve(midStats.energy / (normScale * 0.85))
        let normHigh = perceptualCurve(highStats.energy / (normScale * 0.65))

        // Smooth band telemetry.
        let telemetryAlpha = smoothingAlpha(dt: dt, tau: 0.06)
        smoothedLow += (normLow - smoothedLow) * telemetryAlpha
        smoothedMid += (normMid - smoothedMid) * telemetryAlpha
        smoothedHigh += (normHigh - smoothedHigh) * telemetryAlpha

        // Layer A: Continuous haptic texture intensity & sharpness.
        let weightedEnergy = normLow * params.continuousBassWeight
            + normMid * params.continuousMidWeight
            + normHigh * params.continuousHighWeight
        let rawContinuous = clamp(
            weightedEnergy * params.continuousGain * macroRatio * userIntensity,
            min: 0,
            max: 1
        )
        let envTau = rawContinuous >= smoothedContinuousIntensity
            ? params.attackTimeSeconds
            : params.releaseTimeSeconds
        let envAlpha = smoothingAlpha(dt: dt, tau: envTau)
        smoothedContinuousIntensity += (rawContinuous - smoothedContinuousIntensity) * envAlpha

        let targetSharpness = clamp(
            params.continuousSharpnessBase + centroidNormalized * params.continuousSharpnessSpectralScale,
            min: 0.05,
            max: 0.95
        )
        let sharpAlpha = smoothingAlpha(dt: dt, tau: 0.11)
        smoothedContinuousSharpness += (targetSharpness - smoothedContinuousSharpness) * sharpAlpha

        // Layer B: Rhythmic transient detection with adaptive flux thresholds & beat confidence weighting.
        decayBeatConfidence(dt: dt)
        var emittedTransients: [MusicHapticsTransient] = []

        if hadPrevious {
            let fluxAlpha = smoothingAlpha(dt: dt, tau: 0.38)

            // Update adaptive baselines BEFORE comparing? No: evaluate against running baseline, then update!
            let lowRatio = onsetRatio(flux: lowStats.flux, mean: lowFluxMean, dev: lowFluxDev)
            let midRatio = onsetRatio(flux: midStats.flux, mean: midFluxMean, dev: midFluxDev)
            let highRatio = onsetRatio(flux: highStats.flux, mean: highFluxMean, dev: highFluxDev)

            // Rising-edge check avoids firing multiple times on a single broad drum body.
            let lowRising = lowStats.flux > prevLowFlux * 0.92 && lowStats.energy > 0.008
            let midRising = midStats.flux > prevMidFlux * 0.92 && midStats.energy > 0.007
            let highRising = highStats.flux > prevHighFlux * 0.92 && highStats.energy > 0.004

            // Beat phase alignment multiplier (1.0 neutral when beatConfidence is low / ambient music).
            let beatMultiplier = currentBeatPhaseMultiplier()

            var candidate: MusicHapticsTransient?
            var candidatePriority = 0

            // 1. Kick: dominant low-frequency onset.
            if lowRising,
               lowRatio >= params.kickThreshold,
               (elapsedTime - lastKickTime) >= 0.13,
               normLow >= 0.22 {
                let rawStrength = clamp((lowRatio - params.kickThreshold * 0.65) / 2.2, min: 0.35, max: 1.0)
                let intensity = clamp(rawStrength * params.kickGain * beatMultiplier * userIntensity, min: 0, max: 1)
                // If crisp high-frequency attack coincides with kick, enrich sharpness slightly instead of double-firing.
                let hiBonus: Float = highRatio >= params.hiHatThreshold ? 0.07 : 0
                let sharpness = clamp(0.14 + normMid * 0.10 + hiBonus, min: 0.10, max: 0.36)
                candidate = MusicHapticsTransient(kind: .kick, intensity: intensity, sharpness: sharpness)
                candidatePriority = 4
            }

            // 2. Snare: strong mid + high burst (not dominated by sub-bass kick).
            if candidate == nil,
               midRising,
               midRatio >= params.snareThreshold,
               (highRatio >= params.hiHatThreshold * 0.68 || normHigh >= 0.20),
               (elapsedTime - lastSnareTime) >= 0.11,
               normMid >= 0.20 {
                let combinedRatio = midRatio * 0.62 + highRatio * 0.38
                let rawStrength = clamp((combinedRatio - params.snareThreshold * 0.6) / 2.3, min: 0.30, max: 1.0)
                let intensity = clamp(rawStrength * params.snareGain * beatMultiplier * userIntensity, min: 0, max: 1)
                let sharpness = clamp(0.54 + normHigh * 0.22, min: 0.48, max: 0.78)
                candidate = MusicHapticsTransient(kind: .snare, intensity: intensity, sharpness: sharpness)
                candidatePriority = 3
            }

            // 3. Bass attack: moderate low-end pluck/swell when kick didn't trigger.
            if candidate == nil,
               lowRising,
               lowRatio >= params.kickThreshold * 0.78,
               (elapsedTime - lastBassAttackTime) >= 0.14,
               (elapsedTime - lastKickTime) >= 0.12,
               normLow >= 0.18 {
                let rawStrength = clamp((lowRatio - params.kickThreshold * 0.50) / 2.0, min: 0.25, max: 0.85)
                let intensity = clamp(rawStrength * params.bassAttackGain * userIntensity, min: 0, max: 1)
                let sharpness = clamp(0.20 + normMid * 0.12, min: 0.16, max: 0.38)
                candidate = MusicHapticsTransient(kind: .bassAttack, intensity: intensity, sharpness: sharpness)
                candidatePriority = 2
            }

            // 4. Hi-hat / bright percussion: crisp high-frequency onset.
            if candidate == nil,
               highRising,
               highRatio >= params.hiHatThreshold,
               (elapsedTime - lastHiHatTime) >= 0.075,
               normHigh >= 0.14 {
                let rawStrength = clamp((highRatio - params.hiHatThreshold * 0.65) / 2.5, min: 0.22, max: 0.85)
                let intensity = clamp(rawStrength * params.hiHatGain * userIntensity, min: 0, max: 1)
                let sharpness = clamp(0.78 + centroidNormalized * 0.17, min: 0.74, max: 0.96)
                candidate = MusicHapticsTransient(kind: .hiHat, intensity: intensity, sharpness: sharpness)
                candidatePriority = 1
            }

            // Global deduplication & spacing check (higher-priority kick/snare can preempt recent hi-hat).
            if let transient = candidate, transient.intensity >= 0.08 {
                let sinceLast = elapsedTime - lastTransientTime
                let prevPriority = priority(of: lastTransientKind)
                let spacingOK = sinceLast >= params.transientMinSpacingSeconds
                    || (candidatePriority >= 3 && prevPriority <= 1 && sinceLast >= 0.025)

                if spacingOK {
                    emittedTransients.append(transient)
                    lastTransientTime = elapsedTime
                    lastTransientKind = transient.kind
                    switch transient.kind {
                    case .kick:
                        lastKickTime = elapsedTime
                        recordBeatOnset(at: elapsedTime)
                    case .snare:
                        lastSnareTime = elapsedTime
                        recordBeatOnset(at: elapsedTime)
                    case .bassAttack:
                        lastBassAttackTime = elapsedTime
                    case .hiHat:
                        lastHiHatTime = elapsedTime
                    }
                }
            }

            // Update adaptive flux baselines smoothly after onset evaluation.
            updateFluxStats(flux: lowStats.flux, mean: &lowFluxMean, dev: &lowFluxDev, alpha: fluxAlpha)
            updateFluxStats(flux: midStats.flux, mean: &midFluxMean, dev: &midFluxDev, alpha: fluxAlpha)
            updateFluxStats(flux: highStats.flux, mean: &highFluxMean, dev: &highFluxDev, alpha: fluxAlpha)
            prevLowFlux = lowStats.flux
            prevMidFlux = midStats.flux
            prevHighFlux = highStats.flux
        }

        return MusicHapticsFrame(
            continuousIntensity: smoothedContinuousIntensity,
            continuousSharpness: smoothedContinuousSharpness,
            transients: emittedTransients,
            bandEnergies: MusicHapticsBandEnergies(low: smoothedLow, mid: smoothedMid, high: smoothedHigh),
            beatConfidence: beatConfidence,
            estimatedBPM: estimatedBeatPeriod.map { 60.0 / $0 },
            isSilent: false
        )
    }

    // MARK: - DSP Primitives

    private func computeRMS(buffer: [Float], start: Int, count: Int) -> Float {
        guard count > 0, start >= 0, start + count <= buffer.count else { return 0 }
        #if canImport(Accelerate)
        var rms: Float = 0
        buffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            vDSP_rmsqv(base + start, 1, &rms, vDSP_Length(count))
        }
        return rms.isFinite ? rms : 0
        #else
        var sumSq: Float = 0
        for i in start..<(start + count) {
            let v = buffer[i]
            sumSq += v * v
        }
        return sqrtf(sumSq / Float(count))
        #endif
    }

    private func computeMagnitudeSpectrum() {
        #if canImport(Accelerate)
        guard let fft else { return }
        vDSP_vmul(inputBuffer, 1, hannWindow, 1, &windowedBuffer, 1, vDSP_Length(fftSize))
        windowedBuffer.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: DSPComplex.self).baseAddress else { return }
            realBuffer.withUnsafeMutableBufferPointer { rBuf in
                imagBuffer.withUnsafeMutableBufferPointer { iBuf in
                    guard let rBase = rBuf.baseAddress, let iBase = iBuf.baseAddress else { return }
                    var split = DSPSplitComplex(realp: rBase, imagp: iBase)
                    vDSP_ctoz(src, 2, &split, 1, vDSP_Length(halfSize))
                    fft.forward(input: split, output: &split)
                    vDSP_zvmags(&split, 1, &magnitudesSq, 1, vDSP_Length(halfSize))
                }
            }
        }
        var count = Int32(halfSize)
        vvsqrtf(&magnitudes, magnitudesSq, &count)
        // Compensate for vDSP forward FFT scaling + Hann window coherent gain (~0.5).
        var scale = Float(4.0) / Float(fftSize)
        magnitudes.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(halfSize))
        }
        magnitudes[0] = 0
        #else
        // Pure-Swift DFT fallback for non-Accelerate environments.
        let n = fftSize
        for i in 0..<n { windowedBuffer[i] = inputBuffer[i] * hannWindow[i] }
        let twoPiOverN = 2.0 * Float.pi / Float(n)
        let scale = 4.0 / Float(n)
        magnitudes[0] = 0
        for k in 1..<halfSize {
            var re: Float = 0
            var im: Float = 0
            let step = twoPiOverN * Float(k)
            for i in 0..<n {
                let angle = step * Float(i)
                re += windowedBuffer[i] * cosf(angle)
                im -= windowedBuffer[i] * sinf(angle)
            }
            magnitudes[k] = sqrtf(re * re + im * im) * scale
        }
        #endif
    }

    private func bandEnergyAndFlux(from lo: Int, through hi: Int) -> (energy: Float, flux: Float) {
        guard lo <= hi, lo >= 1, hi < halfSize else { return (0, 0) }
        var sumSq: Float = 0
        var flux: Float = 0
        let count = hi - lo + 1
        for bin in lo...hi {
            let mag = magnitudes[bin]
            sumSq += mag * mag
            let diff = mag - previousMagnitudes[bin]
            if diff > 0 { flux += diff }
        }
        // RMS amplitude across band bins, plus mean positive flux per bin.
        let energy = sqrtf(sumSq / Float(count))
        let meanFlux = flux / Float(count)
        return (energy, meanFlux)
    }

    private func computeNormalizedSpectralCentroid(from lo: Int, through hi: Int, binWidth: Double) -> Float {
        guard lo <= hi, lo >= 1, hi < halfSize else { return 0.3 }
        var weightedFreqSum: Double = 0
        var magSum: Double = 0
        for bin in lo...hi {
            let mag = Double(magnitudes[bin])
            weightedFreqSum += mag * (Double(bin) * binWidth)
            magSum += mag
        }
        guard magSum > 1e-6 else { return 0.25 }
        let centroidHz = max(40.0, min(8000.0, weightedFreqSum / magSum))
        // Log-frequency mapping: 40 Hz -> 0.0, 8000 Hz -> 1.0.
        let logPos = (log2(centroidHz) - log2(40.0)) / (log2(8000.0) - log2(40.0))
        return clamp(Float(logPos), min: 0, max: 1)
    }

    private func onsetRatio(flux: Float, mean: Float, dev: Float) -> Float {
        let floorThreshold = max(mean + dev * 0.85, 0.0025)
        return flux / floorThreshold
    }

    private func updateFluxStats(flux: Float, mean: inout Float, dev: inout Float, alpha: Float) {
        let deviation = abs(flux - mean)
        mean = max(0.0008, mean + (flux - mean) * alpha)
        dev = max(0.0005, dev + (deviation - dev) * alpha)
    }

    // MARK: - Lightweight Tempo / Beat Confidence Tracker

    private func recordBeatOnset(at timestamp: TimeInterval) {
        onsetTimes[onsetWriteIndex] = timestamp
        onsetWriteIndex = (onsetWriteIndex + 1) % Self.onsetHistoryCapacity
        onsetCount = min(onsetCount + 1, Self.onsetHistoryCapacity)
        lastStrongBeatTime = timestamp

        guard onsetCount >= 4 else { return }

        // Gather chronological onsets from fixed ring (max 16 elements).
        var ordered: [TimeInterval] = []
        ordered.reserveCapacity(onsetCount)
        let oldest = onsetCount < Self.onsetHistoryCapacity ? 0 : onsetWriteIndex
        for i in 0..<onsetCount {
            ordered.append(onsetTimes[(oldest + i) % Self.onsetHistoryCapacity])
        }

        // Compute consecutive inter-onset intervals folded into 0.33s...0.86s (~70...180 BPM).
        var intervals: [TimeInterval] = []
        intervals.reserveCapacity(ordered.count)
        for i in 1..<ordered.count {
            var dt = ordered[i] - ordered[i - 1]
            guard dt >= 0.14, dt <= 2.4 else { continue }
            while dt < 0.33 { dt *= 2 }
            while dt > 0.86 { dt *= 0.5 }
            intervals.append(dt)
        }
        guard intervals.count >= 3 else { return }

        // Find dominant interval cluster (within ±12% tolerance).
        var bestPeriod: TimeInterval = 0
        var bestWeight: Double = 0
        for candidate in intervals {
            var weightedSum = 0.0
            var weightTotal = 0.0
            for (idx, other) in intervals.enumerated() {
                if abs(other - candidate) <= candidate * 0.12 {
                    let recency = 0.5 + 0.5 * (Double(idx + 1) / Double(intervals.count))
                    weightedSum += other * recency
                    weightTotal += recency
                }
            }
            if weightTotal > bestWeight {
                bestWeight = weightTotal
                bestPeriod = weightedSum / weightTotal
            }
        }

        let totalRecency = (0..<intervals.count).reduce(0.0) { acc, idx in
            acc + 0.5 + 0.5 * (Double(idx + 1) / Double(intervals.count))
        }
        let clusterRatio = totalRecency > 0 ? Float(bestWeight / totalRecency) : 0
        let sampleConfidence = Float(min(intervals.count, 8)) / 8.0
        let measuredConfidence = clamp(clusterRatio * sampleConfidence, min: 0, max: 1)

        if let existing = estimatedBeatPeriod, abs(existing - bestPeriod) <= existing * 0.15 {
            estimatedBeatPeriod = existing * 0.72 + bestPeriod * 0.28
        } else if measuredConfidence >= 0.45 {
            estimatedBeatPeriod = bestPeriod
        }
        beatConfidence = beatConfidence * 0.65 + measuredConfidence * 0.35
    }

    private func decayBeatConfidence(dt: TimeInterval) {
        if (elapsedTime - lastStrongBeatTime) > 1.8 {
            let decay = smoothingAlpha(dt: dt, tau: 1.5)
            beatConfidence *= (1 - decay)
            if beatConfidence < 0.05 {
                beatConfidence = 0
                estimatedBeatPeriod = nil
            }
        }
    }

    /// Gently reinforces on-grid accents when beat tracking is confident; returns 1.0 for ambient/irregular audio.
    private func currentBeatPhaseMultiplier() -> Float {
        guard beatConfidence >= 0.45, let period = estimatedBeatPeriod, period > 0.2 else { return 1.0 }
        let sinceBeat = elapsedTime - lastStrongBeatTime
        guard sinceBeat >= 0 else { return 1.0 }
        let cycles = sinceBeat / period
        let phaseDist = abs(cycles - cycles.rounded())
        // Scale effect smoothly with confidence above 0.45.
        let authority = clamp((beatConfidence - 0.45) / 0.55, min: 0, max: 1)
        if phaseDist <= 0.16 {
            return 1.0 + 0.15 * authority
        } else if phaseDist >= 0.32 {
            return 1.0 - 0.10 * authority
        }
        return 1.0
    }

    private func priority(of kind: MusicHapticsTransient.Kind?) -> Int {
        switch kind {
        case .kick: 4
        case .snare: 3
        case .bassAttack: 2
        case .hiHat: 1
        case nil: 0
        }
    }

    private func perceptualCurve(_ x: Float) -> Float {
        guard x.isFinite, x > 0 else { return 0 }
        return clamp(powf(min(x, 2.0) / 1.15, 0.68), min: 0, max: 1)
    }

    private func smoothingAlpha(dt: TimeInterval, tau: TimeInterval) -> Float {
        guard tau > 0 else { return 1 }
        return Float(1.0 - exp(-dt / tau))
    }

    private func clamp(_ value: Float, min lo: Float, max hi: Float) -> Float {
        guard value.isFinite else { return lo }
        return Swift.min(hi, Swift.max(lo, value))
    }
}
