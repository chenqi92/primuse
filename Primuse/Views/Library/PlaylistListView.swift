import SwiftUI
import PrimuseKit

struct PlaylistListView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    private var playlists: [Playlist] {
        library.playlists
    }

    var body: some View {
        Group {
            if playlists.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "no_playlists",
                        systemImage: "music.note.list",
                        description: Text("no_playlists_desc")
                    )

                    Button("new_playlist") {
                        showNewPlaylist = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: playlist) {
                            HStack(spacing: 12) {
                                StoredCoverArtView(fileName: playlist.coverArtPath, size: 48, cornerRadius: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.body)

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
                    }
                    .onDelete(perform: deletePlaylists)
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNewPlaylist = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("new_playlist", isPresented: $showNewPlaylist) {
            TextField("playlist_name", text: $newPlaylistName)
            Button("cancel", role: .cancel) {
                newPlaylistName = ""
            }
            Button("create") {
                createPlaylist()
            }
        }
    }

    private func createPlaylist() {
        let trimmedName = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return }
        _ = library.createPlaylist(name: trimmedName)
        newPlaylistName = ""
    }

    private func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            library.deletePlaylist(id: playlists[index].id)
        }
    }
}
