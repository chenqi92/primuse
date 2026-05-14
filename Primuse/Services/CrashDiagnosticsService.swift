import Foundation
import MetricKit
import OSLog
import PrimuseKit

private let crashLog = Logger(subsystem: "com.welape.yuanyin", category: "Crash")

/// 系统 MetricKit 接收上一次 launch 留下的 crash / hang 诊断报告。完全跑在
/// 系统侧、隐私边界内,不需要第三方 SDK,也不会主动外发数据 —— 报告全部
/// 落本地 (App Group container),用户在设置里能查看 + 通过分享面板手动
/// 发邮件给我。
///
/// 何时触发:
/// - app 启动 24h 内: `didReceive(_ payloads: [MXDiagnosticPayload])` 会被
///   异步回调,把上次启动里发生的 crash / hang / disk write 异常等打包给我
/// - app 一天上线最多一次,我把每份 payload 直接 dump JSON 到 disk,文件名
///   形如 `crash-<unix-ts>.json`
/// - 文件容量上限 50 份, 超过按时间最老的删 (LRU)
@MainActor
final class CrashDiagnosticsService: NSObject {
    static let directoryName = "DiagnosticReports"
    static let maxReports = 50

    /// 启动时注册到 MetricKit。`MXMetricManager` 是单例,无需保存返回值。
    /// 必须保持 self 引用至 app 死亡 (AppServices 持有,生命周期对齐)。
    func register() {
        MXMetricManager.shared.add(self)
        crashLog.notice("CrashDiagnosticsService registered with MetricKit")
    }

    /// 列出已收集的报告(给 Settings 视图渲染列表用),按时间倒序。
    func reports() -> [DiagnosticReport] {
        guard let dir = Self.reportsDirectory() else { return [] }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> DiagnosticReport? in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let date = attrs?[.creationDate] as? Date ?? Date()
                let size = (attrs?[.size] as? Int) ?? 0
                return DiagnosticReport(url: url, date: date, sizeBytes: size)
            }
            .sorted { $0.date > $1.date }
    }

    /// 用户在 settings 里点 "清空"。删全部本地报告。
    func clearAll() {
        guard let dir = Self.reportsDirectory() else { return }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            try? fm.removeItem(at: url)
        }
        crashLog.notice("Cleared all diagnostic reports")
    }

    private static func reportsDirectory() -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }
        let dir = containerURL.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated func persistPayload(_ payload: MXDiagnosticPayload) {
        // payload.jsonRepresentation() 给完整结构化数据,可直接写盘
        let data = payload.jsonRepresentation()
        Task { @MainActor in
            guard let dir = Self.reportsDirectory() else { return }
            let stamp = Int(Date().timeIntervalSince1970)
            let filename = "crash-\(stamp).json"
            let url = dir.appendingPathComponent(filename)
            do {
                try data.write(to: url, options: .atomic)
                crashLog.notice("Wrote diagnostic payload to \(filename)")
                pruneOldReports()
            } catch {
                crashLog.error("Failed to write diagnostic payload: \(error.localizedDescription)")
            }
        }
    }

    private func pruneOldReports() {
        let all = reports()
        guard all.count > Self.maxReports else { return }
        let drop = all.dropFirst(Self.maxReports)
        for r in drop {
            try? FileManager.default.removeItem(at: r.url)
        }
    }
}

extension CrashDiagnosticsService: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // 我们目前不关心常规 metrics (CPU / 内存等),只看 diagnostics。
        crashLog.debug("Received \(payloads.count) metric payloads, ignoring")
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        crashLog.notice("Received \(payloads.count) diagnostic payloads")
        for payload in payloads {
            persistPayload(payload)
        }
    }
}

/// Settings UI 用的简表条目 —— 由 reports() 返回。
struct DiagnosticReport: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let date: Date
    let sizeBytes: Int

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    var displayDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
