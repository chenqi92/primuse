import Foundation
import CryptoKit

/// Enumerates editable tag entries independently, including repeated values of the same field.
public enum EmbeddedLyricsArchive {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: String
        public let text: String
        public let languageCode: String?
        public let fieldName: String
    }

    public static func entries(in data: Data, fileExtension: String) throws -> [Entry] {
        var reader = Editor(edits: [:])
        _ = try reader.visit(data, fileExtension: fileExtension)
        return reader.entries
    }

    /// A key mapped to nil deletes that exact entry. Every requested identity must still exist.
    public static func replacing(in data: Data, fileExtension: String, edits: [String: String?]) throws -> Data {
        guard !edits.isEmpty else { return data }
        var editor = Editor(edits: edits)
        return try editor.visit(data, fileExtension: fileExtension)
    }

    /// An unrelated tag edit can cause a tagging library to collapse repeated lyrics. Restore
    /// the original entries before the working copy replaces the source file.
    public static func preserving(from original: Data, in rewritten: Data, fileExtension: String) throws -> Data {
        let before = try entries(in: original, fileExtension: fileExtension)
        let after = try entries(in: rewritten, fileExtension: fileExtension)
        guard before != after else { return rewritten }
        guard let format = AudioFormat.from(fileExtension: fileExtension) else { throw CocoaError(.featureUnsupported) }
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
        } else {
            func hasLyrics(_ item: OrderedTagContainer.Item) throws -> Bool {
                var reader = Editor(edits: [:])
                if format == .mp3 { _ = try reader.id3(item) }
                else { _ = try reader.mp4(item) }
                guard !reader.entries.isEmpty else { return false }
                guard item.metadataKey == nil else { throw CocoaError(.featureUnsupported) }
                return true
            }
            let existing = try target.filter(hasLyrics)
            append = try source.filter(hasLyrics)
            if format == .mp3, source.first?.majorVersion == 3, target.first?.majorVersion == 4 {
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
        guard try entries(in: result, fileExtension: fileExtension) == before else { throw CocoaError(.fileWriteUnknown) }
        return result
    }

    private enum Change {
        case keep, remove, update(String)
    }

    private struct Editor {
        var edits: [String: String?]
        var occurrences: [String: Int] = [:]
        var entries: [Entry] = []
        var frameNames: [Int: String] = [:]
        var occupiedUSLT = Set<EmbeddedLyricsFieldEditor.USLTIdentity>()

        mutating func entry(_ field: String, language: String?, bytes: Data, text: String) -> Change {
            var hash = SHA256()
            hash.update(data: Data(field.utf8))
            hash.update(data: Data([0]))
            hash.update(data: bytes)
            let digest = Data(hash.finalize()).base64EncodedString()
            let occurrence = occurrences[digest, default: 0]
            occurrences[digest] = occurrence + 1
            let id = "\(digest).\(occurrence)"
            entries.append(Entry(id: id, text: text, languageCode: language, fieldName: field))
            guard let edit = edits.removeValue(forKey: id) else { return .keep }
            guard let edit else { return .remove }
            return edit == text ? .keep : .update(edit)
        }

        mutating func visit(_ data: Data, fileExtension: String) throws -> Data {
            guard let format = AudioFormat.from(fileExtension: fileExtension) else {
                throw CocoaError(.featureUnsupported)
            }
            var replacements: [Int: Data?] = [:]
            let items = try OrderedTagContainer.items(in: data, format: format)
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

        mutating func mp4(_ item: OrderedTagContainer.Item) throws -> Data? {
            let keyRole = item.metadataKey.flatMap(ISOBaseMediaLyricsParser.lyricFieldRole)
            guard item.key == "©lyr" || item.key == "----" || keyRole != nil else { return item.payload }
            let boxes = try MP4Box.parse(item.payload)
            let field: String
            let language: String?
            if item.key == "----" {
                guard let name = boxes.first(where: { $0.key == "name" }), name.body.count >= 4,
                      let key = String(data: name.body.dropFirst(4), encoding: .utf8),
                      let role = ISOBaseMediaLyricsParser.lyricFieldRole(key) else { return item.payload }
                field = key
                language = fieldLanguage(role)
            } else if let keyRole, let metadataKey = item.metadataKey {
                field = metadataKey
                language = fieldLanguage(keyRole)
            } else {
                field = item.key
                language = nil
            }
            var output = Data()
            var count = 0
            var changed = false
            for box in boxes {
                guard box.key == "data" else { output += box.raw; continue }
                guard box.body.count >= 8 else { throw CocoaError(.fileReadCorruptFile) }
                let type = Int(box.body[1]) << 16 | Int(box.body[2]) << 8 | Int(box.body[3])
                let bytes = Data(box.body.dropFirst(8))
                guard let text = mp4Text(bytes, type: type) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                let change = entry(field, language: language, bytes: box.body, text: text)
                switch change {
                case .keep: output += box.raw
                case .remove: changed = true; continue
                case .update(let text):
                    changed = true
                    var header = Data(box.body.prefix(8))
                    header.replaceSubrange(1..<4, with: [0, 0, 1])
                    output += try MP4Box.dataBox(header + Data(text.utf8))
                }
                count += 1
            }
            guard changed else { return item.payload }
            return count == 0 ? nil : output
        }

        mutating func vorbis(_ payload: Data) throws -> Data {
            let block = try VorbisBlock(payload)
            var fields: [Data] = []
            var changed = false
            for bytes in block.comments {
                guard let equals = bytes.firstIndex(of: 61),
                      let key = String(data: bytes.prefix(upTo: equals), encoding: .utf8),
                      let role = ISOBaseMediaLyricsParser.lyricFieldRole(key) else { fields.append(bytes); continue }
                let value = bytes.suffix(from: equals + 1)
                guard let text = String(data: value, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                switch entry(key, language: fieldLanguage(role), bytes: bytes, text: text) {
                case .keep: fields.append(bytes)
                case .remove: changed = true
                case .update(let text):
                    changed = true
                    fields.append(bytes.prefix(through: equals) + Data(text.utf8))
                }
            }
            return changed ? try block.encoding(fields) : payload
        }

        mutating func id3(_ item: OrderedTagContainer.Item) throws -> Data? {
            let isUserText = ["TXXX", "TXX"].contains(item.key)
            let isSynced = ["SYLT", "SLT"].contains(item.key)
            guard isUserText || isSynced || ["USLT", "ULT"].contains(item.key) else { return item.payload }
            let data = item.payload
            // Compression, encryption and per-frame unsynchronisation change the payload layout.
            guard item.flags & 0xff == 0 else {
                if isUserText { return data }
                throw CocoaError(.featureUnsupported)
            }
            let offset = isUserText ? 1 : (isSynced ? 6 : 4)
            guard data.count > offset, data[0] <= 3 else { throw CocoaError(.fileReadCorruptFile) }
            let encoding = data[0]
            guard let end = stringEnd(in: data, from: offset, encoding: encoding) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let descriptorBytes = data.subdata(in: offset..<(end - terminatorSize(encoding)))
            let descriptor = id3Text(descriptorBytes, encoding) ?? ""
            let field: String
            let language: String?
            if isUserText {
                guard let role = ISOBaseMediaLyricsParser.id3UserTextRole(descriptor) else { return data }
                field = descriptor
                language = fieldLanguage(role)
            } else {
                field = item.key
                language = LyricLanguageCodePolicy.canonicalIdentifier(String(decoding: data[1..<4], as: UTF8.self))
            }
            let text: String
            if isSynced {
                guard [1, 2].contains(data[5]) else { return data }
                guard let frame = ID3SynchronizedLyricsParser.parse(data) else { throw CocoaError(.featureUnsupported) }
                text = frame.text
            } else {
                guard let decoded = id3Text(Data(data.dropFirst(end)), encoding) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                text = decoded
            }
            switch entry(field, language: language, bytes: data, text: text) {
            case .keep: return data
            case .remove: return nil
            case .update(let text):
                guard !EmbeddedLyricsFieldEditor.normalizedText(text).isEmpty else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
                if isSynced {
                    let language = data.subdata(in: 1..<4)
                    if let payload = EmbeddedLyricsFieldEditor.synchronizedBody(
                        text, language: language, descriptor: descriptor, contentType: data[5],
                        equivalent: EmbeddedLyricsVariantPolicy.sameSynchronizedCues
                    ) { return payload }
                    frameNames[item.ordinal] = item.majorVersion == 2 ? "ULT" : "USLT"
                    return EmbeddedLyricsFieldEditor.makeUSLTConvertingSYLT(
                        language: language, descriptor: descriptor, text: text, occupied: &occupiedUSLT
                    )
                }
                let newEncoding: UInt8 = item.majorVersion >= 4 ? 3 : 1
                let codec: String.Encoding = newEncoding == 3 ? .utf8 : .utf16
                let terminator = Data(repeating: 0, count: terminatorSize(newEncoding))
                guard let label = descriptor.data(using: codec), let body = text.data(using: codec) else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                return Data([newEncoding]) + data[1..<offset] + label + terminator + body
            }
        }
    }

    private static func fieldLanguage(_ role: ISOBaseMediaLyricsParser.LyricFieldRole) -> String? {
        switch role {
        case .original(let language), .translation(let language): return language
        }
    }

    private static func terminatorSize(_ encoding: UInt8) -> Int { [1, 2].contains(encoding) ? 2 : 1 }

    private static func stringEnd(in data: Data, from offset: Int, encoding: UInt8) -> Int? {
        let size = terminatorSize(encoding)
        var cursor = offset
        while cursor <= data.count - size {
            if data[cursor] == 0 && (size == 1 || data[cursor + 1] == 0) { return cursor + size }
            cursor += size
        }
        return nil
    }

    private static func id3Text(_ bytes: Data, _ encoding: UInt8) -> String? {
        guard !bytes.isEmpty else { return "" }
        let codec: String.Encoding = [.isoLatin1, .utf16, .utf16BigEndian, .utf8][Int(encoding)]
        return String(data: bytes, encoding: codec)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            ?? TextEncodingRepair.decodeID3Text(bytes, encodingByte: encoding)
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

        static func isLyric(_ bytes: Data) -> Bool {
            guard let equals = bytes.firstIndex(of: 61),
                  let key = String(data: bytes.prefix(upTo: equals), encoding: .utf8) else { return false }
            return ISOBaseMediaLyricsParser.lyricFieldRole(key) != nil
        }

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
