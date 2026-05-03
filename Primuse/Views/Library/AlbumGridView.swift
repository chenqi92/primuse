import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var searchText: String = ""
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]

    private var filteredAlbums: [Album] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return library.visibleAlbums }
        return library.visibleAlbums.filter {
            $0.title.localizedCaseInsensitiveContains(q)
            || ($0.artistName?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        if library.visibleAlbums.isEmpty {
            ContentUnavailableView(
                "no_albums",
                systemImage: "square.stack",
                description: Text("no_albums_desc")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .searchable(text: $searchText,
                        placement: .toolbar,
                        prompt: Text("search_albums_prompt"))
        }
    }
}
