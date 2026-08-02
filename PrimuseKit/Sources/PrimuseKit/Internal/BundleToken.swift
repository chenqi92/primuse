import Foundation

/// `Bundle(for:)` returns the bundle containing the given class. Routing all
/// PrimuseKit string lookups through this token guarantees we read from the
/// framework's own .lproj files instead of the host app's. Xcode framework
/// builds use `Bundle(for:)`; Swift Package builds use their generated resource
/// bundle so tests exercise the same localized strings shipped by the app.
final class PrimuseKitBundleToken {}

extension Bundle {
    #if SWIFT_PACKAGE
    static let primuseKit = Bundle.module
    #else
    static let primuseKit = Bundle(for: PrimuseKitBundleToken.self)
    #endif
}
