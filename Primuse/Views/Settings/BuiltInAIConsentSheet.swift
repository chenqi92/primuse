import PrimuseKit
import SwiftUI

/// 一次「先问过再用内置 AI」:同意后接着做 `onAgree`(把刚才那一下选择做完、
/// 接着发起刚才点的功能)。已经同意过时弹出来的是说明页,可以撤回。
struct BuiltInAIConsentRequest: Identifiable {
    let id = UUID()
    let onAgree: @MainActor () -> Void

    init(onAgree: @escaping @MainActor () -> Void = {}) {
        self.onAgree = onAgree
    }
}

extension View {
    /// 挂在触发「用内置 AI」的页面上:`request` 有值时弹出同意页。
    func builtInAIConsentSheet(_ request: Binding<BuiltInAIConsentRequest?>) -> some View {
        modifier(BuiltInAIConsentPresenter(request: request))
    }
}

private struct BuiltInAIConsentPresenter: ViewModifier {
    @Binding var request: BuiltInAIConsentRequest?
    @Environment(MusicIntelligenceService.self) private var intelligence

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(item: $request) { request in
            BuiltInAIConsentSheet(request: request, intelligence: intelligence)
        }
        #else
        content.sheet(item: $request) { request in
            BuiltInAIConsentSheet(request: request, intelligence: intelligence)
        }
        #endif
    }
}

/// 同意页上写的内容。三条要点先说清楚「为什么要问、发了什么、怎么收回」,
/// 各功能具体发什么收在下面,想看再展开,不一上来就是一长串。
enum BuiltInAIConsentContent {
    struct Point: Identifiable {
        let id: String
        let systemImage: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
    }

    struct Item: Identifiable {
        let id: String
        let systemImage: String
        let title: String
        let detail: LocalizedStringResource
        /// 除了这一页,还要在隐私里单独允许(听歌偏好、上传音频)。
        let needsSeparatePermission: Bool
    }

    static var points: [Point] {
        [
        Point(
            id: "minimal",
            systemImage: "text.badge.checkmark",
            title: "ai_consent_point_minimal_title",
            detail: "ai_consent_point_minimal_detail"
        ),
        Point(
            id: "retention",
            systemImage: "server.rack",
            title: "ai_consent_point_retention_title",
            detail: "ai_consent_point_retention_detail"
        ),
        Point(
            id: "control",
            systemImage: "hand.raised",
            title: "ai_consent_point_control_title",
            detail: "ai_consent_point_control_detail"
        ),
        ]
    }

    /// 打开对应功能后会自己发的。
    static var automaticItems: [Item] {
        [
            item(.listeningIntents, "rectangle.stack", "ai_consent_data_listening_intents"),
            item(.semanticSearch, "magnifyingglass", "ai_consent_data_semantic_search"),
            item(.lyricsTranslation, "character.bubble", "ai_consent_data_lyrics_translation"),
            item(.recommendations, "wand.and.stars", "ai_consent_data_recommendations", separate: true),
            item(.listeningMood, "chart.bar", "ai_consent_data_listening_mood", separate: true),
        ]
    }

    /// 用户点了按钮才发的。
    static var onTapItems: [Item] {
        var items = [
            item(.tagCleanup, "tag", "ai_consent_data_tag_cleanup"),
            item(.songDiscovery, "music.note.list", "ai_consent_data_song_discovery"),
            item(.libraryInsight, "text.book.closed", "ai_consent_data_library_insight"),
        ]
        #if !os(tvOS)
        items.append(Item(
            id: "transcription",
            systemImage: "waveform",
            title: String(localized: "lyrics_transcription_settings_title"),
            detail: "ai_consent_data_transcription",
            needsSeparatePermission: true
        ))
        #endif
        return items
    }

    private static func item(
        _ feature: AIFeature,
        _ systemImage: String,
        _ detail: LocalizedStringResource,
        separate: Bool = false
    ) -> Item {
        Item(
            id: feature.rawValue,
            systemImage: systemImage,
            title: feature.localizedTitle,
            detail: detail,
            needsSeparatePermission: separate
        )
    }
}

/// 内置 AI 同意页。还没同意时是「同意并使用 / 暂不使用」,已经同意过再打开是说明页,
/// 可以撤回。语气要让人看得懂、不害怕:先讲为什么要问,再讲只发一点、服务器不留、
/// 随时能收回,细节折起来。
struct BuiltInAIConsentSheet: View {
    let request: BuiltInAIConsentRequest
    let intelligence: MusicIntelligenceService

    @Environment(\.dismiss) private var dismiss
    /// 打开时就定下来:点同意之后不要在关掉的动画里变成说明页。
    @State private var reviewing: Bool
    @State private var showsDetails = false
    @State private var saveFailed = false

    init(request: BuiltInAIConsentRequest, intelligence: MusicIntelligenceService) {
        self.request = request
        self.intelligence = intelligence
        _reviewing = State(initialValue: intelligence.settingsStore.hasBuiltInAIConsent)
    }

    private func agree() {
        do {
            try intelligence.acceptBuiltInAIConsent()
        } catch {
            saveFailed = true
            return
        }
        let onAgree = request.onAgree
        dismiss()
        onAgree()
    }

    private func withdraw() {
        intelligence.withdrawBuiltInAIConsent()
        dismiss()
    }

    #if os(tvOS)
    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.35)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 22) {
                        Image(systemName: reviewing ? "checkmark.shield" : "sparkles")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(TVColor.onBrand)
                            .frame(width: 76, height: 76)
                            .background(TVColor.brand, in: Circle())
                        Text("ai_consent_title")
                            .tvFont(.sectionTitle)
                            .foregroundStyle(TVColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("ai_consent_lead")
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(BuiltInAIConsentContent.points) { point in
                            HStack(alignment: .top, spacing: 18) {
                                Image(systemName: point.systemImage)
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(TVColor.brand)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(point.title)
                                        .tvFont(.rowTitle, weight: .semibold)
                                        .foregroundStyle(TVColor.text)
                                    Text(point.detail)
                                        .tvFont(.meta)
                                        .foregroundStyle(TVColor.textMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if saveFailed {
                        Text("ai_consent_save_failed")
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.warn)
                    }
                    HStack(spacing: 18) {
                        if reviewing {
                            TVPillButton(title: String(localized: "done"), systemImage: "checkmark", style: .solid) {
                                dismiss()
                            }
                            TVPillButton(
                                title: String(localized: "ai_consent_withdraw"),
                                systemImage: "arrow.uturn.backward",
                                action: withdraw
                            )
                        } else {
                            TVPillButton(
                                title: String(localized: "ai_consent_agree"),
                                systemImage: "checkmark",
                                style: .solid,
                                action: agree
                            )
                            TVPillButton(title: String(localized: "ai_consent_decline"), systemImage: "xmark") {
                                dismiss()
                            }
                        }
                    }
                    Text("ai_consent_sync_note")
                        .tvFont(.meta)
                        .foregroundStyle(TVColor.textFaint)
                }
                .frame(width: 720, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    Text("ai_consent_details_title")
                        .tvFont(.rowTitle, weight: .semibold)
                        .foregroundStyle(TVColor.text)
                    tvGroup("ai_consent_group_automatic", BuiltInAIConsentContent.automaticItems)
                    tvGroup("ai_consent_group_on_tap", BuiltInAIConsentContent.onTapItems)
                }
                .frame(width: 620, alignment: .leading)
            }
            .padding(48)
            .frame(maxHeight: 900)
            .tvPanel(radius: 26)
        }
        .onExitCommand { dismiss() }
    }

    private func tvGroup(_ title: LocalizedStringResource, _ items: [BuiltInAIConsentContent.Item]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .tvFont(.eyebrow, weight: .semibold)
                .foregroundStyle(TVColor.textFaint)
                .padding(.top, 6)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(TVColor.textMuted)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title)
                            .tvFont(.meta, weight: .semibold)
                            .foregroundStyle(TVColor.text)
                        Text(item.detail)
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.needsSeparatePermission {
                            Text("ai_consent_separate_permission")
                                .tvFont(.meta)
                                .foregroundStyle(TVColor.textFaint)
                        }
                    }
                }
            }
        }
    }
    #else
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                pointsCard
                detailsCard
                Text("ai_consent_sync_note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        #if os(macOS)
        .frame(width: 500, height: 640)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .accessibilityIdentifier("ai.consent")
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: reviewing ? "checkmark.shield" : "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text("ai_consent_title")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("ai_consent_lead")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var pointsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(BuiltInAIConsentContent.points) { point in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: point.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.title)
                            .font(.subheadline.weight(.semibold))
                        Text(point.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showsDetails.toggle() }
            } label: {
                HStack {
                    Text("ai_consent_details_title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsDetails ? 180 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ai.consent.details")

            if showsDetails {
                VStack(alignment: .leading, spacing: 14) {
                    detailGroup("ai_consent_group_automatic", BuiltInAIConsentContent.automaticItems)
                    detailGroup("ai_consent_group_on_tap", BuiltInAIConsentContent.onTapItems)
                }
                .padding([.horizontal, .bottom], 16)
                .transition(.opacity)
            }
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func detailGroup(
        _ title: LocalizedStringResource,
        _ items: [BuiltInAIConsentContent.Item]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.title)
                            .font(.footnote.weight(.semibold))
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.needsSeparatePermission {
                            Text("ai_consent_separate_permission")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                                .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if saveFailed {
                Text("ai_consent_save_failed")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            if reviewing {
                Button {
                    dismiss()
                } label: {
                    Text("done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .prominentLabelOnAccent()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Button(role: .destructive, action: withdraw) {
                    Text("ai_consent_withdraw").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .accessibilityIdentifier("ai.consent.withdraw")
            } else {
                Button(action: agree) {
                    Text("ai_consent_agree").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .prominentLabelOnAccent()
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("ai.consent.agree")
                Button {
                    dismiss()
                } label: {
                    Text("ai_consent_decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("ai.consent.decline")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.bar)
    }

    private var cardFill: Color { Color.primary.opacity(0.05) }
    #endif
}

/// 设置页里「内置 AI 还差一步」那一行:选了内置 AI 但还没同意,点了弹同意页。
/// 在同意之前内置 AI 不发任何请求,这一行就是告诉用户为什么它还没开始工作。
struct BuiltInAIConsentPendingRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ai_consent_pending_title")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("ai_consent_pending_detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("ai_consent_pending_action")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ai.consent.pending")
    }
}
