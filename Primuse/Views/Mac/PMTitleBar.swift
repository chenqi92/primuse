#if os(macOS)
import SwiftUI
import PrimuseKit

/// 主窗口顶部 44pt 自定义 title bar — 跟设计稿里的 TitleBar 对齐:
/// 三色窗口控制点、左右导航、居中搜索、右侧工具按钮。
struct PMTitleBar: View {
    @Binding var searchText: String
    @Binding var sidebarCollapsed: Bool
    @Binding var selection: MacRoute
    var onAddSource: () -> Void = {}
    var onAudioOutput: () -> Void = {}

    @Environment(\.pmAppearance) private var mode
    @FocusState private var searchFocused: Bool
    /// titlebar 右上喇叭按钮的 popover 显示状态 — 设计稿 P-21 Output Picker。
    /// 之前 onAudioOutput 是空 callback 让点击没反应; 现在把 popover 直接挂在
    /// 按钮上, 点击就弹真 AudioOutputPickerView。
    @State private var audioOutputShown = false

    var body: some View {
        HStack(spacing: 8) {
            PMWindowTrafficLights()

            Spacer(minLength: 12)

            // 设计稿对比: 搜索框比当前版本更窄 + 更高 (高/宽比约 30/25 = 1.2x)。
            // idealWidth 收到 320, maxWidth 380, 高度提到 36 让上下 padding 更松,
            // 视觉比例接近设计图。
            searchBox
                .frame(minWidth: 240, idealWidth: 320, maxWidth: 380)
                .frame(height: 36)

            Spacer(minLength: 12)

            PMRoundBtn(
                icon: sidebarCollapsed ? "sidebar.right" : "sidebar.left",
                iconSize: 13, style: .glass,
                help: "sidebar_toggle"
            ) {
                withAnimation(.easeInOut(duration: 0.22)) { sidebarCollapsed.toggle() }
            }
            PMRoundBtn(icon: "hifispeaker.2.fill", iconSize: 12, style: .glass,
                       help: "audio_output") {
                audioOutputShown.toggle()
                onAudioOutput()
            }
            .popover(isPresented: $audioOutputShown, arrowEdge: .top) {
                // AudioOutputPickerView 自己 frame(width: 280), 系统 popover 自动
                // 配合内容尺寸。不再额外加 padding/frame, 避免跟系统 chrome 重叠。
                AudioOutputPickerView()
            }
            PMRoundBtn(icon: "plus", iconSize: 13, style: .glass,
                       help: "add_source", action: onAddSource)
        }
        .padding(.horizontal, 14)
        .frame(height: PMSize.titlebar)
        .background(titlebarBackground.ignoresSafeArea(edges: .top))
        .pmWindowDragRegion()
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    // MARK: - Search box

    private var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PMColor.textFaint)

            TextField("", text: $searchText, prompt: Text("search_placeholder_universal"))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.text)
                .focused($searchFocused)
                .onSubmit {
                    if !searchText.isEmpty { selectSearchRoute() }
                }
                .onChange(of: searchText) { _, value in
                    if !value.isEmpty, !isOnSearch {
                        selectSearchRoute()
                    }
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: "⌘F")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            // 设计稿 TitleBar 里搜索框是 *实白* 填充 (bg-elev), 不是玻璃覆盖 —
            // 之前用 glassBtn 半透黑叠在米色 titlebar 上呈现粉桃色, 跟设计稿不一致。
            // 圆角降到 7 (设计稿是接近矩形的圆角胶囊, 不是大圆 pill); 描边只在 focus
            // 时上 brand 高亮, 平时用极淡 divider 描一圈。
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(PMColor.bgElev)
                .shadow(color: Color.black.opacity(0.06), radius: 1, y: 0.5)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    searchFocused
                        ? PMColor.brand.opacity(0.55)
                        : PMColor.divider.opacity(0.6),
                    lineWidth: 0.5
                )
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseFocusSearch)) { _ in
            searchFocused = true
            selectSearchRoute()
        }
    }

    private var isOnSearch: Bool {
        if case .search = selection { return true }
        return false
    }

    @ViewBuilder
    private var titlebarBackground: some View {
        // 设计稿: TitleBar 背景 = var(--pm-bg) (浅色: #F6F4EF 米色, 深色: #1A1715) +
        // rgba(255,255,255,.04) 微亮覆盖, 跟整窗 bg 同色调。之前用 .headerView material
        // 会去 blend 窗外内容, 在浅色系统上偏纯白, 跟整窗米色 bg 不一致, 顶部看着像「贴
        // 了块白条」。直接用 PMColor.bg 实色就跟下面 detail 区无缝接上。
        if mode == .glass {
            ZStack {
                Rectangle().fill(PMColor.bg)
                Rectangle().fill(Color.white.opacity(0.04))
            }
        } else {
            Rectangle().fill(PMColor.bg)
        }
    }

    private func selectSearchRoute() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = .search
        }
    }
}

extension Notification.Name {
    static let primuseDetailGoBack    = Notification.Name("primuse.detail.goBack")
    static let primuseDetailGoForward = Notification.Name("primuse.detail.goForward")
    static let primuseFocusSearch     = Notification.Name("primuse.titlebar.focusSearch")
}

#endif
