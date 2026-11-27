import Foundation

/// Chooses the format label for the DSP-free PCM graph after the output route
/// has negotiated its real hardware rate. A preferred rate is only a request;
/// feeding buffers labelled with a rejected source rate can make PCM render at
/// the wrong speed and pitch.
public enum DirectPCMOutputSampleRatePolicy {
    public static let minimumSampleRate = 8_000.0
    public static let maximumSampleRate = 384_000.0
    public static let matchTolerance = 1.0

    public static func resolvedSampleRate(
        requestedSourceSampleRate: Double?,
        actualHardwareSampleRate: Double
    ) -> Double? {
        guard isValid(actualHardwareSampleRate) else { return nil }
        guard let requestedSourceSampleRate,
              isValid(requestedSourceSampleRate) else {
            return actualHardwareSampleRate
        }
        return abs(requestedSourceSampleRate - actualHardwareSampleRate) < matchTolerance
            ? requestedSourceSampleRate
            : actualHardwareSampleRate
    }

    public static func hardwareMatches(
        requestedSampleRate: Double,
        actualHardwareSampleRate: Double
    ) -> Bool {
        isValid(requestedSampleRate)
            && isValid(actualHardwareSampleRate)
            && abs(requestedSampleRate - actualHardwareSampleRate) < matchTolerance
    }

    /// Wireless routes negotiate their own clock and can change it while the
    /// stream is active. Writing their nominal rate from the app can trigger a
    /// second hardware reconfiguration and leave an existing audio graph with
    /// stale formats. Wired outputs may opt in only when Core Audio confirms
    /// the request is settable and supported.
    public static func shouldRequestNominalSampleRateChange(
        requestedSampleRate: Double,
        currentHardwareSampleRate: Double,
        propertyIsSettable: Bool,
        requestedRateIsSupported: Bool?,
        isSystemManagedWirelessOutput: Bool
    ) -> Bool {
        !isSystemManagedWirelessOutput
            && propertyIsSettable
            && requestedRateIsSupported != false
            && isValid(requestedSampleRate)
            && isValid(currentHardwareSampleRate)
            && !hardwareMatches(
                requestedSampleRate: requestedSampleRate,
                actualHardwareSampleRate: currentHardwareSampleRate
            )
    }

    public static func bufferMatchesGraph(
        bufferSampleRate: Double,
        bufferChannelCount: UInt32,
        graphSampleRate: Double,
        graphChannelCount: UInt32
    ) -> Bool {
        isValid(bufferSampleRate)
            && isValid(graphSampleRate)
            && abs(bufferSampleRate - graphSampleRate) < matchTolerance
            && bufferChannelCount > 0
            && bufferChannelCount == graphChannelCount
    }

    private static func isValid(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate >= minimumSampleRate
            && sampleRate <= maximumSampleRate
    }
}
