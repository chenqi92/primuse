import Foundation

/// Reads container metadata by absolute offset so a tag can follow gigabytes of audio.
public enum AudioChunkLyricReader {
    public static func supports(_ format: AudioFormat) -> Bool {
        [.caf, .rf64, .w64, .au].contains(format)
    }

    public static func fields(
        head: Data, fileSize: Int64, fetch: @escaping (Int64, Int64) async throws -> Data
    ) async throws -> [EmbeddedLyricField] {
        guard fileSize >= 8 else { return [] }
        let source = Source(head: head, size: fileSize, fetch: fetch)
        let prefix = try await source.read(0, 8)
        switch fourCC(prefix, at: 0) {
        case "caff" where prefix[4] == 0 && prefix[5] == 1:
            return try await caf(source)
        case "RF64", "BW64":
            return try await rf64(source)
        case "riff":
            return try await wave64(source)
        case ".snd":
            let end = Int64(uint32(prefix, at: 4, little: false))
            guard end > 24, end <= fileSize, end - 24 <= LyricsRawDocumentPolicy.maximumByteCount else { return [] }
            return annotation(try await source.read(24, end - 24))
        default: return []
        }
    }

    private struct Source {
        let head: Data
        let size: Int64
        let fetch: (Int64, Int64) async throws -> Data

        func read(_ offset: Int64, _ count: Int64) async throws -> Data {
            try Task.checkCancellation()
            guard offset >= 0, count >= 0, offset <= size, count <= size - offset else {
                throw ISOBaseMediaRangeReader.ReadError.incompleteRange
            }
            let fromHead = min(count, max(0, Int64(head.count) - offset))
            var bytes = Data()
            if fromHead > 0 {
                let start = head.startIndex + Int(offset)
                bytes.append(contentsOf: head[start..<(start + Int(fromHead))])
            }
            while bytes.count < count {
                try Task.checkCancellation()
                let requested = min(count - Int64(bytes.count), Int64(ISOBaseMediaRangeReader.chunkByteCount))
                let fetched = try await fetch(offset + Int64(bytes.count), requested)
                guard !fetched.isEmpty, fetched.count <= requested else { throw ISOBaseMediaRangeReader.ReadError.incompleteRange }
                bytes.append(fetched)
            }
            return bytes
        }
    }

    private static let maximumChunks = 16_384
    private static let maximumMetadataBytes = Int64(8 * LyricsRawDocumentPolicy.maximumByteCount)
    private static let riffSuffix = Data([0x2e, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0, 0])
    private static let listGUID = Data("list".utf8) + Data([0x2f, 0x91, 0xcf, 0x11, 0xa5, 0xd6, 0x28, 0xdb, 0x04, 0xc1, 0, 0])
    private static let waveSuffix = Data([0xf3, 0xac, 0xd3, 0x11, 0x8c, 0xd1, 0, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a])
    private static let summaryGUID = Data([0xbc, 0x94, 0x5f, 0x92, 0x5a, 0x52, 0xd2, 0x11, 0x86, 0xdc, 0, 0xc0, 0x4f, 0x8e, 0xdb, 0x8a])

    private static func caf(_ source: Source) async throws -> [EmbeddedLyricField] {
        var offset: Int64 = 8
        var result: [EmbeddedLyricField] = []
        for _ in 0..<maximumChunks {
            guard offset <= source.size - 12 else { break }
            let header = try await source.read(offset, 12)
            let start = offset + 12
            // An indefinite-size CAF data chunk extends to EOF.
            guard let count = int64(header, at: 4, little: false), count <= source.size - start else { break }
            if fourCC(header, at: 0) == "info", count >= 4, count <= maximumMetadataBytes {
                let data = try await source.read(start, count)
                var pos = 4
                for _ in 0..<uint32(data, at: 0, little: false) {
                    guard let keyEnd = data[pos...].firstIndex(of: 0),
                          let valueEnd = data[(keyEnd + 1)...].firstIndex(of: 0) else { break }
                    let key = String(data: data[pos..<keyEnd], encoding: .utf8)
                    if valueEnd - keyEnd - 1 <= LyricsRawDocumentPolicy.maximumByteCount, let key,
                       let text = String(data: data[(keyEnd + 1)..<valueEnd], encoding: .utf8) {
                        append(key: key, text: text, to: &result)
                    }
                    pos = valueEnd + 1
                }
            }
            offset = start + count
        }
        return result
    }

    private static func rf64(_ source: Source) async throws -> [EmbeddedLyricField] {
        guard source.size >= 48 else { return [] }
        let start = try await source.read(8, 40)
        guard fourCC(start, at: 0) == "WAVE", fourCC(start, at: 4) == "ds64" else { return [] }
        let dsSize = Int64(uint32(start, at: 8))
        guard dsSize >= 28, dsSize <= source.size - 20, let rootSize = int64(start, at: 12),
              rootSize >= 40, let dataSize = int64(start, at: 20) else { return [] }
        let count = uint32(start, at: 36)
        guard count <= maximumChunks, Int64(count) * 12 <= dsSize - 28 else { return [] }
        let tableBytes = try await source.read(48, Int64(count) * 12)
        // A FourCC may occur more than once in ds64. Pop sizes in file order.
        var table: [String: [Int64]] = [:]
        for index in (0..<Int(count)).reversed() {
            let p = index * 12
            guard let key = fourCC(tableBytes, at: p), let size = int64(tableBytes, at: p + 4) else { return [] }
            table[key, default: []].append(size)
        }
        var firstData = true
        let limit = min(source.size - 8, rootSize) + 8
        guard let first = alignedEnd(20 + dsSize, alignment: 2, limit: limit) else { return [] }
        var offset = first
        var result: [EmbeddedLyricField] = []
        for _ in 0..<maximumChunks {
            guard offset <= limit - 8 else { break }
            let header = try await source.read(offset, 8)
            guard let key = fourCC(header, at: 0) else { break }
            let declared = uint32(header, at: 4)
            let length: Int64?
            if declared == .max {
                length = key == "data" && firstData ? dataSize : table[key]?.popLast()
            } else {
                length = Int64(declared)
            }
            if key == "data" { firstData = false }
            let body = offset + 8
            guard let length, length <= limit - body else { break }
            if let kind = chunkKind(key) {
                result += try await waveFields(kind, source: source, offset: body, count: length)
            }
            guard let next = alignedEnd(body + length, alignment: 2, limit: limit) else { break }
            offset = next
        }
        return result
    }

    private static func wave64(_ source: Source) async throws -> [EmbeddedLyricField] {
        guard source.size >= 40 else { return [] }
        let header = try await source.read(0, 40)
        guard header[4..<16].elementsEqual(riffSuffix), fourCC(header, at: 24) == "wave",
              header[28..<40].elementsEqual(waveSuffix),
              let declared = int64(header, at: 16), declared >= 40 else { return [] }
        let limit = min(source.size, declared)
        var offset: Int64 = 40
        var result: [EmbeddedLyricField] = []
        for _ in 0..<maximumChunks {
            guard offset <= limit - 24 else { break }
            let chunk = try await source.read(offset, 24)
            guard let size = int64(chunk, at: 16), size >= 24, size <= limit - offset else { break }
            let guid = chunk.prefix(16)
            let key = fourCC(chunk, at: 0) ?? ""
            let kind: ChunkKind?
            if guid.elementsEqual(summaryGUID) {
                kind = .summaryList
            } else if guid.elementsEqual(listGUID) {
                kind = .info
            } else if guid.suffix(12).elementsEqual(waveSuffix) {
                kind = chunkKind(key)
            } else {
                // Vendor GUIDs have no common ID3 identifier. Only accept a complete
                // ID3 tag beginning at the declared start of the vendor object.
                kind = .id3
            }
            if let kind {
                result += try await waveFields(kind, source: source, offset: offset + 24, count: size - 24)
            }
            guard let next = alignedEnd(offset + size, alignment: 8, limit: limit) else { break }
            offset = next
        }
        return result
    }

    private enum ChunkKind { case info, summaryList, id3, xmp, xml }

    private static func chunkKind(_ key: String) -> ChunkKind? {
        switch key.uppercased() {
        case "LIST": return .info
        case "ID3 ": return .id3
        case "_PMX": return .xmp
        case "AXML": return .xml
        default: return nil
        }
    }

    private static func waveFields(
        _ kind: ChunkKind, source: Source, offset: Int64, count: Int64
    ) async throws -> [EmbeddedLyricField] {
        if case .id3 = kind {
            guard count >= 10 else { return [] }
            let header = try await source.read(offset, 10)
            guard let size = EmbeddedTagMetadataParser.id3TagByteCount(in: header), size <= count else { return [] }
            if size > RemoteMetadataReadPolicy.maximumHeadByteCount,
               (header[3] == 4 || header[5] & 0x80 == 0), (header[3] != 2 || header[5] & 0x40 == 0) {
                return try await largeID3(header, source: source, offset: offset, size: size)
            }
            guard size <= maximumMetadataBytes else { return [] }
            var tag = header
            tag.append(try await source.read(offset + 10, Int64(size) - 10))
            return ID3EmbeddedLyrics.fields(in: tag)
        }
        guard count >= 4, count <= maximumMetadataBytes else { return [] }
        if case .info = kind {
            guard try await source.read(offset, 4).elementsEqual("INFO".utf8) else { return [] }
            return info(try await source.read(offset + 4, count - 4), summary: false)
        }
        let data = try await source.read(offset, count)
        switch kind {
        case .summaryList: return info(data, summary: true)
        case .xmp: return EmbeddedTagMetadataParser.xmpLyricFields(in: data)
        case .xml:
            let xmp = EmbeddedTagMetadataParser.xmpLyricFields(in: data)
            if !xmp.isEmpty { return xmp }
            guard data.count <= LyricsRawDocumentPolicy.maximumByteCount,
                  let text = TextEncodingRepair.decodeTextFile(data)?.text, LyricsContentParser.isTTML(text),
                  let role = ISOBaseMediaLyricsParser.lyricFieldRole("axml", text: text) else { return [] }
            return [role.field(name: "axml", text: text)]
        case .id3, .info: return []
        }
    }

    /// Size-addressable ID3 frames let a small lyric follow a large embedded cover.
    /// Pre-v2.4 tag-wide unsynchronisation instead needs the decoded byte stream.
    private static func largeID3(_ header: Data, source: Source, offset: Int64, size: Int) async throws -> [EmbeddedLyricField] {
        let version = Int(header[3])
        let tagFlags = header[5]
        let footer = version == 4 && tagFlags & 0x10 != 0 ? 10 : 0
        let end = offset + Int64(size - footer)
        var pos = offset + 10
        if version >= 3, tagFlags & 0x40 != 0 {
            guard end - pos >= 4 else { return [] }
            let bytes = try await source.read(pos, 4)
            let length: Int64
            if version == 4 {
                guard bytes.allSatisfy({ $0 < 128 }) else { return [] }
                length = Int64(ID3TextMetadataParser.syncSafeInt(bytes, at: 0))
            } else {
                length = 4 + Int64(uint32(bytes, at: 0, little: false))
            }
            guard length >= 6, length <= end - pos else { return [] }
            pos += length
        }
        let nameSize = version == 2 ? 3 : 4
        let headerSize: Int64 = version == 2 ? 6 : 10
        var result: [EmbeddedLyricField] = []
        for _ in 0..<maximumChunks {
            guard pos <= end - headerSize else { break }
            let frame = try await source.read(pos, headerSize)
            let id = frame.prefix(nameSize)
            guard id.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { break }
            let sizeBytes = frame[nameSize..<(nameSize * 2)]
            let length: Int64
            if version == 4 {
                guard sizeBytes.allSatisfy({ $0 < 128 }) else { break }
                length = Int64(ID3TextMetadataParser.syncSafeInt(frame, at: 4))
            } else {
                length = sizeBytes.reduce(0) { ($0 << 8) | Int64($1) }
            }
            pos += headerSize
            guard length <= end - pos else { break }
            let name = String(decoding: id, as: UTF8.self)
            if ID3EmbeddedLyrics.frameNames.contains(name), length > 0, length <= maximumMetadataBytes {
                var flags = version == 2 ? UInt16(0) : UInt16(frame[8]) << 8 | UInt16(frame[9])
                if version == 4, tagFlags & 0x80 != 0 { flags |= 2 }
                let raw = try await source.read(pos, length)
                if let body = ID3EmbeddedLyrics.decodedBody(raw, version: version, flags: flags) {
                    result.append(contentsOf: ID3EmbeddedLyrics.fields(frame: name, body: body))
                }
            }
            pos += length
        }
        return result
    }

    private static func info(_ data: Data, summary: Bool) -> [EmbeddedLyricField] {
        // Sony Summary List stores a count and unpadded UTF-16LE strings. RIFF INFO
        // stores an even-padded sequence of ANSI four-character properties.
        var pos = summary ? 4 : 0
        var remaining = summary ? Int(uint32(data, at: 0)) : Int.max
        var result: [EmbeddedLyricField] = []
        while pos <= data.count - 8 && remaining > 0 {
            guard let key = fourCC(data, at: pos) else { break }
            let count = Int(uint32(data, at: pos + 4))
            pos += 8
            guard count <= data.count - pos else { break }
            if count <= LyricsRawDocumentPolicy.maximumByteCount {
                let bytes = data[pos..<(pos + count)]
                let text: String?
                if summary {
                    text = count.isMultiple(of: 2) ? String(data: bytes, encoding: .utf16LittleEndian) : nil
                } else {
                    text = nullTerminatedText(Data(bytes))
                }
                if let text {
                    let property: String = switch key.uppercased() {
                    case "INAM": "title"
                    case "IART": "artist"
                    case "IPRD": "album"
                    case "ICOP": "copyright"
                    case "IGNR": "genre"
                    case "ICRD": "date"
                    case "ISFT": "encoder"
                    default: key
                    }
                    if let field = lyricField(property, name: key, text: text) { result.append(field) }
                }
            }
            pos += count
            if !summary { pos += count % 2 }
            remaining -= 1
        }
        return result
    }

    private static func annotation(_ data: Data) -> [EmbeddedLyricField] {
        // AU defines a single NUL-terminated annotation; some writers store
        // newline-delimited name=value entries, others put a document in it.
        guard let raw = nullTerminatedText(data) else { return [] }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let role = ISOBaseMediaLyricsParser.lyricFieldRole("annotation", text: text) {
            return [role.field(name: "annotation", text: text)]
        }
        var values: [EmbeddedLyricField] = []
        var key: String?
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let equal = line.firstIndex(of: "="), equal != line.startIndex,
               line[..<equal].allSatisfy({ $0.isLetter || $0.isNumber || " _-./".contains($0) }) {
                if let key { append(key: key, text: lines.joined(separator: "\n"), to: &values) }
                key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
                lines = [String(line[line.index(after: equal)...])]
            } else if key != nil {
                lines.append(line)
            }
        }
        if let key { append(key: key, text: lines.joined(separator: "\n"), to: &values) }
        return values
    }

    private static func append(key: String, text raw: String, to result: inout [EmbeddedLyricField]) {
        if let field = lyricField(key, name: key, text: raw) { result.append(field) }
    }

    private static func lyricField(_ key: String, name: String, text raw: String) -> EmbeddedLyricField? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !text.isEmpty, let role = ISOBaseMediaLyricsParser.lyricFieldRole(key, text: text) else { return nil }
        return role.field(name: name, text: text)
    }

    private static func nullTerminatedText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let encoding: String.Encoding?
        if data.starts(with: [0xff, 0xfe]) || (data.count >= 4 && data[0] != 0 && data[1] == 0 && data[2] != 0 && data[3] == 0) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xfe, 0xff]) || (data.count >= 4 && data[0] == 0 && data[1] != 0 && data[2] == 0 && data[3] != 0) {
            encoding = .utf16BigEndian
        } else { encoding = nil }
        if let encoding {
            var end = 0
            while end + 1 < data.count && (data[end] != 0 || data[end + 1] != 0) { end += 2 }
            let start = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) ? 2 : 0
            guard end > start else { return nil }
            return String(data: data[start..<end], encoding: encoding)
        }
        return TextEncodingRepair.decodeTextFile(Data(data.prefix(while: { $0 != 0 })))?.text
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String? {
        String(data: data[offset..<(offset + 4)], encoding: .ascii)
    }

    private static func uint32(_ data: Data, at offset: Int, little: Bool = true) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        return little ? bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
            : bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func int64(_ data: Data, at offset: Int, little: Bool = true) -> Int64? {
        let bytes = data[offset..<(offset + 8)]
        let value = little ? bytes.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            : bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int64(exactly: value)
    }

    private static func alignedEnd(_ end: Int64, alignment: Int64, limit: Int64) -> Int64? {
        let padding = (alignment - end % alignment) % alignment
        return end <= limit && padding <= limit - end ? end + padding : nil
    }
}
