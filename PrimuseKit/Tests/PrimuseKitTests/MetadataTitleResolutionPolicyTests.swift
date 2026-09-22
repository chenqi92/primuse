import Testing
@testable import PrimuseKit

struct MetadataTitleResolutionPolicyTests {
    @Test("Artist duplicated into title is recovered from either filename order", arguments: [
        "走在冷风中 (Live) - 刘思涵",
        "刘思涵 - 走在冷风中 (Live)",
        "走在冷风中 (Live) — 刘思涵",
        "刘思涵 _ 走在冷风中 (Live)",
    ])
    func duplicatedArtistTitle(fileStem: String) {
        #expect(MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: "刘思涵", artist: "刘思涵", fileStem: fileStem
        ) == "走在冷风中 (Live)")
    }

    @Test("Filename evidence must independently match the artist", arguments: [
        "刘思涵", "刘思涵 - 刘思涵", "01 - 刘思涵", "12345678",
        "走在冷风中 (Live) - 其他歌手", "损坏�标题 - 刘思涵", " - 刘思涵",
    ])
    func rejectsAmbiguousFilename(fileStem: String) {
        #expect(MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: "刘思涵", artist: "刘思涵", fileStem: fileStem
        ) == nil)
    }

    @Test("Valid embedded titles and missing artists remain authoritative")
    func preservesValidTitles() {
        #expect(MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: "正确标签", artist: "刘思涵", fileStem: "文件名 - 刘思涵"
        ) == nil)
        #expect(MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: "刘思涵", artist: nil, fileStem: "文件名 - 刘思涵"
        ) == nil)
        #expect(MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: "  ANNE-MARIE ", artist: "Anne-Marie", fileStem: "2002 (Live) - Anne-Marie"
        ) == "2002 (Live)")
        #expect(MetadataTitleResolutionPolicy.titleCorrectingDuplicatedArtist(
            title: "刘思涵", artist: "刘思涵", fileStem: "走在冷风中 - Live - 刘思涵"
        ) == "走在冷风中 - Live")
    }

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
