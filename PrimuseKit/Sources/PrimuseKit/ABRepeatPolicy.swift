import Foundation

/// A-B 循环里反复放的那一段,用这首歌自己的时间。
public struct ABRepeatLoop: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }

    public var length: TimeInterval { max(0, end - start) }
}

/// A-B 循环:在一首歌里自己选一段反复放。只跟着当前这首,换歌就没了;循环中不管循环方式是什么,
/// 放到 B 一律回到 A。
public enum ABRepeatState: Equatable, Sendable {
    case off
    /// 设好了 A,等着设 B。
    case pointA(TimeInterval)
    case looping(ABRepeatLoop)

    public var loop: ABRepeatLoop? {
        if case .looping(let loop) = self { return loop }
        return nil
    }

    public var isActive: Bool { self != .off }
}

public enum ABRepeatPolicy {
    /// 一段至少这么长;两点挨得更近时第二下不算数。
    public static let minimumLength: TimeInterval = 1
    /// 拖进度条落到区间外这么远才算离开 A-B(和卡拉OK 练唱一样)。
    public static let leaveMargin: TimeInterval = KaraokePracticePolicy.leaveMargin
    /// 还没有区间就打开「选择区间」时,从播放头起框这么长一段。
    public static let defaultLength: TimeInterval = 15
    /// 编辑区间时每点一下挪多少。
    public static let nudgeStep: TimeInterval = 0.5
    /// 离 B 这么近就算到了:播放时钟 0.5 秒一拍,准点跳回另有定时,这里只兜底。
    static let endTolerance: TimeInterval = 0.02

    /// 点一下 A-B 之后的样子:没开时在 `time` 设 A,设了 A 时在 `time` 设 B 开始循环,循环中就关掉。
    /// `playable` 是这首此刻放得到的范围(开着播放时间段时是那一段)。
    public static func advanced(
        _ state: ABRepeatState,
        at time: TimeInterval,
        playable: ClosedRange<TimeInterval>
    ) -> ABRepeatState {
        switch state {
        case .off:
            return .pointA(clamped(time, to: playable))
        case .pointA(let a):
            guard let loop = loop(from: a, to: time, playable: playable) else { return state }
            return .looping(loop)
        case .looping:
            return .off
        }
    }

    /// 两点框出的一段:B 在 A 前面时对调,超出范围的部分截掉,不到 `minimumLength` 时为 nil。
    public static func loop(
        from a: TimeInterval,
        to b: TimeInterval,
        playable: ClosedRange<TimeInterval>
    ) -> ABRepeatLoop? {
        guard a.isFinite, b.isFinite else { return nil }
        let start = clamped(min(a, b), to: playable)
        let end = clamped(max(a, b), to: playable)
        guard end - start >= minimumLength else { return nil }
        return ABRepeatLoop(start: start, end: end)
    }

    /// 从 `time` 起框 `defaultLength` 一段;后面不够长时整段往前挪。整首都不到 `minimumLength` 时为 nil。
    public static func initialLoop(at time: TimeInterval, playable: ClosedRange<TimeInterval>) -> ABRepeatLoop? {
        guard playable.upperBound - playable.lowerBound >= minimumLength else { return nil }
        let start = clamped(time.isFinite ? time : playable.lowerBound, to: playable)
        let end = min(playable.upperBound, start + defaultLength)
        let shiftedStart = max(playable.lowerBound, end - defaultLength)
        return ABRepeatLoop(start: min(start, shiftedStart), end: end)
    }

    public enum Edge: Sendable {
        case start
        case end
    }

    /// 把一端挪到 `value`,另一端不动;不越过另一端(至少留 `minimumLength`),也不出范围。
    public static func moving(
        _ edge: Edge,
        of loop: ABRepeatLoop,
        to value: TimeInterval,
        playable: ClosedRange<TimeInterval>
    ) -> ABRepeatLoop {
        guard value.isFinite else { return loop }
        var result = loop
        switch edge {
        case .start:
            let upper = max(playable.lowerBound, loop.end - minimumLength)
            result.start = min(max(value, playable.lowerBound), upper)
        case .end:
            let lower = min(playable.upperBound, loop.start + minimumLength)
            result.end = max(min(value, playable.upperBound), lower)
        }
        return result
    }

    /// 播放范围变了(改了播放时间段)之后还剩下的那一段,剩下的不够长时为 nil。
    public static func fitted(_ loop: ABRepeatLoop, to playable: ClosedRange<TimeInterval>) -> ABRepeatLoop? {
        self.loop(from: loop.start, to: loop.end, playable: playable)
    }

    /// 播放头到了 B(或者已经过了)。
    public static func reachedEnd(of loop: ABRepeatLoop, at time: TimeInterval) -> Bool {
        time >= loop.end - endTolerance
    }

    /// 从 `time` 放到 B 还要多少真实时间,按播放速度换算;已经到了为 0。
    public static func timeUntilEnd(of loop: ABRepeatLoop, at time: TimeInterval, rate: Double) -> TimeInterval {
        let safeRate = rate.isFinite && rate > 0 ? rate : 1
        return max(0, loop.end - time) / safeRate
    }

    /// 一次拖动落在 `target`:循环中落到区间外(留 `leaveMargin`)就关掉 A-B。只设了 A 时随便拖。
    public static func seekLeaves(_ state: ABRepeatState, target: TimeInterval) -> Bool {
        guard let loop = state.loop, target.isFinite else { return false }
        return target < loop.start - leaveMargin || target > loop.end + leaveMargin
    }

    private static func clamped(_ time: TimeInterval, to playable: ClosedRange<TimeInterval>) -> TimeInterval {
        min(max(time, playable.lowerBound), playable.upperBound)
    }
}
