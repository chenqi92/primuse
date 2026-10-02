import SwiftUI
import PrimuseKit

/// AI 语义搜索补充出来的一张专辑:封面、专辑名、艺术家、为什么会搜到它;
/// 下面两个动作:整张播放(按碟号、曲目号排队)和进入专辑。iPhone、iPad、Mac 共用。
struct SemanticAlbumResultCard: View {
    let album: Album
    /// 命中的那个扩展词,卡片上写成「与“……”相关」。
    let relatedConcept: String
    var width: CGFloat = 150
    let canPlay: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: album) {
                VStack(alignment: .leading, spacing: 4) {
                    AlbumArtworkView(album: album, cornerRadius: 10)
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.bottom, 2)
                    Text(album.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(album.artistName ?? String(localized: "unknown_artist"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !relatedConcept.isEmpty {
                        Label {
                            Text(verbatim: String(
                                format: String(localized: "search_ai_reason_format"),
                                relatedConcept
                            ))
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #if os(iOS)
            .mediaZoomSource(.album, id: album.id)
            #else
            .pmHoverLift()
            #endif

            HStack(spacing: 6) {
                Button(action: onPlay) {
                    Label("album_play_whole", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(!canPlay)

                NavigationLink(value: album) {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 18)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel(Text("go_to_album"))
                .help(Text("go_to_album"))
            }
            .font(.caption.weight(.semibold))
            .controlSize(.small)
        }
        .frame(width: width, alignment: .leading)
    }
}
