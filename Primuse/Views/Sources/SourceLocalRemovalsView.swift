import PrimuseKit
import SwiftUI

/// Rows this device dropped while the source copy stayed in place.
///
/// The entry point only appears when a source actually has entries, so it
/// covers both situations that produce them: a protocol with no delete verb
/// (Subsonic family, UPnP, the read-only catalogues) and a mount whose account
/// was refused — a WebDAV share answering 403/405, a read-only export. Both are
/// recoverable here; nothing on the server was touched.
struct SourceLocalRemovalsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore

    let source: MusicSource

    @State private var errorMessage: String?
    @State private var showRestoreAllConfirmation = false

    private var entries: [SongLocalRemovalEntry] {
        library.locallyRemovedEntries(forSourceID: source.id)
    }

    var body: some View {
        List {
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text("local_removals_section")
                } footer: {
                    Text("local_removals_footer")
                }
            }
        }
        .navigationTitle("local_removals_title")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if entries.isEmpty {
                EmptyStateView(
                    titleKey: "local_removals_empty",
                    descriptionKey: "local_removals_empty_desc",
                    systemImage: "arrow.uturn.backward.circle"
                )
            }
        }
        .toolbar {
            if !entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("local_removals_restore_all") {
                        showRestoreAllConfirmation = true
                    }
                }
            }
        }
        .confirmationDialog(
            "local_removals_restore_all",
            isPresented: $showRestoreAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("restore") {
                restore(entries.map(\.song.id))
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(verbatim: String(
                format: String(localized: "local_removals_restore_all_message_format"),
                entries.count
            ))
        }
        .alert(
            "local_removals_restore_failed_title",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("done", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(_ entry: SongLocalRemovalEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: entry.song.title)
                    .font(.body)
                    .lineLimit(1)
                Text(verbatim: entry.song.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(reasonDescription(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("restore") {
                restore([entry.song.id])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func reasonDescription(_ entry: SongLocalRemovalEntry) -> String {
        let reason = switch entry.reason {
        case .sourceDoesNotSupportDeletion:
            String(localized: "local_removal_reason_unsupported")
        case .remoteDeletionDenied:
            String(localized: "local_removal_reason_denied")
        case .userKeptRemoteFile:
            String(localized: "local_removal_reason_user_choice")
        }
        // A timestamp of zero is a v2 ledger entry: it predates the reason
        // being recorded, so showing an epoch date would be a lie.
        guard entry.removedAt.timeIntervalSince1970 > 0 else { return reason }
        let stamp = entry.removedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(reason) · \(stamp)"
    }

    private func restore(_ songIDs: [String]) {
        do {
            let remainingCounts = try library.restoreSongsRemovedFromThisDevice(songIDs)
            for (sourceID, remaining) in remainingCounts {
                sourcesStore.updateLocal(sourceID) { $0.songCount = remaining }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
