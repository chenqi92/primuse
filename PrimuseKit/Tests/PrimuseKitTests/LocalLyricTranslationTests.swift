import Foundation
import Testing

@testable import PrimuseKit

@Suite("Offline lyric translation model")
struct LocalLyricTranslationTests {
    // MARK: Routing

    @Test("English and Persian translate directly in both directions")
    func directPairs() {
        #expect(route("en", "fa") == .local(.englishToPersian))
        #expect(route("en-US", "fa-IR") == .local(.englishToPersian))
        #expect(route("fa", "en") == .local(.persianToEnglish))
        #expect(route("fa-Arab", "en-GB") == .local(.persianToEnglish))
        // Direct pairs never need Apple Translation.
        #expect(route("en", "fa", pivot: false) == .local(.englishToPersian))
    }

    @Test("Other languages reach Persian through English only with an installed system pack")
    func pivotPairs() {
        #expect(route("zh-Hans", "fa") == .systemThenLocal(systemSource: "zh-Hans", local: .englishToPersian))
        #expect(route("ja", "fa") == .systemThenLocal(systemSource: "ja", local: .englishToPersian))
        #expect(route("fa", "zh-Hans") == .localThenSystem(local: .persianToEnglish, systemTarget: "zh-Hans"))
        #expect(route("zh-Hans", "fa", pivot: false) == .unsupported)
        #expect(route("fa", "ja", pivot: false) == .unsupported)
    }

    @Test("Unknown sources, transliterated Persian and unrelated pairs are not routed")
    func unsupportedPairs() {
        #expect(LocalLyricTranslationPolicy.route(
            sourceLanguageCode: nil, targetLanguageCode: "fa", allowsSystemPivot: true
        ) == .unsupported)
        #expect(route("fa-Latn", "en") == .unsupported)
        #expect(route("en", "fa-Latn") == .unsupported)
        #expect(route("fa", "fa-Arab") == .unsupported)
        #expect(route("zh-Hans", "ja") == .unsupported)
        #expect(route("en", "en-US") == .unsupported)
    }

    // MARK: Output checks

    @Test("Model output is cleaned and runaway or copied output is rejected")
    func acceptedTranslations() {
        typealias P = LocalLyricTranslationPolicy
        #expect(P.acceptedTranslation(source: "I miss you", translated: "  دلم برات  تنگ شده ") == "دلم برات تنگ شده")
        #expect(P.acceptedTranslation(source: "Hello", translated: "") == nil)
        #expect(P.acceptedTranslation(source: "Hello", translated: " \u{2047} ") == nil)
        #expect(P.acceptedTranslation(source: "Na na na", translated: "Na na na") == nil)
        let runaway = "ما جوان و وحشی " + Array(repeating: "بودیم", count: 9).joined(separator: " ")
        #expect(P.acceptedTranslation(source: "We were young and wild and free", translated: runaway) == nil)
        // A line that itself repeats may translate into a repetition.
        let chant = Array(repeating: "na", count: 8).joined(separator: " ")
        let echoed = Array(repeating: "نا", count: 8).joined(separator: " ")
        #expect(P.acceptedTranslation(source: chant, translated: echoed) == echoed)
        #expect(P.acceptedTranslation(source: "Hi", translated: String(repeating: "x", count: 41)) == nil)
    }

    @Test("Companion lines are isolated so each keeps its own reading direction")
    func bidiIsolation() {
        let persian = "امشب تو خیابون می رقصیم، آره!"
        #expect(LyricCompanionTextPolicy.displayText(persian) == "\u{2068}\(persian)\u{2069}")
        #expect(LyricCompanionTextPolicy.displayText("I miss you!").unicodeScalars.first == "\u{2068}")
        // Empty companions stay empty so callers can still filter them out.
        #expect(LyricCompanionTextPolicy.displayText("") == "")
        #expect(LyricCompanionTextPolicy.displayText("  ") == "  ")
    }

    @Test("Cache namespace follows the model build")
    func cacheVersion() {
        #expect(LocalLyricTranslationPolicy.cacheProviderVersion(modelVersion: "a")
            != LocalLyricTranslationPolicy.cacheProviderVersion(modelVersion: "b"))
    }

    // MARK: Manifest

    @Test("Manifests need the supported format, a version, both directions and pack-relative paths")
    func manifest() throws {
        let valid = """
        {"format":1,"version":"firefox-2025h1-int8-1","directions":[
          {"source":"en","target":"fa","model":"en-fa.mlmodelc","vocabulary":"vocab.enfa.spm"},
          {"source":"fa","target":"en","model":"fa-en.mlmodelc","vocabulary":"vocab.faen.spm"}]}
        """
        let manifest = try #require(LocalLyricTranslationManifest.decode(Data(valid.utf8)))
        #expect(manifest.version == "firefox-2025h1-int8-1")
        #expect(manifest.entry(for: .persianToEnglish)?.model == "fa-en.mlmodelc")
        #expect(manifest.requiredFiles == [
            "en-fa.mlmodelc/coremldata.bin", "vocab.enfa.spm",
            "fa-en.mlmodelc/coremldata.bin", "vocab.faen.spm",
        ])

        let wrongFormat = valid.replacingOccurrences(of: "\"format\":1", with: "\"format\":2")
        #expect(LocalLyricTranslationManifest.decode(Data(wrongFormat.utf8)) == nil)
        let noVersion = valid.replacingOccurrences(of: "firefox-2025h1-int8-1", with: " ")
        #expect(LocalLyricTranslationManifest.decode(Data(noVersion.utf8)) == nil)
        let escaping = valid.replacingOccurrences(of: "vocab.faen.spm", with: "../vocab.faen.spm")
        #expect(LocalLyricTranslationManifest.decode(Data(escaping.utf8)) == nil)
        let absolute = valid.replacingOccurrences(of: "en-fa.mlmodelc", with: "/tmp/en-fa.mlmodelc")
        #expect(LocalLyricTranslationManifest.decode(Data(absolute.utf8)) == nil)
        let oneWay = """
        {"format":1,"version":"v","directions":[
          {"source":"en","target":"fa","model":"en-fa.mlmodelc","vocabulary":"v.spm"}]}
        """
        #expect(LocalLyricTranslationManifest.decode(Data(oneWay.utf8)) == nil)
        #expect(LocalLyricTranslationManifest.decode(Data("not json".utf8)) == nil)
    }

    // MARK: Tokenizer

    @Test("Viterbi picks the best-scoring segmentation")
    func segmentation() throws {
        let tokenizer = try Self.tokenizer()
        // "▁hello" as one piece beats "▁he" + "llo".
        #expect(pieces(tokenizer, "hello") == ["▁hello"])
        #expect(pieces(tokenizer, "hello world") == ["▁hello", "▁world"])
        #expect(pieces(tokenizer, "helloworld") == ["▁hello", "w", "o", "r", "l", "d"])
    }

    @Test("Whitespace is collapsed and NMT normalization maps ZWNJ and controls")
    func normalization() {
        typealias T = SentencePieceUnigramTokenizer
        #expect(T.normalize("  a   b  ") == "▁a▁b")
        #expect(T.normalize("a\tb\nc") == "▁a▁b▁c")
        #expect(T.normalize("می\u{200C}کند") == "▁می▁کند")
        #expect(T.normalize("a\u{01}b") == "▁ab")
        #expect(T.normalize("ﬁ") == "▁fi")
        #expect(T.normalize("a\u{FF5E}b") == "▁a\u{FF5E}b")
        #expect(T.normalize("   ") == "")
    }

    @Test("Characters outside the vocabulary fall back to UTF-8 bytes and decode back")
    func byteFallback() throws {
        let tokenizer = try Self.tokenizer()
        let ids = tokenizer.encode("hello é")
        #expect(pieces(tokenizer, "hello é") == ["▁hello", "▁", "<0xC3>", "<0xA9>"])
        #expect(tokenizer.decode(ids) == "hello é")
        #expect(tokenizer.decode(ids + [tokenizer.endOfSentenceID]) == "hello é")
    }

    @Test("User-defined symbols are kept whole")
    func userDefinedSymbols() throws {
        let tokenizer = try Self.tokenizer()
        #expect(pieces(tokenizer, "__x__hello") == ["▁", "__x__", "hello"])
    }

    @Test("Malformed models are rejected")
    func malformed() {
        #expect(throws: SentencePieceUnigramTokenizer.LoadError.self) {
            try SentencePieceUnigramTokenizer(modelData: Data([0x0A, 0xFF]))
        }
        #expect(throws: SentencePieceUnigramTokenizer.LoadError.missingSpecialPiece("</s>")) {
            try SentencePieceUnigramTokenizer(modelData: Self.model(pieces: [("<unk>", 0, 2), ("a", -1, 1)]))
        }
        #expect(throws: SentencePieceUnigramTokenizer.LoadError.unsupportedModelType(2)) {
            try SentencePieceUnigramTokenizer(modelData: Self.model(
                pieces: [("</s>", 0, 3), ("<unk>", 0, 2), ("a", -1, 1)],
                modelType: 2
            ))
        }
    }

    // MARK: Helpers

    private func route(_ source: String, _ target: String, pivot: Bool = true) -> LocalLyricTranslationPolicy.Route {
        LocalLyricTranslationPolicy.route(sourceLanguageCode: source, targetLanguageCode: target, allowsSystemPivot: pivot)
    }

    private func pieces(_ tokenizer: SentencePieceUnigramTokenizer, _ text: String) -> [String] {
        tokenizer.encode(text).map { tokenizer.pieces[$0].text }
    }

    private static func tokenizer() throws -> SentencePieceUnigramTokenizer {
        var pieces: [(String, Float, Int)] = [
            ("</s>", 0, 3), ("<unk>", 0, 2), ("__x__", 0, 4),
            ("▁hello", -1, 1), ("▁he", -2, 1), ("llo", -2, 1), ("hello", -3, 1),
            ("▁world", -1, 1), ("▁", -2, 1),
        ]
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            pieces.append((String(letter), -5, 1))
        }
        for byte in 0...255 {
            pieces.append((String(format: "<0x%02X>", byte), 0, 6))
        }
        return try SentencePieceUnigramTokenizer(modelData: model(pieces: pieces))
    }

    /// Serializes a minimal `sentencepiece.ModelProto`.
    private static func model(pieces: [(String, Float, Int)], modelType: Int = 1) -> Data {
        var data = Data()
        for (text, score, type) in pieces {
            var piece = Data()
            piece.append(0x0A)
            appendVarint(UInt64(text.utf8.count), to: &piece)
            piece.append(contentsOf: Array(text.utf8))
            piece.append(0x15)
            withUnsafeBytes(of: score.bitPattern.littleEndian) { piece.append(contentsOf: $0) }
            piece.append(0x18)
            appendVarint(UInt64(type), to: &piece)
            data.append(0x0A)
            appendVarint(UInt64(piece.count), to: &data)
            data.append(piece)
        }
        var trainer = Data([0x18])
        appendVarint(UInt64(modelType), to: &trainer)
        data.append(0x12)
        appendVarint(UInt64(trainer.count), to: &data)
        data.append(trainer)
        return data
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            data.append(byte)
        } while value != 0
    }
}
