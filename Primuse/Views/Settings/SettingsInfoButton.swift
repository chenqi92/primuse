import SwiftUI

/// 设置项的说明收进一个圈问号:点开才以气泡显示,不再让一段段 footer 把设置页撑长。
/// 有标题的分区挂在标题旁(`SettingsInfoHeader`),没有标题的挂在开关/选项名旁(`SettingsInfoLabel`)。
/// 权限被拒、出错、正在进行这类必须一眼看到的状态别收进来,仍放 footer。
struct SettingsInfoButton<Message: View>: View {
    private let message: Message
    @State private var isPresented = false

    init(@ViewBuilder message: () -> Message) {
        self.message = message()
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                // 图标只有一个字高,命中区往外补到够手指点,布局尺寸不变。
                .padding(8)
                .contentShape(Rectangle())
                .padding(-8)
        }
        // 放在列表行里也只认图标本身,不把整行变成按钮、不抢开关和选择器的点击。
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("settings_info_button"))
        .popover(isPresented: $isPresented) {
            SettingsInfoBubble { message }
                .presentationCompactAdaptation(.popover)
        }
        #if DEBUG
        .task {
            guard SettingsInfoDebugAutomation.claimAutoOpen() else { return }
            try? await Task.sleep(for: .seconds(1))
            isPresented = true
        }
        #endif
    }
}

/// 分区标题 + 圈问号。
struct SettingsInfoHeader<Message: View>: View {
    private let title: Text
    private let message: Message

    init(_ titleKey: LocalizedStringKey, @ViewBuilder message: () -> Message) {
        self.title = Text(titleKey)
        self.message = message()
    }

    init(verbatim title: String, @ViewBuilder message: () -> Message) {
        self.title = Text(verbatim: title)
        self.message = message()
    }

    var body: some View {
        HStack(spacing: 4) {
            title
            SettingsInfoButton { message }
        }
    }
}

/// 开关/选项名 + 圈问号,用作 `Toggle`、`Picker` 的 label。
struct SettingsInfoLabel<Message: View>: View {
    private let title: Text
    private let message: Message

    init(_ titleKey: LocalizedStringKey, @ViewBuilder message: () -> Message) {
        self.title = Text(titleKey)
        self.message = message()
    }

    init(verbatim title: String, @ViewBuilder message: () -> Message) {
        self.title = Text(verbatim: title)
        self.message = message()
    }

    var body: some View {
        HStack(spacing: 6) {
            title
            SettingsInfoButton { message }
        }
    }
}

private struct SettingsInfoBubble<Message: View>: View {
    @ViewBuilder let message: Message
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                message
            }
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // 定宽让长段说明折行;高度按量出来的内容定,大字号超过上限才滚动。
        .frame(width: 320, height: contentHeight.map { min($0, 460) })
    }
}

#if DEBUG
/// 取证用:启动时带 `PRIMUSE_DEBUG_SETTINGS_INFO=1`,进设置页后第一个出现的圈问号自动打开。
@MainActor
enum SettingsInfoDebugAutomation {
    private static let isEnabled =
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SETTINGS_INFO"] == "1"
    private static var hasOpened = false

    static func claimAutoOpen() -> Bool {
        guard isEnabled, !hasOpened else { return false }
        hasOpened = true
        return true
    }
}
#endif
