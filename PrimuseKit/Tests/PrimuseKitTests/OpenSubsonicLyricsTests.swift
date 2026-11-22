import Foundation
import Testing
@testable import PrimuseKit

@Suite("OpenSubsonic enhanced lyrics")
struct OpenSubsonicLyricsTests {
    @Test("Prefers the main track and preserves cue start and end times")
    func convertsVersionTwoCueLines() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "translation",
            "synced": true,
            "line": [{"start": 900, "value": "Translated line"}]
          },
          {
            "kind": "main",
            "synced": true,
            "line": [
              {"start": 900, "value": "I sing"},
              {"start": 3000, "value": "Next line"}
            ],
            "cueLine": [
              {
                "index": 0,
                "start": 900,
                "end": 2000,
                "value": "I sing",
                "cue": [
                  {"start": 1000, "end": 1350, "value": "I", "byteStart": 0, "byteEnd": 0},
                  {"start": 1500, "end": 2000, "value": "sing", "byteStart": 2, "byteEnd": 5}
                ]
              }
            ]
          }
        ]
        """#)

        let lines = OpenSubsonicLyricsConverter.read(from: tracks).lines
        #expect(lines.count == 2)
        #expect(lines[0].text == "I sing")
        #expect(lines[0].timestamp == 0.9)
        #expect(lines[0].manualTranslation?.text == "Translated line")
        #expect(lines[1].manualTranslation == nil)
        let syllables = try #require(lines[0].syllables)
        #expect(syllables.count == 2)
        #expect(syllables[0] == LyricSyllable(text: "I ", start: 1.0, end: 1.35))
        #expect(syllables[1] == LyricSyllable(text: "sing", start: 1.5, end: 2.0))
        #expect(lines[1].text == "Next line")
        #expect(lines[1].timestamp == 3.0)
        #expect(lines[1].syllables == nil)
    }

    @Test("Repairs a server's misdecoded words after resolving byte offsets and preserves legacy source text")
    func repairsTimedWordsAtTheirOriginalByteOffsets() throws {
        func misdecoded(_ text: String) throws -> String {
            let bytes = try #require(text.data(using: TextEncodingRepair.gb18030))
            return try #require(String(data: bytes, encoding: .isoLatin1))
        }
        let first = try misdecoded("银色风铃")
        let second = try misdecoded("纸灯轻摇")
        let whole = first + " · " + second
        let secondStart = (first + " · ").utf8.count
        let tracks = try decodeTracks(#"""
        [{"line":[{"start":0,"value":"\#(whole)"}],"cueLine":[{"index":0,"value":"\#(whole)","cue":[
          {"start":25,"end":480,"value":"\#(first)","byteStart":0,"byteEnd":\#(first.utf8.count - 1)},
          {"start":550,"end":920,"value":"\#(second)","byteStart":\#(secondStart),"byteEnd":\#(whole.utf8.count - 1)}
        ]}]}]
        """#)
        let words = try #require(OpenSubsonicLyricsConverter.read(from: tracks).lines.first?.syllables)
        #expect(words.map(\.text) == ["银色风铃 · ", "纸灯轻摇"])
        #expect(words.map(\.start) == [0.025, 0.55])
        #expect(words.map(\.end) == [0.48, 0.92])

        let legacy = try decodeTracks(#"[{"synced":false,"line":[{"value":"\#(first)"}]}]"#)
        let response = OpenSubsonicLyricsConverter.read(from: legacy)
        #expect(response == .content(first))
        #expect(response.lines.first?.text == "银色风铃")
    }

    @Test("Prefers the cue-capable main track when a server returns duplicate mains")
    func prefersCueCapableMainTrack() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 1000, "value": "Line-only copy"}]
          },
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 2000, "value": "Word timed"}],
            "cueLine": [
              {
                "index": 0,
                "start": 2000,
                "end": 3000,
                "value": "Word timed",
                "cue": [
                  {"start": 2000, "end": 2400, "value": "Word "},
                  {"start": 2500, "end": 3000, "value": "timed"}
                ]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let line = try #require(LyricsContentParser.parseText(text).first)

        #expect(line.text == "Word timed")
        #expect(line.syllables?.count == 2)
    }

    @Test("Does not replace the main lyrics with a secondary language layer")
    func rejectsSecondaryTrackWithoutMainLyrics() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "translation",
            "synced": true,
            "line": [{"start": 1000, "value": "Translated line"}]
          },
          {
            "kind": "pronunciation",
            "synced": true,
            "line": [{"start": 1000, "value": "Romanized line"}]
          }
        ]
        """#)

        #expect(OpenSubsonicLyricsConverter.text(from: tracks) == nil)
    }

    @Test("Infers cue ends when a server returns start-only enhanced LRC data")
    func infersMissingCueEnds() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 5000, "value": "la la"}],
            "cueLine": [
              {
                "index": 0,
                "start": 5000,
                "end": 6200,
                "cue": [
                  {"start": 5100, "value": "la "},
                  {"start": 5600, "value": "la"}
                ]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let line = try #require(LyricsContentParser.parseText(text).first)
        let syllables = try #require(line.syllables)

        #expect(syllables[0] == LyricSyllable(text: "la ", start: 5.1, end: 5.6, endTiming: .inferred))
        #expect(syllables[1].text == "la")
        #expect(abs(syllables[1].start - 5.6) < 0.000_001)
        #expect(abs(syllables[1].end - 6.2) < 0.000_001)
    }

    @Test("Uses UTF-8 byte offsets to retain spaces and untimed text")
    func retainsCanonicalCueLineText() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 0, "value": "Oh love love me tonight"}],
            "cueLine": [
              {
                "index": 0,
                "start": 0,
                "end": 2400,
                "value": "Oh love love me tonight",
                "cue": [
                  {"start": 0, "end": 300, "value": "Oh", "byteStart": 0, "byteEnd": 1},
                  {"start": 900, "end": 1300, "value": "love", "byteStart": 8, "byteEnd": 11},
                  {"start": 1300, "end": 1600, "value": "me", "byteStart": 13, "byteEnd": 14},
                  {"start": 1600, "end": 2400, "value": "tonight", "byteStart": 16, "byteEnd": 22}
                ]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let line = try #require(LyricsContentParser.parseText(text).first)
        let syllables = try #require(line.syllables)

        #expect(line.text == "Oh love love me tonight")
        #expect(syllables.map(\.text) == ["Oh love ", "love ", "me ", "tonight"])
    }

    @Test("Uses byte offsets across multibyte UTF-8 text")
    func retainsMultibyteCueLineText() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 2747, "value": "눈을 뜬 순간"}],
            "cueLine": [
              {
                "index": 0,
                "start": 2747,
                "end": 6214,
                "value": "눈을 뜬 순간",
                "cue": [
                  {"start": 2747, "end": 3018, "value": "눈", "byteStart": 0, "byteEnd": 2},
                  {"start": 3018, "end": 3179, "value": "을", "byteStart": 3, "byteEnd": 5},
                  {"start": 3179, "end": 3582, "value": " ", "byteStart": 6, "byteEnd": 6},
                  {"start": 3582, "end": 4100, "value": "뜬", "byteStart": 7, "byteEnd": 9},
                  {"start": 4100, "end": 4500, "value": " ", "byteStart": 10, "byteEnd": 10},
                  {"start": 4500, "end": 5200, "value": "순", "byteStart": 11, "byteEnd": 13},
                  {"start": 5200, "end": 6214, "value": "간", "byteStart": 14, "byteEnd": 16}
                ]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let syllables = try #require(LyricsContentParser.parseText(text).first?.syllables)

        #expect(syllables.map(\.text) == ["눈", "을", " ", "뜬", " ", "순", "간"])
    }

    @Test("Keeps version one line lyrics as a backward-compatible fallback")
    func keepsVersionOneLyrics() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "synced": true,
            "offset": -100,
            "line": [
              {"start": 1250, "value": "Line one"},
              {"start": 2500, "value": "Line two"}
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let lines = LyricsContentParser.parseText(text)

        #expect(lines.map(\.text) == ["Line one", "Line two"])
        #expect(lines.map(\.timestamp) == [1.35, 2.6])
        #expect(lines.allSatisfy { $0.syllables == nil })
    }

    @Test("Applies the track offset to line and cue timing")
    func appliesTrackOffset() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "offset": 250,
            "line": [{"start": 1000, "value": "Shift me"}],
            "cueLine": [
              {
                "index": 0,
                "start": 1000,
                "end": 2000,
                "cue": [
                  {"start": 1100, "end": 1400, "value": "Shift "},
                  {"start": 1500, "end": 2000, "value": "me"}
                ]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let line = try #require(LyricsContentParser.parseText(text).first)
        let syllables = try #require(line.syllables)

        #expect(line.timestamp == 0.75)
        #expect(syllables[0] == LyricSyllable(text: "Shift ", start: 0.85, end: 1.15))
        #expect(syllables[1] == LyricSyllable(text: "me", start: 1.25, end: 1.75))
    }

    @Test("Accepts fractional line starts and track offsets")
    func acceptsFractionalLineTiming() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "offset": 100.5,
            "line": [{"start": 1000.5, "value": "Float"}],
            "cueLine": [
              {
                "index": 0,
                "end": 1500,
                "value": "Float",
                "cue": [
                  {
                    "start": 1200,
                    "end": 1500,
                    "value": "Float",
                    "byteStart": 0,
                    "byteEnd": 4
                  }
                ]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let line = try #require(LyricsContentParser.parseText(text).first)
        let syllable = try #require(line.syllables?.first)

        #expect(abs(line.timestamp - 0.9) < 0.000_001)
        #expect(syllable.text == "Float")
        #expect(abs(syllable.start - 1.1) < 0.000_001)
        #expect(abs(syllable.end - 1.4) < 0.000_001)
    }

    @Test("Preserves an explicitly instantaneous cue")
    func preservesZeroDurationCue() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 1000, "value": "Now"}],
            "cueLine": [
              {
                "index": 0,
                "start": 1000,
                "end": 1500,
                "cue": [{"start": 1100, "end": 1100, "value": "Now"}]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let syllable = try #require(LyricsContentParser.parseText(text).first?.syllables?.first)

        #expect(syllable.start == 1.1)
        #expect(syllable.end == 1.1)
    }

    @Test("Does not stretch a non-final instantaneous cue")
    func preservesNonFinalZeroDurationCue() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 1000, "value": "Now go"}],
            "cueLine": [
              {
                "index": 0,
                "start": 1000,
                "end": 1800,
                "value": "Now go",
                "cue": [
                  {"start": 1100, "end": 1100, "value": "Now ", "byteStart": 0, "byteEnd": 3},
                  {"start": 1300, "end": 1800, "value": "go", "byteStart": 4, "byteEnd": 5}
                ]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let syllables = try #require(LyricsContentParser.parseText(text).first?.syllables)

        #expect(syllables.count == 2)
        #expect(syllables[0].text == "Now ")
        #expect(syllables[0].start == 1.1)
        #expect(syllables[0].end == 1.1)
        #expect(syllables[1].text == "go")
    }

    @Test("Keeps parallel backing vocals nested with their own word timing")
    func keepsLeadCueLine() throws {
        let tracks = try decodeTracks(#"""
        [
          {
            "kind": "main",
            "synced": true,
            "line": [{"start": 1000, "value": "Lead backing"}],
            "agents": [
              {"id": "lead", "role": "main", "name": "Lead Vocal"},
              {"id": "backing", "role": "bg"}
            ],
            "cueLine": [
              {
                "index": 0,
                "agentId": "lead",
                "start": 1000,
                "end": 1800,
                "value": "Lead",
                "cue": [{"start": 1000, "end": 1800, "value": "Lead"}]
              },
              {
                "index": 0,
                "agentId": "backing",
                "start": 1200,
                "end": 1800,
                "value": "backing",
                "cue": [{"start": 1200, "end": 1800, "value": "backing"}]
              }
            ]
          }
        ]
        """#)

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let line = try #require(LyricsContentParser.parseText(text).first)

        #expect(line.text == "Lead")
        #expect(line.syllables?.count == 1)
        let backing = try #require(line.background?.first)
        #expect(backing.text == "backing")
        #expect(backing.isBackingVocal)
        #expect(backing.syllables == [LyricSyllable(text: "backing", start: 1.2, end: 1.8)])
    }

    @Test("Matches sparse translations and independently timed pronunciation by playback time")
    func alignsIndependentTracks() throws {
        let tracks = try decodeTracks(#"""
        [
          {"kind":"pronunciation","lang":"zho","offset":-100,"synced":true,
           "line":[{"start":1900,"value":"shi deng"}],
           "cueLine":[{"index":0,"start":1900,"end":2600,"value":"shi deng","cue":[
             {"start":1920,"end":2120,"value":"shi","byteStart":0,"byteEnd":2},
             {"start":2200,"end":2600,"value":"deng","byteStart":4,"byteEnd":7}]}]},
          {"kind":"main","lang":"zho","synced":true,"offset":200,
           "line":[{"start":1200,"end":1600,"value":"纸桥"},{"start":2200,"end":3200,"value":"石灯"},
                   {"start":3800,"end":3800,"value":"雾"}]},
          {"kind":"translation","lang":"eng","synced":true,"offset":50,
           "line":[{"start":2055,"end":2720,"value":"Stone lamp"},{"start":3450,"value":"Orphan"}],
           "cueLine":[{"index":0,"start":2055,"end":2720,"value":"Stone lamp","cue":[
             {"start":2080,"end":2720,"value":"lamp","byteStart":6,"byteEnd":9}]}]},
          {"kind":"translation","lang":"fra","synced":true,"line":[{"start":2000,"value":"Lampe de pierre"}]}
        ]
        """#)
        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let lines = LyricsContentParser.parseText(text)
        #expect(lines.map(\.text) == ["纸桥", "石灯", "雾"])
        #expect(lines.map(\.endTimestamp) == [1.4, 3, 3.6])
        #expect(lines[0].allManualTranslations.isEmpty && lines[2].allManualTranslations.isEmpty)
        #expect(lines[0].romanization == nil && lines[2].romanization == nil)
        let line = lines[1]
        #expect(line.allManualTranslations.map(\.text) == ["Stone lamp", "Lampe de pierre"])
        #expect(line.allManualTranslations.map(\.languageCode) == ["en", "fr"])
        #expect(line.manualTranslation?.syllables == [LyricSyllable(text: "Stone lamp", start: 2.03, end: 2.67)])
        #expect(line.romanization == "shi deng")
        #expect(line.romanizationSyllables == [
            LyricSyllable(text: "shi ", start: 2.02, end: 2.22), LyricSyllable(text: "deng", start: 2.3, end: 2.7)
        ])
        #expect(LyricCompanionTextPolicy.texts(for: line, translatedText: nil) == ["shi deng", "Stone lamp"])
        let french = LyricManualTranslationPolicy.preferredTranslation(for: line, targetLanguageCode: "fr")
        #expect(LyricCompanionTextPolicy.texts(for: line, translatedText: french?.text) == ["shi deng", "Lampe de pierre"])
        let hidden = LyricBundledTranslationPolicy.presentation(of: [line], showsBundledTranslations: false)
        #expect(LyricCompanionTextPolicy.texts(for: hidden.lines[0], translatedText: nil) == ["shi deng"])
    }

    @Test("Attributes simultaneous voices and backing annotations using track-local agent definitions")
    func preservesDuetAndBackingAnnotations() throws {
        let tracks = try decodeTracks(#"""
        [
          {"kind":"main","synced":true,"line":[{"start":1000,"value":"叩窗 回声"},{"start":1000,"value":"回信"}],
           "agents":[{"id":"a","role":"main","name":"Pine"},{"id":"b","role":"voice","name":"Reed"},{"id":"c","role":"bg"}],
           "cueLine":[{"index":0,"start":1000,"end":2100,"agentId":"a","value":"叩窗"},
                      {"index":0,"start":1200,"end":1800,"agentId":"c","value":"回声"},
                      {"index":1,"start":1000,"end":2100,"agentId":"b","value":"回信"}]},
          {"kind":"translation","lang":"en","synced":true,"line":[{"start":1000,"value":"Reply"},{"start":1000,"value":"Knock Echo"}],
           "agents":[{"id":"a","role":"voice","name":"Reed"},{"id":"b","role":"bg"},{"id":"c","role":"main","name":"Pine"}],
           "cueLine":[{"index":0,"start":1000,"agentId":"a","value":"Reply"},{"index":1,"start":1000,"agentId":"c","value":"Knock"},
                      {"index":1,"start":1200,"agentId":"b","value":"Echo"}]},
          {"kind":"pronunciation","synced":true,"line":[{"start":1200,"value":"hui sheng"}],
           "agents":[{"id":"lead","role":"main"},{"id":"a","role":"bg"}],
           "cueLine":[{"index":0,"start":1200,"agentId":"a","value":"hui sheng"}]}
        ]
        """#)
        let lines = OpenSubsonicLyricsConverter.read(from: tracks).lines
        #expect(lines.map(\.text) == ["叩窗", "回信"])
        #expect(lines.map(\.voice) == [.primary, .secondary])
        #expect(lines.map { $0.manualTranslation?.text } == ["Knock", "Reply"])
        let backing = try #require(lines.first?.background?.first)
        #expect(backing.isBackingVocal && backing.text == "回声")
        #expect(backing.manualTranslation?.text == "Echo")
        #expect(backing.romanization == "hui sheng")
        #expect(lines.allSatisfy { $0.romanization == nil })
    }

    @Test("Pairs plain companion rows only with unambiguous complete plain lyrics")
    func preservesPlainCompanions() throws {
        let tracks = try decodeTracks(#"""
        [
          {"synced":false,"line":[{"value":"铜铃"},{"value":"纸舟"}]},
          {"kind":"translation","lang":"en","synced":false,"line":[{"value":"Brass bell"},{"value":"Paper skiff"}]},
          {"kind":"pronunciation","synced":false,"line":[{"value":"zhi zhou"}]}
        ]
        """#)
        let lines = LyricsContentParser.parseText(try #require(OpenSubsonicLyricsConverter.text(from: tracks)))
        #expect(lines.map { $0.manualTranslation?.text } == ["Brass bell", "Paper skiff"])
        #expect(lines.allSatisfy { !$0.isSynchronized && $0.romanization == nil })
    }

    @Test("Keeps split companion rows together and does not inherit the main language for an untagged translation")
    func overlappingAndSplitCompanions() throws {
        let tracks = try decodeTracks(#"""
        [
          {"kind":"main","lang":"zho","synced":true,"line":[{"start":2000,"end":4000,"value":"铃与风"}]},
          {"kind":"translation","lang":"und","synced":true,"line":[
            {"start":1850,"end":2300,"value":"Bell <one>"},{"start":2800,"end":3500,"value":"& wind"}]},
          {"kind":"pronunciation","synced":true,"line":[{"start":2000,"value":"ling"}],
           "cueLine":[{"index":0,"start":2000,"end":2900,"value":"ling","cue":[{"start":2100,"value":"ling"}]}]}
        ]
        """#)
        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let line = try #require(LyricsContentParser.parseText(text).first)
        #expect(line.manualTranslation?.text == "Bell <one>\n& wind")
        #expect(line.manualTranslation?.languageCode == nil)
        #expect(line.romanization == "ling")
        #expect(line.romanizationSyllables == [LyricSyllable(text: "ling", start: 2.1, end: 2.9, endTiming: .inferred)])
        #expect(LyricManualTranslationPolicy.declaredLanguageCode(in: line.metadataLines ?? []) == "zh")
    }

    @Test("Uses the original language's reading and keeps sparse alternate readings as a fallback")
    func choosesPronunciationForOriginalLanguage() throws {
        let tracks = try decodeTracks(#"""
        [
          {"kind":"main","lang":"zho","synced":true,"line":[{"start":1000,"value":"雾"},{"start":2000,"value":"帆"}]},
          {"kind":"pronunciation","synced":true,"line":[{"start":1000,"value":"u"},{"start":2000,"value":"fan"}]},
          {"kind":"pronunciation","lang":"zh-Latn","synced":true,"line":[{"start":1000,"value":"wu"}]}
        ]
        """#)
        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        #expect(LyricsContentParser.parseText(text).map(\.romanization) == ["wu", "fan"])
    }

    @Test("An unattributed reading follows a solo backing passage and prefers the lead when both sing")
    func matchesUnattributedReading() throws {
        let tracks = try decodeTracks(#"""
        [
          {"kind":"main","synced":true,"agents":[{"id":"a","role":"main"},{"id":"b","role":"bg"}],
           "line":[{"start":1000,"value":"雾"},{"start":3000,"value":"雨 回"}],
           "cueLine":[{"index":0,"agentId":"b","start":1000,"end":1500,"value":"雾"},
                      {"index":1,"agentId":"a","start":3000,"end":4000,"value":"雨"},
                      {"index":1,"agentId":"b","start":3200,"end":3700,"value":"回"}]},
          {"kind":"pronunciation","synced":true,"line":[{"start":1000,"value":"wu"},{"start":3200,"value":"yu"}]}
        ]
        """#)
        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let lines = LyricsContentParser.parseText(text)
        #expect(lines.map(\.romanization) == ["wu", "yu"])
        #expect(lines.last?.background?.first?.romanization == nil)
    }

    @Test("Rereading upgrades a cached main-only document and a second read keeps the enriched cache")
    func rereadsMainOnlyCache() async throws {
        let tracks = try decodeTracks(#"""
        [
          {"synced":true,"line":[{"start":1000,"value":"砂钟"}]},
          {"kind":"translation","lang":"eng","synced":true,"line":[{"start":1000,"value":"Sand clock"}]},
          {"kind":"pronunciation","synced":true,"line":[{"start":1000,"value":"sha zhong"}]}
        ]
        """#)
        let coordinator = LyricsSourceRefreshCoordinator()
        let key = LyricsSourceRefreshKey(sourceID: "library", songID: "clock")
        let old = LyricsContentParser.parseText("[00:01.00]砂钟")
        let fetch: @Sendable () -> [LyricLine] = {
            OpenSubsonicLyricsConverter.read(from: tracks).lines
        }
        let result = await coordinator.refresh(key: key, currentDocument: old, trigger: .explicit,
                                               fetch: fetch, replace: { _ in true })
        guard case .updated(let lines) = result else { Issue.record("An enriched source must replace the cache"); return }
        let cached = try JSONDecoder().decode([LyricLine].self, from: JSONEncoder().encode(lines))
        #expect(cached.first?.romanization == "sha zhong")
        #expect(cached.first?.manualTranslation?.text == "Sand clock")
        let again = await coordinator.refresh(key: key, currentDocument: cached, trigger: .explicit,
                                              fetch: fetch, replace: { _ in Issue.record("Identical lyrics must not be rewritten"); return false })
        #expect(again == .unchanged)
    }

    private func decodeTracks(_ json: String) throws -> [OpenSubsonicLyricsConverter.Track] {
        try JSONDecoder().decode([OpenSubsonicLyricsConverter.Track].self, from: Data(json.utf8))
    }
}
