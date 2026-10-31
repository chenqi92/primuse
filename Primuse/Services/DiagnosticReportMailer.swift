import Foundation
import Observation
import PrimuseKit
import SwiftUI
#if os(iOS)
import MessageUI
#endif
#if os(iOS) || os(tvOS)
import UIKit
#endif

#if os(iOS)
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
    /// feedback sheet hands the same package to the system share sheet instead.
    static var canSendMail: Bool {
        MFMailComposeViewController.canSendMail()
    }

    /// `images` are JPEG pictures the sender chose, already scaled down.
    static func prepare(
        selection: DiagnosticReportMail.Selection,
        reportURLs: [URL],
        message: String = "",
        images: [Data] = []
    ) async throws -> Draft {
        let screenshots = images.enumerated().map { index, data in
            Attachment(data: data, mimeType: "image/jpeg",
                       fileName: DiagnosticReportMail.screenshotName(index: index, of: images.count))
        }
        if selection == .none {
            return Draft(
                subject: DiagnosticReportMail.subject(environment: environment(), isFeedback: true),
                messageBody: DiagnosticReportMail.feedbackBody(message: message, screenshotCount: screenshots.count),
                attachments: screenshots,
                reportCount: 0
            )
        }
        let files = DiagnosticReportMail.attachments(
            selection: selection,
            reportURLs: reportURLs,
            logURL: FileLogger.shared.logFileURL
        )
        // 测试渠道照旧附整份当前日志;正式版只有用户在反馈页里主动勾了日志才会走到这里,
        // 只带末尾一段(与上传同一个长度)。
        let logData: Data?
        if selection.includesLogs {
            await AppServices.shared.spotlightIndex.prepareDiagnosticsForExport(library: AppServices.shared.musicLibrary)
            let channel = Bundle.main.distributionChannel
            if DiagnosticLogExportPolicy.exposesExportEntry(channel: channel) {
                logData = try await FileLogger.shared.exportData()
            } else {
                logData = await FileLogger.shared.tailData(maxBytes: DiagnosticUpload.logTailBytes(
                    channel: channel,
                    diagnosticMode: FileLogger.isDiagnosticModeActive
                ))
            }
        } else {
            logData = nil
        }
        let attachments = try await Task.detached(priority: .userInitiated) {
            try files.map { file in
                let data = file.mimeType == "text/plain"
                    ? logData! : try Data(contentsOf: file.url)
                return Attachment(data: data, mimeType: file.mimeType, fileName: file.fileName)
            }
        }.value
        let reportCount = selection.includesReports ? reportURLs.count : 0
        let size = attachments.reduce(0) { $0 + $1.data.count }
        return Draft(
            subject: DiagnosticReportMail.subject(environment: environment()),
            messageBody: DiagnosticReportMail.body(
                intro: DiagnosticReportUploader.intro(for: selection),
                privacyNote: String(localized: "diagnostics_send_privacy"),
                environment: environment(),
                reportCount: reportCount,
                formattedSize: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                includesLogs: selection.includesLogs,
                message: message,
                screenshotCount: screenshots.count
            ),
            attachments: attachments + screenshots,
            reportCount: reportCount
        )
    }

    static func environment() -> DiagnosticReportMail.Environment {
        DiagnosticReportEnvironment.current()
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

/// 没配邮件账户时,把打好的压缩包交给系统分享面板(AirDrop、存到「文件」、聊天 App)。
/// `onFinish` 的参数是用户有没有真的分享出去;取消不算。
struct DiagnosticArchiveShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let onFinish: @MainActor @Sendable (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        let onFinish = onFinish
        controller.completionWithItemsHandler = { _, completed, _, _ in
            Task { @MainActor in onFinish(completed) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - 打包与上传(iPhone、iPad、Mac、Apple TV 共用)

/// 版本、型号、系统:邮件主题、上传请求、包里的 feedback.txt 用同一份。
@MainActor
enum DiagnosticReportEnvironment {
    /// iPad 的系统名是 iPadOS,也报 iOS;后台按这个名字分平台显示。
    static var platformName: String {
        #if os(macOS)
        "macOS"
        #elseif os(tvOS)
        "tvOS"
        #else
        "iOS"
        #endif
    }

    static func current() -> DiagnosticReportMail.Environment {
        let info = Bundle.main.infoDictionary
        #if os(macOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        let systemName = "macOS"
        #else
        let systemVersion = UIDevice.current.systemVersion
        let systemName = UIDevice.current.systemName
        #endif
        return DiagnosticReportMail.Environment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "",
            buildNumber: info?["CFBundleVersion"] as? String ?? "",
            deviceModel: hardwareModel(),
            systemName: systemName,
            systemVersion: systemVersion
        )
    }

    /// 硬件标识("iPhone16,2"、"Mac14,2"、"AppleTV14,1"):崩溃报告要的就是它,MetricKit 的载荷里
    /// 也是这个写法。Mac 上 uname 的 machine 只是 arm64,型号要从 hw.model 取。
    private static func hardwareModel() -> String {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        let identifier = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return identifier.isEmpty ? "Mac" : identifier
        #else
        var info = utsname()
        uname(&info)
        // 取字节副本读,别在 &info.machine 借出期间再去读 info.machine。
        let identifier = withUnsafeBytes(of: info.machine) { raw -> String in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
        #endif
    }
}

/// 把用户选的内容打成一个 zip:`feedback.txt`(留言与技术摘要,和邮件正文是同一段)、
/// 选中的诊断报告、日志末尾一段、截图。全部在后台执行;临时目录由调用方用完即删。
nonisolated enum DiagnosticReportPackager {
    /// 打好的包。`directory` 是这次的整个临时工作目录,`remove()` 一并删掉。
    struct Archive: Sendable {
        let directory: URL
        let zipURL: URL
        let byteCount: Int
        let contents: [DiagnosticUpload.Content]
        let reportCount: Int
        let reportURLs: [URL]

        nonisolated func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 打包要的材料,在主线程上收齐后交给后台。`log` 已经是按渠道截好的末尾一段。
    struct Input: Sendable {
        var environment: DiagnosticReportMail.Environment
        var intro: String
        var reportURLs: [URL]
        var log: Data?
        var message: String
        var screenshots: [Data]
    }

    private nonisolated static let workDirectoryPrefix = "primuse-diagnostics-work-"

    /// 分享用:原样打一次,不设上限。
    nonisolated static func build(_ input: Input) throws -> Archive {
        let workDirectory = try makeWorkDirectory()
        do {
            return try build(
                input,
                attempt: DiagnosticUpload.Attempt(logTailBytes: nil, screenshotScale: nil),
                zipName: DiagnosticUpload.archiveName(date: Date()),
                in: workDirectory
            )
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        }
    }

    /// 上传用:按 `DiagnosticUpload.attempts` 的顺序逐级缩小,直到不超过上限;
    /// 缩到最后一档还超就报 `.tooLarge`。和上一次打出来一样的组合直接跳过。
    nonisolated static func buildWithinLimit(_ input: Input) throws -> Archive {
        let workDirectory = try makeWorkDirectory()
        do {
            let zipName = DiagnosticUpload.archiveName(date: Date())
            let attempts = DiagnosticUpload.attempts(
                logTailBytes: input.log?.count,
                hasScreenshots: !input.screenshots.isEmpty
            )
            var previous: (logBytes: Int?, scale: DiagnosticUpload.ImageScale?)?
            for attempt in attempts {
                try Task.checkCancellation()
                let logBytes = input.log.map { log in min(log.count, attempt.logTailBytes ?? log.count) }
                if let previous, previous.logBytes == logBytes, previous.scale == attempt.screenshotScale {
                    continue
                }
                previous = (logBytes, attempt.screenshotScale)
                let archive = try build(input, attempt: attempt, zipName: zipName, in: workDirectory)
                if archive.byteCount <= DiagnosticUpload.maximumBytes { return archive }
            }
            throw DiagnosticUpload.Failure.tooLarge
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        }
    }

    /// 上次没删掉(进程中途被杀)的工作目录,一小时以上的清掉。
    nonisolated static func removeStaleWorkDirectories() {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3_600)
        for url in entries where url.lastPathComponent.hasPrefix(workDirectoryPrefix) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    private nonisolated static func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(workDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private nonisolated static func build(
        _ input: Input,
        attempt: DiagnosticUpload.Attempt,
        zipName: String,
        in workDirectory: URL
    ) throws -> Archive {
        let fm = FileManager.default
        let staging = workDirectory.appendingPathComponent(DiagnosticUpload.directoryName, isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var reportCount = 0
        var reportURLs: [URL] = []
        var reportBytes = 0
        for (index, url) in input.reportURLs.enumerated() {
            let destination = staging.appendingPathComponent(
                DiagnosticReportMail.attachmentName(index: index, of: input.reportURLs.count)
            )
            // 报告可能刚被清掉;少一份不影响其余内容。
            guard (try? fm.copyItem(at: url, to: destination)) != nil else { continue }
            reportCount += 1
            reportURLs.append(url)
            reportBytes += (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }

        var includesLog = false
        if let log = input.log, !log.isEmpty {
            let tail = attempt.logTailBytes.map { DiagnosticUpload.logSuffix(log, maxBytes: $0) } ?? log
            try tail.write(to: staging.appendingPathComponent(DiagnosticUpload.logFileName))
            includesLog = true
        }

        for (index, jpeg) in input.screenshots.enumerated() {
            var data = jpeg
            if let scale = attempt.screenshotScale,
               let smaller = PlayerBackdropImaging.downscaledJPEG(
                   from: jpeg, maxPixel: scale.maxPixel, quality: scale.quality
               ) {
                data = smaller
            }
            try data.write(to: staging.appendingPathComponent(
                DiagnosticReportMail.screenshotName(index: index, of: input.screenshots.count)
            ))
        }

        let message = DiagnosticUpload.clampedMessage(input.message) ?? ""
        let feedback = DiagnosticReportMail.body(
            intro: input.intro,
            privacyNote: "",
            environment: input.environment,
            reportCount: reportCount,
            formattedSize: reportCount > 0
                ? ByteCountFormatter.string(fromByteCount: Int64(reportBytes), countStyle: .file)
                : "",
            includesLogs: includesLog,
            message: message,
            screenshotCount: input.screenshots.count
        )
        try Data(feedback.utf8).write(
            to: staging.appendingPathComponent(DiagnosticUpload.feedbackFileName)
        )

        let zipURL = workDirectory.appendingPathComponent(zipName)
        try? fm.removeItem(at: zipURL)
        try zip(staging, to: zipURL)
        let byteCount = (try zipURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        return Archive(
            directory: workDirectory,
            zipURL: zipURL,
            byteCount: byteCount,
            contents: DiagnosticUpload.contents(
                includesReports: reportCount > 0,
                includesLog: includesLog,
                screenshotCount: input.screenshots.count,
                message: message
            ),
            reportCount: reportCount,
            reportURLs: reportURLs
        )
    }

    /// 系统自带的打包:对目录做 `.forUploading` 的协调读取,系统给出一个临时 zip,
    /// 只在回调里有效,所以当场拷出来。
    private nonisolated static func zip(_ directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: .forUploading,
            error: &coordinationError
        ) { zipped in
            do {
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}

/// 诊断报告直接上传给作者:问服务收不收、打包、要上传位、PUT、确认。
///
/// 构建里带了 Palveni 的上传密钥时传到 Palveni(`PalveniDiagnosticsClient`,用上传密钥和匿名
/// 安装 ID,不需要设备注册);没带时走 primuse-ai 中转,和内置 AI 共用同一个中转客户端(同一份
/// 设备注册)。两条路都不看内置 AI 的开关和同意 —— 上传是用户在诊断页亲手点的按钮,传什么由他
/// 在页面上勾选。Apple TV 没有 `AppServices`,由诊断页把它自己的中转客户端交进来。
@MainActor
@Observable
final class DiagnosticReportUploader {
    enum Phase: Equatable {
        case packaging
        case uploading(Double)
        case confirming
    }

    /// 用户在反馈页里选的内容。
    struct Selection: Sendable {
        var reportURLs: [URL]
        var includesLog: Bool
        var message: String
        var screenshots: [Data]
    }

    /// 正在进行的步骤;nil 表示空闲。
    private(set) var phase: Phase?
    /// 中转收不收上传;nil 表示还在问。
    private(set) var availability: Bool?
    private(set) var cleanupError: String?

    /// 十分钟内问过就沿用,反馈页再打开时按钮不再跳一下。
    private static var cachedAvailability: (value: Bool, checkedAt: Date)?
    private static let availabilityLifetime: TimeInterval = 10 * 60

    @ObservationIgnored private let clientProvider: @MainActor () -> PrimuseAIRelayClient
    /// 构建里带了 Palveni 的上传密钥才有;有就不再经过中转。
    @ObservationIgnored private let palveni = PalveniDiagnosticsClient.configured()

    #if os(tvOS)
    convenience init(client: PrimuseAIRelayClient) {
        self.init(clientProvider: { client })
    }
    #else
    convenience init() {
        self.init(clientProvider: { AppServices.shared.musicIntelligence.primuseRelayClient })
    }
    #endif

    private init(clientProvider: @escaping @MainActor () -> PrimuseAIRelayClient) {
        self.clientProvider = clientProvider
        if palveni == nil && !PrimuseAIRelayClient.isSupportedOnCurrentDevice {
            availability = false
        } else if let cached = Self.cachedAvailability,
                  Date().timeIntervalSince(cached.checkedAt) < Self.availabilityLifetime {
            availability = cached.value
        }
    }

    var isRunning: Bool { phase != nil }

    private var client: PrimuseAIRelayClient {
        clientProvider()
    }

    /// 问一次收不收:Palveni 用上传密钥问,中转走公开接口(不带设备标识)。走中转而这台设备
    /// 连注册都做不到时直接算不收。
    func refreshAvailability() async {
        guard palveni != nil || PrimuseAIRelayClient.isSupportedOnCurrentDevice else {
            availability = false
            return
        }
        if let cached = Self.cachedAvailability,
           Date().timeIntervalSince(cached.checkedAt) < Self.availabilityLifetime {
            availability = cached.value
            return
        }
        let value: Bool?
        if let palveni {
            value = await palveni.availability()
        } else {
            value = await client.diagnosticsUploadAvailability()
        }
        if let value {
            Self.cachedAvailability = (value, Date())
        }
        availability = value ?? false
    }

    /// 上传时中转说不收、或这台设备注册不上:这一阵子不再露上传按钮,改走邮件。
    func markUnavailable() {
        Self.cachedAvailability = (false, Date())
        availability = false
    }

    /// 打包、上传、确认,成功返回给人看的编号。失败抛 `DiagnosticUpload.Failure`;
    /// 取消抛 `CancellationError`。临时文件在任何结局下都删掉。
    func upload(_ selection: Selection) async throws -> String {
        phase = .packaging
        cleanupError = nil
        defer { phase = nil }
        let (input, logSnapshot) = await Self.packagerInput(selection, preparingUpload: true)
        DiagnosticReportPackager.removeStaleWorkDirectories()
        let archive = try await Task.detached(priority: .userInitiated) {
            try DiagnosticReportPackager.buildWithinLimit(input)
        }.value
        defer { archive.remove() }
        try Task.checkCancellation()

        let environment = input.environment
        let request = DiagnosticUpload.Request(
            byteCount: archive.byteCount,
            appVersion: environment.appVersion,
            build: environment.buildNumber,
            platform: DiagnosticReportEnvironment.platformName,
            osVersion: environment.systemVersion,
            deviceModel: environment.deviceModel,
            contents: archive.contents,
            message: selection.message
        )
        // 申请就占当天的名额,之后的失败都拿这一个上传位补救,不再重新申请。
        let slot: DiagnosticUpload.Slot
        if let palveni {
            slot = try await palveni.requestUpload(request, channel: Bundle.main.distributionChannel)
        } else {
            slot = try await client.requestDiagnosticsUpload(request)
        }
        try await transfer(archive.zipURL, slot: slot)
        let result = try await Self.finishUpload(archive, logSnapshot: logSnapshot) {
            try await self.complete(slot, archiveURL: archive.zipURL)
        }
        cleanupError = result.cleanupError
        return result.code
    }

    /// 确认失败或取消时保留原件；本地清理失败也不能把已确认的上传改报成失败。
    static func finishUpload(
        _ archive: DiagnosticReportPackager.Archive,
        logSnapshot: FileLogger.UploadSnapshot?,
        logger: FileLogger = .shared,
        confirm: () async throws -> String
    ) async throws -> (code: String, cleanupError: String?) {
        try Task.checkCancellation()
        let code = try await confirm()
        var cleanupError: String?
        for url in archive.reportURLs {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                cleanupError = error.localizedDescription
            }
        }
        if let logSnapshot, archive.contents.contains(.log) {
            do {
                try await logger.clearUploadedLogs(logSnapshot)
            } catch {
                cleanupError = error.localizedDescription
            }
        }
        return (code, cleanupError)
    }

    /// PUT 到上传位;断网、超时、存储端 5xx 时在上传位过期前用同一个地址再试。
    private func transfer(_ fileURL: URL, slot: DiagnosticUpload.Slot) async throws {
        var attempts = 0
        while true {
            phase = .uploading(0)
            do {
                try await DiagnosticArchiveTransfer.put(fileURL, slot: slot) { fraction in
                    Task { @MainActor in self.reportUploadProgress(fraction) }
                }
                return
            } catch let failure as DiagnosticUpload.Failure {
                attempts += 1
                guard DiagnosticUpload.canRetryTransfer(
                    after: failure, attemptsMade: attempts, expiresAt: slot.expiresAt, now: Date()
                ) else { throw failure }
                try await Task.sleep(for: .seconds(DiagnosticUpload.retryDelay(afterAttempt: attempts)))
            }
        }
    }

    /// 确认是幂等的:存储暂时出错或断网就再确认一次;中转说包还没到就重新 PUT 再确认。
    private func complete(_ slot: DiagnosticUpload.Slot, archiveURL: URL) async throws -> String {
        var attempts = 0
        while true {
            phase = .confirming
            do {
                if let palveni {
                    return try await palveni.complete(id: slot.uploadID)
                }
                return try await client.completeDiagnosticsUpload(id: slot.uploadID)
            } catch let failure as DiagnosticUpload.Failure {
                attempts += 1
                guard attempts < DiagnosticUpload.maximumCompletionAttempts else { throw failure }
                switch DiagnosticUpload.completionRecovery(after: failure) {
                case .none:
                    throw failure
                case .retry:
                    try await Task.sleep(for: .seconds(DiagnosticUpload.retryDelay(afterAttempt: attempts)))
                case .reupload:
                    try await transfer(archiveURL, slot: slot)
                }
            }
        }
    }

    private func reportUploadProgress(_ fraction: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(fraction)
    }

    /// 没配邮件账户时交给系统分享面板的同一个包。不设上限:AirDrop、存到「文件」不在乎大小。
    static func shareableArchive(_ selection: Selection) async throws -> DiagnosticReportPackager.Archive {
        let (input, _) = await packagerInput(selection)
        DiagnosticReportPackager.removeStaleWorkDirectories()
        return try await Task.detached(priority: .userInitiated) {
            try DiagnosticReportPackager.build(input)
        }.value
    }

    /// 进行中的步骤怎么写,iPhone、Mac 与 Apple TV 共用。
    static func describe(_ phase: Phase) -> String {
        switch phase {
        case .packaging:
            return String(localized: "diagnostics_upload_packaging")
        case .uploading(let fraction):
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            return String(format: String(localized: "diagnostics_upload_progress %lld"), percent)
        case .confirming:
            return String(localized: "diagnostics_upload_confirming")
        }
    }

    /// 失败时给人看的一句话,iPhone、Mac 与 Apple TV 共用。
    static func message(for failure: DiagnosticUpload.Failure) -> String {
        switch failure {
        case .tooLarge:
            return String(localized: "diagnostics_upload_error_too_large")
        case .dailyLimit(let retryAt):
            let resetAt = DiagnosticUpload.dailyLimitResetDate(retryAt: retryAt, now: Date())
            return String(
                format: String(localized: "diagnostics_upload_error_daily_limit %@"),
                resetAt.formatted(date: .abbreviated, time: .shortened)
            )
        case .unavailable:
            return String(localized: "diagnostics_upload_error_unavailable")
        case .network:
            return String(localized: "diagnostics_upload_error_network")
        case .other(let code):
            return String(format: String(localized: "diagnostics_upload_error_other %@"), code)
        }
    }

    /// 正文开头那句「附上了什么」,邮件与 feedback.txt 共用。
    static func intro(for selection: DiagnosticReportMail.Selection) -> String {
        switch selection {
        case .all: String(localized: "diagnostics_send_all")
        case .reports: String(localized: "diagnostics_send_reports_only")
        case .logs: String(localized: "diagnostics_send_logs_only")
        case .none: ""
        }
    }

    /// 日志按渠道截好末尾一段(正式版 4 MiB,测试渠道 8 MiB),其余照用户选的收齐。
    private static func packagerInput(
        _ selection: Selection,
        preparingUpload: Bool = false
    ) async -> (DiagnosticReportPackager.Input, FileLogger.UploadSnapshot?) {
        var log: Data?
        var logSnapshot: FileLogger.UploadSnapshot?
        if selection.includesLog {
            #if os(iOS) || os(macOS)
            await AppServices.shared.spotlightIndex.prepareDiagnosticsForExport(library: AppServices.shared.musicLibrary)
            #endif
            let tail = DiagnosticUpload.logTailBytes(
                channel: Bundle.main.distributionChannel,
                diagnosticMode: FileLogger.isDiagnosticModeActive
            )
            let data: Data
            if preparingUpload {
                let snapshot = await FileLogger.shared.uploadSnapshot(maxBytes: tail)
                logSnapshot = snapshot
                data = snapshot.data
            } else {
                data = await FileLogger.shared.tailData(maxBytes: tail)
            }
            log = data.isEmpty ? nil : data
        }
        let mailSelection = DiagnosticReportMail.Selection(
            includesReports: !selection.reportURLs.isEmpty,
            includesLogs: log != nil
        )
        return (DiagnosticReportPackager.Input(
            environment: DiagnosticReportEnvironment.current(),
            intro: intro(for: mailSelection),
            reportURLs: selection.reportURLs,
            log: log,
            message: selection.message,
            screenshots: selection.screenshots
        ), logSnapshot)
    }
}

/// 把压缩包 PUT 到服务(Palveni 或中转)给的预签名地址。不带任何身份信息:地址本身就是
/// 凭证,只照服务要求带上它签进去的头。
nonisolated enum DiagnosticArchiveTransfer {
    /// URLSession 自己管这几个头,手动设了也可能被忽略或改写;Content-Length 由
    /// 文件大小得出,和要上传位时报的 byte_count 是同一个数(要位时已核对过)。
    private nonisolated static let systemManagedHeaders: Set<String> = ["content-length", "host", "connection"]

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    nonisolated static func put(
        _ fileURL: URL,
        slot: DiagnosticUpload.Slot,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(
            url: slot.uploadURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "PUT"
        for (name, value) in slot.headers where !systemManagedHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let response: URLResponse
        do {
            response = try await session.upload(
                for: request,
                fromFile: fileURL,
                delegate: DiagnosticUploadProgressDelegate(report: progress)
            ).1
        } catch {
            throw PrimuseAIRelayClient.diagnosticUploadError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DiagnosticUpload.Failure.other(code: "invalid_response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DiagnosticUpload.Failure.other(code: "storage_http_\(http.statusCode)")
        }
    }
}

/// 上传进度:每前进 1% 或传完时才报,免得主线程被刷屏。URLSession 在自己的队列上回调,
/// 所以整个类不隔离到主线程。
private nonisolated final class DiagnosticUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastReported = -1.0

    init(report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let shouldReport: Bool = lock.withLock {
            guard fraction >= 1 || fraction - lastReported >= 0.01 else { return false }
            lastReported = fraction
            return true
        }
        if shouldReport { report(fraction) }
    }
}
