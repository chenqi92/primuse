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

struct TVAISettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss

    @State private var editor = AISettingsEditorModel()
    @State private var providerTarget: TVAIProviderTarget?

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
        .onExitCommand { dismiss() }
        .fullScreenCover(item: $providerTarget) { target in
            TVAIProviderDetailView(editor: editor, providerID: target.id)
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
            TVAIDivider()
            TVAIToggleRow(
                icon: "wand.and.stars",
                title: String(localized: "ai_enable_recommendations"),
                isOn: editor.recommendationsBinding
            )
        }
    }

    // MARK: - 服务商

    private var providerSection: some View {
        TVAISection(title: String(localized: "ai_provider_list_section")) {
            ForEach(editor.draftProviderSet.providers) { provider in
                TVAIActionRow(
                    icon: provider.id == editor.draftProviderSet.primaryProviderID
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

    /// 服务行右侧的一句状态:主服务优先标出来,其余只说启用 / 停用。
    private func providerStatusText(_ provider: AIRemoteProviderConfiguration) -> String {
        if provider.id == editor.draftProviderSet.primaryProviderID {
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
            Text(verbatim: editor.providerListFooterText)
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

    private var providerIndex: Int? {
        editor.draftProviderSet.providers.firstIndex { $0.id == providerID }
    }

    private var isPrimary: Bool {
        editor.draftProviderSet.primaryProviderID == providerID
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
            // 分成三组只是为了绕开 ViewBuilder 的 10 个子视图上限,视觉上仍是一列。
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
                    editor.makePrimary(providerID)
                }
            }
            Group {
                TVAIDivider()
                TVAIActionRow(
                    icon: "arrow.up",
                    title: String(localized: "ai_move_up"),
                    trailing: "chevron.up",
                    isEnabled: (providerIndex ?? 0) > 0
                ) {
                    editor.moveProvider(providerID, offset: -1)
                }
                TVAIDivider()
                TVAIActionRow(
                    icon: "arrow.down",
                    title: String(localized: "ai_move_down"),
                    trailing: "chevron.down",
                    isEnabled: (providerIndex ?? 0) < editor.draftProviderSet.providers.count - 1
                ) {
                    editor.moveProvider(providerID, offset: 1)
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

/// 分组标题 + 一块面板,与 `TVSettingsView` 的分组视觉保持一致。
private struct TVAISection<Content: View>: View {
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

private struct TVAIDivider: View {
    var body: some View {
        Rectangle()
            .fill(TVColor.divider)
            .frame(height: 1)
            .padding(.leading, 80)
    }
}

private func tvAIIcon(_ icon: String, focused: Bool, tint: Color) -> some View {
    Image(systemName: icon)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(focused ? TVColor.onBrand : tint)
        .frame(width: 40, height: 40)
        .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surface),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
}

private struct TVAIToggleRow: View {
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

private struct TVAIActionRow: View {
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
private struct TVAINoteRow: View {
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
