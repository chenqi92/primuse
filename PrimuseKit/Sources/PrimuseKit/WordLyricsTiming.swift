import Foundation

/// Quality tier of simulated word-level timing. Strictly ordered so background
/// jobs only upgrade an existing overlay and never downgrade it.
public enum WordTimingTier: Int, Codable, Comparable, Hashable, Sendable {
    /// Text-only prosody estimation (instant, zero audio dependency).
    case textProsody = 0
    /// Pure DSP singing alignment (VAD + multi-feature onset + pairwise DP) on mixed audio.
    case audioDSP = 1
    /// Pure DSP singing alignment on a separated vocal stem.
    case audioDSPVocal = 2
    /// On-device Core ML CTC forced alignment on center-enhanced mixed audio.
    case ctcMix = 3
    /// On-device Core ML CTC forced alignment on a separated vocal stem.
    case ctcVocal = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var isAudioBacked: Bool { self >= .audioDSP }
    public var usesCTCModel: Bool { self >= .ctcMix }
}

/// Display-only word timing produced for line-level lyrics. Stored separately
/// from source lyrics so editing, export and native word-timed documents stay untouched.
public struct WordLyricsTimingOverlay: Equatable, Codable, Sendable {
    /// Bumped whenever the unified alignment algorithm changes incompatibly.
    public static let currentEngineVersion = "word-align-v2"

    public var tier: WordTimingTier
    public var engineVersion: String
    public var lyricsFingerprint: String
    public var syllablesByLineID: [String: [LyricSyllable]]
    /// True while only a priority window around the current playhead has finished.
    public var isPartial: Bool

    public init(
        tier: WordTimingTier,
        engineVersion: String = Self.currentEngineVersion,
        lyricsFingerprint: String,
        syllablesByLineID: [String: [LyricSyllable]],
        isPartial: Bool = false
    ) {
        self.tier = tier
        self.engineVersion = engineVersion
        self.lyricsFingerprint = lyricsFingerprint
        self.syllablesByLineID = syllablesByLineID
        self.isPartial = isPartial
    }

    /// Deterministic FNV-1a 64-bit fingerprint over synchronized non-empty lines so
    /// editing timestamps or lyric text invalidates stale cached alignments.
    public static func fingerprint(for lines: [LyricLine]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x00000100000001b3
        @inline(__always)
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= prime
            }
        }
        @inline(__always)
        func mixInt(_ value: Int64) {
            var v = UInt64(bitPattern: value)
            for _ in 0..<8 {
                hash ^= v & 0xff
                hash &*= prime
                v >>= 8
            }
        }
        for line in lines where line.isSynchronized {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            mix(line.id.utf8)
            mix([0x1f])
            mixInt(Int64((line.timestamp * 1000).rounded()))
            mixInt(line.endTime.map { Int64(($0 * 1000).rounded()) } ?? -1)
            mix(line.text.utf8)
            mix([0x1e])
        }
        return String(format: "%016llx", hash)
    }

    /// Merges newly aligned lines onto an earlier partial/lower-tier overlay.
    public func merging(_ newer: WordLyricsTimingOverlay) -> WordLyricsTimingOverlay {
        guard newer.lyricsFingerprint == lyricsFingerprint else { return newer }
        var combined = syllablesByLineID
        for (lineID, syllables) in newer.syllablesByLineID {
            combined[lineID] = syllables
        }
        return WordLyricsTimingOverlay(
            tier: max(tier, newer.tier),
            engineVersion: newer.engineVersion,
            lyricsFingerprint: lyricsFingerprint,
            syllablesByLineID: combined,
            isPartial: newer.isPartial
        )
    }

    /// Applies valid aligned syllables to line-level rows. Native word-timed rows
    /// and rows whose text no longer matches are left untouched.
    public func syllables(for line: LyricLine) -> [LyricSyllable]? {
        guard line.syllables?.isEmpty ?? true,
              let aligned = syllablesByLineID[line.id],
              !aligned.isEmpty,
              aligned.map(\.text).joined() == line.text else {
            return nil
        }
        return aligned
    }
}

/// Manifest bundled inside the Apple-hosted `LyricsAlignmentModel` Background Assets pack.
public struct WordLyricsAlignmentManifest: Equatable, Codable, Sendable {
    public var version: String
    public var model: String
    public var vocabulary: String
    public var sampleRate: Double
    public var chunkSamples: Int
    public var frameStrideSamples: Int
    public var frameOffsetSeconds: Double
    public var blankID: Int
    public var unknownID: Int
    public var wordBoundaryToken: String?
    public var lowercaseInput: Bool
    /// Preferred compute units ("cpuAndGPU", "cpuOnly", "all").
    public var preferredComputeUnits: String?

    public init(
        version: String,
        model: String = "LyricsAlignmentCTC.mlmodelc",
        vocabulary: String = "vocab.json",
        sampleRate: Double = 16_000,
        chunkSamples: Int = 320_000,
        frameStrideSamples: Int = 320,
        frameOffsetSeconds: Double = 0.01,
        blankID: Int = 0,
        unknownID: Int = 3,
        wordBoundaryToken: String? = "\u{2581}",
        lowercaseInput: Bool = true,
        preferredComputeUnits: String? = "cpuAndGPU"
    ) {
        self.version = version
        self.model = model
        self.vocabulary = vocabulary
        self.sampleRate = sampleRate
        self.chunkSamples = chunkSamples
        self.frameStrideSamples = frameStrideSamples
        self.frameOffsetSeconds = frameOffsetSeconds
        self.blankID = blankID
        self.unknownID = unknownID
        self.wordBoundaryToken = wordBoundaryToken
        self.lowercaseInput = lowercaseInput
        self.preferredComputeUnits = preferredComputeUnits
    }

    public var frameDuration: TimeInterval {
        guard sampleRate > 0, frameStrideSamples > 0 else { return 0.02 }
        return Double(frameStrideSamples) / sampleRate
    }

    public var chunkDuration: TimeInterval {
        guard sampleRate > 0, chunkSamples > 0 else { return 20 }
        return Double(chunkSamples) / sampleRate
    }

    public var requiredFiles: [String] { [vocabulary] }

    public static func decode(_ data: Data) -> WordLyricsAlignmentManifest? {
        guard let manifest = try? JSONDecoder().decode(Self.self, from: data),
              !manifest.version.isEmpty,
              !manifest.model.isEmpty,
              !manifest.vocabulary.isEmpty,
              manifest.sampleRate > 0,
              manifest.chunkSamples > 0,
              manifest.frameStrideSamples > 0 else {
            return nil
        }
        return manifest
    }
}

/// Unified lyric text tokenizer shared by Now Playing, Karaoke Stage and Immersive Kinetic lyrics.
///
/// Guarantees:
/// - `units(of: text).map(\.text).joined() == text` always holds.
/// - Ideographs (CJK / Kana / Hangul) split per sung syllable; prolonged sound marks (`ー`)
///   and punctuation stay attached to the preceding unit rather than stealing a full beat.
/// - Latin/alphabetic words keep internal apostrophes/hyphens (`don't`, `self-made`) and carry
///   estimated syllable counts instead of raw character counts.
public enum WordTimingUnitSplitter {
    public struct Unit: Equatable, Sendable {
        /// Exact substring of the original line (including attached punctuation and trailing whitespace).
        public var text: String
        /// Pronounced core without surrounding punctuation or whitespace.
        public var coreText: String
        /// Relative sung duration weight (~1.0 per single CJK character or English syllable).
        public var syllableWeight: Double
        /// Relative pause/breath weight after this unit (comma/clause break/CJK space gap).
        public var trailingPauseWeight: Double
        public var isIdeographic: Bool

        public init(
            text: String,
            coreText: String,
            syllableWeight: Double,
            trailingPauseWeight: Double,
            isIdeographic: Bool
        ) {
            self.text = text
            self.coreText = coreText
            self.syllableWeight = syllableWeight
            self.trailingPauseWeight = trailingPauseWeight
            self.isIdeographic = isIdeographic
        }
    }

    public static func units(of text: String) -> [Unit] {
        guard !text.isEmpty else { return [] }
        let pieces = splitPieces(of: text)
        guard !pieces.isEmpty else { return [] }

        var result: [Unit] = []
        result.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() {
            let isLast = index == pieces.count - 1
            let core = extractCore(from: piece)
            let ideographic = core.first.map(isIdeographicUnit) ?? false
            let prolongationCount = piece.unicodeScalars.filter { $0.value == 0x30FC }.count
            let baseSyllables = estimateSyllables(core: core, isIdeographic: ideographic)
            let syllableWeight = baseSyllables + Double(prolongationCount) * 0.65
            let pauseWeight = isLast ? 0 : trailingPauseWeight(of: piece, isIdeographic: ideographic)
            result.append(Unit(
                text: piece,
                coreText: core,
                syllableWeight: max(0.6, syllableWeight),
                trailingPauseWeight: pauseWeight,
                isIdeographic: ideographic
            ))
        }
        return result
    }

    /// Raw text slices preserving every character verbatim.
    public static func splitPieces(of text: String) -> [String] {
        var pieces: [String] = []
        var pendingPrefix = ""
        var current = ""
        var currentIsWord = false
        var joinsNextWordChar = false

        func flushCurrent() {
            guard !current.isEmpty else { return }
            pieces.append(current)
            current = ""
            currentIsWord = false
        }

        for character in text {
            if joinsNextWordChar, isWordCharacter(character), !pieces.isEmpty {
                pieces[pieces.count - 1].append(character)
                joinsNextWordChar = false
                continue
            }
            joinsNextWordChar = false

            // Japanese prolonged sound mark (`ー`) and combining marks stay attached to previous unit.
            if isTrailingAttachment(character) {
                if !current.isEmpty {
                    current.append(character)
                } else if !pieces.isEmpty {
                    pieces[pieces.count - 1].append(character)
                } else {
                    pendingPrefix.append(character)
                }
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    current.append(character)
                    flushCurrent()
                } else if !pieces.isEmpty {
                    pieces[pieces.count - 1].append(character)
                } else {
                    pendingPrefix.append(character)
                }
                continue
            }

            if isIdeographicUnit(character) {
                flushCurrent()
                pieces.append(pendingPrefix + String(character))
                pendingPrefix = ""
                continue
            }

            if isWordCharacter(character) {
                if !current.isEmpty, !currentIsWord {
                    flushCurrent()
                }
                if !pendingPrefix.isEmpty {
                    current.append(pendingPrefix)
                    pendingPrefix = ""
                }
                current.append(character)
                currentIsWord = true
                continue
            }

            // Inner apostrophe or hyphen inside a Latin word keeps the word intact (`don't`, `self-made`).
            if isInnerWordJoiner(character), !current.isEmpty, currentIsWord {
                current.append(character)
                continue
            }
            if isInnerWordJoiner(character), current.isEmpty, let last = pieces.last,
               let lastCore = last.last, isWordCharacter(lastCore) {
                pieces[pieces.count - 1].append(character)
                joinsNextWordChar = true
                continue
            }

            // Leading opening brackets/quotes attach to the following unit; all other punctuation
            // attaches to the preceding unit so punctuation never becomes an orphan sung word.
            if isOpeningPunctuation(character) {
                flushCurrent()
                pendingPrefix.append(character)
                continue
            }

            if !current.isEmpty {
                current.append(character)
                flushCurrent()
            } else if !pieces.isEmpty {
                pieces[pieces.count - 1].append(character)
            } else {
                pendingPrefix.append(character)
            }
        }

        flushCurrent()
        if !pendingPrefix.isEmpty {
            if !pieces.isEmpty {
                pieces[pieces.count - 1] += pendingPrefix
            } else {
                pieces.append(pendingPrefix)
            }
        }
        return pieces
    }

    public static func isIdeographicUnit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x309F, // Hiragana
             0x30A0...0x30FB, // Katakana (excluding 0x30FC prolonged sound mark)
             0x30FD...0x30FF,
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK Compatibility
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func isTrailingAttachment(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x30FC, // Katakana-Hiragana prolonged sound mark ー
             0x3099, 0x309A: // Combining dakuten/handakuten
            return true
        default:
            return false
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        !isIdeographicUnit(character) && (character.isLetter || character.isNumber)
    }

    private static func isInnerWordJoiner(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "-"
    }

    private static func isOpeningPunctuation(_ character: Character) -> Bool {
        switch character {
        case "(", "[", "{", "（", "【", "「", "『", "《", "〈", "“", "‘", "«", "¡", "¿":
            return true
        default:
            return false
        }
    }

    private static func extractCore(from piece: String) -> String {
        String(piece.filter { $0.isLetter || $0.isNumber || isIdeographicUnit($0) })
    }

    /// Estimates sung syllable count: 1.0 per CJK/Kana/Hangul character; vowel-cluster
    /// syllable estimation for Latin/alphabetic words so mixed-script lines keep balanced pacing.
    public static func estimateSyllables(core: String, isIdeographic: Bool) -> Double {
        guard !core.isEmpty else { return 1.0 }
        if isIdeographic {
            return Double(max(1, core.count))
        }
        let lower = core.lowercased()
        let isLatin = lower.unicodeScalars.allSatisfy { $0.value < 0x0250 }
        if !isLatin {
            // Cyrillic / Arabic / Devanagari / Thai: roughly 2.4 letters per syllable.
            return max(1.0, min(6.0, Double(core.count) / 2.4))
        }
        if lower.count <= 3 {
            return 1.0
        }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y", "á", "é", "í", "ó", "ú", "à", "è", "ì", "ò", "ù", "ä", "ë", "ï", "ö", "ü", "â", "ê", "î", "ô", "û"]
        var groups = 0
        var inVowel = false
        for char in lower {
            let v = vowels.contains(char)
            if v && !inVowel { groups += 1 }
            inVowel = v
        }
        // Silent trailing 'e' unless word ends in "-le" after consonant (e.g., "little").
        if lower.hasSuffix("e"), !lower.hasSuffix("le"), !lower.hasSuffix("ee"), groups > 1 {
            groups -= 1
        }
        // Slight compression (0.88 per extra syllable) matches natural English singing cadence vs CJK.
        let count = Double(max(1, min(6, groups)))
        return 1.0 + (count - 1.0) * 0.85
    }

    private static func trailingPauseWeight(of piece: String, isIdeographic: Bool) -> Double {
        var maxPause = 0.0
        for character in piece {
            switch character {
            case ".", "。", "!", "！", "?", "？", "…":
                maxPause = max(maxPause, 0.70)
            case ",", "，", "、", ";", "；", ":", "：", "—", "–":
                maxPause = max(maxPause, 0.48)
            default:
                break
            }
        }
        if maxPause == 0, isIdeographic, piece.last?.isWhitespace == true {
            // Explicit space between CJK/Kana characters usually marks a phrasing breath.
            maxPause = 0.25
        }
        return maxPause
    }
}

/// Upgraded Tier-0 (text-only) prosody sweep aligner: uses syllable counts,
/// inserts visible rests at commas/clause boundaries, applies a gentle final-note
/// hold, and caps inferred windows so short lines before long interludes do not crawl.
public enum ProsodySweepAligner {
    public static let minimumSpan: TimeInterval = 0.2
    /// Maximum reasonable singing duration per syllable when a row lacks an explicit end timestamp.
    public static let maxInferredSecondsPerSyllable: TimeInterval = 0.82
    public static let finalSyllableHoldFactor: Double = 1.18

    public static func sweepLine(_ line: LyricLine, window: KaraokeLineWindow) -> LyricLine {
        if let syllables = line.syllables, !syllables.isEmpty { return line }
        let units = WordTimingUnitSplitter.units(of: line.text)
        guard !units.isEmpty else { return line }

        let rawDuration = max(minimumSpan, window.end - window.start)
        let totalSyllableUnits = units.reduce(0.0) { $0 + $1.syllableWeight + $1.trailingPauseWeight }
        let span: TimeInterval
        if window.hasExplicitEnd {
            span = max(minimumSpan, rawDuration * 0.96)
        } else {
            let cap = max(1.8, totalSyllableUnits * maxInferredSecondsPerSyllable + 0.45)
            span = min(max(minimumSpan, rawDuration * 0.92), cap)
        }

        let unitWeights: [Double] = units.enumerated().map { index, unit in
            let hold = (index == units.count - 1 && units.count > 1) ? finalSyllableHoldFactor : 1.0
            return unit.syllableWeight * hold
        }
        let totalWeight = zip(unitWeights, units).reduce(0.0) { $0 + $1.0 + $1.1.trailingPauseWeight }
        guard totalWeight > 0 else { return line }

        var cursor = window.start
        var syllables: [LyricSyllable] = []
        syllables.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            let duration = max(0.03, span * unitWeights[index] / totalWeight)
            let pause = span * unit.trailingPauseWeight / totalWeight
            let end = min(window.end, cursor + duration)
            syllables.append(LyricSyllable(
                text: unit.text,
                start: cursor,
                end: max(cursor + 0.01, end),
                endTiming: .inferred
            ))
            cursor = min(window.end, cursor + duration + pause)
        }
        var result = line
        result.syllables = syllables
        return result
    }
}

/// Prevents jarring backward highlight jumps when background audio/CTC alignment
/// finishes while a line is already mid-flight on screen.
public enum WordLyricsLiveMergePolicy {
    public static func merge(
        displayed: [LyricLine],
        updated: [LyricLine],
        playbackTime: TimeInterval?,
        isPlaying: Bool
    ) -> [LyricLine] {
        guard isPlaying,
              let playbackTime,
              playbackTime.isFinite,
              displayed.count == updated.count else {
            return updated
        }
        var merged = updated
        for index in displayed.indices {
            let oldLine = displayed[index]
            let newLine = updated[index]
            guard oldLine.id == newLine.id,
                  oldLine.text == newLine.text,
                  let oldSyllables = oldLine.syllables, !oldSyllables.isEmpty,
                  let newSyllables = newLine.syllables, !newSyllables.isEmpty,
                  let oldStart = oldSyllables.first?.start,
                  let oldEnd = oldSyllables.last?.end else {
                continue
            }
            // Only freeze the single line currently mid-flight; upcoming lines upgrade immediately.
            if playbackTime >= oldStart + 0.12 && playbackTime < oldEnd - 0.05 {
                merged[index] = oldLine
            }
        }
        return merged
    }
}
