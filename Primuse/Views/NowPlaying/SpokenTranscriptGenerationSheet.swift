import PrimuseKit
import SwiftUI

/// 给一集播客或一章有声书生成文稿(#314):选识别方式(本机 / 内置智能 / 自己的 Google 密钥 / 阿里云百炼)、
/// 本机识别的语言,开始后显示进度,可以停下;失败了写明原因,能重试。
struct SpokenTranscriptGenerationSheet: View {
    let song: Song
    /// 从播放页打开的:开始后面板自己收起,进度在播放页上看(`SpokenTranscriptGenerationStatusPill`)。
    var dismissesOnStart = false

    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss

    @State private var engine: SpokenTranscriptEngine?
    @State private var onDeviceAvailable: Bool?
    @State private var supportedLocales: [String] = []
    @State private var localeIdentifier: String?
    @State private var allowance: SpokenTranscriptBuiltInAllowance?
    @State private var showsUploadConfirmation = false
    /// 关掉面板后要去的设置页。
    @State private var pendingSettingID: String?

    private var generator: SpokenTranscriptGenerator { .shared }
    private var aliyunAccount: AliyunSpeechTranscriptionAccount { .shared }

    private var segmentCount: Int? {
        guard song.duration > 0 else { return nil }
        return SpokenTranscriptSegmentPlan(duration: song.duration).segments.count
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                engineSection
                actionSection
            }
            .navigationTitle(Text("transcript_generation_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
            }
            .alert(
                Text("transcript_generation_upload_confirm_title"),
                isPresented: $showsUploadConfirmation
            ) {
                Button("cancel", role: .cancel) {}
                Button("transcript_generation_upload_confirm") {
                    if let engine { generator.grantUploadConsent(for: engine) }
                    startGeneration()
                }
            } message: {
                Text(uploadNoticeKey)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .task { await prepare() }
        .onDisappear {
            guard let settingID = pendingSettingID else { return }
            pendingSettingID = nil
            SettingsNavigation.shared.open(settingID)
        }
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.headline)
                    .lineLimit(2)
                if song.duration > 0 {
                    // 分段只对切段上传的两种方式有意义。
                    let segments = engine?.uploadsInSegments == true ? segmentCount : nil
                    Text(verbatim: [
                        Self.durationText(song.duration),
                        segments.map { String(format: String(localized: "transcript_generation_segments_format"), $0) },
                    ].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 识别方式收成一行下拉:四种平铺时「开始生成」被挤到屏幕下面,要先划一下才点得到。
    /// 选中那种的说明写在下拉下面;本机识别的语言也放在这一组里。
    private var engineSection: some View {
        Section {
            LabeledContent {
                engineMenu
            } label: {
                Text("transcript_generation_engine_section")
            }
            if let engine {
                engineDetail(engine)
            }
            if engine == .onDevice, onDeviceAvailable == true {
                languageRow
            }
        } footer: {
            if engine == .onDevice, onDeviceAvailable == true {
                Text("transcript_generation_language_footer")
            } else if let engine, engine.uploadsAudio, engineIssue(engine) == nil {
                Text(uploadNoticeKey)
            }
        }
    }

    /// 不可用的方式照样能选,菜单里那一项的副标题就写明差在哪儿。
    private var engineMenu: some View {
        Menu {
            ForEach(SpokenTranscriptEngine.allCases, id: \.self) { candidate in
                Button {
                    engine = candidate
                } label: {
                    AIMenuChoiceLabel(
                        title: Self.title(candidate),
                        detail: engineStatus(candidate),
                        isSelected: engine == candidate
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let engine {
                    Text(verbatim: Self.title(engine))
                        .lineLimit(1)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
        #if os(macOS)
        // `.button` + 透明按钮样式才把上面这行字当触发器,系统补的箭头去掉(自己画了)。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        #endif
        .disabled(generator.activeJob != nil)
    }

    /// 菜单里每一项的副标题:差什么,或者内置 AI 还剩几段。
    private func engineStatus(_ candidate: SpokenTranscriptEngine) -> String? {
        if let issue = engineIssue(candidate) {
            return String(localized: issue.message)
        }
        if candidate == .builtIn, let remaining = allowance?.remainingSegments {
            return String(format: String(localized: "transcript_generation_remaining_format"), remaining)
        }
        return nil
    }

    /// 选中那种怎么识别;不可用时写明差在哪儿,能一键补上的给「去设置」。
    private func engineDetail(_ engine: SpokenTranscriptEngine) -> some View {
        let issue = engineIssue(engine)
        return VStack(alignment: .leading, spacing: 4) {
            Text(Self.detailKey(engine))
                .foregroundStyle(.secondary)
            if let issue {
                Text(verbatim: String(localized: issue.message))
                    .foregroundStyle(.orange)
            } else if let status = engineStatus(engine) {
                Text(verbatim: status)
                    .foregroundStyle(.secondary)
            }
            if let settingID = issue?.settingID {
                Button("transcript_generation_open_settings") {
                    pendingSettingID = settingID
                    dismiss()
                }
                .fontWeight(.semibold)
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var languageRow: some View {
        if supportedLocales.isEmpty {
            Text("transcript_generation_language_loading")
                .foregroundStyle(.secondary)
        } else {
            Picker("transcript_generation_language", selection: $localeIdentifier) {
                ForEach(supportedLocales, id: \.self) { identifier in
                    Text(verbatim: Self.languageName(identifier)).tag(Optional(identifier))
                }
            }
            .disabled(generator.activeJob != nil)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            if let job = generator.activeJob {
                if job.song.id == song.id {
                    progressView(job.phase)
                    Button("transcript_generation_stop", role: .destructive) { generator.cancel() }
                } else {
                    Text(String(format: String(localized: "transcript_generation_busy_format"), job.song.title))
                        .foregroundStyle(.secondary)
                }
            } else {
                if case .finished(let songID, let count)? = generator.lastOutcome, songID == song.id {
                    Label(
                        String(format: String(localized: "transcript_generation_done_format"), count),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                } else if case .failed(let songID, let failure)? = generator.lastOutcome, songID == song.id {
                    Label(Self.failureKey(failure), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button(action: requestStart) {
                    Text(startTitleKey)
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .disabled(!canStart)
            }
        } footer: {
            if generator.activeJob?.song.id == song.id {
                let note: LocalizedStringKey = dismissesOnStart
                    ? "transcript_generation_keep_foreground"
                    : "transcript_generation_keep_open"
                Text(note)
            }
        }
    }

    private func progressView(_ phase: SpokenTranscriptGenerator.Phase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Self.phaseText(phase))
                .font(.subheadline)
                .monospacedDigit()
            if let fraction = Self.phaseFraction(phase) {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: State

    private var startTitleKey: LocalizedStringKey {
        if case .failed(let songID, _)? = generator.lastOutcome, songID == song.id {
            return "transcript_generation_retry"
        }
        return generator.records[song.id] == nil ? "transcript_generation_start" : "transcript_generation_regenerate_start"
    }

    private var canStart: Bool {
        guard let engine, engineIssue(engine) == nil else { return false }
        if engine == .onDevice { return localeIdentifier != nil }
        return true
    }

    private var uploadNoticeKey: LocalizedStringKey {
        switch engine {
        case .ownKey: "transcript_generation_upload_notice_own_key"
        case .aliyun: "transcript_generation_upload_notice_aliyun"
        case .builtIn, .onDevice, nil: "transcript_generation_upload_notice_built_in"
        }
    }

    private struct EngineIssue {
        /// 菜单副标题只收字符串,所以存成待查的文案而不是 `LocalizedStringKey`。
        var message: String.LocalizationValue
        var settingID: String?
    }

    private func engineIssue(_ candidate: SpokenTranscriptEngine) -> EngineIssue? {
        switch candidate {
        case .onDevice:
            guard let onDeviceAvailable else { return nil }
            return onDeviceAvailable ? nil : EngineIssue(message: "transcript_generation_on_device_unavailable")
        case .builtIn:
            return Self.issue(for: intelligence.builtInTranscriptGenerationState)
        case .ownKey:
            return Self.issue(for: intelligence.ownKeyTranscriptGenerationState)
        case .aliyun:
            return aliyunAccount.isConfigured
                ? nil
                : EngineIssue(
                    message: "transcript_generation_aliyun_not_configured",
                    settingID: Self.aliyunSettingID
                )
        }
    }

    /// 「听歌识词」页里阿里云百炼那一区。
    static let aliyunSettingID = "lyrics.transcriptionAliyun"

    private static func issue(
        for state: MusicIntelligenceService.TranscriptGenerationCloudState
    ) -> EngineIssue? {
        switch state {
        case .ready:
            return nil
        case .builtInAIOff:
            return EngineIssue(message: "transcript_generation_built_in_off", settingID: SettingsPage.intelligence.id)
        case .deviceUnsupported:
            return EngineIssue(message: "transcript_generation_device_unsupported")
        case .regionRestricted:
            return EngineIssue(message: "transcript_generation_region_restricted")
        case .notOffered:
            return EngineIssue(message: "transcript_generation_built_in_not_offered")
        case .notInPlan:
            return EngineIssue(message: "transcript_generation_built_in_not_in_plan")
        case .ownKeyNotConfigured:
            return EngineIssue(message: "transcript_generation_own_key_not_configured", settingID: SettingsPage.transcription.id)
        }
    }

    private func prepare() async {
        let available = await OnDeviceSpeechTranscription.isAvailable()
        onDeviceAvailable = available
        aliyunAccount.reload()
        await intelligence.refreshBuiltInTranscriptGenerationOffer()
        if engine == nil {
            engine = Self.defaultEngine(
                onDevice: available,
                builtIn: intelligence.builtInTranscriptGenerationState == .ready,
                ownKey: intelligence.ownKeyTranscriptGenerationState == .ready,
                aliyun: aliyunAccount.isConfigured,
                previous: generator.records[song.id]?.engine
            )
        }
        if available {
            async let locales = OnDeviceSpeechTranscription.supportedLocaleIdentifiers()
            async let preferred = OnDeviceSpeechTranscription.resolvedLocaleIdentifier(
                from: (generator.records[song.id]?.localeIdentifier.map { [$0] } ?? [])
                    + SpokenTranscriptGenerator.languageCandidates(for: song)
            )
            let (supported, resolved) = await (locales, preferred)
            supportedLocales = supported.sorted { Self.languageName($0) < Self.languageName($1) }
            if localeIdentifier == nil {
                localeIdentifier = resolved.flatMap { id in supported.contains(id) ? id : nil } ?? supported.first
            }
        }
        allowance = await intelligence.transcriptGenerationAllowance()
    }

    private static func defaultEngine(
        onDevice: Bool,
        builtIn: Bool,
        ownKey: Bool,
        aliyun: Bool,
        previous: SpokenTranscriptEngine?
    ) -> SpokenTranscriptEngine {
        let ready: [SpokenTranscriptEngine: Bool] = [
            .onDevice: onDevice, .builtIn: builtIn, .ownKey: ownKey, .aliyun: aliyun,
        ]
        if let previous, ready[previous] == true { return previous }
        return SpokenTranscriptEngine.allCases.first { ready[$0] == true } ?? .onDevice
    }

    private func requestStart() {
        guard let engine, canStart else { return }
        if engine.uploadsAudio, !generator.hasUploadConsent(for: engine) {
            showsUploadConfirmation = true
            return
        }
        startGeneration()
    }

    private func startGeneration() {
        guard let engine else { return }
        generator.start(song: song, engine: engine, localeIdentifier: engine == .onDevice ? localeIdentifier : nil)
        if dismissesOnStart { dismiss() }
    }

    // MARK: Text

    static func title(_ engine: SpokenTranscriptEngine) -> String {
        switch engine {
        case .onDevice: String(localized: "transcript_generation_engine_on_device")
        case .builtIn: String(localized: "transcript_generation_engine_built_in")
        case .ownKey: String(localized: "transcript_generation_engine_own_key")
        case .aliyun: String(localized: "transcript_generation_engine_aliyun")
        }
    }

    private static func detailKey(_ engine: SpokenTranscriptEngine) -> LocalizedStringKey {
        switch engine {
        case .onDevice: "transcript_generation_engine_on_device_detail"
        case .builtIn: "transcript_generation_engine_built_in_detail"
        case .ownKey: "transcript_generation_engine_own_key_detail"
        case .aliyun: "transcript_generation_engine_aliyun_detail"
        }
    }

    static func phaseText(_ phase: SpokenTranscriptGenerator.Phase) -> String {
        switch phase {
        case .fetchingAudio(let fraction?):
            return String(format: String(localized: "transcript_generation_phase_downloading_format"), Int((fraction * 100).rounded()))
        case .fetchingAudio(nil):
            return String(localized: "transcript_generation_phase_fetching")
        case .convertingAudio:
            return String(localized: "transcript_generation_phase_converting")
        case .preparingModel:
            return String(localized: "transcript_generation_phase_model")
        case .transcribing(let fraction):
            return String(format: String(localized: "transcript_generation_phase_transcribing_format"), Int((fraction * 100).rounded()))
        case .uploading(let segment, let total):
            return String(format: String(localized: "transcript_generation_phase_uploading_format"), segment, total)
        case .uploadingAudio(let fraction?):
            return String(format: String(localized: "transcript_generation_phase_aliyun_uploading_format"), Int((fraction * 100).rounded()))
        case .uploadingAudio(nil):
            return String(localized: "transcript_generation_phase_aliyun_uploading")
        case .recognizingRemotely:
            return String(localized: "transcript_generation_phase_aliyun_recognizing")
        case .finishing:
            return String(localized: "transcript_generation_phase_finishing")
        }
    }

    static func phaseFraction(_ phase: SpokenTranscriptGenerator.Phase) -> Double? {
        switch phase {
        case .fetchingAudio(let fraction): return fraction
        case .transcribing(let fraction): return fraction
        case .uploading(let segment, let total): return total > 0 ? Double(segment - 1) / Double(total) : nil
        case .uploadingAudio(let fraction): return fraction
        case .convertingAudio, .preparingModel, .recognizingRemotely, .finishing: return nil
        }
    }

    static func failureKey(_ failure: SpokenTranscriptGenerator.Failure) -> LocalizedStringKey {
        switch failure {
        case .audioUnavailable: "transcript_generation_failure_audio"
        case .unreadableAudio: "transcript_generation_failure_unreadable"
        case .onDeviceUnavailable: "transcript_generation_on_device_unavailable"
        case .unsupportedLanguage: "transcript_generation_failure_language"
        case .modelUnavailable: "transcript_generation_failure_model"
        case .noSpeech: "transcript_generation_failure_no_speech"
        case .builtInUnavailable: "transcript_generation_built_in_not_offered"
        case .builtInLimitReached: "transcript_generation_failure_limit"
        case .builtInMonthlyLimitReached: "transcript_generation_failure_monthly_limit"
        case .builtInNotInPlan: "transcript_generation_built_in_not_in_plan"
        case .ownKeyUnavailable: "transcript_generation_failure_own_key"
        case .aliyunNotConfigured: "transcript_generation_aliyun_not_configured"
        case .aliyunNetwork: "aliyun_speech_error_network"
        case .aliyunKeyRejected: "transcript_generation_aliyun_failure_key"
        case .aliyunAccessDenied: "transcript_generation_aliyun_failure_access"
        case .aliyunBilling: "transcript_generation_aliyun_failure_billing"
        case .aliyunThrottled: "transcript_generation_aliyun_failure_throttled"
        case .aliyunContentBlocked: "transcript_generation_aliyun_failure_content"
        case .aliyunFileRejected: "transcript_generation_aliyun_failure_file"
        case .aliyunTooLong: "transcript_generation_aliyun_failure_too_long"
        case .aliyunTimedOut: "transcript_generation_aliyun_failure_timed_out"
        case .aliyunFailed: "transcript_generation_aliyun_failure_generic"
        case .failed: "transcript_generation_failure_generic"
        }
    }

    private static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// 播放页里的文字稿生成进度(#314)。给正在听的这一集生成时,播放页上挂一条小胶囊写着做到哪一步、几成,
/// 点开是生成面板,能看详情或停止;做完换成「文字稿已生成 · 查看」,点一下打开文字稿;没做成提示一句,
/// 点开面板看原因、重试。结果提示过几秒自己收起。不在生成、也没有新结果时什么都不画、不占位置。
struct SpokenTranscriptGenerationStatusPill: View {
    let songID: String?
    let onOpenDetails: () -> Void
    let onShowTranscript: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 结果提示到点收起时换一下,让这一块重新判断还显不显示。
    @State private var expiryTick = 0

    private var generator: SpokenTranscriptGenerator { .shared }

    private static let resultVisibleSeconds: TimeInterval = 8

    private enum Display: Equatable {
        case running(SpokenTranscriptGenerator.Phase)
        case finished
        case failed
    }

    private var display: Display? {
        _ = expiryTick
        guard let songID else { return nil }
        if let job = generator.activeJob, job.song.id == songID {
            return .running(job.phase)
        }
        guard let at = generator.lastOutcomeAt,
              Date().timeIntervalSince(at) < Self.resultVisibleSeconds else { return nil }
        switch generator.lastOutcome {
        case .finished(let id, _)? where id == songID: return .finished
        case .failed(let id, _)? where id == songID: return .failed
        default: return nil
        }
    }

    /// 没有要显示的就什么都不产出:放在横排里也不多占一份间距。
    var body: some View {
        if let display {
            pill(display)
                .padding(.vertical, 4)
                .transition(
                    .opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.38, extraBounce: 0.08))
                )
                .task(id: generator.lastOutcomeAt) {
                    guard let at = generator.lastOutcomeAt else { return }
                    let remaining = Self.resultVisibleSeconds - Date().timeIntervalSince(at)
                    guard remaining > 0 else { return }
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                    expiryTick &+= 1
                }
        }
    }

    private func pill(_ display: Display) -> some View {
        Button {
            switch display {
            case .running, .failed:
                onOpenDetails()
            case .finished:
                generator.clearOutcome()
                onShowTranscript()
            }
        } label: {
            HStack(spacing: 6) {
                icon(display)
                    .frame(width: 16, height: 16)
                Text(verbatim: title(display))
                    .lineLimit(1)
                    .monospacedDigit()
                if case .running(let phase) = display {
                    progress(phase)
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title(display)))
        .accessibilityHint(Text(accessibilityHintKey(display)))
    }

    private func accessibilityHintKey(_ display: Display) -> LocalizedStringKey {
        display == .finished ? "transcript_generation_pill_show_hint" : "transcript_generation_pill_details_hint"
    }

    @ViewBuilder
    private func icon(_ display: Display) -> some View {
        switch display {
        case .running:
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    /// 有比例的阶段画一圈进度,拿不到比例的(取音频、转格式、下模型、整理)转小菊花。
    @ViewBuilder
    private func progress(_ phase: SpokenTranscriptGenerator.Phase) -> some View {
        if let fraction = SpokenTranscriptGenerationSheet.phaseFraction(phase) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.3), value: fraction)
            }
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
        }
    }

    private func title(_ display: Display) -> String {
        switch display {
        case .running(let phase):
            String(
                format: String(localized: "transcript_generation_pill_running_format"),
                SpokenTranscriptGenerationSheet.phaseText(phase)
            )
        case .finished:
            String(localized: "transcript_generation_pill_done")
        case .failed:
            String(localized: "transcript_generation_pill_failed")
        }
    }
}

/// 有声内容(播客、有声书)的文字稿那一页在没有文字稿时画什么(#314)。点封面总是进文字稿,和音乐进歌词
/// 一样;这里写明没有,这一条能生成就给「生成文字稿…」;正在给它生成时显示做到哪一步、几成,能看详情或停下;
/// 没做成写明原因、能重试。播客另给一颗「节目说明」。
struct SpokenTranscriptEmptyState: View {
    struct Content {
        var song: Song?
        /// 打开生成面板:生成、重试、看详情都走它。
        var onOpenGeneration: () -> Void
        /// 播客单集的节目说明;不是播客时为空。
        var onShowNotes: (() -> Void)?
    }

    let content: Content
    let palette: SpokenWordPlayerPalette

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 刚生成完的那几秒到点时换一下,让这一块重新判断。
    @State private var settleTick = 0

    private var generator: SpokenTranscriptGenerator { .shared }

    /// 生成完到文字稿读进播放页之间(换歌词是异步的)接着转,不闪一下「暂无文字稿」。
    private static let settleSeconds: TimeInterval = 8

    private enum Display: Equatable {
        case running(SpokenTranscriptGenerator.Phase)
        /// 在给别的单集、章节生成,做完才能开始这一条。
        case busy(title: String)
        case failed(SpokenTranscriptGenerator.Failure)
        case settling
        case idle(canGenerate: Bool)

        /// 换了哪一种情形(进度数字变了不算),只在这时淡入淡出。
        var kind: Int {
            switch self {
            case .running: 0
            case .busy: 1
            case .failed: 2
            case .settling: 3
            case .idle(let canGenerate): canGenerate ? 4 : 5
            }
        }
    }

    private var display: Display {
        _ = settleTick
        guard let song = content.song, SpokenTranscriptGenerator.canGenerate(for: song) else {
            return .idle(canGenerate: false)
        }
        if let job = generator.activeJob {
            return job.song.id == song.id ? .running(job.phase) : .busy(title: job.song.title)
        }
        switch generator.lastOutcome {
        case .failed(let id, let failure)? where id == song.id:
            return .failed(failure)
        case .finished(let id, _)? where id == song.id:
            if let at = generator.lastOutcomeAt, Date().timeIntervalSince(at) < Self.settleSeconds {
                return .settling
            }
        default:
            break
        }
        return .idle(canGenerate: true)
    }

    var body: some View {
        let display = self.display
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            icon(display)
                .font(.system(size: 30, weight: .regular))
                .frame(height: 36)
                .accessibilityHidden(true)
            Text(titleKey(display))
                .font(.title3)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
            switch display {
            case .running(let phase): progress(phase)
            case .settling: progress(.finishing)
            default: EmptyView()
            }
            if let detail = detailText(display) {
                detail
                    .font(.footnote)
                    .foregroundStyle(palette.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions(display) }
                VStack(spacing: 10) { actions(display) }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: display.kind)
        .task(id: generator.lastOutcomeAt) {
            guard let at = generator.lastOutcomeAt else { return }
            let remaining = Self.settleSeconds - Date().timeIntervalSince(at)
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            settleTick &+= 1
        }
    }

    @ViewBuilder
    private func icon(_ display: Display) -> some View {
        switch display {
        case .running, .settling:
            Image(systemName: "waveform")
                .foregroundStyle(palette.secondary)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .busy, .idle:
            Image(systemName: "text.bubble")
                .foregroundStyle(palette.tertiary)
        }
    }

    private func titleKey(_ display: Display) -> LocalizedStringKey {
        switch display {
        case .running, .settling: "transcript_generation_menu_running"
        case .failed: "transcript_empty_failed_title"
        case .busy, .idle: "transcript_empty_title"
        }
    }

    private func detailText(_ display: Display) -> Text? {
        switch display {
        case .running:
            Text("transcript_empty_running_detail")
        case .settling:
            nil
        case .busy(let title):
            Text(verbatim: String(format: String(localized: "transcript_generation_busy_format"), title))
        case .failed(let failure):
            Text(SpokenTranscriptGenerationSheet.failureKey(failure))
        case .idle(let canGenerate):
            canGenerate ? Text("transcript_empty_generate_detail") : nil
        }
    }

    /// 有比例的阶段画一条进度,拿不到比例的(取音频、转格式、下模型、等云端、整理)转小菊花。
    private func progress(_ phase: SpokenTranscriptGenerator.Phase) -> some View {
        let text = SpokenTranscriptGenerationSheet.phaseText(phase)
        return VStack(spacing: 8) {
            Text(verbatim: text)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(palette.primary)
            Group {
                if let fraction = SpokenTranscriptGenerationSheet.phaseFraction(phase) {
                    Capsule()
                        .fill(palette.primary.opacity(0.16))
                        .overlay(alignment: .leading) {
                            GeometryReader { track in
                                Capsule()
                                    .fill(palette.primary)
                                    .frame(width: max(4, track.size.width * min(1, max(0, fraction))))
                                    .animation(.smooth(duration: 0.3), value: fraction)
                            }
                        }
                        .frame(width: 220, height: 4)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.primary)
                }
            }
            .frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }

    @ViewBuilder
    private func actions(_ display: Display) -> some View {
        switch display {
        case .running:
            capsuleButton("transcript_empty_details", prominent: false, action: content.onOpenGeneration)
            capsuleButton("transcript_generation_stop", prominent: false) { generator.cancel() }
        case .failed:
            capsuleButton(
                "transcript_empty_retry",
                symbol: "arrow.clockwise",
                prominent: true,
                action: content.onOpenGeneration
            )
        case .idle(canGenerate: true):
            capsuleButton(
                "transcript_generation_action",
                symbol: "waveform.and.mic",
                prominent: true,
                action: content.onOpenGeneration
            )
        case .busy, .settling, .idle(canGenerate: false):
            EmptyView()
        }
        if let onShowNotes = content.onShowNotes, offersNotes(display) {
            capsuleButton("podcast_show_notes", symbol: "text.alignleft", prominent: false, action: onShowNotes)
        }
    }

    /// 生成中这一排只放详情与停止。
    private func offersNotes(_ display: Display) -> Bool {
        switch display {
        case .running, .settling: false
        case .busy, .failed, .idle: true
        }
    }

    private func capsuleButton(
        _ titleKey: LocalizedStringKey,
        symbol: String? = nil,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol) }
                Text(titleKey)
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? prominentLabel : palette.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(prominent ? palette.primary : palette.tileFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 实心那颗拿正文的颜色铺底,字反过来:深色页上白底黑字,浅色页上黑底白字。
    private var prominentLabel: Color {
        colorScheme == .dark ? .black : .white
    }
}

/// 播放页「更多」里「生成文稿」那一项的标题和副标题(生成中写进度)。
struct SpokenTranscriptGenerationMenuItem: Equatable {
    var titleKey: LocalizedStringKey
    var detail: String?
    var isRunning = false
}
