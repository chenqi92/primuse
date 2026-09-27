import CoreML
import Foundation
import PrimuseKit

enum LocalLyricsTranslationEngineError: Error {
    case invalidModelOutput
}

/// One translation direction of the offline lyric model: a Mozilla Firefox
/// Translations student converted to a Core ML package with an `encode` and a
/// `decode` function, plus its SentencePiece vocabulary.
///
/// Each lyric line is translated on its own, so a result always maps back to
/// exactly one source line. Decoding is greedy, as in Firefox.
final class LocalLyricsTranslationDirection: @unchecked Sendable {
    /// Marian's start symbol is a zero embedding; the package encodes it as
    /// the first ID past the vocabulary.
    private let startToken: Int32
    private let encoder: MLModel
    private let decoder: MLModel
    let tokenizer: SentencePieceUnigramTokenizer
    /// Upper bound on source pieces; lines longer than this are cut. Lyric
    /// lines are far shorter in practice.
    static let maximumSourcePieces = 200
    static let hiddenSize = 256

    @available(iOS 18.0, macOS 15.0, tvOS 18.0, *)
    init(compiledModelURL: URL, vocabularyURL: URL, computeUnits: MLComputeUnits = .cpuOnly) throws {
        tokenizer = try SentencePieceUnigramTokenizer(modelData: Data(contentsOf: vocabularyURL))
        startToken = Int32(tokenizer.vocabularySize)
        let encodeConfiguration = MLModelConfiguration()
        encodeConfiguration.computeUnits = computeUnits
        encodeConfiguration.functionName = "encode"
        let decodeConfiguration = MLModelConfiguration()
        decodeConfiguration.computeUnits = computeUnits
        decodeConfiguration.functionName = "decode"
        encoder = try MLModel(contentsOf: compiledModelURL, configuration: encodeConfiguration)
        decoder = try MLModel(contentsOf: compiledModelURL, configuration: decodeConfiguration)
    }

    /// Translates one line. Returns nil for text without translatable
    /// content (empty after normalization).
    func translate(_ text: String) throws -> String? {
        var pieces = tokenizer.encode(text)
        guard !pieces.isEmpty else { return nil }
        if pieces.count > Self.maximumSourcePieces {
            pieces = Array(pieces.prefix(Self.maximumSourcePieces))
        }
        pieces.append(tokenizer.endOfSentenceID)

        let sourceIDs = try MLMultiArray(shape: [1, NSNumber(value: pieces.count)], dataType: .int32)
        sourceIDs.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            for (index, id) in pieces.enumerated() { buffer[index] = Int32(id) }
        }
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: sourceIDs)
        ]))
        guard let encoderArray = encoded.featureValue(for: "encoder_out")?.multiArrayValue else {
            throw LocalLyricsTranslationEngineError.invalidModelOutput
        }
        // The encode and decode functions share one compiled program, and an
        // output may live in memory the next prediction reuses. Keep a copy.
        let encoderCopy = try MLMultiArray(shape: encoderArray.shape, dataType: .float32)
        Self.copy(encoderArray, into: encoderCopy)
        let encoderOut = MLFeatureValue(multiArray: encoderCopy)

        let token = try MLMultiArray(shape: [1], dataType: .int32)
        let position = try MLMultiArray(shape: [1], dataType: .int32)
        // Same for the recurrent state between steps.
        let state1 = try Self.zeroState()
        let state2 = try Self.zeroState()
        var next = startToken
        var output: [Int] = []
        // Same length limit as Marian's default max-length-factor.
        let limit = min(3 * pieces.count, 256)
        for step in 0..<limit {
            token[0] = NSNumber(value: next)
            position[0] = NSNumber(value: Int32(step))
            let result = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "token": MLFeatureValue(multiArray: token),
                "position": MLFeatureValue(multiArray: position),
                "state1": MLFeatureValue(multiArray: state1),
                "state2": MLFeatureValue(multiArray: state2),
                "encoder_out": encoderOut
            ]))
            guard let logits = result.featureValue(for: "logits")?.multiArrayValue,
                  let newState1 = result.featureValue(for: "state1_out")?.multiArrayValue,
                  let newState2 = result.featureValue(for: "state2_out")?.multiArrayValue else {
                throw LocalLyricsTranslationEngineError.invalidModelOutput
            }
            let best = Self.argmax(logits)
            if best == tokenizer.endOfSentenceID { break }
            output.append(best)
            next = Int32(best)
            Self.copy(newState1, into: state1)
            Self.copy(newState2, into: state2)
        }
        let translated = tokenizer.decode(output)
        return translated.isEmpty ? nil : translated
    }

    private static func zeroState() throws -> MLMultiArray {
        let state = try MLMultiArray(shape: [1, NSNumber(value: hiddenSize)], dataType: .float32)
        state.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            buffer.update(repeating: 0)
        }
        return state
    }

    private static func copy(_ source: MLMultiArray, into destination: MLMultiArray) {
        destination.withUnsafeMutableBufferPointer(ofType: Float.self) { target, _ in
            if source.dataType == .float32 {
                source.withUnsafeBufferPointer(ofType: Float.self) { values in
                    for index in target.indices { target[index] = values[index] }
                }
            } else {
                for index in target.indices { target[index] = source[index].floatValue }
            }
        }
    }

    private static func argmax(_ logits: MLMultiArray) -> Int {
        var bestIndex = 0
        switch logits.dataType {
        case .float16:
            #if arch(arm64)
            logits.withUnsafeBufferPointer(ofType: Float16.self) { buffer in
                var best = -Float16.infinity
                for index in buffer.indices where buffer[index] > best {
                    best = buffer[index]
                    bestIndex = index
                }
            }
            #endif
        default:
            logits.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                var best = -Float.infinity
                for index in buffer.indices where buffer[index] > best {
                    best = buffer[index]
                    bestIndex = index
                }
            }
        }
        return bestIndex
    }
}
