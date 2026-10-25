import Foundation

/// 跟着听到的鼓点走的一只节拍钟：拍速取 `ImmersiveBeatTracker` 从最近几拍推出来的那个，拍子落在哪儿按听到的
/// 鼓点一下下校准（锁相）。音游场景要提前一两秒把音符放上轨道，靠它预报接下来几拍什么时候到。时间都是播放时间：
/// 暂停时钟也停，拖进度时拍子的位置作废、拍速留着。
public struct ImmersiveBeatClock: Equatable, Sendable {
    /// 一拍多长（秒）。
    public private(set) var period: TimeInterval = 0.5
    /// 某一拍的时刻（播放时间）；还没听到鼓点、或刚拖过进度时为 nil。
    public private(set) var anchor: TimeInterval?
    /// 预报有多可信，0…1：听到的鼓点一次次落在预报的拍子上就往上走，落不上、很久没鼓点就往下掉。
    public private(set) var confidence: Double = 0
    /// `anchor` 那一拍是第几拍：拍子的位置挪到别的拍上时跟着加，数出来的第几拍（每四拍一小节）不会跳。
    private var anchorBeat = 0.0
    private var lastTime: TimeInterval?
    private var lastBeat = -Double.infinity

    /// 可信到这个程度才拿来预报。
    public static let lockedConfidence = 0.45
    /// 鼓点落在预报的拍子前后这么多拍以内算对上。
    static let captureWindow = 0.2
    /// 对上时把拍子的位置往听到的那一下挪多少（剩下的留给后面几拍，一下鼓点早了晚了不会把整条拍子拽过去）。
    static let anchorPull = 0.3
    /// 这么久没听到鼓点，预报开始变得不可信。
    static let silenceGrace: TimeInterval = 2

    public init() {}

    /// 拍子对上了、可以拿来预报。
    public var isLocked: Bool { anchor != nil && confidence >= Self.lockedConfidence }

    /// 走一帧。`beat` 是这一帧听到的鼓点力度（0 是没有），`beatsPerSecond`、`steadiness` 来自
    /// `ImmersiveAudioFeatures`；`time` 是播放时间。
    public mutating func update(
        beat: Double,
        beatsPerSecond: Double?,
        steadiness: Double,
        at time: TimeInterval
    ) {
        guard time.isFinite else { return }
        defer { lastTime = time }
        if let lastTime, time < lastTime - 0.05 || time - lastTime > 1 {
            // 拖了进度：拍子的位置不再算数，拍速照旧。
            anchor = nil
            confidence *= 0.5
            lastBeat = -.infinity
        }
        let dt = lastTime.map { min(max(time - $0, 0), 0.25) } ?? 0
        if let beatsPerSecond, beatsPerSecond > 0, steadiness > 0.25 {
            let target = 1 / beatsPerSecond
            if confidence < 0.3 || abs(target - period) / period > 0.12 {
                period = target
            } else {
                period += (target - period) * min(1, dt * 0.8)
            }
        }
        if beat > 0 {
            if let anchor {
                let steps = ((time - anchor) / period).rounded()
                let predicted = anchor + steps * period
                let error = time - predicted
                let window = Self.captureWindow * period
                if abs(error) <= window {
                    self.anchor = predicted + Self.anchorPull * error
                    anchorBeat += steps
                    confidence = min(1, confidence + 0.14 * (1 - abs(error) / window))
                } else {
                    confidence = max(0, confidence - 0.05)
                    // 一直对不上：从这一下重新数。
                    if confidence < 0.1 {
                        self.anchor = time
                        anchorBeat = 0
                    }
                }
            } else {
                anchor = time
                anchorBeat = 0
                confidence = max(confidence, 0.05)
            }
            lastBeat = time
        } else if time - lastBeat > Self.silenceGrace {
            confidence = max(0, confidence - dt * 0.3)
        }
        // 很久没对上新的鼓点时把拍子的位置挪到近处的一拍上，往后数不丢精度。
        if let anchor, time - anchor > period * 32 {
            let steps = ((time - anchor) / period).rounded(.down)
            self.anchor = anchor + steps * period
            anchorBeat += steps
        }
    }

    /// `start`…`end` 之间预报的拍子（播放时间，升序）。没对上拍子时为空。
    public func beats(from start: TimeInterval, through end: TimeInterval) -> [TimeInterval] {
        guard isLocked, let anchor, end >= start, period > 0.05 else { return [] }
        var index = ((start - anchor) / period).rounded(.up)
        var result: [TimeInterval] = []
        while true {
            let beat = anchor + index * period
            if beat > end { break }
            result.append(beat)
            index += 1
        }
        return result
    }

    /// 此刻在拍子上走到哪儿：从对上拍子起数的第几拍，小数部分 0 是正落在拍上。没对上拍子时为 nil。
    public func position(at time: TimeInterval) -> Double? {
        guard isLocked, let anchor, period > 0.05 else { return nil }
        return anchorBeat + (time - anchor) / period
    }
}
