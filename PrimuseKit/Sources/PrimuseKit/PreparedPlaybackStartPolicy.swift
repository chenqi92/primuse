import Foundation

/// Rules for the song opened ahead of time: the one after the current song,
/// resolved, connected to its prefetched bytes and decoded into its first
/// buffers while the current song plays, so that pressing Next or reaching the
/// end starts it without waiting.
public enum PreparedPlaybackStartPolicy {
    /// A prepared song older than this is opened again: a signed stream URL
    /// may have expired, and nobody has asked for it in a long while.
    public static let maximumAge: TimeInterval = 30 * 60

    public struct Identity: Sendable, Equatable {
        public var songID: String
        public var sourceID: String
        public var filePath: String
        public var fileSize: Int64
        public var revision: String?
        public var fileFormat: AudioFormat

        public init(
            songID: String,
            sourceID: String,
            filePath: String,
            fileSize: Int64,
            revision: String?,
            fileFormat: AudioFormat
        ) {
            self.songID = songID
            self.sourceID = sourceID
            self.filePath = filePath
            self.fileSize = fileSize
            self.revision = revision
            self.fileFormat = fileFormat
        }

        public init(_ song: Song) {
            self.init(
                songID: song.id,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileSize: song.fileSize,
                revision: song.revision,
                fileFormat: song.fileFormat
            )
        }
    }

    /// What the playback path can take over: a streamed song decoded from
    /// its top. Songs that start mid-file, need the complete file or a
    /// content probe first, play through another player, or have nothing to
    /// stream are started the ordinary way.
    public static func allowsPreparation(
        streamsByRange: Bool,
        startsMidFile: Bool,
        format: AudioFormat,
        requiresCompleteLocalFile: Bool,
        isEpisodeOrStreamDescriptor: Bool,
        hasMusicVideo: Bool,
        queuePrefetchEnabled: Bool,
        audioCacheEnabled: Bool
    ) -> Bool {
        guard queuePrefetchEnabled, audioCacheEnabled, streamsByRange else { return false }
        guard !startsMidFile, !requiresCompleteLocalFile,
              !isEpisodeOrStreamDescriptor, !hasMusicVideo else { return false }
        // A remote WAV is probed for DTS before it is decoded; DSD has its own
        // output negotiation.
        switch format {
        case .wav, .dsf, .dff:
            return false
        default:
            return true
        }
    }

    public enum Verdict: Sendable, Equatable {
        case adopt
        case discard(String)
    }

    /// Whether the song playback is about to start can take over the
    /// prepared one. Anything that changed the stream underneath it — a new
    /// network path (the URL may name the other route), a source reconnect,
    /// a different file, the cache setting — opens the song afresh.
    public static func verdict(
        prepared: Identity,
        requested: Identity,
        preparedNetworkGeneration: UInt64,
        currentNetworkGeneration: UInt64,
        streamEpochIsCurrent: Bool,
        preparedWithAudioCache: Bool,
        audioCacheEnabled: Bool,
        age: TimeInterval
    ) -> Verdict {
        guard prepared.songID == requested.songID else { return .discard("another song") }
        guard prepared == requested else { return .discard("song changed") }
        guard preparedNetworkGeneration == currentNetworkGeneration else {
            return .discard("network changed")
        }
        guard streamEpochIsCurrent else { return .discard("source reconnected") }
        guard preparedWithAudioCache == audioCacheEnabled else {
            return .discard("cache setting changed")
        }
        guard age >= 0, age <= maximumAge else { return .discard("expired") }
        return .adopt
    }
}
