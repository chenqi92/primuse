import SwiftUI
import PrimuseKit

struct AlbumCardView: View {
    let album: Album
    var showsSongCount = false
    @Environment(\.skin) private var skin

    var body: some View {
        // 大一号的卡片(组件级 `SkinComponentStyle.Card.tile`):标题加重一档,下面一行是艺术家,封面稍大的圆角。
        let tile = skin.usesTileCards
        VStack(alignment: .leading, spacing: tile ? 8 : 6) {
            AlbumArtworkView(album: album, cornerRadius: tile ? 12 : 10)
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(tile ? .subheadline : .caption)
                    .fontWeight(tile ? .semibold : .medium)
                    .lineLimit(1)

                Text(album.artistName ?? String(localized: "unknown_artist"))
                    .font(tile ? .caption : .caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if showsSongCount {
                    Text("\(album.songCount) \(String(localized: "songs_count"))")
                        .font(tile ? .caption.monospacedDigit() : .caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
