import CryptoKit
import Foundation

// MARK: - 读同步索引的统一接口

/// 能逐条读出同步索引的东西:已提交的紧凑索引 `SourceSyncIndex`,以及扫描过程中
/// 现建现用的 `[String: SourceSyncIndexedItem]`。只读条目的策略写成对它泛型,
/// 两种都能直接传进来,不必为了调用先把紧凑索引展开成字典。
public protocol SourceSyncIndexContents {
    associatedtype ItemValues: Collection where ItemValues.Element == SourceSyncIndexedItem
    var values: ItemValues { get }
    var isEmpty: Bool { get }
    var count: Int { get }
    subscript(key: String) -> SourceSyncIndexedItem? { get set }
}

extension Dictionary: SourceSyncIndexContents where Key == String, Value == SourceSyncIndexedItem {}

// MARK: - 紧凑同步索引

/// 一个源已提交的同步索引:条目键 → `SourceSyncIndexedItem`。
///
/// 语义就是 `[String: SourceSyncIndexedItem]`:键按 `String` 的相等(规范等价)查找,
/// 条目逐字段比较,读出来的值与存进去的逐字节相同。不同的只是存法:
/// - 所有字符串的 UTF-8 字节放进同一块连续缓冲,每行只记偏移和长度;
/// - 一个目录的路径在它自己那一行和所有子项的 `parentPath` 里只存一份;
/// - `hierarchy-song:<歌曲 ID>`、`hierarchy-folder:<目录路径>` 这类键不另存,
///   与那首歌的 ID / 那个目录的路径共用字节;`stableKey` 等于键时也不另存。
///
/// 服务器源一首歌一行。45 万首时原来的字典(每行十来个独立的字符串、数组对象和
/// 一个哈希桶)常驻约 340MB,这样存约 110MB;定长部分能整块写进每个源自己的
/// 文件、整块读回(`SourceSyncStateDirectory`),冷启动不必再解一整份 JSON。
///
/// 条目是读的时候现建的。成批读请顺序遍历(`values`、`for (key, item) in index`):
/// 遍历时同一目录的路径会复用同一个字符串。
public struct SourceSyncIndex: Sendable {
    @usableFromInline var storage: Storage

    public init() {
        storage = Storage(minimumCapacity: 0)
    }

    public init(minimumCapacity: Int) {
        storage = Storage(minimumCapacity: minimumCapacity)
    }

    public init(_ dictionary: [String: SourceSyncIndexedItem]) {
        var builder = Builder(minimumCapacity: dictionary.count)
        for (key, item) in dictionary {
            builder.insert(item, forKey: key)
        }
        self = builder.build()
    }

    init(storage: Storage) {
        self.storage = storage
    }

    public var count: Int { storage.liveCount }
    public var isEmpty: Bool { storage.liveCount == 0 }

    public subscript(key: String) -> SourceSyncIndexedItem? {
        get {
            guard let found = storage.find(key) else { return nil }
            return storage.item(at: found.row)
        }
        set {
            if let newValue {
                updateValue(newValue, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    public func contains(key: String) -> Bool {
        storage.find(key) != nil
    }

    @discardableResult
    public mutating func updateValue(
        _ item: SourceSyncIndexedItem,
        forKey key: String
    ) -> SourceSyncIndexedItem? {
        makeUnique()
        var interner: Interner?
        return storage.set(item, forKey: key, hash: Storage.hash(of: key), interner: &interner)
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> SourceSyncIndexedItem? {
        guard storage.find(key) != nil else { return nil }
        makeUnique()
        // 复制会压掉作废的行,行号随之变化:复制之后重新找一次。
        guard let current = storage.find(key) else { return nil }
        let previous = storage.item(at: current.row)
        storage.remove(slot: current.slot, row: current.row)
        storage.compactIfWasteful()
        return previous
    }

    public mutating func removeAll() {
        storage = Storage(minimumCapacity: 0)
    }

    /// 展开成普通字典。只给扫描时要整体改写索引的路径用:服务器源 45 万首时
    /// 展开后的字典约 340MB,常驻的那一份始终是紧凑的这份。
    public var dictionary: [String: SourceSyncIndexedItem] {
        var result: [String: SourceSyncIndexedItem] = [:]
        result.reserveCapacity(count)
        for (key, item) in self {
            result[key] = item
        }
        return result
    }

    /// 两份索引是不是同一块存储(没被改过的同一份)。比 `==` 便宜,
    /// 只用来跳过「内容一定相同」的比较与重写。
    public func isIdentical(to other: SourceSyncIndex) -> Bool {
        storage === other.storage
    }

    @usableFromInline
    mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
    }
}

// MARK: - Collection views

extension SourceSyncIndex: Sequence {
    public typealias Element = (key: String, value: SourceSyncIndexedItem)

    public struct Iterator: IteratorProtocol {
        let storage: Storage
        var row = 0
        var cache = SharedStringCache()

        public mutating func next() -> (key: String, value: SourceSyncIndexedItem)? {
            while row < storage.rows.count {
                let current = row
                row += 1
                guard storage.isLive(current) else { continue }
                return (storage.key(at: current), storage.item(at: current, cache: &cache))
            }
            return nil
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(storage: storage)
    }

    public var underestimatedCount: Int { count }

    public var values: Values { Values(storage: storage) }
    public var keys: Keys { Keys(storage: storage) }

    /// 按行号排列的条目。下标是行号,只在没改过的同一份索引里有效。
    public struct Values: Collection {
        let storage: Storage

        public typealias Index = Int

        public var startIndex: Int { storage.nextLiveRow(from: 0) }
        public var endIndex: Int { storage.rows.count }
        public var count: Int { storage.liveCount }
        public var isEmpty: Bool { storage.liveCount == 0 }

        public func index(after i: Int) -> Int {
            storage.nextLiveRow(from: i + 1)
        }

        public subscript(position: Int) -> SourceSyncIndexedItem {
            storage.item(at: position)
        }

        public struct Iterator: IteratorProtocol {
            let storage: Storage
            var row = 0
            var cache = SharedStringCache()

            public mutating func next() -> SourceSyncIndexedItem? {
                while row < storage.rows.count {
                    let current = row
                    row += 1
                    guard storage.isLive(current) else { continue }
                    return storage.item(at: current, cache: &cache)
                }
                return nil
            }
        }

        public func makeIterator() -> Iterator {
            Iterator(storage: storage)
        }

        public var underestimatedCount: Int { storage.liveCount }
    }

    public struct Keys: Collection {
        let storage: Storage

        public typealias Index = Int

        public var startIndex: Int { storage.nextLiveRow(from: 0) }
        public var endIndex: Int { storage.rows.count }
        public var count: Int { storage.liveCount }
        public var isEmpty: Bool { storage.liveCount == 0 }

        public func index(after i: Int) -> Int {
            storage.nextLiveRow(from: i + 1)
        }

        public subscript(position: Int) -> String {
            storage.key(at: position)
        }

        public var underestimatedCount: Int { storage.liveCount }
    }
}

extension SourceSyncIndex: SourceSyncIndexContents {}

extension SourceSyncIndex: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, SourceSyncIndexedItem)...) {
        var builder = Builder(minimumCapacity: elements.count)
        for (key, item) in elements {
            builder.insert(item, forKey: key)
        }
        self = builder.build()
    }
}

// MARK: - Equality

extension SourceSyncIndex: Equatable {
    /// 与 `[String: SourceSyncIndexedItem]` 的 `==` 同义:同样多的键,每个键在另一边
    /// 找得到(按 String 相等),对应条目逐字段相等。
    public static func == (lhs: SourceSyncIndex, rhs: SourceSyncIndex) -> Bool {
        if lhs.storage === rhs.storage { return true }
        guard lhs.count == rhs.count else { return false }
        let left = lhs.storage
        let right = rhs.storage
        for row in 0..<left.rows.count where left.isLive(row) {
            guard let match = right.find(matchingKeyOf: row, in: left),
                  Storage.rowsEqual(row, in: left, match, in: right) else { return false }
        }
        return true
    }
}

// MARK: - Codable

extension SourceSyncIndex: Codable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// 与 `[String: SourceSyncIndexedItem]` 的 JSON 形状完全一样(一个以条目键为键的对象),
    /// 旧版本写的 `source-sync-states.json` 能直接解进来,解的同时就存成紧凑形式,
    /// 不必先建一整本字典。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        let keys = container.allKeys
        var builder = Builder(minimumCapacity: keys.count)
        for key in keys {
            try autoreleasepool {
                let item = try container.decode(SourceSyncIndexedItem.self, forKey: key)
                builder.insert(item, forKey: key.stringValue)
            }
        }
        self = builder.build()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, item) in self {
            try container.encode(item, forKey: DynamicKey(stringValue: key))
        }
    }
}

#if !canImport(ObjectiveC)
@inline(__always)
private func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

// MARK: - Bulk construction

extension SourceSyncIndex {
    /// 成批建索引。同一个目录路径(目录行自己的 `path` 与子项的 `parentPath`)只存一份字节。
    public struct Builder {
        private var storage: Storage
        private var interner: Interner? = Interner()

        public init(minimumCapacity: Int = 0) {
            storage = Storage(minimumCapacity: minimumCapacity)
        }

        /// 已有同一个键时替换它(和字典下标赋值一样保留原来那个键)。
        public mutating func insert(_ item: SourceSyncIndexedItem, forKey key: String) {
            _ = storage.set(item, forKey: key, hash: Storage.hash(of: key), interner: &interner)
        }

        public var count: Int { storage.liveCount }

        /// 交出建好的索引。之后这个构建器从空的重新开始,不会再改到交出去的那份。
        public mutating func build() -> SourceSyncIndex {
            let built = storage
            built.shrinkToFit()
            storage = Storage(minimumCapacity: 0)
            interner = Interner()
            return SourceSyncIndex(storage: built)
        }
    }
}

// MARK: - Storage

extension SourceSyncIndex {
    struct Span: Equatable {
        var offset: UInt32
        var length: UInt32
    }

    /// 一行的定长部分。字段全是 4/8 字节整数、没有填充,整块内存能原样写进文件、
    /// 原样读回来(布局变了要改 `binaryFormatVersion`)。
    struct Row {
        var keyOffset: UInt32 = 0
        var keyLength: UInt32 = 0
        var stableKeyOffset: UInt32 = 0
        var stableKeyLength: UInt32 = 0
        var pathOffset: UInt32 = 0
        var pathLength: UInt32 = 0
        var displayNameOffset: UInt32 = 0
        var displayNameLength: UInt32 = 0
        var parentOffset: UInt32 = 0
        var parentLength: UInt32 = 0
        var revisionOffset: UInt32 = 0
        var revisionLength: UInt32 = 0
        var sidecarOffset: UInt32 = 0
        var sidecarLength: UInt32 = 0
        /// 只有一首歌(`RowFlag.singleSongID`)时是那首歌 ID 的偏移与长度;
        /// 否则是 `songIDSpans` 里的起点与个数。
        var songIDsFirst: UInt32 = 0
        var songIDsSecond: UInt32 = 0
        var size: Int64 = 0
        var modifiedDateBits: UInt64 = 0
        var seenEpoch: Int64 = 0
        var flags: UInt32 = 0
        var reserved: UInt32 = 0
    }

    enum RowFlag {
        static let isDirectory: UInt32 = 1 << 0
        static let hasModifiedDate: UInt32 = 1 << 1
        static let stableKeyIsKey: UInt32 = 1 << 2
        static let hasDisplayName: UInt32 = 1 << 3
        static let hasParent: UInt32 = 1 << 4
        static let hasRevision: UInt32 = 1 << 5
        static let hasSidecar: UInt32 = 1 << 6
        static let singleSongID: UInt32 = 1 << 7
        static let keyIsASCII: UInt32 = 1 << 8
        /// 只在内存里用:被删除或被替换掉的行。写文件时跳过,不会落盘。
        static let dead: UInt32 = 1 << 15
        static let keyPrefixShift: UInt32 = 16
        static let keyPrefixMask: UInt32 = 0xF << 16
        static let knownMask: UInt32 = 0x1FF | keyPrefixMask
    }

    /// 键的常见前缀,按编号存在行标志里。编号写进了文件,只能往后加、不能改顺序。
    static let keyPrefixes: [[UInt8]] = [
        [],
        Array("hierarchy-song:".utf8),
        Array("hierarchy-folder:".utf8),
        Array("hierarchy-root:".utf8),
        Array("path:".utf8),
    ]

    /// 构建时同一个目录路径只存一份。按字节比较,规范等价但写法不同的路径各存各的。
    struct Interner {
        var spans: [String: Span] = [:]
    }

    /// 遍历时复用同一个目录路径的字符串:一个专辑目录下几十首歌的 `parentPath`
    /// 读出来是同一个对象,不是几十份拷贝。
    struct SharedStringCache {
        var keys = [UInt64](repeating: .max, count: 16)
        var strings = [String](repeating: "", count: 16)

        mutating func string(_ offset: UInt32, _ length: UInt32, in storage: Storage) -> String {
            guard length > 15 else { return storage.string(offset, length) }
            let tag = UInt64(offset) << 32 | UInt64(length)
            let slot = Int((offset ^ (offset >> 7)) & 15)
            if keys[slot] == tag { return strings[slot] }
            let value = storage.string(offset, length)
            keys[slot] = tag
            strings[slot] = value
            return value
        }
    }

    @usableFromInline
    final class Storage: @unchecked Sendable {
        var rows: [Row] = []
        var arena: [UInt8] = []
        var songIDSpans: [Span] = []
        /// 每行键的 `String.hashValue`(规范等价的键哈希相同)。哈希种子每个进程不同,
        /// 只在内存里用,读文件时重算。
        var hashes: [UInt32] = []
        /// 开放寻址表:行号,`emptySlot` 为空,`tombstone` 为删除留下的墓碑。
        var slots: [Int32] = []
        var liveCount = 0
        var deadCount = 0
        var tombstoneCount = 0

        static let emptySlot: Int32 = -1
        static let tombstone: Int32 = -2

        init(minimumCapacity: Int) {
            if minimumCapacity > 0 {
                rows.reserveCapacity(minimumCapacity)
                hashes.reserveCapacity(minimumCapacity)
                slots = [Int32](repeating: Self.emptySlot, count: Self.slotCount(for: minimumCapacity))
            }
        }

        private init(copying other: Storage) {
            rows = other.rows
            arena = other.arena
            songIDSpans = other.songIDSpans
            hashes = other.hashes
            slots = other.slots
            liveCount = other.liveCount
            deadCount = other.deadCount
            tombstoneCount = other.tombstoneCount
        }

        /// 写时复制。没有作废行时数组本身也是写时复制的,改到哪个才真的拷哪个;
        /// 有作废行就顺便压掉,反正要整份拷。
        func copy() -> Storage {
            deadCount == 0 ? Storage(copying: self) : compacted()
        }

        static func slotCount(for count: Int) -> Int {
            Swift.max(8, count + count / 2 + 1)
        }

        static func hash(of key: String) -> UInt32 {
            UInt32(truncatingIfNeeded: key.hashValue)
        }

        @inline(__always)
        func isLive(_ row: Int) -> Bool {
            rows[row].flags & RowFlag.dead == 0
        }

        func nextLiveRow(from start: Int) -> Int {
            var row = start
            while row < rows.count, !isLive(row) { row += 1 }
            return row
        }

        @inline(__always)
        private func slotIndex(for hash: UInt32) -> Int {
            Int((UInt64(hash) &* UInt64(slots.count)) >> 32)
        }

        // MARK: Strings

        func string(_ offset: UInt32, _ length: UInt32) -> String {
            guard length > 0 else { return "" }
            return arena.withUnsafeBufferPointer { buffer in
                String(
                    decoding: UnsafeBufferPointer(
                        rebasing: buffer[Int(offset)..<Int(offset) + Int(length)]
                    ),
                    as: UTF8.self
                )
            }
        }

        func key(at row: Int) -> String {
            let value = rows[row]
            let prefix = SourceSyncIndex.keyPrefixes[Int((value.flags & RowFlag.keyPrefixMask) >> RowFlag.keyPrefixShift)]
            guard !prefix.isEmpty else { return string(value.keyOffset, value.keyLength) }
            let total = prefix.count + Int(value.keyLength)
            return arena.withUnsafeBufferPointer { buffer in
                String(unsafeUninitializedCapacity: total) { output in
                    _ = output.initialize(from: prefix)
                    if value.keyLength > 0 {
                        let suffix = UnsafeBufferPointer(
                            rebasing: buffer[Int(value.keyOffset)..<Int(value.keyOffset) + Int(value.keyLength)]
                        )
                        _ = UnsafeMutableBufferPointer(rebasing: output[prefix.count...]).initialize(from: suffix)
                    }
                    return total
                }
            }
        }

        func item(at row: Int) -> SourceSyncIndexedItem {
            makeItem(at: row) { self.string($0, $1) }
        }

        func item(at row: Int, cache: inout SharedStringCache) -> SourceSyncIndexedItem {
            makeItem(at: row) { cache.string($0, $1, in: self) }
        }

        private func makeItem(
            at row: Int,
            shared: (UInt32, UInt32) -> String
        ) -> SourceSyncIndexedItem {
            let value = rows[row]
            let flags = value.flags
            let key = key(at: row)
            let isDirectory = flags & RowFlag.isDirectory != 0
            var songIDs: [String] = []
            if flags & RowFlag.singleSongID != 0 {
                songIDs = [string(value.songIDsFirst, value.songIDsSecond)]
            } else if value.songIDsSecond > 0 {
                songIDs.reserveCapacity(Int(value.songIDsSecond))
                for index in Int(value.songIDsFirst)..<Int(value.songIDsFirst) + Int(value.songIDsSecond) {
                    let span = songIDSpans[index]
                    songIDs.append(string(span.offset, span.length))
                }
            }
            return SourceSyncIndexedItem(
                stableKey: flags & RowFlag.stableKeyIsKey != 0
                    ? key
                    : string(value.stableKeyOffset, value.stableKeyLength),
                path: isDirectory ? shared(value.pathOffset, value.pathLength) : string(value.pathOffset, value.pathLength),
                displayName: flags & RowFlag.hasDisplayName != 0
                    ? string(value.displayNameOffset, value.displayNameLength)
                    : nil,
                parentPath: flags & RowFlag.hasParent != 0
                    ? shared(value.parentOffset, value.parentLength)
                    : nil,
                isDirectory: isDirectory,
                songIDs: songIDs,
                size: value.size,
                modifiedDate: flags & RowFlag.hasModifiedDate != 0
                    ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: value.modifiedDateBits))
                    : nil,
                revision: flags & RowFlag.hasRevision != 0
                    ? string(value.revisionOffset, value.revisionLength)
                    : nil,
                sidecarFingerprint: flags & RowFlag.hasSidecar != 0
                    ? string(value.sidecarOffset, value.sidecarLength)
                    : nil,
                seenEpoch: value.seenEpoch
            )
        }

        // MARK: Lookup

        func find(_ key: String) -> (slot: Int, row: Int)? {
            guard liveCount > 0 else { return nil }
            return find(key, hash: Self.hash(of: key))
        }

        func find(_ key: String, hash: UInt32) -> (slot: Int, row: Int)? {
            guard !slots.isEmpty else { return nil }
            var query = key
            return query.withUTF8 { queryBytes in
                var queryIsASCII: Bool?
                var slot = slotIndex(for: hash)
                while true {
                    let row = slots[slot]
                    if row == Self.emptySlot { return nil }
                    if row >= 0, hashes[Int(row)] == hash {
                        if keyBytesEqual(row: Int(row), queryBytes) { return (slot, Int(row)) }
                        // 字节不同、却仍可能是同一个 String(规范等价):只有不全是 ASCII 时才会。
                        if queryIsASCII == nil { queryIsASCII = !queryBytes.contains { $0 >= 0x80 } }
                        if !(queryIsASCII! && rows[Int(row)].flags & RowFlag.keyIsASCII != 0),
                           self.key(at: Int(row)) == key {
                            return (slot, Int(row))
                        }
                    }
                    slot += 1
                    if slot == slots.count { slot = 0 }
                }
            }
        }

        /// 在这份索引里找另一份索引第 `row` 行的那个键。
        func find(matchingKeyOf row: Int, in other: Storage) -> Int? {
            guard !slots.isEmpty else { return nil }
            let hash = other.hashes[row]
            let otherRow = other.rows[row]
            let otherPrefix = otherRow.flags & RowFlag.keyPrefixMask
            var slot = slotIndex(for: hash)
            while true {
                let candidate = slots[slot]
                if candidate == Self.emptySlot { return nil }
                if candidate >= 0, hashes[Int(candidate)] == hash {
                    let mine = rows[Int(candidate)]
                    if mine.flags & RowFlag.keyPrefixMask == otherPrefix,
                       Self.bytesEqual(self, mine.keyOffset, mine.keyLength, other, otherRow.keyOffset, otherRow.keyLength) {
                        return Int(candidate)
                    }
                    let bothASCII = mine.flags & otherRow.flags & RowFlag.keyIsASCII != 0
                    if !(bothASCII && mine.flags & RowFlag.keyPrefixMask == otherPrefix),
                       key(at: Int(candidate)) == other.key(at: row) {
                        return Int(candidate)
                    }
                }
                slot += 1
                if slot == slots.count { slot = 0 }
            }
        }

        private func keyBytesEqual(row: Int, _ query: UnsafeBufferPointer<UInt8>) -> Bool {
            let value = rows[row]
            let prefix = SourceSyncIndex.keyPrefixes[Int((value.flags & RowFlag.keyPrefixMask) >> RowFlag.keyPrefixShift)]
            guard query.count == prefix.count + Int(value.keyLength) else { return false }
            if !prefix.isEmpty {
                let prefixMatches = prefix.withUnsafeBufferPointer { prefixBytes in
                    memcmp(query.baseAddress!, prefixBytes.baseAddress!, prefix.count) == 0
                }
                guard prefixMatches else { return false }
            }
            guard value.keyLength > 0 else { return true }
            return arena.withUnsafeBufferPointer { buffer in
                memcmp(query.baseAddress! + prefix.count, buffer.baseAddress! + Int(value.keyOffset), Int(value.keyLength)) == 0
            }
        }

        static func bytesEqual(
            _ lhs: Storage, _ lhsOffset: UInt32, _ lhsLength: UInt32,
            _ rhs: Storage, _ rhsOffset: UInt32, _ rhsLength: UInt32
        ) -> Bool {
            guard lhsLength == rhsLength else { return false }
            guard lhsLength > 0 else { return true }
            return lhs.arena.withUnsafeBufferPointer { left in
                rhs.arena.withUnsafeBufferPointer { right in
                    memcmp(left.baseAddress! + Int(lhsOffset), right.baseAddress! + Int(rhsOffset), Int(lhsLength)) == 0
                }
            }
        }

        private func spanBytesEqual(_ offset: UInt32, _ length: UInt32, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            guard Int(length) == bytes.count else { return false }
            guard length > 0 else { return true }
            return arena.withUnsafeBufferPointer { buffer in
                memcmp(buffer.baseAddress! + Int(offset), bytes.baseAddress!, bytes.count) == 0
            }
        }

        /// 两个字符串字段是否相等(`String ==` 的语义):字节相同一定相等;
        /// 字节不同而且都是 ASCII 一定不等;否则取出来按 String 比。
        private static func stringsEqual(
            _ lhs: Storage, _ lhsOffset: UInt32, _ lhsLength: UInt32,
            _ rhs: Storage, _ rhsOffset: UInt32, _ rhsLength: UInt32
        ) -> Bool {
            if bytesEqual(lhs, lhsOffset, lhsLength, rhs, rhsOffset, rhsLength) { return true }
            if lhs.isASCII(lhsOffset, lhsLength), rhs.isASCII(rhsOffset, rhsLength) { return false }
            return lhs.string(lhsOffset, lhsLength) == rhs.string(rhsOffset, rhsLength)
        }

        private func isASCII(_ offset: UInt32, _ length: UInt32) -> Bool {
            guard length > 0 else { return true }
            return arena.withUnsafeBufferPointer { buffer in
                !UnsafeBufferPointer(rebasing: buffer[Int(offset)..<Int(offset) + Int(length)]).contains { $0 >= 0x80 }
            }
        }

        /// 两行除键以外的字段逐个比较(键已经由调用方按 String 相等对上了)。
        static func rowsEqual(_ lhsRow: Int, in lhs: Storage, _ rhsRow: Int, in rhs: Storage) -> Bool {
            let left = lhs.rows[lhsRow]
            let right = rhs.rows[rhsRow]
            let relevant = RowFlag.isDirectory | RowFlag.hasModifiedDate | RowFlag.hasDisplayName
                | RowFlag.hasParent | RowFlag.hasRevision | RowFlag.hasSidecar
            guard left.flags & relevant == right.flags & relevant,
                  left.size == right.size,
                  left.seenEpoch == right.seenEpoch else { return false }
            if left.flags & RowFlag.hasModifiedDate != 0,
               Double(bitPattern: left.modifiedDateBits) != Double(bitPattern: right.modifiedDateBits) {
                return false
            }
            // stableKey:两边都记「同键」时,键已经由调用方按 String 相等对上了。
            let leftStableIsKey = left.flags & RowFlag.stableKeyIsKey != 0
            let rightStableIsKey = right.flags & RowFlag.stableKeyIsKey != 0
            if !leftStableIsKey, !rightStableIsKey {
                guard stringsEqual(lhs, left.stableKeyOffset, left.stableKeyLength,
                                   rhs, right.stableKeyOffset, right.stableKeyLength) else { return false }
            } else if leftStableIsKey != rightStableIsKey {
                let leftStable = leftStableIsKey
                    ? lhs.key(at: lhsRow) : lhs.string(left.stableKeyOffset, left.stableKeyLength)
                let rightStable = rightStableIsKey
                    ? rhs.key(at: rhsRow) : rhs.string(right.stableKeyOffset, right.stableKeyLength)
                guard leftStable == rightStable else { return false }
            }
            guard stringsEqual(lhs, left.pathOffset, left.pathLength, rhs, right.pathOffset, right.pathLength) else {
                return false
            }
            if left.flags & RowFlag.hasDisplayName != 0,
               !stringsEqual(lhs, left.displayNameOffset, left.displayNameLength,
                             rhs, right.displayNameOffset, right.displayNameLength) {
                return false
            }
            if left.flags & RowFlag.hasParent != 0,
               !stringsEqual(lhs, left.parentOffset, left.parentLength, rhs, right.parentOffset, right.parentLength) {
                return false
            }
            if left.flags & RowFlag.hasRevision != 0,
               !stringsEqual(lhs, left.revisionOffset, left.revisionLength,
                             rhs, right.revisionOffset, right.revisionLength) {
                return false
            }
            if left.flags & RowFlag.hasSidecar != 0,
               !stringsEqual(lhs, left.sidecarOffset, left.sidecarLength,
                             rhs, right.sidecarOffset, right.sidecarLength) {
                return false
            }
            let leftSongs = lhs.songIDSpanList(left)
            let rightSongs = rhs.songIDSpanList(right)
            guard leftSongs.count == rightSongs.count else { return false }
            for (leftSong, rightSong) in zip(leftSongs, rightSongs)
            where !stringsEqual(lhs, leftSong.offset, leftSong.length, rhs, rightSong.offset, rightSong.length) {
                return false
            }
            return true
        }

        private func songIDSpanList(_ row: Row) -> [Span] {
            if row.flags & RowFlag.singleSongID != 0 {
                return [Span(offset: row.songIDsFirst, length: row.songIDsSecond)]
            }
            guard row.songIDsSecond > 0 else { return [] }
            return Array(songIDSpans[Int(row.songIDsFirst)..<Int(row.songIDsFirst) + Int(row.songIDsSecond)])
        }

        // MARK: Mutation

        private func append(_ value: String) -> Span {
            var value = value
            return value.withUTF8 { append($0) }
        }

        private func append(_ bytes: UnsafeBufferPointer<UInt8>) -> Span {
            let offset = arena.count
            precondition(offset + bytes.count < Int(UInt32.max), "Source sync index arena exceeds 4 GB")
            arena.append(contentsOf: bytes)
            return Span(offset: UInt32(offset), length: UInt32(bytes.count))
        }

        private func intern(_ value: String, _ interner: inout Interner?) -> Span {
            guard interner != nil else { return append(value) }
            let key = value
            var bytesSource = value
            return bytesSource.withUTF8 { bytes in
                if let existing = interner!.spans[key],
                   spanBytesEqual(existing.offset, existing.length, bytes) {
                    return existing
                }
                let span = append(bytes)
                interner!.spans[key] = span
                return span
            }
        }

        private func makeRow(key: String, item: SourceSyncIndexedItem, interner: inout Interner?) -> Row {
            var row = Row()
            var flags: UInt32 = 0
            if item.isDirectory { flags |= RowFlag.isDirectory }
            // 目录路径还会作为子项的 parentPath 出现,共用一份。
            let path = item.isDirectory ? intern(item.path, &interner) : append(item.path)
            row.pathOffset = path.offset
            row.pathLength = path.length
            if let parent = item.parentPath {
                flags |= RowFlag.hasParent
                let span = intern(parent, &interner)
                row.parentOffset = span.offset
                row.parentLength = span.length
            }
            if let name = item.displayName {
                flags |= RowFlag.hasDisplayName
                let span = append(name)
                row.displayNameOffset = span.offset
                row.displayNameLength = span.length
            }
            if let revision = item.revision {
                flags |= RowFlag.hasRevision
                let span = append(revision)
                row.revisionOffset = span.offset
                row.revisionLength = span.length
            }
            if let sidecar = item.sidecarFingerprint {
                flags |= RowFlag.hasSidecar
                let span = append(sidecar)
                row.sidecarOffset = span.offset
                row.sidecarLength = span.length
            }
            var singleSong: Span?
            if item.songIDs.count == 1 {
                flags |= RowFlag.singleSongID
                let span = append(item.songIDs[0])
                singleSong = span
                row.songIDsFirst = span.offset
                row.songIDsSecond = span.length
            } else {
                row.songIDsFirst = UInt32(songIDSpans.count)
                row.songIDsSecond = UInt32(item.songIDs.count)
                for songID in item.songIDs {
                    songIDSpans.append(append(songID))
                }
            }

            var key = key
            key.withUTF8 { keyBytes in
                if !keyBytes.contains(where: { $0 >= 0x80 }) { flags |= RowFlag.keyIsASCII }
                var prefixID = 0
                for (candidate, prefix) in SourceSyncIndex.keyPrefixes.enumerated()
                where !prefix.isEmpty && prefix.count <= keyBytes.count
                    && prefix.count > SourceSyncIndex.keyPrefixes[prefixID].count {
                    let matches = prefix.withUnsafeBufferPointer { prefixBytes in
                        memcmp(keyBytes.baseAddress!, prefixBytes.baseAddress!, prefix.count) == 0
                    }
                    if matches { prefixID = candidate }
                }
                let suffix = UnsafeBufferPointer(rebasing: keyBytes[SourceSyncIndex.keyPrefixes[prefixID].count...])
                flags |= UInt32(prefixID) << RowFlag.keyPrefixShift
                // 键常常就是「前缀 + 歌曲 ID」或「前缀 + 路径」,那就指向已存的那份字节。
                let span: Span
                if let singleSong, spanBytesEqual(singleSong.offset, singleSong.length, suffix) {
                    span = singleSong
                } else if spanBytesEqual(path.offset, path.length, suffix) {
                    span = path
                } else {
                    span = append(suffix)
                }
                row.keyOffset = span.offset
                row.keyLength = span.length
                let stableIsKey = item.stableKey.utf8.count == keyBytes.count
                    && item.stableKey.utf8.elementsEqual(keyBytes)
                if stableIsKey {
                    flags |= RowFlag.stableKeyIsKey
                }
            }
            if flags & RowFlag.stableKeyIsKey == 0 {
                let span = append(item.stableKey)
                row.stableKeyOffset = span.offset
                row.stableKeyLength = span.length
            }
            row.size = item.size
            if let date = item.modifiedDate {
                flags |= RowFlag.hasModifiedDate
                row.modifiedDateBits = date.timeIntervalSinceReferenceDate.bitPattern
            }
            row.seenEpoch = item.seenEpoch
            row.flags = flags
            return row
        }

        /// 设定一个键的条目,返回原来的条目。已有这个键时保留原来那个键的写法(与字典一致)。
        func set(
            _ item: SourceSyncIndexedItem,
            forKey key: String,
            hash: UInt32,
            interner: inout Interner?
        ) -> SourceSyncIndexedItem? {
            if let existing = find(key, hash: hash) {
                let previous = self.item(at: existing.row)
                let originalKey = self.key(at: existing.row)
                let row = makeRow(key: originalKey, item: item, interner: &interner)
                rows[existing.row].flags |= RowFlag.dead
                deadCount += 1
                rows.append(row)
                hashes.append(hashes[existing.row])
                slots[existing.slot] = Int32(rows.count - 1)
                compactIfWasteful()
                return previous
            }
            growSlotsIfNeeded()
            let row = makeRow(key: key, item: item, interner: &interner)
            rows.append(row)
            hashes.append(hash)
            precondition(rows.count < Int(Int32.max), "Source sync index exceeds Int32 rows")
            insertSlot(row: Int32(rows.count - 1), hash: hash)
            liveCount += 1
            return nil
        }

        func remove(slot: Int, row: Int) {
            slots[slot] = Self.tombstone
            rows[row].flags |= RowFlag.dead
            liveCount -= 1
            deadCount += 1
            tombstoneCount += 1
        }

        private func insertSlot(row: Int32, hash: UInt32) {
            var slot = slotIndex(for: hash)
            while slots[slot] >= 0 {
                slot += 1
                if slot == slots.count { slot = 0 }
            }
            if slots[slot] == Self.tombstone { tombstoneCount -= 1 }
            slots[slot] = row
        }

        private func growSlotsIfNeeded() {
            // 占用(含墓碑)超过四分之三就按存活行数重建:线性探测在这个负载下
            // 未命中平均不到 9 次比较。
            let occupied = liveCount + tombstoneCount + 1
            guard slots.isEmpty || occupied * 4 > slots.count * 3 else { return }
            // 逐行加进来时翻倍扩,摊下来每行只重排常数次。
            rebuildSlots(slotCount: Swift.max(8, (liveCount + 1) * 2))
        }

        func rebuildSlots(slotCount: Int) {
            slots = [Int32](repeating: Self.emptySlot, count: slotCount)
            tombstoneCount = 0
            for row in rows.indices where isLive(row) {
                insertSlot(row: Int32(row), hash: hashes[row])
            }
        }

        /// 数组按倍数长,建完可能空着近一半容量(45 万行时行表空出几十 MB)。
        /// 明显多出来时拷进刚好大小的数组,旧的随即释放。
        func shrinkToFit() {
            func trimmed<Element>(_ array: [Element]) -> [Element]? {
                guard array.capacity > array.count + array.count / 8 + 64 else { return nil }
                return [Element](unsafeUninitializedCapacity: array.count) { buffer, initialized in
                    _ = buffer.initialize(from: array)
                    initialized = array.count
                }
            }
            if let value = trimmed(rows) { rows = value }
            if let value = trimmed(arena) { arena = value }
            if let value = trimmed(songIDSpans) { songIDSpans = value }
            if let value = trimmed(hashes) { hashes = value }
        }

        /// 改得多了作废行占一半以上时就地压一次;只改几行的不动。
        func compactIfWasteful() {
            guard deadCount > 4_096, deadCount > liveCount else { return }
            let compacted = compacted()
            rows = compacted.rows
            arena = compacted.arena
            songIDSpans = compacted.songIDSpans
            hashes = compacted.hashes
            slots = compacted.slots
            liveCount = compacted.liveCount
            deadCount = 0
            tombstoneCount = 0
        }

        /// 只留存活行的一份拷贝。同一段字节(共用的目录路径、键与歌曲 ID 共用的字节)
        /// 拷过去仍是同一段。
        func compacted() -> Storage {
            let result = Storage(minimumCapacity: 0)
            result.rows.reserveCapacity(liveCount)
            result.hashes.reserveCapacity(liveCount)
            var moved: [UInt64: Span] = [:]
            func move(_ offset: UInt32, _ length: UInt32) -> Span {
                let tag = UInt64(offset) << 32 | UInt64(length)
                if let span = moved[tag] { return span }
                let span = arena.withUnsafeBufferPointer { buffer in
                    result.append(UnsafeBufferPointer(rebasing: buffer[Int(offset)..<Int(offset) + Int(length)]))
                }
                moved[tag] = span
                return span
            }
            for index in rows.indices where isLive(index) {
                var row = rows[index]
                let flags = row.flags
                var span = move(row.keyOffset, row.keyLength)
                (row.keyOffset, row.keyLength) = (span.offset, span.length)
                if flags & RowFlag.stableKeyIsKey == 0 {
                    span = move(row.stableKeyOffset, row.stableKeyLength)
                    (row.stableKeyOffset, row.stableKeyLength) = (span.offset, span.length)
                }
                span = move(row.pathOffset, row.pathLength)
                (row.pathOffset, row.pathLength) = (span.offset, span.length)
                if flags & RowFlag.hasDisplayName != 0 {
                    span = move(row.displayNameOffset, row.displayNameLength)
                    (row.displayNameOffset, row.displayNameLength) = (span.offset, span.length)
                }
                if flags & RowFlag.hasParent != 0 {
                    span = move(row.parentOffset, row.parentLength)
                    (row.parentOffset, row.parentLength) = (span.offset, span.length)
                }
                if flags & RowFlag.hasRevision != 0 {
                    span = move(row.revisionOffset, row.revisionLength)
                    (row.revisionOffset, row.revisionLength) = (span.offset, span.length)
                }
                if flags & RowFlag.hasSidecar != 0 {
                    span = move(row.sidecarOffset, row.sidecarLength)
                    (row.sidecarOffset, row.sidecarLength) = (span.offset, span.length)
                }
                if flags & RowFlag.singleSongID != 0 {
                    span = move(row.songIDsFirst, row.songIDsSecond)
                    (row.songIDsFirst, row.songIDsSecond) = (span.offset, span.length)
                } else if row.songIDsSecond > 0 {
                    let start = result.songIDSpans.count
                    for songIndex in Int(row.songIDsFirst)..<Int(row.songIDsFirst) + Int(row.songIDsSecond) {
                        let old = songIDSpans[songIndex]
                        result.songIDSpans.append(move(old.offset, old.length))
                    }
                    row.songIDsFirst = UInt32(start)
                } else {
                    row.songIDsFirst = 0
                }
                result.rows.append(row)
                result.hashes.append(hashes[index])
            }
            result.liveCount = result.rows.count
            result.rebuildSlots(slotCount: Self.slotCount(for: result.liveCount))
            result.shrinkToFit()
            return result
        }
    }
}

// MARK: - Binary file format

public enum SourceSyncIndexFileError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt32)
    case layoutMismatch
    case digestMismatch
    case rowCountMismatch
    case corruptRow(Int)
    case duplicateKey
}

extension SourceSyncIndex {
    /// 文件格式版本。`Row` 的布局、`keyPrefixes` 的编号、行标志的含义任何一样变了都要加一;
    /// 读到不认识的版本时这个源当作没有已提交状态(下次完整扫描),文件不删。
    public static let binaryFormatVersion: UInt32 = 1
    static let fileMagic: [UInt8] = Array("PMSYNCIX".utf8)
    static let headerSize = 64
    static let digestSize = 32
    static let rowStride = 96

    public struct BinarySummary: Sendable, Equatable {
        public let rowCount: Int
        public let byteCount: Int
        /// 文件里除末尾校验以外全部内容的 SHA-256(十六进制)。
        public let sha256: String
    }

    /// 按块写出二进制形式,一边写一边算校验。`write` 收到的缓冲只在调用期间有效。
    /// 定长行直接从内存整块写出,不在内存里另拼一份文件。
    @discardableResult
    public func writeBinary(_ write: (UnsafeRawBufferPointer) throws -> Void) throws -> BinarySummary {
        precondition(MemoryLayout<Row>.stride == Self.rowStride && MemoryLayout<Row>.size == Self.rowStride)
        let storage = storage
        var hasher = SHA256()
        var byteCount = 0
        func emit(_ buffer: UnsafeRawBufferPointer) throws {
            guard buffer.count > 0 else { return }
            hasher.update(bufferPointer: buffer)
            try write(buffer)
            byteCount += buffer.count
        }
        var header = [UInt8](repeating: 0, count: Self.headerSize)
        header.replaceSubrange(0..<8, with: Self.fileMagic)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { bytes in
                header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            }
        }
        put(Self.binaryFormatVersion, at: 8)
        put(UInt32(Self.rowStride), at: 12)
        put(UInt64(storage.liveCount), at: 16)
        put(UInt64(storage.songIDSpans.count), at: 24)
        put(UInt64(storage.arena.count), at: 32)
        try header.withUnsafeBytes { try emit($0) }

        if storage.deadCount == 0 {
            try storage.rows.withUnsafeBytes { try emit($0) }
        } else {
            // 作废的行不落盘,它们留在共享字节里的内容没有行再指向,无害。
            var chunk: [Row] = []
            chunk.reserveCapacity(4_096)
            for row in storage.rows where row.flags & RowFlag.dead == 0 {
                chunk.append(row)
                if chunk.count == 4_096 {
                    try chunk.withUnsafeBytes { try emit($0) }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try chunk.withUnsafeBytes { try emit($0) }
        }
        try storage.songIDSpans.withUnsafeBytes { try emit($0) }
        try storage.arena.withUnsafeBytes { try emit($0) }
        let digest = Data(hasher.finalize())
        try digest.withUnsafeBytes { try write($0) }
        return BinarySummary(
            rowCount: storage.liveCount,
            byteCount: byteCount + digest.count,
            sha256: digest.map { String(format: "%02x", $0) }.joined()
        )
    }

    public func binaryData() throws -> (data: Data, summary: BinarySummary) {
        var data = Data()
        let summary = try writeBinary { data.append(contentsOf: $0) }
        return (data, summary)
    }

    /// 读回 `writeBinary` 写的内容。整份先校验(长度、版本、SHA-256、每行引用的范围、
    /// 键不重复),任何一处不对都报错,不会读出半份索引。
    public static func decodeBinary(_ data: Data, expectedSHA256: String? = nil) throws -> SourceSyncIndex {
        precondition(MemoryLayout<Row>.stride == rowStride && MemoryLayout<Row>.size == rowStride)
        guard data.count >= headerSize + digestSize else { throw SourceSyncIndexFileError.truncated }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> SourceSyncIndex in
            guard Array(raw[0..<8]) == fileMagic else { throw SourceSyncIndexFileError.badMagic }
            func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
                T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            let version = read(UInt32.self, at: 8)
            guard version == binaryFormatVersion else { throw SourceSyncIndexFileError.unsupportedVersion(version) }
            guard read(UInt32.self, at: 12) == UInt32(rowStride) else { throw SourceSyncIndexFileError.layoutMismatch }
            let rowCount = read(UInt64.self, at: 16)
            let spanCount = read(UInt64.self, at: 24)
            let arenaCount = read(UInt64.self, at: 32)
            guard rowCount < UInt64(Int32.max), spanCount < UInt64(Int32.max), arenaCount < UInt64(UInt32.max) else {
                throw SourceSyncIndexFileError.truncated
            }
            let rowsBytes = Int(rowCount) * rowStride
            let spansBytes = Int(spanCount) * MemoryLayout<Span>.stride
            let payloadCount = headerSize + rowsBytes + spansBytes + Int(arenaCount)
            guard data.count == payloadCount + digestSize else { throw SourceSyncIndexFileError.truncated }

            let digest = Data(SHA256.hash(data: UnsafeRawBufferPointer(rebasing: raw[0..<payloadCount])))
            guard digest.elementsEqual(raw[payloadCount..<payloadCount + digestSize]) else {
                throw SourceSyncIndexFileError.digestMismatch
            }
            if let expectedSHA256,
               digest.map({ String(format: "%02x", $0) }).joined() != expectedSHA256.lowercased() {
                throw SourceSyncIndexFileError.digestMismatch
            }

            let storage = Storage(minimumCapacity: 0)
            var offset = headerSize
            storage.rows = [Row](unsafeUninitializedCapacity: Int(rowCount)) { buffer, initialized in
                let bytes = UnsafeMutableRawBufferPointer(buffer)
                bytes.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + rowsBytes]))
                initialized = Int(rowCount)
            }
            offset += rowsBytes
            storage.songIDSpans = [Span](unsafeUninitializedCapacity: Int(spanCount)) { buffer, initialized in
                let bytes = UnsafeMutableRawBufferPointer(buffer)
                bytes.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + spansBytes]))
                initialized = Int(spanCount)
            }
            offset += spansBytes
            storage.arena = [UInt8](UnsafeRawBufferPointer(rebasing: raw[offset..<offset + Int(arenaCount)]))

            try storage.validateLoadedRows()
            storage.liveCount = storage.rows.count
            storage.hashes.reserveCapacity(storage.rows.count)
            for row in storage.rows.indices {
                storage.hashes.append(Storage.hash(of: storage.key(at: row)))
            }
            storage.slots = [Int32](repeating: Storage.emptySlot, count: Storage.slotCount(for: storage.rows.count))
            for row in storage.rows.indices {
                if storage.find(matchingKeyOf: row, in: storage) != nil {
                    throw SourceSyncIndexFileError.duplicateKey
                }
                storage.insertLoadedSlot(row: row)
            }
            return SourceSyncIndex(storage: storage)
        }
    }
}

extension SourceSyncIndex.Storage {
    /// 每行引用的字节都在缓冲之内、标志都是认识的。校验和已经排除了磁盘损坏,
    /// 这里挡的是写入方的错误,免得越界读。
    func validateLoadedRows() throws {
        let arenaCount = UInt64(arena.count)
        func valid(_ offset: UInt32, _ length: UInt32) -> Bool {
            UInt64(offset) + UInt64(length) <= arenaCount
        }
        let prefixCount = UInt32(SourceSyncIndex.keyPrefixes.count)
        for span in songIDSpans where !valid(span.offset, span.length) {
            throw SourceSyncIndexFileError.corruptRow(-1)
        }
        for (index, row) in rows.enumerated() {
            let flags = row.flags
            guard flags & ~SourceSyncIndex.RowFlag.knownMask == 0,
                  (flags & SourceSyncIndex.RowFlag.keyPrefixMask) >> SourceSyncIndex.RowFlag.keyPrefixShift < prefixCount,
                  valid(row.keyOffset, row.keyLength),
                  valid(row.pathOffset, row.pathLength),
                  flags & SourceSyncIndex.RowFlag.stableKeyIsKey != 0 || valid(row.stableKeyOffset, row.stableKeyLength),
                  flags & SourceSyncIndex.RowFlag.hasDisplayName == 0 || valid(row.displayNameOffset, row.displayNameLength),
                  flags & SourceSyncIndex.RowFlag.hasParent == 0 || valid(row.parentOffset, row.parentLength),
                  flags & SourceSyncIndex.RowFlag.hasRevision == 0 || valid(row.revisionOffset, row.revisionLength),
                  flags & SourceSyncIndex.RowFlag.hasSidecar == 0 || valid(row.sidecarOffset, row.sidecarLength)
            else { throw SourceSyncIndexFileError.corruptRow(index) }
            if flags & SourceSyncIndex.RowFlag.singleSongID != 0 {
                guard valid(row.songIDsFirst, row.songIDsSecond) else { throw SourceSyncIndexFileError.corruptRow(index) }
            } else {
                guard UInt64(row.songIDsFirst) + UInt64(row.songIDsSecond) <= UInt64(songIDSpans.count) else {
                    throw SourceSyncIndexFileError.corruptRow(index)
                }
            }
        }
    }

    fileprivate func insertLoadedSlot(row: Int) {
        var slot = Int((UInt64(hashes[row]) &* UInt64(slots.count)) >> 32)
        while slots[slot] >= 0 {
            slot += 1
            if slot == slots.count { slot = 0 }
        }
        slots[slot] = Int32(row)
    }
}
