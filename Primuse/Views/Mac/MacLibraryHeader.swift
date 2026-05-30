#if os(macOS)
import SwiftUI
import PrimuseKit

/// 资料库三个主视图 (Songs / Albums / Artists) 共用的顶部 header — 大封面 +
/// AmbientBackdrop + 标题 + 副标题 + 主操作按钮 (播放/随机/更多)。
struct MacLibraryHeader: View {
    var eyebrow: LocalizedStringKey
    var title: String
    var subtitle: String
    var iconSystemName: String = "music.note"
    var coverSong: Song? = nil
    var accent: Color = PMColor.brand
    var darkAccent: Color = PMColor.brand.opacity(0.6)
    var onPlay: () -> Void = {}
    var onShuffle: () -> Void = {}
    var onMore: () -> Void = {}

    var body: some View {
        ZStack(alignment: .leading) {
            // 设计稿 LibraryHeader 用 strength 0.4 (subtle), 不像 Home Hero 那么饱和。
            // 这里 ambient 是配角, 不能盖过封面 + 标题。
            AmbientBackdrop(accent: accent, darkAccent: darkAccent, strength: 0.4)

            HStack(alignment: .bottom, spacing: 24) {
                coverArt
                    .frame(width: 160, height: 160)

                VStack(alignment: .leading, spacing: 8) {
                    Text(eyebrow)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.72))

                    Text(verbatim: title)
                        .font(.system(size: 44, weight: .bold))
                        .tracking(-0.8)
                        .lineSpacing(0)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(verbatim: subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Button(action: onPlay) {
                            HStack(spacing: 7) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12))
                                Text("play")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 32)
                            .background(PMColor.brand, in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .shadow(color: PMColor.brand.opacity(0.35), radius: 6, y: 2)

                        Button(action: onShuffle) {
                            HStack(spacing: 7) {
                                Image(systemName: "shuffle")
                                    .font(.system(size: 12))
                                Text("shuffle")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Color.white.opacity(0.16), in: .rect(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                        }
                        .buttonStyle(.plain)

                        Button(action: onMore) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.16), in: .rect(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .frame(height: 240)
        .clipped()
    }

    @ViewBuilder
    private var coverArt: some View {
        if let song = coverSong {
            CachedArtworkView(
                coverRef: song.coverArtFileName, songID: song.id,
                cornerRadius: PMRadius.l,
                sourceID: song.sourceID, filePath: song.filePath
            )
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        } else {
            RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay {
                    Image(systemName: iconSystemName)
                        .font(.system(size: 44))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }
}
#endif
