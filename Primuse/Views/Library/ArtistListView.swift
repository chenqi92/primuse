import SwiftUI
import PrimuseKit

struct ArtistListView: View {
    let artists: [Artist]

    var body: some View {
        if artists.isEmpty {
            ContentUnavailableView(
                "no_artists",
                systemImage: "music.mic",
                description: Text("no_artists_desc")
            )
        } else {
            List(artists) { artist in
                NavigationLink(value: artist) {
                    HStack(spacing: 12) {
                        CoverArtView(data: nil, size: 44, cornerRadius: 22)

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
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(artist: artist)
            }
        }
    }
}
