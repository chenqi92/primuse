#if os(iOS) || os(macOS)
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum AudioCacheSyncDirection: String, CaseIterable {
    case send, receive
    var title: String { CacheSyncLocalization.text("cache_sync_mode_" + rawValue) }
}

/// 缓存同步页。iPhone、iPad 与 Mac 共用一份布局, 用「WiFi 传输」的那套
/// `Transfer*` 外观: 两个局域网功能在同一处入口并排出现, 画风要一致。
struct AudioCacheSyncView: View {
    /// iOS: 作为弹出页时左上角给「完成」。Mac 一律是弹出页, 关闭键在标题栏。
    var isPresentedAsSheet = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AudioCacheSyncService.self) private var cacheSync
    @State private var selectedPeerID: String?
    @State private var direction: AudioCacheSyncDirection = .send
    @State private var enteredCode = ""
    @State private var copied = false
    @State private var showsCodeEntry = false
    @State private var showsFullSyncConfirmation = false

    init(isPresentedAsSheet: Bool = true, initialDirection: AudioCacheSyncDirection = .send) {
        self.isPresentedAsSheet = isPresentedAsSheet
        _direction = State(initialValue: initialDirection)
    }

    private var isBusy: Bool {
        cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            header
            #endif
            modeSelector
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if direction == .send {
                        sendContent
                    } else {
                        receiveContent
                    }
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            #if os(macOS)
            footer
            #endif
        }
        .background(TransferAppearance.background)
        .foregroundStyle(TransferAppearance.text)
        #if os(iOS)
        .navigationTitle(text("cache_sync_title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isBusy)
        .toolbar { toolbarContent }
        #else
        .frame(minWidth: 560, idealWidth: 640, minHeight: 500, idealHeight: 600)
        .presentationSizing(.fitted)
        #endif
        .interactiveDismissDisabled(isBusy)
        .onAppear(perform: startSession)
        .onDisappear(perform: endSession)
        .onChange(of: cacheSync.operation) { _, operation in
            updateScreenWake(for: operation)
        }
        .onChange(of: direction) { _, direction in
            if direction == .send {
                cacheSync.startDiscovery()
            } else {
                cacheSync.stopDiscovery()
            }
            updateScreenWake(for: cacheSync.operation)
        }
        .onChange(of: cacheSync.incomingTransferCount) { _, count in
            if count > 0, cacheSync.operation != .transferring { direction = .receive }
        }
        .onChange(of: cacheSync.peers, initial: true) { _, peers in
            updateSelection(for: peers)
        }
        .onChange(of: cacheSync.discoveryIssue) { _, issue in
            // 发现不了附近设备时, 连接码是唯一的路, 直接展开。
            if issue != nil { showsCodeEntry = true }
        }
        .onChange(of: cacheSync.connectionCode) { _, _ in copied = false }
    }

    #if os(macOS)
    private static let horizontalPadding: CGFloat = 22
    #else
    private static let horizontalPadding: CGFloat = 16
    #endif

    // MARK: - Chrome

    #if os(macOS)
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.wifi")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PMColor.brand).frame(width: 34, height: 34)
                .background(PMColor.brand.opacity(0.11), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: text("cache_sync_title")).font(.system(size: 16, weight: .semibold))
                Text(verbatim: text("cache_sync_subtitle")).font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted).lineLimit(2)
            }
            Spacer(minLength: 20)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted).frame(width: 28, height: 28)
                    .background(PMColor.glassBtn, in: .circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(text("cache_sync_close"))
            .accessibilityLabel(text("cache_sync_close"))
            .disabled(isBusy)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(PMColor.bgElev)
        .overlay(alignment: .bottom) { Rectangle().fill(PMColor.divider).frame(height: 0.5) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label(text("cache_sync_encrypted_footer"), systemImage: "lock.shield")
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(TransferAppearance.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if cacheSync.operation == .transferring {
                Button(text("cache_sync_stop")) { cacheSync.cancelTransfer() }
                    .buttonStyle(TransferButtonStyle())
                    .accessibilityIdentifier("cacheSync.stop")
                    .pmAppearFade(.contentAppear)
            } else if direction == .send {
                Button {
                    startSync(maximumFileCount: nil)
                } label: {
                    Label(primaryActionTitle, systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(TransferButtonStyle(prominent: true))
                .disabled(!canStartTransfer)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cacheSync.syncAll")
                .pmAppearFade(.contentAppear)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(minHeight: 54)
        .background(TransferAppearance.surface)
        .overlay(alignment: .top) { Rectangle().fill(TransferAppearance.line).frame(height: 0.5) }
    }
    #endif

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isPresentedAsSheet {
            ToolbarItem(placement: .cancellationAction) {
                Button(text("cache_sync_done")) { dismiss() }
                    .disabled(isBusy)
            }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(verbatim: text("cache_sync_title")).font(.headline)
                Text(verbatim: navigationStatus).font(.caption2)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if direction == .send {
            ToolbarItem(placement: .confirmationAction) {
                if cacheSync.operation == .transferring {
                    Button(text("cache_sync_stop"), role: .destructive) { cacheSync.cancelTransfer() }
                        .accessibilityIdentifier("cacheSync.stop")
                } else {
                    Button(text("cache_sync_start")) { showsFullSyncConfirmation = true }
                        .fontWeight(.semibold)
                        .disabled(!canStartTransfer)
                        .accessibilityIdentifier("cacheSync.syncAll")
                        // 挂在触发按钮上, 弹框从按钮长出来而不是贴在整页边缘。
                        .confirmationDialog(
                            text("cache_sync_confirm_all_title"),
                            isPresented: $showsFullSyncConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(text("cache_sync_sync_all")) { startSync(maximumFileCount: nil) }
                            Button(role: .cancel) {} label: { Text("cancel") }
                        } message: {
                            Text(verbatim: fullSyncConfirmationMessage)
                        }
                }
            }
        }
    }

    /// 导航栏副标题: 页面上唯一的常驻状态位置, 和「WiFi 传输」一样。
    private var navigationStatus: String {
        if direction == .receive {
            if cacheSync.incomingTransferCount > 0 { return text("cache_sync_receiving") }
            return text(cacheSync.receiverState.labelKey)
        }
        if let progress = cacheSync.transferProgress, cacheSync.operation == .transferring {
            return String(
                format: text("cache_sync_progress_count_format"),
                progress.completedFileCount + progress.failedFileCount,
                progress.totalFileCount
            )
        }
        return selectedPeer?.name ?? text("cache_sync_same_wifi_hint")
    }
    #endif

    private var modeSelector: some View {
        Picker(text("cache_sync_title"), selection: $direction) {
            ForEach(AudioCacheSyncDirection.allCases, id: \.self) { direction in
                Text(verbatim: direction.title).tag(direction)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #if os(macOS)
        .controlSize(.regular)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
        #endif
        .disabled(isBusy)
        .accessibilityIdentifier("cacheSync.mode")
    }

    // MARK: - Send

    @ViewBuilder
    private var sendContent: some View {
        localDeviceCard
        devicesSection
        if let plan = selectedPlan, plan.missingFileCount > 0, cacheSync.operation != .transferring {
            trialSyncCard
                .pmAppearFade(.contentAppear)
        }
        if let progress = cacheSync.transferProgress, progress.peerID == selectedPeerID {
            transferProgressCard(progress)
                .pmAppearFade(.contentAppear)
        }
        if let completion = cacheSync.lastCompletion, completion.peerID == selectedPeerID {
            completionCard(completion)
                .pmAppearFade(.contentAppear)
        }
        if let error = cacheSync.lastError {
            VStack(alignment: .leading, spacing: 10) {
                TransferFeedback(text: error, isError: true)
                Button(text("cache_sync_retry"), systemImage: "arrow.clockwise") {
                    cacheSync.clearFeedback()
                    if let selectedPeerID {
                        cacheSync.inspect(peerID: selectedPeerID)
                    } else {
                        cacheSync.startDiscovery()
                    }
                }
                .buttonStyle(TransferButtonStyle(compact: true))
                .accessibilityIdentifier("cacheSync.retry")
            }
            .pmAppearFade(.contentAppear)
        }
        networkIssueFeedback
        codeEntrySection
    }

    private var localDeviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            TransferSectionHeading(title: text("cache_sync_local_device"))
            HStack(spacing: 12) {
                Image(systemName: Self.localDeviceSymbol)
                    .font(.title3).foregroundStyle(TransferAppearance.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: text("cache_sync_local_cache"))
                        .font(.system(size: TransferAppearance.bodySize, weight: .medium))
                    if let inventory = cacheSync.localInventory {
                        Text(verbatim: String(
                            format: text("cache_sync_inventory_format"),
                            inventory.fileCount,
                            byteString(inventory.byteCount)
                        ))
                        .font(.system(size: TransferAppearance.captionSize))
                        .foregroundStyle(TransferAppearance.muted)
                        .monospacedDigit()
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(verbatim: text("cache_sync_preparing_inventory"))
                        }
                        .font(.system(size: TransferAppearance.captionSize))
                        .foregroundStyle(TransferAppearance.muted)
                    }
                }
                Spacer(minLength: 8)
                receiverStatusBadge
            }
            .modifier(TransferSurface(padding: 14))
            Text(verbatim: text("cache_sync_local_network_footer"))
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(TransferAppearance.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("cacheSync.inventory")
    }

    private var receiverStatusBadge: some View {
        let ready = cacheSync.receiverState == .ready
        return Label {
            Text(verbatim: text(cacheSync.receiverState.labelKey))
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 6))
        }
        .font(.system(size: TransferAppearance.captionSize, weight: .medium))
        .foregroundStyle(ready ? TransferAppearance.accent : Color.orange)
        .lineLimit(1)
        .pmAnimation(.control, value: ready)
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: text("cache_sync_nearby_devices"))
                    .font(.system(size: TransferAppearance.bodySize, weight: .semibold))
                Spacer(minLength: 8)
                refreshButton
            }
            VStack(spacing: 0) {
                if cacheSync.peers.isEmpty {
                    HStack(spacing: 10) {
                        if cacheSync.isDiscovering {
                            ProgressView().controlSize(.small).frame(width: 26)
                        } else {
                            Image(systemName: "wifi.slash")
                                .font(.title3).foregroundStyle(TransferAppearance.muted).frame(width: 26)
                        }
                        Text(verbatim: text(
                            cacheSync.isDiscovering ? "cache_sync_searching_devices" : "cache_sync_no_devices"
                        ))
                        .font(.system(size: TransferAppearance.bodySize))
                        .foregroundStyle(TransferAppearance.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .padding(.horizontal, 12)
                } else {
                    ForEach(cacheSync.peers) { peer in
                        peerRow(peer)
                            .padding(.horizontal, 12)
                            .background(selectedPeerID == peer.id ? TransferAppearance.accent.opacity(0.08) : .clear)
                        if peer.id != cacheSync.peers.last?.id { Divider().padding(.leading, 50) }
                    }
                }
            }
            .background(TransferAppearance.surface, in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
            Text(verbatim: text("cache_sync_open_app_hint") + " " + text("cache_sync_send_steps"))
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(TransferAppearance.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refreshButton: some View {
        Button {
            selectedPeerID = nil
            cacheSync.clearFeedback()
            cacheSync.retryNetworking()
            cacheSync.refreshLocalInventory()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.subheadline.weight(.medium))
                .frame(width: TransferAppearance.compactTarget, height: TransferAppearance.compactTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(TransferAppearance.accent)
        .disabled(cacheSync.operation == .transferring)
        .help(text("cache_sync_refresh"))
        .accessibilityLabel(text("cache_sync_refresh"))
        .accessibilityIdentifier("cacheSync.refreshPeers")
    }

    private func peerRow(_ peer: AudioCacheSyncPeer) -> some View {
        let selected = selectedPeerID == peer.id
        let inspecting = cacheSync.operation == .inspecting && cacheSync.activePeerID == peer.id
        let plan = cacheSync.peerPlans[peer.id]
        return Button {
            select(peer)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: peer.platform.symbolName)
                    .font(.title3).foregroundStyle(TransferAppearance.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: peer.name)
                        .font(.system(size: TransferAppearance.bodySize, weight: .medium))
                        .foregroundStyle(TransferAppearance.text)
                        .lineLimit(1)
                    Group {
                        if inspecting {
                            Text(verbatim: text("cache_sync_comparing"))
                        } else if let plan {
                            Text(verbatim: planDescription(plan))
                                .foregroundStyle(
                                    plan.missingFileCount == 0 && plan.rejectedCount == 0
                                        ? Color.green : TransferAppearance.muted
                                )
                        } else {
                            Text(verbatim: text("cache_sync_tap_to_compare"))
                        }
                    }
                    .font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted)
                    .lineLimit(2)
                }
                Spacer(minLength: 4)
                if inspecting {
                    ProgressView().controlSize(.small)
                } else if selected {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                        .foregroundStyle(TransferAppearance.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(cacheSync.operation == .transferring)
        .accessibilityIdentifier("cacheSync.compare")
    }

    /// 选中设备缺缓存时, 先给「试传 3 个」: 确认连通再整批发, 和原来的建议一致。
    private var trialSyncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: text("cache_sync_test_three_footer"))
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(TransferAppearance.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                startSync(maximumFileCount: 3)
            } label: {
                Label(text("cache_sync_test_three"), systemImage: "testtube.2")
            }
            .buttonStyle(TransferButtonStyle(compact: true))
            .disabled(cacheSync.operation != .idle)
            .accessibilityIdentifier("cacheSync.testThree")
        }
        .modifier(TransferSurface(padding: 14))
    }

    private func transferProgressCard(_ progress: AudioCacheSyncTransferProgress) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                if cacheSync.operation == .transferring {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: text("cache_sync_transferring"))
                Spacer()
                Text(verbatim: String(
                    format: text("cache_sync_progress_count_format"),
                    progress.completedFileCount + progress.failedFileCount,
                    progress.totalFileCount
                ))
                .monospacedDigit()
            }
            .font(.system(size: TransferAppearance.bodySize, weight: .medium))
            Text(verbatim: progress.currentTitle ?? text("cache_sync_preparing_transfer"))
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(TransferAppearance.muted)
                .lineLimit(1).truncationMode(.middle)
            ProgressView(value: progress.fractionCompleted).tint(TransferAppearance.accent)
            Text(verbatim: "\(byteString(progress.sentByteCount)) / \(byteString(progress.totalByteCount))")
                .font(.caption).foregroundStyle(TransferAppearance.muted).monospacedDigit()
            Text(verbatim: text("cache_sync_keep_foreground"))
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(TransferAppearance.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(TransferSurface(padding: 14))
    }

    private func completionCard(_ completion: AudioCacheSyncTransferCompletion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TransferFeedback(
                text: String(
                    format: text("cache_sync_completion_format"),
                    completion.transferredFileCount,
                    byteString(completion.transferredByteCount),
                    completion.failedFileCount
                ),
                isError: completion.failedFileCount > 0
            )
            if !completion.transferredTitles.isEmpty {
                Text(verbatim: text("cache_sync_test_transferred_titles"))
                    .font(.system(size: TransferAppearance.captionSize, weight: .semibold))
                    .foregroundStyle(TransferAppearance.muted)
                    .padding(.top, 2)
                ForEach(Array(completion.transferredTitles.enumerated()), id: \.offset) { _, title in
                    Label(title, systemImage: "music.note")
                        .font(.system(size: TransferAppearance.captionSize))
                        .foregroundStyle(TransferAppearance.text)
                        .lineLimit(1)
                }
            }
        }
        .modifier(TransferSurface(padding: 14))
    }

    private var codeEntrySection: some View {
        DisclosureGroup(isExpanded: $showsCodeEntry) {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: text("cache_sync_connect_code_hint"))
                    .font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(text("cache_sync_code_placeholder"), text: $enteredCode, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: TransferAppearance.captionSize + 1, design: .monospaced))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(TransferAppearance.surface, in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
                    .disabled(cacheSync.operation != .idle)
                    .accessibilityIdentifier("cacheSync.connectionCode")
                Button {
                    if let peerID = cacheSync.connect(using: enteredCode) {
                        selectedPeerID = peerID
                        cacheSync.inspect(peerID: peerID)
                    }
                } label: {
                    Label(text("cache_sync_connect"), systemImage: "link")
                }
                .buttonStyle(TransferButtonStyle(compact: true))
                .disabled(
                    enteredCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || cacheSync.operation != .idle
                )
                .accessibilityIdentifier("cacheSync.connect")
            }
            .padding(.top, 10)
        } label: {
            Text(verbatim: text("cache_sync_connect_code"))
                .font(.system(size: TransferAppearance.bodySize, weight: .medium))
                .frame(minHeight: TransferAppearance.compactTarget)
        }
        .tint(TransferAppearance.accent)
    }

    // MARK: - Receive

    @ViewBuilder
    private var receiveContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(cacheSync.localDeviceName, systemImage: Self.localDeviceSymbol)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Label {
                Text(verbatim: text(
                    cacheSync.incomingTransferCount > 0 ? "cache_sync_receiving" : cacheSync.receiverState.labelKey
                ))
            } icon: {
                Image(systemName: "circle.fill").font(.system(size: 7))
            }
            .font(.system(size: TransferAppearance.captionSize, weight: .medium))
            .foregroundStyle(
                cacheSync.receiverState == .ready || cacheSync.receiverState == .directOnly
                    ? TransferAppearance.accent : Color.orange
            )
            .pmAnimation(.control, value: cacheSync.receiverState == .ready)
            Text(verbatim: text("cache_sync_receive_steps"))
                .font(.system(size: TransferAppearance.captionSize))
                .foregroundStyle(TransferAppearance.muted)
                .fixedSize(horizontal: false, vertical: true)
            if cacheSync.incomingTransferCount > 0 || cacheSync.receivedFileCount > 0 {
                HStack(spacing: 8) {
                    if cacheSync.incomingTransferCount > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle").foregroundStyle(TransferAppearance.accent)
                    }
                    Text(verbatim: String(
                        format: text("cache_sync_received_format"),
                        cacheSync.receivedFileCount,
                        byteString(cacheSync.receivedByteCount)
                    ))
                    .monospacedDigit()
                }
                .font(.system(size: TransferAppearance.bodySize, weight: .medium))
                .pmAppearFade(.contentAppear)
            }
            if let code = cacheSync.connectionCode {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { connectionCodeActions(code) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 10) { connectionCodeActions(code) }
                }
                .padding(.top, 4)
            } else if cacheSync.isReceiving {
                Text(verbatim: text("cache_sync_no_local_address"))
                    .font(.system(size: TransferAppearance.captionSize))
                    .foregroundStyle(TransferAppearance.muted)
            }
        }
        .modifier(TransferSurface(padding: 22))
        if let error = cacheSync.incomingError {
            TransferFeedback(text: error, isError: true)
        }
        networkIssueFeedback
        Text(verbatim: text("cache_sync_matching_library_hint"))
            .font(.system(size: TransferAppearance.captionSize))
            .foregroundStyle(TransferAppearance.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func connectionCodeActions(_ code: String) -> some View {
        Button {
            #if os(iOS)
            UIPasteboard.general.string = code
            #else
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            #endif
            copied = true
        } label: {
            Label(
                text(copied ? "cache_sync_code_copied" : "cache_sync_copy_code"),
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
        }
        .buttonStyle(TransferButtonStyle(prominent: true, compact: true))
        .accessibilityIdentifier("cacheSync.copyCode")
        ShareLink(item: code) {
            Label(text("cache_sync_share_code"), systemImage: "square.and.arrow.up")
        }
        .buttonStyle(TransferButtonStyle(compact: true))
        .accessibilityIdentifier("cacheSync.shareCode")
    }

    // MARK: - Shared

    @ViewBuilder
    private var networkIssueFeedback: some View {
        if let issue = direction == .send ? cacheSync.discoveryIssue : cacheSync.receiverIssue {
            VStack(alignment: .leading, spacing: 10) {
                TransferFeedback(text: issue.message, isError: true)
                HStack(spacing: 10) {
                    Button(text("cache_sync_retry"), systemImage: "arrow.clockwise") {
                        cacheSync.retryNetworking(discover: direction == .send)
                    }
                    if issue == .permissionDenied {
                        Button(text("cache_sync_open_settings"), systemImage: "gear") {
                            #if os(iOS)
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                            #else
                            openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                            #endif
                        }
                    }
                }
                .buttonStyle(TransferButtonStyle(compact: true))
                .disabled(isBusy)
            }
            .pmAppearFade(.contentAppear)
        }
    }

    private static var localDeviceSymbol: String {
        #if os(macOS)
        AudioCacheSyncPlatform.mac.symbolName
        #else
        UIDevice.current.userInterfaceIdiom == .pad
            ? AudioCacheSyncPlatform.iPad.symbolName
            : AudioCacheSyncPlatform.iPhone.symbolName
        #endif
    }

    private var selectedPeer: AudioCacheSyncPeer? {
        guard let selectedPeerID else { return nil }
        return cacheSync.peers.first { $0.id == selectedPeerID }
    }

    private var selectedPlan: AudioCacheSyncPeerPlan? {
        selectedPeerID.flatMap { cacheSync.peerPlans[$0] }
    }

    private var canStartTransfer: Bool {
        guard cacheSync.operation == .idle, let selectedPlan else { return false }
        return selectedPlan.missingFileCount > 0
    }

    private var primaryActionTitle: String {
        guard let selectedPlan else { return text("cache_sync_select_device") }
        if selectedPlan.missingFileCount == 0, selectedPlan.rejectedCount > 0 {
            return String(format: text("cache_sync_skipped_format"), selectedPlan.rejectedCount)
        }
        return selectedPlan.missingFileCount == 0 ? text("cache_sync_up_to_date") : text("cache_sync_start")
    }

    private var fullSyncConfirmationMessage: String {
        guard let plan = selectedPlan else { return text("cache_sync_select_device") }
        return String(
            format: text("cache_sync_confirm_all_message_format"),
            plan.missingFileCount,
            byteString(plan.missingByteCount)
        )
    }

    private func planDescription(_ plan: AudioCacheSyncPeerPlan) -> String {
        guard plan.missingFileCount > 0 else {
            return plan.rejectedCount > 0
                ? String(format: text("cache_sync_up_to_date_skipped_format"), plan.rejectedCount)
                : text("cache_sync_up_to_date")
        }
        var description = String(
            format: text("cache_sync_missing_format"),
            plan.missingFileCount,
            byteString(plan.missingByteCount)
        )
        if plan.rejectedCount > 0 {
            description += " · " + String(format: text("cache_sync_skipped_format"), plan.rejectedCount)
        }
        return description
    }

    // MARK: - Session

    private func startSession() {
        if cacheSync.incomingTransferCount > 0 { direction = .receive }
        if cacheSync.operation == .transferring {
            selectedPeerID = cacheSync.activePeerID
        } else {
            cacheSync.clearFeedback()
        }
        cacheSync.retryNetworking(discover: direction == .send)
        cacheSync.refreshLocalInventory()
        updateScreenWake(for: cacheSync.operation)
    }

    private func endSession() {
        if cacheSync.operation == .transferring {
            cacheSync.cancelTransfer()
        }
        cacheSync.stopDiscovery()
        #if os(iOS)
        ScreenWakeLeases.update(owner: "audioCacheSync", holds: false)
        #endif
    }

    /// 传输中、等着接收时不锁屏; 和播放时屏幕常亮各持一份, 互不还原对方的。
    private func updateScreenWake(for operation: AudioCacheSyncOperation) {
        #if os(iOS)
        ScreenWakeLeases.update(
            owner: "audioCacheSync",
            holds: operation == .transferring || direction == .receive
        )
        #endif
    }

    private func updateSelection(for peers: [AudioCacheSyncPeer]) {
        guard direction == .send, cacheSync.operation != .transferring else { return }
        if let selectedPeerID, peers.contains(where: { $0.id == selectedPeerID }) { return }
        selectedPeerID = nil
        #if os(macOS)
        let preferred = peers.first
        #else
        let preferred = peers.first(where: { $0.platform == .mac }) ?? (peers.count == 1 ? peers[0] : nil)
        #endif
        if let preferred { select(preferred) }
    }

    private func select(_ peer: AudioCacheSyncPeer) {
        guard cacheSync.operation != .transferring else { return }
        selectedPeerID = peer.id
        cacheSync.clearFeedback()
        cacheSync.inspect(peerID: peer.id)
    }

    private func startSync(maximumFileCount: Int?) {
        guard let selectedPeerID, cacheSync.operation == .idle else { return }
        cacheSync.clearFeedback()
        cacheSync.sync(to: selectedPeerID, maximumFileCount: maximumFileCount)
    }

    private func text(_ key: String) -> String { CacheSyncLocalization.text(key) }

    private func byteString(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
#endif

#if os(macOS) && DEBUG
import AppKit

/// `PRIMUSE_DEBUG_CACHE_SYNC_MAC_SNAPSHOT=<目录>`: 把缓存同步页(发送、接收)和 WiFi 传输页放进屏幕外
/// 窗口, 深浅色各存一张 PNG。编译机常年锁屏截不到真窗口, 改这两页的画风时并排对照用。
@MainActor
enum MacCacheSyncDebugSnapshot {
    private static var window: NSWindow?

    static func writeIfRequested() async {
        guard let path = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_CACHE_SYNC_MAC_SNAPSHOT"],
              !path.isEmpty else { return }
        try? await Task.sleep(for: .seconds(4))
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages: [(name: String, size: CGSize, make: () -> AnyView)] = [
            ("cachesync-send", CGSize(width: 640, height: 640), { AnyView(AudioCacheSyncView(initialDirection: .send)) }),
            ("cachesync-receive", CGSize(width: 640, height: 640), { AnyView(AudioCacheSyncView(initialDirection: .receive)) }),
            ("wifitransfer-send", CGSize(width: 1040, height: 740), { AnyView(WiFiTransferView()) }),
            ("wifitransfer-receive", CGSize(width: 1040, height: 740), { AnyView(WiFiTransferView(initialMode: "receive")) }),
        ]
        for page in pages {
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
                let root = page.make()
                    .frame(width: page.size.width, height: page.size.height)
                    .environment(AppServices.shared.audioCacheSync)
                    .applyPrimuseEnvironments()
                let host = NSHostingView(rootView: root)
                let window = NSWindow(
                    contentRect: NSRect(x: -4000, y: -4000, width: page.size.width, height: page.size.height),
                    styleMask: [.borderless], backing: .buffered, defer: false
                )
                window.appearance = NSAppearance(named: appearance)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFrontRegardless()
                Self.window = window
                try? await Task.sleep(for: .seconds(6))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: directory.appendingPathComponent("\(page.name)-\(suffix).png"))
                    }
                }
                window.orderOut(nil)
                window.contentView = nil
                Self.window = nil
            }
        }
        plog("🧪 cache sync mac snapshots written to \(directory.path)")
    }
}
#endif
