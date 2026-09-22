import Foundation

/// Describes the attachments the user chooses for a diagnostic email.
public enum DiagnosticReportMail {
    /// Where the reports go. Shown to the user before anything is sent.
    public static let recipient = "hi@yzs.ai"
    public enum Selection: Sendable, CaseIterable {
        case all, reports, logs, none

        public init(includesReports: Bool, includesLogs: Bool) {
            switch (includesReports, includesLogs) {
            case (true, true): self = .all
            case (true, false): self = .reports
            case (false, true): self = .logs
            case (false, false): self = .none
            }
        }

        public var includesReports: Bool { self == .all || self == .reports }
        public var includesLogs: Bool { self == .all || self == .logs }
    }

    public struct Attachment: Equatable, Sendable {
        public let url: URL
        public let mimeType: String
        public let fileName: String
    }

    public static func attachments(
        selection: Selection,
        reportURLs: [URL],
        logURL: URL
    ) -> [Attachment] {
        var result: [Attachment] = selection.includesReports
            ? reportURLs.enumerated().map { index, url in
                Attachment(
                    url: url, mimeType: "application/json",
                    fileName: attachmentName(index: index, of: reportURLs.count)
                )
            } : []
        if selection.includesLogs {
            result.append(Attachment(url: logURL, mimeType: "text/plain", fileName: "primuse_debug.log"))
        }
        return result
    }

    /// The non-personal identifiers that travel with a report.
    public struct Environment: Equatable, Sendable {
        public let appName: String
        public let appVersion: String
        public let buildNumber: String
        public let deviceModel: String
        public let systemName: String
        public let systemVersion: String

        public init(
            appName: String = "Primuse",
            appVersion: String,
            buildNumber: String,
            deviceModel: String,
            systemName: String,
            systemVersion: String
        ) {
            self.appName = appName
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.deviceModel = deviceModel
            self.systemName = systemName
            self.systemVersion = systemVersion
        }

        /// "1.9.6 (412)", or just "1.9.6" when the build number is unknown.
        public var versionDescription: String {
            guard !buildNumber.isEmpty else { return appVersion }
            return "\(appVersion) (\(buildNumber))"
        }

        /// "iOS 18.5", or just the name when the version is unknown.
        public var systemDescription: String {
            guard !systemVersion.isEmpty else { return systemName }
            return "\(systemName) \(systemVersion)"
        }
    }

    /// Deliberately English and machine-greppable: it lands in the developer's
    /// inbox, not in the sender's own language.
    public static func subject(environment: Environment, isFeedback: Bool = false) -> String {
        [
            "\(environment.appName) \(isFeedback ? "feedback" : "diagnostics")",
            environment.versionDescription,
            environment.deviceModel,
            environment.systemDescription,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    /// The technical block appended under the localized explanation. English
    /// for the same reason the subject is.
    public static func technicalSummary(
        environment: Environment,
        reportCount: Int,
        formattedSize: String
    ) -> String {
        let reports = formattedSize.isEmpty
            ? "Reports: \(reportCount)"
            : "Reports: \(reportCount) (\(formattedSize))"
        return [
            "App: \(environment.appName) \(environment.versionDescription)",
            "Device: \(environment.deviceModel)",
            "System: \(environment.systemDescription)",
            reports,
        ].joined(separator: "\n")
    }

    /// Full mail body: the selected content followed by the technical block.
    ///
    /// `intro` and `privacyNote` come from the app's localized strings so the
    /// sender reads them in their own language before tapping send.
    public static func body(
        intro: String,
        privacyNote: String,
        environment: Environment,
        reportCount: Int,
        formattedSize: String,
        includesLogs: Bool = false,
        message: String = ""
    ) -> String {
        let summary = technicalSummary(
            environment: environment,
            reportCount: reportCount,
            formattedSize: formattedSize
        )
        return [message, intro, privacyNote, summary + (includesLogs ? "\nLogs: primuse_debug.log" : "")]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// MetricKit files are named `crash-<unix-ts>-<uuid8>.json`, which is
    /// already anonymous. Attach them under a stable, ordered name so a mail
    /// client cannot reorder them into something ambiguous.
    public static func attachmentName(index: Int, of total: Int) -> String {
        let width = String(total).count
        let number = String(format: "%0\(width)d", index + 1)
        return "primuse-diagnostic-\(number).json"
    }
}
