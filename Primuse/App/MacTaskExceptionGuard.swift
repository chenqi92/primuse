#if os(macOS)
import AppKit
import Darwin
import OSLog
import PrimuseKit

private let taskExceptionLog = Logger(subsystem: "com.welape.yuanyin", category: "Crash")

/// 不让「从 Swift 并发 job 里逃出来的 Objective-C 异常」被 AppKit 悄悄吞掉。
///
/// AppKit 在主线程运行循环边界接住异常后只调 `reportException:` 记一笔日志，然后继续跑。
/// 普通事件处理里的异常这样处理无害；但异常要是从 `@MainActor` 的 Task 里抛出来的，展开会
/// 越过 `swift_job_run`，运行时来不及撤销线程局部的「当前执行器」登记（它在 job 返回后手动
/// `leave()`，没有展开清理）。那条登记从此指向已经销毁的栈帧，之后主线程上任何
/// `@MainActor` 闭包的隔离检查（`swift_task_isCurrentExecutor` → `isMainExecutor`）都会
/// 读到垃圾地址 —— 崩在和真正出错处毫无关系的地方，比如侧栏选中项 Binding 的 getter，
/// 报告里只剩 `???: 0x0`。
///
/// 这时进程已经坏了（抛异常的那个 Task 也永远不会继续），所以在捕获点立刻终止，把异常名、
/// 原因和抛出位置写进崩溃报告。没越过并发运行时的异常保持 AppKit 原来的行为。
///
/// 钩子本身不能带 `@MainActor` 隔离：隔离检查读的正是那条已经失效的登记。
enum MacTaskExceptionGuard {
    private static let installation: Void = installReportExceptionHook()

    /// 越早装越好；只装一次。
    static func install() {
        _ = installation
    }

    private typealias ReportExceptionIMP = @convention(c) (AnyObject, Selector, NSException) -> Void

    private static func installReportExceptionHook() {
        guard let runtimeImageBase = concurrencyRuntimeImageBase() else {
            taskExceptionLog.error("Task exception guard not installed: Swift concurrency runtime not found")
            return
        }
        let selector = #selector(NSApplication.reportException(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else {
            taskExceptionLog.error("Task exception guard not installed: reportException: not found")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: ReportExceptionIMP.self)
        let hook: @convention(block) (AnyObject, NSException) -> Void = { application, exception in
            let report = Self.escapedTaskReport(for: exception, runtimeImageBase: runtimeImageBase)
            original(application, selector, exception)
            guard let report else { return }
            taskExceptionLog.fault("\(report, privacy: .public)")
            // 崩溃报告拿不到的机器上，这份说明得自己走一条能被看见的路。
            MacLaunchDiagnostics.recordFatalReport(report)
            fatalError(report)
        }
        method_setImplementation(method, imp_implementationWithBlock(hook))
    }

    /// 异常越过了并发运行时就返回写进崩溃报告的说明，否则返回 nil。
    private static func escapedTaskReport(for exception: NSException, runtimeImageBase: UInt) -> String? {
        // 只有主线程的运行循环边界会吞异常。
        guard Thread.isMainThread else { return nil }
        let thrown = exception.callStackReturnAddresses.map(\.uintValue)
        let reporting = Thread.callStackReturnAddresses.map(\.uintValue)
        let unwound = ObjCExceptionUnwindPolicy.unwoundFrames(
            thrownReturnAddresses: thrown,
            reportingReturnAddresses: reporting
        )
        guard unwound.contains(where: { imageBase(containing: $0) == runtimeImageBase }) else {
            return nil
        }

        let reason = (exception.reason ?? "").prefix(600)
        var lines = [
            "Objective-C exception escaped a Swift concurrency job on the main thread; AppKit caught it and the executor record is now invalid.",
            "\(exception.name.rawValue): \(reason)",
            "Thrown at:",
        ]
        for (index, address) in unwound.prefix(40).enumerated() {
            lines.append("\(index) \(describeFrame(address))")
        }
        return lines.joined(separator: "\n")
    }

    private static func concurrencyRuntimeImageBase() -> UInt? {
        // RTLD_DEFAULT 是 ((void *)-2)，这个宏导入不到 Swift。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_job_run") else {
            return nil
        }
        return imageBase(containing: UInt(bitPattern: symbol))
    }

    private static func imageBase(containing address: UInt) -> UInt? {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address),
              dladdr(pointer, &info) != 0,
              let base = info.dli_fbase else { return nil }
        return UInt(bitPattern: base)
    }

    /// 「映像名 + 偏移」：配合崩溃报告里的映像加载地址或 dSYM 就能用 atos 还原。
    private static func describeFrame(_ address: UInt) -> String {
        var info = Dl_info()
        guard let pointer = UnsafeRawPointer(bitPattern: address),
              dladdr(pointer, &info) != 0,
              let base = info.dli_fbase,
              let path = info.dli_fname else {
            return "0x" + String(address, radix: 16)
        }
        let image = (String(cString: path) as NSString).lastPathComponent
        let offset = address - UInt(bitPattern: base)
        return "\(image) 0x\(String(address, radix: 16)) +0x\(String(offset, radix: 16))"
    }
}

/// 启动期崩在测试者手里时，系统崩溃报告躺在 `~/Library/Logs/DiagnosticReports`，
/// 对方不一定会导出，我们这边就只能靠猜。这里给每次启动立一个哨兵：正常活过
/// `healthyAfter` 秒或正常退出都会把它销掉，只有启动期崩溃会把它留在盘上。下次
/// 启动一进 AppKit 就把上次的情况摆到屏幕上，截图或拷贝即可回传。
///
/// `MacTaskExceptionGuard` 攒的那份异常说明本来只写进拿不到的崩溃报告，现在也
/// 顺着哨兵落盘，跟着同一个弹窗出来。
enum MacLaunchDiagnostics {
    /// 活过这么久就算启动成功 —— 主窗口在这之前早就上屏了。
    private static let healthyAfter: TimeInterval = 8
    private static let tick: TimeInterval = 2

    private struct Sentinel: Codable {
        var version: String
        var build: String
        var system: String
        var architecture: String
        var startedAt: Date
        var lastSeenAt: Date
        var exceptionReport: String?
    }

    @MainActor private static var heartbeat: Task<Void, Never>?

    /// AppKit 最早的时机调一次：先把上次的中止摆出来，再给这次启动立哨兵。
    @MainActor static func begin() {
        heartbeat?.cancel()
        let previous = loadSentinel()
        clearSentinel()
        if let previous {
            present(previous)
        }

        let now = Date()
        writeSentinel(Sentinel(
            version: bundleValue("CFBundleShortVersionString"),
            build: bundleValue("CFBundleVersion"),
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture,
            startedAt: now,
            lastSeenAt: now,
            exceptionReport: nil
        ))

        // 正常退出也要销哨兵，否则启动后立刻手动退出会被记成一次中止。
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            clearSentinel()
        }

        heartbeat = Task { @MainActor in
            var elapsed: TimeInterval = 0
            while elapsed < healthyAfter {
                try? await Task.sleep(for: .seconds(tick))
                if Task.isCancelled { return }
                elapsed += tick
                touchSentinel()
            }
            clearSentinel()
        }
    }

    /// 异常防护要终止进程前调：把说明并进哨兵，下次启动才有东西可报。
    nonisolated static func recordFatalReport(_ report: String) {
        guard var sentinel = loadSentinel() else { return }
        sentinel.exceptionReport = report
        sentinel.lastSeenAt = Date()
        writeSentinel(sentinel)
    }

    // MARK: 展示

    @MainActor private static func present(_ sentinel: Sentinel) {
        let details = summary(for: sentinel)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "mac_launch_aborted_title")
        alert.informativeText = String(localized: "mac_launch_aborted_hint") + "\n\n" + excerpt(of: details)
        alert.addButton(withTitle: String(localized: "mac_launch_copy_diagnostics"))
        alert.addButton(withTitle: String(localized: "close"))
        // 这时 app 还没走完启动，窗口不抢到前台就可能压在别的窗口下面。
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }

    /// 抛出栈有四十行，整段塞进弹窗会顶到屏幕外。窗里给梗概，完整的走剪贴板。
    private static func excerpt(of details: String) -> String {
        let lines = details.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 14 else { return details }
        return lines.prefix(14).joined(separator: "\n") + "\n…"
    }

    /// 正文一律英文：它要贴进 issue 或转给开发者，跟崩溃报告拼在一起看。
    private static func summary(for sentinel: Sentinel) -> String {
        let alive = max(0, sentinel.lastSeenAt.timeIntervalSince(sentinel.startedAt))
        var lines = [
            "Primuse \(sentinel.version) (\(sentinel.build))  \(sentinel.architecture)  \(sentinel.system)",
            "Launch aborted about \(String(format: "%.0f", alive))s after start.",
        ]
        if let report = sentinel.exceptionReport {
            lines.append("")
            lines.append(report)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 哨兵读写 —— 全程静默，诊断本身绝不能成为新的崩溃源

    private static var currentArchitecture: String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    private static func bundleValue(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "?"
    }

    private static var sentinelURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let directory = base.appendingPathComponent("Primuse/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("mac-launch.json", isDirectory: false)
    }

    private static func loadSentinel() -> Sentinel? {
        guard let url = sentinelURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Sentinel.self, from: data)
    }

    private static func writeSentinel(_ sentinel: Sentinel) {
        guard let url = sentinelURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sentinel) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @MainActor private static func touchSentinel() {
        guard var sentinel = loadSentinel() else { return }
        sentinel.lastSeenAt = Date()
        writeSentinel(sentinel)
    }

    private static func clearSentinel() {
        guard let url = sentinelURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
