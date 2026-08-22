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

        /// True if the design ships a separate dark artwork variant — used by
        /// the settings UI to render the "auto-switch" badge.
        let supportsAppearance: Bool
    }

    /// Keep the classic icon immediately after the current primary icon,
    /// then show the retained design alternatives in their existing order.
    private static let themeOrder = [9, 12, 11, 6]

    /// Themes that ship only a single visual variant (no dark counterpart in
    /// the asset catalog). Add a theme index here when no dark image exists.
    private static let singleVariantThemes: Set<Int> = []

    let options: [IconOption] = {
        var list: [IconOption] = [
            IconOption(
                id: "",
                alternateName: nil,
                previewAsset: "AppIconPreview",
                displayName: NSLocalizedString("icon_default", comment: ""),
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
                supportsAppearance: !AppIconService.singleVariantThemes.contains(i)
            ))
        }
        return list
    }()

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

    /// An icon selected by an older build can remain active after its asset is
    /// retired. Restore the primary icon once the app becomes active so the
    /// Home Screen and the in-app selection stay in sync after an upgrade.
    func restorePrimaryIconIfNeeded() async {
        guard supportsAlternateIcons,
              let live = UIApplication.shared.alternateIconName,
              !options.contains(where: { $0.alternateName == live }) else {
            return
        }

        do {
            try await UIApplication.shared.setAlternateIconName(nil)
            currentIconID = ""
            storedChoiceID = ""
            publishTintToWidget()
        } catch {
            // Retry on the next activation; UIKit can reject icon changes
            // while the application is still transitioning to foreground.
        }
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

    /// 图标选择和应用主题色相互独立。切换图标时仍刷新 widget，确保它立即
    /// 读取当前固定主题色，而不是把图标自身配色误写回主题。
    private func publishTintToWidget() {
        ThemeColorSettings.publishBaseAccentToWidget(
            ThemeColorSettings.shared.baseAccent
        )
    }
}

#endif
