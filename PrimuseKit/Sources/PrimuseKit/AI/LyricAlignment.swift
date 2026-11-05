import Foundation

public struct LyricAlignmentLine: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
    public var start: Double?
    public var end: Double?
}

public struct LyricAlignmentOutput: Codable, Sendable {
    public struct Line: Codable, Sendable {
        public var id: String
        public var status: String
        public var words: [LyricSyllable]
    }
    public var lines: [Line]
}

public enum LyricAlignmentFailure: Error, Sendable {
    case unsupportedLyrics, invalidDuration, invalidResponse, unavailable, editorChanged
}

public enum LyricAlignment {
    public static let languages = ["Chinese", "English", "Cantonese", "French", "German", "Italian", "Japanese", "Korean", "Portuguese", "Russian", "Spanish"]

    public static func requestLines(document: LyricsEditorDocument, duration: Double) throws -> [LyricAlignmentLine] {
        guard duration.isFinite, duration > 0, duration <= 600 else { throw LyricAlignmentFailure.invalidDuration }
        guard document.lines.allSatisfy({ $0.voice == .primary && $0.background?.isEmpty != false && $0.syllables?.contains(where: { $0.languageCode != nil }) != true }) else {
            throw LyricAlignmentFailure.unsupportedLyrics
        }
        let source = document.lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !LyricsTextTools.isCreditLine($0.text)
        }
        guard !source.isEmpty, source.count <= 500,
              source.allSatisfy({ $0.text.utf16.count <= 2_000 }),
              source.reduce(0, { $0 + $1.text.utf16.count }) <= 30_000 else { throw LyricAlignmentFailure.unsupportedLyrics }
        let timed = source.allSatisfy { $0.timestamp != nil }
        guard timed || duration <= 300 else { throw LyricAlignmentFailure.invalidDuration }
        let offset = LyricDocumentOffsetPolicy.offsetSeconds(in: document.metadataLines) ?? 0
        var previousEnd = 0.0
        return try source.enumerated().map { index, row in
            guard timed else { return LyricAlignmentLine(id: row.id.uuidString, text: row.text) }
            let start = row.timestamp! - offset
            let next = index + 1 < source.count ? source[index + 1].timestamp! - offset : duration
            let end = row.endTimestamp.map { $0 - offset } ?? next
            guard start.isFinite, end.isFinite, start >= previousEnd, start >= 0,
                  start < end, end <= duration, end <= next else { throw LyricAlignmentFailure.unsupportedLyrics }
            previousEnd = end
            return LyricAlignmentLine(id: row.id.uuidString, text: row.text, start: start, end: end)
        }
    }

    public static func applying(_ output: LyricAlignmentOutput, to document: LyricsEditorDocument,
                                duration: Double) throws -> LyricsEditorDocument {
        let requested = try requestLines(document: document, duration: duration)
        guard output.lines.count == requested.count else { throw LyricAlignmentFailure.invalidResponse }
        var result = document
        let offset = LyricDocumentOffsetPolicy.offsetSeconds(in: document.metadataLines) ?? 0
        if offset != 0 {
            result.metadataLines = LyricDocumentOffsetPolicy.removingOffsetTag(from: result.metadataLines)
            for index in result.lines.indices {
                result.lines[index].timestamp = result.lines[index].timestamp.map { max(0, $0 - offset) }
                result.lines[index].endTimestamp = result.lines[index].endTimestamp.map { max(0, $0 - offset) }
                result.lines[index].syllables = result.lines[index].syllables?.map {
                    LyricSyllable(text: $0.text, start: max(0, $0.start - offset), end: max(0, $0.end - offset),
                                  endTiming: $0.endTiming, languageCode: $0.languageCode)
                }
            }
        }
        var previousEnd = 0.0
        var aligned = 0
        var wordCount = 0
        for (line, source) in zip(output.lines, requested) {
            guard line.id == source.id else { throw LyricAlignmentFailure.invalidResponse }
            if line.status == "unaligned" {
                guard line.words.isEmpty else { throw LyricAlignmentFailure.invalidResponse }
                previousEnd = source.end ?? previousEnd
                continue
            }
            wordCount += line.words.count
            guard line.status == "aligned", !line.words.isEmpty, wordCount <= 12_000,
                  line.words.map(\.text).joined().utf8.elementsEqual(source.text.utf8) else { throw LyricAlignmentFailure.invalidResponse }
            for word in line.words {
                guard !word.text.isEmpty, word.start.isFinite, word.end.isFinite,
                      word.start >= max(previousEnd, source.start ?? 0), word.end > word.start,
                      word.end <= (source.end ?? duration) else { throw LyricAlignmentFailure.invalidResponse }
                previousEnd = word.end
            }
            previousEnd = source.end ?? previousEnd
            guard let index = result.lines.firstIndex(where: { $0.id.uuidString == line.id }) else {
                throw LyricAlignmentFailure.invalidResponse
            }
            let words = line.words.map { LyricSyllable(text: $0.text, start: $0.start, end: $0.end, endTiming: .explicit) }
            guard words[0].start >= 0 else { throw LyricAlignmentFailure.invalidResponse }
            result.lines[index].timestamp = words[0].start
            result.lines[index].endTimestamp = words.last!.end
            result.lines[index].syllables = words
            aligned += 1
        }
        guard aligned > 0 else { throw LyricAlignmentFailure.invalidResponse }
        return result
    }
}
