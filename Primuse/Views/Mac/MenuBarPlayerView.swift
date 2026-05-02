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

    var body: some View {
        VStack(spacing: 14) {
            artwork
            metadata
            scrubber
            transport
            volume

            Divider()

            Button {
                (NSApp.delegate as? PrimuseAppDelegate)?.toggleDesktopLyrics()
            } label: {
                Label("show_desktop_lyrics", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
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
