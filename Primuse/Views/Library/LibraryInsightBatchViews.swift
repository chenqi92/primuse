import SwiftUI
import PrimuseKit

extension View {
    /// 「补全缺少的简介」:`request` 由菜单置 true,这时从 `items`(当前列表,按显示顺序)里
    /// 挑出缺简介的,弹出说明页;一个都不缺时只提示一句。
    func libraryInsightBatchFill(
        kind: LibraryInsightKind,
        request: Binding<Bool>,
        items: @escaping () -> [LibraryInsightBatchItem]
    ) -> some View {
        modifier(LibraryInsightBatchFillModifier(kind: kind, request: request, items: items))
    }
}

/// 一次要补的这批,给说明页用。
struct LibraryInsightBatchPlan: Identifiable {
    let id = UUID()
    let kind: LibraryInsightKind
    let items: [LibraryInsightBatchItem]
}

/// 专辑页、艺人页右上角菜单里的「补全缺少的简介」;正在补时换成「停止」。
/// 工具栏条目跑在自己的视图图里:只收闭包、读单例,不读环境。
struct LibraryInsightBatchMenuItem: View {
    let start: () -> Void

    private var batch: LibraryInsightBatchFill { .shared }

    var body: some View {
        if let progress = batch.progress, progress.isRunning {
            Button(role: .destructive) {
                batch.stop()
            } label: {
                Label(
                    String(
                        format: String(localized: "library_insight_batch_stop_format"),
                        progress.done,
                        progress.total
                    ),
                    systemImage: "stop.circle"
                )
            }
        } else {
            Button(action: start) {
                Label("library_insight_batch_fill", systemImage: "sparkles")
            }
            .accessibilityIdentifier("libraryInsightBatch.fill")
        }
    }
}

private struct LibraryInsightBatchFillModifier: ViewModifier {
    @Environment(MusicLibrary.self) private var library

    let kind: LibraryInsightKind
    @Binding var request: Bool
    let items: () -> [LibraryInsightBatchItem]

    @State private var plan: LibraryInsightBatchPlan?
    @State private var showsNothingToFill = false
    /// 说明页里点了去设置:等它收起再跳,免得跳转和收起撞在一起。
    @State private var pendingSettingID: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, requested in
                guard requested else { return }
                request = false
                prepare()
            }
            .sheet(item: $plan, onDismiss: openPendingSetting) { plan in
                LibraryInsightBatchSheet(plan: plan) { settingID in
                    pendingSettingID = settingID
                    self.plan = nil
                }
            }
            .alert(Text("library_insight_batch_none_title"), isPresented: $showsNothingToFill) {
                Button("done", role: .cancel) {}
            } message: {
                Text(kind == .album
                    ? LocalizedStringKey("library_insight_batch_none_album")
                    : LocalizedStringKey("library_insight_batch_none_artist"))
            }
    }

    private func prepare() {
        let store = LibraryInsightStore.shared
        let missing = items().filter { item in
            LibraryInsightStore.isIntroducible(item.subject)
                && LibraryInsightBatchPolicy.needsFill(
                    library.storedLibraryInsightRecord(id: store.recordID(for: item.subject))
                )
        }
        if missing.isEmpty {
            showsNothingToFill = true
        } else {
            plan = LibraryInsightBatchPlan(kind: kind, items: missing)
        }
    }

    private func openPendingSetting() {
        guard let settingID = pendingSettingID else { return }
        pendingSettingID = nil
        SettingsNavigation.shared.open(settingID)
    }
}

/// 开始前的说明页。用内置 AI 时先讲清楚体验额度有限、用完就停,推荐换成自己的服务并写明
/// 在哪儿设置(能直接跳过去);也可以坚持用内置 AI。用自己的服务时只确认一下。
struct LibraryInsightBatchSheet: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(\.dismiss) private var dismiss

    let plan: LibraryInsightBatchPlan
    /// 关掉说明页并在收起后打开这项设置。
    let openSetting: (String) -> Void

    @State private var allowance: LibraryInsightBuiltInAllowance?
    @State private var isCheckingAllowance = false
    @State private var consentError = false

    private var title: String {
        plan.kind == .album
            ? String(localized: "library_insight_batch_title_album")
            : String(localized: "library_insight_batch_title_artist")
    }

    private var countLine: String {
        let format: String.LocalizationValue = plan.kind == .album
            ? "library_insight_batch_count_album_format"
            : "library_insight_batch_count_artist_format"
        return String(format: String(localized: format), plan.items.count)
    }

    private var ownServiceName: String? { intelligence.libraryInsightOwnServiceName }

    private var remainingIntros: Int? { allowance?.remainingIntros }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
                .font(.title3.bold())
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 4)
            form
            HStack {
                Spacer()
                Button("cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 440)
        #else
        NavigationStack {
            form
                .navigationTitle(Text(verbatim: title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Text(verbatim: countLine)
            }
            if intelligence.libraryInsightNeedsRemoteConsent {
                consentSection
            } else if !intelligence.isLibraryInsightAvailable {
                notConfiguredSection
            } else if intelligence.libraryInsightAsksBuiltIn {
                builtInSection
                ownServiceSection
            } else {
                ownServiceConfirmSection
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .accessibilityIdentifier("libraryInsightBatch.sheet")
    }

    // MARK: 授权与配置

    private var consentSection: some View {
        Section {
            Text("library_insight_needs_consent")
            Button {
                do {
                    try intelligence.grantRemoteConsent()
                } catch {
                    consentError = true
                }
            } label: {
                Label("library_insight_batch_allow", systemImage: "checkmark.shield")
            }
            if consentError {
                Text("ai_song_discovery_failed_generic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("library_insight_batch_consent_title")
        }
    }

    private var notConfiguredSection: some View {
        Section {
            Text("library_insight_not_configured")
            Button {
                openSetting("intelligence.relay")
            } label: {
                Label("ai_song_discovery_open_settings", systemImage: "gearshape")
            }
        }
    }

    // MARK: 内置 AI

    private var builtInSection: some View {
        Section {
            Text("library_insight_batch_builtin_message")
            allowanceRow
            Button {
                start(skipsBuiltIn: false)
            } label: {
                Label("library_insight_batch_builtin_start", systemImage: "sparkles")
            }
            // 额度已经用完又没有自己的服务可接:点了也是马上停。
            .disabled(remainingIntros == 0 && ownServiceName == nil)
            .accessibilityIdentifier("libraryInsightBatch.startBuiltIn")
        } header: {
            Label("library_insight_batch_builtin_title", systemImage: "gauge.with.dots.needle.33percent")
        } footer: {
            if let ownServiceName {
                Text(verbatim: String(
                    format: String(localized: "library_insight_batch_builtin_then_own_format"),
                    ownServiceName
                ))
            }
        }
        .task { await loadAllowance() }
    }

    @ViewBuilder
    private var allowanceRow: some View {
        if isCheckingAllowance {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("library_insight_batch_builtin_checking")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        } else if let remainingIntros {
            Text(verbatim: remainingIntros == 0
                ? String(localized: "library_insight_batch_builtin_exhausted")
                : String(format: String(localized: "library_insight_batch_builtin_remaining_format"), remainingIntros))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(remainingIntros == 0 ? Color.orange : Color.secondary)
        }
    }

    /// 推荐用自己的服务:写明在哪儿设置,能直接跳过去;已经有自己的服务时也可以这次就用它。
    private var ownServiceSection: some View {
        Section {
            if let ownServiceName {
                Text(verbatim: String(
                    format: String(localized: "library_insight_batch_own_route_format"),
                    ownServiceName,
                    Self.settingsPath(for: .routes),
                    AIFeature.libraryInsight.localizedTitle
                ))
                Button {
                    start(skipsBuiltIn: true)
                } label: {
                    Label(
                        String(format: String(localized: "library_insight_batch_use_own_format"), ownServiceName),
                        systemImage: "key.horizontal"
                    )
                }
                .accessibilityIdentifier("libraryInsightBatch.useOwn")
                Button {
                    openSetting("intelligence.routes")
                } label: {
                    Label("library_insight_batch_open_routes", systemImage: "arrow.up.forward.app")
                }
            } else {
                Text(verbatim: String(
                    format: String(localized: "library_insight_batch_own_guide_format"),
                    Self.settingsPath(for: .services),
                    Self.settingsPath(for: .routes),
                    AIFeature.libraryInsight.localizedTitle
                ))
                Button {
                    openSetting("intelligence.addProvider")
                } label: {
                    Label("library_insight_batch_open_add_service", systemImage: "arrow.up.forward.app")
                }
                .accessibilityIdentifier("libraryInsightBatch.addService")
            }
        } header: {
            Label("library_insight_batch_own_title", systemImage: "key.horizontal")
        }
    }

    // MARK: 自己的服务

    private var ownServiceConfirmSection: some View {
        Section {
            Text(verbatim: String(
                format: String(localized: "library_insight_batch_own_confirm_format"),
                ownServiceName ?? String(localized: "ai_settings_title")
            ))
            Button {
                start(skipsBuiltIn: false)
            } label: {
                Label("library_insight_batch_start", systemImage: "sparkles")
            }
            .accessibilityIdentifier("libraryInsightBatch.start")
        }
    }

    // MARK: -

    private func loadAllowance() async {
        guard allowance == nil else { return }
        isCheckingAllowance = true
        allowance = await intelligence.libraryInsightBuiltInAllowance()
        isCheckingAllowance = false
    }

    private func start(skipsBuiltIn: Bool) {
        LibraryInsightBatchFill.shared.start(
            plan.items,
            kind: plan.kind,
            skipsBuiltIn: skipsBuiltIn,
            library: library,
            intelligence: intelligence,
            sourceManager: sourceManager,
            sourcesStore: sourcesStore
        )
        dismiss()
    }

    enum SettingsPathTarget {
        /// 设置 › 智能功能 › 服务
        case services
        /// 设置 › 智能功能 › 功能 › 按需使用的功能
        case routes
    }

    /// 写在说明里的设置位置,用的都是设置页上真实的标题。
    static func settingsPath(for target: SettingsPathTarget) -> String {
        var parts = [String(localized: "settings_title"), String(localized: "ai_settings_title")]
        switch target {
        case .services:
            parts.append(String(localized: "ai_settings_tab_services"))
        case .routes:
            parts.append(String(localized: "ai_settings_tab_features"))
            parts.append(String(localized: "ai_features_on_demand_section"))
        }
        return parts.joined(separator: " \u{203A} ")
    }
}

/// 页面上的补全进度,补完或停下后换成结果,点叉收起。只在同一种(专辑 / 艺人)页面上显示。
struct LibraryInsightBatchStatusCard: View {
    let kind: LibraryInsightKind
    /// 卡片外的留白;没有卡片时不占地方。进度只在这里读,页面本身不跟着每一个的进度重绘。
    var outerPadding = EdgeInsets()

    private var batch: LibraryInsightBatchFill { .shared }

    #if os(macOS)
    private let titleFont = Font.system(size: 12.5, weight: .semibold)
    private let detailFont = Font.system(size: 11)
    #else
    private let titleFont = Font.subheadline.weight(.semibold)
    private let detailFont = Font.caption
    #endif

    var body: some View {
        if let progress = batch.progress, progress.kind == kind {
            card(progress)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("libraryInsightBatch.status")
                .padding(outerPadding)
        }
    }

    private func card(_ progress: LibraryInsightBatchFill.Progress) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(progress))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconStyle(progress))
                .frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: headline(progress))
                    .font(titleFont)
                    .fixedSize(horizontal: false, vertical: true)
                if progress.isRunning {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                    runningDetail(progress)
                } else {
                    if let summary = summary(progress) {
                        Text(verbatim: summary)
                            .font(detailFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if offersOwnServiceSetup(progress) {
                        Button {
                            batch.dismiss()
                            SettingsNavigation.shared.open("intelligence.addProvider")
                        } label: {
                            Text("library_insight_batch_setup_own")
                                .font(detailFont.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if progress.isRunning {
                Button(role: .destructive) {
                    batch.stop()
                } label: {
                    Text("library_insight_batch_stop")
                        .font(detailFont.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("libraryInsightBatch.stop")
            } else {
                Button {
                    batch.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("close"))
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func runningDetail(_ progress: LibraryInsightBatchFill.Progress) -> some View {
        if let waitingUntil = progress.waitingUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: String(
                    format: String(localized: "library_insight_batch_waiting_format"),
                    max(1, Int(waitingUntil.timeIntervalSince(context.date).rounded(.up)))
                ))
                .font(detailFont)
                .foregroundStyle(.secondary)
            }
        } else if let provider = progress.providerName {
            let format: String.LocalizationValue = progress.switchedToOwnService
                ? "library_insight_batch_switched_format"
                : "library_insight_batch_using_format"
            Text(verbatim: String(format: String(localized: format), provider))
            .font(detailFont)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }

    private func headline(_ progress: LibraryInsightBatchFill.Progress) -> String {
        switch progress.stopReason {
        case nil:
            return String(
                format: String(localized: "library_insight_batch_progress_format"),
                progress.done,
                progress.total
            )
        case .completed?:
            return String(localized: "library_insight_batch_finished")
        case .cancelled?:
            return String(localized: "library_insight_batch_stopped")
        case .repeatedFailures?:
            return String(localized: "library_insight_batch_stopped_failures")
        case .failure(let failure)?:
            return LibraryInsightStore.message(for: failure)
        }
    }

    /// 补了几个 · 读回几个 · 不了解几个 · 没成几个 · 还剩几个,是零的不写。
    private func summary(_ progress: LibraryInsightBatchFill.Progress) -> String? {
        let parts: [(String.LocalizationValue, Int)] = [
            ("library_insight_batch_result_filled_format", progress.filled),
            ("library_insight_batch_result_imported_format", progress.imported),
            ("library_insight_batch_result_unknown_format", progress.unknown),
            ("library_insight_batch_result_failed_format", progress.failed),
            ("library_insight_batch_result_left_format", progress.left),
        ]
        let text = parts
            .filter { $0.1 > 0 }
            .map { String(format: String(localized: $0.0), $0.1) }
            .joined(separator: " \u{00B7} ")
        return text.isEmpty ? nil : text
    }

    /// 因内置 AI 的额度或服务用不了而停下,且还没有自己的服务:给一个去设置的入口。
    private func offersOwnServiceSetup(_ progress: LibraryInsightBatchFill.Progress) -> Bool {
        guard case .failure(let failure)? = progress.stopReason, progress.left > 0 else { return false }
        switch failure {
        case .failed(.dailyLimit), .failed(.monthlyLimit), .builtInNotOffered, .notConfigured:
            return true
        default:
            return false
        }
    }

    private func icon(_ progress: LibraryInsightBatchFill.Progress) -> String {
        switch progress.stopReason {
        case nil: "sparkles"
        case .completed?: "checkmark.circle.fill"
        case .cancelled?: "stop.circle"
        case .failure?, .repeatedFailures?: "exclamationmark.circle.fill"
        }
    }

    private func iconStyle(_ progress: LibraryInsightBatchFill.Progress) -> AnyShapeStyle {
        switch progress.stopReason {
        case nil: AnyShapeStyle(.tint)
        case .completed?: AnyShapeStyle(Color.green)
        case .cancelled?: AnyShapeStyle(.secondary)
        case .failure?, .repeatedFailures?: AnyShapeStyle(Color.orange)
        }
    }
}

#if os(macOS)
/// Mac 专辑页、艺人页头部的「补全缺少的简介」;正在补时换成停止。和旁边的排序、视图切换同一种玻璃小按钮。
struct LibraryInsightBatchMacButton: View {
    let start: () -> Void

    private var batch: LibraryInsightBatchFill { .shared }

    var body: some View {
        let isRunning = batch.isRunning
        let title: LocalizedStringKey = isRunning ? "library_insight_batch_stop" : "library_insight_batch_fill"
        Button {
            if isRunning { batch.stop() } else { start() }
        } label: {
            Image(systemName: isRunning ? "stop.circle" : "sparkles")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .frame(width: 28, height: 24)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("libraryInsightBatch.fill")
    }
}
#endif
