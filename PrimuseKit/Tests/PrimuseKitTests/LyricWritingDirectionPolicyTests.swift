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

    @Test("Untagged Persian ELRC keeps centisecond carry sequential")
    func untaggedPersianELRCCentisecondCarryIsSequential() throws {
        let lines = LyricsContentParser.parse("""
        [00:26.54]<00:26.54>انتظار <00:27.06>و <00:27.60>انتظار <00:28.36>(تا <00:28.44>وقتی <00:28.92>بازی <00:28.100>شروع <00:29.16>نشده)
        [00:41.26]<00:41.26>من <00:41.68>لَش <00:42.10>هَمَش <00:42.84>رو <00:42.100>کاناپه <00:43.88>یا <00:44.24>تخت
        """)

        #expect(lines.count == 2)
        #expect(lines[0].metadataLines == nil)
        #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .rightToLeft)
        #expect(lines[0].syllables?.map(\.text) == [
            "انتظار ", "و ", "انتظار ", "(تا ", "وقتی ", "بازی ", "شروع ", "نشده)",
        ])
        #expect(lines[0].syllables?.map(\.start) == [
            26.54, 27.06, 27.60, 28.36, 28.44, 28.92, 29.00, 29.16,
        ])
        #expect(lines[1].syllables?.map(\.start) == [
            41.26, 41.68, 42.10, 42.84, 43.00, 43.88, 44.24,
        ])
        for line in lines {
            let starts = line.syllables?.map(\.start) ?? []
            #expect(zip(starts, starts.dropFirst()).allSatisfy { pair in
                pair.0 <= pair.1
            })
        }
    }

    @Test("Standard millisecond ELRC keeps three-digit fractions")
    func standardMillisecondELRCRemainsUnchanged() throws {
        let line = try #require(LyricsContentParser.parse(
            "[00:00.000]<00:00.090>مر<00:00.100>حبا"
        ).first)

        #expect(line.syllables?.map(\.start) == [0.09, 0.1])
        #expect(line.text == "مرحبا")
    }

    @Test("Tagged Arabic ELRC preserves mixed Latin tokens")
    func taggedArabicELRCPreservesMixedTokens() throws {
        let lines = LyricsContentParser.parse("""
        [la:ar-EG]
        [00:01.000]<00:01.000>مرحبا <00:01.500>Primuse <00:02.000>بالعالم
        """)

        let line = try #require(lines.first)
        #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .rightToLeft)
        #expect(line.text == "مرحبا Primuse بالعالم")
        #expect(line.syllables?.map(\.text) == ["مرحبا ", "Primuse ", "بالعالم"])
        #expect(line.syllables?.map(\.start) == [1, 1.5, 2])
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

    @Test("Untagged lyrics infer common RTL scripts from their text")
    func untaggedRightToLeftScripts() {
        let samples = [
            "این یک ترانه فارسی است", // Persian / Arabic script
            "זהו שיר בעברית", // Hebrew
            "ܗܢܐ ܙܡܪܐ ܣܘܪܝܝܐ", // Syriac
            "މިއީ ދިވެހި ލަވައެކެވެ", // Dhivehi / Thaana
            "ߒߞߏ ߘߐ߫ ߞߊ߬ߟߊ߲", // NKo
            "𞤀𞤁𞤂𞤃", // Adlam
            "𐴀𐴁𐴂𐴃", // Hanifi Rohingya
        ]

        for text in samples {
            let lines = [LyricLine(timestamp: 0, text: text, isSynchronized: false)]
            #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .rightToLeft)
        }
    }

    @Test("Numbers, punctuation, and a short Latin title do not hide RTL lyrics")
    func neutralAndEmbeddedTextDoNotHideRightToLeftLyrics() {
        let lines = [
            LyricLine(timestamp: 0, text: "Soghati 2026", isSynchronized: false),
            LyricLine(timestamp: 1, text: "وقتی میای صدای پات", isSynchronized: true),
            LyricLine(timestamp: 2, text: "از همه جاده ها میاد", isSynchronized: true),
        ]

        #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .rightToLeft)
    }

    @Test("An explicit valid language header overrides content inference")
    func metadataOverridesContentInference() {
        let lines = [
            LyricLine(
                timestamp: 0,
                text: "این متن با جهت صریح نمایش داده می شود",
                isSynchronized: false,
                metadataLines: ["[la:fa-Latn]"]
            )
        ]

        #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .leftToRight)
    }

    @Test("A small embedded RTL phrase does not flip an LTR document")
    func incidentalRightToLeftTextRemainsNatural() {
        let lines = [
            LyricLine(timestamp: 0, text: "Hello world سلام", isSynchronized: false),
            LyricLine(timestamp: 1, text: "This remains an English song", isSynchronized: true),
        ]

        #expect(LyricWritingDirectionPolicy.resolve(in: lines) == .natural)
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

    @Test("Wrapped lines honor centered and trailing alignment")
    func wrappedLineAlignment() {
        let sizes = [
            LyricFlowItemSize(width: 30, height: 10),
            LyricFlowItemSize(width: 40, height: 12),
            LyricFlowItemSize(width: 50, height: 8),
        ]

        let centered = LyricFlowPlacementPolicy.placements(
            itemSizes: sizes,
            containerWidth: 80,
            spacing: 10,
            isRightToLeft: false,
            alignment: .center
        )
        let trailing = LyricFlowPlacementPolicy.placements(
            itemSizes: sizes,
            containerWidth: 80,
            spacing: 10,
            isRightToLeft: false,
            alignment: .trailing
        )
        let rtlTrailing = LyricFlowPlacementPolicy.placements(
            itemSizes: sizes,
            containerWidth: 80,
            spacing: 10,
            isRightToLeft: true,
            alignment: .trailing
        )

        #expect(centered.map(\.x) == [0, 40, 15])
        #expect(trailing.map(\.x) == [0, 40, 30])
        #expect(rtlTrailing.map(\.x) == [50, 0, 0])
    }

    @Test("Wrapped RTL rows keep logical syllable order")
    func wrappedRightToLeftRowsKeepLogicalOrder() {
        let placements = LyricFlowPlacementPolicy.placements(
            itemSizes: [
                .init(width: 34, height: 10),
                .init(width: 28, height: 12),
                .init(width: 42, height: 9),
                .init(width: 30, height: 11),
                .init(width: 36, height: 10),
            ],
            containerWidth: 72,
            isRightToLeft: true
        )

        #expect(placements.map(\.itemIndex) == [0, 1, 2, 3, 4])
        #expect(placements.map(\.y) == [0, 0, 12, 12, 23])
        #expect(placements[0].x > placements[1].x)
        #expect(placements[2].x > placements[3].x)
        #expect(placements[4].x == 36)
    }
}
