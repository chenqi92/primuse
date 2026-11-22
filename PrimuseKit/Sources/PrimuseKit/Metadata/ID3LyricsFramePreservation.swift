import Foundation
import zlib

/// Keeps a file's ID3 unsynchronised-lyrics frames intact across a tag edit.
///
/// The tagging library rewrites lyrics on every save: it drops all `USLT`
/// frames and recreates a single one from the first frame's text, without a
/// language or a descriptor. A file that carries the original and a
/// translation as two frames therefore loses one of them whenever any other
/// field is edited. The frame bodies read here are put back after the save.
///
/// Both directions are deliberately strict. Anything unusual — compression,
/// encryption, a frame that cannot be walked — yields `nil`, and the caller
/// leaves the saved file as the library wrote it.
public enum ID3LyricsFramePreservation {
    /// Bodies of every `USLT` (`ULT` in ID3v2.2) frame, in file order, with
    /// unsynchronisation reversed: encoding byte, language, descriptor, text.
    /// The layout is identical across ID3v2.2–2.4, so a body can be re-framed
    /// without being decoded. An empty array means the tag has no such frame.
    public static func lyricsFrameBodies(in data: Data) -> [Data]? {
        guard let tag = Tag(data) else { return nil }
        var bodies: [Data] = []
        for frame in tag.frames where frame.isLyrics {
            guard let body = frame.body else { return nil }
            bodies.append(body)
        }
        return bodies
    }

    /// Replaces the lyrics frames of a freshly saved tag with `bodies`.
    ///
    /// Only the shape the tagging library writes is accepted: ID3v2.3/2.4
    /// without tag-level unsynchronisation, extended header or footer. Every
    /// other frame is kept byte for byte and in order. The tag keeps its size
    /// when the padding can absorb the difference and grows otherwise.
    public static func replacingLyricsFrames(in data: Data, with bodies: [Data]) -> Data? {
        guard let tag = Tag(data),
              tag.version == 3 || tag.version == 4,
              tag.headerFlags & 0xD0 == 0,
              tag.frames.allSatisfy({ !$0.isLyrics || $0.body != nil }) else {
            return nil
        }
        for body in bodies {
            guard body.count >= 5,
                  tag.version == 4 || body[body.startIndex] <= 1,
                  body.count <= Tag.maximumFrameSize(version: tag.version) else {
                return nil
            }
        }

        var frames = Data()
        var insertedLyrics = false
        func appendLyrics() {
            guard !insertedLyrics else { return }
            insertedLyrics = true
            for body in bodies {
                frames.append(contentsOf: [0x55, 0x53, 0x4C, 0x54]) // "USLT"
                frames.append(Tag.encodedFrameSize(body.count, version: tag.version))
                frames.append(contentsOf: [0x00, 0x00])
                frames.append(body)
            }
        }
        for frame in tag.frames {
            if frame.isLyrics {
                appendLyrics()
            } else {
                frames.append(tag.body[frame.range])
            }
        }
        appendLyrics()

        let tagSize = frames.count <= tag.body.count
            ? tag.body.count
            : frames.count + 1024
        guard tagSize <= 0x0FFF_FFFF else { return nil }

        var result = Data(capacity: 10 + tagSize + (data.count - tag.end))
        result.append(data[data.startIndex..<(data.startIndex + 6)])
        result.append(Tag.synchsafe(tagSize))
        result.append(frames)
        result.append(Data(count: tagSize - frames.count))
        result.append(data[(data.startIndex + tag.end)...])
        return result
    }

    // MARK: - Tag walking

    private struct Frame {
        /// Header plus payload, relative to the tag body.
        let range: Range<Int>
        let isLyrics: Bool
        /// Lyrics frames only: the decoded body, or nil when it cannot be
        /// carried over (compressed, encrypted, grouped or malformed).
        let body: Data?
    }

    private struct Tag {
        let version: UInt8
        let headerFlags: UInt8
        /// Everything between the ten-byte header and the end of the tag,
        /// after tag-level unsynchronisation (ID3v2.2/2.3) has been reversed.
        let body: Data
        /// Offset of the first byte after the tag, relative to the file start.
        let end: Int
        let frames: [Frame]

        init?(_ data: Data) {
            let base = data.startIndex
            guard data.count >= 10,
                  data[base] == 0x49, data[base + 1] == 0x44, data[base + 2] == 0x33,
                  (2...4).contains(data[base + 3]),
                  data[base + 4] != 0xFF,
                  (6..<10).allSatisfy({ data[base + $0] < 0x80 }) else {
                return nil
            }
            version = data[base + 3]
            headerFlags = data[base + 5]
            let size = (Int(data[base + 6]) << 21) | (Int(data[base + 7]) << 14)
                | (Int(data[base + 8]) << 7) | Int(data[base + 9])
            guard size > 0, 10 + size <= data.count else { return nil }
            end = 10 + size

            // ID3v2.2 defines bit 6 as a compression scheme nobody implemented.
            if version == 2, headerFlags & 0x40 != 0 { return nil }
            var body = Data(data[(base + 10)..<(base + end)])
            if version < 4, headerFlags & 0x80 != 0 {
                body = Tag.removingUnsynchronisation(body)
            }
            self.body = body

            var cursor = 0
            if version >= 3, headerFlags & 0x40 != 0 {
                guard body.count >= 4 else { return nil }
                let declared = version == 4
                    ? Tag.synchsafeValue(body, at: 0)
                    : Tag.bigEndianValue(body, at: 0, length: 4).map { $0 + 4 }
                guard let declared, declared >= 6, declared <= body.count else { return nil }
                cursor = declared
            }

            guard let frames = Tag.walk(body, from: cursor, version: version, tagUnsync: headerFlags & 0x80 != 0) else { return nil }
            self.frames = frames
        }

        private static func walk(_ body: Data, from start: Int, version: UInt8, tagUnsync: Bool) -> [Frame]? {
            let idLength = version == 2 ? 3 : 4
            let headerLength = version == 2 ? 6 : 10
            var frames: [Frame] = []
            var cursor = start
            while cursor < body.count {
                if body[cursor] == 0x00 { break } // padding
                guard cursor + headerLength <= body.count,
                      isFrameIdentifier(body, at: cursor, length: idLength) else {
                    return nil
                }
                guard let size = frameSize(
                    body, at: cursor, idLength: idLength,
                    headerLength: headerLength, version: version
                ) else { return nil }
                let payloadStart = cursor + headerLength
                let payloadEnd = payloadStart + size
                let identifier = body[cursor..<(cursor + idLength)]
                let isLyrics = identifier.elementsEqual(version == 2 ? [0x55, 0x4C, 0x54] : [0x55, 0x53, 0x4C, 0x54])
                var decoded: Data?
                if isLyrics {
                    var formatFlags: UInt8 = version == 2 ? 0 : body[cursor + 9]
                    if version == 4, tagUnsync { formatFlags |= 0x02 }
                    decoded = lyricsBody(
                        Data(body[payloadStart..<payloadEnd]),
                        formatFlags: formatFlags,
                        version: version
                    )
                }
                frames.append(Frame(range: cursor..<payloadEnd, isLyrics: isLyrics, body: decoded))
                cursor = payloadEnd
            }
            // Whatever follows the last frame has to be padding, otherwise the
            // walk went wrong somewhere and nothing it found can be trusted.
            guard body[cursor...].allSatisfy({ $0 == 0x00 }) else { return nil }
            return frames
        }

        /// Resolves the frame size. Some writers store plain big-endian sizes in
        /// ID3v2.4 tags, so an ambiguous value is accepted only in the reading
        /// that lands on another frame, on padding, or on the end of the tag.
        static func frameSize(
            _ body: Data,
            at cursor: Int,
            idLength: Int,
            headerLength: Int,
            version: UInt8
        ) -> Int? {
            let sizeOffset = cursor + idLength
            func lands(_ size: Int) -> Bool {
                guard size > 0 else { return false }
                let next = cursor + headerLength + size
                if next == body.count { return true }
                guard next < body.count else { return false }
                if body[next] == 0x00 {
                    // Padding runs to the end of the tag. A zero byte in the
                    // middle of a payload is just a misread size.
                    return body[next...].allSatisfy { $0 == 0x00 }
                }
                return next + headerLength <= body.count
                    && isFrameIdentifier(body, at: next, length: idLength)
            }
            if version == 2 {
                guard let size = bigEndianValue(body, at: sizeOffset, length: 3), lands(size) else {
                    return nil
                }
                return size
            }
            guard let plain = bigEndianValue(body, at: sizeOffset, length: 4) else { return nil }
            if version == 3 { return lands(plain) ? plain : nil }
            if let synchsafe = synchsafeValue(body, at: sizeOffset), lands(synchsafe) {
                return synchsafe
            }
            return lands(plain) ? plain : nil
        }

        private static func lyricsBody(_ payload: Data, formatFlags: UInt8, version: UInt8) -> Data? {
            var payload = payload
            if version == 4 {
                // Grouping, compression and encryption change what the payload
                // means; unsynchronisation and the length indicator do not.
                guard formatFlags & 0x4C == 0 else { return nil }
                if formatFlags & 0x01 != 0 {
                    guard payload.count >= 4 else { return nil }
                    payload = Data(payload.dropFirst(4))
                }
                if formatFlags & 0x02 != 0 {
                    payload = removingUnsynchronisation(payload)
                }
            } else if version == 3 {
                guard formatFlags & 0xE0 == 0 else { return nil }
            }
            // Encoding, three language bytes and at least a descriptor terminator.
            guard payload.count >= 5, payload[payload.startIndex] <= 3 else { return nil }
            return payload
        }

        private static func isFrameIdentifier(_ body: Data, at offset: Int, length: Int) -> Bool {
            guard offset + length <= body.count else { return false }
            return body[offset..<(offset + length)].allSatisfy {
                (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
            }
        }

        static func removingUnsynchronisation(_ data: Data) -> Data {
            var result = Data(capacity: data.count)
            var previousWasFF = false
            for byte in data {
                if previousWasFF, byte == 0x00 {
                    previousWasFF = false
                    continue
                }
                result.append(byte)
                previousWasFF = byte == 0xFF
            }
            return result
        }

        static func bigEndianValue(_ data: Data, at offset: Int, length: Int) -> Int? {
            guard offset >= 0, offset + length <= data.count else { return nil }
            var value = 0
            for index in 0..<length {
                value = (value << 8) | Int(data[data.startIndex + offset + index])
            }
            return value
        }

        static func synchsafeValue(_ data: Data, at offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            var value = 0
            for index in 0..<4 {
                let byte = data[data.startIndex + offset + index]
                guard byte < 0x80 else { return nil }
                value = (value << 7) | Int(byte)
            }
            return value
        }

        static func synchsafe(_ value: Int) -> Data {
            Data([
                UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
                UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F),
            ])
        }

        static func encodedFrameSize(_ value: Int, version: UInt8) -> Data {
            if version == 4 { return synchsafe(value) }
            return Data([
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ])
        }

        static func maximumFrameSize(version: UInt8) -> Int {
            version == 4 ? 0x0FFF_FFFF : Int(Int32.max)
        }
    }

    static func v24FrameSize(in tag: Data, at offset: Int) -> Int? {
        Tag.frameSize(tag, at: offset, idLength: 4, headerLength: 10, version: 4)
    }
}

/// Reads metadata frames without requiring a layout that can be safely rewritten.
public enum ID3EmbeddedLyrics {
    static let frameNames: Set<String> = ["USLT", "ULT", "SYLT", "SLT", "TXXX", "TXX",
                                          "COMM", "COM", "GEOB", "GEO", "PRIV"]

    public static func visitFrames(in data: Data, _ visit: (String, Data, UInt16, Int) -> Void) {
        guard let byteCount = EmbeddedTagMetadataParser.id3TagByteCount(in: data) else { return }
        let version = Int(data[3]), tagFlags = data[5]
        guard version != 2 || tagFlags & 0x40 == 0 else { return }
        let footer = version == 4 && tagFlags & 0x10 != 0 ? 10 : 0
        var tag = data.subdata(in: 10..<min(data.count, byteCount - footer))
        if version < 4, tagFlags & 0x80 != 0 { tag = ID3TextMetadataParser.removingUnsynchronization(from: tag) }
        let idSize = version == 2 ? 3 : 4
        let headerSize = version == 2 ? 6 : 10
        var offset = ID3TextMetadataParser.extendedHeaderLength(in: tag, version: version, flags: tagFlags)
        while offset <= tag.count - headerSize, tag[offset] != 0 {
            let identifier = tag[offset..<(offset + idSize)]
            guard identifier.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { break }
            let length: Int
            if version == 4 {
                length = ID3LyricsFramePreservation.v24FrameSize(in: tag, at: offset)
                    ?? ID3TextMetadataParser.syncSafeInt(tag, at: offset + 4)
            } else { length = OrderedTagContainer.value(tag, offset + idSize, idSize) }
            var flags = version == 2 ? 0 : UInt16(OrderedTagContainer.value(tag, offset + 8, 2))
            if version == 4, tagFlags & 0x80 != 0 { flags |= 0x02 }
            offset += headerSize
            guard length <= tag.count - offset else { break }
            let name = String(decoding: identifier, as: UTF8.self)
            if frameNames.contains(name) || name == "APIC" || name == "PIC" {
                visit(name, tag.subdata(in: offset..<(offset + length)), flags, version)
            }
            offset += length
        }
    }

    /// Frame format flags prefix extra data in different orders in v2.3 and v2.4.
    public static func decodedBody(_ raw: Data, version: Int, flags: UInt16) -> Data? {
        let format = UInt8(truncatingIfNeeded: flags)
        guard format != 0 else { return raw }
        var data = raw
        var expectedLength: Int?
        var offset = 0
        let compressed: Bool
        switch version {
        case 3:
            guard format & 0x5f == 0 else { return nil } // encrypted or reserved
            compressed = format & 0x80 != 0
            if compressed {
                guard data.count >= 4 else { return nil }
                expectedLength = OrderedTagContainer.value(data, 0, 4)
                offset = 4
            }
            if format & 0x20 != 0 { offset += 1 }
        case 4:
            guard format & 0xb4 == 0 else { return nil } // encrypted or reserved
            if format & 0x02 != 0 { data = ID3TextMetadataParser.removingUnsynchronization(from: data) }
            if format & 0x40 != 0 { offset = 1 }
            compressed = format & 0x08 != 0
            if format & 0x01 != 0 {
                guard offset <= data.count - 4, data[offset..<(offset + 4)].allSatisfy({ $0 < 128 }) else { return nil }
                expectedLength = ID3TextMetadataParser.syncSafeInt(data, at: offset)
                offset += 4
            }
        default: return nil
        }
        guard offset <= data.count else { return nil }
        let body = Data(data.dropFirst(offset))
        if !compressed { return expectedLength == nil || expectedLength == body.count ? body : nil }
        guard let expectedLength, (1...LyricsRawDocumentPolicy.maximumByteCount).contains(expectedLength), !body.isEmpty else { return nil }
        var length = UInt(expectedLength)
        var inflated = Data(count: expectedLength)
        let status = inflated.withUnsafeMutableBytes { result in
            body.withUnsafeBytes { source in
                uncompress(result.bindMemory(to: UInt8.self).baseAddress, &length,
                           source.bindMemory(to: UInt8.self).baseAddress, UInt(source.count))
            }
        }
        return status == Z_OK && length == expectedLength ? inflated : nil
    }

    public static func mpegFrameDuration(in data: Data) -> TimeInterval? {
        guard let start = EmbeddedTagMetadataParser.id3TagByteCount(in: data) else { return nil }
        return AudioFileSignaturePolicy.verifiedMPEGFrameDuration(in: data, from: start)
    }

    enum Storage {
        case text
        case synchronized
        case attachment(LyricsRawDocumentEncoding)
        case xmp
    }

    struct Value {
        let field: EmbeddedLyricField
        let descriptor: String
        let range: Range<Int>
        let storage: Storage
        var textStart: Int?
    }

    public static func fields(frame: String, body: Data, mpegFrameDuration: TimeInterval? = nil) -> [EmbeddedLyricField] {
        values(frame: frame, data: body, mpegFrameDuration: mpegFrameDuration).map(\.field)
    }

    public static func fields(in data: Data, mpegFrameDuration: TimeInterval? = nil) -> [EmbeddedLyricField] {
        var result: [EmbeddedLyricField] = []
        lazy var duration = mpegFrameDuration ?? Self.mpegFrameDuration(in: data)
        visitFrames(in: data) { name, raw, flags, version in
            guard frameNames.contains(name), let body = decodedBody(raw, version: version, flags: flags) else { return }
            let usesFrames = (name == "SLT" || name == "SYLT") && body.count > 4 && body[4] == 1
            result += fields(frame: name, body: body, mpegFrameDuration: usesFrames ? duration : nil)
        }
        return result
    }

    public static func declaredField(name: String, descriptor: String, text: String, languageCode: String?) -> EmbeddedLyricField {
        field(name: name, text: text, language: languageCode, role: ISOBaseMediaLyricsParser.id3UserTextRole(descriptor))
    }

    public static func userField(name: String, text: String) -> EmbeddedLyricField? {
        ISOBaseMediaLyricsParser.id3UserTextRole(name, text: text).map {
            field(name: name, text: text, language: nil, role: $0)
        }
    }

    static func field(name: String, text: String, language: String?, role: ISOBaseMediaLyricsParser.LyricFieldRole?) -> EmbeddedLyricField {
        var field = role?.field(name: name, text: text) ?? .init(name: name, text: text)
        field.languageCode = field.languageCode ?? language
        return field
    }

    static func values(frame: String, data: Data, mpegFrameDuration: TimeInterval?) -> [Value] {
        guard frameNames.contains(frame), !data.isEmpty else { return [] }
        if frame == "PRIV", data.starts(with: [0x58, 0x4d, 0x50, 0]) {
            return EmbeddedTagMetadataParser.xmpLyricFields(in: Data(data.dropFirst(4))).map {
                Value(field: $0, descriptor: "XMP", range: 4..<data.count, storage: .xmp)
            }
        }
        if ["GEOB", "GEO", "PRIV"].contains(frame) {
            return attachment(frame: frame, data: data).map { [$0] } ?? []
        }
        if frame == "SYLT" || frame == "SLT" {
            guard let lyrics = ID3SynchronizedLyricsParser.read(data, mpegFrameDuration: mpegFrameDuration) else { return [] }
            let field = declaredField(name: frame, descriptor: lyrics.descriptor, text: lyrics.text, languageCode: lyrics.languageCode)
            return [Value(field: field, descriptor: lyrics.descriptor, range: 0..<data.count, storage: .synchronized)]
        }
        let encoding = data[0]
        guard encoding <= 3 else { return [] }
        let userText = frame == "TXXX" || frame == "TXX"
        let isLyricFrame = frame == "USLT" || frame == "ULT"
        let start = userText ? 1 : 4
        guard let descriptorRange = terminatedString(in: data, from: start, encoding: encoding) else { return [] }
        let descriptor = string(data.subdata(in: descriptorRange), encoding) ?? ""
        let width = width(of: encoding)
        let startOfText = descriptorRange.upperBound + width
        let lang = userText ? nil : language(data.subdata(in: 1..<4))
        // A single UTF-16 BOM can apply to the descriptor and all subsequent values.
        let inheritedBOM = [descriptorRange.lowerBound, startOfText].compactMap { index -> Data? in
            guard encoding == 1, index + 2 <= data.count else { return nil }
            let bom = data.subdata(in: index..<(index + 2))
            return bom == Data([0xff, 0xfe]) || bom == Data([0xfe, 0xff]) ? bom : nil
        }.last
        var result: [Value] = []
        var cursor = startOfText
        while cursor < data.count {
            let range = terminatedString(in: data, from: cursor, encoding: encoding) ?? cursor..<data.count
            cursor = range.upperBound + width
            guard !range.isEmpty else { continue }
            var bytes = data.subdata(in: range)
            if let inheritedBOM, !bytes.starts(with: [0xfe, 0xff]), !bytes.starts(with: [0xff, 0xfe]) { bytes = inheritedBOM + bytes }
            guard let text = string(bytes, encoding), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let field: EmbeddedLyricField
            if isLyricFrame {
                field = declaredField(name: frame, descriptor: descriptor, text: text, languageCode: lang)
            } else {
                guard let role = ISOBaseMediaLyricsParser.id3UserTextRole(descriptor, text: text) else { continue }
                field = Self.field(name: userText && !descriptor.isEmpty ? descriptor : frame, text: text, language: lang, role: role)
            }
            result.append(Value(field: field, descriptor: descriptor, range: range, storage: .text, textStart: startOfText))
        }
        return result
    }

    private static func attachment(frame: String, data: Data) -> Value? {
        let isPrivate = frame == "PRIV"
        let start = isPrivate ? 0 : 1
        guard let mimeRange = terminatedString(in: data, from: start, encoding: 0),
              let label = String(data: data[mimeRange], encoding: .isoLatin1) else { return nil }
        let mime = label.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        var descriptor = label
        var filename = ""
        var offset = mimeRange.upperBound + 1
        if !isPrivate {
            guard data[0] <= 3, let file = terminatedString(in: data, from: offset, encoding: data[0]),
                  let desc = terminatedString(in: data, from: file.upperBound + width(of: data[0]), encoding: data[0]) else { return nil }
            filename = string(data.subdata(in: file), data[0]) ?? ""
            descriptor = string(data.subdata(in: desc), data[0]) ?? ""
            offset = desc.upperBound + width(of: data[0])
        }
        let declared = ISOBaseMediaLyricsParser.lyricFieldRole(descriptor)
        let lyricFile = LyricsDocumentFormat(fileName: filename) != nil || (filename as NSString).pathExtension.lowercased() == "krc"
        let lyricMIME = ["application/ttml+xml", "text/vtt", "application/x-subrip", "text/lrc"].contains(mime)
        let textMIME = mime.hasPrefix("text/") || ["application/xml", "application/octet-stream", ""].contains(mime)
        guard isPrivate ? declared != nil : (lyricFile || lyricMIME || textMIME),
              offset < data.count, data.count - offset <= LyricsRawDocumentPolicy.maximumByteCount else { return nil }
        let bytes = data.subdata(in: offset..<data.count)
        guard let decoded = TextEncodingRepair.decodeTextFile(bytes),
              !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        let role = declared ?? ISOBaseMediaLyricsParser.id3UserTextRole(descriptor, text: decoded.text)
        guard declared != nil || lyricFile || lyricMIME || role != nil else { return nil }
        let name = filename.isEmpty ? (descriptor.isEmpty ? frame : descriptor) : filename
        let field = Self.field(name: name, text: decoded.text, language: nil, role: role)
        return Value(field: field, descriptor: descriptor, range: offset..<data.count,
                     storage: .attachment(.init(original: bytes, decodedEncoding: decoded.encoding)))
    }

    static func width(of encoding: UInt8) -> Int { encoding == 1 || encoding == 2 ? 2 : 1 }

    static func terminatedString(in data: Data, from start: Int, encoding: UInt8) -> Range<Int>? {
        let width = width(of: encoding)
        var index = start
        while index <= data.count - width {
            if data[index] == 0, width == 1 || data[index + 1] == 0 { return start..<index }
            index += width
        }
        return nil
    }

    private static func string(_ bytes: Data, _ encoding: UInt8) -> String? {
        if bytes.isEmpty { return "" }
        if encoding == 3, let text = String(data: bytes, encoding: .utf8) { return text }
        if encoding == 1, (bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])) {
            return String(data: bytes, encoding: .utf16)
        }
        if encoding == 2 { return String(data: bytes, encoding: .utf16BigEndian) }
        guard let decoded = TextEncodingRepair.decodeID3Text(bytes, encodingByte: encoding) else { return nil }
        guard encoding == 0 else { return decoded }
        let raw = String(decoding: bytes, as: UTF8.self)
        return String(raw.prefix(while: \.isWhitespace)) + decoded + String(raw.reversed().prefix(while: \.isWhitespace).reversed())
    }

    private static func language(_ bytes: Data) -> String? {
        let code = String(decoding: bytes, as: UTF8.self).lowercased()
        guard !["und", "xxx", "zxx"].contains(code) else { return nil }
        return LyricLanguageCodePolicy.canonicalIdentifier(code)
    }
}
