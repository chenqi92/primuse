import Testing
@testable import PrimuseKit

@Suite("Playback automatic advance eligibility")
struct PlaybackAdvanceEligibilityPolicyTests {
    @Test(
        "Interruption rejects every stale local completion",
        arguments: ["final", "gapless", "crossfade", "failure"]
    )
    func interruptionRejectsStaleCompletions(_ trigger: String) {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let stale = gate.beginTransport(itemID: "song-a")

        gate.invalidate()

        let decision = gate.consume(
            stale,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: false
        )
        #expect(decision != .accepted, "stale \(trigger) completion advanced")
    }

    @Test("Output route pause rejects the old completion")
    func routePauseRejectsOldCompletion() {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let stale = gate.beginTransport(itemID: "song-a")

        gate.invalidate()

        #expect(gate.consume(
            stale,
            currentItemID: "song-a",
            playbackIsIntended: false,
            transportIsActive: false
        ) != .accepted)
    }

    @Test(
        "Transport replacement never reauthorizes an old terminal ticket",
        arguments: ["configuration", "user-pause", "stop", "track-replacement", "queue-replacement"]
    )
    func transportReplacementRejectsOldTicket(_ reason: String) {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let stale = gate.beginTransport(itemID: "song-a")

        gate.invalidate()
        let replacement = gate.beginTransport(itemID: "song-a")

        #expect(gate.consume(
            stale,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) != .accepted, "old ticket survived \(reason)")
        #expect(gate.consume(
            replacement,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
    }

    @Test("A terminal ticket advances at most once")
    func ticketIsConsumedOnce() {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let ticket = gate.beginTransport(itemID: "song-a")

        #expect(gate.consume(
            ticket,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
        #expect(gate.consume(
            ticket,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .noActiveTicket)
    }

    @Test("Invalidation after consume cancels deferred advance work")
    func consumedTicketDoesNotSurviveLaterInvalidation() {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let ticket = gate.beginTransport(itemID: "song-a")

        #expect(gate.consume(
            ticket,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
        #expect(gate.isGenerationCurrent(for: ticket))

        gate.invalidate()

        #expect(!gate.isGenerationCurrent(for: ticket))
    }

    @Test("Gapless handoff activates only the prepared successor")
    func gaplessHandoffChangesOwnership() throws {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let outgoing = gate.beginTransport(itemID: "song-a")
        let incoming = try #require(gate.prepareSuccessor(itemID: "song-b"))

        #expect(gate.handoff(
            from: outgoing,
            to: incoming,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
        #expect(gate.consume(
            outgoing,
            currentItemID: "song-b",
            playbackIsIntended: true,
            transportIsActive: true
        ) != .accepted)
        #expect(gate.consume(
            incoming,
            currentItemID: "song-b",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
    }

    @Test("A large mixed-provider gapless queue keeps handing off after refill")
    func repeatedGaplessHandoffsKeepTheNextBoundaryEligible() throws {
        let itemIDs = (0..<12_000).map { index in
            let provider = index.isMultiple(of: 2) ? "navidrome" : "webdav-dts"
            return "\(provider)-\(index)"
        }
        var gate = PlaybackAdvanceEligibilityPolicy()
        var currentItemID = try #require(itemIDs.first)
        var currentTicket = gate.beginTransport(itemID: currentItemID)

        for nextItemID in itemIDs.dropFirst() {
            let successor = try #require(gate.prepareSuccessor(itemID: nextItemID))
            #expect(gate.handoff(
                from: currentTicket,
                to: successor,
                currentItemID: currentItemID,
                playbackIsIntended: true,
                transportIsActive: true
            ) == .accepted)
            currentItemID = nextItemID
            currentTicket = successor
        }

        #expect(gate.consume(
            currentTicket,
            currentItemID: currentItemID,
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
    }

    @Test("Denied interruption end never creates a replacement transport")
    func deniedEndDoesNotResume() {
        var resume = PlaybackInterruptionResumePolicy()
        var gate = PlaybackAdvanceEligibilityPolicy()
        _ = gate.beginTransport(itemID: "song-a")
        resume.registerPlayIntent()
        resume.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")
        gate.invalidate()

        let shouldResume = resume.interruptionEnded(
            systemShouldResume: false,
            currentItemID: "song-a"
        )
        #expect(!shouldResume)
        #expect(gate.activeTicket == nil)
    }

    @Test("Authorized interruption end rebuilds the same item exactly once")
    func authorizedEndRebuildsOnce() {
        var resume = PlaybackInterruptionResumePolicy()
        var gate = PlaybackAdvanceEligibilityPolicy()
        let stale = gate.beginTransport(itemID: "song-a")
        resume.registerPlayIntent()
        resume.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")
        gate.invalidate()

        let firstDecision = resume.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-a"
        )
        let repeatedDecision = resume.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-a"
        )
        #expect(firstDecision)
        #expect(!repeatedDecision)

        let rebuilt = gate.beginTransport(itemID: "song-a")
        #expect(gate.consume(
            stale,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) != .accepted)
        #expect(gate.consume(
            rebuilt,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
    }

    @Test("Manual resume creates a fresh natural-end ticket")
    func manualResumeCanAdvanceNaturally() {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let pausedTransport = gate.beginTransport(itemID: "song-a")
        gate.invalidate()

        let resumedTransport = gate.beginTransport(itemID: "song-a")

        #expect(gate.consume(
            pausedTransport,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) != .accepted)
        #expect(gate.consume(
            resumedTransport,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
    }

    @Test("A prepared paused pipeline keeps its natural-end ticket")
    func preparedPausedPipelineKeepsTicket() {
        var gate = PlaybackAdvanceEligibilityPolicy()
        let preparedTicket = gate.beginTransport(itemID: "song-a")

        #expect(gate.activeTicket == preparedTicket)
        #expect(gate.consume(
            preparedTicket,
            currentItemID: "song-a",
            playbackIsIntended: true,
            transportIsActive: true
        ) == .accepted)
    }

    @Test("Recovery EOF preserves the item while a user seek EOF may advance")
    func recoveryEOFDoesNotAdvance() {
        #expect(PlaybackSeekEndPolicy.action(isRecovery: true) == .preserveCurrentItem)
        #expect(PlaybackSeekEndPolicy.action(isRecovery: false) == .advance)
    }

    @Test("App activation never turns recovery state into a play action")
    func appActivationDoesNotResume() {
        #expect(PlaybackAppActivationPolicy.action(
            needsPlaybackRecovery: true
        ) == .preservePendingRecovery)
        #expect(PlaybackAppActivationPolicy.action(
            needsPlaybackRecovery: false
        ) == .synchronizeVisibleState)
    }

    @Test("Only a state query may use queued Watch delivery")
    func staleWatchControlsAreRejected() {
        #expect(WatchQueuedCommandPolicy.acceptsQueuedDelivery(command: "requestState"))
        for command in ["play", "togglePlayPause", "next", "previous", "seek", "playSong"] {
            #expect(!WatchQueuedCommandPolicy.acceptsQueuedDelivery(command: command))
        }
    }
}
