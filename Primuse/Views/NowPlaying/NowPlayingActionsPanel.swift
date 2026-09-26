#if os(iOS)
import PrimuseKit
import SwiftUI

/// 播放页「更多」里的全部动作。系统菜单与分组面板两种呈现方式消费的是同一份。
struct NowPlayingMoreActions {
    let enterFullScreen: () -> Void
    let addToPlaylist: () -> Void
    let scrape: () -> Void
    let reloadLyricsFromSource: () -> Void
    let showSimilarSongs: () -> Void
    let editTags: () -> Void
    let editLyrics: () -> Void
    let showSongInfo: () -> Void
    let openAlbum: () -> Void
    let openArtist: () -> Void
    let openInAppleMusic: () -> Void
    let share: () -> Void
    let showCastPicker: () -> Void
    let toggleLyricsTranslation: () -> Void
    let showSleepTimer: () -> Void
    let delete: () -> Void
    /// 只在传输键那一行放不下随机 / 循环时(手机窄横屏)用得上,由快照的
    /// `showsPlaybackModeActions` 决定露不露。
    let toggleShuffle: () -> Void
    let cycleRepeatMode: () -> Void
    /// 有声内容:目录与书签、转到这本书。
    let showChapterList: () -> Void
    let openBook: () -> Void
    let startKaraoke: () -> Void
    let startMedley: () -> Void
    let continueMedleySongInFull: () -> Void
    /// iPhone Duo 竖栏那一列放不下时收进来的几颗(快照的 `columnOverflow`)。
    let toggleLike: () -> Void
    let showEffectPicker: () -> Void
    let lockControls: () -> Void
}

/// 播放页「更多」的分组面板(`SkinSurfaceVariant.Player.sheetActions`)。
///
/// 内容与系统菜单完全一致:同一份快照决定哪些项出现、哪些项置灰,同一组闭包负责执行。
/// 差别只在组织方式 —— 睡眠定时、播放速度、投屏、全屏这几样常用的提到第一排,
/// 其余按「这首歌 / 整理 / 歌词」分组,不用再在一长条菜单里上下找。
struct NowPlayingActionsPanel: View {
    let snapshot: NowPlayingMoreMenuSnapshot
    @Binding var lyricsFontScale: Double
    @Binding var playbackRate: Float
    @Binding var lyricsMotionEnabled: Bool
    let actions: NowPlayingMoreActions
    /// 会打开别的面板或页面的动作走这里:先收起本面板,收起完成后再执行,
    /// 否则两个面板同时呈现,后一个会被系统丢掉。
    let performAfterDismiss: (@escaping () -> Void) -> Void

    @Environment(\.skin) private var skin
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]
    private let iconColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 16)

                quickTiles

                columnOverflowRow

                playbackModeRow

                playModesRow

                sectionTitle("now_playing_panel_song_section")
                // 「这首歌」这一组是一排圆形图标:都是一步就走的动作,认图标比读长条快。
                // 无障碍字号下文字放不进图标底下,回到两列长条。
                LazyVGrid(
                    columns: dynamicTypeSize.isAccessibilitySize ? columns : iconColumns,
                    spacing: dynamicTypeSize.isAccessibilitySize ? 8 : 14
                ) {
                    songCell("add_to_playlist", "text.badge.plus", enabled: snapshot.hasSong, actions.addToPlaylist)
                    if !snapshot.isSpokenWord {
                        songCell("similar_songs", "sparkles", enabled: snapshot.hasSong, actions.showSimilarSongs)
                    }
                    if snapshot.canShare {
                        songCell("share", "square.and.arrow.up", enabled: true, actions.share)
                    }
                    songCell("song_info", "info.circle", enabled: snapshot.hasSong, actions.showSongInfo)
                    // 有声内容:「转到专辑 / 艺术家」换成这本书的目录与书页,和系统菜单一个口径。
                    if snapshot.isSpokenWord {
                        if snapshot.hasChapterList {
                            songCell("spoken_word_chapters_and_bookmarks", "list.bullet.indent", enabled: true, actions.showChapterList)
                        }
                        if snapshot.canOpenBook {
                            songCell("spoken_word_go_to_book", "books.vertical", enabled: true, actions.openBook)
                        }
                    } else {
                        if snapshot.canOpenAlbum {
                            songCell("go_to_album", "square.stack", enabled: true, actions.openAlbum)
                        }
                        if snapshot.canOpenArtist {
                            songCell("go_to_artist", "music.mic", enabled: true, actions.openArtist)
                        }
                    }
                    if snapshot.appleMusicCatalogURL != nil {
                        songCell("apple_music_open_in_app", "arrow.up.right.square", enabled: true, actions.openInAppleMusic)
                    }
                }

                sectionTitle("now_playing_panel_manage_section")
                LazyVGrid(columns: columns, spacing: 8) {
                    if !snapshot.isSpokenWord {
                        cell(
                            "scrape_song",
                            "wand.and.stars",
                            enabled: snapshot.hasSong && !snapshot.isScrapingCurrentSong,
                            actions.scrape
                        )
                    }
                    if !snapshot.isAppleMusicMode {
                        cell("tag_editor_menu", "tag", enabled: snapshot.hasSong, actions.editTags)
                        cell("lyrics_editor_menu", "quote.bubble", enabled: snapshot.hasSong, actions.editLyrics)
                    }
                    if snapshot.canReloadLyricsFromSource {
                        cell(
                            "lyrics_reload_from_source",
                            "arrow.clockwise.circle",
                            enabled: !snapshot.isReloadingLyricsFromSource,
                            actions.reloadLyricsFromSource
                        )
                    }
                }

                // 有声内容没有歌词动效,字号与翻译也只在看文字稿时给;都没有时整组不出现。
                if !snapshot.isSpokenWord || snapshot.showsLyricsPreferences {
                    sectionTitle("lyrics_title")
                    lyricsSection
                }

                if snapshot.canDeleteSourceFile {
                    Button {
                        performAfterDismiss(actions.delete)
                    } label: {
                        cellLabel("delete_song", "trash", tint: skin.color(.danger))
                    }
                    .buttonStyle(.plain)
                    .disabled(!snapshot.hasSong)
                    .opacity(snapshot.hasSong ? 1 : 0.4)
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(skin.color(.canvasElevated))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            if snapshot.isSpokenWord {
                // 书是竖的:同一块槽位里放 3:4 的书封。
                SpokenWordBookCover(
                    song: player.currentSong,
                    width: SpokenWordCoverLayout.width(forHeight: 48),
                    cornerRadius: skin.rawMetric(.radiusArtwork),
                    decodeSize: 96
                )
                .frame(width: 48, height: 48)
            } else {
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: 48,
                    cornerRadius: skin.rawMetric(.radiusArtwork) + 2,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath,
                    fileFormat: player.currentSong?.fileFormat,
                    revisionToken: player.coverRevision
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.isSpokenWord ? SpokenWordPlayerText.bookTitle(player) : (player.currentSong?.title ?? ""))
                    .font(skin.font(.bodyStrong))
                    .foregroundStyle(.skin(.textPrimary))
                    .lineLimit(1)
                if snapshot.isSpokenWord {
                    if let part = SpokenWordPlayerText.partTitle(player) {
                        Text(part)
                            .font(skin.font(.caption))
                            .foregroundStyle(.skin(.textSecondary))
                            .lineLimit(1)
                    }
                } else if let song = player.currentSong,
                   let artist = library.artistDisplayName(for: song),
                   !artist.isEmpty {
                    Text(artist)
                        .font(skin.font(.caption))
                        .foregroundStyle(.skin(.textSecondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 第一排

    private var quickTiles: some View {
        HStack(spacing: 8) {
            Button {
                performAfterDismiss(actions.showSleepTimer)
            } label: {
                tile(
                    snapshot.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz",
                    title: Text("sleep_timer"),
                    value: Text(snapshot.isSleepTimerActive ? "a11y_value_on" : "a11y_value_off"),
                    highlighted: snapshot.isSleepTimerActive
                )
            }
            .buttonStyle(.plain)

            if !snapshot.isAppleMusicMode {
                Menu {
                    Picker(selection: $playbackRate) {
                        Text(verbatim: "0.5×").tag(Float(0.5))
                        Text(verbatim: "0.75×").tag(Float(0.75))
                        Text("playback_rate_normal").tag(Float(1.0))
                        Text(verbatim: "1.25×").tag(Float(1.25))
                        Text(verbatim: "1.5×").tag(Float(1.5))
                        Text(verbatim: "1.75×").tag(Float(1.75))
                        Text(verbatim: "2.0×").tag(Float(2.0))
                    } label: {
                        Text("playback_rate")
                    }
                } label: {
                    tile(
                        "speedometer",
                        title: Text("playback_rate"),
                        value: Text(verbatim: Self.rateText(snapshot.playbackRate)),
                        highlighted: snapshot.playbackRate != 1
                    )
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.canChangePlaybackRate)
                .opacity(snapshot.canChangePlaybackRate ? 1 : 0.4)
            }

            Button {
                performAfterDismiss(actions.showCastPicker)
            } label: {
                tile(
                    "airplayaudio",
                    title: Text("cast_to_device"),
                    value: snapshot.castingRendererName.map { Text(verbatim: $0) } ?? Text("cast_local_device"),
                    highlighted: snapshot.castingRendererName != nil
                )
            }
            .buttonStyle(.plain)
            .disabled(!snapshot.hasSong || snapshot.isAppleMusicMode)
            .opacity(!snapshot.hasSong || snapshot.isAppleMusicMode ? 0.4 : 1)

            if snapshot.showsFullScreenAction {
                Button {
                    performAfterDismiss(actions.enterFullScreen)
                } label: {
                    tile(
                        "viewfinder.rectangular",
                        title: Text("full_screen_player"),
                        value: nil,
                        highlighted: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(!snapshot.hasSong)
                .opacity(snapshot.hasSong ? 1 : 0.4)
            }
        }
    }

    /// 手机窄横屏下传输键那一行放不下随机与循环,面板补上这两项;其余场合整行不出现。
    /// 两者都是就地切换,不收起面板 —— 状态就在按钮上,连着点两下才看得出循环的三档。
    @ViewBuilder
    private var playbackModeRow: some View {
        if snapshot.showsPlaybackModeActions {
            LazyVGrid(columns: columns, spacing: 8) {
                Button(action: actions.toggleShuffle) {
                    cellLabel(
                        "shuffle",
                        snapshot.isShuffleEnabled ? "shuffle.circle.fill" : "shuffle",
                        tint: snapshot.isShuffleEnabled ? skin.color(.accent) : nil
                    )
                }
                .buttonStyle(.plain)

                Button(action: actions.cycleRepeatMode) {
                    cellLabel(
                        "repeat",
                        Self.repeatSymbol(for: snapshot.repeatMode),
                        tint: snapshot.repeatMode == .off ? nil : skin.color(.accent)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
    }

    /// iPhone Duo 竖栏那一列放不下时收进来的按钮(锁、全屏效果、喜欢),与系统菜单里那一组相同。
    /// 喜欢就地切换,不收起面板;另外两样会换掉播放页的状态,收起面板后再做。
    @ViewBuilder
    private var columnOverflowRow: some View {
        let overflow = snapshot.columnOverflow
        if !overflow.isEmpty {
            LazyVGrid(columns: columns, spacing: 8) {
                if overflow.like {
                    Button(action: actions.toggleLike) {
                        cellLabel(
                            snapshot.isCurrentLiked ? "a11y_unlike" : "a11y_like",
                            snapshot.isCurrentLiked ? "heart.fill" : "heart",
                            tint: snapshot.isCurrentLiked ? skin.color(.accent) : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!snapshot.hasSong)
                    .opacity(snapshot.hasSong ? 1 : 0.4)
                }
                if overflow.effect {
                    cell("fullscreen_effect_settings_title", "viewfinder.rectangular", enabled: true, actions.showEffectPicker)
                }
                if overflow.lock {
                    cell("immersive_lock_controls", "lock", enabled: true, actions.lockControls)
                }
            }
            .padding(.top, 8)
        }
    }

    /// 卡拉OK 与串烧:和系统菜单一样,只在这首歌能这么玩时出现。
    @ViewBuilder
    private var playModesRow: some View {
        let showsMedley = snapshot.isMedleyActive || snapshot.canStartMedley
        if snapshot.canStartKaraoke || showsMedley {
            LazyVGrid(columns: columns, spacing: 8) {
                if snapshot.canStartKaraoke {
                    cell("karaoke_title", "music.mic.circle", enabled: true, actions.startKaraoke)
                }
                if snapshot.isMedleyActive {
                    cell("medley_continue_full", "music.note", enabled: true, actions.continueMedleySongInFull)
                } else if snapshot.canStartMedley {
                    cell("medley_play_selection", "rectangle.stack.badge.play", enabled: true, actions.startMedley)
                }
            }
            .padding(.top, 8)
        }
    }

    /// 循环模式当前状态对应的图标,与系统菜单里那份保持一致。
    private static func repeatSymbol(for mode: RepeatMode) -> String {
        switch mode {
        case .off: return "repeat"
        case .all: return "repeat.circle.fill"
        case .one: return "repeat.1.circle.fill"
        }
    }

    private func tile(_ systemImage: String, title: Text, value: Text?, highlighted: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: skin.rawMetric(.radiusLarge), style: .continuous)
        return VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(highlighted ? skin.color(.accent) : skin.color(.textPrimary))
            title
                .font(skin.font(.caption))
                .fontWeight(.semibold)
                .foregroundStyle(.skin(.textPrimary))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let value {
                value
                    .font(skin.font(.meta))
                    .foregroundStyle(.skin(.textSecondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(highlighted ? skin.color(.accentSoft) : skin.color(.surface), in: shape)
        .overlay {
            shape.strokeBorder(
                highlighted ? skin.color(.accentMuted) : skin.color(.surfaceBorder),
                lineWidth: skin.rawMetric(.borderWidth)
            )
        }
        .contentShape(shape)
    }

    private static func rateText(_ rate: Float) -> String {
        let hundredths = Int((rate * 100).rounded())
        return hundredths % 10 == 0
            ? String(format: "%.1f×", Double(hundredths) / 100)
            : String(format: "%.2f×", Double(hundredths) / 100)
    }

    // MARK: - 歌词

    @ViewBuilder
    private var lyricsSection: some View {
        VStack(spacing: 8) {
            if snapshot.showsLyricsPreferences {
                LazyVGrid(columns: columns, spacing: 8) {
                    Menu {
                        Picker(selection: $lyricsFontScale) {
                            Text("lyrics_font_small").tag(0.85)
                            Text("lyrics_font_medium").tag(1.0)
                            Text("lyrics_font_large").tag(1.2)
                            Text("lyrics_font_xlarge").tag(1.5)
                        } label: {
                            Text("lyrics_font_size")
                        }
                    } label: {
                        cellLabel("lyrics_font_size", "textformat.size", tint: nil)
                    }
                    .buttonStyle(.plain)

                    Button(action: actions.toggleLyricsTranslation) {
                        cellLabel(
                            snapshot.isLyricsTranslationEnabled ? "lyrics_translation_off" : "lyrics_translation_on",
                            snapshot.isLyricsTranslationEnabled ? "character.bubble.fill" : "character.bubble",
                            tint: snapshot.isLyricsTranslationEnabled ? skin.color(.accent) : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !snapshot.isSpokenWord {
                Toggle(isOn: $lyricsMotionEnabled) {
                    Label("immersive_lyrics_motion_title", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(skin.font(.callout))
                        .foregroundStyle(.skin(.textPrimary))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(
                    skin.color(.surface),
                    in: RoundedRectangle(cornerRadius: skin.rawMetric(.radiusCard), style: .continuous)
                )
            }
        }
    }

    // MARK: - 单元

    private func sectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(skin.font(.caption))
            .fontWeight(.semibold)
            .foregroundStyle(.skin(.textTertiary))
            .padding(.top, 18)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func cell(
        _ titleKey: LocalizedStringKey,
        _ systemImage: String,
        enabled: Bool,
        _ action: @escaping () -> Void
    ) -> some View {
        Button {
            performAfterDismiss(action)
        } label: {
            cellLabel(titleKey, systemImage, tint: nil)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// 「这首歌」一组的格子:平时是圆形图标加一行字,无障碍字号下回到长条。
    @ViewBuilder
    private func songCell(
        _ titleKey: LocalizedStringKey,
        _ systemImage: String,
        enabled: Bool,
        _ action: @escaping () -> Void
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            cell(titleKey, systemImage, enabled: enabled, action)
        } else {
            Button {
                performAfterDismiss(action)
            } label: {
                VStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.skin(.textPrimary))
                        .frame(width: 54, height: 54)
                        .background(skin.color(.surface), in: Circle())
                        .overlay {
                            Circle().strokeBorder(skin.color(.surfaceBorder), lineWidth: skin.rawMetric(.borderWidth))
                        }
                    Text(titleKey)
                        .font(skin.font(.meta))
                        .fontWeight(.semibold)
                        .foregroundStyle(.skin(.textPrimary))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }

    private func cellLabel(_ titleKey: LocalizedStringKey, _ systemImage: String, tint: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: skin.rawMetric(.radiusCard), style: .continuous)
        return HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint ?? skin.color(.textSecondary))
                .frame(width: 22)
            Text(titleKey)
                .font(skin.font(.callout))
                .foregroundStyle(tint ?? skin.color(.textPrimary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(skin.color(.surface), in: shape)
        .overlay {
            shape.strokeBorder(skin.color(.surfaceBorder), lineWidth: skin.rawMetric(.borderWidth))
        }
        .contentShape(shape)
    }
}
#endif
