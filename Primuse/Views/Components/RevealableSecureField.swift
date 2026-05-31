import SwiftUI

struct RevealableSecureField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    #if os(iOS)
    var textContentType: UITextContentType? = .password
    #endif
    // 默认不显示「建议使用英文/半角」键盘提示 —— 它在每个密码/密钥字段里重复
    // 出现, 噪音大且帮助有限。需要时调用处显式传 `showsKeyboardHint: true`。
    var showsKeyboardHint = false

    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if isRevealed {
                        TextField(title, text: $text)
                    } else {
                        SecureField(title, text: $text)
                    }
                }
                #if os(iOS)
                .textContentType(textContentType)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #else
                .textContentType(.password)
                .autocorrectionDisabled()
                #endif

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? Text("password_hide") : Text("password_show"))
            }

            if showsKeyboardHint {
                Label("password_ascii_hint", systemImage: "keyboard")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
