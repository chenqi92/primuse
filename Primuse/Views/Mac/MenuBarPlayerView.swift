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
    @AppStorage("menuBarShowTitle") private var menuBarShowTitle: Bool = true

    var body: some View {
        VStack(spacing: 14) {
            artwork
            metadata
            scrubber
            transport
            volume

            Divider()

            Button {
                PrimuseAppDelegate.shared?.toggleDesktopLyrics()
            } label: {
                Label(desktopLyricsVisible ? "hide_desktop_lyrics" : "show_desktop_lyrics",
                      systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            // 桌面歌词锁定/解锁(穿透鼠标)。锁定后 panel 不接收事件,
            // 解锁的唯一入口就在这里。
            if desktopLyricsVisible {
                Toggle(isOn: $desktopLyricsLocked) {
                    Label(desktopLyricsLocked ? "desktop_lyrics_locked" : "desktop_lyrics_unlocked",
                          systemImage: desktopLyricsLocked ? "lock.fill" : "lock.open")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
            }

            Toggle(isOn: $menuBarShowTitle) {
                Label("menu_bar_show_title", systemImage: "textformat")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)

            HStack {
                Button {
                    onOpenMainWindow()
                } label: {
                    Label("open_main_window", systemImage: "macwindow")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("quit_app").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320)
    }

    private var artwork: some View {
        Group {
            if player.currentSong != nil {
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: 140,
                    cornerRadius: 10,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath
                )
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 140, height: 140)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private var metadata: some View {
        VStack(spacing: 2) {
            Text(player.currentSong?.title ?? "—")
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(1)
            Text(player.currentSong?.artistName ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.01)
            )
            .controlSize(.mini)
            .tint(.secondary)

            HStack {
                Text(formatTime(player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Image(systemName: "play.fill").opacity(0)
                    if player.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)

            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
    }

    private var volume: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(engine.volume) },
                    set: { engine.volume = Float($0) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .tint(.secondary)
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
