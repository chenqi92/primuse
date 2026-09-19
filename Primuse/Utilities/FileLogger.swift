import Foundation
import PrimuseKit

/// Thread-safe file logger that writes to the app's Caches directory.
/// The log file URL is exposed via `logFileURL` for sharing/diagnostics
/// (e.g. share sheet on iOS, "reveal in Finder" on macOS).
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    /// 单个文件多大轮转、保留几代、队列积压多少条。常规模式 10MB、保留一代
    /// (长会话里日志不会无上限增长, 又能留住最近一代历史); 开发脚本打开诊断
    /// 模式时放大, 见 `DiagnosticLoggingPolicy`。
    private let limits: DiagnosticLoggingPolicy.Limits
    /// 诊断模式生效到什么时候; nil 表示常规模式。
    let diagnosticLoggingExpiresAt: Date?

    private static let diagnosticExpiryKey = "primuse.diagnosticLogging.expiresAt"

    private let fileURL: URL
    private let directoryURL: URL
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
        directoryURL = docs
        let diagnosticMode = Self.resolveDiagnosticMode()
        diagnosticLoggingExpiresAt = diagnosticMode.expiresAt
        limits = DiagnosticLoggingPolicy.limits(isActive: diagnosticMode.isActive)

        // 以已有文件大小初始化计数器, 让进程内的轮转判断接着上次会话累计。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int {
            currentBytes = size
        }

        // Write session header
        let header = "\n\n========== SESSION START: \(Date()) ==========\n"
        appendToFile(header)
        if let note = Self.diagnosticModeNote(diagnosticMode, limits: limits) {
            appendToFile(formatEntry(note, source: Self.internalSource))
        }
        // 会话头写完后在队列上做一次收尾, 把跨会话残留的重复计数落到文件里。
        queue.async { [weak self] in
            self?.flushPendingSummaries()
            self?.removeStaleGenerations()
        }
        #if DEBUG
        if diagnosticMode.isActive {
            RuntimeDiagnosticsSampler.shared.start()
        }
        #endif
    }

    /// 诊断模式只在 Debug 构建里能打开; 开关变化会改写存下来的有效期。
    private static func resolveDiagnosticMode() -> DiagnosticLoggingPolicy.Resolution {
        #if DEBUG
        let defaults = UserDefaults.standard
        let resolution = DiagnosticLoggingPolicy.resolve(
            request: ProcessInfo.processInfo.environment[DiagnosticLoggingPolicy.environmentKey],
            storedExpiry: defaults.object(forKey: diagnosticExpiryKey) as? Date,
            now: Date()
        )
        switch resolution.change {
        case .enabled(let until):
            defaults.set(until, forKey: diagnosticExpiryKey)
        case .disabled, .expired:
            defaults.removeObject(forKey: diagnosticExpiryKey)
        case .unchanged:
            break
        }
        return resolution
        #else
        return DiagnosticLoggingPolicy.resolve(request: nil, storedExpiry: nil, now: Date())
        #endif
    }

    private static func diagnosticModeNote(
        _ resolution: DiagnosticLoggingPolicy.Resolution,
        limits: DiagnosticLoggingPolicy.Limits
    ) -> String? {
        let capacity = "files=\(limits.maxFileBytes / 1_000_000)MB×\(limits.rotatedGenerations + 1) "
            + "backlog=\(limits.backlogLimit)"
        switch resolution.change {
        case .enabled(let until):
            return "🩺 Diagnostic logging ON until \(until) \(capacity)"
        case .unchanged:
            guard let until = resolution.expiresAt else { return nil }
            return "🩺 Diagnostic logging still ON until \(until) \(capacity)"
        case .disabled:
            return "🩺 Diagnostic logging turned OFF"
        case .expired:
            return "🩺 Diagnostic logging window expired; back to standard logging"
        }
    }

    /// `.k` 代日志文件的位置, k 从 1 开始。
    private func generationURL(_ generation: Int) -> URL {
        directoryURL.appendingPathComponent("primuse_debug.log.\(generation)")
    }

    /// 诊断模式结束后多出来的旧代(`.2` 起)留 72 小时给开发脚本拉取, 之后清掉。
    /// 只在 `queue` 上调用。
    private func removeStaleGenerations() {
        let keep = limits.rotatedGenerations
        let maximum = DiagnosticLoggingPolicy.diagnosticLimits.rotatedGenerations
        guard maximum > keep else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(DiagnosticLoggingPolicy.maximumHours) * 3600)
        let fm = FileManager.default
        for generation in (keep + 1)...maximum {
            let url = generationURL(generation)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: url)
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
        guard LogBacklogPolicy.admits(pendingCount: pendingCount, limit: limits.backlogLimit) else {
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
        if currentBytes >= limits.maxFileBytes {
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

    /// 轮转: 丢掉最老一代, 其余依次往后挪一代, 当前文件变成 `.1`, 计数器清零。
    /// 下次写入会新建文件。常驻句柄必须先关闭, 否则改名后还会继续写进旧文件。
    private func rotate() {
        closeHandle()
        let fm = FileManager.default
        try? fm.removeItem(at: generationURL(limits.rotatedGenerations))
        for move in DiagnosticLoggingPolicy.rotationMoves(generations: limits.rotatedGenerations) {
            let source = move.from == 0 ? fileURL : generationURL(move.from)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.moveItem(at: source, to: generationURL(move.to))
        }
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

#if DEBUG
/// 诊断日志模式下的运行状态采样, 只在 Debug 构建里存在。
///
/// 每 10 秒一行 `🩺`: CPU、线程数、内存占用、磁盘读写增量、唤醒次数、主线程最长延迟
/// 与发热等级; CPU 偏高时附上最忙的几个线程。主线程被占住 1 秒以上时当场记一行。
/// 这些都是界面上看不出来、却会耗电、发热、写盘或卡顿的东西。
final class RuntimeDiagnosticsSampler: @unchecked Sendable {
    static let shared = RuntimeDiagnosticsSampler()

    private let queue = DispatchQueue(label: "com.primuse.diagnostics.sampler", qos: .utility)

    // 以下状态只在 `queue` 上读写。
    private var sampleTimer: DispatchSourceTimer?
    private var probeTimer: DispatchSourceTimer?
    private var previous: Sample?
    private var probeSentAt: TimeInterval?
    private var maxMainLatency: TimeInterval = 0
    private var stallCount = 0
    private var reportedCounterCheck = false

    private struct Sample {
        var uptime: TimeInterval
        var cpuSeconds: TimeInterval
        var io: IOCounters?
    }

    private struct IOCounters {
        var bytesRead: UInt64
        var bytesWritten: UInt64
        var wakeups: UInt64
        var footprint: UInt64
    }

    func start(sampleInterval: TimeInterval = 10, probeInterval: TimeInterval = 0.5) {
        queue.async { [self] in
            guard sampleTimer == nil else { return }
            previous = Self.takeSample()

            let sample = DispatchSource.makeTimerSource(queue: queue)
            sample.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval, leeway: .seconds(1))
            sample.setEventHandler { [weak self] in self?.emitSample() }
            sample.resume()
            sampleTimer = sample

            let probe = DispatchSource.makeTimerSource(queue: queue)
            probe.schedule(deadline: .now() + probeInterval, repeating: probeInterval, leeway: .milliseconds(100))
            probe.setEventHandler { [weak self] in self?.probeMainThread() }
            probe.resume()
            probeTimer = probe
        }
    }

    // MARK: - 主线程延迟

    /// 往主线程投一个空任务, 看它隔多久才被执行。上一次还没被执行时不再投,
    /// 主线程卡住期间不会越积越多, 等它被执行时一次结算整段卡顿。
    private func probeMainThread() {
        guard probeSentAt == nil else { return }
        probeSentAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            let ranAt = ProcessInfo.processInfo.systemUptime
            guard let self else { return }
            self.queue.async { self.finishProbe(ranAt: ranAt) }
        }
    }

    private func finishProbe(ranAt: TimeInterval) {
        guard let sentAt = probeSentAt else { return }
        probeSentAt = nil
        let latency = max(0, ranAt - sentAt)
        maxMainLatency = max(maxMainLatency, latency)
        guard latency >= 1 else { return }
        stallCount += 1
        plog(String(format: "🩺 main thread blocked for %.2fs", latency))
    }

    // MARK: - 周期采样

    private func emitSample() {
        let current = Self.takeSample()
        defer {
            self.previous = current
            self.maxMainLatency = 0
            self.stallCount = 0
        }
        guard let previous = self.previous else { return }
        let wall = current.uptime - previous.uptime
        guard wall > 0 else { return }

        let cpuPercent = max(0, current.cpuSeconds - previous.cpuSeconds) / wall * 100
        let threads = Self.threadActivity(topCount: cpuPercent >= 50 ? 3 : 0)
        var parts = [String(format: "cpu=%.0f%%", cpuPercent), "threads=\(threads.count)"]

        if let footprint = Self.memoryFootprint() {
            parts.append("footprint=\(Self.megabytes(footprint))")
            if !reportedCounterCheck, let io = current.io {
                reportedCounterCheck = true
                // 核对按下标读取 rusage_info_v2 的布局是否正确: 这两个数应当接近。
                plog("🩺 counter check footprint=\(Self.megabytes(footprint)) rusage=\(Self.megabytes(io.footprint))")
            }
        }
        if let io = current.io, let before = previous.io,
           io.bytesWritten >= before.bytesWritten,
           io.bytesRead >= before.bytesRead,
           io.wakeups >= before.wakeups {
            parts.append("diskW=+\(Self.megabytes(io.bytesWritten - before.bytesWritten))")
            parts.append("diskR=+\(Self.megabytes(io.bytesRead - before.bytesRead))")
            parts.append(String(format: "wakeups=%.0f/s", Double(io.wakeups - before.wakeups) / wall))
            parts.append("diskWTotal=\(Self.megabytes(io.bytesWritten))")
        }
        parts.append(String(format: "mainMax=%.0fms", maxMainLatency * 1000))
        if stallCount > 0 {
            parts.append("stalls=\(stallCount)")
        }
        if let sentAt = probeSentAt, current.uptime - sentAt >= 1 {
            parts.append(String(format: "mainBlockedNow=%.1fs", current.uptime - sentAt))
        }
        parts.append("thermal=\(Self.thermalName(ProcessInfo.processInfo.thermalState))")
        #if os(iOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            parts.append("lowPower")
        }
        #endif
        if !threads.top.isEmpty {
            parts.append("top=[\(threads.top.joined(separator: ", "))]")
        }
        plog("🩺 " + parts.joined(separator: " "))
    }

    private static func takeSample() -> Sample {
        var usage = rusage()
        var cpuSeconds: TimeInterval = 0
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        return Sample(uptime: ProcessInfo.processInfo.systemUptime, cpuSeconds: cpuSeconds, io: ioCounters())
    }

    // MARK: - 磁盘读写与唤醒

    private typealias ProcPidRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32

    /// `proc_pid_rusage` 不在 iOS 的公开头文件里, 只在 Debug 构建里按符号名查找。
    nonisolated(unsafe) private static let procPidRusage: ProcPidRusage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "proc_pid_rusage") else { return nil }
        return unsafeBitCast(symbol, to: ProcPidRusage.self)
    }()

    /// 按 `rusage_info_v2`(flavor 2)的布局取值: 16 字节 uuid 之后是 18 个 UInt64,
    /// 其中空闲唤醒、中断唤醒、phys_footprint、读字节、写字节分别是第 2、3、7、16、17 个。
    /// 第一次采样会把这里的 footprint 与 task_info 的对照着记一行, 用来核对布局。
    private static func ioCounters() -> IOCounters? {
        guard let procPidRusage else { return nil }
        var buffer = [UInt64](repeating: 0, count: 20)
        let status = buffer.withUnsafeMutableBytes { procPidRusage(getpid(), 2, $0.baseAddress) }
        guard status == 0 else { return nil }
        return IOCounters(
            bytesRead: buffer[18],
            bytesWritten: buffer[19],
            wakeups: buffer[4] &+ buffer[5],
            footprint: buffer[9]
        )
    }

    // MARK: - 线程与内存

    /// 线程总数; `topCount > 0` 时再列出最忙的几个(名字 + 占用)。
    private static func threadActivity(topCount: Int) -> (count: Int, top: [String]) {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return (0, []) }
        defer {
            for index in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            )
        }
        guard topCount > 0 else { return (Int(threadCount), []) }

        var busy: [(usage: Double, name: String)] = []
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let usage = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            guard usage >= 1 else { continue }
            busy.append((usage, threadName(threads[index], index: index)))
        }
        let top = busy
            .sorted { $0.usage > $1.usage }
            .prefix(topCount)
            .map { "\($0.name) \(Int($0.usage.rounded()))%" }
        return (Int(threadCount), Array(top))
    }

    /// 有名字的线程(主线程、各个组件自己起的线程)用名字; GCD 工作线程通常没有名字,
    /// 用序号区分, 配合同一时段前后的日志判断是谁。
    private static func threadName(_ thread: thread_act_t, index: Int) -> String {
        if let pthread = pthread_from_mach_thread_np(thread) {
            var buffer = [CChar](repeating: 0, count: 64)
            if pthread_getname_np(pthread, &buffer, buffer.count) == 0, buffer[0] != 0 {
                return String(cString: buffer)
            }
        }
        return "thread#\(index)"
    }

    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
#endif
