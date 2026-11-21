import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Ordered picture slots in the file. The ID includes position so identical images
/// are individually selectable; its digest prevents applying an edit to a changed slot.
public enum EmbeddedPictureArchive {
    public struct Picture: Identifiable, Equatable, Sendable {
        public let id: String
        public let data: Data
        public let role: Int?
    }

    private struct Slot {
        let item: OrderedTagContainer.Item
        let bytes: Range<Int>
        let nested: OrderedTagContainer.Box?
        let role: Int?
        var id3MIMEEnd: Int?
        var flacDimensions: Int?
    }

    public static func pictures(in data: Data, format: AudioFormat) throws -> [Picture] {
        try slots(in: data, format: format).enumerated().map { index, slot in
            Picture(id: identity(slot, index: index), data: slot.item.payload.subdata(in: slot.bytes), role: slot.role)
        }
    }

    private static func identity(_ slot: Slot, index: Int) -> String {
        let range = slot.nested?.range ?? 0..<slot.item.payload.count
        let digest = SHA256.hash(data: slot.item.payload[range])
        return "\(index)-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isPicture(_ item: OrderedTagContainer.Item, format: AudioFormat) -> Bool {
        switch format {
        case .m4a, .alac: return item.key == "covr"
        case .flac: return item.key == "6"
        case .mp3: return item.key == "APIC" || item.key == "PIC"
        default: return false
        }
    }

    private static func slots(in data: Data, format: AudioFormat) throws -> [Slot] {
        var result: [Slot] = []
        for item in try OrderedTagContainer.items(in: data, format: format) where isPicture(item, format: format) {
            let bytes = item.payload
            switch format {
            case .m4a, .alac:
                for box in try OrderedTagContainer.boxes(bytes, in: 0..<bytes.count) where box.key == "data" {
                    guard box.body.count >= 8 else { throw OrderedTagContainer.Failure.invalidEntry }
                    let range = (box.body.lowerBound + 8)..<box.body.upperBound
                    if !range.isEmpty { result.append(Slot(item: item, bytes: range, nested: box, role: nil)) }
                }
            case .mp3:
                let legacy = item.key == "PIC"
                guard item.flags == 0, bytes.count > 4, bytes[0] <= 3 else { throw OrderedTagContainer.Failure.unsupportedLayout }
                let roleOffset: Int
                if legacy { roleOffset = 4 }
                else if let end = bytes[1...].firstIndex(of: 0) { roleOffset = end + 1 }
                else { throw OrderedTagContainer.Failure.invalidEntry }
                guard roleOffset + 1 < bytes.count else { throw OrderedTagContainer.Failure.invalidEntry }
                let width = [1, 2].contains(bytes[0]) ? 2 : 1
                var cursor = roleOffset + 1
                while cursor + width <= bytes.count,
                      !bytes[cursor..<(cursor + width)].allSatisfy({ $0 == 0 }) { cursor += width }
                guard cursor + width < bytes.count else { throw OrderedTagContainer.Failure.invalidEntry }
                result.append(Slot(item: item, bytes: (cursor + width)..<bytes.count, nested: nil,
                                   role: Int(bytes[roleOffset]), id3MIMEEnd: legacy ? nil : roleOffset - 1))
            case .flac:
                guard bytes.count >= 32 else { throw OrderedTagContainer.Failure.invalidEntry }
                let mimeEnd = 8 + OrderedTagContainer.value(bytes, 4, 4)
                guard mimeEnd <= bytes.count - 24 else { throw OrderedTagContainer.Failure.invalidEntry }
                let dimensions = mimeEnd + 4 + OrderedTagContainer.value(bytes, mimeEnd, 4)
                guard dimensions <= bytes.count - 20,
                      OrderedTagContainer.value(bytes, dimensions + 16, 4) == bytes.count - dimensions - 20 else {
                    throw OrderedTagContainer.Failure.invalidEntry
                }
                result.append(Slot(item: item, bytes: (dimensions + 20)..<bytes.count, nested: nil,
                                   role: OrderedTagContainer.value(bytes, 0, 4), flacDimensions: dimensions))
            default: throw OrderedTagContainer.Failure.unsupportedLayout
            }
        }
        return result
    }

    public static func replacing(in original: Data, format: AudioFormat, edits: [String: Data]) throws -> Data {
        if edits.isEmpty { return original }
        let slots = try slots(in: original, format: format)
        var changes: [Int: Data?] = [:]
        var matched = Set<String>()
        // Later child offsets are independent of changes made ahead of them when walking backwards.
        for (index, slot) in slots.enumerated().reversed() {
            let id = identity(slot, index: index)
            guard let replacement = edits[id] else { continue }
            matched.insert(id)
            let bytes = slot.item.payload
            guard let source = CGImageSourceCreateWithData(replacement as CFData, nil),
                  let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
                  let mime = type.preferredMIMEType?.data(using: .ascii) else { throw OrderedTagContainer.Failure.invalidEntry }
            let updated: Data
            if let box = slot.nested {
                let kind: Int
                if type.conforms(to: .png) { kind = 14 }
                else if type.conforms(to: .jpeg) { kind = 13 }
                else if type.conforms(to: .gif) { kind = 12 }
                else if type.conforms(to: .bmp) { kind = 27 }
                else { throw OrderedTagContainer.Failure.invalidEntry }
                let payload = OrderedTagContainer.integer(kind, bytes: 4)
                    + bytes[(box.body.lowerBound + 4)..<(box.body.lowerBound + 8)] + replacement
                var contents = (changes[slot.item.ordinal] ?? nil) ?? bytes
                contents.replaceSubrange(box.range, with: try OrderedTagContainer.box(key: "data", payload: payload))
                updated = contents
            } else if slot.item.key == "PIC" {
                let formatName: String
                if type.conforms(to: .jpeg) { formatName = "JPG" }
                else if type.conforms(to: .png) { formatName = "PNG" }
                else if type.conforms(to: .gif) { formatName = "GIF" }
                else { throw OrderedTagContainer.Failure.invalidEntry }
                updated = bytes.prefix(1) + Data(formatName.utf8) + bytes[4..<slot.bytes.lowerBound] + replacement
            } else if let mimeEnd = slot.id3MIMEEnd {
                updated = bytes.prefix(1) + mime + bytes[mimeEnd..<slot.bytes.lowerBound] + replacement
            } else if let dimensions = slot.flacDimensions {
                guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int,
                      let height = props[kCGImagePropertyPixelHeight] as? Int,
                      replacement.count <= 0xffffff else { throw OrderedTagContainer.Failure.invalidEntry }
                let oldMimeEnd = 8 + OrderedTagContainer.value(bytes, 4, 4)
                var body = Data(bytes.prefix(4))
                body += OrderedTagContainer.integer(mime.count, bytes: 4)
                body += mime
                body += bytes[oldMimeEnd..<dimensions]
                for value in [width, height, 0, 0, replacement.count] { body += OrderedTagContainer.integer(value, bytes: 4) }
                body += replacement
                updated = body
            } else { throw OrderedTagContainer.Failure.invalidEntry }
            changes[slot.item.ordinal] = updated
        }
        guard matched == Set(edits.keys) else { throw OrderedTagContainer.Failure.staleEntry }
        let output = try OrderedTagContainer.replacing(in: original, format: format, replacements: changes)
        let after = try pictures(in: output, format: format)
        guard after.count == slots.count else { throw OrderedTagContainer.Failure.invalidEntry }
        for (index, slot) in slots.enumerated() {
            let expected = edits[identity(slot, index: index)] ?? slot.item.payload.subdata(in: slot.bytes)
            guard after[index].role == slot.role, after[index].data == expected else { throw OrderedTagContainer.Failure.invalidEntry }
        }
        return output
    }

    /// Restore all picture items after a tag library has rewritten unrelated fields
    /// (including duplicate items, untouched types and image descriptions).
    public static func preserving(from original: Data, in rewritten: Data, format: AudioFormat) throws -> Data {
        let before = try OrderedTagContainer.items(in: original, format: format).filter { isPicture($0, format: format) }
        guard !before.isEmpty else { return rewritten }
        let after = try OrderedTagContainer.items(in: rewritten, format: format).filter { isPicture($0, format: format) }
        if before.count == after.count && zip(before, after).allSatisfy({ $0.payload == $1.payload && $0.flags == $1.flags }) {
            return rewritten
        }
        let removed = Dictionary(uniqueKeysWithValues: after.map { ($0.ordinal, nil as Data?) })
        return try OrderedTagContainer.replacing(in: rewritten, format: format, replacements: removed, appending: before)
    }
}
