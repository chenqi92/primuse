import Foundation

/// Describes whether a metadata read must stay transport-bounded or may perform
/// one explicit complete-file fallback for a single user-selected song.
public enum MetadataRangeReadIntent: Sendable, Equatable {
    case bulkBounded
    case explicitSingleFileCompleteFallback
}

public enum MetadataRangeReadError: Error, LocalizedError, Sendable, Equatable {
    case suffixRangeUnsupported
    /// The server answered a bounded metadata read, but its status, headers or
    /// body length do not describe the requested byte range. A malformed file
    /// response is not evidence that the whole source is unavailable and
    /// must not park its other songs behind endpoint probes.
    case invalidRangeResponse

    public var errorDescription: String? {
        switch self {
        case .suffixRangeUnsupported:
            return String(localized: "metadata.rangeRead.error.suffixUnsupported", bundle: Bundle.primuseKit)
        case .invalidRangeResponse:
            return String(localized: "metadata.rangeRead.error.invalidRangeResponse", bundle: Bundle.primuseKit)
        }
    }
}

/// A connector owns one cache instance per source. Recording both the original
/// and final endpoint prevents redirects from repeating known-unsupported
/// suffix probes while keeping unrelated endpoints independent.
public struct MetadataSuffixRangeCapabilityCache: Sendable {
    private var unsupportedEndpointKeys: Set<String> = []

    public init() {}

    public func isUnsupported(endpointKey: String?) -> Bool {
        guard let endpointKey else { return false }
        return unsupportedEndpointKeys.contains(endpointKey)
    }

    public mutating func recordUnsupported(
        requestedEndpointKey: String?,
        finalEndpointKey: String?
    ) {
        if let requestedEndpointKey {
            unsupportedEndpointKeys.insert(requestedEndpointKey)
        }
        if let finalEndpointKey {
            unsupportedEndpointKeys.insert(finalEndpointKey)
        }
    }
}
