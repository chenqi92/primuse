import SwiftUI
import PrimuseKit

struct AlbumCardView: View {
    let album: Album
    var showsSongCount = false
    var isIntelligentRecommendation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtworkView(album: album, cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .searchRecommendationOverlay(isRecommended: isIntelligentRecommendation)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(album.artistName ?? String(localized: "unknown_artist"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if showsSongCount {
                    Text("\(album.songCount) \(String(localized: "songs_count"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
