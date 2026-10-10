import Foundation
import Testing
@testable import PrimuseKit

@Suite("Prepared Playback Start Policy")
struct PreparedPlaybackStartPolicyTests {
    private let song = PreparedPlaybackStartPolicy.Identity(
        songID: "s1", sourceID: "nas", filePath: "/a/b.flac",
        fileSize: 30_000_000, revision: "r1", fileFormat: .flac
    )

    private func verdict(
        requested: PreparedPlaybackStartPolicy.Identity? = nil,
        network: UInt64 = 4,
        epochCurrent: Bool = true,
        cache: Bool = true,
        age: TimeInterval = 12
    ) -> PreparedPlaybackStartPolicy.Verdict {
        PreparedPlaybackStartPolicy.verdict(
            prepared: song,
            requested: requested ?? song,
            preparedNetworkGeneration: 4,
            currentNetworkGeneration: network,
            streamEpochIsCurrent: epochCurrent,
            preparedWithAudioCache: true,
            audioCacheEnabled: cache,
            age: age
        )
    }

    @Test("The same untouched song is taken over")
    func adoptsSameSong() {
        #expect(verdict() == .adopt)
    }

    @Test("Anything that changed the stream opens the song afresh")
    func discardsChangedStream() {
        var other = song
        other.songID = "s2"
        #expect(verdict(requested: other) == .discard("another song"))
        var replaced = song
        replaced.revision = "r2"
        #expect(verdict(requested: replaced) == .discard("song changed"))
        #expect(verdict(network: 5) == .discard("network changed"))
        #expect(verdict(epochCurrent: false) == .discard("source reconnected"))
        #expect(verdict(cache: false) == .discard("cache setting changed"))
        #expect(verdict(age: PreparedPlaybackStartPolicy.maximumAge + 1) == .discard("expired"))
    }

    @Test("Only streamed songs decoded from the top are prepared")
    func eligibility() {
        func allows(
            streams: Bool = true, midFile: Bool = false, format: AudioFormat = .mp3,
            complete: Bool = false, episode: Bool = false, video: Bool = false,
            prefetch: Bool = true, cache: Bool = true
        ) -> Bool {
            PreparedPlaybackStartPolicy.allowsPreparation(
                streamsByRange: streams, startsMidFile: midFile, format: format,
                requiresCompleteLocalFile: complete, isEpisodeOrStreamDescriptor: episode,
                hasMusicVideo: video, queuePrefetchEnabled: prefetch, audioCacheEnabled: cache
            )
        }
        #expect(allows())
        #expect(allows(format: .flac))
        #expect(!allows(streams: false))
        #expect(!allows(midFile: true))
        #expect(!allows(format: .wav))
        #expect(!allows(format: .dsf))
        #expect(!allows(complete: true))
        #expect(!allows(episode: true))
        #expect(!allows(video: true))
        #expect(!allows(prefetch: false))
        #expect(!allows(cache: false))
    }
}
