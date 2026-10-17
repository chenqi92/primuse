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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: message)
                            .fixedSize(horizontal: false, vertical: true)
                        // 整个来源放不了、正在倒数跳过时:可以留在这首,也可以不等了。
                        if player.pendingSourceSkip != nil {
                            HStack(spacing: 8) {
                                Button("cancel") { player.cancelPendingSourceSkip() }
                                Button("source_skip_now") { player.skipUnavailableSourceNow() }
                            }
                            .controlSize(.small)
                        }
                    }
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
