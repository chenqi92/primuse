#if os(iOS)
import SwiftUI

/// Lets the accent either follow the playing song's cover art (default) or stay
/// pinned to a color the user picks from a predefined palette.
struct ThemeColorSettingsView: View {
    @State private var settings = ThemeColorSettings.shared
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioPlayerService.self) private var player

    /// Live position of the custom picker. Seeded from the stored hex so
    /// reopening the page puts the knobs back where the user left them.
    @State private var custom = ThemeColorSettings.hsb(
        fromHex: ThemeColorSettings.shared.fixedColorHex
    )

    /// Keeping the accent above near-black and below near-white ensures it stays
    /// visible against both the light and dark chrome.
    private static let brightnessRange: ClosedRange<CGFloat> = 0.25...0.92

    private let columns = [
        GridItem(.adaptive(minimum: 68), spacing: 16)
    ]

    var body: some View {
        List {
            Section {
                preview
            }

            Section {
                modeRow(
                    .auto,
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

            if settings.mode == .fixed {
                Section {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(ThemeColorSettings.swatches) { swatch in
                            swatchCell(swatch)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("theme_color_palette")
                } footer: {
                    Text("theme_color_palette_footer")
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
                } footer: {
                    Text("theme_color_custom_footer")
                }
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
                        colors: [themeService.accentColor, themeService.darkAccent],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("theme_color_current")
                    .font(.subheadline.weight(.medium))
                let modeKey: LocalizedStringKey = settings.mode == .fixed
                    ? "theme_color_mode_fixed"
                    : "theme_color_mode_auto"
                Text(modeKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.35), value: themeService.colorID)
    }

    private func modeRow(
        _ mode: ThemeColorSettings.Mode,
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
                    .foregroundStyle(themeService.accentColor)
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
                        .foregroundStyle(themeService.accentColor)
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
                    .fill(swatch.color)
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
                                isSelected ? swatch.color : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 3 : 0.5
                            )
                            .padding(isSelected ? -4 : 0)
                    }

                Text(swatch.nameKey)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// A drag-anywhere color channel track. The whole bar is the control — the
    /// knob only marks the position — so a tap or a drag both land the value.
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

    // MARK: - Applying

    /// Repaints the app from the live picker position. Mid-drag updates skip the
    /// crossfade and the widget write; `committing` does both once on release.
    private func applyCustomColor(committing: Bool) {
        let hex = ThemeColorSettings.hex(fromHSB: custom)
        settings.fixedColorHex = hex
        if settings.mode != .fixed {
            settings.mode = .fixed
        }

        let color = Color(hex: hex)
        themeService.setBaseAccent(color, animated: committing)
        themeService.resetToDefault(animated: committing)
        if committing {
            ThemeColorSettings.publishBaseAccentToWidget(color)
        }
    }

    private func apply(_ mode: ThemeColorSettings.Mode) {
        guard settings.mode != mode else { return }
        settings.mode = mode
        switch mode {
        case .fixed:
            pinAccent(settings.fixedColor)
        case .auto:
            // Hand the accent back to the app icon tint, then let the playing
            // song's artwork take over again if it has any.
            themeService.setBaseAccent(AppIconService.shared.currentTint)
            ThemeColorSettings.publishBaseAccentToWidget(AppIconService.shared.currentTint)
            refreshFromCurrentSong()
        }
    }

    private func select(_ swatch: ThemeColorSettings.Swatch) {
        settings.fixedColorHex = swatch.id
        if settings.mode != .fixed {
            settings.mode = .fixed
        }
        // Move the custom sliders onto the swatch so the two controls always
        // describe the same color.
        custom = ThemeColorSettings.hsb(fromHex: swatch.id)
        pinAccent(swatch.color)
    }

    /// `setBaseAccent` only repaints immediately while the theme sits on its
    /// fallback, so drop any artwork-derived color first to make a fixed pick
    /// visible even mid-song.
    private func pinAccent(_ color: Color) {
        themeService.setBaseAccent(color)
        themeService.resetToDefault()
        ThemeColorSettings.publishBaseAccentToWidget(color)
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
