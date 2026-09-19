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
    /// 局域网直传当前这一步的进度;没在发送时为 nil。
    @State private var transferProgress: LANTransferProgress?
    /// 局域网直传停下的那一步。分段直传时之前的步骤已在 Apple TV 上落盘,从这里接着发。
    @State private var failedStage: LANTransferStage?

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

    /// 分段直传的 Apple TV 能从中断处接着收;旧版 TV 只能整包重发。配对已失效(403、链接无效)
    /// 时接着发也只会再被拒,要重新扫码。
    private var canResume: Bool {
        guard lanTarget?.supportsStagedTransfer == true, let failedStage, failedStage > .sources else {
            return false
        }
        switch failure {
        case .tvRejected(statusCode: 403), .invalidPairingLink:
            return false
        default:
            return true
        }
    }

    private var showsTransferSteps: Bool {
        lanTarget != nil && (sending || result != nil)
    }

    private var transferSteps: [SendToTVStep] {
        guard lanTarget?.supportsStagedTransfer == true else {
            return [SendToTVStep(stage: .library, title: PMString("send_to_tv_step_everything"))]
        }
        return [
            SendToTVStep(stage: .sources, title: PMString("send_to_tv_step_sources")),
            SendToTVStep(stage: .library, title: PMString("send_to_tv_step_library")),
            SendToTVStep(stage: .artwork, title: PMString("send_to_tv_step_artwork")),
        ]
    }

    private func stepState(for stage: LANTransferStage) -> SendToTVStepState {
        if result == true { return .done }
        if let failedStage {
            if stage < failedStage { return .done }
            return stage == failedStage ? .failed : .pending
        }
        guard let transferProgress else { return .pending }
        if stage < transferProgress.stage { return .done }
        return stage == transferProgress.stage ? .active(transferProgress) : .pending
    }

    private var panel: some View {
        GeometryReader { proxy in
            ScrollView {
                panelContent
                    .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var panelContent: some View {
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

                if showsTransferSteps {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(transferSteps) { step in
                            SendToTVStepRow(title: step.title, state: stepState(for: step.stage))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .pmFadeTransition(motion: .contentAppear)
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
                                .pmAppearFade(.control)
                        } else {
                            HStack(spacing: 8) {
                                if let result {
                                    Image(systemName: result ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .contentTransition(.symbolEffect(.replace))
                                        // 结果是裸赋值, 换图得自己带一个事务; 只包这一个图标,
                                        // 不让整块按钮内容跟着进动画。
                                        .pmAnimation(.control, value: result)
                                }
                                if result != true, canResume {
                                    Text(PMString("send_to_tv_resume"))
                                } else {
                                    Text(result == true
                                         ? "send_to_tv_sent"
                                         : (lanTarget == nil ? "send_to_tv_action" : "send_to_tv_confirm_and_send"))
                                }
                            }
                            .pmAppearFade(.control)
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
                        if canResume {
                            Text(PMString("send_to_tv_partial_saved"))
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                        }
                        Text(verbatim: failure.diagnosticCode)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                    .foregroundStyle(.orange)
                    .pmFadeTransition(motion: .contentAppear)
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
        let previousFailedStage = failedStage
        let resumeStage: LANTransferStage = canResume ? (previousFailedStage ?? .sources) : .sources
        failedStage = nil
        transferProgress = nil
        Task {
            // 等待原子落盘完成，避免首次安装/重装后的发送读取不到快照。
            switch await musicLibrary.persistNowAndWait() {
            case .success:
                break
            case .failure(let persistenceFailure):
                sending = false
                result = false
                failure = persistenceFailure
                failedStage = previousFailedStage
                return
            }
            guard let target = lanTarget else {
                finish(await LibrarySnapshotSync.shared.uploadNowResult(), failedAt: nil)
                return
            }
            let (updates, continuation) = AsyncStream.makeStream(
                of: LANTransferProgress.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            let observer = Task {
                for await update in updates { transferProgress = update }
            }
            if target.supportsStagedTransfer {
                let outcome = await LibrarySnapshotSync.shared.sendToTVOverLANStaged(
                    target,
                    startingAt: resumeStage
                ) { continuation.yield($0) }
                continuation.finish()
                await observer.value
                switch outcome {
                case .success:
                    finish(.success(()), failedAt: nil)
                case .failure(let staged):
                    finish(.failure(staged.failure), failedAt: staged.stage)
                }
            } else {
                let outcome = await LibrarySnapshotSync.shared.sendToTVOverLANResult(target) {
                    continuation.yield($0)
                }
                continuation.finish()
                await observer.value
                finish(outcome, failedAt: .library)
            }
        }
    }

    private func finish(_ transfer: Result<Void, AppleTVTransferFailure>, failedAt stage: LANTransferStage?) {
        sending = false
        transferProgress = nil
        switch transfer {
        case .success:
            result = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        case .failure(let transferFailure):
            result = false
            failure = transferFailure
            failedStage = stage
        }
    }
}

private struct SendToTVStep: Identifiable {
    let stage: LANTransferStage
    let title: String
    var id: LANTransferStage { stage }
}

private enum SendToTVStepState: Equatable {
    case pending
    case active(LANTransferProgress)
    case done
    case failed
}

/// 局域网直传的一步:图标表示状态,正在进行的那步带说明和进度条。
private struct SendToTVStepRow: View {
    let title: String
    let state: SendToTVStepState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if case .active(let progress) = state,
                   progress.activity == .sending,
                   let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch state {
        case .pending:
            return PMString("send_to_tv_progress_waiting")
        case .done:
            return PMString("send_to_tv_progress_done")
        case .failed:
            return PMString("send_to_tv_progress_failed")
        case .active(let progress):
            switch progress.activity {
            case .preparing:
                return PMString("send_to_tv_progress_preparing")
            case .waitingForTV:
                return PMString("send_to_tv_progress_tv_saving")
            case .sending:
                if let index = progress.batchIndex, let count = progress.batchCount {
                    return PMString("send_to_tv_progress_batch", index.formatted(), count.formatted())
                }
                guard let fraction = progress.fraction else {
                    return PMString("send_to_tv_progress_preparing")
                }
                return PMString("send_to_tv_progress_sending",
                                fraction.formatted(.percent.precision(.fractionLength(0))))
            }
        }
    }
}
