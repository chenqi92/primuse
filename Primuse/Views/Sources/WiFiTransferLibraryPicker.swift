#if os(iOS) || os(macOS)
import SwiftUI
import PrimuseKit

struct WiFiTransferLibraryTree: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sources
    @Binding var selected: Set<String>
    @State private var query = ""
    @State private var selectionError: String?
    @State private var selectionRevision = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(WiFiTransferText.string("librarySearch"), text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("transfer.library.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel(String(localized: "clear"))
                }
            }
            .font(.callout).padding(14)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sources.sources.filter { $0.isEnabled && !$0.isDeleted }) { source in
                        TransferLibrarySourceBranch(source: source, query: query, selected: $selected,
                                                    selectionError: $selectionError, selectionRevision: $selectionRevision,
                                                    initiallyExpanded: source.id == sources.sources.first(where: { $0.isEnabled && !$0.isDeleted && $0.type != .appleMusic })?.id)
                    }
                    if library.visibleSongs.isEmpty {
                        Text(WiFiTransferText.string("libraryEmpty"))
                            .foregroundStyle(.secondary).padding(24)
                    }
                }
            }
            .accessibilityIdentifier("transfer.library.tree")
            Divider()
            HStack {
                Text(WiFiTransferText.string("libraryTreeHint"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !selected.isEmpty {
                    Button(String(localized: "clear")) { selected = []; selectionRevision = UUID() }
                        .buttonStyle(.plain).font(.caption)
                }
            }.padding(12)
            if let selectionError {
                TransferFeedback(text: selectionError, isError: true).padding(12)
            }
        }
        .onChange(of: query) { _, _ in selectionRevision = UUID() }
        .onChange(of: selected) { _, _ in selectionRevision = UUID() }
        .background(TransferAppearance.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
    }
}

private struct TransferLibrarySourceBranch: View {
    @Environment(MusicLibrary.self) private var library
    let source: MusicSource
    let query: String
    @Binding var selected: Set<String>
    @Binding var selectionError: String?
    @Binding var selectionRevision: UUID
    @State private var expanded = false
    @State private var groups: [TransferLibraryAlbumSummary] = []
    @State private var eligibleCount = 0
    @State private var selectedCount = 0
    @State private var totalCount = 0
    @State private var groupLimit = 60
    @State private var loading = false
    @State private var selecting = false

    init(source: MusicSource, query: String, selected: Binding<Set<String>>, selectionError: Binding<String?>,
         selectionRevision: Binding<UUID>, initiallyExpanded: Bool) {
        self.source = source
        self.query = query
        _selected = selected
        _selectionError = selectionError
        _selectionRevision = selectionRevision
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            if totalCount > 0 || query.isEmpty {
                HStack(spacing: 10) {
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded || !query.isEmpty ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).frame(width: 24, height: 32)
                    }.buttonStyle(.plain).accessibilityLabel(source.name)
                    TransferTreeCheckbox(state: .init(selectedCount: selectedCount, songCount: eligibleCount),
                                         title: source.name, disabled: eligibleCount == 0 || selecting) {
                        Task { await toggle(nil) }
                    }
                    Image(systemName: source.type == .local ? "internaldrive" : "externaldrive.connected.to.line.below")
                        .foregroundStyle(TransferAppearance.accent)
                    Text(source.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if loading || selecting { ProgressView().controlSize(.small) }
                    Text("\(totalCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(TransferAppearance.background.opacity(0.65))
                if expanded || !query.isEmpty {
                    ForEach(groups.prefix(groupLimit)) { group in
                        TransferLibraryAlbumBranch(source: source, group: group, query: query, selected: $selected,
                                                   selecting: selecting) {
                            Task { await toggle(group.id) }
                        }
                    }
                    if groups.count > groupLimit {
                        Button(WiFiTransferText.string("libraryLoadMore")) { groupLimit += 60 }
                            .buttonStyle(.plain).font(.callout).padding(12)
                    }
                }
                Divider()
            }
        }
        .task(id: LoadKey(version: .init(collectionRevision: library.visibleSongCollectionRevision,
                                        replacementToken: library.songReplacementToken),
                          query: query, expanded: expanded || !query.isEmpty, selected: selected,
                          sourceScope: MusicSourceSecurityRevision.scopedFingerprint(for: source))) {
            await loadGroups()
        }
    }

    private func loadGroups() async {
        loading = true
        let songs = library.visibleSongs(forSourceID: source.id)
        let source = source, query = query, selected = selected
        let needsGroups = expanded || !query.isEmpty
        let worker = Task.detached(priority: .userInitiated) {
            var groups: [WiFiTransferLibraryGroupID: TransferLibraryAlbumSummary] = [:]
            var total = 0, eligible = 0, checked = 0
            for song in songs {
                if Task.isCancelled { break }
                guard WiFiTransferLibraryGrouping.matches(song, query: query) else { continue }
                total += 1
                let selectable = WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: source.type) == nil
                if selectable { eligible += 1; if selected.contains(song.id) { checked += 1 } }
                guard needsGroups else { continue }
                let id = WiFiTransferLibraryGroupID(song: song)
                var group = groups[id] ?? TransferLibraryAlbumSummary(id: id)
                group.count += 1
                if selectable { group.eligible += 1; if selected.contains(song.id) { group.selected += 1 } }
                groups[id] = group
            }
            return (total, eligible, checked, groups.values.sorted {
                let order = ($0.id.album?.albumTitle ?? "").localizedStandardCompare($1.id.album?.albumTitle ?? "")
                return order == .orderedSame
                    ? ($0.id.album?.artistName ?? "") < ($1.id.album?.artistName ?? "") : order == .orderedAscending
            })
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        totalCount = result.0; eligibleCount = result.1; selectedCount = result.2; groups = result.3
        loading = false
    }

    private func toggle(_ group: WiFiTransferLibraryGroupID?) async {
        guard !selecting else { return }
        selecting = true
        defer { selecting = false }
        let songs = library.visibleSongs(forSourceID: source.id)
        let source = source, query = query, originalSelection = selected, revision = selectionRevision
        let worker = Task.detached(priority: .userInitiated) {
            songs.filter {
                (group == nil || WiFiTransferLibraryGroupID(song: $0) == group)
                    && WiFiTransferLibraryGrouping.matches($0, query: query)
                    && WiFiTransferFilePreparation.unavailableReason(song: $0, sourceType: source.type) == nil
            }.map(\.id)
        }
        let ids = await worker.value
        guard !Task.isCancelled, selected == originalSelection, selectionRevision == revision else { return }
        do {
            selected = try WiFiTransferLibraryGrouping.toggling(ids, in: selected)
            selectionError = nil
        } catch { selectionError = WiFiTransferText.string("librarySelectionLimit") }
    }

    private struct LoadKey: Equatable {
        let version: SongListSnapshotVersion
        let query: String
        let expanded: Bool
        let selected: Set<String>
        let sourceScope: String
    }
}

private struct TransferLibraryAlbumSummary: Identifiable, Sendable {
    let id: WiFiTransferLibraryGroupID
    var count = 0
    var eligible = 0
    var selected = 0
}

private struct TransferLibraryAlbumBranch: View {
    @Environment(MusicLibrary.self) private var library
    let source: MusicSource
    let group: TransferLibraryAlbumSummary
    let query: String
    @Binding var selected: Set<String>
    let selecting: Bool
    let toggleGroup: () -> Void
    @State private var expanded = false
    @State private var ids: [String] = []
    @State private var limit = 100
    @State private var snapshots = SongListSnapshotStore()

    private var title: String { group.id.album?.albumTitle ?? WiFiTransferText.string("libraryUngrouped") }
    var body: some View {
        LazyVStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded || !query.isEmpty ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 24, height: 32)
                }.buttonStyle(.plain).accessibilityLabel(title)
                TransferTreeCheckbox(state: .init(selectedCount: group.selected, songCount: group.eligible),
                                     title: title, disabled: group.eligible == 0 || selecting, action: toggleGroup)
                Image(systemName: "square.stack").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).lineLimit(1)
                    if let artist = group.id.album?.artistName, !artist.isEmpty {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text("\(group.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.leading, 24).padding(.trailing, 12).padding(.vertical, 5)
            if expanded || !query.isEmpty {
                ForEach(ids.prefix(limit), id: \.self) { id in
                    if let song = library.visibleSong(id: id) {
                        songRow(song)
                    }
                }
                if ids.count > limit {
                    Button(WiFiTransferText.string("libraryLoadMore")) { limit += 100 }
                        .buttonStyle(.plain).font(.callout).padding(12)
                }
            }
        }
        .task(id: AlbumLoadKey(expanded: expanded || !query.isEmpty, query: query,
                               version: .init(collectionRevision: library.visibleSongCollectionRevision,
                                              replacementToken: library.songReplacementToken))) {
            guard expanded || !query.isEmpty else { ids = []; return }
            let songs = library.visibleSongs(forSourceID: source.id)
            let groupID = group.id, query = query
            let worker = Task.detached(priority: .userInitiated) {
                songs.filter { WiFiTransferLibraryGroupID(song: $0) == groupID && WiFiTransferLibraryGrouping.matches($0, query: query) }
            }
            let matching = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            let snapshot = await snapshots.snapshot(scopeKey: "transfer-album:\(query)", version: .init(collectionRevision: library.visibleSongCollectionRevision,
                                                        replacementToken: library.songReplacementToken), order: .title,
                                                    songs: matching, cancelSuperseded: true)
            guard !Task.isCancelled else { return }
            ids = snapshot?.orderedSongIDs ?? []
        }
    }

    private func songRow(_ song: Song) -> some View {
        let reason = WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: source.type)
        return HStack(spacing: 10) {
            TransferTreeCheckbox(state: selected.contains(song.id) ? .all : .none, title: song.title,
                                 disabled: !selected.contains(song.id) && (reason != nil || selected.count >= WiFiTransferLibraryGrouping.selectionLimit)) {
                if selected.contains(song.id) { selected.remove(song.id) } else { selected.insert(song.id) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.callout).lineLimit(2)
                Text(reason.map(WiFiTransferText.string) ?? song.artistName ?? "")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if song.fileSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 58).padding(.trailing, 12).padding(.vertical, 9)
        .background(selected.contains(song.id) ? TransferAppearance.accent.opacity(0.07) : .clear)
        .opacity(reason == nil ? 1 : 0.6)
    }

    private struct AlbumLoadKey: Equatable {
        let expanded: Bool
        let query: String
        let version: SongListSnapshotVersion
    }
}

private struct TransferTreeCheckbox: View {
    let state: LibraryFolderSelectionState
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill" : state == .partial ? "minus.square.fill" : "square")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(state == .none ? Color.secondary : TransferAppearance.accent)
                .frame(width: 28, height: 32).contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityValue(state == .partial ? WiFiTransferText.string("libraryPartiallySelected") : state == .all ? WiFiTransferText.string("selected") : "")
        .accessibilityAddTraits(state == .all ? .isSelected : [])
    }
}
#endif
