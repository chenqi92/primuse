import Foundation
import Testing
@testable import PrimuseKit

private func lyricLines(_ pairs: [(TimeInterval, String)]) -> [MedleyLyricLine] {
    pairs.map { MedleyLyricLine(time: $0.0, text: $0.1) }
}

/// Four lines every four seconds from `start`.
private func block(_ start: TimeInterval, _ texts: [String], spacing: TimeInterval = 4) -> [(TimeInterval, String)] {
    texts.enumerated().map { (start + Double($0.offset) * spacing, $0.element) }
}

private let chorusLines = ["我们一起唱", "唱到天亮！", "Shine on, shine on", "不要停下来"]

/// Credits, verse, chorus, a different verse, chorus, bridge, chorus.
private let popSong = lyricLines(
    [(0, "作词：某某"), (2, "作曲：某某")]
        + block(15, ["第一段第一句", "第一段第二句", "第一段第三句", "第一段第四句"])
        + block(31, chorusLines)
        + block(55, ["第二段第一句", "第二段第二句", "第二段第三句", "第二段第四句"])
        + block(71, chorusLines.map { $0.replacingOccurrences(of: "！", with: "") })
        + block(95, ["桥段一", "桥段二", "桥段三"])
        + block(110, chorusLines)
        + [(127, "")]
)

@Suite struct MedleyLyricChorusDetectorTests {
    @Test func findsEveryChorusOfAPopSong() {
        let stretches = MedleyLyricChorusDetector.stretches(in: popSong, duration: 140)
        #expect(stretches.map(\.start) == [31, 71, 110])
        // The last line ends a typical line length later, not at the next verse.
        #expect(abs(stretches[0].end - 49.4) < 0.01)
        #expect(stretches[0].lineStarts == [31, 35, 39, 43])
        // The last chorus ends at the blank line after it.
        #expect(stretches[2].end == 127)
    }

    @Test func growsARepeatedHookIntoTheWholeChorus() {
        // The hook "A B" is sung twice in every chorus, so it is the most
        // repeated block; the chorus around it is what gets played.
        let chorus = ["A line", "B line", "A line", "B line", "C line", "D line"]
        let song = lyricLines(
            block(10, ["v1", "v2", "v3", "v4"])
                + block(26, chorus)
                + block(60, ["w1", "w2", "w3", "w4"])
                + block(76, chorus)
                + block(110, ["x1", "x2"])
                + block(118, chorus)
        )
        let stretches = MedleyLyricChorusDetector.stretches(in: song, duration: 160)
        #expect(stretches.map(\.start) == [26, 76, 118])
        #expect(stretches.allSatisfy { $0.lineStarts.count == 6 })
    }

    @Test func untimedOrNonRepeatingLyricsFindNothing() {
        let unique = lyricLines((0..<20).map { (Double($0) * 4, "line \($0)") })
        #expect(MedleyLyricChorusDetector.stretches(in: unique, duration: 100).isEmpty)
        let short = lyricLines(block(10, chorusLines) + block(40, chorusLines.prefix(2).map { $0 }))
        #expect(MedleyLyricChorusDetector.stretches(in: short, duration: 100).isEmpty)
        #expect(MedleyLyricChorusDetector.stretches(in: [], duration: 100).isEmpty)
    }

    @Test func translationLinesAtTheSameTimeAreIgnored() {
        var lines: [(TimeInterval, String)] = []
        for (time, text) in popSong.map({ ($0.time, $0.text) }) {
            lines.append((time, text))
            if !text.isEmpty { lines.append((time, "translation of \(text) at \(time)")) }
        }
        let stretches = MedleyLyricChorusDetector.stretches(in: lyricLines(lines), duration: 140)
        #expect(stretches.map(\.start) == [31, 71, 110])
    }
}

@Suite struct MedleyHighlightDetectorTests {
    private func flatFeatures(duration: TimeInterval, loudness: (TimeInterval) -> Float) -> MedleyAudioFeatures {
        let count = Int(duration / 0.5)
        return MedleyAudioFeatures(
            frameDuration: 0.5,
            chroma: [Float](repeating: 0, count: count * 12),
            loudness: (0..<count).map { loudness(Double($0) * 0.5) }
        )
    }

    @Test func lyricsAlonePlayTheFirstChorus() {
        let highlight = MedleyHighlightDetector.highlight(duration: 140, lyrics: popSong, audio: nil)
        #expect(highlight?.start == 31)
        #expect(highlight?.basis == .lyrics)
    }

    @Test func audioPicksTheStrongestChorus() {
        let loudLastChorus = flatFeatures(duration: 140) { $0 >= 110 && $0 < 127 ? -10 : -20 }
        let highlight = MedleyHighlightDetector.highlight(duration: 140, lyrics: popSong, audio: loudLastChorus)
        #expect(highlight?.start == 110)
        #expect(highlight?.end == 127)
        #expect(highlight?.basis == .lyricsAndAudio)
    }

    @Test func nearlyEqualChorusesPlayTheEarliest() {
        let features = flatFeatures(duration: 140) { time in
            if time >= 31 && time < 50 { return -12 }
            if time >= 110 && time < 127 { return -11 }
            return -20
        }
        let highlight = MedleyHighlightDetector.highlight(duration: 140, lyrics: popSong, audio: features)
        #expect(highlight?.start == 31)
    }

    @Test func aLongRepeatedVerseAndChorusIsCutToItsEnd() {
        // Identical verses: the repeated block is verse plus chorus, 43 s long.
        let verse = ["v1", "v2", "v3", "v4"]
        let chorus = ["c1", "c2", "c3", "c4"]
        let song = lyricLines(
            block(10, verse, spacing: 5) + block(30, chorus, spacing: 5)
                + block(70, ["b1", "b2"], spacing: 5)
                + block(90, verse, spacing: 5) + block(110, chorus, spacing: 5)
        )
        let highlight = MedleyHighlightDetector.highlight(duration: 160, lyrics: song, audio: nil)
        let stretch = MedleyLyricChorusDetector.stretches(in: song, duration: 160).first
        #expect(stretch.map { $0.length > 40 } == true)
        #expect(highlight?.end == stretch?.end)
        #expect((highlight?.length ?? 0) <= 40)
        #expect((highlight?.start ?? 0) >= 20)
    }

    @Test func noLyricsAndNoAudioFindsNothing() {
        #expect(MedleyHighlightDetector.highlight(duration: 200, lyrics: [], audio: nil) == nil)
    }
}

/// One stretch of a synthesized song: a chord loop (two seconds a chord) at
/// a level, with more overtones when `bright`.
private struct SynthPart {
    let start: TimeInterval
    let end: TimeInterval
    let chords: [[Double]]
    let amplitude: Double
    var bright = false
}

private enum Chord {
    static let c: [Double] = [130.81, 164.81, 196.00]
    static let g: [Double] = [98.00, 123.47, 146.83]
    static let am: [Double] = [110.00, 130.81, 164.81]
    static let f: [Double] = [87.31, 110.00, 130.81]
    static let dm: [Double] = [146.83, 174.61, 220.00]
    static let e: [Double] = [82.41, 103.83, 123.47]
    static let bb: [Double] = [116.54, 146.83, 174.61]
}

/// Chords as stacks of harmonic tones with a two-per-second pulse and a
/// little noise, at the extractor's preferred rate.
private func synthesize(_ parts: [SynthPart], duration: TimeInterval) -> [Float] {
    let sampleRate = MedleyAudioFeatureExtractor.preferredSampleRate
    let total = Int(duration * sampleRate)
    var samples = [Float](repeating: 0, count: total)
    var noise: UInt32 = 12345
    for part in parts {
        let harmonics = part.bright ? 5 : 2
        for index in Int(part.start * sampleRate)..<min(total, Int(part.end * sampleRate)) {
            let time = Double(index) / sampleRate
            let chord = part.chords[Int((time - part.start) / 2) % part.chords.count]
            var value = 0.0
            for frequency in chord {
                for harmonic in 1...harmonics {
                    value += sin(2 * Double.pi * frequency * Double(harmonic) * time) / Double(harmonic * harmonic)
                }
            }
            let pulse = 0.7 + 0.3 * cos(2 * Double.pi * 2 * time)
            noise = noise &* 1_103_515_245 &+ 12345
            let jitter = Double(noise >> 16) / 65_536 - 0.5
            samples[index] = Float(part.amplitude * pulse * (value / 6 + 0.03 * jitter))
        }
    }
    return samples
}

/// The highlight found in `samples`, fed in decoder-sized chunks as the players do.
private func audioHighlight(_ samples: [Float], duration: TimeInterval) -> MedleyHighlight? {
    let extractor = MedleyAudioFeatureExtractor(sampleRate: MedleyAudioFeatureExtractor.preferredSampleRate)
    var offset = 0
    while offset < samples.count {
        let end = min(samples.count, offset + 8192)
        extractor.append(Array(samples[offset..<end]))
        offset = end
    }
    return MedleyAudioHighlightDetector.highlight(in: extractor.finish(), duration: duration)
}

@Suite struct MedleyAudioAnalysisTests {
    @Test func chromaNamesTheSoundingPitchClass() {
        let rate = MedleyAudioFeatureExtractor.preferredSampleRate
        let tone = (0..<Int(rate * 2)).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
        let extractor = MedleyAudioFeatureExtractor(sampleRate: rate)
        extractor.append(tone)
        let features = extractor.finish()
        #expect(features.frameCount >= 3)
        let frame = Array(features.chroma[12..<24])
        #expect(frame.firstIndex(of: frame.max()!) == 9) // A
        #expect(features.loudness[1] > -20)
    }

    @Test func silenceHasNoChroma() {
        let extractor = MedleyAudioFeatureExtractor(sampleRate: 11025)
        extractor.append([Float](repeating: 0, count: 11025 * 2))
        let features = extractor.finish()
        #expect(features.chroma.allSatisfy { $0 == 0 })
    }

    @Test func findsTheFirstChorusOfASynthesizedSong() throws {
        let song = synthesize([
            SynthPart(start: 0, end: 10, chords: [Chord.c], amplitude: 0.03),
            SynthPart(start: 10, end: 35, chords: [Chord.am, Chord.f], amplitude: 0.08),
            SynthPart(start: 35, end: 55, chords: [Chord.c, Chord.g], amplitude: 0.3, bright: true),
            SynthPart(start: 55, end: 80, chords: [Chord.am, Chord.f], amplitude: 0.08),
            SynthPart(start: 80, end: 100, chords: [Chord.c, Chord.g], amplitude: 0.3, bright: true),
            SynthPart(start: 100, end: 115, chords: [Chord.dm, Chord.e], amplitude: 0.15),
            SynthPart(start: 115, end: 135, chords: [Chord.c, Chord.g], amplitude: 0.3, bright: true),
            SynthPart(start: 135, end: 150, chords: [Chord.c], amplitude: 0.03),
        ], duration: 150)
        let highlight = try #require(audioHighlight(song, duration: 150))
        #expect(highlight.basis == .audio)
        #expect(abs(highlight.start - 35) <= 1.5, "starts at \(highlight.start)")
        #expect(abs(highlight.end - 55) <= 1.5, "ends at \(highlight.end)")
    }

    @Test func aLoudBridgeThatNeverReturnsIsNotTheChorus() throws {
        let song = synthesize([
            SynthPart(start: 0, end: 12, chords: [Chord.c], amplitude: 0.04),
            SynthPart(start: 12, end: 35, chords: [Chord.am, Chord.f], amplitude: 0.1),
            SynthPart(start: 35, end: 55, chords: [Chord.c, Chord.g], amplitude: 0.25, bright: true),
            SynthPart(start: 55, end: 80, chords: [Chord.am, Chord.f], amplitude: 0.1),
            SynthPart(start: 80, end: 100, chords: [Chord.c, Chord.g], amplitude: 0.25, bright: true),
            // Louder than any chorus, but heard once.
            SynthPart(start: 100, end: 120, chords: [Chord.dm, Chord.e], amplitude: 0.4, bright: true),
            SynthPart(start: 120, end: 140, chords: [Chord.c, Chord.g], amplitude: 0.25, bright: true),
            SynthPart(start: 140, end: 150, chords: [Chord.c], amplitude: 0.03),
        ], duration: 150)
        let highlight = try #require(audioHighlight(song, duration: 150))
        #expect(highlight.end <= 101 || highlight.start >= 119, "\(highlight.start)–\(highlight.end)")
        #expect(abs(highlight.start - 35) <= 1.5, "starts at \(highlight.start)")
    }

    @Test func aChorusOnTheVerseChordsIsFoundByItsLevel() throws {
        let loop = [Chord.c, Chord.g, Chord.am, Chord.f]
        let song = synthesize([
            SynthPart(start: 0, end: 12, chords: [Chord.c], amplitude: 0.04),
            SynthPart(start: 12, end: 40, chords: loop, amplitude: 0.08),
            SynthPart(start: 40, end: 62, chords: loop, amplitude: 0.3, bright: true),
            SynthPart(start: 62, end: 90, chords: loop, amplitude: 0.08),
            SynthPart(start: 90, end: 112, chords: loop, amplitude: 0.3, bright: true),
            SynthPart(start: 112, end: 128, chords: [Chord.dm, Chord.bb], amplitude: 0.35, bright: true),
            SynthPart(start: 128, end: 150, chords: loop, amplitude: 0.3, bright: true),
            SynthPart(start: 150, end: 165, chords: [Chord.c], amplitude: 0.03),
        ], duration: 165)
        let highlight = try #require(audioHighlight(song, duration: 165))
        #expect(abs(highlight.start - 40) <= 2, "starts at \(highlight.start)")
        #expect(abs(highlight.end - 62) <= 2, "ends at \(highlight.end)")
    }

    @Test func shortAudioFindsNothing() {
        let features = MedleyAudioFeatures(
            frameDuration: 0.5,
            chroma: [Float](repeating: 0, count: 60 * 12),
            loudness: [Float](repeating: -20, count: 60)
        )
        #expect(MedleyAudioHighlightDetector.highlight(in: features, duration: 30) == nil)
    }
}

@Suite struct MedleyAutomaticSegmentTests {
    private let chorus = MedleyHighlight(start: 60, end: 90, basis: .audio)

    @Test func automaticSliceReachesAcrossTheChorus() {
        let slice = MedleySegmentPolicy.segment(duration: 240, length: .automatic, highlight: chorus)
        #expect(slice == MedleySegment(start: 56, end: 94))
        let opening = MedleySegmentPolicy.segment(
            duration: 240, length: .automatic, highlight: chorus, leadsIn: false
        )
        #expect(opening == MedleySegment(start: 60, end: 94))
    }

    @Test func automaticWithoutHighlightPlaysThirtySecondsAThirdIn() {
        let slice = MedleySegmentPolicy.segment(duration: 240, length: .automatic, highlight: nil)
        #expect(slice == MedleySegment(start: 79, end: 109))
        let tooShort = MedleyHighlight(start: 60, end: 63, basis: .lyrics)
        #expect(MedleySegmentPolicy.segment(duration: 240, length: .automatic, highlight: tooShort) == slice)
    }

    @Test func shortSongsPlayWhole() {
        #expect(MedleySegmentPolicy.segment(duration: 45, length: .automatic, highlight: nil)
            == MedleySegment(start: 0, end: 45))
    }

    @Test func fixedLengthStartsAtTheChorus() {
        let slice = MedleySegmentPolicy.segment(duration: 240, length: .fixed(20), highlight: chorus)
        #expect(slice == MedleySegment(start: 56, end: 76))
        let late = MedleyHighlight(start: 225, end: 238, basis: .audio)
        #expect(MedleySegmentPolicy.segment(duration: 240, length: .fixed(30), highlight: late)
            == MedleySegment(start: 210, end: 240))
    }

    @Test func aPlaybackRangeIsPlayedExactly() {
        let range = AppliedSongPlaybackRange(start: 12, end: 200, songDuration: 240)
        #expect(MedleySegmentPolicy.segment(playbackRange: range) == MedleySegment(start: 12, end: 200))
    }

    @Test func choicesStartWithAutomatic() {
        #expect(MedleySegmentPolicy.segmentChoices.first == MedleySegmentPolicy.automaticSegmentChoice)
        #expect(MedleySegmentPolicy.sliceLength(automatic: true, seconds: 10) == .automatic)
        #expect(MedleySegmentPolicy.sliceLength(automatic: false, seconds: 25) == .fixed(20))
    }
}

@Suite struct MedleyHighlightRecordPolicyTests {
    private let found = MedleyHighlight(start: 40, end: 70, basis: .lyrics)

    @Test func recordFitsOnlyTheSameFile() {
        let record = MedleyHighlightRecord(songDuration: 200, highlight: found, includesAudio: false, includesLyrics: true)
        #expect(MedleyHighlightRecordPolicy.highlight(from: record, songDuration: 201) == found)
        #expect(MedleyHighlightRecordPolicy.highlight(from: record, songDuration: 210) == nil)
        var old = record
        old.version = 0
        #expect(MedleyHighlightRecordPolicy.highlight(from: old, songDuration: 200) == nil)
    }

    @Test func analysesAgainWhenMoreHasBecomeAvailable() {
        let lyricsOnly = MedleyHighlightRecord(songDuration: 200, highlight: found, includesAudio: false, includesLyrics: true)
        #expect(MedleyHighlightRecordPolicy.needsAnalysis(nil, songDuration: 200, audioAvailable: false, lyricsAvailable: false))
        #expect(!MedleyHighlightRecordPolicy.needsAnalysis(lyricsOnly, songDuration: 200, audioAvailable: false, lyricsAvailable: true))
        #expect(MedleyHighlightRecordPolicy.needsAnalysis(lyricsOnly, songDuration: 200, audioAvailable: true, lyricsAvailable: true))
        let nothing = MedleyHighlightRecord(songDuration: 200, highlight: nil, includesAudio: true, includesLyrics: false)
        #expect(!MedleyHighlightRecordPolicy.needsAnalysis(nothing, songDuration: 200, audioAvailable: true, lyricsAvailable: false))
        #expect(MedleyHighlightRecordPolicy.needsAnalysis(nothing, songDuration: 200, audioAvailable: true, lyricsAvailable: true))
    }

    @Test func evictsTheOldestAnalyses() {
        var records: [String: MedleyHighlightRecord] = [:]
        for index in 0..<5 {
            records["s\(index)"] = MedleyHighlightRecord(
                songDuration: 200, highlight: nil, includesAudio: true, includesLyrics: false,
                analyzedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        #expect(Set(MedleyHighlightRecordPolicy.evictedIDs(records, limit: 3)) == ["s0", "s1"])
        #expect(MedleyHighlightRecordPolicy.evictedIDs(records, limit: 10).isEmpty)
    }
}
