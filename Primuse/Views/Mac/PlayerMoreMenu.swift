#if os(macOS)
import SwiftUI
import PrimuseKit

/// 全部"播放器层面"菜单项的统一入口 —— 加入歌单 / 刮削 / 歌曲信息 /
/// 分享 / 字号 / 睡眠定时 / 删除 / 上下首 / 随机 / 单曲循环。
///
/// 之前 NowPlaying 顶部和 BottomBar 各有一份不一致的 more 菜单,
/// NowPlaying 的菜单项甚至比底栏多 2/3。把所有菜单项集中到这里,两边
/// 同样行为；状态(showAddToPlaylist / showSongInfo 等)和对应 sheet 都
/// 在本组件内部,调用方只给一个 label 就行。
struct PlayerMoreMenu<MenuLabel: View>: View {
    @ViewBuilder var label: () -> MenuLabel

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore

    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0

    @State private var showAddToPlaylist = false
    @State private var showScrapeOptions = false
    @State private var showSongInfo = false
    @State private var showSleepTimer = false
    @State private var showDeleteConfirm = false
    @State private var scrapeAlertMessage: String?
    @State private var isScrapingCurrentSong = false
    /// 用 Button + Popover 自己画菜单,不用 SwiftUI Menu。原因:
    /// SwiftUI Menu + .borderlessButton 在 macOS 上落到 NSPopUpButton,
    /// 它的 hit test 只覆盖可见图标,玻璃圆环空白区会穿透到下层(歌词)。
    /// Button 是真 Button,整个 frame 都是 hit-testable。
    @State private var menuShown = false
    @State private var fontPickerShown = false

    private var isInAnyPlaylist: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.playlists.contains { library.contains(songID: songID, inPlaylist: $0.id) }
    }

    var body: some View {
        Button { menuShown.toggle() } label: {
            label()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $menuShown, arrowEdge: .top) {
            popoverMenuContent
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.currentSong {
                AddToPlaylistSheet(song: song)
            }
        }
        .sheet(isPresented: $showScrapeOptions) {
            if let song = player.currentSong {
                ScrapeOptionsView(song: song) { u in
                    CachedArtworkView.invalidateCache(for: u.id)
                    if let oldRef = song.coverArtFileName {
                        CachedArtworkView.invalidateCache(for: oldRef)
                    }
                    player.syncSongMetadata(u)
                    player.forceRefreshNowPlayingArtwork()
                }
            }
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
            }
        }
        .confirmationDialog(String(localized: "sleep_timer"), isPresented: $showSleepTimer) {
            Button("15 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 15) }
            Button("30 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 30) }
            Button("45 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 45) }
            Button("60 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 60) }
            if player.isSleepTimerActive {
                Button(String(localized: "cancel_timer"), role: .destructive) { player.cancelSleep() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(get: { scrapeAlertMessage != nil },
                                    set: { if !$0 { scrapeAlertMessage = nil } })) {
            Button("done", role: .cancel) {}
        } message: { Text(scrapeAlertMessage ?? "") }
        .alert(String(localized: "delete_song"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "delete"), role: .destructive) { deleteCurrentSong() }
        } message: {
            Text(String(localized: "delete_song_message"))
        }
    }

    /// Popover 内的菜单内容。每个 row 都是真 Button,整个行 hit-testable,
    /// 没有 NSPopUpButton 那种"只点中图标才响应"的问题。
    @ViewBuilder
    private var popoverMenuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuRow(title: "previous_song", symbol: "backward.fill") {
                Task { await player.previous() }
            }
            menuRow(title: "next_song", symbol: "forward.fill") {
                Task { await player.next() }
            }
            divider()
            menuRow(title: "shuffle",
                    symbol: player.shuffleEnabled ? "checkmark" : "shuffle") {
                player.shuffleEnabled.toggle()
            }
            menuRow(title: repeatMenuTitleKey,
                    symbol: player.repeatMode == .off ? "repeat" :
                             player.repeatMode == .one ? "repeat.1" : "checkmark") {
                cycleRepeat()
            }
            divider()
            menuRow(title: "add_to_playlist",
                    symbol: isInAnyPlaylist ? "heart.fill" : "text.badge.plus",
                    disabled: player.currentSong == nil) {
                showAddToPlaylist = true
            }
            menuRow(title: "scrape_song", symbol: "wand.and.stars",
                    disabled: player.currentSong == nil || isScrapingCurrentSong) {
                showScrapeOptions = true
            }
            divider()
            menuRow(title: "song_info", symbol: "info.circle",
                    disabled: player.currentSong == nil) {
                showSongInfo = true
            }
            if let song = player.currentSong {
                ShareLink(item: "\(song.title) - \(song.artistName ?? "")") {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 18)
                        Text("share").font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            divider()
            // 字号子菜单 —— 用 popover 打开第二层。
            Button { fontPickerShown.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size").frame(width: 18)
                    Text("lyrics_font_size").font(.callout)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $fontPickerShown, arrowEdge: .leading) {
                fontPickerPopover
            }
            divider()
            menuRow(title: player.isSleepTimerActive ? "sleep_timer_active" : "sleep_timer",
                    symbol: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz") {
                showSleepTimer = true
            }
            divider()
            menuRow(title: "delete_song", symbol: "trash", role: .destructive,
                    disabled: player.currentSong == nil) {
                showDeleteConfirm = true
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    private func menuRow(title: LocalizedStringKey, symbol: String,
                         role: ButtonRole? = nil, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(role: role) {
            menuShown = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(role == .destructive ? Color.red : .primary)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(role == .destructive ? Color.red : .primary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func divider() -> some View {
        Divider().padding(.vertical, 4).padding(.horizontal, 8)
    }

    private var fontPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            fontPickerRow("lyrics_font_small", value: 0.85)
            fontPickerRow("lyrics_font_medium", value: 1.0)
            fontPickerRow("lyrics_font_large", value: 1.2)
            fontPickerRow("lyrics_font_xlarge", value: 1.5)
        }
        .padding(.vertical, 6)
        .frame(width: 160)
    }

    private func fontPickerRow(_ title: LocalizedStringKey, value: Double) -> some View {
        Button {
            lyricsFontScale = value
            fontPickerShown = false
        } label: {
            HStack {
                Text(title).font(.callout)
                Spacer()
                if abs(lyricsFontScale - value) < 0.001 {
                    Image(systemName: "checkmark")
                        .font(.caption).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var repeatMenuTitleKey: LocalizedStringKey {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat_all"
        case .one: return "repeat_one"
        }
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private func deleteCurrentSong() {
        guard let song = player.currentSong else { return }
        Task { await player.next() }
        let songID = song.id
        Task {
            await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
            await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
        }
        CachedArtworkView.invalidateCache(for: song.id)
        sourceManager.deleteAudioCache(for: song)
        let remaining = library.deleteSong(song)
        sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
    }
}
#endif
