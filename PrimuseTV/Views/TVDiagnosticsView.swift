#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Apple TV 的「诊断报告」:打开详细日志、写一句留言、把日志直接上传给作者。
///
/// 电视上没有系统的崩溃与卡死报告(MetricKit 不支持 tvOS),也没有邮件,所以只传日志和
/// 留言,走与 iPhone、Mac 同一套中转上传(`DiagnosticReportUploader`),拿到编号显示在屏幕上。
struct TVDiagnosticsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss

    @State private var uploader: DiagnosticReportUploader?
    @State private var includesLog = true
    @State private var message = ""
    @State private var uploadTask: Task<Void, Never>?
    @State private var uploadedCode: String?
    @State private var uploadError: String?
    /// 诊断模式开到什么时候;nil 表示没开。
    @State private var diagnosticModeExpiry: Date?
    @State private var logSize: Int?
    @FocusState private var messageFocused: Bool

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    HStack(alignment: .top, spacing: 40) {
                        VStack(alignment: .leading, spacing: 0) {
                            diagnosticModeSection
                            if let uploadedCode {
                                uploadedSection(code: uploadedCode)
                            } else {
                                uploadSection
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        sideNotes
                            .frame(width: 440, alignment: .leading)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
            }
        }
        .foregroundStyle(TVColor.text)
        .task {
            refreshState()
            let uploader = uploader ?? DiagnosticReportUploader(client: intelligence.primuseRelayClient)
            self.uploader = uploader
            await uploader.refreshAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDiagnosticLoggingDidChange)) { _ in
            refreshState()
        }
        .onExitCommand {
            uploadTask?.cancel()
            dismiss()
        }
        .onDisappear { uploadTask?.cancel() }
        .accessibilityIdentifier("tv.diagnostics")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            Text("diagnostics_title").tvFont(.pageTitle)
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "done"), systemImage: "xmark") {
                uploadTask?.cancel()
                dismiss()
            }
        }
        .padding(.bottom, 28)
    }

    // MARK: - 诊断模式

    private var diagnosticModeSection: some View {
        TVAISection(title: String(localized: "diagnostics_mode_title")) {
            TVAIToggleRow(
                icon: "stethoscope",
                title: String(localized: "diagnostics_mode_toggle"),
                isOn: Binding(
                    get: { diagnosticModeExpiry != nil },
                    set: { enabled in
                        FileLogger.shared.setDiagnosticMode(enabled: enabled)
                        refreshState()
                    }
                )
            )
            TVAIDivider()
            TVAINoteRow(
                icon: diagnosticModeExpiry == nil ? "info.circle" : "clock",
                tint: diagnosticModeExpiry == nil ? TVColor.textMuted : TVColor.brand,
                text: diagnosticModeExpiry.map {
                    String(
                        format: String(localized: "diagnostics_mode_until_format"),
                        $0.formatted(date: .abbreviated, time: .shortened)
                    )
                } ?? String(localized: "diagnostics_mode_footer")
            )
        }
    }

    // MARK: - 上传

    private var uploadSection: some View {
        TVAISection(title: String(localized: "diagnostics_upload_button")) {
            TVAIToggleRow(
                icon: "doc.text",
                title: logToggleTitle,
                isOn: $includesLog
            )
            .disabled(isUploading)
            TVAIDivider()
            TVTextFieldBox {
                TextField(String(localized: "diagnostics_upload_message_placeholder"), text: $message)
                    .focused($messageFocused)
                    .submitLabel(.done)
                    .disabled(isUploading)
                    .accessibilityLabel(Text("diagnostics_upload_message_placeholder"))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            TVAIDivider()
            uploadActionRow
            if let uploadError {
                TVAIDivider()
                TVAINoteRow(icon: "exclamationmark.triangle.fill", tint: TVColor.bad, text: uploadError)
            }
        }
    }

    @ViewBuilder
    private var uploadActionRow: some View {
        if let phase = uploader?.phase {
            TVAINoteRow(icon: "arrow.up.circle", tint: TVColor.brand, text: DiagnosticReportUploader.describe(phase))
        } else if uploader?.availability == nil {
            TVAINoteRow(
                icon: "hourglass",
                tint: TVColor.textMuted,
                text: String(localized: "tv_diagnostics_upload_checking")
            )
        } else if uploader?.availability == false {
            TVAINoteRow(
                icon: "icloud.slash",
                tint: TVColor.textMuted,
                text: String(localized: "diagnostics_upload_error_unavailable")
            )
        } else {
            TVAIActionRow(
                icon: "paperplane.fill",
                title: String(localized: "diagnostics_upload_button"),
                subtitle: String(localized: "diagnostics_upload_consent"),
                trailing: "arrow.up",
                tint: TVColor.brand,
                isEnabled: includesLog || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: startUpload
            )
        }
    }

    private func uploadedSection(code: String) -> some View {
        TVAISection(title: String(localized: "diagnostics_upload_done_title")) {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: code)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVColor.text)
                    .accessibilityIdentifier("tv.diagnostics.code")
                Text("diagnostics_upload_done_hint")
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            TVAIDivider()
            TVAIActionRow(
                icon: "arrow.counterclockwise",
                title: String(localized: "tv_diagnostics_upload_another"),
                action: {
                    uploadedCode = nil
                    message = ""
                }
            )
        }
    }

    // MARK: - 说明

    private var sideNotes: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("tv_diagnostics_how_title").tvFont(.cardTitle)
            Text("tv_diagnostics_how_body")
                .tvFont(.caption)
                .foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(TVColor.divider)
            Text("diagnostics_log_contents_info")
                .tvFont(.caption)
                .foregroundStyle(TVColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .tvPanel(radius: 20)
    }

    // MARK: - 动作

    private var isUploading: Bool { uploader?.isRunning == true }

    private var logToggleTitle: String {
        guard let logSize, logSize > 0 else { return String(localized: "diagnostics_logs_title") }
        let size = ByteCountFormatter.string(fromByteCount: Int64(logSize), countStyle: .file)
        return "\(String(localized: "diagnostics_logs_title")) · \(size)"
    }

    private func refreshState() {
        diagnosticModeExpiry = FileLogger.shared.diagnosticLoggingExpiresAt.flatMap { $0 > Date() ? $0 : nil }
        logSize = try? FileLogger.shared.logFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private func startUpload() {
        guard let uploader, !uploader.isRunning else { return }
        messageFocused = false
        uploadError = nil
        let selection = DiagnosticReportUploader.Selection(
            reportURLs: [],
            includesLog: includesLog,
            message: message,
            screenshots: []
        )
        uploadTask = Task {
            do {
                let code = try await uploader.upload(selection)
                plog("🩺 TV diagnostics uploaded code=\(code) log=\(includesLog)")
                uploadedCode = code
            } catch is CancellationError {
                // 页面关掉了,什么也不传出去。
            } catch let failure as DiagnosticUpload.Failure {
                if failure == .unavailable { uploader.markUnavailable() }
                uploadError = DiagnosticReportUploader.message(for: failure)
            } catch {
                uploadError = error.localizedDescription
            }
            uploadTask = nil
        }
    }
}
#endif
