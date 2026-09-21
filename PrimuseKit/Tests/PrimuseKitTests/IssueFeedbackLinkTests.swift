import Foundation
import Testing
@testable import PrimuseKit

@Suite("Issue feedback link")
struct IssueFeedbackLinkTests {
    private let environment = DiagnosticReportMail.Environment(
        appVersion: "1.9.7",
        buildNumber: "77",
        deviceModel: "iPhone17,1",
        systemName: "iOS",
        systemVersion: "27.0"
    )

    private func queryItems(_ url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [:] }
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } },
                          uniquingKeysWith: { first, _ in first })
    }

    @Test("The bug form arrives with version, platform and system pre-filled")
    func prefillsBugReport() {
        let url = IssueFeedbackLink.url(for: .bugReport, environment: environment, platform: .iPhone)
        let items = queryItems(url)
        #expect(url.path == "/chenqi92/primuse/issues/new")
        #expect(items["template"] == "bug_report.yml")
        #expect(items["app-version"] == "1.9.7 (77)")
        #expect(items["platform"] == "iPhone")
        #expect(items["system-version"] == "iPhone17,1 · iOS 27.0")
    }

    @Test("The feature form has no system field, so nothing is sent for it")
    func featureRequestOmitsSystemVersion() {
        let url = IssueFeedbackLink.url(for: .featureRequest, environment: environment, platform: .mac)
        let items = queryItems(url)
        #expect(items["template"] == "feature_request.yml")
        #expect(items["app-version"] == "1.9.7 (77)")
        #expect(items["platform"] == "Mac")
        #expect(items["system-version"] == nil)
    }

    @Test("Spaces survive form-urlencoded decoding instead of arriving as plus signs")
    func encodesSpacesForFormDecoding() {
        let url = IssueFeedbackLink.url(for: .bugReport, environment: environment, platform: .appleTV)
        let query = url.absoluteString
        #expect(!query.contains("+"))
        #expect(query.contains("app-version=1.9.7%20(77)"))
        #expect(query.contains("platform=Apple%20TV"))
    }

    @Test("A build without version information still opens the right form")
    func toleratesMissingEnvironment() {
        let url = IssueFeedbackLink.url(for: .bugReport, environment: nil, platform: nil)
        #expect(queryItems(url) == ["template": "bug_report.yml"])
    }

    @Test("Unknown details are left out rather than filled in empty")
    func skipsEmptyDetails() {
        let sparse = DiagnosticReportMail.Environment(
            appVersion: "1.9.7",
            buildNumber: "",
            deviceModel: "",
            systemName: "iOS",
            systemVersion: ""
        )
        let items = queryItems(
            IssueFeedbackLink.url(for: .bugReport, environment: sparse, platform: .iPad)
        )
        #expect(items["app-version"] == "1.9.7")
        #expect(items["system-version"] == "iOS")
        #expect(items["platform"] == "iPad")
    }

    @Test("A platform that reports nothing about itself sends no system field")
    func skipsWhitespaceOnlySystemDetails() {
        let unknown = DiagnosticReportMail.Environment(
            appVersion: "1.9.7",
            buildNumber: "77",
            deviceModel: "",
            systemName: "",
            systemVersion: "6.18.33"
        )
        let items = queryItems(
            IssueFeedbackLink.url(for: .bugReport, environment: unknown, platform: nil)
        )
        #expect(items["system-version"] == "6.18.33")
        #expect(items["app-version"] == "1.9.7 (77)")
    }

    @Test("Every platform option matches an option of the issue form dropdowns")
    func platformOptionsMatchTheForms() {
        // The forms list these verbatim; see .github/ISSUE_TEMPLATE/bug_report.yml.
        #expect(IssueFeedbackLink.PlatformOption.iPhone.rawValue == "iPhone")
        #expect(IssueFeedbackLink.PlatformOption.iPad.rawValue == "iPad")
        #expect(IssueFeedbackLink.PlatformOption.mac.rawValue == "Mac")
        #expect(IssueFeedbackLink.PlatformOption.appleTV.rawValue == "Apple TV")
    }

    @Test("Template names match the files under .github/ISSUE_TEMPLATE")
    func templateNamesMatchTheFiles() {
        #expect(IssueFeedbackLink.Template.allCases.map(\.rawValue)
            == ["bug_report.yml", "feature_request.yml"])
    }
}
