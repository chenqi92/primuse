#if os(macOS)
import SwiftUI
import PrimuseKit

/// Floating overlay that highlights the active lyric line with the line
/// after it as a smaller hint. Fits inside a borderless transparent NSPanel
/// pinned to the screen — see `DesktopLyricsWindowController`.
///
/// 视觉模式:
///   - 单行: 大字号居中(默认)
///   - 双行: 上面当前行,下面下一行,KTV 卡拉 OK 风格
///
/// hover 才显示工具栏,而且工具栏是分散到 panel 的 **四个边角** —— 不再
/// 浮在歌词中央把歌词遮住。左侧:上一首/下一首;右侧:字号-/字号+;
/// 底中:播放/暂停 + 单/双行 + 颜色 + 锁定 + 关闭。
struct DesktopLyricsView: View {
    var onClose: () -> Void = {}

    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var isHovering = false
    @State private var colorPaletteShown = false

    @AppStorage("desktopLyricsFontScale") private var fontScale: Double = 1.0
    /// KTV 双行模式 vs 单行模式。
    @AppStorage("desktopLyricsShowNext") private var showNext: Bool = true
    @AppStorage("desktopLyricsLocked") private var locked: Bool = false
    /// 歌词主色调 (hex 字符串方便存 AppStorage)。默认白。
    @AppStorage("desktopLyricsColor") private var colorHex: String = "#FFFFFF"

    private let minScale: Double = 0.7
    private let maxScale: Double = 1.8

    private var lyricsColor: Color {
        Color.fromHexString(colorHex) ?? .white
    }

    var body: some View {
        ZStack {
            content
                // 内容居中,工具按钮浮在四周 padding 区域不挡歌词。
                .padding(.horizontal, 60)
                .padding(.vertical, 20)

            if isHovering && !locked {
                edgeToolbar
            }
        }
        .frame(minWidth: 520, minHeight: showNext ? 120 : 70)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, new in updateIndex(time: new) }
    }

    // MARK: - Lyrics content

    private var content: some View {
        VStack(spacing: 6) {
            Text(activeLine ?? player.currentSong?.title ?? "")
                .font(.system(size: 32 * CGFloat(fontScale), weight: .semibold))
                .foregroundStyle(lyricsColor)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if showNext, let next = nextLine {
                Text(next)
                    .font(.system(size: 18 * CGFloat(fontScale), weight: .medium))
                    .foregroundStyle(lyricsColor.opacity(0.65))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Edge toolbar (按钮分散在 panel 四周)

    private var edgeToolbar: some View {
        ZStack {
            // 左中:上一首
            HStack(spacing: 4) {
                edgeButton("backward.fill", help: "previous_song") {
                    Task { await player.previous() }
                }
                Spacer()
                edgeButton("forward.fill", help: "next_song") {
                    Task { await player.next() }
                }
            }
            .padding(.horizontal, 14)

            // 顶部右:字号
            VStack {
                HStack {
                    Spacer()
                    edgeButton("textformat.size.smaller", help: "lyrics_font_smaller") {
                        fontScale = max(minScale, fontScale - 0.15)
                    }
                    edgeButton("textformat.size.larger", help: "lyrics_font_larger") {
                        fontScale = min(maxScale, fontScale + 0.15)
                    }
                }
                .padding(.top, 6)
                .padding(.trailing, 14)
                Spacer()
            }

            // 底部中央:播放控制 + 行数 + 颜色 + 锁定 + 关闭
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    edgeButton(player.isPlaying ? "pause.fill" : "play.fill",
                               help: player.isPlaying ? "pause" : "play") {
                        player.togglePlayPause()
                    }
                    edgeButton(showNext ? "text.alignleft" : "text.justify",
                               help: showNext ? "single_line_lyrics" : "dual_line_lyrics") {
                        showNext.toggle()
                    }
                    edgeButton("paintpalette", help: "lyrics_color") {
                        colorPaletteShown.toggle()
                    }
                    .popover(isPresented: $colorPaletteShown, arrowEdge: .bottom) {
                        colorPalette
                    }
                    edgeButton("lock.open.fill", help: "lock_desktop_lyrics") {
                        locked = true
                    }
                    edgeButton("xmark", help: "hide_desktop_lyrics") {
                        onClose()
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func edgeButton(_ symbol: String, help: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Color.black.opacity(0.5), in: Circle())
        .help(Text(help))
    }

    // MARK: - Color palette

    /// 9 个预设色,够用而且不让用户陷入色板调色盘。点击立刻应用,
    /// hex 写入 AppStorage 同步到 panel 渲染。
    private static let presetColors: [String] = [
        "#FFFFFF", // white
        "#FFD60A", // yellow
        "#FF453A", // red
        "#FF9F0A", // orange
        "#30D158", // green
        "#64D2FF", // cyan
        "#0A84FF", // blue
        "#BF5AF2", // purple
        "#FF375F"  // pink
    ]

    private var colorPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("lyrics_color").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 5),
                      spacing: 8) {
                ForEach(Self.presetColors, id: \.self) { hex in
                    Button {
                        colorHex = hex
                        colorPaletteShown = false
                    } label: {
                        Circle()
                            .fill(Color.fromHexString(hex) ?? .white)
                            .frame(width: 24, height: 24)
                            .overlay {
                                Circle()
                                    .stroke(.primary.opacity(0.2), lineWidth: 1)
                            }
                            .overlay {
                                if colorHex == hex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.black)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 180)
    }

    // MARK: - Lyrics state

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
        lyrics = []; currentIndex = 0
        let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        guard player.currentSong?.id == song.id else { return }
        lyrics = loaded
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

// MARK: - Color hex helper

private extension Color {
    /// 接收 #RRGGBB / #RRGGBBAA / RRGGBB 格式,失败返回 nil。
    /// 命名为 fromHexString 避开 SwiftUI 6 自带的 Color(hex:)。
    static func fromHexString(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8) / 255
            b = Double(v & 0x0000FF) / 255
            a = 1
        } else {
            r = Double((v & 0xFF000000) >> 24) / 255
            g = Double((v & 0x00FF0000) >> 16) / 255
            b = Double((v & 0x0000FF00) >> 8) / 255
            a = Double(v & 0x000000FF) / 255
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
#endif
