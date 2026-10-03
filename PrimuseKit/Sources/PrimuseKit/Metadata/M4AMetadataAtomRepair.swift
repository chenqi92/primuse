import Foundation

/// SFBAudioEngine 0.12.1 写回 M4A 时的毛病,写完后原地修掉:
/// - 专辑写成 `©ALB`(大写)而不是标准的 `©alb`,旧的 `©alb` 原样留着 → `©ALB` 改名为 `©alb`,
///   旧的 `©alb` 去掉;`©ALB` 是空的(专辑被清空)时两者都去掉。
/// - 没填的字段写成空条目、没封面时写一个空 `covr` 盒子。
/// AVFoundation 在条目列表(`ilst`)里遇到空盒子或 `free` 盒子就不往下读,系统和其它播放器会看不到任何标签,
/// 所以这些条目要真的从列表里拿掉:省下的字节并成紧跟在列表后面的一个 `free` 填充盒(在 `ilst` 外面、
/// 仍在 `meta` 里),`meta` 及其上层的长度都不变,文件里别处的偏移一概不用改。
public enum M4AMetadataAtomRepair {
    /// 一处原地改写:从 `offset` 起用等长的 `bytes` 覆盖。
    public struct Rewrite: Equatable, Sendable {
        public var offset: Int
        public var bytes: Data
    }

    public struct Result: Equatable, Sendable {
        public var data: Data
        public var rewrites: [Rewrite]
        public var renamedAlbumItems: Int
        public var removedItems: Int

        public var changed: Bool { !rewrites.isEmpty }
    }

    static let upperAlbum: UInt32 = 0xA9_41_4C_42   // ©ALB
    static let album: UInt32 = 0xA9_61_6C_62        // ©alb
    static let free: UInt32 = 0x66_72_65_65         // free
    static let skip: UInt32 = 0x73_6B_69_70         // skip
    private static let moov: UInt32 = 0x6D_6F_6F_76
    private static let udta: UInt32 = 0x75_64_74_61
    private static let meta: UInt32 = 0x6D_65_74_61
    private static let ilst: UInt32 = 0x69_6C_73_74
    private static let dataAtom: UInt32 = 0x64_61_74_61

    /// 要改写的区段;找不到 moov/…/ilst 时返回 nil(不是 M4A 或者没有 iTunes 标签块)。
    public static func rewrites(in data: Data) -> [Rewrite]? {
        repaired(data)?.rewrites
    }

    public static func repaired(_ input: Data) -> Result? {
        var data = Data(input)
        let metas = metaChildLists(in: data)
        guard metas.contains(where: { children in children.contains { $0.type == ilst } }) else { return nil }
        var rewrites: [Rewrite] = []
        var renamed = 0
        var removed = 0

        for children in metas {
            for (index, list) in children.enumerated() where list.type == ilst && list.header == 8 {
                let items = atoms(in: data, range: list.payload)
                let upperAlbums = items.filter { $0.type == upperAlbum }
                let hasNewAlbumValue = upperAlbums.contains { !isEmptyItem($0, in: data) }
                var kept = Data()
                var removedBytes = 0
                for item in items {
                    let bytes = data[item.start..<item.payload.upperBound]
                    switch item.type {
                    case album where !upperAlbums.isEmpty:
                        removedBytes += bytes.count
                        removed += 1
                    case upperAlbum:
                        if hasNewAlbumValue, !isEmptyItem(item, in: data) {
                            var renamedItem = Data(bytes)
                            renamedItem.replaceSubrange(4..<8, with: fourCC(album))
                            kept.append(renamedItem)
                            renamed += 1
                        } else {
                            removedBytes += bytes.count
                            removed += 1
                        }
                    case free, skip:
                        removedBytes += bytes.count
                        removed += 1
                    default:
                        if isEmptyItem(item, in: data) {
                            removedBytes += bytes.count
                            removed += 1
                        } else {
                            kept.append(bytes)
                        }
                    }
                }
                let renamedHere = items.contains { $0.type == upperAlbum } && hasNewAlbumValue
                guard removedBytes > 0 || renamedHere else { continue }

                // 新的 ilst + 填充;紧跟着的若本来就是 free,并进同一个填充盒。
                var regionEnd = list.payload.upperBound
                var padding = removedBytes
                if index + 1 < children.count {
                    let next = children[index + 1]
                    if (next.type == free || next.type == skip), next.header == 8, next.start == regionEnd {
                        padding += next.payload.upperBound - next.start
                        regionEnd = next.payload.upperBound
                    }
                }
                var region = Data()
                region.append(sizeBytes(8 + kept.count))
                region.append(fourCC(ilst))
                region.append(kept)
                if padding > 0 {
                    // 被删的条目每个至少 8 字节,所以填充放得下一个盒子头。
                    guard padding >= 8 else { continue }
                    region.append(sizeBytes(padding))
                    region.append(fourCC(free))
                    region.append(Data(repeating: 0, count: padding - 8))
                }
                guard region.count == regionEnd - list.start else { continue }
                data.replaceSubrange(list.start..<regionEnd, with: region)
                rewrites.append(Rewrite(offset: list.start, bytes: region))
            }
        }
        return Result(data: data, rewrites: rewrites, renamedAlbumItems: renamed, removedItems: removed)
    }

    private struct Atom {
        let type: UInt32
        let start: Int
        let header: Int
        let payload: Range<Int>
    }

    /// 条目里没有 `data`,或者每个 `data` 都只有类型和区域字段、没有内容。
    private static func isEmptyItem(_ item: Atom, in data: Data) -> Bool {
        let children = atoms(in: data, range: item.payload).filter { $0.type == dataAtom }
        return children.allSatisfy { $0.payload.count <= 8 }
    }

    /// 每个 iTunes `meta` 盒子的子盒子列表(跳过 meta 自己的版本/标志 4 字节)。
    private static func metaChildLists(in data: Data) -> [[Atom]] {
        var result: [[Atom]] = []
        for top in atoms(in: data, range: data.startIndex..<data.endIndex) where top.type == moov {
            var metas: [Atom] = []
            for child in atoms(in: data, range: top.payload) {
                if child.type == meta {
                    metas.append(child)
                } else if child.type == udta {
                    metas += atoms(in: data, range: child.payload).filter { $0.type == meta }
                }
            }
            for metaAtom in metas where metaAtom.payload.count >= 4 {
                result.append(atoms(in: data, range: (metaAtom.payload.lowerBound + 4)..<metaAtom.payload.upperBound))
            }
        }
        return result
    }

    private static func atoms(in data: Data, range: Range<Int>) -> [Atom] {
        var result: [Atom] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            guard let size32 = readUInt32(data, at: cursor),
                  let type = readUInt32(data, at: cursor + 4) else { break }
            var header = 8
            var size = Int(size32)
            if size32 == 1 {
                guard cursor + 16 <= range.upperBound,
                      let high = readUInt32(data, at: cursor + 8),
                      let low = readUInt32(data, at: cursor + 12) else { break }
                let large = (UInt64(high) << 32) | UInt64(low)
                guard large <= UInt64(Int.max) else { break }
                size = Int(large)
                header = 16
            } else if size32 == 0 {
                size = range.upperBound - cursor
            }
            guard size >= header, cursor + size <= range.upperBound else { break }
            result.append(Atom(type: type, start: cursor, header: header, payload: (cursor + header)..<(cursor + size)))
            cursor += size
        }
        return result
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else { return nil }
        return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func sizeBytes(_ size: Int) -> Data {
        let value = UInt32(size)
        return Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func fourCC(_ type: UInt32) -> Data {
        Data([UInt8(type >> 24 & 0xFF), UInt8(type >> 16 & 0xFF), UInt8(type >> 8 & 0xFF), UInt8(type & 0xFF)])
    }
}
