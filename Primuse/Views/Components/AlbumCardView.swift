import SwiftUI
import PrimuseKit

struct AlbumCardView: View {
    let album: Album
    var showsSongCount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(album: album, cornerRadius: 12)
                .aspectRatio(1, contentMode: .fit)

            // 2.0 的封面卡片:标题加重一档,下面一行是艺术家,封面稍大的圆角。
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(album.artistName ?? String(localized: "unknown_artist"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if showsSongCount {
                    Text("\(album.songCount) \(String(localized: "songs_count"))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
