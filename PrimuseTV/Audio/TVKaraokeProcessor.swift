#if os(tvOS)
import AVFoundation
import Foundation
import MediaToolbox
import os.lock
import PrimuseKit

/// Karaoke vocal reduction inside the AVPlayer processing tap on Apple TV.
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
        /// An AI-separated vocal to subtract instead of the spectral
        /// remover: address and length of a `TVKaraokeStemTrack`'s samples,
        /// kept alive by the session.
        var stemAddress: UInt = 0
        var stemFrames = 0
    }

    private struct Report: Sendable {
        var isEffectivelyMono = false
        var isProcessing = false
    }

    private let settings = OSAllocatedUnfairLock(initialState: Settings())
    private let report = OSAllocatedUnfairLock(initialState: Report())
    /// Mono estimate of the removed vocal, for the reference melody.
    let vocalRing = TVKaraokeSampleRing(capacity: 1 << 16)

    // Render-thread state.
    private var reducer: KaraokeVocalReducer?
    private var cachedSettings = Settings()
    private var vocal: UnsafeMutablePointer<Float>?
    private var vocalCapacity = 0
    private var stemGain: Float = 0
    private(set) var sampleRate: Double = 44_100

    deinit {
        vocal?.deallocate()
    }

    // MARK: Main actor

    func update(_ newValue: Settings) {
        settings.withLock { $0 = newValue }
    }

    var isEffectivelyMono: Bool { report.withLock { $0.isEffectivelyMono } }
    var isProcessing: Bool { report.withLock { $0.isProcessing } }

    // MARK: Tap callbacks

    /// `prepare`: the tap's processing format is known.
    func configure(format: AudioStreamBasicDescription, maxFrames: Int) {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isPlanar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        if isFloat, isPlanar, format.mChannelsPerFrame == 2, format.mBitsPerChannel == 32 {
            reducer = KaraokeVocalReducer(sampleRate: sampleRate)
        } else {
            reducer = nil
        }
        vocal?.deallocate()
        vocalCapacity = max(4_096, maxFrames)
        vocal = .allocate(capacity: vocalCapacity)
        vocal?.initialize(repeating: 0, count: vocalCapacity)
    }

    func unprepare() {
        reducer = nil
    }

    /// `process`, after the source audio was pulled into `bufferList`.
    /// `sourceTime` is where the buffer starts in the song, in seconds.
    func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        startOfStream: Bool,
        sourceTime: Double?
    ) {
        if let latest = settings.withLockIfAvailable({ $0 }) {
            cachedSettings = latest
        }
        guard let reducer, frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count == 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        if startOfStream {
            reducer.restartAfterDiscontinuity()
            vocalRing.reset()
        }
        let settings = cachedSettings

        // AI stem: the tap knows exactly which song samples this buffer
        // holds, so the stem is subtracted sample for sample.
        if settings.stemFrames > 0,
           let stem = UnsafePointer<Int16>(bitPattern: settings.stemAddress),
           let sourceTime, sourceTime.isFinite, frameCount <= vocalCapacity, let vocal {
            let start = Int((sourceTime * sampleRate).rounded())
            let target: Float = settings.isActive ? settings.reduction : 0
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
                vocalRing.write(vocal, count: frameCount)
            }
            if reducer.phase != .bypassed {
                reducer.process(left: left, right: right, frameCount: frameCount, isActive: false, reduction: 0)
            }
            _ = report.withLockIfAvailable { $0 = Report(isEffectivelyMono: false, isProcessing: true) }
            return
        }
        stemGain = 0
        if !settings.isActive, reducer.phase == .bypassed { return }

        // Very large pulls (rare) are processed in slices the scratch fits.
        var offset = 0
        while offset < frameCount {
            let count = min(vocalCapacity, frameCount - offset)
            let vocalOut = settings.capturesVocal ? vocal : nil
            reducer.process(
                left: left + offset,
                right: right + offset,
                frameCount: count,
                isActive: settings.isActive,
                reduction: settings.reduction,
                vocal: vocalOut
            )
            if let vocalOut {
                vocalRing.write(vocalOut, count: count)
            }
            offset += count
        }
        let snapshot = Report(isEffectivelyMono: reducer.isEffectivelyMono, isProcessing: reducer.phase != .bypassed)
        _ = report.withLockIfAvailable { $0 = snapshot }
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
