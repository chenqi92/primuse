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

/// 截图 / 取证:TV_SCREEN=settings 配 TV_SCRAPE_DEBUG=settings 直接打开刮削设置。
private var tvDebugShowsScraperSettings: Bool {
    #if DEBUG
    ProcessInfo.processInfo.environment["TV_SCRAPE_DEBUG"] == "settings"
    #else
    false
    #endif
}

struct TVSettingsView: View {
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
    @AppStorage(PlayerAppearancePreferences.animatedArtworkEnabledKey)
    private var animatedArtworkEnabled = PlayerAppearancePreferences.animatedArtworkEnabledByDefault
    @AppStorage(TVStore.autoContinueSimilarKey) private var autoContinueSimilar = true
    @AppStorage(TVHomeSceneRow.nightSleepTimerKey) private var nightSceneSleepTimer = true
    @AppStorage(LibraryReviewPreferences.enabledKey)
    private var ratingsAndCommentsEnabled = false
    @State private var showsEffectPicker = tvDebugShowsEffectPicker
    @State private var showsThemePicker = tvDebugShowsThemePicker
    @State private var showsAISettings = false
    @State private var siriAuthorization = TVSiriAuthorizationRuntime.status
    @State private var showsMetadata = false
    @State private var showsScraperSettings = tvDebugShowsScraperSettings
    @State private var showsMedleySettings = false
    @State private var showsTabBarSettings = false
    @State private var showsHomeSectionsSettings = false
    @AppStorage(TVHomeSectionConfiguration.storageKey) private var homeSectionsRawValue = ""
    @State private var showsBackdropSettings = tvDebugShowsBackdropSettings
    @State private var backdropSettings = PlayerBackdropSettingsStore.shared
    @AppStorage(TVTabBarConfiguration.storageKey) private var tabBarConfigurationRawValue = ""
    @State private var isSyncing = false
    @State private var syncMsg: String?
    @State private var artistNameSettings = ArtistNameSettingsStore.shared
    @State private var translationSettings = LyricsTranslationSettingsStore.shared
    @State private var showsTranslationModelRemoval = false
    @State private var translationModelRemovalPack: LocalLyricsTranslationModel.Pack = .persian
    private var localTranslation: LocalLyricsTranslationService { .shared }
    @State private var appleMusic = TVAppleMusicCatalog()

    private var immersiveEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: immersiveEffectRawValue) ?? .defaultValue
    }

    private var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0" }
    private var build: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1" }
    private var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
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
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(PMString("ext.tv.settings.eyebrow"))
                            .tvFont(.pageTitle)
                            .foregroundStyle(TVColor.text)
                            .padding(.bottom, 24)
                        settingsSection(String(localized: "sync")) {
                            toggleRow("icloud", PMString("ext.tv.settings.icloudSyncEnabled"), isOn: $iCloudSyncEnabled)
                                .onChange(of: iCloudSyncEnabled) { _, value in
                                    // 只改偏好不生效:引擎要跟着起停,与 iOS 的
                                    // CloudSyncSettingsView 做同一件事。
                                    syncMsg = nil   // 上一次的结果对新状态不再成立
                                    Task { await store.setCloudSyncEnabled(value) }
                                }
                            settingDivider
                            navRow("icloud.fill", PMString("ext.tv.settings.icloudSync"), syncValue, trailing: "arrow.clockwise", action: sync)
                            settingDivider
                            toggleRow("arrow.triangle.2.circlepath", PMString("ext.tv.settings.autoSync"), isOn: $autoSync)
                        }
                        settingsSection(String(localized: "appearance")) {
                            appearanceRow()
                            settingDivider
                            navRow(
                                "paintpalette.fill",
                                PMString("ext.tv.settings.themeColor"),
                                currentThemeTitle,
                                action: { showsThemePicker = true }
                            )
                            settingDivider
                            toggleRow(
                                "photo.on.rectangle.angled",
                                PMString("ext.tv.settings.coverColor"),
                                isOn: $coverDrivenAmbient
                            )
                            settingDivider
                            ambientIntensityRow()
                            settingDivider
                            navRow(
                                "photo.on.rectangle",
                                String(localized: "player_backdrop_title"),
                                TVPlayerBackdropSettingsView.title(backdropSettings.settings.source),
                                action: { showsBackdropSettings = true }
                            )
                            settingDivider
                            navRow(
                                "menubar.rectangle",
                                PMString("ext.tv.settings.tabBar"),
                                tabBarSummary,
                                action: { showsTabBarSettings = true }
                            )
                            settingDivider
                            navRow(
                                "rectangle.grid.1x2",
                                PMString("ext.tv.settings.homeSections"),
                                TVHomeSectionsSettingsView.summary(homeSectionsRawValue),
                                action: { showsHomeSectionsSettings = true }
                            )
                        }
                        settingsSection(String(localized: "playback")) {
                            toggleRow(
                                "infinity",
                                String(localized: "auto_continue_similar"),
                                isOn: $autoContinueSimilar
                            )
                            settingDivider
                            toggleRow(
                                "moon.zzz",
                                String(format: String(localized: "listening_scene_night_timer_setting %lld"), ListeningScene.nightSleepTimerMinutes),
                                isOn: $nightSceneSleepTimer
                            )
                            settingDivider
                            navRow("shuffle", String(localized: "medley_title"),
                                   String(format: String(localized: "seconds_value_format"), store.medleySegmentSeconds),
                                   action: { showsMedleySettings = true })
                            settingDivider
                            navRow("sparkles.tv", PMString("ext.tv.settings.immersive"),
                                   immersiveEffect.localizedTitle,
                                   action: { showsEffectPicker = true })
                            settingDivider
                            toggleRow(
                                "photo.stack.fill",
                                PMString("player_animated_artwork"),
                                isOn: $animatedArtworkEnabled
                            )
                            settingDivider
                            appleMusicRow
                            settingDivider
                            siriRow
                        }
                        lyricsTranslationSection
                        settingsSection(PMString("ext.tv.settings.library")) {
                            toggleRow(
                                "star.bubble",
                                String(localized: "library_review_feature_title"),
                                isOn: $ratingsAndCommentsEnabled
                            )
                            settingDivider
                            navRow("arrow.clockwise", String(localized: "metadata"), PMString("tv_metadata_reread")) {
                                showsMetadata = true
                            }
                            settingDivider
                            navRow(
                                "wand.and.stars",
                                String(localized: "metadata_scraping"),
                                TVScraperSettingsView.summary(
                                    enabledCount: store.scraperSettings.enabledSources.count
                                )
                            ) {
                                showsScraperSettings = true
                            }
                            settingDivider
                            navRow("music.note", PMString("ext.tv.settings.library"), libraryStat) { go(.library) }
                            settingDivider
                            infoRow(
                                "person.2",
                                PMString("artist_name_settings_title"),
                                artistRulesValue + " · " + PMString("artist_name_settings_tv_read_only")
                            )
                            settingDivider
                            navRow("music.note.list", PMString("ext.tv.settings.playlists"), PMString("ext.tv.countOnly", store.playlistCount)) { go(.playlists) }
                            settingDivider
                            navRow("server.rack", PMString("ext.tv.settings.sources"), PMString("ext.tv.countOnly", store.sourceCount)) { go(.sources) }
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
                                    action: { showsAISettings = true }
                                )
                            }
                        }
                        settingsSection(String(localized: "about")) {
                            navRow("star.bubble", PMString("rate_on_app_store"), "App Store", trailing: "arrow.up.right") {
                                openURL(PrimuseAppStore.reviewURL)
                            }
                            settingDivider
                            infoRow("info.circle", PMString("ext.tv.settings.about"), "\(version) (\(build)) · tvOS \(osVersion)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 20) {
                        Text(PMString("ext.tv.settings.remoteTips"))
                            .tvFont(.cardTitle)
                            .foregroundStyle(TVColor.text)
                        HStack { Spacer(); TVSiriRemote(); Spacer() }
                            .padding(.bottom, 8)
                        TVRemoteHint(PMString("ext.tv.settings.tip.touch.title"), PMString("ext.tv.settings.tip.touch.body"))
                        TVRemoteHint(PMString("ext.tv.remote.transportButton"), PMString("ext.tv.remote.transportShortcuts"))
                        TVRemoteHint(PMString("ext.tv.settings.tip.menu.title"), PMString("ext.tv.settings.tip.menu.body"))
                        TVRemoteHint(PMString("ext.tv.settings.tip.search.title"), PMString("ext.tv.settings.tip.search.body"))
                    }
                    .padding(28)
                    .frame(width: 400, alignment: .leading)
                    .tvPanel(radius: 20)
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(showsEffectPicker || showsThemePicker || showsTranslationModelRemoval)
            .accessibilityHidden(showsEffectPicker || showsThemePicker || showsTranslationModelRemoval)

            if showsEffectPicker {
                TVFullscreenEffectPicker(
                    selectedRawValue: $immersiveEffectRawValue,
                    lyricsMotionEnabled: $lyricsMotionEnabled,
                    onDismiss: { showsEffectPicker = false }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            if showsTranslationModelRemoval {
                translationModelRemovalConfirmation
                    .transition(.opacity)
                    .zIndex(12)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: showsTranslationModelRemoval)
        .fullScreenCover(isPresented: $showsMedleySettings) { TVMedleySettingsView() }
        .fullScreenCover(isPresented: $showsTabBarSettings) { TVTabBarSettingsView() }
        .fullScreenCover(isPresented: $showsHomeSectionsSettings) {
            TVHomeSectionsSettingsView().environment(intelligence)
        }
        .fullScreenCover(isPresented: $showsBackdropSettings) { TVPlayerBackdropSettingsView() }
        .fullScreenCover(isPresented: $showsAISettings) {
            TVAISettingsView()
                .environment(intelligence)
        }
        .fullScreenCover(isPresented: $showsMetadata) {
            TVMetadataMaintenanceView().environment(store)
        }
        .fullScreenCover(isPresented: $showsScraperSettings) {
            TVScraperSettingsView().environment(store)
        }
        .preferredColorScheme(appearance.colorScheme)
        .onExitCommand {
            if showsTabBarSettings {
                showsTabBarSettings = false
            } else if showsHomeSectionsSettings {
                showsHomeSectionsSettings = false
            } else if showsMetadata {
                showsMetadata = false
            } else if showsScraperSettings {
                showsScraperSettings = false
            } else if showsTranslationModelRemoval {
                showsTranslationModelRemoval = false
            } else if showsAISettings {
                showsAISettings = false
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

    // MARK: Lyrics translation

    /// Apple TV has no system translator: lyrics are translated only by the
    /// downloadable offline model, so the targets are the languages it covers.
    private static let translationTargets = [
        LocalLyricTranslationPolicy.persianIdentity,
        LocalLyricTranslationPolicy.englishIdentity,
    ]

    private var translationTarget: String {
        let current = LyricsTranslationSettingsStore.normalizedLanguageCode(translationSettings.targetLanguageCode)
        return Self.translationTargets.first {
            LyricTranslationGroupingPolicy.representsSameTranslationLanguage($0, current)
        } ?? Self.translationTargets[0]
    }

    @ViewBuilder
    private var lyricsTranslationSection: some View {
        settingsSection(String(localized: "lyrics_translation_section")) {
            toggleRow(
                "character.bubble",
                String(localized: "lyrics_translation_enabled"),
                isOn: Binding(
                    get: { translationSettings.isEnabled },
                    set: { enabled in
                        if enabled {
                            translationSettings.targetLanguageCode = translationTarget
                        }
                        translationSettings.isEnabled = enabled
                    }
                )
            )
            if translationSettings.isEnabled {
                settingDivider
                navRow(
                    "globe",
                    String(localized: "lyrics_translation_target"),
                    Locale.current.localizedString(forIdentifier: translationTarget) ?? translationTarget,
                    trailing: "arrow.left.arrow.right"
                ) {
                    let index = Self.translationTargets.firstIndex(of: translationTarget) ?? 0
                    translationSettings.targetLanguageCode =
                        Self.translationTargets[(index + 1) % Self.translationTargets.count]
                }
                ForEach(LocalLyricsTranslationModel.Pack.allCases) { pack in
                    if localTranslation.modelState(for: pack) != .unsupportedSystem {
                        settingDivider
                        navRow(
                            "arrow.down.circle",
                            String(localized: String.LocalizationValue(pack.pairsKey)),
                            translationModelStatus(for: pack),
                            trailing: translationModelTrailingIcon(for: pack)
                        ) { translationModelAction(for: pack) }
                    }
                }
            }
        }
        .task { localTranslation.refreshAvailability() }
    }

    private func translationModelStatus(for pack: LocalLyricsTranslationModel.Pack) -> String {
        switch localTranslation.modelState(for: pack) {
        case .ready:
            return String(localized: "lyrics_translation_local_ready")
        case .downloading(let fraction):
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        case .failed:
            return localTranslation.modelFailureReason(for: pack) ?? String(localized: "lyrics_translation_local_retry")
        case .notDownloaded, .unsupportedSystem:
            return String(
                format: String(localized: "lyrics_translation_local_download_size_format"),
                ByteCountFormatter.string(
                    fromByteCount: pack.approximateDownloadBytes,
                    countStyle: .file
                )
            )
        }
    }

    private func translationModelTrailingIcon(for pack: LocalLyricsTranslationModel.Pack) -> String {
        switch localTranslation.modelState(for: pack) {
        case .ready: return "trash"
        case .failed: return "arrow.clockwise"
        case .downloading: return "hourglass"
        case .notDownloaded, .unsupportedSystem: return "arrow.down.circle"
        }
    }

    private func translationModelAction(for pack: LocalLyricsTranslationModel.Pack) {
        switch localTranslation.modelState(for: pack) {
        case .notDownloaded, .failed:
            localTranslation.downloadModel(pack)
        case .ready:
            translationModelRemovalPack = pack
            showsTranslationModelRemoval = true
        case .downloading, .unsupportedSystem:
            break
        }
    }

    private var translationModelRemovalConfirmation: some View {
        ZStack {
            TVColor.bg.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("lyrics_translation_local_remove_confirm").tvFont(.sectionTitle)
                HStack(spacing: 18) {
                    TVPillButton(
                        title: String(localized: "lyrics_translation_local_remove"),
                        systemImage: "trash",
                        style: .solid
                    ) {
                        showsTranslationModelRemoval = false
                        Task { await localTranslation.removeModel(translationModelRemovalPack) }
                    }
                    TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") {
                        showsTranslationModelRemoval = false
                    }
                }
            }
            .padding(36)
            .frame(width: 780, alignment: .leading)
            .tvPanel(radius: 22)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.textMuted)
            VStack(spacing: 0, content: content).tvPanel(radius: 20)
        }
        .padding(.bottom, 34)
        .focusSection()
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
        HStack(spacing: 18) {
            settingIcon("circle.lefthalf.filled", focused: false)
            Text(PMString("ext.tv.settings.appearance"))
                .tvFont(.cardTitle, weight: .medium)
                .foregroundStyle(TVColor.text)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(TVAppearancePreference.allCases, id: \.self) { preference in
                    let isSelected = appearance == preference
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0) {
                        appearanceState.select(preference)
                    } label: { focused in
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

        return HStack(spacing: 18) {
            settingIcon("sun.haze.fill", focused: false)
            Text(PMString("ext.tv.settings.ambientIntensity"))
                .tvFont(.cardTitle, weight: .medium)
                .foregroundStyle(TVColor.text)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(choices, id: \.value) { choice in
                    let isSelected = choice.value == selectedValue
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0) {
                        ambientStrength = choice.value
                    } label: { focused in
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
    }

    private func settingIcon(_ icon: String, focused: Bool) -> some View {
        Image(systemName: icon).font(.system(size: 20, weight: .semibold))
            .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
            .frame(width: 40, height: 40)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surface),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            navRow("mic.fill", title, PMString("ext.tv.settings.siri.authorize"), action: authorizeSiri)
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

    private func navRow(_ icon: String, _ title: String, _ value: String,
                        trailing: String = "chevron.right",
                        action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: action) { focused in
            HStack(spacing: 18) {
                settingIcon(icon, focused: focused)
                Text(title).tvFont(.cardTitle, weight: focused ? .bold : .medium).foregroundStyle(TVColor.text)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: 0)
                Text(value).tvFont(.eyebrow, weight: .regular).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.trailing).lineLimit(2)
                Image(systemName: trailing).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(focused ? TVColor.text : TVColor.textGhost)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : .clear)
        }
    }

    /// 开关行 — 真实持久化偏好(@AppStorage),启动时被读取。
    private func toggleRow(_ icon: String, _ title: String, isOn: Binding<Bool>) -> some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: { isOn.wrappedValue.toggle() }) { focused in
            HStack(spacing: 18) {
                settingIcon(icon, focused: focused)
                Text(title).tvFont(.cardTitle, weight: focused ? .bold : .medium).foregroundStyle(TVColor.text)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: 0)
                ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Capsule().fill(isOn.wrappedValue ? AnyShapeStyle(TVColor.brand)
                                                     : AnyShapeStyle(TVColor.surfaceStrong))
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: isOn.wrappedValue)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : .clear)
            .accessibilityValue(Text(isOn.wrappedValue
                ? PMString("ext.tv.sources.status.enabled")
                : PMString("ext.tv.sources.status.disabled")))
        }
    }

    /// 只读信息行(不可聚焦)。
    private func infoRow(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 18) {
            settingIcon(icon, focused: false)
            Text(title).tvFont(.cardTitle, weight: .medium).foregroundStyle(TVColor.text)
            Spacer(minLength: 0)
            Text(value).tvFont(.eyebrow, weight: .regular).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.clear)
    }

    private var settingDivider: some View {
        Rectangle()
            .fill(TVColor.divider)
            .frame(height: 1)
            .padding(.leading, 80)
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
                    ForEach(AppThemePreferences.swatches) { swatch in
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
        VStack(alignment: .leading, spacing: 5) {
            Text(binding).tvFont(.caption, weight: .semibold).foregroundStyle(TVColor.text)
            Text(label).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TVSiriRemote: View {
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
        .frame(width: 108, height: 416)
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
                    Text(PMString("ext.tv.settings.tabBar.footer"))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

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
            Text("library_filters_settings_footer")
                .tvFont(.caption)
                .foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .tvFont(.cardTitle, weight: focused ? .bold : .medium)
                            .foregroundStyle(isShown ? TVColor.text : TVColor.textMuted)
                        if let hint {
                            Text(hint)
                                .tvFont(.meta)
                                .foregroundStyle(TVColor.textFaint)
                        }
                    }
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
                    Text(PMString("ext.tv.settings.homeSections.footer"))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

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

    /// 与首页上这一排的标题一致:推荐那一排开着智能服务时叫「场景推荐」。
    private func title(_ section: TVHomeSection) -> String {
        switch section {
        case .albumPick: String(localized: "home_section_album_pick")
        case .homeScenes: String(localized: "listening_scene_row_title")
        case .recommendations:
            intelligence.shouldShowRemoteRecommendations
                ? PMString("ai_recommendation_home_title")
                : PMString("ext.tv.home.madeForYou")
        case .recentlyPlayed: PMString("ext.tv.home.recentlyPlayed")
        case .likedAlbums: String(localized: "library_liked_albums_title")
        case .recentlyAdded: PMString("ext.tv.home.recentlyAdded")
        case .radio: PMString("ext.tv.radio.title")
        }
    }

    private static func icon(_ section: TVHomeSection) -> String {
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
