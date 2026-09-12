import Foundation
import PrimuseKit

/// Thread-safe file logger that writes to the app's Caches directory.
/// The log file URL is exposed via `logFileURL` for sharing/diagnostics
/// (e.g. share sheet on iOS, "reveal in Finder" on macOS).
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    /// 单个日志文件体积上限 10MB。超过后轮转: 当前文件改名为 .1 保留一代,
    /// 再从零开始写新文件。这样长会话(macOS 常驻菜单栏可连跑数天)里日志
    /// 不会无上限增长占满磁盘, 同时还能留住最近一代历史。
    private static let maxBytes = 10_000_000

    private let fileURL: URL
    private let rotatedURL: URL
    private let queue = DispatchQueue(label: "com.primuse.filelogger", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 队列积压的准入计数。`log` 在入队前、队列作业在出队后都要改它,
    /// 所以只能靠锁保护; 临界区里只有整数加减, 不做任何字符串或 IO。
    private let backlogLock = NSLock()
    private var pendingCount = 0
    private var droppedCount = 0

    /// 连续重复行折叠器, 只在 `queue` 上驱动, 因此写出顺序与入队顺序一致。
    private var coalescer = LogDuplicateCoalescer()

    /// 丢弃汇总、重复汇总这类由 logger 自己产生的行统一挂这个来源标记。
    private static let internalSource = "FileLogger"

    /// 当前日志文件的累计字节数。只在 `queue` 上读写。
    private var currentBytes: Int = 0

    /// 常驻写句柄, 首次写入时惰性打开; 轮转或写失败后置空重开。
    /// 与 `currentBytes` 一样只在 `queue` 上读写(`init` 早于任何队列作业)。
    private var handle: FileHandle?

    private init() {
        let docs = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        fileURL = docs.appendingPathComponent("primuse_debug.log")
        rotatedURL = docs.appendingPathComponent("primuse_debug.log.1")

        // 以已有文件大小初始化计数器, 让进程内的轮转判断接着上次会话累计。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int {
            currentBytes = size
        }

        // Write session header
        let header = "\n\n========== SESSION START: \(Date()) ==========\n"
        appendToFile(header)
        // 会话头写完后在队列上做一次收尾, 把跨会话残留的重复计数落到文件里。
        queue.async { [weak self] in
            self?.flushPendingSummaries()
        }
    }

    /// 保留给既有调用方的入口; 规则与正则实例都在 PrimuseKit 里常驻复用。
    static func redactSensitiveData(_ message: String) -> String {
        LogRedactionPolicy.redact(message)
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")

        // 入队前先过准入: 队列是串行的, 消费速度有上限, 而紧循环打点的生产速度
        // 没有上限。超限时直接记一笔丢弃就返回, 连闭包都不分配 —— 这是唯一能
        // 阻止积压把进程撑到 Jetsam 的位置。
        backlogLock.lock()
        guard LogBacklogPolicy.admits(pendingCount: pendingCount) else {
            droppedCount += 1
            backlogLock.unlock()
            return
        }
        pendingCount += 1
        backlogLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            // Redaction (five regular-expression passes), timestamp formatting,
            // console output, and disk I/O all live on the utility queue. Bulk
            // metadata backfill can emit several messages per song; doing this
            // work at the call site previously consumed the main actor even
            // though the final file append itself was asynchronous.
            self.backlogLock.lock()
            self.pendingCount -= 1
            let dropped = self.droppedCount
            self.droppedCount = 0
            self.backlogLock.unlock()

            // 丢弃汇总写在当前这条之前, 文件里就能看出丢了多少、丢在哪个位置。
            if dropped > 0 {
                self.appendToFile(
                    self.formatEntry(
                        LogBacklogPolicy.droppedSummary(count: dropped),
                        source: Self.internalSource
                    )
                )
            }

            // 判重用原始消息, 比较的是廉价的字符串相等, 不碰正则。
            let key = "\(fileName):\(line) \(message)"
            for produced in self.coalescer.absorb(key: key, line: message) {
                self.appendToFile(self.formatEntry(produced, source: "\(fileName):\(line)"))
            }
        }
    }

    /// 把挂起的重复汇总写出去。只在 `queue` 上调用。
    private func flushPendingSummaries() {
        for summary in coalescer.flush() {
            appendToFile(formatEntry(summary, source: Self.internalSource))
        }
    }

    /// 脱敏 + 时间戳 + 来源前缀。每一条写进文件的行(含 logger 自己产生的汇总)
    /// 都走这里, 脱敏覆盖面与改动前一致。
    private func formatEntry(_ body: String, source: String) -> String {
        let safeMessage = Self.redactSensitiveData(body)
        let timestamp = dateFormatter.string(from: Date())
        #if DEBUG
        print(safeMessage)
        #endif
        return "[\(timestamp)] [\(source)] \(safeMessage)\n"
    }

    private func appendToFile(_ text: String) {
        // 写入前若已超上限, 先轮转(保留一代到 .1, 再从零开始新文件)。
        if currentBytes >= Self.maxBytes {
            // 挂起的重复计数属于旧的一代, 轮转前先落盘, 否则这条汇总会跨代,
            // 读旧文件的人看不到"最后那几行重复了多少次"。这里必须直接走
            // `writeRaw`: 再进 `appendToFile` 会二次触发轮转, 把上一代覆盖掉。
            for summary in coalescer.flush() {
                if let data = formatEntry(summary, source: Self.internalSource).data(using: .utf8) {
                    writeRaw(data)
                }
            }
            rotate()
        }

        guard let data = text.data(using: .utf8) else { return }
        writeRaw(data)
    }

    /// 实际写盘。不做轮转判断, 供轮转前的收尾复用。
    private func writeRaw(_ data: Data) {
        guard let handle = openHandleIfNeeded() else { return }
        if write(data, to: handle) {
            currentBytes += data.count
            return
        }
        // 写失败一般意味着句柄背后的文件已经不可写(被替换 / 描述符失效)。
        // 关掉重开一次, 再失败就丢掉这一行, 不在日志路径上继续放大故障。
        closeHandle()
        guard let reopened = openHandleIfNeeded(), write(data, to: reopened) else {
            closeHandle()
            return
        }
        currentBytes += data.count
    }

    /// 惰性打开并常驻写句柄。之前每行日志都要 fileExists + open + seek +
    /// close 一轮系统调用, 元数据回填这种高频日志下白白占用 IO。
    private func openHandleIfNeeded() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil) else { return nil }
            currentBytes = 0
        }
        guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
        opened.seekToEndOfFile()
        handle = opened
        return opened
    }

    private func write(_ data: Data, to handle: FileHandle) -> Bool {
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// 把当前日志改名为 .1(覆盖上一代), 计数器清零。下次写入会新建文件。
    /// 常驻句柄必须先关闭, 否则改名后还会继续写进上一代文件。
    private func rotate() {
        closeHandle()
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        currentBytes = 0
    }

    /// Returns the log file URL for sharing/debugging
    var logFileURL: URL { fileURL }

    /// Returns recent log content (last N bytes). 用 FileHandle.seek 只读尾部,
    /// 避免把可能数 MB 的整个文件全量读进内存。
    func recentContent(maxBytes: Int = 50_000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return "(no log file)" }
        defer { try? handle.close() }

        let total: UInt64
        if let end = try? handle.seekToEnd() {
            total = end
        } else {
            return "(no log file)"
        }

        let want = UInt64(max(0, maxBytes))
        let truncated = total > want
        let offset = truncated ? total - want : 0
        try? handle.seek(toOffset: offset)

        let data = (try? handle.readToEnd()) ?? Data()
        let body = String(data: data, encoding: .utf8) ?? "(encoding error)"
        return truncated ? "...(truncated)...\n" + body : body
    }
}

/// Convenience global function
func plog(_ message: String, file: String = #file, line: Int = #line) {
    FileLogger.shared.log(message, file: file, line: line)
}
