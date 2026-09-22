import Foundation
import Testing
@testable import PrimuseKit

@Suite("Diagnostic report mail")
struct DiagnosticReportMailTests {
    private let environment = DiagnosticReportMail.Environment(
        appVersion: "1.9.6",
        buildNumber: "412",
        deviceModel: "iPhone16,2",
        systemName: "iOS",
        systemVersion: "18.5"
    )

    @Test("Reports go to the developer address the UI promises")
    func usesTheDeclaredRecipient() {
        #expect(DiagnosticReportMail.recipient == "hi@yzs.ai")
    }

    @Test("The subject identifies the build, device and system")
    func buildsSubject() {
        #expect(
            DiagnosticReportMail.subject(environment: environment)
                == "Primuse diagnostics · 1.9.6 (412) · iPhone16,2 · iOS 18.5"
        )
    }

    @Test("Unknown build and system details are left out, not printed empty")
    func toleratesMissingEnvironmentDetails() {
        let sparse = DiagnosticReportMail.Environment(
            appVersion: "1.9.6",
            buildNumber: "",
            deviceModel: "iPhone16,2",
            systemName: "iOS",
            systemVersion: ""
        )

        #expect(sparse.versionDescription == "1.9.6")
        #expect(sparse.systemDescription == "iOS")
        #expect(
            DiagnosticReportMail.subject(environment: sparse)
                == "Primuse diagnostics · 1.9.6 · iPhone16,2 · iOS"
        )
    }

    @Test("The technical block lists the build, device, system and report count")
    func buildsTechnicalSummary() {
        let summary = DiagnosticReportMail.technicalSummary(
            environment: environment,
            reportCount: 3,
            formattedSize: "128 KB"
        )

        #expect(summary == """
        App: Primuse 1.9.6 (412)
        Device: iPhone16,2
        System: iOS 18.5
        Reports: 3 (128 KB)
        """)
    }

    @Test("An unknown size drops the parentheses instead of showing them empty")
    func omitsUnknownSize() {
        let summary = DiagnosticReportMail.technicalSummary(
            environment: environment,
            reportCount: 1,
            formattedSize: ""
        )

        #expect(summary.hasSuffix("Reports: 1"))
    }

    @Test("The body carries the localized explanation before the technical block")
    func buildsBody() {
        let body = DiagnosticReportMail.body(
            intro: "Attached: 2.",
            privacyNote: "Thread call stacks only.",
            environment: environment,
            reportCount: 2,
            formattedSize: "64 KB"
        )

        #expect(body == """
        Attached: 2.

        Thread call stacks only.

        App: Primuse 1.9.6 (412)
        Device: iPhone16,2
        System: iOS 18.5
        Reports: 2 (64 KB)
        """)
    }

    @Test("Attachment names sort in the order the reports were listed")
    func namesAttachmentsInOrder() {
        let names = (0..<12).map { DiagnosticReportMail.attachmentName(index: $0, of: 12) }

        #expect(names.first == "primuse-diagnostic-01.json")
        #expect(names.last == "primuse-diagnostic-12.json")
        #expect(names == names.sorted())
        #expect(Set(names).count == names.count)
    }

    @Test("A single attachment is not zero-padded")
    func namesSingleAttachment() {
        #expect(
            DiagnosticReportMail.attachmentName(index: 0, of: 1)
                == "primuse-diagnostic-1.json"
        )
    }

    @Test("Each selection attaches exactly the requested file types")
    func selectsAttachments() {
        let crash = URL(fileURLWithPath: "/reports/crash.json")
        let metrics = URL(fileURLWithPath: "/reports/metrics.json")
        let log = URL(fileURLWithPath: "/logs/primuse_debug.log")
        let reports = DiagnosticReportMail.attachments(
            selection: .reports, reportURLs: [crash, metrics], logURL: log
        )
        #expect(reports.map(\.url) == [crash, metrics])
        #expect(reports.map(\.mimeType) == ["application/json", "application/json"])
        #expect(reports.map(\.fileName) == ["primuse-diagnostic-1.json", "primuse-diagnostic-2.json"])

        let logs = DiagnosticReportMail.attachments(
            selection: .logs, reportURLs: [crash, metrics], logURL: log
        )
        #expect(logs.map(\.url) == [log])
        #expect(logs.first?.mimeType == "text/plain")
        #expect(logs.first?.fileName == "primuse_debug.log")
        #expect(!DiagnosticReportMail.Selection.logs.includesReports)

        let all = DiagnosticReportMail.attachments(
            selection: .all, reportURLs: [crash, metrics], logURL: log
        )
        #expect(all == reports + logs)
    }

    @Test("Logs can be sent when no diagnostic reports exist")
    func sendsLogsWithoutReports() {
        let log = URL(fileURLWithPath: "/logs/primuse_debug.log")
        #expect(DiagnosticReportMail.attachments(
            selection: .logs, reportURLs: [], logURL: log
        ).map(\.url) == [log])
        #expect(DiagnosticReportMail.attachments(
            selection: .reports, reportURLs: [], logURL: log
        ).isEmpty)
    }

    @Test("Mail identifies included logs without inventing diagnostic reports")
    func describesLogOnlyMail() {
        let body = DiagnosticReportMail.body(
            intro: "Logs only", privacyNote: "", environment: environment,
            reportCount: 0, formattedSize: "4 KB", includesLogs: true
        )
        #expect(body.contains("Reports: 0"))
        #expect(body.contains("Logs: primuse_debug.log"))
    }

    @Test("Optional attachment toggles support both, either, or neither")
    func resolvesOptionalSelections() {
        for selection in DiagnosticReportMail.Selection.allCases {
            #expect(DiagnosticReportMail.Selection(
                includesReports: selection.includesReports,
                includesLogs: selection.includesLogs
            ) == selection)
        }
        let empty = DiagnosticReportMail.Selection(includesReports: false, includesLogs: false)
        #expect(empty == .none)
        #expect(!empty.includesReports)
        #expect(!empty.includesLogs)
        #expect(DiagnosticReportMail.attachments(
            selection: empty,
            reportURLs: [URL(fileURLWithPath: "/reports/crash.json")],
            logURL: URL(fileURLWithPath: "/logs/primuse_debug.log")
        ).isEmpty)
    }

    @Test("User feedback precedes attachment details without losing line breaks")
    func preservesMessageAlongsideReports() {
        let message = "A playback problem\n\nSteps to reproduce:"
        let body = DiagnosticReportMail.body(
            intro: "Reports", privacyNote: "", environment: environment,
            reportCount: 1, formattedSize: "4 KB", message: message
        )
        #expect(body.hasPrefix(message + "\n\nReports\n\n"))
        #expect(body.contains("Reports: 1 (4 KB)"))
    }
}
