import Foundation
import Testing
@testable import PrimuseKit

@Suite("DSD output probe policy")
struct DSDOutputProbePolicyTests {
    @Test("A non-DSD track opens no DSD decoder")
    func nonDSDNeedsNoProbe() {
        #expect(
            DSDOutputProbePolicy.required(
                isLocalDSD: false,
                outputModeIsHighFidelity: true,
                dsdPlaybackModeIsPCM: false
            ) == .none
        )
        #expect(
            DSDOutputProbePolicy.required(
                isLocalDSD: false,
                outputModeIsHighFidelity: false,
                dsdPlaybackModeIsPCM: true
            ) == .none
        )
    }

    @Test("A DSP-free graph with DoP allowed probes DoP before PCM")
    func highFidelityProbesDoPFirst() {
        #expect(
            DSDOutputProbePolicy.required(
                isLocalDSD: true,
                outputModeIsHighFidelity: true,
                dsdPlaybackModeIsPCM: false
            ) == .dopThenPCM
        )
    }

    @Test("Pinning the DSD mode to PCM skips the DoP probe")
    func pinnedPCMModeSkipsDoP() {
        #expect(
            DSDOutputProbePolicy.required(
                isLocalDSD: true,
                outputModeIsHighFidelity: true,
                dsdPlaybackModeIsPCM: true
            ) == .pcmOnly
        )
    }

    @Test("An effects graph never carries DoP")
    func effectsGraphProbesPCMOnly() {
        #expect(
            DSDOutputProbePolicy.required(
                isLocalDSD: true,
                outputModeIsHighFidelity: false,
                dsdPlaybackModeIsPCM: false
            ) == .pcmOnly
        )
        #expect(
            DSDOutputProbePolicy.required(
                isLocalDSD: true,
                outputModeIsHighFidelity: false,
                dsdPlaybackModeIsPCM: true
            ) == .pcmOnly
        )
    }

    @Test("A PCM probe is required for every local DSD track")
    func everyLocalDSDProbesPCM() {
        for highFidelity in [true, false] {
            for pinnedPCM in [true, false] {
                #expect(
                    DSDOutputProbePolicy.required(
                        isLocalDSD: true,
                        outputModeIsHighFidelity: highFidelity,
                        dsdPlaybackModeIsPCM: pinnedPCM
                    ) != .none
                )
            }
        }
    }
}
