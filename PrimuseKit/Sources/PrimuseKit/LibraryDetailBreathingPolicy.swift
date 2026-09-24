import Foundation

/// 呼吸背景网格上的一个控制点，单位坐标（左上 0,0，右下 1,1）。
public struct LibraryDetailMeshPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 详情页呼吸背景（3×3 网格渐变）的控制点怎么漂。
///
/// 每个点绕着静止位置做一段正弦摆动：正弦本身两头慢中间快，是柔和的缓入缓出；
/// 各点的频率与相位错开，整面看起来是一团团色块在慢慢流，而不是整张网格机械地来回推拉。
/// 四个角不动，边上的点只沿着边走，网格不会露出空隙；中间一行与中间一列在任何时刻都不交叉，网格不会翻折。
/// 幅度是单位坐标里的定值，不随页面尺寸变。
public enum LibraryDetailBreathingPolicy {
    /// 基准周期（秒）。各点的频率是它的倍数，所以整面不会每 6.5 秒原样重复一次。
    public static let period: Double = 6.5

    /// 静止时三行在 0 / 0.45 / 1：上半屏是主色，过了头图才变深。减弱动态效果时就停在这里。
    public static let restingPoints: [LibraryDetailMeshPoint] = [
        .init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0),
        .init(x: 0, y: 0.45), .init(x: 0.5, y: 0.45), .init(x: 1, y: 0.45),
        .init(x: 0, y: 1), .init(x: 0.5, y: 1), .init(x: 1, y: 1),
    ]

    /// 一个点的摆动：两个方向各自的幅度（单位坐标）、频率倍数与相位（弧度）。
    struct Drift: Sendable {
        var amplitudeX: Double
        var amplitudeY: Double
        var frequencyX: Double
        var frequencyY: Double
        var phaseX: Double
        var phaseY: Double

        static let still = Drift(amplitudeX: 0, amplitudeY: 0, frequencyX: 0, frequencyY: 0, phaseX: 0, phaseY: 0)

        static func horizontal(_ amplitude: Double, frequency: Double, phase: Double) -> Drift {
            Drift(amplitudeX: amplitude, amplitudeY: 0, frequencyX: frequency, frequencyY: 0, phaseX: phase, phaseY: 0)
        }

        static func vertical(_ amplitude: Double, frequency: Double, phase: Double) -> Drift {
            Drift(amplitudeX: 0, amplitudeY: amplitude, frequencyX: 0, frequencyY: frequency, phaseX: 0, phaseY: phase)
        }
    }

    /// 九个点各自的摆动，顺序与 `restingPoints` 一致。
    /// 上下两条边的中点左右摆 ±0.22，左右两条边的中点上下摆 ±0.18，正中那点走一条 ±0.24 × ±0.16 的利萨如曲线。
    static let drifts: [Drift] = [
        .still, .horizontal(0.22, frequency: 1, phase: 0), .still,
        .vertical(0.18, frequency: 0.83, phase: 1.9),
        Drift(amplitudeX: 0.24, amplitudeY: 0.16, frequencyX: 0.91, frequencyY: 1.17, phaseX: 0.6, phaseY: 2.4),
        .vertical(0.18, frequency: 1.09, phase: 4.1),
        .still, .horizontal(0.22, frequency: 0.77, phase: 3.3), .still,
    ]

    /// 某一时刻（秒，任意起点）九个点的位置。
    public static func points(at time: Double) -> [LibraryDetailMeshPoint] {
        let omega = 2 * Double.pi / period
        let t = time.isFinite ? time : 0
        return zip(restingPoints, drifts).map { resting, drift in
            LibraryDetailMeshPoint(
                x: resting.x + drift.amplitudeX * sin(omega * drift.frequencyX * t + drift.phaseX),
                y: resting.y + drift.amplitudeY * sin(omega * drift.frequencyY * t + drift.phaseY)
            )
        }
    }

    /// 每个点离静止位置最远能走多远（单位坐标）。测试与文档用。
    public static func maximumDisplacement(ofPointAt index: Int) -> (x: Double, y: Double) {
        let drift = drifts[index]
        return (drift.amplitudeX, drift.amplitudeY)
    }
}
