import Foundation

/// Which DSD header probes an output-pipeline negotiation has to perform.
public enum DSDOutputProbe: Sendable, Equatable {
    /// Not a local DSD file — no DSD decoder is opened at all.
    case none
    /// Only the PCM conversion format is probed.
    case pcmOnly
    /// The DoP carrier format is probed first; PCM remains the fallback.
    case dopThenPCM
}

/// DoP is only a candidate for a DSP-free graph whose DSD mode has not been
/// pinned to PCM. Every other local DSD file goes straight to the PCM probe.
public enum DSDOutputProbePolicy {
    public static func required(
        isLocalDSD: Bool,
        outputModeIsHighFidelity: Bool,
        dsdPlaybackModeIsPCM: Bool
    ) -> DSDOutputProbe {
        guard isLocalDSD else { return .none }
        guard outputModeIsHighFidelity, !dsdPlaybackModeIsPCM else { return .pcmOnly }
        return .dopThenPCM
    }
}
