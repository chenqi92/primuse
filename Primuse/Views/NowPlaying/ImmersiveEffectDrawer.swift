#if os(iOS)
import SwiftUI
import PrimuseKit

/// 全屏效果的侧边抽屉。
///
/// 纯文字清单换成缩略图转轮：真正在动的预览是背后的舞台本身，转轮里的卡片一律
/// 停在静态帧 —— 同时跑十几个动画舞台既没有意义，也会让机器发烫。
///
/// 抽屉自己按视口决定贴哪一边（横屏贴尾侧、竖屏贴底部）与转轮方向；宿主只负责
/// 把它放进自己的 ZStack、加 `if` 与同侧的滑入过渡，这样宿主才能准确知道它开着，
/// 继续暂停浮动控件的自动隐藏。
struct ImmersiveEffectDrawer: View {
    @Binding var selection: FullscreenPlayerEffect
    /// 要列出的效果，顺序即转轮顺序。
    let effects: [FullscreenPlayerEffect]
    let palette: ImmersiveArtworkPalette
    /// true：滚停即应用（全屏内，背后的舞台跟着换）；false：转轮只是浏览，点卡片才写回。
    let appliesOnSettle: Bool
    let viewportSize: CGSize
    let safeAreaInsets: EdgeInsets
    /// 点了某张卡片（哪怕它就是当前效果）。播放页用它来「选完直接进全屏」；
    /// 全屏内不需要，留空即可。
    let onPick: ((FullscreenPlayerEffect) -> Void)?
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var centeredID: String?
    @State private var settleTask: Task<Void, Never>?

    init(
        selection: Binding<FullscreenPlayerEffect>,
        effects: [FullscreenPlayerEffect],
        palette: ImmersiveArtworkPalette,
        appliesOnSettle: Bool,
        viewportSize: CGSize,
        safeAreaInsets: EdgeInsets,
        onPick: ((FullscreenPlayerEffect) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        _selection = selection
        self.effects = effects
        self.palette = palette
        self.appliesOnSettle = appliesOnSettle
        self.viewportSize = viewportSize
        self.safeAreaInsets = safeAreaInsets
        self.onPick = onPick
        self.onClose = onClose
        // 打开时就停在当前效果上。放在 init 里而不是 onAppear，转轮第一次布局就位，
        // 不会先显示第一张再跳一下。
        _centeredID = State(
            initialValue: ImmersiveEffectDrawerPolicy.initialCenterID(
                effectIDs: effects.map(\.id),
                currentID: selection.wrappedValue.id
            )
        )
    }

    var body: some View {
        let layout = drawerLayout
        return panel(layout: layout)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(layout.placement))
            .sensoryFeedback(.selection, trigger: selection)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onClose)
            .onChange(of: centeredID) { _, newValue in
                scheduleSettle(newValue)
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
            }
    }

    private var drawerLayout: ImmersiveEffectDrawerLayout {
        ImmersiveEffectDrawerPolicy.layout(
            viewportWidth: viewportSize.width,
            viewportHeight: viewportSize.height,
            safeAreaLeading: safeAreaInsets.leading,
            safeAreaTrailing: safeAreaInsets.trailing,
            safeAreaTop: safeAreaInsets.top,
            safeAreaBottom: safeAreaInsets.bottom
        )
    }

    private func alignment(_ placement: ImmersiveEffectDrawerPlacement) -> Alignment {
        switch placement {
        case .trailing: return .trailing
        case .bottom: return .bottom
        }
    }

    // MARK: - 面板

    @ViewBuilder
    private func panel(layout: ImmersiveEffectDrawerLayout) -> some View {
        if layout.placement.scrollsVertically {
            trailingPanel(layout: layout)
        } else {
            bottomPanel(layout: layout)
        }
    }

    private func trailingPanel(layout: ImmersiveEffectDrawerLayout) -> some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header
            verticalWheel(layout: layout)
            caption
        }
        .padding(.leading, layout.contentLeading)
        .padding(.trailing, layout.contentTrailing)
        .padding(.top, layout.contentTop)
        .padding(.bottom, layout.contentBottom)
        .frame(width: layout.panelWidth, height: layout.panelHeight)
        .background { surface(shape(for: .trailing)) }
    }

    private func bottomPanel(layout: ImmersiveEffectDrawerLayout) -> some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            compactCaption
            horizontalWheel(layout: layout)
        }
        .padding(.leading, layout.contentLeading)
        .padding(.trailing, layout.contentTrailing)
        .padding(.top, layout.contentTop)
        .padding(.bottom, layout.contentBottom)
        .frame(width: layout.panelWidth, height: layout.panelHeight)
        .background { surface(shape(for: .bottom)) }
    }

    /// 靠内的一侧圆角，贴边的一侧切平。
    private func shape(for placement: ImmersiveEffectDrawerPlacement) -> UnevenRoundedRectangle {
        switch placement {
        case .trailing:
            return UnevenRoundedRectangle(
                topLeadingRadius: Self.panelCornerRadius,
                bottomLeadingRadius: Self.panelCornerRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .bottom:
            return UnevenRoundedRectangle(
                topLeadingRadius: Self.panelCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Self.panelCornerRadius,
                style: .continuous
            )
        }
    }

    private func surface(_ outline: UnevenRoundedRectangle) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            ImmersiveStagePalette.obsidian.opacity(0.74)
            LinearGradient(
                colors: [
                    palette.secondary.opacity(0.58),
                    palette.primary.opacity(0.20),
                    ImmersiveStagePalette.obsidian.opacity(0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .environment(\.colorScheme, .dark)
        .clipShape(outline)
        .overlay {
            outline.strokeBorder(ImmersiveStagePalette.ink.opacity(0.18), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.42), radius: 26)
    }

    // MARK: - 标题与说明

    private var header: some View {
        HStack(spacing: 8) {
            Text("fullscreen_effect_settings_title")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ImmersiveStagePalette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            closeButton
        }
        .frame(height: Self.headerHeight)
    }

    /// 横屏时说明放在抽屉底部：转轮占满中段，名称与描述固定在同一位置，换项时只换字。
    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: centeredEffect.localizedTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ImmersiveStagePalette.ink)
                .lineLimit(1)
            Text(verbatim: centeredEffect.motionDescription)
                .font(.system(size: 12))
                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.62))
                .lineLimit(2)
        }
        .contentTransition(.opacity)
        .pmAnimation(.control, value: centeredID)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.captionHeight, alignment: .topLeading)
    }

    /// 竖屏时抽屉只有两百来点高，说明与收起按钮并成一行放在转轮上方。
    private var compactCaption: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: centeredEffect.localizedTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ImmersiveStagePalette.ink)
                    .lineLimit(1)
                Text(verbatim: centeredEffect.motionDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.62))
                    .lineLimit(1)
            }
            .contentTransition(.opacity)
            .pmAnimation(.control, value: centeredID)

            Spacer(minLength: 8)
            closeButton
        }
        .padding(.horizontal, Self.compactCaptionInset)
        .frame(height: Self.compactCaptionHeight)
    }

    private var closeButton: some View {
        ImmersiveGlassActionButton(
            symbol: "xmark",
            label: "close",
            diameter: Self.closeButtonDiameter,
            action: onClose
        )
    }

    private var centeredEffect: FullscreenPlayerEffect {
        guard let centeredID, let match = effects.first(where: { $0.id == centeredID }) else {
            return selection
        }
        return match
    }

    // MARK: - 转轮

    private func verticalWheel(layout: ImmersiveEffectDrawerLayout) -> some View {
        // scrollTransition 的闭包是 @Sendable 的，读不到 @MainActor 的视图成员，
        // 所以先把要用到的环境取成局部值，闭包里只调用文件内的自由函数。
        let reducesMotion = reduceMotion
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: Self.cardSpacing) {
                ForEach(effects) { effect in
                    card(effect, layout: layout)
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            immersiveEffectWheelEffect(
                                content,
                                phase: phase,
                                scrollsVertically: true,
                                reduceMotion: reducesMotion
                            )
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredID, anchor: .center)
        .contentMargins(.vertical, layout.wheelMargin, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func horizontalWheel(layout: ImmersiveEffectDrawerLayout) -> some View {
        let reducesMotion = reduceMotion
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Self.cardSpacing) {
                ForEach(effects) { effect in
                    card(effect, layout: layout)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            immersiveEffectWheelEffect(
                                content,
                                phase: phase,
                                scrollsVertically: false,
                                reduceMotion: reducesMotion
                            )
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centeredID, anchor: .center)
        .contentMargins(.horizontal, layout.wheelMargin, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ effect: FullscreenPlayerEffect, layout: ImmersiveEffectDrawerLayout) -> some View {
        let isCurrent = effect == selection
        return Button {
            selectCard(effect)
        } label: {
            VStack(spacing: Self.cardNameSpacing) {
                ImmersiveEffectPreview(effect: effect, isActive: false, palette: palette)
                    .frame(width: layout.cardWidth, height: layout.cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                            .strokeBorder(
                                isCurrent ? palette.primary.opacity(0.92) : Color.white.opacity(0.14),
                                lineWidth: isCurrent ? 1.6 : 0.7
                            )
                    }

                Text(verbatim: effect.localizedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isCurrent ? palette.primary : ImmersiveStagePalette.text.opacity(0.70))
                    .lineLimit(1)
                    .frame(height: Self.cardNameHeight)
            }
            // 缩略图自己关掉了命中测试,不补一层整卡的命中形状就只有名字那一行点得动。
            .contentShape(Rectangle())
        }
        .buttonStyle(.pmPressable)
        .frame(width: layout.cardWidth)
        .accessibilityLabel(Text(verbatim: effect.localizedTitle))
        .accessibilityValue(Text(verbatim: effect.motionDescription))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: - 应用

    private func selectCard(_ effect: FullscreenPlayerEffect) {
        settleTask?.cancel()
        settleTask = nil

        let applies = ImmersiveEffectDrawerPolicy.shouldApply(
            currentEffectID: selection.id,
            candidateID: effect.id,
            trigger: .tapped,
            appliesOnSettle: appliesOnSettle,
            secondsSinceCenterChange: 0
        )
        if applies { selection = effect }
        pmWithAnimation(.selection) { centeredID = effect.id }
        onPick?(effect)
        if !appliesOnSettle { onClose() }
    }

    /// 居中项稳定下来才应用。滚动途中每变一次就重新计时，路过的效果不会被选中。
    private func scheduleSettle(_ candidateID: String?) {
        settleTask?.cancel()
        settleTask = nil
        guard appliesOnSettle, let candidateID, candidateID != selection.id else { return }

        settleTask = Task { @MainActor in
            let start = Date()
            do {
                try await Task.sleep(for: .seconds(ImmersiveEffectDrawerPolicy.settleDelay))
            } catch {
                return
            }
            guard !Task.isCancelled, centeredID == candidateID else { return }

            let elapsed = Date().timeIntervalSince(start)
            let applies = ImmersiveEffectDrawerPolicy.shouldApply(
                currentEffectID: selection.id,
                candidateID: candidateID,
                trigger: .settled,
                appliesOnSettle: appliesOnSettle,
                secondsSinceCenterChange: elapsed
            )
            guard applies, let match = effects.first(where: { $0.id == candidateID }) else { return }
            selection = match
        }
    }

    // MARK: - 尺寸常量

    /// 这几个值同时写在 `ImmersiveEffectDrawerPolicy` 里参与转轮长度的计算，改动要一起改。
    private static let sectionSpacing: CGFloat = 12
    private static let headerHeight: CGFloat = 44
    private static let captionHeight: CGFloat = 62
    private static let compactCaptionHeight: CGFloat = 46
    private static let cardNameHeight: CGFloat = 18
    private static let cardNameSpacing: CGFloat = 6

    private static let cardSpacing: CGFloat = 12
    private static let cardCornerRadius: CGFloat = 12
    private static let panelCornerRadius: CGFloat = 22
    private static let compactCaptionInset: CGFloat = 16
    private static let closeButtonDiameter: CGFloat = 34
}

/// 转轮的立体感：离中心越远越小、越淡，并绕垂直于滚动方向的轴转开。
///
/// 写成文件内的自由函数而不是视图方法 —— `scrollTransition` 的闭包是 `@Sendable` 的，
/// 不继承视图的 MainActor 隔离，里面调不了视图自己的成员。
/// 开启「减少动态效果」时只保留淡出与轻微缩放，不转。
private func immersiveEffectWheelEffect<Effect: VisualEffect>(
    _ content: Effect,
    phase: ScrollTransitionPhase,
    scrollsVertically: Bool,
    reduceMotion: Bool
) -> some VisualEffect {
    let distance = min(abs(phase.value), 1)
    let opacity = 1 - distance * immersiveEffectWheelFade
    let depth: CGFloat = reduceMotion ? 0.05 : 0.16
    let scale = 1 - CGFloat(distance) * depth
    let clamped = min(max(phase.value, -1), 1)
    let degrees: Double = reduceMotion ? 0 : clamped * immersiveEffectWheelRotationDegrees
    // 纵向滚动时绕水平轴转，横向滚动时绕垂直轴转。
    let axisX: CGFloat = scrollsVertically ? 1 : 0
    let axisY: CGFloat = scrollsVertically ? 0 : 1

    return content
        .opacity(opacity)
        .scaleEffect(scale)
        .rotation3DEffect(
            Angle(degrees: degrees),
            axis: (x: axisX, y: axisY, z: 0),
            perspective: immersiveEffectWheelPerspective
        )
}

private let immersiveEffectWheelFade: Double = 0.55
private let immersiveEffectWheelRotationDegrees: Double = -28
private let immersiveEffectWheelPerspective: CGFloat = 0.55

extension ImmersiveEffectDrawer {
    /// 全屏内可选的效果：按效果分组的顺序排列，并排除原生播放器 —— 在全屏里选它
    /// 等于退出全屏，不能因为转轮路过就触发，退出仍走顶部的收起按钮。
    static let fullscreenCases: [FullscreenPlayerEffect] = FullscreenEffectCollection
        .allCases
        .flatMap(\.effects)
        .filter { !$0.isNative }

    /// 抽屉从哪一边滑入。宿主的 `if` 上要挂同侧的 `pmSlideTransition`。
    static func transitionEdge(for viewportSize: CGSize) -> Edge {
        let placement = ImmersiveEffectDrawerPolicy.placement(
            viewportWidth: viewportSize.width,
            viewportHeight: viewportSize.height
        )
        switch placement {
        case .trailing: return .trailing
        case .bottom: return .bottom
        }
    }
}
#endif
