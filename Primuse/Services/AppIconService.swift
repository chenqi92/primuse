import SwiftUI
import UIKit
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

    static let themeCount = 7

    /// Themes that ship only a single visual variant (no dark counterpart in
    /// the asset catalog). Add a theme index here when no dark image exists.
    private static let singleVariantThemes: Set<Int> = [2]

    /// Brand tints per icon — eyeballed from the preview artwork. Updating an
    /// icon design? Refresh the tint here too.
    private static let iconTints: [String: Color] = [
        "":         Color(red: 0.20, green: 0.50, blue: 0.95),  // default — vinyl blue
        "AppIcon1": Color(red: 0.39, green: 0.32, blue: 0.98),  // 1 — blue-purple gradient
        "AppIcon2": Color(red: 0.55, green: 0.32, blue: 0.85),  // 2 — gorilla purple
        "AppIcon3": Color(red: 0.20, green: 0.78, blue: 0.78),  // 3 — NAS cyan
        "AppIcon4": Color(red: 0.92, green: 0.72, blue: 0.20),  // 4 — gold
        "AppIcon5": Color(red: 0.95, green: 0.45, blue: 0.78),  // 5 — pastel magenta
        "AppIcon6": Color(red: 0.45, green: 0.55, blue: 0.95),  // 6 — pastel blue
        "AppIcon7": Color(red: 0.55, green: 0.50, blue: 0.92),  // 7 — pastel lavender
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
        for i in 1...AppIconService.themeCount {
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
        self.currentIconID = storedChoiceID
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
    private func publishTintToWidget() {
        let tint = UIColor(currentTint)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard tint.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        BrandTintStore.save(BrandTintStore.RGB(red: Double(r), green: Double(g), blue: Double(b)))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
