#if os(iOS)
import Foundation
import MessageUI
import PrimuseKit
import SwiftUI
import UIKit

/// Prepares the user-selected reports and logs in a system mail draft.
///
/// Nothing here ever sends by itself. The user taps a button, the system mail
/// composer opens with the recipient, subject, body and attachments already
/// filled in, and they still have to press send. Only when the system reports
/// the message as actually sent does the app offer to clear the local copies.
@MainActor
enum DiagnosticReportMailer {
    struct Attachment: Sendable {
        let data: Data
        let mimeType: String
        let fileName: String
    }

    struct Draft: Identifiable {
        let id = UUID()
        let subject: String
        let messageBody: String
        let attachments: [Attachment]
        let reportCount: Int
    }

    enum Outcome: Equatable {
        case sent
        case cancelled
        case failed(String)
    }

    /// False when the device has no configured mail account, in which case the
    /// UI points at the per-report share button instead.
    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    static func prepare(
        selection: DiagnosticReportMail.Selection,
        reportURLs: [URL],
        message: String = ""
    ) async throws -> Draft {
        if selection == .none {
            return Draft(
                subject: DiagnosticReportMail.subject(environment: environment(), isFeedback: true),
                messageBody: message,
                attachments: [],
                reportCount: 0
            )
        }
        let files = DiagnosticReportMail.attachments(
            selection: selection,
            reportURLs: reportURLs,
            logURL: FileLogger.shared.logFileURL
        )
        let logData = selection.includesLogs ? try await FileLogger.shared.exportData() : nil
        let attachments = try await Task.detached(priority: .userInitiated) {
            try files.map { file in
                let data = file.mimeType == "text/plain"
                    ? logData! : try Data(contentsOf: file.url)
                return Attachment(data: data, mimeType: file.mimeType, fileName: file.fileName)
            }
        }.value
        let reportCount = selection.includesReports ? reportURLs.count : 0
        let size = attachments.reduce(0) { $0 + $1.data.count }
        let intro: String
        switch selection {
        case .all: intro = String(localized: "diagnostics_send_all")
        case .reports: intro = String(localized: "diagnostics_send_reports_only")
        case .logs: intro = String(localized: "diagnostics_send_logs_only")
        case .none: intro = ""
        }
        return Draft(
            subject: DiagnosticReportMail.subject(environment: environment()),
            messageBody: DiagnosticReportMail.body(
                intro: intro,
                privacyNote: String(localized: "diagnostics_send_privacy"),
                environment: environment(),
                reportCount: reportCount,
                formattedSize: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                includesLogs: selection.includesLogs,
                message: message
            ),
            attachments: attachments,
            reportCount: reportCount
        )
    }

    static func environment() -> DiagnosticReportMail.Environment {
        let info = Bundle.main.infoDictionary
        return DiagnosticReportMail.Environment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info?["CFBundleVersion"] as? String ?? "",
            deviceModel: hardwareModel(),
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion
        )
    }

    /// The raw hardware identifier ("iPhone16,2"), which is what a crash report
    /// needs and what Apple already stamps into every MetricKit payload.
    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}

/// Presents MFMailComposeViewController from SwiftUI.
struct DiagnosticMailComposer: UIViewControllerRepresentable {
    let subject: String
    /// Not named `body`: that is the SwiftUI `View` requirement this type
    /// already satisfies through the representable default.
    let messageBody: String
    let attachments: [DiagnosticReportMailer.Attachment]
    let onFinish: (DiagnosticReportMailer.Outcome) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([DiagnosticReportMail.recipient])
        controller.setSubject(subject)
        controller.setMessageBody(messageBody, isHTML: false)
        for attachment in attachments {
            controller.addAttachmentData(
                attachment.data,
                mimeType: attachment.mimeType,
                fileName: attachment.fileName
            )
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: (DiagnosticReportMailer.Outcome) -> Void

        init(onFinish: @escaping (DiagnosticReportMailer.Outcome) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            if let error {
                onFinish(.failed(error.localizedDescription))
                return
            }
            switch result {
            case .sent:
                onFinish(.sent)
            case .failed:
                onFinish(.failed(String(localized: "diagnostics_send_failed_message")))
            default:
                // .cancelled and .saved both leave the reports untouched.
                onFinish(.cancelled)
            }
        }
    }
}
#endif
