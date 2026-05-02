#if os(macOS)
import SwiftUI
import PrimuseKit

/// Full-width bottom transport bar shown across the entire window. Modeled
/// after Apple Music's "now playing" strip — artwork + title on the left,
/// transport in the middle, scrubber spanning the available width, volume
/// + queue on the right.
struct MacBottomBar: View {
    var isExpanded: Bool = false
    var onToggleNowPlaying: () -> Void = {}

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                nowPlayingInfo
                    .frame(width: 280, alignment: .leading)

                transport
                    .frame(maxWidth: .infinity)

                rightControls
                    .frame(width: 200, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: - Sections

    private var nowPlayingInfo: some View {
        HStack(spacing: 10) {
            if player.currentSong != nil {
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: 44,
                    cornerRadius: 6,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath
                )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.tertiary)
                    }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? "")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(player.currentSong?.artistName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleNowPlaying() }
    }

    private var transport: some View {
        VStack(spacing: 4) {
            HStack(spacing: 18) {
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .medium))

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
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(player.isLoading)

                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 16, weight: .medium))
            }

            HStack(spacing: 8) {
                Text(formatTime(player.currentTime))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                ScrubberSlider(
                    value: player.currentTime,
                    bounds: 0...max(player.duration, 0.01),
                    onScrub: { newValue in player.seek(to: newValue) }
                )
                .tint(.secondary)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                Text(formatTime(player.duration))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
            }
        }
    }

    private var rightControls: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Slider(
                value: Binding(
                    get: { Double(engine.volume) },
                    set: { engine.volume = Float($0) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .tint(.secondary)
            .frame(width: 110)
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
                .font(.caption)

            Button { onToggleNowPlaying() } label: {
                Image(systemName: isExpanded
                      ? "chevron.down"
                      : "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text(isExpanded ? "close" : "now_playing"))
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Continuous slider that only commits the new value when the user releases
/// — without this, AVAudioEngine seeks every frame and chokes on big files.
private struct ScrubberSlider: View {
    let value: Double
    let bounds: ClosedRange<Double>
    var onScrub: (Double) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        Slider(
            value: Binding(
                get: { isDragging ? dragValue : value },
                set: { dragValue = $0 }
            ),
            in: bounds,
            onEditingChanged: { editing in
                if editing {
                    isDragging = true
                    dragValue = value
                } else {
                    isDragging = false
                    onScrub(dragValue)
                }
            }
        )
    }
}
#endif
