import SwiftUI

/// 16 条柱状频谱。强度 0~1, 0.07s linear 动画过渡, 25Hz tick 流畅但不卡。
struct VisualizerBarsView: View {
    let levels: [Float]
    var barColor: Color = .primary
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var maxHeight: CGFloat = 36
    /// 强度太低时一律抹平到底, 不显示零碎的 1px 残影 (静音时 FFT 仍有
    /// 微弱噪声触底)。
    private let noiseFloor: Float = 0.05

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<levels.count, id: \.self) { i in
                let value = max(0, levels[i] - noiseFloor)
                Capsule()
                    .fill(barColor)
                    .frame(width: barWidth, height: max(2, CGFloat(value) * maxHeight))
            }
        }
        .frame(height: maxHeight, alignment: .bottom)
        .animation(.linear(duration: 0.07), value: levels)
    }
}
