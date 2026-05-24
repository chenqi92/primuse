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
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    @ViewBuilder
    private var iosBody: some View {
        if artists.isEmpty {
            EmptyStateView(
                titleKey: "no_artists",
                descriptionKey: "no_artists_desc",
                systemImage: "music.mic"
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

    #if os(macOS)
    @ViewBuilder
    private var macBody: some View {
        Group {
            if artists.isEmpty {
                ContentUnavailableView(
                    "no_artists",
                    systemImage: "music.mic",
                    description: Text("no_artists_desc")
                )
            } else if filteredArtists.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12, alignment: .top)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(filteredArtists) { artist in
                            NavigationLink(value: artist) {
                                artistCard(artist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 112)
                }
            }
        }
        .searchable(text: $searchText,
                    placement: .toolbar,
                    prompt: Text("search_artists_prompt"))
    }

    private func artistCard(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            CachedArtworkView(artistID: artist.id, artistName: artist.name,
                              size: 54, cornerRadius: 27)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.headline)
                    .lineLimit(1)

                Text("\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
    #endif
}
