import Foundation
import Testing
@testable import PrimuseKit

@Suite("ReplayGain policy")
struct ReplayGainPolicyTests {
    @Test("A missing or broken tag plays at unity")
    func missingTagIsUnity() {
        #expect(ReplayGainPolicy.linearGain(gainDB: nil, peak: nil) == 1)
        #expect(ReplayGainPolicy.linearGain(gainDB: nil, peak: 0.5) == 1)
        #expect(ReplayGainPolicy.linearGain(gainDB: .nan, peak: 0.5) == 1)
        #expect(ReplayGainPolicy.linearGain(gainDB: .infinity, peak: nil) == 1)
    }

    @Test("Decibels convert to amplitude")
    func decibelsToAmplitude() {
        let quieter = ReplayGainPolicy.linearGain(gainDB: -6.0206, peak: nil)
        #expect(abs(quieter - 0.5) < 0.001)
        let louder = ReplayGainPolicy.linearGain(gainDB: 6.0206, peak: nil)
        #expect(abs(louder - 2) < 0.001)
    }

    @Test("Peak caps a positive gain below full scale")
    func peakCapsGain() {
        let capped = ReplayGainPolicy.linearGain(gainDB: 6, peak: 0.8)
        #expect(abs(capped - 1.25) < 0.001)
        // A negative gain already fits; the peak must not raise it.
        let quieter = ReplayGainPolicy.linearGain(gainDB: -6.0206, peak: 0.1)
        #expect(abs(quieter - 0.5) < 0.001)
        // Zero, negative or broken peaks are ignored rather than divided by.
        let zeroPeak = ReplayGainPolicy.linearGain(gainDB: 6.0206, peak: 0)
        #expect(abs(zeroPeak - 2) < 0.001)
        let negativePeak = ReplayGainPolicy.linearGain(gainDB: 6.0206, peak: -1)
        #expect(abs(negativePeak - 2) < 0.001)
        let brokenPeak = ReplayGainPolicy.linearGain(gainDB: 6.0206, peak: .nan)
        #expect(abs(brokenPeak - 2) < 0.001)
    }

    @Test("Gain never exceeds the +12 dB ceiling")
    func gainCeiling() {
        let ceiling = ReplayGainPolicy.maximumLinearGain
        #expect(ReplayGainPolicy.linearGain(gainDB: 30, peak: nil) == ceiling)
        #expect(ReplayGainPolicy.linearGain(gainDB: 30, peak: 0.1) == ceiling)
    }

    @Test("Crossfade starts on the outgoing program volume and lands on the incoming one")
    func crossfadeEndpoints() {
        let start = ReplayGainPolicy.crossfadeVolumes(
            progress: 0,
            outgoingGain: 0.45,
            incomingGain: 1.6
        )
        #expect(start == ReplayGainPolicy.CrossfadeVolumes(outgoing: 0.45, incoming: 0))

        let end = ReplayGainPolicy.crossfadeVolumes(
            progress: 1,
            outgoingGain: 0.45,
            incomingGain: 1.6
        )
        #expect(abs(end.outgoing) < 0.0001)
        #expect(abs(end.incoming - 1.6) < 0.0001)
    }

    @Test("Two songs at the same program volume keep equal power throughout")
    func equalPowerThroughout() {
        for step in 0...20 {
            let volumes = ReplayGainPolicy.crossfadeVolumes(
                progress: Double(step) / 20,
                outgoingGain: 0.7,
                incomingGain: 0.7
            )
            let power = volumes.outgoing * volumes.outgoing + volumes.incoming * volumes.incoming
            #expect(abs(power - 0.49) < 0.001)
        }
    }

    @Test("Attenuated songs never pass through unity during the fade")
    func attenuatedFadeStaysBelowProgramVolumes() {
        for step in 0...20 {
            let volumes = ReplayGainPolicy.crossfadeVolumes(
                progress: Double(step) / 20,
                outgoingGain: 0.5,
                incomingGain: 0.4
            )
            #expect(volumes.outgoing <= 0.5)
            #expect(volumes.incoming <= 0.4)
        }
    }

    @Test("Out-of-range progress is clamped")
    func progressClamped() {
        let before = ReplayGainPolicy.crossfadeVolumes(
            progress: -0.5,
            outgoingGain: 1,
            incomingGain: 1
        )
        #expect(before == ReplayGainPolicy.CrossfadeVolumes(outgoing: 1, incoming: 0))

        let after = ReplayGainPolicy.crossfadeVolumes(
            progress: 2,
            outgoingGain: 1,
            incomingGain: 1
        )
        #expect(abs(after.outgoing) < 0.0001)
        #expect(abs(after.incoming - 1) < 0.0001)

        let broken = ReplayGainPolicy.crossfadeVolumes(
            progress: .nan,
            outgoingGain: 1,
            incomingGain: 1
        )
        #expect(abs(broken.incoming - 1) < 0.0001)
    }
}
