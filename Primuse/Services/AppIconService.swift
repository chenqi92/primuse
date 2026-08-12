#if os(iOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif
import WidgetKit
import PrimuseKit

@MainActor
@Observable
final class AppIconService {
    static let shared = AppIconService()

    /// One selectable icon design. Each design ships a single asset-catalog
    /// iconset that bundles its light/dark/tinted appearance variants — iOS
    /// auto-renders the right one when system appearance changes, so we only
    /// pass a single name to `setAlternateIconName`.
    struct IconOption: Identifiable, Equatable {
        /// Stable identifier for the design — matches the alternate iconset
        /// name (or empty string for the default primary icon). Used as the
        /// selection key in UI and persisted state.
        let id: String

        /// Alternate-icon name to pass to `setAlternateIconName`. `nil` means
        /// reset to the primary icon.
        let alternateName: String?

        let previewAsset: String
        let displayName: String

        /// Brand tint that the chosen icon paints across the rest of the UI as
        /// the fallback accent (when no song's cover art is driving the theme).
        let tint: Color

        /// True if the design ships a separate dark artwork variant — used by
        /// the settings UI to render the "auto-switch" badge.
        let supportsAppearance: Bool
    }

    /// Keep the classic icon immediately after the current primary icon,
    /// then show the retained design alternatives in their existing order.
    private static let themeOrder = [9, 12, 10, 11, 4, 6, 7]

    /// Themes that ship only a single visual variant (no dark counterpart in
    /// the asset catalog). Add a theme index here when no dark image exists.
    private static let singleVariantThemes: Set<Int> = []

    /// Brand tints sampled from the shared flat icon palette.
    private static let iconTints: [String: Color] = [
        "":         Color(red: 0.914, green: 0.314, blue: 0.263), // folded note — coral underside
        "AppIcon12": Color(red: 0.965, green: 0.251, blue: 0.424), // Pikaqiu — gradient pink
        "AppIcon10": Color(red: 0.827, green: 0.227, blue: 0.173), // vinyl ape — vermilion label
        "AppIcon11": Color(red: 0.176, green: 0.651, blue: 0.890), // color brush — cyan-blue stroke
        "AppIcon4": Color(red: 0.388, green: 0.902, blue: 0.839), // music note — mint cyan
        "AppIcon6": Color(red: 0.251, green: 0.835, blue: 0.784), // restored soft note — mint
        "AppIcon7": Color(red: 0.220, green: 0.835, blue: 0.784), // Primuse P — turquoise
        "AppIcon9": Color(red: 0.078, green: 0.490, blue: 0.541), // classic record — cyan teal
    ]

    let options: [IconOption] = {
        var list: [IconOption] = [
            IconOption(
                id: "",
                alternateName: nil,
                previewAsset: "AppIconPreview",
                displayName: NSLocalizedString("icon_default", comment: ""),
                tint: AppIconService.iconTints[""] ?? Color.accentColor,
                supportsAppearance: true
            )
        ]
        for i in AppIconService.themeOrder {
            let name = "AppIcon\(i)"
            list.append(IconOption(
                id: name,
                alternateName: name,
                previewAsset: "AppIcon\(i)Preview",
                displayName: NSLocalizedString("icon_theme_\(i)", comment: ""),
                tint: AppIconService.iconTints[name] ?? Color.accentColor,
                supportsAppearance: !AppIconService.singleVariantThemes.contains(i)
            ))
        }
        return list
    }()

    /// Tint for the currently-selected icon — drives the theme accent.
    var currentTint: Color {
        options.first { $0.id == currentIconID }?.tint
            ?? options.first?.tint
            ?? Color.accentColor
    }

    /// Persisted user choice — the option's `id`. Survives launches.
    @ObservationIgnored
    @AppStorage("primuse.appIconChoice") private var storedChoiceID: String = ""

    private(set) var currentIconID: String

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    private init() {
        self.currentIconID = ""
        // Read after init so @AppStorage can resolve.
        let persistedID = storedChoiceID
        if options.contains(where: { $0.id == persistedID }) {
            self.currentIconID = persistedID
        } else {
            // Normalize a stored selection that no longer exists in the
            // current icon catalog so UI and tint fall back together.
            storedChoiceID = ""
        }
        // Make sure the widget extension sees the right brand color on first
        // launch — without this, fresh installs render the widget with
        // whatever fallback the design system picks.
        publishTintToWidget()
    }

    func setIcon(_ option: IconOption) async {
        guard supportsAlternateIcons else { return }
        let actual = UIApplication.shared.alternateIconName

        storedChoiceID = option.id
        currentIconID = option.id
        publishTintToWidget()

        guard option.alternateName != actual else { return }

        do {
            try await UIApplication.shared.setAlternateIconName(option.alternateName)
        } catch {
            // Reconcile with whatever the system actually has, in case the
            // call partially applied.
            let live = UIApplication.shared.alternateIconName
            currentIconID = options.first { $0.alternateName == live }?.id ?? ""
            storedChoiceID = currentIconID
            publishTintToWidget()
        }
    }

    /// Push the current tint into the App Group so the widget's next render
    /// picks it up, then ask WidgetKit to refresh timelines now (without this,
    /// the home-screen widget keeps its stale color until iOS happens to wake
    /// it on its own schedule).
    /// A theme pinned to a fixed color outranks the icon tint, so resolve
    /// through the theme settings rather than publishing `currentTint` directly.
    private func publishTintToWidget() {
        ThemeColorSettings.publishBaseAccentToWidget(
            ThemeColorSettings.shared.baseAccent(iconTint: currentTint)
        )
    }
}

#endif
