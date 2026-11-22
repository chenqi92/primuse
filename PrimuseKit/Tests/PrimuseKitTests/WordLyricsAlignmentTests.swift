import Foundation
import Testing
@testable import PrimuseKit

@Suite("Unified word lyrics alignment")
struct WordLyricsAlignmentTests {
    static let sampleRate = 16_000.0

    /// Synthesises a clean singing-like mono track with arbitrary per-note start/end,
    /// pitches, vibrato depth and optional background noise.
    static func synthesizeSinging(
        duration: TimeInterval,
        notes: [(start: TimeInterval, end: TimeInterval, freq: Double, amp: Double, vibratoSemitones: Double)],
        noiseAmp: Double = 0.002
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: count)
        var rng: UInt64 = 42
        for i in 0..<count {
            rng = rng &* 6364136223846793005 &+ 1
            let n = Double(Int64(bitPattern: rng >> 11) % 2_000 - 1_000) / 1_000.0
            out[i] = Float(n * noiseAmp)
        }
        for note in notes {
            let sIdx = max(0, Int(note.start * sampleRate))
            let eIdx = min(count, Int(note.end * sampleRate))
            guard eIdx > sIdx else { continue }
            var phase = 0.0
            for i in sIdx..<eIdx {
                let localT = Double(i - sIdx) / sampleRate
                let remain = Double(eIdx - i) / sampleRate
                let attack = min(1.0, localT / 0.015)
                let release = min(1.0, remain / 0.025)
                let vibratoRatio = note.vibratoSemitones > 0
                    ? pow(2.0, (note.vibratoSemitones * sin(2 * Double.pi * 5.5 * localT)) / 12.0)
                    : 1.0
                let instFreq = note.freq * vibratoRatio
                phase += 2 * Double.pi * instFreq / sampleRate
                let wave = sin(phase) + 0.45 * sin(2 * phase) + 0.20 * sin(3 * phase)
                out[i] += Float(note.amp * attack * release * wave)
            }
        }
        return out
    }

    // MARK: - Unit Splitter & Prosody Fallback

    @Test("Unified splitter preserves verbatim text, attaches punctuation and estimates mixed syllables")
    func unitSplitterHandlesPunctuationAndMixedScripts() {
        let text = "（我）love，beautiful 世界！コーヒー"
        let units = WordTimingUnitSplitter.units(of: text)
        #expect(units.map(\.text).joined() == text)
        // Punctuation never becomes an orphan unit; Japanese prolonged mark stays attached.
        #expect(units.map(\.text) == ["（我）", "love，", "beautiful ", "世", "界！", "コー", "ヒー"])
        #expect(units[1].trailingPauseWeight > 0.4)
        // English 1-syllable "love" weighs near 1.0 (not 4.0 like raw char count).
        #expect(abs(units[1].syllableWeight - 1.0) < 0.2)
        // 3-syllable "beautiful" weighs ~2.7 (not 9.0).
        #expect(units[2].syllableWeight > 2.0 && units[2].syllableWeight < 3.2)
        // Japanese prolonged sound mark increases unit duration weight.
        #expect(units[5].syllableWeight > 1.5)
    }

    @Test("Prosody sweep inserts comma rests and caps long inferred instrumental gaps")
    func prosodySweepHandlesPausesAndLongGaps() throws {
        let line = LyricLine(id: "p", timestamp: 10, text: "快走，别回头")
        let window = KaraokeLineWindow(lineIndex: 0, lineID: "p", voice: .primary, start: 10, end: 18, hasExplicitEnd: false)
        let swept = ProsodySweepAligner.sweepLine(line, window: window)
        let syllables = try #require(swept.syllables)
        #expect(syllables.count == 5)
        #expect(syllables.map(\.text).joined() == line.text)
        // Visible rest between "走，" and "别".
        #expect(syllables[2].start > syllables[1].end + 0.10)
        // Does not stretch a 5-char line across 7.36 seconds of silence.
        #expect((syllables.last?.end ?? 0) < 16.5)
    }

    // MARK: - Upgraded Pure-DSP Alignment (Fast/Slow Rhythm, Tail Silence, Quiet Verse, Vibrato)

    @Test("DSP aligner tracks extreme fast-then-slow rhythm with long trailing silence")
    func dspAlignerTracksFastThenSlowRhythm() throws {
        // 4 rapid 150 ms syllables (0.20, 0.35, 0.50, 0.65) followed by 2 slow held syllables (0.85, 1.75)
        // and 2.5 seconds of trailing instrumental silence inside a 5.2 s LRC window!
        let truthStarts: [TimeInterval] = [0.20, 0.35, 0.50, 0.65, 0.85, 1.75]
        let notes: [(TimeInterval, TimeInterval, Double, Double, Double)] = [
            (0.20, 0.34, 261.6, 0.30, 0),
            (0.35, 0.49, 293.7, 0.30, 0),
            (0.50, 0.64, 329.6, 0.30, 0),
            (0.65, 0.83, 349.2, 0.30, 0),
            (0.85, 1.70, 392.0, 0.32, 0.35), // sustained note with vibrato!
            (1.75, 2.75, 440.0, 0.32, 0.40), // long final held note with vibrato!
        ]
        let audio = Self.synthesizeSinging(duration: 5.5, notes: notes)
        let profile = VocalAcousticProfile.analyze(samples: audio, sampleRate: Self.sampleRate)

        let line = LyricLine(id: "fs", timestamp: 0.20, text: "快快快快慢慢")
        let window = KaraokeLineWindow(lineIndex: 0, lineID: "fs", voice: .primary, start: 0.20, end: 5.20)
        let aligned = try #require(AudioWordTimingAligner.alignLine(line, window: window, profile: profile))
        let syllables = try #require(aligned.syllables)
        #expect(syllables.count == 6)

        // Compare MAE against naive uniform spread.
        let mae = zip(syllables.map(\.start), truthStarts).map { abs($0 - $1) }.reduce(0, +) / 6.0
        #expect(mae < 0.06, "Expected DSP MAE < 60ms on fast-slow line, got \(mae)s: \(syllables.map(\.start))")
        // Final syllable ends near actual vocal decay (~2.75 s), NOT dragged to 4.8 s!
        let lastEnd = try #require(syllables.last?.end)
        #expect(lastEnd > 2.4 && lastEnd < 3.2, "Unexpected last end: \(lastEnd)")
        #expect(syllables.allSatisfy { $0.endTiming == .explicit })
    }

    @Test("DSP aligner tracks slow-then-fast rhythm across mid-line breath pause")
    func dspAlignerTracksSlowThenFastWithPause() throws {
        // Two slow syllables, a 0.6 s silence breath, then 4 quick syllables.
        let truthStarts: [TimeInterval] = [0.30, 1.10, 2.30, 2.48, 2.66, 2.84]
        let notes: [(TimeInterval, TimeInterval, Double, Double, Double)] = [
            (0.30, 1.05, 220.0, 0.30, 0),
            (1.10, 1.70, 246.9, 0.30, 0),
            // 1.70 -> 2.30 silence breath!
            (2.30, 2.46, 293.7, 0.30, 0),
            (2.48, 2.64, 329.6, 0.30, 0),
            (2.66, 2.82, 349.2, 0.30, 0),
            (2.84, 3.25, 392.0, 0.30, 0),
        ]
        let audio = Self.synthesizeSinging(duration: 4.0, notes: notes)
        let profile = VocalAcousticProfile.analyze(samples: audio, sampleRate: Self.sampleRate)

        let line = LyricLine(id: "sf", timestamp: 0.30, text: "慢着，突然加快")
        let window = KaraokeLineWindow(lineIndex: 0, lineID: "sf", voice: .primary, start: 0.30, end: 3.80)
        let aligned = try #require(AudioWordTimingAligner.alignLine(line, window: window, profile: profile))
        let syllables = try #require(aligned.syllables)
        #expect(syllables.count == 6)

        let mae = zip(syllables.map(\.start), truthStarts).map { abs($0 - $1) }.reduce(0, +) / 6.0
        #expect(mae < 0.07, "Expected MAE < 70ms on slow-then-fast line, got \(mae)s: \(syllables.map(\.start))")
        // Pause before "突" leaves visible gap (ends near 1.70, next starts near 2.30).
        #expect(syllables[1].end < syllables[2].start - 0.25)
    }

    @Test("Local adaptive thresholding detects quiet verse onsets even next to a loud chorus")
    func localAdaptiveThresholdHandlesDynamicContrast() throws {
        // Quiet verse at 0.04 amp followed by loud chorus at 0.60 amp (15x louder!).
        let notes: [(TimeInterval, TimeInterval, Double, Double, Double)] = [
            (0.30, 0.55, 220, 0.04, 0),
            (0.60, 0.85, 247, 0.04, 0),
            (0.90, 1.15, 262, 0.04, 0),
            (1.20, 1.50, 294, 0.04, 0),
            // Loud chorus far louder than verse:
            (3.00, 3.40, 440, 0.60, 0),
            (3.45, 3.85, 494, 0.60, 0),
        ]
        let audio = Self.synthesizeSinging(duration: 4.5, notes: notes, noiseAmp: 0.0005)
        let profile = VocalAcousticProfile.analyze(samples: audio, sampleRate: Self.sampleRate)
        let verseOnsets = profile.onsets.filter { $0.time >= 0.2 && $0.time <= 1.5 }
        #expect(verseOnsets.count >= 4, "Quiet verse onsets should not be suppressed by loud chorus: \(verseOnsets.map(\.time))")
    }

    // MARK: - Window-Constrained CTC Forced Alignment

    @Test("CTC forced aligner locks fast/slow phoneme spikes, repeated tokens, OOV wildcards and sustained vocal tails")
    func ctcForcedAlignerHandlesFastSlowRepeatedOOVAndTails() throws {
        // Vocabulary: blank=0, 你=1, 好=2, 啦=3 (repeated!), 慢=4 ("罕" is intentionally OOV!)
        let vocab = CTCLyricsVocabulary(
            idByPiece: ["<blk>": 0, "你": 1, "好": 2, "啦": 3, "慢": 4],
            blankID: 0,
            unknownID: 99,
            wordBoundaryToken: nil,
            lowercaseInput: true
        )
        let frameDuration = 0.02
        let frameCount = 200 // 4.0 s total
        let tokenIDs = [0, 1, 2, 3, 4]
        var logProbs = [Float](repeating: -12.0, count: frameCount * tokenIDs.count)

        // Default every frame to blank high probability.
        for f in 0..<frameCount {
            logProbs[f * tokenIDs.count + 0] = -0.05
        }
        func spike(frame: Int, col: Int) {
            logProbs[frame * tokenIDs.count + 0] = -8.0
            logProbs[frame * tokenIDs.count + col] = -0.05
        }

        // Fast cluster: "你" at 0.20s (f=10), "好" at 0.34s (f=17), "啦" at 0.48s (f=24), repeated "啦" at 0.62s (f=31)
        // Then OOV "罕" sits between 0.62s and 1.80s, and slow held "慢" starts at 1.80s (f=90) and vocal sustains until 2.90s!
        spike(frame: 10, col: 1)
        spike(frame: 17, col: 2)
        spike(frame: 24, col: 3)
        spike(frame: 31, col: 3) // consecutive identical token requires intervening blank
        spike(frame: 90, col: 4)

        let emissions = CTCEmissionSlice(
            startTime: 0,
            frameDuration: frameDuration,
            frameOffset: 0.01,
            frameCount: frameCount,
            blankID: 0,
            tokenIDs: tokenIDs,
            logProbs: logProbs
        )

        // Synthesise sustained vocal energy for "慢" until 2.90 s, then silence until 3.80 s.
        let audio = Self.synthesizeSinging(
            duration: 4.0,
            notes: [
                (0.20, 0.33, 260, 0.3, 0),
                (0.34, 0.47, 290, 0.3, 0),
                (0.48, 0.61, 320, 0.3, 0),
                (0.62, 1.75, 340, 0.3, 0),
                (1.80, 2.90, 392, 0.35, 0),
            ]
        )
        let profile = VocalAcousticProfile.analyze(samples: audio, sampleRate: Self.sampleRate)

        let line = LyricLine(id: "ctc1", timestamp: 0.20, text: "你好啦啦罕慢")
        let window = KaraokeLineWindow(lineIndex: 0, lineID: "ctc1", voice: .primary, start: 0.20, end: 3.80)
        let outcome = try #require(CTCForcedAligner.alignLine(
            line,
            window: window,
            vocabulary: vocab,
            emissions: emissions,
            profile: profile
        ))

        #expect(outcome.usedCTC)
        #expect(outcome.syllables.count == 6)
        #expect(outcome.syllables.map(\.text).joined() == line.text)
        #expect(abs(outcome.syllables[0].start - 0.21) < 0.03)
        #expect(abs(outcome.syllables[1].start - 0.35) < 0.03)
        #expect(abs(outcome.syllables[2].start - 0.49) < 0.03)
        #expect(abs(outcome.syllables[3].start - 0.63) < 0.03)
        // OOV wildcard "罕" smoothly interpolated between 0.63 s and 1.81 s.
        #expect(outcome.syllables[4].start > 0.70 && outcome.syllables[4].start < 1.70)
        #expect(abs(outcome.syllables[5].start - 1.81) < 0.03)
        // CTC peak at 1.81s extended across the actual held vowel until ~2.90s (not collapsed to 1.83s, not dragged to 3.8s!).
        #expect(outcome.syllables[5].end > 2.60 && outcome.syllables[5].end < 3.20)
    }

    @Test("CTC aligner falls back cleanly when emission confidence collapses")
    func ctcFallsBackOnLowConfidence() throws {
        let vocab = CTCLyricsVocabulary(idByPiece: ["<blk>": 0, "a": 1, "b": 2], blankID: 0)
        let tokenIDs = [0, 1, 2]
        // Completely flat ultra-low probabilities (-25) for target tokens.
        var logProbs = [Float](repeating: -25.0, count: 100 * 3)
        for f in 0..<100 { logProbs[f * 3] = -0.01 }
        let emissions = CTCEmissionSlice(
            startTime: 0, frameDuration: 0.02, frameCount: 100, blankID: 0, tokenIDs: tokenIDs, logProbs: logProbs
        )
        let line = LyricLine(id: "low", timestamp: 0.1, text: "a b")
        let window = KaraokeLineWindow(lineIndex: 0, lineID: "low", voice: .primary, start: 0.1, end: 1.9)
        let outcome = try #require(CTCForcedAligner.alignLine(line, window: window, vocabulary: vocab, emissions: emissions))
        #expect(!outcome.usedCTC)
        #expect(outcome.syllables.map(\.text).joined() == "a b")
    }

    // MARK: - Chunk Planning, Overlay & Live Merge

    @Test("Chunk planner prioritizes the playhead chunk first")
    func chunkPlannerPrioritizesPlayhead() {
        let windows = (0..<12).map { i in
            KaraokeLineWindow(
                lineIndex: i,
                lineID: "l\(i)",
                voice: .primary,
                start: Double(i) * 5.0,
                end: Double(i + 1) * 5.0
            )
        }
        let plan = CTCChunkPlan.make(windows: windows, chunkDuration: 20.0, prioritizing: 32.0)
        #expect(plan.chunks.count >= 3)
        #expect(plan.chunks[0].startTime <= 32.0 && plan.chunks[0].endTime >= 32.0)
        let allIndices = plan.chunks.flatMap(\.windowIndices).sorted()
        #expect(allIndices == Array(0..<12))
    }

    @Test("Live merge freezes the line currently mid-flight while immediately upgrading upcoming lines")
    func liveMergePreventsBackwardJumpOnActiveLine() {
        let oldLines = [
            LyricLine(id: "l1", timestamp: 10, text: "一二", syllables: [
                LyricSyllable(text: "一", start: 10.0, end: 11.0, endTiming: .inferred),
                LyricSyllable(text: "二", start: 11.0, end: 12.0, endTiming: .inferred),
            ]),
            LyricLine(id: "l2", timestamp: 12, text: "三四", syllables: [
                LyricSyllable(text: "三", start: 12.0, end: 13.0, endTiming: .inferred),
                LyricSyllable(text: "四", start: 13.0, end: 14.0, endTiming: .inferred),
            ]),
        ]
        let newLines = [
            LyricLine(id: "l1", timestamp: 10, text: "一二", syllables: [
                LyricSyllable(text: "一", start: 10.0, end: 10.3, endTiming: .explicit),
                LyricSyllable(text: "二", start: 10.3, end: 11.8, endTiming: .explicit),
            ]),
            LyricLine(id: "l2", timestamp: 12, text: "三四", syllables: [
                LyricSyllable(text: "三", start: 12.0, end: 12.2, endTiming: .explicit),
                LyricSyllable(text: "四", start: 12.2, end: 13.9, endTiming: .explicit),
            ]),
        ]
        let merged = WordLyricsLiveMergePolicy.merge(
            displayed: oldLines,
            updated: newLines,
            playbackTime: 10.8,
            isPlaying: true
        )
        // Line 1 is mid-flight at 10.8s -> stays stable.
        #expect(merged[0] == oldLines[0])
        // Upcoming line 2 upgrades immediately!
        #expect(merged[1] == newLines[1])
    }

    @Test func hidingCompanionsDuringAWordKeepsOnlyThePreviousWordTiming() {
        let old = LyricLine(id: "paper", timestamp: 2, text: "纸帆", syllables: [
            .init(text: "纸", start: 2, end: 2.8), .init(text: "帆", start: 2.8, end: 3),
        ], manualTranslation: .init(text: "Paper sail", source: .embeddedField), romanization: "zhi fan")
        var updated = old
        updated.syllables = [.init(text: "纸帆", start: 2, end: 3.1)]
        updated.manualTranslation = nil
        updated.romanization = nil
        let result = WordLyricsLiveMergePolicy.merge(displayed: [old], updated: [updated], playbackTime: 2.4, isPlaying: true)
        #expect(result.first?.syllables == old.syllables)
        #expect(result.first?.manualTranslation == nil)
        #expect(result.first?.romanization == nil)
    }

    @Test("Unified overlay integrates consistently with SimulatedWordLyricsPolicy and KaraokeLyricsSnapshot")
    func overlayConsistencyAcrossPolicies() throws {
        let raw = [
            LyricLine(id: "row1", timestamp: 1.0, text: "你好世界"),
            LyricLine(id: "row2", timestamp: 5.0, text: "hello world"),
        ]
        let customSyllables = [
            LyricSyllable(text: "你", start: 1.0, end: 1.15, endTiming: .explicit),
            LyricSyllable(text: "好", start: 1.15, end: 1.30, endTiming: .explicit),
            LyricSyllable(text: "世", start: 1.30, end: 2.10, endTiming: .explicit),
            LyricSyllable(text: "界", start: 2.10, end: 3.40, endTiming: .explicit),
        ]
        let overlay = WordLyricsTimingOverlay(
            tier: .ctcVocal,
            lyricsFingerprint: WordLyricsTimingOverlay.fingerprint(for: raw),
            syllablesByLineID: ["row1": customSyllables]
        )

        let nowPlaying = SimulatedWordLyricsPolicy.presentation(of: raw, enabled: true, overlay: overlay)
        let karaoke = KaraokeLyricsSnapshot(lines: raw, overlay: overlay)

        #expect(nowPlaying.isSimulated)
        #expect(nowPlaying.tier == .ctcVocal)
        #expect(karaoke.usesInferredWordTiming)
        // Row 1 uses identical CTC timing in both Now Playing and Karaoke; row 2 uses identical prosody fallback!
        #expect(nowPlaying.lines[0].syllables == customSyllables)
        #expect(karaoke.lines[0].syllables == customSyllables)
        #expect(nowPlaying.lines[1].syllables == karaoke.lines[1].syllables)
    }
}
