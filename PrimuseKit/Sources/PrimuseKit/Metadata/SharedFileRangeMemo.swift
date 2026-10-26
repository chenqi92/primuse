import Foundation

/// 一个整轨文件切出来的几条 CUE 分轨补读标签时, 读的都是这个文件的同样几段(首段、尾段)。
/// 读到的字节按文件留一小会儿, 下一条分轨直接拿去解析, 不再把同样的首尾再下载一遍。
/// 分轨在补读队列里本来就挨着: 只留最近两个文件、总量有上限、两分钟没人用就作废。
/// 只收已经读完的结果, 不合并正在下载的请求 —— 每一段读取仍归发起它的那首歌, 停下时照常能取消。
public final class SharedFileRangeMemo: @unchecked Sendable {
    /// 同一个源、同一路径, 大小和版本也对得上才算同一个文件。重扫后文件变了就是另一把钥匙。
    public struct FileKey: Hashable, Sendable {
        public let sourceID: String
        public let path: String
        public let fileSize: Int64
        public let revision: String?
        public let modifiedAt: Date?

        public init(sourceID: String, path: String, fileSize: Int64, revision: String?, modifiedAt: Date?) {
            self.sourceID = sourceID
            self.path = path
            self.fileSize = fileSize
            self.revision = revision
            self.modifiedAt = modifiedAt
        }
    }

    private struct RangeKey: Hashable {
        let offset: Int64
        let length: Int64
    }

    private struct Entry {
        let file: FileKey
        var ranges: [RangeKey: Data] = [:]
        var byteCount = 0
        var lastUsedAt: Date
    }

    public static let defaultLifetime: TimeInterval = 120
    public static let defaultMaximumFiles = 2
    public static let defaultMaximumBytes = 8 * 1024 * 1024

    private let lock = NSLock()
    /// 最近用过的排在最后。
    private var entries: [Entry] = []
    private let lifetime: TimeInterval
    private let maximumFiles: Int
    private let maximumBytes: Int

    public init(
        lifetime: TimeInterval = SharedFileRangeMemo.defaultLifetime,
        maximumFiles: Int = SharedFileRangeMemo.defaultMaximumFiles,
        maximumBytes: Int = SharedFileRangeMemo.defaultMaximumBytes
    ) {
        self.lifetime = lifetime
        self.maximumFiles = max(1, maximumFiles)
        self.maximumBytes = max(0, maximumBytes)
    }

    /// 这个文件的这一段刚被别的分轨读过就直接给出; 偏移和长度要一模一样(尾段用负偏移)。
    public func data(for file: FileKey, offset: Int64, length: Int64, now: Date = Date()) -> Data? {
        lock.withLock {
            removeExpired(now: now)
            guard let index = entries.firstIndex(where: { $0.file == file }),
                  let data = entries[index].ranges[RangeKey(offset: offset, length: length)] else {
                return nil
            }
            var entry = entries.remove(at: index)
            entry.lastUsedAt = now
            entries.append(entry)
            return data
        }
    }

    public func store(_ data: Data, for file: FileKey, offset: Int64, length: Int64, now: Date = Date()) {
        guard !data.isEmpty, data.count <= maximumBytes else { return }
        lock.withLock {
            removeExpired(now: now)
            var entry: Entry
            if let index = entries.firstIndex(where: { $0.file == file }) {
                entry = entries.remove(at: index)
            } else {
                entry = Entry(file: file, lastUsedAt: now)
            }
            entry.lastUsedAt = now
            let key = RangeKey(offset: offset, length: length)
            let replacedCount = entry.ranges[key]?.count ?? 0
            // 单这一个文件就放不下的段不留, 已经留着的几段照旧可用。
            if entry.byteCount - replacedCount + data.count <= maximumBytes {
                entry.ranges[key] = data
                entry.byteCount += data.count - replacedCount
            }
            entries.append(entry)
            // 先让出最久没用的文件。
            while entries.count > maximumFiles
                || (entries.count > 1 && entries.reduce(0, { $0 + $1.byteCount }) > maximumBytes) {
                entries.removeFirst()
            }
        }
    }

    public func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    private func removeExpired(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.lastUsedAt) > lifetime }
    }
}
