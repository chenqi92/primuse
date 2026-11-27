import Foundation

public enum SpokenChapterImport {
    public enum Failure: Error, Equatable, Sendable {
        case tooLarge, invalidFormat, invalidTimeline, empty
    }

    public static let maximumBytes = 2 * 1_024 * 1_024
    public static let maximumChapters = 10_000

    private struct Document: Decodable {
        var chapters: [Chapter]
    }

    private struct Chapter: Decodable {
        var startTime: Double
        var title: String?
        var endTime: Double?
        var toc: Bool?
    }

    public static func parse(_ data: Data, duration: TimeInterval = 0) throws -> [MediaChapter] {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let decoded = String(data: data, encoding: .utf8) else { throw Failure.invalidFormat }
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
        guard !text.isEmpty else { throw Failure.empty }
        let chapters: [MediaChapter]
        if text.hasPrefix("{") {
            guard let document = try? JSONDecoder().decode(Document.self, from: Data(text.utf8)) else {
                throw Failure.invalidFormat
            }
            guard document.chapters.count <= maximumChapters else { throw Failure.tooLarge }
            chapters = try document.chapters.filter { $0.toc != false }.map { chapter in
                guard chapter.startTime.isFinite, chapter.startTime >= 0, chapter.startTime <= 31_536_000 else {
                    throw Failure.invalidTimeline
                }
                if let end = chapter.endTime, !end.isFinite || end > 31_536_000 || end <= chapter.startTime {
                    throw Failure.invalidTimeline
                }
                let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return MediaChapter(startTime: chapter.startTime,
                                    title: title.flatMap { $0.isEmpty ? nil : $0 }
                                        ?? ChapterTimeFormatter.string(from: chapter.startTime), endTime: chapter.endTime)
            }
        } else {
            chapters = try text.components(separatedBy: .newlines).compactMap { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { return nil }
                guard let split = line.firstIndex(where: { $0.isWhitespace }),
                      let time = timestamp(String(line[..<split])) else { throw Failure.invalidFormat }
                let title = line[split...].trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { throw Failure.invalidFormat }
                return MediaChapter(startTime: time, title: title)
            }
        }
        guard !chapters.isEmpty else { throw Failure.empty }
        guard chapters.count <= maximumChapters else { throw Failure.tooLarge }
        var previous: TimeInterval = -1
        for (index, chapter) in chapters.enumerated() {
            guard chapter.startTime.isFinite, chapter.startTime >= 0, chapter.startTime <= 31_536_000, chapter.startTime > previous,
                  !(duration.isFinite && duration > 0 && chapter.startTime >= duration) else {
                throw Failure.invalidTimeline
            }
            guard chapter.title.count <= 500, !chapter.title.contains(where: { $0.isNewline }) else {
                throw Failure.invalidFormat
            }
            if let end = chapter.endTime {
                guard !(duration.isFinite && duration > 0 && end > duration),
                      !(index + 1 < chapters.count && end > chapters[index + 1].startTime) else {
                    throw Failure.invalidTimeline
                }
            }
            previous = chapter.startTime
        }
        return chapters
    }

    private static func timestamp(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              let secondsText = parts.last,
              secondsText.range(of: "^[0-9]{2}(\\.[0-9]+)?$", options: .regularExpression) != nil,
              let seconds = Double(secondsText), seconds < 60 else { return nil }
        let whole = parts.dropLast()
        guard whole.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let first = Double(whole[0]), first.isFinite else { return nil }
        if parts.count == 2 { return first * 60 + seconds }
        guard let minutes = Double(whole[1]), minutes < 60 else { return nil }
        return first * 3_600 + minutes * 60 + seconds
    }
}

/// A preview remembers the record it was based on so a later cloud edit cannot be overwritten.
public struct SpokenChapterImportPreview: Sendable {
    public let songID: String
    public let chapters: [MediaChapter]
    public let previousRevision: String?

    public init(songID: String, data: Data, duration: TimeInterval, previousRevision: String?) throws {
        self.songID = songID
        self.chapters = try SpokenChapterImport.parse(data, duration: duration)
        self.previousRevision = previousRevision
    }

    public func record(replacing current: SpokenChapterRecord?) throws -> SpokenChapterRecord {
        guard current?.revision == previousRevision else { throw SpokenChapterGeneration.Failure.changedDuringGeneration }
        var record = SpokenChapterRecord(id: songID, chapters: chapters, transcriptFingerprint: "", providerName: "file")
        record.origin = .imported
        return record
    }
}
