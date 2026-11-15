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

public enum RemoteRangeSeekRejectionDecision: Sendable, Equatable {
    case materializeCompleteFile
    case reportSeekUnavailable
}

/// Every remote seek without a complete cache file first asks the decoder to
/// seek through its Range InputSource. A seekable format reaches the target
/// after a few range reads, whereas completing a large lossless download
/// first keeps interruption recovery silent for tens of seconds. The Range
/// decoder never decodes and discards up to a remote target; it rejects the
/// seek instead, and only then is the complete file worth waiting for.
///
/// Cold-process restoration has no live decoder or audible position to
/// protect, so blocking the first Play on a complete download is worse than
/// restarting at the beginning. A disabled cache never persists a complete
/// file behind the user's back.
public enum RemoteSeekPreparationPolicy {
    public static func afterRangeSeekRejected(
        cacheEnabled: Bool,
        isColdSessionRestore: Bool
    ) -> RemoteRangeSeekRejectionDecision {
        if isColdSessionRestore || !cacheEnabled {
            return .reportSeekUnavailable
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

/// When a stream with no length and no Range support (a server transcoding
/// on the fly) that is decoded while it downloads may start playing.
///
/// A download faster than playback starts after a short lead. A slower one
/// waits until what has arrived covers the shortfall over the whole song at
/// the rate seen so far: running dry mid-song can only recover by fetching
/// the whole file again, which is far worse than a few more seconds at the
/// start.
public enum ProgressiveDownloadStartPolicy {
    /// Audio that has to be on disk before playback starts.
    public static let minimumLeadSeconds: Double = 2
    /// The download rate is not trusted before it has been watched this long…
    public static let minimumObservationSeconds: Double = 1.5
    /// …unless this much audio has already arrived, which only a fast
    /// server delivers within that time.
    public static let fastStartLeadSeconds: Double = 8
    /// Headroom the download rate needs over the audio bit rate.
    public static let rateSafetyFactor: Double = 1.25

    /// - Parameters:
    ///   - bufferedAudioBytes: audio payload received so far, without the
    ///     leading tag the stream may start with.
    ///   - downloadedBytes: every byte received so far.
    ///   - elapsedSeconds: time since the response arrived.
    ///   - audioBytesPerSecond: how fast playback consumes the payload; nil
    ///     until the first frames have been parsed.
    ///   - expectedDuration: the song's length when known.
    public static func canStart(
        bufferedAudioBytes: Int64,
        downloadedBytes: Int64,
        elapsedSeconds: Double,
        downloadFinished: Bool,
        audioBytesPerSecond: Double?,
        expectedDuration: Double?
    ) -> Bool {
        if downloadFinished { return true }
        guard let audioBytesPerSecond, audioBytesPerSecond.isFinite, audioBytesPerSecond > 0,
              elapsedSeconds.isFinite else { return false }
        let buffered = Double(max(0, bufferedAudioBytes))
        let bufferedSeconds = buffered / audioBytesPerSecond
        guard bufferedSeconds >= minimumLeadSeconds,
              elapsedSeconds >= minimumObservationSeconds || bufferedSeconds >= fastStartLeadSeconds,
              elapsedSeconds > 0 else { return false }
        let downloadRate = Double(max(0, downloadedBytes)) / elapsedSeconds
        let requiredRate = audioBytesPerSecond * rateSafetyFactor
        if downloadRate >= requiredRate { return true }
        guard let expectedDuration, expectedDuration.isFinite, expectedDuration > 0 else { return false }
        return buffered >= (requiredRate - downloadRate) * expectedDuration
    }
}
