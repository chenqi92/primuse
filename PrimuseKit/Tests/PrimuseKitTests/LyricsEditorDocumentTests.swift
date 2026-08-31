import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyrics editor document")
struct LyricsEditorDocumentTests {

    // MARK: - 解析

    @Test("Keeps unstamped lines that the playback parser drops")
    func keepsUnstampedLines() {
        let document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        我还站在原地等候
        [00:24.100]云层散去以后
        """)

        #expect(document.lines.count == 3)
        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.lines[1].timestamp == nil)
        #expect(document.lines[1].text == "我还站在原地等候")
        #expect(document.lines[2].timestamp == 24.1)
        #expect(document.unstampedCount == 1)
    }

    @Test("Preserves leading metadata headers")
    func preservesMetadata() {
        let document = LyricsEditorDocument(parsing: """
        [ti:那年夏天]
        [ar:某人]
        [00:12.300]晚风吹过温柔的午后
        """)

        #expect(document.metadataLines == ["[ti:那年夏天]", "[ar:某人]"])
        #expect(document.lines.count == 1)
        #expect(document.serialized().hasPrefix("[ti:那年夏天]\n[ar:某人]\n[00:12.300]"))
    }

    @Test("Malformed timestamps survive as editable text")
    func keepsMalformedTimestampText() {
        // 秒数字段写成字母 O 而不是 0 —— 丢掉这行会让用户以为歌词被吃了。
        let document = LyricsEditorDocument(parsing: "[00:6O.100]云层散去以后")

        #expect(document.lines.count == 1)
        #expect(document.lines[0].timestamp == nil)
        #expect(document.lines[0].text == "[00:6O.100]云层散去以后")
    }

    @Test("A line carrying several heads expands into separate lines")
    func expandsRepeatedHeads() {
        let document = LyricsEditorDocument(parsing: "[00:12.300][01:40.100]副歌")

        #expect(document.lines.count == 2)
        #expect(document.lines.map(\.text) == ["副歌", "副歌"])
        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.lines[1].timestamp == 100.1)
    }

    @Test("Text round-trips through serialization")
    func roundTripsText() {
        let source = """
        [ti:那年夏天]
        [00:12.300]晚风吹过温柔的午后
        还没打轴的一句
        [00:24.100]云层散去以后
        """

        #expect(LyricsEditorDocument(parsing: source).serialized() == source)
    }

    @Test("Adjacent same-timestamp bilingual rows become separate editable fields")
    func parsesBilingualRowsIntoManualTranslations() {
        let document = LyricsEditorDocument(parsing: """
        [00:12.300]The evening breeze is soft
        [00:12.300]晚风轻柔
        [00:24.100]The clouds drift away
        [00:24.100]云层散去
        """)

        #expect(document.lines.count == 2)
        #expect(document.lines.map(\.text) == [
            "The evening breeze is soft",
            "The clouds drift away",
        ])
        #expect(document.lines[0].manualTranslation?.text == "晚风轻柔")
        #expect(document.lines[1].manualTranslation?.text == "云层散去")
        #expect(document.lines[0].manualTranslation?.source == .bilingualLRC)
    }

    @Test("Bilingual parsing stays inside contiguous timed blocks")
    func bilingualPairingDoesNotCrossUnstampedLines() {
        let document = LyricsEditorDocument(parsing: """
        [00:12.300]The evening breeze is soft
        还没打轴的一句
        [00:12.300]晚风轻柔
        """)

        #expect(document.lines.count == 3)
        #expect(document.lines[0].manualTranslation == nil)
        #expect(document.lines[1].timestamp == nil)
        #expect(document.lines[2].manualTranslation == nil)
    }

    @Test("Structured input preserves same-script embedded translations")
    func structuredInputPreservesSameScriptTranslations() {
        let source = [
            LyricLine(
                timestamp: 12.3,
                text: "The evening breeze",
                isSynchronized: true,
                manualTranslation: LyricManualTranslation(
                    text: "La brise du soir",
                    languageCode: "fr",
                    source: .embeddedField
                )
            ),
            LyricLine(
                timestamp: 24.1,
                text: "The clouds drift away",
                isSynchronized: true,
                manualTranslation: LyricManualTranslation(
                    text: "Les nuages se dissipent",
                    languageCode: "fr",
                    source: .embeddedField
                )
            ),
        ]

        let document = LyricsEditorDocument(lyricLines: source)

        #expect(document.lines.count == 2)
        #expect(document.lines[0].manualTranslation?.text == "La brise du soir")
        #expect(document.lines[0].manualTranslation?.languageCode == "fr")
        #expect(document.lines[0].manualTranslation?.source == .embeddedField)
        #expect(document.hasCompleteManualTranslation)
    }

    @Test("Structured editing preserves TTML end times, voices, and background rows")
    func structuredInputPreservesTTMLStructure() {
        let background = LyricLine(
            timestamp: 12.8,
            text: "Backing vocal",
            isSynchronized: true,
            endTimestamp: 14.2,
            voice: .secondary
        )
        var document = LyricsEditorDocument(lyricLines: [
            LyricLine(
                timestamp: 12.3,
                text: "Lead vocal",
                isSynchronized: true,
                endTimestamp: 15.4,
                voice: .primary,
                background: [background]
            )
        ])

        #expect(document.lyricLines()[0].endTimestamp == 15.4)
        #expect(document.lyricLines()[0].voice == .primary)
        #expect(document.lyricLines()[0].background?.first?.voice == .secondary)

        document.shift(by: 2)
        let shifted = document.lyricLines()[0]
        #expect(shifted.timestamp == 14.3)
        #expect(shifted.endTimestamp == 17.4)
        #expect(shifted.background?.first?.timestamp == 14.8)
        #expect(shifted.background?.first?.endTimestamp == 16.2)
        #expect(!document.lines[0].canClearStamp)
        #expect(LyricsStructuredPersistencePolicy.requiresTTML(document.lyricLines()))
        #expect(!LyricsStructuredPersistencePolicy.requiresTTML([
            LyricLine(
                timestamp: 1,
                text: "Portable",
                syllables: [.init(text: "Portable", start: 1, end: 2)]
            ),
        ]))
        #expect(LyricsStructuredPersistencePolicy.requiresTTML([
            LyricLine(
                timestamp: 1,
                text: "A B",
                syllables: [
                    .init(text: "A ", start: 1, end: 1.2),
                    .init(text: "B", start: 2, end: 2.5),
                ]
            ),
        ]))
        let explicitBoundary = LyricsEditorDocument(lyricLines: [
            LyricLine(
                timestamp: 1,
                text: "A B",
                isSynchronized: true,
                syllables: [
                    .init(text: "A ", start: 1, end: 2, endTiming: .explicit),
                    .init(text: "B", start: 2, end: 3, endTiming: .inferred),
                ]
            ),
        ])
        #expect(LyricsStructuredPersistencePolicy.requiresTTML(explicitBoundary.lyricLines()))
        #expect(!explicitBoundary.permitsSourceTextEditing)
        #expect(LyricsStructuredPersistencePolicy.requiresTTML([
            LyricLine(
                timestamp: 1,
                text: "First visual line\nSecond visual line",
                isSynchronized: true
            ),
        ]))
    }

    @Test("Documents with translations refuse lossy source-text replacement")
    func structuredTranslationsDisableSourceEditing() {
        let preferred = LyricManualTranslation(
            text: "La brise du soir",
            languageCode: "fr",
            source: .embeddedField
        )
        let alternate = LyricManualTranslation(
            text: "Abendbrise",
            languageCode: "de",
            source: .embeddedField
        )
        let original = LyricsEditorDocument(lyricLines: [
            LyricLine(
                timestamp: 12.3,
                text: "The evening breeze",
                isSynchronized: true,
                manualTranslation: preferred,
                alternateManualTranslations: [alternate]
            )
        ])

        #expect(original.originalOnlySerialized() == "[00:12.300]The evening breeze")
        #expect(!original.permitsSourceTextEditing)
        let rejected = original.replacingOriginalSource(
            with: "[00:13.000]The gentle evening breeze"
        )
        #expect(rejected == original)
    }

    @Test("Plain LRC source editing remains available")
    func plainSourceEditingRemainsAvailable() {
        let document = LyricsEditorDocument(parsing: """
        [00:01.000]First
        [00:02.000]Second
        """)

        #expect(document.permitsSourceTextEditing)
        let reordered = document.replacingOriginalSource(with: """
        [00:02.000]Second
        [00:01.000]First
        """)

        #expect(reordered.lines.map(\.text) == ["Second", "First"])
        #expect(reordered.lines.allSatisfy { $0.manualTranslation == nil })
    }

    @Test("Pasting TTML into source mode keeps structured cues")
    func sourceModeParsesTTMLInsteadOfTreatingMarkupAsLyrics() throws {
        let original = LyricsEditorDocument(parsing: "[00:01.000]Old line")
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body><div><p begin="1s" end="2s">
            <span begin="1s" end="2s" xml:lang="fa">سلام</span>
          </p></div></body>
        </tt>
        """

        let replaced = original.replacingOriginalSource(with: ttml)
        let line = try #require(replaced.lyricLines().first)
        #expect(line.text == "سلام")
        #expect(line.endTimestamp == 2)
        #expect(line.syllables?.first?.languageCode == "fa")
        #expect(!replaced.serialized().contains("&lt;tt"))
    }

    @Test("Session identities do not count as lyric content changes")
    func ignoresSessionIdentitiesWhenComparingContent() {
        let first = LyricsEditorDocument(parsing: "[00:12.300]Same line")
        let second = LyricsEditorDocument(parsing: "[00:12.300]Same line")

        #expect(first.lines[0].id != second.lines[0].id)
        #expect(first.hasSameContent(as: second))
    }

    @Test("An unchanged edit preserves the original timestamp precision")
    func unchangedCommitPreservesOriginalText() {
        let source = "[00:12.30]Same line"
        let original = LyricsEditorDocument(parsing: source)
        let reopened = LyricsEditorDocument(parsing: source)

        #expect(reopened.serialized() == "[00:12.300]Same line")
        #expect(reopened.committedText(preserving: source, comparedTo: original) == source)
    }

    @Test("Word-level syllables round-trip")
    func roundTripsWordLevel() {
        let document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")

        #expect(document.lines.count == 1)
        #expect(document.lines[0].isWordLevel)
        #expect(document.lines[0].syllables?.count == 2)
        #expect(document.serialized() == "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
    }

    @Test("Serialized output stays parseable by the playback validator")
    func serializationFeedsPlaybackValidator() {
        var document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        [00:24.100]云层散去以后
        """)
        document.shift(by: 1.5)

        let validation = LyricsContentParser.validateEditableText(document.serialized())
        #expect(validation.isValid)
        #expect(validation.issues.isEmpty)
        #expect(validation.lines.map(\.timestamp) == [13.8, 25.6])
    }

    // MARK: - 整体偏移

    @Test("Shifting moves every stamped line and leaves the rest alone")
    func shiftsStampedLinesOnly() {
        var document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        还没打轴的一句
        [00:24.100]云层散去以后
        """)

        #expect(document.shift(by: 2) == 2)
        #expect(document.lines[0].timestamp == 14.3)
        #expect(document.lines[1].timestamp == nil)
        #expect(document.lines[2].timestamp == 26.1)
    }

    @Test("Unstamped structured timing still shifts as one unit")
    func shiftsUnstampedStructuredTiming() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(
                timestamp: nil,
                text: "Lead",
                endTimestamp: 4,
                background: [
                    LyricLine(
                        timestamp: 2,
                        text: "Backing",
                        isSynchronized: true,
                        endTimestamp: 3,
                        voice: .secondary
                    ),
                ]
            ),
        ])

        #expect(document.shift(by: 1) == 1)
        #expect(document.lines[0].timestamp == nil)
        #expect(document.lines[0].endTimestamp == 5)
        #expect(document.lines[0].background?.first?.timestamp == 3)
        #expect(document.lines[0].background?.first?.endTimestamp == 4)
    }

    @Test("Structured timing changes count as document edits")
    func structuredTimingParticipatesInContentComparison() {
        let original = LyricsEditorDocument(lines: [
            EditableLyricLine(
                timestamp: nil,
                text: "Lead",
                endTimestamp: 4,
                background: [
                    LyricLine(
                        timestamp: 2,
                        text: "Backing",
                        isSynchronized: true,
                        voice: .secondary
                    ),
                ]
            ),
        ])
        let shifted = original.shifted(by: 1)

        #expect(!shifted.hasSameContent(as: original))
        #expect(shifted.serialized() == original.serialized())
    }

    @Test("Stamping an unstamped structured row preserves relative timing")
    func stampsUnstampedStructuredTiming() {
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(
                timestamp: nil,
                text: "Lead",
                endTimestamp: 4,
                background: [
                    LyricLine(
                        timestamp: 2,
                        text: "Backing",
                        isSynchronized: true,
                        endTimestamp: 3,
                        voice: .secondary
                    ),
                ]
            ),
        ])

        document.stamp(at: 0, time: 10)
        #expect(document.lines[0].timestamp == 10)
        #expect(document.lines[0].background?.first?.timestamp == 10)
        #expect(document.lines[0].background?.first?.endTimestamp == 11)
        #expect(document.lines[0].endTimestamp == 12)
    }

    @Test("Backward shift clamps the whole document, never collapsing lines together")
    func backwardShiftPreservesSpacing() {
        var document = LyricsEditorDocument(parsing: """
        [00:00.500]第一句
        [00:01.000]第二句
        [00:02.000]第三句
        """)

        // 逐行 clamp 会得到 [0, 0, 1.0] —— 前两句挤在一起。整份 clamp 只把最早
        // 那句顶到 0,行距原样保留。
        #expect(document.shift(by: -1) == -0.5)
        #expect(document.lines.map(\.timestamp) == [0, 0.5, 1.5])
    }

    @Test("A clamped shift is fully reversible from the baseline")
    func clampedShiftIsReversibleFromBaseline() {
        let baseline = LyricsEditorDocument(parsing: """
        [00:00.500]第一句
        [00:01.000]第二句
        """)

        // UI 保留基线、每次从基线重算,所以拖到头再拖回来不会丢原始时间。
        let pushedToFloor = baseline.shifted(by: -30)
        #expect(pushedToFloor.lines.map(\.timestamp) == [0, 0.5])
        #expect(baseline.shifted(by: 0).lines.map(\.timestamp) == [0.5, 1.0])
    }

    @Test("Word-level syllables shift with their line")
    func shiftMovesSyllables() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
        document.shift(by: 1)

        #expect(document.lines[0].timestamp == 13.3)
        #expect(document.lines[0].syllables?.map(\.start) == [13.3, 14.1])
        #expect(document.lines[0].syllables?.last?.end == 15.0)
        #expect(document.lines[0].syllables?.map(\.endTiming) == [.inferred, .explicit])
    }

    @Test("Backward shift limit accounts for syllables ahead of their line head")
    func backwardLimitConsidersSyllables() {
        // 坏数据:首个音节比行头还早。下限必须按音节算,否则偏移后音节会变负。
        let document = LyricsEditorDocument(
            metadataLines: [],
            lines: [
                EditableLyricLine(
                    timestamp: 5,
                    text: "晚风",
                    syllables: [LyricSyllable(text: "晚风", start: 3, end: 6)]
                )
            ]
        )

        #expect(document.maximumBackwardShift == 3)
        #expect(document.shifted(by: -10).lines[0].syllables?.first?.start == 0)
    }

    // MARK: - 打轴

    @Test("Stamping records a time and keeps intra-line rhythm")
    func stampingShiftsSyllables() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
        document.stamp(at: 0, time: 20)

        #expect(document.lines[0].timestamp == 20)
        // 音节按 delta 平移,浮点上取不到精确的 20.8,比到毫秒即可。
        let starts = document.lines[0].syllables?.map(\.start) ?? []
        #expect(starts.count == 2)
        #expect(document.lines[0].syllables?.map(\.endTiming) == [.inferred, .explicit])
        #expect(abs(starts[0] - 20) < 0.001)
        #expect(abs(starts[1] - 20.8) < 0.001)
    }

    @Test("Stamping an unstamped line and clearing it again")
    func stampAndClear() {
        var document = LyricsEditorDocument(parsing: "还没打轴的一句")

        document.stamp(at: 0, time: 9.25)
        #expect(document.lines[0].timestamp == 9.25)
        #expect(document.nextUnstampedIndex == nil)

        document.clearStamp(at: 0)
        #expect(document.lines[0].timestamp == nil)
        #expect(document.nextUnstampedIndex == 0)
    }

    @Test("Editing text drops stale syllable data")
    func editingTextDropsSyllables() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]<00:12.300>晚风<00:13.100>吹过<00:14.000>")
        document.updateText("晚风吹过温柔的午后", at: 0)

        #expect(document.lines[0].syllables == nil)
        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.serialized() == "[00:12.300]晚风吹过温柔的午后")
    }

    @Test("Editing a translation preserves the original timeline and source provenance")
    func editingTranslationPreservesTimelineAndProvenance() {
        let translation = LyricManualTranslation(
            id: "manual-translation",
            text: "The evening breeze",
            languageCode: "en",
            source: .embeddedField
        )
        let alternate = LyricManualTranslation(
            id: "alternate-translation",
            text: "La brise du soir",
            languageCode: "fr",
            source: .embeddedField
        )
        var document = LyricsEditorDocument(lines: [
            EditableLyricLine(
                timestamp: 12.3,
                text: "晚风吹过",
                syllables: [
                    LyricSyllable(text: "晚风", start: 12.3, end: 13.1),
                    LyricSyllable(text: "吹过", start: 13.1, end: 14.0),
                ],
                manualTranslation: translation,
                alternateManualTranslations: [alternate]
            )
        ])

        document.updateManualTranslation("The soft evening breeze", at: 0)
        document.clearStamp(at: 0)

        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.lines[0].syllables?.map(\.start) == [12.3, 13.1])
        #expect(document.lines[0].manualTranslation?.id == "manual-translation")
        #expect(document.lines[0].manualTranslation?.languageCode == "en")
        #expect(document.lines[0].manualTranslation?.source == .embeddedField)
        #expect(document.lines[0].manualTranslation?.text == "The soft evening breeze")
        #expect(document.lines[0].alternateManualTranslations == [alternate])
        #expect(document.lyricLines()[0].alternateManualTranslations == [alternate])
        #expect(document.hasCompleteManualTranslation)
    }

    @Test("A newly authored translation serializes as same-timestamp bilingual LRC")
    func serializesNewTranslationAsBilingualLRC() {
        var document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过
        [00:24.100]云层散去
        """)
        document.updateManualTranslation("The evening breeze", at: 0)
        document.updateManualTranslation("The clouds drift away", at: 1)

        #expect(document.lines[0].manualTranslation?.source == .bilingualLRC)
        #expect(document.serialized() == """
        [00:12.300]晚风吹过
        [00:12.300]The evening breeze
        [00:24.100]云层散去
        [00:24.100]The clouds drift away
        """)

        let validation = LyricsContentParser.validateEditableText(document.serialized())
        #expect(validation.isValid)
        #expect(validation.lines.count == 2)
        #expect(validation.lines[0].manualTranslation?.text == "The evening breeze")
        #expect(validation.lines[1].manualTranslation?.text == "The clouds drift away")
        #expect(document.hasCompleteManualTranslation)
    }

    @Test("Clearing a translation leaves the original lyric untouched")
    func clearsTranslationOnly() {
        var document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过
        [00:12.300]The evening breeze
        [00:24.100]云层散去
        [00:24.100]The clouds drift away
        [00:36.500]星光落下
        [00:36.500]The starlight falls
        """)

        document.updateManualTranslation("   ", at: 0)

        #expect(document.lines[0].text == "晚风吹过")
        #expect(document.lines[0].timestamp == 12.3)
        #expect(document.lines[0].manualTranslation == nil)
        #expect(document.serialized() == """
        [00:12.300]晚风吹过
        [00:24.100]云层散去
        [00:24.100]The clouds drift away
        [00:36.500]星光落下
        [00:36.500]The starlight falls
        """)
        #expect(!document.hasCompleteManualTranslation)

        let validation = LyricsContentParser.validateEditableText(document.serialized())
        #expect(validation.lines.count == 3)
        #expect(validation.lines[0].manualTranslation == nil)
        #expect(validation.lines[1].manualTranslation?.text == "The clouds drift away")
        #expect(validation.lines[2].manualTranslation?.text == "The starlight falls")
    }

    @Test("Unstamped rows reject translations that cannot round-trip as bilingual LRC")
    func unstampedRowsRejectManualTranslations() {
        var document = LyricsEditorDocument(parsing: "还没打轴的一句")
        document.updateManualTranslation("An unstamped line", at: 0)

        #expect(document.lines[0].manualTranslation == nil)
        #expect(document.serialized() == "还没打轴的一句")
    }

    @Test("Word-level rows reject new bilingual-LRC translations")
    func wordLevelRowsRejectPortableTranslations() {
        var document = LyricsEditorDocument(
            parsing: "[00:01.000]<00:01.000>晚<00:02.000>风<00:03.000>"
        )

        document.updateManualTranslation("Evening breeze", at: 0)

        #expect(document.lines[0].manualTranslation == nil)
    }

    @Test("Local structured storage can author translations for unstamped rows")
    func localStructuredRowsCanAuthorTranslations() {
        var document = LyricsEditorDocument(parsing: "还没打轴的一句")

        document.updateManualTranslation(
            "An unstamped line",
            at: 0,
            allowsStructuredOnly: true
        )

        #expect(document.lines[0].manualTranslation?.text == "An unstamped line")
        #expect(document.lines[0].manualTranslation?.source == .localEditor)
    }

    @Test("Local structured storage marks even portable rows as local edits")
    func localStructuredTimedRowsKeepLocalProvenance() {
        var document = LyricsEditorDocument(parsing: "[00:01.000]A timed line")

        document.updateManualTranslation(
            "A local translation",
            at: 0,
            allowsStructuredOnly: true
        )

        #expect(document.lines[0].manualTranslation?.source == .localEditor)
    }

    @Test("Editing an existing source translation locally promotes its provenance")
    func localStructuredEditPromotesExistingTranslation() {
        var document = LyricsEditorDocument(lyricLines: [
            LyricLine(
                timestamp: 1,
                text: "Original",
                isSynchronized: true,
                manualTranslation: .init(
                    text: "Source translation",
                    source: .bilingualLRC
                )
            ),
        ])

        document.updateManualTranslation(
            "Locally edited translation",
            at: 0,
            allowsStructuredOnly: true
        )

        #expect(document.lines[0].manualTranslation?.text == "Locally edited translation")
        #expect(document.lines[0].manualTranslation?.source == .localEditor)
    }

    @Test("An existing structured plain-text translation remains editable")
    func editsExistingUnstampedTranslation() {
        var document = LyricsEditorDocument(lyricLines: [
            LyricLine(
                timestamp: 0,
                text: "The evening breeze",
                isSynchronized: false,
                manualTranslation: LyricManualTranslation(
                    text: "La brise du soir",
                    languageCode: "fr",
                    source: .embeddedField
                )
            )
        ])

        document.updateManualTranslation("La douce brise du soir", at: 0)

        #expect(document.lines[0].timestamp == nil)
        #expect(document.lines[0].manualTranslation?.text == "La douce brise du soir")
        #expect(document.lines[0].manualTranslation?.source == .embeddedField)
        #expect(document.hasCompleteManualTranslation)
    }

    @Test("Stamping one syllable shifts the remaining word-level timeline")
    func stampingSyllableShiftsSuffix() {
        var document = LyricsEditorDocument(
            parsing: "[00:01.000]<00:01.000>晚<00:02.000>风<00:03.000>来<00:04.000>"
        )

        let applied = document.stampSyllable(at: 0, syllableIndex: 1, time: 2.5)
        let syllables = document.lines[0].syllables ?? []

        #expect(applied == 2.5)
        #expect(syllables.map(\.start) == [1, 2.5, 3.5])
        #expect(syllables.map(\.end) == [2.5, 3.5, 4.5])
        #expect(document.lines[0].timestamp == 1)
        #expect(LyricsContentParser.validateEditableText(document.serialized()).isValid)
    }

    @Test("Syllable fine tuning moves only one boundary and clamps to neighbors")
    func nudgingSyllableMovesBoundary() {
        var document = LyricsEditorDocument(
            parsing: "[00:01.000]<00:01.000>晚<00:02.000>风<00:03.000>来<00:04.000>"
        )

        #expect(document.nudgeSyllable(at: 0, syllableIndex: 1, by: 0.2) == 2.2)
        #expect(document.lines[0].syllables?.map(\.start) == [1, 2.2, 3])
        #expect(document.lines[0].syllables?.map(\.end) == [2.2, 3, 4])

        #expect(document.nudgeSyllable(at: 0, syllableIndex: 1, by: 10) == 3)
        #expect(document.lines[0].syllables?.map(\.start) == [1, 3, 3])
        #expect(LyricsContentParser.validateEditableText(document.serialized()).isValid)
    }

    @Test("Explicit word ends survive suffix stamps and fine tuning")
    func explicitWordEndsSurviveTimingEdits() {
        let line = LyricLine(
            timestamp: 1,
            text: "A B",
            isSynchronized: true,
            syllables: [
                .init(text: "A ", start: 1, end: 1.4, endTiming: .explicit),
                .init(text: "B", start: 2, end: 2.6, endTiming: .explicit),
            ],
            endTimestamp: 3
        )
        var stamped = LyricsEditorDocument(lyricLines: [line])

        #expect(stamped.stampSyllable(at: 0, syllableIndex: 1, time: 2.2) == 2.2)
        #expect(stamped.lines[0].timestamp == 1)
        #expect(stamped.lines[0].syllables?[0].end == 1.4)
        #expect(stamped.lines[0].syllables?[0].endTiming == .explicit)
        #expect(abs((stamped.lines[0].endTimestamp ?? 0) - 3.2) < 0.001)

        var nudged = LyricsEditorDocument(lyricLines: [line])
        #expect(nudged.nudgeSyllable(at: 0, syllableIndex: 1, by: 10) == 2.6)
        #expect(nudged.lines[0].timestamp == 1)
        #expect(nudged.lines[0].syllables?[0].end == 1.4)
        #expect(nudged.lines[0].syllables?[1].end == 2.6)
        #expect(nudged.lines[0].syllables?[1].endTiming == .explicit)
    }

    // MARK: - 顺序

    @Test("Out-of-order stamps are detected and can be sorted")
    func detectsAndFixesOutOfOrder() {
        var document = LyricsEditorDocument(parsing: """
        [00:24.100]云层散去以后
        [00:12.300]晚风吹过温柔的午后
        """)

        #expect(!document.isMonotonic)
        document.sortByTimestamp()
        #expect(document.isMonotonic)
        #expect(document.lines.map(\.text) == ["晚风吹过温柔的午后", "云层散去以后"])
    }

    @Test("Sorting keeps unstamped lines in their slots")
    func sortingKeepsUnstampedSlots() {
        var document = LyricsEditorDocument(parsing: """
        [00:24.100]云层散去以后
        还没打轴的一句
        [00:12.300]晚风吹过温柔的午后
        """)
        document.sortByTimestamp()

        // 未打轴的行没有可比的时间,留在原位;已打轴的行在自己的槽位里重排。
        #expect(document.lines.map(\.text) == [
            "晚风吹过温柔的午后",
            "还没打轴的一句",
            "云层散去以后",
        ])
        #expect(document.lines[1].timestamp == nil)
    }

    @Test("Timing commit repairs ordering caused by skipped scraped information lines")
    func timingCommitRepairsSkippedInformationLines() {
        let document = LyricsEditorDocument(parsing: """
        [00:12.000]愿得一人心 - 李行亮
        [00:02.000]只愿得一人心
        [00:14.000]作词：胡小健
        [00:04.000]白首不分离
        """)

        let prepared = document.preparedForTimingCommit(eligibleIndices: [1, 3])
        let validation = LyricsContentParser.validateEditableText(prepared.serialized())

        #expect(!document.isMonotonic)
        #expect(prepared.isMonotonic)
        #expect(prepared.lines.map(\.text) == [
            "只愿得一人心",
            "白首不分离",
            "愿得一人心 - 李行亮",
            "作词：胡小健",
        ])
        #expect(validation.isValid)
        #expect(validation.lines.count == 4)
    }

    @Test("Timing commit repairs the 82 of 82 timing workflow with two skipped information lines")
    func timingCommitRepairsEightyTwoTimedLines() {
        var lines = (0..<84).map { index in
            EditableLyricLine(
                timestamp: TimeInterval(index + 1),
                text: "第\(index + 1)行"
            )
        }
        lines[0] = EditableLyricLine(timestamp: 70, text: "愿得一人心 - 李行亮")
        lines[43] = EditableLyricLine(timestamp: 10, text: "作词：胡小健")
        let eligibleIndices = lines.indices.filter { $0 != 0 && $0 != 43 }
        for (offset, index) in eligibleIndices.enumerated() {
            lines[index].timestamp = TimeInterval(offset + 1)
        }
        let document = LyricsEditorDocument(lines: lines)

        let prepared = document.preparedForTimingCommit(eligibleIndices: eligibleIndices)
        let validation = LyricsContentParser.validateEditableText(prepared.serialized())

        #expect(eligibleIndices.count == 82)
        #expect(!document.isMonotonic)
        #expect(prepared.isMonotonic)
        #expect(validation.isValid)
        #expect(validation.lines.count == 84)
        #expect(Set(prepared.lines.map(\.text)) == Set(document.lines.map(\.text)))
    }

    @Test("Timing commit does not hide an ordering mistake in lyric lines")
    func timingCommitKeepsLyricOrderingMistakesVisible() {
        let document = LyricsEditorDocument(parsing: """
        [00:01.000]愿得一人心 - 李行亮
        [00:12.000]只愿得一人心
        [00:04.000]白首不分离
        """)

        let prepared = document.preparedForTimingCommit(eligibleIndices: [1, 2])

        #expect(prepared == document)
        #expect(!prepared.isMonotonic)
        #expect(!LyricsContentParser.validateEditableText(prepared.serialized()).isValid)
    }

    @Test("Timing commit keeps a valid scraped timeline unchanged")
    func timingCommitKeepsValidTimeline() {
        let document = LyricsEditorDocument(parsing: """
        [00:01.000]愿得一人心 - 李行亮
        [00:12.000]只愿得一人心
        [00:14.000]作词：胡小健
        [00:18.000]白首不分离
        """)

        #expect(document.preparedForTimingCommit(eligibleIndices: [1, 3]) == document)
    }

    // MARK: - 高亮

    @Test("Active line tracks playback time")
    func tracksActiveLine() {
        let document = LyricsEditorDocument(parsing: """
        [00:12.300]晚风吹过温柔的午后
        还没打轴的一句
        [00:24.100]云层散去以后
        """)

        #expect(document.activeLineIndex(at: 0) == nil)
        #expect(document.activeLineIndex(at: 12.3) == 0)
        #expect(document.activeLineIndex(at: 20) == 0)
        #expect(document.activeLineIndex(at: 30) == 2)
    }

    @Test("Active line follows time rather than document order")
    func tracksActiveLineInOutOfOrderDocument() {
        let document = LyricsEditorDocument(parsing: """
        [00:44.690]Future line placed first
        [00:25.920]Current line placed later
        [00:32.260]Next line
        """)

        #expect(document.activeLineIndex(at: 30) == 1)
        #expect(document.activeLineIndex(at: 40) == 2)
        #expect(document.activeLineIndex(at: 50) == 0)
    }

    @Test("Insertion and removal keep stable identities")
    func insertAndRemove() {
        var document = LyricsEditorDocument(parsing: "[00:12.300]晚风吹过温柔的午后")
        let originalID = document.lines[0].id

        let newID = document.insertLine(at: 1, text: "新的一句")
        #expect(document.lines.count == 2)
        #expect(document.lines[1].id == newID)
        #expect(document.lines[0].id == originalID)

        document.removeLines(at: IndexSet(integer: 0))
        #expect(document.lines.map(\.id) == [newID])
    }

    @Test("Removing several lines at once drops exactly those lines")
    func removesMultipleLines() {
        var document = LyricsEditorDocument(parsing: """
        第一句
        第二句
        第三句
        第四句
        """)
        document.removeLines(at: IndexSet([0, 2]))

        #expect(document.lines.map(\.text) == ["第二句", "第四句"])
    }

    @Test("Moving down uses pre-removal destination indices, like SwiftUI")
    func movesLineDown() {
        var document = LyricsEditorDocument(parsing: """
        第一句
        第二句
        第三句
        """)
        // SwiftUI 的 onMove 语义:destination 用移除之前的下标表达。
        // 把第 0 行拖到下标 2 => 它落在原第二句之后。
        document.moveLines(from: IndexSet(integer: 0), to: 2)

        #expect(document.lines.map(\.text) == ["第二句", "第一句", "第三句"])
    }

    @Test("Moving up places the line before the destination")
    func movesLineUp() {
        var document = LyricsEditorDocument(parsing: """
        第一句
        第二句
        第三句
        """)
        document.moveLines(from: IndexSet(integer: 2), to: 0)

        #expect(document.lines.map(\.text) == ["第三句", "第一句", "第二句"])
    }
}
