#if os(tvOS)
import AVFoundation
import Foundation
import MediaToolbox
import os.lock
import PrimuseKit

/// Karaoke settings shared by every AVPlayer tap on Apple TV, and what the
/// taps report back. The render state itself lives in one
/// `TVKaraokeTapRenderer` per tap: AVPlayer may prepare the next item's tap
/// before it has released the previous one, so nothing a tap allocates can
/// be shared.
///
/// The tap callback is a realtime thread, so settings cross over through a
/// lock the render side only ever *tries*: when the main actor holds it, the
/// previous values are used for that buffer. (tvOS 17 has no Swift atomics.)
final class TVKaraokeProcessor: @unchecked Sendable {
    struct Settings: Equatable, Sendable {
        var isActive = false
        /// 0 keeps the vocal, 1 removes it.
        var reduction: Float = 1
        var capturesVocal = false
        var bypassesVocalReduction = false
        /// An AI-separated vocal to subtract instead of the spectral
        /// remover: address and length of a `TVKaraokeStemTrack`'s samples,
        /// kept alive by the session.
        var stemAddress: UInt = 0
        var stemFrames = 0
        /// Where stem frame 0 sits in the playing item: a CUE track's start
        /// in the whole file, 0 otherwise.
        var stemTimeOffset: Double = 0
        /// Karaoke key change in semitones; 0 bypasses the shifter.
        var keyShift = 0
    }

    struct Report: Sendable {
        var isEffectivelyMono = false
        var isProcessing = false
        var sampleRate: Double = 44_100
    }

    fileprivate let settings = OSAllocatedUnfairLock(initialState: Settings())
    fileprivate let report = OSAllocatedUnfairLock(initialState: Report())
    /// Mono estimate of the removed vocal, for the reference melody.
    let vocalRing = TVKaraokeSampleRing(capacity: 1 << 16)

    func update(_ newValue: Settings) {
        settings.withLock { $0 = newValue }
    }

    var isEffectivelyMono: Bool { report.withLock { $0.isEffectivelyMono } }
    var isProcessing: Bool { report.withLock { $0.isProcessing } }
    /// Sample rate of the most recently prepared tap.
    var sampleRate: Double { report.withLock { $0.sampleRate } }
}

/// One tap's render state. Created with the tap, released in its
/// `finalize` callback.
final class TVKaraokeTapRenderer: @unchecked Sendable {
    private let processor: TVKaraokeProcessor
    private var reducer: KaraokeVocalReducer?
    private var shifter: KaraokePitchShifter?
    private var cachedSettings = TVKaraokeProcessor.Settings()
    private var vocal: UnsafeMutablePointer<Float>?
    private var vocalCapacity = 0
    private var stemGain: Float = 0
    private var shiftedLastBuffer = false
    private var sampleRate: Double = 44_100
    private let shiftPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)

    init(processor: TVKaraokeProcessor) {
        self.processor = processor
    }

    deinit {
        vocal?.deallocate()
        shiftPointers.deallocate()
    }

    /// `prepare`: the tap's processing format is known.
    func configure(format: AudioStreamBasicDescription, maxFrames: Int) {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isPlanar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        if isFloat, isPlanar, format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32 {
            reducer = KaraokeVocalReducer(sampleRate: sampleRate)
            shifter = KaraokePitchShifter(sampleRate: sampleRate, channelCount: 2)
        } else {
            reducer = nil
            shifter = nil
        }
        vocal?.deallocate()
        vocalCapacity = max(4_096, maxFrames)
        vocal = .allocate(capacity: vocalCapacity)
        vocal?.initialize(repeating: 0, count: vocalCapacity)
        let rate = sampleRate
        processor.report.withLock { $0.sampleRate = rate }
    }

    func unprepare() {
        reducer = nil
        shifter = nil
    }

    /// `process`, after the source audio was pulled into `bufferList`.
    /// `sourceTime` is where the buffer starts in the item, in seconds.
    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        startOfStream: Bool,
        sourceTime: Double?
    ) {
        if let latest = processor.settings.withLockIfAvailable({ $0 }) {
            cachedSettings = latest
        }
        guard let reducer, frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count == 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        if startOfStream {
            reducer.restartAfterDiscontinuity()
            processor.vocalRing.reset()
            shifter?.reset()
        }
        let settings = cachedSettings
        let reducesVocal = settings.isActive && !settings.bypassesVocalReduction
        defer { shiftKey(left: left, right: right, frameCount: frameCount, settings: settings) }

        // AI stem: the tap knows exactly which samples of the item this
        // buffer holds, so the stem is subtracted sample for sample.
        if settings.stemFrames > 0,
           let stem = UnsafePointer<Int16>(bitPattern: settings.stemAddress),
           let sourceTime, sourceTime.isFinite, frameCount <= vocalCapacity, let vocal {
            let start = Int(((sourceTime - settings.stemTimeOffset) * sampleRate).rounded())
            let target: Float = reducesVocal ? settings.reduction : 0
            let from = stemGain
            stemGain = target
            let step = (target - from) / Float(frameCount)
            let scale: Float = 1 / 32_767
            for i in 0..<frameCount {
                let index = start + i
                guard index >= 0, index < settings.stemFrames else {
                    vocal[i] = 0
                    continue
                }
                let stemLeft = Float(stem[2 * index]) * scale
                let stemRight = Float(stem[2 * index + 1]) * scale
                let gain = from + step * Float(i)
                left[i] -= gain * stemLeft
                right[i] -= gain * stemRight
                vocal[i] = (stemLeft + stemRight) * 0.5
            }
            if settings.capturesVocal {
                processor.vocalRing.write(vocal, count: frameCount)
            }
            if reducer.phase != .bypassed {
                reducer.process(left: left, right: right, frameCount: frameCount, isActive: false, reduction: 0)
            }
            _ = processor.report.withLockIfAvailable {
                $0.isEffectivelyMono = false
                $0.isProcessing = true
            }
            return
        }
        stemGain = 0
        if !reducesVocal, reducer.phase == .bypassed { return }

        // Very large pulls (rare) are processed in slices the scratch fits.
        var offset = 0
        while offset < frameCount {
            let count = min(vocalCapacity, frameCount - offset)
            let vocalOut = settings.capturesVocal ? vocal : nil
            reducer.process(
                left: left + offset,
                right: right + offset,
                frameCount: count,
                isActive: reducesVocal,
                reduction: settings.reduction,
                vocal: vocalOut
            )
            if let vocalOut {
                processor.vocalRing.write(vocalOut, count: count)
            }
            offset += count
        }
        let mono = reducer.isEffectivelyMono
        let processing = reducer.phase != .bypassed
        _ = processor.report.withLockIfAvailable {
            $0.isEffectivelyMono = mono
            $0.isProcessing = processing
        }
    }

    /// The key change runs last, on whatever the vocal remover left.
    private func shiftKey(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int,
        settings: TVKaraokeProcessor.Settings
    ) {
        guard let shifter else { return }
        guard settings.isActive, settings.keyShift != 0 else {
            shiftedLastBuffer = false
            return
        }
        // Starting afresh avoids replaying stale audio from an earlier use.
        if !shiftedLastBuffer { shifter.reset() }
        shiftedLastBuffer = true
        shiftPointers[0] = left
        shiftPointers[1] = right
        shifter.process(
            UnsafeMutableBufferPointer(start: shiftPointers, count: 2),
            frameCount: frameCount,
            semitones: Double(settings.keyShift)
        )
    }
}

/// A vocal stem at the tap's sample rate, 16-bit interleaved stereo.
/// Immutable once built so the render thread can read it by address.
final class TVKaraokeStemTrack: @unchecked Sendable {
    let songID: String
    let frames: Int
    let sampleRate: Double
    let samples: UnsafeMutablePointer<Int16>

    init(songID: String, left: [Float], right: [Float], sampleRate: Double) {
        self.songID = songID
        frames = min(left.count, right.count)
        self.sampleRate = sampleRate
        samples = .allocate(capacity: max(1, frames * 2))
        for i in 0..<frames {
            samples[2 * i] = Int16(max(-32_768, min(32_767, (left[i] * 32_767).rounded())))
            samples[2 * i + 1] = Int16(max(-32_768, min(32_767, (right[i] * 32_767).rounded())))
        }
    }

    func onsets() -> [KaraokeOnset] {
        let mono = (0..<frames).map { (Float(samples[2 * $0]) + Float(samples[2 * $0 + 1])) / 65_534 }
        return KaraokeOnsetDetector.onsets(in: mono, sampleRate: sampleRate)
    }

    deinit {
        samples.deallocate()
    }
}

/// Single-writer ring for the render thread: writes never block (a busy
/// reader just costs that block), reads copy the newest samples.
final class TVKaraokeSampleRing: @unchecked Sendable {
    private struct State {
        var storage: [Float]
        var written = 0
        var consumed = 0
    }

    let capacity: Int
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int) {
        self.capacity = capacity
        state = OSAllocatedUnfairLock(initialState: State(storage: [Float](repeating: 0, count: capacity)))
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        let capacity = self.capacity
        // The pointer is only read synchronously inside the lock.
        _ = state.withLockIfAvailableUnchecked { state in
            for i in 0..<count {
                state.storage[(state.written + i) % capacity] = samples[i]
            }
            state.written += count
        }
    }

    /// The newest `count` samples when enough new ones arrived since the
    /// last read.
    func readLatest(_ count: Int) -> [Float]? {
        let capacity = self.capacity
        return state.withLock { state -> [Float]? in
            guard count <= capacity, state.written >= count, state.written > state.consumed else { return nil }
            let start = state.written - count
            state.consumed = state.written
            return (0..<count).map { state.storage[(start + $0) % capacity] }
        }
    }

    func reset() {
        _ = state.withLockIfAvailable { $0.consumed = $0.written }
    }
}
#endif
