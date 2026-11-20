import Foundation

// 智能速度(REQ-174):有声内容里过长的停顿在进播放节点之前缩短,说话本身的速度和音调不变。
//
// 静音按 10 ms 一个窗口、所有声道的均方根判定。一段停顿开头留 `keptLeadingSilence`、说话前留
// `keptTrailingSilence`,中间超出的部分再按 `retainedRatio` 留一点(长停顿缩短后仍比短停顿长一些),
// 其余拿掉;能拿掉的不到 `minimumCut` 就整段不动。接缝在静音里,两边各做 `fadeDuration` 的淡出淡入。
//
// 拿掉的帧记成「接缝」(`SmartSpeedCut`):播放节点上的帧号加上它之前拿掉的帧数就是文件里的真实
// 位置,进度、锁屏、续播位置、字幕、章节和跳转都照文件时间走(`SmartSpeedTimeline`)。

/// 智能速度的判定参数。
public struct SmartSpeedPolicy: Sendable, Equatable {
    /// 一个窗口里各声道的均方根低于这个电平(dBFS)算静音。
    public var silenceThresholdDB: Double
    /// 判定窗口长度。
    public var windowDuration: TimeInterval
    /// 停顿开头保留的长度。
    public var keptLeadingSilence: TimeInterval
    /// 说话之前保留的长度(轻声起音不被切掉)。
    public var keptTrailingSilence: TimeInterval
    /// 一段停顿至少能省下这么多才动它。
    public var minimumCut: TimeInterval
    /// 超出两头保留部分的停顿再按这个比例留下。
    public var retainedRatio: Double
    /// 按比例多留的部分最多这么长。
    public var maximumRetainedExtra: TimeInterval
    /// 接缝两边的淡出、淡入长度。
    public var fadeDuration: TimeInterval

    public init(
        silenceThresholdDB: Double,
        windowDuration: TimeInterval,
        keptLeadingSilence: TimeInterval,
        keptTrailingSilence: TimeInterval,
        minimumCut: TimeInterval,
        retainedRatio: Double,
        maximumRetainedExtra: TimeInterval,
        fadeDuration: TimeInterval
    ) {
        self.silenceThresholdDB = silenceThresholdDB
        self.windowDuration = windowDuration
        self.keptLeadingSilence = keptLeadingSilence
        self.keptTrailingSilence = keptTrailingSilence
        self.minimumCut = minimumCut
        self.retainedRatio = retainedRatio
        self.maximumRetainedExtra = maximumRetainedExtra
        self.fadeDuration = fadeDuration
    }

    /// 默认:-42 dBFS 以下算静音,一段停顿最短剩约 0.35 秒,长停顿再按一成多留、最多多留 0.4 秒。
    public static let standard = SmartSpeedPolicy(
        silenceThresholdDB: -42,
        windowDuration: 0.01,
        keptLeadingSilence: 0.25,
        keptTrailingSilence: 0.1,
        minimumCut: 0.1,
        retainedRatio: 0.1,
        maximumRetainedExtra: 0.4,
        fadeDuration: 0.005
    )

    /// 换算到某个采样率下的帧数。
    public struct Frames: Sendable, Equatable {
        public let window: Int
        public let head: Int
        public let tail: Int
        public let minimumCut: Int
        public let maximumExtra: Int
        public let fade: Int
        public let retainedRatio: Double
        /// 静音判定用的均方值上限(线性幅度的平方)。
        public let thresholdMeanSquare: Double
    }

    public func frames(sampleRate: Double) -> Frames {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 44_100
        func count(_ seconds: TimeInterval) -> Int {
            guard seconds.isFinite, seconds > 0 else { return 0 }
            return Int((seconds * rate).rounded())
        }
        let window = max(1, count(windowDuration))
        let fade = max(1, count(fadeDuration))
        // 淡出落在开头保留的那段里、淡入落在说话前保留的那段里,两段都至少一个淡变长。
        let head = max(fade, count(keptLeadingSilence))
        let tail = max(fade, count(keptTrailingSilence))
        let ratio = retainedRatio.isFinite ? min(max(retainedRatio, 0), 0.9) : 0
        let amplitude = pow(10, (silenceThresholdDB.isFinite ? silenceThresholdDB : -42) / 20)
        return Frames(
            window: window,
            head: head,
            tail: tail,
            minimumCut: max(1, count(minimumCut)),
            maximumExtra: count(maximumRetainedExtra),
            fade: fade,
            retainedRatio: ratio,
            thresholdMeanSquare: amplitude * amplitude
        )
    }
}

/// 一处接缝:输出块里 `frameOffset` 这一帧之前拿掉了 `removedFrames` 帧。
/// `frameOffset` 总小于这一块的帧数 —— 接缝后面至少跟着一帧,和它在同一块里。
public struct SmartSpeedCut: Sendable, Equatable {
    public var frameOffset: Int
    public var removedFrames: Int

    public init(frameOffset: Int, removedFrames: Int) {
        self.frameOffset = frameOffset
        self.removedFrames = removedFrames
    }
}

/// 处理器交出的一块:各声道的样本(非交错)和这一块里的接缝。
public struct SmartSpeedChunk: Sendable, Equatable {
    public var channels: [[Float]]
    public var cuts: [SmartSpeedCut]

    public init(channels: [[Float]], cuts: [SmartSpeedCut]) {
        self.channels = channels
        self.cuts = cuts
    }

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var removedFrames: Int { cuts.reduce(0) { $0 + $1.removedFrames } }
}

/// 缩短停顿的流式处理器:一块一块喂进去,交出处理过的块;流结束时 `finish()` 交出还压着的部分。
///
/// 一段停顿里只有可能要淡出的那几帧和说话前要留的那段会压在手里(最多不到一秒),其余随到随交。
/// 只有接缝两侧那几毫秒的静音会被改动,说话的样本原样交出。
public struct SmartSpeedSilenceShortener: Sendable {
    public let channelCount: Int
    public let frames: SmartSpeedPolicy.Frames

    /// 还不够一个窗口、没判定的帧。
    private var pending: FrameQueue
    /// 当前这段停顿里压着没交的帧。
    private var held: FrameQueue
    /// 当前这段停顿已经有多长(帧)。
    private var runLength = 0
    /// 这段停顿已经决定要缩短。
    private var cutDecided = false
    /// 这段停顿已经拿掉的帧数。
    private var removedInRun = 0
    private var output: [[Float]]
    private var cuts: [SmartSpeedCut] = []

    /// 从开始到现在一共拿掉的帧数。
    public private(set) var totalRemovedFrames: Int64 = 0

    public init(policy: SmartSpeedPolicy = .standard, sampleRate: Double, channelCount: Int) {
        let channels = max(1, channelCount)
        self.channelCount = channels
        self.frames = policy.frames(sampleRate: sampleRate)
        pending = FrameQueue(channelCount: channels)
        held = FrameQueue(channelCount: channels)
        output = Array(repeating: [], count: channels)
    }

    /// 喂进一块(每个声道一个数组,长度相同),交出现在能交的部分。
    public mutating func process(_ input: [[Float]]) -> SmartSpeedChunk {
        let frameCount = input.map(\.count).min() ?? 0
        guard input.count == channelCount, frameCount > 0 else { return takeOutput() }
        pending.append(input, range: 0..<frameCount)
        consumeCompleteWindows()
        return takeOutput()
    }

    /// 和 `process(_:)` 一样,样本直接从调用方的声道指针里读,省一次拷贝。
    public mutating func process(
        channels: [UnsafeBufferPointer<Float>]
    ) -> SmartSpeedChunk {
        let frameCount = channels.map(\.count).min() ?? 0
        guard channels.count == channelCount, frameCount > 0 else { return takeOutput() }
        pending.append(channels, count: frameCount)
        consumeCompleteWindows()
        return takeOutput()
    }

    /// 流结束:不满一个窗口的尾巴照样判定,停顿里压着的部分全部交出。
    public mutating func finish() -> SmartSpeedChunk {
        if pending.count > 0 {
            consumeWindow(length: pending.count)
            pending.removeAll()
        }
        if runLength > 0 { endRun() }
        return takeOutput()
    }

    // MARK: - Windows

    private mutating func consumeCompleteWindows() {
        while pending.count >= frames.window {
            consumeWindow(length: frames.window)
        }
        pending.compact()
    }

    /// 判定队首 `length` 帧,交出或压下,然后把它们从队里拿走。
    private mutating func consumeWindow(length: Int) {
        let silent = pending.meanSquare(length: length).map { $0 < frames.thresholdMeanSquare } ?? false
        defer { pending.dropFirst(length) }
        guard silent else {
            if runLength > 0 { endRun() }
            pending.copyPrefix(length, into: &output)
            return
        }
        var offset = 0
        // 停顿开头那段直接交出;要淡出的最后几帧先压着,等知道会不会缩短。
        let direct = max(0, frames.head - frames.fade - runLength)
        if direct > 0 {
            let count = min(length, direct)
            pending.copy(from: 0, count: count, into: &output)
            offset = count
            runLength += count
        }
        if offset < length {
            held.append(pending, from: offset, count: length - offset)
            runLength += length - offset
        }
        trimHeldSilence()
    }

    /// 停顿超出开头保留的部分 `beyondHead` 帧时,说话前要留多少。
    private func keptFrames(beyondHead: Int) -> Int {
        guard beyondHead > frames.tail else { return beyondHead }
        let extra = min(frames.maximumExtra, Int(Double(beyondHead - frames.tail) * frames.retainedRatio))
        return frames.tail + extra
    }

    private mutating func trimHeldSilence() {
        let beyondHead = runLength - frames.head
        guard beyondHead > 0 else { return }
        let keep = keptFrames(beyondHead: beyondHead)
        if !cutDecided {
            guard beyondHead - keep >= frames.minimumCut else { return }
            cutDecided = true
            // 压着的最前面正是开头保留段的最后 `fade` 帧:淡出后交出。
            let fade = min(frames.fade, held.count)
            held.applyFade(from: 0, count: fade, fadingIn: false)
            held.copyPrefix(fade, into: &output)
            held.dropFirst(fade)
        }
        let drop = held.count - keep
        if drop > 0 {
            held.dropFirst(drop)
            removedInRun += drop
            totalRemovedFrames += Int64(drop)
        }
        held.compact()
    }

    /// 说话回来了(或流结束):压着的停顿交出,缩短过的就在这里记一处接缝、淡入。
    private mutating func endRun() {
        if cutDecided, held.count > 0 {
            cuts.append(SmartSpeedCut(frameOffset: output[0].count, removedFrames: removedInRun))
            held.applyFade(from: 0, count: min(frames.fade, held.count), fadingIn: true)
        } else if cutDecided, removedInRun > 0 {
            // 说话前留的那段至少有一个淡变长,走不到这里;万一走到,把接缝记在下一帧上。
            cuts.append(SmartSpeedCut(frameOffset: output[0].count, removedFrames: removedInRun))
        }
        held.copyPrefix(held.count, into: &output)
        held.removeAll()
        runLength = 0
        cutDecided = false
        removedInRun = 0
    }

    private mutating func takeOutput() -> SmartSpeedChunk {
        var produced = output
        var producedCuts = cuts
        // 接缝后面要跟着至少一帧;只剩一个落在块尾的接缝时(上面的保险分支),留到下一块。
        var carried: [SmartSpeedCut] = []
        let count = produced.first?.count ?? 0
        producedCuts.removeAll { cut in
            guard cut.frameOffset >= count else { return false }
            carried.append(SmartSpeedCut(frameOffset: 0, removedFrames: cut.removedFrames))
            return true
        }
        for index in output.indices { output[index].removeAll(keepingCapacity: true) }
        cuts = carried
        if count == 0 { produced = Array(repeating: [], count: channelCount) }
        return SmartSpeedChunk(channels: produced, cuts: producedCuts)
    }
}

/// 每个声道一条的帧队列,前面拿走的部分攒够了再整理,不每次挪动整段。
private struct FrameQueue: Sendable {
    private var storage: [[Float]]
    private var start = 0

    init(channelCount: Int) {
        storage = Array(repeating: [], count: channelCount)
    }

    var count: Int { (storage.first?.count ?? 0) - start }

    mutating func append(_ input: [[Float]], range: Range<Int>) {
        for channel in storage.indices {
            storage[channel].append(contentsOf: input[channel][range])
        }
    }

    mutating func append(_ input: [UnsafeBufferPointer<Float>], count: Int) {
        for channel in storage.indices {
            storage[channel].append(contentsOf: UnsafeBufferPointer(rebasing: input[channel][0..<count]))
        }
    }

    mutating func append(_ other: FrameQueue, from offset: Int, count: Int) {
        guard count > 0 else { return }
        let lower = other.start + offset
        for channel in storage.indices {
            storage[channel].append(contentsOf: other.storage[channel][lower..<(lower + count)])
        }
    }

    /// 队首 `length` 帧所有声道的均方值;有非有限值时为 nil(当作有声,不在坏数据上动刀)。
    func meanSquare(length: Int) -> Double? {
        guard length > 0 else { return nil }
        var sum = 0.0
        for channel in storage.indices {
            let samples = storage[channel]
            var index = start
            let end = start + length
            while index < end {
                let value = Double(samples[index])
                sum += value * value
                index += 1
            }
        }
        let mean = sum / Double(length * max(1, storage.count))
        return mean.isFinite ? mean : nil
    }

    func copyPrefix(_ length: Int, into output: inout [[Float]]) {
        copy(from: 0, count: length, into: &output)
    }

    func copy(from offset: Int, count: Int, into output: inout [[Float]]) {
        guard count > 0 else { return }
        let lower = start + offset
        for channel in storage.indices {
            output[channel].append(contentsOf: storage[channel][lower..<(lower + count)])
        }
    }

    /// 升余弦淡入或淡出,改的是队首 `offset` 起的 `count` 帧。
    mutating func applyFade(from offset: Int, count: Int, fadingIn: Bool) {
        guard count > 0 else { return }
        for step in 0..<count {
            let progress = Double(step + 1) / Double(count + 1)
            let rising = 0.5 - 0.5 * cos(Double.pi * progress)
            let gain = Float(fadingIn ? rising : 1 - rising)
            let index = start + offset + step
            for channel in storage.indices {
                storage[channel][index] *= gain
            }
        }
    }

    mutating func dropFirst(_ length: Int) {
        start = min(start + max(0, length), start + count)
    }

    mutating func removeAll() {
        for channel in storage.indices { storage[channel].removeAll(keepingCapacity: true) }
        start = 0
    }

    /// 前面空出来的超过一半时整理一次。
    mutating func compact() {
        guard start > 0 else { return }
        if count == 0 {
            removeAll()
        } else if start >= count {
            for channel in storage.indices { storage[channel].removeFirst(start) }
            start = 0
        }
    }
}

/// 一个播放节点上的接缝表:节点时间线上第几帧之前拿掉了多少帧。
///
/// 节点在第 n 帧时,文件里的位置是 n 加上它之前(含 n 处)所有接缝拿掉的帧数。无缝接续的下一首
/// 从时间线中途开始,只算它自己起点以后的接缝。
public struct SmartSpeedTimeline: Sendable, Equatable {
    private var frames: [Int64] = []
    /// 到这一处为止(含)一共拿掉的帧数,从时间线开头算起。
    private var cumulative: [Int64] = []
    /// 丢掉的那些接缝一共拿掉的帧数。
    private var discardedTotal: Int64 = 0

    public init() {}

    public var isEmpty: Bool { frames.isEmpty }
    public var count: Int { frames.count }

    /// 记一处接缝。节点帧号只增不减;同一帧上的接缝合并。
    public mutating func record(cutAt frame: Int64, removedFrames: Int64) {
        guard removedFrames > 0, frame >= 0 else { return }
        let total = (cumulative.last ?? 0) + removedFrames
        if let last = frames.last, frame <= last {
            // 不会倒着来;真倒着来时并到最后一处,累计量不丢。
            cumulative[cumulative.count - 1] = total
            return
        }
        frames.append(frame)
        cumulative.append(total)
    }

    /// `start ... end` 之间(两头都含)的接缝一共拿掉了多少帧。
    public func removedFrames(from start: Int64, through end: Int64) -> Int64 {
        guard !frames.isEmpty, end >= start else { return 0 }
        return removedFrames(through: end) - removedFrames(before: start)
    }

    /// 节点播到第 `playedFrame` 帧时,这一首从开头算已经播到文件里第几帧。
    /// `sampleTimeOffset` 是这一首在节点时间线上的零点(跳转后为负:零点之前那段没排进节点)。
    public func sourceFrames(playedFrame: Int64, sampleTimeOffset: Int64) -> Int64 {
        let lower = max(0, sampleTimeOffset)
        return playedFrame - sampleTimeOffset + removedFrames(from: lower, through: playedFrame)
    }

    /// 丢掉 `frame` 之前的接缝(它们属于已经过去的歌),表不会无限长。
    public mutating func discard(before frame: Int64) {
        let index = firstIndex(atOrAfter: frame)
        guard index > 0 else { return }
        discardedTotal = cumulative[index - 1]
        frames.removeFirst(index)
        cumulative.removeFirst(index)
    }

    public mutating func reset() {
        frames.removeAll()
        cumulative.removeAll()
        discardedTotal = 0
    }

    /// 到 `frame` 为止(含)从时间线开头算起一共拿掉的帧数。丢掉的部分之前的帧号不再准确,也不会再被问到。
    private func removedFrames(through frame: Int64) -> Int64 {
        let index = firstIndex(after: frame)
        return index > 0 ? cumulative[index - 1] : discardedTotal
    }

    private func removedFrames(before frame: Int64) -> Int64 {
        let index = firstIndex(atOrAfter: frame)
        return index > 0 ? cumulative[index - 1] : discardedTotal
    }

    private func firstIndex(atOrAfter frame: Int64) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid] < frame { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func firstIndex(after frame: Int64) -> Int {
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid] <= frame { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// 「已节省时间」的记账:每一拍读这一段播放到目前为止被拿掉的文件时长,只把新增的部分按当时的
/// 速度折成收听时间。跳转、换条目后这一段从零重新算,读数变小时只换基准、不倒扣。
public struct SmartSpeedSavingsMeter: Sendable, Equatable {
    private var lastSkipped: TimeInterval = 0

    /// 两拍之间新增超过这么多当作读数异常,不计。
    static let maximumDelta: TimeInterval = 600

    public init() {}

    /// 记一拍,返回这一拍新省下的收听时间(秒)。
    public mutating func record(skipped: TimeInterval, rate: Double) -> TimeInterval {
        guard skipped.isFinite, skipped >= 0 else { return 0 }
        defer { lastSkipped = skipped }
        let delta = skipped - lastSkipped
        guard delta > 0, delta <= Self.maximumDelta else { return 0 }
        let safeRate = rate.isFinite && rate > 0 ? rate : 1
        return delta / safeRate
    }

    public mutating func reset() {
        lastSkipped = 0
    }
}
