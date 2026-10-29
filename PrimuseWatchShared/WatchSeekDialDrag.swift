import Foundation

struct WatchSeekDialDrag {
    let songID: String
    let duration: TimeInterval
    private(set) var time: TimeInterval
    private(set) var hasMoved = false
    private var lastAngle: Double?
    private let center: CGPoint
    private let minimumRadius: CGFloat

    init?(songID: String, time: TimeInterval, duration: TimeInterval,
          location: CGPoint, center: CGPoint, radius: CGFloat) {
        guard time.isFinite, duration.isFinite, duration > 0, radius.isFinite, radius > 0 else { return nil }
        self.songID = songID
        self.duration = duration
        self.time = min(duration, max(0, time))
        self.center = center
        minimumRadius = radius * 0.3
        lastAngle = angle(at: location)
    }

    mutating func update(location: CGPoint) {
        let nextAngle = angle(at: location)
        defer { lastAngle = nextAngle }
        guard let nextAngle, let lastAngle else { return }
        var delta = nextAngle - lastAngle
        // 穿过十二点时连续增减，并在首尾停住，不从结尾跳回开头。
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        guard abs(delta) > 0.0001 else { return }
        hasMoved = true
        time = min(duration, max(0, time + delta / (2 * .pi) * duration))
    }

    func destination(songID: String, duration: TimeInterval) -> TimeInterval? {
        guard hasMoved, self.songID == songID, self.duration == duration else { return nil }
        return time
    }

    private func angle(at location: CGPoint) -> Double? {
        let dx = location.x - center.x
        let dy = location.y - center.y
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) >= minimumRadius else { return nil }
        return atan2(dy, dx)
    }
}
