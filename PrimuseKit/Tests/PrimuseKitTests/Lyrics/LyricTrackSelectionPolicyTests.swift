import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric group voice & multi-track selection")
struct LyricTrackSelectionPolicyTests {
    // MARK: - Chorus / Group Voice (`type="group"` / `v1000`)

    @Test("TTML parses <ttm:agent type=\"group\"> and v1000 into .group voice and centers layout")
    func parsesGroupAgentAndCentersInDuetAndSolo() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
          <head>
            <metadata>
              <ttm:agent type="person" xml:id="v1"/>
              <ttm:agent type="person" xml:id="v2"/>
              <ttm:agent type="group" xml:id="v1000"/>
              <ttm:agent type="group" xml:id="chorus"/>
            </metadata>
          </head>
          <body>
            <div>
              <p begin="00:00:01.000" end="00:00:03.000" ttm:agent="v1">Lead singer</p>
              <p begin="00:00:03.000" end="00:00:05.000" ttm:agent="v2">Partner singer</p>
              <p begin="00:00:05.000" end="00:00:08.000" ttm:agent="v1000">Everyone together</p>
              <p begin="00:00:08.000" end="00:00:10.000" ttm:agent="chorus">Named group chorus</p>
              <p begin="00:00:10.000" end="00:00:12.000" ttm:agent="v1 v2">Multi-agent unison</p>
            </div>
          </body>
        </tt>
        """

        let lines = LyricsContentParser.parseText(ttml)
        #expect(lines.map(\.voice) == [.primary, .secondary, .group, .group, .group])
        #expect(KaraokeDuetGatePolicy.hasDuetParts(lines))

        // In duet mode: primary leading, secondary trailing, group centered.
        #expect(LyricDuetLayoutPolicy.side(for: .primary, preferred: .leading, isDuet: true) == .leading)
        #expect(LyricDuetLayoutPolicy.side(for: .secondary, preferred: .leading, isDuet: true) == .trailing)
        #expect(LyricDuetLayoutPolicy.side(for: .group, preferred: .leading, isDuet: true) == .center)
        #expect(LyricDuetLayoutPolicy.side(for: .group, preferred: .trailing, isDuet: true) == .center)
        // Even in non-duet songs (solo + chorus), group lines stay centered.
        #expect(LyricDuetLayoutPolicy.side(for: .group, preferred: .leading, isDuet: false) == .center)

        // Karaoke duet parts both sing group chorus lines.
        #expect(KaraokePart.primary.includes(.group))
        #expect(KaraokePart.secondary.includes(.group))
        #expect(KaraokePart.all.includes(.group))
    }

    @Test("TTML recognizes v1000 as .group even without <ttm:agent> metadata and round-trips v1000")
    func recognizesImplicitV1000AndRoundTripsTTML() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
              <p begin="00:00:01.000" end="00:00:03.000" ttm:agent="v1000">Opening chorus</p>
              <p begin="00:00:03.000" end="00:00:05.000" ttm:agent="singerA">Verse one</p>
              <p begin="00:00:05.000" end="00:00:07.000" ttm:agent="singerB">Verse two</p>
            </div>
          </body>
        </tt>
        """

        let lines = LyricsContentParser.parseText(ttml)
        #expect(lines.map(\.voice) == [.group, .primary, .secondary])

        let serialized = LyricsContentParser.serializeTTML(lines)
        #expect(serialized.contains(#"<ttm:agent xml:id="v1000" type="group"/>"#))
        #expect(serialized.contains(#"ttm:agent="v1000""#))
        #expect(serialized.contains(#"<ttm:agent xml:id="v2" type="person"/>"#))

        let reparsed = LyricsContentParser.parseText(serialized)
        #expect(reparsed.map(\.voice) == [.group, .primary, .secondary])
        #expect(LyricsContentParser.areSemanticallyEquivalent(lines, reparsed))
    }

    @Test("LyricLine Codable round-trips .group, replacement kind, and legacy JSON without kind")
    func codableBackwardCompatibility() throws {
        let original = LyricLine(
            id: "l1",
            timestamp: 1.0,
            text: "繁體歌詞",
            voice: .group,
            manualTranslation: LyricManualTranslation(
                id: "sub1",
                text: "Traditional lyrics",
                languageCode: "en-US",
                source: .embeddedField,
                kind: .subtitle
            ),
            alternateManualTranslations: [
                LyricManualTranslation(
                    id: "rep1",
                    text: "简体歌词",
                    languageCode: "zh-Hans",
                    source: .embeddedField,
                    syllables: [LyricSyllable(text: "简体", start: 1.0, end: 1.5), LyricSyllable(text: "歌词", start: 1.5, end: 2.0)],
                    kind: .replacement
                ),
            ],
            romanization: "fan ti ge ci",
            romanizationLanguageCode: "zh-Latn",
            alternateRomanizations: [
                LyricTransliteration(id: "rom2", text: "faan4 tai2 go1 ci4", languageCode: "yue-Latn")
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LyricLine.self, from: data)
        #expect(decoded.voice == .group)
        #expect(decoded.manualTranslation?.kind == .subtitle)
        #expect(decoded.replacementTracks.count == 1)
        #expect(decoded.replacementTracks.first?.kind == .replacement)
        #expect(decoded.replacementTracks.first?.syllables?.map(\.text) == ["简体", "歌词"])
        #expect(decoded.romanizationLanguageCode == "zh-Latn")
        #expect(decoded.alternateRomanizations.map(\.languageCode) == ["yue-Latn"])

        // Legacy JSON omitting `kind`, `romanizationLanguageCode`, and `alternateRomanizations`
        let legacyJSON = #"""
        {
          "id": "legacy-1",
          "timestamp": 2.0,
          "text": "Hello",
          "manualTranslation": {
            "id": "t1",
            "text": "你好",
            "languageCode": "zh-Hans",
            "source": "embeddedField"
          }
        }
        """#
        let legacy = try JSONDecoder().decode(LyricLine.self, from: Data(legacyJSON.utf8))
        #expect(legacy.voice == .primary)
        #expect(legacy.manualTranslation?.kind == .subtitle)
        #expect(legacy.replacementTracks.isEmpty)
        #expect(legacy.alternateRomanizations.isEmpty)
    }

    // MARK: - Replacement, Multi-Language Subtitles, and Multi-Transliteration TTML

    private let multiTrackTTML = """
    <tt xmlns="http://www.w3.org/ns/ttml"
        xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
        xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
        xml:lang="zh-Hant">
      <head>
        <metadata>
          <ttm:agent type="person" xml:id="v1"/>
          <ttm:agent type="group" xml:id="v1000"/>
          <itunes:iTunesMetadata>
            <itunes:translations>
              <itunes:translation type="replacement" xml:lang="zh-Hans">
                <itunes:text for="L1">
                  <span begin="1.000" end="1.500">你好</span><span begin="1.500" end="2.200">世界</span>
                  <span ttm:role="x-bg" begin="1.600" end="2.100"><span begin="1.600" end="2.100">回声</span></span>
                </itunes:text>
                <itunes:text for="L2">合唱时间</itunes:text>
              </itunes:translation>
              <itunes:translation type="subtitle" xml:lang="en-US">
                <itunes:text for="L1"><span begin="1.000" end="1.500">Hello </span><span begin="1.500" end="2.200">world</span></itunes:text>
                <itunes:text for="L2">Chorus time</itunes:text>
              </itunes:translation>
              <itunes:translation type="subtitle" xml:lang="ja-JP">
                <itunes:text for="L1"><span begin="1.000" end="2.200">こんにちは世界</span></itunes:text>
                <itunes:text for="L2">合唱の時間</itunes:text>
              </itunes:translation>
            </itunes:translations>
            <itunes:transliterations>
              <itunes:transliteration xml:lang="zh-Latn">
                <itunes:text for="L1"><span begin="1.000" end="1.500">nǐ hǎo </span><span begin="1.500" end="2.200">shì jiè</span></itunes:text>
                <itunes:text for="L2">hé chàng shí jiān</itunes:text>
              </itunes:transliteration>
              <itunes:transliteration xml:lang="yue-Latn">
                <itunes:text for="L1">nei5 hou2 sai3 gaai3</itunes:text>
                <itunes:text for="L2">hap6 coeng3 si4 gaan3</itunes:text>
              </itunes:transliteration>
            </itunes:transliterations>
          </itunes:iTunesMetadata>
        </metadata>
      </head>
      <body>
        <div>
          <p itunes:key="L1" begin="1.000" end="2.200" ttm:agent="v1">
            <span begin="1.000" end="1.500">妳好</span><span begin="1.500" end="2.200">世界</span>
            <span ttm:role="x-bg" begin="1.600" end="2.100"><span begin="1.600" end="2.100">回聲</span></span>
          </p>
          <p itunes:key="L2" begin="3.000" end="5.000" ttm:agent="v1000">合唱時間</p>
        </div>
      </body>
    </tt>
    """

    @Test("Parses replacement, multiple subtitle tracks, and multiple transliterations, and round-trips TTML")
    func parsesAndRoundTripsMultiTrackTTML() throws {
        let lines = LyricsContentParser.parseText(multiTrackTTML)
        #expect(lines.count == 2)
        #expect(lines.map(\.voice) == [.primary, .group])

        let first = try #require(lines.first)
        // manualTranslation stays reserved for subtitle tracks, never replacement.
        #expect(first.manualTranslation?.kind == .subtitle)
        #expect(first.manualTranslation?.languageCode == "en-US")
        #expect(first.subtitleTranslations.map(\.languageCode) == ["en-US", "ja-JP"])
        #expect(first.replacementTracks.map(\.languageCode) == ["zh-Hans"])
        #expect(first.replacementTracks.first?.text == "你好世界")
        #expect(first.replacementTracks.first?.syllables?.map(\.text) == ["你好", "世界"])
        #expect(first.background?.first?.replacementTracks.first?.text == "回声")
        #expect(first.romanization == "nǐ hǎo shì jiè")
        #expect(first.romanizationLanguageCode == "zh-Latn")
        #expect(first.alternateRomanizations.map(\.languageCode) == ["yue-Latn"])

        // Export to TTML preserves v1000, type="replacement", xml:lang, and word-level syllables.
        let exported = LyricsContentParser.serializeTTML(lines)
        #expect(exported.contains(#"<ttm:agent xml:id="v1000" type="group"/>"#))
        #expect(exported.contains(#"type="replacement" xml:lang="zh-Hans""#))
        #expect(exported.contains(#"ttm:role="x-translation" xml:lang="en-US""#))
        #expect(exported.contains(#"ttm:role="x-translation" xml:lang="ja-JP""#))
        #expect(exported.contains(#"ttm:role="x-roman" xml:lang="zh-Latn""#))
        #expect(exported.contains(#"ttm:role="x-roman" xml:lang="yue-Latn""#))

        let reparsed = LyricsContentParser.parseText(exported)
        #expect(LyricsContentParser.areSemanticallyEquivalent(lines, reparsed))
        #expect(reparsed[0].replacementTracks.first?.syllables?.map(\.text) == ["你好", "世界"])
        #expect(reparsed[0].background?.first?.replacementTracks.first?.text == "回声")
    }

    @Test("Track selection replaces primary text + syllables, selects subtitle language, and switches transliteration")
    func appliesReplacementSubtitleAndTransliterationSelections() throws {
        let lines = LyricsContentParser.parseText(multiTrackTTML)
        let catalog = LyricTrackSelectionPolicy.catalog(for: lines)

        #expect(catalog.originalLanguageCode == "zh-Hant")
        #expect(catalog.replacementTracks.map(\.languageCode) == ["zh-Hans"])
        #expect(catalog.subtitleTracks.map(\.languageCode) == ["en-US", "ja-JP"])
        #expect(catalog.transliterationTracks.map(\.languageCode) == ["zh-Latn", "yue-Latn"])
        #expect(catalog.tracks == [.translation, .romanization, .replacement])

        // 1. Select replacement zh-Hans + subtitle ja-JP + transliteration yue-Latn
        let zhHansID = try #require(catalog.replacementTracks.first?.id)
        let jaID = try #require(catalog.subtitleTracks.last?.id)
        let yueID = try #require(catalog.transliterationTracks.last?.id)

        let selected = LyricTrackSelectionPolicy.presenting(
            lines,
            selection: LyricTrackSelection(
                replacementTrackID: zhHansID,
                subtitleTrackID: jaID,
                transliterationTrackID: yueID
            ),
            showsBundledTranslations: true,
            targetLanguageCode: "en"
        )

        #expect(selected.lines.map(\.text) == ["你好世界", "合唱时间"])
        #expect(selected.lines[0].syllables?.map(\.text) == ["你好", "世界"])
        #expect(selected.lines[0].syllables?.map(\.start) == [1.0, 1.5])
        #expect(selected.lines[0].background?.first?.text == "回声")
        #expect(selected.lines[0].background?.first?.syllables?.map(\.text) == ["回声"])
        // Replacement tracks are stripped from display companions.
        #expect(selected.lines[0].replacementTracks.isEmpty)
        // Subtitle selection pinned ja-JP with its word-level syllables.
        #expect(selected.lines[0].manualTranslation?.text == "こんにちは世界")
        #expect(selected.lines[0].manualTranslation?.syllables?.map(\.start) == [1.0])
        #expect(LyricTrackSelectionPolicy.pinnedSubtitleLanguageCode(in: selected.lines) == "ja-JP")
        // Transliteration switched to Cantonese Jyutping.
        #expect(selected.lines[0].romanization == "nei5 hou2 sai3 gaai3")
        #expect(selected.lines[0].romanizationLanguageCode == "yue-Latn")

        // 2. Turn bundled translations off: replacement and transliteration still work, subtitles hidden.
        let hiddenSub = LyricTrackSelectionPolicy.presenting(
            lines,
            selection: LyricTrackSelection(replacementTrackID: zhHansID),
            showsBundledTranslations: false,
            targetLanguageCode: "en"
        )
        #expect(hiddenSub.lines[0].text == "你好世界")
        #expect(hiddenSub.lines[0].allManualTranslations.isEmpty)
        #expect(hiddenSub.lines[0].romanization == "nǐ hǎo shì jiè")
        #expect(LyricTrackSelectionPolicy.pinnedSubtitleLanguageCode(in: hiddenSub.lines) == nil)
    }

    @Test("Replacement-only TTML does not show a spurious subtitle translation")
    func replacementOnlyDocumentHasNoSubtitleTrack() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xml:lang="zh-Hant">
          <head><metadata><itunes:iTunesMetadata><itunes:translations>
            <itunes:translation type="replacement" xml:lang="zh-Hans">
              <itunes:text for="L1">简体歌词</itunes:text>
            </itunes:translation>
          </itunes:translations></itunes:iTunesMetadata></metadata></head>
          <body><div><p itunes:key="L1" begin="1s" end="3s">繁體歌詞</p></div></body>
        </tt>
        """

        let lines = LyricsContentParser.parseText(ttml)
        let first = try #require(lines.first)
        #expect(first.manualTranslation == nil)
        #expect(first.replacementTracks.map(\.text) == ["简体歌词"])
        #expect(LyricCompanionTextPolicy.items(for: first, translatedText: nil).isEmpty)

        let bundled = LyricBundledTranslationPolicy.presentation(of: lines, showsBundledTranslations: true)
        #expect(!bundled.tracks.contains(.translation))
        #expect(bundled.tracks.contains(.replacement))

        let catalog = LyricTrackSelectionPolicy.catalog(for: lines)
        #expect(catalog.hasReplacementTracks)
        #expect(!catalog.hasSubtitleTracks)
        #expect(!catalog.hasTransliteration)
    }

    // MARK: - OpenSubsonic `type` Extension & Group Agent

    @Test("OpenSubsonic supports structuredLyrics[].type (replacement / subtitle / omitted / unknown) and group agents")
    func openSubsonicSupportsTrackTypeAndGroupAgent() throws {
        let json = #"""
        [
          {
            "kind": "main",
            "lang": "zh-Hant",
            "synced": true,
            "agents": [
              {"id": "v1", "role": "main"},
              {"id": "v1000", "role": "group"}
            ],
            "line": [
              {"start": 1000, "end": 3000, "value": "繁體一句"},
              {"start": 3500, "end": 5500, "value": "全體合唱"}
            ],
            "cueLine": [
              {"index": 0, "agentId": "v1", "start": 1000, "end": 3000, "value": "繁體一句"},
              {"index": 1, "agentId": "v1000", "start": 3500, "end": 5500, "value": "全體合唱"}
            ]
          },
          {
            "kind": "translation",
            "type": "replacement",
            "lang": "zh-Hans",
            "synced": true,
            "line": [
              {"start": 1000, "end": 3000, "value": "简体一句"},
              {"start": 3500, "end": 5500, "value": "全体合唱"}
            ],
            "cueLine": [
              {
                "index": 0, "start": 1000, "end": 3000, "value": "简体一句",
                "cue": [
                  {"start": 1000, "end": 2000, "value": "简体"},
                  {"start": 2000, "end": 3000, "value": "一句"}
                ]
              }
            ]
          },
          {
            "kind": "translation",
            "type": "subtitle",
            "lang": "en-US",
            "synced": true,
            "line": [
              {"start": 1000, "end": 3000, "value": "Line one"}
            ]
          },
          {
            "kind": "translation",
            "lang": "ja-JP",
            "synced": true,
            "line": [
              {"start": 1000, "end": 3000, "value": "一行目"}
            ]
          },
          {
            "kind": "translation",
            "type": "future-custom-type",
            "lang": "fr",
            "synced": true,
            "line": [
              {"start": 1000, "end": 3000, "value": "Première ligne"}
            ]
          }
        ]
        """#

        let tracks = try JSONDecoder().decode([OpenSubsonicLyricsConverter.Track].self, from: Data(json.utf8))
        let lines = OpenSubsonicLyricsConverter.read(from: tracks).lines
        #expect(lines.count == 2)
        #expect(lines.map(\.voice) == [.primary, .group])

        let first = try #require(lines.first)
        #expect(first.replacementTracks.count == 1)
        #expect(first.replacementTracks.first?.languageCode == "zh-Hans")
        #expect(first.replacementTracks.first?.syllables?.map(\.text) == ["简体", "一句"])

        // subtitle + omitted type + unknown type all default to .subtitle
        #expect(first.subtitleTranslations.map(\.languageCode) == ["en-US", "ja-JP", "fr"])
        #expect(first.manualTranslation?.languageCode == "en-US")

        let catalog = LyricTrackSelectionPolicy.catalog(for: lines)
        #expect(catalog.replacementTracks.map(\.languageCode) == ["zh-Hans"])
        #expect(catalog.subtitleTracks.map(\.languageCode) == ["en-US", "ja-JP", "fr"])
    }

    @Test("Comments on chorus lines keep the anchor older versions wrote and never sync the group voice")
    func chorusLineCommentAnchorsStayCompatible() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
              <p begin="00:00:01.000" end="00:00:03.000" ttm:agent="v1">Lead line</p>
              <p begin="00:00:05.000" end="00:00:08.000" ttm:agent="v1000">Everyone together</p>
            </div>
          </body>
        </tt>
        """
        let lines = LyricsContentParser.parseText(ttml)
        #expect(lines.map(\.voice) == [.primary, .group])

        let anchor = try #require(LyricLineCommentAnchor.index(lines)[lines[1].id])
        // Before chorus lines had their own voice, v1000 was read as the primary voice.
        let writtenByOlderVersion = LyricLineCommentAnchor(text: "Everyone together", occurrence: 0, voice: .primary, timestamp: 5)
        #expect(anchor.id == writtenByOlderVersion.id)
        let encoded = String(decoding: try JSONEncoder().encode(anchor), as: UTF8.self)
        #expect(!encoded.contains("\"group\""))
    }
}
