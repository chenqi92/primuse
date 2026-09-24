import Foundation

/// In-place iterative radix-2 complex FFT over split real/imaginary storage.
///
/// Written for the audio render thread: every table is built in `init`, and
/// `forward`/`inverse` touch only the caller's buffers, so a transform never
/// allocates. The inverse is unnormalized; callers fold `1/size` into their
/// own output scale.
public final class KaraokeComplexFFT: @unchecked Sendable {
    public let size: Int
    private let log2Size: Int
    private let cosTable: UnsafeMutablePointer<Float>
    private let sinTable: UnsafeMutablePointer<Float>
    private let bitReversed: UnsafeMutablePointer<Int>

    public init(size: Int) {
        precondition(size >= 4 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        var bits = 0
        while (1 << bits) < size { bits += 1 }
        log2Size = bits

        let half = size / 2
        cosTable = .allocate(capacity: half)
        sinTable = .allocate(capacity: half)
        for index in 0..<half {
            let angle = -2.0 * Double.pi * Double(index) / Double(size)
            cosTable[index] = Float(cos(angle))
            sinTable[index] = Float(sin(angle))
        }

        bitReversed = .allocate(capacity: size)
        for index in 0..<size {
            var reversed = 0
            var value = index
            for _ in 0..<bits {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            bitReversed[index] = reversed
        }
    }

    deinit {
        cosTable.deallocate()
        sinTable.deallocate()
        bitReversed.deallocate()
    }

    public func forward(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        transform(real: real, imag: imag, inverse: false)
    }

    public func inverse(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        transform(real: real, imag: imag, inverse: true)
    }

    private func transform(
        real: UnsafeMutablePointer<Float>,
        imag: UnsafeMutablePointer<Float>,
        inverse: Bool
    ) {
        let n = size
        let reversed = bitReversed
        for index in 0..<n {
            let target = reversed[index]
            if target > index {
                let r = real[index]; real[index] = real[target]; real[target] = r
                let i = imag[index]; imag[index] = imag[target]; imag[target] = i
            }
        }

        let cosines = cosTable
        let sines = sinTable
        let sign: Float = inverse ? -1 : 1
        var span = 1
        var stride = n / 2
        while span < n {
            var start = 0
            while start < n {
                var twiddle = 0
                for offset in 0..<span {
                    let wr = cosines[twiddle]
                    let wi = sign * sines[twiddle]
                    let even = start + offset
                    let odd = even + span
                    let oddReal = real[odd] * wr - imag[odd] * wi
                    let oddImag = real[odd] * wi + imag[odd] * wr
                    real[odd] = real[even] - oddReal
                    imag[odd] = imag[even] - oddImag
                    real[even] += oddReal
                    imag[even] += oddImag
                    twiddle += stride
                }
                start += span * 2
            }
            span *= 2
            stride /= 2
        }
    }
}

/// Removes centre-panned material (almost always the lead vocal) from a
/// stereo stream while keeping everything panned elsewhere.
///
/// Each short-time spectrum is compared bin by bin: a component that sounds
/// equally loud and in phase in both channels scores near 1 and is subtracted
/// from both sides by `reduction`. The work is restricted to the vocal band so
/// the kick and bass (also centre-panned) survive. The masks are smoothed over
/// time, which trades a little sharpness for far less "underwater" noise.
///
/// Both channels travel through one complex FFT (left in the real part, right
/// in the imaginary part), and every per-bin operation is a real linear
/// combination, so the spectrum stays Hermitian and the inverse is real.
///
/// The processor is allocation-free after `init`; `process` is safe to call
/// from the render thread.
public final class KaraokeVocalReducer: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var fftSize: Int
        /// Below this the centre is left alone so bass and kick survive.
        public var lowCutHz: Double
        /// Fully active above this frequency.
        public var lowFullHz: Double
        /// Fully active below this frequency.
        public var highFullHz: Double
        /// Above this the centre is left alone so cymbals keep their air.
        public var highCutHz: Double
        /// Centre similarity where suppression starts and where it is total.
        public var similarityFloor: Float
        public var similarityCeiling: Float
        /// Per-hop weight of the previous mask (0 = no smoothing).
        public var maskSmoothing: Float
        /// Samples used to fade between the dry and processed signal whenever
        /// the processor is switched on or off.
        public var transitionSamples: Int

        public init(
            fftSize: Int = 2048,
            lowCutHz: Double = 90,
            lowFullHz: Double = 180,
            highFullHz: Double = 7_000,
            highCutHz: Double = 12_000,
            similarityFloor: Float = 0.55,
            similarityCeiling: Float = 0.92,
            maskSmoothing: Float = 0.45,
            transitionSamples: Int = 1_024
        ) {
            self.fftSize = fftSize
            self.lowCutHz = lowCutHz
            self.lowFullHz = lowFullHz
            self.highFullHz = highFullHz
            self.highCutHz = highCutHz
            self.similarityFloor = similarityFloor
            self.similarityCeiling = similarityCeiling
            self.maskSmoothing = maskSmoothing
            self.transitionSamples = transitionSamples
        }
    }

    /// Where the processor is between fully bypassed and fully processing.
    public enum Phase: Equatable, Sendable {
        case bypassed
        /// Filling the analysis window; the dry signal still plays.
        case priming
        case fadingIn
        case processing
        case fadingOut
    }

    public let configuration: Configuration
    public let sampleRate: Double
    /// Delay the processed signal carries relative to the input.
    public let latencySamples: Int

    public private(set) var phase: Phase = .bypassed
    /// Smoothed share of in-band energy that differs between the channels.
    /// Near zero means the recording is effectively mono, where the centre
    /// cannot be told apart from everything else.
    public private(set) var stereoWidth: Float = 1
    /// True while the recording is too close to mono for vocal removal;
    /// suppression is then faded out instead of hollowing out the whole mix.
    public private(set) var isEffectivelyMono = false

    private let fft: KaraokeComplexFFT
    private let size: Int
    private let hop: Int
    private let window: UnsafeMutablePointer<Float>
    private let bandWeight: UnsafeMutablePointer<Float>
    private let previousMask: UnsafeMutablePointer<Float>
    private let inputLeft: UnsafeMutablePointer<Float>
    private let inputRight: UnsafeMutablePointer<Float>
    private let accumulatorLeft: UnsafeMutablePointer<Float>
    private let accumulatorRight: UnsafeMutablePointer<Float>
    private let accumulatorVocal: UnsafeMutablePointer<Float>
    private let outputLeft: UnsafeMutablePointer<Float>
    private let outputRight: UnsafeMutablePointer<Float>
    private let outputVocal: UnsafeMutablePointer<Float>
    private let spectrumReal: UnsafeMutablePointer<Float>
    private let spectrumImag: UnsafeMutablePointer<Float>
    private let vocalReal: UnsafeMutablePointer<Float>
    private let vocalImag: UnsafeMutablePointer<Float>
    /// Where new input enters the analysis FIFO.
    private let fifoStart: Int
    private var rover: Int
    private var primedSamples = 0
    private var transitionPosition = 0
    private var appliedReduction: Float = 0
    /// Set after a discontinuity: priming outputs silence instead of dry.
    private var fadesFromSilence = false
    private let outputScale: Float

    public init(sampleRate: Double, configuration: Configuration = Configuration()) {
        let size = configuration.fftSize
        precondition(size >= 256 && size & (size - 1) == 0)
        self.configuration = configuration
        self.sampleRate = sampleRate
        self.size = size
        hop = size / 4
        fifoStart = size - size / 4
        // One hop of FIFO fill plus the hop the output waits to be read.
        latencySamples = size
        rover = size - size / 4
        fft = KaraokeComplexFFT(size: size)

        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }

        window = buffer(size)
        // sqrt of a periodic Hann: applied on analysis and synthesis, the
        // product is a Hann whose 75 %-overlap sum is exactly 2.
        for index in 0..<size {
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(size))
            window[index] = Float(hann.squareRoot())
        }
        outputScale = 1 / (2 * Float(size))

        let bins = size / 2 + 1
        bandWeight = buffer(bins)
        let binHz = sampleRate / Double(size)
        for bin in 0..<bins {
            bandWeight[bin] = Float(Self.bandWeight(
                frequency: Double(bin) * binHz,
                configuration: configuration
            ))
        }
        bandWeight[0] = 0
        bandWeight[bins - 1] = 0
        previousMask = buffer(bins)

        inputLeft = buffer(size)
        inputRight = buffer(size)
        accumulatorLeft = buffer(size)
        accumulatorRight = buffer(size)
        accumulatorVocal = buffer(size)
        outputLeft = buffer(size)
        outputRight = buffer(size)
        outputVocal = buffer(size)
        spectrumReal = buffer(size)
        spectrumImag = buffer(size)
        vocalReal = buffer(size)
        vocalImag = buffer(size)
    }

    deinit {
        for pointer in [
            window, bandWeight, previousMask, inputLeft, inputRight,
            accumulatorLeft, accumulatorRight, accumulatorVocal,
            outputLeft, outputRight, outputVocal,
            spectrumReal, spectrumImag, vocalReal, vocalImag,
        ] {
            pointer.deallocate()
        }
    }

    static func bandWeight(frequency: Double, configuration: Configuration) -> Double {
        if frequency <= configuration.lowCutHz || frequency >= configuration.highCutHz { return 0 }
        if frequency < configuration.lowFullHz {
            return smoothstep(
                (frequency - configuration.lowCutHz)
                    / (configuration.lowFullHz - configuration.lowCutHz)
            )
        }
        if frequency > configuration.highFullHz {
            return 1 - smoothstep(
                (frequency - configuration.highFullHz)
                    / (configuration.highCutHz - configuration.highFullHz)
            )
        }
        return 1
    }

    @inline(__always)
    static func smoothstep(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    /// Clears every buffer and returns to the bypassed state.
    /// Called from the render thread at the end of a fade-out, so it
    /// touches each buffer directly rather than through a temporary array.
    public func reset() {
        clearBuffers()
        primedSamples = 0
        transitionPosition = 0
        appliedReduction = 0
        phase = .bypassed
        stereoWidth = 1
        isEffectivelyMono = false
        fadesFromSilence = false
    }

    /// The input jumped (seek, new song): drops the audio still in the delay
    /// line so none of the old position is heard, then fades the new audio in
    /// from silence. The dry signal is not played meanwhile, since that would
    /// let the vocal through. Does nothing while bypassed.
    public func restartAfterDiscontinuity() {
        guard phase != .bypassed else { return }
        if phase == .fadingOut {
            reset()
            return
        }
        clearBuffers()
        phase = .priming
        primedSamples = 0
        transitionPosition = 0
        fadesFromSilence = true
    }

    private func clearBuffers() {
        inputLeft.update(repeating: 0, count: size)
        inputRight.update(repeating: 0, count: size)
        accumulatorLeft.update(repeating: 0, count: size)
        accumulatorRight.update(repeating: 0, count: size)
        accumulatorVocal.update(repeating: 0, count: size)
        outputLeft.update(repeating: 0, count: size)
        outputRight.update(repeating: 0, count: size)
        outputVocal.update(repeating: 0, count: size)
        previousMask.update(repeating: 0, count: size / 2 + 1)
        rover = fifoStart
    }

    /// Processes `frameCount` samples of both channels in place.
    ///
    /// - Parameters:
    ///   - isActive: whether suppression should run. Switching fades between
    ///     the dry and processed paths instead of cutting.
    ///   - reduction: 0 keeps the vocal, 1 removes as much centre as the mask
    ///     allows. Changes are ramped per hop.
    ///   - vocal: optional mono destination for the estimated centre (vocal)
    ///     signal, aligned with the processed output. Written with zeros while
    ///     no estimate exists.
    public func process(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int,
        isActive: Bool,
        reduction: Float,
        vocal: UnsafeMutablePointer<Float>? = nil
    ) {
        if phase == .bypassed {
            guard isActive else {
                vocal?.update(repeating: 0, count: frameCount)
                return
            }
            phase = .priming
            primedSamples = 0
        } else if !isActive, phase != .fadingOut {
            // Priming never produced audible output, so it can stop at once.
            if phase == .priming {
                reset()
                vocal?.update(repeating: 0, count: frameCount)
                return
            }
            // Resume the fade from wherever a fade-in had reached.
            transitionPosition = phase == .fadingIn
                ? configuration.transitionSamples - transitionPosition
                : 0
            fadesFromSilence = false
            phase = .fadingOut
        } else if isActive, phase == .fadingOut {
            transitionPosition = configuration.transitionSamples - transitionPosition
            phase = .fadingIn
        }

        let target = min(1, max(0, reduction))
        let transitionLength = max(1, configuration.transitionSamples)
        let inL = inputLeft
        let inR = inputRight
        let outL = outputLeft
        let outR = outputRight
        let outV = outputVocal
        let latency = latencySamples
        let fifo = fifoStart

        for index in 0..<frameCount {
            let dryLeft = left[index]
            let dryRight = right[index]
            inL[rover] = dryLeft
            inR[rover] = dryRight
            let wetLeft = outL[rover - fifo]
            let wetRight = outR[rover - fifo]
            let wetVocal = outV[rover - fifo]
            rover += 1
            if rover >= size {
                rover = fifo
                processFrame(targetReduction: target)
            }

            switch phase {
            case .bypassed:
                vocal?[index] = 0
            case .priming:
                // Output stays dry until the delay line holds real audio.
                if fadesFromSilence {
                    left[index] = 0
                    right[index] = 0
                }
                vocal?[index] = 0
                primedSamples += 1
                if primedSamples >= latency {
                    phase = .fadingIn
                    transitionPosition = 0
                }
            case .fadingIn:
                let wet = Float(transitionPosition) / Float(transitionLength)
                let dry = fadesFromSilence ? 0 : 1 - wet
                left[index] = dryLeft * dry + wetLeft * wet
                right[index] = dryRight * dry + wetRight * wet
                vocal?[index] = wetVocal * wet
                transitionPosition += 1
                if transitionPosition >= transitionLength {
                    phase = .processing
                    fadesFromSilence = false
                }
            case .processing:
                left[index] = wetLeft
                right[index] = wetRight
                vocal?[index] = wetVocal
            case .fadingOut:
                let wet = 1 - Float(transitionPosition) / Float(transitionLength)
                left[index] = dryLeft * (1 - wet) + wetLeft * wet
                right[index] = dryRight * (1 - wet) + wetRight * wet
                vocal?[index] = wetVocal * wet
                transitionPosition += 1
                if transitionPosition >= transitionLength {
                    reset()
                }
            }
        }
    }

    private func processFrame(targetReduction: Float) {
        let n = size
        let re = spectrumReal
        let im = spectrumImag
        let win = window
        for index in 0..<n {
            re[index] = inputLeft[index] * win[index]
            im[index] = inputRight[index] * win[index]
        }
        fft.forward(real: re, imag: im)

        // Ramp towards the requested reduction; a full swing takes ~0.2 s.
        let step: Float = 0.06
        if appliedReduction < targetReduction {
            appliedReduction = min(targetReduction, appliedReduction + step)
        } else if appliedReduction > targetReduction {
            appliedReduction = max(targetReduction, appliedReduction - step)
        }
        let monoFade = isEffectivelyMono ? Float(0) : Float(1)
        let gain = appliedReduction * monoFade

        let floor = configuration.similarityFloor
        let span = max(0.0001, configuration.similarityCeiling - floor)
        let smoothing = configuration.maskSmoothing
        let vr = vocalReal
        let vi = vocalImag
        vr[0] = 0; vi[0] = 0
        vr[n / 2] = 0; vi[n / 2] = 0

        var sideEnergy: Float = 0
        var totalEnergy: Float = 0
        for bin in 1..<(n / 2) {
            let mirror = n - bin
            let a = re[bin], b = im[bin]
            let c = re[mirror], d = im[mirror]
            // Unpack the two real spectra from the shared complex one.
            let leftReal = (a + c) * 0.5
            let leftImag = (b - d) * 0.5
            let rightReal = (b + d) * 0.5
            let rightImag = (c - a) * 0.5

            let leftPower = leftReal * leftReal + leftImag * leftImag
            let rightPower = rightReal * rightReal + rightImag * rightImag
            let power = leftPower + rightPower
            let band = bandWeight[bin]

            var mask: Float = 0
            if power > 1e-12 {
                // 1 when both channels carry the same component, 0 when it
                // lives in one channel only, negative when out of phase.
                let similarity = 2 * (leftReal * rightReal + leftImag * rightImag) / power
                let x = min(1, max(0, (similarity - floor) / span))
                mask = x * x * (3 - 2 * x) * band
                if band > 0 {
                    let sideReal = leftReal - rightReal
                    let sideImag = leftImag - rightImag
                    sideEnergy += (sideReal * sideReal + sideImag * sideImag) * band
                    totalEnergy += power * band
                }
            }
            mask = smoothing * previousMask[bin] + (1 - smoothing) * mask
            previousMask[bin] = mask

            let centreReal = mask * (leftReal + rightReal) * 0.5
            let centreImag = mask * (leftImag + rightImag) * 0.5
            let newLeftReal = leftReal - gain * centreReal
            let newLeftImag = leftImag - gain * centreImag
            let newRightReal = rightReal - gain * centreReal
            let newRightImag = rightImag - gain * centreImag

            // Repack: Z[k] = L + iR, Z[N-k] = conj(L) + i*conj(R).
            re[bin] = newLeftReal - newRightImag
            im[bin] = newLeftImag + newRightReal
            re[mirror] = newLeftReal + newRightImag
            im[mirror] = newRightReal - newLeftImag

            vr[bin] = centreReal
            vi[bin] = centreImag
            vr[mirror] = centreReal
            vi[mirror] = -centreImag
        }

        if totalEnergy > 1e-9 {
            let width = min(1, sideEnergy / totalEnergy)
            stereoWidth = 0.9 * stereoWidth + 0.1 * width
            // Hysteresis keeps a quiet, narrow passage from flickering.
            if isEffectivelyMono {
                if stereoWidth > 0.02 { isEffectivelyMono = false }
            } else if stereoWidth < 0.008 {
                isEffectivelyMono = true
            }
        }

        fft.inverse(real: re, imag: im)
        fft.inverse(real: vr, imag: vi)

        let scale = outputScale
        for index in 0..<n {
            let w = win[index] * scale
            accumulatorLeft[index] += re[index] * w
            accumulatorRight[index] += im[index] * w
            accumulatorVocal[index] += vr[index] * w
        }
        for index in 0..<hop {
            outputLeft[index] = accumulatorLeft[index]
            outputRight[index] = accumulatorRight[index]
            outputVocal[index] = accumulatorVocal[index]
        }
        // Overlapping shifts: memmove, never a forward element copy.
        shiftDown(accumulatorLeft, zeroFillingTail: true)
        shiftDown(accumulatorRight, zeroFillingTail: true)
        shiftDown(accumulatorVocal, zeroFillingTail: true)
        shiftDown(inputLeft, zeroFillingTail: false)
        shiftDown(inputRight, zeroFillingTail: false)
    }

    @inline(__always)
    private func shiftDown(_ pointer: UnsafeMutablePointer<Float>, zeroFillingTail: Bool) {
        let remaining = size - hop
        memmove(pointer, pointer + hop, remaining * MemoryLayout<Float>.stride)
        if zeroFillingTail {
            (pointer + remaining).update(repeating: 0, count: hop)
        }
    }
}
