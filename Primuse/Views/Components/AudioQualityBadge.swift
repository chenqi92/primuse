import SwiftUI
import PrimuseKit

/// 高码率 / DSD 标签 — 当 Song.audioQuality 不是 .standard 时显示。
/// 用在 NowPlaying 主标题旁、SongRow 等位置。
struct AudioQualityBadge: View {
    let quality: AudioQuality
    var compact: Bool = false

    var body: some View {
        Text(quality.displayName)
            .font(compact ? .caption2 : .caption)
            .fontWeight(.semibold)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(badgeColor, lineWidth: 1)
            )
            .foregroundStyle(badgeColor)
            .accessibilityLabel(Text(quality.displayName))
    }

    private var badgeColor: Color {
        switch quality {
        case .dsd: return .yellow
        case .hiRes: return .orange
        case .lossless: return .cyan
        case .standard: return .secondary
        }
    }
}
