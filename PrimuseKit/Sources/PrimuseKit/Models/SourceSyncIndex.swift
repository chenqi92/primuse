import CryptoKit
import Foundation

// MARK: - 读同步索引的统一接口

/// 能按键查、能逐条(键, 条目)遍历的同步索引:紧凑索引 `SourceSyncIndex`、目录走查的
/// `SourceScanWalkLog`、两者叠起来读的 `SourceSyncIndexOverlay`,以及测试里常用的
/// `[String: SourceSyncIndexedItem]`。遍历时每个键只出现一次。
public protocol SourceSyncIndexReading: Sequence where Element == (key: String, value: SourceSyncIndexedItem) {
    func item(forKey key: String) -> SourceSyncIndexedItem?
    /// 只遍历目录条目。紧凑索引按行标志跳过文件行,不必把它们一条条建出来。
    func forEachDirectoryItem(_ body: (SourceSyncIndexedItem) throws -> Void) rethrows
}

extension SourceSyncIndexReading {
    public func forEachDirectoryItem(_ body: (SourceSyncIndexedItem) throws -> Void) rethrows {
        for (_, item) in self where item.isDirectory { try body(item) }
    }
}

/// 能逐条读出同步索引的东西:已提交的紧凑索引 `SourceSyncIndex`,以及扫描过程中
/// 现建现用的 `[String: SourceSyncIndexedItem]`。只读条目的策略写成对它泛型,
/// 两种都能直接传进来,不必为了调用先把紧凑索引展开成字典。
public protocol SourceSyncIndexContents: SourceSyncIndexReading {
    associatedtype ItemValues: Collection where ItemValues.Element == SourceSyncIndexedItem
    var values: ItemValues { get }
    var isEmpty: Bool { get }
    var count: Int { get }
    subscript(key: String) -> SourceSyncIndexedItem? { get set }
}

extension Dictionary: SourceSyncIndexReading where Key == String, Value == SourceSyncIndexedItem {
    public func item(forKey key: String) -> SourceSyncIndexedItem? { self[key] }
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
///
/// 已提交的索引可以直接映射磁盘上的文件(`mapFile(at:)`):行、字节、哈希表都读映射里的,
/// 不占堆,映射的干净页系统随时能收回,不计进 footprint。映射的那份只读,第一次改动时
/// 才整份拷进堆里(写时复制,与普通的共享存储相同)。
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

    /// 读的是映射的文件(不占堆)。
    public var isMemoryMapped: Bool { storage.isMapped }

    /// 这份索引在堆上占的字节(数组容量之和);映射的为 0。只给诊断日志和测试用。
    public var heapByteCount: Int { storage.heapByteCount }

    /// 映射的文件有多大;不是映射的为 0。
    public var mappedByteCount: Int { storage.mapped?.length ?? 0 }

    public func item(forKey key: String) -> SourceSyncIndexedItem? {
        self[key]
    }

    /// 存着的那个键的写法(与 `key` 按 String 相等,字节可能不同)。没有这个键时为 nil。
    func storedKey(matching key: String) -> String? {
        storage.find(key).map { storage.key(at: $0.row) }
    }

    /// 有没有目录条目。只看行标志,不建条目。
    public var hasDirectoryEntries: Bool {
        let storage = storage
        for row in 0..<storage.rowCount
        where storage.rowFlags(row) & (RowFlag.dead | RowFlag.isDirectory) == RowFlag.isDirectory {
            return true
        }
        return false
    }

    public func forEachDirectoryItem(_ body: (SourceSyncIndexedItem) throws -> Void) rethrows {
        for item in directoryItems { try body(item) }
    }

    /// 逐条给出目录条目的(键, 条目)。文件行按标志跳过。
    public func forEachDirectoryEntry(_ body: (String, SourceSyncIndexedItem) throws -> Void) rethrows {
        let storage = storage
        var cache = SharedStringCache()
        for row in 0..<storage.rowCount
        where storage.rowFlags(row) & (RowFlag.dead | RowFlag.isDirectory) == RowFlag.isDirectory {
            try body(storage.key(at: row), storage.item(at: row, cache: &cache))
        }
    }

    /// 只含目录条目的视图。文件行按标志跳过,不建出来。
    public var directoryItems: DirectoryItems { DirectoryItems(storage: storage) }

    public struct DirectoryItems: Sequence {
        let storage: Storage

        public struct Iterator: IteratorProtocol {
            let storage: Storage
            var row = 0
            var cache = SharedStringCache()

            public mutating func next() -> SourceSyncIndexedItem? {
                while row < storage.rowCount {
                    let current = row
                    row += 1
                    guard storage.rowFlags(current) & (RowFlag.dead | RowFlag.isDirectory)
                        == RowFlag.isDirectory else { continue }
                    return storage.item(at: current, cache: &cache)
                }
                return nil
            }
        }

        public func makeIterator() -> Iterator { Iterator(storage: storage) }
    }

    /// 父目录在 `parents` 里的条目,按父目录分组(组名是条目自己记的 `parentPath`)。
    /// 与逐条判断 `parents.contains(item.parentPath)` 结果相同;父目录路径相同的行
    /// (同一个目录下的歌共用一段字节)只判断一次,不在的行不建条目。
    public func entries(withParentIn parents: Set<String>) -> [String: [String: SourceSyncIndexedItem]] {
        var result: [String: [String: SourceSyncIndexedItem]] = [:]
        guard !parents.isEmpty else { return result }
        let storage = storage
        var memoTags = [UInt64](repeating: .max, count: 64)
        var memoHits = [Bool](repeating: false, count: 64)
        var cache = SharedStringCache()
        for row in 0..<storage.rowCount {
            let value = storage.row(row)
            guard value.flags & (RowFlag.dead | RowFlag.hasParent) == RowFlag.hasParent else { continue }
            let tag = UInt64(value.parentOffset) << 32 | UInt64(value.parentLength)
            let slot = Int((value.parentOffset ^ (value.parentOffset >> 6) ^ value.parentLength) & 63)
            let isWanted: Bool
            if memoTags[slot] == tag {
                isWanted = memoHits[slot]
            } else {
                isWanted = parents.contains(cache.string(value.parentOffset, value.parentLength, in: storage))
                memoTags[slot] = tag
                memoHits[slot] = isWanted
            }
            guard isWanted else { continue }
            let item = storage.item(at: row, cache: &cache)
            result[item.parentPath!, default: [:]][storage.key(at: row)] = item
        }
        return result
    }

    /// 要改之前调用:共享的、或映射的(只读)存储先拷一份堆上的。
    @usableFromInline
    mutating func makeUnique() {
        if storage.isMapped || !isKnownUniquelyReferenced(&storage) {
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
            while row < storage.rowCount {
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
        public var endIndex: Int { storage.rowCount }
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
                while row < storage.rowCount {
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
        public var endIndex: Int { storage.rowCount }
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
        for row in 0..<left.rowCount where left.isLive(row) {
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

// MARK: - Layered construction (directory walks)

extension SourceSyncIndex {
    /// 写入一条并沿用 `interner`(同一批里目录路径只存一份)。存储被拷走过时
    /// 旧的去重表不再对得上,换一张新的。
    @discardableResult
    mutating func insert(
        _ item: SourceSyncIndexedItem,
        forKey key: String,
        hash: UInt32,
        interner: inout Interner?
    ) -> SourceSyncIndexedItem? {
        if storage.isMapped || !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
            if interner != nil { interner = Interner() }
        }
        return storage.set(item, forKey: key, hash: hash, interner: &interner)
    }

    /// 按预先算好的哈希找一个键,返回所在行。
    func row(forKey key: String, hash: UInt32) -> Int? {
        guard storage.liveCount > 0 else { return nil }
        return storage.find(key, hash: hash)?.row
    }

    /// 找另一份索引第 `row` 行的那个键,返回在这份里的行号。
    func row(matchingRow row: Int, of other: SourceSyncIndex) -> Int? {
        guard storage.liveCount > 0 else { return nil }
        return storage.find(matchingKeyOf: row, in: other.storage)
    }

    /// 存活行的行号,按存放顺序。
    var liveRows: LazyFilterSequence<Range<Int>> {
        let storage = storage
        return (0..<storage.rowCount).lazy.filter { storage.isLive($0) }
    }

    func key(atRow row: Int) -> String { storage.key(at: row) }
    func item(atRow row: Int) -> SourceSyncIndexedItem { storage.item(at: row) }

    /// 把几份索引按先后接成一份,行与字节整段搬过去,不把条目一条条建出来。
    ///
    /// `skipping(part, row)` 为真的行不搬(调用方用它丢掉被后面同键条目盖住的旧行)。
    /// 调用方保证留下来的行里没有相同的键。
    static func concatenating(
        _ parts: [SourceSyncIndex],
        skipping: ((_ part: Int, _ row: Int) -> Bool)? = nil
    ) -> SourceSyncIndex {
        let result = Storage(minimumCapacity: 0)
        var rowCapacity = 0
        var arenaCapacity = 0
        var spanCapacity = 0
        var skippedRows: [[Bool]?] = []
        var needsCompaction = false
        for (partIndex, part) in parts.enumerated() {
            let source = part.storage
            let skipped = skipping.map { shouldSkip in
                (0..<source.rowCount).map { source.isLive($0) && shouldSkip(partIndex, $0) }
            }
            let skippedCount = skipped?.reduce(0) { $0 + ($1 ? 1 : 0) } ?? 0
            skippedRows.append(skippedCount > 0 ? skipped : nil)
            needsCompaction = needsCompaction || source.deadCount > 0 || skippedCount > 0
            rowCapacity += source.liveCount - skippedCount
            arenaCapacity += source.arenaCount
            spanCapacity += source.songIDSpanCount
        }
        result.rows.reserveCapacity(rowCapacity)
        result.hashes.reserveCapacity(rowCapacity)
        if !needsCompaction {
            precondition(arenaCapacity < Int(UInt32.max), "Source sync index arena exceeds 4 GB")
            result.arena.reserveCapacity(arenaCapacity)
            result.songIDSpans.reserveCapacity(spanCapacity)
        }
        for (partIndex, part) in parts.enumerated() {
            let source = part.storage
            if source.deadCount > 0 || skippedRows[partIndex] != nil {
                // 被覆盖的行连同字节一起丢掉，不能让每轮合并继续携带旧版本的内容。
                source.appendCompactedRows(to: result) { skippedRows[partIndex]?[$0] ?? false }
                continue
            }
            precondition(result.arena.count + source.arenaCount < Int(UInt32.max),
                         "Source sync index arena exceeds 4 GB")
            let base = UInt32(result.arena.count)
            let spanBase = UInt32(result.songIDSpans.count)
            source.withArena { result.arena.append(contentsOf: $0) }
            for spanIndex in 0..<source.songIDSpanCount {
                let span = source.songIDSpan(spanIndex)
                result.songIDSpans.append(Span(offset: span.offset + base, length: span.length))
            }
            for index in 0..<source.rowCount where source.isLive(index) {
                var row = source.row(index)
                let flags = row.flags
                row.keyOffset += base
                row.pathOffset += base
                if flags & RowFlag.stableKeyIsKey == 0 { row.stableKeyOffset += base }
                if flags & RowFlag.hasDisplayName != 0 { row.displayNameOffset += base }
                if flags & RowFlag.hasParent != 0 { row.parentOffset += base }
                if flags & RowFlag.hasRevision != 0 { row.revisionOffset += base }
                if flags & RowFlag.hasSidecar != 0 { row.sidecarOffset += base }
                if flags & RowFlag.singleSongID != 0 {
                    row.songIDsFirst += base
                } else if row.songIDsSecond > 0 {
                    row.songIDsFirst += spanBase
                }
                result.rows.append(row)
                result.hashes.append(source.hash(atRow: index))
            }
        }
        precondition(result.rows.count < Int(Int32.max), "Source sync index exceeds Int32 rows")
        result.liveCount = result.rows.count
        result.rebuildSlots(slotCount: Storage.slotCount(for: result.liveCount))
        result.shrinkToFit()
        return SourceSyncIndex(storage: result)
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

    /// 映射进来的一份已提交索引文件(`mappableFormatVersion`)的各段。只读,随最后一个持有者释放时解除映射。
    /// 文件按 UUID 命名、写完就不再改,后来被删掉(提交了新的一份)也不影响已经映射的这份。
    final class MappedSections: @unchecked Sendable {
        let base: UnsafeRawPointer
        let length: Int
        let rows: UnsafeBufferPointer<Row>
        let spans: UnsafeBufferPointer<Span>
        let hashes: UnsafeBufferPointer<UInt32>
        let slots: UnsafeBufferPointer<Int32>
        let arena: UnsafeBufferPointer<UInt8>

        init(
            base: UnsafeRawPointer,
            length: Int,
            rows: UnsafeBufferPointer<Row>,
            spans: UnsafeBufferPointer<Span>,
            hashes: UnsafeBufferPointer<UInt32>,
            slots: UnsafeBufferPointer<Int32>,
            arena: UnsafeBufferPointer<UInt8>
        ) {
            self.base = base
            self.length = length
            self.rows = rows
            self.spans = spans
            self.hashes = hashes
            self.slots = slots
            self.arena = arena
        }

        deinit {
            munmap(UnsafeMutableRawPointer(mutating: base), length)
        }
    }

    @usableFromInline
    final class Storage: @unchecked Sendable {
        // 堆上的存法。`mapped` 不为 nil 时这些数组都是空的。
        var rows: [Row] = []
        var arena: [UInt8] = []
        var songIDSpans: [Span] = []
        /// 每行键的稳定哈希(`SourceSyncKeyHash`):跨进程、跨版本相同,规范等价的键哈希相同。
        /// 能映射的文件里原样存着这一列和下面的开放寻址表。
        var hashes: [UInt32] = []
        /// 开放寻址表:行号,`emptySlot` 为空,`tombstone` 为删除留下的墓碑。
        var slots: [Int32] = []
        var liveCount = 0
        var deadCount = 0
        var tombstoneCount = 0
        /// 映射的只读文件。不为 nil 时所有读都走它,这份存储不能改(改之前先 `copy()`)。
        let mapped: MappedSections?

        static let emptySlot: Int32 = -1
        static let tombstone: Int32 = -2

        init(minimumCapacity: Int) {
            mapped = nil
            if minimumCapacity > 0 {
                rows.reserveCapacity(minimumCapacity)
                hashes.reserveCapacity(minimumCapacity)
                slots = [Int32](repeating: Self.emptySlot, count: Self.slotCount(for: minimumCapacity))
            }
        }

        init(mapped: MappedSections) {
            self.mapped = mapped
            liveCount = mapped.rows.count
        }

        private init(copying other: Storage) {
            mapped = nil
            rows = other.rows
            arena = other.arena
            songIDSpans = other.songIDSpans
            hashes = other.hashes
            slots = other.slots
            liveCount = other.liveCount
            deadCount = other.deadCount
            tombstoneCount = other.tombstoneCount
        }

        /// 映射的那份整份拷进堆里。文件里的哈希与开放寻址表就是堆上用的那种,直接拷。
        private init(heapCopyOf mapped: MappedSections) {
            self.mapped = nil
            rows = Array(mapped.rows)
            songIDSpans = Array(mapped.spans)
            arena = Array(mapped.arena)
            hashes = Array(mapped.hashes)
            slots = Array(mapped.slots)
            liveCount = rows.count
        }

        /// 写时复制。没有作废行时数组本身也是写时复制的,改到哪个才真的拷哪个;
        /// 有作废行就顺便压掉,反正要整份拷。作废行的字节不能留在共用的字节块里
        /// 跟着拷下去:作废行数随即清零,那些字节以后再也看不出来,会一轮轮攒着。
        /// 映射的只读存储拷成堆上的一份。
        func copy() -> Storage {
            if let mapped { return Storage(heapCopyOf: mapped) }
            return deadCount == 0 ? Storage(copying: self) : compacted()
        }

        static func slotCount(for count: Int) -> Int {
            Swift.max(8, count + count / 2 + 1)
        }

        static func hash(of key: String) -> UInt32 {
            SourceSyncKeyHash.hash(of: key)
        }

        // MARK: Reading either representation

        @inline(__always) var isMapped: Bool { mapped != nil }

        @inline(__always) var rowCount: Int {
            if let mapped { return mapped.rows.count }
            return rows.count
        }

        @inline(__always) func row(_ index: Int) -> Row {
            if let mapped { return mapped.rows[index] }
            return rows[index]
        }

        @inline(__always) func rowFlags(_ index: Int) -> UInt32 {
            if let mapped { return mapped.rows[index].flags }
            return rows[index].flags
        }

        @inline(__always) func hash(atRow index: Int) -> UInt32 {
            if let mapped { return mapped.hashes[index] }
            return hashes[index]
        }

        @inline(__always) var slotCount: Int {
            if let mapped { return mapped.slots.count }
            return slots.count
        }

        @inline(__always) func slot(_ index: Int) -> Int32 {
            if let mapped { return mapped.slots[index] }
            return slots[index]
        }

        @inline(__always) var songIDSpanCount: Int {
            if let mapped { return mapped.spans.count }
            return songIDSpans.count
        }

        @inline(__always) func songIDSpan(_ index: Int) -> Span {
            if let mapped { return mapped.spans[index] }
            return songIDSpans[index]
        }

        @inline(__always) var arenaCount: Int {
            if let mapped { return mapped.arena.count }
            return arena.count
        }

        @inline(__always)
        func withArena<Result>(_ body: (UnsafeBufferPointer<UInt8>) throws -> Result) rethrows -> Result {
            if let mapped { return try body(mapped.arena) }
            return try arena.withUnsafeBufferPointer(body)
        }

        /// 堆上数组的容量之和;映射的为 0。
        var heapByteCount: Int {
            guard mapped == nil else { return 0 }
            return rows.capacity * MemoryLayout<Row>.stride
                + arena.capacity
                + songIDSpans.capacity * MemoryLayout<Span>.stride
                + hashes.capacity * MemoryLayout<UInt32>.stride
                + slots.capacity * MemoryLayout<Int32>.stride
        }

        @inline(__always)
        func isLive(_ row: Int) -> Bool {
            rowFlags(row) & RowFlag.dead == 0
        }

        func nextLiveRow(from start: Int) -> Int {
            var row = start
            let count = rowCount
            while row < count, !isLive(row) { row += 1 }
            return row
        }

        @inline(__always)
        private func slotIndex(for hash: UInt32) -> Int {
            Int((UInt64(hash) &* UInt64(slotCount)) >> 32)
        }

        // MARK: Strings

        func string(_ offset: UInt32, _ length: UInt32) -> String {
            guard length > 0 else { return "" }
            return withArena { buffer in
                String(
                    decoding: UnsafeBufferPointer(
                        rebasing: buffer[Int(offset)..<Int(offset) + Int(length)]
                    ),
                    as: UTF8.self
                )
            }
        }

        func key(at row: Int) -> String {
            let value = self.row(row)
            let prefix = SourceSyncIndex.keyPrefixes[Int((value.flags & RowFlag.keyPrefixMask) >> RowFlag.keyPrefixShift)]
            guard !prefix.isEmpty else { return string(value.keyOffset, value.keyLength) }
            let total = prefix.count + Int(value.keyLength)
            return withArena { buffer in
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

        /// 第 `row` 行的键的稳定哈希,直接从字节算(不建字符串)。
        func keyHash(atRow row: Int) -> UInt32 {
            let value = self.row(row)
            let prefix = SourceSyncIndex.keyPrefixes[Int((value.flags & RowFlag.keyPrefixMask) >> RowFlag.keyPrefixShift)]
            return withArena { buffer in
                let suffix: UnsafeBufferPointer<UInt8> = value.keyLength > 0
                    ? UnsafeBufferPointer(rebasing: buffer[Int(value.keyOffset)..<Int(value.keyOffset) + Int(value.keyLength)])
                    : UnsafeBufferPointer(start: nil, count: 0)
                return SourceSyncKeyHash.hash(prefix: prefix, suffix: suffix)
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
            let value = self.row(row)
            let flags = value.flags
            let key = key(at: row)
            let isDirectory = flags & RowFlag.isDirectory != 0
            var songIDs: [String] = []
            if flags & RowFlag.singleSongID != 0 {
                songIDs = [string(value.songIDsFirst, value.songIDsSecond)]
            } else if value.songIDsSecond > 0 {
                songIDs.reserveCapacity(Int(value.songIDsSecond))
                for index in Int(value.songIDsFirst)..<Int(value.songIDsFirst) + Int(value.songIDsSecond) {
                    let span = songIDSpan(index)
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
            let slotCount = slotCount
            guard slotCount > 0 else { return nil }
            var query = key
            return query.withUTF8 { queryBytes in
                var queryIsASCII: Bool?
                var slot = slotIndex(for: hash)
                while true {
                    let row = self.slot(slot)
                    if row == Self.emptySlot { return nil }
                    if row >= 0, self.hash(atRow: Int(row)) == hash {
                        if keyBytesEqual(row: Int(row), queryBytes) { return (slot, Int(row)) }
                        // 字节不同、却仍可能是同一个 String(规范等价):只有不全是 ASCII 时才会。
                        if queryIsASCII == nil { queryIsASCII = !queryBytes.contains { $0 >= 0x80 } }
                        if !(queryIsASCII! && rowFlags(Int(row)) & RowFlag.keyIsASCII != 0),
                           self.key(at: Int(row)) == key {
                            return (slot, Int(row))
                        }
                    }
                    slot += 1
                    if slot == slotCount { slot = 0 }
                }
            }
        }

        /// 在这份索引里找另一份索引第 `row` 行的那个键。两边的哈希是同一种(稳定哈希),
        /// 堆上的与映射的可以混着比。
        func find(matchingKeyOf row: Int, in other: Storage) -> Int? {
            let slotCount = slotCount
            guard slotCount > 0 else { return nil }
            let hash = other.hash(atRow: row)
            let otherRow = other.row(row)
            let otherPrefix = otherRow.flags & RowFlag.keyPrefixMask
            var slot = slotIndex(for: hash)
            while true {
                let candidate = self.slot(slot)
                if candidate == Self.emptySlot { return nil }
                if candidate >= 0, self.hash(atRow: Int(candidate)) == hash {
                    let mine = self.row(Int(candidate))
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
                if slot == slotCount { slot = 0 }
            }
        }

        private func keyBytesEqual(row: Int, _ query: UnsafeBufferPointer<UInt8>) -> Bool {
            let value = self.row(row)
            let prefix = SourceSyncIndex.keyPrefixes[Int((value.flags & RowFlag.keyPrefixMask) >> RowFlag.keyPrefixShift)]
            guard query.count == prefix.count + Int(value.keyLength) else { return false }
            if !prefix.isEmpty {
                let prefixMatches = prefix.withUnsafeBufferPointer { prefixBytes in
                    memcmp(query.baseAddress!, prefixBytes.baseAddress!, prefix.count) == 0
                }
                guard prefixMatches else { return false }
            }
            guard value.keyLength > 0 else { return true }
            return withArena { buffer in
                memcmp(query.baseAddress! + prefix.count, buffer.baseAddress! + Int(value.keyOffset), Int(value.keyLength)) == 0
            }
        }

        static func bytesEqual(
            _ lhs: Storage, _ lhsOffset: UInt32, _ lhsLength: UInt32,
            _ rhs: Storage, _ rhsOffset: UInt32, _ rhsLength: UInt32
        ) -> Bool {
            guard lhsLength == rhsLength else { return false }
            guard lhsLength > 0 else { return true }
            return lhs.withArena { left in
                rhs.withArena { right in
                    memcmp(left.baseAddress! + Int(lhsOffset), right.baseAddress! + Int(rhsOffset), Int(lhsLength)) == 0
                }
            }
        }

        private func spanBytesEqual(_ offset: UInt32, _ length: UInt32, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            guard Int(length) == bytes.count else { return false }
            guard length > 0 else { return true }
            // 构建器记下的位置在就地压缩之后可能已经不在这块字节里了:按不相等处理,另存一份。
            guard Int(offset) + Int(length) <= arenaCount else { return false }
            return withArena { buffer in
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
            return withArena { buffer in
                !UnsafeBufferPointer(rebasing: buffer[Int(offset)..<Int(offset) + Int(length)]).contains { $0 >= 0x80 }
            }
        }

        /// 两行除键以外的字段逐个比较(键已经由调用方按 String 相等对上了)。
        static func rowsEqual(_ lhsRow: Int, in lhs: Storage, _ rhsRow: Int, in rhs: Storage) -> Bool {
            let left = lhs.row(lhsRow)
            let right = rhs.row(rhsRow)
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
            return (Int(row.songIDsFirst)..<Int(row.songIDsFirst) + Int(row.songIDsSecond)).map { songIDSpan($0) }
        }

        // MARK: Mutation (heap only)

        private func append(_ value: String) -> Span {
            var value = value
            return value.withUTF8 { append($0) }
        }

        private func append(_ bytes: UnsafeBufferPointer<UInt8>) -> Span {
            precondition(mapped == nil, "Mapped source sync index is read-only")
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
            precondition(mapped == nil, "Mapped source sync index is read-only")
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
            precondition(mapped == nil, "Mapped source sync index is read-only")
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
            precondition(mapped == nil, "Mapped source sync index is read-only")
            slots = [Int32](repeating: Self.emptySlot, count: slotCount)
            tombstoneCount = 0
            for row in rows.indices where isLive(row) {
                insertSlot(row: Int32(row), hash: hashes[row])
            }
        }

        /// 数组按倍数长,建完可能空着近一半容量(45 万行时行表空出几十 MB)。
        /// 明显多出来时拷进刚好大小的数组,旧的随即释放。映射的不动。
        func shrinkToFit() {
            guard mapped == nil else { return }
            func trimmed<Element>(_ array: [Element]) -> [Element]? {
                guard array.capacity > array.count + array.count / 8 + 64 else { return nil }
                guard !array.isEmpty else { return [] }
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
            guard mapped == nil, deadCount > 4_096, deadCount > liveCount else { return }
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

        // 旧分段合并可能留下没有任何行引用的字节，行数和校验和仍然合法。
        // 字段长度之和是存活字节的上界；只有明显超过它时才重建，避免为普通索引多拷一份。
        func hasExcessUnreferencedBytes(arenaByteCount: Int) -> Bool {
            guard arenaByteCount > 64 * 1024 else { return false }
            let threshold = arenaByteCount / 2
            var referenced = 0
            for index in 0..<rowCount {
                let row = self.row(index)
                let flags = row.flags
                referenced += Int(row.pathLength) + Int(row.keyLength)
                if flags & RowFlag.stableKeyIsKey == 0 { referenced += Int(row.stableKeyLength) }
                if flags & RowFlag.hasDisplayName != 0 { referenced += Int(row.displayNameLength) }
                if flags & RowFlag.hasParent != 0 { referenced += Int(row.parentLength) }
                if flags & RowFlag.hasRevision != 0 { referenced += Int(row.revisionLength) }
                if flags & RowFlag.hasSidecar != 0 { referenced += Int(row.sidecarLength) }
                if referenced >= threshold { return false }
                if flags & RowFlag.singleSongID != 0 {
                    referenced += Int(row.songIDsSecond)
                } else {
                    for index in Int(row.songIDsFirst)..<Int(row.songIDsFirst) + Int(row.songIDsSecond) {
                        referenced += Int(songIDSpan(index).length)
                        if referenced >= threshold { return false }
                    }
                }
                if referenced >= threshold { return false }
            }
            return true
        }

        /// 只留存活行的一份拷贝(堆上的)。同一段字节(共用的目录路径、键与歌曲 ID 共用的字节)
        /// 拷过去仍是同一段。
        ///
        /// 跨行共用的只有构建时去重的目录路径(目录行的 `path` 与子项的 `parentPath`),
        /// 只给它们建对照表;键、歌曲 ID 这类只在同一行里共用,逐行比一下就够,不必为
        /// 整份索引的每一段字节建一张大表(45 万行时那张表就有上百 MB)。
        func compacted() -> Storage {
            let result = Storage(minimumCapacity: 0)
            result.rows.reserveCapacity(liveCount)
            result.hashes.reserveCapacity(liveCount)
            appendCompactedRows(to: result)
            result.liveCount = result.rows.count
            result.rebuildSlots(slotCount: Self.slotCount(for: result.liveCount))
            result.shrinkToFit()
            return result
        }

        func appendCompactedRows(
            to result: Storage,
            arenaBytes: UnsafeBufferPointer<UInt8>? = nil,
            copyingHashes: Bool = true,
            skipping: (Int) -> Bool = { _ in false }
        ) {
            var shared: [UInt64: Span] = [:]
            var local: [(tag: UInt64, span: Span)] = []
            local.reserveCapacity(8)
            func copyBytes(_ offset: UInt32, _ length: UInt32) -> Span {
                if let arenaBytes {
                    return result.append(UnsafeBufferPointer(rebasing:
                        arenaBytes[Int(offset)..<Int(offset) + Int(length)]))
                }
                return withArena { buffer in
                    result.append(UnsafeBufferPointer(rebasing: buffer[Int(offset)..<Int(offset) + Int(length)]))
                }
            }
            /// 同一行里已经搬过的那段就沿用。
            func move(_ offset: UInt32, _ length: UInt32) -> Span {
                let tag = UInt64(offset) << 32 | UInt64(length)
                for entry in local where entry.tag == tag { return entry.span }
                let span = copyBytes(offset, length)
                local.append((tag, span))
                return span
            }
            /// 可能被别的行共用的目录路径。
            func moveShared(_ offset: UInt32, _ length: UInt32) -> Span {
                let tag = UInt64(offset) << 32 | UInt64(length)
                for entry in local where entry.tag == tag { return entry.span }
                let span: Span
                if let existing = shared[tag] {
                    span = existing
                } else {
                    span = copyBytes(offset, length)
                    shared[tag] = span
                }
                local.append((tag, span))
                return span
            }
            for index in 0..<rowCount where isLive(index) {
                if skipping(index) { continue }
                var row = self.row(index)
                let flags = row.flags
                local.removeAll(keepingCapacity: true)
                var span = flags & RowFlag.isDirectory != 0
                    ? moveShared(row.pathOffset, row.pathLength)
                    : move(row.pathOffset, row.pathLength)
                (row.pathOffset, row.pathLength) = (span.offset, span.length)
                if flags & RowFlag.hasParent != 0 {
                    span = moveShared(row.parentOffset, row.parentLength)
                    (row.parentOffset, row.parentLength) = (span.offset, span.length)
                }
                if flags & RowFlag.singleSongID != 0 {
                    span = move(row.songIDsFirst, row.songIDsSecond)
                    (row.songIDsFirst, row.songIDsSecond) = (span.offset, span.length)
                } else if row.songIDsSecond > 0 {
                    let start = result.songIDSpans.count
                    for songIndex in Int(row.songIDsFirst)..<Int(row.songIDsFirst) + Int(row.songIDsSecond) {
                        let old = songIDSpan(songIndex)
                        result.songIDSpans.append(move(old.offset, old.length))
                    }
                    row.songIDsFirst = UInt32(start)
                } else {
                    row.songIDsFirst = 0
                }
                span = move(row.keyOffset, row.keyLength)
                (row.keyOffset, row.keyLength) = (span.offset, span.length)
                if flags & RowFlag.stableKeyIsKey == 0 {
                    span = move(row.stableKeyOffset, row.stableKeyLength)
                    (row.stableKeyOffset, row.stableKeyLength) = (span.offset, span.length)
                }
                if flags & RowFlag.hasDisplayName != 0 {
                    span = move(row.displayNameOffset, row.displayNameLength)
                    (row.displayNameOffset, row.displayNameLength) = (span.offset, span.length)
                }
                if flags & RowFlag.hasRevision != 0 {
                    span = move(row.revisionOffset, row.revisionLength)
                    (row.revisionOffset, row.revisionLength) = (span.offset, span.length)
                }
                if flags & RowFlag.hasSidecar != 0 {
                    span = move(row.sidecarOffset, row.sidecarLength)
                    (row.sidecarOffset, row.sidecarLength) = (span.offset, span.length)
                }
                result.rows.append(row)
                if copyingHashes { result.hashes.append(self.hash(atRow: index)) }
            }
        }
    }
}

// MARK: - Stable key hash

/// 同步索引键的哈希:每个进程、每个版本算出来都一样(能映射的文件里存着它和开放寻址表),
/// 又与 `String ==` 一致(规范等价的写法哈希相同,查找语义与字典相同)。
///
/// 规范等价的两种写法要落到同一个哈希上,所以哈希的是 NFC 形式的 UTF-8 字节。
/// 全是「一定已经是 NFC」的字符(ASCII、常用拉丁字母、西里尔基本区、常用标点、
/// 中日韩表意文字、假名、谚文音节、全角半角形式;这些字符都没有正规分解以外的组合、
/// 组合类为 0、NFC_QC=Yes)时字节本身就是 NFC 形式,直接哈希,不建字符串;
/// 其余的(组合附加符号、别的文字、增补平面)先用 Foundation 转成 NFC 再哈希。
/// 算法(包括哪些字符走快路)改了就要加 `algorithm`:文件里记着,对不上的文件当作旧格式重写。
enum SourceSyncKeyHash {
    static let algorithm: UInt32 = 1

    static func hash(of key: String) -> UInt32 {
        var key = key
        return key.withUTF8 { hash(utf8: $0) }
    }

    /// 「前缀 + 后缀」两段拼成的键(行里存的是前缀编号和后缀字节)。
    static func hash(prefix: [UInt8], suffix: UnsafeBufferPointer<UInt8>) -> UInt32 {
        guard !prefix.isEmpty else { return hash(utf8: suffix) }
        let total = prefix.count + suffix.count
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: total) { buffer in
            _ = buffer.initialize(from: prefix)
            if suffix.count > 0 {
                _ = UnsafeMutableBufferPointer(rebasing: buffer[prefix.count..<total]).initialize(from: suffix)
            }
            return hash(utf8: UnsafeBufferPointer(buffer))
        }
    }

    static func hash(utf8 bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        if isKnownNFC(bytes) { return mix(UnsafeRawBufferPointer(bytes)) }
        var normalized = String(decoding: bytes, as: UTF8.self).precomposedStringWithCanonicalMapping
        return normalized.withUTF8 { mix(UnsafeRawBufferPointer($0)) }
    }

    /// 每个字符都在已知一定是 NFC、组合类为 0 的范围里。只是快路的判断:判成「不知道」
    /// 也对,只是慢一点。
    static func isKnownNFC(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        let count = bytes.count
        while index < count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            let scalar: UInt32
            if lead & 0xE0 == 0xC0, index + 1 < count {
                scalar = UInt32(lead & 0x1F) << 6 | UInt32(bytes[index + 1] & 0x3F)
                index += 2
            } else if lead & 0xF0 == 0xE0, index + 2 < count {
                scalar = UInt32(lead & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6
                    | UInt32(bytes[index + 2] & 0x3F)
                index += 3
            } else {
                return false
            }
            guard isKnownNFCScalar(scalar) else { return false }
        }
        return true
    }

    @inline(__always)
    private static func isKnownNFCScalar(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x00A0...0x017F, // Latin-1 补充、拉丁扩展 A(预组合字母)
             0x0400...0x045F, // 西里尔基本区
             0x1E00...0x1EFF, // 拉丁扩展附加(越南文等预组合字母)
             0x2010...0x2027, 0x2030...0x205E, // 常用标点(不含 U+2000/2001 这类单字分解)
             0x3000...0x3029, 0x3030...0x303F, // 中日韩符号(不含 U+302A–302F 组合声调)
             0x3041...0x3096, 0x309B...0x30FF, // 假名(不含 U+3099/309A 组合浊点)
             0x3400...0x4DBF, 0x4E00...0x9FFF, // 中日韩表意文字
             0xAC00...0xD7A3, // 谚文音节
             0xFF01...0xFFBE, 0xFFE0...0xFFE6: // 全角半角形式
            return true
        default:
            return false
        }
    }

    @inline(__always)
    private static func scramble(_ value: UInt64) -> UInt64 {
        var value = value &* 0x87C3_7B91_1142_53D5
        value = (value << 31) | (value >> 33)
        return value &* 0x4CF5_AD43_2745_937F
    }

    /// 64 位逐 8 字节混合,最后做 fmix64,取低 32 位。
    static func mix(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        let count = bytes.count
        var hash: UInt64 = 0x9E37_79B9_7F4A_7C15 ^ (UInt64(truncatingIfNeeded: count) &* 0xFF51_AFD7_ED55_8CCD)
        var offset = 0
        while offset + 8 <= count {
            hash ^= scramble(UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            hash = ((hash << 27) | (hash >> 37)) &* 5 &+ 0x52DC_E729
            offset += 8
        }
        if offset < count {
            var tail: UInt64 = 0
            var shift: UInt64 = 0
            while offset < count {
                tail |= UInt64(bytes.load(fromByteOffset: offset, as: UInt8.self)) << shift
                shift += 8
                offset += 1
            }
            hash ^= scramble(tail)
        }
        hash ^= hash >> 33
        hash &*= 0xFF51_AFD7_ED55_8CCD
        hash ^= hash >> 33
        hash &*= 0xC4CE_B9FE_1A85_EC53
        hash ^= hash >> 33
        return UInt32(truncatingIfNeeded: hash)
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
    /// 能映射的文件里的哈希表对不上:哈希算法版本不同,或者表本身不完整。
    case hashTableMismatch
    /// 打不开或映射不了文件(值是 errno)。
    case mappingFailed(Int32)
    /// 能映射的文件里开放寻址表有过长的连续占用段(大量键的哈希挤在一起)。
    case excessiveProbing
}

extension SourceSyncIndex {
    /// 紧凑格式版本。`Row` 的布局、`keyPrefixes` 的编号、行标志的含义任何一样变了都要加一;
    /// 读到不认识的版本时这个源当作没有已提交状态(下次完整扫描),文件不删。
    /// 扫描断点的段文件写这一版。
    public static let binaryFormatVersion: UInt32 = 1
    /// 能直接映射的格式:在第 1 版的行、歌曲 ID 区之后多存每行键的稳定哈希
    /// (`SourceSyncKeyHash`)和开放寻址表,读的时候不必在堆上建任何东西。
    /// 已提交索引的文件(`SourceSyncStateDirectory`)写这一版;第 1 版的文件读进来后改写一次。
    public static let mappableFormatVersion: UInt32 = 2
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

    /// 文件头(64 字节,小端):魔数 8、版本 4、行宽 4、行数 8、歌曲 ID 区个数 8、字节区大小 8;
    /// 第 2 版另有开放寻址表的槽数 8(偏移 40)与哈希算法版本 4(偏移 48)。
    /// 之后依次是行、歌曲 ID 区、(第 2 版:每行哈希、开放寻址表)、字节区,最后 32 字节 SHA-256。
    struct FileHeader {
        var version: UInt32
        var rowCount: Int
        var spanCount: Int
        var arenaCount: Int
        var slotCount: Int
        var hashAlgorithm: UInt32

        var isMappable: Bool { version == SourceSyncIndex.mappableFormatVersion }
        var rowsOffset: Int { SourceSyncIndex.headerSize }
        var spansOffset: Int { rowsOffset + rowCount * SourceSyncIndex.rowStride }
        var hashesOffset: Int { spansOffset + spanCount * MemoryLayout<Span>.stride }
        var slotsOffset: Int { hashesOffset + (isMappable ? rowCount * MemoryLayout<UInt32>.stride : 0) }
        var arenaOffset: Int { slotsOffset + (isMappable ? slotCount * MemoryLayout<Int32>.stride : 0) }
        var payloadCount: Int { arenaOffset + arenaCount }
    }

    static func readHeader(_ raw: UnsafeRawBufferPointer) throws -> FileHeader {
        guard raw.count >= headerSize + digestSize else { throw SourceSyncIndexFileError.truncated }
        guard raw[0..<8].elementsEqual(fileMagic) else { throw SourceSyncIndexFileError.badMagic }
        func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
            T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
        let version = read(UInt32.self, at: 8)
        guard version == binaryFormatVersion || version == mappableFormatVersion else {
            throw SourceSyncIndexFileError.unsupportedVersion(version)
        }
        guard read(UInt32.self, at: 12) == UInt32(rowStride) else { throw SourceSyncIndexFileError.layoutMismatch }
        let rowCount = read(UInt64.self, at: 16)
        let spanCount = read(UInt64.self, at: 24)
        let arenaCount = read(UInt64.self, at: 32)
        guard rowCount < UInt64(Int32.max), spanCount < UInt64(Int32.max), arenaCount < UInt64(UInt32.max) else {
            throw SourceSyncIndexFileError.truncated
        }
        var slotCount: UInt64 = 0
        var hashAlgorithm: UInt32 = 0
        if version == mappableFormatVersion {
            slotCount = read(UInt64.self, at: 40)
            hashAlgorithm = read(UInt32.self, at: 48)
            // 至少留一个空槽,线性探测才停得下来。
            guard slotCount < UInt64(Int32.max), slotCount > rowCount else {
                throw SourceSyncIndexFileError.truncated
            }
        }
        let header = FileHeader(
            version: version, rowCount: Int(rowCount), spanCount: Int(spanCount),
            arenaCount: Int(arenaCount), slotCount: Int(slotCount), hashAlgorithm: hashAlgorithm
        )
        guard raw.count == header.payloadCount + digestSize else { throw SourceSyncIndexFileError.truncated }
        return header
    }

    static func verifyDigest(
        _ raw: UnsafeRawBufferPointer,
        payloadCount: Int,
        expectedSHA256: String?
    ) throws {
        let digest = Data(SHA256.hash(data: UnsafeRawBufferPointer(rebasing: raw[0..<payloadCount])))
        guard digest.elementsEqual(raw[payloadCount..<payloadCount + digestSize]) else {
            throw SourceSyncIndexFileError.digestMismatch
        }
        if let expectedSHA256,
           digest.map({ String(format: "%02x", $0) }).joined() != expectedSHA256.lowercased() {
            throw SourceSyncIndexFileError.digestMismatch
        }
    }

    /// 按块写出二进制形式,一边写一边算校验。`write` 收到的缓冲只在调用期间有效。
    /// 定长行直接从内存整块写出,不在内存里另拼一份文件。
    /// `mappable` 时写第 2 版(多出每行哈希与开放寻址表,`mapFile(at:)` 能直接映射)。
    @discardableResult
    public func writeBinary(
        mappable: Bool = false,
        _ write: (UnsafeRawBufferPointer) throws -> Void
    ) throws -> BinarySummary {
        precondition(MemoryLayout<Row>.stride == Self.rowStride && MemoryLayout<Row>.size == Self.rowStride)
        // 有作废行时先压一份再写:作废行的字节没有行指向,写进文件读回来以后作废行数是零,
        // 那些字节就再也看不出来,增量对账一轮轮改下去会越攒越多。
        let storage = storage.deadCount == 0 ? storage : storage.compacted()
        var hasher = SHA256()
        var byteCount = 0
        func emit(_ buffer: UnsafeRawBufferPointer) throws {
            // 写入方可能需要 Data；限制每次交出的大小，避免复制整块索引。
            let chunkSize = 256 * 1024
            for start in stride(from: 0, to: buffer.count, by: chunkSize) {
                let end = Swift.min(start + chunkSize, buffer.count)
                let chunk = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                hasher.update(bufferPointer: chunk)
                try write(chunk)
                byteCount += chunk.count
            }
        }
        // 堆上的那份按文件的槽数重排一张开放寻址表(堆上的表按倍数长,还可能带墓碑);
        // 映射来的那份原样写回。
        let fileSlots: [Int32] = mappable && !storage.isMapped ? Self.fileSlotTable(for: storage) : []
        let slotCount = mappable ? (storage.mapped?.slots.count ?? fileSlots.count) : 0

        var header = [UInt8](repeating: 0, count: Self.headerSize)
        header.replaceSubrange(0..<8, with: Self.fileMagic)
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { bytes in
                header.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            }
        }
        put(mappable ? Self.mappableFormatVersion : Self.binaryFormatVersion, at: 8)
        put(UInt32(Self.rowStride), at: 12)
        put(UInt64(storage.liveCount), at: 16)
        put(UInt64(storage.songIDSpanCount), at: 24)
        put(UInt64(storage.arenaCount), at: 32)
        if mappable {
            put(UInt64(slotCount), at: 40)
            put(SourceSyncKeyHash.algorithm, at: 48)
        }
        try header.withUnsafeBytes { try emit($0) }

        if let mapped = storage.mapped {
            try emit(UnsafeRawBufferPointer(mapped.rows))
            try emit(UnsafeRawBufferPointer(mapped.spans))
            if mappable {
                try emit(UnsafeRawBufferPointer(mapped.hashes))
                try emit(UnsafeRawBufferPointer(mapped.slots))
            }
            try emit(UnsafeRawBufferPointer(mapped.arena))
        } else {
            try storage.rows.withUnsafeBytes { try emit($0) }
            try storage.songIDSpans.withUnsafeBytes { try emit($0) }
            if mappable {
                try storage.hashes.withUnsafeBytes { try emit($0) }
                try fileSlots.withUnsafeBytes { try emit($0) }
            }
            try storage.arena.withUnsafeBytes { try emit($0) }
        }
        let digest = Data(hasher.finalize())
        try digest.withUnsafeBytes { try write($0) }
        return BinarySummary(
            rowCount: storage.liveCount,
            byteCount: byteCount + digest.count,
            sha256: digest.map { String(format: "%02x", $0) }.joined()
        )
    }

    public func binaryData(mappable: Bool = false) throws -> (data: Data, summary: BinarySummary) {
        var data = Data()
        let summary = try writeBinary(mappable: mappable) { data.append(contentsOf: $0) }
        return (data, summary)
    }

    /// 没有作废行的堆上存储:按 `slotCount(for:)` 的槽数、各行的稳定哈希重排一张表。
    private static func fileSlotTable(for storage: Storage) -> [Int32] {
        let rowCount = storage.rows.count
        let slotCount = Storage.slotCount(for: rowCount)
        var slots = [Int32](repeating: Storage.emptySlot, count: slotCount)
        for row in 0..<rowCount {
            var slot = Int((UInt64(storage.hashes[row]) &* UInt64(slotCount)) >> 32)
            while slots[slot] >= 0 {
                slot += 1
                if slot == slotCount { slot = 0 }
            }
            slots[slot] = Int32(row)
        }
        return slots
    }

    /// 读回 `writeBinary` 写的内容(两个版本都认),整份放进堆里。整份先校验(长度、版本、
    /// SHA-256、每行引用的范围、键不重复),任何一处不对都报错,不会读出半份索引。
    public static func decodeBinary(_ data: Data, expectedSHA256: String? = nil) throws -> SourceSyncIndex {
        precondition(MemoryLayout<Row>.stride == rowStride && MemoryLayout<Row>.size == rowStride)
        guard data.count >= headerSize + digestSize else { throw SourceSyncIndexFileError.truncated }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> SourceSyncIndex in
            let header = try readHeader(raw)
            try verifyDigest(raw, payloadCount: header.payloadCount, expectedSHA256: expectedSHA256)

            var storage = Storage(minimumCapacity: 0)
            let rowCount = header.rowCount
            let spanCount = header.spanCount
            let rowsBytes = rowCount * rowStride
            let spansBytes = spanCount * MemoryLayout<Span>.stride
            // 零长度沿用默认空数组，避免 unsafe 初始化器写共享空数组的计数。
            if rowCount > 0 {
                let offset = header.rowsOffset
                storage.rows = [Row](unsafeUninitializedCapacity: rowCount) { buffer, initialized in
                    let bytes = UnsafeMutableRawBufferPointer(buffer)
                    bytes.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + rowsBytes]))
                    initialized = rowCount
                }
            }
            if spanCount > 0 {
                let offset = header.spansOffset
                storage.songIDSpans = [Span](unsafeUninitializedCapacity: spanCount) { buffer, initialized in
                    let bytes = UnsafeMutableRawBufferPointer(buffer)
                    bytes.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + spansBytes]))
                    initialized = spanCount
                }
            }
            let arenaBytes = UnsafeBufferPointer(rebasing:
                raw.bindMemory(to: UInt8.self)[header.arenaOffset..<header.arenaOffset + header.arenaCount])
            try storage.validateLoadedRows(arenaByteCount: arenaBytes.count)
            if storage.hasExcessUnreferencedBytes(arenaByteCount: arenaBytes.count) {
                let compacted = Storage(minimumCapacity: 0)
                compacted.rows.reserveCapacity(storage.rows.count)
                // 从已校验的输入直接拷存活字节，不先分配整块旧的冗余数据。
                storage.appendCompactedRows(to: compacted, arenaBytes: arenaBytes, copyingHashes: false)
                compacted.shrinkToFit()
                storage = compacted
            } else {
                storage.arena = Array(arenaBytes)
            }
            storage.liveCount = storage.rows.count
            // 第 2 版文件里也存着哈希,这里仍按字节重算一遍:读进堆里的这份不依赖文件里的表。
            storage.hashes.reserveCapacity(storage.rows.count)
            for row in storage.rows.indices {
                storage.hashes.append(storage.keyHash(atRow: row))
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

    /// 映射一份第 2 版的文件,读的时候不在堆上建任何东西(只有校验时的一张位图,用完就放)。
    ///
    /// 映射之前整份校验:长度、版本、SHA-256、每行引用的范围、开放寻址表(见
    /// `validateMappedHashTable`:完整、探测段不过长、键不重复、哈希与键的字节对得上)。任何一处
    /// 不对都报错并解除映射。第 1 版的文件报 `unsupportedVersion(1)`,哈希算法版本不同或
    /// 哈希对不上报 `hashTableMismatch`(调用方读进堆里,之后再写一份第 2 版),探测段过长报
    /// `excessiveProbing`(调用方读进堆里,不改写)。
    ///
    /// 文件写完以后不能再被改写或截短(SIGBUS);目录里的索引文件都是新名字写的,只会被删除。
    /// 映射的开放寻址表里连续占用的一段最长多少。45 万行随机哈希时最长一段一百多,
    /// 这里留了好几倍的余量;超过了说明哈希挤在一起,改成读进堆里。
    public static let maximumMappedProbeRun = 1_024

    public static func mapFile(
        at url: URL,
        expectedSHA256: String? = nil,
        maximumProbeRun: Int = maximumMappedProbeRun
    ) throws -> SourceSyncIndex {
        precondition(MemoryLayout<Row>.stride == rowStride && MemoryLayout<Row>.size == rowStride)
        let (base, length) = try mapReadOnly(url)
        var sections: MappedSections?
        defer {
            if sections == nil { munmap(UnsafeMutableRawPointer(mutating: base), length) }
        }
        let raw = UnsafeRawBufferPointer(start: base, count: length)
        let header = try readHeader(raw)
        guard header.isMappable else { throw SourceSyncIndexFileError.unsupportedVersion(header.version) }
        guard header.hashAlgorithm == SourceSyncKeyHash.algorithm else {
            throw SourceSyncIndexFileError.hashTableMismatch
        }
        try verifyDigest(raw, payloadCount: header.payloadCount, expectedSHA256: expectedSHA256)
        // 页对齐的映射加上 8 的倍数的偏移:行(8 字节对齐)与其余各段都对齐。
        let mapped = MappedSections(
            base: base,
            length: length,
            rows: UnsafeBufferPointer(
                start: (base + header.rowsOffset).bindMemory(to: Row.self, capacity: header.rowCount),
                count: header.rowCount
            ),
            spans: UnsafeBufferPointer(
                start: (base + header.spansOffset).bindMemory(to: Span.self, capacity: header.spanCount),
                count: header.spanCount
            ),
            hashes: UnsafeBufferPointer(
                start: (base + header.hashesOffset).bindMemory(to: UInt32.self, capacity: header.rowCount),
                count: header.rowCount
            ),
            slots: UnsafeBufferPointer(
                start: (base + header.slotsOffset).bindMemory(to: Int32.self, capacity: header.slotCount),
                count: header.slotCount
            ),
            arena: UnsafeBufferPointer(
                start: (base + header.arenaOffset).bindMemory(to: UInt8.self, capacity: header.arenaCount),
                count: header.arenaCount
            )
        )
        sections = mapped
        let storage = Storage(mapped: mapped)
        try storage.validateLoadedRows(arenaByteCount: header.arenaCount)
        try storage.validateMappedHashTable(maximumProbeRun: maximumProbeRun)
        return SourceSyncIndex(storage: storage)
    }

    /// 只读映射整个文件。文件描述符映射完就关(映射自己持有文件)。
    static func mapReadOnly(_ url: URL) throws -> (base: UnsafeRawPointer, length: Int) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw SourceSyncIndexFileError.mappingFailed(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw SourceSyncIndexFileError.mappingFailed(errno) }
        let length = Int(info.st_size)
        guard length >= headerSize + digestSize else { throw SourceSyncIndexFileError.truncated }
        guard let pointer = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0),
              pointer != UnsafeMutableRawPointer(bitPattern: -1) else {
            throw SourceSyncIndexFileError.mappingFailed(errno)
        }
        return (UnsafeRawPointer(pointer), length)
    }
}

extension SourceSyncIndex.Storage {
    /// 每行引用的字节都在缓冲之内、标志都是认识的。校验和已经排除了磁盘损坏,
    /// 这里挡的是写入方的错误,免得越界读。
    func validateLoadedRows(arenaByteCount: Int) throws {
        let arenaCount = UInt64(arenaByteCount)
        func valid(_ offset: UInt32, _ length: UInt32) -> Bool {
            UInt64(offset) + UInt64(length) <= arenaCount
        }
        let prefixCount = UInt32(SourceSyncIndex.keyPrefixes.count)
        let spanCount = songIDSpanCount
        for index in 0..<spanCount {
            let span = songIDSpan(index)
            guard valid(span.offset, span.length) else { throw SourceSyncIndexFileError.corruptRow(-1) }
        }
        for index in 0..<rowCount {
            let row = self.row(index)
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
                guard UInt64(row.songIDsFirst) + UInt64(row.songIDsSecond) <= UInt64(spanCount) else {
                    throw SourceSyncIndexFileError.corruptRow(index)
                }
            }
        }
    }

    /// 映射来的开放寻址表,一遍走完(从一个空槽开始,按连续占用的一段一段走):
    /// - 每行恰好占一个槽,槽里的行号都在范围内,空槽至少一个;
    /// - 每行的起始位置(按它的哈希算)落在它所在的那一段里、在它之前:查找一路探测得到它;
    /// - 连续占用的一段不超过 `maximumProbeRun`:超过了报 `excessiveProbing`(大量键的哈希挤在
    ///   一起,映射着查会很慢);每行只往回比到自己的起始位置,校验本身不会变成平方级;
    /// - 哈希相同的两行(只会出现在同一段里、起始位置相同)比一下键,相同(按 String 相等)
    ///   报 `duplicateKey`,与读进堆里时的判断一致;
    /// - 存着的哈希就是按键的字节现算的那个:键不全是「一定是 NFC」的字符时(哈希要经过
    ///   系统的 NFC 规范化)每行都核对,其余抽查约 512 行。对不上报 `hashTableMismatch`。
    func validateMappedHashTable(maximumProbeRun: Int) throws {
        guard let mapped else { return }
        let rowCount = mapped.rows.count
        let slotCount = mapped.slots.count
        guard slotCount > rowCount, mapped.hashes.count == rowCount else {
            throw SourceSyncIndexFileError.hashTableMismatch
        }
        guard let start = (0..<slotCount).first(where: { mapped.slots[$0] == Self.emptySlot }) else {
            throw SourceSyncIndexFileError.hashTableMismatch
        }
        var seen = [UInt64](repeating: 0, count: (rowCount + 63) / 64)
        var occupied = 0
        var run = 0
        var slot = start
        for _ in 0..<slotCount {
            slot += 1
            if slot == slotCount { slot = 0 }
            let row = mapped.slots[slot]
            if row == Self.emptySlot {
                run = 0
                continue
            }
            guard row >= 0, Int(row) < rowCount else { throw SourceSyncIndexFileError.hashTableMismatch }
            let word = Int(row) >> 6
            let bit = UInt64(1) << UInt64(Int(row) & 63)
            guard seen[word] & bit == 0 else { throw SourceSyncIndexFileError.hashTableMismatch }
            seen[word] |= bit
            occupied += 1
            run += 1
            guard run <= maximumProbeRun else { throw SourceSyncIndexFileError.excessiveProbing }
            let hash = mapped.hashes[Int(row)]
            let home = Int((UInt64(hash) &* UInt64(slotCount)) >> 32)
            let displacement = slot >= home ? slot - home : slot + slotCount - home
            // 起始位置不在这一段里:中间隔着空槽,查找到不了它。
            guard displacement < run else { throw SourceSyncIndexFileError.hashTableMismatch }
            var probe = home
            while probe != slot {
                let other = Int(mapped.slots[probe])
                if mapped.hashes[other] == hash, keysEqual(other, Int(row)) {
                    throw SourceSyncIndexFileError.duplicateKey
                }
                probe += 1
                if probe == slotCount { probe = 0 }
            }
        }
        guard occupied == rowCount else { throw SourceSyncIndexFileError.hashTableMismatch }
        guard rowCount > 0 else { return }
        let sampleStride = Swift.max(1, rowCount / 512)
        for row in 0..<rowCount {
            let sampled = row % sampleStride == 0 || row == rowCount - 1
            guard sampled || !keyIsKnownNFC(atRow: row) else { continue }
            guard keyHash(atRow: row) == mapped.hashes[row] else {
                throw SourceSyncIndexFileError.hashTableMismatch
            }
        }
    }

    /// 第 `row` 行的键全是「一定是 NFC」的字符(哈希不经过系统的规范化)。前缀都是 ASCII。
    func keyIsKnownNFC(atRow row: Int) -> Bool {
        let value = self.row(row)
        guard value.flags & SourceSyncIndex.RowFlag.keyIsASCII == 0, value.keyLength > 0 else { return true }
        return withArena { buffer in
            SourceSyncKeyHash.isKnownNFC(UnsafeBufferPointer(
                rebasing: buffer[Int(value.keyOffset)..<Int(value.keyOffset) + Int(value.keyLength)]
            ))
        }
    }

    /// 两行的键按 String 相等(与查找的判断相同):字节相同一定相等,都是 ASCII 而字节不同
    /// 一定不等,其余取出来比。
    func keysEqual(_ lhs: Int, _ rhs: Int) -> Bool {
        let left = row(lhs)
        let right = row(rhs)
        let samePrefix = left.flags & SourceSyncIndex.RowFlag.keyPrefixMask
            == right.flags & SourceSyncIndex.RowFlag.keyPrefixMask
        if samePrefix, Self.bytesEqual(self, left.keyOffset, left.keyLength, self, right.keyOffset, right.keyLength) {
            return true
        }
        if samePrefix, left.flags & right.flags & SourceSyncIndex.RowFlag.keyIsASCII != 0 { return false }
        return key(at: lhs) == key(at: rhs)
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
