import Testing
@testable import PrimuseKit

@Suite("Lyric writing direction")
struct LyricWritingDirectionPolicyTests {
    @Test("RTL language headers support common and regional BCP-47 tags")
    func rtlLanguageHeaders() {
        for tag in ["fa", "ar", "he", "ur", "FA-ir", "ar-EG", "HE-il", "ur_PK"] {
            #expect(LyricWritingDirectionPolicy.resolve(languageTag: tag) == .rightToLeft)
        }
    }

    @Test("Explicit script subtags override a language's usual direction")
    func explicitScriptOverridesDefault() {
        #expect(LyricWritingDirectionPolicy.resolve(languageTag: "az-Arab") == .rightToLeft)
        #expect(LyricWritingDirectionPolicy.resolve(languageTag: "fa-Latn") == .leftToRight)
    }

    @Test("Parser-preserved ELRC metadata drives the whole document")
    func parsedELRCMetadata() throws {
        let lines = LyricsContentParser.parse("""
        [ti:RTL sample]
        [LA: fa-IR]
        [00:01.000]<00:01.000>سلا<00:01.500>م<00:02.000>
        [00:03.000]<00:03.000>دنیا<00:04.000>
        """)

        #expect(lines.count == 2)
        #expect(lines[0].metadataLines?.contains("[LA: fa-IR]") == true)
        #expect(lines[1].metadataLines == nil)
        #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .rightToLeft)
        #expect(lines.map(\.text) == ["سلام", "دنیا"])
        #expect(lines.map(\.timestamp) == [1, 3])
        #expect(lines[0].syllables?.map(\.text) == ["سلا", "م"])
        #expect(lines[0].syllables?.map(\.start) == [1, 1.5])
        #expect(lines[0].syllables?.map(\.end) == [1.5, 2])
    }

    @Test("LTR headers remain LTR")
    func ltrLanguageHeaders() {
        #expect(
            LyricWritingDirectionPolicy.resolve(metadataLines: ["[la:en-US]"])
                == .leftToRight
        )
    }

    @Test("Missing, malformed, and unknown headers remain natural")
    func untrustedMetadataRemainsNatural() {
        #expect(LyricWritingDirectionPolicy.resolve(metadataLines: []) == .natural)
        #expect(LyricWritingDirectionPolicy.resolve(metadataLines: ["[ar:Artist]"]) == .natural)
        #expect(LyricWritingDirectionPolicy.resolve(metadataLines: ["[la:]"]) == .natural)
        #expect(LyricWritingDirectionPolicy.resolve(metadataLines: ["[la:zz]"]) == .natural)
        #expect(LyricWritingDirectionPolicy.resolve(metadataLines: ["[la:not_a_real_language]"]) == .natural)
        #expect(LyricWritingDirectionPolicy.resolve(languageTag: "-") == .natural)
    }

    @Test("Untagged mixed-script lyrics keep natural presentation")
    func mixedLyricsRemainNatural() {
        let lines = [
            LyricLine(timestamp: 1, text: "Hello سلام", isSynchronized: true),
            LyricLine(timestamp: 2, text: "مرحبا world", isSynchronized: true),
        ]

        #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .natural)
        #expect(lines.map(\.timestamp) == [1, 2])
    }
}

@Suite("Lyric flow placement")
struct LyricFlowPlacementPolicyTests {
    @Test("LTR and RTL coordinates mirror without reordering timed syllables")
    func mirroredCoordinatesPreserveTimelineOrder() {
        let sizes = [
            LyricFlowItemSize(width: 30, height: 10),
            LyricFlowItemSize(width: 40, height: 12),
            LyricFlowItemSize(width: 50, height: 8),
        ]
        let timestamps = [1.0, 1.5, 2.0]
        let ltr = LyricFlowPlacementPolicy.placements(
            itemSizes: sizes,
            containerWidth: 80,
            spacing: 10,
            isRightToLeft: false
        )
        let rtl = LyricFlowPlacementPolicy.placements(
            itemSizes: sizes,
            containerWidth: 80,
            spacing: 10,
            isRightToLeft: true
        )

        #expect(ltr.map(\.itemIndex) == [0, 1, 2])
        #expect(rtl.map(\.itemIndex) == [0, 1, 2])
        #expect(rtl.map { timestamps[$0.itemIndex] } == timestamps)
        #expect(ltr.map(\.x) == [0, 40, 0])
        #expect(rtl.map(\.x) == [50, 0, 30])
        #expect(ltr.map(\.y) == [0, 0, 12])
        #expect(rtl.map(\.y) == [0, 0, 12])

        for index in sizes.indices {
            #expect(rtl[index].x == 80 - ltr[index].x - sizes[index].width)
        }
    }
}
