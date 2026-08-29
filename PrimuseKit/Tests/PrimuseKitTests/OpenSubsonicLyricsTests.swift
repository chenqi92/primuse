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

        let text = try #require(OpenSubsonicLyricsConverter.text(from: tracks))
        let lines = LyricsContentParser.parseText(text)

        #expect(lines.count == 2)
        #expect(lines[0].text == "I sing")
        #expect(lines[0].timestamp == 0.9)
        let syllables = try #require(lines[0].syllables)
        #expect(syllables.count == 2)
        #expect(syllables[0] == LyricSyllable(text: "I ", start: 1.0, end: 1.35))
        #expect(syllables[1] == LyricSyllable(text: "sing", start: 1.5, end: 2.0))
        #expect(lines[1].text == "Next line")
        #expect(lines[1].timestamp == 3.0)
        #expect(lines[1].syllables == nil)
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

        #expect(syllables[0] == LyricSyllable(text: "la ", start: 5.1, end: 5.6))
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

    @Test("Uses the first cue line as the lead layer for parallel vocal agents")
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
    }

    private func decodeTracks(_ json: String) throws -> [OpenSubsonicLyricsConverter.Track] {
        try JSONDecoder().decode([OpenSubsonicLyricsConverter.Track].self, from: Data(json.utf8))
    }
}
