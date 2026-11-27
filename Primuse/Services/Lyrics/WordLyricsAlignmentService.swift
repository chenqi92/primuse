@preconcurrency import AVFoundation
import CoreML
import Foundation
import Observation
import PrimuseKit
import SFBAudioEngine
#if canImport(BackgroundAssets)
import BackgroundAssets
import System
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Apple-Hosted Background Assets Model

/// Where the optional high-accuracy CTC lyrics alignment model comes from.
/// Hosted via Apple Background Assets (`onDemand`, iOS / macOS / tvOS 26.4+),
/// sharing `PrimuseKaraokeModelDownloader` with the karaoke vocal and offline
/// translation packs. Debug builds can point at a local directory via
/// `PRIMUSE_LYRICS_ALIGNMENT_MODEL`.
enum LyricsAlignmentModel {
    static let assetPackID = "LyricsAlignmentModel"
    static let manifestFile = "alignment-model.json"
    static let requiredModelFiles = ["coremldata.bin", "model.mil"]
    /// Approximate download size of INT8-quantized omniASR-CTC-300M (~320 MB).
    static let approximateDownloadBytes: Int64 = 320_000_000

    static var formattedDownloadSize: String {
        ByteCountFormatter.string(fromByteCount: approximateDownloadBytes, countStyle: .file)
    }

    #if DEBUG
    static var debugOverrideDirectory: URL? {
        ProcessInfo.processInfo.environment["PRIMUSE_LYRICS_ALIGNMENT_MODEL"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #endif

    static var isSystemSupported: Bool {
        #if DEBUG
        if debugOverrideDirectory != nil { return true }
        #endif
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *) {
            return BackgroundAssetsPrerequisites.isSatisfied
        }
        return false
    }

    struct Located: Sendable, Equatable {
        let manifest: WordLyricsAlignmentManifest
        let modelURL: URL
        let vocabularyURL: URL
    }

    /// Returns the locally installed, verified model pack, or nil when missing/incomplete.
    nonisolated static func locate() -> Located? {
        guard let manifestURL = fileURL(manifestFile),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = WordLyricsAlignmentManifest.decode(data),
              let vocabURL = fileURL(manifest.vocabulary),
              FileManager.default.fileExists(atPath: vocabURL.path),
              let modelURL = fileURL(manifest.model) else {
            return nil
        }
        let fm = FileManager.default
        let missing = requiredModelFiles.filter {
            !fm.fileExists(atPath: modelURL.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            plog("⚠️ WordAlign: model incomplete missing=\(missing)")
            return nil
        }
        return Located(manifest: manifest, modelURL: modelURL, vocabularyURL: vocabURL)
    }

    private nonisolated static func fileURL(_ path: String) -> URL? {
        #if DEBUG
        if let dir = debugOverrideDirectory {
            return dir.appendingPathComponent(path)
        }
        #endif
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *),
           let manager = BackgroundAssetsPrerequisites.manager,
           manager.assetPackIsAvailableLocally(withID: assetPackID) {
            return try? manager.url(for: FilePath(path))
        }
        #endif
        return nil
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws -> Located {
        if let located = locate() { return located }
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *), let manager = BackgroundAssetsPrerequisites.manager {
            let pack = try await AppleHostedAssetPackResolver.assetPack(withID: assetPackID, manager: manager)
            let watcher = Task {
                for await update in manager.statusUpdates(forAssetPackWithID: assetPackID) {
                    if case .downloading(_, let fraction) = update {
                        progress(fraction.fractionCompleted)
                    }
                }
            }
            defer { watcher.cancel() }
            try await manager.ensureLocalAvailability(of: pack, requireLatestVersion: false)
            if let located = locate() { return located }
        }
        #endif
        throw WordLyricsAlignmentError.modelUnavailable
    }

    static func remove() async {
        #if canImport(BackgroundAssets)
        if #available(iOS 26.4, macOS 26.4, tvOS 26.4, *), let manager = BackgroundAssetsPrerequisites.manager {
            try? await manager.remove(assetPackWithID: assetPackID)
        }
        #endif
    }
}

/// Guards Core ML compilation against MPSGraph GPU cache aborts on tvOS and
/// remembers if a previous load on the same OS build never returned.
private enum WordLyricsAlignmentModelLoadGuard {
    private static let pendingKey = "wordAlignModelLoadPending"
    private static let cpuOnlySystemKey = "wordAlignModelCPUOnlySystem"
    private static let processToken = UUID().uuidString

    static func beginLoad(preferred: String?) -> MLComputeUnits {
        #if os(tvOS)
        return .cpuOnly
        #else
        let defaults = UserDefaults.standard
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        if let pending = defaults.dictionary(forKey: pendingKey) as? [String: String],
           pending["system"] == system,
           pending["process"] != processToken,
           defaults.string(forKey: cpuOnlySystemKey) != system {
            defaults.set(system, forKey: cpuOnlySystemKey)
            plog("⚠️ WordAlign: previous model load aborted on \(system); falling back to cpuOnly")
        }
        let cpuOnly = defaults.string(forKey: cpuOnlySystemKey) == system
        defaults.set(["system": system, "process": processToken], forKey: pendingKey)
        if cpuOnly { return .cpuOnly }
        switch preferred {
        case "cpuOnly": return .cpuOnly
        case "all": return .all
        default: return .cpuAndGPU
        }
        #endif
    }

    static func endLoad() {
        let defaults = UserDefaults.standard
        guard (defaults.dictionary(forKey: pendingKey) as? [String: String])?["process"] == processToken else { return }
        defaults.removeObject(forKey: pendingKey)
    }
}

enum WordLyricsAlignmentError: Error {
    case modelUnavailable
    case invalidVocabulary
    case unexpectedOutput
    case unreadableAudio
    case tooLong
}

// MARK: - Core ML CTC Predictor

/// Owns the loaded Core ML CTC alignment model and runs chunked inference off the main actor.
private actor WordLyricsAlignmentPredictor {
    private var loaded: (located: LyricsAlignmentModel.Located, model: MLModel, vocab: CTCLyricsVocabulary)?
    private var idleUnloadTask: Task<Void, Never>?

    func unload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        loaded = nil
    }

    func vocabulary(for located: LyricsAlignmentModel.Located) throws -> CTCLyricsVocabulary {
        let entry = try ensureLoaded(located)
        scheduleIdleUnload()
        return entry.vocab
    }

    func emissions(
        for located: LyricsAlignmentModel.Located,
        chunkSamples: [Float],
        startTime: TimeInterval,
        neededTokenIDs: [Int]
    ) throws -> CTCEmissionSlice {
        let entry = try ensureLoaded(located)
        scheduleIdleUnload()

        let manifest = located.manifest
        let targetCount = manifest.chunkSamples
        return try autoreleasepool {
            let inputArray = try MLMultiArray(shape: [1, NSNumber(value: targetCount)], dataType: .float32)
            let ptr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
            let copyCount = min(chunkSamples.count, targetCount)
            if copyCount > 0 {
                chunkSamples.withUnsafeBufferPointer { src in
                    ptr.update(from: src.baseAddress!, count: copyCount)
                }
            }
            if copyCount < targetCount {
                ptr.advanced(by: copyCount).initialize(repeating: 0, count: targetCount - copyCount)
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "waveform": MLFeatureValue(multiArray: inputArray),
            ])
            let output = try entry.model.prediction(from: provider)
            guard let logProbs = output.featureValue(for: "log_probs")?.multiArrayValue
                ?? output.featureNames.compactMap({ output.featureValue(for: $0)?.multiArrayValue }).first else {
                throw WordLyricsAlignmentError.unexpectedOutput
            }

            let dims = logProbs.shape.map(\.intValue)
            let strides = logProbs.strides.map(\.intValue)
            let frameCount: Int
            let vocabSize: Int
            let frameStride: Int
            let vocabStride: Int
            if dims.count == 3 {
                frameCount = dims[1]
                vocabSize = dims[2]
                frameStride = strides[1]
                vocabStride = strides[2]
            } else if dims.count == 2 {
                frameCount = dims[0]
                vocabSize = dims[1]
                frameStride = strides[0]
                vocabStride = strides[1]
            } else {
                throw WordLyricsAlignmentError.unexpectedOutput
            }

            let colCount = neededTokenIDs.count
            var compact = [Float](repeating: -30, count: frameCount * colCount)

            switch logProbs.dataType {
            case .float32:
                let base = logProbs.dataPointer.assumingMemoryBound(to: Float.self)
                for f in 0..<frameCount {
                    let rowBase = f * frameStride
                    let dstBase = f * colCount
                    for c in 0..<colCount {
                        let tokID = neededTokenIDs[c]
                        if tokID >= 0 && tokID < vocabSize {
                            compact[dstBase + c] = base[rowBase + tokID * vocabStride]
                        }
                    }
                }
            case .float16:
                // Bit-level IEEE-754 half-precision decode compiles cleanly on both arm64 and Intel macOS.
                let base = logProbs.dataPointer.assumingMemoryBound(to: UInt16.self)
                for f in 0..<frameCount {
                    let rowBase = f * frameStride
                    let dstBase = f * colCount
                    for c in 0..<colCount {
                        let tokID = neededTokenIDs[c]
                        if tokID >= 0 && tokID < vocabSize {
                            compact[dstBase + c] = Self.decodeFloat16(base[rowBase + tokID * vocabStride])
                        }
                    }
                }
            default:
                for f in 0..<frameCount {
                    let dstBase = f * colCount
                    for c in 0..<colCount {
                        let tokID = neededTokenIDs[c]
                        if tokID >= 0 && tokID < vocabSize {
                            let idx = dims.count == 3 ? [0, f, tokID] : [f, tokID]
                            compact[dstBase + c] = logProbs[idx.map(NSNumber.init)].floatValue
                        }
                    }
                }
            }

            return CTCEmissionSlice(
                startTime: startTime,
                frameDuration: manifest.frameDuration,
                frameOffset: manifest.frameOffsetSeconds,
                frameCount: frameCount,
                blankID: manifest.blankID,
                tokenIDs: neededTokenIDs,
                logProbs: compact
            )
        }
    }

    private func ensureLoaded(
        _ located: LyricsAlignmentModel.Located
    ) throws -> (located: LyricsAlignmentModel.Located, model: MLModel, vocab: CTCLyricsVocabulary) {
        if let loaded, loaded.located == located { return loaded }
        let vocabData = try Data(contentsOf: located.vocabularyURL)
        guard let vocab = CTCLyricsVocabulary.decode(vocabularyJSON: vocabData, manifest: located.manifest) else {
            throw WordLyricsAlignmentError.invalidVocabulary
        }
        let computeUnits = WordLyricsAlignmentModelLoadGuard.beginLoad(preferred: located.manifest.preferredComputeUnits)
        defer { WordLyricsAlignmentModelLoadGuard.endLoad() }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let compiledURL = located.modelURL.pathExtension == "mlmodelc"
            ? located.modelURL
            : try MLModel.compileModel(at: located.modelURL)
        let started = Date()
        let model = try MLModel(contentsOf: compiledURL, configuration: config)
        plog("🎵 WordAlign: loaded CTC model v=\(located.manifest.version) units=\(computeUnits.rawValue) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        let entry = (located, model, vocab)
        loaded = entry
        return entry
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private static func decodeFloat16(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exp = Int((bits >> 10) & 0x1F)
        let mant = UInt32(bits & 0x03FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            // Subnormal half-float
            var m = mant
            var e = -14
            while (m & 0x0400) == 0 {
                m <<= 1
                e -= 1
            }
            m &= 0x03FF
            let fExp = UInt32(e + 127) << 23
            return Float(bitPattern: sign | fExp | (m << 13))
        } else if exp == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13))
        } else {
            let fExp = UInt32(exp - 15 + 127) << 23
            return Float(bitPattern: sign | fExp | (mant << 13))
        }
    }
}

// MARK: - 16 kHz Vocal Audio Loader

private enum WordLyricsAudioLoader {
    static let targetSampleRate: Double = 16_000
    static let maximumDuration: TimeInterval = 15 * 60 // 15 min safety cap

    struct PreparedAudio: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let isSeparatedVocal: Bool
    }

    /// Loads 16 kHz mono vocal audio: prefers an existing HTDemucs vocal stem on disk;
    /// otherwise decodes the local/cached song file and runs fast stereo center-channel vocal emphasis.
    static func load(
        song: Song,
        audioFile: KaraokeAudioFile?
    ) throws -> PreparedAudio {
        defer {
            if let audioFile, audioFile.removeAfterDecoding {
                try? FileManager.default.removeItem(at: audioFile.url)
            }
        }
        try Task.checkCancellation()

        // 1. Prefer cached HTDemucs separated vocal stem whenever available.
        let stemURL = KaraokeSeparationService.stemURL(for: song)
        if FileManager.default.fileExists(atPath: stemURL.path),
           let data = try? Data(contentsOf: stemURL, options: .mappedIfSafe),
           let stem = KaraokeStemFile.decodeMono(data),
           !stem.samples.isEmpty,
           stem.header.sampleRate > 0 {
            let duration = Double(stem.samples.count) / stem.header.sampleRate
            if duration <= maximumDuration {
                let resampled = resampleMono(stem.samples, from: stem.header.sampleRate, to: targetSampleRate)
                return PreparedAudio(samples: resampled, sampleRate: targetSampleRate, isSeparatedVocal: true)
            }
        }

        // 2. Otherwise decode local/cached track and extract center-channel vocal mono at 16 kHz.
        guard let audioFile, audioFile.url.isFileURL else {
            throw WordLyricsAlignmentError.unreadableAudio
        }
        let cueStart = max(0, song.cueStartTime.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        let cueEnd = song.cueEndTime.flatMap { $0.isFinite && $0 > cueStart ? $0 : nil }
        let (left, right, rate) = try decodeStereo(url: audioFile.url, start: cueStart, end: cueEnd)
        try Task.checkCancellation()
        guard !left.isEmpty, rate > 0 else { throw WordLyricsAlignmentError.unreadableAudio }
        let duration = Double(left.count) / rate
        guard duration <= maximumDuration else { throw WordLyricsAlignmentError.tooLong }

        let left16 = resampleMono(left, from: rate, to: targetSampleRate)
        let right16 = right.map { resampleMono($0, from: rate, to: targetSampleRate) }
        let vocal16 = StereoVocalPreprocessor.extractVocalMono(
            left: left16,
            right: right16,
            sampleRate: targetSampleRate
        )
        return PreparedAudio(samples: vocal16, sampleRate: targetSampleRate, isSeparatedVocal: false)
    }

    private static func decodeStereo(
        url: URL,
        start: TimeInterval,
        end: TimeInterval?
    ) throws -> (left: [Float], right: [Float]?, sampleRate: Double) {
        if let result = try? decodeWithAVAudioFile(url: url, start: start, end: end) {
            return result
        }
        if let result = try? decodeWithFFmpeg(url: url, start: start, end: end) {
            return result
        }
        return try decodeWithSFB(url: url, start: start, end: end)
    }

    private static func decodeWithAVAudioFile(
        url: URL,
        start: TimeInterval,
        end: TimeInterval?
    ) throws -> (left: [Float], right: [Float]?, sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate >= 8_000 else { throw WordLyricsAlignmentError.unreadableAudio }
        let firstFrame = AVAudioFramePosition((start * rate).rounded())
        let lastFrame = end.map { AVAudioFramePosition(($0 * rate).rounded()) } ?? file.length
        let totalFrames = max(0, min(file.length, lastFrame) - firstFrame)
        guard firstFrame >= 0, totalFrames > 0 else { throw WordLyricsAlignmentError.unreadableAudio }
        guard Double(totalFrames) / rate <= maximumDuration else { throw WordLyricsAlignmentError.tooLong }

        file.framePosition = firstFrame
        let channels = Int(format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw WordLyricsAlignmentError.unreadableAudio
        }
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(Int(totalFrames))
        if channels >= 2 { right.reserveCapacity(Int(totalFrames)) }

        var remaining = totalFrames
        while remaining > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(remaining, 16_384))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            let n = Int(buffer.frameLength)
            left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            if channels >= 2 {
                right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: n))
            }
            remaining -= AVAudioFramePosition(n)
        }
        return (left, channels >= 2 ? right : nil, rate)
    }

    private static func decodeWithFFmpeg(
        url: URL,
        start: TimeInterval,
        end: TimeInterval?
    ) throws -> (left: [Float], right: [Float]?, sampleRate: Double) {
        let bridge = try FFmpegDecoderBridge(url: url, ioTimeout: 10)
        var collector = PCMWindowCollector(start: start, end: end, maxDuration: maximumDuration)
        while true {
            try Task.checkCancellation()
            guard let buffer = try bridge.readNextBuffer().buffer, buffer.frameLength > 0 else { break }
            if try collector.append(buffer) { break }
        }
        return try collector.finish()
    }

    private static func decodeWithSFB(
        url: URL,
        start: TimeInterval,
        end: TimeInterval?
    ) throws -> (left: [Float], right: [Float]?, sampleRate: Double) {
        let decoder: AudioDecoder
        if AudioFormat.from(fileExtension: url.pathExtension)?.isTrackerModule == true {
            decoder = try AudioDecoder(url: url, decoderName: .module)
        } else {
            decoder = try AudioDecoder(url: url)
        }
        try decoder.open()
        defer { try? decoder.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 8_192) else {
            throw WordLyricsAlignmentError.unreadableAudio
        }
        var collector = PCMWindowCollector(start: start, end: end, maxDuration: maximumDuration)
        while true {
            try Task.checkCancellation()
            try decoder.decode(into: buffer, length: 8_192)
            if buffer.frameLength == 0 { break }
            if try collector.append(buffer) { break }
        }
        return try collector.finish()
    }

    private struct PCMWindowCollector {
        let start: TimeInterval
        let end: TimeInterval?
        let maxDuration: TimeInterval
        var sampleRate: Double?
        var left: [Float] = []
        var right: [Float] = []
        var hasStereo = false
        var elapsed: TimeInterval = 0

        mutating func append(_ buffer: AVAudioPCMBuffer) throws -> Bool {
            let format = buffer.format
            let rate = format.sampleRate
            guard rate.isFinite, rate >= 8_000 else { throw WordLyricsAlignmentError.unreadableAudio }
            if let existing = sampleRate, abs(existing - rate) > 1 { throw WordLyricsAlignmentError.unreadableAudio }
            sampleRate = rate
            let channels = Int(format.channelCount)
            guard channels >= 1 else { throw WordLyricsAlignmentError.unreadableAudio }
            if channels >= 2 { hasStereo = true }

            let frames = Int(buffer.frameLength)
            let limit = end ?? .infinity
            let lower = Int(min(Double(frames), max(0, ((start - elapsed) * rate).rounded(.up))))
            let upper = Int(min(Double(frames), max(0, ((limit - elapsed) * rate).rounded(.up))))
            defer { elapsed += Double(frames) / rate }
            guard upper > lower else { return elapsed >= limit }

            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            left.reserveCapacity(left.count + (upper - lower))
            if hasStereo { right.reserveCapacity(right.count + (upper - lower)) }

            @inline(__always)
            func sample(channel: Int, frame: Int) throws -> Float {
                let data = buffers[format.isInterleaved ? 0 : channel].mData
                guard let data else { throw WordLyricsAlignmentError.unreadableAudio }
                let offset = format.isInterleaved ? frame * channels + channel : frame
                switch format.commonFormat {
                case .pcmFormatFloat32: return data.assumingMemoryBound(to: Float.self)[offset]
                case .pcmFormatFloat64: return Float(data.assumingMemoryBound(to: Double.self)[offset])
                case .pcmFormatInt16: return Float(data.assumingMemoryBound(to: Int16.self)[offset]) / 32_768
                case .pcmFormatInt32: return Float(Double(data.assumingMemoryBound(to: Int32.self)[offset]) / 2_147_483_648)
                default: throw WordLyricsAlignmentError.unreadableAudio
                }
            }

            for f in lower..<upper {
                left.append(try sample(channel: 0, frame: f))
                if hasStereo {
                    right.append(try sample(channel: min(1, channels - 1), frame: f))
                }
            }
            if Double(left.count) / rate > maxDuration { throw WordLyricsAlignmentError.tooLong }
            return elapsed + Double(frames) / rate >= limit
        }

        func finish() throws -> (left: [Float], right: [Float]?, sampleRate: Double) {
            guard let rate = sampleRate, !left.isEmpty else { throw WordLyricsAlignmentError.unreadableAudio }
            return (left, hasStereo ? right : nil, rate)
        }
    }

    /// Clean anti-aliased linear/boxcar resampler to 16 kHz mono (fast, zero AVAudioConverter edge bugs).
    private static func resampleMono(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        if abs(sourceRate - targetRate) < 1 { return samples }
        let ratio = sourceRate / targetRate
        let outCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: outCount)
        if ratio > 1.05 {
            // Downsampling: triangular anti-aliasing filter over window [-ratio, +ratio] around each sample.
            let halfWidth = max(1, Int(ceil(ratio)))
            for i in 0..<outCount {
                let center = Double(i) * ratio
                let lo = max(0, Int(floor(center)) - halfWidth)
                let hi = min(samples.count - 1, Int(ceil(center)) + halfWidth)
                var acc = 0.0
                var weightSum = 0.0
                for j in lo...hi {
                    let dist = abs(Double(j) - center) / ratio
                    if dist < 1.0 {
                        let w = 1.0 - dist
                        acc += Double(samples[j]) * w
                        weightSum += w
                    }
                }
                out[i] = weightSum > 0 ? Float(acc / weightSum) : 0
            }
        } else {
            // Upsampling: linear interpolation.
            for i in 0..<outCount {
                let pos = Double(i) * ratio
                let idx = min(samples.count - 1, Int(pos))
                let next = min(samples.count - 1, idx + 1)
                let frac = Float(pos - Double(idx))
                out[i] = samples[idx] * (1 - frac) + samples[next] * frac
            }
        }
        return out
    }
}

// MARK: - Persistent Disk Cache

private enum WordLyricsAlignmentDiskCache {
    static let maxCachedFiles = 400

    static var directory: URL {
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("WordLyricsAlignments", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func fileURL(songKey: String, lyricsFingerprint: String, versionKey: String) -> URL {
        let raw = "\(songKey)|\(lyricsFingerprint)|\(versionKey)"
        let digest = fnv1aHex(raw)
        return directory.appendingPathComponent("\(digest).json")
    }

    static func load(songKey: String, lyricsFingerprint: String, versionKey: String) -> WordLyricsTimingOverlay? {
        let url = fileURL(songKey: songKey, lyricsFingerprint: lyricsFingerprint, versionKey: versionKey)
        guard let data = try? Data(contentsOf: url),
              let overlay = try? JSONDecoder().decode(WordLyricsTimingOverlay.self, from: data),
              overlay.lyricsFingerprint == lyricsFingerprint,
              overlay.engineVersion == WordLyricsTimingOverlay.currentEngineVersion,
              !overlay.isPartial else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return overlay
    }

    static func save(_ overlay: WordLyricsTimingOverlay, songKey: String, versionKey: String) {
        guard !overlay.isPartial else { return }
        let url = fileURL(songKey: songKey, lyricsFingerprint: overlay.lyricsFingerprint, versionKey: versionKey)
        guard let data = try? JSONEncoder().encode(overlay) else { return }
        try? data.write(to: url, options: .atomic)
        trimIfNeeded()
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func trimIfNeeded() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), files.count > maxCachedFiles else { return }
        let sorted = files.sorted { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate < rDate
        }
        for url in sorted.prefix(files.count - maxCachedFiles) {
            try? fm.removeItem(at: url)
        }
    }

    private static func fnv1aHex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x00000100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Unified Alignment Service

extension Notification.Name {
    static let wordLyricsAlignmentModelChanged = Notification.Name("primuse.lyrics.wordAlignmentModelChanged")
}

/// Single source of truth for simulated word-by-word lyrics across Now Playing,
/// Karaoke Stage and Fullscreen Immersive modes (iOS, macOS and tvOS).
///
/// Automatically picks the highest accuracy tier available:
/// 1. Core ML CTC forced alignment on HTDemucs vocal stem (`ctcVocal`)
/// 2. Core ML CTC forced alignment on center-enhanced mixed audio (`ctcMix`)
/// 3. Upgraded pure-DSP alignment on HTDemucs vocal stem (`audioDSPVocal`)
/// 4. Upgraded pure-DSP alignment on center-enhanced mixed audio (`audioDSP`)
/// 5. Instant text prosody fallback (`textProsody`) when audio is unavailable (e.g. Apple Music)
@MainActor
@Observable
final class WordLyricsAlignmentService {

    private(set) var modelState: ModelState
    private(set) var modelFailureReason: String?
    private(set) var modelRevision: UInt = 0 {
        didSet { NotificationCenter.default.post(name: .wordLyricsAlignmentModelChanged, object: nil) }
    }
    /// Increments whenever an alignment overlay becomes available or upgrades to a higher tier.
    private(set) var alignmentRevision: UInt = 0

    @ObservationIgnored private var locatedModel: LyricsAlignmentModel.Located?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var hasRequestedAvailability = false
    @ObservationIgnored private var availabilityRefresh: Task<Void, Never>?
    @ObservationIgnored private var isRemovingModel = false
    @ObservationIgnored private var availabilityRevision: UInt = 0
    @ObservationIgnored private let predictor = WordLyricsAlignmentPredictor()

    @ObservationIgnored private var memoryCache: [OverlayKey: WordLyricsTimingOverlay] = [:]
    @ObservationIgnored private var memoryOrder: [OverlayKey] = []
    @ObservationIgnored private var activeJobs: [OverlayKey: (tier: WordTimingTier, task: Task<Void, Never>)] = [:]

    private init() {
        let supported = LyricsAlignmentModel.isSystemSupported
        modelState = supported ? .notDownloaded : .unsupportedSystem
    }
}

extension WordLyricsAlignmentService {
    static let shared = WordLyricsAlignmentService()

    enum ModelState: Equatable, Sendable {
        case unsupportedSystem
        case notDownloaded
        case downloading(Double)
        case ready
        case failed
    }

    var isModelReady: Bool { modelState == .ready }

    private struct OverlayKey: Hashable {
        let songKey: String
        let lyricsFingerprint: String
    }

    // MARK: - Model Pack Lifecycle

    func refreshAvailability() async {
        hasRequestedAvailability = true
        guard LyricsAlignmentModel.isSystemSupported, !isRemovingModel else { return }
        if let task = availabilityRefresh {
            await task.value
            return
        }
        guard modelState == .ready || modelState == .notDownloaded else { return }
        let revision = availabilityRevision
        let task = Task {
            defer { availabilityRefresh = nil }
            let found = await Task.detached(priority: .utility) { LyricsAlignmentModel.locate() }.value
            guard availabilityRevision == revision, !isRemovingModel else { return }
            guard modelState == .ready || modelState == .notDownloaded else { return }
            if let found, modelState == .notDownloaded {
                locatedModel = found
                modelState = .ready
                modelRevision &+= 1
            } else if found == nil, modelState == .ready {
                locatedModel = nil
                modelState = .notDownloaded
                modelRevision &+= 1
                await predictor.unload()
            }
        }
        availabilityRefresh = task
        await task.value
    }

    func downloadModel() {
        guard LyricsAlignmentModel.isSystemSupported, downloadTask == nil else { return }
        availabilityRevision &+= 1
        modelFailureReason = nil
        modelState = .downloading(0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }
            do {
                let located = try await LyricsAlignmentModel.download { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.modelState else { return }
                        self.modelState = .downloading(fraction)
                    }
                }
                self.locatedModel = located
                self.modelState = .ready
                self.modelRevision &+= 1
                // Invalidate in-memory lower-tier alignments so currently playing songs upgrade immediately.
                self.memoryCache = self.memoryCache.filter { $0.value.tier.usesCTCModel }
                self.alignmentRevision &+= 1
            } catch is CancellationError {
                self.modelState = .notDownloaded
            } catch {
                self.modelFailureReason = error.localizedDescription
                self.modelState = .failed
            }
        }
    }

    func removeModel() async {
        downloadTask?.cancel()
        downloadTask = nil
        isRemovingModel = true
        availabilityRevision &+= 1
        defer { isRemovingModel = false }
        locatedModel = nil
        await predictor.unload()
        await LyricsAlignmentModel.remove()
        modelFailureReason = nil
        modelState = LyricsAlignmentModel.isSystemSupported ? .notDownloaded : .unsupportedSystem
        modelRevision &+= 1
    }

    // MARK: - Unified Alignment Lookup & Scheduling

    static func songCacheKey(for song: Song) -> String {
        let modified = song.lastModified.map { Int($0.timeIntervalSince1970) } ?? 0
        let cue = song.cueStartTime.map { "-c\(Int($0 * 1000))" } ?? ""
        return "\(song.id)-\(song.fileSize)-\(modified)\(cue)"
    }

    /// Synchronous read of the best alignment currently ready in memory.
    func overlay(for song: Song?, lines: [LyricLine]) -> WordLyricsTimingOverlay? {
        guard let song, !lines.isEmpty else { return nil }
        let fp = WordLyricsTimingOverlay.fingerprint(for: lines)
        return memoryCache[OverlayKey(songKey: Self.songCacheKey(for: song), lyricsFingerprint: fp)]
    }

    /// Ensures the highest available alignment tier is computed and cached for `(song, lines)`.
    /// Safe to call repeatedly on view updates; deduplicates and upgrades monotonically.
    func alignIfNeeded(
        song: Song,
        lines: [LyricLine],
        playbackTime: TimeInterval? = nil,
        audioFile: @escaping @MainActor () async -> KaraokeAudioFile?
    ) {
        guard !song.isStreamDescriptor,
              !lines.isEmpty,
              !lines.contains(where: \.containsWordLevelContent),
              lines.contains(where: { $0.isSynchronized && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return
        }
        if !hasRequestedAvailability {
            hasRequestedAvailability = true
            Task {
                await refreshAvailability()
                if locatedModel != nil {
                    alignIfNeeded(song: song, lines: lines, playbackTime: playbackTime, audioFile: audioFile)
                }
            }
        }
        let songKey = Self.songCacheKey(for: song)
        let fingerprint = WordLyricsTimingOverlay.fingerprint(for: lines)
        let key = OverlayKey(songKey: songKey, lyricsFingerprint: fingerprint)

        let hasStem = FileManager.default.fileExists(atPath: KaraokeSeparationService.stemURL(for: song).path)
        let model = locatedModel
        let targetTier: WordTimingTier = switch (model != nil, hasStem) {
        case (true, true): .ctcVocal
        case (true, false): .ctcMix
        case (false, true): .audioDSPVocal
        case (false, false): .audioDSP
        }

        if let existing = memoryCache[key], existing.tier >= targetTier, !existing.isPartial {
            return
        }
        if let active = activeJobs[key], active.tier >= targetTier {
            return
        }

        activeJobs[key]?.task.cancel()
        let versionKey = Self.cacheVersionKey(tier: targetTier, modelVersion: model?.manifest.version)

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeJobs[key]?.tier == targetTier {
                    self.activeJobs[key] = nil
                }
            }

            // 1. Fast disk-cache hit check before touching audio or Core ML.
            let cached = await Task.detached(priority: .utility) {
                WordLyricsAlignmentDiskCache.load(
                    songKey: songKey,
                    lyricsFingerprint: fingerprint,
                    versionKey: versionKey
                )
            }.value
            guard !Task.isCancelled else { return }
            if let cached {
                self.storeOverlay(cached, for: key)
                return
            }

            // 2. Resolve audio file (only if no separated HTDemucs stem already exists on disk).
            let resolvedFile: KaraokeAudioFile?
            if hasStem {
                resolvedFile = nil
            } else {
                resolvedFile = await audioFile()
            }
            guard !Task.isCancelled else {
                if let resolvedFile, resolvedFile.removeAfterDecoding {
                    try? FileManager.default.removeItem(at: resolvedFile.url)
                }
                return
            }

            // 3. Decode to 16 kHz mono vocal & extract acoustic profile off the main actor.
            let prepared: (audio: WordLyricsAudioLoader.PreparedAudio, profile: VocalAcousticProfile)? =
                await Task.detached(priority: .utility) {
                    guard let audio = try? WordLyricsAudioLoader.load(song: song, audioFile: resolvedFile) else {
                        return nil
                    }
                    guard !Task.isCancelled else { return nil }
                    let profile = VocalAcousticProfile.analyze(samples: audio.samples, sampleRate: audio.sampleRate)
                    return (audio, profile)
                }.value
            guard !Task.isCancelled, let prepared else { return }

            let dspTier: WordTimingTier = prepared.audio.isSeparatedVocal ? .audioDSPVocal : .audioDSP
            let dspOverlay = await Task.detached(priority: .utility) {
                AudioWordTimingAligner.align(lines: lines, profile: prepared.profile, tier: dspTier)
            }.value
            guard !Task.isCancelled else { return }

            // Publish DSP immediately so even if CTC takes a moment (or model isn't installed),
            // playback switches from text-only prosody to audio-aligned timing right away.
            self.storeOverlay(dspOverlay, for: key)

            guard let model else {
                let dspVersionKey = Self.cacheVersionKey(tier: dspTier, modelVersion: nil)
                await Task.detached(priority: .utility) {
                    WordLyricsAlignmentDiskCache.save(dspOverlay, songKey: songKey, versionKey: dspVersionKey)
                }.value
                return
            }

            // 4. Upgrade via window-constrained Core ML CTC forced alignment (playhead chunk first).
            await self.runCTCAlignment(
                key: key,
                songKey: songKey,
                lines: lines,
                fingerprint: fingerprint,
                model: model,
                audio: prepared.audio,
                profile: prepared.profile,
                playbackTime: playbackTime,
                baseOverlay: dspOverlay
            )
        }
        activeJobs[key] = (targetTier, task)
    }

    /// Called when an HTDemucs vocal stem finishes separating, allowing active songs
    /// to upgrade seamlessly from mixed-audio alignment to separated-vocal alignment.
    func notifyVocalStemReady(for song: Song) {
        let songKey = Self.songCacheKey(for: song)
        var shouldBump = false
        for key in memoryCache.keys where key.songKey == songKey {
            if let existing = memoryCache[key],
               existing.tier != .ctcVocal,
               (locatedModel != nil || existing.tier < .audioDSPVocal) {
                shouldBump = true
            }
        }
        // Also bump even if not yet in memory so active views re-trigger alignment against the new vocal stem.
        if shouldBump || !memoryCache.keys.contains(where: { $0.songKey == songKey }) {
            alignmentRevision &+= 1
        }
    }

    #if !os(tvOS)
    /// Non-intrusive local/cached audio lookup matching ReplayGain's policy:
    /// never starts an unwanted cloud download solely for lyric alignment.
    static func localAudioFile(
        for song: Song,
        sourceManager: SourceManager?
    ) async -> KaraokeAudioFile? {
        guard let sourceManager else { return nil }
        if let local = await sourceManager.cachedURLForBackgroundRead(for: song)
            ?? sourceManager.cachedPlaybackURL(for: song) {
            return KaraokeAudioFile(url: local)
        }
        if let local = await sourceManager.directLocalFileURL(for: song) {
            return KaraokeAudioFile(url: local)
        }
        return nil
    }
    #endif

    // MARK: - Private CTC Chunked Runner

    private func runCTCAlignment(
        key: OverlayKey,
        songKey: String,
        lines: [LyricLine],
        fingerprint: String,
        model: LyricsAlignmentModel.Located,
        audio: WordLyricsAudioLoader.PreparedAudio,
        profile: VocalAcousticProfile,
        playbackTime: TimeInterval?,
        baseOverlay: WordLyricsTimingOverlay
    ) async {
        let ctcTier: WordTimingTier = audio.isSeparatedVocal ? .ctcVocal : .ctcMix
        let windows = KaraokeLineWindowPolicy.windows(in: lines)
        guard !windows.isEmpty else { return }
        let plan = CTCChunkPlan.make(
            windows: windows,
            chunkDuration: model.manifest.chunkDuration,
            prioritizing: playbackTime
        )
        guard !plan.chunks.isEmpty else { return }

        do {
            let vocab = try await predictor.vocabulary(for: model)
            let sampleRate = model.manifest.sampleRate
            let chunkLen = model.manifest.chunkSamples
            var accumulated = baseOverlay.syllablesByLineID

            for (chunkIndex, chunk) in plan.chunks.enumerated() {
                try Task.checkCancellation()
                try await holdWhileThermallyOrBackgroundPaused()

                let chunkLines = chunk.windowIndices.map { lines[windows[$0].lineIndex] }
                let neededTokens = vocab.requiredTokenIDs(for: chunkLines)
                let startSample = max(0, Int((chunk.startTime * sampleRate).rounded()))
                let endSample = min(audio.samples.count, startSample + chunkLen)
                guard endSample > startSample else { continue }
                let slice = Array(audio.samples[startSample..<endSample])

                let emissions = try await predictor.emissions(
                    for: model,
                    chunkSamples: slice,
                    startTime: Double(startSample) / sampleRate,
                    neededTokenIDs: neededTokens
                )
                try Task.checkCancellation()

                let alignedChunk: [String: [LyricSyllable]] = await Task.detached(priority: .utility) {
                    var result: [String: [LyricSyllable]] = [:]
                    for wIdx in chunk.windowIndices {
                        let window = windows[wIdx]
                        let line = lines[window.lineIndex]
                        if let outcome = CTCForcedAligner.alignLine(
                            line,
                            window: window,
                            vocabulary: vocab,
                            emissions: emissions,
                            profile: profile
                        ) {
                            result[line.id] = outcome.syllables
                        }
                    }
                    return result
                }.value

                for (id, syllables) in alignedChunk {
                    accumulated[id] = syllables
                }

                let isLast = chunkIndex == plan.chunks.count - 1
                let overlay = WordLyricsTimingOverlay(
                    tier: ctcTier,
                    lyricsFingerprint: fingerprint,
                    syllablesByLineID: accumulated,
                    isPartial: !isLast
                )
                self.storeOverlay(overlay, for: key)

                if isLast {
                    let versionKey = Self.cacheVersionKey(tier: ctcTier, modelVersion: model.manifest.version)
                    await Task.detached(priority: .utility) {
                        WordLyricsAlignmentDiskCache.save(overlay, songKey: songKey, versionKey: versionKey)
                    }.value
                }
            }
        } catch is CancellationError {
            return
        } catch {
            plog("⚠️ WordAlign: CTC chunk alignment fell back to DSP: \(error.localizedDescription)")
        }
    }

    private func holdWhileThermallyOrBackgroundPaused() async throws {
        while Self.shouldPauseHeavyInference() {
            try await Task.sleep(for: .seconds(2))
        }
    }

    private static func shouldPauseHeavyInference() -> Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return true }
        #if canImport(UIKit) && !os(tvOS)
        if UIApplication.shared.applicationState == .background { return true }
        #endif
        return false
    }

    private func storeOverlay(_ overlay: WordLyricsTimingOverlay, for key: OverlayKey) {
        if let existing = memoryCache[key], existing.tier > overlay.tier {
            return
        }
        memoryCache[key] = overlay
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        if memoryOrder.count > 16 {
            let evicted = memoryOrder.removeFirst()
            memoryCache[evicted] = nil
        }
        alignmentRevision &+= 1
    }

    private static func cacheVersionKey(tier: WordTimingTier, modelVersion: String?) -> String {
        "\(WordLyricsTimingOverlay.currentEngineVersion)-t\(tier.rawValue)-\(modelVersion ?? "dsp")"
    }
}
