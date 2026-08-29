import Foundation

/// Decodes songLyrics v2 cue timing and converts it to the relative A2 LRC
/// representation already understood by Primuse's shared lyrics parser.
public enum OpenSubsonicLyricsConverter {
    public struct Track: Decodable, Sendable {
        public let kind: String?
        public let synced: Bool?
        public let offset: Double?
        public let line: [Line]?
        public let cueLine: [CueLine]?
    }

    public struct Line: Decodable, Sendable {
        public let start: Double?
        public let value: String?
    }

    public struct CueLine: Decodable, Sendable {
        public let index: Int?
        public let start: Int?
        public let end: Int?
        public let value: String?
        public let cue: [Cue]?
    }

    public struct Cue: Decodable, Sendable {
        public let start: Int?
        public let end: Int?
        public let value: String?
        public let byteStart: Int?
        public let byteEnd: Int?
    }

    public static func text(from tracks: [Track]) -> String? {
        let candidates = tracks.filter { !($0.line ?? []).isEmpty }
        let main = candidates.filter { normalizedKind($0.kind) == "main" }
        let track = main.first(where: hasRenderableCues)
            ?? main.first
        guard let track, let lines = track.line else {
            return nil
        }

        let timingOffset = track.offset ?? 0
        // ServerLyricsConnector exposes one lyrics document. The v2 contract
        // orders the main cueLine first when an index has multiple vocal
        // agents, so render that lead layer and leave parallel background
        // layers out instead of interleaving their text.
        let cuesByIndex = Dictionary(grouping: track.cueLine ?? []) { $0.index ?? -1 }
        var output: [String] = []
        for (index, line) in lines.enumerated() {
            let nextLineStart = lines.indices.contains(index + 1)
                ? lines[index + 1].start.map { adjustedTimestamp($0, offset: timingOffset) }
                : nil
            if track.synced != false,
               let cueLine = cuesByIndex[index]?.first,
               let text = serialize(
                   cueLine,
                   parent: line,
                   nextLineStart: nextLineStart,
                   timingOffset: timingOffset
               ) {
                output.append(text)
            } else if let value = lineValue(line.value) {
                output.append(
                    line.start.map {
                        lrcTimestamp(adjustedTimestamp($0, offset: timingOffset)) + value
                    } ?? value
                )
            }
        }

        let result = output.joined(separator: "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result
    }

    private static func hasRenderableCues(_ track: Track) -> Bool {
        track.synced != false && (track.cueLine ?? []).contains { cueLine in
            (cueLine.cue ?? []).contains { cue in
                cue.start != nil && !(cue.value ?? "").isEmpty
            }
        }
    }

    private static func serialize(
        _ cueLine: CueLine,
        parent: Line,
        nextLineStart: Int?,
        timingOffset: Double
    ) -> String? {
        let cues = (cueLine.cue ?? []).enumerated().compactMap { order, cue -> TimedCue? in
            guard let start = cue.start, start >= 0,
                  let value = cue.value, !value.isEmpty else { return nil }
            return TimedCue(
                order: order,
                start: adjustedTimestamp(start, offset: timingOffset),
                end: cue.end.map { adjustedTimestamp($0, offset: timingOffset) },
                value: value,
                byteStart: cue.byteStart,
                byteEnd: cue.byteEnd
            )
        }.sorted {
            $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start
        }
        guard !cues.isEmpty,
              cues.contains(where: { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }

        let declaredLineStart = cueLine.start.map {
            adjustedTimestamp($0, offset: timingOffset)
        } ?? parent.start.map {
            adjustedTimestamp($0, offset: timingOffset)
        }
        let lineStart = min(declaredLineStart ?? cues[0].start, cues[0].start)
        let lineEnd = cueLine.end.map { adjustedTimestamp($0, offset: timingOffset) }
            ?? cues.compactMap(\.end).max()
            ?? nextLineStart
            ?? addingMilliseconds(400, to: cues.last!.start)
        let values = resolvedValues(for: cues, canonicalLine: cueLine.value)
        let body: String = cues.enumerated().map { index, cue -> String in
            let end = cue.end
                ?? (cues.indices.contains(index + 1) ? cues[index + 1].start : nil)
                ?? cueLine.end.map { adjustedTimestamp($0, offset: timingOffset) }
                ?? nextLineStart
                ?? addingMilliseconds(400, to: cue.start)
            return "<\(cue.start - lineStart),\(max(0, end - cue.start))>\(values[index])"
        }.joined()
        return "[\(lineStart),\(max(0, lineEnd - lineStart))]\(body)"
    }

    /// byteStart/byteEnd point into cueLine.value's final UTF-8 bytes. Taking
    /// each segment up to the next cue retains spaces and any untimed text.
    private static func resolvedValues(
        for cues: [TimedCue],
        canonicalLine: String?
    ) -> [String] {
        let fallback = cues.map { oneLine($0.value) }
        guard let canonicalLine, !canonicalLine.isEmpty else { return fallback }
        let bytes = Array(canonicalLine.utf8)
        var result: [String] = []
        for index in cues.indices {
            guard let start = cues[index].byteStart,
                  let end = cues[index].byteEnd,
                  start >= 0, end >= start, end < bytes.count else {
                return fallback
            }
            let lower = index == cues.startIndex ? 0 : start
            let upper: Int
            if cues.indices.contains(index + 1) {
                guard let nextStart = cues[index + 1].byteStart,
                      nextStart > end, nextStart <= bytes.count else { return fallback }
                upper = nextStart
            } else {
                upper = bytes.count
            }
            guard lower < upper,
                  let value = String(bytes: bytes[lower..<upper], encoding: .utf8) else {
                return fallback
            }
            result.append(oneLine(value))
        }
        return result
    }

    private static func normalizedKind(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "main" : normalized.lowercased()
    }

    private static func lineValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = oneLine(value)
        return normalized.trimmingCharacters(in: .whitespaces).isEmpty ? nil : normalized
    }

    private static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func lrcTimestamp(_ milliseconds: Int) -> String {
        let centiseconds = max(0, milliseconds) / 10
        return String(
            format: "[%02d:%02d.%02d]",
            centiseconds / 6_000,
            (centiseconds / 100) % 60,
            centiseconds % 100
        )
    }

    /// OpenSubsonic defines a positive track offset as displaying lyrics
    /// earlier, and a negative offset as displaying them later.
    private static func adjustedTimestamp(_ timestamp: Int, offset: Double) -> Int {
        adjustedTimestamp(Double(timestamp), offset: offset)
    }

    /// The API permits fractional line starts and offsets, while Primuse's
    /// relative A2 representation has millisecond precision.
    private static func adjustedTimestamp(_ timestamp: Double, offset: Double) -> Int {
        guard timestamp.isFinite, offset.isFinite else { return 0 }
        let adjusted = max(0, timestamp) - offset
        if adjusted <= 0 { return 0 }
        if adjusted >= Double(Int.max) { return .max }
        return Int(adjusted.rounded())
    }

    private static func addingMilliseconds(_ milliseconds: Int, to timestamp: Int) -> Int {
        let (result, overflow) = timestamp.addingReportingOverflow(milliseconds)
        return overflow ? .max : result
    }

    private struct TimedCue {
        let order: Int
        let start: Int
        let end: Int?
        let value: String
        let byteStart: Int?
        let byteEnd: Int?
    }
}
