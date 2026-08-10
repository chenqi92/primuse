import SwiftUI

extension View {
    /// 批量删除的进度和结果提示。删网盘上的文件可能要几十秒，用户需要看得见
    /// 进展；结果提示则必须活过发起它的那个页面（选择模式在提交瞬间就退出了），
    /// 所以这个 modifier 挂在根视图上，全 app 一份。
    func songBatchRemovalFeedback() -> some View {
        modifier(SongBatchRemovalFeedbackModifier())
    }
}

private struct SongBatchRemovalFeedbackModifier: ViewModifier {
    @Environment(SongBatchRemovalService.self) private var removal

    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let progress = removal.progress, !progress.isFinished {
                        card {
                            ProgressView()
                                .controlSize(.small)
                            Text(verbatim: String(
                                format: String(localized: "batch_delete_progress_format"),
                                progress.done,
                                progress.total
                            ))
                            .monospacedDigit()
                        }
                    }

                    if let toastMessage {
                        card {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                            Text(verbatim: toastMessage)
                        }
                    }
                }
                // 抬过 mini player / 底部栏，否则提示正好被压在下面看不见。
                .padding(.bottom, 96)
                .animation(.snappy(duration: 0.25), value: removal.progress)
                .animation(.snappy(duration: 0.25), value: toastMessage)
                .allowsHitTesting(false)
            }
            .onChange(of: removal.completionRevision) { _, _ in
                presentOutcome()
            }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func presentOutcome() {
        guard let outcome = removal.lastOutcome else { return }
        var parts = [String(
            format: String(localized: "batch_delete_result_format"),
            outcome.removed
        )]
        if outcome.failed > 0 {
            parts.append(String(
                format: String(localized: "batch_delete_failed_format"),
                outcome.failed
            ))
        }
        if outcome.skipped > 0 {
            parts.append(String(
                format: String(localized: "batch_delete_skipped_format"),
                outcome.skipped
            ))
        }
        toastMessage = parts.joined(separator: " · ")

        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }
}
