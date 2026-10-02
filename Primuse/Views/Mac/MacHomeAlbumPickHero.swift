#if os(macOS)
import SwiftUI
import PrimuseKit

/// Mac 首页主卡的情景推荐版:原来的「叙事文案 + 封面拼贴」换成此刻情景下推荐的一整张
/// 专辑 —— 单张封面、情景标题(通勤路上 / 周末午后 / 睡前…)、推荐理由,整张播放、
/// 换一张,以及原有的随机播放整个曲库。推荐与 iPhone 首页、电视首页同源
/// (`AlbumRecommendationService`)。
struct MacHomeAlbumPickHero: View {
    let pick: AlbumRecommendation
    let album: Album
    let moment: ListeningMoment
    let canShowAnother: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAnother: () -> Void
    let onDismiss: () -> Void
    let onShuffleLibrary: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                .fill(PMColor.bgElev)

            AmbientBackdrop(
                accent: PMColor.brand,
                darkAccent: PMColor.brand.opacity(0.55),
                strength: 0.72
            )
            .allowsHitTesting(false)

            HStack(alignment: .center, spacing: 36) {
                NavigationLink(value: album) {
                    AlbumArtworkView(album: album, size: 240, cornerRadius: PMRadius.l)
                        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                }
                .buttonStyle(.plain)
                .help(Text("go_to_album"))
                .contextMenu { menu }

                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: moment.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))

                    NavigationLink(value: album) {
                        Text(verbatim: pick.title)
                            .font(.system(size: 36, weight: .bold))
                            .tracking(-0.7)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)

                    Text(verbatim: [pick.artistName, pick.detailLine].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)

                    Label(pick.reason.text, systemImage: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)

                    HStack(spacing: PMSpace.s10) {
                        Button(action: onPlay) {
                            Label("album_pick_play", systemImage: "play.fill")
                                .font(.system(size: 13.5, weight: .semibold))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 11)
                                .background(PMColor.brand, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .shadow(color: PMColor.brand.opacity(0.45), radius: 10, y: 4)
                        .accessibilityIdentifier("macHome.albumPick.play")

                        glassButton("album_pick_another", symbol: "arrow.triangle.2.circlepath", action: onAnother)
                            .disabled(!canShowAnother)
                            .accessibilityIdentifier("macHome.albumPick.another")

                        glassButton("shuffle_all", symbol: "shuffle", action: onShuffleLibrary)
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PMSpace.xxl)
            .padding(.vertical, PMSpace.l24)
        }
        .frame(height: 296)
        .clipShape(RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
    }

    private func glassButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13.5, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.18), in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 0.5) }
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var menu: some View {
        Button(action: onPlay) {
            Label("album_pick_play", systemImage: "play.fill")
        }
        Button(action: onPlayNext) {
            Label("album_pick_play_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button(action: onAddToQueue) {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Divider()
        Button(action: onDismiss) {
            Label("album_pick_dismiss", systemImage: "hand.thumbsdown")
        }
    }
}
#endif
