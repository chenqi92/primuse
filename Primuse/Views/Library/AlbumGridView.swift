import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    let albums: [Album]
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]

    var body: some View {
        if albums.isEmpty {
            ContentUnavailableView(
                "no_albums",
                systemImage: "square.stack",
                description: Text("no_albums_desc")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(albums) { album in
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
