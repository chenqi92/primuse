#if os(iOS)
import PrimuseKit
import SwiftUI

/// 冷启动首帧同步缓存上次播放会话文件是否存在，避免每次视图求值重复访问文件系统。
@MainActor
final class LaunchPersistedSessionCache {
    private var cachedURL: URL?
    private var cachedExists = false

    func hasPersistedSession(at url: URL) -> Bool {
        if cachedURL == url { return cachedExists }
        cachedURL = url
        cachedExists = TabBarStartupPolicy.hasPersistedSession(at: url)
        return cachedExists
    }
}

@available(iOS 26.0, *)
struct NowPlayingAccessory: View {
    var onTap: () -> Void
    var accessoryState: TabBarStartupPolicy.SystemBottomAccessoryState = .live
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }
    private var isLive: Bool { accessoryState == .live }

    var body: some View {
        Group {
            if isLive {
                HStack(spacing: 0) {
                    MiniPlayerSwipeContent(
                        onTap: onTap,
                        artworkSize: isInline ? 32 : 30,
                        artworkCornerRadius: 6,
                        artworkTrailingSpacing: isInline ? 10 : 8,
                        titleFont: isInline ? .caption : .subheadline
                    )

                    MiniPlayerTransportControls(
                        isInline: isInline,
                        showsNextButton: !isInline,
                        regularIconSize: 18
                    )
                }
            } else {
                restoringPlaceholder
            }
        }
        .padding(.horizontal, isInline ? 12 : 16)
        .padding(.vertical, isInline ? 2 : 4)
        .background(NowPlayingCapsuleProbe())
        .allowsHitTesting(accessoryState.isInteractive)
        .accessibilityHidden(!isLive)
        .pmAnimation(.contentAppear, value: isLive)
    }

    /// 播放会话恢复中的等高占位，确保少于 4 个标签时冷启动首帧即稳定于最终标签栏宽度。
    private var restoringPlaceholder: some View {
        let artworkSize: CGFloat = isInline ? 32 : 30
        return HStack(spacing: isInline ? 10 : 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .frame(width: artworkSize, height: artworkSize)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.6))
                }

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.16))
                .frame(width: isInline ? 88 : 132, height: 12)

            Spacer(minLength: 0)

            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.35))
                .frame(width: 36, height: 36)
        }
        .frame(minHeight: 44)
    }
}
#endif
