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
#endif
