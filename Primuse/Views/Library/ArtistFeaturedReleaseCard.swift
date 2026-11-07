import SwiftUI
import PrimuseKit

#if os(iOS)
/// 艺人页里曲库已有的最新发行。选择与排序由页面复用发行货架的缓存，
/// 这里不另查目录，也不把入库时间当作发行日期。
@MainActor
struct ArtistFeaturedReleaseCard: View {
    let album: Album

    @Environment(\.libraryDetailTint) private var tint
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        albumLink(stacked: dynamicTypeSize.isAccessibilitySize)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .libraryDetailSection(tint: tint, cornerRadius: 24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("artistFeaturedRelease")
    }

    private func albumLink(stacked: Bool) -> some View {
        NavigationLink(value: album) {
            Group {
                if stacked {
                    VStack(alignment: .leading, spacing: 12) {
                        artwork
                        metadata(expanded: true)
                    }
                } else {
                    HStack(spacing: 12) {
                        artwork
                        metadata(expanded: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityIdentifier("artistFeaturedRelease.open")
    }

    private var artwork: some View {
        AlbumArtworkView(album: album, size: 96, cornerRadius: 12)
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
    }

    private func metadata(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // Album 目前只有年份；不补造月日，无有效年份时直接省略。
            if let year = album.year, (1...9999).contains(year) {
                Text(verbatim: String(year))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            Text(verbatim: album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: "\(max(0, album.songCount)) \(String(localized: "songs_count"))")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
#endif
