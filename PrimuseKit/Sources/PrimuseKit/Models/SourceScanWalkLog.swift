import CryptoKit
import Foundation

// MARK: - 目录走查的进度

/// 目录走查记下的东西:同步索引条目,以及走到过的歌曲 ID。
///
/// 走查每列完一个目录就交出一份快照当扫描断点,扫描服务握着那一份,走查接着往下记。
/// 用普通的字典和集合时,交出快照之后的第一笔改动就要把整份拷一遍:45 万首、
/// 5 万个目录的源,每个目录都要拷几十万条,时间随曲库平方增长,还常驻两份。
/// 这里把记下的东西按批封存成不可变的段:交快照前先把尾巴封存,快照只是把段的
/// 列表拷一份;相邻的小段按大小两两并成大段(行与字节整段搬),段数保持在对数级。
///
/// 索引部分与 `[String: SourceSyncIndexedItem]` 同义:同一个键后写的覆盖先写的,
/// 键的写法保留第一次写入时的,遍历时每个键只出现一次。歌曲 ID 只增不减,可以重复
/// 记,取用时去重,与原来 `Set<String>` 的 `insert` / `formUnion` 相同。
public struct SourceScanWalkLog: Sendable {
    public struct Segment: Sendable {
        public let id: UUID
        public let index: SourceSyncIndex
        public let songIDs: [String]

        public init(id: UUID = UUID(), index: SourceSyncIndex, songIDs: [String]) {
            self.id = id
            self.index = index
            self.songIDs = songIDs
        }

        var weight: Int { Swift.max(1, index.count + songIDs.count) }
    }

    /// 已封存的段,先记的在前。
    public private(set) var segments: [Segment] = []
    /// 还没封存的最后一层。
    private(set) var pendingIndex = SourceSyncIndex()
    private(set) var pendingSongIDs: [String] = []
    private var interner: SourceSyncIndex.Interner? = SourceSyncIndex.Interner()
    /// 在不止一层里出现过的键(较老的那几处已经过时)。通常是空的。
    public private(set) var shadowedKeys: Set<String> = []
    /// 索引里不同键的个数。
    public private(set) var indexCount = 0

    /// 尾巴攒到这么多就自己封存,快照之后的写时复制最多拷这么多。
    static let maximumPendingRows = 2_048
    static let maximumPendingSongIDs = 4_096

    public init() {}

    public init(index: SourceSyncIndex, songIDs: [String] = []) {
        if !index.isEmpty || !songIDs.isEmpty {
            segments = [Segment(index: index, songIDs: songIDs)]
        }
        indexCount = index.count
    }

    public init<IDs: Sequence>(
        index: [String: SourceSyncIndexedItem],
        songIDs: IDs
    ) where IDs.Element == String {
        self.init(index: SourceSyncIndex(index), songIDs: Array(songIDs))
    }

    /// 从扫描断点读回:段按先后排好,`tail` 是还没封存的最后一层(断点里内联存着的那部分),
    /// 读回来仍然是尾巴,再写断点时照旧内联,不会多出一个段文件。
    init(
        segments: [Segment],
        tail: SourceSyncIndex,
        tailSongIDs: [String],
        shadowedKeys: Set<String>
    ) {
        self.segments = segments.filter { !$0.index.isEmpty || !$0.songIDs.isEmpty }
        pendingIndex = tail
        pendingSongIDs = tailSongIDs
        self.shadowedKeys = shadowedKeys
        indexCount = recountedIndex()
    }

    public var isIndexEmpty: Bool { indexCount == 0 }
    public var isEmpty: Bool { indexCount == 0 && !hasSongIDs }

    public var hasSongIDs: Bool {
        !pendingSongIDs.isEmpty || segments.contains { !$0.songIDs.isEmpty }
    }

    /// 索引的各层,先记的在前(已封存的段,再是尾巴)。
    var indexLayers: [SourceSyncIndex] {
        var layers = segments.map(\.index)
        if !pendingIndex.isEmpty { layers.append(pendingIndex) }
        return layers
    }

    // MARK: Index

    public func item(forKey key: String) -> SourceSyncIndexedItem? {
        let hash = SourceSyncIndex.Storage.hash(of: key)
        if let row = pendingIndex.row(forKey: key, hash: hash) {
            return pendingIndex.item(atRow: row)
        }
        if let found = newestSegmentRow(forKey: key, hash: hash) {
            return segments[found.segment].index.item(atRow: found.row)
        }
        return nil
    }

    public subscript(key: String) -> SourceSyncIndexedItem? { item(forKey: key) }

    public func containsKey(_ key: String) -> Bool {
        let hash = SourceSyncIndex.Storage.hash(of: key)
        return pendingIndex.row(forKey: key, hash: hash) != nil
            || newestSegmentRow(forKey: key, hash: hash) != nil
    }

    /// 写入(或覆盖)一个键的条目。
    public mutating func updateValue(_ item: SourceSyncIndexedItem, forKey key: String) {
        let hash = SourceSyncIndex.Storage.hash(of: key)
        if pendingIndex.row(forKey: key, hash: hash) != nil {
            pendingIndex.insert(item, forKey: key, hash: hash, interner: &interner)
        } else if let found = newestSegmentRow(forKey: key, hash: hash) {
            // 老的那层不能改(快照还握着它):新值记进尾巴,用老的那个键的写法,
            // 老的那处记成过时。
            let stored = segments[found.segment].index.key(atRow: found.row)
            shadowedKeys.insert(stored)
            pendingIndex.insert(item, forKey: stored, hash: hash, interner: &interner)
        } else {
            pendingIndex.insert(item, forKey: key, hash: hash, interner: &interner)
            indexCount += 1
        }
        if pendingIndex.count >= Self.maximumPendingRows { seal() }
    }

    private func newestSegmentRow(forKey key: String, hash: UInt32) -> (segment: Int, row: Int)? {
        for segment in segments.indices.reversed() {
            if let row = segments[segment].index.row(forKey: key, hash: hash) {
                return (segment, row)
            }
        }
        return nil
    }

    /// 合成一份紧凑索引。只有一段、没有尾巴时就是那一段本身,不拷。
    public func materializedIndex() -> SourceSyncIndex {
        let layers = indexLayers
        if layers.isEmpty { return SourceSyncIndex() }
        if layers.count == 1 { return layers[0] }
        return Self.concatenating(layers, shadowedKeys: shadowedKeys)
    }

    /// 展开成字典。只给仍按字典读写走查进度的老路径(群晖、电视)用。
    public var indexDictionary: [String: SourceSyncIndexedItem] {
        var result: [String: SourceSyncIndexedItem] = [:]
        result.reserveCapacity(indexCount)
        for (key, item) in self { result[key] = item }
        return result
    }

    /// 按先后接起几层,丢掉被后面同键条目盖住的旧行。后面那一处已经沿用了最早的
    /// 键写法(见 `updateValue`),所以结果与依次写进字典相同。
    static func concatenating(_ layers: [SourceSyncIndex], shadowedKeys: Set<String>) -> SourceSyncIndex {
        guard !shadowedKeys.isEmpty else { return SourceSyncIndex.concatenating(layers) }
        return SourceSyncIndex.concatenating(layers) { part, row in
            for newer in layers.indices where newer > part {
                if layers[newer].row(matchingRow: row, of: layers[part]) != nil { return true }
            }
            return false
        }
    }

    // MARK: Song IDs

    public mutating func insertSongID(_ id: String) {
        pendingSongIDs.append(id)
        if pendingSongIDs.count >= Self.maximumPendingSongIDs { seal() }
    }

    public mutating func insertSongIDs<IDs: Sequence>(_ ids: IDs) where IDs.Element == String {
        for id in ids { insertSongID(id) }
    }

    /// 记下的所有歌曲 ID(可能重复),先记的在前。
    public var allSongIDs: [String] {
        var result: [String] = []
        result.reserveCapacity(segments.reduce(pendingSongIDs.count) { $0 + $1.songIDs.count })
        for segment in segments { result.append(contentsOf: segment.songIDs) }
        result.append(contentsOf: pendingSongIDs)
        return result
    }

    public func songIDSet() -> Set<String> {
        var result = Set<String>(minimumCapacity: segments.reduce(pendingSongIDs.count) { $0 + $1.songIDs.count })
        for segment in segments { result.formUnion(segment.songIDs) }
        result.formUnion(pendingSongIDs)
        return result
    }

    // MARK: Sealing

    /// 把尾巴封存成一段。交出快照之前调用:之后再记的东西进新的尾巴,
    /// 不会碰到快照里的任何一块存储。
    public mutating func seal() {
        guard !pendingIndex.isEmpty || !pendingSongIDs.isEmpty else { return }
        var index = pendingIndex
        pendingIndex = SourceSyncIndex()
        // 没交出去过的尾巴才就地收紧容量;交出去过的那块存储别人可能正在读。
        if isKnownUniquelyReferenced(&index.storage) { index.storage.shrinkToFit() }
        segments.append(Segment(index: index, songIDs: pendingSongIDs))
        pendingSongIDs = []
        interner = SourceSyncIndex.Interner()
        mergeTrailingSegments()
    }

    /// 并成一段(走查结束时用):之后 `materializedIndex()` 不必再拷。
    public mutating func consolidate() {
        seal()
        guard segments.count > 1 else {
            shadowedKeys = []
            return
        }
        let index = Self.concatenating(segments.map(\.index), shadowedKeys: shadowedKeys)
        var songIDs: [String] = []
        songIDs.reserveCapacity(segments.reduce(0) { $0 + $1.songIDs.count })
        for segment in segments { songIDs.append(contentsOf: segment.songIDs) }
        segments = [Segment(index: index, songIDs: songIDs)]
        shadowedKeys = []
    }

    /// 末尾两段大小相当(老的不超过新的两倍)就并起来,直到不再相当:
    /// 段的大小大致按倍数递减,段数是对数级,每条记录平均只被搬对数次。
    private mutating func mergeTrailingSegments() {
        while segments.count >= 2,
              segments[segments.count - 2].weight <= 2 * segments[segments.count - 1].weight {
            // 先把两段整个取出来再合并：合并时手里拿的是自己的值，不是数组元素的借用，
            // 不会碰到数组里已经释放的存储（135 扫描时的崩溃就出在这里的借用上）。
            let newer = segments.removeLast()
            let older = segments.removeLast()
            let index = Self.concatenating([older.index, newer.index], shadowedKeys: shadowedKeys)
            segments.append(Segment(index: index, songIDs: older.songIDs + newer.songIDs))
        }
    }

    private func recountedIndex() -> Int {
        let layers = indexLayers
        var total = layers.reduce(0) { $0 + $1.count }
        for key in shadowedKeys {
            let hash = SourceSyncIndex.Storage.hash(of: key)
            let occurrences = layers.reduce(0) { $0 + ($1.row(forKey: key, hash: hash) == nil ? 0 : 1) }
            total -= Swift.max(0, occurrences - 1)
        }
        return total
    }
}

// MARK: - Iteration

extension SourceScanWalkLog: SourceSyncIndexReading {
    public typealias Element = (key: String, value: SourceSyncIndexedItem)

    /// 先记的层在前;一个键在几层里都有时只给最新的那条(键是最早的写法)。
    public struct Iterator: IteratorProtocol {
        let layers: [SourceSyncIndex]
        let shadowedKeys: Set<String>
        var layer = 0
        var row = 0
        var cache = SourceSyncIndex.SharedStringCache()

        public mutating func next() -> (key: String, value: SourceSyncIndexedItem)? {
            while layer < layers.count {
                let storage = layers[layer].storage
                while row < storage.rowCount {
                    let current = row
                    row += 1
                    guard storage.isLive(current) else { continue }
                    let key = storage.key(at: current)
                    if !shadowedKeys.isEmpty, shadowedKeys.contains(key), newerLayerContains(row: current) {
                        continue
                    }
                    return (key, storage.item(at: current, cache: &cache))
                }
                layer += 1
                row = 0
                // 缓存按字节位置认字符串,换了一层字节块就不能再用。
                cache = SourceSyncIndex.SharedStringCache()
            }
            return nil
        }

        private func newerLayerContains(row: Int) -> Bool {
            for newer in layers.indices where newer > layer {
                if layers[newer].row(matchingRow: row, of: layers[layer]) != nil { return true }
            }
            return false
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(layers: indexLayers, shadowedKeys: shadowedKeys)
    }

    public var underestimatedCount: Int { indexCount }

    public func forEachDirectoryItem(_ body: (SourceSyncIndexedItem) throws -> Void) rethrows {
        let layers = indexLayers
        guard shadowedKeys.isEmpty else {
            for (_, item) in self where item.isDirectory { try body(item) }
            return
        }
        for layer in layers { try layer.forEachDirectoryItem(body) }
    }
}

// MARK: - Equality

extension SourceScanWalkLog: Equatable {
    /// 与 (字典, 集合) 的相等同义:同样的键与条目,同样的歌曲 ID 集合。
    public static func == (lhs: SourceScanWalkLog, rhs: SourceScanWalkLog) -> Bool {
        if lhs.segments.map(\.id) == rhs.segments.map(\.id),
           lhs.shadowedKeys == rhs.shadowedKeys,
           lhs.pendingSongIDs == rhs.pendingSongIDs,
           lhs.pendingIndex == rhs.pendingIndex {
            return true
        }
        guard lhs.indexCount == rhs.indexCount, lhs.songIDSet() == rhs.songIDSet() else { return false }
        for (key, item) in lhs {
            guard rhs.item(forKey: key) == item else { return false }
        }
        return true
    }
}

// MARK: - Overlay

/// 已提交的索引上面叠一份走查进度来读,与 `lower.merging(upper) { _, new in new }`
/// 同义(值取上层的,键的写法取下层的),不必真的合成一本。
public struct SourceSyncIndexOverlay: SourceSyncIndexReading, Sendable {
    public let lower: SourceSyncIndex
    public let upper: SourceScanWalkLog

    public init(lower: SourceSyncIndex, upper: SourceScanWalkLog = SourceScanWalkLog()) {
        self.lower = lower
        self.upper = upper
    }

    public func item(forKey key: String) -> SourceSyncIndexedItem? {
        if !upper.isIndexEmpty, let item = upper.item(forKey: key) { return item }
        return lower[key]
    }

    public subscript(key: String) -> SourceSyncIndexedItem? { item(forKey: key) }

    public var isEmpty: Bool { lower.isEmpty && upper.isIndexEmpty }

    public struct Iterator: IteratorProtocol {
        var lowerIterator: SourceSyncIndex.Iterator
        var upperIterator: SourceScanWalkLog.Iterator?
        let lower: SourceSyncIndex
        let upper: SourceScanWalkLog

        public mutating func next() -> (key: String, value: SourceSyncIndexedItem)? {
            if upperIterator == nil {
                if let entry = lowerIterator.next() {
                    if !upper.isIndexEmpty, let replacement = upper.item(forKey: entry.key) {
                        return (entry.key, replacement)
                    }
                    return entry
                }
                upperIterator = upper.makeIterator()
            }
            while let entry = upperIterator?.next() {
                if !lower.contains(key: entry.key) { return entry }
            }
            return nil
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(lowerIterator: lower.makeIterator(), upperIterator: nil, lower: lower, upper: upper)
    }

    public func forEachDirectoryItem(_ body: (SourceSyncIndexedItem) throws -> Void) rethrows {
        guard !upper.isIndexEmpty else {
            try lower.forEachDirectoryItem(body)
            return
        }
        // 上层的目录全算;下层的目录只算上层没有的键(上层有的以上层为准,
        // 哪怕上层那条已经不是目录)。
        try upper.forEachDirectoryItem(body)
        try lower.forEachDirectoryEntry { key, item in
            if !upper.containsKey(key) { try body(item) }
        }
    }
}

// MARK: - Segment files

/// 扫描断点里一段走查进度的清单。段的数据存在断点旁边的文件里,按 id 命名,
/// 写一次就不再改;清单里记着整份文件的 SHA-256,读回时逐字节核对。
public struct ScanResumeSegmentManifest: Codable, Sendable, Equatable {
    public let id: UUID
    public let sha256: String
    public let byteCount: Int
    public let rows: Int
    public let songIDs: Int
}

public enum ScanResumeSegmentFileError: Error, Equatable, Sendable {
    case missing
    case digestMismatch
    case malformed
}

/// 扫描断点旁边存放走查进度段的目录。编码断点时把还没落盘的段写成文件
/// (`CodingUserInfoKey.scanResumeSegmentStore`),解码时按清单读回。
public final class ScanResumeSegmentStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    /// 当前这一遍编码引用到的段,以及这一遍新写的段文件字节数。
    private var referenced: Set<UUID> = []
    private var writtenByteCount = 0
    /// 这个进程里写过或读回过、确认在盘上的段(按目录区分)。启动时读断点用的那个实例
    /// 与断点存储自己的实例共用,读回来的段不必再写一遍。
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: ScanResumeSegmentManifest] = [:]

    private func registryKey(_ id: UUID) -> String {
        directory.standardizedFileURL.path + "|" + id.uuidString
    }

    private func knownManifest(_ id: UUID) -> ScanResumeSegmentManifest? {
        Self.registryLock.lock()
        defer { Self.registryLock.unlock() }
        return Self.registry[registryKey(id)]
    }

    private func register(_ manifest: ScanResumeSegmentManifest) {
        Self.registryLock.lock()
        Self.registry[registryKey(manifest.id)] = manifest
        Self.registryLock.unlock()
    }

    static let fileMagic: [UInt8] = Array("PMWALKSG".utf8)
    static let fileVersion: UInt32 = 1
    static let headerSize = 32

    public init(directory: URL) {
        self.directory = directory
    }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".pmwalk")
    }

    func beginPass() {
        lock.lock()
        referenced = []
        writtenByteCount = 0
        lock.unlock()
    }

    func endPass() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return referenced
    }

    /// 这一遍编码里新写到盘上的段文件字节数(已经在盘上的段不算)。
    var bytesWrittenThisPass: Int {
        lock.lock()
        defer { lock.unlock() }
        return writtenByteCount
    }

    /// 段已经在盘上就只登记引用;否则写成文件(先写临时文件再改名)。
    func store(_ segment: SourceScanWalkLog.Segment) throws -> ScanResumeSegmentManifest {
        let manifest: ScanResumeSegmentManifest
        if let known = knownManifest(segment.id),
           FileManager.default.fileExists(atPath: fileURL(for: segment.id).path) {
            manifest = known
        } else {
            manifest = try Self.write(segment, to: fileURL(for: segment.id), directory: directory)
            register(manifest)
            lock.lock()
            writtenByteCount += manifest.byteCount
            lock.unlock()
        }
        lock.lock()
        referenced.insert(segment.id)
        lock.unlock()
        return manifest
    }

    func load(_ manifest: ScanResumeSegmentManifest) throws -> SourceScanWalkLog.Segment {
        let url = fileURL(for: manifest.id)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ScanResumeSegmentFileError.missing
        }
        let segment = try Self.decode(data, manifest: manifest)
        register(manifest)
        return segment
    }

    /// 删掉 `keep` 以外的段文件(以及中途留下的临时文件)。
    public func removeFiles(keeping keep: Set<UUID>) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let id = name.hasSuffix(".pmwalk") ? UUID(uuidString: String(name.dropLast(".pmwalk".count))) : nil
            if let id, keep.contains(id) { continue }
            guard name.hasSuffix(".pmwalk") || name.hasSuffix(".pmwalk.partial") else { continue }
            if let id {
                Self.registryLock.lock()
                Self.registry[registryKey(id)] = nil
                Self.registryLock.unlock()
            }
            try? manager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Format
    //
    // [头 32 字节:魔数 8、版本 4、保留 4、歌曲 ID 个数 8、歌曲 ID 区字节数 8]
    // [歌曲 ID:每个 4 字节长度 + UTF-8]
    // [索引:`SourceSyncIndex.writeBinary` 的原样输出]
    // [以上全部内容的 SHA-256,32 字节]

    static func write(
        _ segment: SourceScanWalkLog.Segment,
        to url: URL,
        directory: URL
    ) throws -> ScanResumeSegmentManifest {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(url.lastPathComponent + ".partial")
        defer { try? manager.removeItem(at: partial) }
        guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: partial)
        var hasher = SHA256()
        var byteCount = 0
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        func emit(_ bytes: UnsafeRawBufferPointer) throws {
            guard bytes.count > 0 else { return }
            hasher.update(bufferPointer: bytes)
            byteCount += bytes.count
            if bytes.count >= 64 * 1024 {
                try flush()
                try handle.write(contentsOf: bytes)
            } else {
                buffer.append(contentsOf: bytes)
                if buffer.count >= 256 * 1024 { try flush() }
            }
        }
        func emitInteger<T: FixedWidthInteger>(_ value: T) throws {
            try withUnsafeBytes(of: value.littleEndian) { try emit($0) }
        }
        do {
            var songIDBytes = 0
            for id in segment.songIDs { songIDBytes += 4 + id.utf8.count }
            try fileMagic.withUnsafeBytes { try emit($0) }
            try emitInteger(fileVersion)
            try emitInteger(UInt32(0))
            try emitInteger(UInt64(segment.songIDs.count))
            try emitInteger(UInt64(songIDBytes))
            for id in segment.songIDs {
                var id = id
                try id.withUTF8 { bytes in
                    try emitInteger(UInt32(bytes.count))
                    try emit(UnsafeRawBufferPointer(bytes))
                }
            }
            let summary = try segment.index.writeBinary { try emit($0) }
            let digest = Data(hasher.finalize())
            try flush()
            try handle.write(contentsOf: digest)
            try handle.synchronize()
            try handle.close()
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            try manager.moveItem(at: partial, to: url)
            return ScanResumeSegmentManifest(
                id: segment.id,
                sha256: digest.map { String(format: "%02x", $0) }.joined(),
                byteCount: byteCount + digest.count,
                rows: summary.rowCount,
                songIDs: segment.songIDs.count
            )
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func decode(_ data: Data, manifest: ScanResumeSegmentManifest) throws -> SourceScanWalkLog.Segment {
        guard data.count == manifest.byteCount, data.count >= headerSize + 32 else {
            throw ScanResumeSegmentFileError.malformed
        }
        let payloadCount = data.count - 32
        let digest = data.withUnsafeBytes { raw in
            Data(SHA256.hash(data: UnsafeRawBufferPointer(rebasing: raw[0..<payloadCount])))
        }
        guard digest.elementsEqual(data[data.startIndex + payloadCount..<data.endIndex]),
              digest.map({ String(format: "%02x", $0) }).joined() == manifest.sha256.lowercased() else {
            throw ScanResumeSegmentFileError.digestMismatch
        }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> SourceScanWalkLog.Segment in
            guard Array(raw[0..<8]) == fileMagic else { throw ScanResumeSegmentFileError.malformed }
            func read<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
                T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            guard read(UInt32.self, at: 8) == fileVersion else { throw ScanResumeSegmentFileError.malformed }
            let idCount = read(UInt64.self, at: 16)
            let idBytes = read(UInt64.self, at: 24)
            guard idCount == UInt64(manifest.songIDs),
                  idBytes <= UInt64(payloadCount - headerSize) else { throw ScanResumeSegmentFileError.malformed }
            var offset = headerSize
            let idEnd = headerSize + Int(idBytes)
            var songIDs: [String] = []
            songIDs.reserveCapacity(Int(idCount))
            for _ in 0..<idCount {
                guard offset + 4 <= idEnd else { throw ScanResumeSegmentFileError.malformed }
                let length = Int(read(UInt32.self, at: offset))
                offset += 4
                guard offset + length <= idEnd else { throw ScanResumeSegmentFileError.malformed }
                songIDs.append(String(decoding: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + length]), as: UTF8.self))
                offset += length
            }
            guard offset == idEnd else { throw ScanResumeSegmentFileError.malformed }
            let indexData = data[data.startIndex + idEnd..<data.startIndex + payloadCount]
            let index: SourceSyncIndex
            do {
                index = try SourceSyncIndex.decodeBinary(indexData)
            } catch {
                throw ScanResumeSegmentFileError.malformed
            }
            guard index.count == manifest.rows else { throw ScanResumeSegmentFileError.malformed }
            return SourceScanWalkLog.Segment(id: manifest.id, index: index, songIDs: songIDs)
        }
    }
}

extension CodingUserInfoKey {
    /// 编码/解码扫描断点时放一个 `ScanResumeSegmentStore`:走查进度的段写成旁边的文件,
    /// 断点 JSON 里只留清单。不放时整份内联编码(与以前的格式相同)。
    public static let scanResumeSegmentStore = CodingUserInfoKey(rawValue: "PrimuseKit.ScanResumeSegmentStore")!
}
