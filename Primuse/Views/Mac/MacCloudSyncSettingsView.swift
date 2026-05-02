#if os(macOS)
import SwiftUI
import AppKit

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
#endif
