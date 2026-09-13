import Foundation

/// Small dependency-free ID3 text parser used when AVFoundation cannot open a
/// truncated Range response or has already decoded a legacy tag lossily. It
/// handles ID3v2 text frames at the head and ID3v1 fields in the final 128
/// bytes; audio properties still come from the platform decoder.
public struct ID3TextMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var artists: [String]?
    public var albumTitle: String?
    public var albumArtist: String?
    public var albumArtists: [String]?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        artists: [String]? = nil,
        albumTitle: String? = nil,
        albumArtist: String? = nil,
        albumArtists: [String]? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.artists = artists
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.albumArtists = albumArtists
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.genre = genre
    }

    public var isEmpty: Bool {
        title == nil
            && artist == nil
            && albumTitle == nil
            && albumArtist == nil
            && trackNumber == nil
            && discNumber == nil
            && year == nil
            && genre == nil
    }
}

public enum ID3TextMetadataParser {
    /// Parses independently fetched file head/tail ranges without ever
    /// materializing them as one contiguous `Data`. ID3v2 from the head stays
    /// authoritative; a trailing ID3v1 tag only fills fields that are absent.
    public static func parse(head: Data, tail: Data?) -> ID3TextMetadata? {
        var result = parse(head) ?? ID3TextMetadata()
        if let tail, !tail.isEmpty, let trailing = parseID3v1(tail) {
            fillMissing(in: &result, from: trailing)
        }
        return result.isEmpty ? nil : result
    }

    public static func parse(_ data: Data) -> ID3TextMetadata? {
        let trailingMetadata = parseID3v1(data)
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            return trailingMetadata
        }
        let version = Int(data[3])
        guard (2...4).contains(version) else { return trailingMetadata }

        let declaredEnd = 10 + syncSafeInt(data, at: 6) + ((data[5] & 0x10) != 0 ? 10 : 0)
        let tagEnd = min(data.count, declaredEnd)
        guard tagEnd > 10 else { return nil }

        var tag = data.subdata(in: 10..<tagEnd)
        if (data[5] & 0x80) != 0 {
            tag = removingUnsynchronization(from: tag)
        }

        var result = ID3TextMetadata()
        var userTextValues: [String: [String]] = [:]
        var cursor = extendedHeaderLength(in: tag, version: version, flags: data[5])

        while cursor < tag.count {
            if version == 2 {
                guard cursor + 6 <= tag.count,
                      let frameID = ascii(tag, at: cursor, count: 3),
                      !frameID.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty else {
                    break
                }
                let size = uint24BE(tag, at: cursor + 3)
                let payloadStart = cursor + 6
                guard size > 0, payloadStart + size <= tag.count else { break }
                let declaredEnd = payloadStart + size
                let recovered = recoveredTextPayload(
                    frameID: frameID,
                    payloadStart: payloadStart,
                    declaredEnd: declaredEnd,
                    tag: tag,
                    version: version
                )
                let payload = recovered?.payload
                    ?? tag.subdata(in: payloadStart..<declaredEnd)
                cursor = recovered?.nextFrameOffset ?? declaredEnd
                apply(frameID: frameID, payload: payload, to: &result, userTextValues: &userTextValues)
                continue
            }

            let frameStart = cursor
            guard frameStart + 10 <= tag.count,
                  let frameID = ascii(tag, at: frameStart, count: 4),
                  !frameID.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty else {
                break
            }
            let size = version == 4
                ? syncSafeInt(tag, at: frameStart + 4)
                : uint32BE(tag, at: frameStart + 4)
            let formatFlags = tag[frameStart + 9]
            let payloadStart = frameStart + 10
            guard size > 0, payloadStart + size <= tag.count else { break }

            let declaredEnd = payloadStart + size
            guard supportsPlainTextFrame(version: version, formatFlags: formatFlags) else {
                cursor = declaredEnd
                continue
            }
            let recovered = recoveredTextPayload(
                frameID: frameID,
                payloadStart: payloadStart,
                declaredEnd: declaredEnd,
                tag: tag,
                version: version
            )
            var payload = recovered?.payload
                ?? tag.subdata(in: payloadStart..<declaredEnd)
            cursor = recovered?.nextFrameOffset ?? declaredEnd
            if version == 4, (formatFlags & 0x02) != 0 {
                payload = removingUnsynchronization(from: payload)
            }
            apply(frameID: frameID, payload: payload, to: &result, userTextValues: &userTextValues)
        }

        // TPE2/TP2 remains authoritative regardless of frame order. Custom
        // Album Artist fields are a fallback for files using tagger mappings.
        if result.albumArtist == nil, !userTextValues.isEmpty {
            result.albumArtist = EmbeddedTagMetadataParser.metadata(
                fromTagValues: userTextValues
            ).albumArtist
        }
        if let trailingMetadata {
            fillMissing(in: &result, from: trailingMetadata)
        }
        return result.isEmpty ? nil : result
    }

    private static func parseID3v1(_ data: Data) -> ID3TextMetadata? {
        guard data.count >= 128 else { return nil }
        let start = data.count - 128
        guard data[start] == 0x54, data[start + 1] == 0x41, data[start + 2] == 0x47 else {
            return nil
        }

        let commentStart = start + 97
        let trackNumber = data[commentStart + 28] == 0 && data[commentStart + 29] > 0
            ? Int(data[commentStart + 29])
            : nil
        let yearText = decodedID3v1Field(data[(start + 93)..<(start + 97)])
        let result = ID3TextMetadata(
            title: decodedID3v1Field(data[(start + 3)..<(start + 33)]),
            artist: decodedID3v1Field(data[(start + 33)..<(start + 63)]),
            albumTitle: decodedID3v1Field(data[(start + 63)..<(start + 93)]),
            trackNumber: trackNumber,
            year: yearText.flatMap(Int.init)
        )
        return result.isEmpty ? nil : result
    }

    private static func decodedID3v1Field(_ field: Data.SubSequence) -> String? {
        var bytes = Array(field)
        while bytes.last == 0 || bytes.last == 0x20 { bytes.removeLast() }
        while bytes.first == 0 || bytes.first == 0x20 { bytes.removeFirst() }
        guard !bytes.isEmpty else { return nil }
        return TextEncodingRepair.decodeID3Text(Data(bytes), encodingByte: 0)
    }

    private static func fillMissing(
        in metadata: inout ID3TextMetadata,
        from fallback: ID3TextMetadata
    ) {
        metadata.title = metadata.title ?? fallback.title
        metadata.artist = metadata.artist ?? fallback.artist
        metadata.artists = metadata.artists ?? fallback.artists
        metadata.albumTitle = metadata.albumTitle ?? fallback.albumTitle
        metadata.albumArtist = metadata.albumArtist ?? fallback.albumArtist
        metadata.albumArtists = metadata.albumArtists ?? fallback.albumArtists
        metadata.trackNumber = metadata.trackNumber ?? fallback.trackNumber
        metadata.year = metadata.year ?? fallback.year
    }

    private struct RecoveredTextPayload {
        let payload: Data
        let nextFrameOffset: Int
    }

    /// Some taggers write a text frame's character count into its byte-size
    /// field. When multibyte UTF-8 follows, the declared payload ends inside a
    /// scalar and the platform emits U+FFFD. Recover only when a structurally
    /// valid following frame gives us a bounded end offset and the extended
    /// bytes decode to a clean, strictly more complete value.
    /// 修复「帧长写错」的文本帧:把 payload 延长到下一个像样的帧头处。
    ///
    /// 只在两种情况下延长:① 声明的 payload 本身就是坏的(结构非法、解出乱码);
    /// ② 声明的字节数恰好等于「字符数 + 1 个编码字节」—— 那是某些打标签工具
    /// 把 ID3v2.4 的帧长按字符数而不是字节数写了,多字节文本会被截掉尾巴。
    ///
    /// 第二个条件必须**精确**到这个等式。早先只要求「延长后的文本以声明文本开头
    /// 且更长」,而这对任何一个完好的帧都成立 —— 只要往后多读一点、后面的字节
    /// 又恰好能解成文字,条件就满足。远端只读文件头一小段时(电视端扫描就是这样),
    /// 标签常被窗口截断、下一个帧头不完整,于是标题会把后面那一帧(比如内嵌歌词)
    /// 的内容一并吞进来,变成「歌名 [00:03.696]词:某某」这种。
    private static func recoveredTextPayload(
        frameID: String,
        payloadStart: Int,
        declaredEnd: Int,
        tag: Data,
        version: Int
    ) -> RecoveredTextPayload? {
        guard isParsedTextFrame(frameID) else { return nil }
        guard !isPlausibleFrameHeader(in: tag, at: declaredEnd, version: version) else {
            return nil
        }
        guard let boundary = nextPlausibleFrameOffset(
            in: tag,
            after: declaredEnd,
            version: version
        ), boundary > declaredEnd else {
            return nil
        }

        let declaredPayload = tag.subdata(in: payloadStart..<declaredEnd)
        let recoveredPayload = tag.subdata(in: payloadStart..<boundary)
        guard let recoveredText = decodedText(recoveredPayload),
              !MediaMetadataTextRepair.isSuspicious(recoveredText) else {
            return nil
        }

        let declaredText = decodedText(declaredPayload)
        let declaredWasDamaged = declaredTextPayloadIsStructurallyInvalid(declaredPayload)
            || declaredText.map {
            MediaMetadataTextRepair.isSuspicious($0)
                || TextEncodingRepair.looksCorrupted($0)
            } ?? true
        let sizeWasWrittenAsCharacterCount = declaredText.map {
            !$0.isEmpty
                && recoveredText.hasPrefix($0)
                && recoveredText.count > $0.count
                && declaredPayload.count == recoveredText.count + 1
        } ?? false
        guard declaredWasDamaged || sizeWasWrittenAsCharacterCount else { return nil }
        return RecoveredTextPayload(payload: recoveredPayload, nextFrameOffset: boundary)
    }

    private static func declaredTextPayloadIsStructurallyInvalid(_ payload: Data) -> Bool {
        guard let encodingByte = payload.first else { return true }
        let bytes = Data(payload.dropFirst())
        switch encodingByte {
        case 1, 2:
            return bytes.count.isMultiple(of: 2) == false
        case 3:
            return String(data: bytes, encoding: .utf8) == nil
        default:
            return false
        }
    }

    private static func isParsedTextFrame(_ frameID: String) -> Bool {
        switch frameID {
        case "TIT2", "TT2", "TPE1", "TP1", "TALB", "TAL", "TPE2", "TP2",
             "TRCK", "TRK", "TPOS", "TPA", "TYER", "TDRC", "TYE", "TCON", "TCO":
            return true
        default:
            return false
        }
    }

    private static func nextPlausibleFrameOffset(
        in tag: Data,
        after offset: Int,
        version: Int
    ) -> Int? {
        let headerSize = version == 2 ? 6 : 10
        let upperBound = min(tag.count - headerSize, offset + 4_096)
        guard offset < upperBound else { return nil }
        for candidate in (offset + 1)...upperBound where
            isPlausibleFrameHeader(in: tag, at: candidate, version: version) {
            return candidate
        }
        return nil
    }

    private static func isPlausibleFrameHeader(
        in tag: Data,
        at offset: Int,
        version: Int
    ) -> Bool {
        let idLength = version == 2 ? 3 : 4
        let headerSize = version == 2 ? 6 : 10
        guard offset >= 0, offset <= tag.count - headerSize else { return false }
        let idBytes = tag[offset..<(offset + idLength)]
        guard idBytes.allSatisfy({
            (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
        }) else {
            return false
        }
        let size = if version == 2 {
            uint24BE(tag, at: offset + 3)
        } else if version == 4 {
            syncSafeInt(tag, at: offset + 4)
        } else {
            uint32BE(tag, at: offset + 4)
        }
        return size > 0 && offset + headerSize + size <= tag.count
    }

    private static func supportsPlainTextFrame(version: Int, formatFlags: UInt8) -> Bool {
        if version == 3 {
            // compression, encryption, grouping identity
            return (formatFlags & 0xE0) == 0
        }
        if version == 4 {
            // grouping, compression, encryption, data-length indicator.
            // Frame-level unsynchronisation (0x02) is handled above.
            return (formatFlags & 0x4D) == 0
        }
        return true
    }

    private static func apply(
        frameID: String,
        payload: Data,
        to result: inout ID3TextMetadata,
        userTextValues: inout [String: [String]]
    ) {
        if frameID == "TXXX" || frameID == "TXX" {
            if let field = decodedUserText(payload) {
                userTextValues[field.key, default: []].append(contentsOf: field.values)
            }
            return
        }
        let values = decodedTextValues(payload)
        guard let value = values.first else { return }
        switch frameID {
        case "TIT2", "TT2":
            result.title = result.title ?? value
        case "TPE1", "TP1":
            appendDistinct(values, to: &result.artists)
            result.artist = result.artists?.joined(separator: "; ") ?? value
        case "TALB", "TAL":
            result.albumTitle = result.albumTitle ?? value
        case "TPE2", "TP2":
            appendDistinct(values, to: &result.albumArtists)
            result.albumArtist = result.albumArtists?.joined(separator: "; ") ?? value
        case "TRCK", "TRK":
            result.trackNumber = result.trackNumber ?? leadingInt(value)
        case "TPOS", "TPA":
            result.discNumber = result.discNumber ?? leadingInt(value)
        case "TYER", "TDRC", "TYE":
            result.year = result.year ?? year(value)
        case "TCON", "TCO":
            result.genre = result.genre ?? value
        default:
            break
        }
    }

    private static func decodedUserText(_ payload: Data) -> (key: String, values: [String])? {
        guard let encoding = payload.first, encoding <= 3 else { return nil }
        let terminatorLength = (encoding == 1 || encoding == 2) ? 2 : 1
        var cursor = 1
        while cursor + terminatorLength <= payload.count {
            if payload[cursor] == 0,
               terminatorLength == 1 || payload[cursor + 1] == 0 {
                break
            }
            cursor += terminatorLength
        }
        let valueStart = cursor + terminatorLength
        guard valueStart < payload.count,
              let key = TextEncodingRepair.decodeID3Text(
                payload.subdata(in: 1..<cursor), encodingByte: encoding
              ) else { return nil }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"].contains(normalizedKey) else {
            return nil
        }
        var valueData = payload.subdata(in: valueStart..<payload.count)
        // UTF-16 values may omit a second BOM and inherit the description's
        // byte order; carry it over before decoding that separate string.
        if encoding == 1, payload.count >= 3 {
            let bom = payload.subdata(in: 1..<3)
            let byteOrderMarks = [Data([0xFF, 0xFE]), Data([0xFE, 0xFF])]
            if byteOrderMarks.contains(bom), !byteOrderMarks.contains(Data(valueData.prefix(2))) {
                valueData = bom + valueData
            }
        }
        let values = TextEncodingRepair.decodeID3TextValues(valueData, encodingByte: encoding)
        return values.isEmpty ? nil : (normalizedKey, values)
    }

    private static func decodedText(_ frame: Data) -> String? {
        decodedTextValues(frame).first
    }

    private static func decodedTextValues(_ frame: Data) -> [String] {
        guard let encodingByte = frame.first else { return [] }
        // ID3v2.3 specifies ISO-8859-1 for encoding byte 0, but many legacy
        // taggers wrote GBK/Big5/Shift_JIS bytes while leaving the flag at
        // zero. ISO-8859-1 decoding never fails, so the candidates have to be
        // scored rather than chained with `??`.
        return TextEncodingRepair.decodeID3TextValues(
            Data(frame.dropFirst()),
            encodingByte: encodingByte
        )
    }

    private static func appendDistinct(
        _ values: [String],
        to destination: inout [String]?
    ) {
        var result = destination ?? []
        for value in values where !result.contains(where: {
            $0.compare(
                value,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            ) == .orderedSame
        }) {
            result.append(value)
        }
        destination = result.isEmpty ? nil : result
    }

    private static func extendedHeaderLength(in tag: Data, version: Int, flags: UInt8) -> Int {
        guard (flags & 0x40) != 0 else { return 0 }
        if version == 3 {
            guard tag.count >= 4 else { return tag.count }
            return min(tag.count, 4 + uint32BE(tag, at: 0))
        }
        if version == 4 {
            guard tag.count >= 4 else { return tag.count }
            return min(tag.count, syncSafeInt(tag, at: 0))
        }
        return 0
    }

    private static func removingUnsynchronization(from data: Data) -> Data {
        var result = Data()
        result.reserveCapacity(data.count)
        var index = 0
        while index < data.count {
            let byte = data[index]
            result.append(byte)
            if byte == 0xFF, index + 1 < data.count, data[index + 1] == 0 {
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    private static func leadingInt(_ value: String) -> Int? {
        let digits = value.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(String(digits))
    }

    private static func year(_ value: String) -> Int? {
        let digits = value.prefix(4)
        return digits.count == 4 ? Int(String(digits)) : nil
    }

    private static func ascii(_ data: Data, at offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            return nil
        }
        return String(data: data.subdata(in: offset..<(offset + count)), encoding: .isoLatin1)
    }

    private static func uint24BE(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 3 else { return 0 }
        return (Int(data[offset]) << 16)
            | (Int(data[offset + 1]) << 8)
            | Int(data[offset + 2])
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private static func syncSafeInt(_ data: Data, at offset: Int) -> Int {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return (Int(data[offset] & 0x7F) << 21)
            | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7)
            | Int(data[offset + 3] & 0x7F)
    }
}
