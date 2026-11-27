import Foundation

/// Per-song choices that survive cache eviction and rebuilding the library index.
public struct LyricsVersionPreferences: Codable, Equatable, Sendable {
    public struct LocalEdit: Codable, Equatable, Sendable {
        public var text: String
        public var lines: [LyricLine]
        public var displayName: String
        public init(text: String, lines: [LyricLine], displayName: String) {
            self.text = text
            self.lines = lines
            self.displayName = displayName
        }
    }

    public var selectedID: String?
    public var selectedLines: [LyricLine] = []
    public var edits: [String: LocalEdit] = [:]
    public var hiddenIDs: Set<String> = []
    public var removedDocuments: Set<String> = []
    public var cleared = false

    public init() {}

    public static func documentKey(_ lines: [LyricLine]) -> String {
        let source = LyricsDocumentSource.of(lines)
        return [source?.kind.rawValue ?? "", source?.identifier ?? "", LyricsDocumentFingerprint(lines: lines).rawValue]
            .joined(separator: "|")
    }

    public func permits(_ lines: [LyricLine]) -> Bool {
        !cleared && (removedDocuments.isEmpty || !removedDocuments.contains(Self.documentKey(lines)))
    }

    /// Occurrence numbers can move when an earlier byte-identical field is edited or removed.
    public mutating func remapVersions(_ mapping: [String: String]) {
        let changes = mapping.filter { $0.key != $0.value }
        guard !changes.isEmpty else { return }
        let priorEdits = edits
        let priorHidden = hiddenIDs
        for old in changes.keys {
            edits[old] = nil
            hiddenIDs.remove(old)
        }
        for (old, new) in changes {
            if let edit = priorEdits[old] { edits[new] = edit }
            if priorHidden.contains(old) { hiddenIDs.insert(new) }
        }
        if let selectedID, let new = changes[selectedID] { self.selectedID = new }
    }
}

public struct LyricsSourceCollection: Codable, Equatable, Sendable {
    public struct Candidate: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public var lines: [LyricLine]
        public var source: LyricsDocumentSource? { LyricsDocumentSource.of(lines) }
    }

    public private(set) var candidates: [Candidate] = []
    public var selectedID: String?
    /// 「另存为新版本」时留下的旧版本。它们原来所在的文件已经换成新内容了，来源页照样要列出来。
    /// 旧数据没有这一项。
    public private(set) var keptIDs: [String]?
    public var selected: Candidate? { candidates.first { $0.id == selectedID } }

    public init() {}

    public func isKept(_ id: String) -> Bool {
        keptIDs?.contains(id) == true
    }

    public mutating func forget(_ matching: (Candidate) -> Bool) {
        for candidate in candidates.filter(matching) { remove(id: candidate.id) }
    }

    @discardableResult
    public mutating func remember(_ lines: [LyricLine]) -> Candidate? {
        guard !lines.isEmpty, !LossyDecodedLyricsRepair.isDamaged(lines) else { return nil }
        let fingerprint = LyricsDocumentFingerprint(lines: lines)
        if let index = candidates.firstIndex(where: {
            $0.source == LyricsDocumentSource.of(lines)
                && $0.lines.first?.documentIsLocalOverride == lines.first?.documentIsLocalOverride
                && LyricsDocumentFingerprint(lines: $0.lines) == fingerprint
        }) {
            // 又见到一次就挪到最后：满了先淘汰的是最久没见过的。
            var existing = candidates.remove(at: index)
            existing.lines = lines
            candidates.append(existing)
            return existing
        }
        let candidate = Candidate(id: UUID().uuidString, lines: lines)
        candidates.append(candidate)
        // 超过上限时先淘汰最旧的；选定的、「另存为新版本」留下的、刚记下的这一份都不淘汰。
        while candidates.count > 12, let index = candidates.firstIndex(where: {
            $0.id != selectedID && !isKept($0.id) && $0.id != candidate.id
        }) {
            candidates.remove(at: index)
        }
        return candidate
    }

    /// 保存时替换掉的那一份：不管当时记成哪个来源，内容一样的都从候选里去掉。
    /// `normalize` 把两边规整成同一种样子再比（缓存读出来时会规整一遍，候选里存的是规整前的）。
    /// - Returns: 去掉了几份。
    @discardableResult
    public mutating func forget(
        _ lines: [LyricLine],
        normalize: ([LyricLine]) -> [LyricLine] = { $0 }
    ) -> Int {
        guard !lines.isEmpty else { return 0 }
        let fingerprint = LyricsDocumentFingerprint(lines: normalize(lines))
        let removed = candidates.filter {
            LyricsDocumentFingerprint(lines: normalize($0.lines)) == fingerprint
        }
        guard !removed.isEmpty else { return 0 }
        for candidate in removed { remove(id: candidate.id) }
        return removed.count
    }

    /// 来源页「删除此版本」。删的是选定的那份时选定一起清掉。
    @discardableResult
    public mutating func remove(id: String) -> Candidate? {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = candidates.remove(at: index)
        if selectedID == id { selectedID = nil }
        keptIDs?.removeAll { $0 == id }
        if keptIDs?.isEmpty == true { keptIDs = nil }
        return removed
    }

    /// 记成「另存为新版本」留下的旧版本。
    public mutating func keep(id: String) {
        guard candidates.contains(where: { $0.id == id }), !isKept(id) else { return }
        keptIDs = (keptIDs ?? []) + [id]
    }
}

/// The file formats a song's lyric documents come in, as the lyric sources
/// page names them.
public enum LyricsDocumentFormat: String, Sendable, CaseIterable {
    case lrc, ttml, elrc, lys, yrc, qrc, vtt, srt, ass, ssa, lyl

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
        // A Lyricify Lines file is LRC with millisecond line windows.
        case .lrc, .elrc, .lyl: return .lrc
        case .ttml: return .ttml
        case .lys, .yrc, .qrc: return .wordTimed
        case .vtt, .srt, .ass, .ssa: return .subtitle
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

public struct PlayerLyricsDocument: Sendable {
    public let lines: [LyricLine]
    public let summary: LyricsDocumentSummary
    public let isDuet: Bool

    public init(_ lines: [LyricLine]) {
        self.lines = lines
        summary = LyricsDocumentSummary(lines: lines)
        isDuet = KaraokeDuetGatePolicy.hasDuetParts(lines)
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
    /// 按时间轴精度自动挑的文件,只在本次运行里有效、不落盘。键在、值为 nil 表示
    /// 这首已经比过,原来的规则挑的就是最好的。
    private var automaticPicks: [String: String?] = [:]

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

    /// 解析器实际按哪份读:用户选的优先,没选就用按时间轴精度自动挑的。
    public func effectiveFileName(forSongID songID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pins[songID]?.fileName ?? automaticPicks[songID] ?? nil
    }

    /// 这次运行里是否已经为这首比过各份歌词文件的时间轴。
    public func hasEvaluatedAutomaticPick(forSongID songID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return automaticPicks.keys.contains(songID)
    }

    /// 记下比较结果;nil 表示原来的规则挑的就是最好的。
    public func setAutomaticPick(_ fileName: String?, forSongID songID: String) {
        lock.lock()
        defer { lock.unlock() }
        automaticPicks[songID] = .some(fileName)
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
            // 自动挑出来的那份被编辑保存过, 就当成用户选的: 之后重新比时间轴
            // 也不会把刚保存的这份换掉。
            if pins[songID] == nil, (automaticPicks[songID] ?? nil) != nil {
                automaticPicks[songID] = nil
                pins[songID] = Pin(fileName: fileName, updatedAt: now)
                return true
            }
            guard let current = pins[songID], current.fileName != fileName else { return false }
            pins[songID] = Pin(fileName: fileName, updatedAt: now)
            return true
        }
    }

    /// The pinned file was deleted through Primuse.
    public func forgetFile(named fileName: String, forSongID songID: String) {
        mutate { pins in
            if let automatic = automaticPicks[songID] ?? nil,
               automatic.caseInsensitiveCompare(fileName) == .orderedSame {
                automaticPicks[songID] = nil
            }
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
