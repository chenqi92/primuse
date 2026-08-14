import Foundation

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
