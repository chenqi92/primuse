import Foundation

public struct SettingsSearchDocument: Equatable, Sendable {
    public let id: String
    public let title: String
    public let path: String
    public let keywords: [String]
    public let isPage: Bool

    public init(id: String, title: String, path: String, keywords: [String] = [], isPage: Bool = false) {
        self.id = id
        self.title = title
        self.path = path
        self.keywords = keywords
        self.isPage = isPage
    }
}

/// Index only descriptive metadata: setting values may contain credentials or server addresses.
public struct SettingsSearchIndex: Sendable {
    private struct Record: Sendable {
        let id: String
        let title: String
        let keywords: [String]
        let path: String
        let romanized: String
        let order: Int
        let isPage: Bool
    }

    private let records: [Record]

    public init(documents: [SettingsSearchDocument]) {
        records = documents.enumerated().map { index, document in
            Record(
                id: document.id,
                title: Self.normalized(document.title),
                keywords: document.keywords.map(Self.normalized),
                path: Self.normalized(document.path),
                romanized: Self.normalized(document.title.applyingTransform(.toLatin, reverse: false) ?? ""),
                order: index,
                isPage: document.isPage
            )
        }
    }

    public func search(_ query: String) -> [String] {
        let phrase = Self.normalized(query)
        guard !phrase.isEmpty else { return [] }
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { Self.normalized(String($0)) }
            .filter { !$0.isEmpty }
        return records.compactMap { record -> (id: String, score: Int, order: Int)? in
            let fields = [record.title] + record.keywords + [record.path]
            let score: Int
            if record.title == phrase {
                score = 1_000
            } else if record.title.hasPrefix(phrase) {
                score = 850
            } else if record.title.contains(phrase) {
                score = 750
            } else if record.keywords.contains(phrase) {
                score = 700
            } else if record.keywords.contains(where: { $0.contains(phrase) }) {
                score = 600
            } else if words.count > 1, words.allSatisfy({ word in fields.contains { $0.contains(word) } }) {
                score = 450
            } else if record.romanized.contains(phrase) {
                score = 350
            } else if record.path.contains(phrase) {
                score = 200
            } else {
                return nil
            }
            return (record.id, score + (record.isPage ? 0 : 10), record.order)
        }
        .sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
        .map(\.id)
    }

    public static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
    }
}

public enum SettingsRecentItems {
    public static let limit = 5

    public static func recording(_ id: String, in previous: [String], availableIDs: Set<String>) -> [String] {
        var seen = Set<String>()
        let candidates = availableIDs.contains(id) ? [id] + previous : previous
        return candidates.filter { availableIDs.contains($0) && seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }
}
