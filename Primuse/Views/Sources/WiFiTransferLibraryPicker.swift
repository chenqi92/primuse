#if os(iOS) || os(macOS)
import SwiftUI
import PrimuseKit

struct WiFiTransferLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sources
    let alreadyAdded: Set<String>
    let onSelect: ([String]) -> Void
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var sourceID = ""
    @State private var orderedIDs: [String] = []
    @State private var displayedIDs: [String] = []
    @State private var loading = true
    @State private var snapshots = SongListSnapshotStore()
    @State private var filterRevision = UUID()

    private var enabledSources: [MusicSource] { sources.sources.filter { $0.isEnabled && !$0.isDeleted } }
    private var version: SongListSnapshotVersion {
        .init(collectionRevision: library.visibleSongCollectionRevision, replacementToken: library.songReplacementToken)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Menu {
                        Picker(WiFiTransferText.string("libraryAllSources"), selection: $sourceID) {
                            Text(WiFiTransferText.string("libraryAllSources")).tag("")
                            ForEach(enabledSources) { source in Text(source.name).tag(source.id) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal.decrease")
                            Text(sourceID.isEmpty ? WiFiTransferText.string("libraryAllSources") : (sources.source(id: sourceID)?.name ?? ""))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down").imageScale(.small)
                        }
                        .font(.body)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("transfer.library.source")
                } footer: {
                    Text(WiFiTransferText.string("librarySelectionHint"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    if !loading && displayedIDs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 32))
                                .accessibilityHidden(true)
                            Text(WiFiTransferText.string("libraryEmpty"))
                                .font(.body)
                                .multilineTextAlignment(.center)
                        }
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 24)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(displayedIDs, id: \.self) { id in
                        WiFiTransferLibrarySongRow(songID: id, selected: $selected, alreadyAdded: alreadyAdded.contains(id))
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle(String(localized: "library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: Text(WiFiTransferText.string("librarySearch")))
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(WiFiTransferText.string("cancel")) { dismiss() }
                        .buttonStyle(TransferButtonStyle())
                    Spacer(minLength: 0)
                    Button(String(format: WiFiTransferText.string("libraryAddSelected"), selected.count)) {
                        onSelect(orderedIDs.filter { selected.contains($0) })
                        dismiss()
                    }
                    .buttonStyle(TransferButtonStyle(prominent: true))
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("transfer.confirmSelection")
                }
                .padding(16).background(.bar)
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 580)
        #endif
        .task(id: version) { await loadSongs() }
        .task(id: FilterKey(query: query, sourceID: sourceID, revision: filterRevision)) { await filterSongs() }
        .onDisappear { Task { await snapshots.cancelPending(scopeKey: "transfer-library") } }
    }

    private func loadSongs() async {
        loading = true
        let songs = library.visibleSongs
        let snapshot = await snapshots.snapshot(
            scopeKey: "transfer-library", version: version, order: .title, songs: songs, cancelSuperseded: true
        )
        guard !Task.isCancelled, let snapshot else { return }
        orderedIDs = snapshot.orderedSongIDs
        filterRevision = UUID()
        selected.formIntersection(Set(orderedIDs))
        loading = false
    }

    private func filterSongs() async {
        let songs = library.visibleSongs
        let order = orderedIDs
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = sourceID
        let worker = Task.detached(priority: .userInitiated) {
            let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var result: [String] = []
            for id in order {
                if Task.isCancelled { return [] as [String] }
                guard let song = songsByID[id], sourceID.isEmpty || song.sourceID == sourceID else { continue }
                if query.isEmpty || [song.title, song.artistName ?? "", song.albumTitle ?? ""].contains(where: { $0.localizedStandardContains(query) }) {
                    result.append(song.id)
                }
            }
            return result
        }
        let ids = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        displayedIDs = ids
    }

    private struct FilterKey: Equatable {
        let query: String
        let sourceID: String
        let revision: UUID
    }
}

private struct WiFiTransferLibrarySongRow: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sources
    let songID: String
    @Binding var selected: Set<String>
    let alreadyAdded: Bool

    var body: some View {
        if let song = library.visibleSong(id: songID), let source = sources.source(id: song.sourceID) {
            songRow(song, source: source)
        }
    }
    private func songRow(_ song: Song, source: MusicSource) -> some View {
        let reason = WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: source.type)
        let added = alreadyAdded
        return Button {
            if selected.contains(song.id) { selected.remove(song.id) }
            else if selected.count < 3_000 { selected.insert(song.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: added || selected.contains(song.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(added || selected.contains(song.id) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.body).foregroundStyle(.primary).lineLimit(2)
                    Text([song.artistName, source.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let reason {
                        Text(WiFiTransferText.string(reason)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if added {
                        Text(WiFiTransferText.string("libraryAlreadyAdded")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if song.fileSize > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.vertical, 5).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(reason != nil || added || (!selected.contains(song.id) && selected.count >= 3_000))
        .accessibilityAddTraits(selected.contains(song.id) || added ? .isSelected : [])
    }

}
#endif
