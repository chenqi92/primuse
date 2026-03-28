import SwiftUI
import PrimuseKit

struct PlaylistListView: View {
    let playlists: [Playlist]
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        if playlists.isEmpty {
            ContentUnavailableView(
                "no_playlists",
                systemImage: "music.note.list",
                description: Text("no_playlists_desc")
            )
        } else {
            List(playlists) { playlist in
                NavigationLink(value: playlist) {
                    HStack(spacing: 12) {
                        CoverArtView(data: nil, size: 48, cornerRadius: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name)
                                .font(.body)

                            Text(playlist.updatedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
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
                Button("cancel", role: .cancel) {}
                Button("create") {
                    createPlaylist()
                }
            }
        }
    }

    private func createPlaylist() {
        guard !newPlaylistName.isEmpty else { return }
        // Will be connected to LibraryService
        newPlaylistName = ""
    }
}
