import Testing
@testable import PrimuseKit

@Suite("Local playback resume policy")
struct LocalPlaybackResumePolicyTests {
    @Test("An unprepared engine restarts the current song")
    func restartsAfterPreparationFailure() {
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: false,
            needsRecovery: false,
            hasPreparedAudio: false
        ) == .restartCurrentSong)
    }

    @Test("Only prepared audio uses the engine resume path")
    func resumesPreparedAudio() {
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: false,
            needsRecovery: false,
            hasPreparedAudio: true
        ) == .resumePreparedAudio)
    }

    @Test("Track-end replay and interruption recovery keep their dedicated paths")
    func preservesExistingRecoverySemantics() {
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: true,
            needsRecovery: true,
            hasPreparedAudio: true
        ) == .restartCurrentSong)
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: false,
            needsRecovery: true,
            hasPreparedAudio: true
        ) == .recoverFromInterruption)
    }
}
