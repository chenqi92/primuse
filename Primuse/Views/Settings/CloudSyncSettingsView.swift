import SwiftUI

struct CloudSyncSettingsView: View {
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
                Toggle("icloud_sync_enabled", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        Task {
                            if newValue {
                                await sync.start()
                            } else {
                                sync.stop()
                            }
                        }
                    }
            } footer: {
                Text("icloud_sync_footer")
            }

            if enabled {
                Section("icloud_sync_status") {
                    HStack {
                        Text("status")
                        Spacer()
                        statusLabel
                            .foregroundStyle(.secondary)
                    }

                    if let lastSyncedAt = sync.lastSyncedAt {
                        HStack {
                            Text("last_synced")
                            Spacer()
                            // Named relative format ("just now", "5 minutes ago") —
                            // does NOT tick by seconds. Style `.relative` would.
                            Text(lastSyncedAt.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if case .accountUnavailable(.noAccount) = sync.status {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("open_system_settings", systemImage: "gear")
                        }
                    }

                    Button {
                        isSyncingNow = true
                        Task {
                            await sync.syncNow()
                            isSyncingNow = false
                        }
                    } label: {
                        HStack {
                            Text("sync_now")
                            if isSyncingNow {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isSyncingNow)
                }
            }

            Section {
                channelToggle("synced_playlists", systemImage: "music.note.list", isOn: $syncPlaylists)
                channelToggle("synced_sources", systemImage: "externaldrive.connected.to.line.below", isOn: $syncSources)
                channelToggle("synced_playback_history", systemImage: "clock.arrow.circlepath", isOn: $syncPlaybackHistory)
                channelToggle("synced_settings", systemImage: "slider.horizontal.3", isOn: $syncSettings)
                channelToggle("synced_credentials", systemImage: "lock.shield", isOn: $syncCredentials)
            } header: {
                Text("synced_items")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("synced_items_footer")
                    Text("credentials_channel_footer")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("icloud_sync_title")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A channel toggle that fires a catch-up sync when flipped on.
    private func channelToggle(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(titleKey, systemImage: systemImage)
        }
        .disabled(!enabled)
        .onChange(of: isOn.wrappedValue) { _, newValue in
            guard newValue, enabled else { return }
            Task { await sync.syncNow() }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch sync.status {
        case .disabled:
            Text("status_disabled")
        case .idle:
            Text("status_idle")
        case .syncing:
            Text("status_syncing")
        case .upToDate:
            Text("status_up_to_date")
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
