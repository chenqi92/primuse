import SwiftUI
import PrimuseKit

/// 播放页背景「流动色彩」(#189):封面里挑出来的几个颜色化成七团又大又软的光,沿互不相同的慢速轨迹
/// 漂动,看上去像慢慢流动的液体。iPhone、iPad 与 Mac 的播放页共用。
///
/// - 只在播放、页面看得见、App 在前台时动;暂停时原地停住,接着播放从停住的地方继续。
/// - 换歌时颜色用 1.8 秒从屏幕上此刻的颜色渐变过去,色块位置不重置。
/// - 不做整屏高斯模糊:每团是从中心往外淡到透明的径向渐变,软边本身就够,重叠处自然融成一片。
///   每团半径约为长边的一半(Linx 是 55%),七团都盖满整屏时颜色会被平均成一片浑色。
/// - 减弱动态效果、低电量模式、机身过热时停住不动;最多每秒 24 帧(偏热时 12 帧)。
/// - 上面照旧压着播放页那两层浅色 / 深色遮罩,字的可读性不靠这一层。
struct LiquidArtworkBackdrop: View {
    let palette: [LiquidBackdropColor]
    let isLight: Bool
    /// 0…1,设置里的「氛围强度」;默认 0.7 时每团的不透明度正好是 0.65。
    let strength: Double
    let isVisible: Bool
    let isSceneActive: Bool
    let isPlaying: Bool

    static let colorTransitionDuration: TimeInterval = 1.8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var runtimeRevision: UInt = 0
    @State private var activeElapsed: TimeInterval = 0
    @State private var startedAt: Date?
    @State private var fromColors: [LiquidBackdropColor] = []
    @State private var toColors: [LiquidBackdropColor] = []
    @State private var transitionStart: Date?

    var body: some View {
        let _ = runtimeRevision
        let moves = shouldMove
        TimelineView(.animation(
            minimumInterval: frameInterval,
            paused: !(moves || transitionStart != nil)
        )) { context in
            Canvas(rendersAsynchronously: true) { canvas, size in
                draw(in: &canvas, size: size, date: context.date)
            }
        }
        .onAppear {
            if toColors.isEmpty {
                let colors = LiquidBackdropPalettePolicy.blobColors(for: palette)
                fromColors = colors
                toColors = colors
            }
            updateClock(running: moves, at: .now)
        }
        .onChange(of: moves) { _, running in
            updateClock(running: running, at: .now)
        }
        .onChange(of: palette) { _, newPalette in
            beginColorTransition(to: newPalette, at: .now)
        }
        .onDisappear {
            updateClock(running: false, at: .now)
        }
        .task(id: transitionStart) {
            guard transitionStart != nil else { return }
            try? await Task.sleep(for: .seconds(Self.colorTransitionDuration))
            guard !Task.isCancelled else { return }
            fromColors = toColors
            transitionStart = nil
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            runtimeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            runtimeRevision &+= 1
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 什么时候动

    private var shouldMove: Bool {
        guard isVisible, isSceneActive, isPlaying, !reduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair: return true
        default: return false
        }
    }

    private var frameInterval: TimeInterval {
        ProcessInfo.processInfo.thermalState == .fair ? 1.0 / 12 : 1.0 / 24
    }

    /// 只在动的时候累计时间:暂停、看不见时停在原处,接着从原处继续。
    private func updateClock(running: Bool, at date: Date) {
        if running {
            if startedAt == nil { startedAt = date }
        } else if let startedAt {
            activeElapsed += max(0, date.timeIntervalSince(startedAt))
            self.startedAt = nil
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return activeElapsed }
        return activeElapsed + max(0, date.timeIntervalSince(startedAt))
    }

    // MARK: 颜色

    /// 从屏幕上此刻的颜色出发渐变到新的一组,连着换几首也不会跳色。
    private func beginColorTransition(to newPalette: [LiquidBackdropColor], at date: Date) {
        let target = LiquidBackdropPalettePolicy.blobColors(for: newPalette)
        guard target != toColors else { return }
        fromColors = currentColors(at: date)
        toColors = target
        transitionStart = date
    }

    private func currentColors(at date: Date) -> [LiquidBackdropColor] {
        guard let transitionStart, !fromColors.isEmpty else { return toColors }
        let linear = min(max(date.timeIntervalSince(transitionStart) / Self.colorTransitionDuration, 0), 1)
        let t = linear * linear * (3 - 2 * linear)
        return toColors.enumerated().map { index, target in
            fromColors[index % fromColors.count].mixed(with: target, amount: t)
        }
    }

    // MARK: 画

    private func draw(in canvas: inout GraphicsContext, size: CGSize, date: Date) {
        let colors = currentColors(at: date)
        let base = LiquidBackdropPalettePolicy.baseColor(for: Array(colors.prefix(2)), isLight: isLight)
        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base.swiftUIColor))
        guard !colors.isEmpty else { return }

        let longSide = max(size.width, size.height)
        let opacity = LiquidBackdropMotion.blobOpacity
            * min(max(strength / 0.7, 0), 1.2)
            * (isLight ? 0.85 : 1)
        let blobs = LiquidBackdropMotion.blobs(at: elapsed(at: date))
        for (blob, color) in zip(blobs, colors) {
            let center = CGPoint(x: blob.x * size.width, y: blob.y * size.height)
            let radius = blob.radius * longSide
            let tint = color.swiftUIColor
            // 中心一大片较实,外圈再慢慢淡掉:各团的颜色分得出来,边缘仍然看不出圆。
            let gradient = Gradient(stops: [
                .init(color: tint.opacity(opacity), location: 0),
                .init(color: tint.opacity(opacity * 0.78), location: 0.4),
                .init(color: tint.opacity(opacity * 0.32), location: 0.72),
                .init(color: tint.opacity(0), location: 1),
            ])
            canvas.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius)
            )
        }
    }
}

extension LiquidBackdropColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }
}
