import SwiftUI
import PrimuseKit

/// Apple TV 二维码(primuse://add-source)扫码后的入口。
///
/// 解决"扫码只能新建源、没法把已有源同步过去"的困惑:主操作是把当前曲库 + 已添加的
/// 音乐源 + 凭据一键发送到 Apple TV(经 iCloud);"添加新的音乐源"作为次入口保留。
struct SendToTVSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var musicLibrary
    @Environment(SourcesStore.self) private var sourcesStore
    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true

    @State private var sending = false
    @State private var result: Bool?
    @State private var showAddSource = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                Image(systemName: "appletv.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                Text("send_to_tv_title")
                    .font(.title2.weight(.bold))
                Text("send_to_tv_message")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if !iCloudSyncEnabled {
                    Label("send_to_tv_need_icloud", systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Button(action: send) {
                    Group {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            HStack(spacing: 8) {
                                if let result {
                                    Image(systemName: result ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                }
                                Text(result == true ? "send_to_tv_sent" : "send_to_tv_action")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(sending || !iCloudSyncEnabled)

                if result == false {
                    Text("send_to_tv_failed")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Button("send_to_tv_add_source") { showAddSource = true }
                    .font(.subheadline)
                    .padding(.top, 2)

                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddSource) {
                SourceTypeSelectionView { source in sourcesStore.add(source) }
            }
        }
    }

    private func send() {
        guard !sending else { return }
        sending = true
        result = nil
        // 先把最新曲库落盘成快照,否则 uploadNow 会因本地没有 library-cache.json 直接跳过。
        musicLibrary.persistNow()
        Task {
            let ok = await LibrarySnapshotSync.shared.uploadNow()
            sending = false
            result = ok
            if ok {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        }
    }
}
