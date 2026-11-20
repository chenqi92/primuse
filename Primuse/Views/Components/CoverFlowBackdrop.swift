import SwiftUI
import PrimuseKit

/// 几首歌的封面色拼成一块缓慢流动的网格渐变,像 Apple Music 歌单、混音卡片的底。
/// 首页顶部卡片没有封面时、智能推荐页头上那张卡共用。颜色来自 `CoverTintProvider`。
struct CoverFlowBackdrop: View {
    let palettes: [ImmersiveArtworkPalette]
    /// 不在屏幕正中、滑动中、页面不在前台时停住,省电。
    var isAnimating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var elapsed: TimeInterval = 0
    @State private var started: TimeInterval?

    var body: some View {
        let colors = Self.meshColors(palettes)
        let moving = isAnimating && !reduceMotion && scenePhase == .active
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
            let time = elapsed + (started.map { context.date.timeIntervalSinceReferenceDate - $0 } ?? 0)
            MeshGradient(
                width: 3,
                height: 3,
                points: MeshBackdropPalettePolicy.liquidPoints(at: time),
                colors: colors
            )
        }
        .onChange(of: moving, initial: true) { _, active in
            let now = Date().timeIntervalSinceReferenceDate
            if active {
                started = now
            } else if let started {
                elapsed += now - started
                self.started = nil
            }
        }
        .animation(.easeInOut(duration: 0.6), value: colors.map(\.description))
        .accessibilityHidden(true)
    }

    /// 九个顶点:四角压深色,中间和四边放各首的亮色,一首歌也排得满。
    static func meshColors(_ palettes: [ImmersiveArtworkPalette]) -> [Color] {
        let source = palettes.isEmpty ? [ImmersiveArtworkPalette.fallback] : palettes
        let lights = source.map(\.primary)
        let darks = source.map(\.secondary)
        func light(_ index: Int) -> Color { lights[index % lights.count] }
        func dark(_ index: Int) -> Color { darks[index % darks.count] }
        return [
            dark(0), light(1), dark(2),
            light(2), light(0), light(3),
            dark(1), light(3), dark(3),
        ]
    }
}
