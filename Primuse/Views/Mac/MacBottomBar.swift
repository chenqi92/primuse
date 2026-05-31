#if os(macOS)
import SwiftUI
import PrimuseKit

/// 1.6 重设计的底部 Now Playing Bar — 三列布局: 左 cover+title+heart, 中
/// transport+scrubber, 右 secondary controls + volume。两套外观 (Liquid Glass
/// / Classic Material) 由 `pmAppearance` 环境驱动。
struct MacBottomBar: View {
    var isExpanded: Bool = false
    var isQueueShown: Bool = false
    var onToggleNowPlaying: () -> Void = {}
    var onToggleQueue: () -> Void = {}
    var onMiniPlayer: () -> Void = {}
    var onFullScreen: () -> Void = {}

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @Environment(MusicLibrary.self) private var library
    @Environment(\.pmAppearance) private var mode

    @State private var airPlayShown = false
    @State private var castShown = false
    @State private var coverMenuShown = false
    @State private var dragValue: Double?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            leftColumn
                .frame(width: 260, alignment: .leading)
            transportColumn
                .frame(maxWidth: .infinity)
            rightColumn
                .frame(width: 260, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: PMSize.bottomBar)
        .background {
            // 设计稿玻璃底栏: 浮在窗内, 14px 顶部圆角 + 左右 10pt 间距。背景只在圆角
            // 形状内填充 —— 之前用 NSVisualEffectView 的"吸窗后模糊"会画出一个不跟
            // 圆角走的实心方块, 盖出一块半透明方形; 改用直接 fill 圆角形状的
            // ultraThinMaterial, 圆角之外 (四角 + 左右留白) 完全透明, 看得到后面内容。
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: mode == .glass ? 14 : 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: mode == .glass ? 14 : 0,
                style: .continuous
            )
            ZStack {
                if mode == .glass {
                    shape.fill(.ultraThinMaterial)     // 半透模糊, 只在圆角内
                    shape.fill(PMColor.barGlassFill)   // 叠一层品牌半透色拉对比 (设计 pm-glass)
                } else {
                    shape.fill(PMColor.bgElev)         // 经典模式: 实色
                }
                // 顶边高光 (Apple "玻璃感" 配方 inset 0 1px 0 rgba(255,255,255,.3))
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
            }
        }
        .shadow(color: .black.opacity(mode == .glass ? 0.18 : 0), radius: 12, y: -3)
        // 设计稿: 玻璃模式左右留 10pt 浮动间距 (用户确认这个间距是要保留的)。
        .padding(.horizontal, mode == .glass ? 10 : 0)
    }

    // MARK: - Left column

    private var leftColumn: some View {
        HStack(spacing: 10) {
            coverThumb
                .onTapGesture { onToggleNowPlaying() }

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? String(localized: "player_empty_title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(player.currentSong == nil ? PMColor.textMuted : PMColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(metaLine.isEmpty ? String(localized: "player_empty_message") : metaLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            if let song = player.currentSong {
                let liked = library.isLiked(songID: song.id)
                Button {
                    library.toggleLiked(songID: song.id)
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(liked ? PMColor.brand : PMColor.textMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text(liked ? "a11y_unlike" : "a11y_like"))
                .animation(.easeOut(duration: 0.12), value: liked)
            }
        }
    }

    private var coverThumb: some View {
        Group {
            if let song = player.currentSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 48, cornerRadius: 5,
                    sourceID: song.sourceID,
                    filePath: song.filePath
                )
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(PMColor.card)
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(PMColor.textFaint)
                    }
            }
        }
        .help(Text(isExpanded ? "close" : "now_playing"))
    }

    private var metaLine: String {
        let parts = [player.currentSong?.artistName, player.currentSong?.albumTitle]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    // MARK: - Transport column

    private var transportColumn: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                transportBtn("shuffle", size: 13, active: player.shuffleEnabled, help: "shuffle") {
                    player.shuffleEnabled.toggle()
                }
                transportBtn("backward.fill", size: 13, help: "previous_song") {
                    Task { await player.previous() }
                }
                Button { player.togglePlayPause() } label: {
                    ZStack {
                        Circle().fill(PMColor.brand).frame(width: 36, height: 36)
                        if player.isLoading {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                                .offset(x: player.isPlaying ? 0 : 1)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(player.isLoading)
                .help(Text(player.isPlaying ? "pause" : "play"))

                transportBtn("forward.fill", size: 13, help: "next_song") {
                    Task { await player.next() }
                }
                transportBtn(repeatIconName, size: 13, active: player.repeatMode != .off, help: "repeat") {
                    cycleRepeat()
                }
            }

            scrubberRow
        }
    }

    private var scrubberRow: some View {
        let cur = dragValue ?? player.currentTime
        let dur = max(player.duration, 0.001)
        return HStack(spacing: 8) {
            Text(player.currentSong == nil ? "--:--" : cur.formattedDuration)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textFaint)
                .frame(minWidth: 36, alignment: .trailing)

            Scrubber(value: cur, total: dur,
                     onDrag: { dragValue = $0 },
                     onCommit: { v in
                         player.seek(to: v)
                         dragValue = nil
                     })
            .frame(height: 14)
            .opacity(player.currentSong == nil ? 0.4 : 1)

            Text(player.currentSong == nil ? "--:--" : "-\(max(0, dur - cur).formattedDuration)")
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textFaint)
                .frame(minWidth: 36, alignment: .leading)
        }
        .frame(maxWidth: 560)
    }

    private var repeatIconName: String {
        switch player.repeatMode {
        case .off, .all: return "repeat"
        case .one:       return "repeat.1"
        }
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private func transportBtn(_ symbol: String, size: CGFloat,
                              active: Bool = false,
                              help: LocalizedStringKey,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? PMColor.brand : PMColor.text)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }

    // MARK: - Right column

    private var rightColumn: some View {
        HStack(spacing: 8) {
            PMRoundBtn(icon: isExpanded ? "text.bubble.fill" : "text.bubble",
                       iconSize: 12, style: .plain,
                       isActive: isExpanded, help: "lyrics_word",
                       action: onToggleNowPlaying)

            PMRoundBtn(icon: isQueueShown ? "list.bullet.indent" : "list.bullet",
                       iconSize: 12, style: .plain,
                       isActive: isQueueShown, help: "queue_title") {
                onToggleQueue()
            }

            PMRoundBtn(icon: "tv.and.hifispeaker.fill", iconSize: 12, style: .plain,
                       isActive: player.isCastingMode, help: "cast_picker_title") {
                castShown = true
            }
            .popover(isPresented: $castShown, arrowEdge: .top) {
                CastDevicePickerSheet()
                    .frame(minWidth: 420, minHeight: 460)
            }

            volumeControl

            PMRoundBtn(icon: "rectangle.inset.filled.on.rectangle", iconSize: 12, style: .plain,
                       help: "mini_player", action: onMiniPlayer)
            PMRoundBtn(icon: "arrow.up.left.and.arrow.down.right", iconSize: 12, style: .plain,
                       help: "full_screen_player", action: onFullScreen)

            PlayerMoreMenu {
                PMRoundBtnIcon(icon: "ellipsis", help: "more")
            }
            .frame(width: PMSize.medBtn, height: PMSize.medBtn)
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 5) {
            Button { airPlayShown.toggle() } label: {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("audio_output"))
            .popover(isPresented: $airPlayShown, arrowEdge: .top) {
                AudioOutputPickerView()
            }

            // AppKit slider opts out of window-background dragging, so volume
            // drags do not move the hidden-titlebar window.
            PMVolumeSlider(value: Binding(
                get: { Double(engine.volume) },
                set: { engine.volume = Float($0) }
            ))
            .frame(width: 72)
        }
    }

    private var volumeSymbol: String {
        let v = engine.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.wave.1.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Scrubber

private struct Scrubber: View {
    let value: Double
    let total: Double
    var onDrag: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let frac = total > 0 ? CGFloat(max(0, min(1, value / total))) : 0
            let dotSize: CGFloat = (hover || dragging) ? 10 : 0
            let barHeight: CGFloat = (hover || dragging) ? 4 : 3

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(PMColor.dividerStrong)
                    .frame(height: barHeight)

                Capsule()
                    .fill(PMColor.brand)
                    .frame(width: max(0, min(width, width * frac)), height: barHeight)

                if dotSize > 0 {
                    Circle()
                        .fill(.white)
                        .frame(width: dotSize, height: dotSize)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .overlay {
                            Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5)
                        }
                        .offset(x: max(0, min(width - dotSize, width * frac - dotSize / 2)))
                }
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hover = h } }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard width > 0, total > 0 else { return }
                        dragging = true
                        let frac = max(0, min(1, g.location.x / width))
                        onDrag(Double(frac) * total)
                    }
                    .onEnded { g in
                        guard width > 0, total > 0 else { dragging = false; return }
                        let frac = max(0, min(1, g.location.x / width))
                        onCommit(Double(frac) * total)
                        dragging = false
                    }
            )
        }
    }
}

// MARK: - PlayerMoreMenu label helper

/// 没有点击行为的纯展示 icon — 给 PlayerMoreMenu 当 label 用 (PlayerMoreMenu
/// 自己接管点击)。复用 PMRoundBtn 的视觉但不要 button。
private struct PMRoundBtnIcon: View {
    var icon: String
    var help: LocalizedStringKey

    @Environment(\.pmAppearance) private var mode
    @State private var hover = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(PMColor.text)
            .frame(width: PMSize.medBtn, height: PMSize.medBtn)
            .background(hover ? (mode == .glass ? PMColor.glassBtnHover : PMColor.matBtnHover) : .clear, in: .circle)
            .help(Text(help))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}

#endif
