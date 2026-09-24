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
        #if DEBUG
        // 调试构建用 `PRIMUSE_DEBUG_INSTALLED_VERSION=1.9.7` 冒充旧版,在模拟器上走一遍
        // 真实的 App Store 查询与更新弹框。
        self.currentVersion = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_INSTALLED_VERSION"]
            ?? info?["CFBundleShortVersionString"] as? String ?? "0"
        #else
        self.currentVersion = info?["CFBundleShortVersionString"] as? String ?? "0"
        #endif
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
            return String(localized: "update_policy_macos_bundle_id")
        }
        return String(localized: "update_policy_macos_app_store_id")
        #else
        return String(localized: "update_policy_ios")
        #endif
    }

    var platformName: String {
        #if os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }

    /// Throttled to once per `throttleInterval` unless `force` is true.
    /// `userInitiated` 是设置里手动点「检查更新」:此时不理会之前的「稍后提醒 /
    /// 跳过此版本」—— 用户主动问了,有新版就要告诉他。
    func checkForUpdate(force: Bool = false, userInitiated: Bool = false) async {
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
        if userInitiated {
            defaults.removeObject(forKey: Self.snoozeUntilKey)
            availableUpdate = info
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

    /// 当前地区与默认 storefront 两边都查,取版本号更新的那条。App 也可能尚未在
    /// 当前地区上架,那时只剩默认 storefront 的结果。
    ///
    /// lookup 接口前面挂着 Akamai,按完整查询串缓存,max-age 可达数小时;新版上架
    /// 当天各 storefront 的缓存各自过期 —— 2026-09-25 实测 1.9.8 已发布,
    /// `country=CN` 与 `country=US` 仍返回 1.9.7,只有不带地区的查询是 1.9.8。
    /// 只信地区结果就会把「已是最新」报给还停在旧版的用户。
    private func fetchLatest() async throws -> UpdateInfo? {
        let countryCode = Locale.current.region?.identifier.uppercased()
        var regional: UpdateInfo?
        var fallback: UpdateInfo?
        var firstError: Error?
        do {
            if let countryCode {
                regional = try await fetchLatest(countryCode: countryCode)
            }
        } catch {
            firstError = error
        }
        do {
            fallback = try await fetchLatest(countryCode: nil)
        } catch {
            firstError = firstError ?? error
        }

        guard let regional else {
            if let fallback { return fallback }
            if let firstError { throw firstError }
            return nil
        }
        guard let fallback, isVersion(fallback.version, newerThan: regional.version) else {
            return regional
        }
        // 版本信息取更新的那条,商店链接仍用本地区的,免得跳到别国商店页。
        return UpdateInfo(
            version: fallback.version,
            storeURL: regional.storeURL,
            releaseNotes: fallback.releaseNotes ?? regional.releaseNotes,
            releaseDate: fallback.releaseDate,
            minimumOSVersion: fallback.minimumOSVersion,
            trackName: regional.trackName ?? fallback.trackName
        )
    }

    private func fetchLatest(countryCode: String?) async throws -> UpdateInfo? {
        guard let url = lookupURL(countryCode: countryCode) else {
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

    private func lookupURL(countryCode: String?) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        var queryItems: [URLQueryItem]
        if let explicitAppStoreID {
            queryItems = [
                URLQueryItem(name: "id", value: explicitAppStoreID),
                URLQueryItem(name: "entity", value: lookupEntity),
            ]
        } else {
            queryItems = [
                URLQueryItem(name: "bundleId", value: bundleID),
                URLQueryItem(name: "entity", value: lookupEntity),
            ]
        }
        if let countryCode {
            queryItems.append(URLQueryItem(name: "country", value: countryCode))
        }
        // CDN 的缓存键包含整条查询串;带一个一次性参数直接回源。自动检查一天只有
        // 一次,手动检查本来就要当前结果,都不该吃到几小时前的缓存。
        queryItems.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
        components?.queryItems = queryItems
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
