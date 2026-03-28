import SwiftUI
import PrimuseKit

struct AlbumCardView: View {
    let album: Album
    var coverData: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverArtView(data: coverData, size: .infinity, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)

            Text(album.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)

            Text(album.artistName ?? String(localized: "unknown_artist"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
