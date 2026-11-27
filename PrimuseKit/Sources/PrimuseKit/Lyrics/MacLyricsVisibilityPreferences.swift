import Foundation

public struct MacLyricsVisibility: Equatable, Sendable {
    public let desktop: Bool
    public let island: Bool
}

public enum MacLyricsVisibilityPreferences {
    public static let desktopKey = "desktopLyricsVisible"
    public static let islandKey = "desktopLyricsIsland"
    public static let independentVisibilityKey = "desktopLyricsIndependentVisibility.v1"

    public static func restore(in defaults: UserDefaults = .standard) -> MacLyricsVisibility {
        if !defaults.bool(forKey: independentVisibilityKey) {
            let wasVisible = defaults.bool(forKey: desktopKey)
            let usedIsland = defaults.bool(forKey: islandKey)
            // The previous visible flag referred to either surface. Preserve what was on screen.
            defaults.set(wasVisible && !usedIsland, forKey: desktopKey)
            defaults.set(wasVisible && usedIsland, forKey: islandKey)
            defaults.set(true, forKey: independentVisibilityKey)
        }
        return visibility(in: defaults)
    }

    public static func visibility(in defaults: UserDefaults = .standard) -> MacLyricsVisibility {
        MacLyricsVisibility(
            desktop: defaults.bool(forKey: desktopKey),
            island: defaults.bool(forKey: islandKey)
        )
    }

    public static func setDesktopVisible(_ visible: Bool, in defaults: UserDefaults = .standard) {
        _ = restore(in: defaults)
        defaults.set(visible, forKey: desktopKey)
    }

    public static func setIslandVisible(_ visible: Bool, in defaults: UserDefaults = .standard) {
        _ = restore(in: defaults)
        defaults.set(visible, forKey: islandKey)
    }
}
