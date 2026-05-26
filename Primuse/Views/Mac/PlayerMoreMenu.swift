#if os(macOS)
import AppKit
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
    @State private var showTagEditor = false
    @State private var showSimilarSongs = false
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
        #if os(macOS)
        baseBody
            .popover(isPresented: $showSleepTimer, arrowEdge: .top) {
                MacSleepTimerPopover {
                    showSleepTimer = false
                }
            }
        #else
        baseBody
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
        #endif
    }

    private var baseBody: some View {
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
        // macOS 走 ScrapeWindowController 独立 NSWindow,带原生红灯。
        // showScrapeOptions 仅作为触发开关,window 自己管生命周期。
        .onChange(of: showScrapeOptions) { _, new in
            guard new, let song = player.currentSong else {
                if new { showScrapeOptions = false }
                return
            }
            ScrapeWindowController.shared.show(song: song) { u in
                CachedArtworkView.invalidateCache(for: u.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
                player.syncSongMetadata(u)
                player.forceRefreshNowPlayingArtwork()
            }
            showScrapeOptions = false
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
            }
        }
        .sheet(isPresented: $showTagEditor) {
            if let song = player.currentSong {
                TagEditorView(song: song) { updated in
                    player.syncSongMetadata(updated)
                    player.forceRefreshNowPlayingArtwork()
                }
            }
        }
        .sheet(isPresented: $showSimilarSongs) {
            if let song = player.currentSong {
                SimilarSongsSheet(seed: song)
                    .frame(minWidth: 420, minHeight: 420)
            }
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
            if let song = player.currentSong {
                menuHeader(song)
                divider()
            }
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
            menuRow(title: "similar_songs",
                    symbol: "sparkles",
                    disabled: player.currentSong == nil) {
                showSimilarSongs = true
            }
            if let song = player.currentSong {
                if let album = matchingAlbum(for: song) {
                    menuRow(titleText: "\(goToAlbumTitle) · \(album.title)",
                            symbol: "rectangle.stack.fill") {
                        NotificationCenter.default.post(name: .primuseDetailOpenAlbum, object: album)
                    }
                }
                if let artist = matchingArtist(for: song) {
                    menuRow(titleText: "\(goToArtistTitle) · \(artist.name)",
                            symbol: "music.mic") {
                        NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
                    }
                }
            }
            divider()
            menuRow(title: "tag_editor_menu",
                    symbol: "tag",
                    disabled: player.currentSong == nil) {
                showTagEditor = true
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
                            .foregroundStyle(PMColor.textMuted)
                        Text("share")
                            .font(.callout)
                            .foregroundStyle(PMColor.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .pmRowBackground(cornerRadius: 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            divider()
            // 字号子菜单 —— 用 popover 打开第二层。
            Button { fontPickerShown.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size").frame(width: 18)
                        .foregroundStyle(PMColor.textMuted)
                    Text("lyrics_font_size")
                        .font(.callout)
                        .foregroundStyle(PMColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(PMColor.textFaint)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .pmRowBackground(cornerRadius: 6)
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
            menuRow(title: "scrobble_title", symbol: "waveform.path.ecg") {
                NotificationCenter.default.post(name: .primuseSelectScrobble, object: nil)
            }
            menuRow(titleText: playbackSettingsTitle, symbol: "slider.horizontal.3") {
                openSettingsWindow()
            }
            divider()
            menuRow(title: "delete_song", symbol: "trash", role: .destructive,
                    disabled: player.currentSong == nil) {
                showDeleteConfirm = true
            }
        }
        .padding(.vertical, 6)
        .frame(width: 260)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PMColor.bg.opacity(0.68))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
    }

    private func menuHeader(_ song: Song) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 42,
                cornerRadius: 7,
                sourceID: song.sourceID,
                filePath: song.filePath
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.artistName ?? String(localized: "unknown_artist"))
                    .font(.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.textMuted)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.text)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func menuRow(titleText: String, symbol: String,
                         role: ButtonRole? = nil, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(role: role) {
            menuShown = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.textMuted)
                Text(verbatim: titleText)
                    .font(.callout)
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(PMColor.divider)
            .frame(height: 0.5)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
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
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PMColor.bg.opacity(0.70))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func fontPickerRow(_ title: LocalizedStringKey, value: Double) -> some View {
        Button {
            lyricsFontScale = value
            fontPickerShown = false
        } label: {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(PMColor.text)
                Spacer()
                if abs(lyricsFontScale - value) < 0.001 {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
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

    private var goToAlbumTitle: String {
        NSLocalizedString("go_to_album", tableName: nil, bundle: .main, value: "Go to Album", comment: "")
    }

    private var goToArtistTitle: String {
        NSLocalizedString("go_to_artist", tableName: nil, bundle: .main, value: "Go to Artist", comment: "")
    }

    private var playbackSettingsTitle: String {
        NSLocalizedString("playback_settings_title", tableName: nil, bundle: .main, value: "Playback Settings", comment: "")
    }

    private func matchingAlbum(for song: Song) -> Album? {
        if let id = song.albumID,
           let album = library.visibleAlbums.first(where: { $0.id == id }) {
            return album
        }

        guard let title = trimmed(song.albumTitle), !title.isEmpty else { return nil }
        let artistName = trimmed(song.artistName)
        return library.visibleAlbums.first { album in
            guard album.title.localizedCaseInsensitiveCompare(title) == .orderedSame else { return false }
            guard let artistName, !artistName.isEmpty else { return true }
            return (album.artistName ?? "").localizedCaseInsensitiveCompare(artistName) == .orderedSame
        }
    }

    private func matchingArtist(for song: Song) -> Artist? {
        if let id = song.artistID,
           let artist = library.visibleArtists.first(where: { $0.id == id }) {
            return artist
        }

        guard let name = trimmed(song.artistName), !name.isEmpty else { return nil }
        return library.visibleArtists.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MacSleepTimerPopover: View {
    var onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @State private var customMinutes: Double = 30
    @State private var now = Date()

    private let presets = [15, 30, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(presets, id: \.self) { minutes in
                    presetButton(minutes)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    player.scheduleSleepAtTrackEnd()
                    onClose()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        Text("sleep_at_track_end")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        if player.sleepStopAfterSongID != nil {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("自定义 (分钟)")
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                        Spacer()
                        Text("\(Int(customMinutes))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(PMColor.textMuted)
                    }
                    Slider(value: $customMinutes, in: 5...120, step: 5)
                        .tint(PMColor.brand)
                    Button {
                        player.scheduleSleep(minutes: Int(customMinutes))
                        onClose()
                    } label: {
                        Text("设置自定义定时")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(PMColor.brand, in: .rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            footer
        }
        .frame(width: 280)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PMColor.bg.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 22, y: 10)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("睡眠定时器")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text("P-14 · SleepTimerService")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func presetButton(_ minutes: Int) -> some View {
        let selected = selectedPreset == minutes
        return Button {
            player.scheduleSleep(minutes: minutes)
            onClose()
        } label: {
            Text("\(minutes) \(String(localized: "minutes"))")
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : PMColor.text)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(selected ? PMColor.brand : PMColor.glassBtn, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? .clear : PMColor.cardBorder, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(player.isSleepTimerActive ? PMColor.brand : PMColor.textFaint)
                .lineLimit(1)
            Spacer()
            if player.isSleepTimerActive {
                Button {
                    player.cancelSleep()
                    onClose()
                } label: {
                    Text("cancel_timer")
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.bad)
                        .frame(height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var selectedPreset: Int? {
        guard let end = player.sleepTimerEndDate else { return nil }
        let minutes = Int(round(end.timeIntervalSince(now) / 60.0))
        return presets.min(by: { abs($0 - minutes) < abs($1 - minutes) })
            .flatMap { abs($0 - minutes) <= 1 ? $0 : nil }
    }

    private var statusText: String {
        if let end = player.sleepTimerEndDate {
            let remaining = max(0, Int(end.timeIntervalSince(now)))
            return "剩余 \(TimeInterval(remaining).formattedDuration)"
        }
        if player.sleepStopAfterSongID != nil {
            return "当前歌曲结束后停止"
        }
        return "未启用"
    }
}
#endif
