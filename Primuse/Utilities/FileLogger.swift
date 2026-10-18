import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

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
    /// 诊断模式下主线程取栈门槛(毫秒),跟有效期一起存、一起清。
    static let diagnosticStackThresholdKey = "primuse.diagnosticLogging.stackMS"
    static let diagnosticStackThresholdEnvironmentKey = "PRIMUSE_DIAGNOSTIC_STACK_MS"

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
        // 取栈门槛和有效期一样存在 App 里:「一顿一顿」这种几十毫秒的短卡常常不是每次启动都有,
        // 开诊断时带上一次,之后从主屏幕直接打开也照样抓栈。新开一段诊断没带就回到默认。
        if resolution.isActive {
            if let raw = ProcessInfo.processInfo.environment[diagnosticStackThresholdEnvironmentKey],
               let requested = Double(raw), requested.isFinite, requested > 0 {
                defaults.set(requested, forKey: diagnosticStackThresholdKey)
            } else if case .enabled = resolution.change {
                defaults.removeObject(forKey: diagnosticStackThresholdKey)
            }
        } else {
            defaults.removeObject(forKey: diagnosticStackThresholdKey)
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
        var capacity = "files=\(limits.maxFileBytes / 1_000_000)MB×\(limits.rotatedGenerations + 1) "
            + "backlog=\(limits.backlogLimit)"
        #if DEBUG
        if let threshold = RuntimeDiagnosticsSampler.configuredStackThreshold {
            capacity += " stackMS=\(Int((threshold * 1000).rounded()))"
        }
        #endif
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
        guard (try? opened.seekToEnd()) != nil else {
            try? opened.close()
            return nil
        }
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

    func exportData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.flushPendingSummaries()
                continuation.resume(with: Result { try Data(contentsOf: self.fileURL) })
            }
        }
    }

    /// 日志末尾最多 `maxBytes` 字节,从整行开始。刚轮转过、当前文件不够长时从上一代
    /// (`.1`)的末尾补上,免得刚好在轮转后上传只剩几行。只读要用的那一段,不整份读进内存。
    func tailData(maxBytes: Int) async -> Data {
        await withCheckedContinuation { continuation in
            queue.async {
                self.flushPendingSummaries()
                let budget = max(0, maxBytes)
                let current = Self.readTail(of: self.fileURL, maxBytes: budget)
                var combined = current.data
                var truncated = current.truncated
                if !truncated, combined.count < budget {
                    let previous = Self.readTail(of: self.generationURL(1), maxBytes: budget - combined.count)
                    if !previous.data.isEmpty {
                        combined = previous.data + combined
                        truncated = previous.truncated
                    }
                }
                continuation.resume(returning: truncated
                    ? DiagnosticUpload.alignedToLineStart(combined)
                    : combined)
            }
        }
    }

    /// 文件最后 `maxBytes` 字节;`truncated` 表示开头切在了一行中间(前面还有没读的半行)。
    /// 多读前面一个字节来判断:它是换行就说明恰好切在行首,不用再丢一行。读不到当作空。
    private nonisolated static func readTail(of url: URL, maxBytes: Int) -> (data: Data, truncated: Bool) {
        guard maxBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), false) }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return (Data(), false) }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        let readFrom = start > 0 ? start - 1 : 0
        guard (try? handle.seek(toOffset: readFrom)) != nil else { return (Data(), false) }
        let data = (try? handle.readToEnd()) ?? Data()
        guard start > 0, let first = data.first else { return (data, false) }
        return (Data(data.dropFirst()), first != 0x0A)
    }

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
#if os(iOS)
/// 掉帧记录：1 秒级的主线程探测看不见滚动时几十毫秒的卡顿。显示链接每帧回调一次，
/// 两帧间隔超过预期的 1.5 倍且不短于 50ms 就算一次掉帧，当场记一行（每 10 秒最多
/// 20 行，免得刷屏），带上时间戳好和同一时刻的其它日志对上。只在诊断模式里跑。
@MainActor
final class FrameHitchMonitor: NSObject {
    static let shared = FrameHitchMonitor()

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var windowStart: CFTimeInterval = 0
    private var loggedInWindow = 0
    /// 开诊断时带了 `PRIMUSE_DIAGNOSTIC_STACK_MS`,掉帧也按同一个门槛记(最低 20ms,即 60Hz 下丢一帧),
    /// 看得出动画途中零星丢的那几帧;每 10 秒的行数上限跟着放宽。
    private static let minimumGap: CFTimeInterval = RuntimeDiagnosticsSampler.configuredStackThreshold
        .map { min(0.05, max(0.02, $0)) } ?? 0.05
    private static let maximumLinesPerWindow = RuntimeDiagnosticsSampler.configuredStackThreshold == nil ? 20 : 120

    /// 诊断模式开着时才在跑；别处据此决定要不要记帧率。
    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        NotificationCenter.default.addObserver(
            self, selector: #selector(resetTimestamp),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    /// 回到前台前的那段间隔是挂起，不是掉帧。
    @objc private func resetTimestamp() {
        lastTimestamp = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard let lastTimestamp, UIApplication.shared.applicationState == .active else { return }
        let gap = link.timestamp - lastTimestamp
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        guard gap >= Self.minimumGap, gap > expected * 1.5, gap < 5 else { return }
        RuntimeDiagnosticsSampler.shared.recordHitch(gap)
        if link.timestamp - windowStart >= 10 {
            windowStart = link.timestamp
            loggedInWindow = 0
        }
        guard loggedInWindow < Self.maximumLinesPerWindow else { return }
        loggedInWindow += 1
        plog(String(format: "🩺 frame hitch %.0fms", gap * 1000))
    }
}
#endif

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
    private var hitchCount = 0
    private var worstHitch: TimeInterval = 0
    private var reportedCounterCheck = false
    /// 主线程的 Mach 端口, 卡住时从采样队列上抓它的调用栈。
    private var mainThread: thread_t = 0
    /// 这一次卡顿已经抓了几份栈; 探针回来时清零。
    private var stallSamples = 0
    /// 一次卡顿最多抓这么多份栈, 每次探针间隔抓一份, 看得出它在同一处还是换了地方。
    private static let maximumStallSamples = 3
    /// 探针投出去超过这么久还没被执行, 就抓一份主线程栈。
    private static let stallSampleThreshold: TimeInterval = configuredStackThreshold ?? 0.25
    /// 开诊断时带 `PRIMUSE_DIAGNOSTIC_STACK_MS=<毫秒>` 把取栈门槛调低(最低 20ms)、探针按门槛的一半投,
    /// 看几十毫秒的短卡;这个值随诊断有效期存着(见 `FileLogger.resolveDiagnosticMode`)。
    /// 没设时保持 250ms,免得探针本身成了负担。
    static let configuredStackThreshold: TimeInterval? = {
        let milliseconds = UserDefaults.standard.double(forKey: FileLogger.diagnosticStackThresholdKey)
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        return max(0.02, milliseconds / 1000)
    }()

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

    func start(sampleInterval: TimeInterval = 10, probeInterval: TimeInterval = 0.25) {
        // 主线程的 Mach 端口由它自己报上来(Swift 里没有 pthread_main_thread_np);
        // 报上来之前探针照投, 只是还抓不了栈。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let port = pthread_mach_thread_np(pthread_self())
            self.queue.async { self.mainThread = port }
        }
        queue.async { [self] in
            guard sampleTimer == nil else { return }
            previous = Self.takeSample()

            let sample = DispatchSource.makeTimerSource(queue: queue)
            sample.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval, leeway: .seconds(1))
            sample.setEventHandler { [weak self] in self?.emitSample() }
            sample.resume()
            sampleTimer = sample

            let probe = DispatchSource.makeTimerSource(queue: queue)
            let interval = Self.configuredStackThreshold.map { $0 / 2 } ?? probeInterval
            let leeway = Self.configuredStackThreshold == nil ? 100 : max(1, Int(interval * 250))
            probe.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(leeway))
            probe.setEventHandler { [weak self] in self?.probeMainThread() }
            probe.resume()
            probeTimer = probe
        }
        #if os(iOS)
        Task { @MainActor in FrameHitchMonitor.shared.start() }
        #endif
    }

    /// 掉帧由主线程上的显示链接报过来，在采样行里汇总。
    func recordHitch(_ duration: TimeInterval) {
        queue.async { [self] in
            hitchCount += 1
            worstHitch = max(worstHitch, duration)
        }
    }

    // MARK: - 主线程延迟

    /// 往主线程投一个空任务, 看它隔多久才被执行。上一次还没被执行时不再投,
    /// 主线程卡住期间不会越积越多, 等它被执行时一次结算整段卡顿。
    private func probeMainThread() {
        if let sentAt = probeSentAt {
            sampleStalledMainThread(pendingFor: ProcessInfo.processInfo.systemUptime - sentAt)
            return
        }
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
        stallSamples = 0
        let latency = max(0, ranAt - sentAt)
        maxMainLatency = max(maxMainLatency, latency)
        guard latency >= 1 else { return }
        stallCount += 1
        plog(String(format: "🩺 main thread blocked for %.2fs", latency))
    }

    /// 探针还没回来、主线程已经停了一阵: 当场抓它的调用栈记一行, 卡顿过后才有
    /// 归属可查。一次卡顿最多抓 `maximumStallSamples` 份。
    private func sampleStalledMainThread(pendingFor pending: TimeInterval) {
        guard pending >= Self.stallSampleThreshold, stallSamples < Self.maximumStallSamples,
              mainThread != 0 else { return }
        stallSamples += 1
        let frames = MainThreadStackSampler.capture(thread: mainThread)
        guard !frames.isEmpty else { return }
        let text = frames.map(MainThreadStackSampler.describe).joined(separator: " < ")
        plog(String(format: "🩺 main thread busy %.0fms, stack: ", pending * 1000) + text)
    }

    // MARK: - 周期采样

    private func emitSample() {
        let current = Self.takeSample()
        defer {
            self.previous = current
            self.maxMainLatency = 0
            self.stallCount = 0
            self.hitchCount = 0
            self.worstHitch = 0
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
        if hitchCount > 0 {
            parts.append(String(format: "hitches=%d worstHitch=%.0fms", hitchCount, worstHitch * 1000))
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
    private static let procPidRusage: ProcPidRusage? = {
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

/// 从别的线程抓主线程的调用栈: 挂起它, 读寄存器, 顺着帧指针链把返回地址抄下来,
/// 再恢复。挂起期间不能分配内存、不能打日志(主线程可能正拿着 malloc 的锁),
/// 所以缓冲区先开好, 读栈用 `vm_read_overwrite` 而不是直接解引用, 符号化放在恢复之后。
/// 只支持 arm64(真机与 Apple 芯片的 Mac); 模拟器上返回空。
enum MainThreadStackSampler {
    static let maximumFrames = 32

    static func capture(thread: thread_t) -> [UInt] {
        #if arch(arm64)
        var frames = [UInt](repeating: 0, count: maximumFrames)
        var count = 0
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        frames.withUnsafeMutableBufferPointer { buffer in
            var state = arm_thread_state64_t()
            var stateCount = mach_msg_type_number_t(
                MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                    thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
                }
            }
            guard result == KERN_SUCCESS else { return }
            buffer[count] = UInt(state.__pc); count += 1
            if state.__lr != 0 { buffer[count] = UInt(state.__lr); count += 1 }
            var framePointer = state.__fp
            while count < buffer.count, framePointer != 0, framePointer % 16 == 0 {
                var saved: (UInt64, UInt64) = (0, 0)
                var read: vm_size_t = 0
                let status = withUnsafeMutablePointer(to: &saved) {
                    vm_read_overwrite(
                        mach_task_self_, vm_address_t(framePointer), 16,
                        vm_address_t(UInt(bitPattern: $0)), &read
                    )
                }
                guard status == KERN_SUCCESS, read == 16, saved.1 != 0 else { break }
                buffer[count] = UInt(saved.1); count += 1
                // 栈向低地址生长, 上一帧的帧指针必须更高; 否则链断了。
                guard saved.0 > framePointer else { break }
                framePointer = saved.0
            }
        }
        thread_resume(thread)
        return Array(frames.prefix(count))
        #else
        return []
        #endif
    }

    private typealias Demangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let demangle: Demangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangle.self)
    }()

    /// 「符号+偏移」; 没有符号(Release 包)时写「镜像名+偏移」, 拿 dSYM 用
    /// `atos -l 0x100000000` 加上这个偏移就能还原。
    static func describe(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        if let symbol = info.dli_sname, let start = info.dli_saddr {
            var name = String(cString: symbol)
            if name.hasPrefix("$s") || name.hasPrefix("_$s"),
               let demangle, let demangled = demangle(symbol, strlen(symbol), nil, nil, 0) {
                name = String(cString: demangled)
                free(demangled)
            }
            if name.count > 96 { name = String(name.prefix(96)) + "…" }
            return "\(name)+\(address - UInt(bitPattern: start))"
        }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let base = info.dli_fbase.map { UInt(bitPattern: $0) } ?? 0
        return String(format: "%@+0x%lx", image, base <= address ? address - base : address)
    }
}
