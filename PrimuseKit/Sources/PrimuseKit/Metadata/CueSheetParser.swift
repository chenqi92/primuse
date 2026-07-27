import CoreFoundation
import Foundation

public struct CueSheet: Equatable, Sendable {
    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var genre: String?
    public var year: Int?
    public var files: [CueFile]

    public init(
        title: String? = nil,
        performer: String? = nil,
        songwriter: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        files: [CueFile] = []
    ) {
        self.title = title
        self.performer = performer
        self.songwriter = songwriter
        self.genre = genre
        self.year = year
        self.files = files
    }
}

public struct CueFile: Equatable, Sendable {
    public var name: String
    public var type: String
    public var tracks: [CueTrack]

    public init(name: String, type: String, tracks: [CueTrack] = []) {
        self.name = name
        self.type = type
        self.tracks = tracks
    }
}

public struct CueTrack: Equatable, Sendable {
    public var number: Int
    public var type: String
    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?

    public init(
        number: Int,
        type: String,
        title: String? = nil,
        performer: String? = nil,
        songwriter: String? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) {
        self.number = number
        self.type = type
        self.title = title
        self.performer = performer
        self.songwriter = songwriter
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Tolerant parser for the CDRWIN CUE subset used by music archives.
///
/// It deliberately ignores unknown directives while preserving the pieces a
/// library/player needs: FILE, TRACK AUDIO, TITLE/PERFORMER/SONGWRITER and
/// INDEX 01. UTF-8 (with or without BOM), UTF-16 and legacy GB18030 sheets are
/// accepted because Chinese NAS libraries commonly contain all three.
public enum CueSheetParser {
    public static func parse(data: Data) -> CueSheet? {
        guard let text = decode(data: data) else { return nil }
        return parse(text: text)
    }

    public static func parse(text: String) -> CueSheet? {
        var sheet = CueSheet()
        var currentFileIndex: Int?
        var currentTrackIndex: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let split = line.firstIndex(where: { $0.isWhitespace })
            let command = String(split.map { line[..<$0] } ?? Substring(line)).uppercased()
            let remainder = split.map {
                String(line[$0...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""

            switch command {
            case "FILE":
                guard let parsed = parseFile(remainder) else { continue }
                sheet.files.append(CueFile(name: parsed.name, type: parsed.type))
                currentFileIndex = sheet.files.count - 1
                currentTrackIndex = nil

            case "TRACK":
                guard let fileIndex = currentFileIndex else { continue }
                let fields = remainder.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 2, let number = Int(fields[0]) else { continue }
                sheet.files[fileIndex].tracks.append(
                    CueTrack(number: number, type: String(fields[1]).uppercased())
                )
                currentTrackIndex = sheet.files[fileIndex].tracks.count - 1

            case "TITLE", "PERFORMER", "SONGWRITER":
                let value = unquote(remainder)
                guard !value.isEmpty else { continue }
                if let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex {
                    switch command {
                    case "TITLE": sheet.files[fileIndex].tracks[trackIndex].title = value
                    case "PERFORMER": sheet.files[fileIndex].tracks[trackIndex].performer = value
                    default: sheet.files[fileIndex].tracks[trackIndex].songwriter = value
                    }
                } else {
                    switch command {
                    case "TITLE": sheet.title = value
                    case "PERFORMER": sheet.performer = value
                    default: sheet.songwriter = value
                    }
                }

            case "INDEX":
                guard let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex else { continue }
                let fields = remainder.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 2, fields[0] == "01",
                      let time = parseTime(String(fields[1])) else { continue }
                sheet.files[fileIndex].tracks[trackIndex].startTime = time

            case "REM":
                let fields = remainder.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2 else { continue }
                let key = fields[0].uppercased()
                let value = unquote(String(fields[1]))
                if key == "GENRE", !value.isEmpty {
                    sheet.genre = value
                } else if key == "DATE" || key == "YEAR" {
                    sheet.year = Int(value.prefix(4))
                }

            default:
                continue
            }
        }

        // A track ends at the next INDEX 01 only when both entries refer to
        // the same physical FILE. The last track's end is filled from the
        // decoded image duration by the scanner.
        for fileIndex in sheet.files.indices {
            let trackIndices = sheet.files[fileIndex].tracks.indices
            for trackIndex in trackIndices {
                guard sheet.files[fileIndex].tracks[trackIndex].startTime != nil else { continue }
                sheet.files[fileIndex].tracks[trackIndex].endTime = trackIndices
                    .dropFirst(trackIndex + 1)
                    .lazy
                    .compactMap { sheet.files[fileIndex].tracks[$0].startTime }
                    .first
            }
        }

        let hasPlayableTrack = sheet.files.contains { file in
            file.tracks.contains { $0.type == "AUDIO" && $0.startTime != nil }
        }
        return hasPlayableTrack ? sheet : nil
    }

    public static func parseTime(_ value: String) -> TimeInterval? {
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let minutes = Int(fields[0]),
              let seconds = Int(fields[1]),
              let frames = Int(fields[2]),
              minutes >= 0, (0..<60).contains(seconds), (0..<75).contains(frames) else {
            return nil
        }
        return Double(minutes * 60 + seconds) + Double(frames) / 75.0
    }

    private static func parseFile(_ value: String) -> (name: String, type: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.first == "\"" {
            var escaped = false
            var closingQuote: String.Index?
            var index = trimmed.index(after: trimmed.startIndex)
            while index < trimmed.endIndex {
                let character = trimmed[index]
                if character == "\"", !escaped {
                    closingQuote = index
                    break
                }
                escaped = character == "\\" && !escaped
                if character != "\\" { escaped = false }
                index = trimmed.index(after: index)
            }
            guard let closingQuote else { return nil }
            let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingQuote])
                .replacingOccurrences(of: "\\\"", with: "\"")
            let type = trimmed[trimmed.index(after: closingQuote)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (name, type.uppercased())
        }

        let fields = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else { return nil }
        return (fields.dropLast().joined(separator: " "), fields.last!.uppercased())
    }

    private static func unquote(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count >= 2, result.first == "\"", result.last == "\"" {
            result.removeFirst()
            result.removeLast()
        }
        return result.replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func decode(data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if var utf8 = String(data: data, encoding: .utf8) {
            if utf8.first == "\u{FEFF}" { utf8.removeFirst() }
            return utf8
        }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }
}
