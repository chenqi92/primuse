import Foundation

/// Thread-safe file logger that writes to the app's Documents directory.
/// The log file can be retrieved via iTunes File Sharing (UIFileSharingEnabled).
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.primuse.filelogger", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("primuse_debug.log")

        // Rotate: 上限 10MB (2MB 时一会儿就被刷屏, 用户拉日志诊断时只能看到
        // 最近一小段。10MB 大概能放几小时密集播放 + 刮削的全量日志, 够诊断。)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > 10_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
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
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Returns the log file URL for sharing/debugging
    var logFileURL: URL { fileURL }

    /// Returns recent log content (last N bytes)
    func recentContent(maxBytes: Int = 50_000) -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "(no log file)" }
        if data.count <= maxBytes {
            return String(data: data, encoding: .utf8) ?? "(encoding error)"
        }
        let tail = data.suffix(maxBytes)
        return "...(truncated)...\n" + (String(data: tail, encoding: .utf8) ?? "(encoding error)")
    }
}

/// Convenience global function
func plog(_ message: String, file: String = #file, line: Int = #line) {
    FileLogger.shared.log(message, file: file, line: line)
}
