import SwiftUI

#if os(iOS)
extension View {
    /// 资料库分区页的「在本页里找」。标准界面用导航栏下面常驻的系统搜索框; 极简界面的根页
    /// 把导航栏藏了, 挂在导航栏上的搜索框跟着消失, 改在顶栏下面钉一条输入框。
    func libraryPageFind(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        modifier(LibraryPageFindModifier(text: text, prompt: prompt))
    }
}

private struct LibraryPageFindModifier: ViewModifier {
    @Binding var text: String
    let prompt: LocalizedStringKey
    @Environment(\.appNavigationMode) private var appNavigationMode
    /// 极简根页的页头给的：输入框平时收着，点页头的放大镜才出来。不在根页上时为 nil，输入框常驻。
    @Environment(MinimalPageFindState.self) private var minimalFind: MinimalPageFindState?

    private var showsMinimalField: Bool {
        guard let minimalFind else { return true }
        return minimalFind.isActive || !text.isEmpty
    }

    func body(content: Content) -> some View {
        Group {
            if appNavigationMode == .minimal {
                content
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if showsMinimalField {
                            LibraryPageFindField(
                                text: $text,
                                prompt: prompt,
                                focusesOnAppear: minimalFind?.isActive == true && text.isEmpty,
                                onDismiss: minimalFind.map { find -> () -> Void in
                                    {
                                        text = ""
                                        pmWithAnimation(.control) { find.isActive = false }
                                    }
                                }
                            )
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .onAppear { minimalFind?.register(prompt: prompt) }
            } else {
                content.searchable(
                    text: $text,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(prompt)
                )
            }
        }
        #if DEBUG
        // 编译机截图用: `PRIMUSE_DEBUG_PAGE_FIND=<词>` 打开挂了页内搜索的页面就带着这个词。
        .onAppear {
            if text.isEmpty,
               let query = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PAGE_FIND"], !query.isEmpty {
                text = query
            }
        }
        #endif
    }
}

extension View {
    /// 歌单、智能歌单详情页的「在歌单里找歌」: 平时不占地方, 点工具栏的放大镜才在导航栏下面
    /// 钉出一条输入框, 「取消」清掉查找词并收起。系统的抽屉搜索框会常驻在头部上面, 和放大镜重复。
    func libraryDetailFind(
        isPresented: Binding<Bool>,
        text: Binding<String>,
        prompt: LocalizedStringKey
    ) -> some View {
        modifier(LibraryDetailFindModifier(isPresented: isPresented, text: text, prompt: prompt))
    }
}

private struct LibraryDetailFindModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var text: String
    let prompt: LocalizedStringKey

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if isPresented || !text.isEmpty {
                LibraryPageFindField(
                    text: $text,
                    prompt: prompt,
                    focusesOnAppear: text.isEmpty,
                    onDismiss: {
                        text = ""
                        pmWithAnimation(.control) { isPresented = false }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// 极简界面与歌单详情页里的页内输入框, 样子跟顶栏的全局搜索框一致, 只是矮一点。
private struct LibraryPageFindField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    /// 从页头的放大镜拉出来的：一出现就弹键盘。
    var focusesOnAppear = false
    /// 页头收得回去时给「取消」：清掉查找词，输入框收起。
    var onDismiss: (() -> Void)?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            field
            if let onDismiss {
                Button {
                    isFocused = false
                    onDismiss()
                } label: {
                    Text("cancel")
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library.pageFind.cancel")
            }
        }
        .onAppear {
            guard focusesOnAppear else { return }
            Task { @MainActor in isFocused = true }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit { isFocused = false }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("clear"))
            }
        }
        .padding(.leading, 13)
        .padding(.trailing, text.isEmpty ? 13 : 4)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(.thinMaterial, in: Capsule())
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    isFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: isFocused ? 1.5 : 1
                )
        }
        .contentShape(Capsule())
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        .accessibilityIdentifier("library.pageFind")
    }
}
#endif

#if os(macOS)
/// Mac 资料库各页「在本页里找」的输入框。高度、圆角跟同一行的按钮走(`MacControlTier`:
/// 页头 32、工具条 26); 底色和标题栏的搜索框一样是实底, 一眼看得出是输入框而不是按钮。
/// `width` 给 nil 时撑满所在的那一栏(艺人、风格的左栏); 给了是最宽到这么宽, 窗口窄时能缩到 120,
/// 页头一排放不下时先让它让, 不把窗口撑宽(见 primuse-mac-min-width-traps)。
struct MacLibraryFindField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    var width: CGFloat? = 200
    var accessibilityIdentifier = "library.pageFind"
    @Environment(\.macControlTier) private var tier
    @FocusState private var isFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tier.cornerRadius, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(tier.textFont(weight: .regular))
                .foregroundStyle(PMColor.text)
                .focused($isFocused)
                .accessibilityLabel(Text(prompt))
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
                .help(Text("clear"))
                .accessibilityLabel(Text("clear"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: tier.height)
        .frame(
            minWidth: width.map { min($0, 120) } ?? 0,
            idealWidth: width,
            maxWidth: width ?? .infinity
        )
        .background(PMColor.bgElev, in: shape)
        .overlay {
            shape.strokeBorder(
                isFocused ? PMColor.brand.opacity(0.55) : PMColor.dividerStrong,
                lineWidth: isFocused ? 1 : 0.5
            )
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
#endif
