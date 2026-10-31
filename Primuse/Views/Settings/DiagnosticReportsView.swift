import SwiftUI
import PrimuseKit
#if os(iOS)
import PhotosUI
#endif

/// Settings → 关于 → 诊断报告。分类显示系统诊断与运行指标报告
/// 列表,点击可以分享 (邮件 / AirDrop / 复制) 给开发者排查。报告全部本地
/// 存放,不会自动外发 —— 顶部的「发送给作者」按钮打开反馈页,由用户勾选内容后
/// 亲手点上传(中转开着上传时)、填好系统邮件草稿,或交给系统分享面板。
struct DiagnosticReportsView: View {
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:「发送」带上标题优先留在竖栏里,「清空」并进系统溢出菜单。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @State private var reports: [DiagnosticReport] = []
    @State private var metricReports: [DiagnosticReport] = []
    @State private var showClearConfirm = false
    @State private var showClearLogsConfirm = false
    @State private var reportToDelete: DiagnosticReport?
    @State private var cleanupError: String?
    @State private var isClearingLogs = false
    @State private var showFeedback = false
    @State private var logSize: Int?
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var mailDraft: DiagnosticReportMailer.Draft?
    @State private var pendingMailDraft: DiagnosticReportMailer.Draft?
    #endif
    @State private var showSentPrompt = false
    /// 反馈页里已经分享出去的报告份数;反馈页收起后据此提议清空本机报告。
    @State private var deliveredReportCount = 0
    @State private var failureMessage: String?
    /// 诊断模式开到什么时候;nil 表示没开。开关在这一页,到期由日志模块自己收。
    @State private var diagnosticModeExpiry: Date?
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
                diagnosticReportCount: reports.count,
                metricReportCount: metricReports.count,
                canExportLogs: canExportLogs,
                onPrepared: { draft in
                    pendingMailDraft = draft
                    showFeedback = false
                },
                onDelivered: { count in
                    deliveredReportCount = count
                }
            )
        }
        #else
        reportsList
        #endif
    }

    private var reportsList: some View {
        List {
            reportSection(reports, title: String(localized: "diagnostics_crash_reports"))
            reportSection(metricReports, title: String(localized: "diagnostics_metric_reports"))
            if !reports.isEmpty || !metricReports.isEmpty {
                Section {
                    Button("diagnostics_clear", role: .destructive) { showClearConfirm = true }
                }
            }
            diagnosticModeSection
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
        .onReceive(NotificationCenter.default.publisher(for: .primuseDiagnosticLoggingDidChange)) { _ in
            refreshDiagnosticMode()
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
        .alert("diagnostics_logs_clear_confirm", isPresented: $showClearLogsConfirm) {
            Button("diagnostics_logs_clear", role: .destructive, action: clearLogs)
            Button("cancel", role: .cancel) {}
        }
        .alert("diagnostics_delete_report_confirm", isPresented: Binding(
            get: { reportToDelete != nil },
            set: { if !$0 { reportToDelete = nil } }
        ), presenting: reportToDelete) { report in
            Button("delete", role: .destructive) {
                do { try service.delete(report) } catch { cleanupError = error.localizedDescription }
                reportToDelete = nil
                reload()
            }
            Button("cancel", role: .cancel) { reportToDelete = nil }
        }
        .alert("diagnostics_cleanup_failed", isPresented: Binding(
            get: { cleanupError != nil },
            set: { if !$0 { cleanupError = nil } }
        )) {
            Button("ok", role: .cancel) { cleanupError = nil }
        } message: {
            Text(cleanupError ?? "")
        }
    }

    private func reportSection(_ items: [DiagnosticReport], title: String) -> some View {
        Section {
            if items.isEmpty {
                Text("diagnostics_category_empty")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { report in
                ShareLink(item: report.url) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.displayDate).font(.subheadline)
                            Text(report.displaySize).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("delete", role: .destructive) { reportToDelete = report }
                }
                .swipeActions {
                    Button("delete", role: .destructive) { reportToDelete = report }
                }
            }
        } header: {
            Text(verbatim: "\(title) · \(items.count.formatted())")
        } footer: {
            if !items.isEmpty { Text("diagnostics_footer") }
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

    /// 诊断模式:所有渠道都能开。开着的这段时间多记排查用的日志(封面读不出来的原因这类),
    /// 到期自动关;发给作者时照旧要勾选「日志」才带上。
    private var diagnosticModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { diagnosticModeExpiry != nil },
                set: { enabled in
                    FileLogger.shared.setDiagnosticMode(enabled: enabled)
                    refreshDiagnosticMode()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("diagnostics_mode_toggle")
                    if let expiry = diagnosticModeExpiry {
                        Text(String(
                            format: String(localized: "diagnostics_mode_until_format"),
                            expiry.formatted(date: .abbreviated, time: .shortened)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .settingsAnchor("diagnostics.detailedLogging")
        } header: {
            Text("diagnostics_mode_title")
        } footer: {
            Text("diagnostics_mode_footer")
        }
    }

    private func refreshDiagnosticMode() {
        diagnosticModeExpiry = FileLogger.shared.diagnosticLoggingExpiresAt.flatMap { $0 > Date() ? $0 : nil }
    }

    private var logSection: some View {
        Section {
            HStack {
                Text("diagnostics_logs_title")
                Spacer()
                Text(logSize.map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
                } ?? "—")
                .foregroundStyle(.secondary)
            }
            if canExportLogs {
                ShareLink(item: FileLogger.shared.logFileURL) {
                    Label("storage_export_log", systemImage: "square.and.arrow.up.on.square")
                }
                .settingsAnchor("storage.exportLog")
            }
            Button("diagnostics_logs_clear", role: .destructive) { showClearLogsConfirm = true }
                .disabled(isClearingLogs)
                .settingsAnchor("diagnostics.clearLogs")
        } header: {
            SettingsInfoHeader("diagnostics_logs_title") {
                Text("storage_export_log_footer")
            }
        }
    }

    private func clearLogs() {
        isClearingLogs = true
        Task {
            defer { isClearingLogs = false }
            do { try await FileLogger.shared.clearLogs() } catch { cleanupError = error.localizedDescription }
            logSize = await FileLogger.shared.storedLogSize()
        }
    }

    private var canExportLogs: Bool {
        DiagnosticLogExportPolicy.exposesExportEntry(channel: Bundle.main.distributionChannel)
    }

    #if os(iOS)
    private func presentPreparedDraft() {
        mailDraft = pendingMailDraft
        pendingMailDraft = nil
        // 分享成功后同邮件「已发送」一样,提议清空本机报告。
        if deliveredReportCount > 0 {
            showSentPrompt = true
        }
        deliveredReportCount = 0
        reload()
    }
    #endif

    private func clearAll() {
        do { try service.clearAll() } catch { cleanupError = error.localizedDescription }
        reload()
    }

    private func reload() {
        refreshDiagnosticMode()
        reports = service.reports()
        metricReports = service.metricReports()
        Task { logSize = await FileLogger.shared.storedLogSize() }
    }
}

#if os(iOS)

/// 反馈页:勾选附件、加截图、写留言,然后发给作者。
///
/// 中转开着诊断上传时,主按钮是「上传给作者」(底部常驻,紧挨着隐私说明),邮件或系统分享
/// 退为次要选项;中转没开、是老版本、或这台设备注册不上时,照旧只有右上角的「打开邮件」。
/// 没配邮件账户时,邮件换成把同一个压缩包交给系统分享面板。
private struct DiagnosticFeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var includesReports = true
    @State private var includesLogs: Bool
    @State private var message = ""
    @State private var isPreparing = false
    @State private var failureMessage: String?
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [DiagnosticFeedbackImage] = []
    @State private var isLoadingImages = false
    @State private var imageNotice: String?
    @State private var uploader = DiagnosticReportUploader()
    @State private var uploadTask: Task<Void, Never>?
    @State private var uploadedCode: String?
    @State private var codeCopied = false
    @State private var shareItem: DiagnosticShareItem?
    /// 正在分享的那个包:分享面板收起后删掉它的临时目录。
    @State private var sharedItem: DiagnosticShareItem?
    @State private var shareCompleted = false
    let reportURLs: [URL]
    let diagnosticReportCount: Int
    let metricReportCount: Int
    let canExportLogs: Bool
    let onPrepared: (DiagnosticReportMailer.Draft) -> Void
    /// 上传或分享成功,参数是带出去的报告份数。
    let onDelivered: (Int) -> Void
    private let canSendMail: Bool

    init(
        reportURLs: [URL],
        diagnosticReportCount: Int,
        metricReportCount: Int,
        canExportLogs: Bool,
        onPrepared: @escaping (DiagnosticReportMailer.Draft) -> Void,
        onDelivered: @escaping (Int) -> Void
    ) {
        self.reportURLs = reportURLs
        self.diagnosticReportCount = diagnosticReportCount
        self.metricReportCount = metricReportCount
        self.canExportLogs = canExportLogs
        self.onPrepared = onPrepared
        self.onDelivered = onDelivered
        canSendMail = DiagnosticReportMailer.canSendMail
        _includesReports = State(initialValue: !reportURLs.isEmpty)
        // 测试渠道照旧默认带日志;正式版的日志要用户自己勾,开着诊断模式时默认勾上
        // (打开它就是为了把问题记下来发给作者)。
        _includesLogs = State(initialValue: canExportLogs || FileLogger.isDiagnosticModeActive)
    }

    private var uploadAvailable: Bool { uploader.availability == true }

    /// 正式版只在上传或分享时提供日志:那两条路都只带日志末尾一段,并且先看得到说明。
    private var logOffered: Bool {
        canExportLogs || uploadAvailable || !canSendMail
    }

    private var selection: DiagnosticReportMail.Selection {
        DiagnosticReportMail.Selection(
            includesReports: includesReports && !reportURLs.isEmpty,
            includesLogs: includesLogs && logOffered
        )
    }

    private var uploadSelection: DiagnosticReportUploader.Selection {
        DiagnosticReportUploader.Selection(
            reportURLs: selection.includesReports ? reportURLs : [],
            includesLog: selection.includesLogs,
            message: message,
            screenshots: images.map(\.jpeg)
        )
    }

    private var hasContent: Bool {
        selection != .none || !images.isEmpty
            || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isBusy: Bool { isPreparing || uploader.isRunning }

    private var canSend: Bool { hasContent && !isBusy && !isLoadingImages }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "diagnostics_send_button"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .interactiveDismissDisabled(isBusy)
                .alert(
                    uploadedCode != nil ? String(localized: "diagnostics_cleanup_failed")
                        : String(localized: "diagnostics_send_failed_title"),
                    isPresented: Binding(
                        get: { failureMessage != nil },
                        set: { if !$0 { failureMessage = nil } }
                    )
                ) {
                    Button(String(localized: "ok"), role: .cancel) { failureMessage = nil }
                } message: {
                    Text(failureMessage ?? String(localized: "diagnostics_send_failed_message"))
                }
                .sheet(item: $shareItem, onDismiss: finishSharing) { item in
                    DiagnosticArchiveShareSheet(fileURL: item.archive.zipURL) { completed in
                        shareCompleted = completed
                        shareItem = nil
                    }
                    .ignoresSafeArea()
                }
        }
        .task { await uploader.refreshAvailability() }
    }

    @ViewBuilder private var content: some View {
        if let uploadedCode {
            uploadedView(code: uploadedCode)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section("diagnostics_feedback_attachments") {
                Toggle(isOn: $includesReports) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("diagnostics_title")
                        Text(verbatim: "\(String(localized: "diagnostics_crash_reports")) · \(diagnosticReportCount.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: "\(String(localized: "diagnostics_metric_reports")) · \(metricReportCount.formatted())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(reportURLs.isEmpty)
                if logOffered {
                    Toggle(isOn: $includesLogs) {
                        SettingsInfoLabel("diagnostics_logs_title") {
                            Text("diagnostics_log_contents_info")
                        }
                    }
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
                if !uploadAvailable {
                    Text(verbatim: DiagnosticReportMail.recipient)
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            importPicked(items)
        }
        .disabled(isBusy)
        .safeAreaInset(edge: .bottom) {
            if uploadAvailable {
                uploadPanel
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if uploadedCode != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("done") { dismiss() }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                // 上传途中「取消」只停下上传,留在本页,写好的留言不丢。
                Button("cancel") {
                    if uploader.isRunning {
                        uploadTask?.cancel()
                    } else {
                        dismiss()
                    }
                }
                .disabled(isPreparing)
            }
            if !uploadAvailable {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: sendWithoutUpload) {
                        if isPreparing || uploader.availability == nil {
                            ProgressView()
                        } else if canSendMail {
                            Text("diagnostics_feedback_compose")
                        } else {
                            Text("diagnostics_feedback_share")
                        }
                    }
                    .accessibilityLabel(canSendMail
                        ? String(localized: "diagnostics_feedback_compose")
                        : String(localized: "diagnostics_feedback_share"))
                    .disabled(!canSend || uploader.availability == nil)
                }
            }
        }
    }

    /// 底部常驻:主按钮上传,次要的邮件 / 分享,和上传前必须看得到的去向说明。
    private var uploadPanel: some View {
        VStack(spacing: 10) {
            Button(action: startUpload) {
                HStack(spacing: 8) {
                    if let phase = uploader.phase {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: DiagnosticReportUploader.describe(phase))
                            .monospacedDigit()
                    } else {
                        Label("diagnostics_upload_button", systemImage: "arrow.up.circle")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSend)
            if let uploadFraction {
                ProgressView(value: uploadFraction)
            }
            Button(action: sendWithoutUpload) {
                if isPreparing {
                    ProgressView()
                        .controlSize(.small)
                } else if canSendMail {
                    Text("diagnostics_upload_use_mail")
                } else {
                    Text("diagnostics_upload_use_share")
                }
            }
            .font(.subheadline)
            .disabled(!canSend)
            Text("diagnostics_upload_consent")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var uploadFraction: Double? {
        if case .uploading(let fraction) = uploader.phase { return fraction }
        return nil
    }

    /// 传完:编号要醒目、能复制,并说清楚拿它去哪儿用。
    private func uploadedView(code: String) -> some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("diagnostics_upload_done_title")
                        .font(.headline)
                    Text(verbatim: code)
                        .font(.system(.largeTitle, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = code
                        codeCopied = true
                    } label: {
                        Label(
                            codeCopied
                                ? String(localized: "diagnostics_upload_code_copied")
                                : String(localized: "diagnostics_upload_copy_code"),
                            systemImage: codeCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } footer: {
                Text("diagnostics_upload_done_hint")
            }
        }
    }

    private func startUpload() {
        let selection = uploadSelection
        uploadTask = Task {
            defer { uploadTask = nil }
            do {
                let code = try await uploader.upload(selection)
                codeCopied = false
                uploadedCode = code
                failureMessage = uploader.cleanupError
            } catch is CancellationError {
                // 用户自己停的,不提示。
            } catch let failure as DiagnosticUpload.Failure {
                if failure == .unavailable {
                    // 中转不收或这台设备注册不上:页面回到邮件 / 分享。
                    uploader.markUnavailable()
                }
                failureMessage = DiagnosticReportUploader.message(for: failure)
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }

    private func sendWithoutUpload() {
        if canSendMail {
            prepareMail()
        } else {
            prepareShare()
        }
    }

    private func prepareMail() {
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

    /// 没配邮件账户:同样的内容打成一个压缩包,交给系统分享面板。
    private func prepareShare() {
        let selection = uploadSelection
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let archive = try await DiagnosticReportUploader.shareableArchive(selection)
                let item = DiagnosticShareItem(archive: archive, reportCount: selection.reportURLs.count)
                shareCompleted = false
                sharedItem = item
                shareItem = item
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }

    private func finishSharing() {
        guard let item = sharedItem else { return }
        sharedItem = nil
        item.archive.remove()
        if shareCompleted {
            shareCompleted = false
            onDelivered(item.reportCount)
            dismiss()
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

/// 交给系统分享面板的一个压缩包。
private struct DiagnosticShareItem: Identifiable {
    let id = UUID()
    let archive: DiagnosticReportPackager.Archive
    let reportCount: Int
}

/// One picture going into the feedback: the scaled JPEG that is attached and a
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
