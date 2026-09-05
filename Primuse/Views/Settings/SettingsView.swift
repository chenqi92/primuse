import CloudKit
import SwiftUI
import PrimuseKit
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Environment(MusicIntelligenceService.self) private var musicIntelligence
    @Binding private var scraperSettingsRoute: ScraperSettingsRouteState
    @State private var path: [SettingsDestination] = []
    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var rootItemID: String?
    @State private var rootFocusRevision = UUID()
    #if os(iOS)
    @AppStorage(AppNavigationMode.storageKey)
    private var navigationModeRawValue = AppNavigationMode.standard.rawValue
    #endif

    init(scraperSettingsRoute: Binding<ScraperSettingsRouteState> = .constant(.init())) {
        _scraperSettingsRoute = scraperSettingsRoute
    }

    private var recentItems: [SettingDefinition] {
        SettingsSearchHistory.shared.ids.compactMap { SettingsCatalog.byID[$0] }
            .filter { musicIntelligence.shouldExposeRemoteConfiguration || $0.page != .intelligence }
    }

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            searchableNavigation.searchToolbarBehavior(.minimize)
        } else {
            searchableNavigation
        }
        #else
        searchableNavigation
        #endif
    }

    private var searchableNavigation: some View {
        NavigationStack(path: $path) {
            SettingsFocusedPage(itemID: rootItemID) {
                List {
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResults
                    } else if isSearchPresented && !recentItems.isEmpty {
                        Section {
                            ForEach(recentItems) { item in
                                Button { open(item) } label: { SettingsSearchResultRow(item: item) }
                                    .buttonStyle(.plain)
                            }
                        } header: {
                            HStack {
                                Text(SettingsStrings.text("Recently used"))
                                Spacer()
                                Button(SettingsStrings.text("Clear")) { SettingsSearchHistory.shared.clear() }
                                    .textCase(nil)
                            }
                        }
                    } else {
                        settingsRows
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .id(rootFocusRevision)
            // Search belongs to this column; putting it on the stack hides it in iPad split view.
            .searchable(text: $query, isPresented: $isSearchPresented, placement: .toolbar,
                        prompt: Text(SettingsStrings.text("Search settings")))
            .autocorrectionDisabled()
            .navigationTitle("settings_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            #if os(iOS)
            .toolbar(AppNavigationMode.resolve(navigationModeRawValue) == .minimal ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if #available(iOS 26.0, *) {
                    if AppNavigationMode.resolve(navigationModeRawValue) == .minimal {
                        DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    } else {
                        DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                    }
                }
            }
            #endif
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .page(let page, let itemID):
                    SettingsFocusedPage(itemID: itemID, page: page) { SettingsPageContent(page: page) }
                        .id(destination)
                        .onAppear {
                            if itemID == nil { SettingsSearchHistory.shared.record(page.id) }
                        }
                }
            }
            .onChange(of: scraperSettingsRoute.isMetadataScrapingPresented, initial: true) { _, requested in
                guard requested else { return }
                path = [.page(.scraping, nil)]
                scraperSettingsRoute.setMetadataScrapingPresented(false)
            }
            .onChange(of: SettingsNavigation.shared.request, initial: true) { _, request in
                guard let request, SettingsNavigation.shared.presentedToken != request.token,
                      let item = SettingsCatalog.byID[request.settingID] else { return }
                SettingsNavigation.shared.presentedToken = request.token
                path = []
                open(item)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let results = SettingsCatalog.search(query, showsIntelligence: musicIntelligence.shouldExposeRemoteConfiguration)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ForEach(results) { item in
                Button { open(item) } label: { SettingsSearchResultRow(item: item) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func open(_ item: SettingDefinition) {
        guard let page = item.page else { return }
        SettingsSearchHistory.shared.record(item.id)
        if page == .about || page == .appleTV {
            isSearchPresented = false
            query = ""
            path = []
            rootItemID = item.id
            rootFocusRevision = UUID()
        } else {
            path.append(.page(page, item.isPage ? nil : item.id))
        }
    }

    @ViewBuilder private var settingsRows: some View {
        Section("library") {
            NavigationLink(value: SettingsDestination.page(.sources, nil)) {
                Label("manage_sources", systemImage: "externaldrive.connected.to.line.below")
            }

            NavigationLink(value: SettingsDestination.page(.scraping, nil)) {
                Label("metadata_scraping", systemImage: "wand.and.stars")
            }

            NavigationLink(value: SettingsDestination.page(.artists, nil)) {
                Label("artist_name_settings_title", systemImage: "person.2")
            }

            NavigationLink(value: SettingsDestination.page(.lyrics, nil)) {
                Label("lyrics_settings_title", systemImage: "character.bubble")
            }

            NavigationLink(value: SettingsDestination.page(.duplicates, nil)) {
                Label("dup_title", systemImage: "square.stack.3d.up.badge.automatic")
            }

            NavigationLink(value: SettingsDestination.page(.storage, nil)) {
                Label("storage_management", systemImage: "internaldrive")
            }

            NavigationLink(value: SettingsDestination.page(.deleted, nil)) {
                Label("recently_deleted", systemImage: "trash")
            }
        }

        Section("playback") {
            NavigationLink(value: SettingsDestination.page(.playback, nil)) {
                Label("playback_settings", systemImage: "play.circle")
            }

            NavigationLink(value: SettingsDestination.page(.equalizer, nil)) {
                Label("equalizer", systemImage: "slider.horizontal.3")
            }

            NavigationLink(value: SettingsDestination.page(.effects, nil)) {
                Label("audio_effects", systemImage: "waveform.badge.plus")
            }

            #if os(iOS)
            NavigationLink(value: SettingsDestination.page(.siri, nil)) {
                Label("Siri", systemImage: "waveform")
            }
            #endif
        }

        Section("appearance") {
            #if os(iOS)
            NavigationLink(value: SettingsDestination.page(.appearance, nil)) {
                Label("appearance", systemImage: "circle.lefthalf.filled")
            }

            NavigationLink(value: SettingsDestination.page(.themeColor, nil)) {
                Label("theme_color_title", systemImage: "paintpalette")
            }

            NavigationLink(value: SettingsDestination.page(.player, nil)) {
                Label("player_appearance_title", systemImage: "play.rectangle")
            }

            NavigationLink(value: SettingsDestination.page(.fullscreen, nil)) {
                Label("fullscreen_effect_settings_title", systemImage: "viewfinder.rectangular")
            }

            NavigationLink(value: SettingsDestination.page(.appIcon, nil)) {
                Label("app_icon", systemImage: "app.badge")
            }
            #endif

            NavigationLink(value: SettingsDestination.page(.home, nil)) {
                Label("home_settings_title", systemImage: "house")
            }

            NavigationLink(value: SettingsDestination.page(.libraryDisplay, nil)) {
                Label("library_display_settings_title", systemImage: "rectangle.grid.1x2")
            }
        }

        Section("sync") {
            NavigationLink(value: SettingsDestination.page(.cloud, nil)) {
                Label("icloud_sync_title", systemImage: "icloud")
            }

            NavigationLink(value: SettingsDestination.page(.family, nil)) {
                Label("family_sharing_title", systemImage: "person.2.fill")
            }
        }

        Section("services_integrations") {
            if musicIntelligence.shouldExposeRemoteConfiguration {
                NavigationLink(value: SettingsDestination.page(.intelligence, nil)) {
                    Label("ai_settings_title", systemImage: "sparkles")
                }
            }

            NavigationLink(value: SettingsDestination.page(.appleMusic, nil)) {
                Label("settings_apple_music_section", systemImage: "applelogo")
            }

            NavigationLink(value: SettingsDestination.page(.scrobble, nil)) {
                Label("scrobble_title", systemImage: "music.note.list")
            }

            NavigationLink(value: SettingsDestination.page(.statistics, nil)) {
                Label("stats_title", systemImage: "chart.bar.xaxis")
            }

            NavigationLink(value: SettingsDestination.page(.dlna, nil)) {
                Label("settings_dlna_section", systemImage: "antenna.radiowaves.left.and.right")
            }
        }

        Section {
            AppleTVPushRow()

            NavigationLink(value: SettingsDestination.page(.relay, nil)) {
                Label("settings_relay_section", systemImage: "appletv")
            }
        } header: {
            Text("settings_appletv_section")
        }
        .settingsAnchor("page.appleTV")

        Section("security") {
            NavigationLink(value: SettingsDestination.page(.domains, nil)) {
                HStack {
                    Label("trusted_domains", systemImage: "lock.shield")
                    Spacer()
                    Text("\(SSLTrustStore.shared.trustedDomains.count + SSLTrustStore.shared.insecureHTTPDomains.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            HStack {
                Label("version", systemImage: "number")
                Spacer()
                Text(Bundle.main.appVersion)
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor("about.version")

            HStack {
                Label("build", systemImage: "hammer")
                Spacer()
                Text(Bundle.main.appBuildNumber)
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor("about.build")

            CheckForUpdateRow()

            NavigationLink(value: SettingsDestination.page(.diagnostics, nil)) {
                Label(String(localized: "diagnostics_title"), systemImage: "stethoscope")
            }

            NavigationLink(value: SettingsDestination.page(.licenses, nil)) {
                Label("licenses", systemImage: "doc.text")
            }

            Link(destination: PrimuseAppStore.reviewURL) {
                Label("rate_on_app_store", systemImage: "star.bubble")
            }
            .settingsAnchor("about.rate")

            Link(destination: URL(string: "https://github.com/chenqi92/primuse")!) {
                Label("github_repository", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .settingsAnchor("about.repository")

            Link(destination: URL(string: "https://github.com/chenqi92/primuse/issues/new/choose")!) {
                Label("github_feedback", systemImage: "exclamationmark.bubble")
            }
            .settingsAnchor("about.feedback")
        } header: {
            Text("about")
        }
        .settingsAnchor("page.about")
    }
}

private struct SettingsPageContent: View {
    let page: SettingsPage

    @ViewBuilder var body: some View {
        switch page {
        case .playback: PlaybackSettingsView()
        case .equalizer: EqualizerView()
        case .effects: AudioEffectsView()
        case .lyrics: LyricsSettingsView()
        case .transcription: GoogleLyricsTranscriptionSettingsView()
        case .sources: SourcesContentView()
        case .scraping: MetadataScrapingView()
        case .artists: ArtistNameSettingsView()
        case .duplicates: DuplicateSongsView()
        case .deleted: RecentlyDeletedView()
        case .storage: StorageManagementView()
        case .home: HomeSectionsSettingsView()
        case .libraryDisplay: LibraryDisplaySettingsView()
        case .cloud: CloudSyncSettingsView()
        case .family: FamilySharingSettingsView()
        case .appleTV, .about: EmptyView()
        case .relay: RelaySettingsView()
        case .dlna: DLNARendererSettingsView()
        case .intelligence: AISettingsView()
        case .appleMusic: AppleMusicSettingsView()
        case .scrobble: ScrobbleSettingsView()
        case .statistics: ListeningStatsView()
        case .domains: TrustedDomainsView()
        case .diagnostics: DiagnosticReportsView(service: AppServices.shared.crashDiagnostics)
        case .licenses: LicensesView()
        #if os(iOS)
        case .appearance: AppearanceSettingsView()
        case .themeColor: ThemeColorSettingsView()
        case .player: PlayerAppearanceSettingsView()
        case .fullscreen: FullscreenPlayerEffectSettingsView()
        case .appIcon: AppIconSettingsView()
        case .cacheSync: StorageManagementView(opensCacheSync: true)
        case .siri: SiriSettingsView()
        #else
        case .appearance, .themeColor, .player, .fullscreen, .appIcon, .cacheSync, .siri: EmptyView()
        #endif
        case .keyboard, .widgets: EmptyView()
        }
    }
}

#if os(iOS)
private struct PlayerAppearanceSettingsView: View {
    @AppStorage(PlayerAppearancePreferences.animatedArtworkEnabledKey)
    private var animatedArtworkEnabled = PlayerAppearancePreferences.animatedArtworkEnabledByDefault
    @AppStorage(PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyKey)
    private var animatedArtworkUnmeteredOnly = PlayerAppearancePreferences.animatedArtworkUnmeteredOnlyByDefault
    @AppStorage(PlayerAppearancePreferences.motionArtworkServiceEnabledKey)
    private var motionArtworkServiceEnabled = PlayerAppearancePreferences.motionArtworkServiceEnabledByDefault
    @AppStorage(PlayerAppearancePreferences.motionArtworkServiceEndpointKey)
    private var motionArtworkServiceEndpoint = PlayerAppearancePreferences.motionArtworkServiceEndpointByDefault
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.lyricsAlignmentKey)
    private var lyricsAlignmentRawValue = PlayerLyricsAlignment.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.lyricsColorModeKey)
    private var lyricsColorModeRawValue = PlayerLyricsColorMode.defaultValue.rawValue
    @AppStorage(PlayerAppearancePreferences.customLyricsColorHexKey)
    private var customLyricsColorHex = PlayerAppearancePreferences.defaultCustomLyricsColorHex
    @AppStorage(PlayerAppearancePreferences.gradientLyricsStartColorHexKey)
    private var gradientLyricsStartColorHex = PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
    @AppStorage(PlayerAppearancePreferences.gradientLyricsEndColorHexKey)
    private var gradientLyricsEndColorHex = PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
    @AppStorage(PlayerAppearancePreferences.blursInactiveLyricsKey)
    private var blursInactiveLyrics = PlayerAppearancePreferences.blursInactiveLyricsByDefault
    @AppStorage(PlayerAppearancePreferences.keepsScreenAwakeForLyricsKey)
    private var keepsScreenAwakeForLyrics =
        PlayerAppearancePreferences.keepsScreenAwakeForLyricsByDefault
    @AppStorage(PlayerAppearancePreferences.tapLyricsToSeekKey)
    private var tapLyricsToSeek = PlayerAppearancePreferences.tapLyricsToSeekByDefault

    private var lyricsAlignment: Binding<PlayerLyricsAlignment> {
        Binding(
            get: {
                PlayerLyricsAlignment(rawValue: lyricsAlignmentRawValue) ?? .defaultValue
            },
            set: { lyricsAlignmentRawValue = $0.rawValue }
        )
    }

    private var selectedLyricsColorMode: PlayerLyricsColorMode {
        PlayerLyricsColorMode(rawValue: lyricsColorModeRawValue) ?? .defaultValue
    }

    private var lyricsColorMode: Binding<PlayerLyricsColorMode> {
        Binding(
            get: { selectedLyricsColorMode },
            set: { lyricsColorModeRawValue = $0.rawValue }
        )
    }

    private var customLyricsColor: Binding<Color> {
        storedColorBinding(
            $customLyricsColorHex,
            fallback: PlayerAppearancePreferences.defaultCustomLyricsColorHex
        )
    }

    private var gradientLyricsStartColor: Binding<Color> {
        storedColorBinding(
            $gradientLyricsStartColorHex,
            fallback: PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
        )
    }

    private var gradientLyricsEndColor: Binding<Color> {
        storedColorBinding(
            $gradientLyricsEndColorHex,
            fallback: PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
        )
    }

    private var lyricsColorPreviewStyle: AnyShapeStyle {
        switch selectedLyricsColorMode {
        case .defaultColor:
            AnyShapeStyle(Color.primary)
        case .custom:
            AnyShapeStyle(color(from: customLyricsColorHex, fallback: PlayerAppearancePreferences.defaultCustomLyricsColorHex))
        case .gradient:
            AnyShapeStyle(
                LinearGradient(
                    colors: [
                        color(
                            from: gradientLyricsStartColorHex,
                            fallback: PlayerAppearancePreferences.defaultGradientLyricsStartColorHex
                        ),
                        color(
                            from: gradientLyricsEndColorHex,
                            fallback: PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
                        ),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("player_animated_artwork", isOn: $animatedArtworkEnabled)
                .settingsAnchor("appearance.animatedArtwork")
                    .accessibilityHint(Text("player_animated_artwork_description"))
                Toggle(
                    "player_animated_artwork_unmetered_only",
                    isOn: $animatedArtworkUnmeteredOnly
                )
                .settingsAnchor("appearance.animatedArtworkUnmeteredOnly")
                .disabled(!animatedArtworkEnabled)
                .accessibilityHint(Text("player_animated_artwork_unmetered_only_description"))
            }

            Section {
                Toggle(
                    "motion_artwork_service_enabled",
                    isOn: $motionArtworkServiceEnabled
                )
                .settingsAnchor("appearance.motionArtworkService")
                TextField(
                    "motion_artwork_service_endpoint",
                    text: $motionArtworkServiceEndpoint
                )
                .settingsAnchor("appearance.motionArtworkEndpoint")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(!motionArtworkServiceEnabled)
            } footer: {
                Text("motion_artwork_service_description")
            }

            Section {
                Toggle("player_volume_bar", isOn: $showsVolumeBar)
                .settingsAnchor("appearance.volumeBar")
                    .accessibilityHint(Text("player_volume_bar_description"))
            }

            Section {
                Picker("player_current_lyric_color", selection: lyricsColorMode) {
                    ForEach(PlayerLyricsColorMode.allCases) { mode in
                        Text(mode.localizedTitle)
                            .tag(mode)
                    }
                }
                .settingsAnchor("lyrics.colorMode")
                .pickerStyle(.menu)
                .accessibilityHint(Text("player_current_lyric_color_description"))
                .accessibilityIdentifier("playerLyricsColorModePicker")

                switch selectedLyricsColorMode {
                case .defaultColor:
                    EmptyView()
                case .custom:
                    ColorPicker(
                        "player_lyrics_custom_color",
                        selection: customLyricsColor,
                        supportsOpacity: false
                    )
                    .accessibilityIdentifier("playerLyricsCustomColorPicker")
                case .gradient:
                    ColorPicker(
                        "player_lyrics_gradient_start_color",
                        selection: gradientLyricsStartColor,
                        supportsOpacity: false
                    )
                    .accessibilityIdentifier("playerLyricsGradientStartColorPicker")

                    ColorPicker(
                        "player_lyrics_gradient_end_color",
                        selection: gradientLyricsEndColor,
                        supportsOpacity: false
                    )
                    .accessibilityIdentifier("playerLyricsGradientEndColorPicker")
                }

                HStack(spacing: 12) {
                    Text("player_lyrics_color_preview")
                    Spacer(minLength: 12)
                    Text("player_lyrics_color_preview_sample")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(lyricsColorPreviewStyle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Picker("player_lyrics_alignment", selection: lyricsAlignment) {
                    ForEach(PlayerLyricsAlignment.allCases) { alignment in
                        Text(alignment.localizedTitle)
                            .tag(alignment)
                    }
                }
                .settingsAnchor("lyrics.alignment")
                .pickerStyle(.segmented)

                Toggle("player_blur_inactive_lyrics", isOn: $blursInactiveLyrics)
                .settingsAnchor("lyrics.blurInactive")
                    .accessibilityHint(Text("player_blur_inactive_lyrics_description"))

                Toggle(
                    "player_keep_screen_awake_for_lyrics",
                    isOn: $keepsScreenAwakeForLyrics
                )
                .settingsAnchor("lyrics.keepScreenAwake")
                .accessibilityHint(Text("player_keep_screen_awake_for_lyrics_description"))
                .accessibilityIdentifier("playerKeepScreenAwakeForLyricsToggle")

                Toggle("player_tap_lyrics_to_seek", isOn: $tapLyricsToSeek)
                .settingsAnchor("lyrics.tapToSeek")
                    .accessibilityHint(Text("player_tap_lyrics_to_seek_description"))
                    .accessibilityIdentifier("playerTapLyricsToSeekToggle")
            } header: {
                Text("player_lyrics_section")
            }
        }
        .navigationTitle("player_appearance_title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(from storedHex: String, fallback: String) -> Color {
        Color(
            hex: PlayerAppearancePreferences.normalizedLyricsColorHex(
                storedHex,
                fallback: fallback
            )
        )
    }

    private func storedColorBinding(
        _ storage: Binding<String>,
        fallback: String
    ) -> Binding<Color> {
        Binding(
            get: { color(from: storage.wrappedValue, fallback: fallback) },
            set: { storage.wrappedValue = Self.hex(from: $0, fallback: fallback) }
        )
    }

    private static func hex(from color: Color, fallback: String) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return fallback
        }

        return String(
            format: "%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
    }
}
#endif

private struct LibraryDisplaySettingsView: View {
    @AppStorage(LibrarySongBrowseModePreference.storageKey)
    private var libraryBrowseModeRawValue = LibrarySongBrowseMode.folder.rawValue
    @AppStorage(LibraryDisplayConfiguration.quickAccessLimitKey)
    private var configuredQuickAccessLimit = LibraryDisplayConfiguration.defaultQuickAccessLimit
    @AppStorage(LibraryDisplayConfiguration.sectionOrderKey)
    private var sectionOrderRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.hiddenSectionsKey)
    private var hiddenSectionsRawValue = ""
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customIntentsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetVisibilityPolicy.storageKey)
    private var hiddenRecommendationPresetsRawValue = ""
    @AppStorage(AIRecommendationIntentSelectionPolicy.storageKey)
    private var selectedRecommendationIntentID =
        AIRecommendationIntentSelectionPolicy.defaultSelectionID
    @State private var customIntentTitle = ""
    @State private var customIntentPrompt = ""
    @State private var inspectedRecommendationIntent: AIRecommendationIntentDetails?

    private var quickAccessLimit: Int {
        LibraryDisplayConfiguration.normalizedQuickAccessLimit(configuredQuickAccessLimit)
    }

    private var sectionOrder: [LibrarySection] {
        LibraryDisplayConfiguration.decodeSectionOrder(sectionOrderRawValue)
    }

    private var customIntents: [AICustomRecommendationIntent] {
        AIRecommendationIntentStoragePolicy.decode(customIntentsRawValue)
    }

    private var visibleRecommendationPresets: [AIRecommendationIntentPreset] {
        AIRecommendationIntentPresetVisibilityPolicy.visiblePresets(
            hiddenRecommendationPresetsRawValue
        )
    }

    private var defaultFlatBrowseBinding: Binding<Bool> {
        Binding(
            get: {
                LibrarySongBrowseMode(rawValue: libraryBrowseModeRawValue) == .flat
            },
            set: { isEnabled in
                libraryBrowseModeRawValue = LibrarySongBrowseModePreference
                    .mode(flatViewEnabled: isEnabled)
                    .rawValue
            }
        )
    }

    private var quickAccessLimitBinding: Binding<Double> {
        Binding(
            get: { Double(quickAccessLimit) },
            set: { configuredQuickAccessLimit = Int($0.rounded()) }
        )
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("library_quick_access_count", systemImage: "pin")
                        Spacer()
                        Text("\(quickAccessLimit)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .settingsAnchor("library.quickAccessCount")

                    Slider(
                        value: quickAccessLimitBinding,
                        in: Double(LibraryDisplayConfiguration.quickAccessLimitRange.lowerBound)...Double(
                            LibraryDisplayConfiguration.quickAccessLimitRange.upperBound
                        ),
                        step: 1
                    )
                    .accessibilityLabel(Text("library_quick_access_count"))
                    .accessibilityValue(Text("\(quickAccessLimit)"))
                    .accessibilityHint(Text("library_quick_access_count_description"))
                }
                .padding(.vertical, 4)
            } header: {
                Text("library_quick_access")
            }

            Section {
                ForEach(sectionOrder) { section in
                    Toggle(isOn: visibilityBinding(for: section)) {
                        Label(section.title, systemImage: section.icon)
                    }
                    .accessibilityHint(Text("library_sections_settings_footer"))
                    .settingsAnchor("library.show." + section.rawValue)
                }
                .onMove(perform: moveSections)
            } header: {
                Text("library_sections_settings_label")
            }
            .settingsAnchor("library.sectionOrder")

            Section {
                Button("library_sections_restore_default_order") {
                    sectionOrderRawValue = LibraryDisplayConfiguration.encodeSectionOrder(
                        LibraryDisplayConfiguration.defaultSectionOrder
                    )
                }
                .settingsAnchor("library.restoreOrder")
            }

            Section {
                ForEach(visibleRecommendationPresets, id: \.self) { preset in
                    HStack(alignment: .center, spacing: 10) {
                        Button {
                            inspectedRecommendationIntent = preset.intentDetails
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: preset.localizedTitle)
                                        .font(.body.weight(.semibold))
                                    Text(verbatim: preset.localizedDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            removeRecommendationPreset(preset)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("ai_recommendation_custom_remove"))
                    }
                }

                ForEach(customIntents) { intent in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            inspectedRecommendationIntent = intent.intentDetails
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: intent.title)
                                        .font(.body.weight(.semibold))
                                    Text(verbatim: intent.prompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            removeCustomIntent(id: intent.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("ai_recommendation_custom_remove"))
                    }
                }

                if !AIRecommendationIntentPresetVisibilityPolicy
                    .hiddenPresets(hiddenRecommendationPresetsRawValue).isEmpty {
                    Button(
                        "ai_recommendation_presets_restore",
                        systemImage: "arrow.counterclockwise"
                    ) {
                        restoreRecommendationPresets()
                    }
                }

                TextField("ai_recommendation_custom_title_placeholder", text: $customIntentTitle)
                    .textInputAutocapitalization(.sentences)
                TextField(
                    "ai_recommendation_custom_prompt_placeholder",
                    text: $customIntentPrompt,
                    axis: .vertical
                )
                .lineLimit(2...4)
                Button("ai_recommendation_custom_add", systemImage: "plus") {
                    addCustomIntent()
                }
                .disabled(
                    AIRecommendationIntentStoragePolicy.makeIntent(
                        title: customIntentTitle,
                        prompt: customIntentPrompt
                    ) == nil
                    || customIntents.count
                        >= AIRecommendationIntentStoragePolicy.maximumCustomIntents
                )
            } header: {
                Text("ai_recommendation_intents_settings_title")
            } footer: {
                Text("ai_recommendation_intents_settings_footer")
            }
            .settingsAnchor("library.recommendationDirections")

            Section {
                Toggle("library_default_flat_view", isOn: defaultFlatBrowseBinding)
                .settingsAnchor("library.flatBrowse")
                    .accessibilityHint(Text("library_default_flat_view_description"))
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("library_display_settings_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $inspectedRecommendationIntent) { details in
            AIRecommendationIntentDetailView(details: details)
        }
    }

    private func visibilityBinding(for section: LibrarySection) -> Binding<Bool> {
        Binding(
            get: {
                !LibraryDisplayConfiguration.decodeHiddenSections(hiddenSectionsRawValue)
                    .contains(section)
            },
            set: { isVisible in
                var hidden = LibraryDisplayConfiguration.decodeHiddenSections(
                    hiddenSectionsRawValue
                )
                if isVisible {
                    hidden.remove(section)
                } else {
                    hidden.insert(section)
                }
                hiddenSectionsRawValue = LibraryDisplayConfiguration.encodeHiddenSections(hidden)
            }
        )
    }

    private func moveSections(from source: IndexSet, to destination: Int) {
        var updated = sectionOrder
        updated.move(fromOffsets: source, toOffset: destination)
        sectionOrderRawValue = LibraryDisplayConfiguration.encodeSectionOrder(updated)
    }

    private func removeRecommendationPreset(_ preset: AIRecommendationIntentPreset) {
        hiddenRecommendationPresetsRawValue =
            AIRecommendationIntentPresetVisibilityPolicy.hiding(
                preset,
                in: hiddenRecommendationPresetsRawValue
            )
        CloudKVSSync.shared.markChanged(
            key: AIRecommendationIntentPresetVisibilityPolicy.storageKey
        )
        resetRecommendationSelectionIfNeeded(removing: preset.selectionID)
    }

    private func restoreRecommendationPresets() {
        hiddenRecommendationPresetsRawValue =
            AIRecommendationIntentPresetVisibilityPolicy.restoringAll()
        CloudKVSSync.shared.markChanged(
            key: AIRecommendationIntentPresetVisibilityPolicy.storageKey
        )
    }

    private func addCustomIntent() {
        guard customIntents.count < AIRecommendationIntentStoragePolicy.maximumCustomIntents,
              let intent = AIRecommendationIntentStoragePolicy.makeIntent(
                title: customIntentTitle,
                prompt: customIntentPrompt
              ) else { return }
        customIntentsRawValue = AIRecommendationIntentStoragePolicy.encode(customIntents + [intent])
        customIntentTitle = ""
        customIntentPrompt = ""
        CloudKVSSync.shared.markChanged(key: AIRecommendationIntentStoragePolicy.storageKey)
    }

    private func removeCustomIntent(id: UUID) {
        customIntentsRawValue = AIRecommendationIntentStoragePolicy.encode(
            customIntents.filter { $0.id != id }
        )
        CloudKVSSync.shared.markChanged(key: AIRecommendationIntentStoragePolicy.storageKey)
        resetRecommendationSelectionIfNeeded(removing: "custom:\(id.uuidString)")
    }

    private func resetRecommendationSelectionIfNeeded(removing selectionID: String) {
        guard selectedRecommendationIntentID == selectionID else { return }
        selectedRecommendationIntentID = AIRecommendationIntentSelectionPolicy.defaultSelectionID
        CloudKVSSync.shared.markChanged(
            key: AIRecommendationIntentSelectionPolicy.storageKey
        )
    }
}

private struct AIRecommendationIntentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let details: AIRecommendationIntentDetails

    var body: some View {
        NavigationStack {
            Form {
                Section("ai_recommendation_intent_description_label") {
                    Text(verbatim: details.detail)
                        .textSelection(.enabled)
                }
                if let prompt = details.prompt {
                    Section("ai_recommendation_intent_prompt_label") {
                        Text(verbatim: prompt)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(details.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
    }
}

/// Settings row that lets the user manually poll the App Store. Three
/// visual states:
/// - Idle: tappable "Check for updates" row.
/// - Checking: spinner replaces the chevron.
/// - Result: inline status line under the title — "you're on the
///   latest version" or "version X.Y.Z available, tap to update".
private struct CheckForUpdateRow: View {
    @Environment(AppUpdateChecker.self) private var checker

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
    }

    @State private var status: Status = .idle

    var body: some View {
        Button {
            switch status {
            case .available:
                checker.openAppStore()
            case .idle, .upToDate:
                Task { await runCheck() }
            case .checking:
                break
            }
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("check_for_updates")
                            .foregroundStyle(.primary)
                        if let detail = statusDetail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(statusColor)
                        }
                    }
                    .settingsAnchor("about.update")
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Spacer()
                accessory
            }
        }
        .buttonStyle(.plain)
        .disabled(status == .checking)
    }

    @ViewBuilder
    private var accessory: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.tint)
        default:
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var statusDetail: String? {
        switch status {
        case .idle, .checking:
            return nil
        case .upToDate:
            return String(localized: "check_for_updates_up_to_date")
        case .available(let v):
            return String(format: String(localized: "check_for_updates_available_format"), v)
        }
    }

    private var statusColor: Color {
        switch status {
        case .available: return .accentColor
        default: return .secondary
        }
    }

    private func runCheck() async {
        status = .checking
        // force=true bypasses the 6h throttle so the manual button
        // always actually hits the network.
        await checker.checkForUpdate(force: true)
        if let info = checker.availableUpdate {
            status = .available(version: info.version)
        } else {
            status = .upToDate
        }
    }
}

struct MetadataScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings

    @State private var editingCookieSourceId: String?
    @State private var cookieText = ""
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var shareTarget: ShareTarget?

    /// 分享 sheet 用 — URL 不是 Identifiable，包一层。
    struct ShareTarget: Identifiable {
        let id = UUID()
        let url: URL
    }
    @State private var importError: String?
    @State private var importPreview: ScraperImportSummary?
    @State private var editingConfigSource: ScraperSourceConfig?
    @State private var editingConfigJSON = ""
    @State private var isReordering = false


    var body: some View {
        @Bindable var settings = scraperSettings

        Form {
            Section {
                ForEach(settings.sources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: source.type.iconName)
                            .font(.title3)
                            .foregroundStyle(source.isEnabled ? source.type.themeColor : .secondary)
                            .frame(width: 28)

                        Text(source.type.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if source.type.supportsWordLevelLyrics {
                            Text("lyrics_word_level_badge")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(source.type.themeColor.opacity(0.15))
                                )
                                .foregroundStyle(source.type.themeColor)
                                .accessibilityLabel(Text("lyrics_word_level_hint"))
                        }

                        Spacer()

                        if source.type.supportsCookie {
                            Button {
                                editingCookieSourceId = source.id
                                cookieText = source.cookie ?? ""
                            } label: {
                                Image(systemName: "key")
                                    .font(.caption)
                                    .foregroundStyle(source.cookie?.isEmpty == false ? Color.green : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Toggle("", isOn: Binding(
                            get: { source.isEnabled },
                            set: { _ in scraperSettings.toggleSource(id: source.id) }
                        ))
                        .labelsHidden()
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !source.type.isBuiltIn {
                            Button(role: .destructive) {
                                scraperSettings.removeCustomSource(id: source.id)
                            } label: {
                                Image(systemName: "trash")
                            }

                            Button {
                                if case .custom(let configId) = source.type,
                                   let config = ScraperConfigStore.shared.config(for: configId) {
                                    let encoder = JSONEncoder()
                                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                                    if let data = try? encoder.encode(config),
                                       let json = String(data: data, encoding: .utf8) {
                                        editingConfigJSON = json
                                        editingConfigSource = source
                                    }
                                }
                            } label: {
                                Image(systemName: "doc.text")
                            }
                            .tint(.blue)

                            Button {
                                if let url = makeShareableConfigFile(for: source) {
                                    shareTarget = ShareTarget(url: url)
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .tint(.green)
                        }
                    }
                }
                .onMove { scraperSettings.reorderSources(fromOffsets: $0, toOffset: $1) }
            } header: {
                HStack {
                    Text("scraper_sources")
                    Spacer()
                    Button(isReordering ? String(localized: "done") : String(localized: "reorder")) {
                        withAnimation { isReordering.toggle() }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
                .settingsAnchor("scraping.sources")
            }

            Section {
                Button {
                    importText = ""
                    importError = nil
                    importPreview = nil
                    showImportSheet = true
                } label: {
                    Label("import_scraper_source", systemImage: "plus.circle")
                }
            } header: {
                Text("custom_sources")
            } footer: {
                Text("import_scraper_footer")
            }
            .settingsAnchor("scraping.import")

            Section("scraper_options") {
                Toggle("only_fill_missing", isOn: $settings.onlyFillMissingFields)
                .settingsAnchor("scraping.onlyMissing")

                Button("reset_scraper_defaults") {
                    scraperSettings.resetToDefaults()
                }
                .settingsAnchor("scraping.reset")
                .foregroundStyle(.red)
            }

            Section {
                if scraperService.isScraping {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView(value: scraperService.progress)
                        Text(scraperService.currentSongTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack(spacing: 12) {
                            Text("\(scraperService.processedCount)/\(scraperService.totalCount)")
                            Text("·")
                            Text("\(scraperService.updatedCount) \(String(localized: "updated_count"))")
                            Text("·")
                            Text("\(scraperService.failedCount) \(String(localized: "failed_count"))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        Button("cancel", role: .cancel) {
                            scraperService.cancel()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button("scrape_missing_metadata") {
                        scraperService.scrapeMissingMetadata(in: library)
                    }
                    .settingsAnchor("scraping.fillMissing")

                    Button("rescrape_library") {
                        scraperService.rescrapeLibrary(in: library)
                    }
                    .settingsAnchor("scraping.rescrape")
                }
            } header: {
                Text("scrape_actions")
            } footer: {
                Text("scrape_description")
            }
        }
        .navigationTitle("metadata_scraping")
        #if os(iOS)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .environment(\.editMode, isReordering ? .constant(.active) : .constant(.inactive))
        #endif
        .alert("cookie_config", isPresented: Binding(
            get: { editingCookieSourceId != nil },
            set: { if !$0 { editingCookieSourceId = nil } }
        )) {
            TextField("cookie_placeholder", text: $cookieText)
            Button("save") {
                if let id = editingCookieSourceId {
                    scraperSettings.updateCookie(id: id, cookie: cookieText.isEmpty ? nil : cookieText)
                }
                editingCookieSourceId = nil
            }
            Button("cancel", role: .cancel) {
                editingCookieSourceId = nil
            }
        } message: {
            Text("cookie_config_message")
        }
        .sheet(isPresented: $showImportSheet) {
            importScraperSheet
        }
        .sheet(item: $editingConfigSource) { source in
            editConfigSheet(source: source)
        }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
    }

    /// 把指定源的 ScraperConfig（含 secrets）写入临时文件返回 URL，供 ShareSheet 使用。
    /// 注意：分享出去的 JSON 包含 secrets，因此目标只能是用户私下分享（AirDrop / 信任的私人聊天）。
    private func makeShareableConfigFile(for source: ScraperSourceConfig) -> URL? {
        guard case .custom(let configId) = source.type,
              let config = ScraperConfigStore.shared.config(for: configId) else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ScraperConfig.encode(to:) 默认跳 secrets，先编出主体，再 inject secrets 拼成完整 bundle。
        guard let mainData = try? encoder.encode(config),
              var dict = (try? JSONSerialization.jsonObject(with: mainData)) as? [String: Any] else { return nil }
        if let secrets = config.secrets, !secrets.isEmpty {
            dict["secrets"] = secrets
        }
        guard let bundleData = try? SafeJSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        let safeId = configId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeId.isEmpty ? "scraper" : safeId).json")
        do {
            try bundleData.write(to: url, options: .atomic)
            return url
        } catch {
            plog("⚠️ Share scraper config: write temp file failed: \(error.localizedDescription)")
            return nil
        }
    }

    private var importScraperSheet: some View {
        NavigationStack {
            Form {
                // review 阶段(已生成预览)隐藏输入区, 只显示预览 —— 否则输入栏/键盘
                // 会和预览同屏遮挡, 也容易让人误以为"预览=已导入"。
                if importPreview == nil {
                    Section {
                        TextEditor(text: $importText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200)
                            .textInputAutocapitalization(.never)
                    } footer: {
                        Text("scraper_import_auto_footer")
                    }
                }

                if let error = importError {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }

                if let importPreview {
                    Section {
                        Label("scraper_review_banner", systemImage: "eye.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ScraperImportSummaryView(summary: importPreview)
                }
            }
            .navigationTitle("import_scraper_source")
            #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        plog("📥 Import cancelled (preview discarded)")
                        importPreview = nil
                        showImportSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importPreview == nil
                           ? String(localized: "scraper_review_action")
                           : String(localized: "scraper_confirm_import")) {
                        performImport()
                    }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: importText) { _, _ in
            importPreview = nil
            importError = nil
        }
    }

    private func editConfigSheet(source: ScraperSourceConfig) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $editingConfigJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 300)
                }
            }
            .navigationTitle(source.type.displayName)
            #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { editingConfigSource = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        do {
                            let configs = try ScraperConfigStore.shared.importFromJSON(editingConfigJSON)
                            guard configs.count == 1, let config = configs.first else {
                                plog("Config save error: edit accepts a single source only, got \(configs.count)")
                                return
                            }
                            scraperSettings.addCustomSource(config)
                            editingConfigSource = nil
                        } catch {
                            plog("Config save error: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func performImport() {
        importError = nil
        let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        plog("📥 Import: auto-detect textLen=\(text.count)")

        if let preview = importPreview {
            do {
                let configs = try ScraperConfigStore.shared.importConfigs(preview.configs)
                plog("📥 Import confirmed: count=\(configs.count) ids=\(configs.map(\.id))")
                for config in configs { scraperSettings.addCustomSource(config) }
                importPreview = nil
                showImportSheet = false
            } catch {
                importError = error.localizedDescription
            }
            return
        }

        let input: ScraperImportInput
        do {
            input = try ScraperConfigStore.shared.classifyImportInput(text)
        } catch {
            importError = error.localizedDescription
            return
        }

        switch input {
        case .remoteURL(let url):
            let requestedText = text
            Task {
                do {
                    let preview = try await ScraperConfigStore.shared.previewImportFromURL(url)
                    await MainActor.run {
                        guard importText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedText else { return }
                        importPreview = preview
                    }
                } catch {
                    await MainActor.run {
                        guard importText.trimmingCharacters(in: .whitespacesAndNewlines) == requestedText else { return }
                        importError = error.localizedDescription
                    }
                }
            }
        case .json(let json):
            do {
                importPreview = try ScraperConfigStore.shared.previewImportFromJSON(json)
            } catch {
                plog("📥 Import failed: \(error.localizedDescription)")
                importError = error.localizedDescription
            }
        }
    }
}

struct ScraperImportSummaryView: View {
    let summary: ScraperImportSummary

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                row(String(localized: "scraper_review_source"), summary.sourceDescription)
                row(String(localized: "scraper_review_configs"), summary.configs.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))
                row(String(localized: "scraper_review_capabilities"), summary.capabilities.isEmpty ? String(localized: "scraper_review_unknown") : summary.capabilities.joined(separator: ", "))
                row(String(localized: "scraper_review_requests"), String(format: String(localized: "scraper_review_endpoints_fmt"), summary.endpointCount, summary.methods.joined(separator: ", ")))

                if !summary.domains.isEmpty {
                    tagGroup(title: String(localized: "scraper_review_network_domains"), values: summary.domains)
                }
                if !summary.sslTrustDomains.isEmpty {
                    tagGroup(title: String(localized: "scraper_review_tls_trust_domains"), values: summary.sslTrustDomains)
                }

                HStack(spacing: 8) {
                    permissionBadge(String(localized: "scraper_review_headers"), enabled: summary.includesHeaders)
                    permissionBadge(String(localized: "scraper_review_cookie"), enabled: summary.includesCookie)
                    permissionBadge(String(localized: "scraper_review_secrets"), enabled: summary.includesSecrets)
                    permissionBadge(String(localized: "scraper_review_javascript"), enabled: summary.scriptCharacterCount > 0)
                }
                .font(.caption)

                ForEach(summary.warnings, id: \.self) { warning in
                    Label {
                        Text(verbatim: warning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("scraper_review_header")
        } footer: {
            Text("scraper_review_footer")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }

    private func tagGroup(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(values.chunked(maxItems: 3), id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { value in
                            Text(verbatim: value)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func permissionBadge(_ label: String, enabled: Bool) -> some View {
        Label {
            Text(verbatim: label)
        } icon: {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
        }
        .foregroundStyle(enabled ? .primary : .secondary)
    }
}

private extension Array {
    func chunked(maxItems: Int) -> [[Element]] {
        guard maxItems > 0 else { return [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: maxItems, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
    }
}

struct PlaybackSettingsView: View {
    @Environment(PlaybackSettingsStore.self) private var playbackSettings

    var body: some View {
        @Bindable var settings = playbackSettings

        Form {
            Section {
                Picker("audio_output_mode", selection: $settings.outputMode) {
                    ForEach(AudioOutputMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .settingsAnchor("playback.outputMode")

                Picker("dsd_playback_mode", selection: $settings.dsdPlaybackMode) {
                    ForEach(DSDPlaybackMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .settingsAnchor("playback.dsdMode")
            } header: {
                Text("audio_output_section")
            } footer: {
                Text(settings.outputMode == .highFidelity
                     ? "output_mode_high_fidelity_desc"
                     : "output_mode_effects_desc")
            }

            Section {
                Toggle("output_sr_matching", isOn: Binding(
                    get: { settings.outputMode == .highFidelity || settings.matchOutputSampleRate },
                    set: { settings.matchOutputSampleRate = $0 }
                ))
                .settingsAnchor("playback.matchSampleRate")
            } footer: {
                Text(settings.outputMode == .highFidelity
                     ? "output_sr_matching_fidelity_desc"
                     : "output_sr_matching_desc")
            }
            .disabled(settings.outputMode == .highFidelity)

            Section {
                Toggle("gapless_playback", isOn: $settings.gaplessEnabled)
                .settingsAnchor("playback.gapless")
                    .onChange(of: settings.gaplessEnabled) { _, enabled in
                        if enabled { settings.crossfadeEnabled = false }
                    }
                    .accessibilityHint(Text("gapless_desc"))
            }

            Section {
                Toggle("crossfade", isOn: $settings.crossfadeEnabled)
                .settingsAnchor("playback.crossfade")
                    .onChange(of: settings.crossfadeEnabled) { _, enabled in
                        if enabled { settings.gaplessEnabled = false }
                    }
                    .accessibilityHint(Text("crossfade_desc"))

                if settings.crossfadeEnabled {
                    Picker("crossfade_mode", selection: $settings.crossfadeMode) {
                        ForEach(CrossfadeMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text(settings.crossfadeMode == .smart
                             ? "crossfade_max_duration"
                             : "crossfade_duration")
                            .font(.caption)
                        Slider(value: $settings.crossfadeDuration, in: 1...12, step: 1) {
                            Text(
                                String(
                                    format: String(localized: "stats_seconds_format"),
                                    settings.crossfadeDuration.finiteInt()
                                )
                            )
                        }
                        Text("\(settings.crossfadeDuration.finiteInt()) \(String(localized: "seconds"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(settings.outputMode == .highFidelity)

            Section {
                Toggle("skip_leading_silence", isOn: $settings.skipLeadingSilenceEnabled)
                .settingsAnchor("playback.skipLeadingSilence")
                Toggle("skip_trailing_silence", isOn: $settings.skipTrailingSilenceEnabled)
                .settingsAnchor("playback.skipTrailingSilence")
            } footer: {
                Text("silence_skipping_desc")
            }
            .disabled(settings.outputMode == .highFidelity)

            Section {
                Toggle("replay_gain", isOn: $settings.replayGainEnabled)
                .settingsAnchor("playback.replayGain")
                    .accessibilityHint(Text("replay_gain_desc"))

                if settings.replayGainEnabled {
                    Picker("rg_mode", selection: $settings.replayGainMode) {
                        ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
            }
            .disabled(settings.outputMode == .highFidelity)

            Section {
                Toggle("spatial_audio", isOn: $settings.spatialAudioEnabled)
                .settingsAnchor("playback.spatialAudio")
                    .accessibilityHint(Text("spatial_audio_desc"))

                if settings.spatialAudioEnabled {
                    Toggle("spatial_head_tracking", isOn: $settings.spatialHeadTrackingEnabled)
                        .accessibilityHint(Text("spatial_head_tracking_desc"))
                }
            }
            .disabled(settings.outputMode == .highFidelity)

            Section {
                HStack {
                    Text("playback_rate")
                    Spacer()
                    Text(String(format: "%.2fx", Double(settings.outputMode == .highFidelity ? Float(1) : settings.playbackRate)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { settings.outputMode == .highFidelity ? 1 : settings.playbackRate },
                        set: { settings.playbackRate = $0 }
                    ),
                    in: 0.5...2.0,
                    step: 0.05
                ) {
                    Text("playback_rate")
                } minimumValueLabel: {
                    Text("0.5x").font(.caption2)
                } maximumValueLabel: {
                    Text("2.0x").font(.caption2)
                }
                .settingsAnchor("playback.speed")
                .accessibilityHint(Text("playback_rate_desc"))
                if settings.playbackRate != 1.0 {
                    Button("playback_rate_reset") {
                        settings.playbackRate = 1.0
                    }
                    .font(.caption)
                }
            } header: {
                Text("playback_rate_section")
            }
            .disabled(settings.outputMode == .highFidelity)

            #if os(iOS)
            Section {
                Toggle("lock_screen_lyrics", isOn: $settings.lockScreenLyricsEnabled)
                    .settingsAnchor("lyrics.lockScreen")
            } footer: {
                Text("lock_screen_lyrics_desc")
            }
            #endif
        }
        .navigationTitle("playback_settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Send to Apple TV

/// 一键把当前曲库 + 音乐源 + 凭据(含中继端点)立刻上传到 iCloud,供 Apple TV 拉取。
/// 平时退后台也会自动上传;这个按钮是「立即、可见」的显式入口。
private struct AppleTVPushRow: View {
    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @Environment(MusicLibrary.self) private var musicLibrary
    @State private var pushing = false
    @State private var result: Bool?   // nil=空闲, true=已推送, false=失败
    @State private var transferFailure: AppleTVTransferFailure?

    var body: some View {
        Button {
            guard !pushing else { return }
            pushing = true; result = nil
            transferFailure = nil
            Task {
                switch await musicLibrary.persistNowAndWait() {
                case .success:
                    break
                case .failure(let persistenceFailure):
                    pushing = false
                    result = false
                    transferFailure = persistenceFailure
                    return
                }
                let transfer = await LibrarySnapshotSync.shared.uploadNowResult()
                pushing = false
                switch transfer {
                case .success:
                    result = true
                case .failure(let failure):
                    result = false
                    transferFailure = failure
                }
                try? await Task.sleep(for: .seconds(4))
                result = nil
            }
        } label: {
            HStack {
                Label("settings_push_to_tv", systemImage: "appletv.fill")
                Spacer()
                if pushing {
                    ProgressView()
                } else if let result {
                    Label(result ? "settings_push_to_tv_done" : "settings_push_to_tv_failed",
                          systemImage: result ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .foregroundStyle(result ? .green : .orange)
                }
            }
            .settingsAnchor("appleTV.push")
        }
        .disabled(pushing || !iCloudSyncEnabled)
        .alert(
            String(localized: "settings_push_to_tv_failed"),
            isPresented: Binding(
                get: { transferFailure != nil },
                set: { if !$0 { transferFailure = nil } }
            )
        ) {
            Button("ok") { transferFailure = nil }
        } message: {
            if let transferFailure {
                Text("\(transferFailure.userFacingMessage)\n\(transferFailure.diagnosticCode)")
            }
        }
    }
}

// MARK: - Apple TV Relay

/// Phase 3:Apple TV 局域网中继开关。开启后,登录同一 Apple ID 的 Apple TV
/// 可经本机中继播放本地 / SMB / SFTP / NFS / WebDAV 等无法直连的源。
///
/// 开关持久化用 @AppStorage(`phoneRelayEnabled`,与 PhoneRelayServer 守卫的
/// key 同一个),实际生效靠 onChange 调 server.start/stop;app 启动时
/// AppServices 已按这个 key 自动拉起,所以无需在此恢复状态。
/// 变更后顺手把凭据包(含中继端点)推到 iCloud,让 TV 尽快拿到 / 失效。
struct RelaySettingsView: View {
    @AppStorage(PhoneRelayServer.enabledKey) private var enabled: Bool = false
    @AppStorage("primuse.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @State private var endpoint: RelayEndpoint?

    var body: some View {
        Form {
            Section {
                Text(String(localized: "settings_push_to_tv_footer"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(String(localized: "settings_relay_enable"), isOn: $enabled)
                .settingsAnchor("relay.enabled")
                    .onChange(of: enabled) { _, on in
                        if on { startRelay() } else { PhoneRelayServer.shared.stop() }
                        pushCredentialsToTV(relayOn: on)
                    }

                if enabled {
                    if let endpoint {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.green)
                            Text(verbatim: "\(endpoint.host):\(endpoint.port)")
                                .font(.subheadline.monospacedDigit())
                                .textSelection(.enabled)
                        }
                    } else {
                        HStack {
                            Image(systemName: "wifi.exclamationmark")
                                .foregroundStyle(.orange)
                            Text(String(localized: "settings_relay_waiting"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text(String(localized: "settings_relay_footer"))
                    .font(.footnote)
            }
        }
        .navigationTitle("settings_relay_section")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 进页面 / 开关翻动后刷新端点显示。端口绑定是异步的,开启时轮询几次再读。
        .task(id: enabled) {
            endpoint = enabled ? await waitForEndpoint() : nil
        }
    }

    private func startRelay() {
        let services = AppServices.shared
        PhoneRelayServer.shared.startIfEnabled(
            sourceManager: services.sourceManager,
            sourcesStore: services.sourcesStore,
            library: services.musicLibrary
        )
    }

    /// 把凭据包(含中继端点)覆盖上传到 iCloud。开启时监听端口要等几十毫秒才
    /// ready,先等 endpoint 就绪再传,确保端点进包;关闭时立即传,让 TV 端失效。
    private func pushCredentialsToTV(relayOn: Bool) {
        guard iCloudSyncEnabled else { return }   // iCloud 同步关闭时不上传(中继端点也无从下发)
        Task {
            if relayOn { _ = await waitForEndpoint() }
            await LibrarySnapshotSync.shared.uploadNow()
        }
    }

    /// 轮询直到监听端口绑定好(或 ~1.8s 超时)。未连 Wi-Fi 时始终 nil。
    private func waitForEndpoint() async -> RelayEndpoint? {
        for _ in 0..<12 {
            if let ep = PhoneRelayServer.shared.endpoint() { return ep }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return PhoneRelayServer.shared.endpoint()
    }
}

// MARK: - Storage Management

struct StorageManagementView: View {
    var opensCacheSync = false
    @State private var showsCacheSync = false
    @Environment(SourceManager.self) private var sourceManager
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(MetadataBackfillService.self) private var backfill
    @AppStorage(MetadataBackfillService.wifiOnlyDefaultsKey) private var cloudScanWifiOnly: Bool = true
    @AppStorage(UserNotificationService.notifyLongTasksKey) private var notifyBackfillComplete: Bool = false
    /// 系统授权状态 ── 进页面时查一次。用户在系统 Settings 关掉后, toggle
    /// 仍是 on 但显示"已被系统拒绝"提示, 让用户知道为什么开关无效。
    @State private var notificationStatusDenied: Bool = false
    @State private var audioCacheSize: String = "..."
    @State private var imageCacheSize: String = "..."
    @State private var metadataSize: String = "..."
    @State private var isClearingAudio = false
    @State private var isClearingImages = false
    @State private var isClearingMetadata = false
    @State private var audioBreakdown: SourceManager.AudioCacheBreakdown?
    @State private var isClearingPartials = false
    @State private var isClearingOrphans = false
    /// 清理结果提示 — 失败时让用户知道为什么没全清掉 (通常是当前正在播放的歌)。
    @State private var cacheActionToast: String?
    @State private var logShareItem: LogShareItem?

    struct LogShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        @Bindable var settings = playbackSettings

        List {
            Section {
                Toggle("cloud_scan_wifi_only", isOn: $cloudScanWifiOnly)
                .settingsAnchor("storage.wifiOnly")
                    .onChange(of: cloudScanWifiOnly) { _, _ in
                        // Re-evaluate immediately so the user sees backfill
                        // start (or stop) right after flipping the switch.
                        backfill.refreshQueue()
                    }
                Toggle("notify_backfill_complete", isOn: $notifyBackfillComplete)
                .settingsAnchor("storage.notifyBackfill")
                    .onChange(of: notifyBackfillComplete) { _, on in
                        guard on else { return }
                        // 用户从关 → 开: 主动请求权限。UserNotificationService 内部
                        // 会 lazy 请求, 这里直接发一条 silent 'probe' 触发授权
                        // 弹窗即可; 之前 deny 过的话不会再弹, 我们改用直接查询
                        // UNUserNotificationCenter.notificationSettings() 检测。
                        Task {
                            let center = UNUserNotificationCenter.current()
                            let settings = await center.notificationSettings()
                            if settings.authorizationStatus == .notDetermined {
                                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                                if !granted {
                                    notificationStatusDenied = true
                                }
                            } else if settings.authorizationStatus == .denied {
                                notificationStatusDenied = true
                            }
                        }
                    }
                if notifyBackfillComplete && notificationStatusDenied {
                    Label("notify_permission_denied_hint", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if backfill.statusCount > 0 {
                    HStack {
                        switch backfill.activityState {
                        case .running:
                            Text("backfill_in_progress")
                        case .retrying:
                            Text("backfill_retry_in_progress")
                        case .waitingForWiFi:
                            Label("backfill_waiting_for_wifi", systemImage: "wifi.exclamationmark")
                        case .retryPending:
                            Label("backfill_retry_pending", systemImage: "arrow.clockwise.circle")
                        case .pending, .idle:
                            Text("home_pending_details")
                        }
                        Spacer()
                        Text(String(format: String(localized: "backfill_remaining"), backfill.statusCount))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if backfill.deferredRetryCount(forSource: nil) > 0 {
                        Text(
                            String(
                                format: String(localized: "backfill_retry_count_format"),
                                backfill.deferredRetryCount(forSource: nil)
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    if backfill.activityState == .retryPending {
                        Text(String(
                            format: String(localized: "backfill_retry_pending_hint"),
                            MetadataBackfillRetryPolicy.maximumAutomaticAttempts
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if backfill.failedCount > 0 {
                    Button {
                        backfill.retryFailed()
                    } label: {
                        Label(
                            String(format: String(localized: "backfill_retry_failed"), backfill.failedCount),
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
            } header: {
                Text("network")
            } footer: {
                Text("cloud_scan_wifi_only_footer")
            }
            .task {
                // 进设置页时查一次系统授权状态。如果用户在 Settings 关掉了,
                // toggle 显示打开但 notificationStatusDenied 让 UI 提示。
                if notifyBackfillComplete {
                    let settings = await UNUserNotificationCenter.current().notificationSettings()
                    notificationStatusDenied = (settings.authorizationStatus == .denied)
                }
            }

            Section {
                Toggle("audio_cache_enabled", isOn: $settings.audioCacheEnabled)
                .settingsAnchor("storage.audioCacheEnabled")

                Picker("audio_cache_limit", selection: $settings.audioCacheLimitBytes) {
                    ForEach(
                        AudioCacheLimitPolicy.options(including: settings.audioCacheLimitBytes),
                        id: \.self
                    ) { bytes in
                        Text(formatBytes(bytes)).tag(bytes)
                    }
                }
                .settingsAnchor("storage.audioCacheLimit")

                storageRow(
                    icon: "waveform",
                    title: "audio_cache",
                    size: audioCacheSize,
                    isClearing: isClearingAudio
                ) {
                    isClearingAudio = true
                    Task {
                        let result = await sourceManager.clearAudioCache()
                        await refreshSizes()
                        isClearingAudio = false
                        flashCacheToast(freed: result.freedBytes, failed: result.failedCount)
                    }
                }
                .settingsAnchor("storage.clearAudioCache")

                if let bd = audioBreakdown {
                    audioBreakdownDetail(bd)
                }

                storageRow(
                    icon: "photo",
                    title: "image_cache",
                    size: imageCacheSize,
                    isClearing: isClearingImages
                ) {
                    isClearingImages = true
                    Task {
                        try? await ImageCache.shared.clearDiskCache()
                        CachedArtworkView.clearMemoryCache()
                        await refreshSizes()
                        isClearingImages = false
                    }
                }
                .settingsAnchor("storage.clearImageCache")
            } header: {
                Text("cache")
            } footer: {
                Text("cache_clear_footer")
            }

            Section {
                storageRow(
                    icon: "music.note.list",
                    title: "cover_art_lyrics",
                    size: metadataSize,
                    isClearing: isClearingMetadata
                ) {
                    isClearingMetadata = true
                    Task {
                        await MetadataAssetStore.shared.clearAll()
                        CachedArtworkView.clearMemoryCache()
                        await refreshSizes()
                        isClearingMetadata = false
                    }
                }
                .settingsAnchor("storage.clearMetadata")
            } header: {
                Text("persistent_data")
            } footer: {
                Text("metadata_clear_footer")
            }

            // Debug 区只在 Debug 构建里显示 —— 生产 Release 不出现这个入口,
            // 普通用户看不到 (避免误触把开发日志泄露)。
            #if DEBUG
            Section {
                Button {
                    logShareItem = LogShareItem(url: FileLogger.shared.logFileURL)
                } label: {
                    Label("storage_export_log", systemImage: "square.and.arrow.up.on.square")
                }
            } header: {
                Text("debug")
            } footer: {
                Text("storage_export_log_footer")
            }
            #endif
        }
        .sheet(item: $logShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .navigationTitle("storage_management")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsCacheSync = true
                } label: {
                    Label(CacheSyncLocalization.text("cache_sync_title"), systemImage: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("storage.cacheSync")
            }
        }
        .sheet(isPresented: $showsCacheSync) {
            NavigationStack { IOSAudioCacheSyncView(isPresentedAsSheet: true) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            if opensCacheSync { showsCacheSync = true }
        }
        #endif
        .task { await refreshSizes() }
        .overlay(alignment: .bottom) {
            if let msg = cacheActionToast {
                Text(msg)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func flashCacheToast(freed: Int64, failed: Int) {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        let freedStr = fmt.string(fromByteCount: freed)
        let msg: String
        if failed > 0 {
            // 通常是当前正在播放的歌锁住了文件 — 提示一下用户暂停后重试
            msg = String(format: String(localized: "cache_clear_partial_format"), freedStr, failed)
        } else {
            msg = String(format: String(localized: "cache_clear_done_format"), freedStr)
        }
        withAnimation { cacheActionToast = msg }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { cacheActionToast = nil }
        }
    }

    private func storageRow(
        icon: String,
        title: LocalizedStringKey,
        size: String,
        isClearing: Bool,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if isClearing {
                ProgressView()
            } else {
                Text(size)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) { onClear() } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isClearing)
        }
    }

    @ViewBuilder
    private func audioBreakdownDetail(_ bd: SourceManager.AudioCacheBreakdown) -> some View {
        let fmt = ByteCountFormatter()
        let _ = (fmt.countStyle = .file)

        // 缩进 + 小一号字, 提示是 audio cache 的细分
        VStack(alignment: .leading, spacing: 8) {
            if bd.pinnedBytes > 0 {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.tint).font(.caption)
                    Text("cache_pinned").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.pinnedBytes))
                        .font(.caption).foregroundStyle(.tint).monospacedDigit()
                }
            }

            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary).font(.caption)
                Text("cache_completed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmt.string(fromByteCount: bd.completedBytes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }

            if bd.activeBytes > 0 {
                HStack {
                    Image(systemName: "play.circle")
                        .foregroundStyle(.blue).font(.caption)
                    Text("cache_active").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.activeBytes))
                        .font(.caption).foregroundStyle(.blue).monospacedDigit()
                }
            }

            if bd.prewarmSeedBytes > 0 {
                HStack {
                    Image(systemName: "bolt.circle")
                        .foregroundStyle(.secondary).font(.caption)
                    Text("cache_prewarm_seed").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.prewarmSeedBytes))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            HStack {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary).font(.caption)
                Text("cache_partial").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fmt.string(fromByteCount: bd.partialBytes))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if bd.partialBytes > 0 {
                    Button(role: .destructive) {
                        isClearingPartials = true
                        Task {
                            let result = sourceManager.purgeAllPartialFiles()
                            await refreshSizes()
                            isClearingPartials = false
                            flashCacheToast(freed: result.freedBytes, failed: result.failedCount)
                        }
                    } label: {
                        if isClearingPartials {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "trash").font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isClearingPartials)
                }
            }

            if bd.orphanedBytes > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                    Text("cache_orphaned").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmt.string(fromByteCount: bd.orphanedBytes))
                        .font(.caption).foregroundStyle(.orange).monospacedDigit()
                    Button(role: .destructive) {
                        isClearingOrphans = true
                        Task {
                            await sourceManager.purgeOrphanedAudioCache()
                            await refreshSizes()
                            isClearingOrphans = false
                        }
                    } label: {
                        if isClearingOrphans {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "trash").font(.caption2)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(isClearingOrphans)
                }
            }
        }
        .padding(.leading, 24)
    }

    private func refreshSizes() async {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let audio = await sourceManager.audioCacheSizeAsync()
        audioCacheSize = formatter.string(fromByteCount: audio)
        audioBreakdown = await sourceManager.audioCacheBreakdown()

        let images = (try? await ImageCache.shared.diskCacheSize()) ?? 0
        imageCacheSize = formatter.string(fromByteCount: images)

        let metadata = await MetadataAssetStore.shared.cacheSize()
        metadataSize = formatter.string(fromByteCount: metadata)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes != AudioCacheLimitPolicy.unlimitedBytes else {
            return String(localized: "smart_limit_placeholder")
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Trusted Domains

struct TrustedDomainsView: View {
    @State private var newDomain = ""
    @State private var showAddSSLAlert = false
    @State private var showAddHTTPAlert = false

    var body: some View {
        List {
            Section {
                ForEach(SSLTrustStore.shared.trustedDomains, id: \.self) { domain in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(domain)
                        if let certificate = SSLTrustStore.shared.certificateInfo(for: domain) {
                            if let subject = certificate.subjectSummary,
                               !subject.isEmpty {
                                Text(String(
                                    format: String(localized: "ssl_trust_subject %@"),
                                    subject
                                ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            if let fingerprint = ServerCertificateFingerprint.formatted(
                                certificate.fingerprintSHA256
                            ) {
                                Text(String(
                                    format: String(localized: "ssl_trust_fingerprint %@"),
                                    fingerprint
                                ))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
                .onDelete { indexSet in
                    let domains = SSLTrustStore.shared.trustedDomains
                    for index in indexSet {
                        SSLTrustStore.shared.untrust(domain: domains[index])
                    }
                }

                if SSLTrustStore.shared.trustedDomains.isEmpty {
                    Text("no_trusted_domains")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("https_certificate_trust")
            } footer: {
                Text("trusted_domains_footer")
            }
            .settingsAnchor("security.httpsTrust")

            Section {
                ForEach(SSLTrustStore.shared.insecureHTTPDomains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                        Spacer()
                        Text(verbatim: "HTTP")
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .onDelete { indexSet in
                    let domains = SSLTrustStore.shared.insecureHTTPDomains
                    for index in indexSet {
                        SSLTrustStore.shared.disallowInsecureHTTP(domain: domains[index])
                    }
                }

                if SSLTrustStore.shared.insecureHTTPDomains.isEmpty {
                    Text("no_insecure_http_domains")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("insecure_http_domains")
            } footer: {
                Text("insecure_http_domains_footer")
            }
            .settingsAnchor("security.httpDomains")
        }
        .navigationTitle("trusted_domains")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("add_trusted_domain") {
                        newDomain = ""
                        showAddSSLAlert = true
                    }
                    .settingsAnchor("security.addTrustedDomain")
                    Button("add_insecure_http_domain") {
                        newDomain = ""
                        showAddHTTPAlert = true
                    }
                    .settingsAnchor("security.addHTTPDomain")
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("add_trusted_domain", isPresented: $showAddSSLAlert) {
            TextField("domain_placeholder", text: $newDomain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("add") {
                if let domain = InsecureHTTPHostPolicy.normalizedHost(newDomain) {
                    SSLTrustStore.shared.trust(domain: domain)
                }
                newDomain = ""
            }
            Button("cancel", role: .cancel) { newDomain = "" }
        } message: {
            Text("add_trusted_domain_message")
        }
        .alert("add_insecure_http_domain", isPresented: $showAddHTTPAlert) {
            TextField("domain_placeholder", text: $newDomain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("allow_insecure_http", role: .destructive) {
                if let domain = InsecureHTTPHostPolicy.normalizedHost(newDomain) {
                    SSLTrustStore.shared.allowInsecureHTTP(domain: domain)
                }
                newDomain = ""
            }
            Button("cancel", role: .cancel) { newDomain = "" }
        } message: {
            Text("add_insecure_http_domain_message")
        }
    }
}

struct LicensesView: View {
    var body: some View {
        List {
            Section("open_source") {
                licenseRow("SFBAudioEngine", "MIT License")
                licenseRow("FFmpeg 8.1", "LGPL 2.1+")
                licenseRow("GRDB.swift", "MIT License")
                licenseRow("AMSMB2", "LGPL 2.1")
                licenseRow("FileProvider", "MIT License")
                licenseRow("FLAC", "BSD License")
                licenseRow("mpg123", "LGPL 2.1")
                licenseRow("libsndfile", "LGPL 2.1")
                licenseRow("libogg / libvorbis", "BSD License")
                licenseRow("libopus", "BSD License")
                licenseRow("WavPack", "BSD License")
                licenseRow("Monkey's Audio", "BSD License")
                licenseRow("True Audio (libtta)", "LGPL 2.1")
            }
        }
        .navigationTitle("licenses")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func licenseRow(_ name: String, _ license: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(license)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}


// MARK: - Share Sheet

#if os(iOS)
/// SwiftUI 包装的 `UIActivityViewController`，让任意 view 通过 `.sheet`
/// 弹出系统分享面板（AirDrop / 微信 / 邮件 / 文件 / 等）。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#else
/// macOS 等价物 ── 调用 NSSharingServicePicker。SwiftUI sheet 里用 onAppear
/// 在第一次显示时拉起系统分享面板, 然后立即 dismiss 自身。
struct ShareSheet: View {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                let picker = NSSharingServicePicker(items: items)
                if let window = NSApp.keyWindow,
                   let view = window.contentView {
                    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                }
                dismiss()
            }
    }
}
#endif

// MARK: - Family Sharing Settings

/// 家庭共享设置入口。
/// - 未启用: 显示"创建家庭包"按钮 → enableFamilySharing 拿到 CKShare → 弹
///   UICloudSharingController 让用户发邀请
/// - 已启用 (owner / participant 通用): 显示状态 + "查看 / 邀请" + "解散 /
///   退出" (destructive)
struct FamilySharingSettingsView: View {
    @Environment(CloudKitSyncService.self) private var sync
    @State private var familyEnabled = CloudKitSyncService.familySharingEnabled
    @State private var pendingShare: CKShare?
    @State private var pendingContainer: CKContainer?
    @State private var showSharingController = false
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        Form {
            // 状态 + 主动作 ── 启用状态和"邀请家人"放一起逻辑紧凑
            Section {
                if familyEnabled {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("family_sharing_active")
                            .font(.subheadline)
                    }
                    Button {
                        Task { await openExistingShare() }
                    } label: {
                        Label("family_sharing_manage", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .disabled(isBusy)
                } else {
                    Button {
                        Task { await enable() }
                    } label: {
                        Label("family_sharing_create", systemImage: "person.2.badge.plus")
                    }
                    .disabled(isBusy)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                if !familyEnabled {
                    Text("family_sharing_footer").font(.footnote)
                }
            }
            .settingsAnchor("family.create")

            // 解散 ── 独立 Section, 物理上跟"邀请家人"分开避免 SwiftUI Form
            // 多 Button 同 Section 时点击 highlight 串味。
            if familyEnabled {
                Section {
                    Button(role: .destructive) {
                        Task { await disable() }
                    } label: {
                        Label("family_sharing_leave", systemImage: "person.crop.circle.badge.xmark")
                    }
                    .settingsAnchor("family.leave")
                    .disabled(isBusy)
                } footer: {
                    Text("family_sharing_footer").font(.footnote)
                }
            }

            Section {
                row("family_sharing_shared_playlists", systemImage: "checkmark")
                row("family_sharing_shared_smart", systemImage: "checkmark")
                row("family_sharing_shared_sources", systemImage: "checkmark")
                row("family_sharing_shared_apple_mirror", systemImage: "checkmark")
            } header: {
                Text("family_sharing_shared_header")
            }

            Section {
                row("family_sharing_private_liked", value: "—")
                row("family_sharing_private_history", value: "—")
                row("family_sharing_private_settings", value: "—")
            } header: {
                Text("family_sharing_private_header")
            } footer: {
                Text("family_sharing_scope_footer")
                    .font(.footnote)
            }
        }
        .navigationTitle("family_sharing_title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSharingController) {
            if let share = pendingShare, let container = pendingContainer {
                CloudSharingControllerView(share: share, container: container) {
                    showSharingController = false
                    familyEnabled = CloudKitSyncService.familySharingEnabled
                }
            }
        }
    }

    private func row(_ key: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(key)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func row(_ key: LocalizedStringKey, systemImage: String) -> some View {
        HStack {
            Text(key)
                .font(.subheadline)
            Spacer()
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.green)
        }
    }

    @MainActor
    private func enable() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let share = try await sync.enableFamilySharing()
            guard let container = sync.containerForSharingController() else {
                throw NSError(domain: "Primuse.Cloud", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "cloudkit_unavailable")])
            }
            pendingShare = share
            pendingContainer = container
            familyEnabled = true
            showSharingController = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func openExistingShare() async {
        isBusy = true
        defer { isBusy = false }
        // 重新启用一次拿到当前 share, 让用户能看到成员 / 重新发邀请。
        // enableFamilySharing 是幂等的 ── zone / holder 已在时只追加邀请逻辑。
        do {
            let share = try await sync.enableFamilySharing()
            guard let container = sync.containerForSharingController() else {
                throw NSError(domain: "Primuse.Cloud", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: String(localized: "cloudkit_unavailable")])
            }
            pendingShare = share
            pendingContainer = container
            showSharingController = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func disable() async {
        isBusy = true
        defer { isBusy = false }
        await sync.disableFamilySharing()
        familyEnabled = false
    }
}

#if os(iOS)
/// SwiftUI 包 UICloudSharingController ── Apple 提供的 share 邀请 UI, 自带
/// iMessage / 邮件 / 复制链接发送、成员列表、权限调整、移除成员等全套功能。
/// macOS 没有 UICloudSharingController, 用 NSSharingService 走另一套实现。
struct CloudSharingControllerView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let vc = UICloudSharingController(share: share, container: container)
        vc.delegate = context.coordinator
        vc.availablePermissions = [.allowReadWrite, .allowPrivate]
        return vc
    }

    func updateUIViewController(_ vc: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onDismiss()
        }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {}
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            plog("⚠️ UICloudSharingController save failed: \(error.localizedDescription)")
        }
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "Primuse Family"
        }
    }
}
#else
/// macOS 端 ── 用 NSSharingServicePicker 弹邀请 panel (iCloud sharing 走系统
/// 内置的 sharing service)。stub 占位先编过, 完整 UI 在分析阶段做。
struct CloudSharingControllerView: View {
    let share: CKShare
    let container: CKContainer
    let onDismiss: () -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1).onAppear { onDismiss() }
    }
}
#endif
