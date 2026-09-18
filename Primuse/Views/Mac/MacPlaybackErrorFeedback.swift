#if os(macOS)
import SwiftUI

extension View {
    func macPlaybackErrorFeedback(topInset: CGFloat = 64) -> some View {
        modifier(MacPlaybackErrorFeedbackModifier(topInset: topInset))
    }
}

private struct MacPlaybackErrorFeedbackModifier: ViewModifier {
    @Environment(AudioPlayerService.self) private var player
    let topInset: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = player.lastPlaybackError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(verbatim: message)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        player.dismissPlaybackError()
                    } label: {
                        Image(systemName: "xmark")
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("close"))
                    .help(Text("close"))
                }
                .font(.callout)
                .padding(14)
                .frame(maxWidth: 520)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                // 错误由服务层裸赋值触发, 调用点包不了动画事务, 所以把曲线附在过渡上。
                .pmSlideTransition(edge: .top, motion: .list)
            }
        }
    }
}
#endif
