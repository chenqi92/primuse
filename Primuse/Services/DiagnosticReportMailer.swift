#if os(iOS)
import Foundation
import MessageUI
import PrimuseKit
import SwiftUI
import UIKit

/// One-tap delivery of the locally stored MetricKit reports to the developer.
///
/// Nothing here ever sends by itself. The user taps a button, the system mail
/// composer opens with the recipient, subject, body and attachments already
/// filled in, and they still have to press send. Only when the system reports
/// the message as actually sent does the app offer to clear the local copies.
@MainActor
enum DiagnosticReportMailer {
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
    let attachments: [URL]
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
        for (index, url) in attachments.enumerated() {
            guard let data = try? Data(contentsOf: url) else { continue }
            controller.addAttachmentData(
                data,
                mimeType: "application/json",
                fileName: DiagnosticReportMail.attachmentName(
                    index: index,
                    of: attachments.count
                )
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
