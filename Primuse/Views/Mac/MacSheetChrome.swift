#if os(macOS)
import SwiftUI

// MARK: - Mac 弹框 / 弹出层共用的外观
//
// 弹框(sheet)一律是: 标题行(可带图标、一行说明、右上角圆形关闭键) → 内容 → 底栏(左边说明或次要操作,
// 右边按钮)。标题 14 半粗、说明 11.5 次要色; 底栏按钮 28 高、12 号字, 主按钮铺品牌色。
// 输入框、搜索框、分段选择都是同一种 28 高的圆角底, 不再一处一个样子, 也不混着系统默认的蓝色控件。
// 弹出层(popover)的标题行照「播放设备」那一个: 13 号半粗, 左右 14 边距。

enum MacSheetMetrics {
    static let horizontalPadding: CGFloat = 20
    static let headerMinHeight: CGFloat = 56
    static let footerHeight: CGFloat = 52
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 6
    static let popoverPadding: CGFloat = 14
}

/// 弹框标题行。
struct MacSheetHeader<Accessory: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let systemImage: String?
    private let tint: Color?
    private let onBack: (() -> Void)?
    private let onClose: (() -> Void)?
    private let accessory: Accessory

    init(
        _ title: Text,
        subtitle: Text? = nil,
        systemImage: String? = nil,
        tint: Color? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.onBack = onBack
        self.onClose = onClose
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                MacSheetBackButton(action: onBack)
            }
            if let systemImage {
                let tint = tint ?? PMColor.brand
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                if let subtitle {
                    subtitle
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            accessory
            if let onClose {
                MacSheetCloseButton(action: onClose)
            }
        }
        .padding(.horizontal, MacSheetMetrics.horizontalPadding)
        .padding(.vertical, 12)
        .frame(minHeight: MacSheetMetrics.headerMinHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }
}

extension MacSheetHeader where Accessory == EmptyView {
    init(
        _ title: Text,
        subtitle: Text? = nil,
        systemImage: String? = nil,
        tint: Color? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tint: tint, onBack: onBack, onClose: onClose) {
            EmptyView()
        }
    }
}

/// 弹框里推进去的那一页, 标题行最左边的圆形返回键(和右上角的关闭键一个样子)。⌘[ 也走它。
struct MacSheetBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 26, height: 26)
                .background(PMColor.glassBtn, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help(Text("back_to_options"))
        .accessibilityLabel(Text("back_to_options"))
        .accessibilityIdentifier("macSheet.back")
    }
}

extension EnvironmentValues {
    /// 弹框带导航栈时, 根页面把收起整个弹框的动作放在这里; 推进去的页面右上角的关闭键用它
    /// (推进去的页面自己的 `dismiss` 只退回上一页)。
    @Entry var macSheetDismiss: DismissAction? = nil
}

extension Optional where Wrapped == DismissAction {
    /// 交给 `MacSheetHeader(onClose:)` 的闭包; 没有可收起的弹框时是 nil, 标题行就不画关闭键。
    var macCloseAction: (() -> Void)? {
        map { action in { action() } }
    }
}

/// 弹框右上角的圆形关闭键。Esc 也走它 —— 底栏已经有一颗占着 Esc 的按钮(「返回」这一类)时传 false。
struct MacSheetCloseButton: View {
    var handlesEscape = true
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 26, height: 26)
                .background(PMColor.glassBtn, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .keyboardShortcut(handlesEscape ? .cancelAction : nil)
        .help(Text("close"))
        .accessibilityLabel(Text("close"))
    }
}

/// 弹框底栏: 左边放说明或次要操作, 右边放按钮。
struct MacSheetFooter<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, MacSheetMetrics.horizontalPadding)
        .frame(minHeight: MacSheetMetrics.footerHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }
}

extension MacSheetFooter where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

/// 弹框里的按钮: 主按钮铺品牌色(或传进来的空间色), 次要按钮是浅底细边, 危险操作是红字。
struct MacSheetButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, plain }

    var kind: Kind = .secondary
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        MacSheetButtonBody(configuration: configuration, kind: kind, tint: tint)
    }
}

private struct MacSheetButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: MacSheetButtonStyle.Kind
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.self) private var environment

    var body: some View {
        configuration.label
            .labelStyle(MacSheetButtonLabelStyle())
            .font(.system(size: 12, weight: kind == .primary ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, kind == .plain ? 8 : 14)
            .frame(height: MacSheetMetrics.controlHeight)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: MacSheetMetrics.controlRadius, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: MacSheetMetrics.controlRadius, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
            }
            .opacity(configuration.isPressed ? 0.72 : (isEnabled || kind == .primary ? 1 : 0.45))
            .contentShape(.rect)
    }

    private var foreground: Color {
        switch kind {
        // 底色太浅(深色模式下的有声书薄荷绿这一类)时换黑字, 和 `prominentLabelOnAccent` 同一个判断。
        case .primary: isEnabled
            ? (ThemeService.isTooLightForWhiteText(tint ?? PMColor.brand, in: environment) ? .black : .white)
            : PMColor.textFaint
        case .secondary: PMColor.text
        case .destructive: PMColor.bad
        case .plain: tint ?? PMColor.brand
        }
    }

    private var background: Color {
        switch kind {
        case .primary: isEnabled ? (tint ?? PMColor.brand) : PMColor.glassBtn
        case .secondary: PMColor.glassBtn
        case .destructive, .plain: .clear
        }
    }
}

private struct MacSheetButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == MacSheetButtonStyle {
    static var macSheet: MacSheetButtonStyle { MacSheetButtonStyle() }
    static var macSheetPrimary: MacSheetButtonStyle { MacSheetButtonStyle(kind: .primary) }
    static var macSheetDestructive: MacSheetButtonStyle { MacSheetButtonStyle(kind: .destructive) }

    static func macSheetPrimary(tint: Color?) -> MacSheetButtonStyle {
        MacSheetButtonStyle(kind: .primary, tint: tint)
    }

    /// 只有字、没有底的轻按钮(「全选」「清空」这一类)。
    static func macSheetText(tint: Color? = nil) -> MacSheetButtonStyle {
        MacSheetButtonStyle(kind: .plain, tint: tint)
    }
}

/// 分组小标题(大写、浅色), 和「播放设备」弹出层里的「局域网设备」一个样子。
struct MacSheetSectionLabel: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim: String) { text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
            .lineLimit(1)
    }
}

/// 输入框上面的字段名(不转大写, 句子式的名字也读得顺)。
struct MacSheetFieldLabel: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim: String) { text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(PMColor.textMuted)
            .lineLimit(1)
    }
}

/// 弹框里输入框的底: 28 高、浅底细边, 获得焦点时描一圈主题色。
struct MacSheetFieldChrome: ViewModifier {
    var isFocused = false
    var tint: Color? = nil

    func body(content: Content) -> some View {
        // 不设前景色: 设了会连提示字一起染成正文色, 空输入框看着像已经填了值; 系统的正文色和 PMColor.text 一样。
        content
            .textFieldStyle(.plain)
            // 放在分组表单里时系统会把输入框里的字靠右排; 弹框里的输入框一律靠左。
            .multilineTextAlignment(.leading)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(minHeight: MacSheetMetrics.controlHeight)
            .background(PMColor.bgElev, in: .rect(cornerRadius: MacSheetMetrics.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MacSheetMetrics.controlRadius, style: .continuous)
                    .strokeBorder(
                        isFocused ? (tint ?? PMColor.brand).opacity(0.75) : PMColor.dividerStrong,
                        lineWidth: isFocused ? 1 : 0.5
                    )
            }
            .pmAnimation(.hover, value: isFocused)
    }
}

extension View {
    func macSheetField(isFocused: Bool = false, tint: Color? = nil) -> some View {
        modifier(MacSheetFieldChrome(isFocused: isFocused, tint: tint))
    }
}

/// 弹框里的搜索框。
struct MacSheetSearchField: View {
    @Binding var text: String
    let prompt: Text
    var tint: Color? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            // 提示字要压成浅色: 输入框的前景色会连提示字一起染成正文色, 看着像已经填了值。
            TextField("", text: $text, prompt: prompt.foregroundStyle(PMColor.textFaint))
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("clear"))
            }
        }
        .macSheetField(isFocused: isFocused, tint: tint)
    }
}

/// 弹框里的分段选择(发送 / 接收 这一类): 浅底上一块抬起的白底标出选中项,
/// 和资料库页里的分段切换同一个做法, 不用系统那种蓝色高亮的分段控件。
struct MacSheetSegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var systemImage: String? = nil
        var id: Value { value }
    }

    @Binding var selection: Value
    let segments: [Segment]
    /// 铺满给的宽度、各段等分(放在窄弹出层里用); 默认按字的宽度收紧。
    var fillsWidth = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = segment.value == selection
                Button {
                    selection = segment.value
                } label: {
                    HStack(spacing: 5) {
                        if let systemImage = segment.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        Text(verbatim: segment.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(fillsWidth ? 0.8 : 1)
                    }
                    .foregroundStyle(isSelected ? PMColor.text : PMColor.textMuted)
                    .padding(.horizontal, fillsWidth ? 6 : 12)
                    .frame(minWidth: fillsWidth ? 0 : 64, maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: MacSheetMetrics.controlHeight - 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: MacSheetMetrics.controlRadius - 1, style: .continuous)
                                .fill(PMColor.bgElev)
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: MacSheetMetrics.controlRadius + 1, style: .continuous))
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .pmAnimation(.hover, value: selection)
    }
}

extension View {
    /// 和 iOS 共用的「表单 + 导航标题 + 工具栏」面板在 Mac 上的外观: 标题行 → 表单 → 底栏按钮。
    /// Mac 弹框里导航标题不显示, 工具栏的取消 / 确认会被系统摆到底下、还是系统蓝的按钮,
    /// 所以这些面板在 Mac 上不挂 `.navigationTitle` / `.toolbar`, 改挂这个。
    func macFormSheet<Leading: View, Trailing: View>(
        title: Text,
        subtitle: Text? = nil,
        systemImage: String? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            MacSheetHeader(title, subtitle: subtitle, systemImage: systemImage, onBack: onBack, onClose: onClose)
            self
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            MacSheetFooter(leading: leading, trailing: trailing)
        }
        .background(PMColor.bg)
        .tint(PMColor.brand)
        // 推进去的页面自己画返回键; 万一系统也给一个, 藏掉。
        .navigationBarBackButtonHidden(onBack != nil)
    }

    func macFormSheet<Trailing: View>(
        title: Text,
        subtitle: Text? = nil,
        systemImage: String? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        macFormSheet(
            title: title, subtitle: subtitle, systemImage: systemImage, onBack: onBack, onClose: onClose,
            leading: { EmptyView() }, trailing: trailing
        )
    }

    /// 同上, 但没有底栏: 列表一类改了就生效、只需要关掉的页面。
    func macSheetPage(
        title: Text,
        subtitle: Text? = nil,
        systemImage: String? = nil,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            MacSheetHeader(title, subtitle: subtitle, systemImage: systemImage, onBack: onBack, onClose: onClose)
            self
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
        }
        .background(PMColor.bg)
        .tint(PMColor.brand)
        .navigationBarBackButtonHidden(onBack != nil)
    }
}

/// 弹出层标题行, 照「播放设备」弹出层: 13 号半粗, 右边可以挂一个小按钮。
struct MacPopoverHeader<Accessory: View>: View {
    private let title: Text
    private let accessory: Accessory

    init(_ title: Text, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 8) {
            title
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, MacSheetMetrics.popoverPadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

extension MacPopoverHeader where Accessory == EmptyView {
    init(_ title: Text) {
        self.init(title) { EmptyView() }
    }
}
#endif
