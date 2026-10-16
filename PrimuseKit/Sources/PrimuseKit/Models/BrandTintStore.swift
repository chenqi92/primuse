import Foundation

/// Brand accent color shared from the main app to the widget extension via the
/// App Group. The main app writes the user's currently-selected app icon tint
/// here whenever it changes; the widget reads it on every timeline render so
/// its UI follows the same accent the app shows.
public enum BrandTintStore {
    private static let redKey = "primuse.brandTint.r"
    private static let greenKey = "primuse.brandTint.g"
    private static let blueKey = "primuse.brandTint.b"
    private static let artworkRedKey = "primuse.artworkTint.r"
    private static let artworkGreenKey = "primuse.artworkTint.g"
    private static let artworkBlueKey = "primuse.artworkTint.b"

    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public static func save(_ rgb: RGB) {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier) else { return }
        defaults.set(rgb.red, forKey: redKey)
        defaults.set(rgb.green, forKey: greenKey)
        defaults.set(rgb.blue, forKey: blueKey)
    }

    public static func load() -> RGB? {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              defaults.object(forKey: redKey) != nil else {
            return nil
        }
        return RGB(
            red: defaults.double(forKey: redKey),
            green: defaults.double(forKey: greenKey),
            blue: defaults.double(forKey: blueKey)
        )
    }

    /// The colour picked from the cover playing now (the theme colour when
    /// there is none). Radio, spoken word and podcasts set to follow the cover
    /// keep a colour of their own (`ListeningSpaceArtworkTintStore`), so the
    /// widgets no longer draw with this one; the app still writes it, and a
    /// change here is what refreshes them.
    public static func saveArtwork(_ rgb: RGB) {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier) else { return }
        defaults.set(rgb.red, forKey: artworkRedKey)
        defaults.set(rgb.green, forKey: artworkGreenKey)
        defaults.set(rgb.blue, forKey: artworkBlueKey)
    }

    public static func loadArtwork() -> RGB? {
        guard let defaults = UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier),
              defaults.object(forKey: artworkRedKey) != nil else {
            return nil
        }
        return RGB(
            red: defaults.double(forKey: artworkRedKey),
            green: defaults.double(forKey: artworkGreenKey),
            blue: defaults.double(forKey: artworkBlueKey)
        )
    }
}
