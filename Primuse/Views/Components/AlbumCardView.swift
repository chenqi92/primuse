import SwiftUI
import PrimuseKit

struct AlbumCardView: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedArtworkView(albumID: album.id, albumTitle: album.title,
                              artistName: album.artistName, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(album.artistName ?? String(localized: "unknown_artist"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
