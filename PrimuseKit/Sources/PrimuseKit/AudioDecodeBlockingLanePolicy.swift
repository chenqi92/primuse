import Foundation

/// Where a decode session's bytes actually come from.
public enum AudioDecodeSourceKind: Sendable, Equatable, CaseIterable {
    /// A file on a local volume, read by the decoder with ordinary file I/O.
    case localFileURL
    /// A cloud-source input whose reads are served by a synchronous bridge
    /// over an asynchronous range fetch.
    case cloudInputSource
    /// A direct HTTP(S) range input, served through the same synchronous
    /// bridge.
    case httpInputSource
}

/// A decode whose byte reads are served by a synchronous bridge over an
/// asynchronous fetch parks its calling thread for the whole fetch. Running
/// that on the shared cooperative pool takes a thread away from the very
/// fetch it is waiting for, so those decodes belong on a dedicated blocking
/// lane. Plain local-file reads never do.
public enum AudioDecodeBlockingLanePolicy {
    public static func requiresDedicatedBlockingLane(
        sourceKind: AudioDecodeSourceKind
    ) -> Bool {
        switch sourceKind {
        case .localFileURL:
            return false
        case .cloudInputSource, .httpInputSource:
            return true
        }
    }
}
