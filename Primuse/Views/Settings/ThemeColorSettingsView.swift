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

    private var selection: IOSAppearancePreference {
        IOSAppearancePreference(rawValue: appearanceRawValue) ?? .system
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
        }
        .navigationTitle("appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ThemeColorSettingsView: View {
    @State private var settings = ThemeColorSettings.shared
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioPlayerService.self) private var player

    @State private var custom = ThemeColorSettings.hsb(
        fromHex: ThemeColorSettings.shared.fixedColorHex
    )

    private static let brightnessRange: ClosedRange<CGFloat> = 0.25...0.92
    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 16)]

    var body: some View {
        List {
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

            Section {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(ThemeColorSettings.swatches) { swatch in
                        swatchCell(swatch)
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("theme_color_palette")
            }

            Section {
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

                HStack {
                    Text("theme_color_hex")
                    Spacer()
                    Text(verbatim: "#\(settings.fixedColorHex)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("theme_color_custom")
            }

            Section {
                Toggle(isOn: coverDrivenAmbientBinding) {
                    Label {
                        Text(PMString("ext.tv.settings.coverColor"))
                    } icon: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label {
                            Text(PMString("ext.tv.settings.ambientIntensity"))
                        } icon: {
                            Image(systemName: "sun.haze.fill")
                        }
                        Spacer()
                        Text(verbatim: "\(Int(round(settings.ambientStrength * 100)))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: ambientStrengthBinding, in: 0...1, step: 0.05)
                        .tint(themeService.uiAccentColor)
                }
                .padding(.vertical, 4)
            } header: {
                Text(PMString("ext.tv.settings.coverColor"))
            }
        }
        .navigationTitle("theme_color_title")
        .navigationBarTitleDisplayMode(.inline)
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
        .animation(.easeInOut(duration: 0.35), value: themeService.colorID)
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
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(settings.mode == mode ? [.isButton, .isSelected] : .isButton)
    }

    private func swatchCell(_ swatch: ThemeColorSettings.Swatch) -> some View {
        let isSelected = settings.mode == .fixed && settings.fixedColorHex == swatch.id

        return Button {
            select(swatch)
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: swatch.id))
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 1.5)
                        }
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(
                                isSelected ? Color(hex: swatch.id) : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 3 : 0.5
                            )
                            .padding(isSelected ? -4 : 0)
                    }

                Text(PMString(swatch.localizationKey))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                            applyCustomColor(committing: false)
                        }
                        .onEnded { _ in applyCustomColor(committing: true) }
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
            applyCustomColor(committing: true)
        }
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

    private var ambientStrengthBinding: Binding<Double> {
        Binding(
            get: { settings.ambientStrength },
            set: { settings.ambientStrength = AppThemePreferences.normalizedAmbientStrength($0) }
        )
    }

    private func applyCustomColor(committing: Bool) {
        let hex = ThemeColorSettings.hex(fromHSB: custom)
        settings.fixedColorHex = hex
        activateFixedMode(animated: committing)
        applyBaseAccent(Color(hex: hex), animated: committing, publish: committing)
    }

    private func select(_ swatch: ThemeColorSettings.Swatch) {
        settings.fixedColorHex = swatch.id
        custom = ThemeColorSettings.hsb(fromHex: swatch.id)
        activateFixedMode(animated: true)
        applyBaseAccent(Color(hex: swatch.id), animated: true)
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

#endif
