import Foundation

/// Physical, ordered tag entries used when editing one of several attachments.
/// Unknown entries stay opaque. Reject layouts we cannot rewrite without moving audio.
public enum OrderedTagContainer {
    public enum Failure: Error { case unsupportedLayout, invalidEntry, staleEntry }

    public struct Item: Equatable, Sendable {
        public let ordinal: Int
        public let key: String
        public let payload: Data
        public let flags: UInt16
        public let majorVersion: Int
        public let metadataKey: String?

        public init(ordinal: Int, key: String, payload: Data, flags: UInt16 = 0, majorVersion: Int = 0, metadataKey: String? = nil) {
            self.ordinal = ordinal
            self.key = key
            self.payload = payload
            self.flags = flags
            self.majorVersion = majorVersion
            self.metadataKey = metadataKey
        }
    }

    private struct Span {
        let key: String
        let start: Int
        let body: Range<Int>
        var flags: UInt16 = 0
    }

    struct Box {
        let key: String
        let start: Int
        let body: Range<Int>
        var range: Range<Int> { start..<body.upperBound }
    }

    static func value(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        data[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
    }

    static func integer(_ value: Int, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    static func boxes(_ data: Data, in bounds: Range<Int>) throws -> [Box] {
        var cursor = bounds.lowerBound
        var result: [Box] = []
        while cursor < bounds.upperBound {
            guard bounds.upperBound - cursor >= 8 else { throw Failure.unsupportedLayout }
            let key = String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .isoLatin1)
            var length = value(data, cursor, 4)
            var header = 8
            if length == 1 {
                guard bounds.upperBound - cursor >= 16, data[cursor + 8] < 128 else { throw Failure.unsupportedLayout }
                length = value(data, cursor + 8, 8)
                header = 16
            } else if length == 0 {
                length = bounds.upperBound - cursor
            }
            guard let key, length >= header, length <= bounds.upperBound - cursor else { throw Failure.unsupportedLayout }
            result.append(Box(key: key, start: cursor, body: (cursor + header)..<(cursor + length)))
            cursor += length
        }
        return result
    }

    private static func mp4Paths(_ data: Data) throws -> [[Box]] {
        let top = try boxes(data, in: 0..<data.count)
        guard !top.contains(where: { $0.key == "moof" }), top.filter({ $0.key == "moov" }).count == 1,
              let movie = top.first(where: { $0.key == "moov" }) else { throw Failure.unsupportedLayout }
        let movieChildren = try boxes(data, in: movie.body)
        guard !movieChildren.contains(where: { $0.key == "mvex" || $0.key == "cmov" }) else { throw Failure.unsupportedLayout }
        var paths: [[Box]] = []
        var parents = [([movie], movieChildren)]
        for udta in movieChildren where udta.key == "udta" {
            parents.append(([movie, udta], try boxes(data, in: udta.body)))
        }
        for (parents, children) in parents {
            for meta in children where meta.key == "meta" && meta.body.count >= 4 {
                let entries = try boxes(data, in: (meta.body.lowerBound + 4)..<meta.body.upperBound)
                for list in entries where list.key == "ilst" { paths.append(parents + [meta, list]) }
            }
        }
        return paths.sorted { ($0.last?.start ?? 0) < ($1.last?.start ?? 0) }
    }

    private struct Layout {
        var spans: [Span]
        var version = 0
        var end: Int
        var path: [Box] = []
    }

    private static func layout(_ data: Data, format: AudioFormat, pathIndex: Int = 0) throws -> Layout {
        switch format {
        case .m4a, .alac:
            let paths = try mp4Paths(data)
            guard paths.indices.contains(pathIndex) else { throw Failure.unsupportedLayout }
            let path = paths[pathIndex]
            guard let list = path.last else { throw Failure.unsupportedLayout }
            let spans = try boxes(data, in: list.body).map { Span(key: $0.key, start: $0.start, body: $0.body) }
            return Layout(spans: spans, end: list.body.upperBound, path: path)
        case .flac:
            guard data.starts(with: "fLaC".utf8) else { throw Failure.unsupportedLayout }
            var cursor = 4
            var spans: [Span] = []
            while data.count - cursor >= 4 {
                let type = data[cursor] & 127
                let length = value(data, cursor + 1, 3)
                guard length <= data.count - cursor - 4, type < 127,
                      !spans.isEmpty || (type == 0 && length == 34) else { throw Failure.unsupportedLayout }
                spans.append(Span(key: String(type), start: cursor, body: (cursor + 4)..<(cursor + 4 + length)))
                let last = data[cursor] & 128 != 0
                cursor += 4 + length
                if last { return Layout(spans: spans, end: cursor) }
            }
            throw Failure.unsupportedLayout
        case .mp3:
            guard data.count >= 10, data.starts(with: "ID3".utf8), (2...4).contains(data[3]),
                  data[5] == 0 else { throw Failure.unsupportedLayout }
            let version = Int(data[3])
            let length = try syncSize(data, at: 6)
            guard length <= data.count - 10 else { throw Failure.unsupportedLayout }
            let end = length + 10
            let keyLength = version == 2 ? 3 : 4
            let headerLength = version == 2 ? 6 : 10
            var cursor = 10
            var spans: [Span] = []
            while cursor < end, data[cursor] != 0 {
                guard end - cursor >= headerLength,
                      data[cursor..<(cursor + keyLength)].allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
                      let key = String(data: data[cursor..<(cursor + keyLength)], encoding: .ascii) else { throw Failure.unsupportedLayout }
                let size = version == 4 ? try syncSize(data, at: cursor + 4) : value(data, cursor + keyLength, keyLength)
                guard size > 0, size <= end - cursor - headerLength else { throw Failure.unsupportedLayout }
                let flags = version == 2 ? 0 : UInt16(value(data, cursor + 8, 2))
                spans.append(Span(key: key, start: cursor, body: (cursor + headerLength)..<(cursor + headerLength + size), flags: flags))
                cursor += headerLength + size
            }
            guard data[cursor..<end].allSatisfy({ $0 == 0 }) else { throw Failure.unsupportedLayout }
            return Layout(spans: spans, version: version, end: end)
        default: throw Failure.unsupportedLayout
        }
    }

    private static func syncSize(_ data: Data, at offset: Int) throws -> Int {
        let bytes = data[offset..<(offset + 4)]
        guard bytes.allSatisfy({ $0 < 128 }) else { throw Failure.unsupportedLayout }
        return bytes.reduce(0) { ($0 << 7) | Int($1) }
    }

    private static func syncBytes(_ size: Int) throws -> Data {
        guard size <= 0x0fffffff else { throw Failure.invalidEntry }
        return Data([21, 14, 7, 0].map { UInt8((size >> $0) & 127) })
    }

    /// Materialize only the original tag bytes before a tag library writes in place.
    /// A memory map of the full media object would observe those writes.
    public static func tagSnapshot(in data: Data, format: AudioFormat) throws -> Data {
        switch format {
        case .m4a, .alac:
            let top = try boxes(data, in: 0..<data.count)
            guard let movie = top.first(where: { $0.key == "moov" }) else { throw Failure.unsupportedLayout }
            return data.subdata(in: movie.range)
        case .mp3:
            guard data.starts(with: "ID3".utf8) else { return Data() }
            guard data.count >= 10 else { throw Failure.unsupportedLayout }
            let end = 10 + (try syncSize(data, at: 6)) + (data[5] & 0x10 == 0 ? 0 : 10)
            guard end <= data.count else { throw Failure.unsupportedLayout }
            return data.subdata(in: 0..<end)
        case .flac:
            let tag = try layout(data, format: format)
            return data.subdata(in: 0..<tag.end)
        default: throw Failure.unsupportedLayout
        }
    }

    public static func items(in data: Data, format: AudioFormat) throws -> [Item] {
        if format == .mp3, !data.starts(with: "ID3".utf8) {
            // A legal MPEG audio frame header, with no leading ID3 tag.
            guard data.count >= 4, data[0] == 0xff, data[1] & 0xe0 == 0xe0,
                  data[1] & 0x18 != 0x08, data[1] & 0x06 != 0,
                  data[2] & 0xf0 != 0xf0, data[2] & 0x0c != 0x0c else { throw Failure.unsupportedLayout }
            return []
        }
        let pathCount = format == .m4a || format == .alac ? try mp4Paths(data).count : 1
        var items: [Item] = []
        for pathIndex in 0..<pathCount {
            let layout = try layout(data, format: format, pathIndex: pathIndex)
            let keys = try mdtaKeys(data, layout: layout)
            for span in layout.spans {
                let metadataKey = keys.isEmpty ? nil : keys[value(data, span.start + 4, 4)]
                items.append(Item(ordinal: items.count, key: span.key, payload: data.subdata(in: span.body),
                                  flags: span.flags, majorVersion: layout.version, metadataKey: metadataKey))
            }
        }
        return items
    }

    private static func mdtaKeys(_ data: Data, layout: Layout) throws -> [Int: String] {
        guard layout.path.count >= 2 else { return [:] }
        let meta = layout.path[layout.path.count - 2]
        guard let keys = try boxes(data, in: (meta.body.lowerBound + 4)..<meta.body.upperBound)
            .first(where: { $0.key == "keys" }) else { return [:] }
        guard keys.body.count >= 8 else { throw Failure.unsupportedLayout }
        let entries = try boxes(data, in: (keys.body.lowerBound + 8)..<keys.body.upperBound)
        guard entries.count == value(data, keys.body.lowerBound + 4, 4) else { throw Failure.unsupportedLayout }
        var names: [Int: String] = [:]
        for (index, entry) in entries.enumerated() {
            names[index + 1] = String(data: data[entry.body], encoding: .utf8) ?? String(data: data[entry.body], encoding: .isoLatin1)
        }
        return names
    }

    static func box(key: String, payload: Data) throws -> Data {
        guard let keyData = key.data(using: .isoLatin1), keyData.count == 4,
              payload.count <= Int(UInt32.max) - 8 else { throw Failure.invalidEntry }
        return integer(payload.count + 8, bytes: 4) + keyData + payload
    }

    public static func replacing(in data: Data, format: AudioFormat, replacements: [Int: Data?], appending: [Item] = []) throws -> Data {
        if replacements.isEmpty && appending.isEmpty { return data }
        if format == .m4a || format == .alac {
            let paths = try mp4Paths(data)
            var groups: [Range<Int>] = []
            var total = 0
            var insertionPath: Int?
            for index in paths.indices {
                let layout = try layout(data, format: format, pathIndex: index)
                groups.append(total..<(total + layout.spans.count))
                total += layout.spans.count
                if insertionPath == nil, try mdtaKeys(data, layout: layout).isEmpty { insertionPath = index }
            }
            guard replacements.keys.allSatisfy({ (0..<total).contains($0) }),
                  appending.isEmpty || (insertionPath != nil && appending.allSatisfy({ $0.metadataKey == nil })) else {
                throw Failure.staleEntry
            }
            var result = data
            for index in groups.indices.reversed() {
                let group = groups[index]
                let edits = replacements.reduce(into: [Int: Data?]()) { output, entry in
                    if group.contains(entry.key) { output.updateValue(entry.value, forKey: entry.key - group.lowerBound) }
                }
                let additions = index == insertionPath ? appending : []
                if !edits.isEmpty || !additions.isEmpty {
                    result = try replacingGroup(in: result, format: format, pathIndex: index, replacements: edits, appending: additions)
                }
            }
            return result
        }
        return try replacingGroup(in: data, format: format, pathIndex: 0, replacements: replacements, appending: appending)
    }

    static func replacingID3Frames(in data: Data, bodies: [Int: Data?], names: [Int: String]) throws -> Data {
        guard names.keys.allSatisfy(bodies.keys.contains) else { throw Failure.staleEntry }
        return try replacingGroup(in: data, format: .mp3, pathIndex: 0, replacements: bodies, appending: [], frameNames: names)
    }

    private static func replacingGroup(in data: Data, format: AudioFormat, pathIndex: Int,
                                       replacements: [Int: Data?], appending: [Item], frameNames: [Int: String] = [:]) throws -> Data {
        let layout = try layout(data, format: format, pathIndex: pathIndex)
        guard replacements.keys.allSatisfy(layout.spans.indices.contains) else { throw Failure.staleEntry }
        var contents = Data()
        var lastFLACHeader: Int?
        for (ordinal, span) in layout.spans.enumerated() {
            if let replacement = replacements[ordinal], replacement == nil {
                guard format != .flac || ordinal > 0 else { throw Failure.invalidEntry }
                continue
            }
            let start = contents.count
            if let replacement = replacements[ordinal], let payload = replacement {
                switch format {
                case .m4a, .alac: contents += try box(key: span.key, payload: payload)
                case .flac:
                    guard payload.count <= 0xffffff else { throw Failure.invalidEntry }
                    contents.append(data[span.start] & 127)
                    contents += integer(payload.count, bytes: 3)
                    contents += payload
                case .mp3:
                    let keyLength = layout.version == 2 ? 3 : 4
                    guard span.flags == 0, payload.count <= (layout.version == 2 ? 0xffffff : Int(UInt32.max)) else {
                        throw Failure.unsupportedLayout
                    }
                    if let name = frameNames[ordinal] {
                        guard let id = name.data(using: .ascii), id.count == keyLength,
                              id.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw Failure.invalidEntry }
                        contents += id
                    } else {
                        contents += data[span.start..<(span.start + keyLength)]
                    }
                    contents += layout.version == 4 ? try syncBytes(payload.count) : integer(payload.count, bytes: keyLength)
                    if layout.version != 2 { contents += Data([0, 0]) }
                    contents += payload
                default: throw Failure.unsupportedLayout
                }
            } else { contents += data[span.start..<span.body.upperBound] }
            if format == .flac {
                contents[start] &= 127
                lastFLACHeader = start
            }
        }
        for item in appending {
            switch format {
            case .m4a, .alac: contents += try box(key: item.key, payload: item.payload)
            case .mp3:
                let keyLength = layout.version == 2 ? 3 : 4
                guard let key = item.key.data(using: .ascii), key.count == keyLength, !item.payload.isEmpty,
                      item.majorVersion == 0 || item.majorVersion == layout.version,
                      item.payload.count <= (layout.version == 2 ? 0xffffff : Int(UInt32.max)) else { throw Failure.unsupportedLayout }
                contents += key
                contents += layout.version == 4 ? try syncBytes(item.payload.count) : integer(item.payload.count, bytes: keyLength)
                if layout.version != 2 { contents += integer(Int(item.flags), bytes: 2) }
                contents += item.payload
            case .flac:
                guard let type = UInt8(item.key), (1..<127).contains(type), item.payload.count <= 0xffffff else {
                    throw Failure.invalidEntry
                }
                lastFLACHeader = contents.count
                contents.append(type)
                contents += integer(item.payload.count, bytes: 3)
                contents += item.payload
            default: throw Failure.unsupportedLayout
            }
        }
        switch format {
        case .flac:
            guard let lastFLACHeader else { throw Failure.invalidEntry }
            contents[lastFLACHeader] |= 128
            return data.prefix(4) + contents + data[layout.end...]
        case .mp3:
            let length = max(contents.count, layout.end - 10)
            return data.prefix(6) + (try syncBytes(length)) + contents + Data(count: length - contents.count) + data[layout.end...]
        case .m4a, .alac:
            guard let list = layout.path.last, let movie = layout.path.first else { throw Failure.unsupportedLayout }
            var rewritten = try box(key: list.key, payload: contents)
            var child = list
            for parent in layout.path.dropLast().reversed() {
                let payload = data[parent.body.lowerBound..<child.start] + rewritten + data[child.body.upperBound..<parent.body.upperBound]
                rewritten = try box(key: parent.key, payload: payload)
                child = parent
            }
            if rewritten.count == movie.range.count || movie.body.upperBound == data.count {
                return data[..<movie.start] + rewritten + data[movie.body.upperBound...]
            }
            // Keep every media offset (including co64) stable. The original movie atom
            // becomes free space and the replacement goes after the final top-level box.
            let top = try boxes(data, in: 0..<data.count)
            guard let last = top.last else { throw Failure.unsupportedLayout }
            var result = data
            if value(data, last.start, 4) == 0 {
                guard last.range.count <= Int(UInt32.max) else { throw Failure.unsupportedLayout }
                result.replaceSubrange(last.start..<(last.start + 4), with: integer(last.range.count, bytes: 4))
            }
            result.replaceSubrange((movie.start + 4)..<(movie.start + 8), with: "free".utf8)
            result.replaceSubrange(movie.body, with: Data(count: movie.body.count))
            result += rewritten
            return result
        default: throw Failure.unsupportedLayout
        }
    }
}
