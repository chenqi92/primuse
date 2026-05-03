import SwiftUI
import PrimuseKit

struct ArtistListView: View {
    let artists: [Artist]
    @State private var searchText: String = ""

    private var filteredArtists: [Artist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return artists }
        return artists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        if artists.isEmpty {
            ContentUnavailableView(
                "no_artists",
                systemImage: "music.mic",
                description: Text("no_artists_desc")
            )
        } else {
            List(filteredArtists) { artist in
                NavigationLink(value: artist) {
                    HStack(spacing: 12) {
                        CachedArtworkView(artistID: artist.id, artistName: artist.name,
                                          size: 44, cornerRadius: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(artist.name)
                                .font(.body)

                            Text("\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText,
                        placement: .toolbar,
                        prompt: Text("search_artists_prompt"))
        }
    }
}
