import Foundation

extension Bundle {
    /// 应用版本号 (跟 xcconfig 的 MARKETING_VERSION 一致, 来自 Info.plist
    /// 的 CFBundleShortVersionString)。
    var appVersion: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Build 号 (跟 xcconfig 的 CURRENT_PROJECT_VERSION 一致, 来自 Info.plist
    /// 的 CFBundleVersion)。
    var appBuildNumber: String {
        (object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }
}
