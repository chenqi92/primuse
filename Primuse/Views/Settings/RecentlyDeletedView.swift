import SwiftUI
import PrimuseKit

struct RecentlyDeletedView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var configsTick: Int = 0
    @State private var showClearAllConfirmation = false
    @State private var pendingPurgePlan: RecentlyDeletedPurgePlan?
    @State private var clearAllFailureCount = 0

    private var purgePlan: RecentlyDeletedPurgePlan {
        let _ = configsTick
        return RecentlyDeletedPurgePlan(
            playlistIDs: Set(library.recentlyDeletedPlaylists.map(\.id)),
            smartPlaylistIDs: Set(library.recentlyDeletedSmartPlaylists.map(\.id)),
            sourceIDs: Set(sourcesStore.recentlyDeletedSources.map(\.id)),
            scraperConfigurationIDs: Set(
                ScraperConfigStore.shared.recentlyDeletedConfigs.map(\.id)
            )
        )
    }

    var body: some View {
        Form {
            playlistsSection
            smartPlaylistsSection
            hiddenMirrorPlaylistsSection
            sourcesSection
            scraperConfigsSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #else
        .navigationTitle("recently_deleted")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !purgePlan.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("clear_all", role: .destructive) {
                        pendingPurgePlan = purgePlan
                        showClearAllConfirmation = true
                    }
                }
            }
        }
        .confirmationDialog(
            "recently_deleted_clear_all_confirm_title",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("clear_all", role: .destructive) {
                if let pendingPurgePlan {
                    clearAll(pendingPurgePlan)
                }
                pendingPurgePlan = nil
            }
            Button("cancel", role: .cancel) { pendingPurgePlan = nil }
        } message: {
            Text(verbatim: String(
                format: String(localized: "recently_deleted_clear_all_confirm_message_format"),
                pendingPurgePlan?.count ?? 0
            ))
        }
        .alert(
            "recently_deleted_clear_all_failed_title",
            isPresented: Binding(
                get: { clearAllFailureCount > 0 },
                set: { if !$0 { clearAllFailureCount = 0 } }
            )
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(verbatim: String(
                format: String(localized: "recently_deleted_clear_all_failed_format"),
                clearAllFailureCount
            ))
        }
        .overlay {
            if library.recentlyDeletedPlaylists.isEmpty
                && library.recentlyDeletedSmartPlaylists.isEmpty
                && library.hiddenMirrorPlaylists.isEmpty
                && sourcesStore.recentlyDeletedSources.isEmpty
                && ScraperConfigStore.shared.recentlyDeletedConfigs.isEmpty {
                EmptyStateView(
                    titleKey: "recently_deleted_empty",
                    descriptionKey: "recently_deleted_empty_desc",
                    systemImage: "trash"
                )
            }
        }
    }

    @ViewBuilder
    private var hiddenMirrorPlaylistsSection: some View {
        let items = library.hiddenMirrorPlaylists
        if !items.isEmpty {
            Section {
                ForEach(items) { suppression in
                    hiddenMirrorRow(suppression)
                }
            } header: {
                Text("hidden_source_playlists")
            } footer: {
                Text("hidden_source_playlists_desc")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var playlistsSection: some View {
        let items = library.recentlyDeletedPlaylists
        if !items.isEmpty {
            Section {
                ForEach(items) { playlist in
                    row(
                        title: playlist.name,
                        deletedAt: playlist.deletedAt,
                        systemImage: "music.note.list",
                        restore: { library.restorePlaylist(id: playlist.id) },
                        purge: { library.permanentlyDeletePlaylist(id: playlist.id) }
                    )
                }
            } header: {
                Text("recently_deleted_playlists")
            }
        }
    }

    @ViewBuilder
    private var smartPlaylistsSection: some View {
        let items = library.recentlyDeletedSmartPlaylists
        if !items.isEmpty {
            Section {
                ForEach(items) { playlist in
                    row(
                        title: playlist.name,
                        deletedAt: playlist.deletedAt,
                        systemImage: "sparkles",
                        restore: { library.restoreSmartPlaylist(id: playlist.id) },
                        purge: { library.permanentlyDeleteSmartPlaylist(id: playlist.id) }
                    )
                }
            } header: {
                Text("recently_deleted_smart_playlists")
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        let items = sourcesStore.recentlyDeletedSources
        if !items.isEmpty {
            Section {
                ForEach(items) { source in
                    row(
                        title: source.name,
                        deletedAt: source.deletedAt,
                        systemImage: source.type.iconName,
                        statusMessage: sourcesStore.permanentDeletionFailureIDs.contains(source.id)
                            ? "\(String(localized: "status_unavailable")) · \(String(localized: "retry"))"
                            : nil,
                        restore: { sourcesStore.restore(id: source.id) },
                        purge: { sourcesStore.permanentlyDelete(id: source.id) }
                    )
                }
            } header: {
                Text("recently_deleted_sources")
            }
        }
    }

    @ViewBuilder
    private var scraperConfigsSection: some View {
        let _ = configsTick // re-evaluate when configsTick bumps
        let items = ScraperConfigStore.shared.recentlyDeletedConfigs
        if !items.isEmpty {
            Section {
                ForEach(items) { config in
                    row(
                        title: config.name,
                        deletedAt: config.deletedAt,
                        systemImage: "wand.and.stars",
                        restore: {
                            ScraperConfigStore.shared.restore(id: config.id)
                            configsTick += 1
                        },
                        purge: {
                            ScraperConfigStore.shared.permanentlyDelete(id: config.id)
                            configsTick += 1
                        }
                    )
                }
            } header: {
                Text("recently_deleted_scraper_configs")
            }
        }
    }

    // MARK: - Row

    private func row(
        title: String,
        deletedAt: Date?,
        systemImage: String,
        statusMessage: String? = nil,
        restore: @escaping () -> Void,
        purge: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let deletedAt {
                    Text(daysRemaining(from: deletedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // macOS 没法 swipe,inline 给两个按钮(恢复 / 彻底删除)。
            // iOS 维持 swipeActions,行内不再插按钮以免和滑动冲突。
            #if os(macOS)
            Button {
                restore()
            } label: {
                Label("restore", systemImage: "arrow.uturn.backward")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("restore"))

            Button(role: .destructive) {
                purge()
            } label: {
                Label("delete_permanently", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("delete_permanently"))
            #endif
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { purge() } label: {
                Label("delete_permanently", systemImage: "trash.fill")
            }
            Button { restore() } label: {
                Label("restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
        #endif
    }

    private func hiddenMirrorRow(_ suppression: MirrorPlaylistSuppression) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(suppression.displayName)
                Text(suppression.hiddenAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            #if os(macOS)
            Button {
                library.restoreHiddenMirrorPlaylist(suppression)
            } label: {
                Label("restore_hidden_playlist", systemImage: "eye")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("restore_hidden_playlist"))
            #endif
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                library.restoreHiddenMirrorPlaylist(suppression)
            } label: {
                Label("restore_hidden_playlist", systemImage: "eye")
            }
            .tint(.blue)
        }
        #endif
    }

    private func daysRemaining(from deletedAt: Date) -> String {
        let days = RecoverableDeletionPolicy.daysRemaining(deletedAt: deletedAt)
        return String(format: NSLocalizedString("auto_remove_in_n_days", comment: ""), days)
    }

    private func clearAll(_ plan: RecentlyDeletedPurgePlan) {
        guard !plan.isEmpty else { return }
        library.permanentlyDeletePlaylists(ids: plan.playlistIDs)
        library.permanentlyDeleteSmartPlaylists(ids: plan.smartPlaylistIDs)
        let sourceResults = sourcesStore.permanentlyDelete(ids: plan.sourceIDs)
        let deletedConfigIDs = ScraperConfigStore.shared.permanentlyDelete(
            ids: plan.scraperConfigurationIDs
        )
        configsTick &+= 1

        let failedSourceCount = sourceResults.values.filter {
            $0 == .credentialCleanupFailed || $0 == .deletionLedgerPersistFailed
        }.count
        let failedPlaylistCount = library.recentlyDeletedPlaylists.filter {
            plan.playlistIDs.contains($0.id)
        }.count
        let failedSmartPlaylistCount = library.recentlyDeletedSmartPlaylists.filter {
            plan.smartPlaylistIDs.contains($0.id)
        }.count
        let failedConfigCount = plan.scraperConfigurationIDs
            .subtracting(deletedConfigIDs)
            .count
        clearAllFailureCount = failedSourceCount
            + failedPlaylistCount
            + failedSmartPlaylistCount
            + failedConfigCount
    }
}
