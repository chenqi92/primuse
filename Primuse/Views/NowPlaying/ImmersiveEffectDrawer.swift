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
///
/// 转轮首尾相接：清单排三遍，平时停在中间那一遍，滚停在前后两遍里就悄悄换回中间那遍的同一张
/// （格子换算见 `ImmersiveEffectWheelLoop`）。打开时停在当前效果上，不用从第一张一张张翻过去。
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
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    /// 播放时屏幕常亮只在全屏画面上起作用，就地在这里改：只存在这台设备上，不随 iCloud 同步。
    @AppStorage(ScreenIdleHoldMode.storageKey)
    private var screenIdleModeRawValue = ScreenIdleHoldMode.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.playerScreenWakeRequiresChargingKey)
    private var screenWakeRequiresCharging = PlayerAppearancePreferences.playerScreenWakeRequiresChargingByDefault
    /// 停在转轮正中的那一格（三遍连着数，见 `ImmersiveEffectWheelLoop`）。
    @State private var centeredSlot: Int?
    @State private var settleTask: Task<Void, Never>?
    /// 转轮第一次出现时已经按打开时的那一格摆好；之后再出现（转屏换了横竖转轮）就按当时停着的那格摆。
    @State private var hasPlacedWheel = false
    private let loop: ImmersiveEffectWheelLoop
    /// 打开时停的那一格：中间那一遍里的当前效果。
    private let initialSlot: Int?
    /// 每一格排第几个换上真实画面(从打开时停着的那格往两边排)。
    private let previewSequence: [Int]

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
        // 打开时就停在当前效果上（中间那一遍里的那张）。初值放在 init 里，转轮第一次布局就能就位；
        // 出现时再按格子明确滚一次（`placeWheel`），初值没被照着滚过去也不会停在第一张上。
        let initialCenterID = ImmersiveEffectDrawerPolicy.initialCenterID(
            effectIDs: effects.map(\.id),
            currentID: selection.wrappedValue.id
        )
        let initialItem = effects.firstIndex { $0.id == initialCenterID } ?? 0
        let loop = ImmersiveEffectWheelLoop(itemCount: effects.count)
        let initialSlot = loop.homeSlot(forItem: initialItem)
        self.loop = loop
        self.initialSlot = initialSlot
        _centeredSlot = State(initialValue: initialSlot)
        previewSequence = loop.previewSequence(centerItem: initialItem)
    }

    var body: some View {
        let layout = drawerLayout
        return panel(layout: layout)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(layout.placement))
            .sensoryFeedback(.selection, trigger: selection)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onClose)
            .onChange(of: centeredSlot) { oldSlot, newSlot in
                // 滚停后换回中间那一遍时效果没变：正在等的那次应用照旧算数，不重新计时。
                let candidate = effect(atSlot: newSlot)
                guard candidate != effect(atSlot: oldSlot) else { return }
                scheduleSettle(candidate?.id)
            }
            .onDisappear {
                settleTask?.cancel()
                settleTask = nil
            }
            #if DEBUG
            .task {
                // 取证:`PRIMUSE_DEBUG_EFFECT_DRAWER_SWEEP=1` 打开后转轮往后挨张转一整圈再倒回来,录屏看卡片滑进来时
                // 是不是已经画好、转过首尾相接处停稳后换回中间那一遍时有没有跳(模拟器上没法用手指划)。
                guard ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_EFFECT_DRAWER_SWEEP"] == "1" else { return }
                try? await Task.sleep(for: .seconds(0.4))
                let steps = Array(repeating: 1, count: effects.count) + Array(repeating: -1, count: effects.count)
                for step in steps {
                    guard !Task.isCancelled, let slot = centeredSlot ?? initialSlot else { return }
                    let next = min(max(slot + step, 0), loop.slotCount - 1)
                    withAnimation(.easeInOut(duration: 0.35)) { centeredSlot = next }
                    try? await Task.sleep(for: .seconds(0.45))
                }
            }
            #endif
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
            screenIdleMenu
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
        .pmAnimation(.control, value: centeredEffect.id)
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
            .pmAnimation(.control, value: centeredEffect.id)

            Spacer(minLength: 8)
            screenIdleMenu
            closeButton
        }
        .padding(.horizontal, Self.compactCaptionInset)
        .frame(height: Self.compactCaptionHeight)
    }

    private var screenIdleMode: ScreenIdleHoldMode {
        ScreenIdleHoldMode(storedValue: screenIdleModeRawValue)
    }

    /// 播放时屏幕常亮的菜单。和收起键同一种玻璃圆钮、并排放在抽屉顶上，不另占一行，也不在全屏控件里
    /// 多挂一颗常驻的键：这是偶尔改一次的设置，和换效果放在同一处最好找。拿着常亮时圆钮亮起。
    private var screenIdleMenu: some View {
        Menu {
            Picker("screen_idle_short_title", selection: Binding(
                get: { screenIdleMode },
                set: { mode in
                    screenIdleModeRawValue = mode.rawValue
                    ScreenIdleHoldController.shared.settingsDidChange()
                }
            )) {
                ForEach(ScreenIdleHoldMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                }
            }
            .pickerStyle(.inline)
            if screenIdleMode.holdsWhilePlaying {
                Section {
                    Toggle("player_keep_screen_awake_charging_only_title", isOn: Binding(
                        get: { screenWakeRequiresCharging },
                        set: { value in
                            screenWakeRequiresCharging = value
                            ScreenIdleHoldController.shared.settingsDidChange()
                        }
                    ))
                }
            }
        } label: {
            // 亮起时和转轮里当前那张卡同一个颜色。
            ImmersiveGlassActionLabel(
                symbol: screenIdleMode.holdsWhilePlaying ? "sun.max.fill" : "sun.max",
                tint: screenIdleMode.holdsWhilePlaying ? palette.primary : ImmersiveStagePalette.ink,
                diameter: Self.closeButtonDiameter,
                isSelected: screenIdleMode.holdsWhilePlaying
            )
        }
        .accessibilityLabel(Text("screen_idle_short_title"))
        .accessibilityValue(Text(LocalizedStringKey(screenIdleMode.titleKey)))
        .accessibilityIdentifier("immersive.screenIdleMenu")
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
        effect(atSlot: centeredSlot) ?? selection
    }

    /// 第几格是哪种效果。三遍里同一种效果各占一格。
    private func effect(atSlot slot: Int?) -> FullscreenPlayerEffect? {
        guard let slot, let index = loop.itemIndex(forSlot: slot), effects.indices.contains(index) else {
            return nil
        }
        return effects[index]
    }

    // MARK: - 转轮

    /// 卡片一次全建好、不用惰性容器:惰性容器滑到才建,建一张那一帧就卡一下,卡片是「闪」出来的。
    /// 全建好时重的只是真实画面,由 `ImmersiveEffectThumbnail` 排着队换上,打开那一下只画占位。
    /// 首尾相接要把清单排三遍,卡片也是三遍的数目;真实画面照样排队,离停着那格越远越晚换上。
    private var wheelSlots: Range<Int> {
        0..<loop.slotCount
    }

    private func verticalWheel(layout: ImmersiveEffectDrawerLayout) -> some View {
        // scrollTransition 的闭包是 @Sendable 的，读不到 @MainActor 的视图成员，
        // 所以先把要用到的环境取成局部值，闭包里只调用文件内的自由函数。
        let reducesMotion = reduceMotion
        return wheelScroller(vertical: true, margin: layout.wheelMargin) {
            VStack(spacing: Self.cardSpacing) {
                ForEach(wheelSlots, id: \.self) { slot in
                    card(atSlot: slot, layout: layout)
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
        }
    }

    private func horizontalWheel(layout: ImmersiveEffectDrawerLayout) -> some View {
        let reducesMotion = reduceMotion
        return wheelScroller(vertical: false, margin: layout.wheelMargin) {
            HStack(spacing: Self.cardSpacing) {
                ForEach(wheelSlots, id: \.self) { slot in
                    card(atSlot: slot, layout: layout)
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
        }
    }

    /// 两个方向的转轮共用的滚动行为：居中那格跟着 `centeredSlot` 走、按卡片对齐停下，
    /// 出现时摆到该停的那格，滚停在前后两遍里就换回中间那一遍。
    private func wheelScroller<Cards: View>(
        vertical: Bool,
        margin: CGFloat,
        @ViewBuilder cards: () -> Cards
    ) -> some View {
        let stack = cards()
        let axis: Axis.Set = vertical ? .vertical : .horizontal
        let marginEdges: Edge.Set = vertical ? .vertical : .horizontal
        return ScrollViewReader { proxy in
            ScrollView(axis, showsIndicators: false) {
                stack
                    .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredSlot, anchor: .center)
            .contentMargins(marginEdges, margin, for: .scrollContent)
            .onScrollPhaseChange { _, phase in
                guard phase == .idle else { return }
                recenterOnHomeCopy(proxy)
            }
            .onAppear { placeWheel(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 转轮出现时摆到该停的那一格：第一次是打开时的当前效果，之后（转屏换了横竖转轮）是当时停着的那格。
    ///
    /// `scrollPosition` 的初值不一定会被第一次布局照着滚过去，那样转轮就停在第一张「原生」上，
    /// 得从头一张张翻回当前效果；这里按格子明确滚一次。本来就停在那格时什么也不变，不会先显示第一张再跳。
    private func placeWheel(_ proxy: ScrollViewProxy) {
        let target = hasPlacedWheel ? (centeredSlot ?? initialSlot) : initialSlot
        hasPlacedWheel = true
        guard let target else { return }
        jumpWheel(to: target, proxy: proxy)
    }

    /// 滚停在前后两遍里时，换回中间那一遍的同一张：卡片一模一样，不加动画看不出换过，
    /// 下一次滑动前后又各有一整遍的余量。
    private func recenterOnHomeCopy(_ proxy: ScrollViewProxy) {
        guard let slot = centeredSlot, let home = loop.recenteredSlot(for: slot) else { return }
        jumpWheel(to: home, proxy: proxy)
    }

    /// 不加动画地把某一格摆到正中。滚动位置和滚动本身一起改：只改位置时第一次布局可能不照着滚，
    /// 只滚不改位置时说明文字要等滚动回报才跟上。
    private func jumpWheel(to slot: Int, proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            centeredSlot = slot
            proxy.scrollTo(slot, anchor: .center)
        }
    }

    private func card(atSlot slot: Int, layout: ImmersiveEffectDrawerLayout) -> some View {
        let shown = effect(atSlot: slot) ?? selection
        let sequence = previewSequence.indices.contains(slot) ? previewSequence[slot] : slot
        return card(shown, slot: slot, sequence: sequence, layout: layout)
            // 前后两遍只是转圈用的替身：朗读只念中间那一遍，同一种效果不会被念三次。
            .accessibilityHidden(!loop.isHomeSlot(slot))
            // 和 ForEach 给的身份同一个值，写明了 `ScrollViewProxy.scrollTo` 才稳稳找得到这一格。
            .id(slot)
    }

    private func card(
        _ effect: FullscreenPlayerEffect,
        slot: Int,
        sequence: Int,
        layout: ImmersiveEffectDrawerLayout
    ) -> some View {
        let isCurrent = effect == selection
        return Button {
            selectCard(effect, slot: slot)
        } label: {
            VStack(spacing: Self.cardNameSpacing) {
                ImmersiveEffectThumbnail(
                    effect: effect,
                    palette: palette,
                    sequence: sequence,
                    // 等抽屉滑入放完再开始换,别和滑入抢主线程。
                    startDelay: PMMotion.panel.settleDuration + 0.02,
                    song: .current(player: player, library: library)
                )
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

    /// `slot` 是点中的那一格：点了前后两遍里露出来的那张，就滚到那一格，停稳后再换回中间那一遍。
    private func selectCard(_ effect: FullscreenPlayerEffect, slot: Int) {
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
        pmWithAnimation(.selection) { centeredSlot = slot }
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
            // 比的是效果不是格子：等的时候换回了中间那一遍，仍是同一种效果。
            guard !Task.isCancelled, effect(atSlot: centeredSlot)?.id == candidateID else { return }

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
    /// 手机的普通全屏歌词也必须能从效果面板切回。按分组排，和捏合换效果（`advanced(by:)`）同一个顺序。
    static let fullscreenCases: [FullscreenPlayerEffect] = FullscreenPlayerEffect.groupedCases

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

/// 全屏效果的缩略卡画面(效果抽屉、转轮舞台面共用):先放同色调的占位,真实舞台的静止一帧排着队挂上、淡入。
///
/// 真实画面是整套舞台按 960×540 建好再缩小,一张就要几十毫秒。几张一起建会卡住正在放的滑入或转动,
/// 滑到才建会让卡片一张张「闪」出来;排着队一张接一张换上,每次只多建一张。已经换上的不再撤回。
struct ImmersiveEffectThumbnail: View {
    let effect: FullscreenPlayerEffect
    let palette: ImmersiveArtworkPalette
    /// 排第几个换上真实画面,0 最先。
    let sequence: Int
    /// 从可以开始换起再等多久(秒):等抽屉滑入、转轮转停这类正在放的动画放完。
    var startDelay: TimeInterval = 0
    /// false 时只放占位、不开始排(转轮还在转)。
    var isEnabled = true
    var song: ImmersivePreviewSong? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPreview = false

    /// 相邻两张换上的间隔。
    private static let step: TimeInterval = 0.05

    var body: some View {
        ZStack {
            placeholder
            if showsPreview {
                ImmersiveEffectPreview(
                    effect: effect,
                    isActive: false,
                    palette: palette,
                    song: song
                )
                .transition(.opacity)
            }
        }
        .task(id: isEnabled) {
            guard isEnabled, !showsPreview else { return }
            let delay = startDelay + Double(max(sequence, 0)) * Self.step
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                showsPreview = true
            }
        }
    }

    /// 和舞台一样的深底,叠一层压暗的主题色与效果图标。
    private var placeholder: some View {
        ZStack {
            ImmersiveStagePalette.obsidian
            LinearGradient(
                colors: [palette.primary.opacity(0.42), palette.secondary.opacity(0.26)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: effect.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
