import Foundation

/// Extracts embedded lyrics from ISO Base Media metadata without relying on
/// AVFoundation's identifier projection. In addition to the traditional
/// iTunes `©lyr` item, ffmpeg and other writers can use an `mdta` keys table
/// whose `ilst` children are numeric indexes. Keeping the original `data` atom
/// bytes also lets the shared encoding repair recover incorrectly declared
/// GB18030, Big5, Shift_JIS and EUC-KR text. The same item walk reads the
/// file's ReplayGain items.
public enum ISOBaseMediaLyricsParser {
    public struct LyricsPayload: Equatable, Sendable {
        public var lyrics: String?
        public var lyricsLanguageCode: String?
        public var translatedLyrics: String?
        public var translatedLyricsLanguageCode: String?
        public var languageTaggedLyrics: [String: String]
        public var languageTaggedTranslations: [String: String]
        /// `©lyr` 和不带语言（或同一种语言）的原文字段按先后都记下，`lyrics` 按设置从里面挑。
        public var lyricsVariants: [EmbeddedLyricsVariant]

        public init(
            lyrics: String? = nil,
            lyricsLanguageCode: String? = nil,
            translatedLyrics: String? = nil,
            translatedLyricsLanguageCode: String? = nil,
            languageTaggedLyrics: [String: String] = [:],
            languageTaggedTranslations: [String: String] = [:],
            lyricsVariants: [EmbeddedLyricsVariant] = []
        ) {
            self.lyrics = lyrics
            self.lyricsLanguageCode = lyricsLanguageCode
            self.translatedLyrics = translatedLyrics
            self.translatedLyricsLanguageCode = translatedLyricsLanguageCode
            self.languageTaggedLyrics = languageTaggedLyrics
            self.languageTaggedTranslations = languageTaggedTranslations
            self.lyricsVariants = lyricsVariants
        }

        public var isEmpty: Bool {
            lyrics == nil
                && translatedLyrics == nil
                && languageTaggedLyrics.isEmpty
                && languageTaggedTranslations.isEmpty
        }
    }

    public static func lyrics(in data: Data) -> String? {
        payload(in: data)?.lyrics
    }

    /// Requires a complete moov so a truncated range is never recorded as tagless.
    public static func contentMetadata(in data: Data) -> SongContentMetadata? {
        let movies = atoms(in: data, range: data.startIndex..<data.endIndex)
            .filter { $0.type == AtomType.moov }
        guard !movies.isEmpty else { return nil }
        var result = SongContentMetadata(isFileInspectionComplete: true)
        // 同一份 moov 顺手数章节:资料库按它算有声书的章数,不必为这个数字另开文件。
        result.embeddedChapterCount = ISOBaseMediaChapterParser.chapterCount(in: data) ?? 0
        for moov in movies {
            for metadata in metadataAtoms(in: data, moov: moov) {
                guard metadata.payload.count >= 4 else { continue }
                let children = atoms(in: data, range: (metadata.payload.lowerBound + 4)..<metadata.payload.upperBound)
                for list in children where list.type == AtomType.ilst {
                    for item in atoms(in: data, range: list.payload) {
                        if item.type == AtomType.freeform,
                           let name = freeformName(in: data, item: item),
                           let value = decodedItem(in: data, item: item),
                           let releaseType = EmbeddedTagMetadataParser.metadata(fromTagValues: [name: [value]]).releaseType {
                            result.releaseType = [result.releaseType, releaseType].compactMap { $0 }.joined(separator: "; ")
                        } else if item.type == 0x63707274 {
                            result.copyright = result.copyright ?? decodedItem(in: data, item: item)
                        } else if item.type == 0x72746E67 {
                            for value in atoms(in: data, range: item.payload) where value.type == AtomType.data {
                                guard value.payload.count >= 9, value.payload.count <= 12,
                                      let type = readUInt32BE(data, at: value.payload.lowerBound),
                                      [0, 21, 22].contains(type & 0x00FF_FFFF) else { continue }
                                let bytes = data[(value.payload.lowerBound + 8)..<value.payload.upperBound]
                                result.iTunesAdvisory = result.iTunesAdvisory ?? bytes.reduce(0) { ($0 << 8) | Int($1) }
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    public static func payload(in data: Data) -> LyricsPayload? {
        guard !data.isEmpty else { return nil }
        var fields: [(text: String, role: LyricFieldRole)] = []
        for moov in atoms(in: data, range: data.startIndex..<data.endIndex)
            where moov.type == AtomType.moov {
            for metadata in metadataAtoms(in: data, moov: moov) {
                fields.append(contentsOf: lyricFields(in: data, metadata: metadata))
            }
        }
        let originals = fields.compactMap { field -> EmbeddedLyricsVariant? in
            guard case .original(let language) = field.role else { return nil }
            return EmbeddedLyricsVariant(text: field.text, languageCode: language)
        }
        // Untagged originals identify the source even if a language-specific alternate
        // occurs earlier. Without an untagged original, use the first original's language.
        let primaryLanguage: String?
        if let untagged = originals.first(where: { $0.languageCode == nil }) {
            primaryLanguage = originals.first { $0.text == untagged.text && $0.languageCode != nil }?.languageCode
        } else {
            primaryLanguage = originals.first?.languageCode
        }
        var result = LyricsPayload()
        for field in fields {
            apply(text: field.text, role: field.role, primaryLanguage: primaryLanguage, to: &result)
        }
        if let chosen = EmbeddedLyricsVariantPolicy.preferred(
            in: result.lyricsVariants, priority: EmbeddedLyricsVariantPriority.current()
        ) {
            result.lyrics = chosen.text
            result.lyricsLanguageCode = chosen.languageCode ?? primaryLanguage
        }
        return result.isEmpty ? nil : result
    }

    /// The iTunes-style `©lyr` and `©grp` items as the file itself stores them.
    public struct StoredITunesTextItems: Equatable, Sendable {
        public var lyrics: String?
        public var grouping: String?
        /// A `©lyr` item is present but its data atom could not be decoded, so
        /// `lyrics == nil` does not mean the file has no lyrics to lose.
        public var hasUndecodableLyrics: Bool

        public init(
            lyrics: String? = nil,
            grouping: String? = nil,
            hasUndecodableLyrics: Bool = false
        ) {
            self.lyrics = lyrics
            self.grouping = grouping
            self.hasUndecodableLyrics = hasUndecodableLyrics
        }
    }

    /// Reads `©lyr` and `©grp` independently of the tagging library.
    ///
    /// SFBAudioEngine 0.12.1 loaded the grouping item into its lyrics field
    /// and never into its grouping field, so writing that model back replaced
    /// the file's lyrics with the grouping text and deleted the grouping. The
    /// embedded tag writer still restores both from this reading before it
    /// saves.
    public static func storedITunesTextItems(in data: Data) -> StoredITunesTextItems {
        var result = StoredITunesTextItems()
        var sawLyricsItem = false
        for moov in atoms(in: data, range: data.startIndex..<data.endIndex)
            where moov.type == AtomType.moov {
            for metadata in metadataAtoms(in: data, moov: moov) {
                guard metadata.payload.count >= 4 else { continue }
                let childrenRange =
                    (metadata.payload.lowerBound + 4)..<metadata.payload.upperBound
                for list in atoms(in: data, range: childrenRange)
                    where list.type == AtomType.ilst {
                    for item in atoms(in: data, range: list.payload) {
                        switch item.type {
                        case AtomType.iTunesLyrics:
                            sawLyricsItem = true
                            result.lyrics = result.lyrics ?? decodedItem(in: data, item: item)
                        case AtomType.iTunesGrouping:
                            result.grouping = result.grouping ?? decodedItem(in: data, item: item)
                        default:
                            break
                        }
                    }
                }
            }
        }
        result.hasUndecodableLyrics = sawLyricsItem && result.lyrics == nil
        return result
    }

    /// Rewrites individual data children so multilingual/freeform siblings and their names
    /// survive. When the movie header grows before media, media offsets stay at their original positions.
    public static func editingOriginals(in data: Data, _ operation: EmbeddedLyricsFieldEditor.Operation) -> EmbeddedLyricsFieldEditor.FileEdit? {
        typealias Editor = EmbeddedLyricsFieldEditor
        let corrupt = CocoaError(.fileReadCorruptFile)
        func children(_ bounds: Range<Int>) throws -> [Atom] {
            let list = atoms(in: data, range: bounds)
            guard bounds.isEmpty || list.last?.payload.upperBound == bounds.upperBound else { throw corrupt }
            return list
        }
        func uint32(_ n: UInt32) -> Data {
            Data([UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        }
        func box(_ type: UInt32, _ body: Data) throws -> Data {
            guard let size = UInt32(exactly: body.count + 8) else { throw corrupt }
            return uint32(size) + uint32(type) + body
        }
        do {
            let top = try children(data.startIndex..<data.endIndex)
            let movies = top.filter { $0.type == AtomType.moov }
            guard movies.count == 1, let movie = movies.first,
                  !top.contains(where: { $0.type == 0x6d6f6f66 }) else { return nil } // moof
            let movieChildren = try children(movie.payload)
            guard !movieChildren.contains(where: { [0x636d6f76, 0x6d766578].contains($0.type) }) else { return nil } // cmov, mvex
            var fields: [Editor.Field] = []
            var dataAtoms: [Atom] = []
            var valueItem: [Int: Atom] = [:]
            var additions: [Int: Data] = [:]
            var paths: [Int: [Atom]] = [movie.start: movieChildren]
            var defaultList: Atom?
            var metadata = movieChildren.filter { $0.type == AtomType.meta }
            for userData in movieChildren where userData.type == AtomType.udta {
                let nested = try children(userData.payload)
                paths[userData.start] = nested
                metadata.append(contentsOf: nested.filter { $0.type == AtomType.meta })
            }
            for meta in metadata {
                guard meta.payload.count >= 4 else { return nil }
                let metaChildren = try children((meta.payload.lowerBound + 4)..<meta.payload.upperBound)
                paths[meta.start] = metaChildren
                let keyTable = metaChildren.first { $0.type == AtomType.keys }
                let keys = keyTable.map { metadataKeys(in: data, atom: $0) } ?? [:]
                for list in metaChildren where list.type == AtomType.ilst {
                    let items = try children(list.payload)
                    paths[list.start] = items
                    if keyTable == nil, defaultList == nil { defaultList = list }
                    for item in items {
                        let role: LyricFieldRole?
                        switch item.type {
                        case AtomType.iTunesLyrics: role = .original(languageCode: nil)
                        case AtomType.freeform: role = freeformName(in: data, item: item).flatMap(lyricFieldRole)
                        default: role = keys[item.type].flatMap(lyricFieldRole)
                        }
                        guard case .original(let code) = role else { continue }
                        let components = try children(item.payload)
                        paths[item.start] = components
                        for child in components where child.type == AtomType.data {
                            guard let text = decodedDataAtom(child, in: data) else { return nil }
                            fields.append(Editor.Field(text: text, language: code))
                            dataAtoms.append(child)
                            valueItem[child.start] = item
                        }
                    }
                }
            }
            guard let plan = Editor.targets(fields, operation: operation, prefersUntagged: true) else { return nil }
            var changed: [Int: Data] = [:]
            switch operation {
            case .replace(let text, _):
                guard !Editor.normalizedText(text).isEmpty else { return nil }
                if plan.indices.isEmpty {
                    let encoded = try box(AtomType.iTunesLyrics, box(AtomType.data, uint32(1) + uint32(0) + Data(text.utf8)))
                    if let list = defaultList {
                        additions[list.start] = encoded
                    } else {
                        // A numeric mdta ilst cannot carry an iTunes key. Add a standard mdir metadata box.
                        let handler = try box(0x68646c72, Data(count: 8) + Data("mdirappl".utf8) + Data(count: 9))
                        let meta = try box(AtomType.meta, Data(count: 4) + handler + box(AtomType.ilst, encoded))
                        if let udta = movieChildren.first(where: { $0.type == AtomType.udta }) {
                            additions[udta.start] = meta
                        } else {
                            additions[movie.start] = try box(AtomType.udta, meta)
                        }
                    }
                }
                for i in plan.indices {
                    let child = dataAtoms[i]
                    var header = Data(data[child.payload.prefix(8)])
                    header.replaceSubrange(1..<4, with: [0, 0, 1]) // UTF-8; preserve locale
                    changed[child.start] = try box(AtomType.data, header + Data(text.utf8))
                }
            case .removeOne, .removeAllOriginals:
                if plan.indices.isEmpty { return Editor.FileEdit(data: data, result: plan.result) }
                for i in plan.indices { changed[dataAtoms[i].start] = Data() }
                for i in plan.indices {
                    let child = dataAtoms[i]
                    guard let item = valueItem[child.start], let parts = paths[item.start] else { return nil }
                    let keep = parts.contains { part in
                        if part.type == AtomType.data { return changed[part.start] == nil }
                        return part.type != AtomType.name && part.type != 0x6d65616e
                    }
                    if !keep { changed[item.start] = Data() }
                }
            }
            // Only rebuild an ancestor of a changed atom. Every other box, including custom
            // children and extended-size headers, is copied byte-for-byte.
            func rewritten(_ atom: Atom) throws -> Data? {
                if let value = changed[atom.start] { return value }
                guard let nested = paths[atom.start] else { return nil }
                var body = Data()
                var position = atom.payload.lowerBound
                var dirty = false
                for child in nested {
                    if let next = try rewritten(child) {
                        body.append(data[position..<child.start])
                        body.append(next)
                        position = child.payload.upperBound
                        dirty = true
                    }
                }
                guard dirty || additions[atom.start] != nil else { return nil }
                body.append(data[position..<atom.payload.upperBound])
                if let added = additions[atom.start] { body.append(added) }
                return try box(atom.type, body)
            }
            guard let edited = try rewritten(movie) else { return nil }
            let end = movie.payload.upperBound
            var output: Data
            if edited.count == end - movie.start || end == data.endIndex {
                output = Data(data[..<movie.start]) + edited
                output.append(data[end...])
            } else {
                let followingFree = top.first {
                    $0.start == end && $0.type == 0x66726565 && data[$0.payload].allSatisfy { $0 == 0 }
                }
                let reservedEnd = followingFree?.payload.upperBound ?? end
                let slack = reservedEnd - movie.start - edited.count
                if slack == 0 || (8...Int(UInt32.max)).contains(slack) {
                    output = Data(data[..<movie.start]) + edited
                    if slack > 0 { output.append(try box(0x66726565, Data(count: slack - 8))) }
                    output.append(data[reservedEnd...])
                } else {
                    guard let last = top.last, readUInt32BE(data, at: last.start) != 0 else { return nil }
                    output = data
                    output.replaceSubrange((movie.start + 4)..<(movie.start + 8), with: "free".utf8)
                    output.resetBytes(in: movie.payload)
                    output.append(edited)
                }
            }
            return Editor.FileEdit(data: output, result: plan.result)
        } catch { return nil }
    }

    public struct ReplayGainTags: Equatable, Sendable {
        public var trackGain: Double?
        public var trackPeak: Double?
        public var albumGain: Double?
        public var albumPeak: Double?

        public init(
            trackGain: Double? = nil,
            trackPeak: Double? = nil,
            albumGain: Double? = nil,
            albumPeak: Double? = nil
        ) {
            self.trackGain = trackGain
            self.trackPeak = trackPeak
            self.albumGain = albumGain
            self.albumPeak = albumPeak
        }

        public var isEmpty: Bool {
            trackGain == nil && trackPeak == nil && albumGain == nil && albumPeak == nil
        }
    }

    /// Reads ReplayGain from iTunes freeform items
    /// (`----:com.apple.iTunes:replaygain_track_gain`, as foobar2000, rsgain,
    /// Mp3tag and Picard write it) and from `mdta` keys.
    ///
    /// AVFoundation only surfaces the ID3 form of these tags, and the TagLib
    /// fallback needs a whole local file, so a scan that reads a remote file's
    /// head and tail would otherwise never see an M4A file's ReplayGain.
    public static func replayGainTags(in data: Data) -> ReplayGainTags? {
        guard !data.isEmpty else { return nil }
        var result = ReplayGainTags()
        for moov in atoms(in: data, range: data.startIndex..<data.endIndex)
            where moov.type == AtomType.moov {
            for metadata in metadataAtoms(in: data, moov: moov) {
                guard metadata.payload.count >= 4 else { continue }
                let childrenRange =
                    (metadata.payload.lowerBound + 4)..<metadata.payload.upperBound
                let children = atoms(in: data, range: childrenRange)
                let keys = children.first(where: { $0.type == AtomType.keys })
                    .map { metadataKeys(in: data, atom: $0) } ?? [:]
                for list in children where list.type == AtomType.ilst {
                    for item in atoms(in: data, range: list.payload) {
                        let name = item.type == AtomType.freeform
                            ? freeformName(in: data, item: item)
                            : keys[item.type]
                        guard let name,
                              let field = ReplayGainField(itemName: name),
                              let text = decodedItem(in: data, item: item),
                              let value = replayGainNumber(text) else { continue }
                        switch field {
                        case .trackGain:
                            result.trackGain = result.trackGain ?? value
                        case .trackPeak:
                            result.trackPeak = result.trackPeak ?? value
                        case .albumGain:
                            result.albumGain = result.albumGain ?? value
                        case .albumPeak:
                            result.albumPeak = result.albumPeak ?? value
                        }
                    }
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    private enum ReplayGainField: CaseIterable {
        case trackGain, trackPeak, albumGain, albumPeak

        var tagName: String {
            switch self {
            case .trackGain: "replaygain_track_gain"
            case .trackPeak: "replaygain_track_peak"
            case .albumGain: "replaygain_album_gain"
            case .albumPeak: "replaygain_album_peak"
            }
        }

        /// The bare tag name, or one qualified by a namespace such as
        /// `com.apple.quicktime.` in an `mdta` key. Writers disagree on case.
        init?(itemName: String) {
            let normalized = itemName.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let field = Self.allCases.first(where: { field in
                normalized == field.tagName
                    || [".", ":", "/"].contains { normalized.hasSuffix($0 + field.tagName) }
            }) else { return nil }
            self = field
        }
    }

    /// "-7.43 dB", "+3.21 dB", "-7.43" or a bare peak such as "0.988". A
    /// non-finite value is no value: it would otherwise read as a tag.
    private static func replayGainNumber(_ text: String) -> Double? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "db", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    private struct Atom {
        let start: Int
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
        static let iTunesGrouping: UInt32 = 0xA9677270

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

    private static func lyricFields(in data: Data, metadata: Atom) -> [(text: String, role: LyricFieldRole)] {
        guard metadata.payload.count >= 4 else { return [] }
        let childrenRange = (metadata.payload.lowerBound + 4)..<metadata.payload.upperBound
        let children = atoms(in: data, range: childrenRange)
        let keys = children.first(where: { $0.type == AtomType.keys })
            .map { metadataKeys(in: data, atom: $0) } ?? [:]
        var fields: [(text: String, role: LyricFieldRole)] = []

        for list in children where list.type == AtomType.ilst {
            for item in atoms(in: data, range: list.payload) {
                let role: LyricFieldRole?
                switch item.type {
                case AtomType.iTunesLyrics: role = .original(languageCode: nil)
                case AtomType.freeform: role = freeformName(in: data, item: item).flatMap(lyricFieldRole)
                default: role = keys[item.type].flatMap(lyricFieldRole)
                }
                guard let role else { continue }
                for child in atoms(in: data, range: item.payload) {
                    if let text = decodedDataAtom(child, in: data) { fields.append((text, role)) }
                }
            }
        }
        return fields
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
        for child in atoms(in: data, range: item.payload) {
            if let text = decodedDataAtom(child, in: data) { return text }
        }
        return nil
    }

    private static func decodedDataAtom(_ child: Atom, in data: Data) -> String? {
        guard child.type == AtomType.data, child.payload.count >= 8,
              let declaredType = readUInt32BE(data, at: child.payload.lowerBound) else { return nil }
        let value = data.subdata(in: (child.payload.lowerBound + 8)..<child.payload.upperBound)
        return decode(value, declaredType: declaredType & 0x00FF_FFFF)
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

    enum LyricFieldRole {
        case original(languageCode: String?)
        case translation(languageCode: String?)
    }

    private static func apply(
        text: String,
        role: LyricFieldRole,
        primaryLanguage: String?,
        to payload: inout LyricsPayload
    ) {
        switch role {
        case .original(let languageCode):
            if let languageCode {
                payload.languageTaggedLyrics[languageCode] = text
            }
            if languageCode == nil || languageCode == primaryLanguage {
                EmbeddedLyricsVariantPolicy.append(text, languageCode: languageCode, to: &payload.lyricsVariants)
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

    static func lyricFieldRole(_ value: String) -> LyricFieldRole? {
        lyricFieldRole(value, allowsNamespace: true)
    }

    static func id3UserTextRole(_ value: String) -> LyricFieldRole? {
        lyricFieldRole(value, allowsNamespace: false)
    }

    private static func lyricFieldRole(_ value: String, allowsNamespace: Bool) -> LyricFieldRole? {
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

        if let languageCode = matchedLyricKey(normalized, roots: translatedRoots, allowsNamespace: allowsNamespace) {
            return .translation(languageCode: languageCode)
        }
        if let languageCode = matchedLyricKey(normalized, roots: originalRoots, allowsNamespace: allowsNamespace) {
            return .original(languageCode: languageCode)
        }
        return nil
    }

    /// A nil outer optional means no lyric key matched. A non-nil outer
    /// optional with a nil language is an untagged lyric key.
    private static func matchedLyricKey(
        _ key: String,
        roots: [String],
        allowsNamespace: Bool
    ) -> String?? {
        for root in roots.sorted(by: { $0.count > $1.count }) {
            guard let range = key.range(of: root) else { continue }
            let prefix = key[..<range.lowerBound]
            guard prefix.isEmpty || (allowsNamespace && prefix.last.map({ ".:/_- ".contains($0) }) == true) else {
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
            result.append(Atom(start: cursor, type: type, payload: (cursor + headerLength)..<end))
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
