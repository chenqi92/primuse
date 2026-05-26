#if os(macOS)
import SwiftUI
import PrimuseKit

/// 右侧 slide-in 队列面板,模仿 Apple Music 的「正在播放」队列。跟 sheet
/// 版 (`QueueView`) 唯一的区别是布局——侧栏紧贴 detail 右边,不劫持
/// 整个窗口。内部 list / 拖拽逻辑跟 sheet 版保持一致,源数据来自同一个
/// AudioPlayerService。
struct MacQueuePanel: View {
    var onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .background {
            ZStack {
                NSVisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
                Rectangle().fill(PMColor.sidebarGlass.opacity(0.6))
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(PMColor.divider).frame(width: 0.5).ignoresSafeArea(edges: .vertical)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if player.queue.isEmpty {
            ContentUnavailableView(
                "queue_empty",
                systemImage: "music.note.list",
                description: Text("queue_empty_desc")
            )
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    let playedIndices = 0..<player.currentIndex
                    if !playedIndices.isEmpty {
                        queueSection(title: "played") {
                            ForEach(Array(playedIndices), id: \.self) { index in
                                queueRow(song: player.queue[index], index: index, dimmed: true)
                            }
                        }
                    }

                    if let current = player.currentSong {
                        queueSection(title: "now_playing", accent: true) {
                            queueRow(song: current, index: player.currentIndex, isPlaying: true)
                        }
                    }

                    let upNextIndices = (player.currentIndex + 1)..<player.queue.count
                    if !upNextIndices.isEmpty {
                        queueSection(title: "up_next") {
                            ForEach(Array(upNextIndices), id: \.self) { index in
                                queueRow(song: player.queue[index], index: index, draggable: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("queue_title")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text(verbatim: queueSummaryText)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            Spacer(minLength: 0)
            PlayerMoreMenu {
                PMRoundBtnIcon(symbol: "ellipsis")
            }
            .frame(width: 24, height: 24)
            Button(action: onClose) {
                PMRoundBtnIcon(symbol: "xmark")
            }
            .buttonStyle(.plain)
            .help(Text("close"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func queueSection<Content: View>(
        title: LocalizedStringKey,
        accent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(accent ? PMColor.brand : PMColor.textFaint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            content()
        }
    }

    private func queueRow(song: Song,
                          index: Int,
                          isPlaying: Bool = false,
                          dimmed: Bool = false,
                          draggable: Bool = false) -> some View {
        HStack(spacing: 8) {
            if draggable {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14)
            }

            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 32,
                cornerRadius: 4,
                sourceID: song.sourceID,
                filePath: song.filePath
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 12, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                Text(song.artistName ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(song.duration.formattedDuration)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isPlaying ? PMColor.rowHover : Color.clear, in: .rect(cornerRadius: 6))
        .opacity(dimmed ? 0.52 : 1)
        .contentShape(Rectangle())
        .onTapGesture { playAt(index: index) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("clear_all") { clearPlayed(uptoIndex: player.currentIndex) }
                .disabled(player.currentIndex <= 0)
            Button("save_as_playlist") { saveQueueAsPlaylist() }
                .disabled(player.queue.isEmpty)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(PMColor.textMuted)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var queueSummaryText: String {
        "\(player.queue.count) \(String(localized: "songs_count")) · \(queueDuration.formattedDuration)"
    }

    private var queueDuration: TimeInterval {
        player.queue.reduce(0) { $0 + max(0, $1.duration) }
    }

    // MARK: - Actions

    private func playAt(index: Int) {
        guard index >= 0, index < player.queue.count else { return }
        player.currentIndex = index
        let song = player.queue[index]
        Task { await player.play(song: song) }
    }

    private func clearPlayed(uptoIndex: Int) {
        guard uptoIndex > 0, uptoIndex <= player.queue.count else { return }
        player.removeQueuePrefix(count: uptoIndex)
    }

    private func saveQueueAsPlaylist() {
        guard !player.queue.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let playlist = library.createPlaylist(name: "\(String(localized: "queue_title")) \(formatter.string(from: Date()))")
        library.replacePlaylistSongs(playlistID: playlist.id, songIDs: player.queue.map(\.id))
    }
}

private struct PMRoundBtnIcon: View {
    let symbol: String

    @State private var hover = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PMColor.textMuted)
            .frame(width: 24, height: 24)
            .background(hover ? PMColor.glassBtnHover : PMColor.glassBtn, in: .circle)
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}
#endif
