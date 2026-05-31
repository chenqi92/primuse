import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Polls Apple's iTunes Lookup API to learn whether the current build is
/// behind App Store, surfaces a banner inviting the user to update.
///
/// iOS doesn't let an app force itself to update — auto-update is a
/// system-level user setting, gated by Wi-Fi / battery / app size. Users
/// on TestFlight or with auto-update off won't see new builds without a
/// nudge. This checker provides that nudge:
///
/// - Hits Apple's lookup endpoint for the current platform only. macOS native
///   builds must not treat an iOS/iPad app that is available on Mac as the
///   native Mac App Store version line.
/// - Compares `version` semantically against the running build's
///   `CFBundleShortVersionString`.
/// - Persists "skip this version" / "remind later" in UserDefaults so the
///   banner doesn't pester the user every launch.
@MainActor
@Observable
final class AppUpdateChecker {
    struct UpdateInfo: Sendable, Equatable {
        let version: String
        let storeURL: URL
        let releaseNotes: String?
        let releaseDate: Date?
        let minimumOSVersion: String?
        let trackName: String?
    }

    /// Non-nil when a strictly newer App Store version exists AND the
    /// user hasn't dismissed it. Banner observes this.
    private(set) var availableUpdate: UpdateInfo?
    private(set) var latestUpdateInfo: UpdateInfo?
    private(set) var latestStoreVersion: String?
    private(set) var storeURL: URL?
    private(set) var lastCheckedAt: Date?
    private(set) var lastErrorMessage: String?
    private(set) var isChecking = false

    private let bundleID: String
    private let currentVersion: String
    private let explicitAppStoreID: String?
    private let defaults: UserDefaults
    private let session: URLSession

    private static let skippedVersionKey = "primuse.update.skippedVersion"
    private static let snoozeUntilKey = "primuse.update.snoozeUntil"
    private static let lastCheckKey = "primuse.update.lastCheckedAt"
    /// "稍后提醒" 静默 7 天 ── 跟微信 / 抖音的更新提示节奏对齐。24 小时
    /// 太频繁; 一周一提既能让用户记起, 又不至于打扰。
    private static let snoozeDuration: TimeInterval = 7 * 24 * 3600
    /// 一天 fetch 一次 App Store 足够 ── 用户实际感知的"有新版"决策
    /// 颗粒度本来就是天级。频繁 hit Apple lookup 浪费流量也可能被节流。
    private static let throttleInterval: TimeInterval = 24 * 3600

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        let info = Bundle.main.infoDictionary
        self.bundleID = info?["CFBundleIdentifier"] as? String ?? "com.welape.yuanyin"
        self.currentVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        #if os(macOS)
        self.explicitAppStoreID = Self.cleanInfoString(info?["PrimuseMacAppStoreID"] as? String)
            ?? Self.cleanInfoString(info?["PrimuseAppStoreID"] as? String)
        #else
        self.explicitAppStoreID = Self.cleanInfoString(info?["PrimuseIOSAppStoreID"] as? String)
            ?? Self.cleanInfoString(info?["PrimuseAppStoreID"] as? String)
        #endif
        self.defaults = defaults
        self.session = session
        self.lastCheckedAt = defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    var installedVersion: String { currentVersion }
    var appStoreBundleID: String { bundleID }
    var appStoreLookupTarget: String {
        if let explicitAppStoreID {
            return "\(platformName) · App Store ID \(explicitAppStoreID)"
        }
        return "\(platformName) · Bundle ID \(bundleID)"
    }

    var versionPolicyDescription: String {
        #if os(macOS)
        if explicitAppStoreID == nil {
            return "macOS 与 iOS 分开检查；当前未配置 Mac App Store ID，因此只接受 Bundle ID 查询里 kind=mac-software 的原生 Mac 记录，忽略 iOS 1.x 版本线。"
        }
        return "macOS 与 iOS 分开检查；当前使用 Mac App Store ID 查询原生 Mac 版本线，iOS 版本不会触发 macOS 更新提示。"
        #else
        return "iOS 与 macOS 分开检查；当前仅检查 iOS App Store 版本线。"
        #endif
    }

    var platformName: String {
        #if os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }

    /// Throttled to once per `throttleInterval` unless `force` is true
    /// (manual "check for updates" tap from settings, if/when added).
    func checkForUpdate(force: Bool = false) async {
        if !force,
           let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.throttleInterval {
            return
        }

        isChecking = true
        defer { isChecking = false }

        let info: UpdateInfo?
        do {
            info = try await fetchLatest()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            return
        }
        let checkedAt = Date()
        defaults.set(checkedAt, forKey: Self.lastCheckKey)
        lastCheckedAt = checkedAt
        latestUpdateInfo = info
        latestStoreVersion = info?.version
        storeURL = info?.storeURL

        guard let info, isVersion(info.version, newerThan: currentVersion) else {
            availableUpdate = nil
            return
        }

        // Honor user's prior "skip this version". Skipped record is keyed
        // by version string — once Apple ships an even newer version,
        // the comparison fails and the banner returns.
        if let skipped = defaults.string(forKey: Self.skippedVersionKey),
           skipped == info.version {
            availableUpdate = nil
            return
        }
        if let until = defaults.object(forKey: Self.snoozeUntilKey) as? Date,
           until > Date() {
            availableUpdate = nil
            return
        }

        availableUpdate = info
    }

    /// "Skip this version" — banner stays hidden until App Store lists
    /// something newer than `version`.
    func skipCurrentVersion() {
        guard let v = availableUpdate?.version else { return }
        defaults.set(v, forKey: Self.skippedVersionKey)
        availableUpdate = nil
    }

    /// "Remind me later" — banner hidden for 24h.
    func snooze() {
        defaults.set(Date().addingTimeInterval(Self.snoozeDuration), forKey: Self.snoozeUntilKey)
        availableUpdate = nil
    }

    /// Open App Store at the app's listing.
    func openAppStore() {
        guard let url = availableUpdate?.storeURL ?? storeURL else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - Private

    private struct LookupResponse: Decodable {
        struct Result: Decodable {
            let version: String
            let trackViewUrl: String
            let kind: String?
            let bundleId: String?
            let trackId: Int?
            let releaseNotes: String?
            let currentVersionReleaseDate: String?
            let releaseDate: String?
            let minimumOsVersion: String?
            let trackName: String?
        }
        let results: [Result]
    }

    private func fetchLatest() async throws -> UpdateInfo? {
        guard let url = lookupURL() else {
            return nil
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        let (data, _) = try await session.data(for: req)
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard let r = response.results.first(where: isResultForCurrentPlatform),
              let storeURL = URL(string: r.trackViewUrl) else { return nil }
        return UpdateInfo(
            version: r.version,
            storeURL: storeURL,
            releaseNotes: Self.cleanInfoString(r.releaseNotes),
            releaseDate: Self.parseAppStoreDate(r.currentVersionReleaseDate ?? r.releaseDate),
            minimumOSVersion: Self.cleanInfoString(r.minimumOsVersion),
            trackName: Self.cleanInfoString(r.trackName)
        )
    }

    private func lookupURL() -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        if let explicitAppStoreID {
            components?.queryItems = [
                URLQueryItem(name: "id", value: explicitAppStoreID),
                URLQueryItem(name: "entity", value: lookupEntity),
            ]
        } else {
            components?.queryItems = [
                URLQueryItem(name: "bundleId", value: bundleID),
                URLQueryItem(name: "entity", value: lookupEntity),
            ]
        }
        return components?.url
    }

    private var lookupEntity: String {
        #if os(macOS)
        return "macSoftware"
        #else
        return "software"
        #endif
    }

    private func isResultForCurrentPlatform(_ result: LookupResponse.Result) -> Bool {
        #if os(macOS)
        // Apple's lookup can return an iOS app that is installable on Mac
        // (`kind=software`, supportedDevices contains MacDesktop) even when
        // `entity=macSoftware` is present. The native macOS build must only
        // compare against true Mac App Store records.
        return result.kind == "mac-software"
        #else
        return result.kind == nil || result.kind == "software"
        #endif
    }

    private static func cleanInfoString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    private static func parseAppStoreDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Numeric semantic compare — "1.10.0" > "1.2.0" (which the default
    /// lexicographic compare would get wrong).
    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
