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
    @Environment(SourceManager.self) private var sourceManager
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService
    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true

    @State private var sending = false
    @State private var result: Bool?
    @State private var failure: AppleTVTransferFailure?
    @State private var showAddSource = false

    /// 局域网直传不依赖 iCloud;仅旧的 iCloud 上传模式才需要开关开启。
    private var blocked: Bool { lanTarget == nil && !iCloudSyncEnabled }

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            macHeader
            Divider()
            panel
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 500, idealHeight: 580)
        #else
        NavigationStack {
            panel
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var panel: some View {
        VStack(spacing: 20) {
                Spacer(minLength: 8)

                Image(systemName: "appletv.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                #if !os(macOS)
                Text("send_to_tv_title")
                    .font(.title2.weight(.bold))
                #endif
                Text(lanTarget == nil ? "send_to_tv_message" : "send_to_tv_lan_message")
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
                            Text(PMString("ext.tv.sources.confirmCode"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(verbatim: lanTarget.displayPairCode)
                                .font(.system(.title2, design: .monospaced).weight(.bold))
                                .textSelection(.enabled)
                            Text(PMString("ext.tv.sources.confirmCodeHint"))
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
                                Text(result == true
                                     ? "send_to_tv_sent"
                                     : (lanTarget == nil ? "send_to_tv_action" : "send_to_tv_confirm_and_send"))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(sending || blocked)

                if let failure {
                    VStack(spacing: 5) {
                        Text(failure.userFacingMessage)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        Text(verbatim: failure.diagnosticCode)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.orange)
                }

                Button("send_to_tv_add_source") { showAddSource = true }
                    .font(.subheadline)
                    .padding(.top, 2)

                Spacer()
            }
            .padding(24)
            .sheet(isPresented: $showAddSource) {
                SourceTypeSelectionView { source in
                    if source.type == .jellyfin {
                        try sourcesStore.addDurably(source)
                    } else if source.type == .local,
                              source.id == LocalImportService.existingSourceID {
                        try sourcesStore.addDurably(source)
                    } else {
                        sourcesStore.add(source)
                    }
                    if source.type == .jellyfin {
                        scanService.scanSource(
                            source,
                            sourceManager: sourceManager,
                            library: musicLibrary,
                            sourceStore: sourcesStore,
                            scraperService: scraperService
                        )
                    }
                }
            }
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(spacing: 12) {
            Text("send_to_tv_title")
                .font(.system(size: 13.5, weight: .semibold))
            Spacer()
            Button("done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("sendToTVDone")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }
    #endif

    private func send() {
        guard !sending else { return }
        sending = true
        result = nil
        failure = nil
        Task {
            // 等待原子落盘完成，避免首次安装/重装后的发送读取不到快照。
            switch await musicLibrary.persistNowAndWait() {
            case .success:
                break
            case .failure(let persistenceFailure):
                sending = false
                result = false
                failure = persistenceFailure
                return
            }
            let transfer: Result<Void, AppleTVTransferFailure>
            if let target = lanTarget {
                transfer = await LibrarySnapshotSync.shared.sendToTVOverLANResult(target)
            } else {
                transfer = await LibrarySnapshotSync.shared.uploadNowResult()
            }
            sending = false
            switch transfer {
            case .success:
                result = true
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            case .failure(let transferFailure):
                result = false
                failure = transferFailure
            }
        }
    }
}
