#if os(iOS) || os(macOS)
import SwiftUI
import PrimuseKit

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

struct TransferReceiveReceiptView: View {
    let receipt: WiFiTransferReceipt
    var indexing = false
    var indexError: String?
    @State private var expanded = false

    private var status: String {
        receipt.finished ? (receipt.succeeded ? "receiveCompleted" : "receiveInterrupted") : "receiving"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: receipt.finished ? (receipt.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle") : "arrow.down.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(receipt.finished && !receipt.succeeded ? Color.orange : TransferAppearance.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(WiFiTransferText.string(status))
                        .font(.system(size: TransferAppearance.bodySize + 3, weight: .semibold))
                    Text(receipt.sender ?? WiFiTransferText.string("browserSender"))
                        .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Text(String(format: WiFiTransferText.string("receiveCount"), receipt.completed, receipt.fileCount))
                    .font(.system(size: TransferAppearance.bodySize, weight: .semibold)).monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            if !receipt.finished {
                ProgressView(value: receipt.progress).tint(TransferAppearance.accent)
                    .accessibilityLabel(WiFiTransferText.string("receiving"))
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: receipt.receivedBytes, countStyle: .file)
                         + " / " + ByteCountFormatter.string(fromByteCount: receipt.byteCount, countStyle: .file))
                    Spacer()
                    Text(receipt.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }.font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                if let file = receipt.files.last(where: { !$0.finished }) {
                    Text(file.path).font(.system(size: TransferAppearance.bodySize))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(WiFiTransferText.string("receiveWaitingFiles"))
                        .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                }
            }
            if let error = receipt.error {
                TransferFeedback(text: WiFiTransferText.string(error), isError: true)
            }
            if receipt.completed > 0 {
                if indexing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(WiFiTransferText.string("indexing")).font(.system(size: TransferAppearance.captionSize))
                    }
                } else if indexError == nil {
                    TransferFeedback(text: WiFiTransferText.string("receiveStored"))
                }
            }
            if !receipt.files.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(receipt.files.suffix(20)) { file in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: file.finished ? (file.succeeded ? "checkmark.circle" : "exclamationmark.circle") : "arrow.down.circle")
                                    .foregroundStyle(file.error == nil ? TransferAppearance.accent : Color.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(file.path).lineLimit(2).truncationMode(.middle)
                                    Text(file.error.map(WiFiTransferText.string)
                                         ?? ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .foregroundStyle(TransferAppearance.muted)
                                }
                            }.font(.system(size: TransferAppearance.captionSize))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if receipt.files.count > 20 {
                            Text(WiFiTransferText.string("receiveRecentFiles"))
                                .font(.system(size: TransferAppearance.captionSize)).foregroundStyle(TransferAppearance.muted)
                        }
                    }.padding(.top, 12)
                } label: {
                    Text(WiFiTransferText.string("receiveFileDetails"))
                        .font(.system(size: TransferAppearance.bodySize, weight: .medium))
                        .frame(minHeight: TransferAppearance.compactTarget, alignment: .leading)
                }.tint(TransferAppearance.accent)
            }
        }.modifier(TransferSurface())
            .accessibilityIdentifier("wifiTransfer.receipt.\(receipt.id)")
    }
}
#endif
