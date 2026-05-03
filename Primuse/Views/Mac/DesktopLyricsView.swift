#if os(macOS)
import SwiftUI
import PrimuseKit

/// Floating overlay that highlights the active lyric line with the line
/// after it as a smaller hint. Fits inside a borderless transparent NSPanel
/// pinned to the screen — see `DesktopLyricsWindowController`.
///
/// 视觉模式 (DesktopLyricsLayout):
///   - single: 单行,大字号居中
///   - dual: 双行,KTV 卡拉 OK 风格 (当前 + 下一行)
///   - vertical: 纵向,逐字从上往下排,中文古典书写习惯
///
/// hover 才显示工具栏,工具栏分散在 panel 四个边角不挡歌词。字号会
/// 跟着 panel 大小自动放大缩小,用户手动 fontScale 是叠加在自动尺寸
/// 之上的微调。
struct DesktopLyricsView: View {
    var onClose: () -> Void = {}
    /// 由 controller 注入,在 layout 切换 (single/dual ↔ vertical) 时
    /// 把 panel 拉成横宽或竖窄。SwiftUI 内部的 GeometryReader 会跟着
    /// 新尺寸刷新字号。
    var onLayoutChange: ((DesktopLyricsLayout) -> Void)? = nil

    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var isHovering = false
    @State private var colorPaletteShown = false

    @AppStorage("desktopLyricsFontScale") private var fontScale: Double = 1.0
    /// 排版模式:single / dual / vertical。旧版本只有 showNext bool,
    /// 新版本枚举存 raw value,迁移逻辑在 init 里。
    @AppStorage("desktopLyricsLayout") private var layoutRaw: String = DesktopLyricsLayout.dual.rawValue
    @AppStorage("desktopLyricsLocked") private var locked: Bool = false
    /// 是否显示玻璃背景 chrome。关掉后只剩浮动文字,适合极简桌面。
    @AppStorage("desktopLyricsShowBackground") private var showBackground: Bool = true
    /// 歌词主色调 (hex 字符串方便存 AppStorage)。默认白。
    @AppStorage("desktopLyricsColor") private var colorHex: String = "#FFFFFF"

    private var layout: DesktopLyricsLayout {
        DesktopLyricsLayout(rawValue: layoutRaw) ?? .dual
    }

    private let minScale: Double = 0.7
    private let maxScale: Double = 1.8

    private var lyricsColor: Color {
        Color.fromHexString(colorHex) ?? .white
    }

    /// 各布局下的最小允许尺寸 —— width 至少 260pt 才能装下顶部工具栏的
    /// 10 个按钮 (220pt + padding);height 至少留 toolbar (38pt) + 一行
    /// 字 (~30pt) + 底部 padding (16pt) = 84pt。
    private var minPanelSize: CGSize {
        switch layout {
        case .single: return CGSize(width: 360, height: 100)
        case .dual: return CGSize(width: 360, height: 140)
        case .vertical: return CGSize(width: 260, height: 220)
        }
    }

    /// 顶部工具栏总高度 (按钮 + 上下 padding)。歌词内容上方要预留这么多
    /// 空白,无论横向 / 纵向都不会被工具栏挡住。
    private static let topToolbarHeight: CGFloat = 38
    private static let cornerRadius: CGFloat = 18

    var body: some View {
        // GeometryReader 拿当前 panel 实际尺寸,把字号绑到尺寸上 ——
        // 用户拖大 panel 字也跟着变大,fontScale 在此基础上再叠加。
        GeometryReader { geo in
            content(in: geo.size)
                // 顶部留出 toolbar 高度,左右/底部用普通 padding。横向、
                // 纵向都用同一组 padding,工具栏永远在顶部一致位置。
                .padding(.top, Self.topToolbarHeight)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(minWidth: minPanelSize.width, minHeight: minPanelSize.height)
        // 关掉 showBackground 就只剩浮动文字,跟锁定态一样无 chrome。
        .background {
            if showBackground && !locked {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
            }
        }
        // 工具栏走 .overlay 不进 ZStack —— ZStack 里跟内容竞争 frame
        // 时,长歌词会把按钮挤出可视区。overlay 锚定 panel 自身 frame
        // 顶边,跟内容完全独立,不会被挤压也不会被裁。
        .overlay(alignment: .top) {
            if isHovering || colorPaletteShown {
                if locked {
                    lockedHoverOverlay
                } else {
                    topToolbar
                }
            }
        }
        // 内容铺出 panel 时直接裁掉,别越过 panel 边界。
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, new in updateIndex(time: new) }
        // 切到/出 vertical 时把 panel 整块改成竖窄/横宽。
        .onChange(of: layoutRaw) { _, _ in
            onLayoutChange?(layout)
        }
    }

    /// 锁定状态下 hover 浮现的解锁按钮 —— 单个按钮浮在右上角,
    /// 一点就解锁,不挡歌词。
    private var lockedHoverOverlay: some View {
        VStack {
            HStack {
                Spacer()
                edgeButton("lock.fill", help: "desktop_lyrics_unlocked") {
                    locked = false
                }
            }
            Spacer()
        }
        .padding(8)
    }

    // MARK: - Lyrics content

    /// 根据当前 panel 尺寸算出主文字的基准字号 —— 取 panel 的"长边"
    /// 6% 然后 clamp 到 [20, 64]。这样横向 1100×220 跟纵向 220×1100
    /// 调换长宽后字号一致 (均为 64pt 满档),不会出现"切到纵向就变小"
    /// 的情况。用户的 fontScale 在 [0.7, 1.8] 之间叠加微调。
    private func activeFontSize(in size: CGSize) -> CGFloat {
        let longSide: CGFloat
        switch layout {
        case .single, .dual:
            longSide = size.width
        case .vertical:
            longSide = size.height
        }
        let clamped = min(64, max(20, longSide * 0.06))
        return clamped * CGFloat(fontScale)
    }

    private func nextFontSize(in size: CGSize) -> CGFloat {
        activeFontSize(in: size) * 0.55
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        let active = activeLine
        let next = nextLine
        let placeholder = player.currentSong?.title
            ?? String(localized: "desktop_lyrics_no_song")

        switch layout {
        case .single:
            Text(active ?? placeholder)
                .font(.system(size: activeFontSize(in: size), weight: .semibold))
                .foregroundStyle(lyricsColor)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .dual:
            VStack(spacing: 6) {
                Text(active ?? placeholder)
                    .font(.system(size: activeFontSize(in: size), weight: .semibold))
                    .foregroundStyle(lyricsColor)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if let next {
                    // 下一行只是提示,保持默认白 — 用户调的颜色只染当前行,
                    // 否则两行同色会让"哪句正在唱"的视觉重点丢失。
                    Text(next)
                        .font(.system(size: nextFontSize(in: size), weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .vertical:
            // 纵向排版 —— 左为当前行 (用户色),右为下一行 (白色提示)。
            // 字号根据行字数 + panel 高度自动收缩,避免超出 panel 高度
            // 顶到工具按钮区域。
            let activeText = active ?? placeholder
            HStack(alignment: .top, spacing: 14) {
                verticalColumn(activeText,
                               fontSize: fittedFontSize(text: activeText,
                                                        in: size,
                                                        base: activeFontSize(in: size)),
                               weight: .semibold,
                               color: lyricsColor)
                if let next {
                    verticalColumn(next,
                                   fontSize: fittedFontSize(text: next,
                                                            in: size,
                                                            base: nextFontSize(in: size)),
                                   weight: .medium,
                                   color: .white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 算出能塞进 size.height 的字号:可用高度 / (字符数 × 行高系数),
    /// 跟 base (按尺寸算的"理想字号") 取小值。`verticalLineHeightFactor`
    /// 跟 verticalColumn 里 `frame(height:)` 用同一个值 (1.05),否则算
    /// 出来的字号渲染时会被 SwiftUI 的默认行高撑高,不够塞 N 个字符。
    private static let verticalLineHeightFactor: CGFloat = 1.05

    private func fittedFontSize(text: String, in size: CGSize, base: CGFloat) -> CGFloat {
        let count = max(1, text.count)
        let available = size.height - 80  // 上下 toolbar + padding 安全区
        let perChar = available / (CGFloat(count) * Self.verticalLineHeightFactor)
        return max(12, min(base, perChar))
    }

    /// 一列纵向歌词 —— 每个字符锁在 fontSize × 1.05 的固定高度盒子里,
    /// VStack 不留额外 spacing。这样总高 = 字符数 × fontSize × 1.05,
    /// 跟 fittedFontSize 算出来的容量严格匹配,长歌词不会突破 panel
    /// 把底部按钮挤出屏幕。之前用 `spacing: fontSize × 0.18` + Text
    /// 默认 line height (~1.2) 双重叠加,实际每字占用 ~1.4×fontSize,
    /// 30 字会冲到 2640pt 把 panel 撑超出屏。
    private func verticalColumn(_ text: String, fontSize: CGFloat,
                                weight: Font.Weight, color: Color) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, char in
                Text(String(char))
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
                    .frame(height: fontSize * Self.verticalLineHeightFactor)
            }
        }
    }

    // MARK: - Edge toolbar (按钮分散在 panel 四周)

    /// 把所有按钮整合成顶部一行 HStack,横向 / 纵向都摆在同一处。
    /// 按钮按功能组分 (媒体 / 排版 / 字号 / 锁定&关闭),组间用一个
    /// 小 spacer 分开,组内紧凑排列。横向 panel 宽度足够,纵向 260pt
    /// 左右也刚好够装下全部 10 个按钮 (220pt) + 留 padding。
    private var topToolbar: some View {
        HStack(spacing: 2) {
            // 媒体控制
            edgeButton("backward.fill", help: "previous_song") {
                Task { await player.previous() }
            }
            edgeButton(player.isPlaying ? "pause.fill" : "play.fill",
                       help: player.isPlaying ? "pause" : "play") {
                player.togglePlayPause()
            }
            edgeButton("forward.fill", help: "next_song") {
                Task { await player.next() }
            }

            Spacer().frame(width: 8)

            // 排版 / 背景 / 颜色
            edgeButton(layoutIconName, help: nextLayoutHelpKey) {
                let nextLayout = layout.next
                layoutRaw = nextLayout.rawValue
                onLayoutChange?(nextLayout)
            }
            edgeButton(showBackground ? "rectangle.fill" : "rectangle",
                       help: showBackground ? "hide_lyrics_background"
                                            : "show_lyrics_background") {
                showBackground.toggle()
            }
            edgeButton("paintpalette", help: "lyrics_color") {
                colorPaletteShown.toggle()
            }
            .popover(isPresented: $colorPaletteShown, arrowEdge: .bottom) {
                colorPalette
            }

            Spacer().frame(width: 8)

            // 字号
            edgeButton("textformat.size.smaller", help: "lyrics_font_smaller") {
                fontScale = max(minScale, fontScale - 0.15)
            }
            edgeButton("textformat.size.larger", help: "lyrics_font_larger") {
                fontScale = min(maxScale, fontScale + 0.15)
            }

            Spacer().frame(width: 8)

            // 锁定 / 关闭
            edgeButton("lock.open.fill", help: "lock_desktop_lyrics") {
                locked = true
            }
            edgeButton("xmark", help: "hide_desktop_lyrics") {
                onClose()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// 当前布局对应的图标 (按钮上显示的) + 切换 tooltip 翻译键
    /// (告诉用户点了之后会跳到哪个排版)。
    private var layoutIconName: String {
        switch layout {
        case .single: return "text.alignleft"
        case .dual: return "text.justify"
        case .vertical: return "text.append"
        }
    }

    private var nextLayoutHelpKey: LocalizedStringKey {
        switch layout.next {
        case .single: return "single_line_lyrics"
        case .dual: return "dual_line_lyrics"
        case .vertical: return "vertical_lyrics"
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

// MARK: - Layout enum

enum DesktopLyricsLayout: String, CaseIterable {
    case single, dual, vertical

    var next: DesktopLyricsLayout {
        switch self {
        case .single: return .dual
        case .dual: return .vertical
        case .vertical: return .single
        }
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
