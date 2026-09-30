import Foundation

/// Routes supported by the downloadable offline translation packs.
public enum LocalLyricTranslationPolicy {
    public static let englishIdentity = "en"
    public static let persianIdentity = "fa"

    public struct Direction: Hashable, Sendable, Codable {
        public let source: String
        public let target: String

        public init(source: String, target: String) {
            self.source = source
            self.target = target
        }

        public static let englishToPersian = Direction(source: englishIdentity, target: persianIdentity)
        public static let persianToEnglish = Direction(source: persianIdentity, target: englishIdentity)
        public static let englishToSimplifiedChinese = Direction(source: "en", target: "zh-Hans")
        public static let simplifiedChineseToEnglish = Direction(source: "zh-Hans", target: "en")
        public static let englishToTraditionalChinese = Direction(source: "en", target: "zh-Hant")
        public static let traditionalChineseToEnglish = Direction(source: "zh-Hant", target: "en")
        public static let englishToJapanese = Direction(source: "en", target: "ja")
        public static let japaneseToEnglish = Direction(source: "ja", target: "en")
        public static let englishToKorean = Direction(source: "en", target: "ko")
        public static let koreanToEnglish = Direction(source: "ko", target: "en")
    }

    public static let persianDirections: [Direction] = [.englishToPersian, .persianToEnglish]
    public static let cjkDirections: [Direction] = [
        .englishToSimplifiedChinese, .simplifiedChineseToEnglish,
        .englishToTraditionalChinese, .traditionalChineseToEnglish,
        .englishToJapanese, .japaneseToEnglish, .englishToKorean, .koreanToEnglish,
    ]
    public static let directions = persianDirections + cjkDirections

    public enum Route: Equatable, Sendable {
        /// The model translates the pair directly.
        case local(Direction)
        case localPivot(first: Direction, second: Direction)
        /// Apple Translation (with an installed language pack) turns the
        /// source into English, then the model translates English → Persian.
        case systemThenLocal(systemSource: String, local: Direction)
        /// The model turns Persian into English, then Apple Translation
        /// (installed) translates English into the target.
        case localThenSystem(local: Direction, systemTarget: String)
        case unsupported

        public var localDirections: [Direction] {
            switch self {
            case .local(let direction), .systemThenLocal(_, let direction), .localThenSystem(let direction, _):
                return [direction]
            case .localPivot(let first, let second):
                return [first, second]
            case .unsupported:
                return []
            }
        }
    }

    /// A local English bridge also works on devices without Apple Translation.
    public static func route(
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        allowsSystemPivot: Bool
    ) -> Route {
        guard let sourceLanguageCode else { return .unsupported }
        let source = modelLanguageIdentity(sourceLanguageCode)
        let target = modelLanguageIdentity(targetLanguageCode)
        guard !LyricTranslationGroupingPolicy.representsSameTranslationLanguage(source, target) else {
            return .unsupported
        }
        let sourceIsPersian = isPersianScriptPersian(source)
        let targetIsPersian = isPersianScriptPersian(target)
        guard !(isAnyPersian(source) && !sourceIsPersian),
              !(isAnyPersian(target) && !targetIsPersian) else { return .unsupported }
        if let direct = directions.first(where: { $0.source == source && $0.target == target }) {
            return .local(direct)
        }
        // Preserve the installed system bridge for the existing Persian pack.
        if allowsSystemPivot, targetIsPersian {
            return .systemThenLocal(systemSource: source, local: .englishToPersian)
        }
        if allowsSystemPivot, sourceIsPersian {
            return .localThenSystem(local: .persianToEnglish, systemTarget: target)
        }
        let first = directions.first { $0.source == source && $0.target == englishIdentity }
        let second = directions.first { $0.source == englishIdentity && $0.target == target }
        if let first, let second { return .localPivot(first: first, second: second) }
        if allowsSystemPivot, let second {
            return .systemThenLocal(systemSource: source, local: second)
        }
        if allowsSystemPivot, let first {
            return .localThenSystem(local: first, systemTarget: target)
        }
        return .unsupported
    }

    // MARK: Output checks

    /// Cleans a model output for display. Returns nil when the result should
    /// not be shown: empty, a verbatim copy of the source, or runaway output
    /// that is far longer than the line it came from.
    public static func acceptedTranslation(source: String, translated: String) -> String? {
        let cleaned = translated
            .replacingOccurrences(of: "\u{2047}", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return nil }
        let trimmedSource = source
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard cleaned != trimmedSource else { return nil }
        let limit = max(40, 4 * trimmedSource.count)
        guard cleaned.count <= limit else { return nil }
        if hasRunawayRepetition(cleaned), !hasRunawayRepetition(trimmedSource) {
            return nil
        }
        return cleaned
    }

    /// A word repeated more than six times in a row: the greedy decoder's
    /// failure mode, unless the lyric line itself does that.
    static func hasRunawayRepetition(_ text: String) -> Bool {
        var previous: Substring?
        var run = 0
        for word in text.split(whereSeparator: \.isWhitespace) {
            let folded = word.trimmingCharacters(in: .punctuationCharacters)
            let key = Substring(folded)
            if key == previous {
                run += 1
                if run > 6 { return true }
            } else {
                previous = key
                run = 1
            }
        }
        return false
    }

    // MARK: Cache identity

    /// Cache namespace for results of one model build, so an updated model
    /// never reuses the previous build's translations.
    public static func cacheProviderVersion(modelVersion: String) -> String {
        "local-translation-\(modelVersion)"
    }

    // MARK: Helpers

    private static func modelLanguageIdentity(_ code: String) -> String {
        let identity = LyricTranslationGroupingPolicy.languageIdentity(code)
        if identity == "zh" { return "zh-Hans" }
        if isPersianScriptPersian(identity) { return persianIdentity }
        return identity
    }

    private static func primaryLanguage(_ identity: String) -> String {
        identity.split(separator: "-", maxSplits: 1).first.map { $0.lowercased() } ?? identity
    }

    private static func isAnyPersian(_ identity: String) -> Bool {
        primaryLanguage(identity) == persianIdentity
    }

    /// Persian written in its usual Arabic script; the model has not seen
    /// Latin transliteration.
    private static func isPersianScriptPersian(_ identity: String) -> Bool {
        LyricTranslationGroupingPolicy.representsSameTranslationLanguage(identity, persianIdentity)
    }
}

/// `translation-model.json` at the root of the model asset pack.
public struct LocalLyricTranslationManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let source: String
        public let target: String
        /// Compiled Core ML model directory, relative to the pack root.
        public let model: String
        /// SentencePiece model file, relative to the pack root.
        public let vocabulary: String
        public let targetVocabulary: String?

        public init(source: String, target: String, model: String, vocabulary: String, targetVocabulary: String? = nil) {
            self.source = source
            self.target = target
            self.model = model
            self.vocabulary = vocabulary
            self.targetVocabulary = targetVocabulary
        }

        public var direction: LocalLyricTranslationPolicy.Direction {
            .init(source: source, target: target)
        }
    }

    /// Layout version this app understands.
    public static let supportedFormat = 1
    /// A file every compiled Core ML model contains; the pack API resolves
    /// files, not directories.
    public static let compiledModelAnchor = "coremldata.bin"

    public let format: Int
    /// Model build identity. Part of every cache key.
    public let version: String
    public let directions: [Entry]

    public init(format: Int, version: String, directions: [Entry]) {
        self.format = format
        self.version = version
        self.directions = directions
    }

    /// Decodes and validates a manifest: the supported format, a version,
    /// both directions, and only relative paths inside the pack.
    public static func decode(
        _ data: Data,
        requiredDirections: [LocalLyricTranslationPolicy.Direction] = LocalLyricTranslationPolicy.persianDirections
    ) -> LocalLyricTranslationManifest? {
        guard let manifest = try? JSONDecoder().decode(Self.self, from: data),
              manifest.format == supportedFormat,
              !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let listed = manifest.directions.map(\.direction)
        guard Set(listed).count == listed.count,
              requiredDirections.allSatisfy({ listed.contains($0) }),
              manifest.directions.allSatisfy({ entry in
                  LocalLyricTranslationPolicy.directions.contains(entry.direction)
                      && isSafeRelativePath(entry.model) && isSafeRelativePath(entry.vocabulary)
                      && (entry.targetVocabulary.map(isSafeRelativePath) ?? true)
              }) else { return nil }
        return manifest
    }

    public func entry(for direction: LocalLyricTranslationPolicy.Direction) -> Entry? {
        directions.first { $0.direction == direction }
    }

    /// Files that must exist before the model can be loaded.
    public var requiredFiles: [String] {
        directions.flatMap { entry in
            ["\(entry.model)/\(Self.compiledModelAnchor)", entry.vocabulary]
                + (entry.targetVocabulary.map { [$0] } ?? [])
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}
