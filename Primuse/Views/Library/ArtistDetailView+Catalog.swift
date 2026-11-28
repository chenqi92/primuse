import Foundation
import PrimuseKit
import SwiftUI

/// 艺人页两排专辑(他发行的、他参与的)在歌曲模型不在内存里时从曲库目录取(6c 单元 4 详情页):候选
/// (`artistAlbumShelfCandidates`:署名有他的、专辑艺人是他的、他唱的歌所在的)交给同一个
/// `ArtistAlbumShelfPolicy.partition`,发行的那几张的专辑分类一并算好(`ReleaseCategoryCatalog`),
/// 两排的成员、先后、分到哪一排与模型在内存里时相同。
struct ArtistCatalogShelves: Equatable {
    struct Key: Hashable {
        let artistID: String
        let displayName: String
        let catalog: [UInt64]
    }

    let key: Key
    let release: [Album]
    let appearsOn: [Album]

    /// 模型不在内存里、曲库可用、目录读得了时这一刻的键(读的视图跟着目录变);否则 nil(读内存模型)。
    @MainActor
    static func key(artistID: String, displayName: String, library: MusicLibrary) -> Key? {
        guard !library.isReady, library.isUsable, let revisions = library.catalogHost?.revisions,
              revisions.isReadable else { return nil }
        return Key(
            artistID: artistID, displayName: displayName,
            catalog: [revisions.albums, revisions.artists, revisions.membership, revisions.everything]
        )
    }

    /// 读不出来时 nil(页面先空着这两排,下一次目录变了再读)。
    @MainActor
    static func load(_ key: Key, songs: [Song], library: MusicLibrary) async -> ArtistCatalogShelves? {
        guard let reader = library.readableCatalogReader else { return nil }
        let songAlbumIDs = Set(songs.compactMap(\.albumID))
        do {
            let candidates = try await reader.read {
                try $0.artistAlbumShelfCandidates(
                    artistID: key.artistID, displayName: key.displayName, songAlbumIDs: songAlbumIDs
                )
            }
            let partition = ArtistAlbumShelfPolicy.partition(
                albums: candidates.albums, artistID: key.artistID, displayName: key.displayName,
                songAlbumIDs: songAlbumIDs, isCredited: { candidates.creditedAlbumIDs.contains($0.id) }
            )
            // 发行的按分类分排:分类先算好再交出去,货架不先全摆在「专辑」里再挪。
            await ReleaseCategoryCatalog.shared.prefetch(partition.releases, library: library)
            return ArtistCatalogShelves(key: key, release: partition.releases, appearsOn: partition.appearsOn)
        } catch {
            plog("🎤 artist shelves from the catalog failed: \(error)")
            return nil
        }
    }
}

struct ArtistAllSongsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    #if os(iOS)
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    #endif

    let artist: Artist
    var initialLocationID: String? = nil
    @State private var songLocation = SongListLocation()
    @State private var selection = SongSelectionModel()
    @State private var songsCache = ArtistSongsCache()

    private var songs: [Song] {
        songsCache.songs(
            for: ArtistSongsCache.key(artistID: artist.id, library: library)
            // crash-pattern: allow legacy-library-api 按艺人取歌的门面,模型不在内存里时由曲库目录作答(同原来,只是搬了文件)
        ) { library.songs(forArtist: artist.id) }
    }
    private var playableSongs: [Song] { songs.filteredPlayable() }

    var body: some View {
        Group {
            if songs.isEmpty {
                EmptyStateView(
                    titleKey: "no_songs",
                    descriptionKey: "no_songs_desc",
                    systemImage: "music.note"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            SongRowView(
                                song: song,
                                isPlaying: player.currentSong?.id == song.id,
                                trackNumber: index + 1,
                                largestTrackNumber: songs.count,
                                selection: selection,
                                context: SongRowView.context(
                                    for: song,
                                    sourcesStore: sourcesStore,
                                    backfill: backfill
                                )
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { playSong(song) }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("artistSong.\(song.id)")
                            .songLocationRow(song.id)
                            .songSelectable(
                                songID: song.id,
                                selection: selection,
                                orderedIDs: { songs.map(\.id) },
                                defaultAction: SongSelectableDefaultAction.macOnly { playSong(song) }
                            )

                            if index != songs.count - 1 {
                                Divider()
                                    .padding(.leading, 66)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    #if os(macOS)
                    .background(PMColor.bgElev, in: RoundedRectangle(cornerRadius: 8))
                    .padding(24)
                    #endif
                }
            }
        }
        .songLocationReader(songLocation, revision: songs.map(\.id))
        .onAppear {
            if let initialLocationID { songLocation.locate(initialLocationID) }
        }
        .onDisappear { songLocation.cancel() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                LocateCurrentSongButton(
                    isEditing: selection.isActive,
                    contains: { id in songs.contains { $0.id == id } }
                ) { songID, _ in songLocation.locate(songID) }
            }
        }
        .navigationTitle("all_songs_section")
        .toolbarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbar {
            SongSelectionToolbarItems(
                selection: selection,
                orderedIDs: { songs.map(\.id) },
                titled: verticalBarEdge != nil
            )
        }
        .minimalNavigationDetail()
        .librarySearchContext {
            let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return LibrarySearchScope(
                title: name.isEmpty ? String(localized: "unknown_artist") : name,
                songIDs: Set(songs.map(\.id)),
                kind: .artist
            )
        }
        #endif
        .songBatchActions(
            selection: selection,
            orderedIDs: { songs.map(\.id) },
            resolve: { library.song(id: $0) }
        )
    }

    private func playSong(_ song: Song) {
        guard let index = playableSongs.firstIndex(where: { $0.id == song.id }) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queue: playableSongs, startingAt: index) }
    }
}
