import Foundation

/// Extracts embedded lyrics from ISO Base Media metadata without relying on
/// AVFoundation's identifier projection. In addition to the traditional
/// iTunes `©lyr` item, ffmpeg and other writers can use an `mdta` keys table
/// whose `ilst` children are numeric indexes. Keeping the original `data` atom
/// bytes also lets the shared encoding repair recover incorrectly declared
/// GB18030, Big5, Shift_JIS and EUC-KR text.
public enum ISOBaseMediaLyricsParser {
    public struct LyricsPayload: Equatable, Sendable {
        public var lyrics: String?
        public var lyricsLanguageCode: String?
        public var translatedLyrics: String?
        public var translatedLyricsLanguageCode: String?
        public var languageTaggedLyrics: [String: String]
        public var languageTaggedTranslations: [String: String]

        public init(
            lyrics: String? = nil,
            lyricsLanguageCode: String? = nil,
            translatedLyrics: String? = nil,
            translatedLyricsLanguageCode: String? = nil,
            languageTaggedLyrics: [String: String] = [:],
            languageTaggedTranslations: [String: String] = [:]
        ) {
            self.lyrics = lyrics
            self.lyricsLanguageCode = lyricsLanguageCode
            self.translatedLyrics = translatedLyrics
            self.translatedLyricsLanguageCode = translatedLyricsLanguageCode
            self.languageTaggedLyrics = languageTaggedLyrics
            self.languageTaggedTranslations = languageTaggedTranslations
        }

        public var isEmpty: Bool {
            lyrics == nil
                && translatedLyrics == nil
                && languageTaggedLyrics.isEmpty
                && languageTaggedTranslations.isEmpty
        }

        mutating func fillMissing(from fallback: LyricsPayload) {
            if lyrics == nil {
                lyrics = fallback.lyrics
                lyricsLanguageCode = fallback.lyricsLanguageCode
            } else if lyrics == fallback.lyrics, lyricsLanguageCode == nil {
                lyricsLanguageCode = fallback.lyricsLanguageCode
            }
            if translatedLyrics == nil {
                translatedLyrics = fallback.translatedLyrics
                translatedLyricsLanguageCode = fallback.translatedLyricsLanguageCode
            } else if translatedLyrics == fallback.translatedLyrics,
                      translatedLyricsLanguageCode == nil {
                translatedLyricsLanguageCode = fallback.translatedLyricsLanguageCode
            }
            languageTaggedLyrics.merge(fallback.languageTaggedLyrics) { current, _ in current }
            languageTaggedTranslations.merge(fallback.languageTaggedTranslations) {
                current, _ in current
            }
        }
    }

    public static func lyrics(in data: Data) -> String? {
        payload(in: data)?.lyrics
    }

    public static func payload(in data: Data) -> LyricsPayload? {
        guard !data.isEmpty else { return nil }
        var result = LyricsPayload()
        for moov in atoms(in: data, range: data.startIndex..<data.endIndex)
            where moov.type == AtomType.moov {
            for metadata in metadataAtoms(in: data, moov: moov) {
                if let payload = lyricsPayload(in: data, metadata: metadata) {
                    result.fillMissing(from: payload)
                }
            }
        }
        return result.isEmpty ? nil : result
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

    private static func lyricsPayload(in data: Data, metadata: Atom) -> LyricsPayload? {
        guard metadata.payload.count >= 4 else { return nil }
        let childrenRange = (metadata.payload.lowerBound + 4)..<metadata.payload.upperBound
        let children = atoms(in: data, range: childrenRange)
        let keys = children.first(where: { $0.type == AtomType.keys })
            .map { metadataKeys(in: data, atom: $0) } ?? [:]
        var result = LyricsPayload()

        for list in children where list.type == AtomType.ilst {
            let items = atoms(in: data, range: list.payload)

            for item in items where item.type == AtomType.iTunesLyrics {
                if let text = decodedItem(in: data, item: item) {
                    result.lyrics = result.lyrics ?? text
                }
            }

            for item in items {
                guard let key = keys[item.type], let role = lyricFieldRole(key),
                      let text = decodedItem(in: data, item: item) else { continue }
                apply(text: text, role: role, to: &result)
            }

            for item in items where item.type == AtomType.freeform {
                guard let name = freeformName(in: data, item: item),
                      let role = lyricFieldRole(name),
                      let text = decodedItem(in: data, item: item) else { continue }
                apply(text: text, role: role, to: &result)
            }
        }
        return result.isEmpty ? nil : result
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

    private enum LyricFieldRole {
        case original(languageCode: String?)
        case translation(languageCode: String?)
    }

    private static func apply(
        text: String,
        role: LyricFieldRole,
        to payload: inout LyricsPayload
    ) {
        switch role {
        case .original(let languageCode):
            if let languageCode {
                payload.languageTaggedLyrics[languageCode] = text
            }
            if payload.lyrics == nil {
                payload.lyrics = text
                payload.lyricsLanguageCode = languageCode
            } else if payload.lyrics == text, payload.lyricsLanguageCode == nil {
                payload.lyricsLanguageCode = languageCode
            }
        case .translation(let languageCode):
            if let languageCode {
                payload.languageTaggedTranslations[languageCode] = text
            }
            if payload.translatedLyrics == nil {
                payload.translatedLyrics = text
                payload.translatedLyricsLanguageCode = languageCode
            } else if payload.translatedLyrics == text,
                      payload.translatedLyricsLanguageCode == nil {
                payload.translatedLyricsLanguageCode = languageCode
            }
        }
    }

    private static func lyricFieldRole(_ value: String) -> LyricFieldRole? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let translatedRoots = [
            "TRANSLATEDLYRICS", "TRANSLATED LYRICS", "TRANSLATION",
            "LYRICS TRANSLATION",
        ]
        let originalRoots = [
            "UNSYNCEDLYRICS", "UNSYNCED LYRICS", "SYNCEDLYRICS",
            "SYNCED LYRICS", "LYRICS",
        ]

        if let languageCode = matchedLyricKey(normalized, roots: translatedRoots) {
            return .translation(languageCode: languageCode)
        }
        if let languageCode = matchedLyricKey(normalized, roots: originalRoots) {
            return .original(languageCode: languageCode)
        }
        return nil
    }

    /// A nil outer optional means no lyric key matched. A non-nil outer
    /// optional with a nil language is an untagged lyric key.
    private static func matchedLyricKey(
        _ key: String,
        roots: [String]
    ) -> String?? {
        for root in roots.sorted(by: { $0.count > $1.count }) {
            guard let range = key.range(of: root) else { continue }
            let prefix = key[..<range.lowerBound]
            guard prefix.isEmpty || prefix.last.map({ ".:/_- ".contains($0) }) == true else {
                continue
            }
            let rawSuffix = key[range.upperBound...]
            guard rawSuffix.isEmpty
                    || rawSuffix.first.map({ " .:/_-[".contains($0) }) == true else {
                continue
            }
            let suffix = rawSuffix
                .trimmingCharacters(in: CharacterSet(charactersIn: " .:/_-[]()"))
            guard !suffix.isEmpty else { return .some(nil) }
            guard let languageCode = normalizedLanguageCode(String(suffix)) else { continue }
            return .some(languageCode)
        }
        return nil
    }

    private static func normalizedLanguageCode(_ value: String) -> String? {
        LyricLanguageCodePolicy.canonicalIdentifier(value)
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
