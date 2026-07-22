#if os(macOS)
import SwiftUI
import PrimuseKit

/// Compact "what's playing" UI shown inside the menu bar popover. Covers
/// the basics — artwork, title, transport, volume — plus a button to
/// foreground the main window.
struct MenuBarPlayerView: View {
    var onOpenMainWindow: () -> Void = {}
    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine

    @AppStorage("desktopLyricsLocked") private var desktopLyricsLocked: Bool = false
    @AppStorage("desktopLyricsVisible") private var desktopLyricsVisible: Bool = false
    @AppStorage("miniPlayerVisible") private var miniPlayerVisible: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            coverRow
            scrubber
            transport
            volume

            Divider().background(PMColor.divider).padding(.vertical, 2)

            menuRow(icon: "text.bubble",
                    title: desktopLyricsVisible ? "hide_desktop_lyrics" : "show_desktop_lyrics",
                    shortcut: "⌘L",
                    active: desktopLyricsVisible,
                    showsCheckmark: desktopLyricsVisible) {
                PrimuseAppDelegate.shared?.toggleDesktopLyrics()
            }

            menuRow(icon: desktopLyricsLocked ? "lock.fill" : "lock",
                    title: "lock_desktop_lyrics",
                    shortcut: "⌘⇧L",
                    active: desktopLyricsLocked) {
                desktopLyricsLocked.toggle()
            }

            menuRow(icon: "rectangle.inset.filled.on.rectangle",
                    title: "mini_player",
                    active: miniPlayerVisible,
                    showsCheckmark: miniPlayerVisible) {
                PrimuseAppDelegate.shared?.toggleMiniPlayer()
            }

            menuRow(icon: "arrow.up.left.and.arrow.down.right", title: "full_screen_player") {
                PrimuseAppDelegate.shared?.toggleFullScreenPlayer()
            }

            Divider().background(PMColor.divider).padding(.vertical, 2)

            menuRow(icon: "macwindow", title: "open_main_window", shortcut: "⌘0") {
                onOpenMainWindow()
            }
            menuRow(icon: "gearshape", title: "settings_title", shortcut: "⌘,") {
                SettingsWindowController.shared.show()
            }
            menuRow(icon: "rectangle.portrait.and.arrow.right",
                    title: "quit_app",
                    shortcut: "⌘Q",
                    accent: PMColor.bad) {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background {
            // 设计稿要求 popover 用 rounded 14pt + 玻璃面板。
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PMColor.bg.opacity(0.6))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    // MARK: - Cover row

    private var coverRow: some View {
        HStack(alignment: .top, spacing: 10) {
            artwork.frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? "—")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(player.currentSong?.artistName ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                if let album = player.currentSong?.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var artwork: some View {
        Group {
            if let song = player.currentSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 64, cornerRadius: 8,
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(PMColor.card)
                    .frame(width: 64, height: 64)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 22))
                            .foregroundStyle(PMColor.textFaint)
                    }
            }
        }
        .shadow(color: .black.opacity(0.20), radius: 6, y: 3)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        MenuBarPlayerProgress()
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Spacer()
            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(PMColor.brand).frame(width: 42, height: 42)
                    if player.isLoading {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)

            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Volume

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeSymbol)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 14)
            Slider(
                value: Binding(
                    get: { Double(engine.volume) },
                    set: { engine.volume = Float($0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(PMColor.text.opacity(0.7))
            Text(String(format: "%d", Double(engine.volume * 100).finiteInt()))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 24, alignment: .trailing)
        }
    }

    private var volumeSymbol: String {
        let v = engine.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.wave.1.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Menu rows

    private func menuRow(icon: String, title: LocalizedStringKey,
                         shortcut: String? = nil,
                         active: Bool = false,
                         showsCheckmark: Bool = false,
                         accent: Color = PMColor.brand,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(active ? accent : PMColor.textMuted)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5, weight: active ? .medium : .regular))
                    .foregroundStyle(PMColor.text)
                Spacer()
                if showsCheckmark {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? PMColor.rowHover : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

private struct MenuBarPlayerProgress: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        VStack(spacing: 4) {
            MenuBarScrubberLine(
                value: player.currentTime,
                total: player.duration,
                tint: PMColor.brand
            ) { player.seek(to: $0) }

            HStack {
                Text(formatTime(player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(PMColor.textFaint)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = time.finiteInt()
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Scrubber slider only commits seek on release, otherwise AVAudioEngine
/// chokes on the per-frame seeks during a drag.
private struct MenuBarScrubberLine: View {
    let value: Double
    let total: Double
    var tint: Color = .secondary
    var onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        Slider(
            value: Binding(
                get: { isDragging ? dragValue : value },
                set: { dragValue = $0 }
            ),
            in: 0...max(total, 0.01),
            onEditingChanged: { editing in
                if editing { isDragging = true; dragValue = value }
                else { isDragging = false; onSeek(dragValue) }
            }
        )
        .controlSize(.mini)
        .tint(tint)
    }
}
#endif
