import Foundation

/// Some connectors cannot safely sustain the generic five-request playback
/// burst. OneDrive can stall under concurrent ranges, so it uses demand-driven
/// reads instead of background prefetch. FTP reads hand their control
/// connection back after each range, but a server gets at most three of them
/// and waiting reads are served in order, so FTP keeps one read ahead like the
/// HTTP file connectors instead of queueing the playhead behind a burst.
public enum RangeStreamingPrefetchPolicy {
    public enum BackgroundCacheMode: Sendable, Equatable {
        case disabled
        case rangePrewarm
        case completeFile
    }

    public static func aheadCount(
        for sourceType: MusicSourceType,
        defaultValue: Int
    ) -> Int {
        switch sourceType {
        case .oneDrive:
            return 0
        // 115:同一条直链几路并发 Range 会被 CDN 限速或拒绝(真实账号上还没核实能放开),
        // 播放只多预读一块,和前台那一路加起来不超过两条。
        case .ftp, .webdav, .infiniCloud, .synology, .synologyAudioStation, .pan115:
            return min(1, max(0, defaultValue))
        default:
            return max(0, defaultValue)
        }
    }

    /// Complete downloads for these connectors must use one sequential
    /// transfer. Repeating random-access requests is especially expensive when
    /// a WebDAV proxy ignores Range and returns the entire file for every chunk.
    public static func usesSingleTransferForCompleteDownload(
        for sourceType: MusicSourceType
    ) -> Bool {
        switch sourceType {
        case .webdav, .infiniCloud, .synology, .synologyAudioStation, .jellyfin, .emby, .plex:
            return true
        default:
            return false
        }
    }

    public static func allowsBackgroundPrewarm(for sourceType: MusicSourceType) -> Bool {
        // MusicKit owns Apple Music playback and downloads; its items cannot
        // be materialized through a file-source connector.
        switch sourceType {
        case .local, .appleMusic, .appleMusicLibrary:
            return false
        default:
            return allowsAutomaticTrailingFill(for: sourceType)
        }
    }

    /// Selects the cache work for one queued track. A source can advertise
    /// Range reads while the file format itself still requires a complete,
    /// seekable local file (for example DTS through FFmpeg). Those tracks must
    /// be materialized instead of falling through the Range branch without
    /// doing any work.
    public static func backgroundCacheMode(
        cacheEnabled: Bool,
        supportsRangeStreaming: Bool,
        hasKnownFileSize: Bool,
        usesRangeStreamingForPlayback: Bool,
        requiresCompleteLocalFile: Bool
    ) -> BackgroundCacheMode {
        guard cacheEnabled else { return .disabled }
        guard supportsRangeStreaming, hasKnownFileSize else { return .completeFile }
        if usesRangeStreamingForPlayback { return .rangePrewarm }
        if requiresCompleteLocalFile { return .completeFile }
        return .disabled
    }

    /// How playback will read a queued song, as far as prefetch cares.
    public enum UpcomingPlaybackTransport: Sendable, Equatable {
        /// Ranged reads through the source connector (sparse cache).
        case connectorRange
        /// Ranged reads against a plain HTTP(S) playback URL (sparse cache).
        case directHTTPRange
        /// Playback needs, or will download, the whole file.
        case completeFile
    }

    public enum UpcomingPrefetchMode: Sendable, Equatable {
        case disabled
        /// Seed head + tail through the connector's range reads.
        case connectorSeed
        /// Seed head + tail from the plain HTTP URL playback will use.
        case directSeed
        case completeFile
    }

    /// Cache work for a song queued after the current one (`rank` 0 is the
    /// next song). Unlike `backgroundCacheMode`, this covers WebDAV and
    /// Synology too: queue seeds run one bounded request at a time (see
    /// `SpeculativeRangeRead`), which neither overloads DSM nor turns into a
    /// whole-file download behind a proxy that ignores `Range`. OneDrive
    /// seeds use its range connection, which playback leaves free (it streams
    /// one continuous transfer). FTP seeds borrow one pooled control connection
    /// per bounded read and return it afterwards.
    public static func upcomingPrefetchMode(
        sourceType: MusicSourceType,
        transport: UpcomingPlaybackTransport,
        hasKnownFileSize: Bool,
        rank: Int,
        prefersCompleteFile: Bool,
        rangeSeedOnly: Bool
    ) -> UpcomingPrefetchMode {
        switch sourceType {
        case .local, .appleMusic, .appleMusicLibrary:
            return .disabled
        default:
            break
        }
        if prefersCompleteFile, !rangeSeedOnly,
           UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: rank, kind: .medley) {
            return .completeFile
        }
        switch transport {
        case .connectorRange:
            return hasKnownFileSize ? .connectorSeed : .disabled
        case .directHTTPRange:
            return hasKnownFileSize ? .directSeed : .disabled
        case .completeFile:
            if !rangeSeedOnly,
               UpcomingPlaybackPrefetchPolicy.allowsCompleteFile(rank: rank, kind: .original) {
                return .completeFile
            }
            return .disabled
        }
    }

    /// Whether a foreground range read may schedule completion of the
    /// remaining cache gap in the background. Constrained connectors must
    /// stay demand-driven even when the remaining file is below the generic
    /// trailing-fill threshold.
    public static func allowsAutomaticTrailingFill(for sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        // Audio Station 与群晖直连落在同一台 DSM 的 CGI 上,保持同样的按需读取。
        case .oneDrive, .ftp, .webdav, .infiniCloud, .synology, .synologyAudioStation:
            return false
        default:
            return true
        }
    }
}
