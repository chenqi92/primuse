import Foundation

public enum WidgetLyricPresentationRole: String, Hashable, Sendable {
    case previous
    case current
    case next
}

public struct WidgetLyricPresentationRow: Identifiable, Hashable, Sendable {
    public let index: Int
    public let text: String
    public let role: WidgetLyricPresentationRole

    public var id: Int { index }

    public init(index: Int, text: String, role: WidgetLyricPresentationRole) {
        self.index = index
        self.text = text
        self.role = role
    }
}

/// Chooses a stable lyric window for fixed-height widgets. Reducing the row
/// budget always preserves the current line before dropping surrounding lines.
public enum WidgetLyricsPresentationPolicy {
    public static func rows(
        in lines: [WidgetLyricLine],
        anchorIndex: Int,
        maximumRowCount: Int
    ) -> [WidgetLyricPresentationRow] {
        guard !lines.isEmpty, maximumRowCount > 0 else { return [] }

        let currentIndex = min(max(anchorIndex, 0), lines.count - 1)
        let rowCount = min(lines.count, min(maximumRowCount, 3))

        let startIndex: Int
        switch rowCount {
        case 1:
            startIndex = currentIndex
        case 2:
            startIndex = currentIndex < lines.count - 1
                ? currentIndex
                : max(0, currentIndex - 1)
        default:
            startIndex = min(max(0, currentIndex - 1), lines.count - rowCount)
        }

        return (startIndex..<(startIndex + rowCount)).map { index in
            let role: WidgetLyricPresentationRole
            if index < currentIndex {
                role = .previous
            } else if index == currentIndex {
                role = .current
            } else {
                role = .next
            }
            return WidgetLyricPresentationRow(index: index, text: lines[index].text, role: role)
        }
    }

    /// New snapshots carry the direction resolved from the complete LRC/ELRC
    /// document, including `[la:]` metadata. Legacy snapshots fall back to
    /// dominant-script inference without changing mixed-direction text order.
    public static func writingDirection(
        for lines: [WidgetLyricLine],
        preferredDirection: LyricWritingDirection?
    ) -> LyricWritingDirection {
        if let preferredDirection { return preferredDirection }

        let lyricLines = lines.enumerated().map { index, line in
            LyricLine(
                id: "widget-\(index)",
                timestamp: line.time,
                text: line.text,
                isSynchronized: false
            )
        }
        return LyricWritingDirectionPolicy.resolve(in: lyricLines)
    }
}
