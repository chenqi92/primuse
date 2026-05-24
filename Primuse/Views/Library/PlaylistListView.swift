import SwiftUI
import PrimuseKit

struct PlaylistListView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var showSmartEditor = false

    private var playlists: [Playlist] { library.playlists }
    private var smartPlaylists: [SmartPlaylist] { library.smartPlaylists }

    var body: some View {
        Group {
            if playlists.isEmpty && smartPlaylists.isEmpty {
                EmptyStateView(
                    titleKey: "no_playlists",
                    descriptionKey: "no_playlists_desc",
                    systemImage: "music.note.list",
                    actionLabel: "new_playlist",
                    action: { showNewPlaylist = true }
                )
            } else {
                List {
                    if !smartPlaylists.isEmpty {
                        Section {
                            ForEach(smartPlaylists) { smart in
                                NavigationLink(value: smart) {
                                    smartPlaylistRow(smart)
                                }
                            }
                            .onDelete(perform: deleteSmartPlaylists)
                        } header: {
                            Text("smart_playlists_section")
                        }
                    }

                    if !playlists.isEmpty {
                        Section {
                            ForEach(playlists) { playlist in
                                NavigationLink(value: playlist) {
                                    playlistRow(playlist)
                                }
                                // 用 swipeActions 而不是 .onDelete ── 后者无法
                                // 按行条件禁用, 之前在 deletePlaylists 里 continue
                                // 跳过 system 歌单时 SwiftUI 已经做了消失动画
                                // 等下一帧数据刷回来又出现, 用户看到"删了又回来"。
                                // 改成 swipeActions 让 system 歌单根本没有 swipe
                                // 入口, 视觉一致。
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if !isSystemPlaylist(playlist.id) {
                                        Button(role: .destructive) {
                                            library.deletePlaylist(id: playlist.id)
                                        } label: {
                                            Label("delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        } header: {
                            // 只有一类时不显示 header, 跟原版视觉一致;
                            // 两类都有时才显示 "歌单" header 区分。
                            if !smartPlaylists.isEmpty {
                                Text("playlists_section")
                            } else {
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Label("new_playlist", systemImage: "music.note.list")
                    }
                    Button {
                        showSmartEditor = true
                    } label: {
                        Label("new_smart_playlist", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("new_playlist", isPresented: $showNewPlaylist) {
            TextField("playlist_name", text: $newPlaylistName)
            Button("cancel", role: .cancel) { newPlaylistName = "" }
            Button("create") { createPlaylist() }
        }
        .sheet(isPresented: $showSmartEditor) {
            SmartPlaylistEditorView(existing: nil)
        }
        .navigationDestination(for: SmartPlaylist.self) { smart in
            SmartPlaylistDetailView(smartPlaylistID: smart.id)
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        // 歌单封面始终用第一首歌的封面 ── 跟其他地方的 cover 渲染同源 (NAS /
        // URL / Apple Music ArtworkImage 都自动适配), 而且歌单重排后封面立刻
        // 跟着变。playlist.coverArtPath 字段保留 (replacePlaylistSongs 内部
        // 仍写它, 不破坏 schema / sync), 但 UI 渲染不再读, 避免老的 path 跟
        // 实际歌曲不同步。
        let firstSong = library.songs(forPlaylist: playlist.id).first
        return HStack(spacing: 12) {
            Group {
                if let song = firstSong {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: 48,
                        cornerRadius: 8,
                        sourceID: song.sourceID,
                        filePath: song.filePath
                    )
                } else {
                    StoredCoverArtView(fileName: nil, size: 48, cornerRadius: 8)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.body)
                HStack(spacing: 4) {
                    Text("\(library.songs(forPlaylist: playlist.id).count) \(String(localized: "songs_count"))")
                    Text("·")
                    Text(playlist.updatedAt, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func smartPlaylistRow(_ smart: SmartPlaylist) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [.purple.opacity(0.7), .blue.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(smart.name).font(.body)
                Text("\(smart.rules.count) \(String(localized: "rules_count"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func createPlaylist() {
        let trimmedName = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        _ = library.createPlaylist(name: trimmedName)
        newPlaylistName = ""
    }

    /// system 歌单 (Apple Music 镜像 / 「我喜欢」) 不允许从这里删:
    /// - AM 镜像下次 sync 自动重建, "删了又出现"
    /// - 「我喜欢」heart toggle 又会触发 ensure 重建
    /// 真想清空都得从内容侧操作 (取消 Apple Music 资料库同步 / 进歌单逐条移除)。
    private func isSystemPlaylist(_ playlistID: String) -> Bool {
        AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlistID)
            || playlistID == MusicLibrary.likedSongsPlaylistID
    }

    private func deleteSmartPlaylists(at offsets: IndexSet) {
        for index in offsets {
            library.deleteSmartPlaylist(id: smartPlaylists[index].id)
        }
    }
}
