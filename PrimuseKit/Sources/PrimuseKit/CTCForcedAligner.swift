import Foundation

/// Token vocabulary for a CTC acoustic forced-alignment model (e.g. Meta `omniASR-CTC-300M`).
/// Loads from a simple JSON map `{ "<token>": <id> }` so Swift stays independent of
/// SentencePiece model-type variants (Unigram / Char / BPE).
public struct CTCLyricsVocabulary: Sendable, Equatable {
    public let idByPiece: [String: Int]
    public let blankID: Int
    public let unknownID: Int
    public let wordBoundaryToken: String?
    public let lowercaseInput: Bool
    private let maxPieceScalars: Int

    public init(
        idByPiece: [String: Int],
        blankID: Int = 0,
        unknownID: Int = 3,
        wordBoundaryToken: String? = "\u{2581}",
        lowercaseInput: Bool = true
    ) {
        self.idByPiece = idByPiece
        self.blankID = blankID
        self.unknownID = unknownID
        self.wordBoundaryToken = wordBoundaryToken
        self.lowercaseInput = lowercaseInput
        self.maxPieceScalars = max(1, min(16, idByPiece.keys.map { $0.unicodeScalars.count }.max() ?? 1))
    }

    public static func decode(
        vocabularyJSON: Data,
        manifest: WordLyricsAlignmentManifest
    ) -> CTCLyricsVocabulary? {
        guard let raw = try? JSONDecoder().decode([String: Int].self, from: vocabularyJSON),
              !raw.isEmpty else {
            return nil
        }
        return CTCLyricsVocabulary(
            idByPiece: raw,
            blankID: manifest.blankID,
            unknownID: manifest.unknownID,
            wordBoundaryToken: manifest.wordBoundaryToken,
            lowercaseInput: manifest.lowercaseInput
        )
    }

    /// Maps each lyric unit to its CTC token IDs (empty when the unit is OOV/symbol-only).
    public func tokenize(units: [WordTimingUnitSplitter.Unit]) -> [[Int]] {
        let boundary = wordBoundaryToken
        return units.enumerated().map { index, unit in
            let cleaned = normalize(unit.coreText)
            guard !cleaned.isEmpty else { return [] }
            var prefixed = cleaned
            if let boundary, !boundary.isEmpty {
                // SentencePiece / OmniASR marks word starts with U+2581 (or space) on non-ideographic words
                // or at line start when that prefixed form exists in the vocabulary.
                let wantsBoundary = index == 0 || !unit.isIdeographic
                if wantsBoundary, idByPiece[boundary + cleaned] != nil || idByPiece[boundary + String(cleaned.prefix(1))] != nil {
                    prefixed = boundary + cleaned
                }
            }
            let ids = greedyEncode(prefixed)
            if !ids.isEmpty { return ids }
            return greedyEncode(cleaned)
        }
    }

    /// Returns the compact sorted set of vocabulary IDs required to align `lines` (always including `blankID`).
    public func requiredTokenIDs(for lines: [LyricLine]) -> [Int] {
        var needed: Set<Int> = [blankID]
        for line in lines where line.isSynchronized && (line.syllables?.isEmpty ?? true) {
            let units = WordTimingUnitSplitter.units(of: line.text)
            for tokenList in tokenize(units: units) {
                for id in tokenList where id != blankID && id != unknownID {
                    needed.insert(id)
                }
            }
        }
        return needed.sorted()
    }

    private func normalize(_ text: String) -> String {
        var s = text.precomposedStringWithCompatibilityMapping
        if lowercaseInput { s = s.lowercased() }
        // Strip combining diacritics only if direct match fails later; first keep composed form.
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func greedyEncode(_ text: String) -> [Int] {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        var ids: [Int] = []
        var i = 0
        while i < scalars.count {
            let maxLen = min(maxPieceScalars, scalars.count - i)
            var matchedID: Int?
            var matchedLen = 1
            for len in stride(from: maxLen, through: 1, by: -1) {
                let candidate = String(String.UnicodeScalarView(scalars[i..<(i + len)]))
                if let id = idByPiece[candidate], id != blankID, id != unknownID {
                    matchedID = id
                    matchedLen = len
                    break
                }
            }
            if let matchedID {
                ids.append(matchedID)
                i += matchedLen
            } else {
                // Retry stripped base ASCII character (e.g., accented Latin -> base vowel) before marking OOV.
                let folded = String(scalars[i]).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                if let baseID = idByPiece[folded], baseID != blankID, baseID != unknownID {
                    ids.append(baseID)
                }
                i += 1
            }
        }
        return ids
    }
}

/// Compact frame-level log-probability matrix holding only the columns needed for
/// the lyric tokens inside a chunk (typically 30–150 columns instead of 10,288+).
public struct CTCEmissionSlice: Sendable {
    public let startTime: TimeInterval
    public let frameDuration: TimeInterval
    public let frameOffset: TimeInterval
    public let frameCount: Int
    public let blankID: Int
    public let columnCount: Int
    public let columnByTokenID: [Int: Int]
    /// Row-major `[frame * columnCount + column]` log-probabilities (`<= 0`).
    public let logProbs: [Float]

    public init(
        startTime: TimeInterval,
        frameDuration: TimeInterval,
        frameOffset: TimeInterval = 0.01,
        frameCount: Int,
        blankID: Int,
        tokenIDs: [Int],
        logProbs: [Float]
    ) {
        self.startTime = startTime
        self.frameDuration = frameDuration
        self.frameOffset = frameOffset
        self.frameCount = frameCount
        self.blankID = blankID
        self.columnCount = tokenIDs.count
        self.columnByTokenID = Dictionary(uniqueKeysWithValues: tokenIDs.enumerated().map { ($1, $0) })
        self.logProbs = logProbs
    }

    public func time(forFrame frame: Int) -> TimeInterval {
        startTime + Double(frame) * frameDuration + frameOffset
    }

    public func frameIndex(for time: TimeInterval) -> Int {
        guard frameCount > 0, frameDuration > 0 else { return 0 }
        let idx = Int(((time - startTime - frameOffset) / frameDuration).rounded())
        return min(frameCount - 1, max(0, idx))
    }

    @inline(__always)
    public func logProb(frame: Int, tokenID: Int) -> Float {
        guard frame >= 0, frame < frameCount, let col = columnByTokenID[tokenID] else {
            return -30
        }
        let idx = frame * columnCount + col
        guard idx < logProbs.count else { return -30 }
        return logProbs[idx]
    }
}

/// Plans fixed-size overlapping audio chunks for Core ML CTC inference, prioritizing
/// the chunk covering the active playhead so visible lines upgrade first.
public struct CTCChunkPlan: Equatable, Sendable {
    public struct Chunk: Equatable, Sendable {
        public var startTime: TimeInterval
        public var endTime: TimeInterval
        public var windowIndices: [Int]
    }

    public let chunks: [Chunk]

    public static func make(
        windows: [KaraokeLineWindow],
        chunkDuration: TimeInterval,
        margin: TimeInterval = 0.65,
        prioritizing playbackTime: TimeInterval? = nil
    ) -> CTCChunkPlan {
        guard !windows.isEmpty, chunkDuration > 2 * margin else {
            return CTCChunkPlan(chunks: [])
        }
        let usable = chunkDuration - 2 * margin
        var rawChunks: [Chunk] = []
        var idx = 0
        while idx < windows.count {
            let chunkStart = max(0, windows[idx].start - margin)
            let chunkEnd = chunkStart + chunkDuration
            var group: [Int] = []
            while idx < windows.count {
                let w = windows[idx]
                if !group.isEmpty && w.end + margin > chunkEnd {
                    // If the single line itself exceeds chunkDuration, still place it in its own chunk.
                    break
                }
                group.append(idx)
                idx += 1
                if w.end - chunkStart >= usable { break }
            }
            if group.isEmpty {
                group.append(idx)
                idx += 1
            }
            rawChunks.append(Chunk(startTime: chunkStart, endTime: chunkEnd, windowIndices: group))
        }

        if let playbackTime, playbackTime.isFinite, rawChunks.count > 1 {
            // Put the chunk containing (or immediately following) playbackTime first.
            let priorityIdx = rawChunks.firstIndex { $0.startTime <= playbackTime && playbackTime <= $0.endTime }
                ?? rawChunks.firstIndex { $0.startTime >= playbackTime }
                ?? 0
            if priorityIdx > 0 {
                let first = rawChunks.remove(at: priorityIdx)
                rawChunks.insert(first, at: 0)
            }
        }
        return CTCChunkPlan(chunks: rawChunks)
    }
}

/// Window-constrained CTC forced aligner (Tier 3 & Tier 4).
///
/// Decodes the optimal monotonic Viterbi path over extended CTC states inside each
/// LRC line window, gracefully interpolates OOV/wildcard units, extends collapsed CTC
/// peaks across sustained vowels using vocal energy, and falls back to DSP alignment
/// if CTC confidence collapses on a noisy/instrumental line.
public enum CTCForcedAligner {
    /// Minimum mean per-token log-probability relative to frame blank/max before falling back to DSP.
    public static let minimumMeanTokenLogProb: Float = -14.0
    public static let windowLeadMargin: TimeInterval = 0.45
    public static let windowTailMargin: TimeInterval = 0.30

    public struct LineOutcome: Equatable, Sendable {
        public var syllables: [LyricSyllable]
        public var usedCTC: Bool
        public var meanTokenLogProb: Float
    }

    /// Aligns one lyric line inside `window` using CTC emissions and optional vocal energy profile.
    public static func alignLine(
        _ line: LyricLine,
        window: KaraokeLineWindow,
        vocabulary: CTCLyricsVocabulary,
        emissions: CTCEmissionSlice,
        profile: VocalAcousticProfile? = nil
    ) -> LineOutcome? {
        guard line.syllables?.isEmpty ?? true else { return nil }
        let units = WordTimingUnitSplitter.units(of: line.text)
        guard !units.isEmpty else { return nil }

        let fallback: () -> LineOutcome? = {
            if let profile, let dsp = AudioWordTimingAligner.alignLine(line, window: window, profile: profile)?.syllables {
                return LineOutcome(syllables: dsp, usedCTC: false, meanTokenLogProb: -30)
            }
            guard let sweep = ProsodySweepAligner.sweepLine(line, window: window).syllables else { return nil }
            return LineOutcome(syllables: sweep, usedCTC: false, meanTokenLogProb: -30)
        }

        let unitTokenLists = vocabulary.tokenize(units: units)
        var targetTokens: [Int] = []
        var tokenUnitIndices: [Int] = []
        var anchoredUnitCount = 0
        for (unitIdx, tokens) in unitTokenLists.enumerated() {
            guard !tokens.isEmpty else { continue }
            anchoredUnitCount += 1
            for tok in tokens {
                targetTokens.append(tok)
                tokenUnitIndices.append(unitIdx)
            }
        }

        // Require at least half of units (or >= 1) to have valid vocabulary tokens.
        guard !targetTokens.isEmpty, anchoredUnitCount * 2 >= units.count else {
            return fallback()
        }

        // Frame slice restricted to this line's LRC window (prevents cross-line drift).
        let sliceStartTime = max(emissions.startTime, window.start - windowLeadMargin)
        let sliceEndTime = min(
            emissions.startTime + Double(emissions.frameCount) * emissions.frameDuration,
            window.end + windowTailMargin
        )
        let fStart = emissions.frameIndex(for: sliceStartTime)
        let fEnd = emissions.frameIndex(for: sliceEndTime)
        let frameCount = fEnd - fStart + 1

        // Minimum frames required for CTC path (consecutive identical tokens need a blank frame between them).
        var repeats = 0
        for i in 1..<targetTokens.count where targetTokens[i] == targetTokens[i - 1] { repeats += 1 }
        guard frameCount >= targetTokens.count + repeats + 1 else {
            return fallback()
        }

        // Standard CTC forced alignment Viterbi over extended states S = [b, L0, b, L1, ..., LM-1, b].
        let stateCount = targetTokens.count * 2 + 1
        let blankID = emissions.blankID
        let negInf = -Float.infinity

        var prevDP = [Float](repeating: negInf, count: stateCount)
        var currDP = [Float](repeating: negInf, count: stateCount)
        var backpointer = [Int8](repeating: 0, count: frameCount * stateCount)

        prevDP[0] = emissions.logProb(frame: fStart, tokenID: blankID)
        prevDP[1] = emissions.logProb(frame: fStart, tokenID: targetTokens[0])

        for localT in 1..<frameCount {
            let globalFrame = fStart + localT
            let rowOffset = localT * stateCount
            let blankScore = emissions.logProb(frame: globalFrame, tokenID: blankID)

            for s in 0..<stateCount {
                let emit: Float
                let canSkipBlank: Bool
                if s & 1 == 0 {
                    emit = blankScore
                    canSkipBlank = false
                } else {
                    let tokIdx = s >> 1
                    emit = emissions.logProb(frame: globalFrame, tokenID: targetTokens[tokIdx])
                    canSkipBlank = tokIdx > 0 && targetTokens[tokIdx] != targetTokens[tokIdx - 1]
                }

                var bestVal = prevDP[s]
                var bestStep: Int8 = 0 // 0 = stay, 1 = from s-1, 2 = from s-2

                if s >= 1 && prevDP[s - 1] > bestVal {
                    bestVal = prevDP[s - 1]
                    bestStep = 1
                }
                if canSkipBlank && s >= 2 && prevDP[s - 2] > bestVal {
                    bestVal = prevDP[s - 2]
                    bestStep = 2
                }
                currDP[s] = bestVal.isFinite ? (bestVal + emit) : negInf
                backpointer[rowOffset + s] = bestStep
            }
            swap(&prevDP, &currDP)
        }

        let endBlank = prevDP[stateCount - 1]
        let endTok = prevDP[stateCount - 2]
        var state = endBlank >= endTok ? (stateCount - 1) : (stateCount - 2)
        guard prevDP[state].isFinite else { return fallback() }

        // Backtrack exact frame spans per token state.
        var tokenFirstFrame = [Int](repeating: Int.max, count: targetTokens.count)
        var tokenLastFrame = [Int](repeating: -1, count: targetTokens.count)
        var tokenLogProbSum: Float = 0
        var tokenFrameTotal = 0

        for localT in stride(from: frameCount - 1, through: 0, by: -1) {
            if state & 1 == 1 {
                let tokIdx = state >> 1
                let globalFrame = fStart + localT
                if globalFrame < tokenFirstFrame[tokIdx] { tokenFirstFrame[tokIdx] = globalFrame }
                if globalFrame > tokenLastFrame[tokIdx] { tokenLastFrame[tokIdx] = globalFrame }
                tokenLogProbSum += emissions.logProb(frame: globalFrame, tokenID: targetTokens[tokIdx])
                tokenFrameTotal += 1
            }
            if localT > 0 {
                let step = Int(backpointer[localT * stateCount + state])
                state -= step
            }
        }

        guard tokenFrameTotal > 0 else { return fallback() }
        let meanLogProb = tokenLogProbSum / Float(tokenFrameTotal)
        guard meanLogProb >= minimumMeanTokenLogProb else {
            return fallback()
        }

        // Collapse token spans to unit start/end anchors.
        var unitStarts = [TimeInterval?](repeating: nil, count: units.count)
        var unitPeakEnds = [TimeInterval?](repeating: nil, count: units.count)
        for tokIdx in 0..<targetTokens.count {
            let first = tokenFirstFrame[tokIdx]
            let last = tokenLastFrame[tokIdx]
            guard first <= last else { continue }
            let u = tokenUnitIndices[tokIdx]
            let sTime = emissions.time(forFrame: first)
            let eTime = emissions.time(forFrame: last) + emissions.frameDuration
            if let existing = unitStarts[u] {
                unitStarts[u] = min(existing, sTime)
            } else {
                unitStarts[u] = sTime
            }
            if let existing = unitPeakEnds[u] {
                unitPeakEnds[u] = max(existing, eTime)
            } else {
                unitPeakEnds[u] = eTime
            }
        }

        // Interpolate any OOV / wildcard units smoothly between anchored neighbors.
        let activeRegion = profile?.activeRegion(for: window)
        let fallbackStart = activeRegion?.start ?? window.start
        let fallbackEnd = activeRegion?.end ?? (window.start + max(0.2, (window.end - window.start) * 0.92))
        let resolvedStarts = interpolateMissingStarts(
            unitStarts,
            units: units,
            lowerBound: fallbackStart,
            upperBound: fallbackEnd
        )

        // Extend collapsed CTC peaks across real sustained vowels using vocal energy envelope.
        var syllables: [LyricSyllable] = []
        syllables.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            let start = max(window.start - windowLeadMargin, resolvedStarts[index])
            let nextStart: TimeInterval
            if index + 1 < resolvedStarts.count {
                nextStart = max(start + 0.03, resolvedStarts[index + 1])
            } else {
                let lineEndBound = max(
                    activeRegion?.end ?? window.end,
                    (unitPeakEnds[index] ?? start) + 0.12
                )
                nextStart = min(window.end + 0.08, max(start + 0.12, lineEndBound))
            }

            let ctcEnd = unitPeakEnds[index].map { min(nextStart, max(start + 0.05, $0)) } ?? nextStart
            let end: TimeInterval
            if let profile, let region = activeRegion {
                let energyEnd = profile.vocalEnd(startingAt: start, limit: nextStart, linePeakDB: region.peakDB)
                end = max(ctcEnd, min(nextStart, energyEnd))
            } else {
                // Without vocal energy profile, extend smoothly toward next unit unless there is a punctuation pause.
                let gapRatio = unit.trailingPauseWeight > 0 ? 0.72 : 0.96
                end = max(ctcEnd, start + (nextStart - start) * gapRatio)
            }
            syllables.append(LyricSyllable(
                text: unit.text,
                start: start,
                end: max(start + 0.02, min(nextStart, end)),
                endTiming: .explicit
            ))
        }

        // Enforce strict monotonic non-overlapping starts.
        for i in 1..<syllables.count {
            if syllables[i].start < syllables[i - 1].start + 0.02 {
                syllables[i].start = syllables[i - 1].start + 0.02
            }
            if syllables[i - 1].end > syllables[i].start {
                syllables[i - 1].end = syllables[i].start
            }
            if syllables[i].end <= syllables[i].start {
                syllables[i].end = syllables[i].start + 0.02
            }
        }

        return LineOutcome(syllables: syllables, usedCTC: true, meanTokenLogProb: meanLogProb)
    }

    private static func interpolateMissingStarts(
        _ starts: [TimeInterval?],
        units: [WordTimingUnitSplitter.Unit],
        lowerBound: TimeInterval,
        upperBound: TimeInterval
    ) -> [TimeInterval] {
        var resolved = starts
        let count = units.count
        var i = 0
        while i < count {
            if resolved[i] != nil {
                i += 1
                continue
            }
            let runStart = i
            while i < count && resolved[i] == nil { i += 1 }
            let runEnd = i // exclusive

            let leftTime: TimeInterval
            if runStart > 0, let prev = resolved[runStart - 1] {
                leftTime = prev
            } else {
                leftTime = lowerBound
            }
            let rightTime: TimeInterval
            if runEnd < count, let next = resolved[runEnd] {
                rightTime = max(leftTime + 0.04 * Double(runEnd - runStart), next)
            } else {
                rightTime = max(leftTime + 0.12 * Double(runEnd - runStart), upperBound)
            }

            // Distribute across `[leftTime, rightTime]` weighted by syllables (including preceding anchored unit if any).
            let includeLeft = runStart > 0
            let weightStart = includeLeft ? runStart - 1 : runStart
            let totalWeight = max(
                0.5,
                (weightStart..<runEnd).reduce(0.0) { $0 + units[$1].syllableWeight + units[$1].trailingPauseWeight }
            )
            var accum = includeLeft
                ? (units[runStart - 1].syllableWeight + units[runStart - 1].trailingPauseWeight)
                : 0.0
            for idx in runStart..<runEnd {
                resolved[idx] = leftTime + (rightTime - leftTime) * (accum / totalWeight)
                accum += units[idx].syllableWeight + units[idx].trailingPauseWeight
            }
        }
        return resolved.map { $0 ?? lowerBound }
    }
}
