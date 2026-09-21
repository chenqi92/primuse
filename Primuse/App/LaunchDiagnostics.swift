#if os(iOS)
import Foundation
import PrimuseKit
import SwiftUI
import UIKit

/// 启动哨兵。每次启动在盘上立一份记录，活过 `healthyAfter` 秒才销掉，所以留在
/// 盘上的只会是**没跑完的那次启动**；下次启动把它读出来报给用户。
///
/// 为什么需要它：被系统按内存上限回收、watchdog 终止、非正常退出这几种"闪退"
/// **不产生崩溃报告**，Xcode Organizer 的 Crashes 里一条都没有，测试者又够不着
/// app 里的诊断页——除了猜就只剩这条路。哨兵里记的是阶段轨迹、每一步的时刻、
/// 最后一次看到的内存占用和剩余空间，足够把"死在界面上"和"死在启动链上"分开。
///
/// 连续中止两次就锁定安全模式：下次启动跳过首页与延后启动链，让人至少打得开、
/// 读得到、发得出去。Mac 端的同类实现是 `MacLaunchDiagnostics`。
@MainActor
enum LaunchDiagnostics {
    /// 活过这么久就算启动成功。首页在这之前早就上屏了，这次反馈里的闪退也发生在
    /// 主界面出现后一秒。
    private static let healthyAfter: TimeInterval = 8
    private static let tick: TimeInterval = 2
    /// 连着中止几次就进安全模式。一次可能是用户自己划掉的，两次才算模式。
    private static let safeModeThreshold = 2

    private static let abortCountKey = "primuse.launch.consecutiveAborts"
    private static let safeModeLatchKey = "primuse.launch.safeModeLatched"

    enum Stage: String, Codable, Sendable {
        /// `didFinishLaunching` 刚进来。
        case launching
        /// 资料库还在准备，屏幕上是占位页。
        case preparingLibrary
        /// 主界面首帧已上屏。
        case homeFirstFrame
        /// 延后启动链开工（对账、剪枝、iCloud、后台扫描）。
        case deferredStartup
        /// 上次播放会话恢复完成，迷你播放条随之插入。
        case playbackRestored
        /// 活过 `healthyAfter`，这次启动算成功。
        case settled
    }

    private struct Step: Codable {
        var stage: String
        var at: Date
    }

    private struct Sentinel: Codable {
        var version: String
        var build: String
        var system: String
        var device: String
        var startedAt: Date
        var lastSeenAt: Date
        var steps: [Step]
        var freeDiskBytes: Int64
        var footprintBytes: UInt64?
        var safeMode: Bool
    }

    /// 上一次启动没跑完时的回执，给界面展示与复制。
    struct AbortReport: Identifiable, Sendable {
        let id = UUID()
        /// 一律英文：它要贴进 issue 或转给开发者，跟崩溃报告拼在一起看。
        let details: String
        let consecutiveAborts: Int
    }

    /// 这次启动该怎么走。抽成纯函数是因为它最容易悄悄写错：门槛差一次就永远
    /// 进不去安全模式，锁定解错就再也出不来，而这两种错都只在测试者手上才看得见。
    struct Decision: Equatable, Sendable {
        /// 写回 `abortCountKey` 的新计数。
        var consecutiveAborts: Int
        /// 写回 `safeModeLatchKey`。一旦锁上就不会在这里被解开。
        var latchSafeMode: Bool
        /// 这次启动是否走安全模式。
        var safeModeActive: Bool
    }

    static func decide(
        previousLaunchAborted: Bool,
        storedAborts: Int,
        latched: Bool,
        threshold: Int = safeModeThreshold
    ) -> Decision {
        let aborts = previousLaunchAborted ? max(0, storedAborts) + 1 : max(0, storedAborts)
        // 锁定只增不减：解锁是用户在安全模式里点「恢复正常启动」的事。否则会变成
        // "安全模式活下来 → 计数清零 → 下次又正常启动 → 又崩"的来回震荡。
        let latch = latched || (previousLaunchAborted && aborts >= threshold)
        return Decision(consecutiveAborts: aborts, latchSafeMode: latch, safeModeActive: latch)
    }

    private(set) static var previousAbort: AbortReport?
    /// 这次启动是否处于安全模式。首页、延后启动链都看它。
    private(set) static var isSafeModeActive = false

    private static var heartbeat: Task<Void, Never>?
    private static var observers: [NSObjectProtocol] = []

    // MARK: - 生命周期

    /// `didFinishLaunching` 的第一件事。要早于任何可能崩的东西，否则这次启动
    /// 自己就报不出来了。
    static func begin() {
        heartbeat?.cancel()
        let defaults = UserDefaults.standard
        let previous = loadSentinel()
        clearSentinel()

        let decision = decide(
            previousLaunchAborted: previous != nil,
            storedAborts: defaults.integer(forKey: abortCountKey),
            latched: defaults.bool(forKey: safeModeLatchKey)
        )
        defaults.set(decision.consecutiveAborts, forKey: abortCountKey)
        defaults.set(decision.latchSafeMode, forKey: safeModeLatchKey)
        isSafeModeActive = decision.safeModeActive
        if let previous {
            previousAbort = AbortReport(
                details: summary(for: previous, consecutiveAborts: decision.consecutiveAborts),
                consecutiveAborts: decision.consecutiveAborts
            )
        }

        let now = Date()
        write(Sentinel(
            version: bundleValue("CFBundleShortVersionString"),
            build: bundleValue("CFBundleVersion"),
            system: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            device: deviceModelIdentifier,
            startedAt: now,
            lastSeenAt: now,
            steps: [Step(stage: Stage.launching.rawValue, at: now)],
            freeDiskBytes: freeDiskBytes(),
            footprintBytes: memoryFootprintBytes(),
            safeMode: isSafeModeActive
        ))

        if previousAbort != nil {
            exportDiagnosticsForRetrieval()
        }

        let center = NotificationCenter.default
        // 用户自己划掉 app，或者退到后台之后被系统正常回收，都不算启动中止。
        for name in [
            UIApplication.willTerminateNotification,
            UIApplication.didEnterBackgroundNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in settle() }
            })
        }

        heartbeat = Task { @MainActor in
            var elapsed: TimeInterval = 0
            while elapsed < healthyAfter {
                try? await Task.sleep(for: .seconds(tick))
                if Task.isCancelled { return }
                elapsed += tick
                touch()
            }
            mark(.settled)
            settle()
        }
    }

    /// 里程碑。落盘是同步的：异步写在进程被回收时正好丢的就是最后一行。
    static func mark(_ stage: Stage) {
        guard var sentinel = loadSentinel() else { return }
        guard sentinel.steps.last?.stage != stage.rawValue else { return }
        let now = Date()
        sentinel.steps.append(Step(stage: stage.rawValue, at: now))
        sentinel.lastSeenAt = now
        sentinel.footprintBytes = memoryFootprintBytes()
        write(sentinel)
    }

    /// 这次启动算成功：销哨兵、清连续中止计数。安全模式的锁定**不在这里解**。
    private static func settle() {
        heartbeat?.cancel()
        heartbeat = nil
        clearSentinel()
        UserDefaults.standard.set(0, forKey: abortCountKey)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 用户在安全模式里点「恢复正常启动」。
    static func exitSafeMode() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: safeModeLatchKey)
        defaults.set(0, forKey: abortCountKey)
        isSafeModeActive = false
    }

    static func dismissPreviousAbort() {
        previousAbort = nil
    }

    // MARK: - 回执正文

    private static func summary(for sentinel: Sentinel, consecutiveAborts: Int) -> String {
        let alive = max(0, sentinel.lastSeenAt.timeIntervalSince(sentinel.startedAt))
        var lines = [
            "Primuse \(sentinel.version) (\(sentinel.build))  \(sentinel.device)  \(sentinel.system)",
            "Launch aborted about \(String(format: "%.1f", alive))s after start"
                + (sentinel.safeMode ? " (safe mode)." : ".")
                + " Consecutive: \(consecutiveAborts).",
            "Last stage: \(sentinel.steps.last?.stage ?? "?")",
        ]
        if let footprint = sentinel.footprintBytes {
            lines.append("Memory footprint at last heartbeat: \(megabytes(footprint)).")
        }
        lines.append("Free disk at launch: \(megabytes(UInt64(max(0, sentinel.freeDiskBytes)))).")
        lines.append("")
        lines.append("Stage trail:")
        for step in sentinel.steps {
            let offset = step.at.timeIntervalSince(sentinel.startedAt)
            lines.append(String(format: "  +%6.2fs  %@", offset, step.stage))
        }
        return lines.joined(separator: "\n")
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - 取证：拷到「文件」App 看得见的地方

    /// 崩在启动上的人进不了设置里的诊断页，但 `UIFileSharingEnabled` 让
    /// Documents 在「文件」App 里直接可见。上次启动中止时就把证据搬过去一份，
    /// 他不用打开 app 就能发出来。
    ///
    /// 日志整份可能有几十兆（诊断模式下更大），只搬尾巴。
    static var retrievalDirectoryName: String { "Diagnostics" }
    static let logTailBytes = 2 * 1_024 * 1_024
    static let exportedReportLimit = 8

    private static func exportDiagnosticsForRetrieval() {
        let summary = previousAbort?.details
        let logURL = FileLogger.shared.logFileURL
        // 不走 `AppServices.shared`：那会在 `didFinishLaunching` 里把整张服务图
        // 提前构造出来，正好是这时候最不该做的事。目录自己算。
        let reports = diagnosticReportURLs(limit: exportedReportLimit)
        Task.detached(priority: .utility) {
            guard let directory = retrievalDirectory() else { return }
            if let summary {
                try? Data(summary.utf8).write(
                    to: directory.appendingPathComponent("last-launch-abort.txt"),
                    options: .atomic
                )
            }
            if let tail = tail(of: logURL, bytes: logTailBytes) {
                try? tail.write(
                    to: directory.appendingPathComponent("primuse_debug_tail.log"),
                    options: .atomic
                )
            }
            for url in reports {
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: url, to: destination)
            }
        }
    }

    /// MetricKit 的报告落在 App Group 容器里，`CrashDiagnosticsService` 写、
    /// 设置页读。这里只按修改时间取最新的几份。
    private nonisolated static func diagnosticReportURLs(limit: Int) -> [URL] {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return [] }
        let directory = container.appendingPathComponent(
            CrashDiagnosticsService.directoryName,
            isDirectory: true
        )
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return Array(
            urls
                .filter { $0.pathExtension == "json" }
                .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
                .prefix(limit)
        )
    }

    private nonisolated static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    nonisolated static func retrievalDirectory() -> URL? {
        let documents = FileManager.default.primuseDirectoryURL(for: .documentDirectory)
        let directory = documents.appendingPathComponent(retrievalDirectoryName, isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else { return nil }
        return directory
    }

    private nonisolated static func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    // MARK: - 环境

    private nonisolated static func bundleValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "?"
    }

    /// `iPhone17,1` 这种标识符。市场名对不上代次，排查时反而不如它。
    private nonisolated static var deviceModelIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.machine)) {
                String(cString: $0)
            }
        }
        return identifier.isEmpty ? "?" : identifier
    }

    private nonisolated static func freeDiskBytes() -> Int64 {
        let path = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory).path
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let value = attributes[.systemFreeSize] as? NSNumber else { return 0 }
        return value.int64Value
    }

    /// 与 `FileLogger` 的诊断采样同一份实现，区别是这份在 Release 里也在。
    private nonisolated static func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    // MARK: - 哨兵读写 —— 全程静默，诊断本身绝不能成为新的崩溃源

    private nonisolated static var sentinelURL: URL? {
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        let directory = base.appendingPathComponent("Primuse/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ios-launch.json", isDirectory: false)
    }

    private nonisolated static func loadSentinel() -> Sentinel? {
        guard let url = sentinelURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Sentinel.self, from: data)
    }

    private nonisolated static func write(_ sentinel: Sentinel) {
        guard let url = sentinelURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sentinel) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func touch() {
        guard var sentinel = loadSentinel() else { return }
        sentinel.lastSeenAt = Date()
        sentinel.footprintBytes = memoryFootprintBytes()
        write(sentinel)
    }

    private nonisolated static func clearSentinel() {
        guard let url = sentinelURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 安全模式与回执界面

/// 连续启动失败之后的落地页。这一支不碰首页、迷你播放条、入场动画与整库派生
/// 数据 —— 目的只有一个: 让打不开 app 的人打得开, 把回执读出来、发出去。
struct LaunchSafeModeView: View {
    @State private var restored = false

    private var details: String { LaunchDiagnostics.previousAbort?.details ?? "" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(String(localized: "safe_mode_title"), systemImage: "lifepreserver")
                            .font(.headline)
                        Text(String(localized: "safe_mode_hint"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(localized: "safe_mode_skipped"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                if !details.isEmpty {
                    Section {
                        Text(details)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } header: {
                        Text(String(localized: "launch_aborted_title"))
                    } footer: {
                        Text(String(localized: "launch_diagnostics_files_hint"))
                    }
                }

                Section {
                    if !details.isEmpty {
                        ShareLink(item: details) {
                            Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = details
                        } label: {
                            Label(
                                String(localized: "launch_diagnostics_copy"),
                                systemImage: "doc.on.doc"
                            )
                        }
                    }
                    NavigationLink {
                        DiagnosticReportsView(service: AppServices.shared.crashDiagnostics)
                    } label: {
                        Label(String(localized: "diagnostics_title"), systemImage: "stethoscope")
                    }
                }

                Section {
                    Button {
                        LaunchDiagnostics.exitSafeMode()
                        restored = true
                    } label: {
                        Label(
                            String(localized: "safe_mode_exit"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(restored)
                } footer: {
                    Text(String(localized: "safe_mode_exit_hint"))
                }
            }
            .navigationTitle(String(localized: "safe_mode_title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 只中止过一次(还没到安全模式门槛)时的回执。挂在资料库占位页那一层, 它要显示
/// 十秒, 比等首页出来再弹稳妥 —— 首页正是出事的地方。
private struct LaunchAbortReportModifier: ViewModifier {
    @State private var report: LaunchDiagnostics.AbortReport?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !LaunchDiagnostics.isSafeModeActive else { return }
                report = LaunchDiagnostics.previousAbort
            }
            .alert(
                String(localized: "launch_aborted_title"),
                isPresented: Binding(
                    get: { report != nil },
                    set: { if !$0 { dismiss() } }
                ),
                presenting: report
            ) { presented in
                Button(String(localized: "launch_diagnostics_copy")) {
                    UIPasteboard.general.string = presented.details
                    dismiss()
                }
                Button(String(localized: "close"), role: .cancel) { dismiss() }
            } message: { presented in
                Text(String(localized: "launch_aborted_hint") + "\n\n" + presented.details)
            }
    }

    private func dismiss() {
        report = nil
        LaunchDiagnostics.dismissPreviousAbort()
    }
}

extension View {
    func launchAbortReport() -> some View {
        modifier(LaunchAbortReportModifier())
    }
}
#endif
