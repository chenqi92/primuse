import PrimuseKit
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

    /// 源端永久拒绝删除的那些歌。留在库里对用户没有意义 —— 给一个可恢复的出口。
    @State private var localRemovalOffer: LocalRemovalOffer?

    private struct LocalRemovalOffer: Identifiable {
        let id = UUID()
        let songs: [Song]
        let details: [String: String]
    }

    /// 进度和结果是两个来源:结果出来时顺手撤掉进度,进度那边收尾时也不会把结果撤掉。
    private static let progressKey = "songBatchRemoval.progress"
    private static let outcomeKey = "songBatchRemoval.outcome"

    func body(content: Content) -> some View {
        content
            // 提示条本身由根视图上的 `PMToastPresenter.shared` 宿主画:抬过迷你条、底部栏,
            // 结果要活过发起它的页面(选择模式在提交瞬间就退出了)。
            .onChange(of: removal.progress, initial: true) { _, progress in
                presentProgress(progress)
            }
            .onChange(of: removal.completionRevision) { _, _ in
                presentOutcome()
            }
            .alert(
                "batch_delete_denied_title",
                isPresented: Binding(
                    get: { localRemovalOffer != nil },
                    set: { if !$0 { localRemovalOffer = nil } }
                ),
                presenting: localRemovalOffer
            ) { offer in
                Button("batch_remove_from_device", role: .destructive) {
                    removal.remove(
                        offer.songs,
                        mode: .deviceLocal,
                        localRemovalReason: .remoteDeletionDenied,
                        localRemovalDetails: offer.details
                    )
                }
                Button("cancel", role: .cancel) {}
            } message: { offer in
                Text(verbatim: String(
                    format: String(localized: "batch_delete_denied_message_format"),
                    offer.songs.count
                ))
            }
    }

    private func presentProgress(_ progress: SongBatchRemovalService.Progress?) {
        guard let progress, !progress.isFinished else {
            PMToastPresenter.shared.dismiss(key: Self.progressKey)
            return
        }
        PMToastPresenter.shared.show(PMToastItem(
            key: Self.progressKey,
            message: String(
                format: String(localized: "batch_delete_progress_format"),
                progress.done,
                progress.total
            ),
            showsProgress: true,
            duration: nil
        ))
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
        PMToastPresenter.shared.dismiss(key: Self.progressKey)
        PMToastPresenter.shared.show(PMToastItem(
            key: Self.outcomeKey,
            message: parts.joined(separator: " · "),
            systemImage: "checkmark.circle.fill",
            duration: 3.5
        ))
        if outcome.offersLocalRemoval {
            localRemovalOffer = LocalRemovalOffer(
                songs: outcome.locallyRemovableSongs,
                details: outcome.locallyRemovableDetails
            )
        }
    }
}

// MARK: - 从音乐服务器删歌的第二次确认

/// 从音乐服务器删歌（`ServerSongDeletionPolicy`）在各入口原有的删除确认之后再确认一次：
/// 说清楚在哪台服务器上删、这台服务器的所有用户和客户端都会失去这些歌、不能撤销。
/// 文件来源（本机、NAS 共享、网盘）照旧只确认一次。
struct ServerSongDeletionRequest: Identifiable {
    let id = UUID()
    let serverNames: [String]
    let songCount: Int
    let perform: @MainActor () -> Void

    /// 要删的歌里有走音乐服务器删除的就返回第二次确认，否则 nil（照原流程直接删）。
    @MainActor
    static func make(
        deleting songs: [Song],
        sources: [MusicSource],
        perform: @escaping @MainActor () -> Void
    ) -> ServerSongDeletionRequest? {
        let servers = ServerSongDeletionPolicy.serverSources(deleting: songs, sources: sources)
        guard !servers.isEmpty else { return nil }
        let serverIDs = Set(servers.map(\.id))
        return ServerSongDeletionRequest(
            serverNames: servers.map(\.name),
            songCount: songs.filter { serverIDs.contains($0.sourceID) }.count,
            perform: perform
        )
    }

    var message: String {
        String(
            format: String(localized: "server_delete_confirm_message_format"),
            ListFormatter.localizedString(byJoining: serverNames),
            songCount
        )
    }
}

extension View {
    /// 第一次确认框还在收起时就弹下一个，系统会把它丢掉；调用方等它收完再给 `request` 赋值
    /// （`ServerSongDeletionRequest.presentationDelay`）。
    func serverSongDeletionConfirmation(_ request: Binding<ServerSongDeletionRequest?>) -> some View {
        alert(
            Text("server_delete_confirm_title"),
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }
            ),
            presenting: request.wrappedValue
        ) { pending in
            Button("cancel", role: .cancel) {}
            Button("server_delete_confirm_action", role: .destructive) { pending.perform() }
        } message: { pending in
            Text(verbatim: pending.message)
        }
    }
}

extension ServerSongDeletionRequest {
    /// 前一个确认框收起要一点时间，紧接着弹第二个会被系统丢掉。
    static let presentationDelay: Duration = .milliseconds(450)
}
