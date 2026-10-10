import Foundation
import PrimuseKit
import SwiftUI

// 画面来自一段持续运行的模拟的沉浸层：克拉尼沙画。模拟本身（沙子怎么走、鼓点怎么找）
// 在 PrimuseKit，这里只负责逐帧推进和画。
//
// 和 ImmersiveStageRenderers.swift 一样同时编进 Primuse(iOS)、PrimuseMac 与 PrimuseTV。
// 模拟状态放在 @State 持有的引用里，在 TimelineView 的内容闭包（主线程）里推进，
// 推进完拷一份值给 Canvas，Canvas 异步绘制时不碰会变的状态。

// MARK: - 克拉尼沙画

/// 克拉尼沙画的模拟宿主：频谱 → 鼓点与重心 → 沙子走一步。暂停、减少动态效果或省电时停在原处，
/// 沙子就像板子停振那样静静躺着。
@MainActor
final class ImmersiveChladniModel {
    struct Frame {
        var xs: [Double] = []
        var ys: [Double] = []
        var agitation: [Double] = []
        var mode = ChladniPlate.modes[0]
    }

    private var simulation: ChladniSandSimulation?
    private var tracker = ImmersiveBeatTracker()
    private var lastTime: TimeInterval?
    private var songSeed: UInt64?

    func frame(time: TimeInterval, levels: [CGFloat], songKey: String, grainCount: Int, advances: Bool) -> Frame {
        let seed = ImmersiveRandom.seed(for: songKey)
        let samples = levels.map { Double($0) }
        let features = tracker.update(levels: samples, at: time)

        if simulation == nil || needsRebuild(for: grainCount) {
            simulation = ChladniSandSimulation(count: grainCount, seed: 0xC1AD_1A, songSeed: seed)
            songSeed = seed
            lastTime = nil
        }
        guard var current = simulation else { return Frame() }
        // 先放手再改：两处同时持有时每一步都会把整组坐标复制一遍。
        simulation = nil
        if songSeed != seed {
            songSeed = seed
            current.changeSong(seed: seed, centroid: features.centroid)
        }
        if advances {
            let dt = lastTime.map { time - $0 } ?? 0
            current.step(dt: dt, centroid: features.centroid, drive: features.energy, kick: features.beat)
            lastTime = time
        } else {
            lastTime = nil
        }
        simulation = current
        return Frame(xs: current.xs, ys: current.ys, agitation: current.agitation, mode: current.mode)
    }

    /// 转屏、换视口后沙子数差得多才重新撒；差一点就沿用，免得一转屏花纹就重来。
    private func needsRebuild(for grainCount: Int) -> Bool {
        guard let simulation else { return true }
        let existing = simulation.xs.count
        return abs(existing - grainCount) > max(existing, grainCount) * 3 / 10
    }
}

/// 一块振动的方形金属板，上面撒满细沙。频谱重心与响度挑振动模式（花纹），沙子顺着流到节线上；
/// 鼓点让振幅大的地方的沙粒蹦起来。板角标出当前的模式 (m, n)。
struct ImmersiveChladniPlate: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    var levelsProvider: @MainActor () -> [CGFloat]
    var palette: ImmersiveArtworkPalette
    var isAnimating: Bool
    /// 换歌时换一组花纹；同一首歌的种子固定。
    var songKey: String
    var side: CGFloat
    var labelSize: CGFloat

    @State private var model = ImmersiveChladniModel()

    /// 节线是一维的，沙粒数跟边长成正比，线上的疏密在各种尺寸下差不多。
    private var grainCount: Int {
        min(max(Int(side * 8), 900), 6000)
    }

    var body: some View {
        let radius = max(side * 0.014, 2)
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.13, green: 0.135, blue: 0.16),
                            ImmersiveStagePalette.obsidian,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    // 金属板上一道很淡的斜向反光。
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0), location: 0.25),
                            .init(color: .white.opacity(0.05), location: 0.45),
                            .init(color: .white.opacity(0), location: 0.62),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.13), lineWidth: 1)
                }
                .shadow(color: palette.primary.opacity(0.28), radius: side * 0.05)

            TimelineView(.animation(
                minimumInterval: frameRate.minimumInterval(base: 1.0 / 24),
                paused: !isAnimating
            )) { context in
                let frame = model.frame(
                    time: context.date.timeIntervalSinceReferenceDate,
                    levels: levelsProvider(),
                    songKey: songKey,
                    grainCount: grainCount,
                    advances: isAnimating
                )
                ZStack(alignment: .bottomLeading) {
                    sand(frame)
                    Text(verbatim: "m \(frame.mode.m) · n \(frame.mode.n)")
                        .font(.system(size: labelSize, weight: .medium, design: .monospaced))
                        .foregroundStyle(ImmersiveStagePalette.text.opacity(0.42))
                        .padding(side * 0.03)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    private func sand(_ frame: ImmersiveChladniModel.Frame) -> some View {
        Canvas(rendersAsynchronously: true) { canvas, size in
            let inset = size.width * 0.018
            let span = size.width - inset * 2
            let grain = max(span / 380, 1)
            var settled = Path()
            var bouncing = Path()
            for index in frame.xs.indices {
                let rect = CGRect(
                    x: inset + CGFloat(frame.xs[index]) * span - grain / 2,
                    y: inset + CGFloat(frame.ys[index]) * span - grain / 2,
                    width: grain,
                    height: grain
                )
                if frame.agitation[index] < 0.22 {
                    settled.addRect(rect)
                } else {
                    bouncing.addRect(rect)
                }
            }
            canvas.fill(bouncing, with: .color(ImmersiveStagePalette.ink.opacity(0.38)))
            canvas.fill(settled, with: .color(Color(red: 0.96, green: 0.93, blue: 0.86).opacity(0.92)))
        }
    }
}
