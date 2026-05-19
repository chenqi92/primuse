import Foundation

/// Build-time defaults for third-party integrations.
///
/// Real values should be supplied through `Config/Secrets.local.xcconfig`,
/// which is ignored by git and expanded into Info.plist at build time. Empty
/// values keep the app in "user supplies their own key in Settings" mode.
enum AppSecrets {
    static var lastFmAPIKey: String {
        secretValue(for: "PrimuseLastFmAPIKey")
    }

    static var lastFmAPISecret: String {
        secretValue(for: "PrimuseLastFmAPISecret")
    }

    static let scraperSecrets: [String: [String: String]] = [:]

    private static func secretValue(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return ""
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }
}
