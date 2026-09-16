import Foundation

/// One lyric row as it appears on a shareable poster. Timing is preserved so
/// motion posters can highlight rows along the original playback timeline.
public struct LyricPosterLine: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String
    /// Translation shown under the source line when the user has translation
    /// turned on. Poster styles may drop it when the layout runs out of room.
    public let translation: String?
    /// Authored romanization of the source line. It shares the translation's
    /// switch and its fate when the layout runs out of room: both are
    /// secondary rows under the sung text.
    public let romanization: String?
    public let timestamp: TimeInterval
    public let endTimestamp: TimeInterval?
    public let isSynchronized: Bool

    public init(
        id: String,
        text: String,
        translation: String? = nil,
        romanization: String? = nil,
        timestamp: TimeInterval,
        endTimestamp: TimeInterval? = nil,
        isSynchronized: Bool
    ) {
        self.id = id
        self.text = text
        self.translation = translation
        self.romanization = romanization
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.isSynchronized = isSynchronized
    }
}

/// Everything a poster style needs about the song, independent of SwiftUI and
/// of where the lyrics came from. Renderers must not reach back into the
/// player: a poster is a snapshot, and the user keeps editing playback while
/// the share sheet is open.
public struct LyricPosterContent: Hashable, Sendable {
    public let songTitle: String
    public let artistName: String?
    public let albumTitle: String?
    public let year: Int?
    public let lines: [LyricPosterLine]

    public init(
        songTitle: String,
        artistName: String? = nil,
        albumTitle: String? = nil,
        year: Int? = nil,
        lines: [LyricPosterLine]
    ) {
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.year = year
        self.lines = lines
    }

    public var isEmpty: Bool { lines.isEmpty }

    public var hasTranslation: Bool {
        lines.contains { ($0.translation?.isEmpty == false) }
    }

    /// Any secondary row under the sung text — a translation, a romanization,
    /// or both. Layout and the share sheet switch on this rather than on the
    /// translation alone.
    public var hasCompanionText: Bool {
        hasTranslation || lines.contains { ($0.romanization?.isEmpty == false) }
    }

    /// Total characters across source lines. Layout uses it to pick a type
    /// scale, so translations are excluded — they render at a smaller size and
    /// styles may hide them entirely.
    public var characterCount: Int {
        lines.reduce(0) { $0 + $1.text.count }
    }

    public var longestLineLength: Int {
        lines.map(\.text.count).max() ?? 0
    }

    /// Whether every selected row carries real timing. Motion posters fall back
    /// to an even cadence otherwise.
    public var isSynchronized: Bool {
        !lines.isEmpty && lines.allSatisfy(\.isSynchronized)
    }

    public var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// Why a lyric row could not join the current selection. The UI turns this
/// into feedback instead of silently ignoring the tap.
public enum LyricPosterSelectionRejection: Hashable, Sendable {
    /// The selection already holds `LyricPosterSelectionPolicy.maximumLines`.
    case limitReached
    /// Poster selections stay one contiguous passage; the tapped row does not
    /// touch the existing range.
    case notAdjacent
}

public struct LyricPosterSelectionResult: Hashable, Sendable {
    public let selection: [String]
    public let rejection: LyricPosterSelectionRejection?

    public init(selection: [String], rejection: LyricPosterSelectionRejection? = nil) {
        self.selection = selection
        self.rejection = rejection
    }
}

/// Turns the player's lyric document into a poster-ready passage.
///
/// Selection is deliberately restricted to one contiguous run of lines: a
/// poster that stitches together unrelated lines reads as a quote that was
/// never sung that way, and the motion timeline would have to jump over the
/// gaps.
public enum LyricPosterSelectionPolicy {
    /// Upper bound for one poster. Past this, type size drops below what a
    /// shared screenshot can carry.
    public static let maximumLines = 8

    /// Rows that can be put on a poster: real text only. Unsynchronized
    /// documents (plain text lyrics) are still selectable — they simply cannot
    /// drive a motion timeline.
    public static func selectableLines(
        from lyrics: [LyricLine],
        translations: [String: String] = [:]
    ) -> [LyricPosterLine] {
        lyrics.compactMap { line in
            let text = normalized(line.text)
            guard !text.isEmpty else { return nil }
            let translation = translations[line.id].map(normalized).flatMap { $0.isEmpty ? nil : $0 }
            let romanization = line.romanization.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
            return LyricPosterLine(
                id: line.id,
                text: text,
                translation: translation,
                romanization: romanization,
                timestamp: line.timestamp,
                endTimestamp: line.endTime,
                isSynchronized: line.isSynchronized
            )
        }
    }

    /// The row to preselect when the user opens the sheet from the player: the
    /// line that is currently sung, or the first line before playback starts.
    public static func defaultSelection(
        in lines: [LyricPosterLine],
        playbackPosition: TimeInterval
    ) -> [String] {
        guard let anchor = anchorIndex(in: lines, playbackPosition: playbackPosition) else {
            return []
        }
        return [lines[anchor].id]
    }

    public static func anchorIndex(
        in lines: [LyricPosterLine],
        playbackPosition: TimeInterval
    ) -> Int? {
        guard !lines.isEmpty else { return nil }
        var anchor = 0
        for (index, line) in lines.enumerated()
        where line.isSynchronized && line.timestamp <= playbackPosition {
            anchor = index
        }
        return anchor
    }

    /// Adds or removes `id`, keeping the selection one contiguous passage.
    ///
    /// Deselecting an interior row would split the passage in two, so a tap
    /// inside the range trims the shorter side toward that row instead.
    public static func toggling(
        _ id: String,
        in lines: [LyricPosterLine],
        selection: [String]
    ) -> LyricPosterSelectionResult {
        guard let target = lines.firstIndex(where: { $0.id == id }) else {
            return LyricPosterSelectionResult(selection: selection)
        }
        guard let range = selectedRange(in: lines, selection: selection) else {
            return LyricPosterSelectionResult(selection: [lines[target].id])
        }

        if range.contains(target) {
            if range.count == 1 {
                return LyricPosterSelectionResult(selection: [])
            }
            let trimmed: ClosedRange<Int>
            if target == range.lowerBound {
                trimmed = (range.lowerBound + 1)...range.upperBound
            } else if target == range.upperBound {
                trimmed = range.lowerBound...(range.upperBound - 1)
            } else if target - range.lowerBound <= range.upperBound - target {
                // Interior tap: keep the longer remaining side so one tap never
                // throws away most of a carefully built passage.
                trimmed = target...range.upperBound
            } else {
                trimmed = range.lowerBound...target
            }
            return LyricPosterSelectionResult(selection: ids(of: trimmed, in: lines))
        }

        guard target == range.lowerBound - 1 || target == range.upperBound + 1 else {
            return LyricPosterSelectionResult(selection: selection, rejection: .notAdjacent)
        }
        guard range.count < maximumLines else {
            return LyricPosterSelectionResult(selection: selection, rejection: .limitReached)
        }
        let extended = min(range.lowerBound, target)...max(range.upperBound, target)
        return LyricPosterSelectionResult(selection: ids(of: extended, in: lines))
    }

    /// Whether tapping `id` would extend the passage. Drives the enabled state
    /// of rows outside the current range.
    public static func canExtend(
        to id: String,
        in lines: [LyricPosterLine],
        selection: [String]
    ) -> Bool {
        guard let target = lines.firstIndex(where: { $0.id == id }) else { return false }
        guard let range = selectedRange(in: lines, selection: selection) else { return true }
        if range.contains(target) { return true }
        guard range.count < maximumLines else { return false }
        return target == range.lowerBound - 1 || target == range.upperBound + 1
    }

    /// Grows the passage outward from the anchor, used by "select more" and by
    /// the menu entry that opens the sheet with a ready-made passage.
    public static func expanded(
        from selection: [String],
        in lines: [LyricPosterLine],
        toCount count: Int
    ) -> [String] {
        guard !lines.isEmpty else { return [] }
        let budget = min(max(count, 1), min(maximumLines, lines.count))
        guard var range = selectedRange(in: lines, selection: selection) else {
            return ids(of: 0...(budget - 1), in: lines)
        }
        while range.count < budget {
            if range.upperBound + 1 < lines.count {
                range = range.lowerBound...(range.upperBound + 1)
            } else if range.lowerBound > 0 {
                range = (range.lowerBound - 1)...range.upperBound
            } else {
                break
            }
        }
        return ids(of: range, in: lines)
    }

    public static func content(
        songTitle: String,
        artistName: String?,
        albumTitle: String?,
        year: Int?,
        lines: [LyricPosterLine],
        selection: [String]
    ) -> LyricPosterContent {
        let selected: [LyricPosterLine]
        if let range = selectedRange(in: lines, selection: selection) {
            selected = Array(lines[range])
        } else {
            selected = []
        }
        return LyricPosterContent(
            songTitle: songTitle,
            artistName: artistName?.isEmpty == false ? artistName : nil,
            albumTitle: albumTitle?.isEmpty == false ? albumTitle : nil,
            year: year,
            lines: selected
        )
    }

    /// The contiguous span covered by `selection`. Unknown ids are ignored so a
    /// stale selection kept across a song change cannot resurrect rows.
    public static func selectedRange(
        in lines: [LyricPosterLine],
        selection: [String]
    ) -> ClosedRange<Int>? {
        let selectedIDs = Set(selection)
        let indices = lines.indices.filter { selectedIDs.contains(lines[$0].id) }
        guard let first = indices.first, let last = indices.last else { return nil }
        return first...last
    }

    private static func ids(of range: ClosedRange<Int>, in lines: [LyricPosterLine]) -> [String] {
        range.map { lines[$0].id }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
