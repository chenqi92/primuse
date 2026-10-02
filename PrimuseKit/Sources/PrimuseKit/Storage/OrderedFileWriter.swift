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
