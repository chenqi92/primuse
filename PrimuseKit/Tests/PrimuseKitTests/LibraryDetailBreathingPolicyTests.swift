import Foundation
import Testing
@testable import PrimuseKit

@Suite("详情页呼吸背景")
struct LibraryDetailBreathingPolicyTests {
    private typealias Policy = LibraryDetailBreathingPolicy
    private static let samples: [Double] = stride(from: 0.0, through: 60, by: 0.05).map { $0 }

    @Test("四个角不动，边上的点只沿着边走")
    func cornersStayAndEdgesSlide() {
        for time in Self.samples {
            let points = Policy.points(at: time)
            #expect(points[0] == .init(x: 0, y: 0))
            #expect(points[2] == .init(x: 1, y: 0))
            #expect(points[6] == .init(x: 0, y: 1))
            #expect(points[8] == .init(x: 1, y: 1))
            #expect(points[1].y == 0)
            #expect(points[7].y == 1)
            #expect(points[3].x == 0)
            #expect(points[5].x == 1)
        }
    }

    @Test("网格任何时刻都不翻折：每行从左到右、每列从上到下都有间隔")
    func meshNeverFolds() {
        for time in Self.samples {
            let p = Policy.points(at: time)
            for row in 0..<3 {
                #expect(p[row * 3].x + 0.2 < p[row * 3 + 1].x, "t=\(time) row \(row)")
                #expect(p[row * 3 + 1].x + 0.2 < p[row * 3 + 2].x, "t=\(time) row \(row)")
            }
            for column in 0..<3 {
                #expect(p[column].y + 0.2 < p[3 + column].y, "t=\(time) column \(column)")
                #expect(p[3 + column].y + 0.2 < p[6 + column].y, "t=\(time) column \(column)")
            }
        }
    }

    @Test("位移看得出来：正中那点与边上的点都走出一成以上，且真的走到了")
    func driftIsVisible() {
        let center = Policy.maximumDisplacement(ofPointAt: 4)
        #expect(center.x >= 0.15)
        #expect(center.y >= 0.1)
        #expect(Policy.maximumDisplacement(ofPointAt: 1).x >= 0.15)
        #expect(Policy.maximumDisplacement(ofPointAt: 3).y >= 0.12)

        let xs = Self.samples.map { Policy.points(at: $0)[4].x }
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) >= 0.3)
    }

    @Test("连续：相邻两帧（1/30 秒）之间每个点只挪一点点，没有跳变")
    func motionIsContinuous() {
        var previous = Policy.points(at: 0)
        for frame in 1...900 {
            let current = Policy.points(at: Double(frame) / 30)
            for (a, b) in zip(previous, current) {
                #expect(abs(a.x - b.x) < 0.01)
                #expect(abs(a.y - b.y) < 0.01)
            }
            previous = current
        }
    }

    @Test("幅度与尺寸无关，时间原点任意（大时间戳也照样平滑）")
    func largeTimestampsStaySmooth() {
        let base = 780_000_000.0
        let a = Policy.points(at: base)
        let b = Policy.points(at: base + 1.0 / 30)
        for (p, q) in zip(a, b) {
            #expect(abs(p.x - q.x) < 0.01)
            #expect(abs(p.y - q.y) < 0.01)
        }
        #expect(Policy.points(at: .nan) == Policy.points(at: 0))
    }

    @Test("静止位置与原来一致：三行在 0 / 0.45 / 1")
    func restingPoints() {
        #expect(Policy.restingPoints.map(\.y) == [0, 0, 0, 0.45, 0.45, 0.45, 1, 1, 1])
        #expect(Policy.restingPoints.map(\.x) == [0, 0.5, 1, 0, 0.5, 1, 0, 0.5, 1])
    }
}
