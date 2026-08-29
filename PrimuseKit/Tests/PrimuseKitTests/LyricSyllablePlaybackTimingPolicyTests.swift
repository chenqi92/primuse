import Foundation
import Testing
@testable import PrimuseKit

@Suite("Lyric syllable playback timing")
struct LyricSyllablePlaybackTimingPolicyTests {
    @Test("Start-only Persian ELRC finishes a short word before a long silent gap")
    func capsIssue68InferredPersianWordDuration() throws {
        let line = try #require(LyricsContentParser.parse(
            "[00:29.30]<00:29.30>انتظار <00:29.60>و <00:31.30>انتظار"
        ).first)
        let syllables = try #require(line.syllables)
        let conjunction = syllables[1]

        #expect(conjunction.text == "و ")
        #expect(conjunction.endTiming == .inferred)
        #expect(abs(conjunction.end - 31.30) < 0.001)
        #expect(abs(LyricSyllablePlaybackTimingPolicy.effectiveDuration(
            for: conjunction,
            nextSyllableStart: syllables[2].start
        ) - 0.42) < 0.001)
    }

    @Test("Parenthesized ELRC remains ordinary text and uses its exact word starts")
    func keepsIssue68ParenthesizedELRCOnOneVoice() throws {
        let line = try #require(LyricsContentParser.parse(
            "[01:36.74]<01:36.74>باز <01:37.90>دوره <01:39.82>(دوره)"
        ).first)
        let syllables = try #require(line.syllables)

        #expect(line.voice == .primary)
        #expect(line.background == nil)
        #expect(syllables.map(\.start) == [96.74, 97.90, 99.82])
        #expect(syllables[1].endTiming == .inferred)
        #expect(LyricSyllablePlaybackTimingPolicy.effectiveEnd(
            for: syllables[1],
            nextSyllableStart: syllables[2].start
        ) < syllables[2].start)
    }

    @Test("Explicit long syllable durations are never capped")
    func preservesExplicitHeldNotes() {
        let held = LyricSyllable(
            text: "آواز",
            start: 10,
            end: 12.4,
            endTiming: .explicit
        )

        #expect(abs(LyricSyllablePlaybackTimingPolicy.effectiveDuration(
            for: held,
            nextSyllableStart: 12.4
        ) - 2.4) < 0.001)
    }

    @Test("TTML distinguishes explicit word ends from inferred next-word gaps")
    func tracksTTMLWordEndProvenance() throws {
        let content = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="10s" end="15s">
            <span begin="10s" end="12.4s">Held </span>
            <span begin="12.4s">then </span>
            <span begin="14.4s">next</span>
          </p>
        </div></body></tt>
        """
        let syllables = try #require(LyricsContentParser.parse(content).first?.syllables)

        #expect(syllables[0].endTiming == .explicit)
        #expect(abs(LyricSyllablePlaybackTimingPolicy.effectiveDuration(
            for: syllables[0],
            nextSyllableStart: syllables[1].start
        ) - 2.4) < 0.001)
        #expect(syllables[1].endTiming == .inferred)
        #expect(LyricSyllablePlaybackTimingPolicy.effectiveEnd(
            for: syllables[1],
            nextSyllableStart: syllables[2].start
        ) < syllables[2].start)
    }

    @Test("Legacy start-only caches get the conservative long-gap fallback")
    func migratesLegacyStartOnlyTimingAtPlayback() throws {
        let data = try #require(
            #"{"text":"و ","start":29.6,"end":31.3}"#.data(using: .utf8)
        )
        let cached = try JSONDecoder().decode(LyricSyllable.self, from: data)

        #expect(cached.endTiming == .legacy)
        #expect(abs(LyricSyllablePlaybackTimingPolicy.effectiveDuration(
            for: cached,
            nextSyllableStart: 31.3
        ) - 0.42) < 0.001)
    }
}
