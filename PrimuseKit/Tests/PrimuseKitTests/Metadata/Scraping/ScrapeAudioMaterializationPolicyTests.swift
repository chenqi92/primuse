import Testing
@testable import PrimuseKit

@Suite("Scrape audio materialization policy")
struct ScrapeAudioMaterializationPolicyTests {
    @Test("Range-backed complete-file formats use scanned metadata")
    func remoteCompleteFileFormatSkipsPlaybackResolution() {
        #expect(!ScrapeAudioMaterializationPolicy.shouldResolvePlaybackURL(
            sourceSupportsRangeStreaming: true,
            formatRequiresCompleteLocalFile: true
        ))
    }

    @Test("Range-backed streamable formats retain normal resolution")
    func remoteStreamableFormatKeepsPlaybackResolution() {
        #expect(ScrapeAudioMaterializationPolicy.shouldResolvePlaybackURL(
            sourceSupportsRangeStreaming: true,
            formatRequiresCompleteLocalFile: false
        ))
    }

    @Test("Non-range sources retain local metadata extraction")
    func nonRangeSourceKeepsPlaybackResolution() {
        #expect(ScrapeAudioMaterializationPolicy.shouldResolvePlaybackURL(
            sourceSupportsRangeStreaming: false,
            formatRequiresCompleteLocalFile: true
        ))
    }
}
