import Foundation

extension QueueContinuation {
    /// 整张请求的 id,按需逐条读出(映射文件里的那份不先读成一个数组)。
    public var requestedIDList: QueueRequestedIDList { QueueRequestedIDList(storage: idStorage) }
}

/// 续接请求的 id 序列。
public struct QueueRequestedIDList: RandomAccessCollection, Sendable {
    let storage: QueueContinuationIDStorage

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }
    public subscript(position: Int) -> String { storage[position] }
}

/// 一个队列请求的整张 id:续接(整库请求时在映射文件里)或一份普通数组。比较两份请求是不是同一张时
/// 逐条比,不把映射的那份读成数组;条数不同立刻不等。
public enum QueueRequestedSongs: Equatable, Sendable {
    case continuation(QueueContinuation)
    case ids([String])

    public var count: Int {
        switch self {
        case .continuation(let continuation): return continuation.requestedCount
        case .ids(let ids): return ids.count
        }
    }

    private var storage: QueueContinuationIDStorage {
        switch self {
        case .continuation(let continuation): return continuation.idStorage
        case .ids(let ids): return .memory(ids)
        }
    }

    public static func == (lhs: QueueRequestedSongs, rhs: QueueRequestedSongs) -> Bool {
        if case .ids(let left) = lhs, case .ids(let right) = rhs { return left == right }
        let left = lhs.storage
        let right = rhs.storage
        guard left.count == right.count else { return false }
        // 逐条按 Swift 的字符串相等比(与比较两个数组同一口径);指纹按字节算,不能拿来先判不等。
        return left == right
    }
}
