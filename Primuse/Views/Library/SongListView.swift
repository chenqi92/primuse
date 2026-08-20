import SwiftUI
import PrimuseKit
import os
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Reference-backed storage prevents AttributeGraph from applying
/// `Array<Song>.==` to the list cache whenever metadata changes. Song's
/// synthesized equality includes lyricsText, so a value-backed SwiftUI state
/// made each background backfill publication walk the full lyrics library.
@MainActor
@Observable
private final class SongListRowModel {
    private final class SongReference {
        let value: Song

        init(_ value: Song) {
            self.value = value
        }
    }

    private var reference: SongReference

    var song: Song { reference.value }

    init(song: Song) {
        reference = SongReference(song)
    }

    func replace(with song: Song) {
        // SongReference deliberately has identity equality. Assigning a new
        // Song value therefore notifies only this row without Observation
        // comparing the complete lyricsText payload first.
        reference = SongReference(song)
    }
}

@MainActor
@Observable
private final class SongListPositionModel {
    private(set) var row: SongListRowIdentity?

    init(row: SongListRowIdentity?) {
        self.row = row
    }

    func replace(with row: SongListRowIdentity?) {
        guard self.row != row else { return }
        self.row = row
    }
}

@MainActor
@Observable
private final class SongListCache {
    private struct ProjectionKey: Equatable {
        let snapshotIdentity: ObjectIdentifier
        let sourceID: String?
        let query: String
        let replacementToken: UUID
    }

    private struct ProjectionEntry {
        let key: ProjectionKey
        let value: SongListProjection
    }

    /// The worker builds this immutable reference off the main actor. Publishing
    /// it is O(1), instead of rebuilding dictionaries and aggregates while the
    /// navigation animation or a scroll gesture is running.
    @ObservationIgnored private var snapshot: SongListSnapshot?

    @ObservationIgnored private var rowModelsByID: [String: SongListRowModel] = [:]
    @ObservationIgnored private var positionModelsByPosition: [Int: SongListPositionModel] = [:]
    @ObservationIgnored private var visiblePositions: Set<Int> = []
    @ObservationIgnored private var projectionEntry: ProjectionEntry?

    private(set) var hasSnapshot = false
    private(set) var positionCount = 0
    private(set) var rowOrderRevision = 0
    private(set) var songCount = 0
    private(set) var playableCount = 0
    private(set) var totalDuration: TimeInterval = 0

    var rows: [SongListRowIdentity] { snapshot?.rows ?? [] }
    var orderedSongIDs: [String] { snapshot?.orderedSongIDs ?? [] }
    var isEmpty: Bool { !hasSnapshot }

    func songCount(forSourceID sourceID: String) -> Int {
        snapshot?.sourceCounts[sourceID, default: 0] ?? 0
    }

    func publish(_ snapshot: SongListSnapshot, pruneRowModels: Bool) {
        if pruneRowModels {
            // This dictionary contains only rows SwiftUI has instantiated, not
            // the complete library. Explicit sorts keep it intact so visible
            // row identity and scroll state survive the order change.
            rowModelsByID = rowModelsByID.filter { snapshot.songIDs.contains($0.key) }
        }
        self.snapshot = snapshot
        projectionEntry = nil
        if !hasSnapshot {
            hasSnapshot = true
        }
        if positionCount != snapshot.rows.count {
            positionCount = snapshot.rows.count
            songCount = snapshot.rows.count
        }
        if playableCount != snapshot.playableCount {
            playableCount = snapshot.playableCount
        }
        if totalDuration != snapshot.totalDuration {
            totalDuration = snapshot.totalDuration
        }
        if !positionModelsByPosition.isEmpty {
            positionModelsByPosition = positionModelsByPosition.filter {
                snapshot.rows.indices.contains($0.key)
            }
            visiblePositions = visiblePositions.filter(snapshot.rows.indices.contains)
            for position in visiblePositions {
                positionModelsByPosition[position]?.replace(with: snapshot.rows[position])
            }
        }
        rowOrderRevision &+= 1
    }

    func patch(_ replacements: [String: Song]) {
        guard !replacements.isEmpty else { return }
        for (songID, song) in replacements {
            rowModelsByID[songID]?.replace(with: song)
        }
    }

    func contains(songID: String) -> Bool {
        snapshot?.songIDs.contains(songID) == true
    }

    func row(at position: Int) -> SongListRowIdentity? {
        guard let snapshot, snapshot.rows.indices.contains(position) else { return nil }
        return snapshot.rows[position]
    }

    func positionModel(at position: Int) -> SongListPositionModel {
        if let model = positionModelsByPosition[position] {
            return model
        }
        let model = SongListPositionModel(row: row(at: position))
        positionModelsByPosition[position] = model
        return model
    }

    func setPosition(_ position: Int, isVisible: Bool) {
        if isVisible {
            visiblePositions.insert(position)
            positionModelsByPosition[position]?.replace(with: row(at: position))
        } else {
            visiblePositions.remove(position)
        }
    }

    func rowModel(id: String, song: @autoclosure () -> Song?) -> SongListRowModel? {
        if let model = rowModelsByID[id] {
            return model
        }
        guard let song = song() else { return nil }
        let model = SongListRowModel(song: song)
        rowModelsByID[id] = model
        return model
    }

    func projection(
        sourceID: String?,
        query: String,
        replacementToken: UUID,
        resolve: (String) -> Song?
    ) -> SongListProjection {
        _ = rowOrderRevision
        guard let snapshot else { return .empty }
        guard sourceID != nil || !query.isEmpty else {
            return SongListProjection(rows: snapshot.rows, orderedSongIDs: snapshot.orderedSongIDs)
        }

        let key = ProjectionKey(
            snapshotIdentity: ObjectIdentifier(snapshot),
            sourceID: sourceID,
            query: query,
            replacementToken: replacementToken
        )
        if projectionEntry?.key == key, let cached = projectionEntry?.value {
            return cached
        }

        let interval = SongListPerformanceSignpost.signposter.beginInterval(
            "FilteredProjection",
            "count: \(snapshot.rows.count, privacy: .public), hasSource: \(sourceID != nil, privacy: .public), queryLength: \(query.count, privacy: .public)"
        )
        var rows: [SongListRowIdentity] = []
        var ids: [String] = []
        rows.reserveCapacity(snapshot.rows.count)
        ids.reserveCapacity(snapshot.rows.count)
        for row in snapshot.rows {
            guard let song = resolve(row.id) else { continue }
            if let sourceID, song.sourceID != sourceID { continue }
            if !query.isEmpty,
               !song.title.localizedCaseInsensitiveContains(query),
               !(song.artistName?.localizedCaseInsensitiveContains(query) ?? false),
               !(song.albumTitle?.localizedCaseInsensitiveContains(query) ?? false) {
                continue
            }
            let id = row.id
            rows.append(SongListRowIdentity(id: id, offset: rows.count))
            ids.append(id)
        }
        let value = SongListProjection(rows: rows, orderedSongIDs: ids)
        projectionEntry = ProjectionEntry(key: key, value: value)
        SongListPerformanceSignpost.signposter.endInterval(
            "FilteredProjection",
            interval,
            "resultCount: \(rows.count, privacy: .public)"
        )
        return value
    }

}

@MainActor
@Observable
private final class LibraryFolderBrowserCache {
    enum QueryScope: Hashable {
        case visible
        case action
    }

    private struct OrderedQueryKey: Hashable {
        let folderRevision: Int
        let rowOrderRevision: Int
        let nodeID: LibraryFolderNodeID
        let scope: QueryScope
    }

    @ObservationIgnored private var indexReference: LibraryFolderIndex?
    @ObservationIgnored private var orderedQueries: [OrderedQueryKey: [String]] = [:]

    private(set) var hasIndex = false
    private(set) var revision = 0

    var index: LibraryFolderIndex? {
        _ = revision
        return indexReference
    }

    func publish(_ index: LibraryFolderIndex) {
        indexReference = index
        orderedQueries.removeAll(keepingCapacity: true)
        if !hasIndex { hasIndex = true }
        revision &+= 1
    }

    func node(withID id: LibraryFolderNodeID) -> LibraryFolderNode? {
        index?.node(withID: id)
    }

    func children(of id: LibraryFolderNodeID) -> [LibraryFolderNode] {
        index?.children(of: id) ?? []
    }

    func rootNodes(sourceID: String?) -> [LibraryFolderNode] {
        guard let index else { return [] }
        return LibraryFolderBrowsePolicy.rootNodes(in: index, sourceID: sourceID)
    }

    func orderedSongIDs(
        in nodeID: LibraryFolderNodeID,
        scope: QueryScope,
        listCache: SongListCache
    ) -> [String] {
        let rowOrderRevision = listCache.rowOrderRevision
        let key = OrderedQueryKey(
            folderRevision: revision,
            rowOrderRevision: rowOrderRevision,
            nodeID: nodeID,
            scope: scope
        )
        if let cached = orderedQueries[key] { return cached }
        guard let index else { return [] }

        let ordered: [String]
        switch scope {
        case .visible:
            ordered = LibraryFolderBrowsePolicy.visibleSongIDs(
                in: nodeID,
                index: index,
                orderedBy: listCache.orderedSongIDs
            )
        case .action:
            ordered = LibraryFolderBrowsePolicy.actionSongIDs(
                in: nodeID,
                index: index,
                orderedBy: listCache.orderedSongIDs
            )
        }
        orderedQueries[key] = ordered
        return ordered
    }
}

private struct SongListProjection {
    let rows: [SongListRowIdentity]
    let orderedSongIDs: [String]

    static let empty = SongListProjection(rows: [], orderedSongIDs: [])
}

/// Keeps progress-only mutations below the song-list observation boundary.
/// Revealing or hiding the toolbar status must not invalidate the 20,000-row
/// parent view while the prepared snapshot is being published.
@MainActor
@Observable
private final class SongListSortProgressModel {
    private var state = SongListSortProgressState()

    var generation: Int? { state.generation }
    var order: LibrarySongSortOrder? { state.order }
    var isVisible: Bool { state.isVisible }

    @discardableResult
    func begin(generation: Int, order: LibrarySongSortOrder) -> Bool {
        state.begin(generation: generation, order: order)
    }

    @discardableResult
    func reveal(generation: Int) -> Bool {
        state.reveal(generation: generation)
    }

    @discardableResult
    func markWaitingForPublication(generation: Int) -> Bool {
        state.markWaitingForPublication(generation: generation)
    }

    @discardableResult
    func markPublished(generation: Int) -> Bool {
        state.markPublished(generation: generation)
    }

    @discardableResult
    func finish(generation: Int) -> Bool {
        state.finish(generation: generation)
    }

    @discardableResult
    func cancel(generation: Int) -> Bool {
        state.cancel(generation: generation)
    }
}

private struct SongListSortProgressIndicator: View {
    let progress: SongListSortProgressModel

    @ViewBuilder
    var body: some View {
        if progress.isVisible, let order = progress.order {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: progressMessage(for: order))
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: progressMessage(for: order)))
            .accessibilityIdentifier("songSortProgress")
        }
    }

    private func localizedSortLabel(_ order: LibrarySongSortOrder) -> String {
        switch order {
        case .title: return String(localized: "sort_title")
        case .artist: return String(localized: "sort_artist")
        case .album: return String(localized: "sort_album")
        case .dateAdded: return String(localized: "sort_date_added")
        case .format: return String(localized: "sort_format")
        }
    }

    private func progressMessage(for order: LibrarySongSortOrder) -> String {
        String(
            format: String(localized: "song_sort_progress_format"),
            localizedSortLabel(order)
        )
    }
}

struct SongListView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    /// Keep only a lightweight scope in the view identity. Storing `[Song]`
    /// here made SwiftUI/AttributeGraph compare every Song (including its full
    /// lyricsText) whenever an ancestor refreshed.
    private let scope: Scope
    @State private var sortOrder: SongSortOrder = .title
    @State private var listCache = SongListCache()
    @State private var searchText: String = ""
    @State private var sortGeneration: Int = 0
    @State private var sortTask: Task<Void, Never>?
    @State private var sortFeedbackTask: Task<Void, Never>?
    @State private var sortFeedbackDeadline: ContinuousClock.Instant?
    @State private var sortProgress = SongListSortProgressModel()
    @State private var sortRequestActive = false
    @State private var activeSortIsExplicit = false
    @State private var isListInteracting = false
    @State private var pendingSnapshot: SongListSnapshot?
    @State private var pendingSnapshotPrunesRows = false
    @State private var pendingSnapshotIsExplicitSort = false
    @State private var pendingSnapshotGeneration = 0
    @State private var pendingSnapshotOrder: LibrarySongSortOrder?
    @State private var showNoScraperSourceAlert = false
    @State private var selection = SongSelectionModel()
    @State private var browseMode: LibrarySongBrowseMode
    @State private var folderCache = LibraryFolderBrowserCache()
    @State private var folderIndexStore = LibraryFolderIndexStore()
    @State private var folderIndexTask: Task<Void, Never>?
    @State private var folderIndexGeneration = 0
    @State private var folderSourceRevision = 0
    @State private var folderIndexScopeToken = UUID()
    #if os(macOS)
    @State private var macViewMode: MacSongsViewMode = .list
    @State private var macRowDensity: MacSongsRowDensity = .standard
    @State private var visibleColumns: Set<MacSongsColumn> = MacSongsColumn.defaultVisible
    /// 当前选中的数据源过滤 (nil = 全部)。设计稿 SourceFilterChips 是可点切换的。
    @State private var selectedSourceID: String? = nil
    @State private var showViewOptions = false
    @State private var showAddVisibleToPlaylist = false
    // Bind context-menu sheets to the selected value itself.  A separate
    // `songID` + `isPresented` pair can publish in either order when a menu
    // closes, letting SwiftUI create a permanently empty sheet before the ID
    // becomes visible.
    @State private var contextAddToPlaylistSong: Song?
    @State private var contextSongInfoSong: Song?
    @State private var contextTagEditorSong: Song?
    @State private var exportError: String?
    /// songID → 播放次数, 由 PlayHistory 一次性折叠而来。重建只发生在
    /// onAppear 和 PlayHistory 变更通知时, 而不是每行重算 (否则 LazyVStack
    /// 滚动时每实例化一行都要 O(5000) 折叠+建字典)。
    @State private var playCountsBySongID: [String: Int] = [:]
    #endif

    private enum Scope: Hashable, Sendable {
        case library
        case source(String)

        var snapshotCacheKey: String {
            switch self {
            case .library:
                return SongListSnapshotStore.libraryScopeKey
            case .source(let sourceID):
                return SongListSnapshotStore.sourceScopeKey(sourceID)
            }
        }
    }

    init(sourceID: String? = nil) {
        scope = sourceID.map(Scope.source) ?? .library
        _browseMode = State(initialValue: LibrarySongBrowseModePreference.load())
    }

    enum SongSortOrder: String, CaseIterable, Sendable {
        case title, artist, album, dateAdded, format

        var libraryOrder: LibrarySongSortOrder {
            switch self {
            case .title: return .title
            case .artist: return .artist
            case .album: return .album
            case .dateAdded: return .dateAdded
            case .format: return .format
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .title: return "sort_title"
            case .artist: return "sort_artist"
            case .album: return "sort_album"
            case .dateAdded: return "sort_date_added"
            case .format: return "sort_format"
            }
        }

    }

    #if os(macOS)
    private enum MacSongsViewMode: String, CaseIterable, Hashable {
        case list, compact, grid

        var title: String {
            switch self {
            case .list: return String(localized: "songs_view_list")
            case .compact: return String(localized: "songs_view_compact")
            case .grid: return String(localized: "songs_view_grid")
            }
        }

        var icon: String {
            switch self {
            case .list: return "list.bullet"
            case .compact: return "text.justify"
            case .grid: return "square.grid.3x3"
            }
        }
    }

    private enum MacSongsRowDensity: String, CaseIterable, Hashable {
        case compact, standard, relaxed

        var title: String {
            switch self {
            case .compact: return String(localized: "songs_row_compact")
            case .standard: return String(localized: "songs_row_standard")
            case .relaxed: return String(localized: "songs_row_relaxed")
            }
        }

        var icon: String {
            switch self {
            case .compact: return "chevron.up"
            case .standard: return "line.3.horizontal"
            case .relaxed: return "chevron.down"
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact: return 3
            case .standard: return 6
            case .relaxed: return 10
            }
        }
    }

    private enum MacSongsColumn: String, CaseIterable, Hashable, Identifiable {
        case artist, album, format, duration, plays, source, year, rating, dateAdded, bitRate

        var id: String { rawValue }

        static let defaultVisible: Set<MacSongsColumn> = [.artist, .album, .format, .duration, .plays, .source]

        var title: String {
            switch self {
            case .artist: return String(localized: "artist_label")
            case .album: return String(localized: "album_label")
            case .format: return String(localized: "songs_column_format_sample_rate")
            case .duration: return String(localized: "duration_label")
            case .plays: return String(localized: "stats_play_count")
            case .source: return String(localized: "source_label")
            case .year: return String(localized: "year_label")
            case .rating: return String(localized: "songs_column_rating")
            case .dateAdded: return String(localized: "sort_date_added")
            case .bitRate: return String(localized: "songs_column_bitrate")
            }
        }
    }
    #endif

    var body: some View {
        content
            .songBatchActions(
                selection: selection,
                orderedIDs: { batchOrderedSongIDs },
                resolve: { library.unobservedVisibleSong(id: $0) }
            )
            .onAppear {
                // NavigationStack keeps this destination alive while another
                // tab is selected. Reuse its existing order instead of
                // sorting 10K songs again on every return.
                if listCache.isEmpty {
                    scheduleSortedRecompute(pruneRowModels: false)
                }
                scheduleFolderIndexRecompute()
            }
            .onChange(of: library.visibleSongCollectionRevision) { _, _ in
                scheduleSortedRecompute(
                    delay: .milliseconds(180),
                    pruneRowModels: true
                )
                scheduleFolderIndexRecompute(delay: .milliseconds(180))
            }
            .onChange(of: configuredFolderSourceDescriptors) { _, _ in
                folderSourceRevision &+= 1
                scheduleFolderIndexRecompute(delay: .milliseconds(80))
            }
            .onChange(of: library.playlistCollectionRevision) { _, _ in
                scheduleFolderIndexRecompute(delay: .milliseconds(80))
            }
            .onChange(of: browseMode) { _, mode in
                cancelExplicitSortForNavigation()
                LibrarySongBrowseModePreference.save(mode)
                selection.deactivate()
                if mode == .folder {
                    scheduleFolderIndexRecompute()
                } else {
                    folderIndexGeneration &+= 1
                    folderIndexTask?.cancel()
                }
            }
            .onChange(of: searchText) { _, _ in
                pruneSelection()
            }
            .onChange(of: library.songReplacementToken) { _, _ in
                let folderStructureChanged = folderReplacementChangesStructure()
                let shouldRetryPendingSort = sortRequestActive
                applyLibrarySongReplacements()
                if folderStructureChanged {
                    folderSourceRevision &+= 1
                    scheduleFolderIndexRecompute(delay: .milliseconds(80))
                }
                if listCache.isEmpty || shouldRetryPendingSort {
                    scheduleSortedRecompute(
                        delay: .milliseconds(80),
                        pruneRowModels: false,
                        isExplicitSort: activeSortIsExplicit
                    )
                }
            }
            .onChange(of: selection.isActive) { _, isActive in
                if isActive {
                    cancelExplicitSortForSelection()
                }
            }
            .onDisappear {
                cancelExplicitSortForNavigation()
            }
            #if os(macOS)
            .sheet(isPresented: $showAddVisibleToPlaylist) {
                BatchAddToPlaylistSheet(songs: filteredSongs.filteredPlayable())
            }
            .sheet(item: $contextAddToPlaylistSong) { song in
                AddToPlaylistSheet(song: library.song(id: song.id) ?? song)
            }
            .sheet(item: $contextSongInfoSong) { song in
                SongInfoSheet(song: library.song(id: song.id) ?? song)
            }
            .sheet(item: $contextTagEditorSong) { song in
                TagEditorView(song: library.song(id: song.id) ?? song) { updated in
                    player.syncSongMetadata(updated)
                    player.forceRefreshNowPlayingArtwork()
                }
            }
            .alert("songs_export_failed",
                   isPresented: Binding(get: { exportError != nil },
                                        set: { if !$0 { exportError = nil } })) {
                Button("done", role: .cancel) {}
            } message: {
                Text(exportError ?? "")
            }
            #endif
            .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
    }

    private var songs: [Song] {
        switch scope {
        case .library:
            library.visibleSongs
        case .source(let sourceID):
            library.visibleSongs(forSourceID: sourceID)
        }
    }

    private var sortOrderBinding: Binding<SongSortOrder> {
        Binding(
            get: { sortOrder },
            set: { requestedOrder in
                let currentOrder = sortOrder
                let accepted = SongListSortProgressState.acceptsChange(
                    from: currentOrder.libraryOrder,
                    to: requestedOrder.libraryOrder
                )
                SongListPerformanceSignpost.sortSelection(
                    current: currentOrder.rawValue,
                    requested: requestedOrder.rawValue,
                    accepted: accepted
                )
                guard accepted else { return }
                sortOrder = requestedOrder
                scheduleSortedRecompute(
                    pruneRowModels: false,
                    isExplicitSort: true
                )
            }
        )
    }

    private func localizedSortLabel(_ order: LibrarySongSortOrder) -> String {
        switch order {
        case .title: return String(localized: "sort_title")
        case .artist: return String(localized: "sort_artist")
        case .album: return String(localized: "sort_album")
        case .dateAdded: return String(localized: "sort_date_added")
        case .format: return String(localized: "sort_format")
        }
    }

    private func sortProgressMessage(for order: LibrarySongSortOrder) -> String {
        String(
            format: String(localized: "song_sort_progress_format"),
            localizedSortLabel(order)
        )
    }

    private func sortCompletedMessage(for order: LibrarySongSortOrder) -> String {
        String(
            format: String(localized: "song_sort_progress_complete_format"),
            localizedSortLabel(order)
        )
    }

    private var showsFolderBrowser: Bool {
        browseMode == .folder
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var folderRootSourceID: String? {
        guard case .source(let sourceID) = scope else { return nil }
        return sourceID
    }

    private var configuredFolderSourceDescriptors: [LibraryFolderSourceDescriptor] {
        let descriptors = sourcesStore.allSources.map(LibraryFolderSourceDescriptor.init(source:))
        guard case .source(let sourceID) = scope else { return descriptors }
        return descriptors.filter { $0.sourceID == sourceID }
    }

    @ViewBuilder
    private var content: some View {
        if songs.isEmpty && !showsFolderBrowser {
            EmptyStateView(
                titleKey: "no_songs",
                descriptionKey: "no_songs_desc",
                systemImage: "music.note"
            )
        } else if (!songs.isEmpty && listCache.isEmpty)
                    || (showsFolderBrowser && !folderCache.hasIndex) {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            #if os(macOS)
            macSongList
            #else
            iosSongList
            #endif
        }
    }

    private var iosSongList: some View {
        Group {
            if showsFolderBrowser {
                LibraryFolderRootView(
                    folderCache: folderCache,
                    listCache: listCache,
                    rootSourceID: folderRootSourceID,
                    selection: selection,
                    sortOrder: sortOrderBinding
                )
            } else {
                IOSSongListContainer(
                    cache: listCache,
                    selection: selection,
                    onPlay: playSong
                )
                .equatable()
            }
        }
        .onScrollPhaseChange { _, newPhase in
            updateListInteraction(for: newPhase)
        }
        .toolbar {
            iosToolbar
        }
    }

    #if os(macOS)
    private var macSongList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "library_title",
                    title: String(localized: "tab_songs"),
                    subtitle: librarySubtitle,
                    iconSystemName: "music.note",
                    coverSong: songs.first(where: { $0.coverArtFileName?.isEmpty == false }),
                    onPlay: { playLibrary(shuffled: false) },
                    onShuffle: { playLibrary(shuffled: true) },
                    moreMenu: listMoreMenu
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
                    if !showsFolderBrowser {
                        sourceFilterChips
                    }
                    macToolbarRow

                    if showsFolderBrowser {
                        LibraryFolderRootContent(
                            folderCache: folderCache,
                            listCache: listCache,
                            rootSourceID: folderRootSourceID,
                            selection: selection,
                            sortOrder: sortOrderBinding
                        )
                    } else if filteredRows.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .padding(.top, 48)
                    } else {
                        macSongsContent
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.m14)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .onScrollPhaseChange { _, newPhase in
            updateListInteraction(for: newPhase)
        }
        .onAppear { rebuildPlayCounts() }
        .onChange(of: selectedSourceID) { _, _ in
            pruneSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
            rebuildPlayCounts()
        }
    }

    private var sourceFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sourceChip(title: String(localized: "search_chip_all"),
                           count: listCache.songCount, color: nil,
                           active: selectedSourceID == nil) {
                    selectedSourceID = nil
                }

                ForEach(sourcesStore.allSources.prefix(5), id: \.id) { source in
                    let count = listCache.songCount(forSourceID: source.id)
                    if count > 0 {
                        sourceChip(title: source.name, count: count,
                                   color: sourceColor(source),
                                   active: selectedSourceID == source.id) {
                            // 再点一次已选中的源 = 取消过滤回到全部。
                            selectedSourceID = (selectedSourceID == source.id) ? nil : source.id
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func sourceChip(title: String, count: Int, color: Color?, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                }
                Text(verbatim: title)
                    .lineLimit(1)
                Text(verbatim: count.formatted())
                    .monospacedDigit()
                    .opacity(0.65)
            }
            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? .white : PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(active ? PMColor.brand : PMColor.glassBtn, in: Capsule())
            .overlay {
                Capsule().strokeBorder(active ? .clear : PMColor.cardBorder, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sourceColor(_ source: MusicSource) -> Color {
        switch source.type {
        case .baiduPan: return PMColor.brand
        case .appleMusic, .appleMusicLibrary: return Color(red: 0.64, green: 0.48, blue: 0.96)
        case .synology, .qnap, .ugreen, .fnos: return Color(red: 0.31, green: 0.68, blue: 0.95)
        case .webdav, .smb, .ftp, .sftp, .nfs, .upnp, .s3: return Color(red: 0.45, green: 0.82, blue: 0.56)
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic, .fnMusic, .daoliyu:
            return Color(red: 0.98, green: 0.66, blue: 0.28)
        case .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123: return Color(red: 0.42, green: 0.68, blue: 0.96)
        case .local: return PMColor.textFaint
        }
    }

    private var macToolbarRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                TextField("", text: $searchText, prompt: Text("filter_songs_placeholder"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 26)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }

            Spacer()

            SongListSortProgressIndicator(progress: sortProgress)

            browseModeSegment

            Text("sort_by")
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textFaint)

            Menu {
                Picker("sort_by", selection: sortOrderBinding) {
                    ForEach(SongSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(sortOrder.label)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
            }
            .menuStyle(.borderlessButton)
            // 自己画了 chevron.down, 隐藏系统 Menu 默认的小箭头, 否则两个箭头叠一起。
            .menuIndicator(.hidden)
            .disabled(selection.isActive)
            .fixedSize()

            if !showsFolderBrowser {
                viewModeSegment

                PMRoundBtn(icon: "slider.horizontal.3", size: 26, iconSize: 12, style: .glass,
                           help: "songs_view_options") {
                    showViewOptions.toggle()
                }
                .popover(isPresented: $showViewOptions, arrowEdge: .bottom) {
                    viewOptionsPopover
                }
            }
        }
        .padding(.top, -4)
    }

    private var browseModeSegment: some View {
        HStack(spacing: 1) {
            ForEach(LibrarySongBrowseMode.allCases, id: \.self) { mode in
                Button {
                    browseMode = mode
                } label: {
                    Label(
                        mode == .folder ? "library_browse_folder" : "library_browse_flat",
                        systemImage: mode == .folder ? "folder" : "list.bullet"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(browseMode == mode ? PMColor.brand : PMColor.textMuted)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 22)
                    .background(
                        browseMode == mode ? PMColor.bgElev : .clear,
                        in: .rect(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selection.isActive)
                .accessibilityIdentifier("libraryBrowseMode.\(mode.rawValue)")
            }
        }
        .padding(2)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }

    private var viewModeSegment: some View {
        HStack(spacing: 1) {
            ForEach(MacSongsViewMode.allCases, id: \.self) { mode in
                Button {
                    macViewMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(macViewMode == mode ? PMColor.brand : PMColor.textMuted)
                        .frame(width: 26, height: 22)
                        .background(macViewMode == mode ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 5))
                        .shadow(color: macViewMode == mode ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: mode.title))
            }
        }
        .padding(2)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
    }

    private var librarySubtitle: String {
        "\(listCache.songCount) \(String(localized: "songs_count")) · \(listCache.playableCount) \(String(localized: "home_playable")) · \(listCache.totalDuration.formattedShort)"
    }

    @ViewBuilder
    private var macSongsContent: some View {
        switch macViewMode {
        case .list:
            songTable
        case .compact:
            compactSongList
        case .grid:
            songGrid
        }
    }

    private var songTable: some View {
        VStack(spacing: 0) {
            tableHeader
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(PMColor.bg)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            LazyVStack(spacing: 1) {
                ForEach(filteredRows) { row in
                    if let song = library.unobservedVisibleSong(id: row.id) {
                        songTableRow(song, index: row.offset)
                            .songSelectable(
                                songID: row.id,
                                selection: selection,
                                orderedIDs: { filteredSongIDs }
                            )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 设计稿表头 9 列: # / cover / 标题 / 艺术家 / 专辑 / 格式 / 时长 / 播放 / 源
    /// gridTemplateColumns: 32px 32px 1fr 1.2fr 1fr 100px 80px 80px 60px
    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 32, alignment: .leading)
            Color.clear.frame(width: 32, height: 1)
            // 3 个 flex 列等分 — 之前 artist 加 layoutPriority(0.2) 反而导致 SwiftUI
            // 把所有 flexible 空间全分给它, title / album 被压成 0 宽显示空。
            Text("sort_title").frame(maxWidth: .infinity, alignment: .leading)
            if visibleColumns.contains(.artist) {
                Text("sort_artist").frame(maxWidth: .infinity, alignment: .leading)
            }
            if visibleColumns.contains(.album) {
                Text("sort_album").frame(maxWidth: .infinity, alignment: .leading)
            }
            if visibleColumns.contains(.format) {
                Text("sort_format").frame(width: 100, alignment: .leading)
            }
            if visibleColumns.contains(.duration) {
                Text("track_duration_short").frame(width: 80, alignment: .trailing)
            }
            if visibleColumns.contains(.plays) {
                Text("home_playable_count_short").frame(width: 80, alignment: .trailing)
            }
            if visibleColumns.contains(.source) {
                Text("source").frame(width: 60, alignment: .leading)
            }
            if visibleColumns.contains(.year) {
                Text("year_label").frame(width: 54, alignment: .trailing)
            }
            if visibleColumns.contains(.rating) {
                Text("rating").frame(width: 54, alignment: .trailing)
            }
            if visibleColumns.contains(.dateAdded) {
                Text("sort_date_added").frame(width: 92, alignment: .trailing)
            }
            if visibleColumns.contains(.bitRate) {
                Text("Bitrate").frame(width: 70, alignment: .trailing)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(PMColor.textFaint)
    }

    /// 一次性把 PlayHistory 折叠成 songID → count 字典, 避免每行 O(N) 扫描。
    /// 结果写入 @State playCountsBySongID, 仅在 onAppear / 变更通知时调用。
    private func rebuildPlayCounts() {
        var dict: [String: Int] = [:]
        for e in PlayHistoryStore.shared.entries {
            dict[e.songID, default: 0] += 1
        }
        playCountsBySongID = dict
    }

    @ViewBuilder
    private func songTableRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let liked = playlistContains(song)
        let plays = playCountsBySongID[song.id] ?? 0
        let source = sourcesStore.sources.first(where: { $0.id == song.sourceID })
        Button { playSong(song) } label: {
            HStack(spacing: 12) {
                // # / play indicator
                ZStack {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 32, alignment: .leading)

                // Cover
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 28, cornerRadius: 4,
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .frame(width: 32, alignment: .leading)

                // Title + (optional heart)
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if liked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.brand)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if visibleColumns.contains(.artist) {
                    Text(song.artistName ?? "—")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if visibleColumns.contains(.album) {
                    Text(song.albumTitle ?? "—")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if visibleColumns.contains(.format) {
                    HStack(spacing: 6) {
                        PMFormatPill.forFormat(song.fileFormat.displayName)
                        if let sr = song.sampleRate, sr > 0 {
                            Text(verbatim: "\(sr / 1000)k")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(PMColor.textFaint)
                        }
                    }
                    .frame(width: 100, alignment: .leading)
                }

                if visibleColumns.contains(.duration) {
                    Text(song.duration.formattedDuration)
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 80, alignment: .trailing)
                }

                if visibleColumns.contains(.plays) {
                    playCountText(plays)
                        .frame(width: 80, alignment: .trailing)
                }

                if visibleColumns.contains(.source) {
                    sourceCell(source)
                        .frame(width: 60, alignment: .leading)
                }

                if visibleColumns.contains(.year) {
                    Text(song.year.map(String.init) ?? "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 54, alignment: .trailing)
                }

                if visibleColumns.contains(.rating) {
                    Text(verbatim: "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                        .frame(width: 54, alignment: .trailing)
                }

                if visibleColumns.contains(.dateAdded) {
                    Text(song.dateAdded, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                        .frame(width: 92, alignment: .trailing)
                }

                if visibleColumns.contains(.bitRate) {
                    Text(song.bitRate.map { "\($0 / 1000)k" } ?? "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, macRowDensity.verticalPadding)
            .pmRowBackground(selected: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { macSongContextMenu(for: song) }
    }

    /// 用源类型 hash 出稳定彩色点 (跟 sidebar 同算法)。
    @ViewBuilder
    private func playCountText(_ plays: Int) -> some View {
        if plays > 0 {
            Text("\(plays)")
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textMuted)
        } else {
            Text(verbatim: "—")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
        }
    }

    private func sourceCell(_ source: MusicSource?) -> some View {
        HStack(spacing: 5) {
            if let source {
                Circle()
                    .fill(macSourceDotColor(for: source))
                    .frame(width: 6, height: 6)
                Text(verbatim: source.name.components(separatedBy: "·").first?
                    .trimmingCharacters(in: .whitespaces) ?? source.name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
            }
        }
    }

    private var compactSongList: some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredRows) { row in
                if let song = library.unobservedVisibleSong(id: row.id) {
                    compactSongRow(song, index: row.offset)
                        .songSelectable(
                            songID: row.id,
                            selection: selection,
                            orderedIDs: { filteredSongIDs }
                        )
                }
            }
        }
        .padding(.top, 8)
    }

    private func compactSongRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return Button { playSong(song) } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 28, alignment: .leading)

                HStack(spacing: 5) {
                    Text(song.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                        .lineLimit(1)
                    if playlistContains(song) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(PMColor.brand)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(song.artistName ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    PMFormatPill.forFormat(song.fileFormat.displayName)
                    if let sr = song.sampleRate, sr > 0 {
                        Text(verbatim: "\(sr / 1000)k")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 80, alignment: .leading)

                Text(song.duration.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isCurrent ? PMColor.brand.opacity(0.16) : .clear, in: .rect(cornerRadius: 4))
            .overlay(alignment: .bottom) {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { macSongContextMenu(for: song) }
    }

    private var songGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 6),
            alignment: .leading,
            spacing: 20
        ) {
            ForEach(filteredRows) { row in
                if let song = library.unobservedVisibleSong(id: row.id) {
                    songGridTile(song, highlighted: player.currentSong?.id == song.id)
                        .songSelectable(
                            songID: row.id,
                            selection: selection,
                            style: .overlay,
                            orderedIDs: { filteredSongIDs }
                        )
                }
            }
        }
        .padding(.top, 12)
    }

    private func songGridTile(_ song: Song, highlighted: Bool) -> some View {
        Button { playSong(song) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        cornerRadius: 8,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .aspectRatio(1, contentMode: .fit)

                    if highlighted {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(PMColor.brand, in: .circle)
                            .shadow(color: .black.opacity(0.30), radius: 8, y: 2)
                            .padding(8)
                    }
                }

                Text(song.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(highlighted ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 8)

                Text(song.artistName ?? "—")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { macSongContextMenu(for: song) }
    }

    @ViewBuilder
    private func macSongContextMenu(for song: Song) -> some View {
        Section {
            Button {
                playSong(song)
            } label: {
                Label(String(localized: "play"), systemImage: "play.fill")
            }
            .disabled(!song.isPlayable)

            Button {
                player.insertNextInQueue([song])
            } label: {
                Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(!song.isPlayable)

            Button {
                player.appendToQueue([song])
            } label: {
                Label(String(localized: "add_to_queue"), systemImage: "text.badge.plus")
            }
            .disabled(!song.isPlayable)
        }

        Section {
            Button {
                showSongInfo(for: song)
            } label: {
                Label(String(localized: "song_info"), systemImage: "info.circle")
            }

            Button {
                editTags(for: song)
            } label: {
                Label(String(localized: "tag_editor_menu"), systemImage: "tag")
            }

            Button {
                openScrapeWindow(for: song)
            } label: {
                Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
            }

            Button {
                addToPlaylist(song)
            } label: {
                Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
            }
        }

        Section {
            Button {
                library.toggleLiked(songID: song.id)
            } label: {
                Label(library.isLiked(songID: song.id) ? String(localized: "a11y_unlike") : String(localized: "a11y_like"),
                      systemImage: library.isLiked(songID: song.id) ? "heart.fill" : "heart")
            }

            ShareLink(item: "\(song.title) - \(song.artistName ?? "")") {
                Label(String(localized: "share"), systemImage: "square.and.arrow.up")
            }
        }
    }

    private func latestSong(_ song: Song) -> Song {
        library.song(id: song.id) ?? song
    }

    private func showSongInfo(for song: Song) {
        contextSongInfoSong = latestSong(song)
    }

    private func editTags(for song: Song) {
        contextTagEditorSong = latestSong(song)
    }

    private func addToPlaylist(_ song: Song) {
        contextAddToPlaylistSong = latestSong(song)
    }

    private func openScrapeWindow(for song: Song) {
        let song = latestSong(song)
        scraperSettings.performSingleSongScrapeAction(
            from: .macSongListContextMenu,
            onProceed: {
                ScrapeWindowController.shared.show(song: song) { updated in
                    CachedArtworkView.invalidateCache(for: updated.id)
                    if let oldRef = song.coverArtFileName {
                        CachedArtworkView.invalidateCache(for: oldRef)
                    }
                    player.syncSongMetadata(updated)
                    player.forceRefreshNowPlayingArtwork()
                }
            },
            onRequireSource: {
                showNoScraperSourceAlert = true
            }
        )
    }

    private var listMoreMenu: AnyView {
        // Header/menu construction is part of every macOS body update. Keep it
        // on lightweight IDs; materialize 10K Song values only after the user
        // actually invokes an action.
        let visibleIDs = filteredSongIDs
        let playableCount: Int
        if selectedSourceID == nil,
           searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            playableCount = listCache.playableCount
        } else {
            playableCount = visibleIDs.reduce(into: 0) { count, songID in
                if library.unobservedVisibleSong(id: songID)?.isPlayable == true { count += 1 }
            }
        }

        func materializeVisible() -> [Song] {
            visibleIDs.compactMap { library.unobservedVisibleSong(id: $0) }
        }

        func materializePlayable() -> [Song] {
            visibleIDs.compactMap { songID in
                guard let song = library.unobservedVisibleSong(id: songID), song.isPlayable else { return nil }
                return song
            }
        }

        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "checkmark.circle",
                      title: selection.isActive
                          ? String(localized: "done")
                          : String(localized: "batch_select"),
                      enabled: !visibleIDs.isEmpty) {
                    if selection.isActive {
                        selection.deactivate()
                    } else {
                        selection.activate()
                    }
                },
            ],
            [
                .init(icon: "text.line.last.and.arrowtriangle.forward",
                      title: String(localized: "queue_all_songs"),
                      trailing: playableCount.formatted(),
                      enabled: playableCount > 0) {
                    player.appendToQueue(materializePlayable())
                },
                .init(icon: "text.line.first.and.arrowtriangle.forward",
                      title: String(localized: "insert_next"),
                      enabled: playableCount > 0) {
                    player.insertNextInQueue(materializePlayable())
                },
                .init(icon: "text.badge.plus",
                      title: String(localized: "add_to_playlist_ellipsis"),
                      enabled: playableCount > 0) {
                    showAddVisibleToPlaylist = true
                },
            ],
            [
                .init(icon: "shuffle",
                      title: String(localized: "shuffle_all"),
                      enabled: playableCount > 0) {
                    playLibrary(shuffled: true)
                },
            ],
            [
                .init(icon: "wand.and.stars",
                      title: String(localized: "scrape_missing_metadata"),
                      trailing: visibleIDs.count.formatted(),
                      enabled: !visibleIDs.isEmpty && !scraperService.isScraping) {
                    guard scraperSettings.hasEnabledSource else {
                        showNoScraperSourceAlert = true
                        return
                    }
                    scraperService.scrapeMissingMetadata(songs: materializeVisible(), in: library)
                },
                .init(icon: "square.and.arrow.up",
                      title: String(localized: "export_m3u8_ellipsis"),
                      enabled: playableCount > 0) {
                    exportVisibleSongs(format: .m3u8)
                },
                .init(icon: "curlybraces",
                      title: String(localized: "export_json_ellipsis"),
                      enabled: playableCount > 0) {
                    exportVisibleSongs(format: .json)
                },
            ],
            [
                .init(icon: "list.bullet.rectangle",
                      title: String(localized: "songs_column_settings_ellipsis")) {
                    showViewOptions = true
                },
            ],
        ]))
    }

    private var viewOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("songs_view_options")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)

            viewOptionsSection(String(localized: "songs_display_mode")) {
                segmentedIconPicker(MacSongsViewMode.allCases, selection: $macViewMode)
            }

            // 行高 / 显示列 只作用于「列表」视图 (紧凑、网格是固定密排布局, 不吃这些
            // 设置)。在别的模式下隐藏, 免得勾了列却不生效、看着对不上。
            if macViewMode == .list {
                viewOptionsSection(String(localized: "songs_row_height")) {
                    segmentedIconPicker(MacSongsRowDensity.allCases, selection: $macRowDensity)
                }

                viewOptionsSection(String(localized: "songs_display_columns")) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(MacSongsColumn.allCases) { column in
                            Button {
                                if visibleColumns.contains(column) {
                                    visibleColumns.remove(column)
                                } else {
                                    visibleColumns.insert(column)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(visibleColumns.contains(column) ? PMColor.brand : .clear)
                                            .frame(width: 14, height: 14)
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .strokeBorder(visibleColumns.contains(column) ? .clear : PMColor.dividerStrong, lineWidth: 1.5)
                                            }
                                        if visibleColumns.contains(column) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    Text(verbatim: column.title)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(visibleColumns.contains(column) ? PMColor.text : PMColor.textMuted)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                // 整行 (含复选框本身) 都可点, 不必非点中文字。
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        // 系统 popover 的半透材质叠在内容后面会让白色选中块显得过亮 / 发灰;
        // 铺一层 flat 不透明底 (不画圆角边框, 系统 chrome 会裁圆角, 不会双框),
        // 选中块就跟工具栏里的视图切换一样是"米色上一块白"的柔和效果。
        .background(PMColor.bg)
    }

    private func viewOptionsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
            content()
        }
    }

    private func segmentedIconPicker<T: CaseIterable & Hashable>(_ values: T.AllCases, selection: Binding<T>) -> some View where T.AllCases: RandomAccessCollection {
        HStack(spacing: 2) {
            ForEach(Array(values), id: \.self) { value in
                let item = segmentInfo(for: value)
                Button {
                    selection.wrappedValue = value
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .medium))
                        Text(verbatim: item.title)
                            .font(.system(size: 9, weight: selection.wrappedValue == value ? .semibold : .medium))
                    }
                    .foregroundStyle(selection.wrappedValue == value ? PMColor.brand : PMColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(selection.wrappedValue == value ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 6))
                    .shadow(color: selection.wrappedValue == value ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
                    // 整段都可点选, 而不是只点中图标/文字才生效。
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
    }

    private func segmentInfo<T>(for value: T) -> (title: String, icon: String) {
        if let mode = value as? MacSongsViewMode { return (mode.title, mode.icon) }
        if let density = value as? MacSongsRowDensity { return (density.title, density.icon) }
        return ("", "circle")
    }

    private var visiblePlayableSongs: [Song] {
        filteredSongs.filteredPlayable()
    }

    private func exportVisibleSongs(format: PlaylistExporter.Format) {
        do {
            let playlist = Playlist(name: String(localized: "tab_songs"))
            let url = try PlaylistExporter.export(
                playlist: playlist,
                songs: visiblePlayableSongs,
                format: format,
                sourcesStore: sourcesStore
            )
            try PlaylistExporter.presentSavePanel(for: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func macSourceDotColor(for source: MusicSource) -> Color {
        let palette: [Color] = [
            PMColor.flac, PMColor.dsd, PMColor.warn, PMColor.brand,
            Color(red: 0.4, green: 0.7, blue: 0.95),
            Color(red: 0.7, green: 0.6, blue: 0.95),
        ]
        let h = source.type.rawValue.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[h]
    }

    private func playlistContains(_ song: Song) -> Bool {
        library.isLiked(songID: song.id)
    }

    private func playLibrary(shuffled: Bool) {
        let candidates = filteredSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }
        let queue = shuffled ? candidates.shuffled() : candidates
        guard let first = queue.first else { return }
        player.shuffleEnabled = shuffled
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }
    #endif

    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        if selection.isActive {
            ToolbarItem(placement: .principal) {
                SongSelectionToolbarTitle(selection: selection)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                SongSelectionOptionsMenu(
                    selection: selection,
                    orderedIDs: { batchOrderedSongIDs }
                )
                Button("done") {
                    selection.deactivate()
                }
            }
        } else {
            ToolbarItem(placement: .principal) {
                SongListSortProgressIndicator(progress: sortProgress)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Picker("library_browse", selection: $browseMode) {
                            Label("library_browse_folder", systemImage: "folder")
                                .tag(LibrarySongBrowseMode.folder)
                            Label("library_browse_flat", systemImage: "list.bullet")
                                .tag(LibrarySongBrowseMode.flat)
                        }
                        .pickerStyle(.inline)
                    }

                    Section {
                        Picker("sort_by", selection: sortOrderBinding) {
                            ForEach(SongSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                    }

                    Section {
                        Button {
                            selection.activate()
                        } label: {
                            Label("batch_select", systemImage: "checkmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("a11y_more_actions"))
            }
        }
    }

    /// 过滤条件变了或歌被删了之后，丢掉已经不在列表里的选中项 —— 否则批量
    /// 操作会作用到用户此刻根本看不见的歌上。
    private func pruneSelection() {
        guard selection.isActive, !selection.isEmpty else { return }
        selection.prune(to: Set(batchOrderedSongIDs))
    }

    /// Normal browsing returns worker-built arrays by reference. A source/search
    /// projection is materialized once per snapshot/filter key and shared by
    /// every body consumer instead of repeating filter/reindex/map work.
    private var filteredProjection: SongListProjection {
        #if os(macOS)
        let sourceID = selectedSourceID
        #else
        let sourceID: String? = nil
        #endif
        return listCache.projection(
            sourceID: sourceID,
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            replacementToken: library.songReplacementToken,
            resolve: { library.unobservedVisibleSong(id: $0) }
        )
    }

    private var filteredRows: [SongListRowIdentity] {
        filteredProjection.rows
    }

    private var filteredSongIDs: [String] {
        filteredProjection.orderedSongIDs
    }

    private var batchOrderedSongIDs: [String] {
        showsFolderBrowser ? listCache.orderedSongIDs : filteredSongIDs
    }

    /// Materialize Song values only for explicit actions (queue, export,
    /// scrape), never as the List's structural data.
    private var filteredSongs: [Song] {
        filteredSongIDs.compactMap { library.unobservedVisibleSong(id: $0) }
    }

    /// Patch only the rows touched by a metadata replacement. Do not reorder
    /// the complete list while background scraping/backfill is publishing:
    /// besides forcing a 10K-row List diff, that could move the row whose
    /// More menu the user is currently operating. The next explicit sort,
    /// collection change, or appearance rebuilds the order from fresh data.
    private func applyLibrarySongReplacements() {
        let replacedIDs = library.lastReplacedSongIDs
        guard !replacedIDs.isEmpty, !listCache.isEmpty else { return }

        var replacements: [String: Song] = [:]
        replacements.reserveCapacity(replacedIDs.count)
        for songID in replacedIDs {
            guard listCache.contains(songID: songID),
                  let latest = library.unobservedVisibleSong(id: songID),
                  belongsToCurrentScope(latest)
            else { continue }
            replacements[songID] = latest
        }

        guard !replacements.isEmpty else { return }
        listCache.patch(replacements)
    }

    /// A full scan can replace a Song in place while preserving the ordered
    /// song IDs, so `visibleSongCollectionRevision` intentionally does not
    /// change. Compare only the replaced IDs against the existing index and
    /// rebuild when source/path placement moved; title/artist/lyrics updates
    /// stay on the cheap row-patch path.
    private func folderReplacementChangesStructure() -> Bool {
        guard browseMode == .folder,
              let index = folderCache.index,
              !library.lastReplacedSongIDs.isEmpty else {
            return false
        }

        var descriptorsByID: [String: LibraryFolderSourceDescriptor] = [:]
        for descriptor in configuredFolderSourceDescriptors
        where descriptorsByID[descriptor.sourceID] == nil {
            descriptorsByID[descriptor.sourceID] = descriptor
        }
        for songID in library.lastReplacedSongIDs {
            let indexedNodeID = index.nodeID(containingSongID: songID)
            if let song = library.unobservedVisibleSong(id: songID),
               song.sourceID == AppleMusicLibraryIdentity.sourceID {
                continue
            }
            let expectedNodeID: LibraryFolderNodeID?
            if let song = library.unobservedVisibleSong(id: songID),
               belongsToCurrentScope(song) {
                let descriptor: LibraryFolderSourceDescriptor
                if let configured = descriptorsByID[song.sourceID] {
                    descriptor = configured
                } else {
                    let fallback = fallbackFolderSourceDescriptor(for: song)
                    descriptorsByID[song.sourceID] = fallback
                    descriptor = fallback
                }
                expectedNodeID = descriptor.placementNodeID(for: song)
            } else {
                expectedNodeID = nil
            }

            if indexedNodeID != expectedNodeID {
                return true
            }
        }
        return false
    }

    private func belongsToCurrentScope(_ song: Song) -> Bool {
        switch scope {
        case .library:
            return library.containsVisibleSong(id: song.id)
        case .source(let sourceID):
            return song.sourceID == sourceID && library.containsVisibleSong(id: song.id)
        }
    }

    private func folderSourceDescriptors(
        for songsSnapshot: [Song],
        configured descriptors: [LibraryFolderSourceDescriptor]
    ) -> [LibraryFolderSourceDescriptor] {
        var result = descriptors
        var knownSourceIDs = Set(descriptors.map(\.sourceID))
        for song in songsSnapshot where knownSourceIDs.insert(song.sourceID).inserted {
            result.append(fallbackFolderSourceDescriptor(for: song))
        }
        return result
    }

    private func fallbackFolderSourceDescriptor(
        for song: Song
    ) -> LibraryFolderSourceDescriptor {
        // The system Apple Music mirror normally has a SourcesStore row, but
        // older snapshots and imported libraries may not. Unknown providers
        // are intentionally opaque and get a generic safe name; never expose
        // their ID or playback reference as a path label.
        let displayName = song.sourceID == AppleMusicLibraryIdentity.sourceID
            ? String(localized: "apple_music_library_section")
            : String(localized: "source_label")
        return LibraryFolderSourceDescriptor(
            sourceID: song.sourceID,
            displayName: displayName,
            scanRoots: [],
            pathSemantics: .opaque
        )
    }

    /// Build the immutable prefix index away from the main actor. Metadata-only
    /// replacements deliberately do not call this path: folder structure depends
    /// on collection membership, source configuration, sourceID, and filePath,
    /// not on title/artist/lyrics backfill publications.
    private func scheduleFolderIndexRecompute(delay: Duration? = nil) {
        guard browseMode == .folder else { return }

        folderIndexGeneration &+= 1
        let generation = folderIndexGeneration
        let songsSnapshot = songs
        let configuredDescriptors = configuredFolderSourceDescriptors
        let sourceRevision = folderSourceRevision
        let collectionRevision = library.visibleSongCollectionRevision
        let playlistRevision = library.playlistCollectionRevision
        let virtualCollections = library.appleMusicFolderCollections(
            availableSongs: songsSnapshot
        )
        let version = LibraryFolderIndexVersion(
            collectionRevision: collectionRevision,
            // This token identifies this view/store scope; metadata-only song
            // replacements must not invalidate a 100k-folder index on return.
            replacementToken: folderIndexScopeToken,
            sourceRevision: sourceRevision,
            virtualCollectionRevision: playlistRevision
        )
        let descriptors = folderSourceDescriptors(
            for: songsSnapshot,
            configured: configuredDescriptors
        )

        folderIndexTask?.cancel()
        folderIndexTask = Task { @MainActor in
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let prepared = await folderIndexStore.index(
                version: version,
                sources: descriptors,
                songs: songsSnapshot,
                virtualCollections: virtualCollections
            )
            guard !Task.isCancelled,
                  browseMode == .folder,
                  folderIndexGeneration == generation,
                  folderSourceRevision == sourceRevision,
                  library.visibleSongCollectionRevision == collectionRevision,
                  library.playlistCollectionRevision == playlistRevision
            else { return }
            folderCache.publish(prepared)
            if selection.isActive, !selection.isEmpty {
                selection.prune(to: Set(listCache.orderedSongIDs))
            }
        }
    }

    /// Build sorting, IDs, membership, and aggregates away from the main actor.
    /// The main actor only swaps the completed immutable snapshot reference.
    private func scheduleSortedRecompute(
        delay: Duration? = nil,
        pruneRowModels: Bool,
        isExplicitSort: Bool = false
    ) {
        if !isExplicitSort, let explicitGeneration = sortProgress.generation {
            sortFeedbackTask?.cancel()
            sortFeedbackTask = nil
            sortFeedbackDeadline = nil
            let cancelledOrder = sortProgress.order ?? sortOrder.libraryOrder
            _ = sortProgress.cancel(generation: explicitGeneration)
            SongListPerformanceSignpost.sortCancelled(
                generation: explicitGeneration,
                order: cancelledOrder.rawValue
            )
        }
        sortGeneration &+= 1
        let generation = sortGeneration
        let songsSnapshot = songs
        let order = sortOrder
        let snapshotVersion = SongListSnapshotVersion(
            collectionRevision: library.visibleSongCollectionRevision,
            replacementToken: library.songReplacementToken
        )
        let scopeKey = scope.snapshotCacheKey
        pendingSnapshot = nil
        pendingSnapshotPrunesRows = false
        pendingSnapshotIsExplicitSort = false
        pendingSnapshotGeneration = 0
        pendingSnapshotOrder = nil
        activeSortIsExplicit = isExplicitSort
        sortRequestActive = true
        SongListPerformanceSignpost.sortIntent(
            generation: generation,
            count: songsSnapshot.count,
            order: order.rawValue
        )
        if isExplicitSort, !showsFolderBrowser {
            beginSortFeedback(generation: generation, order: order.libraryOrder)
        }

        sortTask?.cancel()
        sortTask = Task { @MainActor in
            var didPublishOrQueue = false
            defer {
                if sortGeneration == generation, !didPublishOrQueue {
                    finishSortWithoutPublication(
                        generation: generation,
                        order: order.libraryOrder,
                        isExplicitSort: isExplicitSort
                    )
                }
            }
            // Give a system Menu one main-run-loop turn to dismiss. Cache hits
            // are still immediate; there is no fixed 350 ms latency floor.
            await Task.yield()
            SongListPerformanceSignpost.sortDispatched(
                generation: generation,
                order: order.rawValue
            )
            if let delay {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard let prepared = await SongListSnapshotStore.shared.snapshot(
                scopeKey: scopeKey,
                version: snapshotVersion,
                order: order.libraryOrder,
                songs: songsSnapshot,
                cancelSuperseded: true
            ) else { return }
            // A delayed feedback task whose 200 ms deadline elapsed while the
            // worker was sorting must get a main-actor turn before publication
            // can cancel it. Fast cache hits still publish without feedback.
            await Task.yield()
            guard !Task.isCancelled,
                  sortGeneration == generation,
                  sortOrder == order,
                  library.visibleSongCollectionRevision == snapshotVersion.collectionRevision,
                  library.songReplacementToken == snapshotVersion.replacementToken
            else { return }
            await revealOverdueSortFeedbackBeforePublication(
                generation: generation,
                order: order.libraryOrder,
                songCount: prepared.rows.count
            )
            publishPreparedSnapshot(
                prepared,
                pruneRowModels: pruneRowModels,
                isExplicitSort: isExplicitSort,
                generation: generation,
                order: order.libraryOrder
            )
            didPublishOrQueue = true
        }
    }

    private func publishPreparedSnapshot(
        _ snapshot: SongListSnapshot,
        pruneRowModels: Bool,
        isExplicitSort: Bool,
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        if isListInteracting, !listCache.isEmpty {
            pendingSnapshot = snapshot
            pendingSnapshotPrunesRows = pruneRowModels
            pendingSnapshotIsExplicitSort = isExplicitSort
            pendingSnapshotGeneration = generation
            pendingSnapshotOrder = order
            if isExplicitSort,
               sortProgress.markWaitingForPublication(generation: generation) {
                SongListPerformanceSignpost.sortWaitingForPublication(
                    generation: generation,
                    order: order.rawValue
                )
            }
            return
        }
        publishSnapshotWithoutAnimation(
            snapshot,
            pruneRowModels: pruneRowModels,
            isExplicitSort: isExplicitSort,
            generation: generation,
            order: order
        )
    }

    private func updateListInteraction(for phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            isListInteracting = true
        case .idle:
            isListInteracting = false
            guard let pendingSnapshot else { return }
            let pruneRowModels = pendingSnapshotPrunesRows
            let isExplicitSort = pendingSnapshotIsExplicitSort
            let generation = pendingSnapshotGeneration
            guard let order = pendingSnapshotOrder else { return }
            self.pendingSnapshot = nil
            pendingSnapshotPrunesRows = false
            pendingSnapshotIsExplicitSort = false
            pendingSnapshotGeneration = 0
            pendingSnapshotOrder = nil
            publishSnapshotWithoutAnimation(
                pendingSnapshot,
                pruneRowModels: pruneRowModels,
                isExplicitSort: isExplicitSort,
                generation: generation,
                order: order
            )
        case .animating:
            break
        }
    }

    private func publishSnapshotWithoutAnimation(
        _ snapshot: SongListSnapshot,
        pruneRowModels: Bool,
        isExplicitSort: Bool,
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            listCache.publish(snapshot, pruneRowModels: pruneRowModels)
        }
        if selection.isActive, !selection.isEmpty {
            selection.prune(to: snapshot.songIDs)
        }
        SongListPerformanceSignpost.sortPublished(
            generation: generation,
            count: snapshot.rows.count,
            order: order.rawValue
        )
        if isExplicitSort {
            finishSortAfterPublication(generation: generation, order: order)
        } else if sortGeneration == generation {
            sortRequestActive = false
            activeSortIsExplicit = false
        }
    }

    private func beginSortFeedback(
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        SongListPerformanceSignpost.sortFeedbackScheduled(
            generation: generation,
            order: order.rawValue
        )
        sortFeedbackTask?.cancel()
        let updatedVisibleFeedback = sortProgress.begin(
            generation: generation,
            order: order
        )
        if updatedVisibleFeedback {
            sortFeedbackDeadline = nil
            SongListPerformanceSignpost.sortFeedbackShown(
                generation: generation,
                order: order.rawValue,
                updated: true
            )
            announceSortStatus(sortProgressMessage(for: order))
            return
        }

        sortFeedbackDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))

        sortFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            guard sortProgress.reveal(generation: generation) else { return }
            SongListPerformanceSignpost.sortFeedbackShown(
                generation: generation,
                order: order.rawValue,
                updated: false
            )
            announceSortStatus(sortProgressMessage(for: order))
        }
    }

    private func revealOverdueSortFeedbackBeforePublication(
        generation: Int,
        order: LibrarySongSortOrder,
        songCount: Int
    ) async {
        guard sortProgress.generation == generation,
              !sortProgress.isVisible,
              let sortFeedbackDeadline else { return }
        let now = ContinuousClock.now
        if now < sortFeedbackDeadline {
            let remaining = now.duration(to: sortFeedbackDeadline)
            // A large snapshot can finish sorting quickly but still spend well
            // over the threshold in SwiftUI publication. Give that known-cost
            // path real feedback; genuinely small/fast lists still publish
            // immediately unless they are within one display opportunity.
            guard SongListSortProgressState.shouldAwaitFeedbackDeadline(
                songCount: songCount
            ) || remaining <= .milliseconds(34) else { return }
            try? await Task.sleep(for: remaining)
        }
        guard sortProgress.generation == generation,
              !sortProgress.isVisible,
              sortProgress.reveal(generation: generation) else { return }
        SongListPerformanceSignpost.sortFeedbackShown(
            generation: generation,
            order: order.rawValue,
            updated: false
        )
        announceSortStatus(sortProgressMessage(for: order))
        // The deadline may have elapsed while a system Menu owned the main
        // run loop. Keep the newly revealed status for at least one display
        // opportunity before swapping the prepared snapshot.
        try? await Task.sleep(for: .milliseconds(34))
    }

    private func finishSortWithoutPublication(
        generation: Int,
        order: LibrarySongSortOrder,
        isExplicitSort: Bool
    ) {
        sortRequestActive = false
        activeSortIsExplicit = false
        guard isExplicitSort else { return }
        sortFeedbackTask?.cancel()
        sortFeedbackDeadline = nil
        let wasVisible = sortProgress.isVisible
        guard sortProgress.cancel(generation: generation) else { return }
        SongListPerformanceSignpost.sortCancelled(
            generation: generation,
            order: order.rawValue
        )
        if wasVisible {
            announceSortStatus(String(localized: "song_sort_progress_cancelled"))
        }
    }

    private func finishSortAfterPublication(
        generation: Int,
        order: LibrarySongSortOrder
    ) {
        guard sortGeneration == generation else { return }
        sortRequestActive = false
        activeSortIsExplicit = false
        sortFeedbackTask?.cancel()
        sortFeedbackDeadline = nil
        let shouldAnnounceCompletion = sortProgress.markPublished(generation: generation)
        if shouldAnnounceCompletion {
            announceSortStatus(sortCompletedMessage(for: order))
        }
        _ = sortProgress.finish(generation: generation)
    }

    private func cancelExplicitSortForSelection() {
        cancelExplicitSort(announceCancellation: true)
    }

    private func cancelExplicitSortForNavigation() {
        cancelExplicitSort(announceCancellation: false)
    }

    private func cancelExplicitSort(announceCancellation: Bool) {
        guard activeSortIsExplicit
                || pendingSnapshotIsExplicitSort
                || sortProgress.generation != nil else { return }
        let cancelledGeneration = sortGeneration
        let cancelledOrder = sortProgress.order ?? sortOrder.libraryOrder
        let wasVisible = sortProgress.isVisible
        sortGeneration &+= 1
        sortTask?.cancel()
        sortTask = nil
        sortFeedbackTask?.cancel()
        sortFeedbackTask = nil
        sortFeedbackDeadline = nil
        sortRequestActive = false
        activeSortIsExplicit = false
        if pendingSnapshotIsExplicitSort {
            pendingSnapshot = nil
            pendingSnapshotPrunesRows = false
            pendingSnapshotIsExplicitSort = false
            pendingSnapshotGeneration = 0
            pendingSnapshotOrder = nil
        }
        _ = sortProgress.cancel(generation: cancelledGeneration)
        SongListPerformanceSignpost.sortCancelled(
            generation: cancelledGeneration,
            order: cancelledOrder.rawValue
        )
        if announceCancellation, wasVisible {
            announceSortStatus(String(localized: "song_sort_progress_cancelled"))
        }
        let scopeKey = scope.snapshotCacheKey
        Task {
            await SongListSnapshotStore.shared.cancelPending(scopeKey: scopeKey)
        }
    }

    private func announceSortStatus(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif os(macOS)
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
    }

    private func playSong(_ song: Song) {
        let visibleQueue = filteredSongs
        guard let index = visibleQueue.firstIndex(where: { $0.id == song.id }) else { return }

        let queue = Array(visibleQueue[index...]) + Array(visibleQueue[..<index])
        guard let first = queue.first else { return }
        plog("🎶 SongList setQueue visible=\(visibleQueue.count) queue=\(queue.count) start='\(first.title)'")
        player.setQueue(queue, startAt: 0)
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(song: first) }
    }
}

/// Sorting changes only the visible models attached to stable positions.
/// Equatable also isolates unrelated parent state such as the Picker binding.
private struct IOSSongListContainer: View, @MainActor Equatable {
    let cache: SongListCache
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cache === rhs.cache && lhs.selection === rhs.selection
    }

    @ViewBuilder
    var body: some View {
        if SongListPresentationPolicy.prefersLazyStack(
            songCount: cache.positionCount
        ) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<cache.positionCount, id: \.self) { position in
                        IOSSongListPositionRow(
                            position: position,
                            cache: cache,
                            selection: selection,
                            onPlay: onPlay
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Divider().padding(.leading, 70)
                        }
                    }
                }
            }
        } else {
            List {
                ForEach(0..<cache.positionCount, id: \.self) { position in
                    IOSSongListPositionRow(
                        position: position,
                        cache: cache,
                        selection: selection,
                        onPlay: onPlay
                    )
                }
            }
            .listStyle(.plain)
        }
    }
}

private enum LibraryFolderNodePresentation {
    static var background: Color {
        #if os(macOS)
        return PMColor.bg
        #else
        return Color(.systemBackground)
        #endif
    }

    static func title(for node: LibraryFolderNode) -> String {
        switch node.kind {
        case .source:
            return node.displayName ?? String(localized: "source_label")
        case .scanRoot:
            return node.displayName ?? String(localized: "library_folder_scan_root")
        case .folder:
            return node.displayName ?? String(localized: "library_folder_scan_root")
        case .librarySongs:
            return node.displayName ?? String(localized: "library_folder_apple_music_library_songs")
        case .playlist:
            return node.displayName ?? String(localized: "library_folder_apple_music_unnamed_playlist")
        case .notInPlaylist:
            return node.displayName ?? String(localized: "library_folder_apple_music_not_in_playlist")
        case .uncategorized:
            return String(localized: "library_folder_uncategorized")
        case .other:
            return String(localized: "library_folder_other")
        }
    }

    static func icon(for kind: LibraryFolderNodeKind) -> String {
        switch kind {
        case .source: return "externaldrive.connected.to.line.below"
        case .scanRoot: return "externaldrive.fill.badge.checkmark"
        case .folder: return "folder.fill"
        case .librarySongs: return "music.note.house.fill"
        case .playlist: return "music.note.list"
        case .notInPlaylist: return "tray.fill"
        case .uncategorized: return "tray.fill"
        case .other: return "questionmark.folder.fill"
        }
    }

    static func songCount(_ count: Int) -> String {
        "\(count.formatted()) \(String(localized: "songs_count"))"
    }

    static func accessibilityToken(for id: LibraryFolderNodeID) -> String {
        // Swift's `hashValue` is deliberately randomized per process. A small
        // deterministic digest keeps UI automation stable without exposing a
        // source ID or normalized path through the accessibility identifier.
        var digest: UInt64 = 0xcbf29ce484222325
        let identity = [
            id.sourceID,
            id.kind.rawValue,
            id.normalizedRelativePath,
        ].joined(separator: "\u{1F}")
        for byte in identity.utf8 {
            digest ^= UInt64(byte)
            digest &*= 0x100000001b3
        }
        return String(digest, radix: 16)
    }
}

private struct LibraryFolderRootView: View {
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let rootSourceID: String?
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder

    var body: some View {
        ScrollView {
            LibraryFolderRootContent(
                folderCache: folderCache,
                listCache: listCache,
                rootSourceID: rootSourceID,
                selection: selection,
                sortOrder: $sortOrder
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 112)
        }
        .background(LibraryFolderNodePresentation.background.ignoresSafeArea())
    }
}

private struct LibraryFolderRootContent: View {
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let rootSourceID: String?
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder

    var body: some View {
        let nodes = folderCache.rootNodes(sourceID: rootSourceID)
        if nodes.isEmpty {
            ContentUnavailableView(
                "no_songs",
                systemImage: "folder",
                description: Text("no_songs_desc")
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(nodes) { node in
                    LibraryFolderNodeBranch(
                        nodeID: node.id,
                        depth: 0,
                        folderCache: folderCache,
                        listCache: listCache,
                        selection: selection,
                        sortOrder: $sortOrder
                    )
                    .id(node.id)
                }
            }
        }
    }
}

private struct LibraryFolderNodeBranch: View {
    let nodeID: LibraryFolderNodeID
    let depth: Int
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder

    @State private var isExpanded = false

    @ViewBuilder
    var body: some View {
        if let node = folderCache.node(withID: nodeID) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    disclosureButton(for: node)
                    rowAction(for: node)
                }
                .padding(.leading, CGFloat(min(depth, 8)) * 14)
                .frame(minHeight: 56)

                Divider()
                    .padding(.leading, CGFloat(min(depth, 8)) * 14 + 52)

                if isExpanded {
                    LazyVStack(spacing: 0) {
                        ForEach(folderCache.children(of: node.id)) { child in
                            AnyView(LibraryFolderNodeBranch(
                                nodeID: child.id,
                                depth: depth + 1,
                                folderCache: folderCache,
                                listCache: listCache,
                                selection: selection,
                                sortOrder: $sortOrder
                            ))
                            .id(child.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func disclosureButton(for node: LibraryFolderNode) -> some View {
        if node.childNodeCount > 0 {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: isExpanded
                ? String(localized: "library_folder_collapse")
                : String(localized: "library_folder_expand")
            ))
            .accessibilityIdentifier(
                "libraryFolderDisclosure.\(LibraryFolderNodePresentation.accessibilityToken(for: node.id))"
            )
        } else {
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func rowAction(for node: LibraryFolderNode) -> some View {
        if selection.isActive {
            LibraryFolderSelectionButton(
                node: node,
                folderCache: folderCache,
                listCache: listCache,
                selection: selection
            )
        } else {
            NavigationLink {
                LibraryFolderNodeView(
                    nodeID: node.id,
                    folderCache: folderCache,
                    listCache: listCache,
                    selection: selection,
                    sortOrder: $sortOrder
                )
            } label: {
                LibraryFolderNodeLabel(node: node, selectionState: nil)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    selection.activate()
                    selection.selectAll(actionSongIDs())
                } label: {
                    Label("batch_select", systemImage: "checkmark.circle")
                }
                .disabled(node.descendantSongCount == 0)
            }
            .accessibilityAction(named: Text("batch_select")) {
                selection.activate()
                selection.selectAll(actionSongIDs())
            }
        }
    }

    private func actionSongIDs() -> [String] {
        folderCache.orderedSongIDs(
            in: nodeID,
            scope: .action,
            listCache: listCache
        )
    }
}

/// A dedicated observation boundary keeps an aggregate folder-state change
/// from rebuilding its expanded descendants. The selection index materializes
/// the descendant set only when the immutable folder/list version changes.
private struct LibraryFolderSelectionButton: View {
    let node: LibraryFolderNode
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let selection: SongSelectionModel

    var body: some View {
        let songIDs = folderCache.orderedSongIDs(
            in: node.id,
            scope: .action,
            listCache: listCache
        )
        let membership = selection.groupMembership(
            for: node.id,
            version: LibraryFolderSelectionVersion(
                folderRevision: folderCache.revision,
                rowOrderRevision: listCache.rowOrderRevision
            ),
            songIDs: songIDs
        )
        let snapshot = membership.snapshot

        Button {
            selection.toggleGroup(songIDs)
        } label: {
            LibraryFolderNodeLabel(
                node: node,
                selectionState: snapshot.state,
                selectionSongCount: snapshot.songCount
            )
        }
        .buttonStyle(.plain)
        .disabled(snapshot.songCount == 0)
        .accessibilityAddTraits(snapshot.state == .all ? .isSelected : [])
    }
}

private struct LibraryFolderNodeLabel: View {
    let node: LibraryFolderNode
    let selectionState: SongSelectionModel.GroupState?
    let selectionSongCount: Int?

    init(
        node: LibraryFolderNode,
        selectionState: SongSelectionModel.GroupState?,
        selectionSongCount: Int? = nil
    ) {
        self.node = node
        self.selectionState = selectionState
        self.selectionSongCount = selectionSongCount
    }

    var body: some View {
        HStack(spacing: 12) {
            if let selectionState {
                Image(systemName: selectionIcon(for: selectionState))
                    .font(.title3)
                    .foregroundStyle(selectionState == .none ? .secondary : Color.accentColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }

            Image(systemName: LibraryFolderNodePresentation.icon(for: node.kind))
                .font(.title3)
                .foregroundStyle(node.kind == .other ? Color.secondary : Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: LibraryFolderNodePresentation.title(for: node))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)

                Text(verbatim: LibraryFolderNodePresentation.songCount(node.descendantSongCount))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            if selectionState == nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: LibraryFolderNodePresentation.title(for: node)))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityIdentifier(
            "libraryFolderNode.\(node.kind.rawValue).\(LibraryFolderNodePresentation.accessibilityToken(for: node.id))"
        )
    }

    private func selectionIcon(for state: SongSelectionModel.GroupState) -> String {
        switch state {
        case .none: return "circle"
        case .partial: return "minus.circle.fill"
        case .all: return "checkmark.circle.fill"
        }
    }

    private var accessibilityValue: String {
        let songCount = LibraryFolderNodePresentation.songCount(
            selectionSongCount ?? node.descendantSongCount
        )
        guard let selectionState else { return songCount }
        let state: String
        switch selectionState {
        case .none:
            state = String(localized: "library_folder_selection_none")
        case .partial:
            state = String(localized: "library_folder_selection_partial")
        case .all:
            state = String(localized: "library_folder_selection_all")
        }
        return "\(state), \(songCount)"
    }
}

private struct LibraryFolderNodeView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    let nodeID: LibraryFolderNodeID
    let folderCache: LibraryFolderBrowserCache
    let listCache: SongListCache
    let selection: SongSelectionModel
    @Binding var sortOrder: SongListView.SongSortOrder

    var body: some View {
        content
            .navigationTitle(Text(verbatim: navigationTitle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { iosToolbar }
            #endif
            .songBatchActions(
                selection: selection,
                context: nodeID.sourceID == AppleMusicLibraryIdentity.sourceID
                    ? .readOnly
                    : .library,
                orderedIDs: { actionSongIDs },
                resolve: { library.unobservedVisibleSong(id: $0) }
            )
            .onChange(of: folderCache.revision) { _, _ in
                pruneSelection()
            }
            .onChange(of: listCache.rowOrderRevision) { _, _ in
                pruneSelection()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let node = folderCache.node(withID: nodeID) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    #if os(macOS)
                    macFolderHeader(node)
                    #endif

                    let children = folderCache.children(of: nodeID)
                    if !children.isEmpty {
                        sectionHeader("shared_folders")
                        ForEach(children) { child in
                            LibraryFolderNodeBranch(
                                nodeID: child.id,
                                depth: 0,
                                folderCache: folderCache,
                                listCache: listCache,
                                selection: selection,
                                sortOrder: $sortOrder
                            )
                            .id(child.id)
                        }
                    }

                    if !visibleSongIDs.isEmpty {
                        sectionHeader("tab_songs")
                        ForEach(visibleSongIDs, id: \.self) { songID in
                            LibraryFolderSongRow(
                                songID: songID,
                                orderedIDs: { visibleSongIDs },
                                listCache: listCache,
                                selection: selection,
                                onPlay: playSong
                            )
                            .id(songID)
                        }
                    }

                    if children.isEmpty && visibleSongIDs.isEmpty {
                        ContentUnavailableView(
                            "no_songs",
                            systemImage: "folder",
                            description: Text("no_songs_desc")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 112)
            }
            .background(LibraryFolderNodePresentation.background.ignoresSafeArea())
        } else {
            ContentUnavailableView(
                "no_songs",
                systemImage: "folder.badge.questionmark",
                description: Text("no_songs_desc")
            )
        }
    }

    private var navigationTitle: String {
        guard let node = folderCache.node(withID: nodeID) else {
            return String(localized: "library_browse_folder")
        }
        return LibraryFolderNodePresentation.title(for: node)
    }

    private var visibleSongIDs: [String] {
        folderCache.orderedSongIDs(
            in: nodeID,
            scope: .visible,
            listCache: listCache
        )
    }

    private var actionSongIDs: [String] {
        folderCache.orderedSongIDs(
            in: nodeID,
            scope: .action,
            listCache: listCache
        )
    }

    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.headline)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private func macFolderHeader(_ node: LibraryFolderNode) -> some View {
        HStack(spacing: 12) {
            Label(
                LibraryFolderNodePresentation.title(for: node),
                systemImage: LibraryFolderNodePresentation.icon(for: node.kind)
            )
            .font(.title2.weight(.semibold))

            Spacer()

            Menu {
                Picker("sort_by", selection: $sortOrder) {
                    ForEach(SongListView.SongSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Label("sort_by", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(selection.isActive)
        }
        .padding(12)
    }
    #endif

    #if os(iOS)
    @ToolbarContentBuilder
    private var iosToolbar: some ToolbarContent {
        if selection.isActive {
            ToolbarItem(placement: .principal) {
                SongSelectionToolbarTitle(selection: selection)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                SongSelectionOptionsMenu(
                    selection: selection,
                    orderedIDs: { actionSongIDs }
                )
                Button("done") {
                    selection.deactivate()
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Picker("sort_by", selection: $sortOrder) {
                            ForEach(SongListView.SongSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    Section {
                        Button {
                            selection.activate()
                        } label: {
                            Label("batch_select", systemImage: "checkmark.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("a11y_more_actions"))
            }
        }
    }
    #endif

    private func playSong(_ song: Song) {
        let queue = visibleSongIDs
            .compactMap { library.unobservedVisibleSong(id: $0) }
            .filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(song: song) }
    }

    private func pruneSelection() {
        guard selection.isActive, !selection.isEmpty else { return }
        selection.prune(to: Set(actionSongIDs))
    }
}

private struct LibraryFolderSongRow: View {
    @Environment(MusicLibrary.self) private var library

    let songID: String
    let orderedIDs: () -> [String]
    let listCache: SongListCache
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    @ViewBuilder
    var body: some View {
        if let model = listCache.rowModel(
            id: songID,
            song: library.unobservedVisibleSong(id: songID)
        ) {
            IOSSongListRow(model: model, selection: selection, onPlay: onPlay)
                .songSelectable(
                    songID: songID,
                    selection: selection,
                    orderedIDs: orderedIDs,
                    defaultAction: { onPlay(model.song) }
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)

            Divider()
                .padding(.leading, 72)
        }
    }
}

/// Each resolved List position observes its own lightweight model. Snapshot
/// publication updates only visible/prefetched models; an offscreen slot syncs
/// from the latest snapshot when it appears.
private struct IOSSongListPositionRow: View {
    @Environment(MusicLibrary.self) private var library

    let position: Int
    let cache: SongListCache
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    @ViewBuilder
    var body: some View {
        let positionModel = cache.positionModel(at: position)
        Group {
            if let row = positionModel.row,
               let model = cache.rowModel(
                   id: row.id,
                   song: library.unobservedVisibleSong(id: row.id)
               ) {
                IOSSongListRow(model: model, selection: selection, onPlay: onPlay)
                    .songSelectable(
                        songID: row.id,
                        selection: selection,
                        orderedIDs: { cache.orderedSongIDs },
                        defaultAction: { onPlay(model.song) }
                    )
                    // The structural identity stays bound to `position`,
                    // while VoiceOver tracks the song currently occupying it.
                    .accessibilityIdentifier("songRow.\(row.id)")
            }
        }
        .onAppear { cache.setPosition(position, isVisible: true) }
        .onDisappear { cache.setPosition(position, isVisible: false) }
    }
}

/// Separate observation boundaries keep a count change from re-evaluating the
/// parent `SongListView` and its complete `ForEach` description.
private struct SongSelectionToolbarTitle: View {
    let selection: SongSelectionModel

    var body: some View {
        Text(verbatim: String(
            format: String(localized: "batch_selected_count_format"),
            selection.count
        ))
        .font(.headline)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

private struct SongSelectionOptionsMenu: View {
    let selection: SongSelectionModel
    let orderedIDs: () -> [String]

    var body: some View {
        Menu {
            Button {
                selection.selectAll(orderedIDs())
            } label: {
                Label("batch_select_all", systemImage: "checkmark.circle.fill")
            }

            Button {
                selection.clear()
            } label: {
                Label("batch_deselect_all", systemImage: "circle.dashed")
            }
            .disabled(selection.isEmpty)
        } label: {
            Image(systemName: "checklist")
        }
        .accessibilityLabel(Text("a11y_more_actions"))
    }
}

/// A row-level observation boundary. Metadata/backfill changes replace the
/// model for one song, and only this subtree re-evaluates; the parent List no
/// longer observes Song values or per-row source/backfill state.
private struct IOSSongListRow: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    let model: SongListRowModel
    let selection: SongSelectionModel
    let onPlay: (Song) -> Void

    var body: some View {
        let song = model.song
        SongRowView(
            song: song,
            isPlaying: player.currentSong?.id == song.id,
            selection: selection,
            context: SongRowView.context(
                for: song,
                sourcesStore: sourcesStore,
                backfill: backfill
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.isActive {
                selection.toggle(song.id)
            } else {
                onPlay(song)
            }
        }
    }
}
