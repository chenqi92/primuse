#if os(tvOS)
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

/// tvOS 设置 — 左列常用清单,右列 Siri Remote 图示(对应 TVSettingsArtboard)。
/// 刻意精简:无 EQ 推子 / 刮削源 / SSL 信任,这些留在 macOS / iOS。
struct TVSettingsView: View {
    @Environment(TVStore.self) private var store
    @Environment(TVAppearanceState.self) private var appearanceState
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var onNavigate: (TVRoot.Tab) -> Void = { _ in }
    @AppStorage("tvAutoSync") private var autoSync = true
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
    @State private var showsEffectPicker = tvDebugShowsEffectPicker
    @State private var showsThemePicker = tvDebugShowsThemePicker
    @State private var showsAISettings = false
    @State private var isSyncing = false
    @State private var syncMsg: String?

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
        return syncMsg ?? PMString("ext.tv.settings.tapToPull")
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 64) {
                    VStack(alignment: .leading, spacing: 0) {
                        TVEyebrow(text: PMString("ext.tv.settings.eyebrow")).padding(.bottom, 6)
                        Text(PMString("ext.tv.settings.general"))
                            .font(TVFont.pageTitle)
                            .foregroundStyle(TVColor.text)
                            .padding(.bottom, 24)
                        VStack(spacing: 0) {
                            navRow("icloud.fill", PMString("ext.tv.settings.icloudSync"), syncValue, trailing: "arrow.clockwise", action: sync)
                            settingDivider
                            toggleRow("arrow.triangle.2.circlepath", PMString("ext.tv.settings.autoSync"), isOn: $autoSync)
                            settingDivider
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
                            navRow("sparkles.tv", PMString("ext.tv.settings.immersive"),
                                   immersiveEffect.localizedTitle,
                                   action: { showsEffectPicker = true })
                            settingDivider
                            navRow("music.note", PMString("ext.tv.settings.library"), libraryStat) { go(.library) }
                            settingDivider
                            navRow("music.note.list", PMString("ext.tv.settings.playlists"), PMString("ext.tv.countOnly", store.playlists.count)) { go(.playlists) }
                            settingDivider
                            navRow("server.rack", PMString("ext.tv.settings.sources"), PMString("ext.tv.countOnly", store.sources.count)) { go(.sources) }
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
                            settingDivider
                            navRow("star.bubble", PMString("rate_on_app_store"), "App Store", trailing: "arrow.up.right") {
                                openURL(PrimuseAppStore.reviewURL)
                            }
                            settingDivider
                            infoRow("info.circle", PMString("ext.tv.settings.about"), "\(version) (\(build)) · tvOS \(osVersion)")
                        }
                        .tvPanel(radius: 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 0) {
                        TVEyebrow(text: PMString("ext.tv.settings.remoteTips")).padding(.bottom, 24)
                        VStack(spacing: 0) {
                            HStack { Spacer(); TVSiriRemote(); Spacer() }
                            Rectangle()
                                .fill(TVColor.divider)
                                .frame(height: 1)
                                .padding(.vertical, 24)
                            VStack(alignment: .leading, spacing: 14) {
                                TVRemoteHint(PMString("ext.tv.settings.tip.touch.title"), PMString("ext.tv.settings.tip.touch.body"))
                                TVRemoteHint(PMString("ext.tv.settings.tip.menu.title"), PMString("ext.tv.settings.tip.menu.body"))
                                TVRemoteHint(PMString("ext.tv.settings.tip.tv.title"), PMString("ext.tv.settings.tip.tv.body"))
                                TVRemoteHint(PMString("ext.tv.settings.tip.search.title"), PMString("ext.tv.settings.tip.search.body"))
                            }
                        }
                        .padding(28)
                        .tvPanel(radius: 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 72)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsEffectPicker {
                TVFullscreenEffectPicker(
                    selectedRawValue: $immersiveEffectRawValue,
                    lyricsMotionEnabled: $lyricsMotionEnabled,
                    onDismiss: { showsEffectPicker = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(10)
            }

            if showsThemePicker {
                TVThemeColorPicker(
                    selectedHex: $accentHex,
                    selectedModeRawValue: $themeColorModeRawValue,
                    onDismiss: { showsThemePicker = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: showsEffectPicker)
        .animation(.easeInOut(duration: 0.24), value: showsThemePicker)
        .fullScreenCover(isPresented: $showsAISettings) {
            TVAISettingsContainer()
                .environment(intelligence)
        }
        .preferredColorScheme(appearance.colorScheme)
        .onExitCommand {
            if showsAISettings {
                showsAISettings = false
            } else if showsThemePicker {
                showsThemePicker = false
            } else if showsEffectPicker {
                showsEffectPicker = false
            } else {
                dismiss()
            }
        }
        .onAppear { FullscreenPlayerEffectSync.shared.install() }
    }

    private func sync() {
        guard !isSyncing else { return }
        isSyncing = true
        syncMsg = nil
        Task {
            await store.bootstrap()
            isSyncing = false
            syncMsg = !store.hasRealLibrary ? PMString("ext.tv.settings.noSnapshot") : PMString("ext.tv.settings.synced", TVFmt.count(store.songs.count))
        }
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
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(TVColor.text)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(TVAppearancePreference.allCases, id: \.self) { preference in
                    let isSelected = appearance == preference
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0) {
                        appearanceState.select(preference)
                    } label: { focused in
                        Text(appearanceTitle(preference))
                            .font(.system(size: 16, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(isSelected ? TVColor.onBrand : TVColor.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: 94)
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
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(TVColor.text)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(choices, id: \.value) { choice in
                    let isSelected = choice.value == selectedValue
                    TVFocusButton(radius: 10, scale: 1.04, lift: 0) {
                        ambientStrength = choice.value
                    } label: { focused in
                        Text(PMString(choice.key))
                            .font(.system(size: 16, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(isSelected ? TVColor.onBrand : TVColor.textMuted)
                            .frame(width: 94)
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
    private func navRow(_ icon: String, _ title: String, _ value: String,
                        trailing: String = "chevron.right",
                        action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: action) { focused in
            HStack(spacing: 18) {
                settingIcon(icon, focused: focused)
                Text(title).font(.system(size: 22, weight: focused ? .bold : .medium)).foregroundStyle(TVColor.text)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 18)).foregroundStyle(TVColor.textMuted).lineLimit(1)
                Image(systemName: trailing).font(.system(size: 16, weight: .semibold))
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
                Text(title).font(.system(size: 22, weight: focused ? .bold : .medium)).foregroundStyle(TVColor.text)
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
            Text(title).font(.system(size: 22, weight: .medium)).foregroundStyle(TVColor.text)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 18)).foregroundStyle(TVColor.textMuted).lineLimit(1)
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

private struct TVAISettingsContainer: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AISettingsView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(PMString("done")) { dismiss() }
                    }
                }
        }
        .onExitCommand { dismiss() }
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
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(TVColor.text)
                    }
                    Spacer()
                    Text("#\(selectedHex)")
                        .font(.system(size: 18, design: .monospaced))
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
                    .font(.system(size: 17, weight: selected ? .bold : .semibold))
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
                    .font(.system(size: 17, weight: selected ? .bold : .semibold))
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
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(binding).font(.system(size: 15, weight: .semibold)).foregroundStyle(TVColor.text)
                .frame(minWidth: 180).padding(.horizontal, 12).padding(.vertical, 6)
                .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(TVColor.cardBorder, lineWidth: 0.5)
                }
            Text(label).font(.system(size: 18)).foregroundStyle(TVColor.textMuted)
        }
    }
}

/// 风格化 Siri Remote。
private struct TVSiriRemote: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.08), .clear],
                                         center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 90))
                    .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
                    .frame(width: 150, height: 150)
                ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { deg in
                    Image(systemName: "chevron.up").font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.45))
                        .offset(y: -56)
                        .rotationEffect(.degrees(deg))
                }
                Circle().fill(.white.opacity(0.18))
                    .overlay { Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5) }
                    .frame(width: 24, height: 24)
            }
            .padding(.top, 10)

            let grid = [("arrow.uturn.backward", "Back"), ("tv", "TV"),
                        ("speaker.slash.fill", "Mute"), ("mic.fill", "Siri")]
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(grid, id: \.0) { b in
                    VStack(spacing: 3) {
                        Image(systemName: b.0).font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                        Text(b.1).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "backward.fill")
                Image(systemName: "playpause.fill")
                Image(systemName: "forward.fill")
            }
            .font(.system(size: 16)).foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }

            Text("SIRI REMOTE").font(.system(size: 11, weight: .medium)).tracking(1.6)
                .foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
        }
        .padding(24)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "#2a2722"), Color(hex: "#16140f")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
    }
}
#endif
