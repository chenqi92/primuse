import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    @Environment(MusicLibrary.self) private var library
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]

    var body: some View {
        if library.albums.isEmpty {
            ContentUnavailableView(
                "no_albums",
                systemImage: "square.stack",
                description: Text("no_albums_desc")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(library.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }
}
