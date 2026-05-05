import SwiftUI

struct RevealableSecureField: View {
    let title: LocalizedStringKey
    @Binding var text: String
    var textContentType: UITextContentType? = .password
    var showsKeyboardHint = true

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
                .textContentType(textContentType)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

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
