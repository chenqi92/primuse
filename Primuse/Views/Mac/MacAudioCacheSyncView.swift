#if os(macOS)
import SwiftUI
import AppKit

@MainActor
private struct CacheSyncSheetSizing: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ view: SizingView, context: Context) {
        view.requestedSize = size
        view.scheduleResize()
    }

    final class SizingView: NSView {
        var requestedSize: CGSize = .zero
        private var resizeScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleResize()
        }

        func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                resizeScheduled = false
                let size = requestedSize
                guard let window, window.sheetParent != nil,
                      size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
                let current = window.contentRect(forFrameRect: window.frame).size
                guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }
                // Attached SwiftUI sheets retain their largest frame after their content shrinks.
                window.contentMaxSize = NSSize(width: max(window.contentMaxSize.width, size.width),
                                               height: max(window.contentMaxSize.height, size.height))
                window.contentMinSize = size
                window.setContentSize(size)
            }
        }
    }
}

struct MacAudioCacheSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioCacheSyncService.self) private var cacheSync
    @State private var selectedPeerID: String?
    @State private var direction: AudioCacheSyncDirection = .send
    @State private var contentHeight: CGFloat = 480
    @State private var sheetSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            AudioCacheSyncDirectionPicker(selection: $direction)
                .disabled(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PMSpace.l).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: PMSpace.m14) {
                    if direction == .send {
                    localInventoryCard
                    nearbyDevicesSection
                    }
                    AudioCacheSyncConnectionControls(direction: direction) { peerID in
                        selectedPeerID = peerID
                        cacheSync.inspect(peerID: peerID)
                    }

                    if direction == .send, let progress = cacheSync.transferProgress,
                       progress.peerID == selectedPeerID {
                        transferProgressCard(progress)
                    }
                    if direction == .send, let completion = cacheSync.lastCompletion,
                       completion.peerID == selectedPeerID {
                        completionCard(completion)
                    }
                    if direction == .send, let error = cacheSync.lastError {
                        feedbackCard(
                            icon: "exclamationmark.triangle.fill",
                            message: error,
                            tint: PMColor.warn
                        )
                    }
                }
                .padding(PMSpace.l)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    guard height.isFinite, height > 0, abs(height - contentHeight) > 1 else { return }
                    contentHeight = height
                }
            }
            .frame(height: min(contentHeight, 460))

            footer
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .presentationSizing(.fitted.fitted(horizontal: false, vertical: true))
        .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { sheetSize = $0 }
        .background { CacheSyncSheetSizing(size: sheetSize).allowsHitTesting(false).accessibilityHidden(true) }
        .background(PMColor.bg)
        .interactiveDismissDisabled(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
        .onAppear {
            if cacheSync.incomingTransferCount > 0 { direction = .receive }
            if cacheSync.operation == .transferring {
                selectedPeerID = cacheSync.activePeerID
            }
            cacheSync.retryNetworking(discover: direction == .send)
            cacheSync.refreshLocalInventory()
        }
        .onDisappear {
            cacheSync.stopDiscovery()
        }
        .onChange(of: direction) { _, direction in
            if direction == .send {
                cacheSync.startDiscovery()
            } else {
                cacheSync.stopDiscovery()
            }
        }
        .onChange(of: cacheSync.incomingTransferCount) { _, count in
            if count > 0, cacheSync.operation != .transferring { direction = .receive }
        }
        .onChange(of: cacheSync.peers, initial: true) { _, peers in
            guard direction == .send, cacheSync.operation != .transferring else { return }
            if let selectedPeerID, peers.contains(where: { $0.id == selectedPeerID }) {
                return
            }
            selectedPeerID = peers.first?.id
            if let selectedPeerID {
                cacheSync.inspect(peerID: selectedPeerID)
            }
        }
    }

    private var header: some View {
        HStack(spacing: PMSpace.m14) {
            ZStack {
                RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                    .fill(PMColor.brand.opacity(0.16))
                Image(systemName: "externaldrive.badge.wifi")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: localized("cache_sync_title"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: localized("cache_sync_subtitle"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }

            Spacer()

            Button {
                selectedPeerID = nil
                cacheSync.clearFeedback()
                cacheSync.retryNetworking(discover: direction == .send)
                cacheSync.refreshLocalInventory()
            } label: {
                HStack(spacing: PMSpace.s) {
                    if cacheSync.isDiscovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(verbatim: localized("cache_sync_refresh"))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(PMColor.textMuted)
                .padding(.horizontal, PMSpace.s10)
                .frame(height: 28)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            }
            .buttonStyle(.plain)
            .disabled(cacheSync.operation == .transferring)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 26, height: 26)
                    .background(PMColor.glassBtn, in: .circle)
            }
            .buttonStyle(.plain)
            .help(localized("cache_sync_close"))
            .disabled(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, PMSpace.l)
    }

    private var localInventoryCard: some View {
        HStack(spacing: PMSpace.m14) {
            ZStack {
                RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                    .fill(PMColor.brand.opacity(0.11))
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PMColor.brand)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: localized("cache_sync_local_cache"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                if let inventory = cacheSync.localInventory {
                    Text(verbatim: String(
                        format: localized("cache_sync_inventory_format"),
                        inventory.fileCount,
                        byteString(inventory.byteCount)
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                } else {
                    HStack(spacing: PMSpace.s) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: localized("cache_sync_preparing_inventory"))
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                    }
                }
            }

            Spacer()

            HStack(spacing: PMSpace.s) {
                Circle()
                    .fill(cacheSync.receiverState == .ready ? PMColor.ok : PMColor.warn)
                    .frame(width: 7, height: 7)
                Text(verbatim: localized(cacheSync.receiverState.labelKey))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(PMColor.textMuted)
            }
            .padding(.horizontal, PMSpace.s10)
            .frame(height: 26)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.pill))
        }
        .padding(PMSpace.m14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var nearbyDevicesSection: some View {
        VStack(alignment: .leading, spacing: PMSpace.s8) {
            HStack {
                Text(verbatim: localized("cache_sync_nearby_devices"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(PMColor.textFaint)
                Spacer()
                Text(verbatim: localized("cache_sync_same_wifi_hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) {
                if cacheSync.peers.isEmpty {
                    emptyDevicesState
                } else {
                    ForEach(Array(cacheSync.peers.enumerated()), id: \.element.id) { index, peer in
                        deviceRow(peer)
                        if index < cacheSync.peers.count - 1 {
                            Rectangle()
                                .fill(PMColor.divider)
                                .frame(height: 0.5)
                                .padding(.leading, 58)
                        }
                    }
                }
            }
            .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
        }
    }

    private var emptyDevicesState: some View {
        VStack(spacing: PMSpace.s10) {
            Image(systemName: "wifi.badge.exclamationmark")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(PMColor.textFaint)
            Text(verbatim: localized(
                cacheSync.isDiscovering
                    ? "cache_sync_searching_devices"
                    : "cache_sync_no_devices"
            ))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(PMColor.textMuted)
            Text(verbatim: localized("cache_sync_open_app_hint"))
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func deviceRow(_ peer: AudioCacheSyncPeer) -> some View {
        let selected = selectedPeerID == peer.id
        let plan = cacheSync.peerPlans[peer.id]
        let inspecting = cacheSync.operation == .inspecting && cacheSync.activePeerID == peer.id

        return Button {
            guard cacheSync.operation != .transferring else { return }
            selectedPeerID = peer.id
            cacheSync.clearFeedback()
            cacheSync.inspect(peerID: peer.id)
        } label: {
            HStack(spacing: PMSpace.m) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: peer.platform.symbolName)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(selected ? PMColor.brand : PMColor.textMuted)
                        .frame(width: 36, height: 36)
                        .background(
                            selected ? PMColor.brand.opacity(0.12) : PMColor.glassBtn,
                            in: .rect(cornerRadius: PMRadius.m)
                        )
                    Circle()
                        .fill(PMColor.ok)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(PMColor.bgElev, lineWidth: 1.5))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: peer.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    if inspecting {
                        HStack(spacing: PMSpace.s) {
                            ProgressView().controlSize(.mini)
                            Text(verbatim: localized("cache_sync_comparing"))
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                    } else if let plan {
                        Text(verbatim: planDescription(plan))
                            .font(.system(size: 11.5))
                            .foregroundStyle(plan.missingFileCount == 0 ? PMColor.ok : PMColor.textMuted)
                    } else {
                        Text(verbatim: localized("cache_sync_tap_to_compare"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(PMColor.textMuted)
                    }
                }

                Spacer()

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .padding(.horizontal, PMSpace.m14)
            .frame(minHeight: 60)
            .background(selected ? PMColor.brand.opacity(0.055) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func transferProgressCard(_ progress: AudioCacheSyncTransferProgress) -> some View {
        VStack(alignment: .leading, spacing: PMSpace.s10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: localized("cache_sync_transferring"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: progress.currentTitle ?? localized("cache_sync_preparing_transfer"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(verbatim: String(
                    format: localized("cache_sync_progress_count_format"),
                    progress.completedFileCount,
                    progress.totalFileCount
                ))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(PMColor.glassBtn)
                    Capsule()
                        .fill(PMColor.brand)
                        .frame(width: geometry.size.width * progress.fractionCompleted)
                }
            }
            .frame(height: 5)

            HStack {
                Text(verbatim: byteString(progress.sentByteCount))
                Spacer()
                Text(verbatim: byteString(progress.totalByteCount))
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(PMColor.textFaint)
        }
        .padding(PMSpace.m14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func completionCard(_ completion: AudioCacheSyncTransferCompletion) -> some View {
        feedbackCard(
            icon: completion.failedFileCount == 0
                ? "checkmark.seal.fill"
                : "checkmark.circle.badge.questionmark",
            message: String(
                format: localized("cache_sync_completion_format"),
                completion.transferredFileCount,
                byteString(completion.transferredByteCount),
                completion.failedFileCount
            ),
            tint: completion.failedFileCount == 0 ? PMColor.ok : PMColor.warn
        )
    }

    private func feedbackCard(icon: String, message: String, tint: Color) -> some View {
        HStack(spacing: PMSpace.s10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(verbatim: message)
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
            Spacer()
        }
        .padding(.horizontal, PMSpace.m14)
        .frame(minHeight: 42)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: PMRadius.m10))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m10, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        }
    }

    private var footer: some View {
        HStack(spacing: PMSpace.s8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
            Text(verbatim: localized("cache_sync_encrypted_footer"))
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)

            Spacer()

            if cacheSync.operation == .transferring {
                Button {
                    cacheSync.cancelTransfer()
                } label: {
                    Text(verbatim: localized("cache_sync_stop"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.warn)
                        .padding(.horizontal, PMSpace.m)
                        .frame(height: 28)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    dismiss()
                } label: {
                    Text(verbatim: localized("cache_sync_done"))

                }
                .buttonStyle(TransferButtonStyle())
                .disabled(cacheSync.incomingTransferCount > 0)

                if direction == .send {
                Button {
                    guard let selectedPeerID else { return }
                    cacheSync.sync(to: selectedPeerID)
                } label: {
                    Text(verbatim: primaryActionTitle)
                }
                .buttonStyle(TransferButtonStyle(prominent: true))
                .disabled(!canStartTransfer)
                }
            }
        }
        .padding(.horizontal, PMSpace.l)
        .frame(height: 56)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var selectedPlan: AudioCacheSyncPeerPlan? {
        selectedPeerID.flatMap { cacheSync.peerPlans[$0] }
    }

    private var canStartTransfer: Bool {
        guard cacheSync.operation == .idle,
              let selectedPlan else { return false }
        return selectedPlan.missingFileCount > 0
    }

    private var primaryActionTitle: String {
        guard let selectedPlan else { return localized("cache_sync_select_device") }
        if selectedPlan.missingFileCount == 0, selectedPlan.rejectedCount > 0 {
            return String(format: localized("cache_sync_skipped_format"), selectedPlan.rejectedCount)
        }
        return selectedPlan.missingFileCount == 0
            ? localized("cache_sync_up_to_date")
            : localized("cache_sync_start")
    }

    private func planDescription(_ plan: AudioCacheSyncPeerPlan) -> String {
        if plan.missingFileCount == 0 {
            return plan.rejectedCount > 0
                ? String(
                    format: localized("cache_sync_up_to_date_skipped_format"),
                    plan.rejectedCount
                )
                : localized("cache_sync_up_to_date")
        }
        var text = String(
            format: localized("cache_sync_missing_format"),
            plan.missingFileCount,
            byteString(plan.missingByteCount)
        )
        if plan.rejectedCount > 0 {
            text += " · " + String(
                format: localized("cache_sync_skipped_format"),
                plan.rejectedCount
            )
        }
        return text
    }

    private func localized(_ key: String) -> String {
        CacheSyncLocalization.text(key)
    }

    private func byteString(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
#endif

#if os(iOS) || os(macOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AudioCacheSyncDirection: String, CaseIterable {
    case send, receive
    var title: String { CacheSyncLocalization.text("cache_sync_mode_" + rawValue) }
}

struct AudioCacheSyncDirectionPicker: View {
    @Binding var selection: AudioCacheSyncDirection

    var body: some View {
        Picker(CacheSyncLocalization.text("cache_sync_title"), selection: $selection) {
            ForEach(AudioCacheSyncDirection.allCases, id: \.self) { direction in
                Text(verbatim: direction.title).tag(direction)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #if os(macOS)
        .controlSize(.regular)
        #endif
    }
}

private struct AudioCacheSyncConnectionControls: View {
    @Environment(AudioCacheSyncService.self) private var cacheSync
    @Environment(\.openURL) private var openURL
    let direction: AudioCacheSyncDirection
    let onConnect: (String) -> Void
    @State private var enteredCode = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: text(direction == .send ? "cache_sync_send_steps" : "cache_sync_receive_steps"))
                .font(.callout)
                .foregroundStyle(.secondary)

            if direction == .receive {
                Label(cacheSync.localDeviceName, systemImage: "externaldrive.badge.wifi")
                    .font(.headline)
                Label {
                    Text(verbatim: text(cacheSync.receiverState.labelKey))
                } icon: {
                    Image(systemName: cacheSync.receiverState == .ready ? "checkmark.circle.fill" : "exclamationmark.circle")
                }
                .foregroundStyle(cacheSync.receiverState == .ready ? Color.green : Color.orange)

                if cacheSync.incomingTransferCount > 0 {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(verbatim: text("cache_sync_receiving"))
                    }
                }
                if cacheSync.receivedFileCount > 0 {
                    Text(verbatim: String(
                        format: text("cache_sync_received_format"), cacheSync.receivedFileCount,
                        ByteCountFormatter.string(fromByteCount: cacheSync.receivedByteCount, countStyle: .file)
                    ))
                    .font(.callout.monospacedDigit())
                }
                if let error = cacheSync.incomingError {
                    Text(verbatim: error).foregroundStyle(.orange)
                }

                if let code = cacheSync.connectionCode {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            connectionCodeActions(code)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 10) {
                            connectionCodeActions(code)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                } else if cacheSync.isReceiving {
                    Text(verbatim: text("cache_sync_no_local_address"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text(verbatim: text("cache_sync_matching_library_hint"))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: text("cache_sync_connect_code"))
                        .font(.headline)
                    Text(verbatim: text("cache_sync_connect_code_hint"))
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField(text("cache_sync_code_placeholder"), text: $enteredCode, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                        .autocorrectionDisabled()
                        .disabled(cacheSync.operation != .idle)
                        .accessibilityIdentifier("cacheSync.connectionCode")
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button {
                        if let peerID = cacheSync.connect(using: enteredCode) {
                            onConnect(peerID)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                            Text(verbatim: text("cache_sync_connect"))
                        }
                        #if os(iOS)
                        .frame(maxWidth: .infinity)
                        #endif
                    }
                    .buttonStyle(TransferButtonStyle(prominent: true))
                    .disabled(enteredCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cacheSync.operation != .idle)
                    .accessibilityIdentifier("cacheSync.connect")
                }
            }

            if let issue = direction == .send ? cacheSync.discoveryIssue : cacheSync.receiverIssue {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                HStack {
                    Button(text("cache_sync_retry")) {
                        cacheSync.retryNetworking(discover: direction == .send)
                    }
                    if issue == .permissionDenied {
                        Button(text("cache_sync_open_settings")) {
                            #if os(iOS)
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                            #else
                            openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                            #endif
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .padding(PMSpace.m14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.l))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        #endif
        .onChange(of: cacheSync.connectionCode) { _, _ in copied = false }
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
            connectionCodeActionLabel(text(copied ? "cache_sync_code_copied" : "cache_sync_copy_code"),
                                      icon: copied ? "checkmark" : "doc.on.doc")
        }
        .accessibilityIdentifier("cacheSync.copyCode")
        ShareLink(item: code) {
            connectionCodeActionLabel(text("cache_sync_share_code"), icon: "square.and.arrow.up")
        }
        .accessibilityIdentifier("cacheSync.shareCode")
    }

    private func connectionCodeActionLabel(_ title: String, icon: String) -> some View {
        // Form's automatic Label styling reserves a large leading icon column.
        HStack(spacing: 8) {
            Image(systemName: icon).imageScale(.medium)
            Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout.weight(.medium))
        #if os(iOS)
        .padding(.vertical, 6)
        #endif
    }

    private func text(_ key: String) -> String { CacheSyncLocalization.text(key) }
}
#endif

#if os(iOS)
import SwiftUI

struct IOSAudioCacheSyncView: View {
    var isPresentedAsSheet = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioCacheSyncService.self) private var cacheSync
    @State private var selectedPeerID: String?
    @State private var direction: AudioCacheSyncDirection = .send
    @State private var showsFullSyncConfirmation = false
    @State private var previousIdleTimerDisabled = false

    var body: some View {
        Form {
            Section {
                AudioCacheSyncDirectionPicker(selection: $direction)
                    .disabled(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
            }
            if direction == .send {
            localInventorySection
            nearbyDevicesSection

            if let peer = selectedPeer {
                selectedDeviceSection(peer)
            }
            }
            Section {
                AudioCacheSyncConnectionControls(direction: direction) { peerID in
                    selectedPeerID = peerID
                    cacheSync.inspect(peerID: peerID)
                }
            }

            if direction == .send, let progress = cacheSync.transferProgress,
               progress.peerID == selectedPeerID {
                transferProgressSection(progress)
            }

            if direction == .send, let completion = cacheSync.lastCompletion,
               completion.peerID == selectedPeerID {
                completionSection(completion)
            }

            if direction == .send, let error = cacheSync.lastError {
                errorSection(error)
            }
        }
        .navigationTitle(localized("cache_sync_title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
        .interactiveDismissDisabled(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
        .toolbar {
            if isPresentedAsSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                        .disabled(cacheSync.operation == .transferring || cacheSync.incomingTransferCount > 0)
                }
            }
        }
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
        .confirmationDialog(
            localized("cache_sync_confirm_all_title"),
            isPresented: $showsFullSyncConfirmation,
            titleVisibility: .visible
        ) {
            Button(localized("cache_sync_sync_all")) {
                startSync(maximumFileCount: nil)
            }
            Button(role: .cancel) {
            } label: {
                Text("cancel")
            }
        } message: {
            Text(verbatim: fullSyncConfirmationMessage)
        }
    }

    private var localInventorySection: some View {
        Section {
            LabeledContent {
                if let inventory = cacheSync.localInventory {
                    Text(verbatim: String(
                        format: localized("cache_sync_inventory_format"),
                        inventory.fileCount,
                        byteString(inventory.byteCount)
                    ))
                    .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } label: {
                Text(verbatim: localized("cache_sync_local_cache"))
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: localized("cache_sync_device_status"))
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: cacheSync.isReceiving ? "checkmark.circle.fill" : "clock.fill")
                    Text(verbatim: localized(cacheSync.receiverState.labelKey))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(cacheSync.receiverState == .ready ? Color.green : Color.orange)
            }
        } header: {
            Text(verbatim: localized("cache_sync_local_device"))
        } footer: {
            Text(verbatim: localized("cache_sync_local_network_footer"))
        }
    }

    private var nearbyDevicesSection: some View {
        Section {
            if cacheSync.peers.isEmpty {
                HStack(spacing: 10) {
                    if cacheSync.isDiscovering {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: localized(
                        cacheSync.isDiscovering
                            ? "cache_sync_searching_devices"
                            : "cache_sync_no_devices"
                    ))
                    .foregroundStyle(.secondary)
                }
            } else {
                ForEach(cacheSync.peers) { peer in
                    peerRow(peer)
                }
            }

            Button {
                cacheSync.clearFeedback()
                cacheSync.retryNetworking()
            } label: {
                Label {
                    Text(verbatim: localized("cache_sync_refresh"))
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(cacheSync.operation == .transferring)
        } header: {
            Text(verbatim: localized("cache_sync_nearby_devices"))
        } footer: {
            Text(verbatim: localized("cache_sync_open_app_hint"))
        }
    }

    private func peerRow(_ peer: AudioCacheSyncPeer) -> some View {
        Button {
            select(peer)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: peer.platform.symbolName)
                    .font(.title3)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: peer.name)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let plan = cacheSync.peerPlans[peer.id] {
                        Text(verbatim: planDescription(plan))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: localized("cache_sync_tap_to_compare"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if cacheSync.operation == .inspecting,
                   cacheSync.activePeerID == peer.id {
                    ProgressView()
                        .controlSize(.small)
                } else if selectedPeerID == peer.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cacheSync.operation == .transferring)
    }

    @ViewBuilder
    private func selectedDeviceSection(_ peer: AudioCacheSyncPeer) -> some View {
        Section {
            if cacheSync.operation == .inspecting,
               cacheSync.activePeerID == peer.id {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: localized("cache_sync_comparing"))
                }
            } else if let plan = cacheSync.peerPlans[peer.id] {
                LabeledContent {
                    Text(verbatim: planDescription(plan))
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(verbatim: localized("cache_sync_missing_on_target"))
                }

                if plan.missingFileCount > 0 {
                    Button {
                        startSync(maximumFileCount: 3)
                    } label: {
                        Label {
                            Text(verbatim: localized("cache_sync_test_three"))
                        } icon: {
                            Image(systemName: "testtube.2")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(cacheSync.operation != .idle)

                    Button {
                        showsFullSyncConfirmation = true
                    } label: {
                        Label {
                            Text(verbatim: localized("cache_sync_sync_all"))
                        } icon: {
                            Image(systemName: "arrow.left.arrow.right.circle.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cacheSync.operation != .idle)
                } else {
                    Label {
                        Text(verbatim: localized("cache_sync_up_to_date"))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .foregroundStyle(.green)
                }
            } else {
                Button {
                    cacheSync.inspect(peerID: peer.id)
                } label: {
                    Text(verbatim: localized("cache_sync_tap_to_compare"))
                        .frame(maxWidth: .infinity)
                }
            }
        } header: {
            Text(verbatim: peer.name)
        } footer: {
            Text(verbatim: localized("cache_sync_test_three_footer"))
        }
    }

    private func transferProgressSection(
        _ progress: AudioCacheSyncTransferProgress
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: progress.currentTitle
                     ?? localized("cache_sync_preparing_transfer"))
                    .lineLimit(2)

                ProgressView(value: progress.fractionCompleted)

                HStack {
                    Text(verbatim: String(
                        format: localized("cache_sync_progress_count_format"),
                        progress.completedFileCount + progress.failedFileCount,
                        progress.totalFileCount
                    ))
                    Spacer()
                    Text(verbatim: "\(byteString(progress.sentByteCount)) / \(byteString(progress.totalByteCount))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                cacheSync.cancelTransfer()
            } label: {
                Text(verbatim: localized("cache_sync_stop"))
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text(verbatim: localized("cache_sync_transferring"))
        } footer: {
            Text(verbatim: localized("cache_sync_keep_foreground"))
        }
    }

    private func completionSection(
        _ completion: AudioCacheSyncTransferCompletion
    ) -> some View {
        Section {
            Label {
                Text(verbatim: String(
                    format: localized("cache_sync_completion_format"),
                    completion.transferredFileCount,
                    byteString(completion.transferredByteCount),
                    completion.failedFileCount
                ))
            } icon: {
                Image(systemName: completion.failedFileCount == 0
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
            }
            .foregroundStyle(
                completion.failedFileCount == 0 ? Color.green : Color.orange
            )

            if !completion.transferredTitles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: localized("cache_sync_test_transferred_titles"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(
                        Array(completion.transferredTitles.enumerated()),
                        id: \.offset
                    ) { _, title in
                        Label {
                            Text(verbatim: title)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: "music.note")
                        }
                    }
                }
            }

            Button {
                cacheSync.clearFeedback()
            } label: {
                Text(verbatim: localized("cache_sync_done"))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)

            Button {
                cacheSync.clearFeedback()
                if let selectedPeerID {
                    cacheSync.inspect(peerID: selectedPeerID)
                } else {
                    cacheSync.startDiscovery()
                }
            } label: {
                Text(verbatim: localized("cache_sync_retry"))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var selectedPeer: AudioCacheSyncPeer? {
        guard let selectedPeerID else { return nil }
        return cacheSync.peers.first { $0.id == selectedPeerID }
    }

    private var selectedPlan: AudioCacheSyncPeerPlan? {
        guard let selectedPeerID else { return nil }
        return cacheSync.peerPlans[selectedPeerID]
    }

    private var fullSyncConfirmationMessage: String {
        guard let plan = selectedPlan else {
            return localized("cache_sync_select_device")
        }
        return String(
            format: localized("cache_sync_confirm_all_message_format"),
            plan.missingFileCount,
            byteString(plan.missingByteCount)
        )
    }

    private func startSession() {
        if cacheSync.incomingTransferCount > 0 { direction = .receive }
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        cacheSync.clearFeedback()
        cacheSync.retryNetworking(discover: direction == .send)
        cacheSync.refreshLocalInventory()
        updateScreenWake(for: cacheSync.operation)
    }

    private func endSession() {
        if cacheSync.operation == .transferring {
            cacheSync.cancelTransfer()
        }
        cacheSync.stopDiscovery()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }

    private func updateScreenWake(for operation: AudioCacheSyncOperation) {
        UIApplication.shared.isIdleTimerDisabled =
            previousIdleTimerDisabled || operation == .transferring || direction == .receive
    }

    private func updateSelection(for peers: [AudioCacheSyncPeer]) {
        guard direction == .send, cacheSync.operation != .transferring else { return }
        if let selectedPeerID,
           peers.contains(where: { $0.id == selectedPeerID }) {
            return
        }
        selectedPeerID = nil
        let preferred = peers.first(where: { $0.platform.rawValue == "mac" })
            ?? (peers.count == 1 ? peers[0] : nil)
        if let preferred {
            select(preferred)
        }
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
        cacheSync.sync(
            to: selectedPeerID,
            maximumFileCount: maximumFileCount
        )
    }

    private func planDescription(_ plan: AudioCacheSyncPeerPlan) -> String {
        guard plan.missingFileCount > 0 else {
            return plan.rejectedCount > 0
                ? String(
                    format: localized("cache_sync_up_to_date_skipped_format"),
                    plan.rejectedCount
                )
                : localized("cache_sync_up_to_date")
        }
        var text = String(
            format: localized("cache_sync_missing_format"),
            plan.missingFileCount,
            byteString(plan.missingByteCount)
        )
        if plan.rejectedCount > 0 {
            text += " · " + String(
                format: localized("cache_sync_skipped_format"),
                plan.rejectedCount
            )
        }
        return text
    }

    private func localized(_ key: String) -> String {
        CacheSyncLocalization.text(key)
    }

    private func byteString(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
#endif
