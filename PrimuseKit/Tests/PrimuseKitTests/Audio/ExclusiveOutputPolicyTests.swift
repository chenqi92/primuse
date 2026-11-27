import Testing
@testable import PrimuseKit

@Suite("Exclusive output device")
struct ExclusiveOutputPolicyTests {
    @Test("Hog mode pid maps to nobody, this process or another process")
    func ownerFromPID() {
        #expect(ExclusiveOutputOwner(hogModePID: -1, currentPID: 42) == .nobody)
        #expect(ExclusiveOutputOwner(hogModePID: 42, currentPID: 42) == .thisProcess)
        #expect(ExclusiveOutputOwner(hogModePID: 77, currentPID: 42) == .otherProcess(pid: 77))
    }

    @Test("Only a free, settable wired device is claimed")
    func claimDecision() {
        #expect(ExclusiveOutputClaimPolicy.decision(
            owner: .nobody, isSettable: true, isSystemManagedWireless: false
        ) == .claim)
        #expect(ExclusiveOutputClaimPolicy.decision(
            owner: .otherProcess(pid: 77), isSettable: true, isSystemManagedWireless: false
        ) == .heldByOther(pid: 77))
        #expect(ExclusiveOutputClaimPolicy.decision(
            owner: .nobody, isSettable: false, isSystemManagedWireless: false
        ) == .unsupported)
        #expect(ExclusiveOutputClaimPolicy.decision(
            owner: .nobody, isSettable: true, isSystemManagedWireless: true
        ) == .unsupported)
    }

    @Test("A device this process already holds is never written again")
    func alreadyHeldIsKept() {
        #expect(ExclusiveOutputClaimPolicy.decision(
            owner: .thisProcess, isSettable: true, isSystemManagedWireless: false
        ) == .alreadyHeld)
    }

    @Test("Releasing writes only when this process is the owner")
    func releaseNeverClaims() {
        #expect(ExclusiveOutputClaimPolicy.shouldWriteToRelease(owner: .thisProcess))
        #expect(!ExclusiveOutputClaimPolicy.shouldWriteToRelease(owner: .nobody))
        #expect(!ExclusiveOutputClaimPolicy.shouldWriteToRelease(owner: .otherProcess(pid: 77)))
    }

    @Test("Target bit depth follows the song and is rounded up to a device tier")
    func targetBitDepth() {
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 16, carriesDSD: false) == 16)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 24, carriesDSD: false) == 24)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 20, carriesDSD: false) == 24)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 8, carriesDSD: false) == 16)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 32, carriesDSD: false) == 32)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 64, carriesDSD: false) == 32)
    }

    @Test("Lossy or unknown depth leaves the device alone; DSD always asks for 24 bit")
    func unknownAndDSD() {
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: nil, carriesDSD: false) == nil)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 0, carriesDSD: false) == nil)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: 1, carriesDSD: true) == 24)
        #expect(PhysicalOutputBitDepthPolicy.targetBitDepth(sourceBitDepth: nil, carriesDSD: true) == 24)
    }

    private static func pcm(
        _ bits: Int,
        channels: Int = 2,
        float: Bool = false,
        mixable: Bool = true,
        linear: Bool = true,
        rates: ClosedRange<Double> = 44_100...192_000
    ) -> PhysicalOutputBitDepthPolicy.Candidate {
        .init(
            bitsPerChannel: bits,
            channelCount: channels,
            isLinearPCM: linear,
            isFloat: float,
            isMixable: mixable,
            minimumSampleRate: rates.lowerBound,
            maximumSampleRate: rates.upperBound
        )
    }

    @Test("An exact integer match wins over deeper formats")
    func exactMatch() {
        let formats = [Self.pcm(24), Self.pcm(16), Self.pcm(32)]
        let index = PhysicalOutputBitDepthPolicy.select(
            from: formats, sampleRate: 44_100, channelCount: 2, targetBitDepth: 16
        )
        #expect(index == 1)
    }

    @Test("Without an exact match the smallest deeper format is used, then the deepest shallower one")
    func nearestFallback() {
        let deeper = [Self.pcm(32), Self.pcm(24), Self.pcm(16)]
        let deeperIndex = PhysicalOutputBitDepthPolicy.select(
            from: deeper, sampleRate: 96_000, channelCount: 2, targetBitDepth: 20
        )
        #expect(deeperIndex == 1)

        let shallower = [Self.pcm(16), Self.pcm(24)]
        let shallowerIndex = PhysicalOutputBitDepthPolicy.select(
            from: shallower, sampleRate: 96_000, channelCount: 2, targetBitDepth: 32
        )
        #expect(shallowerIndex == 1)
    }

    @Test("Float, non-mixable, wrong-channel and out-of-range formats are skipped")
    func unusableFormatsAreSkipped() {
        let formats = [
            Self.pcm(24, float: true),
            Self.pcm(24, mixable: false),
            Self.pcm(24, channels: 8),
            Self.pcm(24, rates: 44_100...48_000),
            Self.pcm(24, linear: false),
            Self.pcm(16),
        ]
        let index = PhysicalOutputBitDepthPolicy.select(
            from: formats, sampleRate: 96_000, channelCount: 2, targetBitDepth: 24
        )
        #expect(index == 5)
    }

    @Test("A device that lists only float formats is left unchanged")
    func floatOnlyDevice() {
        let formats = [Self.pcm(32, float: true)]
        let index = PhysicalOutputBitDepthPolicy.select(
            from: formats, sampleRate: 48_000, channelCount: 2, targetBitDepth: 24
        )
        #expect(index == nil)
    }

    @Test("A zero sample-rate range means any rate, and the first equal layout is kept")
    func anyRateAndTies() {
        let formats = [Self.pcm(24, rates: 0...0), Self.pcm(24, rates: 0...0)]
        let index = PhysicalOutputBitDepthPolicy.select(
            from: formats, sampleRate: 352_800, channelCount: 2, targetBitDepth: 24
        )
        #expect(index == 0)

        let deeperTies = [Self.pcm(16), Self.pcm(32), Self.pcm(32)]
        let tieIndex = PhysicalOutputBitDepthPolicy.select(
            from: deeperTies, sampleRate: 44_100, channelCount: 2, targetBitDepth: 24
        )
        #expect(tieIndex == 1)
    }
}
