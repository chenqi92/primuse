#if os(iOS) || os(macOS)
import SwiftUI
import PrimuseKit
import OSLog

struct WiFiTransferLibraryTree: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sources
    @Environment(\.isEnabled) private var isEnabled
    @Binding var selected: Set<String>
    @State private var query = ""
    let model: TransferLibraryTreeModel

    private var enabledSources: [MusicSource] { sources.sources.filter { $0.isEnabled && !$0.isDeleted } }

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
            TransferLibraryWindow(model: model)
                .id(model.scrollReset)
                .accessibilityIdentifier("transfer.library.tree")
                .overlay {
                    if model.rows.count == 0 {
                        Text(WiFiTransferText.string("libraryEmpty"))
                            .foregroundStyle(.secondary).padding(24)
                    }
                }
            Divider()
            HStack {
                Text(WiFiTransferText.string("libraryTreeHint"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !selected.isEmpty {
                    Button(String(localized: "clear")) { model.setSelection([]) }
                        .buttonStyle(.plain).font(.caption)
                }
            }.padding(12)
            if let error = model.error {
                TransferFeedback(text: error, isError: true).padding(12)
            }
        }
        .task(id: LoadKey(version: .init(collectionRevision: library.visibleSongCollectionRevision,
                                        replacementToken: library.songReplacementToken),
                          query: query, sources: enabledSources.map {
                              .init(id: $0.id, scope: MusicSourceSecurityRevision.scopedFingerprint(for: $0))
                          })) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await model.reload(
                sources: enabledSources.map {
                    .init(id: $0.id, name: $0.name, type: $0.type, count: library.visibleSongCount(forSourceID: $0.id))
                }, query: query, selected: selected,
                version: .init(collectionRevision: library.visibleSongCollectionRevision, replacementToken: library.songReplacementToken),
                sourceScopes: Dictionary(uniqueKeysWithValues: enabledSources.map {
                    ($0.id, MusicSourceSecurityRevision.scopedFingerprint(for: $0))
                }),
                selectedSources: Set(selected.compactMap { library.unobservedVisibleSong(id: $0)?.sourceID }),
                snapshot: { library.visibleSongs(forSourceID: $0) },
                commit: { selected = $0 })
        }
        .onChange(of: query) { _, _ in model.cancelSelection() }
        .onChange(of: selected) { _, value in model.updateSelection(value) }
        .onChange(of: isEnabled) { _, enabled in if !enabled { model.cancelSelection() } }
        .onDisappear { model.cancel() }
        .background(TransferAppearance.surface)
        .clipShape(.rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(TransferAppearance.line, lineWidth: 0.5) }
    }

    private struct LoadKey: Equatable {
        struct Source: Equatable { let id: String; let scope: String }
        let version: SongListSnapshotVersion
        let query: String
        let sources: [Source]
    }
}

enum TransferTreeNode: Hashable, Identifiable {
    case source(String)
    case album(WiFiTransferLibraryGroupID)
    case song(String, WiFiTransferLibraryGroupID)
    case loading(String)
    case moreAlbums(String, Int)
    case moreSongs(WiFiTransferLibraryGroupID, Int)
    var id: Self { self }
}

/// Pages form a flat address space without copying every loaded leaf ID each
/// time a branch grows. Only the viewport resolves positions into row values.
final class TransferTreeRows {
    enum Segment {
        case node(TransferTreeNode)
        case songs(WiFiTransferLibraryGroupID, [String])
        var count: Int {
            switch self { case .node: 1; case .songs(_, let ids): ids.count }
        }
    }

    let count: Int
    private let segments: [Segment]
    private let starts: [Int]

    init(_ segments: [Segment] = []) {
        self.segments = segments
        var starts: [Int] = [], count = 0
        for segment in segments { starts.append(count); count += segment.count }
        self.starts = starts
        self.count = count
    }

    func node(at position: Int) -> TransferTreeNode {
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle + 1 } else { high = middle }
        }
        let segment = max(0, low - 1)
        switch segments[segment] {
        case .node(let node): return node
        case .songs(let group, let ids): return .song(ids[position - starts[segment]], group)
        }
    }
}

@MainActor @Observable
final class TransferLibraryTreeModel {
    struct Source {
        let id: String
        let name: String
        let type: MusicSourceType
        let count: Int
    }

    private(set) var rows = TransferTreeRows()
    private(set) var selected: Set<String> = []
    private(set) var selectedCounts: [WiFiTransferLibraryGroupID: Int] = [:]
    private(set) var sourceSelectedCounts: [String: Int] = [:]
    private(set) var loadingSources: Set<String> = []
    private(set) var loadingGroups: Set<WiFiTransferLibraryGroupID> = []
    private(set) var expandedSources: Set<String> = []
    private(set) var expandedAlbums: Set<WiFiTransferLibraryGroupID> = []
    private(set) var selecting = false
    private(set) var query = ""
    private(set) var scrollReset = 0
    var error: String?

    @ObservationIgnored private(set) var sourceByID: [String: Source] = [:]
    @ObservationIgnored private(set) var indices: [String: WiFiTransferLibraryIndex] = [:]
    @ObservationIgnored private var sourceOrder: [String] = []
    @ObservationIgnored private var pages: [WiFiTransferLibraryGroupID: [[String]]] = [:]
    @ObservationIgnored private var loadedCounts: [WiFiTransferLibraryGroupID: Int] = [:]
    @ObservationIgnored private var albumLimits: [String: Int] = [:]
    @ObservationIgnored private var pageStores: [String: WiFiTransferLibraryPages] = [:]
    @ObservationIgnored private var sourceJobs: [String: Task<WiFiTransferLibraryIndex, Error>] = [:]
    @ObservationIgnored private var sourceTickets: [String: UUID] = [:]
    @ObservationIgnored private var pageJobs: [WiFiTransferLibraryGroupID: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedGroups: Set<WiFiTransferLibraryGroupID> = []
    @ObservationIgnored private var selectionJob: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var selectionRevision = UUID()
    @ObservationIgnored private var version: SongListSnapshotVersion?
    @ObservationIgnored private var sourceScopes: [String: String] = [:]
    @ObservationIgnored private var snapshot: ((String) -> [Song])?
    @ObservationIgnored private var commit: ((Set<String>) -> Void)?

    func reload(sources: [Source], query: String, selected: Set<String>,
                version: SongListSnapshotVersion, sourceScopes: [String: String], selectedSources: Set<String>,
                snapshot: @escaping (String) -> [Song], commit: @escaping (Set<String>) -> Void) async {
        let firstLoad = sourceOrder.isEmpty
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let reuse = self.version == version && self.sourceScopes == sourceScopes && self.query == query
        cancel()
        let generation = revision
        if self.query != query { scrollReset += 1 }
        self.query = query
        self.version = version
        self.sourceScopes = sourceScopes
        self.snapshot = snapshot
        self.commit = commit
        if reuse { updateSelection(selected) } else { self.selected = selected }
        error = nil
        sourceOrder = sources.map(\.id)
        sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        if firstLoad, let first = sources.first(where: { $0.type != .appleMusic }) { expandedSources.insert(first.id) }
        if !reuse {
            indices = [:]; pages = [:]; loadedCounts = [:]; pageStores = [:]
            selectedCounts = [:]; sourceSelectedCounts = [:]; failedGroups = []
        }
        rebuildRows()
        for source in sources where sourceExpanded(source.id) || selectedSources.contains(source.id) {
            guard !Task.isCancelled, revision == generation else { return }
            _ = await ensureIndex(source.id)
        }
    }

    func sourceExpanded(_ id: String) -> Bool { !query.isEmpty || expandedSources.contains(id) }
    func albumExpanded(_ id: WiFiTransferLibraryGroupID) -> Bool { !query.isEmpty || expandedAlbums.contains(id) }

    func toggleSource(_ id: String) {
        guard query.isEmpty else { return }
        if expandedSources.remove(id) != nil {
            sourceJobs.removeValue(forKey: id)?.cancel()
            sourceTickets[id] = nil
            loadingSources.remove(id)
            for group in Array(pageJobs.keys) where group.sourceID == id { cancelPage(group) }
            rebuildRows()
        } else {
            expandedSources.insert(id)
            rebuildRows()
            Task { _ = await ensureIndex(id) }
        }
    }

    func toggleAlbum(_ id: WiFiTransferLibraryGroupID) {
        guard query.isEmpty else { return }
        if expandedAlbums.remove(id) != nil { cancelPage(id) }
        else { expandedAlbums.insert(id) }
        rebuildRows()
    }

    private func ensureIndex(_ id: String) async -> WiFiTransferLibraryIndex? {
        if let index = indices[id] { return index }
        guard let source = sourceByID[id], let snapshot else { return nil }
        let generation = revision
        let ticket: UUID
        let worker: Task<WiFiTransferLibraryIndex, Error>
        if let pending = sourceJobs[id], let pendingTicket = sourceTickets[id] {
            worker = pending; ticket = pendingTicket
        } else {
            // The library has already built this per-source COW slice.
            let songs = snapshot(id), query = query, sourceType = source.type
            ticket = UUID()
            worker = Task.detached(priority: .userInitiated) {
                try await WiFiTransferLibraryIndex.build(sourceID: id, sourceType: sourceType, songs: songs, query: query)
            }
            sourceJobs[id] = worker; sourceTickets[id] = ticket
            loadingSources.insert(id)
        }
        do {
            // Index jobs are shared by expansion and selection. Cancelling a
            // checkbox action must not cancel the visible branch's load.
            let index = try await worker.value
            guard revision == generation else { return nil }
            guard sourceTickets[id] == ticket else { return Task.isCancelled ? nil : indices[id] }
            indices[id] = index
            pageStores[id] = WiFiTransferLibraryPages(index: index)
            sourceJobs[id] = nil; sourceTickets[id] = nil; loadingSources.remove(id)
            let counts = index.selectionCounts(in: selected)
            selectedCounts.merge(counts) { _, new in new }
            sourceSelectedCounts[id] = counts.values.reduce(0, +)
            rebuildRows()
            #if DEBUG
            Logger(subsystem: "com.primuse.performance", category: "TransferTree")
                .debug("Indexed source songs=\(index.songCount) groups=\(index.albums.count); published leaf pages=0")
            #endif
            return Task.isCancelled ? nil : index
        } catch {
            guard revision == generation, sourceTickets[id] == ticket else { return nil }
            sourceJobs[id] = nil; sourceTickets[id] = nil; loadingSources.remove(id)
            if !(error is CancellationError) { self.error = WiFiTransferText.error(error) }
            rebuildRows()
            return nil
        }
    }

    func loadMoreAlbums(_ id: String, offset: Int) {
        guard sourceExpanded(id), albumLimits[id, default: 60] == offset else { return }
        albumLimits[id] = offset + 60
        rebuildRows()
    }

    func loadNextPage(_ group: WiFiTransferLibraryGroupID, offset: Int, retry: Bool = false) {
        if retry { failedGroups.remove(group) }
        guard sourceExpanded(group.sourceID), albumExpanded(group), !failedGroups.contains(group),
              pageJobs[group] == nil, loadedCounts[group, default: 0] == offset,
              let store = pageStores[group.sourceID] else { return }
        let generation = revision
        loadingGroups.insert(group)
        pageJobs[group] = Task {
            do {
                let page = try await store.page(in: group, offset: offset)
                guard !Task.isCancelled, revision == generation else { return }
                pages[group, default: []].append(page)
                loadedCounts[group, default: 0] += page.count
                pageJobs[group] = nil; loadingGroups.remove(group)
                rebuildRows()
                #if DEBUG
                Logger(subsystem: "com.primuse.performance", category: "TransferTree")
                    .debug("Published song page offset=\(offset) count=\(page.count)")
                #endif
            } catch {
                guard !Task.isCancelled, revision == generation else { return }
                pageJobs[group] = nil; loadingGroups.remove(group)
                failedGroups.insert(group)
                if !(error is CancellationError) { self.error = WiFiTransferText.error(error) }
                rebuildRows()
            }
        }
    }

    func selectParent(sourceID: String, group: WiFiTransferLibraryGroupID?) {
        guard !selecting else { return }
        selecting = true
        let generation = revision, selectionGeneration = selectionRevision
        selectionJob = Task {
            defer { if selectionRevision == selectionGeneration { selecting = false } }
            guard let index = await ensureIndex(sourceID), !Task.isCancelled,
                  revision == generation, selectionRevision == selectionGeneration else { return }
            let original = selected
            let worker = Task.detached(priority: .userInitiated) { try index.toggling(group, in: original) }
            do {
                let next = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, revision == generation, selectionRevision == selectionGeneration else { return }
                setSelection(next)
                error = nil
            } catch {
                if !Task.isCancelled, revision == generation { self.error = WiFiTransferText.string("librarySelectionLimit") }
            }
        }
    }

    func setSelection(_ value: Set<String>) {
        updateSelection(value)
        commit?(value)
    }

    func updateSelection(_ value: Set<String>) {
        guard selected != value else { return }
        let changed = selected.symmetricDifference(value)
        var counts = selectedCounts, sourceCounts = sourceSelectedCounts
        for id in changed {
            for (sourceID, index) in indices {
                guard let group = index.group(forEligibleSongID: id) else { continue }
                let delta = value.contains(id) ? 1 : -1
                counts[group, default: 0] += delta
                sourceCounts[sourceID, default: 0] += delta
                break
            }
        }
        selectedCounts = counts
        sourceSelectedCounts = sourceCounts
        selected = value
        cancelSelection()
    }

    func cancelSelection() {
        selectionRevision = UUID()
        selectionJob?.cancel()
        selectionJob = nil
        selecting = false
    }

    func cancel() {
        revision = UUID()
        for job in sourceJobs.values { job.cancel() }
        for job in pageJobs.values { job.cancel() }
        sourceJobs = [:]; sourceTickets = [:]; pageJobs = [:]
        loadingSources = []; loadingGroups = []
        snapshot = nil; commit = nil
        cancelSelection()
    }

    private func cancelPage(_ group: WiFiTransferLibraryGroupID) {
        pageJobs.removeValue(forKey: group)?.cancel()
        loadingGroups.remove(group)
    }

    private func rebuildRows() {
        var segments: [TransferTreeRows.Segment] = []
        for sourceID in sourceOrder {
            let index = indices[sourceID]
            if !query.isEmpty, index?.songCount == 0 { continue }
            segments.append(.node(.source(sourceID)))
            guard sourceExpanded(sourceID) else { continue }
            guard let index else { segments.append(.node(.loading(sourceID))); continue }
            let limit = albumLimits[sourceID, default: 60]
            for album in index.albums.prefix(limit) {
                segments.append(.node(.album(album.id)))
                guard albumExpanded(album.id) else { continue }
                for page in pages[album.id] ?? [] { segments.append(.songs(album.id, page)) }
                let count = loadedCounts[album.id, default: 0]
                if count < album.count { segments.append(.node(.moreSongs(album.id, count))) }
            }
            if index.albums.count > limit { segments.append(.node(.moreAlbums(sourceID, limit))) }
        }
        rows = TransferTreeRows(segments)
    }
}

private struct TransferLibraryWindow: View {
    @Environment(MusicLibrary.self) private var library
    let model: TransferLibraryTreeModel
    @State private var firstVisibleRow = 0
    @State private var viewportHeight = 480.0
    @ScaledMetric(relativeTo: .callout) private var rowHeight = 54.0

    var body: some View {
        let rows = model.rows
        let range = SongListScrollWindow.range(totalCount: rows.count, firstVisibleRow: firstVisibleRow,
                                               viewportHeight: viewportHeight, rowHeight: rowHeight)
        let nodes = range.map { rows.node(at: $0) }
        let nextPage = nodes.first { if case .moreSongs = $0 { return true }; return false }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Double(range.lowerBound) * rowHeight).accessibilityHidden(true)
                ForEach(nodes) { node in
                    row(node).frame(height: rowHeight)
                }
                Color.clear.frame(height: Double(rows.count - range.upperBound) * rowHeight).accessibilityHidden(true)
            }
        }
        .onScrollGeometryChange(for: Metrics.self) { geometry in
            let row = Int(max(0, geometry.visibleRect.minY) / max(1, rowHeight))
            return Metrics(firstRow: row / SongListScrollWindow.rowStride * SongListScrollWindow.rowStride,
                           height: Double(geometry.containerSize.height))
        } action: { _, metrics in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                firstVisibleRow = metrics.firstRow
                viewportHeight = metrics.height
            }
        }
        .onChange(of: nextPage, initial: true) { _, node in
            if case .moreSongs(let group, let offset) = node { model.loadNextPage(group, offset: offset) }
        }
        #if DEBUG
        .onChange(of: WindowKey(total: rows.count, range: range), initial: true) { _, key in
            Logger(subsystem: "com.primuse.performance", category: "TransferTree")
                .debug("Row window total=\(key.total) lower=\(key.range.lowerBound) upper=\(key.range.upperBound) realized=\(key.range.count)")
        }
        #endif
    }

    @ViewBuilder private func row(_ node: TransferTreeNode) -> some View {
        switch node {
        case .source(let id):
            if let source = model.sourceByID[id] {
                HStack(spacing: 10) {
                    disclosure(expanded: model.sourceExpanded(id), title: source.name) { model.toggleSource(id) }
                    let count = model.sourceSelectedCounts[id, default: 0]
                    TransferTreeCheckbox(state: .init(selectedCount: count, songCount: model.indices[id]?.eligibleCount ?? Int.max),
                                         title: source.name, disabled: model.selecting || source.type == .appleMusic) {
                        model.selectParent(sourceID: id, group: nil)
                    }
                    Image(systemName: source.type == .local ? "internaldrive" : "externaldrive.connected.to.line.below")
                        .foregroundStyle(TransferAppearance.accent)
                    Text(source.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if model.loadingSources.contains(id) { ProgressView().controlSize(.small) }
                    Text("\(model.indices[id]?.songCount ?? source.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .background(TransferAppearance.background.opacity(0.65))
            }
        case .album(let group):
            if let album = model.indices[group.sourceID]?.albumsByID[group] {
                let title = group.album?.albumTitle ?? WiFiTransferText.string("libraryUngrouped")
                HStack(spacing: 10) {
                    disclosure(expanded: model.albumExpanded(group), title: title) { model.toggleAlbum(group) }
                    TransferTreeCheckbox(state: .init(selectedCount: model.selectedCounts[group, default: 0], songCount: album.eligibleCount),
                                         title: title, disabled: model.selecting || album.eligibleCount == 0) {
                        model.selectParent(sourceID: group.sourceID, group: group)
                    }
                    Image(systemName: "square.stack").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout).lineLimit(1)
                        if let artist = group.album?.artistName, !artist.isEmpty {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text("\(album.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.leading, 24).padding(.trailing, 12)
            }
        case .song(let id, let group):
            if let song = library.unobservedVisibleSong(id: id), let source = model.sourceByID[group.sourceID] {
                songRow(song, source: source)
            }
        case .loading:
            HStack { ProgressView().controlSize(.small); Spacer() }.padding(.leading, 32)
        case .moreAlbums(let sourceID, let offset):
            Button(WiFiTransferText.string("libraryLoadMore")) { model.loadMoreAlbums(sourceID, offset: offset) }
                .buttonStyle(.plain).font(.callout).padding(.leading, 32)
                .onAppear { model.loadMoreAlbums(sourceID, offset: offset) }
        case .moreSongs(let group, let offset):
            HStack {
                Button(WiFiTransferText.string("libraryLoadMore")) { model.loadNextPage(group, offset: offset, retry: true) }
                    .buttonStyle(.plain).font(.callout)
                if model.loadingGroups.contains(group) { ProgressView().controlSize(.small) }
                Spacer()
            }.padding(.leading, 58)
        }
    }

    private func disclosure(expanded: Bool, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold)).frame(width: 24, height: 32)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func songRow(_ song: Song, source: TransferLibraryTreeModel.Source) -> some View {
        let reason = WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: source.type)
        let checked = model.selected.contains(song.id)
        return HStack(spacing: 10) {
            TransferTreeCheckbox(state: checked ? .all : .none, title: song.title,
                                 disabled: !checked && (reason != nil || model.selected.count >= WiFiTransferLibraryGrouping.selectionLimit)) {
                var selected = model.selected
                if checked { selected.remove(song.id) } else { selected.insert(song.id) }
                model.setSelection(selected)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(.callout).lineLimit(1)
                Text(reason.map(WiFiTransferText.string) ?? song.artistName ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if song.fileSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: song.fileSize, countStyle: .file))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 58).padding(.trailing, 12)
        .background(checked ? TransferAppearance.accent.opacity(0.07) : .clear)
        .opacity(reason == nil ? 1 : 0.6)
    }

    private struct Metrics: Equatable { let firstRow: Int; let height: Double }
    #if DEBUG
    private struct WindowKey: Equatable { let total: Int; let range: Range<Int> }
    #endif
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
