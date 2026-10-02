import SwiftUI
import PrimuseKit

enum SearchRecommendationOriginPolicy {
    nonisolated static func intelligentIDs<ID: Hashable>(
        primary: [ID], recommended: [ID], isCurrentQuery: Bool
    ) -> Set<ID> {
        guard isCurrentQuery else { return [] }
        return Set(recommended).subtracting(primary)
    }
}

struct SearchRecommendationBadge: View {
    var body: some View {
        Label("library_recommendations_title", systemImage: "sparkles")
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.1), in: Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SearchArtworkRecommendationBadge: View {
    var iconOnly = false

    var body: some View {
        Group {
            if iconOnly {
                Image(systemName: "sparkles")
                    .frame(width: 12, height: 12)
                    .padding(4)
                    .accessibilityLabel(Text("library_recommendations_title"))
            } else {
                Label("library_recommendations_title", systemImage: "sparkles")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.accentColor)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
        .lineLimit(1)
        .allowsHitTesting(false)
    }
}

extension View {
    func searchRecommendationOverlay(isRecommended: Bool, iconOnly: Bool = false, inset: CGFloat = 6) -> some View {
        overlay(alignment: .topTrailing) {
            if isRecommended {
                SearchArtworkRecommendationBadge(iconOnly: iconOnly)
                    .padding(inset)
            }
        }
    }
}

enum SearchResultActionTarget {
    case album(String)
    case artist(String)
    case collection(SearchCollectionResult)

    var moreMenuAccessibilityIdentifier: String {
        switch self {
        case .album(let id): "search.album.more.\(id)"
        case .artist(let id): "search.artist.more.\(id)"
        case .collection(let result): "search.collection.more.\(result.id)"
        }
    }

    @MainActor
    func songs(in library: MusicLibrary) -> [PrimuseKit.Song] {
        switch self {
        case .album(let id): library.songs(forAlbum: id)
        case .artist(let id): library.songs(forArtist: id)
        case .collection(let result): result.songs(in: library)
        }
    }

    @MainActor
    func addToLiked(in library: MusicLibrary) {
        library.likeSongs(songs(in: library).map(\.id))
    }
}

struct SearchCollectionResult: Identifiable, Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case playlist(String)
        case smartPlaylist(String)
        case folder(LibraryFolderNodeID)
    }

    let target: Target
    let title: String
    let detail: String
    var folderSongIDs: [String] = []
    var relatedConcept: String?

    var id: Target { target }
    var section: SearchResultSection {
        if case .folder = target { return .folders }
        return .playlists
    }
    var icon: String {
        switch target {
        case .playlist: "music.note.list"
        case .smartPlaylist: "sparkles"
        case .folder: "folder.fill"
        }
    }

    @MainActor
    func songs(in library: MusicLibrary) -> [PrimuseKit.Song] {
        switch target {
        case .playlist(let id): library.songs(forPlaylist: id)
        case .smartPlaylist(let id):
            library.smartPlaylists.first { $0.id == id }.map {
                SmartPlaylistEngine.match($0, in: library, history: PlayHistoryStore.shared)
            } ?? []
        case .folder: folderSongIDs.compactMap { library.song(id: $0) }
        }
    }

    /// The songs as IDs. A folder result can be most of a large library, so
    /// the detail page keeps only these and resolves the rows it shows.
    @MainActor
    func songIDs(in library: MusicLibrary) -> [String] {
        switch target {
        case .playlist(let id): library.songIDs(forPlaylist: id)
        case .smartPlaylist: songs(in: library).map(\.id)
        case .folder: folderSongIDs
        }
    }
}

enum SearchCatalogTextPolicy {
    nonisolated static func matches(_ text: String, query: String) -> Bool {
        let query = ListeningSpaceSearchPolicy.normalized(query)
        guard !query.isEmpty else { return false }
        let text = ListeningSpaceSearchPolicy.normalized(text)
        if text.contains(query) { return true }
        let words = query.split(separator: " ")
        return words.count > 1 && words.allSatisfy { text.contains($0) }
    }

    nonisolated static func collections(
        query: String,
        playlists: [Playlist],
        smartPlaylists: [SmartPlaylist],
        folderIndex: LibraryFolderIndex?,
        limit: Int = 60
    ) -> [SearchCollectionResult] {
        var results = playlists.filter {
            !$0.isDeleted && matches($0.name, query: query)
        }.map {
            SearchCollectionResult(target: .playlist($0.id), title: $0.name, detail: "")
        }
        results += smartPlaylists.filter {
            !$0.isDeleted && matches($0.name, query: query)
        }.map {
            SearchCollectionResult(target: .smartPlaylist($0.id), title: $0.name, detail: "")
        }
        if let index = folderIndex {
            var pending = index.sourceNodes
            while let node = pending.popLast() {
                guard !Task.isCancelled else { return [] }
                pending.append(contentsOf: index.children(of: node.id).reversed())
                guard node.kind == .folder || node.kind == .scanRoot,
                      node.descendantSongCount > 0,
                      let name = node.displayName,
                      matches(name, query: query) else { continue }
                var ancestors: [String] = []
                var parentID = node.parentID
                while let id = parentID, let parent = index.node(withID: id) {
                    if let name = parent.displayName { ancestors.append(name) }
                    parentID = parent.parentID
                }
                results.append(SearchCollectionResult(
                    target: .folder(node.id), title: name,
                    detail: ancestors.reversed().joined(separator: " › "),
                    folderSongIDs: index.songIDs(in: node.id, scope: .descendants)
                ))
            }
        }
        return Array(results.sorted {
            let lhsExact = ListeningSpaceSearchPolicy.normalized($0.title) == ListeningSpaceSearchPolicy.normalized(query)
            let rhsExact = ListeningSpaceSearchPolicy.normalized($1.title) == ListeningSpaceSearchPolicy.normalized(query)
            if lhsExact != rhsExact { return lhsExact }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }.prefix(max(0, limit)))
    }
}

enum SearchPlaybackSelectionPolicy {
    @MainActor
    static func currentSong(for result: PrimuseKit.Song, in library: MusicLibrary) -> PrimuseKit.Song? {
        guard let current = library.song(id: result.id), current.isPlayable else { return nil }
        return current
    }
}

struct SearchFolderSnapshotKey: Equatable {
    let collectionRevision: Int
    let hierarchyRevision: Int
    let sources: [LibraryFolderSourceDescriptor]
}

struct SearchFolderProviderInput: Sendable {
    let descriptor: LibraryFolderSourceDescriptor
    let items: [String: SourceSyncIndexedItem]
    let rootNames: [String: String]
    let usesIndexedRoots: Bool

    nonisolated func resolvedDescriptor() -> LibraryFolderSourceDescriptor {
        guard !items.isEmpty else { return descriptor }
        let indexedRoots = items.values.filter { $0.isDirectory && $0.parentPath == nil }
            .sorted { $0.path < $1.path }
        let paths = usesIndexedRoots && !indexedRoots.isEmpty
            ? indexedRoots.map(\.path) : descriptor.scanRoots
        return descriptor.withProviderHierarchy(LibraryFolderProviderHierarchy(
            roots: paths.map { path in
                LibraryFolderProviderRootDescriptor(
                    path: path,
                    displayName: indexedRoots.first { $0.path == path }?.displayName
                        ?? rootNames[path]
                        ?? (descriptor.pathSemantics == .hierarchical && path != "/"
                            ? (path as NSString).lastPathComponent : nil)
                )
            },
            items: items.values.map {
                LibraryFolderProviderItemDescriptor(
                    path: $0.path, displayName: $0.displayName,
                    parentPath: $0.parentPath, isDirectory: $0.isDirectory
                )
            }
        ))
    }
}

struct SearchCollectionDetailView: View {
    let result: SearchCollectionResult
    var onMacInlineBack: (() -> Void)? = nil
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    /// Resolved once per result. A `List` of a folder holding most of a large
    /// library made SwiftUI register every row up front — seconds on the main
    /// thread — so the page keeps IDs and a lazy stack resolves what it shows.
    @State private var songIDs: [String] = []

    var body: some View {
        let ids = songIDs
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                macHeader(songCount: ids.count)
                #endif
                Button {
                    Task { await player.play(queueIDs: ids) }
                } label: {
                    Label("play_all", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(ids.isEmpty)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider().padding(.leading, 20)
                ForEach(ids, id: \.self) { songID in
                    // Unobserved: a metadata write elsewhere must not make
                    // the page walk every ID of a huge folder again.
                    if let song = library.unobservedVisibleSong(id: songID) {
                        SongRowView(song: song, isPlaying: player.currentSong?.id == song.id,
                                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let index = ids.firstIndex(of: songID) else { return }
                                Task { await player.play(queueIDs: ids, startingAt: index, playableOnly: false) }
                            }
                        Divider().padding(.leading, 66)
                    }
                }
            }
        }
        .task(id: result.id) {
            songIDs = result.songIDs(in: library)
        }
        .navigationTitle(result.title)
        #if os(iOS)
        .minimalNavigationDetail()
        .librarySearchContext {
            LibrarySearchScope(title: result.title, songIDs: Set(ids),
                               kind: result.section == .folders ? .folder : .playlist,
                               detail: result.detail)
        }
        #endif
    }

    #if os(macOS)
    /// Mac 的窗口工具栏是隐藏的, 导航标题和系统返回键都看不到, 页内自己摆。
    private func macHeader(songCount: Int) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                Text(verbatim: result.title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(2)
                // id 还没载入时不写「0 首」, 免得进页先闪一下。
                Text(verbatim: [result.detail, songCount > 0 ? "\(songCount) \(String(localized: "songs_count"))" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            if let onMacInlineBack {
                MacNavigationBackButton(
                    accessibilityIdentifier: "searchCollectionInlineBack",
                    action: onMacInlineBack
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
    #endif
}
