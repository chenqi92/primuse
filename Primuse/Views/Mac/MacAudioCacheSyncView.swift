#if os(macOS)
import SwiftUI

struct MacAudioCacheSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioCacheSyncService.self) private var cacheSync
    @State private var selectedPeerID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: PMSpace.m14) {
                    localInventoryCard
                    nearbyDevicesSection

                    if let progress = cacheSync.transferProgress,
                       progress.peerID == selectedPeerID {
                        transferProgressCard(progress)
                    }
                    if let completion = cacheSync.lastCompletion,
                       completion.peerID == selectedPeerID {
                        completionCard(completion)
                    }
                    if let error = cacheSync.lastError {
                        feedbackCard(
                            icon: "exclamationmark.triangle.fill",
                            message: error,
                            tint: PMColor.warn
                        )
                    }
                }
                .padding(PMSpace.l)
            }

            footer
        }
        .frame(width: 640, height: 650)
        .background(PMColor.bg)
        .onAppear {
            if cacheSync.operation == .transferring {
                selectedPeerID = cacheSync.activePeerID
            }
            cacheSync.startDiscovery()
            cacheSync.refreshLocalInventory()
        }
        .onDisappear {
            cacheSync.stopDiscovery()
        }
        .onChange(of: cacheSync.peers, initial: true) { _, peers in
            guard cacheSync.operation != .transferring else { return }
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
                cacheSync.startDiscovery()
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
                    .fill(cacheSync.isReceiving ? PMColor.ok : PMColor.warn)
                    .frame(width: 7, height: 7)
                Text(verbatim: localized(
                    cacheSync.isReceiving
                        ? "cache_sync_receiver_ready"
                        : "cache_sync_receiver_starting"
                ))
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .padding(.horizontal, PMSpace.m)
                        .frame(height: 28)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                }
                .buttonStyle(.plain)

                Button {
                    guard let selectedPeerID else { return }
                    cacheSync.sync(to: selectedPeerID)
                } label: {
                    Text(verbatim: primaryActionTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, PMSpace.m16)
                        .frame(height: 28)
                        .background(PMColor.brand, in: .rect(cornerRadius: PMRadius.s))
                }
                .buttonStyle(.plain)
                .disabled(!canStartTransfer)
                .opacity(canStartTransfer ? 1 : 0.45)
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
