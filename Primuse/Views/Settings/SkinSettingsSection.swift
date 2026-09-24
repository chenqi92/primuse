#if os(iOS)
import PrimuseKit
import SwiftUI

/// 外观设置里的界面皮肤区。
///
/// 皮肤改的是整套视觉词汇(配色、版式、动效,连同配套的沉浸舞台与歌词海报),与「主题色」
/// 「浅深色」是不同层级的东西,所以单列一区。导航方式(标签栏 / 自绘顶栏)现在也由皮肤
/// 决定,原来的「极简模式」开关因此并到了这里。
struct SkinSettingsSection: View {
    @Environment(SkinRuntime.self) private var runtime
    @Environment(\.skin) private var skin
    @State private var inspectedSkin: SkinDefinition?

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(runtime.catalog) { definition in
                        card(for: definition)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .listRowInsets(EdgeInsets())
            // 面板挂在这一行上,而不是整个 Section:挂在 Section 上会被套到它的每一行。
            .sheet(item: $inspectedSkin) { definition in
                SkinDetailSheet(skin: definition)
            }
        } header: {
            Text("skin_section_title")
        } footer: {
            Text(footerText)
        }
        .settingsAnchor("appearance.skin")
    }

    private var footerText: String {
        let base = String(localized: "skin_section_footer")
        let hasLocked = runtime.catalog.contains {
            runtime.availability(of: $0) == .locked
        }
        guard hasLocked else { return base }
        return base + "\n" + String(localized: "skin_locked_hint")
    }

    private func card(for definition: SkinDefinition) -> some View {
        let availability = runtime.availability(of: definition)
        let isActive = runtime.isActive(definition)

        return Button {
            if availability == .locked {
                inspectedSkin = definition
            } else {
                withAnimation(skin.animation(.selection)) {
                    _ = runtime.select(definition.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                SkinPreviewThumbnail(skin: definition)
                    .frame(width: 132, height: 176)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isActive ? Color.accentColor : Color.primary.opacity(0.1),
                                lineWidth: isActive ? 2 : 0.5
                            )
                    }
                    .overlay(alignment: .topTrailing) {
                        if availability == .locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.5), in: Circle())
                                .padding(7)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.localized(definition.nameKey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    stateLabel(availability: availability, isActive: isActive)
                }
                .frame(width: 132, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.localized(definition.nameKey))
        .accessibilityValue(
            isActive
                ? Text("skin_state_active")
                : (availability == .locked ? Text("skin_state_locked") : Text(verbatim: ""))
        )
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("appearance.skin.\(definition.id)")
    }

    @ViewBuilder
    private func stateLabel(availability: SkinAvailability, isActive: Bool) -> some View {
        if isActive {
            Label("skin_state_active", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .labelStyle(.titleAndIcon)
        } else if availability == .locked {
            Text("skin_state_locked")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // 占位:让没有状态文字的卡片与有状态文字的卡片等高。
            Text(verbatim: " ")
                .font(.caption)
                .hidden()
        }
    }

    /// 皮肤名与描述随 PrimuseKit 一起本地化(皮肤定义在那一层),要经 kit 公开的入口去取 ——
    /// kit 自己的 bundle 对 App 不可见。
    static func localized(_ key: String) -> String {
        PMString(key)
    }
}

// MARK: - 缩略预览

/// 用皮肤自己的 token 画出来的小样:底色、顶栏或标题、几行列表、底部播放条或标签栏。
/// 不是截图 —— 改了皮肤的取值,这里自然跟着变。
struct SkinPreviewThumbnail: View {
    let skin: SkinDefinition

    private var style: SkinStyle { SkinStyle(skin: skin) }

    private static let coverTints: [Color] = [
        Color(red: 0.88, green: 0.27, blue: 0.24),
        Color(red: 0.23, green: 0.56, blue: 0.47),
        Color(red: 0.36, green: 0.42, blue: 0.85),
    ]

    var body: some View {
        ZStack {
            background
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)
                VStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { index in
                        row(tint: Self.coverTints[index])
                    }
                }
                .padding(.top, 12)
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 10)
        }
        .modifier(SkinPreviewSchemeModifier(appearance: skin.appearance))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var background: some View {
        switch skin.pageBackground {
        case .canvas:
            LinearGradient(
                colors: [style.color(.canvasGlow), style.color(.canvas)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .system:
            style.color(.canvasSunken)
        }
    }

    /// 顶部按导航插槽画:经典是系统导航栏的大标题,顶部 tab 是一行 tab(选中项下带短横线)加右侧两颗图标。
    @ViewBuilder
    private var header: some View {
        switch skin.navigationHeader {
        case .classic:
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(style.color(.textPrimary))
                    .frame(width: 56, height: 9)
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        case .topTabs:
            HStack(alignment: .top, spacing: 5) {
                VStack(spacing: 2) {
                    Capsule().fill(style.color(.textPrimary)).frame(width: 16, height: 5)
                    Capsule().fill(style.color(.accent)).frame(width: 7, height: 2)
                }
                ForEach([12, 14, 11] as [CGFloat], id: \.self) { width in
                    Capsule().fill(style.color(.chromeItem)).frame(width: width, height: 5)
                }
                Spacer(minLength: 0)
                Circle().fill(style.color(.textSecondary)).frame(width: 6, height: 6)
                Circle().fill(style.color(.textSecondary)).frame(width: 6, height: 6)
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(style.color(.separator)).frame(height: 0.5).padding(.horizontal, -10)
            }
        }
    }

    private func row(tint: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(
                cornerRadius: max(2, style.rawMetric(.radiusArtwork) * 0.4),
                style: .continuous
            )
            .fill(tint)
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(style.color(.textPrimary)).frame(width: 62, height: 4).opacity(0.85)
                Capsule().fill(style.color(.textSecondary)).frame(width: 40, height: 3).opacity(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, skin.pageBackground == .system ? 6 : 0)
        .padding(.vertical, skin.pageBackground == .system ? 5 : 0)
        .background {
            if skin.pageBackground == .system {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(style.color(.canvas))
            }
        }
    }

    /// 底部:标签栏外壳画标签栏;顶部 tab 外壳按底部插槽画停靠条或悬浮胶囊。
    @ViewBuilder
    private var footer: some View {
        switch skin.navigationHeader {
        case .classic:
            tabBar
        case .topTabs:
            switch skin.bottomChrome {
            case .dockedBar:
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Self.coverTints[0])
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(style.color(.textPrimary)).frame(width: 34, height: 4).opacity(0.85)
                        Capsule().fill(style.color(.textSecondary)).frame(width: 22, height: 3).opacity(0.7)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(style.color(.textPrimary))
                    Image(systemName: "list.bullet")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(style.color(.textSecondary))
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(style.color(.chromeBackground), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .top) {
                    Capsule().fill(style.color(.accent)).frame(width: 28, height: 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 3)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(style.color(.chromeBorder), lineWidth: 0.5)
                }
                .padding(.bottom, 9)
            case .floatingCapsule:
                HStack(spacing: 5) {
                    Circle().fill(Self.coverTints[0]).frame(width: 14, height: 14)
                    Capsule().fill(style.color(.textPrimary)).frame(width: 40, height: 4).opacity(0.85)
                    Spacer(minLength: 0)
                    Circle().strokeBorder(style.color(.accent), lineWidth: 1.5).frame(width: 12, height: 12)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(style.color(.chromeBackground), in: Capsule())
                .overlay { Capsule().strokeBorder(style.color(.chromeBorder), lineWidth: 0.5) }
                .padding(.bottom, 9)
            case .classic:
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Self.coverTints[0])
                        .frame(width: 12, height: 12)
                    Capsule().fill(style.color(.textPrimary)).frame(width: 36, height: 4).opacity(0.85)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(style.color(.chromeBackground))
                .padding(.horizontal, -10)
            }
        }
    }

    private var tabBar: some View {
        HStack {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(index == 0 ? style.color(.accent) : style.color(.textTertiary))
                    .frame(width: 11, height: 11)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 26)
        .background(style.color(.chromeBackground))
        .padding(.horizontal, -10)
    }
}

/// 锁定深浅色的皮肤,小样也按它要的那种底色画。
private struct SkinPreviewSchemeModifier: ViewModifier {
    let appearance: SkinAppearanceAffinity

    @ViewBuilder
    func body(content: Content) -> some View {
        switch appearance {
        case .adaptive: content
        case .forcesDark: content.environment(\.colorScheme, .dark)
        case .forcesLight: content.environment(\.colorScheme, .light)
        }
    }
}

// MARK: - 皮肤详情

/// 待解锁皮肤的详情:它长什么样、带来什么。
struct SkinDetailSheet: View {
    let skin: SkinDefinition
    @Environment(SkinRuntime.self) private var runtime
    /// 可选读取:预览或测试宿主里可能没有注入,读不到就只展示详情。
    @Environment(SkinUnlockStore.self) private var unlockStore: SkinUnlockStore?
    @Environment(\.skin) private var skinStyle
    @Environment(\.dismiss) private var dismiss

    private var isUsable: Bool {
        runtime.availability(of: skin) != .locked
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    SkinPreviewThumbnail(skin: skin)
                        .frame(width: 186, height: 248)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
                        .padding(.top, 12)

                    VStack(spacing: 6) {
                        Text(SkinSettingsSection.localized(skin.nameKey))
                            .font(.title2.bold())
                        Text(SkinSettingsSection.localized(skin.descriptionKey))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)

                    includes
                        .padding(.horizontal, 16)

                    unlockArea
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task { await unlockStore?.loadOffers() }
        // 解锁、恢复、或别的设备上完成的解锁生效后,直接换上这套皮肤并收起详情。
        .onChange(of: isUsable) { _, usable in
            guard usable else { return }
            _ = runtime.select(skin.id)
            dismiss()
        }
    }

    private var includes: some View {
        VStack(spacing: 0) {
            includeRow(
                systemImage: "paintpalette",
                title: Text("skin_detail_interface"),
                subtitle: Text("skin_detail_interface_desc")
            )
            if !skin.companions.immersiveStageIDs.isEmpty {
                Divider().padding(.leading, 50)
                includeRow(
                    systemImage: "viewfinder.rectangular",
                    title: Text(
                        String(
                            format: String(localized: "skin_detail_stages_format"),
                            skin.companions.immersiveStageIDs.count
                        )
                    ),
                    subtitle: nil
                )
            }
            if !skin.companions.lyricPosterStyleIDs.isEmpty {
                Divider().padding(.leading, 50)
                includeRow(
                    systemImage: "text.below.photo",
                    title: Text(
                        String(
                            format: String(localized: "skin_detail_posters_format"),
                            skin.companions.lyricPosterStyleIDs.count
                        )
                    ),
                    subtitle: nil
                )
            }
        }
        .background(
            skinStyle.cardFill(classic: Color(uiColor: .secondarySystemGroupedBackground)),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func includeRow(systemImage: String, title: Text, subtitle: Text?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.subheadline.weight(.semibold))
                if let subtitle {
                    subtitle.font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
    }

    @ViewBuilder
    private var unlockArea: some View {
        if let unlockStore, let unlockID = skin.access.unlockID {
            let activity = unlockStore.activity(for: unlockID)
            VStack(spacing: 12) {
                if let offer = unlockStore.offer(for: skin) {
                    Button {
                        Task { await unlockStore.unlock(skin) }
                    } label: {
                        HStack(spacing: 8) {
                            if activity == .working {
                                ProgressView()
                            }
                            Text(verbatim: String(localized: "skin_detail_unlock") + " · " + offer.label)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(activity == .working)
                } else if unlockStore.isLoadingOffers {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 50)
                } else {
                    unavailableNotice(unlockStore: unlockStore, unlockID: unlockID)
                }

                switch activity {
                case .pending:
                    statusText("skin_detail_unlock_pending")
                case .failed:
                    statusText("skin_detail_unlock_failed")
                case .idle, .working:
                    EmptyView()
                }

                Button {
                    Task { await unlockStore.restore() }
                } label: {
                    HStack(spacing: 6) {
                        if unlockStore.isRestoring {
                            ProgressView()
                        }
                        Text("skin_detail_restore")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(unlockStore.isRestoring)
            }
        } else {
            Text("skin_detail_unavailable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
    }

    private func statusText(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// 商店里还查不到这套皮肤的解锁项:正式构建只说明尚未开放;开发构建可以直接在本机解锁,
    /// 便于在真机上核对皮肤效果。
    @ViewBuilder
    private func unavailableNotice(unlockStore: SkinUnlockStore, unlockID: String) -> some View {
        #if DEBUG
        Button {
            unlockStore.developerUnlock(unlockID)
        } label: {
            Text("skin_detail_unlock")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        #else
        Text("skin_detail_unavailable")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 50)
        #endif
    }
}
#endif
