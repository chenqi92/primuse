#if os(macOS)
import SwiftUI
import PrimuseKit

/// Compact "what's playing" UI shown inside the menu bar popover. Covers
/// the basics — artwork, title, transport, volume — plus a button to
/// foreground the main window.
struct MenuBarPlayerView: View {
    var onOpenMainWindow: () -> Void = {}
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    @AppStorage("desktopLyricsLocked") private var desktopLyricsLocked: Bool = false
    @AppStorage("desktopLyricsVisible") private var desktopLyricsVisible: Bool = false
    @AppStorage(DesktopLyricsWindowController.islandVisibleKey) private var desktopLyricsIsland = false
    @State private var shortcutStore = MacKeyboardShortcutStore.shared
    @AppStorage("miniPlayerVisible") private var miniPlayerVisible: Bool = false
    /// 与设置 › 歌词里的开关是同一个键；菜单栏控制器监听它的变化即时换上或撤下歌词。
    @AppStorage(MacMenuBarController.lyricsEnabledKey) private var menuBarLyricsEnabled = false
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsPlayerVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            coverRow
            scrubber
            transport
            if showsPlayerVolumeBar {
                volume
            }

            Divider().background(PMColor.divider).padding(.vertical, 2)

            if !player.isLiveRadio {
                menuRow(icon: "text.bubble",
                        title: desktopLyricsVisible ? "hide_desktop_lyrics" : "show_desktop_lyrics",
                        shortcut: shortcut(.showDesktopLyrics),
                        active: desktopLyricsVisible) {
                    PrimuseAppDelegate.shared?.toggleDesktopLyrics()
                }

                menuRow(icon: desktopLyricsLocked ? "lock.fill" : "lock",
                        title: "lock_desktop_lyrics",
                        shortcut: shortcut(.toggleDesktopLyricsLock),
                        active: desktopLyricsLocked) {
                    pmWithAnimation(.control) { desktopLyricsLocked.toggle() }
                }

                menuRow(icon: "rectangle.tophalf.inset.filled",
                        title: "desktop_lyrics_island",
                        shortcut: shortcut(.toggleLyricsIsland),
                        active: desktopLyricsIsland) {
                    PrimuseAppDelegate.shared?.toggleDesktopLyricsIsland()
                }
                .help(Text("desktop_lyrics_island_description"))

                menuRow(icon: "menubar.rectangle",
                        title: "menu_bar_lyrics",
                        shortcut: shortcut(.toggleMenuBarLyrics),
                        active: menuBarLyricsEnabled) {
                    pmWithAnimation(.control) { menuBarLyricsEnabled.toggle() }
                }
                .help(Text("menu_bar_lyrics_description"))
            }

            menuRow(icon: "rectangle.inset.filled.on.rectangle",
                    title: "mini_player",
                    shortcut: shortcut(.showMiniPlayer),
                    active: miniPlayerVisible) {
                PrimuseAppDelegate.shared?.toggleMiniPlayer()
            }

            menuRow(icon: "arrow.up.left.and.arrow.down.right", title: "full_screen_player",
                    shortcut: shortcut(.toggleFullScreenPlayer)) {
                PrimuseAppDelegate.shared?.toggleFullScreenPlayer()
            }

            Divider().background(PMColor.divider).padding(.vertical, 2)

            menuRow(icon: "macwindow", title: "open_main_window", shortcut: shortcut(.openMainWindow)) {
                onOpenMainWindow()
            }
            menuRow(icon: "gearshape", title: "settings_title", shortcut: "⌘,") {
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)
            menuRow(icon: "rectangle.portrait.and.arrow.right",
                    title: "quit_app",
                    shortcut: "⌘Q",
                    accent: PMColor.bad) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
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

            // 换歌只让文字淡一下。动画分别挂在每行上而不是这个 VStack 上 ——
            // 专辑行是 if let 插入的, 它一进一出会改 NSPopover 的高度, 而 SwiftUI
            // 的过渡跟 popover 自己的尺寸动画不同步, 会出现「字先变、框后变」。
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? "—")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                    .pmAnimation(.trackChange, value: player.currentSong?.id)
                Text(
                    player.currentSong.flatMap { library.artistDisplayName(for: $0) }
                        ?? ""
                )
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .pmAnimation(.trackChange, value: player.currentSong?.id)
                if let album = player.currentSong?.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                        .pmAnimation(.trackChange, value: player.currentSong?.id)
                }
            }
            .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
    }

    private var artwork: some View {
        Group {
            if player.isLiveRadio, let station = player.currentRadioStation {
                RadioStationArtworkView(station: station, size: 64, cornerRadius: 8)
            } else if let song = player.currentSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 64, cornerRadius: 8,
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .artworkCrossfade()
            } else {
                CoverArtView(data: nil, size: 64, cornerRadius: 8)
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
            if player.currentItemIsSpokenWord, !player.isLiveRadio {
                Button { player.skipSpokenWordBackward() } label: {
                    Image(systemName: player.spokenWordSkipBackwardSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pmPointingHand()
                .help(Text("a11y_skip_backward"))
            } else if !player.isLiveRadio || player.canSwitchRadioStation {
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pmPointingHand()
                .help(player.isLiveRadio ? Text("radio_previous_station") : shortcutHelp(.previousTrack))
            }

            Button {
                guard !(player.isLoading && !player.isLiveRadio) else { return }
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(PMColor.brand).frame(width: 42, height: 42)
                    // 两支都落在同一个 42pt 圆心上, 不改父容器布局, 所以这对分支
                    // 可以做交叉淡入(与底栏播放键同一写法)。
                    if player.showsLoadingIndicator && !player.isLiveRadio {
                        ProgressView().controlSize(.small).tint(.white)
                            .pmFadeTransition(motion: .control)
                    } else {
                        Image(systemName: player.isLiveRadio && (player.isPlaying || player.isLoading)
                            ? "stop.fill"
                            : (player.isPlaying || player.isLoading ? "pause.fill" : "play.fill"))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                            .offset(x: player.isPlaying || player.isLoading ? 0 : 1)
                            .pmFadeTransition(motion: .control)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pmPointingHand()
            .disabled(player.showsLoadingIndicator && !player.isLiveRadio)
            .help(Text(player.isLiveRadio && (player.isPlaying || player.isLoading)
                ? LocalizedStringKey("radio_stop")
                : (player.isPlaying || player.isLoading ? "pause" : "play")) + shortcutSuffix(.playPause))

            if player.currentItemIsSpokenWord, !player.isLiveRadio {
                Button { player.skipSpokenWordForward() } label: {
                    Image(systemName: player.spokenWordSkipForwardSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pmPointingHand()
                .help(Text("a11y_skip_forward"))
            } else if !player.isLiveRadio || player.canSwitchRadioStation {
                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pmPointingHand()
                .help(player.isLiveRadio ? Text("radio_next_station") : shortcutHelp(.nextTrack))
            }
            Spacer()
        }
    }

    // MARK: - Volume

    private var volume: some View {
        HStack(spacing: 8) {
            PMVolumeSymbol()
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 14)
            PMPlaybackVolumeSlider()
            PMVolumePercentage()
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 24, alignment: .trailing)
        }
        .help(!player.isLiveRadio && player.playbackSettings.outputMode == .highFidelity
            ? Text("volume_high_fidelity_system_hint")
            : Text("volume") + shortcutSuffix(.volumeDown) + shortcutSuffix(.volumeUp))
    }

    // MARK: - Menu rows

    private func shortcut(_ action: MacKeyboardShortcutAction) -> String? {
        shortcutStore.shortcut(for: action)?.displayString
    }

    private func shortcutSuffix(_ action: MacKeyboardShortcutAction) -> Text {
        guard let shortcut = shortcut(action) else { return Text(verbatim: "") }
        return Text(verbatim: " (\(shortcut))")
    }

    private func shortcutHelp(_ action: MacKeyboardShortcutAction) -> Text {
        Text(verbatim: action.localizedTitle) + shortcutSuffix(action)
    }

    private func menuRow(icon: String, title: LocalizedStringKey,
                         shortcut: String? = nil,
                         active: Bool = false,
                         accent: Color = PMColor.brand,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                    .opacity(active ? 1 : 0)
                    .frame(width: 11)
                    .accessibilityHidden(true)
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(active ? accent : PMColor.textMuted)
                    .frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.text)
                Spacer()
                Text(verbatim: shortcut ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarActionButtonStyle())
        .pmPointingHand()
        .accessibilityAddTraits(active ? .isSelected : [])
    }

}

private struct MenuBarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarActionLabel(configuration: configuration)
    }
}

private struct MenuBarActionLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(hovering || configuration.isPressed ? PMColor.rowHover : .clear)
            }
            .onHover { hovering = $0 }
            .pmAnimation(.hover, value: hovering)
    }
}

private struct MenuBarPlayerProgress: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        Group {
            if player.isLiveRadio {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("live_badge").fontWeight(.bold)
                    Spacer()
                    Text(formatTime(player.currentTime))
                }
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textFaint)
            } else {
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
