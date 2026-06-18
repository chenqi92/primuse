import SwiftUI
import PrimuseKit

/// Apple TV 二维码(primuse://add-source)扫码后的入口。
///
/// 解决"扫码只能新建源、没法把已有源同步过去"的困惑:主操作是把当前曲库 + 已添加的
/// 音乐源 + 凭据一键发送到 Apple TV(经 iCloud);"添加新的音乐源"作为次入口保留。
struct SendToTVSheet: View {
    /// 非 nil 时走【局域网直传】(扫 primuse://pair 而来):整库 / 源 / 凭据 AES-GCM 加密
    /// 直接 POST 给该 Apple TV 端点,绕开 iCloud(不受 Apple ID / 区域 / 环境隔离)。
    /// nil 时退回旧的 iCloud 上传(primuse://add-source 扫码,同账号兜底)。
    var lanTarget: LANPairLink? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var musicLibrary
    @Environment(SourcesStore.self) private var sourcesStore
    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true

    @State private var sending = false
    @State private var result: Bool?
    @State private var showAddSource = false

    /// 局域网直传不依赖 iCloud;仅旧的 iCloud 上传模式才需要开关开启。
    private var blocked: Bool { lanTarget == nil && !iCloudSyncEnabled }

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

                if let lanTarget {
                    VStack(spacing: 8) {
                        Label {
                            Text(verbatim: "\(lanTarget.host):\(lanTarget.port)")
                                .font(.footnote.monospaced())
                        } icon: {
                            Image(systemName: "network")
                        }
                        .foregroundStyle(.secondary)

                        VStack(spacing: 3) {
                            Text(verbatim: "Pairing Code")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: lanTarget.displayPairCode)
                                .font(.system(.title2, design: .monospaced).weight(.bold))
                                .textSelection(.enabled)
                            Text(verbatim: "Confirm this matches the code shown on Apple TV.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }

                if blocked {
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
                                Text(result == true ? "send_to_tv_sent" : (lanTarget == nil ? "send_to_tv_action" : "Confirm and Send"))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(sending || blocked)

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
        // 先把最新曲库落盘成快照,否则发送会因本地没有 library-cache.json 直接跳过/为空。
        musicLibrary.persistNow()
        Task {
            let ok: Bool
            if let target = lanTarget {
                ok = await LibrarySnapshotSync.shared.sendToTVOverLAN(target)
            } else {
                ok = await LibrarySnapshotSync.shared.uploadNow()
            }
            sending = false
            result = ok
            if ok {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        }
    }
}
