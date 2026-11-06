import Foundation

/// Read-only ISO 9660/Joliet and physical-partition UDF access. No paths from an
/// image are ever passed to the host filesystem; extraction uses byte extents.
public enum DiscImageFileSystem {
    public typealias Read = SACDISOReader.Read
    public enum Failure: Error, Equatable {
        case unrecognized, invalidDirectory, unsupportedLayout, truncated, missingFile, excessiveSize
    }
    public struct Extent: Sendable, Equatable {
        public var offset: Int64
        public var length: Int64
        public init(offset: Int64, length: Int64) { self.offset = offset; self.length = length }
    }
    public struct File: Sendable, Equatable {
        public var path: String
        public var extents: [Extent]
        public var size: Int64 { extents.reduce(0) { $0 + $1.length } }
        public init(path: String, extents: [Extent]) { self.path = path; self.extents = extents }
    }

    public static func files(size: Int64, read: @escaping Read) async throws -> [File] {
        let image = Image(size: size, read: read)
        // A UDF bridge may expose truncated ISO names or a compatibility-only
        // tree. Prefer its real directory, falling back only for an unsupported layout.
        do { if let files = try await udf(image) { return files } }
        catch Failure.unsupportedLayout { /* An ISO bridge can still be usable. */ }
        return try await iso9660(image)
    }

    public static func read(_ file: File, offset: Int64, length: Int64, using read: Read) async throws -> Data {
        guard offset >= 0, length >= 0, length <= 4 * 1024 * 1024 else { throw Failure.excessiveSize }
        guard offset < file.size, length > 0 else { return Data() }
        var remaining = min(length, file.size - offset), skip = offset
        var result = Data()
        for extent in file.extents {
            if skip >= extent.length { skip -= extent.length; continue }
            let count = min(remaining, extent.length - skip)
            try Task.checkCancellation()
            let data = try await read(extent.offset + skip, count)
            guard data.count == count else { throw Failure.truncated }
            result.append(data)
            remaining -= count
            if remaining == 0 { break }
            skip = 0
        }
        guard remaining == 0 else { throw Failure.truncated }
        return result
    }

    public static func slice(_ file: File, offset: Int64, length: Int64) throws -> File {
        guard offset >= 0, length >= 0, offset <= file.size, length <= file.size - offset else { throw Failure.truncated }
        var remaining = length, skip = offset
        var extents: [Extent] = []
        for extent in file.extents {
            if skip >= extent.length { skip -= extent.length; continue }
            let count = min(remaining, extent.length - skip)
            if count > 0 { extents.append(.init(offset: extent.offset + skip, length: count)) }
            remaining -= count
            if remaining == 0 { break }
            skip = 0
        }
        return File(path: file.path, extents: extents)
    }

    struct Image {
        let size: Int64
        let read: Read
        func bytes(_ offset: Int64, _ count: Int64 = 2048) async throws -> Data {
            _ = try extent(offset, count)
            guard count <= 4 * 1024 * 1024 else { throw Failure.excessiveSize }
            try Task.checkCancellation()
            let data = try await read(offset, count)
            guard data.count == count else { throw Failure.truncated }
            return data
        }
        func extent(_ offset: Int64, _ length: Int64) throws -> Extent {
            guard offset >= 0, length >= 0, offset <= Int64.max - length,
                  size <= 0 || (offset <= size && length <= size - offset) else { throw Failure.truncated }
            return Extent(offset: offset, length: length)
        }
    }

    private static func iso9660(_ image: Image) async throws -> [File] {
        var primary: Data?, supplementary: Data?
        for sector in 16..<80 {
            if image.size > 0, Int64(sector + 1) * 2048 > image.size { break }
            let data = try await image.bytes(Int64(sector * 2048))
            guard data[1..<6] == Data("CD001".utf8) else { break }
            if data[0] == 1 { primary = data }
            if data[0] == 2, data[88] == 0x25, data[89] == 0x2f,
               [0x40, 0x43, 0x45].contains(data[90]) { supplementary = data }
            if data[0] == 255 { break }
        }
        guard let volume = supplementary ?? primary else { throw Failure.unrecognized }
        guard try ISOBytes.le(volume, 128, 2) == 2048 else { throw Failure.unsupportedLayout }
        let root = try isoRecord(volume, at: 156, joliet: supplementary != nil, image: image)
        var queue: [(File, Int)] = [(File(path: "", extents: [root.extent]), 0)]
        var visited: Set<Int64> = [], output: [File] = []
        var partial: File?
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard depth <= 32, output.count + queue.count < 65_536,
                  directory.size <= 4 * 1024 * 1024 else { throw Failure.excessiveSize }
            guard visited.insert(directory.extents[0].offset).inserted else { throw Failure.invalidDirectory }
            let data = try await read(directory, offset: 0, length: directory.size, using: image.read)
            var cursor = 0
            while cursor < data.count {
                let count = Int(data[cursor])
                if count == 0 { cursor = (cursor / 2048 + 1) * 2048; continue }
                guard count >= 34, cursor + count <= data.count,
                      cursor % 2048 + count <= 2048 else { throw Failure.invalidDirectory }
                let item = try isoRecord(data, at: cursor, joliet: supplementary != nil, image: image)
                cursor += count
                if item.name == nil { continue }
                let path = directory.path + "/" + item.name!
                if item.directory {
                    queue.append((File(path: path, extents: [item.extent]), depth + 1))
                } else {
                    if var pending = partial {
                        guard pending.path == path else { throw Failure.invalidDirectory }
                        pending.extents.append(item.extent)
                        partial = pending
                    } else { partial = File(path: path, extents: [item.extent]) }
                    if !item.continues { output.append(partial!); partial = nil }
                }
            }
            guard partial == nil else { throw Failure.invalidDirectory }
        }
        return output.sorted { $0.path < $1.path }
    }

    private static func isoRecord(_ data: Data, at p: Int, joliet: Bool, image: Image) throws
        -> (name: String?, extent: Extent, directory: Bool, continues: Bool) {
        guard p + 34 <= data.count, Int(data[p]) >= 34,
              p + Int(data[p]) <= data.count else { throw Failure.invalidDirectory }
        let nameLength = Int(data[p + 32])
        guard nameLength > 0, 33 + nameLength <= Int(data[p]), data[p + 26] == 0,
              data[p + 27] == 0 else { throw Failure.unsupportedLayout }
        let sector = try ISOBytes.le(data, p + 2, 4), length = try ISOBytes.le(data, p + 10, 4)
        guard sector == (try ISOBytes.be(data, p + 6, 4)), length == (try ISOBytes.be(data, p + 14, 4)) else {
            throw Failure.invalidDirectory
        }
        let extent = try image.extent((sector + Int64(data[p + 1])) * 2048, length)
        let bytes = Data(data[(p + 33)..<(p + 33 + nameLength)])
        let special = nameLength == 1 && bytes[0] <= 1
        var name = special ? nil : String(data: bytes, encoding: joliet ? .utf16BigEndian : .isoLatin1)
        if let separator = name?.lastIndex(of: ";"), name![name!.index(after: separator)...].allSatisfy(\.isNumber) {
            name = String(name![..<separator])
        }
        if name?.hasSuffix(".") == true { name?.removeLast() }
        if !special { guard let name, validComponent(name) else { throw Failure.invalidDirectory } }
        return (name, extent, data[p + 25] & 2 != 0, data[p + 25] & 128 != 0)
    }

    private static func udf(_ image: Image) async throws -> [File]? {
        guard image.size <= 0 || image.size >= 257 * 2048 else { return nil }
        var recognized = false
        for sector in 16..<32 {
            let descriptor = try await image.bytes(Int64(sector * 2048))
            let identifier = String(data: descriptor[1..<6], encoding: .ascii)
            if identifier == "NSR02" || identifier == "NSR03" { recognized = true; break }
            if identifier != "BEA01" && identifier != "CD001" { break }
        }
        guard recognized else { return nil }
        let anchor = try await image.bytes(256 * 2048)
        guard try ISOBytes.le(anchor, 0, 2) == 2 else { return nil }
        try validateTag(anchor, id: 2)
        let sequenceLength = try ISOBytes.le(anchor, 16, 4)
        let sequence = try ISOBytes.le(anchor, 20, 4)
        guard sequenceLength > 0, sequenceLength <= 256 * 2048 else { throw Failure.excessiveSize }
        var partitions: [Int64: (start: Int64, count: Int64)] = [:]
        var logical: Data?
        for index in 0..<(sequenceLength / 2048) {
            let data = try await image.bytes((sequence + index) * 2048)
            let id = try ISOBytes.le(data, 0, 2)
            try validateTag(data, id: id)
            if id == 5 {
                let start = try ISOBytes.le(data, 188, 4), count = try ISOBytes.le(data, 192, 4)
                _ = try image.extent(start * 2048, count * 2048)
                partitions[try ISOBytes.le(data, 22, 2)] = (start, count)
            }
            if id == 6 { logical = data }
            if id == 8 { break }
        }
        guard let logical, try ISOBytes.le(logical, 212, 4) == 2048 else { throw Failure.unsupportedLayout }
        let mapCount = try ISOBytes.le(logical, 268, 4), mapBytes = try ISOBytes.le(logical, 264, 4)
        guard mapCount > 0, mapCount <= 32, mapBytes <= 1608 else { throw Failure.unsupportedLayout }
        var maps: [(start: Int64, count: Int64)] = [], p = 440
        for _ in 0..<mapCount {
            guard p + 6 <= 440 + mapBytes, logical[p] == 1, logical[p + 1] == 6,
                  let partition = partitions[try ISOBytes.le(logical, p + 4, 2)] else { throw Failure.unsupportedLayout }
            maps.append(partition); p += 6
        }
        func location(_ block: Int64, _ partition: Int64) throws -> Int64 {
            guard partition >= 0, partition < maps.count, block >= 0,
                  block < maps[Int(partition)].count else { throw Failure.invalidDirectory }
            return (maps[Int(partition)].start + block) * 2048
        }
        let fileSet = try await image.bytes(location(ISOBytes.le(logical, 252, 4), ISOBytes.le(logical, 256, 2)))
        try validateTag(fileSet, id: 256)
        var queue: [(String, Int64, Int64, Int)] = [("", try ISOBytes.le(fileSet, 404, 4), try ISOBytes.le(fileSet, 408, 2), 0)]
        var visited: Set<Int64> = [], output: [File] = []
        while !queue.isEmpty {
            let (path, block, partition, depth) = queue.removeFirst()
            guard depth <= 32, visited.count + output.count + queue.count < 65_536 else { throw Failure.excessiveSize }
            let position = try location(block, partition)
            let entry = try await image.bytes(position)
            let tag = try ISOBytes.le(entry, 0, 2)
            guard tag == 261 || tag == 266 else { throw Failure.unsupportedLayout }
            try validateTag(entry, id: tag)
            let isDirectory = entry[27] == 4
            if isDirectory, !visited.insert(position).inserted { throw Failure.invalidDirectory }
            guard isDirectory || entry[27] == 5 else { continue } // No symlink traversal.
            let count = try ISOBytes.le(entry, 56, 8)
            let allocation = try ISOBytes.le(entry, 34, 2) & 7
            let base = tag == 261 ? 176 : 216
            let attributes = try ISOBytes.le(entry, base - 8, 4)
            let descriptors = try ISOBytes.le(entry, base - 4, 4)
            guard attributes <= 2048 - base, descriptors <= Int64(2048 - base) - attributes else { throw Failure.unsupportedLayout }
            var cursor = base + Int(attributes), remaining = count
            var extents: [Extent] = []
            if allocation == 3 {
                guard count <= descriptors else { throw Failure.truncated }
                extents = [try image.extent(position + Int64(cursor), count)]
            } else {
                guard allocation == 0 || allocation == 1 else { throw Failure.unsupportedLayout }
                let stride = allocation == 0 ? 8 : 16
                let end = cursor + Int(descriptors)
                while cursor + stride <= end, remaining > 0 {
                    let encoded = try ISOBytes.le(entry, cursor, 4)
                    guard encoded >> 30 == 0 else { throw Failure.unsupportedLayout }
                    let length = min(encoded & 0x3fffffff, remaining)
                    let extentBlock = try ISOBytes.le(entry, cursor + 4, 4)
                    let extentPartition = allocation == 0 ? partition : try ISOBytes.le(entry, cursor + 8, 2)
                    let offset = try location(extentBlock, extentPartition)
                    guard length <= (maps[Int(extentPartition)].count - extentBlock) * 2048 else { throw Failure.truncated }
                    extents.append(try image.extent(offset, length))
                    remaining -= length; cursor += stride
                }
                guard remaining == 0 else { throw Failure.truncated }
            }
            let file = File(path: path, extents: extents)
            if !isDirectory { output.append(file); continue }
            guard count <= 4 * 1024 * 1024 else { throw Failure.excessiveSize }
            let data = try await read(file, offset: 0, length: count, using: image.read)
            cursor = 0
            while cursor < data.count {
                guard cursor + 38 <= data.count, try ISOBytes.le(data, cursor, 2) == 257 else { throw Failure.invalidDirectory }
                let nameLength = Int(data[cursor + 19]), implementation = try ISOBytes.le(data, cursor + 36, 2)
                let end = cursor + 38 + Int(implementation) + nameLength
                guard end <= data.count else { throw Failure.invalidDirectory }
                let flags = data[cursor + 18]
                if flags & 12 == 0, nameLength > 1 {
                    let nameData = Data(data[(cursor + 38 + Int(implementation))..<end])
                    let name: String?
                    switch nameData[0] {
                    case 8: name = String(data: nameData.dropFirst(), encoding: .isoLatin1)
                    case 16: name = String(data: nameData.dropFirst(), encoding: .utf16BigEndian)
                    default: throw Failure.unsupportedLayout
                    }
                    guard let name, validComponent(name) else { throw Failure.invalidDirectory }
                    queue.append((path + "/" + name, try ISOBytes.le(data, cursor + 24, 4), try ISOBytes.le(data, cursor + 28, 2), depth + 1))
                }
                cursor = (end + 3) & ~3
            }
        }
        return output.sorted { $0.path < $1.path }
    }

    private static func validComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    private static func validateTag(_ data: Data, id: Int64) throws {
        guard data.count >= 16, try ISOBytes.le(data, 0, 2) == id,
              (0..<16).filter({ $0 != 4 }).reduce(UInt8(0), { $0 &+ data[$1] }) == data[4] else {
            throw Failure.invalidDirectory
        }
    }
}

enum ISOBytes {
    static func le(_ data: Data, _ offset: Int, _ count: Int) throws -> Int64 { try integer(data, offset, count, big: false) }
    static func be(_ data: Data, _ offset: Int, _ count: Int) throws -> Int64 { try integer(data, offset, count, big: true) }
    private static func integer(_ data: Data, _ offset: Int, _ count: Int, big: Bool) throws -> Int64 {
        guard offset >= 0, count <= 8, offset <= data.count - count else { throw DiscImageFileSystem.Failure.truncated }
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(data[offset + index]) << ((big ? count - index - 1 : index) * 8) }
        guard value <= Int64.max else { throw DiscImageFileSystem.Failure.excessiveSize }
        return Int64(value)
    }
}
