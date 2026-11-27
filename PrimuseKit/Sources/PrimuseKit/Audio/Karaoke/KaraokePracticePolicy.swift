import Foundation

/// Practice tools on the karaoke stage: looping lines and slowing down.
public enum KaraokePracticePolicy {
    /// Practice speeds; the key stays where it is.
    public static let rates: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    /// Music before the first looped line, to count in.
    public static let preRoll: TimeInterval = 1.5
    /// Music after the last looped line, unless the next line starts sooner.
    public static let postRoll: TimeInterval = 0.4
    /// Playback this far outside the loop was moved there by hand.
    public static let leaveMargin: TimeInterval = 1.5

    /// A stretch of lines played over and over. Indices are into the stage's
    /// line windows.
    public struct Loop: Equatable, Sendable {
        public var firstWindow: Int
        public var lastWindow: Int
        /// Where each pass starts.
        public var start: TimeInterval
        /// Where each pass jumps back.
        public var end: TimeInterval

        public var lineCount: Int { lastWindow - firstWindow + 1 }
    }

    public enum Action: Equatable, Sendable {
        case none
        case jumpBack
        /// The listener moved away from the loop; stop looping.
        case leave
    }

    /// A loop around the line sung at `time`, or the next one to come.
    public static func loop(windows: [KaraokeLineWindow], at time: TimeInterval) -> Loop? {
        let index = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time)
            ?? windows.firstIndex { $0.start > time }
        guard let index else { return nil }
        return loop(windows: windows, first: index, last: index)
    }

    /// The loop grown by the following line, nil when there is none.
    public static func extended(_ loop: Loop, windows: [KaraokeLineWindow]) -> Loop? {
        guard loop.firstWindow >= 0, loop.lastWindow + 1 < windows.count else { return nil }
        return self.loop(windows: windows, first: loop.firstWindow, last: loop.lastWindow + 1)
    }

    static func loop(windows: [KaraokeLineWindow], first: Int, last: Int) -> Loop {
        let start = max(0, windows[first].start - preRoll)
        let lineEnd = windows[last].end
        var end = lineEnd + postRoll
        if last + 1 < windows.count {
            end = min(end, max(lineEnd, windows[last + 1].start))
        }
        return Loop(firstWindow: first, lastWindow: last, start: start, end: end)
    }

    public static func action(for loop: Loop, at time: TimeInterval) -> Action {
        if time < loop.start - leaveMargin || time > loop.end + leaveMargin { return .leave }
        return time >= loop.end ? .jumpBack : .none
    }

    /// The next practice speed up or down from `rate`.
    public static func stepped(_ rate: Double, up: Bool) -> Double {
        if up {
            return rates.first { $0 > rate + 0.001 } ?? rates[rates.count - 1]
        }
        return rates.last { $0 < rate - 0.001 } ?? rates[0]
    }
}
