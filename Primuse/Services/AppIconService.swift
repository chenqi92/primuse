import SwiftUI
import UIKit

@MainActor
@Observable
final class AppIconService {
    static let shared = AppIconService()

    /// One selectable icon design. Each design ships two physical alternate icons
    /// in the asset catalog — `AppIconN` (light) and `AppIconNDark` (dark) — and
    /// we manually pass whichever name matches the current system appearance to
    /// `setAlternateIconName`. We don't rely on the asset catalog's `appearances`
    /// field for alternate icons because iOS's `setAlternateIconName` picks names
    /// literally and does NOT auto-resolve light/dark variants the way it does
    /// for the primary AppIcon.
    struct IconOption: Identifiable, Equatable {
        /// Stable identifier for the design — matches the LIGHT variant's asset
        /// name (or empty string for the default primary icon). Used as the
        /// selection key in UI and persisted state.
        let id: String

        /// Alternate icon name to use in light mode. `nil` means primary icon.
        let lightName: String?

        /// Alternate icon name to use in dark mode. Falls back to `lightName`
        /// when no dark variant exists.
        let darkName: String?

        let previewAsset: String
        let displayName: String

        /// Brand tint that the chosen icon paints across the rest of the UI as
        /// the fallback accent (when no song's cover art is driving the theme).
        let tint: Color

        /// True if the design has separate dark/light artwork — used by the
        /// settings UI to render the "auto-switch" badge.
        var supportsAppearance: Bool { darkName != nil && darkName != lightName }
    }

    static let themeCount = 7

    /// Themes that ship only a single visual variant — using it in both light
    /// and dark mode. Add a theme index here when no `*Dark` iconset exists
    /// for that theme.
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
            // The "default" option is the primary icon, but its dark variant
            // ships as an explicit alternate (AppIconDark). iOS does not
            // reliably auto-swap appearance variants of the primary icon when
            // setAlternateIconName(nil) is called, so we drive the variant
            // ourselves the same way the alternate icons do.
            IconOption(
                id: "",
                lightName: nil,
                darkName: "AppIconDark",
                previewAsset: "AppIconPreview",
                displayName: NSLocalizedString("icon_default", comment: ""),
                tint: AppIconService.iconTints[""] ?? Color.accentColor
            )
        ]
        for i in 1...AppIconService.themeCount {
            let lightName = "AppIcon\(i)"
            let darkName = AppIconService.singleVariantThemes.contains(i)
                ? lightName
                : "AppIcon\(i)Dark"
            list.append(IconOption(
                id: lightName,
                lightName: lightName,
                darkName: darkName,
                previewAsset: "AppIcon\(i)Preview",
                displayName: NSLocalizedString("icon_theme_\(i)", comment: ""),
                tint: AppIconService.iconTints[lightName] ?? Color.accentColor
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

    /// Persisted user choice — the option's `id`. Survives appearance changes;
    /// the actual alternate-icon name we call into iOS with is computed each time.
    @ObservationIgnored
    @AppStorage("primuse.appIconChoice") private var storedChoiceID: String = ""

    /// Set the first time the user actively picks an icon. Until that happens
    /// we leave the system primary icon alone — otherwise on first launch we'd
    /// trigger iOS's "icon changed" alert just because we'd flip to AppIconDark
    /// to match dark mode, which the user never asked for.
    @ObservationIgnored
    @AppStorage("primuse.appIconChosen") private var hasUserChosen: Bool = false

    private(set) var currentIconID: String

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    private init() {
        self.currentIconID = ""
        // Read after init so @AppStorage can resolve.
        self.currentIconID = storedChoiceID
        registerAppearanceObservers()
        // Sync the icon to current appearance on launch — the user may have
        // changed system mode while the app was killed.
        Task { @MainActor in self.refreshForCurrentAppearance() }
    }

    func setIcon(_ option: IconOption) async {
        guard supportsAlternateIcons else { return }
        let target = currentName(for: option)
        let actual = UIApplication.shared.alternateIconName

        storedChoiceID = option.id
        currentIconID = option.id
        hasUserChosen = true

        guard target != actual else { return }

        do {
            try await UIApplication.shared.setAlternateIconName(target)
        } catch {
            // Reconcile with whatever the system actually has, in case the
            // call partially applied.
            let live = UIApplication.shared.alternateIconName
            currentIconID = options.first { $0.lightName == live || $0.darkName == live }?.id ?? ""
            storedChoiceID = currentIconID
        }
    }

    // MARK: - Appearance-aware name resolution

    private func currentName(for option: IconOption) -> String? {
        let style = effectiveInterfaceStyle()
        switch style {
        case .dark:
            return option.darkName ?? option.lightName
        default:
            return option.lightName
        }
    }

    private func option(forID id: String) -> IconOption? {
        options.first { $0.id == id }
    }

    private func effectiveInterfaceStyle() -> UIUserInterfaceStyle {
        // Prefer the app's key window trait — accurate even if the app has
        // overridden its style. Fall back to the screen trait.
        if let window = Self.keyWindow() {
            return window.traitCollection.userInterfaceStyle
        }
        return UIScreen.main.traitCollection.userInterfaceStyle
    }

    // MARK: - Appearance auto-refresh

    private func registerAppearanceObservers() {
        // Re-evaluate when returning from background — appearance may have
        // changed via Settings while we were suspended.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshForCurrentAppearance() }
        }

        // Live trait changes while foregrounded.
        Task { @MainActor in
            await self.attachTraitObserver()
        }
    }

    private func attachTraitObserver() async {
        for _ in 0..<25 {
            if let window = Self.keyWindow() {
                window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindow, _: UITraitCollection) in
                    Task { @MainActor in self?.refreshForCurrentAppearance() }
                }
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func refreshForCurrentAppearance() {
        guard supportsAlternateIcons else { return }
        // Don't touch the icon until the user has actively picked one — calling
        // setAlternateIconName here on a fresh install triggers iOS's "icon
        // changed" system alert, which is jarring and unprompted.
        guard hasUserChosen else { return }
        guard let option = option(forID: storedChoiceID) else { return }
        let target = currentName(for: option)
        let actual = UIApplication.shared.alternateIconName
        guard target != actual else { return }
        UIApplication.shared.setAlternateIconName(target) { _ in }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
