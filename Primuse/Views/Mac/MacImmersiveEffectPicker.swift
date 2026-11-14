#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// macOS 的全屏效果选择面板。
///
/// 从触发它的那个按钮底下展开，不是从窗口边上推一整条抽屉进来 —— 抽屉是手机上的
/// 做法，那里没有指针，只能靠整块面板承接手势；Mac 上按钮在哪，选项就应该在哪。
/// 内容仍是真实舞台缩略图（`ImmersiveEffectPreview`），两列排开，一屏就能扫完。
///
/// 遮罩与出现动画由宿主负责：宿主才知道面板开着，要继续暂停浮动控件的自动隐藏。
struct MacImmersiveEffectPicker: View {
    let selected: FullscreenPlayerEffect
    /// 要列出的效果。分组标题按 `FullscreenEffectCollection` 的顺序排，只显示有内容的组。
    let effects: [FullscreenPlayerEffect]
    let palette: ImmersiveArtworkPalette
    let onSelect: (FullscreenPlayerEffect) -> Void
    let onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    /// 播放时屏幕常亮只在全屏画面上起作用，就地在面板底部改：只存在这台 Mac 上，不随 iCloud 同步。
    @AppStorage(ScreenIdleHoldMode.storageKey)
    private var screenIdleModeRawValue = ScreenIdleHoldMode.defaultValue.rawValue
    @State private var hoveredID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            separator
            content
            separator
            screenIdleRow
        }
        .frame(width: Self.panelWidth)
        .frame(maxHeight: Self.panelMaxHeight)
        .background { surface }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("fullscreen_effect_settings_title")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ImmersiveStagePalette.ink)
                    .lineLimit(1)
                Text(verbatim: selected.localizedTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.primary.opacity(0.92))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .pmAnimation(.control, value: selected.id)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(ImmersiveStagePalette.text.opacity(0.72))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pmPointingHand()
            .help(Text("close"))
            .accessibilityLabel(Text("close"))
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, 12)
    }

    private var separator: some View {
        Rectangle()
            .fill(ImmersiveStagePalette.ink.opacity(0.10))
            .frame(height: 1)
    }

    // MARK: - 屏幕常亮

    private var screenIdleMode: ScreenIdleHoldMode {
        ScreenIdleHoldMode(storedValue: screenIdleModeRawValue)
    }

    /// 面板底部一行：左边说是什么，右边一个弹出菜单写着眼下的档位。字号、颜色照头部那两行，
    /// 菜单的底和收起键同一种淡白圆角；拿着常亮时档位用主题色，和当前效果的名字一样。
    private var screenIdleRow: some View {
        HStack(spacing: 10) {
            Label {
                Text("screen_idle_short_title")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ImmersiveStagePalette.ink)
                    .lineLimit(1)
            } icon: {
                Image(systemName: screenIdleMode.holdsWhilePlaying ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        screenIdleMode.holdsWhilePlaying
                            ? palette.primary.opacity(0.92)
                            : ImmersiveStagePalette.text.opacity(0.62)
                    )
            }
            Spacer(minLength: 8)
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
                .labelsHidden()
            } label: {
                HStack(spacing: 5) {
                    Text(LocalizedStringKey(screenIdleMode.titleKey))
                        .font(.system(size: 11))
                        .foregroundStyle(
                            screenIdleMode.holdsWhilePlaying
                                ? palette.primary.opacity(0.92)
                                : ImmersiveStagePalette.text.opacity(0.72)
                        )
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ImmersiveStagePalette.text.opacity(0.52))
                }
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Color.white.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            // `.borderlessButton` 会丢掉自定义 label；`.button` + 透明按钮样式才照上面画。
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pmPointingHand()
            .help(Text("screen_idle_info_mac"))
            .accessibilityLabel(Text("screen_idle_short_title"))
            .accessibilityValue(Text(LocalizedStringKey(screenIdleMode.titleKey)))
            .accessibilityIdentifier("immersive.screenIdleMenu")
        }
        .padding(.horizontal, Self.contentInset)
        .padding(.vertical, 10)
    }

    // MARK: - 内容

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // 十四张卡片一次建好,不用 Lazy 容器:惰性容器会在滚动途中一行一行装载,
                // 每装一行就是一轮 SwiftUI 更新,主窗口的自定义标题栏跟着逐帧重算,
                // 左上角的红绿灯就会抖。卡片都停在静态帧,一次建好并不贵。
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.collection.id) { group in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(verbatim: group.collection.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .tracking(0.5)
                                .foregroundStyle(ImmersiveStagePalette.text.opacity(0.48))

                            ForEach(group.rows) { row in
                                HStack(alignment: .top, spacing: Self.columnSpacing) {
                                    ForEach(row.effects) { card($0) }
                                    // 落单的一张不该被拉成整行宽,补一个等宽的空位。
                                    if row.effects.count < Self.columnCount {
                                        Color.clear.frame(maxWidth: .infinity)
                                    }
                                }
                                .id(Self.rowAnchor(row.id))
                            }
                        }
                    }
                }
                .padding(.horizontal, Self.contentInset)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
            // 打开时把当前效果那一行滚到中间:两列排开也要翻好几屏,当前效果排在后面时
            // 一打开看不到它,得从「原生」往下找。只在出现时定一次位,开着时不去抢用户正在看的位置。
            .onAppear {
                guard let rowID = selectedRowID else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(Self.rowAnchor(rowID), anchor: .center)
                }
            }
        }
    }

    private func card(_ effect: FullscreenPlayerEffect) -> some View {
        let isCurrent = effect == selected
        let isHovered = hoveredID == effect.id
        return Button {
            onSelect(effect)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                // 卡片一律停在静态帧,指针划过只换描边和底色:缩略图里是完整的舞台
                // （Canvas、实时模糊），让其中一张动起来就等于指针停在面板上的整段时间
                // 窗口都在逐帧重绘。真正在动的预览是选中效果之后的全屏本身。
                ImmersiveEffectPreview(
                    effect: effect,
                    isActive: false,
                    palette: palette,
                    song: .current(player: player, library: library)
                )
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous)
                            .strokeBorder(
                                isCurrent
                                    ? palette.primary.opacity(0.92)
                                    : Color.white.opacity(isHovered ? 0.30 : 0.10),
                                lineWidth: isCurrent ? 1.6 : 0.8
                            )
                    }
                    .overlay(alignment: .topTrailing) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(palette.primary)
                                .symbolRenderingMode(.hierarchical)
                                .padding(6)
                        }
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: effect.localizedTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isCurrent ? palette.primary : ImmersiveStagePalette.ink)
                        .lineLimit(1)
                    Text(verbatim: effect.motionDescription)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ImmersiveStagePalette.text.opacity(0.52))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 缩略图自己关掉了命中测试,不补一层整卡的命中形状就只有文字那两行点得动。
            .padding(6)
            .background {
                RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius + 5, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.07 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius + 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .pmPointingHand()
        .onHover { hovering in
            if hovering {
                hoveredID = effect.id
            } else if hoveredID == effect.id {
                hoveredID = nil
            }
        }
        .accessibilityLabel(Text(verbatim: effect.localizedTitle))
        .accessibilityValue(Text(verbatim: effect.motionDescription))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var surface: some View {
        let outline = RoundedRectangle(cornerRadius: Self.panelCornerRadius, style: .continuous)
        return ZStack {
            Rectangle().fill(.ultraThinMaterial)
            ImmersiveStagePalette.obsidian.opacity(0.80)
            LinearGradient(
                colors: [
                    palette.secondary.opacity(0.42),
                    palette.primary.opacity(0.12),
                    ImmersiveStagePalette.obsidian.opacity(0.94),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .environment(\.colorScheme, .dark)
        .clipShape(outline)
        .overlay {
            outline.strokeBorder(ImmersiveStagePalette.ink.opacity(0.16), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.40), radius: 26, y: 12)
    }

    // MARK: - 分组

    private struct Row: Identifiable {
        let id: String
        let effects: [FullscreenPlayerEffect]
    }

    private struct Group {
        let collection: FullscreenEffectCollection
        let rows: [Row]
    }

    private var groups: [Group] {
        let available = Set(effects.map(\.id))
        return FullscreenEffectCollection.allCases.compactMap { collection in
            let members = collection.effects.filter { available.contains($0.id) }
            guard !members.isEmpty else { return nil }
            let rows = stride(from: 0, to: members.count, by: Self.columnCount).map { start in
                let slice = Array(members[start..<min(start + Self.columnCount, members.count)])
                return Row(id: slice.map(\.id).joined(separator: "+"), effects: slice)
            }
            return Group(collection: collection, rows: rows)
        }
    }

    /// 当前效果所在那一行；当前效果不在列表里时为 nil。
    private var selectedRowID: String? {
        for group in groups {
            if let row = group.rows.first(where: { $0.effects.contains(selected) }) {
                return row.id
            }
        }
        return nil
    }

    /// 行的滚动锚点。行 id 由效果 id 拼成,单张一行时和卡片自己的 id 撞名,加个前缀分开。
    private static func rowAnchor(_ rowID: String) -> String {
        "effect-row:" + rowID
    }

    // MARK: - 尺寸

    static let panelWidth: CGFloat = 520
    static let panelMaxHeight: CGFloat = 540
    private static let columnCount = 2
    private static let columnSpacing: CGFloat = 12
    private static let contentInset: CGFloat = 16
    private static let thumbnailCornerRadius: CGFloat = 10
    private static let panelCornerRadius: CGFloat = 16
}
#endif
