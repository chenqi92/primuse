import Foundation
import MetricKit
import OSLog
import PrimuseKit
#if canImport(UIKit)
import UIKit
#endif

private let crashLog = Logger(subsystem: "com.welape.yuanyin", category: "Crash")

/// 系统 MetricKit 接收上一次 launch 留下的 crash / hang 诊断报告。完全跑在
/// 系统侧、隐私边界内,不需要第三方 SDK,也不会主动外发数据 —— 报告全部
/// 落本地 (App Group container),用户在设置里能查看 + 通过分享面板手动
/// 发邮件给我。
///
/// 系统通过异步序列或旧版 subscriber 交付诊断，每份报告保存为 JSON，文件名
///   形如 `crash-<unix-ts>-<uuid8>.json`(uuid8 保证同一秒内多份 payload 不互相覆盖)
/// 文件容量上限 50 份, 超过按时间最老的删 (LRU)
///
/// 另外收系统每天投递一次的**指标载荷** (`metrics-<unix-ts>-<uuid8>.json`)。
/// 它不是崩溃报告, 但被系统按内存上限回收、watchdog 终止、非正常退出这几种
/// "闪退"根本不产生崩溃报告, 只会计在指标载荷的 `applicationExitMetrics` 里,
/// 内存峰值也只在这里。丢掉它, 用户报"闪退"而 Organizer 的 Crashes 一条没有
/// 时就只剩猜。两份分开存、分开计数, 崩溃列表的空状态才仍然代表"没崩过"。
@MainActor
final class CrashDiagnosticsService: NSObject {
    static let directoryName = "DiagnosticReports"
    static let maxReports = 50
    /// 指标载荷每天一份, 留两周足够回溯一次测试反馈。
    static let maxMetricReports = 14
    static let metricFilePrefix = "metrics-"
    private static let crashFilePrefix = "crash-"
    private var isRegistered = false
    private var diagnosticTask: Task<Void, Never>?
    /// 诊断报告是否已经由新的异步序列接管。接管后旧订阅者只负责指标载荷,
    /// 否则同一份诊断会被两条路各写一遍。
    private var usesModernDiagnosticStream = false
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryWarningObserver: NSObjectProtocol?
    private var lastMemoryPressureHandledAt: Date?
    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        directoryOverride = directory
        super.init()
    }

    deinit {
        diagnosticTask?.cancel()
        memoryPressureSource?.cancel()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *) {
            usesModernDiagnosticStream = true
            diagnosticTask = Task.detached(priority: .utility) { [weak self] in
                let manager = MetricKit.MetricManager()
                // Keep the manager alive for the entire asynchronous subscription.
                defer { withExtendedLifetime(manager) {} }
                for await report in manager.diagnosticReports {
                    guard !Task.isCancelled else { break }
                    do {
                        let data = try JSONEncoder().encode(report)
                        await self?.persistData(data)
                    } catch {
                        crashLog.error("Failed to encode diagnostic report: \(error.localizedDescription)")
                    }
                }
            }
            crashLog.notice("CrashDiagnosticsService registered with MetricManager")
        }
        #endif
        // 指标载荷只有旧订阅者这一条路。新序列接管诊断之后仍然要订阅, 否则
        // 内存上限终止 / watchdog / 非正常退出这些"没有崩溃报告的闪退"就没有
        // 任何记录。诊断那一路由 `usesModernDiagnosticStream` 让开, 不会重复写。
        MXMetricManager.shared.add(self)
        crashLog.notice("CrashDiagnosticsService subscribed to MetricKit payloads")
        startMemoryPressureMonitoring()
    }

    // MARK: - 内存压力

    /// 系统的内存告警是最后一次机会: 收到之后还不放手, 下一步就是直接回收
    /// 进程 —— 用户看到的是"闪退", 而且不会留下崩溃报告。这里做两件事:
    /// 把告警写进诊断日志(被回收前的最后一行就是它, 事后能认出死因), 再把
    /// 可以随时重建的派生数据丢掉, 已解码的封面是其中最大的一块。
    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressureSource?.data else { return }
                self.handleMemoryPressure(event.contains(.critical) ? "critical" : "warning")
            }
        }
        memoryPressureSource = source
        source.activate()

        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleMemoryPressure("app warning")
            }
        }
        #endif
    }

    private func handleMemoryPressure(_ level: String) {
        // 告警会连着来好几次, 第一次就已经把能丢的丢干净了; 再刷日志只会
        // 把终止前最有用的那几行挤出去。
        let now = Date()
        if let last = lastMemoryPressureHandledAt, now.timeIntervalSince(last) < 5 { return }
        lastMemoryPressureHandledAt = now
        plog("🧠 memory pressure \(level); dropping decoded artwork cache")
        crashLog.notice("Memory pressure \(level, privacy: .public); dropping decoded artwork cache")
        CachedArtworkView.purgeDecodedImageCache()
    }

    /// 列出已收集的崩溃 / 卡顿报告(给 Settings 视图渲染列表用),按时间倒序。
    /// 指标载荷不在这里 —— 它每天都来, 混进来这份列表就永远不空, 用户会
    /// 把"每天一份的运行指标"当成"每天都崩"。
    func reports() -> [DiagnosticReport] {
        collectReports { !$0.hasPrefix(Self.metricFilePrefix) }
    }

    /// 系统每天投递一次的指标载荷。发给开发者时随崩溃报告一起带上:
    /// 没有崩溃报告的"闪退"只能从它的 `applicationExitMetrics` 认出来。
    func metricReports() -> [DiagnosticReport] {
        collectReports { $0.hasPrefix(Self.metricFilePrefix) }
    }

    private func collectReports(_ includesFilename: (String) -> Bool) -> [DiagnosticReport] {
        guard let dir = reportsDirectory() else { return [] }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == "json" && includesFilename($0.lastPathComponent) }
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
        guard let dir = reportsDirectory() else { return }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            try? fm.removeItem(at: url)
        }
        crashLog.notice("Cleared all diagnostic reports")
    }

    private func reportsDirectory() -> URL? {
        let dir: URL
        if let directoryOverride {
            dir = directoryOverride
        } else {
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
            ) else { return nil }
            dir = containerURL.appendingPathComponent(Self.directoryName, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func persistData(_ data: Data) {
        persistData(data, prefix: Self.crashFilePrefix)
    }

    func persistData(_ data: Data, prefix: String) {
        guard let dir = reportsDirectory() else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let unique = UUID().uuidString.prefix(8)
        let filename = "\(prefix)\(stamp)-\(unique).json"
        let url = dir.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            crashLog.notice("Wrote diagnostic payload to \(filename)")
            pruneOldReports()
        } catch {
            crashLog.error("Failed to write diagnostic payload: \(error.localizedDescription)")
        }
    }

    private func pruneOldReports() {
        prune(reports(), keeping: Self.maxReports)
        prune(metricReports(), keeping: Self.maxMetricReports)
    }

    private func prune(_ all: [DiagnosticReport], keeping limit: Int) {
        guard all.count > limit else { return }
        for report in all.dropFirst(limit) {
            try? FileManager.default.removeItem(at: report.url)
        }
    }
}

extension CrashDiagnosticsService: MXMetricManagerSubscriber {
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // `applicationExitMetrics` 是唯一能把"闪退"分类的数据: 前后台各自的
        // 内存上限终止、watchdog、非正常退出、真崩溃分别多少次; `memoryMetrics`
        // 还带当天的内存峰值。这两项决定了一份"进主页就退出"的反馈到底该往
        // 内存、系统终止还是代码崩溃上查, 所以必须留下来。
        let datas = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            crashLog.notice("Received \(datas.count) metric payloads")
            for data in datas {
                self.persistData(data, prefix: Self.metricFilePrefix)
            }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // payload.jsonRepresentation() 给完整结构化数据,可直接写盘
        let datas = payloads.map { $0.jsonRepresentation() }
        Task { @MainActor [weak self] in
            // 新序列已经接管时这一路让开, 否则同一份诊断写两遍。
            guard let self, !self.usesModernDiagnosticStream else { return }
            crashLog.notice("Received \(datas.count) diagnostic payloads")
            for data in datas {
                self.persistData(data)
            }
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
