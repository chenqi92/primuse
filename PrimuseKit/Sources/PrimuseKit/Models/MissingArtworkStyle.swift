import Foundation

public enum MissingArtworkStyle: String, CaseIterable, Sendable {
    case standard
    case appIcon

    public static let storageKey = "primuse.artwork.missingStyle"

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .standard
    }

    public var localizationKey: String {
        switch self {
        case .standard: "default_artwork_standard"
        case .appIcon: "default_artwork_app_icon"
        }
    }

    public func usesAppIcon(forPlaceholderSymbol symbol: String) -> Bool {
        self == .appIcon && ["music.note", "square.stack", "music.note.list"].contains(symbol)
    }
}
