import Foundation

/// `Bundle(for:)` returns the bundle containing the given class. Routing all
/// PrimuseKit string lookups through this token guarantees we read from the
/// framework's own .lproj files instead of the host app's. Required because
/// PrimuseKit ships as an Xcode framework target — `Bundle.module` (the SPM
/// shortcut) doesn't exist here.
final class PrimuseKitBundleToken {}

extension Bundle {
    static let primuseKit = Bundle(for: PrimuseKitBundleToken.self)
}
