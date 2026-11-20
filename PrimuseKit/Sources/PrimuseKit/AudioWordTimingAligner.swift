import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

/// A singing-voice syllable onset extracted from multi-feature acoustic analysis.
public struct SingingOnset: Equatable, Sendable {
    public var time: TimeInterval
    /// Combined normalised onset strength in 0...1.
    public var strength: Double
    /// SuperFlux (vibrato-suppressed spectral rise) contribution.
    public var fluxStrength: Double
    /// Pitch-jump (legato melody transition) contribution.
    public var pitchStrength: Double
    /// Spectral-envelope / Log-Mel timbre transition contribution.
    public var timbreStrength: Double

    public init(
        time: TimeInterval,
        strength: Double,
        fluxStrength: Double = 0,
        pitchStrength: Double = 0,
        timbreStrength: Double = 0
    ) {
        self.time = time
        self.strength = strength
        self.fluxStrength = fluxStrength
        self.pitchStrength = pitchStrength
        self.timbreStrength = timbreStrength
    }
}

/// Fast pure-DSP stereo center-channel vocal isolation & bandpass preprocessor.
/// Used when a song has no HTDemucs vocal stem cached, so both DSP alignment and
/// Core ML CTC alignment receive cleaner centered lead vocals with suppressed wide instruments.
public enum StereoVocalPreprocessor {
    /// Extracts a mono vocal-emphasised track from stereo PCM (or band-limits mono PCM).
    public static func extractVocalMono(
        left: [Float],
        right: [Float]?,
        sampleRate: Double
    ) -> [Float] {
        guard !left.isEmpty, sampleRate > 0 else { return [] }
        let count = right.map { min(left.count, $0.count) } ?? left.count
        guard count > 0 else { return [] }

        let fftSize = sampleRate >= 32_000 ? 1_024 : 512
        let hopSize = fftSize / 4
        guard count >= fftSize else {
            if let right {
                return (0..<count).map { 0.5 * (left[$0] + right[$0]) }
            }
            return Array(left.prefix(count))
        }

        let fft = KaraokeComplexFFT(size: fftSize)
        let window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }
        // At 75% overlap, sum of squared Hann windows equals 1.5; KaraokeComplexFFT.inverse is unnormalised.
        let overlapScale = Float(1.0 / (1.5 * Double(fftSize)))
        let binHz = sampleRate / Double(fftSize)

        // Smooth bandpass weights (80 Hz...5200 Hz) to attenuate kick sub-bass and cymbal fizz.
        var bandGain = [Float](repeating: 0, count: fftSize / 2 + 1)
        for bin in 0...(fftSize / 2) {
            let hz = Double(bin) * binHz
            let lowFade: Double = hz < 65 ? 0 : (hz < 110 ? (hz - 65) / 45 : 1)
            let highFade: Double = hz > 5_800 ? 0 : (hz > 4_600 ? (5_800 - hz) / 1_200 : 1)
            bandGain[bin] = Float(lowFade * highFade)
        }

        var output = [Float](repeating: 0, count: count)
        var lReal = [Float](repeating: 0, count: fftSize)
        var lImag = [Float](repeating: 0, count: fftSize)
        var rReal = [Float](repeating: 0, count: fftSize)
        var rImag = [Float](repeating: 0, count: fftSize)

        let hasStereo = right != nil
        let frameCount = (count - fftSize) / hopSize + 1

        for frame in 0..<frameCount {
            let start = frame * hopSize
            for i in 0..<fftSize {
                let w = window[i]
                lReal[i] = left[start + i] * w
                lImag[i] = 0
                if let right {
                    rReal[i] = right[start + i] * w
                    rImag[i] = 0
                }
            }

            lReal.withUnsafeMutableBufferPointer { lr in lImag.withUnsafeMutableBufferPointer { li in
                fft.forward(real: lr.baseAddress!, imag: li.baseAddress!)
            } }
            if hasStereo {
                rReal.withUnsafeMutableBufferPointer { rr in rImag.withUnsafeMutableBufferPointer { ri in
                    fft.forward(real: rr.baseAddress!, imag: ri.baseAddress!)
                } }
            }

            for bin in 0...(fftSize / 2) {
                let gain = bandGain[bin]
                let outR: Float
                let outI: Float
                if hasStereo {
                    let midR = 0.5 * (lReal[bin] + rReal[bin])
                    let midI = 0.5 * (lImag[bin] + rImag[bin])
                    let sideR = 0.5 * (lReal[bin] - rReal[bin])
                    let sideI = 0.5 * (lImag[bin] - rImag[bin])
                    let magMid = hypot(midR, midI)
                    let magSide = hypot(sideR, sideI)
                    // Soft center-channel mask suppresses panned guitars/synths while keeping lead vocal intact.
                    let ratio = magMid / (magMid + 1.45 * magSide + 1e-6)
                    let mask = ratio * sqrt(ratio) * gain
                    outR = midR * mask
                    outI = midI * mask
                } else {
                    outR = lReal[bin] * gain
                    outI = lImag[bin] * gain
                }
                lReal[bin] = outR
                lImag[bin] = outI
                if bin > 0 && bin < fftSize / 2 {
                    lReal[fftSize - bin] = outR
                    lImag[fftSize - bin] = -outI
                }
            }

            lReal.withUnsafeMutableBufferPointer { lr in lImag.withUnsafeMutableBufferPointer { li in
                fft.inverse(real: lr.baseAddress!, imag: li.baseAddress!)
            } }
            for i in 0..<fftSize {
                output[start + i] += lReal[i] * window[i] * overlapScale
            }
        }
        return output
    }
}

/// Frame-by-frame vocal acoustic profile computed at ~10 ms resolution:
/// vocal-band energy (for VAD & sustained-note tail bounds), vibrato-resistant SuperFlux,
/// Log-Mel timbre transitions, and F0 pitch jumps (for legato syllable transitions).
public struct VocalAcousticProfile: Sendable {
    public let sampleRate: Double
    public let hopSize: Int
    public let fftSize: Int
    /// Frame step in seconds (typically 0.01 s).
    public let frameDuration: TimeInterval
    /// Vocal-band (180–3800 Hz) RMS energy in dB per frame.
    public let voiceEnergyDB: [Float]
    /// Estimated background noise floor in dB (15th percentile of finite frame energies).
    public let noiseFloorDB: Float
    /// Multi-feature singing onsets detected across the track.
    public let onsets: [SingingOnset]

    public var frameCount: Int { voiceEnergyDB.count }

    public func frameIndex(for time: TimeInterval) -> Int {
        guard frameCount > 0 else { return 0 }
        let idx = Int(((time - Double(fftSize) * 0.5 / sampleRate) / frameDuration).rounded())
        return min(frameCount - 1, max(0, idx))
    }

    public func time(for frame: Int) -> TimeInterval {
        (Double(frame * hopSize) + Double(fftSize) * 0.5) / sampleRate
    }

    /// Finds the active singing interval `[activeStart, activeEnd]` and internal silence gaps
    /// inside an LRC line window.
    public func activeRegion(for window: KaraokeLineWindow) -> ActiveRegion {
        let rawSpan = max(0.2, window.end - window.start)
        guard frameCount > 4 else {
            return ActiveRegion(start: window.start, end: window.end, peakDB: noiseFloorDB, silenceGaps: [])
        }
        let searchStart = frameIndex(for: max(0, window.start - 0.18))
        let searchEnd = frameIndex(for: window.end + 0.06)
        guard searchEnd > searchStart + 2 else {
            return ActiveRegion(start: window.start, end: window.end, peakDB: noiseFloorDB, silenceGaps: [])
        }

        let slice = Array(voiceEnergyDB[searchStart...searchEnd]).sorted()
        let peakDB = slice[min(slice.count - 1, Int(Double(slice.count) * 0.90))]
        let lineFloorDB = max(noiseFloorDB + 6.0, peakDB - 18.0)
        guard peakDB > noiseFloorDB + 5.0 else {
            return ActiveRegion(start: window.start, end: window.end, peakDB: peakDB, silenceGaps: [])
        }

        let minVoicedRun = max(2, Int((0.03 / frameDuration).rounded()))
        let minEndRun = max(2, Int((0.04 / frameDuration).rounded()))

        // First sustained voiced run near window.start.
        var activeStartFrame = frameIndex(for: window.start)
        let latestStartFrame = frameIndex(for: window.start + min(1.5, rawSpan * 0.45))
        var run = 0
        for f in searchStart...min(searchEnd, latestStartFrame) {
            if voiceEnergyDB[f] >= lineFloorDB {
                run += 1
                if run >= minVoicedRun {
                    activeStartFrame = f - run + 1
                    break
                }
            } else {
                run = 0
            }
        }

        // Last sustained voiced run inside the window (trims trailing instrumental silence).
        var activeEndFrame = frameIndex(for: window.end)
        let earliestEndFrame = min(searchEnd, activeStartFrame + max(minEndRun, Int((0.18 / frameDuration).rounded())))
        run = 0
        for f in stride(from: searchEnd, through: earliestEndFrame, by: -1) {
            if voiceEnergyDB[f] >= lineFloorDB {
                run += 1
                if run >= minEndRun {
                    activeEndFrame = min(searchEnd, f + run - 1 + Int((0.05 / frameDuration).rounded()))
                    break
                }
            } else {
                run = 0
            }
        }

        let activeStart = max(window.start - 0.18, min(window.end - 0.12, time(for: activeStartFrame)))
        let activeEnd = max(activeStart + 0.15, min(window.end, time(for: activeEndFrame)))

        // Detect internal silence islands >= 160 ms (clause breaks / breaths).
        let minSilenceFrames = max(8, Int((0.16 / frameDuration).rounded()))
        let gapThresholdDB = max(noiseFloorDB + 5.0, peakDB - 14.0)
        var gaps: [ClosedRange<TimeInterval>] = []
        var gapStart: Int?
        let innerStart = min(activeEndFrame, activeStartFrame + minVoicedRun)
        if innerStart < activeEndFrame {
            for f in innerStart...activeEndFrame {
                if voiceEnergyDB[f] < gapThresholdDB {
                    if gapStart == nil { gapStart = f }
                } else if let s = gapStart {
                    if f - s >= minSilenceFrames {
                        gaps.append(time(for: s)...time(for: f))
                    }
                    gapStart = nil
                }
            }
        }
        return ActiveRegion(start: activeStart, end: activeEnd, peakDB: peakDB, silenceGaps: gaps)
    }

    /// Finds where vocal energy drops into silence between `start` and `limit`, so sustained
    /// vowels extend across their real sung duration while stopping cleanly at rests.
    public func vocalEnd(startingAt start: TimeInterval, limit: TimeInterval, linePeakDB: Float) -> TimeInterval {
        guard limit > start + 0.08, frameCount > 4 else { return max(start + 0.05, limit) }
        let fStart = frameIndex(for: start + 0.04)
        let fLimit = frameIndex(for: limit)
        guard fLimit > fStart + 4 else { return limit }

        let dropThreshold = max(noiseFloorDB + 5.0, linePeakDB - 16.0)
        let sustainSilence = max(5, Int((0.08 / frameDuration).rounded()))
        var quietRun = 0
        for f in fStart...fLimit {
            if voiceEnergyDB[f] < dropThreshold {
                quietRun += 1
                if quietRun >= sustainSilence {
                    let dropFrame = max(fStart + 1, f - quietRun + 2)
                    return min(limit, max(start + 0.06, time(for: dropFrame)))
                }
            } else {
                quietRun = 0
            }
        }
        return limit
    }

    public struct ActiveRegion: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var peakDB: Float
        public var silenceGaps: [ClosedRange<TimeInterval>]
    }

    /// Computes a full multi-feature acoustic profile from mono vocal samples.
    public static func analyze(samples: [Float], sampleRate: Double) -> VocalAcousticProfile {
        // ~15-21 Hz/bin frequency resolution lets 3-bin SuperFlux suppress vibrato without swallowing 1-semitone steps.
        let fftSize = sampleRate >= 32_000 ? 2_048 : 1_024
        let hopSize = max(64, Int((0.010 * sampleRate).rounded())) // ~10 ms hop
        let frameDuration = Double(hopSize) / sampleRate
        guard samples.count > fftSize, sampleRate > 0 else {
            return VocalAcousticProfile(
                sampleRate: sampleRate,
                hopSize: hopSize,
                fftSize: fftSize,
                frameDuration: frameDuration,
                voiceEnergyDB: [],
                noiseFloorDB: -80,
                onsets: []
            )
        }

        let fft = KaraokeComplexFFT(size: fftSize)
        let window = (0..<fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize))) }
        let binHz = sampleRate / Double(fftSize)
        let halfBins = fftSize / 2
        let lowFluxBin = max(1, Int(100 / binHz))
        let highFluxBin = min(halfBins - 2, Int(4_800 / binHz))
        let lowVoiceBin = max(1, Int(180 / binHz))
        let highVoiceBin = min(halfBins - 1, Int(3_800 / binHz))

        let melBands = 24
        let melBank = buildMelFilterBank(bands: melBands, fftSize: fftSize, sampleRate: sampleRate, lowHz: 100, highHz: min(5_000, sampleRate * 0.48))

        let frameCount = (samples.count - fftSize) / hopSize + 1
        var voiceEnergyDB = [Float](repeating: -90, count: frameCount)
        var superFlux = [Double](repeating: 0, count: frameCount)
        var melVectors = [[Float]](repeating: [Float](repeating: 0, count: melBands), count: frameCount)

        // 1-frame (10 ms) SuperFlux lag + 3-bin max-filter (Böck & Widmer 2013): suppresses
        // continuous vibrato drift while catching rapid 10 ms re-attacks and 1-semitone steps.
        var prevMag = [Float](repeating: 0, count: halfBins)
        var currMag = [Float](repeating: 0, count: halfBins)
        var real = [Float](repeating: 0, count: fftSize)
        var imag = [Float](repeating: 0, count: fftSize)
        var magSq = [Float](repeating: 0, count: halfBins)

        for frame in 0..<frameCount {
            let start = frame * hopSize
            for i in 0..<fftSize {
                real[i] = samples[start + i] * window[i]
                imag[i] = 0
            }
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { m in
                fft.forward(real: r.baseAddress!, imag: m.baseAddress!)
            } }

            var voicePower = 0.0
            for bin in 0..<halfBins {
                let p = real[bin] * real[bin] + imag[bin] * imag[bin]
                magSq[bin] = p
                currMag[bin] = log1p(1_000 * p.squareRoot())
                if bin >= lowVoiceBin && bin <= highVoiceBin {
                    voicePower += Double(p)
                }
            }
            let voiceRMS = (voicePower / Double(max(1, highVoiceBin - lowVoiceBin + 1))).squareRoot() / Double(fftSize)
            voiceEnergyDB[frame] = Float(20.0 * log10(max(voiceRMS, 1e-6)))

            // SuperFlux: compare current log-mag with local 3-bin frequency max from previous frame.
            if frame >= 1 {
                var rise = 0.0
                for bin in lowFluxBin...highFluxBin {
                    let prevMax = max(prevMag[bin - 1], max(prevMag[bin], prevMag[bin + 1]))
                    let diff = currMag[bin] - prevMax
                    if diff > 0 { rise += Double(diff) }
                }
                superFlux[frame] = rise
            }
            swap(&prevMag, &currMag)

            // 24-band mean-normalised Log-Mel vector (captures vowel/timbre changes independent of loudness).
            var mel = [Float](repeating: 0, count: melBands)
            var melSum: Float = 0
            for b in 0..<melBands {
                var e: Float = 0
                for (bin, weight) in melBank[b] {
                    e += magSq[bin] * weight
                }
                let v = log1p(100 * e.squareRoot())
                mel[b] = v
                melSum += v
            }
            let melMean = melSum / Float(melBands)
            for b in 0..<melBands { mel[b] -= melMean }
            melVectors[frame] = mel
        }

        // Estimate background noise floor (15th percentile).
        let sortedEnergy = voiceEnergyDB.sorted()
        let noiseFloorDB = sortedEnergy[min(sortedEnergy.count - 1, Int(Double(sortedEnergy.count) * 0.15))]

        // Timbre delta: L2 distance between smoothed past 30ms and future 30ms normalised Mel spectra.
        var melDelta = [Double](repeating: 0, count: frameCount)
        let melWin = 3
        if frameCount > melWin * 2 + 1 {
            for frame in melWin..<(frameCount - melWin) {
                guard voiceEnergyDB[frame] > noiseFloorDB + 5 else { continue }
                var distSq = 0.0
                for b in 0..<melBands {
                    var past: Float = 0
                    var future: Float = 0
                    for k in 1...melWin {
                        past += melVectors[frame - k][b]
                        future += melVectors[frame + k][b]
                    }
                    let d = Double(future - past) / Double(melWin)
                    distSq += d * d
                }
                melDelta[frame] = distSq.squareRoot()
            }
        }

        // Fast F0 pitch tracking on voiced frames for legato pitch-change onset detection.
        let pitchJump = computePitchJumps(
            samples: samples,
            sampleRate: sampleRate,
            hopSize: hopSize,
            frameCount: frameCount,
            voiceEnergyDB: voiceEnergyDB,
            noiseFloorDB: noiseFloorDB
        )

        let onsets = pickMultiFeatureOnsets(
            superFlux: superFlux,
            melDelta: melDelta,
            pitchJump: pitchJump,
            voiceEnergyDB: voiceEnergyDB,
            noiseFloorDB: noiseFloorDB,
            hopSize: hopSize,
            fftSize: fftSize,
            sampleRate: sampleRate
        )

        return VocalAcousticProfile(
            sampleRate: sampleRate,
            hopSize: hopSize,
            fftSize: fftSize,
            frameDuration: frameDuration,
            voiceEnergyDB: voiceEnergyDB,
            noiseFloorDB: noiseFloorDB,
            onsets: onsets
        )
    }

    // MARK: - Private DSP Helpers

    private static func buildMelFilterBank(
        bands: Int,
        fftSize: Int,
        sampleRate: Double,
        lowHz: Double,
        highHz: Double
    ) -> [[(Int, Float)]] {
        func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
        func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

        let lowMel = hzToMel(lowHz)
        let highMel = hzToMel(highHz)
        let points = (0...(bands + 1)).map { i in
            let mel = lowMel + (highMel - lowMel) * Double(i) / Double(bands + 1)
            return melToHz(mel) * Double(fftSize) / sampleRate
        }
        let maxBin = fftSize / 2 - 1
        var bank: [[(Int, Float)]] = []
        bank.reserveCapacity(bands)
        for b in 0..<bands {
            let left = points[b]
            let center = points[b + 1]
            let right = points[b + 2]
            var weights: [(Int, Float)] = []
            let startBin = max(1, Int(floor(left)))
            let endBin = min(maxBin, Int(ceil(right)))
            guard endBin >= startBin else {
                bank.append([])
                continue
            }
            for bin in startBin...endBin {
                let x = Double(bin)
                let w: Double
                if x >= left && x <= center && center > left {
                    w = (x - left) / (center - left)
                } else if x > center && x <= right && right > center {
                    w = (right - x) / (right - center)
                } else {
                    w = 0
                }
                if w > 0 { weights.append((bin, Float(w))) }
            }
            bank.append(weights)
        }
        return bank
    }

    /// Lightweight decimated YIN pitch tracker (~8 kHz) returning smoothed pitch-jump novelty per frame.
    private static func computePitchJumps(
        samples: [Float],
        sampleRate: Double,
        hopSize: Int,
        frameCount: Int,
        voiceEnergyDB: [Float],
        noiseFloorDB: Float
    ) -> [Double] {
        guard frameCount > 10, sampleRate >= 8_000 else {
            return [Double](repeating: 0, count: frameCount)
        }
        // Decimate to ~8 kHz so YIN lag range (85–950 Hz) is only 8...94 lags.
        let decimation = max(1, Int((sampleRate / 8_000).rounded()))
        let decRate = sampleRate / Double(decimation)
        let decCount = samples.count / decimation
        var dec = [Float](repeating: 0, count: decCount)
        if decimation == 1 {
            dec = samples
        } else {
            let inv = Float(1.0 / Double(decimation))
            for i in 0..<decCount {
                var s: Float = 0
                let base = i * decimation
                for k in 0..<decimation { s += samples[base + k] }
                dec[i] = s * inv
            }
        }

        let minLag = max(4, Int((decRate / 950.0).rounded(.down)))
        let maxLag = min(110, Int((decRate / 85.0).rounded(.up)))
        let integration = max(48, Int((0.016 * decRate).rounded()))
        let windowLen = integration + maxLag
        guard decCount > windowLen, maxLag > minLag else {
            return [Double](repeating: 0, count: frameCount)
        }

        var midi = [Double](repeating: 0, count: frameCount)
        var diff = [Double](repeating: 0, count: maxLag + 1)
        let voicedThreshold = noiseFloorDB + 7.0

        for frame in 0..<frameCount {
            guard voiceEnergyDB[frame] >= voicedThreshold else { continue }
            let start = (frame * hopSize) / decimation
            guard start + windowLen <= decCount else { break }

            diff[0] = 0
            for lag in 1...maxLag {
                var sum = 0.0
                #if canImport(Accelerate)
                dec.withUnsafeBufferPointer { buf in
                    let a = buf.baseAddress! + start
                    let b = a + lag
                    var tmp = [Float](repeating: 0, count: integration)
                    vDSP_vsub(b, 1, a, 1, &tmp, 1, vDSP_Length(integration))
                    var sq: Float = 0
                    vDSP_svesq(tmp, 1, &sq, vDSP_Length(integration))
                    sum = Double(sq)
                }
                #else
                for i in 0..<integration {
                    let d = Double(dec[start + i] - dec[start + i + lag])
                    sum += d * d
                }
                #endif
                diff[lag] = sum
            }

            var running = 0.0
            diff[0] = 1
            for lag in 1...maxLag {
                running += diff[lag]
                diff[lag] = running > 0 ? diff[lag] * Double(lag) / running : 1
            }

            var bestLag = -1
            var lag = minLag
            while lag <= maxLag {
                if diff[lag] < 0.18 {
                    while lag + 1 <= maxLag, diff[lag + 1] < diff[lag] { lag += 1 }
                    bestLag = lag
                    break
                }
                lag += 1
            }
            if bestLag > 0 {
                let freq = decRate / Double(bestLag)
                midi[frame] = 69.0 + 12.0 * log2(freq / 440.0)
            }
        }

        // Compare median pitch in [f-4...f-1] vs [f+1...f+4]; require post-jump stability to ignore vibrato.
        var jumps = [Double](repeating: 0, count: frameCount)
        for f in 4..<(frameCount - 4) {
            let before = ((f - 4)..<f).compactMap { midi[$0] > 0 ? midi[$0] : nil }.sorted()
            let after = ((f + 1)...(f + 4)).compactMap { midi[$0] > 0 ? midi[$0] : nil }.sorted()
            guard before.count >= 2, after.count >= 3 else { continue }
            let mBefore = before[before.count / 2]
            let mAfter = after[after.count / 2]
            let spreadAfter = (after.last ?? mAfter) - (after.first ?? mAfter)
            // Reject rapid vibrato swings where post-jump pitch isn't steady.
            guard spreadAfter <= 0.85 else { continue }
            let delta = abs(mAfter - mBefore)
            if delta >= 0.75 {
                jumps[f] = min(1.0, (delta - 0.5) / 2.5)
            }
        }
        return jumps
    }

    private static func pickMultiFeatureOnsets(
        superFlux: [Double],
        melDelta: [Double],
        pitchJump: [Double],
        voiceEnergyDB: [Float],
        noiseFloorDB: Float,
        hopSize: Int,
        fftSize: Int,
        sampleRate: Double
    ) -> [SingingOnset] {
        let count = superFlux.count
        guard count > 4 else { return [] }
        let frameRate = sampleRate / Double(hopSize)
        let localHalfWin = max(12, Int((0.60 * frameRate).rounded())) // ±0.6 s local adaptive context
        let minGapFrames = max(2, Int((0.055 * frameRate).rounded())) // 55 ms min spacing (fast rap/16th notes)

        let normFlux = localAdaptiveNormalize(superFlux, halfWindow: localHalfWin, floorRatio: 0.010)
        let normMel = localAdaptiveNormalize(melDelta, halfWindow: localHalfWin, floorRatio: 0.015)

        var combined = [Double](repeating: 0, count: count)
        let audibleFloor = noiseFloorDB + 4.5
        for f in 0..<count {
            guard voiceEnergyDB[f] >= audibleFloor else { continue }
            combined[f] = 0.55 * normFlux[f] + 0.30 * normMel[f] + 0.45 * pitchJump[f]
        }

        // Local peak picking over combined novelty (threshold relative to local activity, NOT global max).
        let peakContext = max(4, Int((0.12 * frameRate).rounded()))
        var result: [SingingOnset] = []
        var lastPeak = -minGapFrames

        for f in 1..<(count - 1) {
            let val = combined[f]
            guard val > 0.22, val > combined[f - 1], val >= combined[f + 1] else { continue }
            let lo = max(0, f - peakContext)
            let hi = min(count - 1, f + peakContext)
            var sum = 0.0
            for k in lo...hi { sum += combined[k] }
            let localMean = sum / Double(hi - lo + 1)
            guard val > localMean * 1.30 + 0.14 else { continue }

            let strength = min(1.0, val / 1.8)
            let time = (Double(f * hopSize) + Double(fftSize) * 0.5) / sampleRate
            let candidate = SingingOnset(
                time: time,
                strength: strength,
                fluxStrength: min(1.0, normFlux[f] / 1.8),
                pitchStrength: pitchJump[f],
                timbreStrength: min(1.0, normMel[f] / 1.8)
            )

            if f - lastPeak < minGapFrames {
                if let last = result.last, candidate.strength > last.strength {
                    result[result.count - 1] = candidate
                    lastPeak = f
                }
                continue
            }
            result.append(candidate)
            lastPeak = f
        }
        return result
    }

    /// Normalises a novelty curve against its local sliding-window median + MAD (robust against
    /// dense clusters of fast syllables that would inflate a mean/std baseline) so rapid rap runs
    /// and quiet verses both pop cleanly.
    private static func localAdaptiveNormalize(
        _ values: [Double],
        halfWindow: Int,
        floorRatio: Double
    ) -> [Double] {
        let count = values.count
        guard count > 0 else { return [] }
        let globalMax = values.max() ?? 0
        guard globalMax > 0 else { return [Double](repeating: 0, count: count) }
        let absFloor = globalMax * floorRatio

        // Sample every `step` frames inside the local window for O(N * 24) median+MAD estimation.
        let strideStep = max(1, (halfWindow * 2) / 32)
        var scratch: [Double] = []
        scratch.reserveCapacity(40)
        var out = [Double](repeating: 0, count: count)

        for i in 0..<count {
            let v = values[i]
            guard v > absFloor else { continue }
            let lo = max(0, i - halfWindow)
            let hi = min(count - 1, i + halfWindow)
            scratch.removeAll(keepingCapacity: true)
            var idx = lo
            while idx <= hi {
                scratch.append(values[idx])
                idx += strideStep
            }
            scratch.sort()
            let median = scratch[scratch.count / 2]
            let q75 = scratch[min(scratch.count - 1, (scratch.count * 3) / 4)]
            let spread = max(q75 - median, absFloor)
            let baseline = median + 1.2 * spread + absFloor
            let excess = v - baseline
            if excess > 0 {
                out[i] = min(2.5, excess / max(spread * 1.6, median * 0.5 + absFloor))
            }
        }
        return out
    }
}

/// Pure-DSP singing lyric aligner (Tier 1 & Tier 2).
///
/// Replaces uniform-anchor DP with:
/// 1. Per-line vocal activity window trimming & silence-island detection.
/// 2. Beam-pruned 2nd-order pairwise tempo-smooth DP (Huber log-duration prior +
///    local tempo continuity + skipped-onset penalty + punctuation/silence coupling).
/// 3. Vocal-energy-bounded explicit syllable end times for sustained held notes.
public enum AudioWordTimingAligner {
    private static let beamWidth = 6
    private static let maxCandidatesPerLine = 64

    /// Aligns every line-level row in `lines` against `profile` and returns a unified overlay.
    public static func align(
        lines: [LyricLine],
        profile: VocalAcousticProfile,
        tier: WordTimingTier
    ) -> WordLyricsTimingOverlay {
        let windows = KaraokeLineWindowPolicy.windows(in: lines)
        var byID: [String: [LyricSyllable]] = [:]
        byID.reserveCapacity(windows.count)
        for window in windows {
            let line = lines[window.lineIndex]
            guard line.syllables?.isEmpty ?? true else { continue }
            if let timed = alignLine(line, window: window, profile: profile)?.syllables {
                byID[line.id] = timed
            }
        }
        return WordLyricsTimingOverlay(
            tier: tier,
            lyricsFingerprint: WordLyricsTimingOverlay.fingerprint(for: lines),
            syllablesByLineID: byID,
            isPartial: false
        )
    }

    /// Aligns a single line using the full acoustic profile (VAD + multi-feature onsets).
    public static func alignLine(
        _ line: LyricLine,
        window: KaraokeLineWindow,
        profile: VocalAcousticProfile
    ) -> LyricLine? {
        guard line.syllables?.isEmpty ?? true else { return nil }
        let units = WordTimingUnitSplitter.units(of: line.text)
        guard !units.isEmpty else { return nil }

        let region = profile.activeRegion(for: window)
        let lineOnsets = sliceOnsets(profile.onsets, in: (region.start - 0.12)...(region.end - 0.03))
        let starts = solveStartTimes(
            units: units,
            activeStart: region.start,
            activeEnd: region.end,
            silenceGaps: region.silenceGaps,
            onsets: lineOnsets
        )

        var syllables: [LyricSyllable] = []
        syllables.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            let start = starts[index]
            let nextStart = index + 1 < starts.count
                ? starts[index + 1]
                : max(region.end, start + 0.10)
            let rawEnd = profile.vocalEnd(startingAt: start, limit: nextStart, linePeakDB: region.peakDB)
            let end = max(start + 0.02, min(nextStart, rawEnd))
            syllables.append(LyricSyllable(
                text: unit.text,
                start: start,
                end: end,
                endTiming: .explicit
            ))
        }
        var result = line
        result.syllables = syllables
        return result
    }

    /// Aligns a single line when only external `SingingOnset`s are available (without full energy profile).
    public static func alignLine(
        _ line: LyricLine,
        window: KaraokeLineWindow,
        onsets: [SingingOnset]
    ) -> LyricLine? {
        guard line.syllables?.isEmpty ?? true else { return nil }
        let units = WordTimingUnitSplitter.units(of: line.text)
        guard !units.isEmpty else { return nil }

        let span = max(0.2, (window.end - window.start) * (window.hasExplicitEnd ? 0.96 : 0.92))
        let lineEnd = window.start + span
        let lineOnsets = sliceOnsets(onsets, in: (window.start - 0.18)...(lineEnd - 0.03))
        guard !lineOnsets.isEmpty else {
            return ProsodySweepAligner.sweepLine(line, window: window)
        }

        // Infer compact active bounds from the detected onsets when no energy profile is passed.
        let firstOnset = lineOnsets.first!.time
        let lastOnset = lineOnsets.last!.time
        let activeStart = (firstOnset >= window.start - 0.18 && firstOnset <= window.start + min(1.0, span * 0.35))
            ? firstOnset
            : window.start
        let avgStep = max(0.15, (lastOnset - activeStart) / Double(max(1, units.count - 1)))
        let activeEnd = min(lineEnd, max(activeStart + 0.2, lastOnset + min(0.8, avgStep * 1.15)))

        let starts = solveStartTimes(
            units: units,
            activeStart: activeStart,
            activeEnd: activeEnd,
            silenceGaps: [],
            onsets: lineOnsets
        )

        var syllables: [LyricSyllable] = []
        syllables.reserveCapacity(units.count)
        for (index, unit) in units.enumerated() {
            let start = starts[index]
            let next = index + 1 < starts.count ? starts[index + 1] : max(activeEnd, start + 0.08)
            syllables.append(LyricSyllable(
                text: unit.text,
                start: start,
                end: max(start + 0.02, next),
                endTiming: .inferred
            ))
        }
        var result = line
        result.syllables = syllables
        return result
    }

    // MARK: - Beam-Pruned 2nd-Order Pairwise Tempo-Smooth DP

    private struct Candidate {
        var time: TimeInterval
        var strength: Double
        var isOnset: Bool
    }

    private struct BeamState {
        var cost: Double
        var prevCandidate: Int
        var prevBeam: Int
        var rate: Double // seconds per syllable unit on incoming edge
    }

    static func solveStartTimes(
        units: [WordTimingUnitSplitter.Unit],
        activeStart: TimeInterval,
        activeEnd: TimeInterval,
        silenceGaps: [ClosedRange<TimeInterval>],
        onsets: [SingingOnset]
    ) -> [TimeInterval] {
        let count = units.count
        guard count > 0 else { return [] }
        let activeSpan = max(0.2, activeEnd - activeStart)
        let totalWeight = max(0.5, units.reduce(0.0) { $0 + $1.syllableWeight + $1.trailingPauseWeight })
        let baseRate = activeSpan / totalWeight

        // Prosody-weighted fallback positions inside [activeStart, activeEnd].
        var cumulative = 0.0
        let fallbackTimes: [TimeInterval] = units.map { unit in
            let t = activeStart + activeSpan * (cumulative / totalWeight)
            cumulative += unit.syllableWeight + unit.trailingPauseWeight
            return t
        }
        if count == 1 {
            if let nearest = onsets.min(by: { abs($0.time - activeStart) < abs($1.time - activeStart) }),
               abs(nearest.time - activeStart) <= min(0.35, activeSpan * 0.4) {
                return [nearest.time]
            }
            return [activeStart]
        }
        guard !onsets.isEmpty else { return fallbackTimes }

        // Cap candidate pool to strongest onsets if abnormally dense, then re-sort chronologically.
        let trimmedOnsets: [SingingOnset]
        if onsets.count > maxCandidatesPerLine {
            trimmedOnsets = onsets
                .sorted { $0.strength > $1.strength }
                .prefix(maxCandidatesPerLine)
                .sorted { $0.time < $1.time }
        } else {
            trimmedOnsets = onsets
        }

        // Prefix cumulative strength of real onsets for O(1) skipped-onset penalty queries.
        let onsetTimes = trimmedOnsets.map(\.time)
        var onsetStrengthPrefix = [Double](repeating: 0, count: trimmedOnsets.count + 1)
        for i in 0..<trimmedOnsets.count {
            onsetStrengthPrefix[i + 1] = onsetStrengthPrefix[i] + trimmedOnsets[i].strength
        }
        func skippedOnsetWeight(between a: TimeInterval, and b: TimeInterval) -> Double {
            let lo = a + 0.045
            let hi = b - 0.045
            guard hi > lo, !onsetTimes.isEmpty else { return 0 }
            let startIdx = upperBound(onsetTimes, value: lo)
            let endIdx = lowerBound(onsetTimes, value: hi)
            guard endIdx > startIdx else { return 0 }
            return onsetStrengthPrefix[endIdx] - onsetStrengthPrefix[startIdx]
        }

        // Per-unit candidate lists: all real onsets + unit's own fallback point (only if no onset is within 25 ms).
        var options: [[Candidate]] = []
        options.reserveCapacity(count)
        for k in 0..<count {
            var list: [Candidate] = trimmedOnsets.map {
                Candidate(time: $0.time, strength: $0.strength, isOnset: true)
            }
            let fb = fallbackTimes[k]
            if !trimmedOnsets.contains(where: { abs($0.time - fb) < 0.025 }) {
                list.append(Candidate(time: fb, strength: 0, isOnset: false))
                list.sort { $0.time < $1.time }
            }
            options.append(list)
        }

        // DP table: beams[k][j] stores up to `beamWidth` best paths ending at unit k, candidate j.
        var beams = [[[BeamState]]](repeating: [], count: count)

        // Initialise unit 0: mild anchor near activeStart + onset reward.
        beams[0] = options[0].map { cand in
            let unary = cand.isOnset ? -1.25 * min(1.0, cand.strength) : 0.90
            let startPenalty = 1.40 * abs(cand.time - activeStart) / max(0.35, min(activeSpan, 1.5))
            return [BeamState(cost: unary + startPenalty, prevCandidate: -1, prevBeam: -1, rate: baseRate)]
        }

        for k in 1..<count {
            let prevUnit = units[k - 1]
            let effWeight = max(0.6, prevUnit.syllableWeight + prevUnit.trailingPauseWeight)
            let minDur = max(0.055, min(0.095, 0.06 * prevUnit.syllableWeight))
            let hasPause = prevUnit.trailingPauseWeight > 0
            let prevOptions = options[k - 1]
            let currOptions = options[k]
            var layer = [[BeamState]](repeating: [], count: currOptions.count)

            for (j, curr) in currOptions.enumerated() {
                let unary = curr.isOnset ? -1.25 * min(1.0, curr.strength) : 0.95
                // Asymmetric end anchor on the final unit: penalise impossibly short tails,
                // while allowing long held final notes (拖音) with minimal penalty.
                let finalTailCost: Double
                if k == count - 1 {
                    let tailDur = max(0.05, activeEnd - curr.time)
                    let expTail = max(0.12, units[k].syllableWeight * baseRate)
                    let ratio = log(tailDur / expTail)
                    let baseTail = ratio < 0
                        ? 0.70 * huber(ratio, delta: 0.65)
                        : 0.14 * huber(ratio, delta: 1.2)
                    // Also penalise leaving strong sung onsets unallocated after the last unit.
                    finalTailCost = baseTail + 1.15 * skippedOnsetWeight(between: curr.time, and: activeEnd)
                } else {
                    finalTailCost = 0
                }

                var topStates: [BeamState] = []
                topStates.reserveCapacity(beamWidth + 1)

                for (i, prev) in prevOptions.enumerated() {
                    let prevBeams = beams[k - 1][i]
                    guard !prevBeams.isEmpty else { continue }
                    let dur = curr.time - prev.time
                    guard dur >= minDur else { continue }

                    let rate = dur / effWeight
                    // Huber loss in log-rate space handles fast (2x-4x) and slow (2x-4x) runs symmetrically!
                    let durationPrior = 0.55 * huber(log(rate / baseRate), delta: 0.85)

                    // Strongly penalise skipping real sung onsets between consecutive syllables.
                    let skipped = skippedOnsetWeight(between: prev.time, and: curr.time)
                    let skipFactor = hasPause ? 0.35 : 1.35
                    let skipCost = skipFactor * skipped

                    // Couple textual pauses (commas/clause breaks) with acoustic silence islands.
                    var gapAdjustment = 0.0
                    if !silenceGaps.isEmpty {
                        let spansSilence = silenceGaps.contains { gap in
                            gap.lowerBound >= prev.time + 0.03 && gap.upperBound <= curr.time + 0.04
                        }
                        if spansSilence {
                            gapAdjustment = hasPause ? -0.55 : 0.15
                        }
                    }

                    let edgeBase = unary + finalTailCost + durationPrior + skipCost + gapAdjustment

                    for (bIdx, prevState) in prevBeams.enumerated() {
                        // 2nd-order local tempo smoothness: fast runs stay fast, slow runs stay slow,
                        // while Huber cap permits clean switches at fast <-> slow rhythm boundaries.
                        let smoothCost = k >= 2
                            ? 0.50 * huber(log(rate / max(0.04, prevState.rate)), delta: 0.55)
                            : 0
                        let total = prevState.cost + edgeBase + smoothCost
                        if topStates.count < beamWidth || total < topStates[topStates.count - 1].cost {
                            let state = BeamState(cost: total, prevCandidate: i, prevBeam: bIdx, rate: rate)
                            insertSorted(&topStates, state, limit: beamWidth)
                        }
                    }
                }
                layer[j] = topStates
            }
            beams[k] = layer
        }

        // Backtrack lowest-cost complete path.
        var bestCand = -1
        var bestBeam = -1
        var bestCost = Double.infinity
        for (j, states) in beams[count - 1].enumerated() {
            if let first = states.first, first.cost < bestCost {
                bestCost = first.cost
                bestCand = j
                bestBeam = 0
            }
        }
        guard bestCand >= 0, bestCost.isFinite else { return fallbackTimes }

        var times = [TimeInterval](repeating: 0, count: count)
        var candIdx = bestCand
        var beamIdx = bestBeam
        for k in stride(from: count - 1, through: 0, by: -1) {
            times[k] = options[k][candIdx].time
            let state = beams[k][candIdx][beamIdx]
            candIdx = state.prevCandidate
            beamIdx = state.prevBeam
        }
        return times
    }

    private static func sliceOnsets(
        _ onsets: [SingingOnset],
        in range: ClosedRange<TimeInterval>
    ) -> [SingingOnset] {
        guard !onsets.isEmpty, range.upperBound > range.lowerBound else { return [] }
        return onsets
            .filter { range.contains($0.time) }
            .sorted { $0.time < $1.time }
    }

    @inline(__always)
    private static func huber(_ x: Double, delta: Double) -> Double {
        let a = abs(x)
        return a <= delta ? 0.5 * a * a / delta : (a - 0.5 * delta)
    }

    @inline(__always)
    private static func insertSorted(_ list: inout [BeamState], _ element: BeamState, limit: Int) {
        var pos = list.count
        while pos > 0 && element.cost < list[pos - 1].cost {
            pos -= 1
        }
        list.insert(element, at: pos)
        if list.count > limit { list.removeLast() }
    }

    private static func lowerBound(_ sorted: [TimeInterval], value: TimeInterval) -> Int {
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func upperBound(_ sorted: [TimeInterval], value: TimeInterval) -> Int {
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
