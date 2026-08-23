/// Decides how a full-download playback path should react when a seekable
/// local file is not available yet.
///
/// A user scrub must leave the currently playing node untouched. Recovery is
/// different: the system has already stopped that node, so silently rejecting
/// the seek would make every subsequent play command a no-op.
public enum FullDownloadSeekDecision: Sendable, Equatable {
    case proceed
    case keepCurrentPlayback
    case restartCurrentSong
}

public enum FullDownloadSeekPolicy {
    public static func decision(
        hasSeekableFile: Bool,
        isInterruptionRecovery: Bool
    ) -> FullDownloadSeekDecision {
        if hasSeekableFile {
            return .proceed
        }
        return isInterruptionRecovery ? .restartCurrentSong : .keepCurrentPlayback
    }
}

public enum RemoteSeekPreparationDecision: Sendable, Equatable {
    case useExistingFile
    case tryRangeWithoutMaterialization
    case materializeCompleteFile
}

/// Cold-process restoration has no live decoder or audible position to
/// protect. It may seek through a Range InputSource, but blocking the first
/// Play on a complete remote download is worse than restarting at the
/// beginning if that decoder cannot seek. Runtime recovery and explicit seek
/// retain the complete-file path when caching is enabled.
public enum RemoteSeekPreparationPolicy {
    public static func decision(
        hasCachedFile: Bool,
        cacheEnabled: Bool,
        isColdSessionRestore: Bool
    ) -> RemoteSeekPreparationDecision {
        if hasCachedFile {
            return .useExistingFile
        }
        if isColdSessionRestore || !cacheEnabled {
            return .tryRangeWithoutMaterialization
        }
        return .materializeCompleteFile
    }
}

public enum CompleteFileTransferOrigin: Sendable, Equatable {
    /// A path owned by a configured music-source connector. Authentication,
    /// redirects, certificate identity and endpoint trust remain connector
    /// responsibilities for the complete transfer as well as Range reads.
    case connectorPath
    /// A source-relative descriptor resolved to a URL by its connector. Its
    /// authentication, redirect and TLS context still belong to that source.
    case connectorResolvedURL
    /// An external URL embedded in a stream descriptor has no connector path
    /// that can materialize it, so it uses the generic trusted HTTP transport.
    case externalURL
}

public enum CompleteFileTransferRoute: Sendable, Equatable {
    case connector
    case genericHTTP
}

public enum CompleteFileTransferPolicy {
    public static func route(
        for origin: CompleteFileTransferOrigin
    ) -> CompleteFileTransferRoute {
        switch origin {
        case .connectorPath, .connectorResolvedURL:
            return .connector
        case .externalURL:
            return .genericHTTP
        }
    }
}

/// A configured source URL may leave its connector only when the player can
/// consume it without losing required transport context or forcing another
/// complete download through a generic session.
public enum ConfiguredSourceDirectURLPolicy {
    public static func permitsDirectURL(
        requiresCompleteLocalFile: Bool,
        usesServerTranscodedStream: Bool,
        hasMultipleConnectionRoutes: Bool,
        usesAlternateTLSIdentity: Bool
    ) -> Bool {
        !hasMultipleConnectionRoutes
            && !usesAlternateTLSIdentity
            && (!requiresCompleteLocalFile || usesServerTranscodedStream)
    }
}
