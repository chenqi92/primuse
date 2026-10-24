#if os(tvOS)
import PrimuseKit
import SwiftUI

// Apple TV 的「智能功能」设置页。
//
// 这里不再复用 iPhone 的 `AISettingsView`:那是一整套 `Form` + `Section`,放到
// 1920 宽的电视画面上,标题会被顶到最左、开关被甩到最右,中间空出一大片;字号也
// 还是手机档,10ft 距离下读不清。tvOS 27 起 `Form` / `NavigationStack` 的默认背景
// 又换成了透明材质,于是下层设置页原样透上来,两层界面叠在一起分不出焦点在哪层。
// 电视端因此按 `TVSettingsView` 的面板行重写一遍界面,数据仍然走共享的
// `AISettingsEditorModel`(保存、鉴权、降级逻辑与手机端完全一致)。

/// 进入服务商详情页用的载体 —— `fullScreenCover(item:)` 需要 `Identifiable`。
private struct TVAIProviderTarget: Identifiable {
    let id: UUID
}

/// 打开「由谁处理」选择页用的载体。
private struct TVAIRouteTarget: Identifiable {
    let feature: AIFeature
    var id: String { feature.rawValue }
}

struct TVAISettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss

    @State private var editor = AISettingsEditorModel()
    @State private var providerTarget: TVAIProviderTarget?
    @State private var routeTarget: TVAIRouteTarget?
    @State private var showsRedeemCode = false
    /// 推荐单位:首页智能推荐那一排开头放不放整张专辑。
    @AppStorage(AIRecommendationUnit.storageKey)
    private var recommendationUnitRawValue = AIRecommendationUnit.defaultUnit.rawValue
    /// 场景推荐多久重新问一次智能服务。
    @AppStorage(AIRecommendationRefreshInterval.storageKey)
    private var recommendationRefreshRawValue = AIRecommendationRefreshInterval.defaultInterval.rawValue

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if !intelligence.shouldExposeRemoteConfiguration {
                        regionNotice
                    } else {
                        HStack(alignment: .top, spacing: 40) {
                            VStack(alignment: .leading, spacing: 0) {
                                relaySection
                                quotaSection
                                capabilitySection
                                providerSection
                                privacySection
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            sideNotes
                                .frame(width: 440, alignment: .leading)
                                .focusSection()
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
            }
        }
        .foregroundStyle(TVColor.text)
        .task { await editor.load(using: intelligence) }
        .onChange(of: intelligence.settingsStore.revision) {
            editor.adoptStoredConsent(from: intelligence)
        }
        .builtInAIConsentSheet($editor.pendingBuiltInConsent)
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $providerTarget) { target in
            TVAIProviderDetailView(editor: editor, providerID: target.id)
                .environment(intelligence)
        }
        .fullScreenCover(item: $routeTarget) { target in
            TVAIRoutePickerView(editor: editor, feature: target.feature)
                .environment(intelligence)
        }
        .fullScreenCover(isPresented: $showsRedeemCode) {
            TVAIRedeemCodeView()
                .environment(intelligence)
        }
        .accessibilityIdentifier("tv.ai.settings")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            Text("ai_settings_title").tvFont(.pageTitle)
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
        }
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var regionNotice: some View {
        if intelligence.regionAvailability.isRefreshing {
            HStack(spacing: 16) {
                ProgressView()
                Text("ai_region_checking").tvFont(.body).foregroundStyle(TVColor.textMuted)
            }
            .padding(.top, 60)
        } else {
            TVEmptyState(
                icon: "globe.asia.australia.fill",
                title: String(localized: "ai_region_unavailable_title"),
                subtitle: String(localized: "ai_region_unavailable_description")
            )
            .padding(.top, 40)
        }
    }

    // MARK: - 内置 AI 体验

    private var relaySection: some View {
        TVAISection(title: String(localized: "ai_primuse_relay_section")) {
            TVAIToggleRow(
                icon: "sparkles",
                title: String(localized: "ai_primuse_relay_enabled"),
                isOn: editor.primuseRelayBinding
            )
            builtInConsentPendingRow
            serviceGuidanceRow
            TVAIDivider()
            TVAIActionRow(
                icon: editor.isTestingPrimuseRelay ? "arrow.triangle.2.circlepath" : "network",
                title: String(localized: "ai_primuse_relay_test_connection"),
                value: relayTestValue,
                trailing: "chevron.right",
                isEnabled: editor.canTestPrimuseRelayConnection
            ) {
                Task { await editor.testPrimuseRelayConnection(using: intelligence) }
            }
            if let detail = editor.primuseRelayConnectionDetail,
               editor.primuseRelayConnectionPresentation != .notTested {
                TVAIDivider()
                TVAINoteRow(icon: relayIcon, tint: relayTint, text: detail)
            }
            if !PrimuseAIRelayClient.isSupportedOnCurrentDevice {
                TVAIDivider()
                TVAINoteRow(
                    icon: "exclamationmark.shield",
                    tint: TVColor.warn,
                    text: String(localized: "ai_primuse_relay_unsupported")
                )
            }
        }
    }

    /// 内置 AI 的额度,和手机、Mac 的「额度」区块一致:打开时读一次,之后每次调用随回复更新。
    @ViewBuilder
    private var quotaSection: some View {
        if intelligence.showsBuiltInQuota {
            let quota = intelligence.builtInQuota
            TVAISection(title: String(localized: "ai_quota_section")) {
                TVAIActionRow(
                    icon: quota.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                    title: String(localized: "ai_quota_refresh"),
                    subtitle: quota.overview.flatMap(BuiltInAIQuotaText.bonusBanner),
                    value: quotaPlanValue(quota),
                    trailing: "chevron.right",
                    isEnabled: !quota.isLoading
                ) {
                    Task { await intelligence.refreshBuiltInQuota(force: true) }
                }
                if let overview = quota.overview {
                    ForEach(overview.orderedFeatures(preferredOrder: BuiltInAIQuotaText.featureOrder)) { feature in
                        TVAIDivider()
                        TVAIQuotaRow(
                            title: BuiltInAIQuotaText.title(for: feature),
                            counter: feature.today,
                            detail: BuiltInAIQuotaText.detail(for: feature)
                        )
                    }
                    if let today = overview.today {
                        TVAIDivider()
                        TVAIQuotaRow(
                            title: String(localized: "ai_quota_total_today"),
                            counter: today,
                            detail: overview.month.map {
                                String(localized: "ai_quota_month_remaining \($0.remaining) \($0.limit)")
                            }
                        )
                    }
                }
                if intelligence.builtInRedeemOffered {
                    TVAIDivider()
                    TVAIActionRow(
                        icon: "ticket",
                        title: String(localized: "ai_redeem_entry"),
                        subtitle: String(localized: "ai_redeem_entry_hint")
                    ) {
                        showsRedeemCode = true
                    }
                }
                TVAIDivider()
                TVAINoteRow(icon: "info.circle", tint: TVColor.textMuted, text: BuiltInAIQuotaText.footer(quota.overview))
            }
            .task {
                await intelligence.refreshBuiltInQuota()
                await intelligence.refreshBuiltInRedeemOffer()
            }
        }
    }

    private func quotaPlanValue(_ quota: BuiltInAIQuotaModel) -> String {
        guard let overview = quota.overview else {
            return quota.isLoading ? String(localized: "ai_quota_loading") : String(localized: "ai_quota_unavailable")
        }
        return BuiltInAIQuotaText.plan(overview)
    }

    /// 开关下方的引导:关掉内置 AI 又没有配好的服务时,直接带去填密钥;
    /// 自己的服务已配好但内置 AI 仍开着时,说明谁优先并给一键改用。
    /// 选了内置 AI 却还没同意:它什么都不会发,这一行说明原因并带去同意页。
    @ViewBuilder
    private var builtInConsentPendingRow: some View {
        if editor.didLoad, editor.draftUsesBuiltIn, editor.needsBuiltInConsentBeforeChoosing {
            TVAIDivider()
            TVAINoteRow(
                icon: "hand.raised.fill",
                tint: TVColor.brand,
                text: String(localized: "ai_consent_pending_detail")
            )
            TVAIActionRow(
                icon: "hand.raised",
                title: String(localized: "ai_consent_pending_title"),
                value: String(localized: "ai_consent_pending_action"),
                trailing: "chevron.right"
            ) {
                editor.pendingBuiltInConsent = BuiltInAIConsentRequest()
            }
        }
    }

    @ViewBuilder
    private var serviceGuidanceRow: some View {
        switch editor.serviceSetupGuidance {
        case .none:
            EmptyView()
        case .configureOwnService(let providerID):
            TVAIDivider()
            TVAINoteRow(
                icon: "key.horizontal.fill",
                tint: TVColor.warn,
                text: String(localized: "ai_setup_needs_service_detail")
            )
            TVAIActionRow(
                icon: "key.horizontal",
                title: String(localized: "ai_setup_needs_service_title"),
                value: String(localized: "ai_setup_configure_action"),
                trailing: "chevron.right"
            ) {
                editor.selectProvider(providerID)
                providerTarget = TVAIProviderTarget(id: providerID)
            }
        case .relayTakesPriority:
            TVAIDivider()
            TVAINoteRow(
                icon: "checkmark.seal.fill",
                tint: TVColor.ok,
                text: String(localized: "ai_setup_relay_first_detail")
            )
            TVAIActionRow(
                icon: "arrow.left.arrow.right",
                title: String(localized: "ai_setup_relay_first_title"),
                value: String(localized: "ai_setup_use_own_service"),
                trailing: "chevron.right"
            ) {
                editor.primuseRelayBinding.wrappedValue = false
            }
        }
    }

    private var relayTestValue: String {
        switch editor.primuseRelayConnectionPresentation {
        case .notTested: return ""
        default: return editor.primuseRelayConnectionTitle
        }
    }

    private var relayIcon: String {
        switch editor.primuseRelayConnectionPresentation {
        case .notTested: return "questionmark.circle"
        case .testing: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .degraded: return "arrow.down.right.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var relayTint: Color {
        switch editor.primuseRelayConnectionPresentation {
        case .success: return TVColor.ok
        case .degraded: return TVColor.warn
        case .failure: return TVColor.bad
        case .notTested, .testing: return TVColor.textMuted
        }
    }

    // MARK: - 能力开关

    private var capabilitySection: some View {
        TVAISection(title: String(localized: "ai_capability_section")) {
            TVAIToggleRow(
                icon: "magnifyingglass",
                title: String(localized: "ai_enable_semantic_search"),
                isOn: editor.semanticSearchBinding
            )
            if editor.semanticSearchEnabled {
                TVAIDivider()
                routeRow(.semanticSearch)
            }
            TVAIDivider()
            TVAIToggleRow(
                icon: "wand.and.stars",
                title: String(localized: "ai_enable_recommendations"),
                isOn: editor.recommendationsBinding
            )
            if editor.recommendationsEnabled {
                TVAIDivider()
                routeRow(.recommendations)
            }
            TVAIDivider()
            // 和播放页「歌词翻译」面板里的翻译方式是同一个设置;打开后在这里选由谁翻。
            TVAIToggleRow(
                icon: "character.bubble",
                title: String(localized: "lyrics_translation_use_smart"),
                isOn: smartLyricsTranslationBinding
            )
            .accessibilityIdentifier("tv.ai.lyricsTranslation")
            if smartLyricsTranslationBinding.wrappedValue {
                TVAIDivider()
                routeRow(.lyricsTranslation)
            }
            TVAIDivider()
            // 和设置页「罗马音 › 生成方式」是同一个设置;打开后在这里选由谁生成。
            TVAIToggleRow(
                icon: "textformat.abc",
                title: String(localized: "lyrics_romanization_use_intelligent"),
                isOn: smartLyricsRomanizationBinding
            )
            .accessibilityIdentifier("tv.ai.lyricsRomanization")
            if smartLyricsRomanizationBinding.wrappedValue {
                TVAIDivider()
                routeRow(.lyricsRomanization)
            }
            TVAIDivider()
            // 遥控器上按一下换到下一档:混合 → 歌曲 → 专辑。
            TVAIActionRow(
                icon: "square.stack",
                title: String(localized: "ai_recommendation_unit"),
                value: recommendationUnit.localizedTitle,
                trailing: "arrow.triangle.2.circlepath"
            ) {
                recommendationUnitRawValue = recommendationUnit.next.rawValue
            }
            .accessibilityIdentifier("tv.ai.recommendationUnit")
            TVAIDivider()
            // 遥控器上按一下换到下一档:自动 → 实时 → 每小时 → 每 6 小时 → 每天。
            TVAIActionRow(
                icon: "clock.arrow.circlepath",
                title: String(localized: "ai_recommendation_refresh_interval"),
                value: recommendationRefresh.displayTitle(
                    automatic: intelligence.automaticRecommendationRefreshInterval
                ),
                trailing: "arrow.triangle.2.circlepath"
            ) {
                recommendationRefreshRawValue = recommendationRefresh.next.rawValue
            }
            .accessibilityIdentifier("tv.ai.recommendationRefresh")
        }
    }

    /// 打开 = 自动生成罗马音并交给智能功能;关掉 = 改回本机生成(自动生成本身不关)。
    private var smartLyricsRomanizationBinding: Binding<Bool> {
        let settings = LyricsRomanizationSettingsStore.shared
        return Binding(
            get: { settings.isAutoGenerationEnabled && settings.method == .intelligent },
            set: { on in
                if on {
                    settings.isAutoGenerationEnabled = true
                    settings.method = .intelligent
                } else if settings.method == .intelligent {
                    settings.method = .local
                }
            }
        )
    }

    private var smartLyricsTranslationBinding: Binding<Bool> {
        let settings = LyricsTranslationSettingsStore.shared
        return Binding(
            get: { settings.isEnabled && settings.mode == .intelligentWithSystemFallback },
            set: { on in
                if on {
                    if !settings.isEnabled {
                        settings.targetLanguageCode = LyricsTranslationSettingsStore.target(
                            settings.targetLanguageCode,
                            within: LyricsTranslationSettingsStore.tvTargetLanguages(intelligent: true)
                        )
                    }
                    settings.mode = .intelligentWithSystemFallback
                    settings.isEnabled = true
                } else {
                    // 只是不再交给智能服务:歌词翻译照开,改用离线翻译包。
                    settings.targetLanguageCode = LyricsTranslationSettingsStore.target(
                        settings.targetLanguageCode,
                        within: LyricsTranslationSettingsStore.tvTargetLanguages(intelligent: false)
                    )
                    settings.mode = .system
                }
            }
        )
    }

    private var recommendationUnit: AIRecommendationUnit {
        .stored(recommendationUnitRawValue)
    }

    private var recommendationRefresh: AIRecommendationRefreshInterval {
        .stored(recommendationRefreshRawValue)
    }

    /// 开关下面的「由谁处理」:跟随默认、内置 AI,或自己某项服务的某个模型。
    private func routeRow(_ feature: AIFeature) -> some View {
        TVAIActionRow(
            icon: "arrow.triangle.branch",
            title: String(localized: "ai_route_label"),
            subtitle: editor.routeNote(for: feature),
            value: editor.routeTitle(for: feature),
            trailing: "chevron.right"
        ) {
            routeTarget = TVAIRouteTarget(feature: feature)
        }
        .accessibilityIdentifier("tv.ai.route.\(feature.rawValue)")
    }

    // MARK: - 服务商

    private var providerSection: some View {
        TVAISection(title: String(localized: "ai_provider_list_section")) {
            ForEach(editor.draftProviderSet.providers) { provider in
                TVAIActionRow(
                    icon: editor.defaultEngine == .provider(provider.id)
                        ? "star.fill" : "server.rack",
                    title: provider.displayName.isEmpty
                        ? String(localized: "ai_provider_default_name")
                        : provider.displayName,
                    subtitle: provider.baseURL,
                    value: providerStatusText(provider),
                    trailing: "chevron.right"
                ) {
                    editor.selectProvider(provider.id)
                    providerTarget = TVAIProviderTarget(id: provider.id)
                }
                TVAIDivider()
            }
            TVAIToggleRow(
                icon: "arrow.uturn.down",
                title: String(localized: "ai_fallback_enabled"),
                isOn: editor.fallbackBinding
            )
            TVAIDivider()
            TVAIActionRow(
                icon: "plus",
                title: String(localized: "ai_add_provider"),
                trailing: "chevron.right"
            ) {
                editor.addProvider()
                providerTarget = TVAIProviderTarget(id: editor.selectedProviderID)
            }
        }
    }

    /// 服务行右侧的一句状态:还缺密钥或模型时先说缺什么,其余标出主服务或启用 / 停用。
    private func providerStatusText(_ provider: AIRemoteProviderConfiguration) -> String {
        let isPrimary = editor.defaultEngine == .provider(provider.id)
        if let state = editor.setupState(for: provider),
           state == .needsAPIKey || state == .needsModel {
            return isPrimary
                ? "\(String(localized: "ai_primary_provider")) · \(state.localizedTitle)"
                : state.localizedTitle
        }
        if isPrimary {
            return String(localized: "ai_primary_provider")
        }
        return provider.isEnabled
            ? PMString("ext.tv.sources.status.enabled")
            : PMString("ext.tv.sources.status.disabled")
    }

    // MARK: - 隐私

    private var privacySection: some View {
        TVAISection(title: String(localized: "ai_privacy_section")) {
            TVAIToggleRow(
                icon: "hand.raised.fill",
                title: String(localized: "ai_remote_consent"),
                isOn: editor.consentBinding
            )
            TVAIDivider()
            TVAIToggleRow(
                icon: "waveform.badge.magnifyingglass",
                title: String(localized: "ai_listening_context_consent"),
                isOn: editor.listeningContextConsentBinding
            )
            if PrimuseAIRelayClient.isSupportedOnCurrentDevice {
                TVAIDivider()
                TVAIActionRow(
                    icon: "sparkles",
                    title: String(localized: "ai_consent_privacy_row"),
                    value: String(localized: intelligence.settingsStore.hasBuiltInAIConsent
                                  ? "ai_consent_status_agreed"
                                  : "ai_consent_status_not_agreed"),
                    trailing: "chevron.right"
                ) {
                    editor.pendingBuiltInConsent = BuiltInAIConsentRequest()
                }
            }
        }
    }

    // MARK: - 右栏说明

    private var sideNotes: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: editor.primuseRelayEnabled ? "sparkles" : "key.horizontal")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TVColor.brand)
                    .frame(width: 60, height: 60)
                    .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: summaryTitle).tvFont(.cardTitle)
                    Text(verbatim: summaryDetail)
                        .tvFont(.meta).foregroundStyle(TVColor.textMuted)
                        .lineLimit(3)
                }
            }
            TVAIDivider()
            Text("ai_primuse_relay_footer").tvFont(.meta).foregroundStyle(TVColor.textFaint)
            Text(verbatim: editor.serviceListFooterText)
                .tvFont(.meta).foregroundStyle(TVColor.textFaint)
            Text("ai_privacy_footer").tvFont(.meta).foregroundStyle(TVColor.textFaint)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvPanel(radius: 20)
    }

    private var summaryTitle: String {
        if editor.primuseRelayEnabled {
            return String(localized: "ai_primuse_relay_name")
        }
        let name = editor.draftProviderSet.primaryProvider.displayName
        return name.isEmpty ? String(localized: "ai_provider_default_name") : name
    }

    private var summaryDetail: String {
        switch editor.status {
        case .saving: return String(localized: "ai_saving_changes")
        case .saved: return String(localized: "ai_settings_saved")
        case .connectionSucceeded: return String(localized: "ai_connection_success")
        case .failed(let message, _): return message
        default:
            if editor.primuseRelayEnabled { return editor.primuseRelayConnectionTitle }
            return String(
                format: String(localized: "ai_provider_count_format"),
                editor.draftProviderSet.providers.count
            )
        }
    }
}

// MARK: - 由谁处理

/// 一个功能交给谁:一屏列出跟随默认、内置 AI 与各服务的各个模型,选中即返回。
private struct TVAIRoutePickerView: View {
    let editor: AISettingsEditorModel
    let feature: AIFeature
    @Environment(\.dismiss) private var dismiss
    /// 这一页盖在设置页上面,改选内置 AI 要先同意时同意页从这里弹出。
    @State private var builtInConsent: BuiltInAIConsentRequest?

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ai_route_label").tvFont(.pageTitle)
                            Text(verbatim: feature.localizedTitle)
                                .tvFont(.body).foregroundStyle(TVColor.textMuted)
                        }
                        Spacer(minLength: 0)
                        TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
                    }
                    .padding(.bottom, 28)

                    TVAISection(title: String(localized: "ai_default_engine_label")) {
                        choiceRow(
                            icon: "arrow.uturn.backward",
                            title: String(
                                format: String(localized: "ai_route_follow_default_format"),
                                editor.defaultEngineTitle
                            ),
                            isSelected: editor.route(for: feature) == nil
                        ) {
                            editor.setRoute(nil, for: feature)
                        }
                        if PrimuseAIRelayClient.isSupportedOnCurrentDevice {
                            TVAIDivider()
                            choiceRow(
                                icon: "sparkles",
                                title: String(localized: "ai_settings_engine_builtin"),
                                isSelected: editor.route(for: feature) == .builtIn
                            ) {
                                chooseBuiltIn()
                            }
                        }
                    }

                    ForEach(editor.routableProviders) { provider in
                        TVAISection(title: editor.providerTitle(provider)) {
                            let models = editor.routeModels(for: provider, feature: feature)
                            if models.isEmpty {
                                TVAINoteRow(
                                    icon: "info.circle",
                                    tint: TVColor.textFaint,
                                    text: String(localized: "ai_route_no_model")
                                )
                            }
                            ForEach(Array(models.enumerated()), id: \.element) { index, model in
                                if index > 0 { TVAIDivider() }
                                choiceRow(
                                    icon: "cpu",
                                    title: modelTitle(model, of: provider),
                                    isSelected: editor.isRouted(feature, to: provider, model: model)
                                ) {
                                    editor.route(feature, to: provider, model: model)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
            }
        }
        .foregroundStyle(TVColor.text)
        .onExitCommand { dismiss() }
        .builtInAIConsentSheet($builtInConsent)
    }

    private func chooseBuiltIn() {
        guard editor.needsBuiltInConsentBeforeChoosing else {
            editor.setRoute(.builtIn, for: feature)
            return
        }
        builtInConsent = BuiltInAIConsentRequest { [editor, feature] in
            editor.setRoute(.builtIn, for: feature)
        }
    }

    private func choiceRow(
        icon: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        TVAIActionRow(
            icon: icon,
            title: title,
            trailing: isSelected ? "checkmark" : "circle",
            tint: isSelected ? TVColor.brand : TVColor.text
        ) {
            action()
            dismiss()
        }
    }

    private func modelTitle(_ model: String, of provider: AIRemoteProviderConfiguration) -> String {
        guard model == provider.generationModel.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return model
        }
        return String(format: String(localized: "ai_route_default_model_format"), model)
    }
}

// MARK: - 服务商详情

/// 单个服务商的地址 / 密钥 / 模型 / 次序。电视上这些字段一屏放不下,拆成左右两栏:
/// 左边是需要输入的表单,右边是不需要键盘的动作(测试、设为主服务、排序、删除)。
struct TVAIProviderDetailView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss

    let editor: AISettingsEditorModel
    let providerID: UUID

    @State private var showsRemoveConfirmation = false

    private var provider: AIRemoteProviderConfiguration? {
        editor.draftProviderSet.providers.first { $0.id == providerID }
    }

    /// 「默认」指不开内置 AI 时直接用它,和手机、Mac 的「默认使用」一致。
    private var isPrimary: Bool {
        editor.defaultEngine == .provider(providerID)
    }

    private var providerTitle: String {
        let name = provider?.displayName ?? ""
        return name.isEmpty ? String(localized: "ai_provider_default_name") : name
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    HStack(alignment: .top, spacing: 40) {
                        VStack(alignment: .leading, spacing: 0) {
                            endpointSection
                            modelSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 0) {
                            actionSection
                        }
                        .frame(width: 520, alignment: .leading)
                        .focusSection()
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
            }

            if showsRemoveConfirmation {
                removeConfirmation
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .foregroundStyle(TVColor.text)
        .animation(.easeInOut(duration: 0.2), value: showsRemoveConfirmation)
        .onExitCommand {
            if showsRemoveConfirmation {
                showsRemoveConfirmation = false
            } else {
                dismiss()
            }
        }
        .accessibilityIdentifier("tv.ai.provider.detail")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                TVEyebrow(text: String(localized: "ai_settings_title"))
                Text(verbatim: providerTitle).tvFont(.pageTitle)
            }
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
        }
        .padding(.bottom, 28)
    }

    // MARK: 地址与密钥

    private var endpointSection: some View {
        TVAISection(title: String(localized: "ai_provider_detail_section")) {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4),
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(visiblePresets, id: \.self) { preset in
                        TVAIChoiceChip(
                            title: preset.localizedTitle,
                            isSelected: editor.selectedProviderPreset == preset
                        ) {
                            editor.applyProviderPreset(preset)
                        }
                    }
                }

                if editor.selectedProviderPreset == .custom {
                    TVFormField(
                        label: String(localized: "ai_provider_name"),
                        text: editor.configurationBinding(\.displayName)
                    )
                    TVFormField(
                        label: String(localized: "ai_base_url"),
                        text: editor.configurationBinding(
                            \.baseURL,
                            clearModels: true,
                            updatesProviderPreset: true
                        ),
                        mono: true
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ai_compatibility_mode").tvFont(.caption).foregroundStyle(TVColor.textFaint)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2),
                            alignment: .leading,
                            spacing: 14
                        ) {
                            ForEach(AIProviderCompatibilityMode.allCases, id: \.self) { mode in
                                TVAIChoiceChip(
                                    title: mode.localizedTitle,
                                    isSelected: editor.compatibilityModeBinding.wrappedValue == mode
                                ) {
                                    editor.compatibilityModeBinding.wrappedValue = mode
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ai_service_address").tvFont(.caption).foregroundStyle(TVColor.textFaint)
                        Text(verbatim: editor.draftConfiguration.baseURL)
                            .tvFont(.caption).monospaced()
                            .foregroundStyle(TVColor.textMuted)
                            .lineLimit(2)
                    }
                }

                TVFormField(
                    label: editor.apiKeyTitle,
                    text: editor.apiKeyBinding,
                    secure: true
                )
                if editor.hasStoredAPIKeyForDraft && editor.apiKeyDraft.isEmpty {
                    TVAINoteRow(
                        icon: "checkmark.shield",
                        tint: TVColor.ok,
                        text: String(localized: "ai_api_key_stored"),
                        inset: false
                    )
                }
                TVSwitchRow(
                    icon: "lock.open",
                    title: String(localized: "ai_allow_insecure_local_http"),
                    isOn: editor.configurationBinding(
                        \.allowInsecureLocalHTTP,
                        clearModels: true,
                        autoSaveDelayNanoseconds: 0
                    ),
                    maxWidth: .infinity
                )
                Text(verbatim: editor.providerFooterText)
                    .tvFont(.meta).foregroundStyle(TVColor.textFaint)
            }
            .padding(24)
        }
    }

    private var visiblePresets: [AIProviderPreset] {
        var presets = [AIProviderPreset.custom]
        presets.append(contentsOf: AIProviderPreset.catalog(
            for: intelligence.regionAvailability.context.region
        ))
        return presets
    }

    // MARK: 模型

    private var modelSection: some View {
        TVAISection(title: String(localized: "ai_models_section")) {
            VStack(alignment: .leading, spacing: 20) {
                TVFormField(
                    label: String(localized: "ai_generation_model"),
                    text: editor.configurationBinding(\.generationModel),
                    mono: true
                )
                if editor.draftConfiguration.supportsEmbeddings {
                    TVFormField(
                        label: String(localized: "ai_embedding_model"),
                        text: editor.configurationBinding(\.embeddingModel),
                        mono: true
                    )
                } else {
                    TVAINoteRow(
                        icon: "info.circle",
                        tint: TVColor.textMuted,
                        text: String(localized: "ai_embedding_unsupported"),
                        inset: false
                    )
                }

                TVPillButton(
                    title: String(localized: "ai_fetch_models"),
                    systemImage: editor.isFetchingModels
                        ? "arrow.triangle.2.circlepath" : "square.and.arrow.down"
                ) {
                    Task { await editor.fetchModels(using: intelligence) }
                }
                .disabled(!editor.canFetchModels)

                if !editor.availableModels.isEmpty {
                    // 拉回来的模型名在电视上没法手打,点一下直接填进生成模型一栏。
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(editor.availableModels) { model in
                            TVAIChoiceChip(
                                title: model.id,
                                isSelected: editor.draftConfiguration.generationModel == model.id
                            ) {
                                editor.configurationBinding(\.generationModel).wrappedValue = model.id
                            }
                        }
                    }
                }
                if let status = modelStatusText {
                    Text(verbatim: status).tvFont(.meta).foregroundStyle(TVColor.textMuted)
                }
            }
            .padding(24)
        }
    }

    private var modelStatusText: String? {
        switch editor.status {
        case .modelsLoaded(let count):
            return String(format: String(localized: "ai_models_loaded_format"), count)
        case .modelsEmpty:
            return String(localized: "ai_models_empty")
        case .failed(let message, .models):
            return message
        default:
            return nil
        }
    }

    // MARK: 动作

    private var actionSection: some View {
        TVAISection(title: String(localized: "ai_provider_actions")) {
            // 分成两组只是为了绕开 ViewBuilder 的 10 个子视图上限,视觉上仍是一列。
            Group {
                TVAIActionRow(
                    icon: "network",
                    title: String(localized: "ai_test_connection"),
                    value: connectionStatusText,
                    trailing: "chevron.right",
                    isEnabled: editor.canTestConnection
                ) {
                    Task { await editor.testConnection(using: intelligence) }
                }
                TVAIDivider()
                TVAIToggleRow(
                    icon: "power",
                    title: String(localized: "enable"),
                    isOn: editor.providerEnabledBinding(providerID)
                )
                TVAIDivider()
                TVAIActionRow(
                    icon: "star",
                    title: String(localized: "ai_set_primary"),
                    value: isPrimary ? String(localized: "ai_primary_provider") : "",
                    trailing: "chevron.right",
                    isEnabled: !isPrimary
                ) {
                    editor.chooseDefaultEngine(.provider(providerID))
                }
            }
            Group {
                if editor.hasStoredAPIKeyForDraft {
                    TVAIDivider()
                    TVAIActionRow(
                        icon: "key.slash",
                        title: String(localized: "ai_delete_current_api_key"),
                        trailing: "chevron.right",
                        tint: TVColor.bad,
                        isEnabled: !editor.isWorking && !editor.isFetchingModels
                    ) {
                        Task { await editor.deleteCurrentAPIKey(using: intelligence) }
                    }
                }
                if editor.draftProviderSet.providers.count > 1 {
                    TVAIDivider()
                    TVAIActionRow(
                        icon: "trash",
                        title: String(localized: "ai_remove_provider"),
                        trailing: "chevron.right",
                        tint: TVColor.bad
                    ) {
                        editor.selectProvider(providerID)
                        showsRemoveConfirmation = true
                    }
                }
                TVAIDivider()
                TVAINoteRow(
                    icon: "icloud",
                    tint: TVColor.textMuted,
                    text: String(localized: "ai_key_sync_footer")
                )
            }
        }
    }

    private var connectionStatusText: String {
        switch editor.status {
        case .saving: return String(localized: "ai_saving_changes")
        case .saved: return String(localized: "ai_settings_saved")
        case .connectionSucceeded: return String(localized: "ai_connection_success")
        case .failed(let message, .settings): return message
        default: return ""
        }
    }

    /// 删除确认走自绘卡片 —— 电视端弹框统一是「压暗背景 + 居中面板」,
    /// 系统的 confirmationDialog 在 tvOS 上是另一套观感。
    private var removeConfirmation: some View {
        ZStack {
            TVColor.bg.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("ai_remove_provider_confirm").tvFont(.sectionTitle)
                HStack(spacing: 18) {
                    TVPillButton(
                        title: String(localized: "ai_remove_provider"),
                        systemImage: "trash",
                        style: .solid
                    ) {
                        showsRemoveConfirmation = false
                        editor.removeSelectedProvider()
                        dismiss()
                    }
                    TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") {
                        showsRemoveConfirmation = false
                    }
                }
            }
            .padding(36)
            .frame(width: 780, alignment: .leading)
            .tvPanel(radius: 22)
        }
    }
}

// MARK: - 面板行
//
// 下面几种面板行也给「刮削」设置页用(TVScraperSettingsView),两页保持同一套样式。

/// 分组标题 + 一块面板,与 `TVSettingsView` 的分组视觉保持一致。
/// 输入 AI 额度兑换码(电视)。兑换逻辑和文案与手机、Mac 的 `BuiltInAIRedeemSheet`
/// 共用(`MusicIntelligenceService.redeemBuiltInAICode`、`BuiltInAIRedeemText`);
/// 输入框沿用信源表单的 `TVFormField`,用遥控器的系统键盘输入。
struct TVAIRedeemCodeView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isRedeeming = false
    @State private var redemption: AIRedeemCode.Redemption?
    @State private var errorMessage: String?

    private var isWellFormed: Bool { AIRedeemCode.normalized(code) != nil }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    TVAISection(title: String(localized: "ai_redeem_code_field")) {
                        if let redemption {
                            TVAINoteRow(
                                icon: "checkmark.seal.fill",
                                tint: TVColor.ok,
                                text: BuiltInAIRedeemText.success(redemption)
                            )
                        } else {
                            TVFormField(
                                label: String(localized: "ai_redeem_code_format"),
                                text: $code,
                                mono: true,
                                autofocus: true
                            )
                            .padding(.horizontal, 22)
                            .padding(.vertical, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if let errorMessage {
                                TVAIDivider()
                                TVAINoteRow(icon: "exclamationmark.triangle.fill", tint: TVColor.warn, text: errorMessage)
                            }
                            TVAIDivider()
                            TVAIActionRow(
                                icon: isRedeeming ? "hourglass" : "ticket",
                                title: isRedeeming
                                    ? String(localized: "ai_redeem_in_progress")
                                    : String(localized: "ai_redeem_action"),
                                isEnabled: !isRedeeming && isWellFormed,
                                action: redeem
                            )
                        }
                        TVAIDivider()
                        TVAINoteRow(icon: "info.circle", tint: TVColor.textMuted, text: String(localized: "ai_redeem_code_footer"))
                    }
                    .frame(maxWidth: 1100, alignment: .leading)
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
            }
        }
        .foregroundStyle(TVColor.text)
        .onChange(of: code) { _, newValue in
            let cleaned = AIRedeemCode.editingText(newValue)
            if cleaned != newValue { code = cleaned }
            errorMessage = nil
        }
        .onExitCommand {
            if !isRedeeming { dismiss() }
        }
        .accessibilityIdentifier("tv.ai.redeem")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                TVEyebrow(text: String(localized: "ai_quota_section"))
                Text("ai_redeem_title").tvFont(.pageTitle)
            }
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
                .disabled(isRedeeming)
        }
        .padding(.bottom, 28)
    }

    private func redeem() {
        guard !isRedeeming, isWellFormed else { return }
        isRedeeming = true
        errorMessage = nil
        Task {
            defer { isRedeeming = false }
            do {
                redemption = try await intelligence.redeemBuiltInAICode(code)
            } catch is CancellationError {
                // 取消了系统弹窗(StoreKit 登录),不当错误显示。
            } catch {
                errorMessage = BuiltInAIRedeemText.message(for: error)
            }
        }
    }
}

struct TVAISection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).tvFont(.sectionTitle).foregroundStyle(TVColor.textMuted)
            VStack(spacing: 0, content: content).tvPanel(radius: 20)
        }
        .padding(.bottom, 34)
        .focusSection()
    }
}

struct TVAIDivider: View {
    var body: some View {
        Rectangle()
            .fill(TVColor.divider)
            .frame(height: 1)
            .padding(.leading, 80)
    }
}

@MainActor
private func tvAIIcon(_ icon: String, focused: Bool, tint: Color) -> some View {
    Image(systemName: icon)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(focused ? TVColor.onBrand : tint)
        .frame(width: 40, height: 40)
        .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surface),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
}

struct TVAIToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: { isOn.toggle() }) { focused in
            HStack(spacing: 18) {
                tvAIIcon(icon, focused: focused, tint: TVColor.text)
                Text(title).tvFont(.cardTitle, weight: focused ? .bold : .medium)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: 12)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? AnyShapeStyle(TVColor.brand)
                                        : AnyShapeStyle(TVColor.surfaceStrong))
                        .frame(width: 62, height: 34)
                    Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                }
                .animation(.easeOut(duration: 0.18), value: isOn)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : .clear)
            .accessibilityValue(Text(isOn
                ? PMString("ext.tv.sources.status.enabled")
                : PMString("ext.tv.sources.status.disabled")))
        }
    }
}

struct TVAIActionRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String = ""
    var trailing: String = "chevron.right"
    var tint: Color = TVColor.text
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: action) { focused in
            HStack(spacing: 18) {
                tvAIIcon(icon, focused: focused, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).tvFont(.cardTitle, weight: focused ? .bold : .medium)
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle).tvFont(.meta).foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                if !value.isEmpty {
                    Text(verbatim: value).tvFont(.eyebrow, weight: .regular)
                        .foregroundStyle(TVColor.textMuted)
                        .multilineTextAlignment(.trailing).lineLimit(2)
                }
                Image(systemName: trailing).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(focused ? TVColor.text : TVColor.textGhost)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : .clear)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .disabled(!isEnabled)
    }
}

/// 不可聚焦的说明行(状态、提示)。
struct TVAINoteRow: View {
    let icon: String
    let tint: Color
    let text: String
    var inset: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, alignment: .center)
            Text(verbatim: text).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, inset ? 22 : 0)
        .padding(.vertical, inset ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 额度的一行(只读):功能名、还剩几次、用量条,第二行是本月次数和加量。
private struct TVAIQuotaRow: View {
    let title: String
    let counter: BuiltInAIQuotaCounter
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(verbatim: title).tvFont(.cardTitle, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text(verbatim: BuiltInAIQuotaText.remaining(counter))
                    .tvFont(.eyebrow, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(counter.isExhausted ? TVColor.bad : TVColor.textMuted)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(TVColor.surface)
                    Capsule().fill(counter.isExhausted ? AnyShapeStyle(TVColor.bad) : AnyShapeStyle(TVColor.brand))
                        .frame(width: proxy.size.width * counter.fractionUsed)
                }
            }
            .frame(height: 6)
            if let detail {
                Text(verbatim: detail).tvFont(.meta).foregroundStyle(TVColor.textFaint)
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 单选小药丸:预设、兼容模式、模型名共用。
private struct TVAIChoiceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        TVFocusButton(radius: 12, scale: 1.04, lift: 4, action: action) { focused in
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .bold))
                }
                Text(verbatim: title).tvFont(.caption, weight: .semibold).lineLimit(1)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? TVColor.onBrand : TVColor.text)
            .background(isSelected
                        ? AnyShapeStyle(TVColor.brand)
                        : AnyShapeStyle(focused ? TVColor.surfaceStrong : TVColor.surface),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
#endif
