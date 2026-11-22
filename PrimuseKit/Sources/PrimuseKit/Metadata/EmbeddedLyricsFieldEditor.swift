import Foundation

/// 只改音频文件里「某一份」原文歌词所在的字段：换成新内容，或者只删掉这一个字段；清空时删掉全部原文字段。
/// 其余语言的译文字段和别的标签原样不动。
///
/// 一个文件里常有好几份原文（FLAC 的 `LYRICS` 与 `SYNCEDLYRICS` 并存、ID3 里好几帧 `USLT`），
/// 读标签时按设置挑一份显示。整块改写歌词只会换掉默认字段，用户刚改过的那份还留在别的字段里，
/// 重读标签后可能又被挑回来。这里按内容找到用户正在用的那一份，只改它所在的字段。
///
/// 这里直接改写用户的音频文件，所以只认「规整后全文完全相同」：两份歌词只要逐字时间、译文行、
/// 时间戳写法有一点不同就算不同的字段。定位不准时一律不改（返回 nil），由调用方退回或改为只在 Primuse 里处理。
public enum EmbeddedLyricsFieldEditor {
    /// 这次要做的改动。
    public enum Operation: Equatable, Sendable {
        /// 把正在用的那一份（`anchor`，文件里的原文）换成 `text`。`anchor` 为 nil 表示不知道是哪一份：
        /// 文件里只有一份原文时就换它，否则只在没有默认字段时补一个默认字段。
        case replace(text: String, anchor: String?)
        /// 只删掉内容完全相同的那一份。nil 表示删文件里唯一的那份原文（不止一份时不动）。
        case removeOne(String?)
        /// 删掉全部原文字段，译文字段保留。
        case removeAllOriginals
    }

    /// 实际做了什么。
    public enum Result: Equatable, Sendable {
        /// 换掉了正在用的那一份所在的字段。
        case replacedField
        /// 认不出正在用的是哪一份，只在原来没有默认字段的位置补了一个；别的原文都没动。
        case wroteDefaultField
        /// 删掉了内容完全相同的那一份。
        case removedField
        /// 删掉了这么多个原文字段。
        case removedOriginals(Int)
    }

    // MARK: - 对应

    /// 规整：统一换行，去掉首尾空白、NUL 和 BOM。
    public static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0\u{FEFF}"))
            )
    }

    /// 规整后全文完全相同才算同一份。空文本不和任何东西相同。
    public static func sameLyrics(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedText(lhs)
        return !left.isEmpty && left == normalizedText(rhs)
    }

    // MARK: - FLAC（只处理元数据块区域）

    /// 元数据区域里各份原文歌词，按在文件里的先后。认不出结构时为 nil。
    public static func flacOriginalLyrics(in region: Data) -> [String]? {
        guard let layout = FLACCommentLayout(Data(region)) else { return nil }
        return layout.originalIndices.compactMap { layout.decoded[$0] }
    }

    public struct FLACEdit: Equatable, Sendable {
        /// 改好的整个元数据区域；音频数据由调用方原样接在后面。
        public let region: Data
        public let result: Result
    }

    /// 在元数据区域里改歌词字段。定位不准或认不出结构时为 nil，什么都不改。
    public static func editFLAC(region: Data, _ operation: Operation) -> FLACEdit? {
        guard let layout = FLACCommentLayout(Data(region)) else { return nil }
        var items = layout.items
        let originals = layout.originalIndices
        switch operation {
        case .replace(let text, let anchor):
            let value = Data(text.utf8)
            var targets = anchor.map { anchor in originals.filter { layout.matches($0, anchor) } } ?? []
            if targets.isEmpty, anchor == nil, originals.count == 1 {
                targets = originals
            }
            if let first = targets.first {
                for index in targets {
                    items[index] = layout.keyBytes(index) + Data([0x3D]) + value
                }
                // 换上的这一份挪到所有原文字段前面：同一档的几份按文件先后挑，读回来选中的就是它。
                if let firstOriginal = originals.first, firstOriginal < first {
                    let moved = items.remove(at: first)
                    items.insert(moved, at: firstOriginal)
                }
                return layout.rebuilt(with: items).map { FLACEdit(region: $0, result: .replacedField) }
            }
            // 认不出正在用的是哪一份：只在没有默认字段时补一个，绝不覆盖别的版本。
            guard anchor == nil, !layout.keys.contains(where: { $0?.uppercased() == "LYRICS" }) else { return nil }
            let field = Data("LYRICS=".utf8) + value
            items.insert(field, at: originals.first ?? items.count)
            return layout.rebuilt(with: items).map { FLACEdit(region: $0, result: .wroteDefaultField) }
        case .removeOne(let text):
            let targets = text.map { text in originals.filter { layout.matches($0, text) } }
                ?? (originals.count == 1 ? originals : [])
            guard !targets.isEmpty else { return nil }
            for index in targets.reversed() { items.remove(at: index) }
            return layout.rebuilt(with: items).map { FLACEdit(region: $0, result: .removedField) }
        case .removeAllOriginals:
            for index in originals.reversed() { items.remove(at: index) }
            return layout.rebuilt(with: items).map {
                FLACEdit(region: $0, result: .removedOriginals(originals.count))
            }
        }
    }

    /// 改写前后对一遍（和改写逻辑分开写）：别的元数据块逐字节相同、顺序不变；厂商串相同；
    /// 不是原文歌词的字段（含译文）键和值完全相同、顺序不变；原文字段只按这次的操作变化。
    public static func verifyFLAC(
        original: Data,
        edited: Data,
        _ operation: Operation,
        result: Result
    ) -> Bool {
        guard let before = FLACCommentLayout(Data(original)),
              let after = FLACCommentLayout(Data(edited)),
              before.otherBlocks == after.otherBlocks,
              before.vendor == after.vendor,
              before.nonLyricItems == after.nonLyricItems else { return false }
        let old = before.originalFields
        let new = after.originalFields
        switch (operation, result) {
        case (.replace(let text, _), .replacedField):
            // 数量不变；新出现的只能是新内容，消失的只能是同一份旧内容，两边一样多。
            guard old.count == new.count else { return false }
            let added = difference(new, old)
            let removed = difference(old, new)
            return added.count == removed.count
                && added.allSatisfy { $0.value == normalizedText(text) }
                && Set(removed.map(\.value)).count <= 1
        case (.replace(let text, _), .wroteDefaultField):
            let added = difference(new, old)
            return difference(old, new).isEmpty
                && added.count == 1
                && added[0].key == "LYRICS"
                && added[0].value == normalizedText(text)
        case (.removeOne(let text), .removedField):
            guard let text else { return old.count == 1 && new.isEmpty }
            let target = normalizedText(text)
            let kept = old.filter { $0.value != target }
            return kept.count < old.count
                && new.count == kept.count
                && zip(new, kept).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.removeAllOriginals, .removedOriginals(let count)):
            return new.isEmpty && old.count == count
        default:
            return false
        }
    }

    // MARK: - ID3（USLT 帧体）

    /// 一帧 `USLT` 帧体（编码字节、三字节语言、描述、正文）里的正文。
    public static func usltText(_ body: Data) -> String? {
        guard let parts = usltParts(body) else { return nil }
        return parts.text
    }

    /// 明确标成译文的那一帧（描述是 translation / translated lyrics 之类）：清空和替换都不动它。
    public static func isTranslationUSLT(_ body: Data) -> Bool {
        guard let parts = usltParts(body) else { return false }
        if case .translation = ISOBaseMediaLyricsParser.id3UserTextRole(parts.descriptor) { return true }
        return false
    }

    /// 换掉这一帧的正文，语言和描述照旧。统一写成带 BOM 的 UTF-16，ID3v2.3 和 2.4 都认。
    public static func usltBody(replacingTextOf body: Data, with text: String) -> Data? {
        guard let parts = usltParts(body) else { return nil }
        return makeUSLTBody(language: parts.language, descriptor: parts.descriptor, text: text)
    }

    public struct USLTEdit: Equatable, Sendable {
        public let bodies: [Data]
        public let result: Result
    }

    /// 在这些 `USLT` 帧体里改歌词。定位不准时为 nil，什么都不改。
    public static func editUSLT(bodies: [Data], _ operation: Operation) -> USLTEdit? {
        let originals = bodies.indices.filter {
            guard let parts = usltParts(bodies[$0]) else { return false }
            switch ISOBaseMediaLyricsParser.id3UserTextRole(parts.descriptor) {
            case .translation, .romanization: return false
            default: return true
            }
        }
        func matches(_ index: Int, _ text: String) -> Bool {
            guard let decoded = usltText(bodies[index]) else { return false }
            if sameLyrics(decoded, text) { return true }
            // 按 Latin-1 存的 GBK / Big5：读标签时还原过，这里用同一个还原再比一次（仍是全文完全相同）。
            if let repaired = TextEncodingRepair.repaired(decoded) { return sameLyrics(repaired, text) }
            return false
        }
        var result = bodies
        switch operation {
        case .replace(let text, let anchor):
            var targets = anchor.map { anchor in originals.filter { matches($0, anchor) } } ?? []
            if targets.isEmpty, anchor == nil, originals.count == 1 {
                targets = originals
            }
            if let first = targets.first {
                for index in targets {
                    guard let body = usltBody(replacingTextOf: bodies[index], with: text) else { return nil }
                    result[index] = body
                }
                if first > 0 {
                    let moved = result.remove(at: first)
                    result.insert(moved, at: 0)
                }
                return USLTEdit(bodies: result, result: .replacedField)
            }
            // 认不出是哪一份：补一帧没写语言、没有描述的默认帧放在最前面；已经有这样一帧就不动。
            let occupied = bodies.contains { body in
                guard let parts = usltParts(body) else { return true }
                return parts.descriptor.isEmpty && isUndeterminedLanguage(parts.language)
            }
            guard !occupied else { return nil }
            result.insert(makeUSLTBody(language: Data("und".utf8), descriptor: "", text: text), at: 0)
            return USLTEdit(bodies: result, result: .wroteDefaultField)
        case .removeOne(let text):
            let targets = text.map { text in originals.filter { matches($0, text) } }
                ?? (originals.count == 1 ? originals : [])
            guard !targets.isEmpty else { return nil }
            for index in targets.reversed() { result.remove(at: index) }
            return USLTEdit(bodies: result, result: .removedField)
        case .removeAllOriginals:
            for index in originals.reversed() { result.remove(at: index) }
            return USLTEdit(bodies: result, result: .removedOriginals(originals.count))
        }
    }

    /// ID3v2.3 / 2.4 标签（不带整体反同步、扩展头、尾部）里除 `USLT` 以外的每一帧（帧头加内容）
    /// 和音频数据的起点。别的形状不认，为 nil。
    public static func id3Layout(_ data: Data) -> (otherFrames: [Data], audioOffset: Int)? {
        let data = Data(data)
        guard let layout = checkedID3Frames(data) else { return nil }
        let other = layout.frames.compactMap { frame -> Data? in
            data[frame.prefix(4)].elementsEqual("USLT".utf8) ? nil : data.subdata(in: frame)
        }
        return (other, layout.audioOffset)
    }

    private static func checkedID3Frames(_ data: Data) -> (frames: [Range<Int>], audioOffset: Int)? {
        guard data.count >= 10,
              data.starts(with: Array("ID3".utf8)),
              data[3] == 3 || data[3] == 4,
              data[5] & 0xD0 == 0,
              (6..<10).allSatisfy({ data[$0] < 0x80 }) else { return nil }
        let version = data[3]
        let size = Int(data[6]) << 21 | Int(data[7]) << 14 | Int(data[8]) << 7 | Int(data[9])
        let end = 10 + size
        guard end <= data.count else { return nil }
        var frames: [Range<Int>] = []
        var cursor = 10
        while cursor + 10 <= end {
            if data[cursor] == 0 { break }
            let idBytes = data.subdata(in: cursor..<(cursor + 4))
            guard idBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }) else {
                return nil
            }
            let sizeBytes = data.subdata(in: (cursor + 4)..<(cursor + 8))
            let frameSize: Int
            if version == 4 {
                guard sizeBytes.allSatisfy({ $0 < 0x80 }) else { return nil }
                frameSize = Int(sizeBytes[0]) << 21 | Int(sizeBytes[1]) << 14 | Int(sizeBytes[2]) << 7 | Int(sizeBytes[3])
            } else {
                frameSize = Int(sizeBytes[0]) << 24 | Int(sizeBytes[1]) << 16 | Int(sizeBytes[2]) << 8 | Int(sizeBytes[3])
            }
            let frameEnd = cursor + 10 + frameSize
            guard frameSize > 0, frameEnd <= end else { return nil }
            frames.append(cursor..<frameEnd)
            cursor = frameEnd
        }
        guard data.subdata(in: cursor..<end).allSatisfy({ $0 == 0 }) else { return nil }
        return (frames, end)
    }

    /// 改写前后对一遍：别的帧逐字节相同、顺序不变；`USLT` 正好是计划里的那几帧；音频数据逐字节相同。
    public static func verifyID3(original: Data, edited: Data, expectedBodies: [Data]) -> Bool {
        guard let before = id3Layout(original),
              let after = id3Layout(edited),
              before.otherFrames == after.otherFrames,
              ID3LyricsFramePreservation.lyricsFrameBodies(in: edited) == expectedBodies,
              original.count - before.audioOffset == edited.count - after.audioOffset else { return false }
        return original.subdata(in: before.audioOffset..<original.count)
            == edited.subdata(in: after.audioOffset..<edited.count)
    }

    struct Field {
        let text: String
        let language: String?
    }

    /// Applies the same identity rule to all lyric fields in a container, including
    /// copies of one version in several fields. A stale explicit anchor never inserts a copy.
    static func targets(_ fields: [Field], operation: Operation, prefersUntagged: Bool = false) -> (indices: [Int], result: Result)? {
        var primary = fields.compactMap(\.language).first
        if prefersUntagged, let untagged = fields.first(where: { $0.language == nil }) {
            primary = fields.first { $0.language != nil && sameLyrics($0.text, untagged.text) }?.language
        }
        let originals = fields.indices.filter { fields[$0].language == nil || fields[$0].language == primary }
        func matches(_ text: String?) -> [Int] {
            guard let text else { return originals.count == 1 ? originals : [] }
            let all = fields.indices.filter { index in
                let source = fields[index].text
                return sameLyrics(source, text) || TextEncodingRepair.repaired(source).map { sameLyrics($0, text) } == true
            }
            let inPrimary = all.filter(originals.contains)
            if !inPrimary.isEmpty { return inPrimary }
            return Set(all.map { fields[$0].language }).count == 1 ? all : []
        }
        switch operation {
        case .replace(_, let anchor):
            let found = matches(anchor)
            if !found.isEmpty { return (found, .replacedField) }
            return fields.isEmpty && anchor == nil ? ([], .wroteDefaultField) : nil
        case .removeOne(let anchor):
            let found = matches(anchor)
            return found.isEmpty ? nil : (found, .removedField)
        case .removeAllOriginals:
            return (originals, .removedOriginals(originals.count))
        }
    }

    public struct FileEdit: Sendable {
        public let data: Data
        public let result: Result
    }

    /// Resolves an original against all the physical lyric fields, keeping companions and opaque media bytes intact.
    public static func editID3(_ data: Data, _ operation: Operation) -> FileEdit? {
        guard data.startIndex == 0 else { return nil }
        let tagged: Data
        if data.starts(with: "ID3".utf8) { tagged = data }
        else {
            guard consistsOfMPEGAudioFrames(data) else { return nil }
            tagged = Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0]) + data
        }
        guard let rows = try? EmbeddedLyricsArchive.originalID3Entries(in: tagged),
              let plan = targets(rows.map { Field(text: $0.entry.text, language: $0.entry.languageCode) }, operation: operation) else { return nil }
        do {
            var edits: [String: String?] = [:]
            switch operation {
            case .replace(let text, _):
                guard !normalizedText(text).isEmpty else { return nil }
                if plan.indices.isEmpty {
                    let name = tagged[3] == 2 ? "ULT" : "USLT"
                    let body = makeUSLTBody(language: Data("und".utf8), descriptor: "", text: text)
                    let result = try OrderedTagContainer.replacing(in: tagged, format: .mp3, replacements: [:],
                                                                   appending: [.init(ordinal: 0, key: name, payload: body)])
                    return FileEdit(data: result, result: plan.result)
                }
                for index in plan.indices { edits[rows[index].entry.id] = text }
            case .removeOne, .removeAllOriginals:
                if plan.indices.isEmpty { return FileEdit(data: data, result: plan.result) }
                for index in plan.indices { edits.updateValue(nil, forKey: rows[index].entry.id) }
            }
            var result = try EmbeddedLyricsArchive.replacing(in: tagged, fileExtension: "mp3", edits: edits)
            if case .replace = operation, let first = rows.first, let target = plan.indices.first {
                result = try OrderedTagContainer.promotingID3Frame(in: result, from: rows[target].ordinal, before: first.ordinal)
            }
            return FileEdit(data: result, result: plan.result)
        } catch { return nil }
    }

    private static func consistsOfMPEGAudioFrames(_ data: Data) -> Bool {
        guard let first = MPEGAudioStreamParser.header(in: data, at: 0) else { return false }
        var offset = first.frameLength
        guard offset < data.count else { return false }
        while offset < data.count {
            guard let frame = MPEGAudioStreamParser.header(in: data, at: offset),
                  frame.versionBits == first.versionBits, frame.sampleRate == first.sampleRate,
                  frame.frameLength <= data.count - offset else { return false }
            offset += frame.frameLength
        }
        return true
    }

    static func synchronizedBody(
        _ text: String, language: Data, descriptor: String, contentType: UInt8,
        equivalent: (String, String) -> Bool = sameLyrics
    ) -> Data? {
        let lines = LyricsContentParser.parseText(text)
        guard !lines.isEmpty, lines.allSatisfy(\.isSynchronized) else { return nil }
        var body = Data([1]) + language + Data([2, contentType]) + utf16WithByteOrderMark(descriptor) + Data([0, 0])
        for (lineIndex, line) in lines.enumerated() {
            let cues = line.syllables?.map { ($0.text, $0.start) } ?? [(line.text, line.timestamp)]
            for (cueIndex, cue) in cues.enumerated() {
                let time = (cue.1 * 1000).rounded()
                guard time.isFinite, time >= 0, time <= Double(UInt32.max) else { return nil }
                let value = UInt32(time)
                let prefix = lineIndex > 0 && cueIndex == 0 ? "\n" : ""
                body.append(utf16WithByteOrderMark(prefix + cue.0))
                body.append(contentsOf: [0, 0, UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                                         UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
            }
        }
        guard let rendered = ID3SynchronizedLyricsParser.parse(body), equivalent(text, rendered.text) else { return nil }
        return body
    }

    // MARK: - 工具

    private static func difference(
        _ lhs: [(key: String, value: String)],
        _ rhs: [(key: String, value: String)]
    ) -> [(key: String, value: String)] {
        var remaining = rhs
        var result: [(key: String, value: String)] = []
        for item in lhs {
            if let index = remaining.firstIndex(where: { $0.key == item.key && $0.value == item.value }) {
                remaining.remove(at: index)
            } else {
                result.append(item)
            }
        }
        return result
    }

    private static func isUndeterminedLanguage(_ language: Data) -> Bool {
        let code = String(data: language, encoding: .isoLatin1)?.lowercased() ?? ""
        return code == "und" || code == "xxx" || code.allSatisfy { $0 == "\0" || $0 == " " }
    }

    private static func usltParts(_ body: Data) -> (language: Data, descriptor: String, text: String)? {
        let body = Data(body)
        guard body.count >= 5 else { return nil }
        let encoding = body[0]
        let language = body.subdata(in: 1..<4)
        let rest = body.subdata(in: 4..<body.count)
        guard let ranges = descriptorAndTextRanges(rest, encoding: encoding),
              let text = decodedID3Text(rest.subdata(in: ranges.text), encoding: encoding) else { return nil }
        let descriptor = decodedID3Text(rest.subdata(in: ranges.descriptor), encoding: encoding) ?? ""
        return (language, descriptor, text)
    }

    struct USLTIdentity: Hashable {
        let language: Data
        let descriptor: String
    }

    static func usltIdentity(_ body: Data) -> USLTIdentity? {
        usltParts(body).map { USLTIdentity(language: $0.language, descriptor: $0.descriptor) }
    }

    static func makeUSLTConvertingSYLT(language: Data, descriptor: String, text: String, occupied: inout Set<USLTIdentity>) -> Data {
        var label = descriptor
        var suffix = 1
        while !occupied.insert(USLTIdentity(language: language, descriptor: label)).inserted {
            label = descriptor + " (SYLT " + String(suffix) + ")"
            suffix += 1
        }
        return makeUSLTBody(language: language, descriptor: label, text: text)
    }

    private static func makeUSLTBody(language: Data, descriptor: String, text: String) -> Data {
        var result = Data([0x01])
        result.append(language.count == 3 ? language : Data("und".utf8))
        result.append(utf16WithByteOrderMark(descriptor))
        result.append(contentsOf: [0x00, 0x00])
        result.append(utf16WithByteOrderMark(text))
        return result
    }

    private static func descriptorAndTextRanges(
        _ rest: Data,
        encoding: UInt8
    ) -> (descriptor: Range<Int>, text: Range<Int>)? {
        switch encoding {
        case 1, 2:
            var index = 0
            while index + 1 < rest.count {
                if rest[index] == 0, rest[index + 1] == 0 {
                    return (0..<index, (index + 2)..<rest.count)
                }
                index += 2
            }
            return nil
        case 0, 3:
            guard let zero = rest.firstIndex(of: 0) else { return nil }
            return (0..<zero, (zero + 1)..<rest.count)
        default:
            return nil
        }
    }

    private static func decodedID3Text(_ data: Data, encoding: UInt8) -> String? {
        let text: String?
        switch encoding {
        case 0:
            text = String(data: data, encoding: .isoLatin1)
        case 1:
            if data.starts(with: [0xFF, 0xFE]) {
                text = String(data: data.subdata(in: 2..<data.count), encoding: .utf16LittleEndian)
            } else if data.starts(with: [0xFE, 0xFF]) {
                text = String(data: data.subdata(in: 2..<data.count), encoding: .utf16BigEndian)
            } else {
                text = String(data: data, encoding: .utf16LittleEndian)
            }
        case 2:
            text = String(data: data, encoding: .utf16BigEndian)
        case 3:
            text = String(data: data, encoding: .utf8)
        default:
            text = nil
        }
        return text.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
    }

    private static func utf16WithByteOrderMark(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 {
            data.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)])
        }
        return data
    }
}

/// FLAC 元数据区域里的 VORBIS_COMMENT 块，按字段原样拆开，改完再按原来的块位置拼回去。
private struct FLACCommentLayout {
    let data: Data
    let blockHeaderOffset: Int
    let payloadRange: Range<Int>
    /// 厂商长度加厂商字符串，原样保留。
    let vendor: Data
    let items: [Data]
    let keys: [String?]
    let decoded: [String?]
    /// 除 VORBIS_COMMENT 以外的每个块：块类型和内容（不含「最后一块」标志）。
    let otherBlocks: [Data]

    init?(_ data: Data) {
        guard data.count >= 8, data.starts(with: Array("fLaC".utf8)) else { return nil }
        var cursor = 4
        var located: (header: Int, payload: Range<Int>)?
        var others: [Data] = []
        var reachedLast = false
        while cursor + 4 <= data.count {
            let header = data[cursor]
            let length = Int(data[cursor + 1]) << 16 | Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            let payloadStart = cursor + 4
            let payloadEnd = payloadStart + length
            guard payloadEnd <= data.count else { return nil }
            if header & 0x7F == 4 {
                // 规范只允许一个 VORBIS_COMMENT 块；第二个说明文件不规整，不动它。
                guard located == nil else { return nil }
                located = (cursor, payloadStart..<payloadEnd)
            } else {
                others.append(Data([header & 0x7F]) + data.subdata(in: payloadStart..<payloadEnd))
            }
            cursor = payloadEnd
            if header & 0x80 != 0 {
                reachedLast = true
                break
            }
        }
        guard reachedLast, let located else { return nil }
        let payload = data.subdata(in: located.payload)
        guard let vendorLength = Self.uint32LE(payload, at: 0),
              vendorLength <= payload.count - 4 else { return nil }
        var position = 4 + vendorLength
        let vendor = payload.subdata(in: 0..<position)
        guard let count = Self.uint32LE(payload, at: position), count <= 100_000 else { return nil }
        position += 4
        var items: [Data] = []
        for _ in 0..<count {
            guard let length = Self.uint32LE(payload, at: position),
                  length <= payload.count - position - 4 else { return nil }
            position += 4
            items.append(payload.subdata(in: position..<(position + length)))
            position += length
        }
        var keys: [String?] = []
        var values: [Data] = []
        for item in items {
            if let separator = item.firstIndex(of: 0x3D) {
                keys.append(String(data: item.subdata(in: 0..<separator), encoding: .utf8))
                values.append(item.subdata(in: (separator + 1)..<item.count))
            } else {
                keys.append(nil)
                values.append(Data())
            }
        }
        self.data = data.subdata(in: 0..<cursor)
        self.blockHeaderOffset = located.header
        self.payloadRange = located.payload
        self.vendor = vendor
        self.items = items
        self.keys = keys
        self.decoded = TextEncodingRepair.decodeTagValues(values)
        self.otherBlocks = others
    }

    var originalIndices: [Int] {
        items.indices.filter { isOriginalLyric($0) }
    }

    /// 原文字段：大写的键和规整后的内容。
    var originalFields: [(key: String, value: String)] {
        originalIndices.map { index in
            (keys[index]?.uppercased() ?? "", EmbeddedLyricsFieldEditor.normalizedText(decoded[index] ?? ""))
        }
    }

    /// 不是原文歌词的字段（含译文），原样的字节。
    var nonLyricItems: [Data] {
        items.indices.filter { !isOriginalLyric($0) }.map { items[$0] }
    }

    func isOriginalLyric(_ index: Int) -> Bool {
        guard keys.indices.contains(index), let key = keys[index] else { return false }
        if case .original = ISOBaseMediaLyricsParser.lyricFieldRole(key, text: decoded[index]) { return true }
        return false
    }

    func matches(_ index: Int, _ text: String) -> Bool {
        guard let value = decoded[index] else { return false }
        return EmbeddedLyricsFieldEditor.sameLyrics(value, text)
    }

    func keyBytes(_ index: Int) -> Data {
        let item = items[index]
        guard let separator = item.firstIndex(of: 0x3D) else { return item }
        return item.subdata(in: 0..<separator)
    }

    func rebuilt(with newItems: [Data]) -> Data? {
        var payload = vendor
        payload.append(Self.encodedUInt32LE(newItems.count))
        for item in newItems {
            payload.append(Self.encodedUInt32LE(item.count))
            payload.append(item)
        }
        guard payload.count <= 0x00FF_FFFF else { return nil }
        var result = data.subdata(in: 0..<blockHeaderOffset)
        result.append(contentsOf: [
            data[blockHeaderOffset],
            UInt8((payload.count >> 16) & 0xFF),
            UInt8((payload.count >> 8) & 0xFF),
            UInt8(payload.count & 0xFF),
        ])
        result.append(payload)
        result.append(data.subdata(in: payloadRange.upperBound..<data.count))
        return result
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return Int(data[offset])
            | Int(data[offset + 1]) << 8
            | Int(data[offset + 2]) << 16
            | Int(data[offset + 3]) << 24
    }

    private static func encodedUInt32LE(_ value: Int) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
