import Foundation

/// The playing part's title as the audiobook player sets it: the episode
/// number a file name starts with ("36 【神作｜宿环】", "012. 风起") stands
/// apart from the rest, so the row reads "36 | 【神作｜宿环】".
///
/// Only a number that a separator or an opening bracket closes off is split
/// away. One that runs straight into the words ("3体", "1984") is part of
/// the title, and a title that is nothing but a number stays whole.
public struct SpokenWordPartTitleLabel: Equatable, Sendable {
    /// The leading episode number without its leading zeros; nil when the
    /// title does not start with one.
    public var number: String?
    public var title: String

    public init(number: String? = nil, title: String) {
        self.number = number
        self.title = title
    }

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(number: nil, title: trimmed)

        let digits = trimmed.prefix { Self.digitValue($0) != nil }
        guard !digits.isEmpty, digits.count <= 5 else { return }
        var rest = trimmed[digits.endIndex...]
        guard let first = rest.first else { return }

        if Self.openingBrackets.contains(first) {
            // 「36【神作】」: the bracket belongs to the title.
        } else if first.isWhitespace || Self.separators.contains(first) {
            rest = rest.drop { $0.isWhitespace || Self.separators.contains($0) }
        } else {
            return
        }
        let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return }

        let value = digits.map { String(Self.digitValue($0)!) }.joined()
        let number = value.drop { $0 == "0" }
        self.number = number.isEmpty ? "0" : String(number)
        self.title = remainder
    }

    private static let separators: Set<Character> = [
        ".", "．", "。", "、", ",", "，", "-", "－", "–", "—", "_", ":", "：", ")", "）", "|", "｜", "/",
    ]

    private static let openingBrackets: Set<Character> = [
        "【", "[", "［", "(", "（", "《", "「", "『", "〈", "<",
    ]

    /// 0–9 in ASCII or full width.
    private static func digitValue(_ character: Character) -> Int? {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value - 0x30)
        case 0xFF10...0xFF19: return Int(scalar.value - 0xFF10)
        default: return nil
        }
    }
}
