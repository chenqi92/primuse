import Foundation

/// Reads chapter marks out of an ID3v2 tag: the `CHAP` frames of the ID3v2
/// Chapter Frame Addendum that podcast tools write into MP3 episodes. This is
/// where Apple Podcasts finds the chapters of most MP3 shows, so a feed that
/// declares no chapters of its own often still has them here.
///
/// Each `CHAP` carries its start time and its own sub-frames, of which `TIT2`
/// is the chapter title. A top-level `CTOC` lists the chapters that make up
/// the table of contents (directly or through nested `CTOC`s); when there is
/// one, chapters it leaves out are hidden and are dropped. ID3v2.2 predates
/// the addendum, so only 2.3 and 2.4 are read.
///
/// Every length is bounds-checked against untrusted bytes: a truncated or
/// malformed tag yields the chapters whose frames are complete, or none,
/// rather than a crash.
public enum ID3ChapterParser {
    /// Bytes of the tag header, which is all it takes to learn how long the
    /// whole tag is.
    public static let headerLength = 10

    /// Tags longer than this are not read for chapters. Chapter images make a
    /// tag a few megabytes; anything far larger is mostly artwork.
    public static let maximumTagLength = 16 * 1024 * 1024

    /// Length of the ID3v2.3/2.4 tag that `header` starts, header and footer
    /// included; nil when `header` does not start one.
    public static func tagLength(header: Data) -> Int? {
        let header = zeroBased(header)
        guard header.count >= headerLength,
              header[0] == 0x49, header[1] == 0x44, header[2] == 0x33,
              (3...4).contains(header[3]) else { return nil }
        let size = ID3TextMetadataParser.syncSafeInt(header, at: 6)
        guard size > 0 else { return nil }
        return headerLength + size + ((header[5] & 0x10) != 0 ? 10 : 0)
    }

    /// Reads the tag at the head of a local file; the audio is never touched.
    public static func chapters(fileURL: URL) -> [MediaChapter] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: headerLength),
              let length = tagLength(header: header),
              length <= maximumTagLength,
              (try? handle.seek(toOffset: 0)) != nil,
              let tag = try? handle.read(upToCount: length) else { return [] }
        return chapters(in: tag)
    }

    /// Parses `data`, which must start with the tag.
    public static func chapters(in data: Data) -> [MediaChapter] {
        let data = zeroBased(data)
        guard data.count > headerLength,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return [] }
        let version = Int(data[3])
        guard version == 3 || version == 4 else { return [] }
        let flags = data[5]
        let tagEnd = min(data.count, headerLength + ID3TextMetadataParser.syncSafeInt(data, at: 6))
        guard tagEnd > headerLength else { return [] }

        var tag = data.subdata(in: headerLength..<tagEnd)
        // 2.3 unsynchronises the tag as a whole; 2.4 does it frame by frame,
        // with the tag flag only announcing that every frame is.
        let framesAreUnsynchronised = version == 4 && (flags & 0x80) != 0
        if version == 3, (flags & 0x80) != 0 {
            tag = ID3TextMetadataParser.removingUnsynchronization(from: tag)
        }

        var marks: [String: MediaChapter] = [:]
        var markOrder: [String] = []
        var tables: [String: TableOfContents] = [:]
        let start = ID3TextMetadataParser.extendedHeaderLength(in: tag, version: version, flags: flags)
        for frame in frames(
            in: tag,
            from: start,
            version: version,
            unsynchronised: framesAreUnsynchronised,
            keeping: ["CHAP", "CTOC"]
        ) {
            if frame.id == "CHAP" {
                guard let mark = chapter(in: frame.payload, version: version),
                      marks[mark.elementID] == nil else { continue }
                marks[mark.elementID] = mark.chapter
                markOrder.append(mark.elementID)
            } else if let table = tableOfContents(in: frame.payload) {
                tables[table.elementID] = tables[table.elementID] ?? table
            }
        }

        var listed = markOrder
        if let root = tables.values.first(where: \.isTopLevel) {
            var visited: Set<String> = []
            var contents: [String] = []
            collect(root, tables: tables, marks: marks, visited: &visited, into: &contents)
            if !contents.isEmpty { listed = contents }
        }
        return ISOBaseMediaChapterParser.sanitized(listed.compactMap { marks[$0] })
    }

    // MARK: - Frames

    private struct Frame {
        let id: String
        let payload: Data
    }

    /// Frames of `block` (a tag, or the sub-frame area of a `CHAP`/`CTOC`)
    /// from `offset` on. Only the payloads of `keeping` are copied out:
    /// a tag's artwork can be megabytes that chapters never look at.
    private static func frames(
        in block: Data,
        from offset: Int,
        version: Int,
        unsynchronised: Bool,
        keeping: Set<String>
    ) -> [Frame] {
        var result: [Frame] = []
        var cursor = offset
        while cursor >= 0, cursor + 10 <= block.count {
            // Padding, or bytes that are no frame header, end the frames.
            guard block[cursor..<(cursor + 4)].allSatisfy({
                (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
            }), let id = ID3TextMetadataParser.ascii(block, at: cursor, count: 4) else { break }
            let size = version == 4
                ? ID3TextMetadataParser.syncSafeInt(block, at: cursor + 4)
                : ID3TextMetadataParser.uint32BE(block, at: cursor + 4)
            let formatFlags = block[cursor + 9]
            let payloadStart = cursor + 10
            guard size > 0, size <= block.count - payloadStart else { break }
            cursor = payloadStart + size
            guard keeping.contains(id),
                  ID3TextMetadataParser.supportsPlainTextFrame(version: version, formatFlags: formatFlags)
            else { continue }
            var payload = block.subdata(in: payloadStart..<cursor)
            if version == 4, unsynchronised || (formatFlags & 0x02) != 0 {
                payload = ID3TextMetadataParser.removingUnsynchronization(from: payload)
            }
            result.append(Frame(id: id, payload: payload))
        }
        return result
    }

    /// `CHAP`: element ID, start and end time in milliseconds, start and end
    /// byte offsets, then sub-frames.
    private static func chapter(in payload: Data, version: Int) -> (elementID: String, chapter: MediaChapter)? {
        guard let terminator = payload.firstIndex(of: 0) else { return nil }
        let timesStart = terminator + 1
        guard timesStart + 16 <= payload.count else { return nil }
        let elementID = latin1(payload.subdata(in: 0..<terminator))
        let startMilliseconds = ID3TextMetadataParser.uint32BE(payload, at: timesStart)
        let subframes = frames(
            in: payload,
            from: timesStart + 16,
            version: version,
            unsynchronised: false,
            keeping: ["TIT2", "TIT3"]
        )
        let title = ["TIT2", "TIT3"].lazy.compactMap { id in
            subframes.first { $0.id == id }
                .flatMap { ID3TextMetadataParser.decodedText($0.payload) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
        return (elementID, MediaChapter(startTime: TimeInterval(startMilliseconds) / 1000, title: title ?? ""))
    }

    private struct TableOfContents {
        let elementID: String
        let isTopLevel: Bool
        let entries: [String]
    }

    /// `CTOC`: element ID, flags (0x02 marks the top level), entry count, the
    /// child element IDs, then sub-frames.
    private static func tableOfContents(in payload: Data) -> TableOfContents? {
        guard let terminator = payload.firstIndex(of: 0), terminator + 2 < payload.count else { return nil }
        let isTopLevel = (payload[terminator + 1] & 0x02) != 0
        let entryCount = Int(payload[terminator + 2])
        var entries: [String] = []
        var cursor = terminator + 3
        while entries.count < entryCount, cursor < payload.count,
              let end = payload[cursor...].firstIndex(of: 0) {
            entries.append(latin1(payload.subdata(in: cursor..<end)))
            cursor = end + 1
        }
        return TableOfContents(
            elementID: latin1(payload.subdata(in: 0..<terminator)),
            isTopLevel: isTopLevel,
            entries: entries
        )
    }

    private static func collect(
        _ table: TableOfContents,
        tables: [String: TableOfContents],
        marks: [String: MediaChapter],
        visited: inout Set<String>,
        into contents: inout [String]
    ) {
        guard visited.insert(table.elementID).inserted else { return }
        for entry in table.entries {
            if marks[entry] != nil {
                if !contents.contains(entry) { contents.append(entry) }
            } else if let nested = tables[entry] {
                collect(nested, tables: tables, marks: marks, visited: &visited, into: &contents)
            }
        }
    }

    private static func latin1(_ bytes: Data) -> String {
        String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func zeroBased(_ data: Data) -> Data {
        data.startIndex == 0 ? data : Data(data)
    }
}
