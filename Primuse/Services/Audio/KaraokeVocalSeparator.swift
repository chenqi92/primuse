import CoreML
import Foundation
import PrimuseKit

/// Runs the Hybrid Transformer Demucs vocal model over a whole song.
///
/// The Core ML model covers only the network; the spectrogram, its inverse
/// and the segment stitching are `KaraokeDemucsFrontEnd`, which mirrors the
/// reference implementation. The model must run on the GPU: the Neural
/// Engine computes in half precision internally and the frequency branch
/// overflows there, producing garbage.
actor KaraokeVocalSeparator {
    enum SeparationError: Error {
        case unexpectedOutput
    }

    struct Stem: Sendable {
        var left: [Float]
        var right: [Float]
    }

    private let model: MLModel
    private let layout = KaraokeDemucsLayout.standard
    private let spectrogram = KaraokeDemucsSpectrogram()

    /// `modelURL` may point at a compiled `.mlmodelc` or a source
    /// `.mlpackage`, which is compiled first.
    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        let compiledURL = modelURL.pathExtension == "mlmodelc"
            ? modelURL
            : try MLModel.compileModel(at: modelURL)
        model = try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    /// The vocal stem of a 44.1 kHz stereo song. `progress` receives the
    /// finished share, 0...1, after each segment; `cooling` whether work is
    /// held back until the device cools down.
    func separateVocals(
        left: [Float],
        right: [Float],
        progress: @Sendable (Double) -> Void = { _ in },
        cooling: @Sendable (Bool) -> Void = { _ in }
    ) async throws -> Stem {
        precondition(left.count == right.count)
        let plan = KaraokeSeparationPlan(totalLength: left.count, layout: layout)
        var accumulator = KaraokeSeparationAccumulator(plan: plan)
        for (index, segment) in plan.segments.enumerated() {
            try Task.checkCancellation()
            if Self.needsCooling {
                cooling(true)
                while Self.needsCooling {
                    try await Task.sleep(for: .seconds(3))
                }
                cooling(false)
            }
            let windowLeft = plan.window(segment, of: left)
            let windowRight = plan.window(segment, of: right)
            let output = try predict(left: windowLeft, right: windowRight)
            accumulator.add(segment, left: output.left, right: output.right)
            progress(Double(index + 1) / Double(plan.segments.count))
            await Task.yield()
        }
        let stem = accumulator.finish()
        return Stem(left: stem.left, right: stem.right)
    }

    /// The GPU at full load for minutes heats a phone further; a hot device
    /// throttles playback and the UI first.
    private static var needsCooling: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// One model call: vocals for a full-length segment window.
    private func predict(left: [Float], right: [Float]) throws -> Stem {
        let length = layout.segmentLength
        let bins = layout.bins
        let frames = layout.frames(forLength: length)

        let spectrum = spectrogram.forward(left: left, right: right)
        let spec = try MLMultiArray(shape: [1, 4, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
        spectrum.withUnsafeBufferPointer { source in
            spec.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: source.baseAddress!, count: source.count)
        }
        let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: length)], dataType: .float32)
        let mixPointer = mix.dataPointer.assumingMemoryBound(to: Float.self)
        left.withUnsafeBufferPointer { mixPointer.update(from: $0.baseAddress!, count: length) }
        right.withUnsafeBufferPointer { (mixPointer + length).update(from: $0.baseAddress!, count: length) }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "spec": MLFeatureValue(multiArray: spec),
            "mix": MLFeatureValue(multiArray: mix),
        ])
        let output = try model.prediction(from: input)
        guard let vocalSpec = output.featureValue(for: "vocals_spec")?.multiArrayValue,
              let vocalWave = output.featureValue(for: "vocals_wave")?.multiArrayValue,
              vocalSpec.count == 4 * bins * frames,
              vocalWave.count == 2 * length else {
            throw SeparationError.unexpectedOutput
        }
        let frequencyBranch = spectrogram.inverse(spectrum: Self.floats(vocalSpec), length: length)
        let timeBranch = Self.floats(vocalWave)
        var outLeft = frequencyBranch.left
        var outRight = frequencyBranch.right
        for i in 0..<length {
            outLeft[i] += timeBranch[i]
            outRight[i] += timeBranch[length + i]
        }
        return Stem(left: outLeft, right: outRight)
    }

    /// Contiguous values of an output array as Float. The converted model
    /// declares float32 outputs; other storage takes the slow generic path
    /// (Float16 is unavailable on Intel Macs).
    private static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float32:
            return Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: count))
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }
}
