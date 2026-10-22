import Foundation

/// 在一条串行后台队列上编码并原子写盘。提交顺序就是落盘顺序：先排的写一定先落盘，
/// 跨文件也一样；删除排在它之前的写之后，不会被晚到的旧写复活。
///
/// 给那些整份编码很贵、又必须按先后次序落盘的状态文件用 —— 比如 CloudKit 同步的
/// system fields 缓存必须早于引擎游标落盘。编码闭包在后台队列上执行，捕获的只能是
/// 提交那一刻的快照（值类型拷贝），不能再引用会被别的线程改动的状态。
public final class OrderedFileWriter: Sendable {
    private let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    /// 排一次整份写。`encode` 抛错或返回 nil 时这一次什么都不写，后面排的照常执行；
    /// 写成功后在同一条队列上把字节数交给 `written`。
    public func write(
        to url: URL,
        encode: @escaping @Sendable () throws -> Data?,
        written: (@Sendable (Int) -> Void)? = nil
    ) {
        queue.async {
            guard let data = try? encode() else { return }
            do {
                try data.write(to: url, options: .atomic)
                written?(data.count)
            } catch {
                return
            }
        }
    }

    /// 排一次追加: 把 `encode` 给出的字节接到文件末尾, 文件不在就新建。和整份写、删除
    /// 排在同一条队列上, 先后次序一样有保证。写到一半进程被杀时文件末尾会留下半截,
    /// 读的一方要能认出来丢掉(见 `KeyedDataJournal`)。
    public func append(
        to url: URL,
        encode: @escaping @Sendable () throws -> Data?,
        written: (@Sendable (Int) -> Void)? = nil
    ) {
        queue.async {
            guard let data = try? encode(), !data.isEmpty else { return }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
                written?(data.count)
            } catch {
                return
            }
        }
    }

    public func removeItem(at url: URL) {
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 等已经排上的写和删全部完成。同步读回文件、或判断文件在不在之前调用。
    public func drain() {
        queue.sync {}
    }
}

/// 键到字节的表以「整份底本 + 追加日志」落盘: 平时只把改动的键追加进日志, 日志长到
/// 底本的一定比例再整份重写底本、删掉日志。整份重写一张几千条的表, 写入量与表的大小
/// 成正比, 而一批改动往往只碰几十条。
///
/// 日志是一串记录, 每条是 4 字节大端长度加一份二进制 plist。重放到第一条读不全或
/// 解不开的记录为止: 追加到一半被杀只会丢掉最后那一批。先写底本再删日志, 两步之间
/// 被杀时旧日志在新底本上再放一遍, 结果不变。
public enum KeyedDataJournal {
    public struct Entry: Codable, Sendable, Equatable {
        public var upserts: [String: Data]
        public var removals: [String]

        public init(upserts: [String: Data] = [:], removals: [String] = []) {
            self.upserts = upserts
            self.removals = removals
        }

        public var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }
    }

    /// 日志超过这么多字节、且超过底本的一半时整份合并。
    public static let minimumCompactionBytes = 512 * 1024

    public static func shouldCompact(journalBytes: Int, baseBytes: Int) -> Bool {
        journalBytes > max(minimumCompactionBytes, baseBytes / 2)
    }

    public static func encodeRecord(_ entry: Entry) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = try encoder.encode(entry)
        var length = UInt32(payload.count).bigEndian
        var record = Data(bytes: &length, count: 4)
        record.append(payload)
        return record
    }

    /// 把 `journal` 里的记录依次放到 `table` 上, 返回放上去的条数。
    @discardableResult
    public static func replay(_ journal: Data, onto table: inout [String: Data]) -> Int {
        let decoder = PropertyListDecoder()
        var offset = journal.startIndex
        var applied = 0
        while journal.endIndex - offset >= 4 {
            let length = journal[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let payloadStart = offset + 4
            guard length > 0, journal.endIndex - payloadStart >= length,
                  let entry = try? decoder.decode(
                      Entry.self,
                      from: journal.subdata(in: payloadStart..<payloadStart + length)
                  ) else {
                break
            }
            for key in entry.removals { table.removeValue(forKey: key) }
            for (key, value) in entry.upserts { table[key] = value }
            applied += 1
            offset = payloadStart + length
        }
        return applied
    }
}
