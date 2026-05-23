import SwiftUI
import PrimuseKit

struct PlaylistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let playlist: Playlist

    @State private var exportShareItem: ExportShareItem?
    @State private var exportError: String?

    private var currentPlaylist: Playlist? {
        library.playlist(id: playlist.id)
    }

    private var songs: [Song] {
        library.songs(forPlaylist: playlist.id)
    }

    /// 给 .sheet 用 — URL 不是 Identifiable, 包一层。
    struct ExportShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Playlist header
                VStack(spacing: 8) {
                    StoredCoverArtView(
                        fileName: currentPlaylist?.coverArtPath,
                        size: 180,
                        cornerRadius: 14
                    )

                    Text(currentPlaylist?.name ?? playlist.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(songs.count) \(String(localized: "songs_count"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Action buttons ── 主按钮"播放全部"占大头, 旁边两个紧凑图标按钮。
                // 三按钮等分时中文 label 在 iPhone 上挤换行 / 截断, 这套 Apple Music
                // 风格的 1+2 布局更稳。
                HStack(spacing: 10) {
                    Button {
                        playAll()
                    } label: {
                        Label("play_all", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        player.shuffleEnabled = true
                        playAll()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel(Text("shuffle"))

                    Button {
                        sourceManager.downloadForOffline(songs: songs)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(songs.filteredPlayable().isEmpty)
                    .accessibilityLabel(Text("offline_download"))
                }
                .padding(.horizontal)

                // Songs
                LazyVStack(spacing: 0) {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            showsActions: false,
                            context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .onTapGesture { playSong(song) }
                        .contextMenu {
                            // Apple Music 资料库镜像里的 Apple Music 歌不能移除 ──
                            // 我们没法 push 回 Apple Music 删收藏, 移除后下次 sync
                            // 又自动回来, 视觉上会变成"删了又出现"的 bug。其它源
                            // 的歌 (用户额外手动加进来等情况) 仍能正常移除。
                            if !isAppleMusicMirrorEntry(song: song) {
                                Button(role: .destructive) {
                                    library.remove(songID: song.id, fromPlaylist: playlist.id)
                                } label: {
                                    Label("remove_from_playlist", systemImage: "trash")
                                }
                            }
                        }

                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        export(format: .m3u8)
                    } label: {
                        Label("playlist_export_m3u8", systemImage: "doc.text")
                    }
                    Button {
                        export(format: .json)
                    } label: {
                        Label("playlist_export_json", systemImage: "doc.badge.gearshape")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(songs.isEmpty)
            }
        }
        .sheet(item: $exportShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(String(localized: "playlist_export_failed_title"),
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    /// 这个 song 是不是 Apple Music 镜像歌单里的 Apple Music 歌 ── 同时
     /// 满足 (playlist 是任意 AM 镜像) 且 (song 是 Apple Music 来源) 才算,
     /// 用户自己手动 add 进去的其它源歌仍可正常移除。
     private func isAppleMusicMirrorEntry(song: Song) -> Bool {
         AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlist.id)
             && song.sourceID == AppleMusicLibraryService.systemSourceID
     }

     private func export(format: PlaylistExporter.Format) {
        do {
            let target = currentPlaylist ?? playlist
            let url = try PlaylistExporter.export(
                playlist: target,
                songs: songs,
                format: format,
                sourcesStore: sourcesStore
            )
            exportShareItem = ExportShareItem(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func playAll() {
        let queue = songs.filteredPlayable()
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }
}
