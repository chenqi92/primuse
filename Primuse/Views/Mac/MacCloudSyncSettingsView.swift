#if os(macOS)
import SwiftUI
import AppKit
import CloudKit

/// macOS-native iCloud sync pane. Mirrors Apple Music's settings panes:
/// a single grouped Form with bold section headers, switches on the right,
/// helper text under each section. Replaces the earlier VStack-of-GroupBoxes
/// look so this tab matches Playback / Audio Effects / About visually.
struct MacCloudSyncSettingsView: View {
    @Environment(CloudKitSyncService.self) private var sync
    @AppStorage("primuse.iCloudSyncEnabled") private var enabled: Bool = true
    @AppStorage(CloudSyncChannel.playlists.defaultsKey) private var syncPlaylists: Bool = true
    @AppStorage(CloudSyncChannel.sources.defaultsKey) private var syncSources: Bool = true
    @AppStorage(CloudSyncChannel.playbackHistory.defaultsKey) private var syncPlaybackHistory: Bool = true
    @AppStorage(CloudSyncChannel.settings.defaultsKey) private var syncSettings: Bool = true
    @AppStorage(CloudSyncChannel.credentials.defaultsKey) private var syncCredentials: Bool = true
    @AppStorage(CloudSyncChannel.listeningStats.defaultsKey) private var syncListeningStats: Bool = true
    @State private var isSyncingNow = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Label("icloud_sync_enabled", systemImage: "icloud")
                }
                .toggleStyle(.switch)
                .onChange(of: enabled) { _, newValue in
                    Task {
                        if newValue { await sync.start() } else { sync.stop() }
                    }
                }
            } footer: {
                Text("icloud_sync_footer")
            }

            if enabled {
                Section("icloud_sync_status") {
                    LabeledContent {
                        statusLabel
                    } label: {
                        Text("status")
                    }

                    if let lastSyncedAt = sync.lastSyncedAt {
                        LabeledContent {
                            Text(lastSyncedAt.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("last_synced")
                        }
                    }

                    HStack {
                        if case .accountUnavailable(.noAccount) = sync.status {
                            Button {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("open_system_settings", systemImage: "gear")
                            }
                        }

                        Spacer()

                        Button {
                            isSyncingNow = true
                            Task {
                                await sync.syncNow()
                                isSyncingNow = false
                            }
                        } label: {
                            if isSyncingNow {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("sync_now")
                                }
                            } else {
                                Label("sync_now", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSyncingNow)
                    }
                }

                Section {
                    channelToggle("synced_playlists",
                                  systemImage: "music.note.list",
                                  isOn: $syncPlaylists,
                                  channel: .playlists)
                    channelToggle("synced_sources",
                                  systemImage: "externaldrive.connected.to.line.below",
                                  isOn: $syncSources,
                                  channel: .sources)
                    channelToggle("synced_playback_history",
                                  systemImage: "clock.arrow.circlepath",
                                  isOn: $syncPlaybackHistory,
                                  channel: .playbackHistory)
                    channelToggle("synced_settings",
                                  systemImage: "slider.horizontal.3",
                                  isOn: $syncSettings,
                                  channel: .settings)
                    channelToggle("synced_credentials",
                                  systemImage: "lock.shield",
                                  isOn: $syncCredentials,
                                  channel: .credentials)
                    channelToggle("stats_title",
                                  systemImage: "chart.bar.xaxis",
                                  isOn: $syncListeningStats,
                                  channel: .listeningStats)
                } header: {
                    Text("synced_items")
                } footer: {
                    Text("synced_items_footer")
                }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "key.icloud")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("keychain_sync_hint_title")
                                .font(.callout)
                                .fontWeight(.semibold)
                            Text("keychain_sync_hint_body")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Text("open_keychain_settings")
                            }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                }

                MacFamilySharingSection()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func channelToggle(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        isOn: Binding<Bool>,
        channel: CloudSyncChannel
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(titleKey, systemImage: systemImage)
        }
        .toggleStyle(.switch)
        .disabled(!enabled)
        .onChange(of: isOn.wrappedValue) { _, newValue in
            guard newValue, enabled else { return }
            Task { await sync.catchUp(channel: channel) }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch sync.status {
        case .disabled:
            Text("status_disabled").foregroundStyle(.secondary)
        case .idle:
            Text("status_idle").foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("status_syncing").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("status_up_to_date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .accountUnavailable(let reason):
            Text(reason.localizedKey)
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .quotaExceeded:
            Text("status_quota_exceeded")
                .foregroundStyle(.red)
        case .networkUnavailable:
            Text("status_network_unavailable")
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Family Sharing (macOS)

/// macOS 端的家庭共享 section,逻辑跟 iOS 的 FamilySharingSettingsView 平齐:
/// 未启用显示「创建家庭包」、已启用显示状态 + 邀请 / 解散。邀请走
/// NSSharingServicePicker 拿系统级 sharing menu (Mail / Messages / Copy Link)。
private struct MacFamilySharingSection: View {
    @Environment(CloudKitSyncService.self) private var sync
    @State private var familyEnabled = CloudKitSyncService.familySharingEnabled
    @State private var errorMessage: String?
    @State private var isBusy = false
    /// 拿到 share 后,把 url 暂存,触发 NSSharingServicePicker 弹出。
    @State private var pendingShareURL: URL?

    var body: some View {
        Section {
            if familyEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("family_sharing_active")
                }

                HStack {
                    Button {
                        Task { await invite(reuseExisting: true) }
                    } label: {
                        Label("family_sharing_manage", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(isBusy)

                    Spacer()

                    Button(role: .destructive) {
                        Task { await disable() }
                    } label: {
                        Label("family_sharing_leave", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .disabled(isBusy)
                }
            } else {
                Button {
                    Task { await invite(reuseExisting: false) }
                } label: {
                    Label("family_sharing_create", systemImage: "person.2.badge.plus")
                }
                .disabled(isBusy)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("family_sharing_title")
        } footer: {
            Text("family_sharing_footer").font(.footnote)
        }
        .background(
            // NSSharingServicePicker 是 AppKit 弹出物, 不属于 SwiftUI 视图
            // 树, 这里用一个零尺寸 anchor 等 pendingShareURL 被赋值时拉起。
            SharePickerAnchor(url: $pendingShareURL)
        )
    }

    @MainActor
    private func invite(reuseExisting: Bool) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let share = try await sync.enableFamilySharing()
            familyEnabled = true
            // share.url 在 share 已 save 后非 nil; CloudKit 会异步生成,
            // 兜底用 short-poll 等 1s。
            if let url = share.url {
                pendingShareURL = url
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                pendingShareURL = share.url
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func disable() async {
        isBusy = true
        defer { isBusy = false }
        await sync.disableFamilySharing()
        familyEnabled = false
    }
}

/// NSSharingServicePicker 桥:`url` binding 一旦非 nil, 在主窗口里
/// 弹一次系统分享 menu, 然后清回 nil 等下次。
private struct SharePickerAnchor: NSViewRepresentable {
    @Binding var url: URL?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let url else { return }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: [url])
            // 锚到主窗口 contentView 中央偏下, 避免被 settings tab 遮住。
            let anchor: NSView = NSApp.keyWindow?.contentView ?? nsView
            picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
            self.url = nil
        }
    }
}
#endif
