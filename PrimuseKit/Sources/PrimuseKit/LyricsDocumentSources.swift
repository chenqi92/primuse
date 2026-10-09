import Foundation

/// The file formats a song's lyric documents come in, as the lyric sources
/// page names them.
public enum LyricsDocumentFormat: String, Sendable, CaseIterable {
    case lrc, ttml, elrc, lys, yrc, qrc, vtt, srt

    /// What the file holds, independent of its extension: a `.yrc` and a
    /// `.qrc` are both millisecond word-timed text, an `.lrc` and an `.elrc`
    /// both LRC.
    public enum Family: Sendable, Equatable {
        case lrc
        case ttml
        case wordTimed
        case subtitle
    }

    public init?(fileName: String) {
        self.init(rawValue: (fileName as NSString).pathExtension.lowercased())
    }

    public var label: String { rawValue.uppercased() }

    /// Formats Primuse serializes itself. The others are only ever written
    /// back as the listener typed them.
    public var isSerializable: Bool {
        PrimuseConstants.supportedLyricsExtensions.contains(rawValue)
    }

    public var family: Family {
        switch self {
        case .lrc, .elrc: return .lrc
        case .ttml: return .ttml
        case .lys, .yrc, .qrc: return .wordTimed
        case .vtt, .srt: return .subtitle
        }
    }
}

/// One line of facts about a parsed document, for the row that lists it.
public struct LyricsDocumentSummary: Sendable, Equatable {
    public let lineCount: Int
    public let isWordLevel: Bool
    public let isSynchronized: Bool

    public init(lines: [LyricLine]) {
        lineCount = lines.count
        isWordLevel = lines.contains(where: \.containsWordLevelContent)
        isSynchronized = lines.contains(where: \.isSynchronized)
    }
}

/// Checks text typed into the raw editor of one lyric file before it is
/// written back over that file. The file keeps its format: the text has to
/// read as the kind of document its extension says, and has to hold lyrics.
/// Anything else a real-world file carries — an empty `[03:58.00]` end tag,
/// rows out of time order — is the listener's to keep.
public enum LyricsRawDocumentPolicy {
    public enum Outcome: Sendable, Equatable {
        case valid(LyricsDocumentSummary)
        case empty
        case tooLarge
        /// TTML pasted into an `.lrc`, LRC into a `.ttml`: saving it would
        /// leave a file its own readers cannot open.
        case formatMismatch(expected: LyricsDocumentFormat.Family, found: LyricsDocumentFormat.Family)
        /// The right kind of document, but nothing in it reads as a lyric line.
        case unreadable

        public var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    public struct Validation: Sendable, Equatable {
        public let outcome: Outcome
        public let lines: [LyricLine]
        /// LRC rows whose time tags do not parse, by 1-based line number.
        /// They do not block a save — the file may have shipped with them —
        /// but no player will show them, so the editor says so.
        public let unreadableLineNumbers: [Int]
    }

    /// The sidecar size every connector already refuses to go past.
    public static let maximumByteCount = 4 * 1_024 * 1_024

    public static func family(of content: String) -> LyricsDocumentFormat.Family {
        // Same order as `LyricsContentParser.parseText`, so a document is
        // judged by the reader that will actually open it.
        if LyricsContentParser.isTTML(content) { return .ttml }
        if WordTimedLyricsParser.detect(content) != nil { return .wordTimed }
        if LyricsContentParser.isSubtitleDocument(content) { return .subtitle }
        return .lrc
    }

    public static func validate(_ text: String, fileName: String) -> Validation {
        let content = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return Validation(outcome: .empty) }
        guard text.utf8.count <= maximumByteCount else { return Validation(outcome: .tooLarge) }

        let found = family(of: content)
        if let expected = LyricsDocumentFormat(fileName: fileName)?.family, expected != found {
            return Validation(outcome: .formatMismatch(expected: expected, found: found))
        }

        let lines = LyricsContentParser.parseText(content)
        guard !lines.isEmpty else { return Validation(outcome: .unreadable) }
        var unreadable: [Int] = []
        if found == .lrc {
            let rows = content.components(separatedBy: "\n")
            for issue in LyricsContentParser.validateEditableText(content).issues
            where issue.kind == .invalidTimestamp || issue.kind == .invalidWordTimestamp {
                // A bare `[03:58.00]` marks where the song ends; the editor's
                // own validation calls it an invalid row, a file is entitled to it.
                if rows.indices.contains(issue.lineNumber - 1),
                   rows[issue.lineNumber - 1].range(
                    of: #"^\s*(\[\d+:\d{2}(?:[.:]\d{1,3})?\])+\s*$"#,
                    options: .regularExpression
                   ) != nil {
                    continue
                }
                if unreadable.last != issue.lineNumber { unreadable.append(issue.lineNumber) }
            }
        }
        return Validation(
            outcome: .valid(LyricsDocumentSummary(lines: lines)),
            lines: lines,
            unreadableLineNumbers: unreadable
        )
    }
}

private extension LyricsRawDocumentPolicy.Validation {
    init(outcome: LyricsRawDocumentPolicy.Outcome) {
        self.init(outcome: outcome, lines: [], unreadableLineNumbers: [])
    }
}

/// How an edited lyric file goes back to bytes: in the text encoding it was
/// read in and with the byte-order mark it had, so a GBK `.lrc` an old player
/// reads stays GBK. Text the old encoding cannot hold is written as UTF-8.
public struct LyricsRawDocumentEncoding: Sendable, Equatable {
    public let encoding: String.Encoding
    public let byteOrderMark: [UInt8]

    public init(original: Data, decodedEncoding: String.Encoding) {
        let prefix = [UInt8](original.prefix(3))
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
            byteOrderMark = [0xEF, 0xBB, 0xBF]
        } else if prefix.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            byteOrderMark = [0xFF, 0xFE]
        } else if prefix.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            byteOrderMark = [0xFE, 0xFF]
        } else {
            encoding = decodedEncoding
            byteOrderMark = []
        }
    }

    public func data(for text: String) -> Data {
        if let encoded = text.data(using: encoding, allowLossyConversion: false) {
            return Data(byteOrderMark) + encoded
        }
        return Data(text.utf8)
    }
}

/// The listener's choice of lyric document per song, made on the lyric
/// sources page. Every resolver consults it, so playback, the editor and
/// saves all read the chosen file; a pin whose file is gone is ignored.
///
/// The choice lives on this device. Song ids hash a per-device source id, and
/// another device may not even see the same folder.
public final class LyricsDocumentPinStore: @unchecked Sendable {
    public struct Pin: Codable, Equatable, Sendable {
        public var fileName: String
        public var updatedAt: Date

        public init(fileName: String, updatedAt: Date) {
            self.fileName = fileName
            self.updatedAt = updatedAt
        }
    }

    private struct Payload: Codable {
        var version: Int
        var pins: [String: Pin]
    }

    public static let shared = LyricsDocumentPinStore(fileURL: defaultFileURL())

    private let lock = NSLock()
    private let fileURL: URL?
    private var pins: [String: Pin]

    /// `fileURL` nil keeps the pins in memory only (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.version == 1 {
            pins = payload.pins
        } else {
            pins = [:]
        }
    }

    public func pinnedFileName(forSongID songID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pins[songID]?.fileName
    }

    public func pin(_ fileName: String, forSongID songID: String, now: Date = Date()) {
        mutate { pins in
            guard pins[songID]?.fileName != fileName else { return false }
            pins[songID] = Pin(fileName: fileName, updatedAt: now)
            return true
        }
    }

    public func clearPin(forSongID songID: String) {
        mutate { pins in pins.removeValue(forKey: songID) != nil }
    }

    /// A save landed in another file than the pinned one — a read-only
    /// document is saved as a new `.ttml` beside it — so the song now reads
    /// that file. Songs without a pin keep the default ranking, which
    /// already prefers the file a save writes.
    public func followSave(toFileName fileName: String, forSongID songID: String, now: Date = Date()) {
        mutate { pins in
            guard let current = pins[songID], current.fileName != fileName else { return false }
            pins[songID] = Pin(fileName: fileName, updatedAt: now)
            return true
        }
    }

    /// The pinned file was deleted through Primuse.
    public func forgetFile(named fileName: String, forSongID songID: String) {
        mutate { pins in
            guard let current = pins[songID],
                  current.fileName.caseInsensitiveCompare(fileName) == .orderedSame else { return false }
            pins[songID] = nil
            return true
        }
    }

    private func mutate(_ change: (inout [String: Pin]) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard change(&pins), let fileURL else { return }
        // Pins change on a tap, a few times a session. Writing the whole
        // small file inside the lock keeps two quick changes from landing on
        // disk in the wrong order.
        guard let data = try? JSONEncoder().encode(Payload(version: 1, pins: pins)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        #if os(tvOS)
        // Only Caches is writable in the tvOS group container.
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return base
            .appendingPathComponent("Primuse", isDirectory: true)
            .appendingPathComponent("lyrics_document_pins.json")
    }
}
