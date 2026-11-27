import Testing
@testable import PrimuseKit

@Suite("Remote WAV playback safety policy")
struct RemoteWAVPlaybackPolicyTests {
    @Test("DTS carrier and unavailable probes require a complete file")
    func routesUnsafeWAVOutcomesToCompleteFile() {
        #expect(RemoteWAVPlaybackPolicy.requiresCompleteFile(
            persistedFormat: .wav,
            probeOutcome: .dts
        ))
        #expect(RemoteWAVPlaybackPolicy.requiresCompleteFile(
            persistedFormat: .wav,
            probeOutcome: .unavailable
        ))
    }

    @Test("Confirmed PCM WAV keeps range streaming")
    func keepsConfirmedPCMWAVOnRangePath() {
        #expect(!RemoteWAVPlaybackPolicy.requiresCompleteFile(
            persistedFormat: .wav,
            probeOutcome: .pcm
        ))
    }

    @Test("The WAV-specific probe cannot reroute other formats")
    func leavesOtherFormatsAlone() {
        #expect(!RemoteWAVPlaybackPolicy.requiresCompleteFile(
            persistedFormat: .flac,
            probeOutcome: .dts
        ))
    }
}
