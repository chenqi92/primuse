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

    func body(content: Content) -> some View {
        Group {
            if appNavigationMode == .minimal {
                content.safeAreaInset(edge: .top, spacing: 0) {
                    LibraryPageFindField(text: $text, prompt: prompt)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                }
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

/// 极简界面里的页内输入框, 样子跟顶栏的全局搜索框一致, 只是矮一点。
private struct LibraryPageFindField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    @FocusState private var isFocused: Bool

    var body: some View {
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
/// Mac 资料库各页「在本页里找」的输入框: 和歌曲页工具条上的过滤框同一个样子。
struct MacLibraryFindField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    var width: CGFloat = 200

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
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
        .padding(.horizontal, 10)
        .frame(width: width, height: 26)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .accessibilityIdentifier("library.pageFind")
    }
}
#endif
