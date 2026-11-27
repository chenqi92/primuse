import Foundation

/// A remote `.wav` row can predate DTS-CD content classification. In that
/// case the carrier still looks like ordinary PCM to the native range decoder,
/// so an unavailable probe must fail safe to a complete-file decode path.
public enum RemoteWAVPlaybackPolicy {
    public enum ProbeOutcome: Sendable, Equatable {
        case pcm
        case dts
        case unavailable
    }

    public static func requiresCompleteFile(
        persistedFormat: AudioFormat,
        probeOutcome: ProbeOutcome
    ) -> Bool {
        guard persistedFormat == .wav else { return false }
        return probeOutcome != .pcm
    }
}
