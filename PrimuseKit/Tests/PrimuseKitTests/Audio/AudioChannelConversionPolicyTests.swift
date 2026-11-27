import Testing
@testable import PrimuseKit

@Suite("Audio channel conversion policy")
struct AudioChannelConversionPolicyTests {
    @Test("Multichannel audio is mixed when the output has fewer channels")
    func enablesDownmixForSurroundToStereo() {
        #expect(AudioChannelConversionPolicy.requiresDownmix(
            sourceChannelCount: 6,
            outputChannelCount: 2
        ))
    }

    @Test("Equal and expanding channel layouts do not enable downmix")
    func leavesNonReducingConversionsAlone() {
        #expect(!AudioChannelConversionPolicy.requiresDownmix(
            sourceChannelCount: 2,
            outputChannelCount: 2
        ))
        #expect(!AudioChannelConversionPolicy.requiresDownmix(
            sourceChannelCount: 1,
            outputChannelCount: 2
        ))
        #expect(!AudioChannelConversionPolicy.requiresDownmix(
            sourceChannelCount: 6,
            outputChannelCount: 0
        ))
    }
}
