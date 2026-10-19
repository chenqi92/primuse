#if os(iOS)
import SwiftUI
import PrimuseKit

enum IOSAppearancePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: PMString("ext.tv.settings.appearance.system")
        case .light: PMString("ext.tv.settings.appearance.light")
        case .dark: PMString("ext.tv.settings.appearance.dark")
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppThemePreferences.iOSAppearanceKey)
    private var appearanceRawValue = IOSAppearancePreference.system.rawValue
    @AppStorage(AppNavigationMode.storageKey)
    private var navigationModeRawValue = AppNavigationMode.standard.rawValue
    #if os(iOS)
    @AppStorage(MinimalNavigationPolicy.showsHomeKey) private var minimalShowsHome = true
    #endif
    @AppStorage(WidgetColorStyle.storageKey) private var widgetColorStyle = WidgetColorStyle.defaultValue

    private var selection: IOSAppearancePreference {
        IOSAppearancePreference(rawValue: appearanceRawValue) ?? .system
    }

    private var minimalModeEnabled: Binding<Bool> {
        Binding(
            get: { AppNavigationMode.resolve(navigationModeRawValue) == .minimal },
            set: { isEnabled in
                navigationModeRawValue = (isEnabled
                    ? AppNavigationMode.minimal
                    : AppNavigationMode.standard).rawValue
            }
        )
    }

    var body: some View {
        List {
            Section {
                ForEach(IOSAppearancePreference.allCases, id: \.self) { option in
                    Button {
                        appearanceRawValue = option.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: option.symbolName)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            Text(option.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection == option {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? [.isButton, .isSelected] : .isButton)
                }
            }
            .settingsAnchor("appearance.scheme")

            Section {
                Toggle(isOn: minimalModeEnabled) {
                    Label("minimal_mode_title", systemImage: "rectangle.topthird.inset.filled")
                }
                // 下面选了「白色」时开关圆钮要换色,外观代理只作用于新建的开关。
                .id(ThemeColorSettings.shared.isWhiteTheme)

                #if os(iOS)
                // 极简顶栏上要不要摆「首页」那一格(#69:想要的是能藏,不是去掉)。
                if minimalModeEnabled.wrappedValue {
                    Toggle(isOn: $minimalShowsHome) {
                        Label("minimal_show_home", systemImage: "house")
                    }
                    .id(ThemeColorSettings.shared.isWhiteTheme)
                }
                #endif
            } header: {
                SettingsInfoHeader("navigation_mode_title") {
                    Text("minimal_mode_description")
                }
            }
            .settingsAnchor("appearance.minimalNavigation")

            // 音乐(就是 App 的主题色)和电台、有声书、播客一样，一类一行，点进去再挑。
            ListeningSpaceColorSections(includesMusic: true)

            // 几个台、几本书并排的小组件取一张封面的颜色会和别的封面撞色(#320),这里可以换成单色。
            Section {
                Picker(selection: $widgetColorStyle) {
                    ForEach(WidgetColorStyle.allCases, id: \.self) { style in
                        Text(verbatim: style.title).tag(style)
                    }
                } label: {
                    SettingsInfoLabel("widget_color_style_title") {
                        Text("widget_color_style_footer")
                    }
                }
                .pickerStyle(.menu)
                .settingsAnchor("appearance.widgetColorStyle")
            } header: {
                Text("widget_color_style_section")
            }
            .onChange(of: widgetColorStyle) { _, _ in
                WidgetColorStyleMirror.publish()
            }

            // App 图标直接平铺：要靠眼睛挑，多一次跳转就得来回对比。

            #if os(iOS)
            Section {
                AppIconPickerGrid()
            } header: {
                Text("app_icon")
            }
            #endif
        }
        .navigationTitle("interface_editor_settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 主题色的各个区块。由「颜色和图标」页直接平铺，也可作为独立页面打开（设置搜索会
/// 深链到这里）。所以内容只出 Section，外壳交给使用方的 List / Form。
struct ThemeColorSections: View {
    @State private var settings = ThemeColorSettings.shared
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioPlayerService.self) private var player

    @State private var custom = ThemeColorSettings.hsb(
        fromHex: ThemeColorSettings.shared.fixedColorHex
    )

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 16)]

    var body: some View {
        Group {
            Section {
                preview
            }

            Section {
                modeRow(
                    .automatic,
                    title: "theme_color_mode_auto",
                    hint: "theme_color_mode_auto_hint",
                    icon: "photo.on.rectangle.angled"
                )
                modeRow(
                    .fixed,
                    title: "theme_color_mode_fixed",
                    hint: "theme_color_mode_fixed_hint",
                    icon: "paintpalette"
                )
            } header: {
                Text("theme_color_mode")
            }
            .settingsAnchor("appearance.themeMode")

            Section {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(ThemeColorSettings.swatches) { swatch in
                        ThemeSwatchCell(
                            swatch: swatch,
                            isSelected: settings.mode == .fixed && settings.fixedColorHex == swatch.id
                        ) {
                            select(swatch)
                        }
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("theme_color_palette")
            } footer: {
                // 只想让播放页控件变白的人,不必为此把整个 App 换成白色。
                Button {
                    SettingsNavigation.shared.open("appearance.playerControlTint")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("theme_color_player_monochrome_hint")
                            .foregroundStyle(.secondary)
                        Text("theme_color_player_monochrome_link")
                            .foregroundStyle(.tint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .settingsAnchor("appearance.palette")

            Section {
                ThemeHSBSliders(custom: $custom) { committing in
                    applyCustomColor(committing: committing)
                }

                ThemeColorPickerRow(custom: custom) { hex, committing in
                    applyPickedColor(hex, committing: committing)
                }
                .settingsAnchor("appearance.colorPicker")

                HStack {
                    Text("theme_color_hex")
                    Spacer()
                    Text(verbatim: "#\(settings.fixedColorHex)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
                .settingsAnchor("appearance.hex")
            } header: {
                Text("theme_color_custom")
            } footer: {
                Text("theme_color_picker_footer")
            }
            .settingsAnchor("appearance.hue")

            Section {
                Toggle(isOn: coverDrivenAmbientBinding) {
                    Label {
                        Text(PMString("ext.tv.settings.coverColor"))
                    } icon: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                }
                // 上面选了「白色」时开关圆钮要换色,外观代理只作用于新建的开关。
                .id(settings.isWhiteTheme)
            } header: {
                Text(PMString("ext.tv.settings.coverColor"))
            } footer: {
                // 背景的样式和浓淡挪到了「设置 › 播放器」,和播放页的其它外观放在一起(#69)。
                Button {
                    SettingsNavigation.shared.open("appearance.playerBackdrop")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("theme_color_player_backdrop_moved_hint")
                            .foregroundStyle(.secondary)
                        Text("theme_color_player_backdrop_moved_link")
                            .foregroundStyle(.tint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .settingsAnchor("appearance.coverAmbient")
        }
    }

    private var preview: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [themeService.uiAccentColor, themeService.accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("theme_color_current")
                    .font(.subheadline.weight(.medium))
                Text(settings.mode == .automatic
                     ? String(localized: "theme_color_mode_auto")
                     : String(localized: "theme_color_mode_fixed"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .pmAnimation(.ambient, value: themeService.colorID)
    }

    private func modeRow(
        _ mode: AppThemeColorMode,
        title: LocalizedStringKey,
        hint: LocalizedStringKey,
        icon: String
    ) -> some View {
        Button {
            apply(mode)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(themeService.uiAccentColor)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if settings.mode == mode {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(themeService.uiAccentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(settings.mode == mode ? [.isButton, .isSelected] : .isButton)
    }

    private var coverDrivenAmbientBinding: Binding<Bool> {
        Binding(
            get: { settings.coverDrivenAmbient },
            set: { enabled in
                settings.coverDrivenAmbient = enabled
                themeService.setCoverDrivenAmbient(enabled)
                if enabled {
                    refreshFromCurrentSong()
                } else if settings.mode == .fixed {
                    themeService.resetToDefault()
                }
            }
        )
    }

    private func applyCustomColor(committing: Bool) {
        let hex = ThemeColorSettings.hex(fromHSB: custom)
        settings.fixedColorHex = hex
        activateFixedMode(animated: committing)
        applyBaseAccent(Color(hex: hex), animated: committing, publish: committing)
    }

    /// 取色器挑的颜色原样存下(不截进滑杆的范围),滑杆只是挪到离它最近的位置。
    private func applyPickedColor(_ hex: String, committing: Bool) {
        custom = ThemeColorSettings.hsb(fromHex: hex)
        settings.fixedColorHex = hex
        activateFixedMode(animated: committing)
        applyBaseAccent(Color(hex: hex), animated: committing, publish: committing)
    }

    private func select(_ swatch: ThemeColorSettings.Swatch) {
        settings.fixedColorHex = swatch.id
        custom = ThemeColorSettings.hsb(fromHex: swatch.id)
        activateFixedMode(animated: true)
        // 跟启动时一样取 `fixedColor`:「白色」「品红」是随外观变的,不能当成一个十六进制色。
        applyBaseAccent(settings.fixedColor, animated: true)
    }

    private func apply(_ mode: AppThemeColorMode) {
        guard settings.mode != mode else { return }
        settings.mode = mode
        themeService.setColorMode(mode)
        if mode == .automatic {
            refreshFromCurrentSong()
        } else if !settings.coverDrivenAmbient {
            themeService.resetToDefault()
        }
    }

    private func activateFixedMode(animated: Bool) {
        guard settings.mode != .fixed else { return }
        settings.mode = .fixed
        themeService.setColorMode(.fixed, animated: animated)
    }

    private func applyBaseAccent(_ color: Color, animated: Bool, publish: Bool = true) {
        themeService.setBaseAccent(color, animated: animated)
        if !settings.coverDrivenAmbient {
            themeService.resetToDefault(animated: animated)
        }
        if publish {
            ThemeColorSettings.publishBaseAccentToWidget(color)
        }
    }

    private func refreshFromCurrentSong() {
        guard let song = player.currentSong else {
            themeService.resetToDefault()
            return
        }
        themeService.updateFromCoverArt(
            fileName: song.coverArtFileName,
            songID: song.id,
            appleMusicID: song.sourceID == AppleMusicLibraryService.systemSourceID
                ? song.filePath
                : nil
        )
    }
}

/// 主题色的页面。「颜色和图标」页上「音乐」那一行点进来(标题是「音乐」,下面不再列另外三类);
/// 设置搜索命中主题色或电台、有声书、播客颜色的条目时推的也是这一页。
struct ThemeColorSettingsView: View {
    /// 从「颜色和图标」的「音乐」一行进来:另外三类就在上一页,这里不重复。
    var isMusicEntry = false

    var body: some View {
        List {
            ThemeColorSections()
            if !isMusicEntry {
                ListeningSpaceColorSections()
            }
        }
        .navigationTitle(isMusicEntry ? ListeningSpace.music.titleKey : "theme_color_title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 色板里的一个色块:圆点、选中时打勾加描边、下面写名字。主题色与电台、有声书、播客的颜色共用。
struct ThemeSwatchCell: View {
    let swatch: AppThemePreferences.Swatch
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // 白色色块在白底上要一圈看得见的边,勾是黑的,选中的外圈用文字色。
        let isMonochrome = AppThemePreferences.isMonochrome(swatch.id)
        // 「品红」按当前外观显示那一档;「白色」色块始终画成白的。
        let swatchColor = isMonochrome
            ? Color(hex: swatch.id)
            : AppThemePreferences.themeColor(hex: swatch.id)

        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(swatchColor)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(isMonochrome ? .black : .white)
                                .shadow(color: .black.opacity(isMonochrome ? 0 : 0.35), radius: 1.5)
                                .pmFadeTransition()
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isSelected
                                    ? (isMonochrome ? Color.primary.opacity(0.7) : swatchColor)
                                    : Color.primary.opacity(isMonochrome ? 0.28 : 0.12),
                                lineWidth: isSelected ? 3 : (isMonochrome ? 1 : 0.5)
                            )
                            .padding(isSelected ? -4 : 0)
                    }

                Text(PMString(swatch.localizationKey))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 挂在单个色块上：勾与描边只跟这一块的选中态走, 换色时两块各自动各自的。
        .pmAnimation(.selection, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 系统取色器那一行:色盘、色谱、滑杆里能直接输十六进制,也能用吸管从屏幕上吸(#313)。
/// 取色器拖动时连续回调、没有松手的时刻,停下片刻才按「定下来」交给 `onPick(hex, true)`
/// (那时才刷新小组件、做换色动画),途中给 `onPick(hex, false)`。
struct ThemeColorPickerRow: View {
    /// 打开时显示的颜色:上面三条滑杆此刻的位置。
    let custom: ThemeColorSettings.HSB
    let onPick: (_ hex: String, _ committing: Bool) -> Void

    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        ColorPicker(selection: selection, supportsOpacity: false) {
            Label("theme_color_picker", systemImage: "eyedropper")
        }
    }

    private var selection: Binding<Color> {
        Binding(
            get: { Color(hue: custom.hue, saturation: custom.saturation, brightness: custom.brightness) },
            set: { color in
                let hex = ThemeColorSettings.hex(from: color)
                onPick(hex, false)
                commitTask?.cancel()
                // 页面关掉也不取消:最后挑的那个颜色照样要定下来。
                commitTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    onPick(hex, true)
                }
            }
        )
    }
}

/// 自定义颜色的色相、饱和度、亮度三条滑杆。拖动途中 `onChange(false)`,松手 `onChange(true)`。
struct ThemeHSBSliders: View {
    @Binding var custom: ThemeColorSettings.HSB
    let onChange: (_ committing: Bool) -> Void

    static let brightnessRange: ClosedRange<CGFloat> = 0.25...0.92

    var body: some View {
        channelSlider(
            title: "theme_color_hue",
            value: $custom.hue,
            range: 0...1,
            track: LinearGradient(
                colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
                    Color(hue: $0, saturation: 0.85, brightness: 0.85)
                },
                startPoint: .leading,
                endPoint: .trailing
            )
        )

        channelSlider(
            title: "theme_color_saturation",
            value: $custom.saturation,
            range: 0.15...1,
            track: LinearGradient(
                colors: [
                    Color(hue: custom.hue, saturation: 0.15, brightness: custom.brightness),
                    Color(hue: custom.hue, saturation: 1, brightness: custom.brightness)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )

        channelSlider(
            title: "theme_color_brightness",
            value: $custom.brightness,
            range: Self.brightnessRange,
            track: LinearGradient(
                colors: [
                    Color(
                        hue: custom.hue,
                        saturation: custom.saturation,
                        brightness: Self.brightnessRange.lowerBound
                    ),
                    Color(
                        hue: custom.hue,
                        saturation: custom.saturation,
                        brightness: Self.brightnessRange.upperBound
                    )
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func channelSlider(
        title: LocalizedStringKey,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        track: LinearGradient
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)

            GeometryReader { geometry in
                let width = geometry.size.width
                let span = range.upperBound - range.lowerBound
                let fraction = span > 0
                    ? (value.wrappedValue - range.lowerBound) / span
                    : 0
                let knobX = min(max(fraction, 0), 1) * width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(track)
                        .frame(height: 28)

                    Circle()
                        .fill(.white)
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        .offset(x: min(max(knobX - 13, 0), width - 26))
                }
                .frame(height: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard width > 0 else { return }
                            let ratio = min(max(drag.location.x / width, 0), 1)
                            value.wrappedValue = range.lowerBound + ratio * span
                            onChange(false)
                        }
                        .onEnded { _ in onChange(true) }
                )
            }
            .frame(height: 28)
        }
        .padding(.vertical, 4)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(Text(verbatim: "\(Int(round(value.wrappedValue * 100)))%"))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment:
                value.wrappedValue = min(value.wrappedValue + step, range.upperBound)
            case .decrement:
                value.wrappedValue = max(value.wrappedValue - step, range.lowerBound)
            @unknown default:
                return
            }
            onChange(true)
        }
    }
}

/// 电台、有声书、播客各自的颜色(#283):一类一行,右边写着现在用哪种颜色,点进去挑。
/// 「颜色和图标」页与独立的主题色页都列这一组。
struct ListeningSpaceColorSections: View {
    /// 「颜色和图标」页上把音乐(主题色)也列成一行,四类一样都是点进去再挑。
    var includesMusic = false

    @State private var settings = ListeningSpaceTintSettings.shared
    @State private var themeSettings = ThemeColorSettings.shared

    var body: some View {
        Section {
            if includesMusic {
                NavigationLink {
                    ThemeColorSettingsView(isMusicEntry: true)
                } label: {
                    HStack(spacing: 12) {
                        ListeningSpaceColorGlyph(space: .music, side: 28)
                        Text(ListeningSpace.music.titleKey)
                        Spacer(minLength: 8)
                        Text(themeSettings.mode == .automatic
                             ? LocalizedStringKey("theme_color_mode_auto")
                             : LocalizedStringKey("theme_color_mode_fixed"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("appearance.musicColor")
            }
            ForEach(ListeningSpaceTintPreferences.customizableSpaces, id: \.self) { space in
                NavigationLink {
                    ListeningSpaceColorSettingsView(space: space)
                } label: {
                    HStack(spacing: 12) {
                        ListeningSpaceColorGlyph(space: space, side: 28)
                        Text(space.titleKey)
                        Spacer(minLength: 8)
                        Text(ListeningSpaceColorSettingsView.sourceTitle(settings.choice(for: space)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        } header: {
            Text(includesMusic
                 ? LocalizedStringKey("listening_space_colors_all_title")
                 : LocalizedStringKey("listening_space_colors_title"))
        } footer: {
            Text(includesMusic
                 ? LocalizedStringKey("listening_space_colors_all_footer")
                 : LocalizedStringKey("listening_space_colors_footer"))
        }
        .settingsAnchor("appearance.listeningSpaceColors")
    }
}

/// 资料库里那种白色图标压在色块上的小方块。颜色太浅(「白色」主题色)时垫石墨灰,白图标才看得见。
private struct ListeningSpaceColorGlyph: View {
    let space: ListeningSpace
    let side: CGFloat

    @Environment(\.self) private var environment

    var body: some View {
        Image(systemName: space.systemImage)
            .font(.system(size: side * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(
                ThemeService.legibleFillBehindWhiteText(space.glyphTileTint, in: environment),
                in: RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// 一类内容的颜色:默认、跟随主题色、跟随封面,或者从色板里挑 / 自己调一个固定颜色。
/// 首页顶部切换、资料库、搜索分组和小组件都跟着变。
struct ListeningSpaceColorSettingsView: View {
    let space: ListeningSpace

    @State private var settings = ListeningSpaceTintSettings.shared
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioPlayerService.self) private var player
    @State private var custom: ThemeColorSettings.HSB

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 16)]

    init(space: ListeningSpace) {
        self.space = space
        let hex = ListeningSpaceTintSettings.shared.choice(for: space).fixedHex
            ?? Self.standardHex(of: space)
        _custom = State(initialValue: ThemeColorSettings.hsb(fromHex: hex))
    }

    private var choice: ListeningSpaceTintChoice { settings.choice(for: space) }

    static func sourceTitle(_ choice: ListeningSpaceTintChoice) -> LocalizedStringKey {
        switch choice {
        case .standard: "listening_space_tint_standard"
        case .theme: "listening_space_tint_theme"
        case .artwork: "listening_space_tint_artwork"
        case .fixed: "listening_space_tint_fixed"
        }
    }

    /// 自定义滑杆的起点:没挑过固定颜色时从这一类的默认色开始调。
    private static func standardHex(of space: ListeningSpace) -> String {
        String(format: "%06X", space.fixedTint?.light ?? 0)
    }

    var body: some View {
        List {
            Section {
                preview
            }

            Section {
                sourceRow(.standard, hint: "listening_space_tint_standard_hint", icon: space.systemImage)
                sourceRow(.theme, hint: "listening_space_tint_theme_hint", icon: "paintbrush")
                sourceRow(.artwork, hint: "listening_space_tint_artwork_hint", icon: "photo.on.rectangle.angled")
                sourceRow(
                    .fixed(choice.fixedHex ?? ThemeColorSettings.hex(fromHSB: custom)),
                    hint: "listening_space_tint_fixed_hint",
                    icon: "paintpalette"
                )
            } header: {
                Text("listening_space_tint_source")
            }

            Section {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(ThemeColorSettings.swatches) { swatch in
                        ThemeSwatchCell(swatch: swatch, isSelected: choice.fixedHex == swatch.id) {
                            custom = ThemeColorSettings.hsb(fromHex: swatch.id)
                            apply(.fixed(swatch.id))
                        }
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("theme_color_palette")
            }

            Section {
                ThemeHSBSliders(custom: $custom) { committing in
                    apply(.fixed(ThemeColorSettings.hex(fromHSB: custom)), reloadingWidgets: committing)
                }

                ThemeColorPickerRow(custom: custom) { hex, committing in
                    custom = ThemeColorSettings.hsb(fromHex: hex)
                    apply(.fixed(hex), reloadingWidgets: committing)
                }

                HStack {
                    Text("theme_color_hex")
                    Spacer()
                    Text(verbatim: "#\(choice.fixedHex ?? ThemeColorSettings.hex(fromHSB: custom))")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("theme_color_custom")
            } footer: {
                Text("theme_color_picker_footer")
            }
        }
        .navigationTitle(space.titleKey)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 首页顶部切换选中时的那颗胶囊、资料库的图标块和一行用这个颜色写的字,换色时一起变。
    private var preview: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: space.systemImage)
                Text(space.titleKey)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.text(on: space.tint))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(space.tint.gradient, in: Capsule())

            ListeningSpaceColorGlyph(space: space, side: 36)

            Spacer(minLength: 0)

            Image(systemName: "play.fill")
                .font(.title3)
                .foregroundStyle(space.tint)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .pmAnimation(.selection, value: choice)
    }

    private func sourceRow(
        _ target: ListeningSpaceTintChoice,
        hint: LocalizedStringKey,
        icon: String
    ) -> some View {
        let isSelected = Self.sameSource(choice, target)
        return Button {
            apply(target)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(themeService.uiAccentColor)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.sourceTitle(target))
                        .foregroundStyle(.primary)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(themeService.uiAccentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// 两个固定颜色色值不同也算同一种来源(打勾看的是「固定颜色」这一行)。
    private static func sameSource(_ lhs: ListeningSpaceTintChoice, _ rhs: ListeningSpaceTintChoice) -> Bool {
        switch (lhs, rhs) {
        case (.fixed, .fixed): true
        default: lhs == rhs
        }
    }

    private func apply(_ target: ListeningSpaceTintChoice, reloadingWidgets: Bool = true) {
        settings.setChoice(target, for: space, reloadingWidgets: reloadingWidgets)
        // 主题色固定、播放背景也不取封面色时,封面原本不取色;换成「跟随封面」后现取一次。
        if target == .artwork { refreshFromCurrentSong() }
    }

    private func refreshFromCurrentSong() {
        guard let song = player.currentSong else { return }
        themeService.updateFromCoverArt(
            fileName: song.coverArtFileName,
            songID: song.id,
            appleMusicID: song.sourceID == AppleMusicLibraryService.systemSourceID
                ? song.filePath
                : nil
        )
    }
}

#endif
