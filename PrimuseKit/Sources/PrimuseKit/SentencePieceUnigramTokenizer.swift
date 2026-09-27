import Foundation

/// SentencePiece unigram tokenizer for the offline lyric translation models.
///
/// Reads the original `.spm` model file (a protobuf `ModelProto`) and
/// reproduces `SentencePieceProcessor.encode` for the settings those models use:
/// `nmt_nfkc` normalization, dummy prefix, whitespace collapsing, Viterbi over
/// piece scores and byte fallback for characters outside the vocabulary.
///
/// The precompiled normalization map is not interpreted. Its effect is Unicode
/// NFKC plus the NMT rules below, which were derived by running the reference
/// implementation over every code point; the only remaining differences are
/// a few modifier letters added in recent Unicode versions.
public struct SentencePieceUnigramTokenizer: Sendable {
    public enum LoadError: Error, Equatable {
        case malformedModel
        case unsupportedModelType(Int)
        case missingSpecialPiece(String)
    }

    public enum PieceType: Int, Sendable {
        case normal = 1
        case unknown = 2
        case control = 3
        case userDefined = 4
        case unused = 5
        case byte = 6
    }

    public struct Piece: Sendable, Equatable {
        public let text: String
        public let score: Float
        public let type: PieceType
    }

    public let pieces: [Piece]
    public let unknownID: Int
    public let endOfSentenceID: Int
    private let byteIDs: [Int]
    private let trie: PieceTrie
    private let unknownScore: Float

    public var vocabularySize: Int { pieces.count }

    public init(modelData: Data) throws {
        let parsed = try ModelProtoReader.parse(modelData)
        if let type = parsed.modelType, type != 1 {
            throw LoadError.unsupportedModelType(type)
        }
        pieces = parsed.pieces
        var trie = PieceTrie()
        var byteIDs = [Int](repeating: -1, count: 256)
        var unknownID: Int?
        var endOfSentenceID: Int?
        var minScore = Float.greatestFiniteMagnitude
        for (id, piece) in parsed.pieces.enumerated() {
            switch piece.type {
            case .normal, .userDefined:
                trie.insert(piece.text.unicodeScalars.map(\.value), id: id)
                if piece.type == .normal { minScore = min(minScore, piece.score) }
            case .unknown:
                unknownID = id
            case .control where piece.text == "</s>":
                endOfSentenceID = id
            case .byte:
                if let value = Self.byteValue(piece.text) { byteIDs[Int(value)] = id }
            default:
                break
            }
        }
        guard let unknownID else { throw LoadError.missingSpecialPiece("<unk>") }
        guard let endOfSentenceID else { throw LoadError.missingSpecialPiece("</s>") }
        self.unknownID = unknownID
        self.endOfSentenceID = endOfSentenceID
        self.byteIDs = byteIDs
        self.trie = trie
        // Same penalty as the reference implementation (kUnkPenalty = 10).
        self.unknownScore = (minScore == .greatestFiniteMagnitude ? 0 : minScore) - 10
    }

    // MARK: Encoding

    /// Piece IDs for `text`, without the end-of-sentence marker.
    public func encode(_ text: String) -> [Int] {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return [] }
        let scalars = Array(normalized.unicodeScalars)
        let count = scalars.count

        // Viterbi over the lattice of vocabulary pieces.
        var bestScore = [Float](repeating: -.infinity, count: count + 1)
        var bestStart = [Int](repeating: -1, count: count + 1)
        var bestPiece = [Int](repeating: -1, count: count + 1)
        bestScore[0] = 0
        for start in 0..<count where bestScore[start] > -.infinity {
            var matchedSingle = false
            var node = 0
            for end in (start + 1)...count {
                guard let next = trie.child(of: node, scalar: scalars[end - 1].value) else { break }
                node = next
                guard let id = trie.pieceID(at: node) else { continue }
                if end == start + 1 { matchedSingle = true }
                let piece = pieces[id]
                // User-defined symbols always win, as they do in the reference
                // prefix matcher.
                let score = piece.type == .userDefined
                    ? Float(end - start) * 1_000
                    : piece.score
                let candidate = bestScore[start] + score
                if candidate > bestScore[end] {
                    bestScore[end] = candidate
                    bestStart[end] = start
                    bestPiece[end] = id
                }
            }
            if !matchedSingle {
                let candidate = bestScore[start] + unknownScore
                if candidate > bestScore[start + 1] {
                    bestScore[start + 1] = candidate
                    bestStart[start + 1] = start
                    bestPiece[start + 1] = unknownID
                }
            }
        }

        var reversed: [(id: Int, start: Int, end: Int)] = []
        var position = count
        while position > 0 {
            let start = bestStart[position]
            guard start >= 0 else { break }
            reversed.append((bestPiece[position], start, position))
            position = start
        }

        var ids: [Int] = []
        ids.reserveCapacity(reversed.count)
        for node in reversed.reversed() {
            guard node.id == unknownID else {
                ids.append(node.id)
                continue
            }
            var surface = String.UnicodeScalarView()
            surface.append(contentsOf: scalars[node.start..<node.end])
            let bytes = Array(String(surface).utf8)
            if bytes.allSatisfy({ byteIDs[Int($0)] >= 0 }) {
                ids.append(contentsOf: bytes.map { byteIDs[Int($0)] })
            } else {
                ids.append(unknownID)
            }
        }
        return ids
    }

    // MARK: Decoding

    /// Text for generated piece IDs. Control pieces are dropped and byte
    /// pieces are reassembled into UTF-8.
    public func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids where pieces.indices.contains(id) {
            let piece = pieces[id]
            switch piece.type {
            case .normal, .userDefined:
                bytes.append(contentsOf: piece.text.utf8)
            case .byte:
                if let value = Self.byteValue(piece.text) { bytes.append(value) }
            case .unknown:
                bytes.append(contentsOf: " \u{2047} ".utf8)
            case .control, .unused:
                break
            }
        }
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{2581}", with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Normalization

    /// `nmt_nfkc` followed by SentencePiece's whitespace handling: extra
    /// whitespace removed and every space escaped as U+2581, with the dummy
    /// prefix in front.
    public static func normalize(_ text: String) -> String {
        var mapped = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if removedScalars.contains(value) { continue }
            if spaceScalars.contains(value) {
                mapped.append(" ")
            } else {
                mapped.append(scalar)
            }
        }
        var normalized = String.UnicodeScalarView()
        // NFKC per run so the few code points the reference keeps as-is are
        // not folded by Foundation's newer Unicode tables.
        var run = String.UnicodeScalarView()
        func flushRun() {
            guard !run.isEmpty else { return }
            normalized.append(contentsOf: String(run).precomposedStringWithCompatibilityMapping.unicodeScalars)
            run.removeAll()
        }
        for scalar in mapped {
            if preservedScalars.contains(scalar.value) {
                flushRun()
                normalized.append(scalar)
            } else {
                run.append(scalar)
            }
        }
        flushRun()

        var output = String.UnicodeScalarView()
        var pendingSpace = true // dummy prefix
        var wroteAny = false
        for scalar in normalized {
            if scalar == " " {
                if wroteAny { pendingSpace = true }
                continue
            }
            if pendingSpace {
                output.append("\u{2581}")
                pendingSpace = false
            }
            output.append(scalar)
            wroteAny = true
        }
        return String(output)
    }

    /// Control characters the NMT rules delete.
    private static let removedScalars: Set<UInt32> = {
        var set: Set<UInt32> = [0x0B, 0x7F, 0x8F, 0x9F]
        set.formUnion(0x01...0x08)
        set.formUnion(0x0E...0x1F)
        return set
    }()

    /// Characters the NMT rules turn into a plain space, including the
    /// zero-width non-joiner that Persian uses inside words.
    private static let spaceScalars: Set<UInt32> = [
        0x09, 0x0A, 0x0C, 0x0D, 0x1680, 0x2028, 0x2029,
        0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0xFEFF, 0xFFFD
    ]

    /// Characters whose NFKC mapping the reference map does not apply.
    private static let preservedScalars: Set<UInt32> = [0xFF5E]

    private static func byteValue(_ text: String) -> UInt8? {
        guard text.count == 6, text.hasPrefix("<0x"), text.hasSuffix(">") else { return nil }
        return UInt8(text.dropFirst(3).prefix(2), radix: 16)
    }
}

/// Prefix tree over the Unicode scalars of matchable pieces.
private struct PieceTrie: Sendable {
    private var children: [[UInt32: Int32]] = [[:]]
    private var ids: [Int32] = [-1]

    mutating func insert(_ scalars: [UInt32], id: Int) {
        var node = 0
        for scalar in scalars {
            if let next = children[node][scalar] {
                node = Int(next)
            } else {
                children.append([:])
                ids.append(-1)
                let next = children.count - 1
                children[node][scalar] = Int32(next)
                node = next
            }
        }
        ids[node] = Int32(id)
    }

    func child(of node: Int, scalar: UInt32) -> Int? {
        children[node][scalar].map(Int.init)
    }

    func pieceID(at node: Int) -> Int? {
        ids[node] >= 0 ? Int(ids[node]) : nil
    }
}

// MARK: - Protobuf

/// Minimal reader for the fields of `sentencepiece.ModelProto` the
/// tokenizer needs: pieces (1) and trainer_spec.model_type (2 → 3).
private enum ModelProtoReader {
    struct Parsed {
        var pieces: [SentencePieceUnigramTokenizer.Piece] = []
        var modelType: Int?
    }

    static func parse(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        var parsed = Parsed()
        var reader = Reader(bytes: bytes[...])
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2):
                parsed.pieces.append(try piece(try reader.lengthDelimited()))
            case (2, 2):
                var trainer = Reader(bytes: try reader.lengthDelimited())
                while !trainer.isAtEnd {
                    let (f, w) = try trainer.key()
                    if f == 3, w == 0 {
                        parsed.modelType = Int(try trainer.varint())
                    } else {
                        try trainer.skip(wire: w)
                    }
                }
            default:
                try reader.skip(wire: wire)
            }
        }
        guard !parsed.pieces.isEmpty else {
            throw SentencePieceUnigramTokenizer.LoadError.malformedModel
        }
        return parsed
    }

    private static func piece(_ bytes: ArraySlice<UInt8>) throws -> SentencePieceUnigramTokenizer.Piece {
        var reader = Reader(bytes: bytes)
        var text = ""
        var score: Float = 0
        var type = SentencePieceUnigramTokenizer.PieceType.normal
        while !reader.isAtEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2):
                text = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (2, 5):
                score = Float(bitPattern: try reader.fixed32())
            case (3, 0):
                type = SentencePieceUnigramTokenizer.PieceType(rawValue: Int(try reader.varint())) ?? .normal
            default:
                try reader.skip(wire: wire)
            }
        }
        return .init(text: text, score: score, type: type)
    }

    struct Reader {
        var bytes: ArraySlice<UInt8>
        var isAtEnd: Bool { bytes.isEmpty }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while let byte = bytes.first {
                bytes = bytes.dropFirst()
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { break }
            }
            throw SentencePieceUnigramTokenizer.LoadError.malformedModel
        }

        mutating func key() throws -> (Int, Int) {
            let key = try varint()
            return (Int(key >> 3), Int(key & 7))
        }

        mutating func lengthDelimited() throws -> ArraySlice<UInt8> {
            let length = Int(try varint())
            guard length >= 0, length <= bytes.count else {
                throw SentencePieceUnigramTokenizer.LoadError.malformedModel
            }
            let value = bytes.prefix(length)
            bytes = bytes.dropFirst(length)
            return value
        }

        mutating func fixed32() throws -> UInt32 {
            guard bytes.count >= 4 else { throw SentencePieceUnigramTokenizer.LoadError.malformedModel }
            let b = Array(bytes.prefix(4))
            bytes = bytes.dropFirst(4)
            return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        }

        mutating func skip(wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1:
                guard bytes.count >= 8 else { throw SentencePieceUnigramTokenizer.LoadError.malformedModel }
                bytes = bytes.dropFirst(8)
            case 2: _ = try lengthDelimited()
            case 5: _ = try fixed32()
            default: throw SentencePieceUnigramTokenizer.LoadError.malformedModel
            }
        }
    }
}
