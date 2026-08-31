import Foundation

public enum SmartMixAssetAccess: String, Codable, Sendable {
    /// A complete, locally available asset that framework analyzers can read.
    case completeFile
    /// PCM that Primuse already decodes for playback.
    case decodedPCM
    /// A protected system playback stream whose PCM isn't exposed to the app.
    case protectedSystemStream
    /// An unbounded stream where a complete-track transition plan is invalid.
    case liveStream
}

public enum SmartMixAnalysisBackend: String, Codable, Sendable {
    case streamingPCM
    case musicUnderstanding
}

public enum SmartMixAnalysisBackendPolicy {
    /// Selects an analyzer without treating iOS availability as permission to
    /// inspect protected Apple Music playback. Music Understanding can analyze
    /// complete assets or supplied PCM, not MusicKit's protected output.
    public static func preferredBackend(
        operatingSystemMajorVersion: Int,
        musicUnderstandingAvailable: Bool,
        assetAccess: SmartMixAssetAccess
    ) -> SmartMixAnalysisBackend? {
        switch assetAccess {
        case .completeFile:
            if operatingSystemMajorVersion >= 27, musicUnderstandingAvailable {
                return .musicUnderstanding
            }
            return .streamingPCM
        case .decodedPCM:
            return .streamingPCM
        case .protectedSystemStream, .liveStream:
            return nil
        }
    }
}

public struct SmartMixTempoEstimate: Equatable, Sendable {
    public let beatsPerMinute: Double
    public let confidence: Double
    public let firstBeatTime: TimeInterval

    public init(
        beatsPerMinute: Double,
        confidence: Double,
        firstBeatTime: TimeInterval
    ) {
        self.beatsPerMinute = beatsPerMinute
        self.confidence = confidence
        self.firstBeatTime = firstBeatTime
    }
}

public struct SmartMixTrackAnalysis: Equatable, Sendable {
    public let backend: SmartMixAnalysisBackend
    public let analyzedDuration: TimeInterval
    public let tempo: SmartMixTempoEstimate?
    /// Exact bar positions when supplied by a platform analyzer. Streaming PCM
    /// analysis deliberately leaves these empty because it cannot reliably
    /// distinguish a downbeat from another beat.
    public let barStartTimes: [TimeInterval]
    public let sectionStartTimes: [TimeInterval]
    public let integratedLoudnessDB: Double?

    public init(
        backend: SmartMixAnalysisBackend,
        analyzedDuration: TimeInterval,
        tempo: SmartMixTempoEstimate? = nil,
        barStartTimes: [TimeInterval] = [],
        sectionStartTimes: [TimeInterval] = [],
        integratedLoudnessDB: Double? = nil
    ) {
        self.backend = backend
        self.analyzedDuration = analyzedDuration
        self.tempo = tempo
        self.barStartTimes = barStartTimes
        self.sectionStartTimes = sectionStartTimes
        self.integratedLoudnessDB = integratedLoudnessDB
    }
}

public enum SmartMixRhythmDetector {
    /// Estimates a stable tempo from a low-rate RMS envelope. The detector is
    /// intentionally independent of AVFoundation so the iOS 18-26 fallback and
    /// the iOS 27 framework adapter feed the same planning model.
    public static func estimateTempo(
        rmsEnvelope: [Float],
        envelopeSampleRate: Double,
        minimumBPM: Double = 70,
        maximumBPM: Double = 190,
        minimumDuration: TimeInterval = 8
    ) -> SmartMixTempoEstimate? {
        guard envelopeSampleRate.isFinite,
              envelopeSampleRate > 0,
              minimumBPM.isFinite,
              maximumBPM.isFinite,
              minimumBPM > 0,
              maximumBPM > minimumBPM,
              minimumDuration.isFinite,
              minimumDuration > 0,
              Double(rmsEnvelope.count) / envelopeSampleRate >= minimumDuration else {
            return nil
        }

        let levels = rmsEnvelope.map { sample -> Double in
            let value = Double(sample)
            return value.isFinite ? max(0, value) : 0
        }
        guard levels.contains(where: { $0 > 0 }) else { return nil }

        // An adaptive baseline rejects sustained pads and exposes positive
        // energy changes such as drum hits without requiring FFT allocations.
        var baseline = levels[0]
        let baselineSmoothing = min(1, 2 / envelopeSampleRate)
        var novelty = [Double]()
        novelty.reserveCapacity(levels.count)
        for level in levels {
            baseline += (level - baseline) * baselineSmoothing
            novelty.append(max(0, level - baseline))
        }

        let noveltyEnergy = novelty.reduce(0) { $0 + $1 * $1 }
        guard noveltyEnergy.isFinite, noveltyEnergy > 1e-10 else { return nil }

        let minimumLag = max(1, Int((envelopeSampleRate * 60 / maximumBPM).rounded(.down)))
        let maximumLag = min(
            novelty.count / 2,
            max(minimumLag, Int((envelopeSampleRate * 60 / minimumBPM).rounded(.up)))
        )
        guard maximumLag >= minimumLag else { return nil }

        struct Candidate {
            let lag: Int
            let bpm: Double
            let correlation: Double
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(maximumLag - minimumLag + 1)
        for lag in minimumLag...maximumLag {
            var dot = 0.0
            var lhsEnergy = 0.0
            var rhsEnergy = 0.0
            for index in lag..<novelty.count {
                let lhs = novelty[index]
                let rhs = novelty[index - lag]
                dot += lhs * rhs
                lhsEnergy += lhs * lhs
                rhsEnergy += rhs * rhs
            }
            let denominator = sqrt(lhsEnergy * rhsEnergy)
            let correlation = denominator > 1e-12 ? dot / denominator : 0
            candidates.append(Candidate(
                lag: lag,
                bpm: envelopeSampleRate * 60 / Double(lag),
                correlation: correlation.isFinite ? max(0, min(1, correlation)) : 0
            ))
        }

        guard let strongest = candidates.max(by: { $0.correlation < $1.correlation }),
              strongest.correlation >= 0.12 else { return nil }

        // Autocorrelation naturally produces half/double-tempo aliases. Among
        // near-equal peaks, prefer the conventional DJ range and then the one
        // closest to 120 BPM; this keeps the choice deterministic.
        let nearStrongest = candidates.filter {
            $0.correlation >= max(0.12, strongest.correlation * 0.96)
        }
        let selected = nearStrongest.min { lhs, rhs in
            let lhsPreferred = (80...160).contains(lhs.bpm)
            let rhsPreferred = (80...160).contains(rhs.bpm)
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            let lhsDistance = abs(log(lhs.bpm / 120))
            let rhsDistance = abs(log(rhs.bpm / 120))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.correlation > rhs.correlation
        } ?? strongest

        let sortedCorrelations = candidates.map(\.correlation).sorted()
        let median = sortedCorrelations[sortedCorrelations.count / 2]
        let prominence = max(0, selected.correlation - median)
            / max(1e-9, 1 - median)
        let durationCoverage = min(1, Double(novelty.count) / (envelopeSampleRate * 24))
        let confidence = max(0, min(1, prominence * (0.65 + 0.35 * durationCoverage)))
        guard confidence >= 0.08 else { return nil }

        var bestPhase = 0
        var bestPhaseEnergy = -Double.infinity
        for phase in 0..<selected.lag {
            var phaseEnergy = 0.0
            var index = phase
            while index < novelty.count {
                phaseEnergy += novelty[index]
                index += selected.lag
            }
            if phaseEnergy > bestPhaseEnergy {
                bestPhaseEnergy = phaseEnergy
                bestPhase = phase
            }
        }

        return SmartMixTempoEstimate(
            beatsPerMinute: selected.bpm,
            confidence: confidence,
            firstBeatTime: Double(bestPhase) / envelopeSampleRate
        )
    }
}

public enum SmartMixTransitionBasis: String, Codable, Sendable {
    case fixedDuration
    case audibleBoundary
    case tempoGrid
    case detectedBar
    case detectedSection
}

public struct SmartMixTransitionPlan: Equatable, Sendable {
    public let triggerTime: TimeInterval
    public let overlapDuration: TimeInterval
    public let playableEndpoint: TimeInterval
    public let basis: SmartMixTransitionBasis
    public let analysisBackend: SmartMixAnalysisBackend?

    public init(
        triggerTime: TimeInterval,
        overlapDuration: TimeInterval,
        playableEndpoint: TimeInterval,
        basis: SmartMixTransitionBasis,
        analysisBackend: SmartMixAnalysisBackend?
    ) {
        self.triggerTime = triggerTime
        self.overlapDuration = overlapDuration
        self.playableEndpoint = playableEndpoint
        self.basis = basis
        self.analysisBackend = analysisBackend
    }
}

public enum SmartMixTransitionPlanner {
    /// Builds a transition that remains safe when analysis is absent, then
    /// improves it by snapping to exact framework bars or whole four-beat bars.
    /// `analysisTimelineOffset` normalizes full-file SDK timestamps after
    /// Primuse trims leading silence from the playback timeline.
    public static func plan(
        nominalDuration: TimeInterval,
        analyzedPlayableDuration: TimeInterval?,
        requestedOverlap: TimeInterval,
        analysis: SmartMixTrackAnalysis?,
        analysisTimelineOffset: TimeInterval = 0
    ) -> SmartMixTransitionPlan? {
        guard nominalDuration.isFinite,
              nominalDuration > 0,
              requestedOverlap.isFinite,
              requestedOverlap > 0 else { return nil }

        let usesAudibleBoundary: Bool
        let endpoint: TimeInterval
        if let analyzedPlayableDuration,
           analyzedPlayableDuration.isFinite,
           analyzedPlayableDuration > 0,
           analyzedPlayableDuration <= nominalDuration {
            endpoint = analyzedPlayableDuration
            usesAudibleBoundary = true
        } else {
            endpoint = nominalDuration
            usesAudibleBoundary = false
        }

        var overlap = min(requestedOverlap, endpoint)
        var basis: SmartMixTransitionBasis = usesAudibleBoundary
            ? .audibleBoundary
            : .fixedDuration

        if let analysis {
            let safeOffset = analysisTimelineOffset.isFinite
                ? max(0, analysisTimelineOffset)
                : 0
            let idealStart = max(0, endpoint - overlap)
            let acceptableMinimum = max(0.5, overlap * 0.6)
            let acceptableMaximum = min(endpoint, overlap * 1.45)
            let sectionCandidates = analysis.sectionStartTimes.compactMap {
                rawTime -> TimeInterval? in
                guard rawTime.isFinite else { return nil }
                let normalized = rawTime - safeOffset
                let candidateOverlap = endpoint - normalized
                guard normalized >= 0,
                      candidateOverlap >= acceptableMinimum,
                      candidateOverlap <= acceptableMaximum else { return nil }
                return normalized
            }
            let barCandidates = analysis.barStartTimes.compactMap { rawTime -> TimeInterval? in
                guard rawTime.isFinite else { return nil }
                let normalized = rawTime - safeOffset
                let candidateOverlap = endpoint - normalized
                guard normalized >= 0,
                      candidateOverlap >= acceptableMinimum,
                      candidateOverlap <= acceptableMaximum else { return nil }
                return normalized
            }

            if let sectionStart = sectionCandidates.min(by: {
                abs($0 - idealStart) < abs($1 - idealStart)
            }) {
                overlap = endpoint - sectionStart
                basis = .detectedSection
            } else if let barStart = barCandidates.min(by: {
                abs($0 - idealStart) < abs($1 - idealStart)
            }) {
                overlap = endpoint - barStart
                basis = .detectedBar
            } else if let tempo = analysis.tempo,
                      tempo.beatsPerMinute.isFinite,
                      tempo.beatsPerMinute >= 40,
                      tempo.beatsPerMinute <= 240,
                      tempo.confidence.isFinite,
                      tempo.confidence >= 0.5 {
                let barDuration = 240 / tempo.beatsPerMinute
                let barCount = max(1, Int((overlap / barDuration).rounded()))
                let tempoOverlap = Double(barCount) * barDuration
                if tempoOverlap >= acceptableMinimum,
                   tempoOverlap <= acceptableMaximum,
                   tempoOverlap <= endpoint {
                    overlap = tempoOverlap
                    basis = .tempoGrid
                }
            }
        }

        return SmartMixTransitionPlan(
            triggerTime: max(0, endpoint - overlap),
            overlapDuration: overlap,
            playableEndpoint: endpoint,
            basis: basis,
            analysisBackend: analysis?.backend
        )
    }
}

public enum AudioSignalBoundaryDetector {
    /// Returns the first and last analysis windows that contain an audible
    /// signal. Sampling is capped near 48 kHz per channel so high-resolution
    /// files do not turn transition analysis into a second full-rate decoder.
    public static func audibleFrameRange(
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        silenceThresholdDB: Double = -50,
        windowDuration: TimeInterval = 0.01,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> Range<Int>? {
        guard frameCount > 0,
              channelCount > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              silenceThresholdDB.isFinite,
              windowDuration.isFinite,
              windowDuration > 0 else { return nil }

        let threshold = pow(10, silenceThresholdDB / 20)
        let windowFrames = max(1, Int((sampleRate * windowDuration).rounded()))
        let samplingStride = max(1, Int((sampleRate / 48_000).rounded(.down)))
        var firstAudibleFrame: Int?
        var lastAudibleFrame: Int?

        var windowStart = 0
        while windowStart < frameCount {
            let windowEnd = min(frameCount, windowStart + windowFrames)
            var sumSquares = 0.0
            var sampleCount = 0

            var frame = windowStart
            while frame < windowEnd {
                for channel in 0..<channelCount {
                    let sample = Double(sampleAt(frame, channel))
                    if sample.isFinite {
                        sumSquares += sample * sample
                        sampleCount += 1
                    }
                }
                frame += samplingStride
            }

            if sampleCount > 0,
               sqrt(sumSquares / Double(sampleCount)) >= threshold {
                if firstAudibleFrame == nil { firstAudibleFrame = windowStart }
                lastAudibleFrame = windowEnd
            }
            windowStart = windowEnd
        }

        guard let firstAudibleFrame, let lastAudibleFrame else { return nil }
        return firstAudibleFrame..<lastAudibleFrame
    }
}

public enum SmartTransitionPolicy {
    /// The point on the current player's zero-based timeline where a fade
    /// should begin. An analyzed endpoint is accepted only when it is finite,
    /// positive, and no later than the nominal duration.
    public static func triggerTime(
        nominalDuration: TimeInterval,
        analyzedPlayableDuration: TimeInterval?,
        requestedOverlap: TimeInterval
    ) -> TimeInterval? {
        guard nominalDuration.isFinite,
              nominalDuration > 0,
              requestedOverlap.isFinite,
              requestedOverlap > 0 else { return nil }

        let endpoint: TimeInterval
        if let analyzedPlayableDuration,
           analyzedPlayableDuration.isFinite,
           analyzedPlayableDuration > 0,
           analyzedPlayableDuration <= nominalDuration {
            endpoint = analyzedPlayableDuration
        } else {
            endpoint = nominalDuration
        }
        return max(0, endpoint - requestedOverlap)
    }

    /// If analysis completes after the ideal start point, shorten the fade to
    /// the audible time that remains. A short minimum ramp avoids a hard cut
    /// when the endpoint is discovered on the final progress tick.
    public static func effectiveOverlap(
        requestedOverlap: TimeInterval,
        currentTime: TimeInterval,
        playableEndpoint: TimeInterval,
        minimumRamp: TimeInterval = 0.5
    ) -> TimeInterval {
        guard requestedOverlap.isFinite, requestedOverlap > 0 else { return 0 }
        let safeMinimum = minimumRamp.isFinite ? max(0, minimumRamp) : 0
        guard currentTime.isFinite,
              playableEndpoint.isFinite,
              playableEndpoint > currentTime else {
            return min(requestedOverlap, safeMinimum)
        }
        return min(requestedOverlap, max(safeMinimum, playableEndpoint - currentTime))
    }
}
