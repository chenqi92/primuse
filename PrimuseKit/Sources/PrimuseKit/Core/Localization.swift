import Foundation

/// Shared localization entry point for code that imports PrimuseKit but lives
/// outside the framework (Widget / Watch / tvOS / Activity / TopShelf
/// extensions). Those targets can't reach the `internal` `Bundle.primuseKit`
/// token, so this `public` helper routes their lookups through PrimuseKit's own
/// 7-language (`en` / `zh-Hans` / `zh-Hant` / `de` / `fr` / `ja` / `ko`)
/// `Localizable.strings`, guaranteeing one source of truth for every surface.
///
/// - Parameters:
///   - key: The `Localizable.strings` key to resolve.
///   - args: Optional `printf`-style format arguments. When supplied, the
///     resolved string is treated as a format string and filled in.
/// - Returns: The localized (and optionally formatted) string.
public func PMString(_ key: String, _ args: CVarArg...) -> String {
    let localized = Bundle.primuseKit.localizedString(
        forKey: key,
        value: key,
        table: nil
    )
    guard !args.isEmpty else { return localized }
    return String(format: localized, arguments: args)
}
