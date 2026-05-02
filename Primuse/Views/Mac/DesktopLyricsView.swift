#if os(macOS)
import SwiftUI
import PrimuseKit

/// Floating overlay that highlights the active lyric line with the line
/// after it as a smaller hint. Fits inside a borderless transparent NSPanel
/// pinned to the screen — see `DesktopLyricsWindowController`.
struct DesktopLyricsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0

    var body: some View {
        VStack(spacing: 6) {
            Text(activeLine ?? player.currentSong?.title ?? "")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let next = nextLine {
                Text(next)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(minWidth: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, new in updateIndex(time: new) }
    }

    private var activeLine: String? {
        guard !lyrics.isEmpty, currentIndex < lyrics.count else { return nil }
        return lyrics[currentIndex].text
    }

    private var nextLine: String? {
        let next = currentIndex + 1
        guard !lyrics.isEmpty, next < lyrics.count else { return nil }
        return lyrics[next].text
    }

    private func reloadLyrics() async {
        guard let song = player.currentSong else { lyrics = []; currentIndex = 0; return }
        let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        lyrics = loaded
        currentIndex = 0
        updateIndex(time: player.currentTime)
    }

    private func updateIndex(time: TimeInterval) {
        guard !lyrics.isEmpty else { return }
        for i in (0..<lyrics.count).reversed() where time >= lyrics[i].timestamp {
            if currentIndex != i { currentIndex = i }
            return
        }
        currentIndex = 0
    }
}
#endif
