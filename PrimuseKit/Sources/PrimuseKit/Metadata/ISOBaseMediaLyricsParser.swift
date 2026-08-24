import Foundation

/// Extracts embedded lyrics from ISO Base Media metadata without relying on
/// AVFoundation's identifier projection. In addition to the traditional
/// iTunes `©lyr` item, ffmpeg and other writers can use an `mdta` keys table
/// whose `ilst` children are numeric indexes. Keeping the original `data` atom
/// bytes also lets the shared encoding repair recover incorrectly declared
/// GB18030, Big5, Shift_JIS and EUC-KR text.
public enum ISOBaseMediaLyricsParser {
    public static func lyrics(in data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        for moov in atoms(in: data, range: data.startIndex..<data.endIndex)
            where moov.type == AtomType.moov {
            for metadata in metadataAtoms(in: data, moov: moov) {
                if let lyrics = lyrics(in: data, metadata: metadata) {
                    return lyrics
                }
            }
        }
        return nil
    }

    private struct Atom {
        let type: UInt32
        let payload: Range<Int>
    }

    private enum AtomType {
        static let moov = fourCC(0x6D, 0x6F, 0x6F, 0x76)
        static let udta = fourCC(0x75, 0x64, 0x74, 0x61)
        static let meta = fourCC(0x6D, 0x65, 0x74, 0x61)
        static let keys = fourCC(0x6B, 0x65, 0x79, 0x73)
        static let ilst = fourCC(0x69, 0x6C, 0x73, 0x74)
        static let data = fourCC(0x64, 0x61, 0x74, 0x61)
        static let freeform = fourCC(0x2D, 0x2D, 0x2D, 0x2D)
        static let name = fourCC(0x6E, 0x61, 0x6D, 0x65)
        static let iTunesLyrics: UInt32 = 0xA96C7972

        private static func fourCC(
            _ a: UInt32,
            _ b: UInt32,
            _ c: UInt32,
            _ d: UInt32
        ) -> UInt32 {
            (a << 24) | (b << 16) | (c << 8) | d
        }
    }

    private static func metadataAtoms(in data: Data, moov: Atom) -> [Atom] {
        var result: [Atom] = []
        for child in atoms(in: data, range: moov.payload) {
            if child.type == AtomType.meta {
                result.append(child)
            } else if child.type == AtomType.udta {
                result.append(contentsOf: atoms(in: data, range: child.payload).filter {
                    $0.type == AtomType.meta
                })
            }
        }
        return result
    }

    private static func lyrics(in data: Data, metadata: Atom) -> String? {
        guard metadata.payload.count >= 4 else { return nil }
        let childrenRange = (metadata.payload.lowerBound + 4)..<metadata.payload.upperBound
        let children = atoms(in: data, range: childrenRange)
        let keys = children.first(where: { $0.type == AtomType.keys })
            .map { metadataKeys(in: data, atom: $0) } ?? [:]

        for list in children where list.type == AtomType.ilst {
            let items = atoms(in: data, range: list.payload)

            for item in items where item.type == AtomType.iTunesLyrics {
                if let text = decodedItem(in: data, item: item) {
                    return text
                }
            }

            for item in items {
                guard let key = keys[item.type], isLyricsKey(key),
                      let text = decodedItem(in: data, item: item) else { continue }
                return text
            }

            for item in items where item.type == AtomType.freeform {
                guard freeformName(in: data, item: item).map(isLyricsKey) == true,
                      let text = decodedItem(in: data, item: item) else { continue }
                return text
            }
        }
        return nil
    }

    private static func metadataKeys(in data: Data, atom: Atom) -> [UInt32: String] {
        guard atom.payload.count >= 8,
              let entryCount = readUInt32BE(data, at: atom.payload.lowerBound + 4) else {
            return [:]
        }

        var cursor = atom.payload.lowerBound + 8
        var result: [UInt32: String] = [:]
        let maximumEntries = (atom.payload.upperBound - cursor) / 8
        guard Int(entryCount) <= maximumEntries else { return [:] }
        guard entryCount > 0 else { return result }

        for index in 1...Int(entryCount) {
            guard let entrySize = readUInt32BE(data, at: cursor),
                  entrySize >= 8,
                  UInt64(entrySize) <= UInt64(atom.payload.upperBound - cursor) else {
                return [:]
            }
            let end = cursor + Int(entrySize)
            let keyData = data.subdata(in: (cursor + 8)..<end)
            if let key = String(data: keyData, encoding: .utf8)
                ?? String(data: keyData, encoding: .isoLatin1) {
                result[UInt32(index)] = key
            }
            cursor = end
        }
        return result
    }

    private static func freeformName(in data: Data, item: Atom) -> String? {
        for child in atoms(in: data, range: item.payload) where child.type == AtomType.name {
            guard child.payload.count >= 4 else { continue }
            let value = data.subdata(in: (child.payload.lowerBound + 4)..<child.payload.upperBound)
            if let name = String(data: value, encoding: .utf8)
                ?? String(data: value, encoding: .isoLatin1) {
                return name
            }
        }
        return nil
    }

    private static func decodedItem(in data: Data, item: Atom) -> String? {
        for child in atoms(in: data, range: item.payload) where child.type == AtomType.data {
            guard child.payload.count >= 8,
                  let declaredType = readUInt32BE(data, at: child.payload.lowerBound) else {
                continue
            }
            let value = data.subdata(in: (child.payload.lowerBound + 8)..<child.payload.upperBound)
            if let decoded = decode(value, declaredType: declaredType & 0x00FF_FFFF) {
                return decoded
            }
        }
        return nil
    }

    private static func decode(_ data: Data, declaredType: UInt32) -> String? {
        guard !data.isEmpty else { return nil }

        let decoded: String?
        if [2, 5].contains(declaredType) || hasUTF16ByteOrderMark(data) {
            decoded = TextEncodingRepair.bestDecoding(
                of: data,
                encodings: [.utf16, .utf16BigEndian, .utf16LittleEndian]
            )
        } else if [0, 1, 3, 4].contains(declaredType) {
            decoded = TextEncodingRepair.bestDecoding(
                of: data,
                encodings: TextEncodingRepair.legacyTextEncodings
            )
        } else {
            return nil
        }
        guard let decoded else { return nil }

        let trimSet = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\0\u{FEFF}")
        )
        let normalized = decoded.trimmingCharacters(in: trimSet)
        guard !normalized.isEmpty else { return nil }
        return TextEncodingRepair.repaired(normalized) ?? normalized
    }

    private static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return (data[data.startIndex] == 0xFE && data[data.startIndex + 1] == 0xFF)
            || (data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xFE)
    }

    private static func isLyricsKey(_ value: String) -> Bool {
        let components = value
            .lowercased()
            .split(whereSeparator: { ".:/".contains($0) })
        guard let final = components.last else { return false }
        return final == "lyrics" || final == "unsyncedlyrics"
    }

    private static func atoms(in data: Data, range: Range<Int>) -> [Atom] {
        guard range.lowerBound >= data.startIndex,
              range.upperBound <= data.endIndex,
              range.lowerBound <= range.upperBound else { return [] }

        var result: [Atom] = []
        var cursor = range.lowerBound
        while cursor <= range.upperBound - 8 {
            guard let size32 = readUInt32BE(data, at: cursor),
                  let type = readUInt32BE(data, at: cursor + 4) else { break }

            let headerLength: Int
            let totalLength: UInt64
            switch size32 {
            case 0:
                headerLength = 8
                totalLength = UInt64(range.upperBound - cursor)
            case 1:
                guard cursor <= range.upperBound - 16,
                      let extendedSize = readUInt64BE(data, at: cursor + 8) else {
                    return result
                }
                headerLength = 16
                totalLength = extendedSize
            default:
                headerLength = 8
                totalLength = UInt64(size32)
            }

            guard totalLength >= UInt64(headerLength),
                  totalLength <= UInt64(range.upperBound - cursor) else {
                break
            }
            let end = cursor + Int(totalLength)
            result.append(Atom(type: type, payload: (cursor + headerLength)..<end))
            guard end > cursor else { break }
            cursor = end
        }
        return result
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= data.startIndex, offset <= data.endIndex - 4 else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= data.startIndex, offset <= data.endIndex - 8 else { return nil }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(data[index])
        }
        return value
    }
}
