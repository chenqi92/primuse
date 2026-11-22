import Foundation
import CryptoKit

/// Enumerates editable tag entries independently, including repeated values of the same field.
public enum EmbeddedLyricsArchive {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: String
        public let text: String
        public let languageCode: String?
        public let fieldName: String
        public let role: EmbeddedLyricField.Role
        public let isWritable: Bool
    }

    public static func entries(in data: Data, fileExtension: String) throws -> [Entry] {
        var reader = Editor(edits: [:])
        do {
            _ = try reader.visit(data, fileExtension: fileExtension)
        } catch where fileExtension.lowercased() == "mp3" && EmbeddedTagMetadataParser.id3TagByteCount(in: data) != nil {
            // The source may have an extended header, tag-wide unsync or a partial last frame.
            // Its complete frames remain readable even when the structural editor rejects it.
            reader = Editor(edits: [:])
            lazy var duration = ID3EmbeddedLyrics.mpegFrameDuration(in: data)
            ID3EmbeddedLyrics.visitFrames(in: data) { name, raw, flags, version in
                guard ID3EmbeddedLyrics.frameNames.contains(name),
                      let body = ID3EmbeddedLyrics.decodedBody(raw, version: version, flags: flags) else { return }
                let timed = (name == "SYLT" || name == "SLT") && body.count > 4 && body[4] == 1
                let values = ID3EmbeddedLyrics.values(frame: name, data: body, mpegFrameDuration: timed ? duration : nil)
                for value in values {
                    _ = reader.entry(value.field, bytes: identity(raw: raw, decoded: body, value: value, values: values), writable: false)
                }
            }
        }
        return reader.entries
    }

    /// A key mapped to nil deletes that exact entry. Every requested identity must still exist.
    public static func replacing(in data: Data, fileExtension: String, edits: [String: String?]) throws -> Data {
        guard !edits.isEmpty else { return data }
        var editor = Editor(edits: edits)
        return try editor.visit(data, fileExtension: fileExtension)
    }

    /// The batch tag editor also needs frame positions when promoting the chosen original.
    static func originalID3Entries(in data: Data) throws -> [(entry: Entry, ordinal: Int)] {
        guard opaqueID3Frames(data).isEmpty else { throw CocoaError(.featureUnsupported) }
        var editor = Editor(edits: [:])
        _ = try editor.visit(data, fileExtension: "mp3")
        return zip(editor.entries, editor.id3Ordinals).filter { $0.0.role == .original }
    }

    /// An unrelated tag edit can cause a tagging library to collapse repeated lyrics. Restore
    /// the original entries before the working copy replaces the source file.
    public static func preserving(from original: Data, in rewritten: Data, fileExtension: String) throws -> Data {
        let before = try entries(in: original, fileExtension: fileExtension)
        let after = try entries(in: rewritten, fileExtension: fileExtension)
        guard let format = AudioFormat.from(fileExtension: fileExtension) else { throw CocoaError(.featureUnsupported) }
        if format == .mp3 {
            // An encrypted or undecodable lyrics frame must survive an unrelated tag edit, too.
            guard opaqueID3Frames(original) == opaqueID3Frames(rewritten) else { throw CocoaError(.fileWriteUnknown) }
        }
        guard before.map(\.id) != after.map(\.id) else { return rewritten }
        let source = try OrderedTagContainer.items(in: original, format: format)
        let target = try OrderedTagContainer.items(in: rewritten, format: format)
        var edits: [Int: Data?] = [:]
        var append: [OrderedTagContainer.Item] = []
        if format == .flac {
            let originalComments = try source.filter { $0.key == "4" }.flatMap {
                try VorbisBlock($0.payload).comments.filter(VorbisBlock.isLyric)
            }
            var inserted = false
            for item in target where item.key == "4" {
                let block = try VorbisBlock(item.payload)
                var comments = block.comments.filter { !VorbisBlock.isLyric($0) }
                if !inserted {
                    comments += originalComments
                    inserted = true
                }
                edits[item.ordinal] = try block.encoding(comments)
            }
            if !inserted, !originalComments.isEmpty, let template = source.first(where: { $0.key == "4" }) {
                let payload = try VorbisBlock(template.payload).encoding(originalComments)
                append.append(.init(ordinal: template.ordinal, key: template.key, payload: payload,
                                    flags: template.flags, majorVersion: template.majorVersion))
            }
        } else if format == .m4a || format == .alac {
            // A comment atom can contain ordinary notes and lyrics in separate data children.
            // Retain its rewritten notes and recover only the original lyric children.
            for item in target {
                var reader = Editor(edits: [:])
                _ = try reader.mp4(item)
                guard !reader.entries.isEmpty else { continue }
                guard item.metadataKey == nil else { throw CocoaError(.featureUnsupported) }
                var remover = Editor(edits: Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.id, nil as String?) }))
                edits.updateValue(try remover.mp4(item), forKey: item.ordinal)
            }
            for item in source {
                var reader = Editor(edits: [:])
                if let payload = try reader.mp4(item, onlyLyrics: true), !reader.entries.isEmpty {
                    guard item.metadataKey == nil else { throw CocoaError(.featureUnsupported) }
                    append.append(.init(ordinal: item.ordinal, key: item.key, payload: payload))
                }
            }
        } else {
            func movable(_ items: [OrderedTagContainer.Item], shared: inout [[String]]) throws -> [OrderedTagContainer.Item] {
                try items.filter { item in
                    var reader = Editor(edits: [:], inspectsSharedID3Payload: true)
                    _ = try reader.id3(item)
                    guard !reader.entries.isEmpty else { return false }
                    // Moving a whole packet would duplicate or revert unrelated properties inside it.
                    if reader.hasSharedID3Payload {
                        shared.append(reader.entries.map(\.id))
                        return false
                    }
                    return true
                }
            }
            var originalShared: [[String]] = []
            var savedShared: [[String]] = []
            let existing = try movable(target, shared: &savedShared)
            append = try movable(source, shared: &originalShared)
            guard originalShared == savedShared else { throw CocoaError(.fileWriteUnknown) }
            if source.first?.majorVersion == 3, target.first?.majorVersion == 4 {
                // TagLib can upgrade ID3v2.3 to v2.4 and reorder otherwise unchanged frames.
                // Reuse a frame already encoded in the target format if its payload is identical.
                append = append.map { original in
                    guard original.flags == 0 else { return original }
                    return existing.first {
                        $0.flags == 0 && $0.key == original.key && $0.payload == original.payload
                    } ?? original
                }
            }
            for item in existing { edits.updateValue(nil, forKey: item.ordinal) }
        }
        let result = try OrderedTagContainer.replacing(in: rewritten, format: format, replacements: edits, appending: append)
        guard try entries(in: result, fileExtension: fileExtension).map(\.id) == before.map(\.id) else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    private enum Change {
        case keep, remove, update(String)
    }

    private static func opaqueID3Frames(_ data: Data) -> [Data] {
        var frames: [Data] = []
        ID3EmbeddedLyrics.visitFrames(in: data) { name, raw, flags, version in
            guard ID3EmbeddedLyrics.frameNames.contains(name) else { return }
            let body = ID3EmbeddedLyrics.decodedBody(raw, version: version, flags: flags)
            let isContentFrame = name == "SYLT" || name == "SLT"
            let isLyrics = name == "USLT" || name == "ULT" || (isContentFrame && body.map { $0.count < 6 || $0[5] <= 2 } == true)
            guard body == nil || (isLyrics && body.map({ ID3EmbeddedLyrics.fields(frame: name, body: $0).isEmpty }) == true) else { return }
            frames.append(Data(name.utf8) + OrderedTagContainer.integer(Int(flags), bytes: 2) + raw)
        }
        return frames
    }

    private static func identity(raw: Data, decoded: Data, value: ID3EmbeddedLyrics.Value, values: [ID3EmbeddedLyrics.Value]) -> Data {
        if case .xmp = value.storage {
            return Data(((value.field.languageCode ?? "") + "\0" + value.field.text).utf8)
        }
        guard values.count > 1, let start = value.textStart else { return raw }
        // Siblings in a nul-separated text frame have independent identities.
        return Data(decoded.prefix(start)) + decoded[value.range]
    }

    private struct Editor {
        var edits: [String: String?]
        var occurrences: [String: Int] = [:]
        var entries: [Entry] = []
        var frameNames: [Int: String] = [:]
        var id3Ordinals: [Int] = []
        var inspectsSharedID3Payload = false
        var hasSharedID3Payload = false
        var occupiedUSLT = Set<EmbeddedLyricsFieldEditor.USLTIdentity>()

        var mpegFrameDuration: TimeInterval?

        mutating func entry(_ field: EmbeddedLyricField, bytes: Data, writable: Bool = true) -> Change {
            var hash = SHA256()
            hash.update(data: Data(field.name.utf8))
            hash.update(data: Data([0]))
            hash.update(data: bytes)
            let digest = Data(hash.finalize()).base64EncodedString()
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            let id = "\(digest).\(occurrence)"
            entries.append(Entry(id: id, text: field.text, languageCode: field.languageCode, fieldName: field.name,
                                 role: field.role, isWritable: writable))
            guard let edit = edits.removeValue(forKey: id) else { return .keep }
            guard let edit else { return .remove }
            return edit == field.text ? .keep : .update(edit)
        }

        mutating func visit(_ data: Data, fileExtension: String) throws -> Data {
            guard let format = AudioFormat.from(fileExtension: fileExtension) else {
                throw CocoaError(.featureUnsupported)
            }
            var replacements: [Int: Data?] = [:]
            let items = try OrderedTagContainer.items(in: data, format: format)
            if format == .mp3, items.contains(where: { $0.key == "SYLT" || $0.key == "SLT" }) {
                mpegFrameDuration = ID3EmbeddedLyrics.mpegFrameDuration(in: data)
            }
            if format == .mp3, !edits.isEmpty {
                occupiedUSLT = Set(items.compactMap { item in
                    guard item.key == "USLT" || item.key == "ULT" else { return nil }
                    return EmbeddedLyricsFieldEditor.usltIdentity(item.payload)
                })
            }
            for item in items {
                let updated: Data?
                switch format {
                case .m4a, .alac: updated = try mp4(item)
                case .flac where item.key == "4": updated = try vorbis(item.payload)
                case .mp3: updated = try id3(item)
                default: continue
                }
                if updated != item.payload { replacements.updateValue(updated, forKey: item.ordinal) }
            }
            guard edits.isEmpty else { throw CocoaError(.fileReadUnknown) }
            if !frameNames.isEmpty {
                return try OrderedTagContainer.replacingID3Frames(in: data, bodies: replacements, names: frameNames)
            }
            return replacements.isEmpty ? data : try OrderedTagContainer.replacing(
                in: data, format: format, replacements: replacements
            )
        }

        mutating func mp4(_ item: OrderedTagContainer.Item, onlyLyrics: Bool = false) throws -> Data? {
            let field: String
            let boxes: [MP4Box]
            if item.key == "----" {
                guard let children = try? MP4Box.parse(item.payload),
                      let name = children.first(where: { $0.key == "name" }), name.body.count >= 4,
                      let key = String(data: name.body.dropFirst(4), encoding: .utf8) else { return item.payload }
                field = key
                boxes = children
            } else {
                // The remaining iTunes atoms carry identifiers, numbers, or binary artwork.
                guard let key = item.metadataKey ?? (["©lyr", "©cmt", "desc", "ldes"].contains(item.key) ? item.key : nil),
                      let children = try? MP4Box.parse(item.payload) else { return item.payload }
                field = key
                boxes = children
            }
            var output = Data()
            var hasData = false
            var changed = false
            for box in boxes {
                guard box.key == "data" else { output += box.raw; continue }
                if box.body.count >= 8 {
                    let type = Int(box.body[1]) << 16 | Int(box.body[2]) << 8 | Int(box.body[3])
                    let bytes = Data(box.body.dropFirst(8))
                    if let text = mp4Text(bytes, type: type),
                       let role = ISOBaseMediaLyricsParser.lyricFieldRole(field, text: text) {
                        let change = entry(role.field(name: field, text: text), bytes: box.body)
                        switch change {
                        case .keep:
                            output += box.raw
                            hasData = true
                            continue
                        case .remove: changed = true; continue
                        case .update(let text):
                            guard ISOBaseMediaLyricsParser.lyricFieldRole(field, text: text) != nil else {
                                throw CocoaError(.fileWriteInapplicableStringEncoding)
                            }
                            changed = true
                            var header = Data(box.body.prefix(8))
                            header.replaceSubrange(1..<4, with: [0, 0, 1])
                            output += try MP4Box.dataBox(header + Data(text.utf8))
                            hasData = true
                            continue
                        }
                    }
                }
                if onlyLyrics { changed = true; continue }
                output += box.raw
                hasData = true
            }
            guard changed else { return item.payload }
            return hasData ? output : nil
        }

        mutating func vorbis(_ payload: Data) throws -> Data {
            let block = try VorbisBlock(payload)
            var fields: [Data] = []
            var changed = false
            for bytes in block.comments {
                guard let equals = bytes.firstIndex(of: 61), let field = VorbisBlock.field(bytes) else { fields.append(bytes); continue }
                switch entry(field, bytes: bytes) {
                case .keep: fields.append(bytes)
                case .remove: changed = true
                case .update(let text):
                    changed = true
                    guard ISOBaseMediaLyricsParser.lyricFieldRole(field.name, text: text) != nil else {
                        throw CocoaError(.fileWriteInapplicableStringEncoding)
                    }
                    fields.append(bytes.prefix(through: equals) + Data(text.utf8))
                }
            }
            return changed ? try block.encoding(fields) : payload
        }

        mutating func id3(_ item: OrderedTagContainer.Item) throws -> Data? {
            guard ID3EmbeddedLyrics.frameNames.contains(item.key),
                  let data = ID3EmbeddedLyrics.decodedBody(item.payload, version: item.majorVersion, flags: item.flags) else { return item.payload }
            let values = ID3EmbeddedLyrics.values(frame: item.key, data: data, mpegFrameDuration: mpegFrameDuration)
            guard let first = values.first else { return item.payload }
            if case .xmp = first.storage {
                hasSharedID3Payload = true
            } else if inspectsSharedID3Payload, let start = first.textStart {
                let ranges = Set(values.map(\.range))
                let width = ID3EmbeddedLyrics.width(of: data[0])
                var cursor = start
                while cursor < data.count {
                    let range = ID3EmbeddedLyrics.terminatedString(in: data, from: cursor, encoding: data[0]) ?? cursor..<data.count
                    if !range.isEmpty && !ranges.contains(range) { hasSharedID3Payload = true; break }
                    cursor = range.upperBound + width
                }
            }
            var changes: [Range<Int>: Change] = [:]
            for value in values {
                let bytes = EmbeddedLyricsArchive.identity(raw: item.payload, decoded: data, value: value, values: values)
                id3Ordinals.append(item.ordinal)
                let writable: Bool
                if case .xmp = value.storage { writable = false } else { writable = item.flags == 0 }
                let change = entry(value.field, bytes: bytes, writable: writable)
                if case .keep = change { continue }
                guard writable else { throw CocoaError(.featureUnsupported) }
                changes[value.range] = change
            }
            guard !changes.isEmpty else { return item.payload }
            switch first.storage {
            case .xmp: throw CocoaError(.featureUnsupported)
            case .synchronized:
                guard case .update(let text) = changes[first.range] else { return nil }
                let language = data.subdata(in: 1..<4)
                if let payload = EmbeddedLyricsFieldEditor.synchronizedBody(
                    text, language: language, descriptor: first.descriptor, contentType: data[5],
                    equivalent: EmbeddedLyricsVariantPolicy.sameSynchronizedCues
                ) { return payload }
                frameNames[item.ordinal] = item.majorVersion == 2 ? "ULT" : "USLT"
                return EmbeddedLyricsFieldEditor.makeUSLTConvertingSYLT(
                    language: language, descriptor: first.descriptor, text: text, occupied: &occupiedUSLT
                )
            case .attachment(let encoding):
                guard case .update(let text) = changes[first.range] else { return nil }
                let updated = data.prefix(upTo: first.range.lowerBound) + encoding.data(for: text)
                guard !ID3EmbeddedLyrics.fields(frame: item.key, body: updated).isEmpty else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                return updated
            case .text:
                let isUserText = item.key == "TXXX" || item.key == "TXX"
                let descriptorStart = isUserText ? 1 : 4
                guard let range = ID3EmbeddedLyrics.terminatedString(in: data, from: descriptorStart, encoding: data[0]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let width = ID3EmbeddedLyrics.width(of: data[0])
                let valueStart = range.upperBound + width
                var pieces: [Data] = []
                var cursor = valueStart
                while cursor < data.count {
                    let range = ID3EmbeddedLyrics.terminatedString(in: data, from: cursor, encoding: data[0]) ?? cursor..<data.count
                    cursor = range.upperBound + width
                    if case .remove = changes[range] { continue }
                    if case .update(let text) = changes[range] {
                        guard !EmbeddedLyricsFieldEditor.normalizedText(text).isEmpty,
                              item.key == "USLT" || item.key == "ULT"
                              || ISOBaseMediaLyricsParser.id3UserTextRole(first.descriptor, text: text) != nil else {
                            throw CocoaError(.fileWriteInapplicableStringEncoding)
                        }
                        if range == valueStart..<data.count {
                            let encoding: UInt8 = item.majorVersion >= 4 ? 3 : 1
                            let codec: String.Encoding = encoding == 3 ? .utf8 : .utf16
                            let terminator = Data(count: ID3EmbeddedLyrics.width(of: encoding))
                            guard let label = first.descriptor.data(using: codec), let body = text.data(using: codec) else {
                                throw CocoaError(.fileWriteInapplicableStringEncoding)
                            }
                            return Data([encoding]) + data[1..<descriptorStart] + label + terminator + body
                        }
                        let codec: String.Encoding = [.isoLatin1, .utf16, .utf16BigEndian, .utf8][Int(data[0])]
                        guard let body = text.data(using: codec, allowLossyConversion: false) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
                        pieces.append(body)
                    } else {
                        pieces.append(data.subdata(in: range))
                    }
                }
                guard pieces.contains(where: { !$0.isEmpty }) else { return nil }
                return data.prefix(valueStart) + pieces.joined(separator: Data(count: width))
            }
        }
    }

    private static func mp4Text(_ bytes: Data, type: Int) -> String? {
        if [2, 5].contains(type) {
            let hasBOM = bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff])
            return String(data: bytes, encoding: hasBOM ? .utf16 : .utf16BigEndian)
        }
        guard [0, 1, 3, 4].contains(type) else { return nil }
        return String(data: bytes, encoding: .utf8)
            ?? TextEncodingRepair.bestDecoding(of: bytes, encodings: TextEncodingRepair.legacyTextEncodings)
    }

    private static func integerBytes(_ value: UInt32, littleEndian: Bool) -> Data {
        var integer = littleEndian ? value.littleEndian : value.bigEndian
        return withUnsafeBytes(of: &integer) { Data($0) }
    }

    private struct MP4Box {
        let key: String
        let raw: Data
        let body: Data

        static func parse(_ data: Data) throws -> [Self] {
            try OrderedTagContainer.boxes(data, in: 0..<data.count).map { box in
                Self(key: box.key, raw: data.subdata(in: box.range), body: data.subdata(in: box.body))
            }
        }

        static func dataBox(_ body: Data) throws -> Data {
            guard let size = UInt32(exactly: body.count + 8) else { throw CocoaError(.fileWriteOutOfSpace) }
            return integerBytes(size, littleEndian: false) + Data("data".utf8) + body
        }
    }

    private struct VorbisBlock {
        let vendor: Data
        let comments: [Data]
        let tail: Data

        init(_ data: Data) throws {
            var cursor = 0
            func integer() throws -> Int {
                guard cursor <= data.count - 4 else { throw CocoaError(.fileReadCorruptFile) }
                defer { cursor += 4 }
                return data[cursor..<(cursor + 4)].reversed().reduce(0) { $0 << 8 | Int($1) }
            }
            func field() throws -> Data {
                let length = try integer()
                guard length <= data.count - cursor else { throw CocoaError(.fileReadCorruptFile) }
                defer { cursor += length }
                return data.subdata(in: cursor..<(cursor + length))
            }
            vendor = try field()
            let count = try integer()
            guard count <= (data.count - cursor) / 4 else { throw CocoaError(.fileReadCorruptFile) }
            var values: [Data] = []
            for _ in 0..<count { values.append(try field()) }
            comments = values
            tail = Data(data.suffix(from: cursor))
        }

        static func field(_ bytes: Data) -> EmbeddedLyricField? {
            guard let item = EmbeddedTagMetadataParser.vorbisCommentField(bytes),
                  let text = String(data: item.value, encoding: .utf8)
                      ?? TextEncodingRepair.decodeTagValues([item.value]).first ?? nil,
                  let role = ISOBaseMediaLyricsParser.lyricFieldRole(item.key, text: text) else { return nil }
            return role.field(name: item.key, text: text)
        }

        static func isLyric(_ bytes: Data) -> Bool { field(bytes) != nil }

        func encoding(_ fields: [Data]) throws -> Data {
            func length(_ count: Int) throws -> Data {
                guard let size = UInt32(exactly: count) else { throw CocoaError(.fileWriteOutOfSpace) }
                return integerBytes(size, littleEndian: true)
            }
            var body = try length(vendor.count) + vendor + length(fields.count)
            for field in fields { body += try length(field.count) + field }
            return body + tail
        }
    }
}
