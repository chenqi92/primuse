import SwiftUI
import UIKit

@MainActor
@Observable
final class AppIconService {
    static let shared = AppIconService()

    struct IconOption: Identifiable, Equatable {
        /// Alternate icon name. `nil` means primary AppIcon.
        let alternateName: String?
        let previewAsset: String
        let displayKey: LocalizedStringKey
        let supportsAppearance: Bool

        var id: String { alternateName ?? "" }
    }

    static let themeCount = 7

    let options: [IconOption] = {
        var list: [IconOption] = [
            IconOption(
                alternateName: nil,
                previewAsset: "AppIconPreview",
                displayKey: "icon_default",
                supportsAppearance: false
            )
        ]
        for i in 1...Self.themeCount {
            list.append(IconOption(
                alternateName: "AppIcon\(i)",
                previewAsset: "AppIcon\(i)Preview",
                displayKey: LocalizedStringKey("icon_theme_\(i)"),
                supportsAppearance: true
            ))
        }
        return list
    }()

    private(set) var currentIconID: String

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    private init() {
        self.currentIconID = UIApplication.shared.alternateIconName ?? ""
    }

    func setIcon(_ option: IconOption) async {
        guard supportsAlternateIcons else { return }
        guard option.id != currentIconID else { return }

        do {
            try await UIApplication.shared.setAlternateIconName(option.alternateName)
            currentIconID = option.id
        } catch {
            // Sync from system in case the change partially applied
            currentIconID = UIApplication.shared.alternateIconName ?? ""
        }
    }
}
