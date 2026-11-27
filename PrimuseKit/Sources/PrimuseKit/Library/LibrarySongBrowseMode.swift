import Foundation

public enum LibrarySongBrowseMode: String, CaseIterable, Hashable, Sendable {
    case folder
    case flat
}

/// Keeps the song-library browse choice independent from SwiftUI so upgrades,
/// relaunches, and platform-specific views all follow the same migration rule.
public enum LibrarySongBrowseModePreference {
    public static let storageKey = "library.songBrowseMode"

    public static func mode(flatViewEnabled: Bool) -> LibrarySongBrowseMode {
        flatViewEnabled ? .flat : .folder
    }

    public static func isFlatViewEnabled(
        in defaults: UserDefaults = .standard
    ) -> Bool {
        load(from: defaults) == .flat
    }

    public static func setFlatViewEnabled(
        _ isEnabled: Bool,
        to defaults: UserDefaults = .standard
    ) {
        save(mode(flatViewEnabled: isEnabled), to: defaults)
    }

    /// Persist the caller's platform default only when no valid user choice
    /// exists, then preserve every later explicit choice across relaunches.
    @discardableResult
    public static func load(
        from defaults: UserDefaults = .standard,
        defaultMode: LibrarySongBrowseMode = .folder
    ) -> LibrarySongBrowseMode {
        if let rawValue = defaults.string(forKey: storageKey),
           let mode = LibrarySongBrowseMode(rawValue: rawValue) {
            return mode
        }

        defaults.set(defaultMode.rawValue, forKey: storageKey)
        return defaultMode
    }

    public static func save(
        _ mode: LibrarySongBrowseMode,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: storageKey)
    }
}
