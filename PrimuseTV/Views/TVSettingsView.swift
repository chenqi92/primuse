#if os(tvOS)
import Intents
import SwiftUI
import PrimuseKit

private var tvDebugShowsEffectPicker: Bool {
    #if DEBUG
    TVDebugLaunch.screen == "effectPicker"
    #else
    false
    #endif
}

private var tvDebugShowsThemePicker: Bool {
    #if DEBUG
    TVDebugLaunch.screen == "themePicker"
    #else
    false
    #endif
}

/// 截图:TV_SCREEN=playerBackdrop 直接打开「播放页背景」。
private var tvDebugShowsBackdropSettings: Bool {
    #if DEBUG
    TVDebugLaunch.screen == "playerBackdrop"
    #else
    false
    #endif
}

/// 截图:TV_SCREEN=diagnostics 直接打开「诊断报告」。
private var tvDebugShowsDiagnostics: Bool {
    #if DEBUG
    TVDebugLaunch.screen == "diagnostics"
    #else
    false
    #endif
}

/// 截图:TV_SCREEN=scrobble 直接打开「听歌记录」。
private var tvDebugShowsScrobbleSettings: Bool {
    #if DEBUG
    TVDebugLaunch.screen == "scrobble"
    #else
    false
    #endif
}

/// 截图 / 取证:TV_SCREEN=settings 配 TV_SCRAPE_DEBUG=settings 直接打开刮削设置。
private var tvDebugShowsScraperSettings: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["TV_SCRAPE_DEBUG"] == "settings"
    #else
    false
    #endif
}

struct TVSettingsView: View {
    @State private var replayGain = TVReplayGainSettings.shared
    @AppStorage(PlayerAppearancePreferences.showsReplayGainBadgeKey)
    private var showsReplayGainBadge = PlayerAppearancePreferences.showsReplayGainBadgeByDefault
    @AppStorage(LibraryRowNumberPreferences.storageKey)
    private var showsRowNumbers = LibraryRowNumberPreferences.defaultValue
    @AppStorage(WordLyricsDiscoveryPreferences.enabledKey)
    private var exploresWordLyrics = WordLyricsDiscoveryPreferences.enabledByDefault
    @AppStorage(WordLyricsDiscoveryPreferences.showsActivityKey)
    private var showsActivity = WordLyricsDiscoveryPreferences.showsActivityByDefault
    @Environment(TVStore.self) private var store
    @Environment(TVAppearanceState.self) private var appearanceState
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onNavigate: (TVRoot.Tab) -> Void = { _ in }
    @AppStorage("tvAutoSync") private var autoSync = true
    /// 与 iOS / macOS 同一个键、同一个默认值。CloudKit 在账号退出或切换时会把它
    /// 强制关掉,Apple TV 上必须有地方能再打开。
    @AppStorage(CloudSyncChannel.masterDefaultsKey) private var iCloudSyncEnabled = true
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.colorModeKey)
    private var themeColorModeRawValue = AppThemePreferences.colorMode().rawValue
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient
    @AppStorage(AppThemePreferences.ambientStrengthKey)
    private var ambientStrength = AppThemePreferences.defaultAmbientStrength
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var immersiveEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @AppStorage(MissingArtworkStyle.storageKey) private var missingArtworkStyle = MissingArtworkStyle.standard.rawValue
    @State private var showsDefaultArtworkPicker = false
    @AppStorage(PlayerAppearancePreferences.animatedArtworkEnabledKey)
    private var animatedArtworkEnabled = PlayerAppearancePreferences.animatedArtworkEnabledByDefault
    /// 和 iPhone、Mac 同一个键,经 iCloud 键值同步(启动时在 App 里登记)。
    @AppStorage(PlayerAppearancePreferences.simulatesWordLyricsKey)
    private var simulatesWordLyrics = PlayerAppearancePreferences.simulatesWordLyricsByDefault
    @AppStorage(PlayerAppearancePreferences.showsLyricsInterludeKey)
    private var showsLyricsInterlude = PlayerAppearancePreferences.showsLyricsInterludeByDefault
    @AppStorage(PlayerAppearancePreferences.showsLyricsInterludeAlwaysKey)
    private var showsLyricsInterludeAlways = PlayerAppearancePreferences.showsLyricsInterludeAlwaysByDefault
    @AppStorage(PlayerAppearancePreferences.showsAlbumInSubtitleKey)
    private var showsAlbumInSubtitle = PlayerAppearancePreferences.showsAlbumInSubtitleByDefault
    @AppStorage(TVStore.autoContinueSimilarKey) private var autoContinueSimilar = true
    @AppStorage(TVStore.previousRestartsCurrentSongKey) private var previousRestartsCurrentSong = true
    @AppStorage(TVStore.spokenWordSmartRewindEnabledKey)
    private var spokenWordSmartRewind = SpokenWordSmartRewindPolicy.enabledByDefault
    @AppStorage(TVStore.spokenWordSmartRewindLimitKey)
    private var spokenWordSmartRewindLimit = SpokenWordSmartRewindPolicy.defaultLimit
    @AppStorage(TVStore.shufflePreferenceKey) private var shufflePreferenceRawValue = ShufflePreference.defaultValue.rawValue
    @AppStorage(TVAudioEngine.matchSongSampleRateKey) private var matchSongSampleRate = false
    @AppStorage(TVHomeSceneRow.nightSleepTimerKey) private var nightSceneSleepTimer = true
    @AppStorage(LibraryReviewPreferences.enabledKey)
    private var ratingsAndCommentsEnabled = false
    @State private var showsEffectPicker = tvDebugShowsEffectPicker
    @State private var showsThemePicker = tvDebugShowsThemePicker
    @State private var showsAppIconPicker = false
    @State private var showsHiddenAppIcons = false
    @State private var iconEasterEgg = AppIconEasterEggTrigger()
    @State private var showsAISettings = false
    @State private var showsDiagnostics = tvDebugShowsDiagnostics
    /// 诊断模式开着时「诊断报告」那一行写「已启用」,提醒还在多记日志。
    @State private var diagnosticModeActive = FileLogger.isDiagnosticModeActive
    @State private var siriAuthorization = TVSiriAuthorizationRuntime.status
    @State private var showsMetadata = false
    /// 删逐字对齐模型前先确认，和 iPhone、Mac 一样：删了要重新下载。
    @State private var confirmsWordAlignmentModelRemoval = false
    @State private var showsScraperSettings = tvDebugShowsScraperSettings
    @State private var showsScrobbleSettings = tvDebugShowsScrobbleSettings
    @State private var showsMedleySettings = false
    @State private var showsTabBarSettings = false
    @State private var showsHomeSectionsSettings = false
    @AppStorage(TVHomeSectionConfiguration.storageKey) private var homeSectionsRawValue = ""
    @State private var showsBackdropSettings = tvDebugShowsBackdropSettings
    @State private var backdropSettings = PlayerBackdropSettingsStore.shared
    @State private var showsBackdropCache = false
    @State private var backdropCache = TVAlbumBackdropCache.shared
    @AppStorage(TVTabBarConfiguration.storageKey) private var tabBarConfigurationRawValue = ""
    @State private var isSyncing = false
    @State private var syncMsg: String?
    @State private var artistNameSettings = ArtistNameSettingsStore.shared
    @AppStorage(GenreSplitPreference.storageKey) private var genreSeparatorsRaw = 0

    private func genreSeparatorBinding(_ option: GenreSeparatorOptions) -> Binding<Bool> {
        Binding(
            get: { GenreSeparatorOptions(rawValue: genreSeparatorsRaw).contains(option) },
            set: { isOn in
                var options = GenreSeparatorOptions(rawValue: genreSeparatorsRaw)
                if isOn { options.insert(option) } else { options.remove(option) }
                genreSeparatorsRaw = options.rawValue
            }
        )
    }
    @State private var translationSettings = LyricsTranslationSettingsStore.shared
    @State private var romanizationSettings = LyricsRomanizationSettingsStore.shared
    @State private var googleRomanizationAccount = GoogleCloudRomanizationAccount.shared
    @State private var showsTranslationPanel = false
    @State private var appleMusic = TVAppleMusicCatalog()
    /// 焦点停在哪一行。行在得到焦点时写它,只有右栏的说明卡读它:整页 body 不随焦点重算。
    @State private var focusContext = TVSettingsFocusContext()

    private var immersiveEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: immersiveEffectRawValue) ?? .defaultValue
    }

    private var version: String { TVSettingsAppInfo.version }
    private var build: String { TVSettingsAppInfo.build }
    private var osVersion: String { TVSettingsAppInfo.osVersion }
    private var libraryStat: String {
        !store.hasRealLibrary ? PMString("ext.tv.settings.notSynced") :
            PMString("ext.tv.settings.libraryStat", TVFmt.count(store.songs.count), store.albums.count, store.artists.count)
    }
    private var syncValue: String {
        if isSyncing { return PMString("ext.tv.settings.syncing") }
        if let syncMsg { return syncMsg }
        // 总开关关着时别再写「点按拉取最新曲库」—— 点了也不会拉。
        return iCloudSyncEnabled
            ? PMString("ext.tv.settings.tapToPull")
            : PMString("ext.tv.settings.syncDisabled")
    }
    private var artistRulesValue: String {
        PMString(
            "artist_name_settings_tv_summary",
            artistNameSettings.configuration.separators.count,
            artistNameSettings.configuration.protectedNames.count
        )
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            // 只有左栏滚动;右栏(遥控提示 + 焦点这一项的说明)固定在屏幕上。
            // 左右留白放在滚动区里面,面板的阴影不会被滚动区裁掉。
            HStack(alignment: .top, spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(PMString("ext.tv.settings.eyebrow"))
                            .tvFont(.pageTitle)
                            .foregroundStyle(TVColor.text)
                            .padding(.bottom, 24)
                        settingsSection(String(localized: "sync")) {
                            toggleRow(
                                "icloud",
                                PMString("ext.tv.settings.icloudSyncEnabled"),
                                note: .app("icloud_sync_footer"),
                                kind: .library,
                                isOn: $iCloudSyncEnabled
                            )
                                .onChange(of: iCloudSyncEnabled) { _, value in
                                    // 只改偏好不生效:引擎要跟着起停,与 iOS 的
                                    // CloudSyncSettingsView 做同一件事。
                                    syncMsg = nil   // 上一次的结果对新状态不再成立
                                    Task { await store.setCloudSyncEnabled(value) }
                                }
                            settingDivider
                            navRow(
                                "icloud.fill",
                                PMString("ext.tv.settings.icloudSync"),
                                syncValue,
                                trailing: "arrow.clockwise",
                                note: .app("tv_settings_context_sync_now"),
                                kind: .library,
                                action: sync
                            )
                            settingDivider
                            toggleRow(
                                "arrow.triangle.2.circlepath",
                                PMString("ext.tv.settings.autoSync"),
                                note: .app("tv_settings_context_auto_sync"),
                                kind: .library,
                                isOn: $autoSync
                            )
                        }
                        settingsSection(String(localized: "appearance")) {
                            appearanceRow()
                            settingDivider
                            navRow("app", String(localized: "app_icon"),
                                   AppIconService.shared.availableOptions.first {
                                       $0.id == AppIconService.shared.currentIconID
                                   }?.displayName ?? String(localized: "icon_default"),
                                   note: .app("tv_settings_context_app_icon"),
                                   kind: .appIcon) {
                                showsAppIconPicker = true
                            }
                            settingDivider
                            navRow(
                                "paintpalette.fill",
                                PMString("ext.tv.settings.themeColor"),
                                currentThemeTitle,
                                note: .app("tv_settings_context_theme_color"),
                                kind: .themeColor,
                                action: { showsThemePicker = true }
                            )
                            settingDivider
                            toggleRow(
                                "photo.on.rectangle.angled",
                                PMString("ext.tv.settings.coverColor"),
                                note: .app("tv_settings_context_cover_ambient"),
                                isOn: $coverDrivenAmbient
                            )
                            settingDivider
                            ambientIntensityRow()
                            settingDivider
                            navRow(
                                "photo.on.rectangle",
                                String(localized: "player_backdrop_title"),
                                TVPlayerBackdropSettingsView.title(backdropSettings.settings.source),
                                note: .app("player_backdrop_footer"),
                                kind: .backdrop,
                                action: { showsBackdropSettings = true }
                            )
                            settingDivider
                            navRow(
                                "menubar.rectangle",
                                PMString("ext.tv.settings.tabBar"),
                                tabBarSummary,
                                note: .kit("ext.tv.settings.tabBar.footer"),
                                kind: .tabBar,
                                action: { showsTabBarSettings = true }
                            )
                            settingDivider
                            navRow(
                                "rectangle.grid.1x2",
                                PMString("ext.tv.settings.homeSections"),
                                TVHomeSectionsSettingsView.summary(homeSectionsRawValue),
                                note: .kit("ext.tv.settings.homeSections.footer"),
                                kind: .homeSections,
                                action: { showsHomeSectionsSettings = true }
                            )
                        }
                        settingsSection(String(localized: "playback")) {
                            toggleRow(
                                "waveform",
                                String(localized: "replay_gain"),
                                note: .app("replay_gain_desc"),
                                isOn: $replayGain.enabled
                            )
                            settingDivider
                            toggleRow("waveform", String(localized: "rg_show_badge"),
                                      note: .app("tv_settings_context_rg_badge"), isOn: Binding(
                                get: { showsReplayGainBadge },
                                set: {
                                    showsReplayGainBadge = $0
                                    CloudKVSSync.shared.markChanged(key: PlayerAppearancePreferences.showsReplayGainBadgeKey)
                                }
                            ))
                            if replayGain.enabled {
                                settingDivider
                                navRow("slider.horizontal.3", String(localized: "rg_mode"),
                                       String(localized: String.LocalizationValue(replayGain.mode.localizationKey)),
                                       trailing: "arrow.triangle.2.circlepath",
                                       note: .app("tv_settings_context_rg_mode")) {
                                    replayGain.mode = Self.next(after: replayGain.mode, in: ReplayGainMode.allCases)
                                }
                                settingDivider
                                preampRow
                            }
                            settingDivider
                            toggleRow(
                                "infinity",
                                String(localized: "auto_continue_similar"),
                                note: .app("auto_continue_similar_footer"),
                                isOn: $autoContinueSimilar
                            )
                            settingDivider
                            // 抽歌偏好按一下换到下一档(#332);随机开着时接下来的歌当场按新偏好重排。
                            navRow(
                                "dice",
                                String(localized: "shuffle_preference_title"),
                                shufflePreference.displayName,
                                trailing: "arrow.triangle.2.circlepath",
                                note: .app("shuffle_preference_footer")
                            ) {
                                store.setShufflePreference(Self.next(after: shufflePreference, in: ShufflePreference.allCases))
                            }
                            .accessibilityIdentifier("tv.playback.shufflePreference")
                            settingDivider
                            toggleRow(
                                "backward.end",
                                String(localized: "previous_restarts_current_song"),
                                detail: String(localized: "previous_restarts_current_song_footer"),
                                isOn: $previousRestartsCurrentSong
                            )
                            settingDivider
                            // 智能回退(#363):有声书、播客停得久,继续时往回退一点。上限按一下换到下一档。
                            toggleRow(
                                "gobackward",
                                String(localized: "spoken_word_smart_rewind"),
                                detail: String(localized: "spoken_word_smart_rewind_desc"),
                                isOn: $spokenWordSmartRewind
                            )
                            if spokenWordSmartRewind {
                                settingDivider
                                navRow(
                                    "clock.arrow.circlepath",
                                    String(localized: "spoken_word_smart_rewind_limit"),
                                    SpokenWordSmartRewindPolicy.limitLabel(
                                        SpokenWordSmartRewindPolicy.clampedLimit(spokenWordSmartRewindLimit)
                                    ),
                                    trailing: "arrow.triangle.2.circlepath",
                                    note: .app("spoken_word_smart_rewind_desc")
                                ) {
                                    spokenWordSmartRewindLimit = Self.next(
                                        after: SpokenWordSmartRewindPolicy.clampedLimit(spokenWordSmartRewindLimit),
                                        in: SpokenWordSmartRewindPolicy.limitChoices
                                    )
                                }
                                .accessibilityIdentifier("tv.playback.smartRewindLimit")
                            }
                            settingDivider
                            toggleRow(
                                "moon.zzz",
                                String(format: String(localized: "listening_scene_night_timer_setting %lld"), ListeningScene.nightSleepTimerMinutes),
                                note: .app("tv_settings_context_night_timer"),
                                isOn: $nightSceneSleepTimer
                            )
                            settingDivider
                            navRow("shuffle", String(localized: "medley_title"),
                                   store.medleyLengthTitle,
                                   note: .app("medley_settings_footer"),
                                   action: { showsMedleySettings = true })
                            settingDivider
                            // 播放时屏幕常亮只在全屏播放画面上起作用,收在这一项打开的沉浸风格里。
                            navRow("sparkles.tv", PMString("ext.tv.settings.immersive"),
                                   immersiveEffect.localizedTitle,
                                   note: .text(immersiveEffect.localizedSubtitle),
                                   action: { showsEffectPicker = true })
                            settingDivider
                            navRow("photo", PMString("default_artwork_title"),
                                   PMString(MissingArtworkStyle(storedValue: missingArtworkStyle).localizationKey),
                                   note: .app("tv_settings_context_default_artwork")) {
                                showsDefaultArtworkPicker = true
                            }
                            settingDivider
                            toggleRow(
                                "photo.stack.fill",
                                PMString("player_animated_artwork"),
                                note: .app("player_animated_artwork_description"),
                                isOn: $animatedArtworkEnabled
                            )
                            settingDivider
                            toggleRow(
                                "square.stack",
                                String(localized: "player_album_in_subtitle"),
                                note: .app("player_album_in_subtitle_description"),
                                isOn: Binding(
                                    get: { showsAlbumInSubtitle },
                                    set: { shows in
                                        showsAlbumInSubtitle = shows
                                        CloudKVSSync.shared.markChanged(key: PlayerAppearancePreferences.showsAlbumInSubtitleKey)
                                    }
                                )
                            )
                            settingDivider
                            toggleRow(
                                "waveform",
                                String(localized: "output_sr_matching"),
                                detail: String(localized: "tv_output_sr_matching_desc"),
                                isOn: $matchSongSampleRate
                            )
                            settingDivider
                            appleMusicRow
                            settingDivider
                            siriRow
                        }
                        lyricsSection
                        lyricsRomanizationSection
                        settingsSection(PMString("ext.tv.settings.library")) {
                            toggleRow(
                                "list.number",
                                String(localized: "library_show_row_numbers"),
                                note: .app("tv_settings_context_row_numbers"),
                                isOn: $showsRowNumbers
                            )
                                .accessibilityIdentifier("library.showRowNumbers")
                            settingDivider
                            toggleRow(
                                "star.bubble",
                                String(localized: "library_review_feature_title"),
                                note: .app("library_review_feature_description"),
                                isOn: $ratingsAndCommentsEnabled
                            )
                            settingDivider
                            navRow("arrow.clockwise", String(localized: "metadata"), PMString("tv_metadata_reread"),
                                   note: .kit("tv_metadata_reread_body")) {
                                showsMetadata = true
                            }
                            settingDivider
                            navRow(
                                "wand.and.stars",
                                String(localized: "metadata_scraping"),
                                TVScraperSettingsView.summary(
                                    enabledCount: store.scraperSettings.enabledSources.count
                                ),
                                note: .app("metadata_scraping_desc"),
                                kind: .scraper
                            ) {
                                showsScraperSettings = true
                            }
                            settingDivider
                            // Last.fm / ListenBrainz,和 iPhone、Mac 同一套上报服务。
                            navRow("waveform.path.ecg", String(localized: "scrobble_title"), TVScrobbleSettingsView.summary,
                                   note: .app("scrobble_overall_footer"), kind: .scrobble) {
                                showsScrobbleSettings = true
                            }
                            .accessibilityIdentifier("tv.settings.scrobble")
                            settingDivider
                            navRow("music.note", PMString("ext.tv.settings.library"), libraryStat, kind: .library) { go(.library) }
                            settingDivider
                            infoRow(
                                "person.2",
                                PMString("artist_name_settings_title"),
                                artistRulesValue + " · " + PMString("artist_name_settings_tv_read_only")
                            )
                            settingDivider
                            toggleRow("square.stack", PMString("artist_name_settings_merge_collaborative_albums"),
                                      note: .app("tv_settings_context_merge_collab"), isOn: Binding(
                                get: { artistNameSettings.configuration.mergesCollaborativeAlbums },
                                set: { artistNameSettings.setMergesCollaborativeAlbums($0) }
                            ))
                            settingDivider
                            toggleRow("square.stack", String(localized: "artist_name_settings_merge_same_named_albums"),
                                      note: .app("tv_settings_context_merge_same_name"), isOn: Binding(
                                get: { artistNameSettings.configuration.mergesSameNamedAlbums },
                                set: { artistNameSettings.setMergesSameNamedAlbums($0) }
                            ))
                            settingDivider
                            toggleRow("guitars", PMString("genre_split_slash"), detail: PMString("genre_split_tv_detail"), isOn: genreSeparatorBinding(.slash))
                            settingDivider
                            toggleRow("guitars", PMString("genre_split_comma"), note: .app("genre_split_tv_detail"),
                                      isOn: genreSeparatorBinding(.comma))
                            settingDivider
                            toggleRow("guitars", PMString("genre_split_bar"), note: .app("genre_split_tv_detail"),
                                      isOn: genreSeparatorBinding(.bar))
                            settingDivider
                            navRow("music.note.list", PMString("ext.tv.settings.playlists"),
                                   PMString("ext.tv.countOnly", store.playlistCount), kind: .library) { go(.playlists) }
                            settingDivider
                            navRow("server.rack", PMString("ext.tv.settings.sources"),
                                   PMString("ext.tv.countOnly", store.sourceCount),
                                   note: .app("tv_settings_context_sources"), kind: .sources) { go(.sources) }
                            if intelligence.shouldExposeRemoteConfiguration {
                                settingDivider
                                navRow(
                                    "sparkles",
                                    PMString("ext.tv.settings.intelligence"),
                                    PMString(
                                        intelligence.isSemanticSearchConfigured
                                            ? "ext.tv.settings.intelligence.ready"
                                            : "ext.tv.settings.intelligence.setup"
                                    ),
                                    note: .app("tv_settings_context_intelligence"),
                                    action: { showsAISettings = true }
                                )
                            }
                        }
                        settingsSection(String(localized: "storage_management")) {
                            navRow("photo.stack", String(localized: "player_backdrop_cache_title"),
                                   ByteCountFormatter.string(fromByteCount: backdropCache.usage.reduce(0) { $0 + $1.bytes },
                                                             countStyle: .file),
                                   note: .app("tv_settings_context_backdrop_cache"), kind: .backdropCache) {
                                showsBackdropCache = true
                            }
                            .accessibilityIdentifier("tv.settings.storage.backdropCache")
                        }
                        settingsSection(String(localized: "about")) {
                            navRow("star.bubble", PMString("rate_on_app_store"), "App Store", trailing: "arrow.up.right",
                                   note: .app("tv_settings_context_rate")) {
                                openURL(PrimuseAppStore.reviewURL)
                            }
                            settingDivider
                            navRow(
                                "stethoscope",
                                String(localized: "diagnostics_title"),
                                diagnosticModeActive ? PMString("ext.tv.sources.status.enabled") : "",
                                note: .app("tv_diagnostics_how_body"),
                                kind: .diagnostics
                            ) {
                                showsDiagnostics = true
                            }
                            settingDivider
                            navRow("info.circle", PMString("ext.tv.settings.about"), "\(version) (\(build)) · tvOS \(osVersion)",
                                   trailing: "", kind: .about) {
                                if iconEasterEgg.recordTap() { showsHiddenAppIcons = true }
                            }
                            .accessibilityIdentifier("settings.about.version")
                        }
                    }
                    .padding(TVSettingsLayout.listInsets)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 行在得到焦点时从环境里取到它;只写不读,左栏不会因焦点变化重算。
                .environment(focusContext)

                TVSettingsSidePanel(context: focusContext)
                    .frame(width: TVSettingsLayout.sideWidth)
                    .padding(TVSettingsLayout.sideInsets)
            }
            .disabled(showsEffectPicker || showsThemePicker)
            .accessibilityHidden(showsEffectPicker || showsThemePicker)

            if showsEffectPicker {
                TVFullscreenEffectPicker(
                    selectedRawValue: $immersiveEffectRawValue,
                    lyricsMotionEnabled: $lyricsMotionEnabled,
                    onDismiss: { showsEffectPicker = false }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            if showsThemePicker {
                TVThemeColorPicker(
                    selectedHex: $accentHex,
                    selectedModeRawValue: $themeColorModeRawValue,
                    onDismiss: { showsThemePicker = false }
                )
                .transition(.opacity)
                .zIndex(11)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: showsEffectPicker)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: showsThemePicker)
        .tvFullScreenCover(isPresented: $showsMedleySettings) { TVMedleySettingsView() }
        .tvFullScreenCover(isPresented: $showsAppIconPicker) { TVAppIconSettingsView() }
        .tvFullScreenCover(isPresented: $showsHiddenAppIcons) { TVAppIconSettingsView(hiddenOnly: true) }
        .onDisappear { iconEasterEgg = AppIconEasterEggTrigger() }
        .tvFullScreenCover(isPresented: $showsTabBarSettings) { TVTabBarSettingsView() }
        .tvFullScreenCover(isPresented: $showsHomeSectionsSettings) {
            TVHomeSectionsSettingsView().environment(intelligence)
        }
        .tvFullScreenCover(isPresented: $showsBackdropSettings) { TVPlayerBackdropSettingsView() }
        .tvFullScreenCover(isPresented: $showsBackdropCache) { TVPlayerBackdropCacheView() }
        .task { await backdropCache.reloadUsage() }
        .tvFullScreenCover(isPresented: $showsAISettings) {
            TVAISettingsView()
                .environment(intelligence)
        }
        .tvFullScreenCover(isPresented: $showsDiagnostics, onDismiss: {
            diagnosticModeActive = FileLogger.isDiagnosticModeActive
        }) {
            TVDiagnosticsView()
                .environment(intelligence)
        }
        .tvFullScreenCover(isPresented: $showsTranslationPanel) {
            TVLyricsTranslationPanel(showsCurrentSong: false)
                .environment(store)
                .environment(intelligence)
        }
        .tvFullScreenCover(isPresented: $showsMetadata) {
            TVMetadataMaintenanceView().environment(store)
        }
        .tvFullScreenCover(isPresented: $showsScraperSettings) {
            TVScraperSettingsView().environment(store)
        }
        .tvFullScreenCover(isPresented: $showsScrobbleSettings) { TVScrobbleSettingsView() }
        .preferredColorScheme(appearance.colorScheme)
        .confirmationDialog(PMString("default_artwork_title"), isPresented: $showsDefaultArtworkPicker, titleVisibility: .visible) {
            ForEach(MissingArtworkStyle.allCases, id: \.self) { style in
                Button(PMString(style.localizationKey)) {
                    missingArtworkStyle = style.rawValue
                }
            }
        }
        .confirmationDialog(
            String(localized: "word_alignment_model_remove_confirm"),
            isPresented: $confirmsWordAlignmentModelRemoval,
            titleVisibility: .visible
        ) {
            Button(String(localized: "lyrics_translation_local_remove"), role: .destructive) {
                Task { await WordLyricsAlignmentService.shared.removeModel() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .onExitCommand {
            if showsHiddenAppIcons {
                showsHiddenAppIcons = false
            } else if showsAppIconPicker {
                showsAppIconPicker = false
            } else if showsTabBarSettings {
                showsTabBarSettings = false
            } else if showsHomeSectionsSettings {
                showsHomeSectionsSettings = false
            } else if showsMetadata {
                showsMetadata = false
            } else if showsScraperSettings {
                showsScraperSettings = false
            } else if showsScrobbleSettings {
                showsScrobbleSettings = false
            } else if showsTranslationPanel {
                showsTranslationPanel = false
            } else if showsAISettings {
                showsAISettings = false
            } else if showsDiagnostics {
                showsDiagnostics = false
            } else if showsThemePicker {
                showsThemePicker = false
            } else if showsEffectPicker {
                showsEffectPicker = false
            } else {
                dismiss()
            }
        }
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            // 用户可能刚在搜索页或 tvOS 设置里改过授权,回来要显示最新状态。
            appleMusic.refreshAuthorization()
        }
    }

    // MARK: Lyrics

    /// 间奏提示点,和歌词翻译。翻译的开关留在这一页;译成什么、离线翻译包还是智能翻译、
    /// 下载翻译包都在面板里,和播放页「歌词翻译」键打开的是同一个。
    @ViewBuilder
    private var lyricsSection: some View {
        settingsSection(String(localized: "Lyrics")) {
            TVLyricsColorSettings()
            settingDivider
            HStack(spacing: 12) {
                toggleRow("text.magnifyingglass", String(localized: "explore_word_lyrics"),
                          note: .app("explore_word_lyrics_footer"), isOn: Binding(
                    get: { exploresWordLyrics },
                    set: { exploresWordLyrics = $0; CloudKVSSync.shared.markChanged(key: WordLyricsDiscoveryPreferences.enabledKey) }
                ))
                // 圈问号和左边的开关说的是同一项,右栏照样显示这一项。
                TVWordLyricsHelpButton(contextEntry: TVSettingsContextEntry(
                    icon: "text.magnifyingglass",
                    title: String(localized: "explore_word_lyrics"),
                    isOn: exploresWordLyrics,
                    note: .app("explore_word_lyrics_footer")
                ))
                    .padding(.trailing, 22)
            }
            settingDivider
            toggleRow("ellipsis.rectangle", String(localized: "player_activity_status"),
                      note: .app("tv_settings_context_activity_status"), isOn: Binding(
                get: { showsActivity },
                set: { showsActivity = $0; CloudKVSSync.shared.markChanged(key: WordLyricsDiscoveryPreferences.showsActivityKey) }
            ))
            settingDivider
            toggleRow(
                "waveform",
                String(localized: "player_simulated_word_lyrics"),
                note: .app("tv_settings_context_simulated_word"),
                isOn: Binding(
                    get: { simulatesWordLyrics },
                    set: {
                        simulatesWordLyrics = $0
                        CloudKVSSync.shared.markChanged(key: PlayerAppearancePreferences.simulatesWordLyricsKey)
                    }
                )
            )
            if LyricsAlignmentModel.isSystemSupported,
               simulatesWordLyrics || WordLyricsAlignmentService.shared.modelState != .notDownloaded {
                settingDivider
                wordAlignmentModelRow
            }
            settingDivider
            toggleRow(
                "ellipsis",
                String(localized: "player_lyrics_interlude_dots"),
                detail: String(localized: "player_lyrics_interlude_dots_description"),
                isOn: Binding(
                    get: { showsLyricsInterlude },
                    set: { shows in
                        showsLyricsInterlude = shows
                        CloudKVSSync.shared.markChanged(key: PlayerAppearancePreferences.showsLyricsInterludeKey)
                    }
                )
            )
            if showsLyricsInterlude {
                settingDivider
                toggleRow(
                    "ellipsis.rectangle",
                    String(localized: "player_lyrics_interlude_always"),
                    detail: String(localized: "player_lyrics_interlude_always_description"),
                    isOn: Binding(
                        get: { showsLyricsInterludeAlways },
                        set: { shows in
                            showsLyricsInterludeAlways = shows
                            CloudKVSSync.shared.markChanged(key: PlayerAppearancePreferences.showsLyricsInterludeAlwaysKey)
                        }
                    )
                )
            }
            settingDivider
            toggleRow(
                "character.bubble",
                String(localized: "lyrics_translation_enabled"),
                note: .app("lyrics_translation_overall_footer"),
                isOn: Binding(
                    get: { translationSettings.isEnabled },
                    set: { enabled in
                        if enabled {
                            let codes = LyricsTranslationSettingsStore.tvTargetLanguages(
                                intelligent: usesSmartLyricsTranslation
                            )
                            translationSettings.targetLanguageCode = LyricsTranslationSettingsStore.target(
                                translationSettings.targetLanguageCode,
                                within: codes
                            )
                        }
                        translationSettings.isEnabled = enabled
                    }
                )
            )
            if translationSettings.isEnabled {
                settingDivider
                navRow(
                    "slider.horizontal.3",
                    String(localized: "lyrics_translation_preferences_section"),
                    lyricsTranslationSummary,
                    note: .app("lyrics_translation_overall_footer")
                ) {
                    showsTranslationPanel = true
                }
            }
            settingDivider
            toggleRow(
                "text.bubble",
                String(localized: "lyrics_bundled_translation_shown"),
                detail: String(localized: "lyrics_bundled_translation_shown_footer"),
                isOn: Binding(
                    get: { translationSettings.showsBundledTranslations },
                    set: { translationSettings.showsBundledTranslations = $0 }
                )
            )
        }
    }

    // MARK: Lyrics romanization

    /// 罗马音：显示方式与生成方式按一下换到下一档；语言逐个开关。Google Cloud 的服务账号密钥
    /// 只能在 iPhone 或 Mac 上导入，开着凭据同步时会同步过来。
    @ViewBuilder
    private var lyricsRomanizationSection: some View {
        settingsSection(String(localized: "lyrics_romanization_section")) {
            navRow(
                "textformat.abc",
                String(localized: "lyrics_romanization_display"),
                romanizationSettings.displayMode.localizedTitle,
                trailing: "arrow.triangle.2.circlepath",
                note: .app("lyrics_romanization_display_footer")
            ) {
                romanizationSettings.displayMode = Self.next(
                    after: romanizationSettings.displayMode,
                    in: LyricRomanizationDisplayMode.allCases
                )
            }
            .accessibilityIdentifier("tv.lyricsRomanization.display")
            settingDivider
            toggleRow(
                "wand.and.stars",
                String(localized: "lyrics_romanization_auto_generate"),
                detail: String(localized: "lyrics_romanization_display_only_footer"),
                isOn: Binding(
                    get: { romanizationSettings.isAutoGenerationEnabled },
                    set: { romanizationSettings.isAutoGenerationEnabled = $0 }
                )
            )
            .accessibilityIdentifier("tv.lyricsRomanization.autoGenerate")
            if romanizationSettings.isAutoGenerationEnabled {
                ForEach(LyricRomanizationLanguage.allCases, id: \.self) { language in
                    settingDivider
                    toggleRow(
                        "character",
                        language.localizedTitle,
                        detail: language.localizedDetail,
                        isOn: Binding(
                            get: { romanizationSettings.isLanguageEnabled(language) },
                            set: { romanizationSettings.setLanguage(language, enabled: $0) }
                        )
                    )
                    .accessibilityIdentifier("tv.lyricsRomanization.language.\(language.rawValue)")
                }
                settingDivider
                navRow(
                    "cpu",
                    String(localized: "lyrics_romanization_method"),
                    displayedRomanizationMethod.localizedTitle,
                    trailing: "arrow.triangle.2.circlepath",
                    note: .app("lyrics_romanization_method_footer")
                ) {
                    romanizationSettings.method = Self.next(
                        after: displayedRomanizationMethod,
                        in: offeredRomanizationMethods
                    )
                }
                .accessibilityIdentifier("tv.lyricsRomanization.method")
                switch displayedRomanizationMethod {
                case .googleCloud:
                    settingDivider
                    infoRow(
                        "key",
                        String(localized: "lyrics_romanization_google_title"),
                        googleRomanizationAccount.lastError
                            ?? googleRomanizationAccount.summary?.clientEmail
                            ?? String(localized: "lyrics_romanization_google_tv_import_hint")
                    )
                case .intelligent:
                    let readiness = intelligence.lyricsAIRomanizationReadiness
                    if readiness != .ready, readiness != .regionUnavailable {
                        settingDivider
                        infoRow(
                            "exclamationmark.circle",
                            String(localized: "lyrics_romanization_ai_not_ready_title"),
                            readiness.romanizationExplanation
                        )
                    } else if intelligence.lyricsRomanizationFellBackFromBuiltIn {
                        settingDivider
                        infoRow(
                            "info.circle",
                            String(localized: "lyrics_romanization_ai_builtin_unsupported_title"),
                            String(localized: "lyrics_romanization_ai_builtin_unsupported")
                        )
                    }
                case .local:
                    EmptyView()
                }
            }
        }
    }

    private var offeredRomanizationMethods: [LyricRomanizationMethod] {
        LyricRomanizationMethod.offeredMethods(
            region: intelligence.regionAvailability.context.region,
            exposesIntelligentServices: intelligence.shouldExposeRemoteConfiguration
        )
    }

    private var displayedRomanizationMethod: LyricRomanizationMethod {
        LyricRomanizationMethodPolicy.effectiveMethod(
            romanizationSettings.method,
            region: intelligence.regionAvailability.context.region,
            exposesIntelligentServices: intelligence.shouldExposeRemoteConfiguration
        )
    }

    private var shufflePreference: ShufflePreference {
        ShufflePreference(rawValue: shufflePreferenceRawValue) ?? .defaultValue
    }

    private static func next<Value: Equatable>(after value: Value, in values: [Value]) -> Value {
        guard let index = values.firstIndex(of: value), !values.isEmpty else { return values.first ?? value }
        return values[(index + 1) % values.count]
    }

    private var usesSmartLyricsTranslation: Bool {
        intelligence.shouldExposeRemoteConfiguration
            && translationSettings.mode == .intelligentWithSystemFallback
    }

    private var lyricsTranslationSummary: String {
        let usesBaidu = translationSettings.mode == .baidu
        let codes = LyricsTranslationSettingsStore.tvTargetLanguages(
            intelligent: usesSmartLyricsTranslation || usesBaidu
        )
        let target = LyricsTranslationSettingsStore.target(translationSettings.targetLanguageCode, within: codes)
        let mode = usesBaidu
            ? String(localized: "lyrics_translation_mode_baidu")
            : String(localized: usesSmartLyricsTranslation
                     ? "lyrics_translation_mode_smart"
                     : "lyrics_translation_mode_offline")
        return TVLyricsTranslationPanel.languageName(target) + " · " + mode
    }

    private func settingsSection<Content: View>(
        _ title: String, @ViewBuilder content: @escaping () -> Content
    ) -> TVSettingsSection {
        TVSettingsSection(title, content: content)
    }

    private func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        syncMsg = nil
        Task {
            let outcome = await store.bootstrapWithOutcome()
            isSyncing = false
            syncMsg = syncStatusText(for: outcome)
        }
    }

    /// 同步结果的一句话解释。没登录、连不上、云端没快照、本机写不进去要分开讲,
    /// 「装上了但一首歌都用不了」也得说明白是手机本机文件不跨设备,而不是没同步。
    private func syncStatusText(for outcome: TVSyncOutcome) -> String {
        switch outcome {
        case .installed:
            return PMString("ext.tv.settings.synced", TVFmt.count(store.songs.count))
        case .installedWithoutTransferableSongs:
            return PMString("ext.tv.settings.syncedNoTransferable")
        case .accountUnavailable:
            return PMString("ext.tv.settings.syncNoAccount")
        case .cloudUnreachable:
            return PMString("ext.tv.settings.syncUnreachable")
        case .noSnapshot:
            return PMString("ext.tv.settings.noSnapshot")
        case .localStorageUnavailable:
            return PMString("ext.tv.persistence.failed")
        case .syncDisabled:
            return PMString("ext.tv.settings.syncDisabled")
        }
    }

    private var tabBarSummary: String {
        let configuration = TVTabBarConfiguration.decode(tabBarConfigurationRawValue)
        guard !configuration.isDefault else { return PMString("ext.tv.settings.tabBar.default") }
        return PMString(
            "ext.tv.settings.tabBar.shownCount",
            configuration.order.filter(configuration.isShown).count
        )
    }

    private func go(_ tab: TVRoot.Tab) {
        onNavigate(tab)
        dismiss()
    }

    private var appearance: TVAppearancePreference {
        appearanceState.preference
    }

    private var currentThemeTitle: String {
        if themeColorMode == .automatic {
            return PMString("theme_color_mode_auto")
        }
        guard let swatch = AppThemePreferences.swatches.first(where: { $0.id == accentHex }) else {
            return "#\(accentHex)"
        }
        return PMString(swatch.localizationKey)
    }

    private var themeColorMode: AppThemeColorMode {
        AppThemeColorMode(rawValue: themeColorModeRawValue)
            ?? AppThemePreferences.defaultColorMode
    }

    private func appearanceTitle(_ preference: TVAppearancePreference) -> String {
        switch preference {
        case .system: PMString("ext.tv.settings.appearance.system")
        case .light: PMString("ext.tv.settings.appearance.light")
        case .dark: PMString("ext.tv.settings.appearance.dark")
        }
    }

    /// 三个选项都可独立聚焦，Siri Remote 无需循环点按即可直接选择外观。
    private func appearanceRow() -> some View {
        let contextEntry = TVSettingsContextEntry(
            icon: "circle.lefthalf.filled",
            title: PMString("ext.tv.settings.appearance"),
            value: appearanceTitle(appearance),
            note: .app("tv_settings_context_appearance")
        )
        return HStack(spacing: 18) {
            TVSettingsIcon(icon: "circle.lefthalf.filled", focused: false)
            Text(PMString("ext.tv.settings.appearance"))
                .tvFont(.cardTitle, weight: .medium)
                .foregroundStyle(TVColor.text)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(TVAppearancePreference.allCases, id: \.self) { preference in
                    let isSelected = appearance == preference
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0, action: {
                        appearanceState.select(preference)
                    }, onFocusChanged: { focused in
                        if focused { focusContext.focus(contextEntry) }
                    }) { focused in
                        Text(appearanceTitle(preference))
                            .tvFont(.caption, weight: isSelected ? .bold : .semibold)
                            .foregroundStyle(isSelected ? TVColor.onBrand : TVColor.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .frame(minWidth: 116)
                            .padding(.vertical, 11)
                            .background(isSelected ? TVColor.brand : TVColor.cardElev,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(TVColor.brand.opacity(focused || isSelected ? 0.9 : 0), lineWidth: 2)
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
        .onChange(of: contextEntry) { _, entry in focusContext.refresh(entry) }
    }

    private func ambientIntensityRow() -> some View {
        let choices: [(value: Double, key: String)] = [
            (0.40, "ext.tv.settings.intensity.low"),
            (0.70, "ext.tv.settings.intensity.medium"),
            (1.00, "ext.tv.settings.intensity.high"),
        ]
        let selectedValue = choices.min {
            abs(ambientStrength - $0.value) < abs(ambientStrength - $1.value)
        }?.value ?? 0.70
        let selectedKey: String? = choices.first(where: { $0.value == selectedValue })?.key
        let contextEntry = TVSettingsContextEntry(
            icon: "sun.haze.fill",
            title: PMString("ext.tv.settings.ambientIntensity"),
            value: selectedKey.map { PMString($0) },
            note: .app("tv_settings_context_ambient_strength")
        )

        return HStack(spacing: 18) {
            TVSettingsIcon(icon: "sun.haze.fill", focused: false)
            Text(PMString("ext.tv.settings.ambientIntensity"))
                .tvFont(.cardTitle, weight: .medium)
                .foregroundStyle(TVColor.text)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(choices, id: \.value) { choice in
                    let isSelected = choice.value == selectedValue
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0, action: {
                        ambientStrength = choice.value
                    }, onFocusChanged: { focused in
                        if focused { focusContext.focus(contextEntry) }
                    }) { focused in
                        Text(PMString(choice.key))
                            .tvFont(.caption, weight: isSelected ? .bold : .semibold)
                            .foregroundStyle(isSelected ? TVColor.onBrand : TVColor.textMuted)
                            .frame(minWidth: 116)
                            .padding(.vertical, 11)
                            .background(
                                isSelected ? TVColor.brand : TVColor.cardElev,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(
                                        TVColor.brand.opacity(focused || isSelected ? 0.9 : 0),
                                        lineWidth: 2
                                    )
                            }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .onChange(of: contextEntry) { _, entry in focusContext.refresh(entry) }
    }

    /// 回放增益的前置增益:两颗系统按钮,各自把焦点报给右栏。
    @ViewBuilder
    private var preampRow: some View {
        let contextEntry = TVSettingsContextEntry(
            icon: "speaker.wave.2",
            title: String(localized: "rg_preamp"),
            value: String(format: "%+.1f dB", replayGain.preampDB),
            note: .app("tv_settings_context_rg_preamp")
        )
        HStack {
            Text("rg_preamp")
            Spacer()
            Button { replayGain.preampDB = max(-12, replayGain.preampDB - 0.5) } label: {
                Image(systemName: "minus")
            }
            .accessibilityLabel(Text("rg_preamp_decrease"))
            .modifier(TVSettingsContextReporting(entry: contextEntry))
            Text(String(format: "%+.1f dB", replayGain.preampDB)).monospacedDigit().frame(width: 120)
            Button { replayGain.preampDB = min(12, replayGain.preampDB + 0.5) } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(Text("rg_preamp_increase"))
            .modifier(TVSettingsContextReporting(entry: contextEntry))
        }
        .padding(.vertical, 12)
    }

    /// 可点击行(同步 / 跳转);trailing 默认箭头表示可进入。
    /// Apple Music 授权入口。搜索页只在输入关键词后才会出现授权行,
    /// 这里给一个常驻位置,并显示当前授权状态。
    @ViewBuilder
    private var appleMusicRow: some View {
        let title = PMString("ext.tv.settings.appleMusic")
        switch appleMusic.authorization {
        case .authorized:
            infoRow("music.note", title, PMString("ext.tv.settings.appleMusic.authorized"))
        case .restricted:
            infoRow("music.note", title, PMString("ext.tv.settings.appleMusic.restricted"))
        case .denied:
            infoRow("music.note", title, PMString("ext.tv.settings.appleMusic.denied"))
        case .notDetermined:
            navRow("music.note", title, PMString("ext.tv.settings.appleMusic.authorize"),
                   note: .app("tv_settings_context_apple_music"),
                   action: authorizeAppleMusic)
        }
    }

    private func authorizeAppleMusic() {
        Task { @MainActor in await appleMusic.requestAuthorization() }
    }

    /// Siri 授权入口。电台、有声书和播客的名字要授权后才登记给 Siri,
    /// 「播放 某某」才听得懂;第一次播电台时也会问一次。
    @ViewBuilder
    private var siriRow: some View {
        let title = PMString("ext.tv.settings.siri")
        switch siriAuthorization {
        case .authorized:
            infoRow("mic.fill", title, PMString("ext.tv.settings.siri.authorized"))
        case .denied:
            infoRow("mic.fill", title, PMString("ext.tv.settings.siri.denied"))
        case .notDetermined:
            navRow("mic.fill", title, PMString("ext.tv.settings.siri.authorize"),
                   note: .app("tv_settings_context_siri"), action: authorizeSiri)
        case .restricted:
            infoRow("mic.fill", title, PMString("ext.tv.settings.siri.restricted"))
        @unknown default:
            infoRow("mic.fill", title, PMString("ext.tv.settings.siri.restricted"))
        }
    }

    private func authorizeSiri() {
        TVSiriAuthorizationRuntime.request { status in
            siriAuthorization = status
            if status == .authorized {
                NotificationCenter.default.post(name: .primuseTVSiriRadioCatalogDidChange, object: nil)
            }
        }
    }

    @ViewBuilder
    private var wordAlignmentModelRow: some View {
        let service = WordLyricsAlignmentService.shared
        let title = String(localized: "word_alignment_model_title")
        let state = service.modelState
        let status: String = switch state {
        case .ready:
            String(localized: "lyrics_translation_local_ready")
        case .downloading(let fraction):
            fraction.formatted(.percent.precision(.fractionLength(0)))
        case .failed:
            service.modelFailureReason ?? String(localized: "lyrics_translation_local_retry")
        case .notDownloaded, .unsupportedSystem:
            String(
                format: String(localized: "lyrics_translation_local_download_size_format"),
                LyricsAlignmentModel.formattedDownloadSize
            )
        }
        let trailing: String = switch state {
        case .ready: "trash"
        case .downloading: "hourglass"
        case .failed: "arrow.clockwise"
        case .notDownloaded, .unsupportedSystem: "arrow.down.circle"
        }
        navRow("cpu", title, status, trailing: trailing, note: .app("tv_settings_context_alignment_model")) {
            switch state {
            case .notDownloaded, .failed:
                service.downloadModel()
            case .ready:
                confirmsWordAlignmentModelRemoval = true
            case .downloading, .unsupportedSystem:
                break
            }
        }
        .task { await service.refreshAvailability() }
    }

    /// `note` 是右栏的说明(只存键,显示时才查表),`kind` 决定右栏有没有专门的展示。
    private func navRow(_ icon: String, _ title: String, _ value: String,
                        trailing: String = "chevron.right",
                        note: TVSettingsContextNote? = nil,
                        kind: TVSettingsContextKind = .general,
                        action: @escaping () -> Void) -> TVSettingsNavigationRow {
        TVSettingsNavigationRow(
            icon: icon, title: title, value: value, trailing: trailing,
            note: note, kind: kind, action: action
        )
    }

    /// 没给 `note` 时右栏用行上的 `detail` 当说明。
    private func toggleRow(_ icon: String, _ title: String, detail: String? = nil,
                           note: TVSettingsContextNote? = nil,
                           kind: TVSettingsContextKind = .general,
                           isOn: Binding<Bool>) -> TVSettingsToggleRow {
        var contextNote = note
        if contextNote == nil, let detail { contextNote = .text(detail) }
        return TVSettingsToggleRow(icon: icon, title: title, detail: detail, note: contextNote, kind: kind, isOn: isOn)
    }

    /// 只读信息行(不可聚焦)。
    private func infoRow(_ icon: String, _ title: String, _ value: String) -> TVSettingsInfoRow {
        TVSettingsInfoRow(icon: icon, title: title, value: value)
    }

    private var settingDivider: some View {
        Rectangle()
            .fill(TVColor.divider)
            .frame(height: 1)
            .padding(.leading, 80)
    }
}

// MARK: - 右栏:遥控提示 + 焦点所在这一项

/// 设置主页两栏的尺寸。左栏滚动,右栏固定在屏幕上。
private enum TVSettingsLayout {
    static let outerInset: CGFloat = 80
    static let columnGap: CGFloat = 40
    static let verticalInset: CGFloat = 48
    static let sideWidth: CGFloat = 500
    /// 左栏的留白放在滚动区里面(面板阴影不被裁掉),一次写全,不叠几层 padding。
    static var listInsets: EdgeInsets {
        EdgeInsets(top: verticalInset, leading: outerInset, bottom: verticalInset, trailing: columnGap)
    }
    static var sideInsets: EdgeInsets {
        EdgeInsets(top: verticalInset, leading: 0, bottom: verticalInset, trailing: outerInset)
    }
    /// 遥控器示意图缩小到原来的几分之几,下半部分留给焦点这一项的说明。
    static let remoteScale: CGFloat = 0.45
}

/// 「关于」那一行和右栏共用的版本信息。
private enum TVSettingsAppInfo {
    static var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0" }
    static var build: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1" }
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}

/// 右栏下半部分按焦点行换的专门展示;`.general` 只有说明和当前值。
private enum TVSettingsContextKind: Equatable {
    case general
    /// 曲库规模:同步那几行、曲库、歌单。
    case library
    case appIcon
    case themeColor
    case backdrop
    case tabBar
    case homeSections
    case sources
    case scraper
    case scrobble
    case backdropCache
    case diagnostics
    case about
}

/// 右栏的说明只存键,显示时才查表:设置页整页重绘时不用把几十段说明都查一遍。
private enum TVSettingsContextNote: Equatable {
    /// App 自己的 Localizable.strings。
    case app(String)
    /// PrimuseKit 的表(`PMString`)。
    case kit(String)
    /// 行上本来就查好的文字(开关行的 detail、全屏效果的简介)。
    case text(String)

    var resolved: String {
        switch self {
        case .app(let key): String(localized: String.LocalizationValue(key))
        case .kit(let key): PMString(key)
        case .text(let text): text
        }
    }
}

/// 一行报给右栏的内容。
private struct TVSettingsContextEntry: Equatable {
    let icon: String
    let title: String
    var value: String? = nil
    /// 开关行的状态,右栏写成「已开启 / 已关闭」。
    var isOn: Bool? = nil
    var note: TVSettingsContextNote? = nil
    var kind: TVSettingsContextKind = .general

    /// 同一页里行标题不重复,拿它认是不是同一行。
    var id: String { title }
}

/// 焦点停在哪一行。行在得到焦点时写,只有右栏的说明卡读:焦点移动只重绘那张卡。
/// 焦点离开(打开了子页面)时不清掉,回来时还是这一行,也不会闪一下通用说明。
@MainActor
@Observable
private final class TVSettingsFocusContext {
    private(set) var entry: TVSettingsContextEntry?
    /// 焦点回到同一行时加一(比如关掉从这一行打开的页面回来):右栏另外取的值以它为准重取。
    private(set) var refreshToken = 0
    /// 日志占用。在日志自己的队列上算,同一个 `refreshToken` 只算一次,不随焦点移动扫磁盘。
    private(set) var logSize: Int?
    @ObservationIgnored private var logSizeToken: Int?
    /// Last.fm / ListenBrainz 连上没有(要查钥匙串),同样按 `refreshToken` 缓存。
    private(set) var scrobbleConnections: [ScrobbleProviderID: Bool] = [:]
    @ObservationIgnored private var scrobbleToken: Int?

    func focus(_ entry: TVSettingsContextEntry) {
        if entry.id == self.entry?.id { refreshToken &+= 1 }
        if self.entry != entry { self.entry = entry }
    }

    /// 焦点还在这一行时行上的值变了(同步完成、换了一档)。
    func refresh(_ entry: TVSettingsContextEntry) {
        guard self.entry?.id == entry.id, self.entry != entry else { return }
        self.entry = entry
    }

    func loadLogSize() async {
        let token = refreshToken
        guard logSizeToken != token else { return }
        logSizeToken = token
        let size = await FileLogger.shared.storedLogSize()
        logSize = size
    }

    func loadScrobbleConnections() {
        let token = refreshToken
        guard scrobbleToken != token else { return }
        scrobbleToken = token
        var listenBrainzReady = false
        if case .ready = ListenBrainzCredentialsStore.resolve() { listenBrainzReady = true }
        scrobbleConnections = [
            .lastFm: LastFmCredentialsStore.isConnected(),
            .listenBrainz: listenBrainzReady,
        ]
    }
}

/// 系统按钮这类不经过 `TVFocusButton` 的控件,用它把焦点报给右栏。
private struct TVSettingsContextReporting: ViewModifier {
    let entry: TVSettingsContextEntry
    @Environment(TVSettingsFocusContext.self) private var focusContext: TVSettingsFocusContext?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                if isFocused { focusContext?.focus(entry) }
            }
            .onChange(of: entry) { _, newEntry in focusContext?.refresh(newEntry) }
    }
}

/// 右栏:上面遥控提示,下面焦点所在这一项的说明。纯展示,不可聚焦,不抢遥控器焦点。
private struct TVSettingsSidePanel: View {
    let context: TVSettingsFocusContext

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSettingsRemoteTips()
            TVSettingsContextCard(context: context)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct TVSettingsRemoteTips: View {
    var body: some View {
        let scale = TVSettingsLayout.remoteScale
        VStack(alignment: .leading, spacing: 14) {
            Text(PMString("ext.tv.settings.remoteTips"))
                .tvFont(.rowTitle, weight: .bold)
                .foregroundStyle(TVColor.text)
            HStack(alignment: .top, spacing: 18) {
                // 缩小后只占左边一窄条,提示文字排在旁边。
                TVSiriRemote()
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: TVSiriRemote.size.width * scale,
                        height: TVSiriRemote.size.height * scale,
                        alignment: .topLeading
                    )
                VStack(alignment: .leading, spacing: 12) {
                    TVRemoteHint(PMString("ext.tv.settings.tip.touch.title"), PMString("ext.tv.settings.tip.touch.body"))
                    TVRemoteHint(PMString("ext.tv.remote.transportButton"), PMString("ext.tv.remote.transportShortcuts"))
                    TVRemoteHint(PMString("ext.tv.settings.tip.menu.title"), PMString("ext.tv.settings.tip.menu.body"))
                    TVRemoteHint(PMString("ext.tv.settings.tip.search.title"), PMString("ext.tv.settings.tip.search.body"))
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvPanel(radius: 20)
    }
}

/// 焦点这一项:图标、标题、当前值,一段说明,再加这一项专门的展示。
/// 高度不够时先截短说明(优先级最低),专门的展示和标题保持完整。
private struct TVSettingsContextCard: View {
    let context: TVSettingsFocusContext

    var body: some View {
        let entry = context.entry
        VStack(alignment: .leading, spacing: 16) {
            TVSettingsContextHeader(entry: entry)
                .layoutPriority(2)
            if let note = Self.note(for: entry) {
                Text(note)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TVSettingsContextDetail(kind: entry?.kind ?? .general, context: context)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .padding(24)
        .tvPanel(radius: 20)
        .accessibilityElement(children: .combine)
    }

    /// 还没有焦点时给一句通用说明;这一行没写说明时不占位置。
    private static func note(for entry: TVSettingsContextEntry?) -> String? {
        guard let entry else { return String(localized: "tv_settings_context_default") }
        return entry.note?.resolved
    }
}

private struct TVSettingsContextHeader: View {
    let entry: TVSettingsContextEntry?

    var body: some View {
        let value = valueText
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: entry?.icon ?? "info.circle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(TVColor.onBrand)
                .frame(width: 48, height: 48)
                .background(TVColor.brand, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry?.title ?? PMString("ext.tv.settings.eyebrow"))
                    .tvFont(.cardTitle, weight: .bold)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // 没有当前值时这一行留着位置(透明),换行时标题不上下跳。
                Text(value ?? " ")
                    .tvFont(.eyebrow)
                    .foregroundStyle(entry?.isOn == false ? TVColor.textMuted : TVColor.brand)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(value == nil ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var valueText: String? {
        guard let entry else { return nil }
        if let isOn = entry.isOn {
            return String(localized: isOn ? "a11y_value_on" : "a11y_value_off")
        }
        return entry.value
    }
}

private struct TVSettingsContextDetail: View {
    let kind: TVSettingsContextKind
    let context: TVSettingsFocusContext

    var body: some View {
        switch kind {
        case .general: EmptyView()
        case .library: TVSettingsLibraryStats()
        case .appIcon: TVSettingsIconGallery()
        case .themeColor: TVSettingsThemeSwatches()
        case .backdrop: TVSettingsBackdropHint()
        case .tabBar: TVSettingsTabBarOrder()
        case .homeSections: TVSettingsHomeSectionOrder()
        case .sources: TVSettingsSourceList()
        case .scraper: TVSettingsScraperList()
        case .scrobble: TVSettingsScrobbleStatus(context: context)
        case .backdropCache: TVSettingsBackdropCacheList()
        case .diagnostics: TVSettingsDiagnosticsStatus(context: context)
        case .about: TVSettingsAboutDetail()
        }
    }
}

/// 右栏列表的一行:图标、名称,右边一个状态。
private struct TVSettingsContextLine: View {
    let icon: String
    let title: String
    var value: String? = nil
    var iconTint: Color = TVColor.textMuted
    var valueTint: Color = TVColor.textMuted

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 30)
            Text(title)
                .tvFont(.caption, weight: .medium)
                .foregroundStyle(TVColor.text)
                .lineLimit(1)
            Spacer(minLength: 10)
            if let value {
                Text(value)
                    .tvFont(.meta, weight: .semibold)
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }
}

/// 列表只列前几个时,最后一行写「还有 N 个」。
private struct TVSettingsMoreLine: View {
    let count: Int

    var body: some View {
        Text(String(format: String(localized: "tv_settings_context_more_format"), count))
            .tvFont(.meta)
            .foregroundStyle(TVColor.textFaint)
            .padding(.leading, 42)
    }
}

// MARK: 各项专门的展示

/// 曲库规模:歌曲、专辑、艺术家、歌单各一格。
private struct TVSettingsLibraryStats: View {
    @Environment(TVStore.self) private var store

    var body: some View {
        if store.hasRealLibrary {
            HStack(spacing: 10) {
                TVSettingsStatTile(value: store.songs.count, label: String(localized: "tab_songs"))
                TVSettingsStatTile(value: store.albums.count, label: String(localized: "tab_albums"))
                TVSettingsStatTile(value: store.artists.count, label: String(localized: "tab_artists"))
                TVSettingsStatTile(value: store.playlistCount, label: String(localized: "tab_playlists"))
            }
        } else {
            TVSettingsContextLine(icon: "icloud.slash", title: PMString("ext.tv.settings.notSynced"))
        }
    }
}

private struct TVSettingsStatTile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(TVFmt.count(value))
                .tvFont(.cardTitle, weight: .bold)
                .foregroundStyle(TVColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .tvFont(.meta)
                .foregroundStyle(TVColor.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 全部可选图标排在一起,当前用的那个描边打勾。彩蛋图标只在正用着它时才列出来。
private struct TVSettingsIconGallery: View {
    private var service: AppIconService { .shared }

    var body: some View {
        let current = service.currentIconID
        let options = service.options + service.hiddenOptions.filter { $0.id == current }
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(options) { option in
                TVSettingsIconThumbnail(option: option, isCurrent: option.id == current)
            }
        }
    }
}

private struct TVSettingsIconThumbnail: View {
    let option: AppIconService.IconOption
    let isCurrent: Bool

    var body: some View {
        Image((option.id.isEmpty ? "AppIcon" : option.id) + "TVPreview")
            .resizable()
            .aspectRatio(5.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isCurrent ? TVColor.brand : TVColor.cardBorder, lineWidth: isCurrent ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(TVColor.onBrand, TVColor.brand)
                    .padding(4)
                    .opacity(isCurrent ? 1 : 0)
            }
            .opacity(isCurrent ? 1 : 0.72)
            .accessibilityLabel(Text(option.displayName))
    }
}

/// 主题色色板:第一格是跟随封面,其余是固定色,当前选中的那格套一圈。
private struct TVSettingsThemeSwatches: View {
    @Environment(TVStore.self) private var store
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.colorModeKey)
    private var colorModeRawValue = AppThemePreferences.colorMode().rawValue

    var body: some View {
        let mode = AppThemeColorMode(rawValue: colorModeRawValue) ?? AppThemePreferences.defaultColorMode
        let automatic = mode == .automatic
        let coverColors = store.nowPlayingPresentationColors
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 7),
            alignment: .leading,
            spacing: 14
        ) {
            TVSettingsSwatch(
                fill: AnyShapeStyle(LinearGradient(
                    colors: [coverColors.primary, coverColors.secondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )),
                symbol: "photo.on.rectangle.angled",
                isSelected: automatic
            )
            ForEach(AppThemePreferences.swatchesWithoutMonochrome) { swatch in
                TVSettingsSwatch(
                    fill: AnyShapeStyle(Color(hex: swatch.id)),
                    symbol: nil,
                    isSelected: !automatic && accentHex == swatch.id
                )
            }
        }
    }
}

private struct TVSettingsSwatch: View {
    let fill: AnyShapeStyle
    /// 跟随封面那一格常驻一个图标;固定色只在选中时打勾。
    let symbol: String?
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: symbol ?? "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .opacity(symbol != nil || isSelected ? 1 : 0)
            }
            .padding(4)
            .overlay {
                Circle()
                    .strokeBorder(TVColor.text, lineWidth: 3)
                    .opacity(isSelected ? 1 : 0)
            }
    }
}

/// 播放页背景当前来源的说明,和「播放页背景」页里选中那一项下面的是同一句。
private struct TVSettingsBackdropHint: View {
    private var store: PlayerBackdropSettingsStore { .shared }

    var body: some View {
        Text(hint(for: store.settings.source))
            .tvFont(.meta)
            .foregroundStyle(TVColor.text)
            .lineLimit(3)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func hint(for source: PlayerBackdropSource) -> String {
        switch source {
        case .coverAmbient: String(localized: "player_backdrop_cover_ambient_hint")
        case .liquid: String(localized: "player_backdrop_liquid_hint")
        case .visualizer: String(localized: "player_backdrop_liquid_tv_hint")
        case .coverBlur: String(localized: "player_backdrop_cover_blur_hint")
        case .albumBack: String(localized: "player_backdrop_album_back_hint")
        case .customImages:
            store.hasCustomImages
                ? String(format: String(localized: "player_backdrop_tv_images_count"), store.customImageIDs.count)
                : String(localized: "player_backdrop_tv_images_empty")
        }
    }
}

private struct TVSettingsOrderItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let isShown: Bool
}

/// 顶栏、首页各项的当前顺序:显示的按顺序编号,关掉的不编号、变淡。
private struct TVSettingsOrderGrid: View {
    let items: [TVSettingsOrderItem]

    var body: some View {
        let numbers = Self.numbers(for: items)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 2),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(items) { item in
                TVSettingsOrderCell(item: item, number: numbers[item.id])
            }
        }
    }

    private static func numbers(for items: [TVSettingsOrderItem]) -> [String: Int] {
        var result: [String: Int] = [:]
        var next = 1
        for item in items where item.isShown {
            result[item.id] = next
            next += 1
        }
        return result
    }
}

private struct TVSettingsOrderCell: View {
    let item: TVSettingsOrderItem
    let number: Int?

    var body: some View {
        HStack(spacing: 8) {
            // 关掉的项不编号,数字位置照样留着,各行图标对齐。
            Text(verbatim: "\(number ?? 0)")
                .tvFont(.meta, weight: .bold)
                .foregroundStyle(TVColor.textFaint)
                .frame(width: 26, alignment: .trailing)
                .opacity(number == nil ? 0 : 1)
            Image(systemName: item.isShown ? item.icon : "eye.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(item.isShown ? TVColor.text : TVColor.textGhost)
                .frame(width: 26)
            Text(item.title)
                .tvFont(.caption, weight: .medium)
                .foregroundStyle(item.isShown ? TVColor.text : TVColor.textGhost)
                .lineLimit(1)
        }
    }
}

private struct TVSettingsTabBarOrder: View {
    @AppStorage(TVTabBarConfiguration.storageKey) private var rawValue = ""

    var body: some View {
        let configuration = TVTabBarConfiguration.decode(rawValue)
        TVSettingsOrderGrid(items: configuration.order.map { item in
            TVSettingsOrderItem(
                id: item.rawValue,
                icon: item.tvIcon,
                title: item.tvTitle,
                isShown: configuration.isShown(item)
            )
        })
    }
}

private struct TVSettingsHomeSectionOrder: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage(TVHomeSectionConfiguration.storageKey) private var rawValue = ""

    var body: some View {
        let configuration = TVHomeSectionConfiguration.decode(rawValue)
        let remoteRecommendations = intelligence.shouldShowRemoteRecommendations
        TVSettingsOrderGrid(items: configuration.order.map { section in
            TVSettingsOrderItem(
                id: section.rawValue,
                icon: TVHomeSectionsSettingsView.icon(section),
                title: TVHomeSectionsSettingsView.title(section, remoteRecommendations: remoteRecommendations),
                isShown: configuration.isShown(section)
            )
        })
    }
}

/// 已添加的音乐源:类型图标、名称,右边是歌曲数或状态。太多时只列前几个。
private struct TVSettingsSourceList: View {
    @Environment(TVStore.self) private var store
    private static let limit = 4

    var body: some View {
        let sources = store.sources
        VStack(alignment: .leading, spacing: 10) {
            if sources.isEmpty {
                TVSettingsContextLine(icon: "server.rack", title: PMString("ext.tv.sources.emptyTitle"))
            }
            ForEach(Array(sources.prefix(Self.limit))) { source in
                TVSettingsSourceLine(source: source)
            }
            if sources.count > Self.limit {
                TVSettingsMoreLine(count: sources.count - Self.limit)
            }
        }
    }
}

private struct TVSettingsSourceLine: View {
    let source: TVSource

    var body: some View {
        let state = Self.state(of: source)
        HStack(spacing: 12) {
            Image(systemName: source.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(source.color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(source.name)
                .tvFont(.caption, weight: .medium)
                .foregroundStyle(source.status == .disabled ? TVColor.textGhost : TVColor.text)
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(state.label)
                .tvFont(.meta, weight: .semibold)
                .foregroundStyle(state.color)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// 和音乐源页每一行的状态同一套说法;正常连着的写歌曲数。
    private static func state(of source: TVSource) -> (label: String, color: Color) {
        if source.needsInitialScan {
            return (PMString("ext.tv.sources.status.pendingScan"), TVColor.warn)
        }
        switch source.status {
        case .connected: return (PMString("ext.tv.songsCount", source.songs), TVColor.textMuted)
        case .scanning: return (PMString("ext.tv.sources.status.scanning"), source.color)
        case .authFailed: return (PMString("ext.tv.sources.status.authFailed"), TVColor.bad)
        case .disabled: return (PMString("ext.tv.sources.status.disabled"), TVColor.textGhost)
        }
    }
}

/// 启用的刮削源,按尝试顺序列前几个。
private struct TVSettingsScraperList: View {
    @Environment(TVStore.self) private var store
    private static let limit = 4

    var body: some View {
        let sources = store.scraperSettings.enabledSources
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(sources.prefix(Self.limit))) { source in
                TVSettingsContextLine(icon: "checkmark.circle.fill", title: source.displayName, iconTint: TVColor.ok)
            }
            if sources.count > Self.limit {
                TVSettingsMoreLine(count: sources.count - Self.limit)
            }
        }
    }
}

/// Last.fm / ListenBrainz 连上没有、开着没有,以及向服务器回传播放记录的开关。
private struct TVSettingsScrobbleStatus: View {
    let context: TVSettingsFocusContext
    private var settings: ScrobbleSettingsStore { .shared }

    var body: some View {
        let reportsToServer = settings.reportPlaybackToServer
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ScrobbleProviderID.allCases, id: \.self) { provider in
                let state = providerState(provider)
                TVSettingsContextLine(
                    icon: provider == .lastFm ? "dot.radiowaves.left.and.right" : "waveform",
                    title: provider.displayName,
                    value: state.label,
                    valueTint: state.color
                )
            }
            TVSettingsContextLine(
                icon: "server.rack",
                title: String(localized: "scrobble_report_to_server"),
                value: String(localized: reportsToServer ? "a11y_value_on" : "a11y_value_off"),
                valueTint: reportsToServer ? TVColor.ok : TVColor.textMuted
            )
        }
        .task(id: context.refreshToken) { context.loadScrobbleConnections() }
    }

    private func providerState(_ provider: ScrobbleProviderID) -> (label: String, color: Color) {
        guard let connected = context.scrobbleConnections[provider] else { return ("…", TVColor.textFaint) }
        guard connected else {
            return (String(localized: "tv_settings_context_not_connected"), TVColor.textMuted)
        }
        let connectedLabel = String(localized: "scrobble_lastfm_connected")
        guard settings.isEnabled, settings.enabledProviders.contains(provider) else {
            return (connectedLabel + " · " + String(localized: "a11y_value_off"), TVColor.textMuted)
        }
        return (connectedLabel, TVColor.ok)
    }
}

/// 背景图片缓存:占用最大的几张专辑和各自的大小。
private struct TVSettingsBackdropCacheList: View {
    private var cache: TVAlbumBackdropCache { .shared }
    private static let limit = 4

    var body: some View {
        let usage = cache.usage.sorted { $0.bytes > $1.bytes }
        VStack(alignment: .leading, spacing: 10) {
            if usage.isEmpty {
                TVSettingsContextLine(icon: "photo.stack", title: String(localized: "player_backdrop_cache_empty"))
            }
            ForEach(Array(usage.prefix(Self.limit))) { item in
                TVSettingsContextLine(
                    icon: "photo",
                    title: item.snapshot.collection.title,
                    value: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
                )
            }
            if usage.count > Self.limit {
                TVSettingsMoreLine(count: usage.count - Self.limit)
            }
        }
    }
}

/// 诊断模式开着没有、开到什么时候,以及现在的日志有多大。
private struct TVSettingsDiagnosticsStatus: View {
    let context: TVSettingsFocusContext

    var body: some View {
        // `refreshToken` 变了才重读:关掉诊断页回来时开关和日志大小都重新取。
        let token = context.refreshToken
        let expiry = FileLogger.shared.diagnosticLoggingExpiresAt.flatMap { $0 > Date() ? $0 : nil }
        let logSize = context.logSize.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        }
        VStack(alignment: .leading, spacing: 10) {
            TVSettingsContextLine(
                icon: "stethoscope",
                title: String(localized: "diagnostics_mode_toggle"),
                value: String(localized: expiry == nil ? "a11y_value_off" : "a11y_value_on"),
                valueTint: expiry == nil ? TVColor.textMuted : TVColor.ok
            )
            if let expiry {
                Text(String(
                    format: String(localized: "diagnostics_mode_until_format"),
                    expiry.formatted(date: .abbreviated, time: .shortened)
                ))
                .tvFont(.meta)
                .foregroundStyle(TVColor.textMuted)
                .padding(.leading, 42)
            }
            TVSettingsContextLine(
                icon: "doc.text",
                title: String(localized: "diagnostics_logs_title"),
                value: logSize ?? "…"
            )
        }
        .task(id: token) { await context.loadLogSize() }
    }
}

private struct TVSettingsAboutDetail: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TVSettingsContextLine(icon: "app.badge", title: String(localized: "version"), value: TVSettingsAppInfo.version)
            TVSettingsContextLine(icon: "hammer", title: String(localized: "build"), value: TVSettingsAppInfo.build)
            TVSettingsContextLine(icon: "appletv", title: "tvOS", value: TVSettingsAppInfo.osVersion)
        }
    }
}

// Building all section tuples in the parent exhausts the device's main stack.
// Store a deferred, type-erased builder so both value storage and metadata
// lookup stop at this boundary; content is built only in this view's body.
struct TVSettingsSection: View {
    let title: String
    private let content: () -> AnyView

    init<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = { AnyView(content()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.textMuted)
            VStack(spacing: 0) { content() }.tvPanel(radius: 20)
        }
        .padding(.bottom, 34)
        .focusSection()
    }
}

private struct TVSettingsIcon: View {
    let icon: String
    let focused: Bool

    var body: some View {
        Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            .frame(width: 40, height: 40)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surface),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TVSettingsNavigationRow: View {
    let icon: String
    let title: String
    let value: String
    let trailing: String
    let note: TVSettingsContextNote?
    let kind: TVSettingsContextKind
    let action: () -> Void
    @Environment(TVSettingsFocusContext.self) private var focusContext: TVSettingsFocusContext?

    private var contextEntry: TVSettingsContextEntry {
        TVSettingsContextEntry(icon: icon, title: title, value: value.isEmpty ? nil : value, note: note, kind: kind)
    }

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: action, onFocusChanged: { focused in
            if focused { focusContext?.focus(contextEntry) }
        }) { focused in
            HStack(spacing: 18) {
                TVSettingsIcon(icon: icon, focused: focused)
                Text(title).tvFont(.cardTitle, weight: focused ? .bold : .medium).foregroundStyle(TVColor.text)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: 0)
                Text(value).tvFont(.eyebrow, weight: .regular).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.trailing).lineLimit(2)
                if !trailing.isEmpty {
                    Image(systemName: trailing).font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(focused ? TVColor.text : TVColor.textGhost)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : .clear)
        }
        // 焦点还停在这一行时值变了(同步完成、换了一档),右栏跟着改。
        .onChange(of: contextEntry) { _, entry in focusContext?.refresh(entry) }
    }
}

private struct TVSettingsToggleRow: View {
    let icon: String
    let title: String
    let detail: String?
    let note: TVSettingsContextNote?
    let kind: TVSettingsContextKind
    @Binding var isOn: Bool
    @Environment(TVSettingsFocusContext.self) private var focusContext: TVSettingsFocusContext?

    private var contextEntry: TVSettingsContextEntry {
        TVSettingsContextEntry(icon: icon, title: title, isOn: isOn, note: note, kind: kind)
    }

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: { isOn.toggle() }, onFocusChanged: { focused in
            if focused { focusContext?.focus(contextEntry) }
        }) { focused in
            HStack(spacing: 18) {
                TVSettingsIcon(icon: icon, focused: focused)
                Text(title).tvFont(.cardTitle, weight: focused ? .bold : .medium).foregroundStyle(TVColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? AnyShapeStyle(TVColor.brand)
                                           : AnyShapeStyle(TVColor.surfaceStrong))
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: isOn)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : .clear)
            .accessibilityValue(Text(isOn
                ? PMString("ext.tv.sources.status.enabled")
                : PMString("ext.tv.sources.status.disabled")))
        }
        .accessibilityHint(Text(detail ?? ""))
        .onChange(of: contextEntry) { _, entry in focusContext?.refresh(entry) }
    }
}

private struct TVWordLyricsHelpButton: View {
    let contextEntry: TVSettingsContextEntry
    @State private var isPresented = false
    @Environment(TVSettingsFocusContext.self) private var focusContext: TVSettingsFocusContext?

    init(contextEntry: TVSettingsContextEntry) {
        self.contextEntry = contextEntry
    }

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: {
            isPresented = true
        }, onFocusChanged: { focused in
            if focused { focusContext?.focus(contextEntry) }
        }) { focused in
            Image(systemName: "questionmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                .frame(width: 64, height: 64)
                .background(focused ? TVColor.surfaceStrong : .clear)
        }
        .accessibilityLabel(Text("settings_info_button"))
        .alert("explore_word_lyrics", isPresented: $isPresented) {
            Button("done", role: .cancel) {}
        } message: {
            Text("explore_word_lyrics_footer")
        }
        .onChange(of: contextEntry) { _, entry in focusContext?.refresh(entry) }
    }
}

/// 设置行旁的圈问号:电视上没有气泡,按一下弹出整段说明。沉浸风格选择器里屏幕常亮那一项也用它。
struct TVSettingsHelpButton: View {
    let title: LocalizedStringKey
    let message: String
    @State private var isPresented: Bool

    init(title: LocalizedStringKey, message: String) {
        self.title = title
        self.message = message
        _isPresented = State(initialValue: Self.debugOpens(message))
    }

    /// 截图用:TV_SCREEN=settings 配 TV_SETTINGS_HELP=<说明的键>,进设置就弹出那一段说明。
    private static func debugOpens(_ message: String) -> Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["TV_SETTINGS_HELP"] == message
        #else
        false
        #endif
    }

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0) {
            isPresented = true
        } label: { focused in
            Image(systemName: "questionmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                .frame(width: 64, height: 64)
                .background(focused ? TVColor.surfaceStrong : .clear)
        }
        .accessibilityLabel(Text("settings_info_button"))
        .alert(title, isPresented: $isPresented) {
            Button("done", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(message))
        }
    }
}

private struct TVSettingsInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 18) {
            TVSettingsIcon(icon: icon, focused: false)
            Text(title).tvFont(.cardTitle, weight: .medium).foregroundStyle(TVColor.text)
            Spacer(minLength: 0)
            Text(value).tvFont(.eyebrow, weight: .regular).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }
}

struct TVLyricsColorSettings: View {
    private var colors = PlayerLyricsColors()
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(TVSettingsFocusContext.self) private var focusContext: TVSettingsFocusContext?
    @State private var editingColor: ColorSlot?

    /// 这一组按钮在右栏共用一项:标题、当前档位和说明。
    private var contextEntry: TVSettingsContextEntry {
        let modeKey = switch colors.mode {
        case .defaultColor: "player_lyrics_color_default"
        case .custom: "player_lyrics_color_custom"
        case .gradient: "player_lyrics_color_gradient"
        case .artwork: "player_lyrics_color_artwork"
        }
        return TVSettingsContextEntry(
            icon: "paintbrush.pointed",
            title: String(localized: "player_current_lyric_color"),
            value: String(localized: String.LocalizationValue(modeKey)),
            note: .app("player_current_lyric_color_description")
        )
    }

    private enum ColorSlot: String, Identifiable {
        case custom, start, end
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .custom: "player_lyrics_custom_color"
            case .start: "player_lyrics_gradient_start_color"
            case .end: "player_lyrics_gradient_end_color"
            }
        }
        var storageKey: String {
            switch self {
            case .custom: PlayerAppearancePreferences.customLyricsColorHexKey
            case .start: PlayerAppearancePreferences.gradientLyricsStartColorHexKey
            case .end: PlayerAppearancePreferences.gradientLyricsEndColorHexKey
            }
        }
        var fallback: String {
            switch self {
            case .custom: PlayerAppearancePreferences.defaultCustomLyricsColorHex
            case .start: PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
            case .end: PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 18) {
                Text("player_current_lyric_color").tvFont(.cardTitle, weight: .medium)
                Spacer()
                ForEach(PlayerLyricsColorMode.allCases) { mode in
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0, action: {
                        colors.modeRawValue = mode.rawValue
                        CloudKVSSync.shared.markChanged(key: PlayerAppearancePreferences.lyricsColorModeKey)
                    }, onFocusChanged: { focused in
                        if focused { focusContext?.focus(contextEntry) }
                    }) { _ in
                        Text(mode.localizedTitle)
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(colors.mode == mode ? TVColor.onBrand : TVColor.text)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(colors.mode == mode ? TVColor.brand : TVColor.cardElev,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityIdentifier("tv.lyricsColor.mode.\(mode.rawValue)")
                    .accessibilityAddTraits(colors.mode == mode ? .isSelected : [])
                }
            }
            HStack(spacing: 24) {
                if colors.mode == .custom {
                    colorButton(.custom)
                } else if colors.mode == .gradient {
                    colorButton(.start)
                    colorButton(.end)
                }
                Spacer(minLength: 12)
                Text("player_lyrics_color_preview_sample")
                    .tvFont(.cardTitle, weight: .bold)
                    .foregroundStyle(colors.style(defaultColor: TVColor.text, layoutDirection: layoutDirection))
            }
        }
        .foregroundStyle(TVColor.text)
        .padding(22)
        .onChange(of: contextEntry) { _, entry in focusContext?.refresh(entry) }
        .tvFullScreenCover(item: $editingColor) { slot in
            TVLyricsColorPicker(titleKey: slot.titleKey, selection: binding(for: slot), fallback: slot.fallback) {
                editingColor = nil
            }
        }
    }

    private func binding(for slot: ColorSlot) -> Binding<String> {
        let storage: Binding<String> = switch slot {
        case .custom: colors.$customHex
        case .start: colors.$startHex
        case .end: colors.$endHex
        }
        return Binding(get: { storage.wrappedValue }, set: {
            storage.wrappedValue = $0
            CloudKVSSync.shared.markChanged(key: slot.storageKey)
        })
    }

    private func colorButton(_ slot: ColorSlot) -> some View {
        TVFocusButton(radius: 12, scale: 1.03, lift: 0, action: {
            editingColor = slot
        }, onFocusChanged: { focused in
            if focused { focusContext?.focus(contextEntry) }
        }) { _ in
            HStack(spacing: 12) {
                Circle().fill(PlayerLyricsColors.color(binding(for: slot).wrappedValue, fallback: slot.fallback))
                    .frame(width: 28, height: 28)
                Text(LocalizedStringKey(slot.titleKey)).tvFont(.caption)
            }
            .padding(14)
            .background(TVColor.cardElev, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier("tv.lyricsColor.\(slot.rawValue)")
    }
}

struct TVLyricsColorPicker: View {
    let titleKey: String
    @Binding var selection: String
    let fallback: String
    let onDismiss: () -> Void
    @State private var hexInput = ""

    private var normalizedInput: String {
        PlayerAppearancePreferences.normalizedLyricsColorHex(hexInput, fallback: "")
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                Text(LocalizedStringKey(titleKey)).tvFont(.pageTitle, weight: .bold)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 7), spacing: 18) {
                    ForEach(AppThemePreferences.swatches) { swatch in
                        TVFocusButton(radius: 16, scale: 1.05, lift: 4) {
                            selection = swatch.id
                            onDismiss()
                        } label: { _ in
                            VStack(spacing: 12) {
                                Circle().fill(Color(hex: swatch.id)).frame(width: 56, height: 56)
                                    .overlay {
                                        if selection == swatch.id {
                                            Image(systemName: "checkmark").foregroundStyle(.black)
                                        }
                                    }
                                Text(PMString(swatch.localizationKey)).tvFont(.caption)
                                    .lineLimit(1).minimumScaleFactor(0.75)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                            .background(TVColor.cardElev, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .accessibilityAddTraits(selection == swatch.id ? .isSelected : [])
                    }
                }
                HStack(spacing: 24) {
                    TextField("#RRGGBB", text: $hexInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .frame(width: 360)
                        .accessibilityLabel(Text(LocalizedStringKey(titleKey)))
                    Button("save") {
                        guard !normalizedInput.isEmpty else { return }
                        selection = normalizedInput
                        onDismiss()
                    }
                    .disabled(normalizedInput.isEmpty)
                    Spacer()
                    Text("player_lyrics_color_preview_sample")
                        .tvFont(.cardTitle, weight: .bold)
                        .foregroundStyle(PlayerLyricsColors.color(hexInput, fallback: fallback))
                }
                Button("cancel", action: onDismiss)
            }
            .padding(42).frame(maxWidth: 1500)
        }
        .foregroundStyle(TVColor.text)
        .onAppear { hexInput = selection }
        .onExitCommand(perform: onDismiss)
    }
}

private struct TVThemeColorPicker: View {
    @Environment(TVStore.self) private var store
    @Binding var selectedHex: String
    @Binding var selectedModeRawValue: String
    let onDismiss: () -> Void

    @FocusState private var focusedID: String?

    private static let automaticFocusID = "__automatic_theme__"

    private var mode: AppThemeColorMode {
        AppThemeColorMode(rawValue: selectedModeRawValue)
            ?? AppThemePreferences.defaultColorMode
    }

    private var previewColors: (primary: Color, secondary: Color) {
        if mode == .automatic {
            return store.nowPlayingPresentationColors
        }
        return (
            TVColor.brand(hex: selectedHex),
            TVColor.brandSecondary(hex: selectedHex)
        )
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(
                tint: previewColors.primary,
                tint2: previewColors.secondary,
                strength: 0.65
            )
            TVColor.bg.opacity(0.48).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        TVEyebrow(text: PMString("ext.tv.settings.eyebrow"))
                        Text(PMString("ext.tv.settings.themeColor"))
                            .tvFont(size: 44, weight: .bold, relativeTo: .title)
                            .foregroundStyle(TVColor.text)
                    }
                    Spacer()
                    Text("#\(selectedHex)")
                        .tvFont(.caption, design: .monospaced)
                        .foregroundStyle(TVColor.textMuted)
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 6),
                    spacing: 18
                ) {
                    automaticButton
                    ForEach(AppThemePreferences.swatchesWithoutMonochrome) { swatch in
                        swatchButton(swatch)
                    }
                }
            }
            .padding(42)
            .frame(maxWidth: 1500)
            .tvPanel(radius: 26)
            .padding(.horizontal, 84)
        }
        .focusSection()
        .onAppear {
            focusedID = mode == .automatic ? Self.automaticFocusID : selectedHex
        }
        .accessibilityAddTraits(.isModal)
    }

    private var automaticButton: some View {
        let focused = focusedID == Self.automaticFocusID
        let selected = mode == .automatic

        return Button {
            selectedModeRawValue = AppThemeColorMode.automatic.rawValue
            TVThemeState.shared.setMode(.automatic)
            onDismiss()
        } label: {
            VStack(spacing: 12) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [previewColors.primary, previewColors.secondary],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 66, height: 66)
                    .overlay {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(TVColor.onBrand)
                    }
                Text(PMString("theme_color_mode_auto"))
                    .tvFont(.caption, weight: selected ? .bold : .semibold)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                focused ? TVColor.surfaceStrong : TVColor.card,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? TVColor.brand : TVColor.cardBorder,
                                  lineWidth: selected ? 3 : 1)
            }
            .tvFocusRing(focused, radius: 16, accent: TVColor.brand, scale: 1.05, lift: 6)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedID, equals: Self.automaticFocusID)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func swatchButton(_ swatch: AppThemePreferences.Swatch) -> some View {
        let focused = focusedID == swatch.id
        let selected = mode == .fixed && selectedHex == swatch.id

        return Button {
            selectedModeRawValue = AppThemeColorMode.fixed.rawValue
            selectedHex = swatch.id
            TVThemeState.shared.setMode(.fixed)
            TVThemeState.shared.setFixedHex(swatch.id)
            onDismiss()
        } label: {
            VStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: swatch.id))
                    .frame(width: 66, height: 66)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.42), radius: 2)
                        }
                    }
                Text(PMString(swatch.localizationKey))
                    .tvFont(.caption, weight: selected ? .bold : .semibold)
                    .foregroundStyle(TVColor.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                focused ? TVColor.surfaceStrong : TVColor.card,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        selected ? TVColor.brand(hex: swatch.id) : TVColor.cardBorder,
                        lineWidth: selected ? 3 : 1
                    )
            }
            .tvFocusRing(focused, radius: 16, accent: TVColor.brand(hex: swatch.id), scale: 1.05, lift: 6)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedID, equals: swatch.id)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct TVRemoteHint: View {
    let binding: String
    let label: String
    init(_ binding: String, _ label: String) { self.binding = binding; self.label = label }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(binding).tvFont(.caption, weight: .semibold).foregroundStyle(TVColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(label).tvFont(.meta).foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TVSiriRemote: View {
    /// 画出来的原始尺寸;右栏按比例缩小后摆放。
    static let size = CGSize(width: 108, height: 416)
    private let buttonColor = Color(white: 0.12)

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                remoteButton("power", size: 17, symbolSize: 9)
            }
            ZStack {
                Circle().fill(buttonColor)
                Circle().fill(Color(white: 0.19)).padding(16)
                    .overlay { Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1).padding(16) }
                ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { degrees in
                    Circle().fill(.white.opacity(0.6)).frame(width: 3, height: 3)
                        .offset(y: -35).rotationEffect(.degrees(degrees))
                }
            }
            .frame(width: 88, height: 88)

            HStack(spacing: 14) {
                remoteButton("chevron.left", outlined: true)
                remoteButton("tv")
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    remoteButton("playpause.fill")
                    remoteButton("speaker.slash.fill")
                }
                VStack {
                    Image(systemName: "plus")
                    Spacer()
                    Image(systemName: "minus")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.vertical, 12)
                .frame(width: 34, height: 82)
                .background(buttonColor, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            LinearGradient(colors: [Color(white: 0.92), Color(white: 0.68), Color(white: 0.84)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.6), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Capsule().fill(Color(white: 0.55)).frame(width: 3, height: 44)
                .offset(x: 2, y: 104)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
        .accessibilityHidden(true)
    }

    private func remoteButton(
        _ symbol: String,
        size: CGFloat = 34,
        symbolSize: CGFloat = 14,
        outlined: Bool = false
    ) -> some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(buttonColor, in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(outlined ? 0.9 : 0), lineWidth: 2) }
    }
}
// MARK: - 顶栏菜单

/// 设置 → 顶栏菜单:调整电视顶栏各页的顺序、关掉不常用的页。
///
/// tvOS 的列表拖不动,每行给「上移 / 下移」两颗按钮。设置是顶栏右上角的独立按钮,
/// 不在这张表里,也关不掉;不看内容的页至少留一个打开(`TVTabBarConfiguration.canHide`)。
/// 改动立刻写进 UserDefaults,`TVRoot` 读同一个键,关掉当前所在的页就回到顶栏第一页。
struct TVTabBarSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TVTabBarConfiguration.storageKey) private var rawValue = ""
    @AppStorage(TVLibraryFilterConfiguration.storageKey) private var libraryFilterRawValue = ""
    @FocusState private var focusedID: String?
    @State private var notice: String?

    private var configuration: TVTabBarConfiguration { .decode(rawValue) }

    var body: some View {
        let configuration = self.configuration
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(PMString("ext.tv.settings.tabBar"))
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                    VStack(spacing: 0) {
                        ForEach(Array(configuration.order.enumerated()), id: \.element) { index, item in
                            if index > 0 {
                                Rectangle().fill(TVColor.divider).frame(height: 1).padding(.leading, 80)
                            }
                            row(item, in: configuration)
                        }
                    }
                    .tvPanel(radius: 20)
                    .focusSection()

                    if let notice {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TVPillButton(
                        title: PMString("ext.tv.settings.tabBar.reset"),
                        systemImage: "arrow.counterclockwise",
                        focusBinding: $focusedID,
                        focusID: Self.resetFocusID
                    ) {
                        rawValue = ""
                        notice = nil
                        focusedID = Self.toggleFocusID(TVTabBarConfiguration.defaultOrder[0])
                    }
                    .disabled(configuration.isDefault)
                    .padding(.top, 8)

                    libraryFilterSection
                        .padding(.top, 24)
                }
                .frame(maxWidth: 1200, alignment: .leading)
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .onExitCommand { dismiss() }
    }

    // MARK: 资料库筛选条

    private var libraryFilterConfiguration: TVLibraryFilterConfiguration {
        .decode(libraryFilterRawValue)
    }

    /// 资料库顶部筛选条上能关掉的几项。专辑、歌曲这些藏品本身一直在。
    private var libraryFilterSection: some View {
        let configuration = libraryFilterConfiguration
        let optional = TVLibraryFilter.allCases.filter(\.isOptional)
        return VStack(alignment: .leading, spacing: 16) {
            Text("library_filters_settings_title")
                .tvFont(.sectionTitle)
                .foregroundStyle(TVColor.text)
            VStack(spacing: 0) {
                ForEach(Array(optional.enumerated()), id: \.element) { index, filter in
                    if index > 0 {
                        Rectangle().fill(TVColor.divider).frame(height: 1).padding(.leading, 80)
                    }
                    libraryFilterRow(filter, isShown: configuration.isShown(filter))
                }
            }
            .tvPanel(radius: 20)
            .focusSection()
        }
    }

    private func libraryFilterRow(_ filter: TVLibraryFilter, isShown: Bool) -> some View {
        TVFocusButton(
            radius: 14, scale: 1.0, lift: 0,
            action: {
                var updated = libraryFilterConfiguration
                updated.setShown(!isShown, for: filter)
                libraryFilterRawValue = updated.encoded()
            },
            focusBinding: $focusedID,
            focusID: "libraryFilter." + filter.rawValue
        ) { focused in
            HStack(spacing: 18) {
                Image(systemName: filter.icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isShown ? TVColor.text : TVColor.textGhost)
                    .frame(width: 44)
                Text(filter.display)
                    .tvFont(.cardTitle, weight: focused ? .bold : .medium)
                    .foregroundStyle(isShown ? TVColor.text : TVColor.textMuted)
                Spacer(minLength: 0)
                ZStack(alignment: isShown ? .trailing : .leading) {
                    Capsule().fill(isShown ? AnyShapeStyle(TVColor.brand)
                                           : AnyShapeStyle(TVColor.surfaceStrong))
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: isShown)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
        .accessibilityLabel(Text(filter.display))
        .accessibilityValue(Text(isShown
            ? PMString("ext.tv.sources.status.enabled")
            : PMString("ext.tv.sources.status.disabled")))
    }

    private static let resetFocusID = "tabBar.reset"
    private static func toggleFocusID(_ item: TVTabBarItem) -> String { "tabBar.toggle." + item.rawValue }
    private static func upFocusID(_ item: TVTabBarItem) -> String { "tabBar.up." + item.rawValue }
    private static func downFocusID(_ item: TVTabBarItem) -> String { "tabBar.down." + item.rawValue }

    private func row(_ item: TVTabBarItem, in configuration: TVTabBarConfiguration) -> some View {
        TVOrderedSettingRow(
            icon: item.tvIcon,
            title: item.tvTitle,
            hint: item.dependsOnContent ? PMString("ext.tv.settings.tabBar.contentHint") : nil,
            isShown: configuration.isShown(item),
            canMoveUp: configuration.canMove(item, by: -1),
            canMoveDown: configuration.canMove(item, by: 1),
            focusBinding: $focusedID,
            toggleFocusID: Self.toggleFocusID(item),
            upFocusID: Self.upFocusID(item),
            downFocusID: Self.downFocusID(item),
            onToggle: { toggle(item) },
            onMove: { move(item, by: $0) }
        )
    }

    private func toggle(_ item: TVTabBarItem) {
        var updated = configuration
        if updated.isShown(item) {
            guard updated.setShown(false, for: item) else {
                notice = PMString("ext.tv.settings.tabBar.keepOne")
                return
            }
        } else {
            updated.setShown(true, for: item)
        }
        notice = nil
        rawValue = updated.encoded()
    }

    /// 挪完焦点跟着这一行走;挪到头了那颗按钮会变成不可用,焦点换到反方向那颗上。
    private func move(_ item: TVTabBarItem, by offset: Int) {
        var updated = configuration
        updated.move(item, by: offset)
        notice = nil
        rawValue = updated.encoded()
        if updated.canMove(item, by: offset) {
            focusedID = offset < 0 ? Self.upFocusID(item) : Self.downFocusID(item)
        } else {
            focusedID = offset < 0 ? Self.downFocusID(item) : Self.upFocusID(item)
        }
    }
}
// MARK: - 可排序的开关行

/// 顶栏菜单、首页内容这类「开关 + 上移 / 下移」的设置行。tvOS 的列表拖不动,挪动靠两颗按钮;
/// 挪到头的那颗变成不可用,焦点由父视图换到反方向那颗上。
struct TVOrderedSettingRow: View {
    let icon: String
    let title: String
    var hint: String?
    let isShown: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    var focusBinding: FocusState<String?>.Binding
    let toggleFocusID: String
    let upFocusID: String
    let downFocusID: String
    let onToggle: () -> Void
    let onMove: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            TVFocusButton(
                radius: 14, scale: 1.0, lift: 0,
                action: onToggle,
                focusBinding: focusBinding,
                focusID: toggleFocusID
            ) { focused in
                HStack(spacing: 18) {
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(isShown ? TVColor.text : TVColor.textGhost)
                        .frame(width: 44)
                    Text(title)
                        .tvFont(.cardTitle, weight: focused ? .bold : .medium)
                        .foregroundStyle(isShown ? TVColor.text : TVColor.textMuted)
                    Spacer(minLength: 0)
                    ZStack(alignment: isShown ? .trailing : .leading) {
                        Capsule().fill(isShown ? AnyShapeStyle(TVColor.brand)
                                               : AnyShapeStyle(TVColor.surfaceStrong))
                            .frame(width: 62, height: 34)
                        Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                    }
                    .animation(.easeOut(duration: 0.18), value: isShown)
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(focused ? TVColor.surfaceStrong : .clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(hint ?? ""))
            .accessibilityValue(Text(isShown
                ? PMString("ext.tv.sources.status.enabled")
                : PMString("ext.tv.sources.status.disabled")))

            moveButton(by: -1, icon: "chevron.up", enabled: canMoveUp,
                       label: PMString("ext.tv.settings.tabBar.moveUp"), focusID: upFocusID)
            moveButton(by: 1, icon: "chevron.down", enabled: canMoveDown,
                       label: PMString("ext.tv.settings.tabBar.moveDown"), focusID: downFocusID)
        }
        .padding(.vertical, 6)
        .padding(.trailing, 16)
    }

    private func moveButton(by offset: Int, icon: String, enabled: Bool, label: String, focusID: String) -> some View {
        TVFocusButton(
            radius: 14, scale: 1.06, lift: 0,
            action: { onMove(offset) },
            focusBinding: focusBinding,
            focusID: focusID
        ) { focused in
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(!enabled ? TVColor.textGhost : (focused ? TVColor.bg : TVColor.text))
                .frame(width: 64, height: 64)
                .background(focused ? AnyShapeStyle(TVColor.text) : AnyShapeStyle(TVColor.surfaceStrong),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - 首页内容

/// 设置 → 首页内容:调整电视首页各排的顺序、关掉不想看的排。至少留一排
/// (`TVHomeSectionConfiguration.canHide`)。改动立刻写进 UserDefaults,首页读同一个键。
struct TVHomeSectionsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage(TVHomeSectionConfiguration.storageKey) private var rawValue = ""
    @FocusState private var focusedID: String?
    @State private var notice: String?

    private var configuration: TVHomeSectionConfiguration { .decode(rawValue) }

    var body: some View {
        let configuration = self.configuration
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    Text(PMString("ext.tv.settings.homeSections"))
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                    VStack(spacing: 0) {
                        ForEach(Array(configuration.order.enumerated()), id: \.element) { index, section in
                            if index > 0 {
                                Rectangle().fill(TVColor.divider).frame(height: 1).padding(.leading, 80)
                            }
                            TVOrderedSettingRow(
                                icon: Self.icon(section),
                                title: title(section),
                                hint: section == .albumPick ? String(localized: "home_section_album_pick_hint") : nil,
                                isShown: configuration.isShown(section),
                                canMoveUp: configuration.canMove(section, by: -1),
                                canMoveDown: configuration.canMove(section, by: 1),
                                focusBinding: $focusedID,
                                toggleFocusID: Self.toggleFocusID(section),
                                upFocusID: Self.upFocusID(section),
                                downFocusID: Self.downFocusID(section),
                                onToggle: { toggle(section) },
                                onMove: { move(section, by: $0) }
                            )
                        }
                    }
                    .tvPanel(radius: 20)
                    .focusSection()

                    if let notice {
                        Label(notice, systemImage: "exclamationmark.circle")
                            .tvFont(.caption, weight: .semibold)
                            .foregroundStyle(TVColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TVPillButton(
                        title: PMString("ext.tv.settings.tabBar.reset"),
                        systemImage: "arrow.counterclockwise",
                        focusBinding: $focusedID,
                        focusID: "homeSections.reset"
                    ) {
                        rawValue = ""
                        notice = nil
                        focusedID = Self.toggleFocusID(TVHomeSectionConfiguration.defaultOrder[0])
                    }
                    .disabled(configuration.isDefault)
                    .padding(.top, 8)
                }
                .frame(maxWidth: 1200, alignment: .leading)
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .onExitCommand { dismiss() }
    }

    static func summary(_ rawValue: String) -> String {
        let configuration = TVHomeSectionConfiguration.decode(rawValue)
        guard !configuration.isDefault else { return PMString("ext.tv.settings.tabBar.default") }
        return PMString("ext.tv.settings.tabBar.shownCount", configuration.visibleSections.count)
    }

    private func title(_ section: TVHomeSection) -> String {
        Self.title(section, remoteRecommendations: intelligence.shouldShowRemoteRecommendations)
    }

    /// 与首页上这一排的标题一致:推荐那一排开着智能服务时叫「场景推荐」。设置主页右栏也用它。
    static func title(_ section: TVHomeSection, remoteRecommendations: Bool) -> String {
        switch section {
        case .albumPick: String(localized: "home_section_album_pick")
        case .homeScenes: String(localized: "listening_scene_row_title")
        case .recommendations:
            remoteRecommendations
                ? PMString("ai_recommendation_home_title")
                : PMString("ext.tv.home.madeForYou")
        case .recentlyPlayed: PMString("ext.tv.home.recentlyPlayed")
        case .likedAlbums: String(localized: "library_liked_albums_title")
        case .recentlyAdded: PMString("ext.tv.home.recentlyAdded")
        case .radio: PMString("ext.tv.radio.title")
        }
    }

    static func icon(_ section: TVHomeSection) -> String {
        switch section {
        case .albumPick: "opticaldisc"
        case .homeScenes: "sofa.fill"
        case .recommendations: "sparkles"
        case .recentlyPlayed: "clock.arrow.circlepath"
        case .likedAlbums: "heart.fill"
        case .recentlyAdded: "clock.badge.checkmark"
        case .radio: "radio.fill"
        }
    }

    private static func toggleFocusID(_ section: TVHomeSection) -> String { "homeSections.toggle." + section.rawValue }
    private static func upFocusID(_ section: TVHomeSection) -> String { "homeSections.up." + section.rawValue }
    private static func downFocusID(_ section: TVHomeSection) -> String { "homeSections.down." + section.rawValue }

    private func toggle(_ section: TVHomeSection) {
        var updated = configuration
        if updated.isShown(section) {
            guard updated.setShown(false, for: section) else {
                notice = PMString("ext.tv.settings.homeSections.keepOne")
                return
            }
        } else {
            updated.setShown(true, for: section)
        }
        notice = nil
        rawValue = updated.encoded()
    }

    /// 挪完焦点跟着这一行走;挪到头了那颗按钮会变成不可用,焦点换到反方向那颗上。
    private func move(_ section: TVHomeSection, by offset: Int) {
        var updated = configuration
        updated.move(section, by: offset)
        notice = nil
        rawValue = updated.encoded()
        if updated.canMove(section, by: offset) {
            focusedID = offset < 0 ? Self.upFocusID(section) : Self.downFocusID(section)
        } else {
            focusedID = offset < 0 ? Self.downFocusID(section) : Self.upFocusID(section)
        }
    }
}
#endif
