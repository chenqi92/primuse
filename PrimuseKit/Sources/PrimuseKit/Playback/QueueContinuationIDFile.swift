import Foundation

/// 续接请求的整张 id 列表放在映射文件里:每首歌的 id 按需从映射页读出,常驻内存里没有
/// 整库规模的 `[String]`(映射的干净页不计入 footprint)。
///
/// 文件格式(小端):
/// - 头 32 字节:魔数 `PQIDv2\0\0`、条数、id 正文字节数、指纹(`QueueContinuationStore.fingerprint` 的同一套 FNV-1a);
/// - id 正文:各条 UTF-8 首尾相接,补零到 4 字节对齐;
/// - 偏移表:条数 + 1 个 `UInt32`,第 i 条是正文里 `[offset[i], offset[i+1])`。
///
/// 存 id 而不存目录行号:目录重新导入后行号全部换新,存行号的续接会整张作废;id 跨导入不变。
/// 删掉的歌在取窗口时按 id 解析不到,照旧跳过。
public final class QueueContinuationIDFile: @unchecked Sendable {
    static let magic: [UInt8] = Array("PQIDv2".utf8) + [0, 0]
    static let headerSize = 32

    public let count: Int
    public let fingerprint: UInt64
    /// 映射着的文件内容(只读)。
    private let data: Data
    private let blobStart: Int
    private let offsetsStart: Int
    /// 进程内临时文件(大请求刚建好时落的盘):这一份放掉时删掉文件。映射在删掉之后照样可读。
    private let ownedURL: URL?

    private init(data: Data, count: Int, fingerprint: UInt64, blobLength: Int, ownedURL: URL?) {
        self.data = data
        self.count = count
        self.fingerprint = fingerprint
        self.blobStart = Self.headerSize
        self.offsetsStart = Self.headerSize + Self.aligned(blobLength)
        self.ownedURL = ownedURL
    }

    deinit {
        if let ownedURL { try? FileManager.default.removeItem(at: ownedURL) }
    }

    /// 本进程的临时文件(随这一份删掉);存档里映射来的为 nil。
    var spooledURL: URL? { ownedURL }

    /// 映射一个已写好的文件;格式不对、长度对不上时返回 nil。
    static func open(url: URL, owned: Bool = false) -> QueueContinuationIDFile? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              let header = Header(data) else { return nil }
        let offsetsStart = headerSize + aligned(header.blobLength)
        let expected = offsetsStart + (header.count + 1) * MemoryLayout<UInt32>.size
        guard data.count == expected else { return nil }
        let file = QueueContinuationIDFile(
            data: data, count: header.count, fingerprint: header.fingerprint,
            blobLength: header.blobLength, ownedURL: owned ? url : nil
        )
        guard file.offset(at: 0) == 0, file.offset(at: header.count) == header.blobLength else { return nil }
        return file
    }

    /// 只读文件头(不映射整份):条数与指纹。
    static func header(at url: URL) -> (count: Int, fingerprint: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: headerSize), let header = Header(prefix) else { return nil }
        return (header.count, header.fingerprint)
    }

    public subscript(position: Int) -> String {
        precondition(position >= 0 && position < count, "queue continuation id out of range")
        let lower = Int(offset(at: position))
        let upper = Int(offset(at: position + 1))
        return data.withUnsafeBytes { raw in
            String(decoding: UnsafeRawBufferPointer(rebasing: raw[(blobStart + lower)..<(blobStart + upper)]), as: UTF8.self)
        }
    }

    /// 某一段的 id(取窗口时用,一次至多一批)。
    func ids(in range: Range<Int>) -> [String] {
        range.map { self[$0] }
    }

    private func offset(at position: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offsetsStart + position * MemoryLayout<UInt32>.size, as: UInt32.self)
                .littleEndian
        }
    }

    // MARK: - Writing

    /// 把 `ids`(共 `count` 条)流式写到 `url`(先写临时文件再换上)。内存只占一块写缓冲与 4 字节/条的偏移表。
    @discardableResult
    static func write<IDs: Sequence>(_ ids: IDs, count: Int, to url: URL) throws -> UInt64 where IDs.Element == String {
        let temporary = url.appendingPathExtension("tmp")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: Data(repeating: 0, count: headerSize))
            var offsets = ContiguousArray<UInt32>()
            offsets.reserveCapacity(count + 1)
            offsets.append(0)
            var buffer = Data()
            buffer.reserveCapacity(1 << 16)
            var length = 0
            var hash = QueueContinuationStore.fingerprintSeed
            var written = 0
            for id in ids {
                for byte in id.utf8 {
                    hash ^= UInt64(byte)
                    hash = hash &* QueueContinuationStore.fingerprintPrime
                }
                hash ^= 10
                hash = hash &* QueueContinuationStore.fingerprintPrime
                buffer.append(contentsOf: id.utf8)
                length += id.utf8.count
                guard let end = UInt32(exactly: length) else { throw CocoaError(.fileWriteOutOfSpace) }
                offsets.append(end)
                written += 1
                if buffer.count >= 1 << 16 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            guard written == count else { throw CocoaError(.fileWriteUnknown) }
            buffer.append(Data(repeating: 0, count: aligned(length) - length))
            try handle.write(contentsOf: buffer)
            var table = Data(capacity: offsets.count * MemoryLayout<UInt32>.size)
            for offset in offsets {
                withUnsafeBytes(of: offset.littleEndian) { table.append(contentsOf: $0) }
            }
            try handle.write(contentsOf: table)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Header(count: count, blobLength: length, fingerprint: hash).encoded)
            try handle.close()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temporary, to: url)
            return hash
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: - Spooling

    /// 大请求刚建好时就落到这里,不在内存里留整张列表。
    static let spoolDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("primuse-queue-continuation", isDirectory: true)

    /// 上一个进程留下的临时文件(被杀时来不及删)在本进程第一次落盘前清掉。
    private static let spoolCleanup: Void = {
        let urls = (try? FileManager.default.contentsOfDirectory(at: spoolDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }()

    /// 写进一个本进程的临时文件并映射;写不了时返回 nil(调用方留在内存里)。
    static func spool(_ ids: [String]) -> QueueContinuationIDFile? {
        _ = spoolCleanup
        let url = spoolDirectory.appendingPathComponent("\(UUID().uuidString).qids")
        do {
            try write(ids, count: ids.count, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let file = open(url: url, owned: true) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return file
    }

    // MARK: - Header

    private struct Header {
        let count: Int
        let blobLength: Int
        let fingerprint: UInt64

        init(count: Int, blobLength: Int, fingerprint: UInt64) {
            self.count = count
            self.blobLength = blobLength
            self.fingerprint = fingerprint
        }

        init?(_ data: Data) {
            guard data.count >= QueueContinuationIDFile.headerSize,
                  Array(data.prefix(8)) == QueueContinuationIDFile.magic else { return nil }
            func value(_ offset: Int) -> UInt64 {
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
            }
            guard let count = Int(exactly: value(8)), let blobLength = Int(exactly: value(16)),
                  count >= 0, blobLength >= 0 else { return nil }
            self.count = count
            self.blobLength = blobLength
            self.fingerprint = value(24)
        }

        var encoded: Data {
            var data = Data(QueueContinuationIDFile.magic)
            for field in [UInt64(count), UInt64(blobLength), fingerprint] {
                withUnsafeBytes(of: field.littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
    }

    private static func aligned(_ length: Int) -> Int {
        (length + 3) & ~3
    }
}

/// 续接请求的 id:小请求留在内存数组里,大请求(整库)在映射文件里。
enum QueueContinuationIDStorage: Equatable, Sendable {
    case memory([String])
    case file(QueueContinuationIDFile)

    /// 超过这么多条就落盘映射。
    static let spoolThreshold = 4_096

    /// 大的落盘;落不了盘就留在内存(行为不变,只是多占内存)。
    static func make(_ ids: [String]) -> QueueContinuationIDStorage {
        guard ids.count > spoolThreshold, let file = QueueContinuationIDFile.spool(ids) else { return .memory(ids) }
        return .file(file)
    }

    var count: Int {
        switch self {
        case .memory(let ids): return ids.count
        case .file(let file): return file.count
        }
    }

    subscript(position: Int) -> String {
        switch self {
        case .memory(let ids): return ids[position]
        case .file(let file): return file[position]
        }
    }

    func ids(in range: Range<Int>) -> [String] {
        switch self {
        case .memory(let ids): return Array(ids[range])
        case .file(let file): return file.ids(in: range)
        }
    }

    /// 整张列表(整库请求时是一份整库规模的数组,只在改写列表、旧接口时临时建)。
    var materialized: [String] {
        switch self {
        case .memory(let ids): return ids
        case .file(let file): return (0..<file.count).map { file[$0] }
        }
    }

    var fingerprint: UInt64 {
        switch self {
        case .memory(let ids): return QueueContinuationStore.fingerprint(ids)
        case .file(let file): return file.fingerprint
        }
    }

    static func == (lhs: QueueContinuationIDStorage, rhs: QueueContinuationIDStorage) -> Bool {
        if case .file(let left) = lhs, case .file(let right) = rhs, left === right { return true }
        guard lhs.count == rhs.count else { return false }
        if case .memory(let left) = lhs, case .memory(let right) = rhs { return left == right }
        for position in 0..<lhs.count where lhs[position] != rhs[position] { return false }
        return true
    }
}
