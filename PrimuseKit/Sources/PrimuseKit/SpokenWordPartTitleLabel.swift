import Foundation

/// The playing part's title as the audiobook player sets it: the episode
/// number a file name starts with ("36 【神作｜宿环】", "012. 风起") stands
/// apart from the rest, so the row reads "36 | 【神作｜宿环】".
///
/// Only a number that a separator or an opening bracket closes off is split
/// away. One that runs straight into the words ("3体", "1984") is part of
/// the title, and a title that is nothing but a number stays whole.
///
/// A compound number — numbers joined by a hyphen or a dot ("2-4 风起",
/// "1.1 序章") — is one number: it is split away whole, never torn into
/// "2 | 4 风起". With no words after it ("1-1", "2.4", "1 - 1") nothing is
/// split and the title reads as written.
public struct SpokenWordPartTitleLabel: Equatable, Sendable {
    /// The leading episode number; nil when the title does not start with
    /// one. A single number drops its leading zeros ("012" → "12"); a
    /// compound one reads as written ("01-02"), only in ASCII digits.
    public var number: String?
    public var title: String

    public init(number: String? = nil, title: String) {
        self.number = number
        self.title = title
    }

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(number: nil, title: trimmed)

        guard let leading = Self.leadingNumber(in: trimmed) else { return }
        var rest = trimmed[leading.end...]
        guard let first = rest.first else { return }

        if Self.openingBrackets.contains(first) {
            // 「36【神作】」: the bracket belongs to the title.
        } else if first.isWhitespace || Self.separators.contains(first) {
            rest = rest.drop { $0.isWhitespace || Self.separators.contains($0) }
        } else {
            return
        }
        let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only numbers left ("1 - 1") are no title to set the number apart from.
        guard remainder.contains(where: { character in
            Self.digitValue(character) == nil
                && !character.isWhitespace
                && !Self.separators.contains(character)
        }) else { return }

        self.number = leading.number
        self.title = remainder
    }

    /// The number a title starts with and where it ends: one run of digits,
    /// or runs joined by `compoundJoiners` ("2-4", "1.1", "01_02"). A run
    /// longer than five digits is a date or an id, not an episode number.
    private static func leadingNumber(in text: String) -> (number: String, end: String.Index)? {
        let digits = text.prefix { digitValue($0) != nil }
        guard !digits.isEmpty, digits.count <= 5 else { return nil }
        var number = asciiDigits(digits)
        var end = digits.endIndex
        var isCompound = false
        while end < text.endIndex, compoundJoiners.contains(text[end]) {
            let next = text[text.index(after: end)...].prefix { digitValue($0) != nil }
            guard !next.isEmpty, next.count <= 5 else { break }
            number.append(text[end])
            number += asciiDigits(next)
            end = next.endIndex
            isCompound = true
        }
        if !isCompound {
            let value = number.drop { $0 == "0" }
            number = value.isEmpty ? "0" : String(value)
        }
        return (number, end)
    }

    private static func asciiDigits(_ digits: Substring) -> String {
        digits.map { String(digitValue($0) ?? 0) }.joined()
    }

    private static let separators: Set<Character> = [
        ".", "．", "。", "、", ",", "，", "-", "－", "–", "—", "_", ":", "：", ")", "）", "|", "｜", "/",
    ]

    /// What joins the parts of a compound number when a digit follows it.
    private static let compoundJoiners: Set<Character> = [
        "-", "－", "‐", "–", "—", ".", "．", "_",
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
