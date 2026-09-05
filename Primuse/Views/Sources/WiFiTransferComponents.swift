#if os(iOS) || os(macOS)
import SwiftUI

@MainActor
enum TransferAppearance {
    #if os(macOS)
    static let background = PMColor.bg
    static let surface = PMColor.bgElev
    static let inset = PMColor.bgDeep
    static let text = PMColor.text
    static let muted = PMColor.textMuted
    static let line = PMColor.divider
    static var accent: Color { PMColor.brand }
    static let bodySize: CGFloat = 13
    static let captionSize: CGFloat = 11.5
    static let compactTarget: CGFloat = 28
    #else
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let inset = Color(uiColor: .tertiarySystemGroupedBackground)
    static let text = Color.primary
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.09)
    static let accent = Color.accentColor
    static let bodySize: CGFloat = 15
    static let captionSize: CGFloat = 12
    static let compactTarget: CGFloat = 44
    #endif

    static func deviceIcon(_ platform: String) -> String {
        switch platform {
        case "Mac": "desktopcomputer"
        case "iPad": "ipad"
        case "Apple TV": "appletv"
        default: "iphone.gen3"
        }
    }
}

struct TransferSurface: ViewModifier {
    var padding: CGFloat = 18
    func body(content: Content) -> some View {
        content.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TransferAppearance.surface, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
    }
}

struct TransferButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: TransferAppearance.bodySize, weight: .semibold))
            .padding(.horizontal, compact ? 12 : 18)
            #if os(macOS)
            .frame(minHeight: compact ? 30 : 34)
            #else
            .frame(minHeight: 44)
            #endif
            .foregroundStyle(prominent ? Color.white : TransferAppearance.text)
            .background(prominent ? TransferAppearance.accent : TransferAppearance.line.opacity(0.6),
                        in: .rect(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(.rect)
    }
}

struct TransferSectionHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: TransferAppearance.bodySize, weight: .semibold))
                .foregroundStyle(TransferAppearance.text)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted)
            }
        }
    }
}

struct TransferFeedback: View {
    let text: String
    var isError = false
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
            .font(.system(size: TransferAppearance.captionSize))
            .foregroundStyle(isError ? Color.red : TransferAppearance.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
