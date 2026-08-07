#if os(iOS)
import SwiftUI

/// Lets the accent either follow the playing song's cover art (default) or stay
/// pinned to a color the user picks from a predefined palette.
struct ThemeColorSettingsView: View {
    @State private var settings = ThemeColorSettings.shared
    @Environment(ThemeService.self) private var themeService
    @Environment(AudioPlayerService.self) private var player

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

    // MARK: - Applying

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
