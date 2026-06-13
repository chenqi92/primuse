import Foundation

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

    /// 当前日志文件的累计字节数。只在 `queue` 上读写。
    private var currentBytes: Int = 0

    private init() {
        let docs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let entry = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        // Also print to console
        print(message)

        queue.async { [weak self] in
            self?.appendToFile(entry)
        }
    }

    private func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // 写入前若已超上限, 先轮转(保留一代到 .1, 再从零开始新文件)。
        if currentBytes >= Self.maxBytes {
            rotate()
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
                currentBytes += data.count
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
            currentBytes = data.count
        }
    }

    /// 把当前日志改名为 .1(覆盖上一代), 计数器清零。下次写入会新建文件。
    private func rotate() {
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
