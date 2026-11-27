import Foundation

/// 解码 PCM 缓冲区的合并策略。
///
/// 原生解码器一次交出 8192 帧, 每秒只有约 5 个缓冲区流向播放泵; 而 FFmpeg
/// 路径按解码帧逐个交出, DTS 一帧只有 512 个样本 (48 kHz 下约 10.7 ms),
/// 每秒就是约 94 个缓冲区, AAC 的 1024 帧包同理。每个缓冲区都要在主 actor
/// 上排若干个任务, 于是只有播放 DTS 时列表滚动才会卡顿。把解码结果先攒成
/// 原生大小再交给播放泵, 就能把这个频率拉回同一量级。
public struct PCMBufferCoalescingPolicy: Sendable {
    /// 稳定阶段的目标帧数, 与原生解码器的缓冲区大小一致。
    public static let targetFrameCount = 8192
    /// 首次 flush 的帧数。开头攒得少, 起播延迟才和现在一样。
    public static let firstFlushFrameCount = 1024

    public let targetFrameCount: Int
    public let firstFlushFrameCount: Int

    public init(
        targetFrameCount: Int = PCMBufferCoalescingPolicy.targetFrameCount,
        firstFlushFrameCount: Int = PCMBufferCoalescingPolicy.firstFlushFrameCount
    ) {
        self.targetFrameCount = max(1, targetFrameCount)
        self.firstFlushFrameCount = max(1, firstFlushFrameCount)
    }
}

/// 一次输入之后应该做什么。调用方只按动作搬数据, 不再自己判断阈值。
public enum PCMBufferCoalescingAction: Sendable, Equatable {
    /// 追加到累积区, 暂不交出。
    case buffer
    /// 追加到累积区, 然后把累积区整体交出 (达到阈值)。
    case appendThenFlush
    /// 格式变了而且还有未交出的帧: 先把累积区交出, 再开始累积这一份输入。
    case flushThenBuffer
    /// 累积区为空且这一份输入本身已达阈值: 直接原样交出, 不做任何拷贝。
    case passThrough
}

/// 纯状态机形式的累积器。只记帧数, 不碰任何音频缓冲区类型, 便于单测。
///
/// 阈值规则: 首次 flush 之前用 `firstFlushFrameCount`, 之后用
/// `targetFrameCount`; 当 `accumulated + incoming >= threshold` 时 flush。
/// 由此可知累积帧数永远不会超过 `targetFrameCount + incoming` ——
/// 追加之前累积区必然小于阈值 (否则上一次就已经 flush 了), 阈值最大就是
/// `targetFrameCount`, 所以单个缓冲区的峰值容量是目标帧数加一份输入。
public struct PCMBufferCoalescingPlan: Sendable {
    public let policy: PCMBufferCoalescingPolicy
    /// 当前累积区里的帧数。
    public private(set) var accumulatedFrames: Int
    /// 是否已经 flush 过一次 (决定用哪个阈值)。
    public private(set) var hasFlushedOnce: Bool
    /// 当前累积区的格式标识, 累积区为空时可能仍保留上一次的值。
    public private(set) var formatKey: String?

    public init(policy: PCMBufferCoalescingPolicy = PCMBufferCoalescingPolicy()) {
        self.policy = policy
        accumulatedFrames = 0
        hasFlushedOnce = false
        formatKey = nil
    }

    /// 当前生效的 flush 阈值。
    public var flushThreshold: Int {
        hasFlushedOnce ? policy.targetFrameCount : policy.firstFlushFrameCount
    }

    /// 吸收一份输入, 返回调用方要执行的动作。
    /// - Parameters:
    ///   - incomingFrames: 这一份输入的帧数, 0 帧直接忽略。
    ///   - formatKey: 这一份输入的格式标识, 与累积区不同即视为格式切换。
    public mutating func absorb(
        incomingFrames: Int,
        formatKey incomingFormatKey: String
    ) -> PCMBufferCoalescingAction {
        // 空缓冲区不改变任何状态, 调用方按"继续累积"处理即可。
        guard incomingFrames > 0 else { return .buffer }

        if let currentKey = formatKey,
           currentKey != incomingFormatKey,
           accumulatedFrames > 0 {
            // 旧格式的帧必须先原样交出, 不能和新格式混在一个缓冲区里。
            formatKey = incomingFormatKey
            accumulatedFrames = incomingFrames
            hasFlushedOnce = true
            return .flushThenBuffer
        }

        formatKey = incomingFormatKey
        let threshold = flushThreshold
        if accumulatedFrames == 0, incomingFrames >= threshold {
            // 输入本身已经够大, 多一次拷贝没有意义。
            hasFlushedOnce = true
            return .passThrough
        }
        if accumulatedFrames + incomingFrames >= threshold {
            accumulatedFrames = 0
            hasFlushedOnce = true
            return .appendThenFlush
        }
        accumulatedFrames += incomingFrames
        return .buffer
    }

    /// 流结束。返回 true 表示还有累积帧需要交出。调用后状态复位。
    public mutating func finish() -> Bool {
        let hasPendingFrames = accumulatedFrames > 0
        accumulatedFrames = 0
        hasFlushedOnce = false
        formatKey = nil
        return hasPendingFrames
    }
}
