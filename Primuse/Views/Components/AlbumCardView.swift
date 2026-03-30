import SwiftUI
import PrimuseKit

struct AlbumCardView: View {
    @Environment(MusicLibrary.self) private var library
    let album: Album

    var body: some View {
        let firstSong = library.songs(forAlbum: album.id).first

        VStack(alignment: .leading, spacing: 6) {
            CachedArtworkView(
                coverRef: firstSong?.coverArtFileName,
                songID: firstSong?.id ?? album.id,
                cornerRadius: 10,
                sourceID: firstSong?.sourceID,
                filePath: firstSong?.filePath
            )
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
