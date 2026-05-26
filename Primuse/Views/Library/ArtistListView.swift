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
                macArtistsContent
            }
        }
    }

    private var macArtistsContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "library_title",
                    title: "tab_artists",
                    subtitle: "\(artists.count) \(String(localized: "artists_count"))",
                    iconSystemName: "music.mic"
                )

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: PMSpace.m, alignment: .top)],
                    alignment: .leading,
                    spacing: PMSpace.m
                ) {
                    ForEach(filteredArtists) { artist in
                        NavigationLink(value: artist) {
                            macArtistCard(artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.l)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    private func macArtistCard(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            CachedArtworkView(artistID: artist.id, artistName: artist.name,
                              size: 48, cornerRadius: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text("\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.horizontal, PMSpace.m)
        .padding(.vertical, 10)
        .pmCard(cornerRadius: PMRadius.m)
    }
    #endif
}
