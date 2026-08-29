import Testing
@testable import PrimuseKit

struct MetadataTitleResolutionPolicyTests {
    @Test("Common title remains authoritative")
    func commonTitleWins() {
        let title = MetadataTitleResolutionPolicy.preferredEmbeddedTitle(from: [
            .init(value: "QuickTime Title", source: .quickTimeMetadataTitle),
            .init(value: "Common Title", source: .common),
            .init(value: "iTunes Title", source: .iTunesSongName),
        ])

        #expect(title == "Common Title")
    }

    @Test("A trustworthy format title beats damaged common text")
    func trustworthyFormatTitleBeatsDamagedCommonText() {
        let title = MetadataTitleResolutionPolicy.preferredEmbeddedTitle(from: [
            .init(value: "损坏�标题", source: .common),
            .init(value: "真实标题", source: .iTunesSongName),
        ])

        #expect(title == "真实标题")
    }

    @Test("Blank candidates are ignored")
    func blankCandidatesAreIgnored() {
        let title = MetadataTitleResolutionPolicy.preferredEmbeddedTitle(from: [
            .init(value: "  ", source: .common),
            .init(value: "  Track Name  ", source: .quickTimeUserDataTrackName),
        ])

        #expect(title == "Track Name")
    }

    @Test("Only untouched non-CUE filename fallbacks are reopened")
    func fileNameFallbackEligibility() {
        #expect(MetadataTitleResolutionPolicy.shouldReinspectFileNameFallback(
            currentTitle: "01 - File Name",
            filePath: "/Music/01 - File Name.m4a",
            userEdited: false,
            isCueTrack: false
        ))
        #expect(!MetadataTitleResolutionPolicy.shouldReinspectFileNameFallback(
            currentTitle: "Custom Name",
            filePath: "/Music/01 - File Name.m4a",
            userEdited: true,
            isCueTrack: false
        ))
        #expect(!MetadataTitleResolutionPolicy.shouldReinspectFileNameFallback(
            currentTitle: "01 - File Name",
            filePath: "/Music/01 - File Name.m4a",
            userEdited: false,
            isCueTrack: true
        ))
    }
}
