import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Version and hardware facts about the running app, collected without UIKit so
/// every platform (and the Linux test harness) can build it.
///
/// `DiagnosticReportMailer` on iOS asks UIKit for the same three values when it
/// composes a diagnostics mail; this one exists for code that has no UIKit to
/// ask, such as the Mac About page and `IssueFeedbackLink`.
public enum RunningAppEnvironment {
    public static func diagnosticEnvironment(bundle: Bundle = .main) -> DiagnosticReportMail.Environment {
        let info = bundle.infoDictionary
        return DiagnosticReportMail.Environment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info?["CFBundleVersion"] as? String ?? "",
            deviceModel: hardwareModel,
            systemName: systemName,
            systemVersion: systemVersion
        )
    }

    /// Which `platform` option of the issue forms this build is running as.
    public static var issuePlatform: IssueFeedbackLink.PlatformOption? {
        #if os(macOS)
        return .mac
        #elseif os(tvOS)
        return .appleTV
        #elseif os(iOS)
        return hardwareModel.hasPrefix("iPad") ? .iPad : .iPhone
        #else
        return nil
        #endif
    }

    /// The raw identifier ("iPhone17,1", "MacBookPro18,3"), which is what Apple
    /// stamps into crash reports. Empty when the platform cannot report one.
    public static var hardwareModel: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }
        #endif
        #if os(macOS)
        return sysctlString(name: "hw.model")
        #elseif canImport(Darwin)
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return withUnsafeBytes(of: &info.machine) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #else
        return ""
        #endif
    }

    public static var systemName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(iOS)
        // UIDevice would say this for us, but it is main-actor bound and this
        // type deliberately stays free of UIKit.
        return hardwareModel.hasPrefix("iPad") ? "iPadOS" : "iOS"
        #else
        return ""
        #endif
    }

    /// "27.0", or "27.0.1" when there is a patch component.
    public static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var parts = [version.majorVersion, version.minorVersion]
        if version.patchVersion > 0 { parts.append(version.patchVersion) }
        return parts.map(String.init).joined(separator: ".")
    }

    #if os(macOS)
    private static func sysctlString(name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
    #endif
}
