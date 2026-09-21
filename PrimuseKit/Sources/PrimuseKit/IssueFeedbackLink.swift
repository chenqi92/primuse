import Foundation

/// The "report a problem" / "suggest a feature" links in About.
///
/// Both point at the repository's issue forms and pre-fill the version, the
/// device端 and the OS version the user is running, because that is exactly
/// what a report usually arrives without. Nothing is submitted by opening the
/// link: the form appears in the browser with those fields filled in, and the
/// user can edit or clear any of them before pressing submit. Only the
/// description is required by the form itself — see
/// `.github/ISSUE_TEMPLATE/bug_report.yml`.
public enum IssueFeedbackLink {
    public static let repositoryURL = URL(string: "https://github.com/chenqi92/primuse")!

    /// The manual "pick a template" page. Also the fallback for the rare case
    /// where the pre-filled URL cannot be composed.
    public static let templateChooserURL = URL(
        string: "https://github.com/chenqi92/primuse/issues/new/choose"
    )!

    private static let newIssueURL = URL(string: "https://github.com/chenqi92/primuse/issues/new")!

    /// Form file names under `.github/ISSUE_TEMPLATE/`. Renaming a file there
    /// breaks the link, so these two strings have to move together with it.
    public enum Template: String, Sendable, CaseIterable {
        case bugReport = "bug_report.yml"
        case featureRequest = "feature_request.yml"

        /// Only the bug form has a "机型与系统版本" field. GitHub ignores query
        /// parameters that name no field, but there is no reason to send them.
        var acceptsSystemVersion: Bool { self == .bugReport }
    }

    /// Must match the `platform` dropdown options in the issue forms word for
    /// word: GitHub pre-selects a dropdown only when the value is one of its
    /// options, and silently leaves the field empty otherwise. The forms list
    /// more options than this (CarPlay, widgets, Apple Watch); only the ones a
    /// running app can claim for itself are here.
    public enum PlatformOption: String, Sendable {
        case iPhone = "iPhone"
        case iPad = "iPad"
        case mac = "Mac"
        case appleTV = "Apple TV"
    }

    /// Field ids from the issue forms, used as query parameter names.
    private enum Field {
        static let template = "template"
        static let appVersion = "app-version"
        static let platform = "platform"
        static let systemVersion = "system-version"
    }

    public static func url(
        for template: Template,
        environment: DiagnosticReportMail.Environment?,
        platform: PlatformOption?
    ) -> URL {
        var items = [URLQueryItem(name: Field.template, value: template.rawValue)]

        if let environment {
            let version = environment.versionDescription
            if !version.isEmpty {
                items.append(URLQueryItem(name: Field.appVersion, value: version))
            }
            if template.acceptsSystemVersion {
                let system = systemDescription(for: environment)
                if !system.isEmpty {
                    items.append(URLQueryItem(name: Field.systemVersion, value: system))
                }
            }
        }

        if let platform {
            items.append(URLQueryItem(name: Field.platform, value: platform.rawValue))
        }

        guard var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false) else {
            return templateChooserURL
        }
        components.queryItems = items
        // Issue forms decode their pre-fill values form-urlencoded style, so a
        // literal "+" in a value would arrive as a space.
        return FormSafeQueryURLBuilder.url(from: components) ?? templateChooserURL
    }

    /// "iPhone17,1 · iOS 27.0" — the model identifier is worth more than a
    /// marketing name here, since that is what crash reports carry.
    ///
    /// Trimmed because `systemDescription` joins a name and a version with a
    /// space, and a platform that reports neither would otherwise pre-fill the
    /// field with whitespace.
    static func systemDescription(for environment: DiagnosticReportMail.Environment) -> String {
        [environment.deviceModel, environment.systemDescription]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
