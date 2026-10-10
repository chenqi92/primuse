import Foundation

/// Bounds every HTTP response read inside a speculative range read (queue
/// prefetch seeds). A server or reverse proxy that ignores `Range` answers a
/// 1 MB seed request with the whole file; without this bound the connector's
/// generic 20 MB response ceiling (or a whole-file fallback) turns every seed
/// into a large download. Transports consult `effectiveLimit(_:)`, and
/// connectors that would otherwise fall back to a complete download check
/// `isActive` and throw `SpeculativeRangeReadError.rangeUnsupported` instead.
public enum SpeculativeRangeRead {
    @TaskLocal public static var responseByteLimit: Int?

    /// Headroom above the requested window: covers error envelopes, login or
    /// link-resolution JSON issued on the way, and chunked-transfer slack.
    public static let responseSlackBytes: Int64 = 1024 * 1024

    public static var isActive: Bool { responseByteLimit != nil }

    public static func effectiveLimit(_ maxBytes: Int) -> Int {
        guard let limit = responseByteLimit else { return maxBytes }
        return min(maxBytes, max(0, limit))
    }

    public static func responseLimit(forRequestedLength length: Int64) -> Int {
        let requested = max(0, length)
        let (sum, overflow) = requested.addingReportingOverflow(responseSlackBytes)
        return overflow ? Int.max : Int(clamping: sum)
    }

    nonisolated(nonsending)
    public static func withBoundedResponses<T>(
        requestedLength length: Int64,
        operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $responseByteLimit.withValue(
            responseLimit(forRequestedLength: length),
            operation: operation
        )
    }
}

public enum SpeculativeRangeReadError: Error, Equatable, Sendable {
    /// The endpoint does not honour byte ranges, so a speculative seed
    /// would degrade into a complete download.
    case rangeUnsupported
}

/// Decisions for prefetching the songs queued after the current one.
///
/// The next song is the one an automatic advance will start, so it gets a
/// head long enough to ride out a stall right at the track change; later
/// songs only get the bytes a decoder needs to open the file. Complete-file
/// transfers are limited to the songs that genuinely need them soon, and a
/// song that can start from ranged reads never waits for a whole-file
/// prefetch to finish.
public enum UpcomingPlaybackPrefetchPolicy {
    /// Audio seconds the next song's seed should cover.
    public static let nextSongHeadDuration: TimeInterval = 20
    /// Upper bound for the next song's head, in playback chunks.
    public static let maximumNextSongHeadChunks: Int64 = 8
    /// Queue depth on metered or Low Data Mode networks.
    public static let meteredNetworkSongLimit = 2

    public enum CompleteFileKind: Sendable, Equatable {
        /// The original file, required by the format (DTS through FFmpeg) or
        /// because the source cannot serve ranged reads for this song.
        case original
        /// A server-side transcode, which playback downloads whole anyway.
        case transcoded
        /// A medley slice that is crossfaded mid-file from a local copy.
        case medley
    }

    public enum InFlightPhase: Sendable, Equatable {
        /// Registered but still waiting for current playback to go quiet.
        case queued
        /// Fetching the bytes a decoder needs to open the file.
        case openSeed
        /// The open seed is published; lengthening the head.
        case extendingSeed
        /// Transferring a complete file.
        case completeFile(CompleteFileKind)
    }

    public enum JoinDecision: Sendable, Equatable {
        /// Await the in-flight transfer: its bytes are needed before playback
        /// can start anyway.
        case wait
        /// Cancel the transfer and start playback on its own path.
        case cancelAndProceed
    }

    public static func plannedSongCount(
        configured: Int,
        isMeteredNetwork: Bool
    ) -> Int {
        let count = max(0, configured)
        return isMeteredNetwork ? min(count, meteredNetworkSongLimit) : count
    }

    /// Head bytes to seed for the queued song at `rank` (0 = next song).
    /// The result is chunk-aligned, never below one chunk, and never beyond
    /// the file.
    public static func headByteCount(
        rank: Int,
        fileSize: Int64,
        duration: TimeInterval,
        chunkSize: Int64
    ) -> Int64 {
        guard fileSize > 0, chunkSize > 0 else { return 0 }
        let minimum = min(fileSize, chunkSize)
        guard rank == 0, duration.isFinite, duration > 0 else { return minimum }
        let bytesPerSecond = Double(fileSize) / duration
        let wanted = bytesPerSecond * nextSongHeadDuration
        guard wanted.isFinite, wanted > 0 else { return minimum }
        let chunks = min(
            maximumNextSongHeadChunks,
            max(1, Int64((wanted / Double(chunkSize)).rounded(.up)))
        )
        return min(fileSize, chunks * chunkSize)
    }

    /// Tags and cover art a seed reaches past to get to the audio. Beyond this
    /// the seed stays sized from the top of the file.
    public static let maximumLeadingMetadataBytes: Int64 = 8 * 1024 * 1024
    /// Largest trailing MP4 index (`moov` after `mdat`) a seed's tail grows to.
    public static let maximumTrailingIndexBytes: Int64 = 4 * 1024 * 1024

    /// Grows `headByteCount` past leading tags and cover art. A head sized
    /// from the top of the file already has room for an ordinary tag; it only
    /// grows once the metadata would leave less than half of it for audio.
    public static func seedHeadByteCount(
        headByteCount: Int64,
        layout: AudioPayloadLayout,
        fileSize: Int64,
        chunkSize: Int64
    ) -> Int64 {
        guard fileSize > 0, chunkSize > 0, headByteCount > 0 else { return headByteCount }
        let metadataEnd: Int64
        switch layout.audioStart {
        case .at(let offset), .beyond(let offset):
            metadataEnd = offset
        case .unrecognized:
            metadataEnd = 0
        }
        guard metadataEnd * 2 > headByteCount,
              metadataEnd <= maximumLeadingMetadataBytes else {
            return min(headByteCount, fileSize)
        }
        let wanted = metadataEnd + headByteCount
        let aligned = ((wanted + chunkSize - 1) / chunkSize) * chunkSize
        return min(fileSize, aligned)
    }

    /// The tail a seed keeps: the usual trailing tag window, or the whole
    /// trailing MP4 index when it fits, never overlapping the head.
    public static func seedTailByteCount(
        defaultTail: Int64,
        headByteCount: Int64,
        layout: AudioPayloadLayout,
        fileSize: Int64
    ) -> Int64 {
        var tail = defaultTail
        if let indexStart = layout.trailingIndexStart, indexStart > 0, indexStart < fileSize {
            let indexBytes = fileSize - indexStart
            if indexBytes <= maximumTrailingIndexBytes {
                tail = max(tail, indexBytes)
            }
        }
        return max(0, min(tail, fileSize - headByteCount))
    }

    /// Complete-file transfers stay close to the playhead: the original file
    /// only for the next song, small transcodes and medley slices for the
    /// next two.
    public static func allowsCompleteFile(rank: Int, kind: CompleteFileKind) -> Bool {
        switch kind {
        case .original:
            return rank == 0
        case .transcoded, .medley:
            return rank <= 1
        }
    }

    public static let joinCompletedFractionThreshold = 0.75

    /// What playback does when the song it is about to start is still being
    /// prefetched.
    public static func joinDecision(
        phase: InFlightPhase,
        playbackRequiresCompleteFile: Bool,
        completedFraction: Double?
    ) -> JoinDecision {
        switch phase {
        case .queued, .extendingSeed:
            // Nothing is on the wire yet, or the open seed is already
            // published: waiting would only delay the first sound.
            return .cancelAndProceed
        case .openSeed:
            return .wait
        case .completeFile(let kind):
            if playbackRequiresCompleteFile || kind == .transcoded { return .wait }
            if let completedFraction, completedFraction >= joinCompletedFractionThreshold {
                return .wait
            }
            return .cancelAndProceed
        }
    }
}

/// When a streamed song ends, the missing bytes are fetched in the background
/// so the file can be promoted to the complete cache. That is worth it for a
/// song heard (almost) to the end; a song skipped early would turn the track
/// change into a large download that competes with the song the user just
/// chose.
public enum StreamingSessionCompletionFillPolicy {
    public static let absoluteMaximumBytes: Int64 = 50 * 1024 * 1024
    public static let smallGapBytes: Int64 = 4 * 1024 * 1024
    /// Gaps up to this fraction of the file are still completed.
    public static let maximumMissingFraction = 0.25
    /// A song left sooner than this was skipped past, not listened to (a run
    /// of Next presses); its remainder is not fetched however small it is.
    public static let minimumPlayedSeconds: Double = 10

    public static func allowsFill(
        missingBytes: Int64,
        totalLength: Int64,
        playedSeconds: Double = .infinity
    ) -> Bool {
        guard playedSeconds >= minimumPlayedSeconds,
              missingBytes > 0, totalLength > 0,
              missingBytes < absoluteMaximumBytes else { return false }
        if missingBytes <= smallGapBytes { return true }
        return Double(missingBytes) <= Double(totalLength) * maximumMissingFraction
    }
}
