import Testing
@testable import PrimuseKit

@Suite struct PlaybackSourceAvailabilityPolicyTests {
    @Test func mixedQueueSkipsEveryUnavailableSourceEntryButKeepsOfflineCopies() {
        let sources = ["wan", "lan", "wan", "lan", "lan"]
        let cached = [false, false, false, false, true]
        let isAvailable: (Int) -> Bool = { index in
            PlaybackSourceAvailabilityPolicy.allowsPlayback(
                isSourceEnabled: true,
                isSourceUnreachable: sources[index] == "lan",
                hasUsableLocalAudio: cached[index]
            )
        }
        #expect(QueueTraversalPolicy.nextAvailableIndex(
            queueCount: sources.count, after: 0, wraps: false,
            isAvailable: isAvailable
        ) == 2)
        #expect(QueueTraversalPolicy.nextAvailableIndex(
            queueCount: sources.count, after: 2, wraps: false,
            isAvailable: isAvailable
        ) == 4)
        let shuffleOrder = [0, 3, 1, 4, 2]
        #expect(QueueTraversalPolicy.nextAvailableTraversalPosition(
            in: shuffleOrder, queueCount: sources.count, after: 0,
            isAvailable: isAvailable
        ) == 3)
    }

    @Test func allUnavailableQueueHasNoSuccessorEvenWithRepeatAll() {
        #expect(QueueTraversalPolicy.nextAvailableIndex(
            queueCount: 500, after: 218, wraps: true,
            isAvailable: { _ in
                PlaybackSourceAvailabilityPolicy.allowsPlayback(
                    isSourceEnabled: true,
                    isSourceUnreachable: true,
                    hasUsableLocalAudio: false
                )
            }
        ) == nil)
        #expect(!PlaybackSourceAvailabilityPolicy.allowsPlayback(
            isSourceEnabled: false,
            isSourceUnreachable: true,
            hasUsableLocalAudio: true
        ))
    }

    @Test func newNetworkAndSourceConfigurationDiscardOldOutageEvidence() {
        var policy = PlaybackSourceAvailabilityPolicy()
        policy.record(isUnreachable: true, sourceID: "nas", networkGeneration: 3,
                      sourceGeneration: 4, now: 100)
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 3,
                                           sourceGeneration: 4, now: 101) == true)
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 4,
                                           sourceGeneration: 4, now: 101) == nil)
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 3,
                                           sourceGeneration: 5, now: 101) == nil)
        #expect(policy.cachedUnavailability(sourceID: "other", networkGeneration: 3,
                                           sourceGeneration: 4, now: 101) == nil)
    }

    @Test func freshVerdictsAgeOutAndAnExplicitReconnectClearsThem() {
        var policy = PlaybackSourceAvailabilityPolicy()
        policy.record(isUnreachable: true, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: 0)
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 1,
                                           sourceGeneration: 0, now: 60) == nil)
        policy.invalidate(sourceID: "nas")
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 1,
                                           sourceGeneration: 0, now: 1) == nil)
        #expect(policy.standing(sourceID: "nas", networkGeneration: 1,
                                sourceGeneration: 0, now: 1) == .unknown)
        policy.record(isUnreachable: false, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: 1)
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 1,
                                           sourceGeneration: 0, now: 2) == false)
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 1,
                                           sourceGeneration: 0, now: 16) == nil)
    }

    @Test func agedOutageKeepsSkippingSongsUntilAProbeAnswers() {
        var policy = PlaybackSourceAvailabilityPolicy()
        policy.record(isUnreachable: true, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: 0)
        let fresh = policy.standing(sourceID: "nas", networkGeneration: 1,
                                    sourceGeneration: 0, now: 19)
        #expect(fresh == .unreachable)
        #expect(fresh.skipsUncachedSongs)
        #expect(!fresh.wantsProbe)

        // A song lasts longer than any verdict. The aged outage must not turn
        // the source back into a candidate; it only asks for another probe.
        let aged = policy.standing(sourceID: "nas", networkGeneration: 1,
                                   sourceGeneration: 0, now: 240)
        #expect(aged == .unreachableAwaitingRecheck)
        #expect(aged.skipsUncachedSongs)
        #expect(aged.wantsProbe)
        #expect(policy.cachedUnavailability(sourceID: "nas", networkGeneration: 1,
                                           sourceGeneration: 0, now: 240) == nil)

        policy.record(isUnreachable: false, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: 241)
        let recovered = policy.standing(sourceID: "nas", networkGeneration: 1,
                                        sourceGeneration: 0, now: 900)
        #expect(recovered == .reachable)
        #expect(!recovered.skipsUncachedSongs)
        #expect(!recovered.wantsProbe)
    }

    @Test func newNetworkPathOrSourceConfigurationMakesTheSourceACandidateAgain() {
        var policy = PlaybackSourceAvailabilityPolicy()
        policy.record(isUnreachable: true, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: 0)
        let onNewPath = policy.standing(sourceID: "nas", networkGeneration: 2,
                                        sourceGeneration: 0, now: 1)
        #expect(onNewPath == .unknown)
        #expect(!onNewPath.skipsUncachedSongs)
        #expect(onNewPath.wantsProbe)
        #expect(policy.standing(sourceID: "nas", networkGeneration: 1,
                                sourceGeneration: 1, now: 1) == .unknown)

        // Recording on the new path drops what the old one left behind.
        policy.record(isUnreachable: false, sourceID: "cloud", networkGeneration: 2,
                      sourceGeneration: 0, now: 2)
        #expect(policy.standing(sourceID: "nas", networkGeneration: 1,
                                sourceGeneration: 0, now: 2) == .unknown)
    }

    @Test func outageRechecksBackOffAndARecoveryStartsOver() {
        var policy = PlaybackSourceAvailabilityPolicy()
        var now = 0.0
        var intervals: [Double] = []
        for _ in 0..<6 {
            policy.record(isUnreachable: true, sourceID: "nas", networkGeneration: 1,
                          sourceGeneration: 0, now: now)
            let next = policy.nextRecheckTime(networkGeneration: 1) { _ in 0 }
            intervals.append((next ?? now) - now)
            now = next ?? now
        }
        #expect(intervals == [20, 60, 120, 300, 300, 300])

        policy.record(isUnreachable: false, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: now)
        #expect(policy.nextRecheckTime(networkGeneration: 1) { _ in 0 } == nil)
        policy.record(isUnreachable: true, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: now)
        #expect(policy.nextRecheckTime(networkGeneration: 1) { _ in 0 } == now + 20)
    }

    @Test func projectionsOnlyReportOutagesOfTheCurrentPathAndConfiguration() {
        var policy = PlaybackSourceAvailabilityPolicy()
        policy.record(isUnreachable: true, sourceID: "home", networkGeneration: 5,
                      sourceGeneration: 2, now: 0)
        policy.record(isUnreachable: true, sourceID: "office", networkGeneration: 5,
                      sourceGeneration: 0, now: 10)
        policy.record(isUnreachable: false, sourceID: "cloud", networkGeneration: 5,
                      sourceGeneration: 0, now: 10)
        let generations = ["home": 2, "office": 0, "cloud": 0]
        let generation: (String) -> Int = { generations[$0] ?? 0 }

        #expect(policy.unreachableSourceIDs(networkGeneration: 5, sourceGeneration: generation)
                == ["home", "office"])
        #expect(policy.sourceIDsAwaitingRecheck(networkGeneration: 5,
                                                sourceGeneration: generation, now: 25) == ["home"])
        #expect(policy.nextRecheckTime(networkGeneration: 5, sourceGeneration: generation) == 20)

        // An edited source is a different source as far as evidence goes.
        let edited: (String) -> Int = { $0 == "home" ? 3 : 0 }
        #expect(policy.unreachableSourceIDs(networkGeneration: 5, sourceGeneration: edited)
                == ["office"])
        #expect(policy.nextRecheckTime(networkGeneration: 5, sourceGeneration: edited) == 30)
        #expect(policy.unreachableSourceIDs(networkGeneration: 6, sourceGeneration: generation).isEmpty)
        #expect(policy.nextRecheckTime(networkGeneration: 6, sourceGeneration: generation) == nil)
    }

    @Test func aRecheckWithoutAVerdictWaitsAnotherIntervalInsteadOfSpinning() {
        var policy = PlaybackSourceAvailabilityPolicy()
        policy.record(isUnreachable: true, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: 0)
        policy.postponeRecheck(sourceID: "nas", now: 5)
        #expect(policy.nextRecheckTime(networkGeneration: 1) { _ in 0 } == 20)

        policy.postponeRecheck(sourceID: "nas", now: 21)
        #expect(policy.nextRecheckTime(networkGeneration: 1) { _ in 0 } == 41)
        #expect(policy.standing(sourceID: "nas", networkGeneration: 1,
                                sourceGeneration: 0, now: 22) == .unreachable)

        policy.record(isUnreachable: false, sourceID: "nas", networkGeneration: 1,
                      sourceGeneration: 0, now: 50)
        policy.postponeRecheck(sourceID: "nas", now: 500)
        #expect(policy.standing(sourceID: "nas", networkGeneration: 1,
                                sourceGeneration: 0, now: 500) == .reachable)
    }
}
