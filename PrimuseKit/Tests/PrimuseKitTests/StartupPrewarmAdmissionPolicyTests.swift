import Testing
@testable import PrimuseKit

@Suite("Startup prewarm admission policy")
struct StartupPrewarmAdmissionPolicyTests {
    @Test("Disabled automatic caching admits nothing")
    func disabledCachingAdmitsNothing() {
        let admitted = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: "resume",
            queueSongIDs: ["a", "b"],
            alreadyPrewarmedIDs: [],
            inFlightBackgroundCacheSongIDs: [],
            requestedCount: 3,
            automaticCachingEnabled: false
        )
        #expect(admitted.isEmpty)
    }

    @Test("Zero requested queue songs still prewarms the resume song")
    func zeroRequestedKeepsResumeSong() {
        let admitted = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: "resume",
            queueSongIDs: ["a", "b"],
            alreadyPrewarmedIDs: [],
            inFlightBackgroundCacheSongIDs: [],
            requestedCount: 0,
            automaticCachingEnabled: true
        )
        #expect(admitted == ["resume"])

        let withoutResume = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: nil,
            queueSongIDs: ["a", "b"],
            alreadyPrewarmedIDs: [],
            inFlightBackgroundCacheSongIDs: [],
            requestedCount: 0,
            automaticCachingEnabled: true
        )
        #expect(withoutResume.isEmpty)
    }

    @Test("A song already registered in the background cache registry is dropped")
    func inFlightSongsAreDropped() {
        let admitted = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: "resume",
            queueSongIDs: ["a", "b", "c"],
            alreadyPrewarmedIDs: [],
            inFlightBackgroundCacheSongIDs: ["resume", "b"],
            requestedCount: 3,
            automaticCachingEnabled: true
        )
        #expect(admitted == ["a", "c"])
    }

    @Test("Seeded songs are dropped")
    func prewarmedSongsAreDropped() {
        let admitted = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: "resume",
            queueSongIDs: ["a", "b"],
            alreadyPrewarmedIDs: ["a"],
            inFlightBackgroundCacheSongIDs: [],
            requestedCount: 3,
            automaticCachingEnabled: true
        )
        #expect(admitted == ["resume", "b"])
    }

    @Test("Resume song comes first and is never repeated by the queue tail")
    func resumeSongIsFirstAndUnique() {
        let admitted = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: "resume",
            queueSongIDs: ["resume", "a", "resume", "a", "b"],
            alreadyPrewarmedIDs: [],
            inFlightBackgroundCacheSongIDs: [],
            requestedCount: 3,
            automaticCachingEnabled: true
        )
        #expect(admitted == ["resume", "a", "b"])
    }

    @Test("Admitted count never exceeds one resume song plus the requested tail")
    func admittedCountIsBounded() {
        let queue = (0..<40).map { "song-\($0)" }
        let admitted = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: "resume",
            queueSongIDs: queue,
            alreadyPrewarmedIDs: [],
            inFlightBackgroundCacheSongIDs: [],
            requestedCount: 3,
            automaticCachingEnabled: true
        )
        #expect(admitted.count == 4)
        #expect(admitted.count <= 1 + 3)

        let negative = StartupPrewarmAdmissionPolicy.songsToPrewarm(
            resumeSongID: nil,
            queueSongIDs: queue,
            alreadyPrewarmedIDs: [],
            inFlightBackgroundCacheSongIDs: [],
            requestedCount: -5,
            automaticCachingEnabled: true
        )
        #expect(negative.isEmpty)
    }
}
