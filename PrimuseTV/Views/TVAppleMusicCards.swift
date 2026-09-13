#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Apple Music 目录条目的网络封面。曲库内容有本地封面缓存,目录内容没有,
/// 统一走这一层,免得每处都写一遍占位与圆角。
struct TVAppleMusicArtwork: View {
    let url: URL?
    let glyph: String
    var side: CGFloat
    var radius: CGFloat
    var isCircular = false

    var body: some View {
        shape
            .fill(TVColor.surface)
            .overlay {
                if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
    }

    private var placeholder: some View {
        Image(systemName: glyph)
            .font(.system(size: side * 0.3))
            .foregroundStyle(TVColor.textGhost)
    }

    private var shape: AnyShape {
        isCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 专辑磁贴。选中即整张入队播放,不另开详情页 —— 电视上多一层导航只是多按一次。
struct TVAppleMusicTileCard: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let glyph: String
    var width: CGFloat = 200
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.06, lift: 6, action: action) { focused in
            VStack(alignment: .leading, spacing: 10) {
                TVAppleMusicArtwork(url: artworkURL, glyph: glyph, side: width, radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).tvFont(.eyebrow, weight: .semibold)
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(subtitle).tvFont(.meta)
                        .foregroundStyle(focused ? TVColor.textMuted : TVColor.textFaint)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .accessibilityLabel(Text("\(title) · \(subtitle)"))
    }
}

/// 艺术家圆形卡。
struct TVAppleMusicCircleCard: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let glyph: String
    var side: CGFloat = 140
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: side / 2, scale: 1.08, lift: 6, action: action) { focused in
            VStack(spacing: 10) {
                TVAppleMusicArtwork(
                    url: artworkURL, glyph: glyph, side: side, radius: side / 2, isCircular: true
                )
                VStack(spacing: 2) {
                    Text(title).tvFont(.caption, weight: .semibold)
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(subtitle).tvFont(.meta)
                        .foregroundStyle(focused ? TVColor.textMuted : TVColor.textFaint)
                        .lineLimit(1)
                }
                .frame(width: side + 24)
            }
        }
        .accessibilityLabel(Text("\(title) · \(subtitle)"))
    }
}
#endif
