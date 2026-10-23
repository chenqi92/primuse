import Foundation

/// HTTP/1.1 分块传输(Transfer-Encoding: chunked)的增量解码器:收到多少喂多少,
/// 解出的正文立刻交出去,不用等整个响应收完,也不会把一整块攒在内存里。
/// 读到末尾的 0 长度块即 `isComplete`,之后的尾部字段和多余字节一律忽略。
public struct HTTPChunkedBodyDecoder: Sendable {
    private enum State: Sendable {
        case sizeLine
        case chunkData(remaining: Int)
        case chunkTerminator
        case complete
    }

    private static let lineBreak = Data("\r\n".utf8)

    private var state = State.sizeLine
    /// 跨两次 append 的半行块大小或半个块结尾 CRLF。
    private var pending = Data()
    private let maximumSizeLineBytes: Int

    public var isComplete: Bool {
        if case .complete = state { return true }
        return false
    }

    public init(maximumSizeLineBytes: Int = 8 * 1_024) {
        self.maximumSizeLineBytes = maximumSizeLineBytes
    }

    /// 喂进一段原始响应正文。`emit` 按顺序收到解出的正文片段,片段下标从 0 起。
    /// 块大小或块结尾不合法时抛 `URLError(.badServerResponse)`;`emit` 抛出的错误原样抛出。
    public mutating func append(_ data: Data, emit: (Data) throws -> Void) throws {
        guard !isComplete, !data.isEmpty else { return }
        let input: Data
        if pending.isEmpty {
            input = data
        } else {
            pending.append(data)
            input = pending
            pending = Data()
        }

        // 只用 input 自己的下标走:传进来的 Data 可能是切片,下标不从 0 起。
        var cursor = input.startIndex
        while cursor < input.endIndex {
            switch state {
            case .complete:
                return
            case .sizeLine:
                guard let lineEnd = input.range(of: Self.lineBreak, in: cursor..<input.endIndex) else {
                    guard input.endIndex - cursor <= maximumSizeLineBytes else {
                        throw URLError(.badServerResponse)
                    }
                    pending = Data(input[cursor...])
                    return
                }
                let line = String(decoding: input[cursor..<lineEnd.lowerBound], as: UTF8.self)
                let token = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                guard let size = Int(token.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16),
                      size >= 0 else {
                    throw URLError(.badServerResponse)
                }
                cursor = lineEnd.upperBound
                state = size == 0 ? .complete : .chunkData(remaining: size)
            case .chunkData(let remaining):
                let count = min(remaining, input.endIndex - cursor)
                let end = input.index(cursor, offsetBy: count)
                try emit(Data(input[cursor..<end]))
                cursor = end
                state = count == remaining ? .chunkTerminator : .chunkData(remaining: remaining - count)
            case .chunkTerminator:
                guard input.endIndex - cursor >= Self.lineBreak.count else {
                    pending = Data(input[cursor...])
                    return
                }
                let end = input.index(cursor, offsetBy: Self.lineBreak.count)
                guard input[cursor..<end].elementsEqual(Self.lineBreak) else {
                    throw URLError(.badServerResponse)
                }
                cursor = end
                state = .sizeLine
            }
        }
    }
}
