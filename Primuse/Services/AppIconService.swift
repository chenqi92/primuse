import Foundation

struct AppIconEasterEggTrigger {
    private var tapCount = 0
    private var lastTap: TimeInterval?

    mutating func recordTap(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let lastTap, time - lastTap > 1.5 || time < lastTap {
            tapCount = 0
        }
        lastTap = time
        tapCount += 1
        guard tapCount == 7 else { return false }
        self = Self()
        return true
    }
}

#if os(iOS) || os(tvOS)
import SwiftUI
import UIKit
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

    private static let themeOrder = [20, 19, 16, 15, 12]

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

    let hiddenOptions = [IconOption(
        id: "AppIconGroove",
        alternateName: "AppIconGroove",
        previewAsset: "AppIconGroovePreview",
        displayName: "Groove",
        supportsAppearance: false
    )]

    var availableOptions: [IconOption] { options + hiddenOptions }

    /// Persisted user choice — the option's `id`. Survives launches.
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored private let supportsIcons: () -> Bool
    @ObservationIgnored private let liveIconName: () -> String?
    @ObservationIgnored private let changeIcon: (String?) async throws -> Void
    static let storageKey = "primuse.appIconChoice"

    private(set) var currentIconID: String
    private(set) var isChangingIcon = false
    private(set) var lastError: String?

    var supportsAlternateIcons: Bool {
        supportsIcons()
    }

    init(
        defaults: UserDefaults = .standard,
        supportsIcons: @escaping () -> Bool = { UIApplication.shared.supportsAlternateIcons },
        liveIconName: @escaping () -> String? = { UIApplication.shared.alternateIconName },
        changeIcon: @escaping (String?) async throws -> Void = {
            try await UIApplication.shared.setAlternateIconName($0)
        }
    ) {
        self.defaults = defaults
        self.supportsIcons = supportsIcons
        self.liveIconName = liveIconName
        self.changeIcon = changeIcon
        self.currentIconID = ""
        let persistedID = defaults.string(forKey: Self.storageKey) ?? ""
        if availableOptions.contains(where: { $0.id == persistedID }) {
            self.currentIconID = persistedID
        } else {
            // Normalize a stored selection that no longer exists in the
            // current icon catalog so UI and tint fall back together.
            defaults.removeObject(forKey: Self.storageKey)
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
        guard supportsAlternateIcons, !isChangingIcon else { return }
        let live = liveIconName()
        if let option = availableOptions.first(where: { $0.alternateName == live }) {
            persist(option.id)
        } else {
            await setIcon(options[0])
        }
    }

    @discardableResult
    func setIcon(_ option: IconOption) async -> Bool {
        guard supportsAlternateIcons, !isChangingIcon, availableOptions.contains(option) else { return false }
        lastError = nil
        guard option.alternateName != liveIconName() else {
            persist(option.id)
            return true
        }
        isChangingIcon = true
        defer { isChangingIcon = false }

        do {
            try await changeIcon(option.alternateName)
            persist(option.id)
            return true
        } catch {
            // Reconcile with whatever the system actually has, in case the
            // call partially applied.
            let live = liveIconName()
            persist(availableOptions.first { $0.alternateName == live }?.id ?? "")
            lastError = error.localizedDescription
            return false
        }
    }

    private func persist(_ id: String) {
        currentIconID = id
        defaults.set(id, forKey: Self.storageKey)
        publishTintToWidget()
    }

    /// 图标选择和应用主题色相互独立。切换图标时仍刷新 widget，确保它立即
    /// 读取当前固定主题色，而不是把图标自身配色误写回主题。
    private func publishTintToWidget() {
        #if os(iOS)
        ThemeColorSettings.publishBaseAccentToWidget(
            ThemeColorSettings.shared.baseAccent
        )
        #endif
    }
}

#endif
