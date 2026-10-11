import SwiftUI
import PrimuseKit
#if os(iOS)
import PhotosUI
#endif

/// Settings → 关于 → 诊断报告。显示由 MetricKit 上报的 crash / hang 报告
/// 列表,点击可以分享 (邮件 / AirDrop / 复制) 给开发者排查。报告全部本地
/// 存放,不会自动外发 —— 顶部的「发送给开发者」按钮也只是把系统邮件草稿
/// 填好,仍然要用户自己按发送。
struct DiagnosticReportsView: View {
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:「发送」带上标题优先留在竖栏里,「清空」并进系统溢出菜单。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @State private var reports: [DiagnosticReport] = []
    /// 系统每天投递的指标载荷。不进列表(它不是崩溃), 但发给开发者时一起带上 ——
    /// 没有崩溃报告的"闪退"只能从它的退出原因统计里认出来。
    @State private var metricReports: [DiagnosticReport] = []
    @State private var showClearConfirm = false
    @State private var showFeedback = false
    @State private var logSize: Int?
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var mailDraft: DiagnosticReportMailer.Draft?
    @State private var pendingMailDraft: DiagnosticReportMailer.Draft?
    #endif
    @State private var showSentPrompt = false
    @State private var failureMessage: String?
    private let service: CrashDiagnosticsService

    init(service: CrashDiagnosticsService) {
        self.service = service
    }

    var body: some View {
        #if os(iOS)
        reportsList.modifier(DiagnosticMailSupport(
            draft: $mailDraft,
            showSentPrompt: $showSentPrompt,
            failureMessage: $failureMessage,
            onClearRequested: clearAll
        ))
        .sheet(isPresented: $showFeedback, onDismiss: presentPreparedDraft) {
            DiagnosticFeedbackView(
                reportURLs: reports.map(\.url) + metricReports.map(\.url),
                canExportLogs: canExportLogs
            ) { draft in
                pendingMailDraft = draft
                showFeedback = false
            }
        }
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
            logSection
        }
        .navigationTitle(String(localized: "diagnostics_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if os(iOS)
            if verticalBarEdge != nil {
                verticalBarToolbar
            } else {
                standardToolbar
            }
            #else
            standardToolbar
            #endif
        }
        .task { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
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

    @ToolbarContentBuilder
    private var standardToolbar: some ToolbarContent {
        if !reports.isEmpty || !metricReports.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(String(localized: "diagnostics_clear"))
            }
        }
        #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showFeedback = true
            } label: {
                Label(String(localized: "diagnostics_send_button"), systemImage: "paperplane")
            }
            .settingsAnchor("diagnostics.sendReports")
        }
        #endif
    }

    #if os(iOS)
    /// 系统竖栏(iPhone Duo):「发送给开发者」带标题、空间不够时最后才收;
    /// 会删东西的「清空」不和它并排竖在栏里,并进系统溢出菜单。
    @ToolbarContentBuilder
    private var verticalBarToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showFeedback = true
            } label: {
                Label(String(localized: "diagnostics_send_button"), systemImage: "paperplane")
            }
            .settingsAnchor("diagnostics.sendReports")
        }
        .pmHighVisibilityPriority()
        if #available(iOS 27.0, *) {
            if !reports.isEmpty || !metricReports.isEmpty {
                ToolbarOverflowMenu {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label(String(localized: "diagnostics_clear"), systemImage: "trash")
                    }
                }
            }
        }
    }
    #endif

    @ViewBuilder private var logSection: some View {
        #if os(iOS)
        if canExportLogs {
            Section {
                ShareLink(item: FileLogger.shared.logFileURL) {
                    HStack {
                        Label("storage_export_log", systemImage: "square.and.arrow.up.on.square")
                        Spacer()
                        Text(logSize.map {
                            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                        } ?? "—")
                        .foregroundStyle(.secondary)
                    }
                }
                .settingsAnchor("storage.exportLog")
            } header: {
                SettingsInfoHeader("diagnostics_logs_title") {
                    Text("storage_export_log_footer")
                }
            }
        }
        #endif
    }

    private var canExportLogs: Bool {
        DiagnosticLogExportPolicy.exposesExportEntry(channel: Bundle.main.distributionChannel)
    }

    #if os(iOS)
    private func presentPreparedDraft() {
        mailDraft = pendingMailDraft
        pendingMailDraft = nil
        reload()
    }
    #endif

    private func clearAll() {
        service.clearAll()
        reload()
    }

    private func reload() {
        reports = service.reports()
        metricReports = service.metricReports()
        if canExportLogs {
            logSize = try? FileLogger.shared.logFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
    }
}

#if os(iOS)

private struct DiagnosticFeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var includesReports = true
    @State private var includesLogs = true
    @State private var message = ""
    @State private var isPreparing = false
    @State private var showMailUnavailable = false
    @State private var failureMessage: String?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [DiagnosticFeedbackImage] = []
    @State private var isLoadingImages = false
    @State private var imageNotice: String?
    let reportURLs: [URL]
    let canExportLogs: Bool
    let onPrepared: (DiagnosticReportMailer.Draft) -> Void

    private var selection: DiagnosticReportMail.Selection {
        DiagnosticReportMail.Selection(
            includesReports: includesReports && !reportURLs.isEmpty,
            includesLogs: includesLogs && canExportLogs
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("diagnostics_feedback_attachments") {
                    Toggle("diagnostics_title", isOn: $includesReports)
                        .disabled(reportURLs.isEmpty)
                    if canExportLogs {
                        Toggle("diagnostics_logs_title", isOn: $includesLogs)
                    }
                }
                imagesSection
                Section {
                    TextEditor(text: $message)
                        .frame(minHeight: 160)
                        .accessibilityLabel(String(localized: "diagnostics_feedback_message"))
                } header: {
                    Text("diagnostics_feedback_message")
                } footer: {
                    Text(verbatim: DiagnosticReportMail.recipient)
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                importPicked(items)
            }
            .disabled(isPreparing)
            .navigationTitle(String(localized: "diagnostics_send_button"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .disabled(isPreparing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: prepareMail) {
                        if isPreparing {
                            ProgressView()
                        } else {
                            Text("diagnostics_feedback_compose")
                        }
                    }
                    .accessibilityLabel(String(localized: "diagnostics_feedback_compose"))
                    .disabled(isPreparing || isLoadingImages
                              || (selection == .none && images.isEmpty
                                  && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .interactiveDismissDisabled(isPreparing)
            .alert(String(localized: "diagnostics_send_unavailable_title"), isPresented: $showMailUnavailable) {
                Button(String(localized: "ok"), role: .cancel) {}
            } message: {
                Text(String(format: String(localized: "diagnostics_send_unavailable_message %@"), DiagnosticReportMail.recipient))
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
    }

    private func prepareMail() {
        guard DiagnosticReportMailer.canSendMail else {
            showMailUnavailable = true
            return
        }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let draft = try await DiagnosticReportMailer.prepare(
                    selection: selection, reportURLs: reportURLs, message: message, images: images.map(\.jpeg)
                )
                onPrepared(draft)
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }

    /// Screenshots of what the message is about: a strip of the chosen
    /// pictures, each removable, and the picker while there is room for more.
    private var imagesSection: some View {
        Section {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images) { image in
                            ZStack(alignment: .topTrailing) {
                                Image(decorative: image.thumbnail, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 88, height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Button {
                                    images.removeAll { $0.id == image.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                        .font(.system(size: 20))
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                                .accessibilityLabel(String(localized: "diagnostics_feedback_remove_image"))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            if images.count < DiagnosticFeedbackImage.maximumCount {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: DiagnosticFeedbackImage.maximumCount - images.count,
                    matching: .images,
                    preferredItemEncoding: .compatible
                ) {
                    if isLoadingImages {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("diagnostics_feedback_images_loading")
                        }
                    } else {
                        Label("diagnostics_feedback_add_image", systemImage: "photo.badge.plus")
                    }
                }
                .disabled(isLoadingImages)
            }
        } header: {
            Text("diagnostics_feedback_images")
        } footer: {
            if let imageNotice {
                Text(imageNotice).foregroundStyle(.orange)
            } else {
                Text(String(format: String(localized: "diagnostics_feedback_images_footer %lld"),
                            DiagnosticFeedbackImage.maximumCount))
            }
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) {
        isLoadingImages = true
        imageNotice = nil
        Task {
            defer { isLoadingImages = false }
            var added: [DiagnosticFeedbackImage] = []
            for item in items.prefix(max(0, DiagnosticFeedbackImage.maximumCount - images.count)) {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = await DiagnosticFeedbackImage.make(from: data) else { continue }
                added.append(image)
            }
            images.append(contentsOf: added)
            if added.count < items.count {
                imageNotice = String(localized: "diagnostics_feedback_image_failed")
            }
        }
    }
}

/// One picture going into the mail: the scaled JPEG that is attached and a
/// small decoded copy for the strip. A 12MP photo is never decoded whole.
struct DiagnosticFeedbackImage: Identifiable, @unchecked Sendable {
    static let maximumCount = 6
    static let maximumPixel = 2048
    let id = UUID()
    let jpeg: Data
    let thumbnail: CGImage

    static func make(from data: Data) async -> DiagnosticFeedbackImage? {
        await Task.detached(priority: .userInitiated) {
            guard let jpeg = PlayerBackdropImaging.downscaledJPEG(from: data, maxPixel: maximumPixel, quality: 0.8),
                  let thumbnail = PlayerBackdropImaging.decodedImage(data: jpeg, maxPixel: 240) else { return nil }
            return DiagnosticFeedbackImage(jpeg: jpeg, thumbnail: thumbnail)
        }.value
    }
}

/// 邮件草稿 sheet 与三种结果提示。只有系统确认「已发送」才会提议清空本机
/// 报告 —— 取消或存草稿都不动数据。
private struct DiagnosticMailSupport: ViewModifier {
    @Binding var draft: DiagnosticReportMailer.Draft?
    @Binding var showSentPrompt: Bool
    @Binding var failureMessage: String?
    @State private var pendingOutcome: DiagnosticReportMailer.Outcome?
    @State private var sentReportCount = 0
    let onClearRequested: () -> Void

    func body(content: Content) -> some View {
        content
            // The result alert has to wait for the sheet to finish dismissing;
            // presenting it from the compose callback loses it.
            .sheet(item: $draft, onDismiss: presentOutcome) { item in
                DiagnosticMailComposer(
                    subject: item.subject,
                    messageBody: item.messageBody,
                    attachments: item.attachments
                ) { outcome in
                    pendingOutcome = outcome
                    sentReportCount = item.reportCount
                    draft = nil
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
            showSentPrompt = sentReportCount > 0
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
