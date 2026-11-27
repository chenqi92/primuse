import Testing
@testable import PrimuseKit

@Suite("Direct PCM output sample rate")
struct DirectPCMOutputSampleRatePolicyTests {
    @Test("A rejected preferred rate uses the actual hardware rate")
    func rejectedRateFallsBack() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: 44_100,
            actualHardwareSampleRate: 48_000
        ) == 48_000)
    }

    @Test("A matched preferred rate remains bit-exactly labelled")
    func matchedRateIsPreserved() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: 96_000,
            actualHardwareSampleRate: 96_000
        ) == 96_000)
        #expect(DirectPCMOutputSampleRatePolicy.hardwareMatches(
            requestedSampleRate: 96_000,
            actualHardwareSampleRate: 96_000
        ))
    }

    @Test("An unknown or invalid source rate still uses a valid route rate")
    func invalidSourceUsesRoute() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: nil,
            actualHardwareSampleRate: 48_000
        ) == 48_000)
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: -1,
            actualHardwareSampleRate: 48_000
        ) == 48_000)
    }

    @Test("An unknown hardware rate never trusts the requested label")
    func unknownHardwareDoesNotGuess() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: 192_000,
            actualHardwareSampleRate: 0
        ) == nil)
    }

    @Test("The first decoded buffer must match the configured graph")
    func firstBufferCompatibility() {
        #expect(DirectPCMOutputSampleRatePolicy.bufferMatchesGraph(
            bufferSampleRate: 48_000,
            bufferChannelCount: 2,
            graphSampleRate: 48_000,
            graphChannelCount: 2
        ))
        #expect(!DirectPCMOutputSampleRatePolicy.bufferMatchesGraph(
            bufferSampleRate: 96_000,
            bufferChannelCount: 2,
            graphSampleRate: 48_000,
            graphChannelCount: 2
        ))
        #expect(!DirectPCMOutputSampleRatePolicy.bufferMatchesGraph(
            bufferSampleRate: 48_000,
            bufferChannelCount: 1,
            graphSampleRate: 48_000,
            graphChannelCount: 2
        ))
    }

    @Test("Wireless routes keep the sample rate negotiated by the system")
    func wirelessRoutesDoNotChangeNominalRate() {
        for requestedRateIsSupported in [true, false, nil] as [Bool?] {
            #expect(!DirectPCMOutputSampleRatePolicy.shouldRequestNominalSampleRateChange(
                requestedSampleRate: 44_100,
                currentHardwareSampleRate: 48_000,
                propertyIsSettable: true,
                requestedRateIsSupported: requestedRateIsSupported,
                isSystemManagedWirelessOutput: true
            ))
        }
    }

    @Test("A wired route changes only to a confirmed valid rate")
    func wiredRouteChangeValidation() {
        #expect(DirectPCMOutputSampleRatePolicy.shouldRequestNominalSampleRateChange(
            requestedSampleRate: 96_000,
            currentHardwareSampleRate: 48_000,
            propertyIsSettable: true,
            requestedRateIsSupported: true,
            isSystemManagedWirelessOutput: false
        ))
        #expect(!DirectPCMOutputSampleRatePolicy.shouldRequestNominalSampleRateChange(
            requestedSampleRate: 96_000,
            currentHardwareSampleRate: 48_000,
            propertyIsSettable: true,
            requestedRateIsSupported: false,
            isSystemManagedWirelessOutput: false
        ))
        #expect(!DirectPCMOutputSampleRatePolicy.shouldRequestNominalSampleRateChange(
            requestedSampleRate: 48_000,
            currentHardwareSampleRate: 48_000,
            propertyIsSettable: true,
            requestedRateIsSupported: true,
            isSystemManagedWirelessOutput: false
        ))
    }
}

@Suite("Continuous transition sample rate")
struct ContinuousTransitionSampleRatePolicyTests {
    private func plan(
        isHighFidelity: Bool = false,
        follows: Bool = true,
        dsd: Bool = false,
        current: Double? = 44_100,
        next: Double? = 96_000,
        graph: Double? = 44_100,
        hardware: Double? = 96_000,
        sameAlbum: Bool = false,
        withinAlbum: Bool = false
    ) -> ContinuousTransitionPlan {
        ContinuousTransitionSampleRatePolicy.plan(
            isHighFidelity: isHighFidelity,
            followsSourceSampleRate: follows,
            involvesDSD: dsd,
            currentSourceSampleRate: current,
            nextSourceSampleRate: next,
            graphSampleRate: graph,
            nextHardwareSampleRate: hardware,
            isSameAlbum: sameAlbum,
            switchesWithinAlbum: withinAlbum
        )
    }

    @Test("A rate change across albums is handed off to the new hardware rate")
    func crossAlbumChangeHandsOff() {
        #expect(plan() == .sampleRateHandoff(targetSampleRate: 96_000))
        #expect(plan(isHighFidelity: true) == .sampleRateHandoff(targetSampleRate: 96_000))
    }

    @Test("Without rate matching the effects graph stays seamless")
    func noMatchingStaysSeamless() {
        #expect(plan(follows: false) == .seamless)
    }

    @Test("One album stays continuous on the effects graph unless switching inside albums is on")
    func albumContinuity() {
        #expect(plan(sameAlbum: true) == .seamless)
        #expect(plan(sameAlbum: true, withinAlbum: true) == .sampleRateHandoff(targetSampleRate: 96_000))
        // The direct graph cannot resample, so it switches inside an album too.
        #expect(plan(isHighFidelity: true, sameAlbum: true) == .sampleRateHandoff(targetSampleRate: 96_000))
    }

    @Test("Nothing is switched when the device would keep its rate")
    func unchangedHardwareStaysSeamless() {
        // Same rate as the running graph.
        #expect(plan(next: 44_100, hardware: 44_100) == .seamless)
        // The device cannot take the next rate, so a request would not be made.
        #expect(plan(isHighFidelity: true, next: 352_800, hardware: 44_100) == .seamless)
        // The next song matches the device even though the current one did not.
        #expect(plan(current: 176_400, next: 96_000, graph: 96_000, hardware: 96_000) == .seamless)
    }

    @Test("DSD keeps its previous transitions")
    func dsdKeepsPreviousRules() {
        #expect(plan(isHighFidelity: true, dsd: true) == .restart)
        #expect(plan(dsd: true) == .seamless)
    }

    @Test("An unknown successor rate cannot be prepared for")
    func unknownSuccessorRate() {
        #expect(plan(next: nil) == .seamless)
        #expect(plan(isHighFidelity: true, next: nil) == .restart)
        #expect(plan(isHighFidelity: true, current: nil, next: nil) == .seamless)
    }

    @Test("Without a live graph only equal rates stay continuous on the direct graph")
    func missingGraph() {
        #expect(plan(isHighFidelity: true, graph: nil) == .restart)
        #expect(plan(isHighFidelity: true, current: 96_000, graph: nil) == .seamless)
        #expect(plan(graph: nil) == .seamless)
        #expect(plan(isHighFidelity: true, hardware: nil) == .restart)
    }

    @Test("Albums match by id, or by title and album artist when ids are missing")
    func albumIdentity() {
        typealias Key = ContinuousTransitionSampleRatePolicy.AlbumKey
        let byID = Key(albumID: "a1", albumTitle: "Kind of Blue", albumArtist: "Miles Davis")
        #expect(ContinuousTransitionSampleRatePolicy.isSameAlbum(
            byID, Key(albumID: " A1 ", albumTitle: "Other", albumArtist: nil)
        ))
        #expect(!ContinuousTransitionSampleRatePolicy.isSameAlbum(
            byID, Key(albumID: "a2", albumTitle: "Kind of Blue", albumArtist: "Miles Davis")
        ))
        let titled = Key(albumID: nil, albumTitle: "Café Tacvba", albumArtist: "Café Tacvba")
        #expect(ContinuousTransitionSampleRatePolicy.isSameAlbum(
            titled, Key(albumID: "x", albumTitle: "cafe tacvba", albumArtist: "CAFE TACVBA")
        ))
        #expect(!ContinuousTransitionSampleRatePolicy.isSameAlbum(
            titled, Key(albumID: nil, albumTitle: "Café Tacvba", albumArtist: "Other")
        ))
        #expect(!ContinuousTransitionSampleRatePolicy.isSameAlbum(
            Key(albumID: nil, albumTitle: " ", albumArtist: "A"),
            Key(albumID: nil, albumTitle: nil, albumArtist: "A")
        ))
    }
}

@Suite("Sample-rate handoff timing")
struct SampleRateHandoffTimingPolicyTests {
    @Test("The switch starts inside closing silence, at most one second early")
    func switchLead() {
        #expect(SampleRateHandoffTimingPolicy.switchLead(trailingSilence: 0.1) == 0)
        #expect(abs(SampleRateHandoffTimingPolicy.switchLead(trailingSilence: 0.5) - 0.45) < 0.000_001)
        #expect(SampleRateHandoffTimingPolicy.switchLead(trailingSilence: 6) == 1)
        #expect(SampleRateHandoffTimingPolicy.switchLead(trailingSilence: .infinity) == 0)
    }

    @Test("The switch frame sits before the boundary by the lead")
    func switchFrame() {
        #expect(SampleRateHandoffTimingPolicy.switchFrame(
            boundaryFrame: 441_000,
            trailingSilentFrames: 44_100 * 3,
            sampleRate: 44_100
        ) == 396_900)
        #expect(SampleRateHandoffTimingPolicy.switchFrame(
            boundaryFrame: 441_000,
            trailingSilentFrames: 2_000,
            sampleRate: 44_100
        ) == nil)
        // Silence longer than the scheduled timeline is clamped to it.
        #expect(SampleRateHandoffTimingPolicy.switchFrame(
            boundaryFrame: 22_050,
            trailingSilentFrames: 441_000,
            sampleRate: 44_100
        ) == 2_205)
        #expect(SampleRateHandoffTimingPolicy.switchFrame(
            boundaryFrame: 441_000,
            trailingSilentFrames: 44_100,
            sampleRate: 0
        ) == nil)
    }

    @Test("Pre-roll completes on duration, bytes or buffer count")
    func preroll() {
        #expect(!SampleRateHandoffTimingPolicy.prerollIsComplete(
            heldDuration: 1,
            heldBytes: 1_000,
            heldBufferCount: 10
        ))
        #expect(SampleRateHandoffTimingPolicy.prerollIsComplete(
            heldDuration: 2,
            heldBytes: 1_000,
            heldBufferCount: 10
        ))
        #expect(SampleRateHandoffTimingPolicy.prerollIsComplete(
            heldDuration: 0.5,
            heldBytes: SampleRateHandoffTimingPolicy.maximumPrerollBytes,
            heldBufferCount: 10
        ))
        // Tiny decoder buffers must not outgrow the scheduling gate's count.
        #expect(SampleRateHandoffTimingPolicy.prerollIsComplete(
            heldDuration: 0.5,
            heldBytes: 1_000,
            heldBufferCount: SampleRateHandoffTimingPolicy.maximumPrerollBufferCount
        ))
    }
}
