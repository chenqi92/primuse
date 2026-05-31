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
                    symbol: "text.badge.plus",
                    disabled: player.currentSong == nil) {
                showAddToPlaylist = true
            }
            // 相似歌曲 —— 飞出二级浮层 (和字号子菜单一致),点外部自动消失,
            // 不是之前那个没关闭按钮的固定 sheet。整行 hit-testable。
            Button {
                guard player.currentSong != nil else { return }
                showSimilarSongs.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .frame(width: 18)
                        .foregroundStyle(PMColor.textMuted)
                    Text("similar_songs")
                        .font(.callout)
                        .foregroundStyle(PMColor.text)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(PMColor.textFaint)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .pmRowBackground(cornerRadius: 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentSong == nil)
            .popover(isPresented: $showSimilarSongs, arrowEdge: .leading) {
                if let song = player.currentSong {
                    MacSimilarSongsPopover(seed: song) {
                        showSimilarSongs = false
                        menuShown = false
                    }
                }
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
        // 迷你播放器是深色面板, 系统 popover 的半透材质叠在它上面会把菜单染得发灰/
        // 发白、文字对比度很低。铺一层 flat 不透明 bg (不画圆角描边 —— 系统 chrome
        // 已经裁圆角带边框, 自己再画会变双框)。
        .background(PMColor.bg)
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
                        Text(Lz("Custom (minutes)"))
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
                        Text(Lz("Set Custom Timer"))
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
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Lz("Sleep Timer"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
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
            return "\(Lz("Remaining")) \(TimeInterval(remaining).formattedDuration)"
        }
        if player.sleepStopAfterSongID != nil {
            return Lz("Stop After Current Song")
        }
        return Lz("Not Enabled")
    }
}

// MARK: - Similar Songs Popover (相似歌曲浮层)

/// 设计稿「相似歌曲」浮层 —— 从 More 菜单 / 歌曲右键飞出的悬浮面板,点外部
/// 自动消失 (系统 popover 行为),不再是没关闭按钮的固定 sheet。
///
/// 把本地特征相似 (MusicDiscoveryEngine, 看 metadata 重叠) 和 Last.fm 听众
/// 重叠 (看播放行为) 合并成一个按匹配度排序的列表:每行一条匹配进度条 + 0~99
/// 分值,来源是 Apple Music 的标 AM。底部一个整宽「播放相似电台」。
struct MacSimilarSongsPopover: View {
    let seed: Song
    /// 关闭整组浮层 (含父级 More 菜单)。播放后或点外部时调用。
    var onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore

    @State private var lastFmCandidates: [SimilarTracksCandidate] = []
    @State private var isLoadingLastFm = true
    // 缓存计算结果, 不在 body 里实时算。否则 `rows` 每次 body 重算都会跑一遍全库
    // 相似度 (MusicDiscoveryEngine.similarSongs over 全库); 回填/播放进度在改
    // library.songs 时 body 又频繁重算 → 滚动时一帧算一次全库, 极卡。
    @State private var localRows: [Row] = []
    @State private var displayRows: [Row] = []

    /// 合并去重后的展示行。`affinity` 统一到 0~1,本地分按软上限折算。
    private struct Row: Identifiable {
        let song: Song
        let affinity: Double
        var id: String { song.id }
        var score: Int { min(99, max(1, Int((affinity * 100).rounded()))) }
    }

    /// 全库相似度计算 (较重) —— 只在 seed 变化时算一次, 结果缓存到 `localRows`。
    private func computeLocalRows() -> [Row] {
        // 本地特征分用 120 作软上限:同专辑 (~46+) 叠到接近满,同艺术家+流派+年代
        // (~84) 折到 0.7 左右,跟 Last.fm 的 0~1 同量级,合并排序才不串味。
        MusicDiscoveryEngine.similarSongs(to: seed, in: library, limit: 30).map { result in
            Row(song: result.song, affinity: min(1.0, max(0.0, result.score / 120.0)))
        }
    }

    /// 合并本地 + Last.fm 候选 (去重 + 排序), 较轻 —— lastFm 加载完后再算一次即可。
    private func mergedRows() -> [Row] {
        var byID: [String: Row] = [:]
        for row in localRows {
            if row.affinity >= (byID[row.song.id]?.affinity ?? -1) {
                byID[row.song.id] = row
            }
        }
        for candidate in lastFmCandidates {
            guard let song = candidate.librarySong else { continue }
            let affinity = min(1.0, max(0.0, candidate.match))
            if affinity >= (byID[song.id]?.affinity ?? -1) {
                byID[song.id] = Row(song: song, affinity: affinity)
            }
        }
        return byID.values.sorted {
            $0.affinity != $1.affinity
                ? $0.affinity > $1.affinity
                : $0.song.title.localizedCompare($1.song.title) == .orderedAscending
        }
    }

    private var subtitle: String {
        let source = lastFmCandidates.isEmpty ? String(localized: "library") : "Last.fm"
        return String(format: String(localized: "similar_subtitle_format"), seed.title, source)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            content
            divider
            footer
        }
        .frame(width: 320)
        // 跟主菜单一致: 铺 flat 不透明底, 避免半透材质叠深色背景发灰 (不画圆角边框)。
        .background(PMColor.bg)
        .task(id: seed.id) {
            localRows = computeLocalRows()
            displayRows = mergedRows()
            await loadLastFm()
            // Last.fm 候选加载完后再合并一次 (SimilarTracksCandidate 非 Equatable,
            // 不走 onChange, 直接在这里重算)。
            displayRows = mergedRows()
        }
    }

    private var divider: some View {
        Rectangle().fill(PMColor.divider).frame(height: 0.5)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("similar_songs")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private var content: some View {
        if displayRows.isEmpty {
            VStack(spacing: 8) {
                if isLoadingLastFm {
                    ProgressView().controlSize(.small)
                    Text("similar_loading")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(PMColor.textFaint)
                    Text("similar_empty")
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(displayRows) { row in
                        rowView(row)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            .scrollIndicators(.hidden)
            // 系统「总是显示滚动条」时直接在底层 NSScrollView 上隐藏。
            .pmForceHideScrollers()
        }
    }

    private func rowView(_ row: Row) -> some View {
        Button {
            play(row.song)
        } label: {
            HStack(spacing: 10) {
                CachedArtworkView(
                    coverRef: row.song.coverArtFileName,
                    songID: row.song.id,
                    size: 38,
                    cornerRadius: 6,
                    sourceID: row.song.sourceID,
                    filePath: row.song.filePath
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.song.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(row.song.artistName ?? String(localized: "unknown_artist"))
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                    matchBar(row.affinity)
                }

                if isAppleMusic(row.song) {
                    Text(verbatim: "AM")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PMColor.bad)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(PMColor.bad.opacity(0.14), in: Capsule())
                }

                Text("\(row.score)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func matchBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PMColor.divider)
                Capsule()
                    .fill(PMColor.brand)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .padding(.top, 1)
    }

    private var footer: some View {
        Button {
            playRadio()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("play_similar_radio")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(PMColor.brand, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(displayRows.isEmpty)
        .opacity(displayRows.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func isAppleMusic(_ song: Song) -> Bool {
        guard let type = sourcesStore.source(id: song.sourceID)?.type else { return false }
        return type == .appleMusic || type == .appleMusicLibrary
    }

    private func play(_ song: Song) {
        let tail = displayRows.map(\.song).filter { $0.id != song.id }
        let queue = ([song] + tail).filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        onClose()
        Task { await player.play(song: first) }
    }

    private func playRadio() {
        let queue = MusicDiscoveryEngine.songRadio(from: seed, in: library, limit: 48)
            .map(\.song)
            .filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        onClose()
        Task { await player.play(song: first) }
    }

    private func loadLastFm() async {
        isLoadingLastFm = true
        guard !LastFmCredentialsStore.effectiveAPIKey().isEmpty else {
            isLoadingLastFm = false
            return
        }
        let service = AppServices.shared.similarTracks
        let pool = library.visibleSongs
        do {
            lastFmCandidates = try await service.fetchSimilar(
                to: seed,
                limit: 30,
                library: pool,
                includeUnmatched: false
            )
        } catch {
            lastFmCandidates = []
        }
        isLoadingLastFm = false
    }
}
#endif
