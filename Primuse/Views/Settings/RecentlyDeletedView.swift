import SwiftUI
import PrimuseKit

struct RecentlyDeletedView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var configsTick: Int = 0

    var body: some View {
        Form {
            playlistsSection
            sourcesSection
            scraperConfigsSection
        }
        .navigationTitle("recently_deleted")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if library.recentlyDeletedPlaylists.isEmpty
                && sourcesStore.recentlyDeletedSources.isEmpty
                && ScraperConfigStore.shared.recentlyDeletedConfigs.isEmpty {
                ContentUnavailableView(
                    "recently_deleted_empty",
                    systemImage: "trash",
                    description: Text("recently_deleted_empty_desc")
                )
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
    private var sourcesSection: some View {
        let items = sourcesStore.recentlyDeletedSources
        if !items.isEmpty {
            Section {
                ForEach(items) { source in
                    row(
                        title: source.name,
                        deletedAt: source.deletedAt,
                        systemImage: source.type.iconName,
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
        restore: @escaping () -> Void,
        purge: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let deletedAt {
                    Text(daysRemaining(from: deletedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { purge() } label: {
                Label("delete_permanently", systemImage: "trash.fill")
            }
            Button { restore() } label: {
                Label("restore", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
        }
    }

    private func daysRemaining(from deletedAt: Date) -> String {
        let pruneAt = deletedAt.addingTimeInterval(30 * 24 * 60 * 60)
        let interval = pruneAt.timeIntervalSinceNow
        let days = max(0, Int(interval / 86400))
        return String(format: NSLocalizedString("auto_remove_in_n_days", comment: ""), days)
    }
}
