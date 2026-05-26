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

    var body: some View {
        HStack(spacing: 8) {
            PMWindowTrafficLights()

            HStack(spacing: 4) {
                PMRoundBtn(icon: "chevron.left", size: 26, iconSize: 12, style: .glass,
                           help: "back") {
                    NotificationCenter.default.post(name: .primuseDetailGoBack, object: nil)
                }
                PMRoundBtn(icon: "chevron.right", size: 26, iconSize: 12, style: .glass,
                           help: "forward") {
                    NotificationCenter.default.post(name: .primuseDetailGoForward, object: nil)
                }
            }
            .padding(.leading, 8)

            Spacer(minLength: 12)

            searchBox
                .frame(width: 320, height: 26)

            Spacer(minLength: 12)

            PMRoundBtn(
                icon: sidebarCollapsed ? "sidebar.right" : "sidebar.left",
                iconSize: 13, style: .glass,
                help: "sidebar_toggle"
            ) {
                withAnimation(.easeInOut(duration: 0.22)) { sidebarCollapsed.toggle() }
            }
            PMRoundBtn(icon: "hifispeaker.2.fill", iconSize: 12, style: .glass,
                       help: "audio_output", action: onAudioOutput)
            PMRoundBtn(icon: "plus", iconSize: 13, style: .glass,
                       help: "add_source", action: onAddSource)
        }
        .padding(.horizontal, 14)
        .frame(height: PMSize.titlebar)
        .background(titlebarBackground.ignoresSafeArea(edges: .top))
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
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(mode == .glass ? PMColor.glassBtn : PMColor.matBtn)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(searchFocused ? PMColor.brand.opacity(0.55) : PMColor.cardBorder, lineWidth: 0.5)
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
        if mode == .glass {
            ZStack {
                NSVisualEffectBackdrop(material: .headerView, blending: .behindWindow)
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
