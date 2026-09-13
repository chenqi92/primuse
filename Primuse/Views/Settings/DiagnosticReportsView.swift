import SwiftUI
import PrimuseKit

/// Settings → 关于 → 诊断报告。显示由 MetricKit 上报的 crash / hang 报告
/// 列表,点击可以分享 (邮件 / AirDrop / 复制) 给开发者排查。报告全部本地
/// 存放,不会自动外发 —— 顶部的「发送给开发者」按钮也只是把系统邮件草稿
/// 填好,仍然要用户自己按发送。
struct DiagnosticReportsView: View {
    @State private var reports: [DiagnosticReport] = []
    @State private var showClearConfirm = false
    @State private var showComposer = false
    @State private var showSentPrompt = false
    @State private var showMailUnavailable = false
    @State private var failureMessage: String?
    private let service: CrashDiagnosticsService

    init(service: CrashDiagnosticsService) {
        self.service = service
    }

    var body: some View {
        #if os(iOS)
        reportsList.modifier(DiagnosticMailSupport(
            showComposer: $showComposer,
            showSentPrompt: $showSentPrompt,
            showMailUnavailable: $showMailUnavailable,
            failureMessage: $failureMessage,
            subject: mailSubject,
            messageBody: mailBody,
            attachments: reports.map(\.url),
            onClearRequested: clearAll
        ))
        #else
        reportsList
        #endif
    }

    private var reportsList: some View {
        List {
            if reports.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text(String(localized: "diagnostics_empty_title"))
                            .font(.headline)
                        Text(String(localized: "diagnostics_empty_subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                sendSection

                Section {
                    ForEach(reports) { report in
                        ShareLink(item: report.url) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(report.displayDate)
                                        .font(.subheadline)
                                    Text(report.displaySize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text(String(localized: "diagnostics_footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
        }
        .navigationTitle(String(localized: "diagnostics_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !reports.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(String(localized: "diagnostics_clear"))
                }
            }
        }
        .task { reload() }
        // Use a centered alert instead of an iPad popover. A confirmation
        // dialog attached to the List used the bottom destructive section as
        // its source rect; with only one report at the top, the arrow could
        // point at an empty, recycled List row far below the report.
        .alert(
            String(localized: "diagnostics_clear_confirm"),
            isPresented: $showClearConfirm,
        ) {
            Button(String(localized: "diagnostics_clear"), role: .destructive) {
                clearAll()
            }
            .settingsAnchor("diagnostics.clearReports")
            Button(String(localized: "cancel"), role: .cancel) {}
        }
    }

    /// 一键把本机报告作为附件填进系统邮件草稿,发给开发者。
    @ViewBuilder private var sendSection: some View {
        #if os(iOS)
        Section {
            Button {
                if DiagnosticReportMailer.canSendMail {
                    showComposer = true
                } else {
                    showMailUnavailable = true
                }
            } label: {
                HStack {
                    Label(
                        String(localized: "diagnostics_send_button"),
                        systemImage: "paperplane"
                    )
                    Spacer()
                    Text(totalSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsAnchor("diagnostics.sendReports")
        } footer: {
            Text(String(localized: "diagnostics_send_privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        #endif
    }

    #if os(iOS)
    private var totalSizeText: String {
        let total = reports.reduce(0) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    private var mailSubject: String {
        DiagnosticReportMail.subject(environment: DiagnosticReportMailer.environment())
    }

    private var mailBody: String {
        DiagnosticReportMail.body(
            intro: String(
                format: String(localized: "diagnostics_send_mail_intro %lld"),
                reports.count
            ),
            privacyNote: String(localized: "diagnostics_send_privacy"),
            environment: DiagnosticReportMailer.environment(),
            reportCount: reports.count,
            formattedSize: totalSizeText
        )
    }
    #endif

    private func clearAll() {
        service.clearAll()
        reload()
    }

    private func reload() {
        reports = service.reports()
    }
}

#if os(iOS)

/// 邮件草稿 sheet 与三种结果提示。只有系统确认「已发送」才会提议清空本机
/// 报告 —— 取消或存草稿都不动数据。
private struct DiagnosticMailSupport: ViewModifier {
    @Binding var showComposer: Bool
    @Binding var showSentPrompt: Bool
    @Binding var showMailUnavailable: Bool
    @Binding var failureMessage: String?
    @State private var pendingOutcome: DiagnosticReportMailer.Outcome?
    let subject: String
    /// Not named `body`: `ViewModifier` already requires `body(content:)`.
    let messageBody: String
    let attachments: [URL]
    let onClearRequested: () -> Void

    func body(content: Content) -> some View {
        content
            // The result alert has to wait for the sheet to finish dismissing;
            // presenting it from the compose callback loses it.
            .sheet(isPresented: $showComposer, onDismiss: presentOutcome) {
                DiagnosticMailComposer(
                    subject: subject,
                    messageBody: messageBody,
                    attachments: attachments
                ) { outcome in
                    pendingOutcome = outcome
                    showComposer = false
                }
                .ignoresSafeArea()
            }
            .alert(
                String(localized: "diagnostics_send_sent_title"),
                isPresented: $showSentPrompt
            ) {
                Button(String(localized: "diagnostics_clear"), role: .destructive) {
                    onClearRequested()
                }
                Button(String(localized: "diagnostics_send_keep"), role: .cancel) {}
            } message: {
                Text(String(localized: "diagnostics_send_sent_message"))
            }
            .alert(
                String(localized: "diagnostics_send_unavailable_title"),
                isPresented: $showMailUnavailable
            ) {
                Button(String(localized: "ok"), role: .cancel) {}
            } message: {
                Text(
                    String(
                        format: String(localized: "diagnostics_send_unavailable_message %@"),
                        DiagnosticReportMail.recipient
                    )
                )
            }
            .alert(
                String(localized: "diagnostics_send_failed_title"),
                isPresented: Binding(
                    get: { failureMessage != nil },
                    set: { if !$0 { failureMessage = nil } }
                )
            ) {
                Button(String(localized: "ok"), role: .cancel) { failureMessage = nil }
            } message: {
                Text(failureMessage ?? String(localized: "diagnostics_send_failed_message"))
            }
    }

    private func presentOutcome() {
        switch pendingOutcome {
        case .sent:
            showSentPrompt = true
        case .failed(let message):
            failureMessage = message.isEmpty
                ? String(localized: "diagnostics_send_failed_message")
                : message
        case .cancelled, nil:
            break
        }
        pendingOutcome = nil
    }
}

#endif
