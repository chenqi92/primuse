#if os(tvOS)
import SwiftUI
import PrimuseKit

enum TVDiscoveryText {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "HomeDiscovery", comment: "")
    }
}

struct TVBrowseDestination: Identifiable {
    let id: String
    let title: String
    let songIDs: [String]
}

struct TVSongCollectionView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let destination: TVBrowseDestination
    var openPlayer: () -> Void = {}

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            HStack(alignment: .top, spacing: 50) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(destination.title).tvFont(.pageTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PMString("ext.tv.songsCount", destination.songIDs.count))
                        .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    TVPillButton(title: PMString("ext.tv.home.playAll"), systemImage: "play.fill", style: .solid) {
                        play(shuffled: false)
                    }
                    TVPillButton(title: PMString("ext.tv.home.shuffle"), systemImage: "shuffle") {
                        play(shuffled: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 410, alignment: .leading)
                .focusSection()
                ScrollView {
                    TVPagedSongIDList(songIDs: destination.songIDs, spacing: 14, action: finishPlayback)
                        .padding(18)
                }
                .focusSection()
            }
            .padding(.horizontal, 80).padding(.vertical, 54)
            .foregroundStyle(TVColor.text)
        }
        .onExitCommand { dismiss() }
    }

    private func play(shuffled: Bool) {
        if store.playResolvedQueue(songIDs: destination.songIDs, shuffled: shuffled) { finishPlayback() }
    }

    private func finishPlayback() { openPlayer(); dismiss() }
}

struct TVGenreBrowser: View {
    @Environment(TVStore.self) private var store
    @State private var destination: TVBrowseDestination?
    @State private var opensPlayerAfterDismissal = false
    var openPlayer: () -> Void = {}
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    var body: some View {
        if store.library.visibleGenres.isEmpty {
            TVEmptyState(icon: "guitars", title: String(localized: "tab_genres"))
                .frame(minHeight: 400)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .top), count: 3), spacing: 26) {
                ForEach(store.library.visibleGenres) { genre in
                    let ids = store.library.songs(forGenre: genre.id).map(\.id)
                    TVFocusButton(radius: 18, scale: 1.03, lift: 0, action: {
                        destination = TVBrowseDestination(id: genre.id, title: genre.name, songIDs: ids)
                    }) { focused in
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 6) {
                                ForEach(Array(ids.prefix(3)), id: \.self) { id in
                                    if let song = store.song(id) {
                                        TVBrowseSongArtwork(song: song, size: 76)
                                    }
                                }
                            }
                            Text(genre.name).tvFont(.cardTitle).lineLimit(2, reservesSpace: true)
                            Text(PMString("ext.tv.songsCount", ids.count)).tvFont(.caption)
                                .foregroundStyle(TVColor.textMuted)
                        }
                        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(focused ? TVColor.surfaceStrong : TVColor.card)
                    }
                }
            }
            .foregroundStyle(TVColor.text)
            .fullScreenCover(item: $destination, onDismiss: finishDismissal) { value in
                TVSongCollectionView(destination: value, openPlayer: { opensPlayerAfterDismissal = true })
            }
            .onChange(of: destination != nil) { _, active in onModalActivityChanged(active) }
            .onDisappear { onModalActivityChanged(false) }
        }
    }
    private func finishDismissal() {
        onModalActivityChanged(false)
        if opensPlayerAfterDismissal {
            opensPlayerAfterDismissal = false
            openPlayer()
        }
    }

}

struct TVFolderBrowser: View {
    @Environment(TVStore.self) private var store
    @State private var index: LibraryFolderIndex?
    @State private var path: [LibraryFolderNodeID] = []
    var openPlayer: () -> Void = {}

    private var current: LibraryFolderNode? {
        path.last.flatMap { index?.node(withID: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let index {
                if let current {
                    HStack(spacing: 22) {
                        TVPillButton(title: String(localized: "tv_remote_back"), systemImage: "chevron.left") {
                            path.removeLast()
                        }
                        Text(currentTitle(current, index: index)).tvFont(.sectionTitle).lineLimit(2)
                        Spacer(minLength: 0)
                        TVPillButton(title: PMString("ext.tv.home.playAll"), systemImage: "play.fill", style: .solid) {
                            let ids = LibraryFolderBrowsePolicy.actionSongIDs(in: current.id, index: index, orderedBy: store.songIDs)
                            if store.playResolvedQueue(songIDs: ids, shuffled: false) { openPlayer() }
                        }
                    }
                }
                let nodes = current.map { index.children(of: $0.id) } ?? index.sourceNodes
                TVPagedList(nodes, alignment: .leading, spacing: 22) { _, node, onFocusChanged in
                    TVFocusButton(radius: 14, scale: 1.02, lift: 0,
                                  action: { enter(node, index: index) },
                                  onFocusChanged: onFocusChanged) { focused in
                        HStack(spacing: 22) {
                            Image(systemName: node.kind == .source ? "server.rack" : "folder.fill")
                                .font(.system(size: 34)).foregroundStyle(TVColor.brand).frame(width: 50)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Self.title(node)).tvFont(.cardTitle).lineLimit(2)
                                Text(String(format: TVDiscoveryText.string("folder_counts"), node.childNodeCount, node.descendantSongCount))
                                    .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                            }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").tvFont(.caption)
                        }
                        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(focused ? TVColor.surfaceStrong : TVColor.card)
                    }
                }
                if let current {
                    let ids = LibraryFolderBrowsePolicy.visibleSongIDs(in: current.id, index: index, orderedBy: store.songIDs)
                    TVPagedSongIDList(songIDs: ids, alignment: .leading, spacing: 22, action: openPlayer)
                } else if nodes.isEmpty {
                    TVEmptyState(icon: "folder", title: TVDiscoveryText.string("no_folders"), subtitle: TVDiscoveryText.string("folders_hint"))
                        .frame(minHeight: 350)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .foregroundStyle(TVColor.text)
        .task(id: store.recommendationRevision) {
            let built = await store.makeFolderIndex()
            guard !Task.isCancelled else { return }
            index = built
            if path.contains(where: { built.node(withID: $0) == nil }) { path = [] }
        }
        .onExitCommand(perform: path.isEmpty ? nil : { path.removeLast() })
    }

    private func enter(_ node: LibraryFolderNode, index: LibraryFolderIndex) {
        let children = index.children(of: node.id)
        if node.kind == .source, children.count == 1, children[0].kind == .scanRoot {
            path.append(children[0].id)
        } else {
            path.append(node.id)
        }
    }

    private func currentTitle(_ node: LibraryFolderNode, index: LibraryFolderIndex) -> String {
        if node.kind == .scanRoot, node.displayName == nil,
           let source = index.sourceNodes.first(where: { $0.id.sourceID == node.id.sourceID }) {
            return Self.title(source)
        }
        return Self.title(node)
    }

    static func title(_ node: LibraryFolderNode) -> String {
        if let name = node.displayName, !name.isEmpty { return name }
        let key: String
        switch node.kind {
        case .uncategorized: key = "library_folder_uncategorized"
        case .other: key = "library_folder_other"
        case .librarySongs: key = "library_folder_apple_music_library_songs"
        case .notInPlaylist: key = "library_folder_apple_music_not_in_playlist"
        case .playlist: key = "library_folder_apple_music_unnamed_playlist"
        case .scanRoot, .folder, .source: key = "library_folder_scan_root"
        }
        return NSLocalizedString(key, comment: "")
    }
}

struct TVRankingBrowser: View {
    @Environment(TVStore.self) private var store
    @State private var period = HomeListeningPeriod.week
    @State private var category = HomeListeningCategory.songs
    @State private var destination: TVBrowseDestination?
    @State private var opensPlayerAfterDismissal = false
    var openPlayer: () -> Void = {}
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    @State private var ranks: [HomeListeningRank] = []
    @State private var historyRevision = 0

    private var rankingIdentity: String {
        "\(period.rawValue)#\(category.rawValue)#\(store.recommendationRevision)#\(historyRevision)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                ForEach(HomeListeningPeriod.allCases, id: \.self) { value in
                    TVSelectionButton(title: NSLocalizedString("stats_range_" + value.rawValue, comment: ""), selected: value == period) { period = value }
                }
            }.focusSection()
            HStack(spacing: 14) {
                ForEach(HomeListeningCategory.allCases, id: \.self) { value in
                    TVSelectionButton(
                        title: value == .folders ? TVDiscoveryText.string("folders") : NSLocalizedString("stats_rank_" + value.rawValue, comment: ""),
                        selected: category == value
                    ) { category = value }
                }
            }.focusSection()
            Text(TVDiscoveryText.string("ranking_scope")).tvFont(.caption).foregroundStyle(TVColor.textMuted)
            if ranks.isEmpty {
                TVEmptyState(icon: "chart.bar", title: TVDiscoveryText.string("empty_ranking"), subtitle: TVDiscoveryText.string("ranking_hint"))
                    .frame(minHeight: 350)
            } else {
                TVPagedList(ranks, alignment: .leading, spacing: 24) { offset, rank, onFocusChanged in
                    TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: {
                        destination = TVBrowseDestination(id: rank.id, title: rank.title, songIDs: rank.songIDs)
                    }, onFocusChanged: onFocusChanged) { focused in
                        HStack(spacing: 20) {
                            Text(String(offset + 1)).tvFont(.sectionTitle).monospacedDigit().frame(width: 50)
                                .foregroundStyle(offset < 3 ? TVColor.brand : TVColor.textMuted)
                            if let id = rank.songIDs.first, let song = store.song(id) { TVBrowseSongArtwork(song: song, size: 74) }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(rank.title).tvFont(.cardTitle).lineLimit(2)
                                Text(rank.subtitle).tvFont(.caption).foregroundStyle(TVColor.textMuted).lineLimit(1)
                            }
                            Spacer(minLength: 10)
                            Text(String(format: TVDiscoveryText.string("play_count"), rank.playCount))
                                .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                            Image(systemName: "chevron.right").tvFont(.caption)
                        }.padding(22).background(focused ? TVColor.surfaceStrong : TVColor.card)
                    }
                }
            }
        }
        .foregroundStyle(TVColor.text)
        .task(id: rankingIdentity) {
            let selectedPeriod = period
            let selectedCategory = category
            let folders = selectedCategory == .folders ? await store.makeFolderIndex() : nil
            let events = PlayHistoryStore.shared.entries.map {
                HomeListeningEvent(songID: $0.songID, playedAt: $0.playedAt, listenedSeconds: $0.listenedSec)
            }
            let songs = Dictionary(uniqueKeysWithValues: store.songIDs.compactMap { id in
                store.library.song(id: id).map { (id, $0) }
            })
            let result = await Task.detached(priority: .userInitiated) {
                HomeListeningRanking.ranks(events: events, songs: songs, folders: folders,
                                          period: selectedPeriod, category: selectedCategory)
            }.value
            guard !Task.isCancelled else { return }
            ranks = result
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in historyRevision &+= 1 }
        .fullScreenCover(item: $destination, onDismiss: finishDismissal) { value in
            TVSongCollectionView(destination: value, openPlayer: { opensPlayerAfterDismissal = true })
        }
        .onChange(of: destination != nil) { _, active in onModalActivityChanged(active) }
            .onDisappear { onModalActivityChanged(false) }
    }
    private func finishDismissal() {
        onModalActivityChanged(false)
        if opensPlayerAfterDismissal {
            opensPlayerAfterDismissal = false
            openPlayer()
        }
    }

}

struct TVSelectionButton: View {
    let title: String
    let selected: Bool
    var action: () -> Void

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: action) { focused in
            Text(title).tvFont(.caption, weight: .semibold).lineLimit(2)
                .padding(.horizontal, 24).frame(minHeight: 64)
                .foregroundStyle(selected ? TVColor.onBrand : TVColor.text)
                .background(selected ? TVColor.brand : (focused ? TVColor.surfaceStrong : TVColor.card))
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct TVBrowseSongArtwork: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    let size: CGFloat

    var body: some View {
        let album = store.albumOf(song)
        TVArtworkView(coverKey: song.albumID, artist: song.artist, album: album?.title ?? "", songID: song.id,
                      coverRef: song.coverRef, tint: album?.tint ?? TVColor.brand, tint2: album?.tint2 ?? .black,
                      glyph: album?.glyph ?? "♪", size: size, radius: 10)
    }
}

extension TVStore {
    func makeFolderIndex() async -> LibraryFolderIndex {
        let sources = sourcesStore.allSources.map { LibraryFolderSourceDescriptor(source: $0) }
        let visible = songIDs.compactMap { library.song(id: $0) }
        return await Task.detached(priority: .userInitiated) {
            LibraryFolderIndexBuilder.build(sources: sources, songs: visible)
        }.value
    }
}
#endif
