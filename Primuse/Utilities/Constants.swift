import Foundation

enum AppConstants {
    static let minBufferDuration: TimeInterval = 30
    static let maxRecentSearches = 10
    static let thumbnailSize: CGFloat = 100
    static let largeCoverSize: CGFloat = 600

    /// Device label sent to NAS / cloud auth flows (e.g. Synology
    /// `device_name`). DSM shows this in the trusted devices list, so it
    /// should reflect the actual platform — a Mac showing "Primuse-iOS" is
    /// confusing.
    static var trustedDeviceName: String {
        #if os(macOS)
        return "Primuse-macOS"
        #else
        return "Primuse-iOS"
        #endif
    }
}
