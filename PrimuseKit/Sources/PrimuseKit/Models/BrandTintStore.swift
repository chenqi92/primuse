import Foundation

/// Brand accent color shared from the main app to the widget extension via the
/// App Group. The main app writes the user's currently-selected app icon tint
/// here whenever it changes; the widget reads it on every timeline render so
/// its UI follows the same accent the app shows.
public enum BrandTintStore {
    private static let redKey = "primuse.brandTint.r"
    private static let greenKey = "primuse.brandTint.g"
    private static let blueKey = "primuse.brandTint.b"

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
}
