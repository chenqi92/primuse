import PrimuseKit
import SwiftUI

/// 歌词切歌过渡修饰符：仅在切歌或解析落地时提供轻柔淡出 / 淡入，
/// 正常播放期间的逐行滚动、逐字高亮和手动浏览不触发额外重绘或闪烁。
struct NowPlayingLyricsTransition: ViewModifier {
    let songID: String?
    let loadedSongID: String?
    let hasLyrics: Bool
    let isResolving: Bool
    let isSceneActive: Bool
    let presentation: NowPlayingLyricsPresentation?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity: Double = 1
    @State private var isRevealed = true
    @State private var transitionTask: Task<Void, Never>?

    private var snapshot: TrackSwitchTransitionPolicy.LyricsTransitionSnapshot {
        TrackSwitchTransitionPolicy.LyricsTransitionSnapshot(
            songID: songID,
            loadedSongID: loadedSongID,
            hasLyrics: hasLyrics,
            isResolving: isResolving
        )
    }

    func body(content: Content) -> some View {
        let isVisible = isSceneActive && (presentation?.isVisible ?? true)
        content
            .opacity(opacity)
            .offset(
                y: CGFloat(TrackSwitchTransitionPolicy.lyricsEntranceOffset(
                    isRevealed: isRevealed,
                    reduceMotion: reduceMotion
                ))
            )
            .onChange(of: snapshot) { previous, current in
                handleTransition(from: previous, to: current, isVisible: isVisible)
            }
            .onChange(of: isVisible) { _, visible in
                if !visible {
                    cancelAndRestoreImmediately()
                }
            }
            .onDisappear {
                transitionTask?.cancel()
                transitionTask = nil
            }
    }

    private func handleTransition(
        from previous: TrackSwitchTransitionPolicy.LyricsTransitionSnapshot,
        to current: TrackSwitchTransitionPolicy.LyricsTransitionSnapshot,
        isVisible: Bool
    ) {
        let action = TrackSwitchTransitionPolicy.lyricsTransitionAction(
            from: previous,
            to: current,
            isVisible: isVisible
        )
        switch action {
        case .none:
            return
        case .fadeOutPendingTrack:
            transitionTask?.cancel()
            withAnimation(.easeOut(duration: TrackSwitchTransitionPolicy.lyricsFadeOutDuration)) {
                opacity = 0
                isRevealed = false
            }
            // 兜底恢复，防止异常状态下歌词长期停在透明态。
            transitionTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(900))
                } catch {
                    return
                }
                guard !Task.isCancelled, opacity < 1 else { return }
                let duration = TrackSwitchTransitionPolicy.lyricsFadeInDuration(reduceMotion: reduceMotion)
                withAnimation(.easeInOut(duration: duration)) {
                    opacity = 1
                    isRevealed = true
                }
            }
        case .fadeInTrack, .fadeInResolvedContent:
            transitionTask?.cancel()
            if opacity > 0.05 {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    opacity = 0
                    isRevealed = false
                }
            }
            let duration = TrackSwitchTransitionPolicy.lyricsFadeInDuration(reduceMotion: reduceMotion)
            transitionTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: duration)) {
                    opacity = 1
                    isRevealed = true
                }
            }
        }
    }

    private func cancelAndRestoreImmediately() {
        transitionTask?.cancel()
        transitionTask = nil
        guard opacity != 1 || !isRevealed else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            opacity = 1
            isRevealed = true
        }
    }
}

extension View {
    func nowPlayingLyricsTransition(
        songID: String?,
        loadedSongID: String?,
        hasLyrics: Bool,
        isResolving: Bool,
        isSceneActive: Bool,
        presentation: NowPlayingLyricsPresentation? = nil
    ) -> some View {
        modifier(NowPlayingLyricsTransition(
            songID: songID,
            loadedSongID: loadedSongID,
            hasLyrics: hasLyrics,
            isResolving: isResolving,
            isSceneActive: isSceneActive,
            presentation: presentation
        ))
    }
}
