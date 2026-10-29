import Foundation

@main struct WatchSeekDialDragSmoke {
    static func main() {
        let center = CGPoint(x: 50, y: 50)
        func point(_ fraction: Double) -> CGPoint {
            CGPoint(x: center.x + 40 * sin(fraction * 2 * .pi),
                    y: center.y - 40 * cos(fraction * 2 * .pi))
        }
        func drag(_ time: Double, at fraction: Double? = nil) -> WatchSeekDialDrag {
            WatchSeekDialDrag(songID: "song", time: time, duration: 100,
                             location: point(fraction ?? time / 100), center: center, radius: 40)!
        }
        func expect(_ actual: Double, _ expected: Double) {
            precondition(abs(actual - expected) < 0.00001, "Expected \(expected), got \(actual)")
        }

        var clockwise = drag(25)
        precondition(clockwise.destination(songID: "song", duration: 100) == nil, "Touch alone must not seek")
        clockwise.update(location: point(0.5))
        expect(clockwise.time, 50)
        clockwise.update(location: point(0.25))
        expect(clockwise.time, 25)
        precondition(clockwise.destination(songID: "other", duration: 100) == nil)
        precondition(clockwise.destination(songID: "song", duration: 200) == nil)
        expect(clockwise.destination(songID: "song", duration: 100)!, 25)

        var leftEdge = drag(73)
        leftEdge.update(location: point(0.77))
        expect(leftEdge.time, 77)
        leftEdge.update(location: point(0.73))
        expect(leftEdge.time, 73)

        var end = drag(98)
        end.update(location: point(0.02))
        expect(end.time, 100)
        end.update(location: point(0.01))
        expect(end.time, 99)
        var start = drag(2)
        start.update(location: point(0.98))
        expect(start.time, 0)
        start.update(location: point(0.99))
        expect(start.time, 1)

        var offsetTouch = drag(40, at: 0.43)
        offsetTouch.update(location: point(0.53))
        expect(offsetTouch.time, 50)
        offsetTouch.update(location: center)
        offsetTouch.update(location: point(0.9))
        expect(offsetTouch.time, 50)
        offsetTouch.update(location: point(0.95))
        expect(offsetTouch.time, 55)

        precondition(WatchSeekDialDrag(songID: "song", time: 0, duration: 0,
                                      location: point(0), center: center, radius: 40) == nil)
        precondition(WatchSeekDialDrag(songID: "song", time: .nan, duration: 100,
                                      location: point(0), center: center, radius: 40) == nil)
        print("Watch dial: bidirectional drag, endpoint clamping, offset touch, center crossing, stale track and tap passed")
    }
}
