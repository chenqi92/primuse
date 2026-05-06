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
                ContentUnavailableView {
                    Label("no_playlists", systemImage: "music.note.list")
                } description: {
                    Text("no_playlists_desc")
                } actions: {
                    Button("new_playlist") { showNewPlaylist = true }
                        .buttonStyle(.borderedProminent)
                }
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
                            }
                            .onDelete(perform: deletePlaylists)
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
        HStack(spacing: 12) {
            StoredCoverArtView(fileName: playlist.coverArtPath, size: 48, cornerRadius: 8)

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

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            library.deletePlaylist(id: playlists[index].id)
        }
    }

    private func deleteSmartPlaylists(at offsets: IndexSet) {
        for index in offsets {
            library.deleteSmartPlaylist(id: smartPlaylists[index].id)
        }
    }
}
