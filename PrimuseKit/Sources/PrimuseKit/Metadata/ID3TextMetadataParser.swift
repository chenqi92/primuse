import Foundation

/// Small dependency-free ID3v2 text-frame parser used when AVFoundation
/// cannot open a truncated Range response. It intentionally handles only
/// fields that are safe to recover from the tag header; audio properties such
/// as duration and bitrate still come from the platform decoder.
public struct ID3TextMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var albumTitle: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        albumTitle: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        genre: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
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
    public static func parse(_ data: Data) -> ID3TextMetadata? {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            return nil
        }
        let version = Int(data[3])
        guard (2...4).contains(version) else { return nil }

        let declaredEnd = 10 + syncSafeInt(data, at: 6) + ((data[5] & 0x10) != 0 ? 10 : 0)
        let tagEnd = min(data.count, declaredEnd)
        guard tagEnd > 10 else { return nil }

        var tag = data.subdata(in: 10..<tagEnd)
        if (data[5] & 0x80) != 0 {
            tag = removingUnsynchronization(from: tag)
        }

        var result = ID3TextMetadata()
        var cursor = extendedHeaderLength(in: tag, version: version, flags: data[5])

        while cursor < tag.count {
            if version == 2 {
                guard cursor + 6 <= tag.count,
                      let frameID = ascii(tag, at: cursor, count: 3),
                      !frameID.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty else {
                    break
                }
                let size = uint24BE(tag, at: cursor + 3)
                cursor += 6
                guard size > 0, cursor + size <= tag.count else { break }
                let payload = tag.subdata(in: cursor..<(cursor + size))
                cursor += size
                apply(frameID: frameID, payload: payload, to: &result)
                continue
            }

            guard cursor + 10 <= tag.count,
                  let frameID = ascii(tag, at: cursor, count: 4),
                  !frameID.trimmingCharacters(in: CharacterSet(charactersIn: "\0")).isEmpty else {
                break
            }
            let size = version == 4
                ? syncSafeInt(tag, at: cursor + 4)
                : uint32BE(tag, at: cursor + 4)
            let formatFlags = tag[cursor + 9]
            cursor += 10
            guard size > 0, cursor + size <= tag.count else { break }

            var payload = tag.subdata(in: cursor..<(cursor + size))
            cursor += size
            guard supportsPlainTextFrame(version: version, formatFlags: formatFlags) else {
                continue
            }
            if version == 4, (formatFlags & 0x02) != 0 {
                payload = removingUnsynchronization(from: payload)
            }
            apply(frameID: frameID, payload: payload, to: &result)
        }

        return result.isEmpty ? nil : result
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
        to result: inout ID3TextMetadata
    ) {
        guard let value = decodedText(payload) else { return }
        switch frameID {
        case "TIT2", "TT2":
            result.title = result.title ?? value
        case "TPE1", "TP1":
            result.artist = result.artist ?? value
        case "TALB", "TAL":
            result.albumTitle = result.albumTitle ?? value
        case "TPE2", "TP2":
            result.albumArtist = result.albumArtist ?? value
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

    private static func decodedText(_ frame: Data) -> String? {
        guard let encodingByte = frame.first else { return nil }
        let payload = Data(frame.dropFirst())
        let decoded: String?

        switch encodingByte {
        case 0:
            // ID3v2.3 specifies ISO-8859-1, but many legacy libraries wrote
            // UTF-8/GBK bytes while leaving this flag at zero.
            decoded = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1)
                ?? String(data: payload, encoding: .windowsCP1252)
        case 1:
            decoded = String(data: payload, encoding: .utf16)
                ?? String(data: payload, encoding: .utf16LittleEndian)
                ?? String(data: payload, encoding: .utf16BigEndian)
        case 2:
            decoded = String(data: payload, encoding: .utf16BigEndian)
        case 3:
            decoded = String(data: payload, encoding: .utf8)
        default:
            return nil
        }

        guard let decoded else { return nil }
        let normalized = decoded
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return MediaMetadataTextRepair.repaired(normalized) ?? normalized
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
        guard offset >= 0, count >= 0, offset + count <= data.count else { return nil }
        return String(data: data.subdata(in: offset..<(offset + count)), encoding: .isoLatin1)
    }

    private static func uint24BE(_ data: Data, at offset: Int) -> Int {
        guard offset + 3 <= data.count else { return 0 }
        return (Int(data[offset]) << 16)
            | (Int(data[offset + 1]) << 8)
            | Int(data[offset + 2])
    }

    private static func uint32BE(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset]) << 24)
            | (Int(data[offset + 1]) << 16)
            | (Int(data[offset + 2]) << 8)
            | Int(data[offset + 3])
    }

    private static func syncSafeInt(_ data: Data, at offset: Int) -> Int {
        guard offset + 4 <= data.count else { return 0 }
        return (Int(data[offset] & 0x7F) << 21)
            | (Int(data[offset + 1] & 0x7F) << 14)
            | (Int(data[offset + 2] & 0x7F) << 7)
            | Int(data[offset + 3] & 0x7F)
    }
}
