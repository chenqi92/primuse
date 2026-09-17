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
    let shareLyrics: () -> Void
    let showCastPicker: () -> Void
    let toggleLyricsTranslation: () -> Void
    let showSleepTimer: () -> Void
    let delete: () -> Void
}

/// 播放页「更多」的分组面板(`SkinSlotVariant.PlayerStage.sheetActions`)。
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

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 16)

                quickTiles

                sectionTitle("now_playing_panel_song_section")
                LazyVGrid(columns: columns, spacing: 8) {
                    cell("add_to_playlist", "text.badge.plus", enabled: snapshot.hasSong, actions.addToPlaylist)
                    cell("similar_songs", "sparkles", enabled: snapshot.hasSong, actions.showSimilarSongs)
                    cell("lyric_poster_menu", "text.below.photo", enabled: snapshot.canShareLyrics, actions.shareLyrics)
                    if snapshot.canShare {
                        cell("share", "square.and.arrow.up", enabled: true, actions.share)
                    }
                    cell("song_info", "info.circle", enabled: snapshot.hasSong, actions.showSongInfo)
                    if snapshot.canOpenAlbum {
                        cell("go_to_album", "square.stack", enabled: true, actions.openAlbum)
                    }
                    if snapshot.canOpenArtist {
                        cell("go_to_artist", "music.mic", enabled: true, actions.openArtist)
                    }
                    if snapshot.appleMusicCatalogURL != nil {
                        cell("apple_music_open_in_app", "arrow.up.right.square", enabled: true, actions.openInAppleMusic)
                    }
                }

                sectionTitle("now_playing_panel_manage_section")
                LazyVGrid(columns: columns, spacing: 8) {
                    cell(
                        "scrape_song",
                        "wand.and.stars",
                        enabled: snapshot.hasSong && !snapshot.isScrapingCurrentSong,
                        actions.scrape
                    )
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

                sectionTitle("lyrics_title")
                lyricsSection

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

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentSong?.title ?? "")
                    .font(skin.font(.bodyStrong))
                    .foregroundStyle(.skin(.textPrimary))
                    .lineLimit(1)
                if let song = player.currentSong,
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
