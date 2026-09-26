import PrimuseKit
import SwiftUI

/// 设置根页的功能契约。
///
/// 两种组织方式(分区长列表 / 「常用 + 分类」枢纽,见 `SkinSurfaceVariant.SettingsRoot`)只收它:
/// 分区与每区列哪些设置页来自 `SettingsCatalog`,搜索状态决定此刻显示搜索结果、最近使用还是设置行,
/// 深链锚点是要在根页上定位并高亮的那一项(版本信息、推送到 Apple TV 这类直接长在列表里的行)。
/// 搜索、锚点、跳转都只有一份,换一种组织方式不会碰到它们。
@MainActor
struct SettingsRootModel {
    /// 一个分类,和它下面列在根页上的设置页(`SettingsCatalog` 的顺序)。
    struct Section: Identifiable {
        let category: SettingsCategory
        let pages: [SettingsPage]
        var id: SettingsCategory { category }
    }

    /// 全部分类,顺序与 `SettingsCategory.allCases` 一致;没有可列页面的分类也在(「关于」就是)。
    let sections: [Section]
    let search: SettingsSearchState
    /// 未开放远程配置的地区不显示智能功能。
    let showsIntelligence: Bool
    /// 深链锚点。
    let focusedItemID: String?
    /// 打开一条设置(搜索结果、最近使用):推入它所在的页并定位。
    let openItem: (SettingDefinition) -> Void
    /// 直接推入一个设置页(枢纽的常用磁贴)。
    let openPage: (SettingsPage) -> Void

    /// 这一类下面列在根页上的设置页。未开放远程配置的地区不列智能功能。
    static func listedPages(in category: SettingsCategory, showsIntelligence: Bool) -> [SettingsPage] {
        SettingsPage.allCases.filter { page in
            guard page.category == category, page.available, page.isListed else { return false }
            return page != .intelligence || showsIntelligence
        }
    }

    static func sections(showsIntelligence: Bool) -> [Section] {
        SettingsCategory.allCases.map { category in
            Section(
                category: category,
                pages: listedPages(in: category, showsIntelligence: showsIntelligence)
            )
        }
    }
}

/// 设置根页的入口:搜索结果与最近使用两种组织方式共用,设置行按界面皮肤的 `settingsRoot` 表面穷尽分派。
struct SettingsRootContent: View {
    let model: SettingsRootModel
    @Environment(\.skin) private var skin

    var body: some View {
        SettingsFocusedPage(itemID: model.focusedItemID) {
            SkinList {
                if model.search.content == .results {
                    searchResults
                }
                if model.search.content == .recent, !recentItems.isEmpty {
                    recentItemsSection
                }
                if model.search.showsSettingsRows {
                    switch skin.skin.settingsRoot {
                    case .classic:
                        SettingsSectionedRootRows(model: model)
                    case .hub:
                        SettingsHubRootRows(model: model)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // iPhone Duo 竖栏：分组卡片铺到屏幕右缘，系统的玻璃胶囊浮在上面。
            .pmExtendsUnderVerticalBar()
        }
    }

    private var recentItems: [SettingDefinition] {
        SettingsSearchHistory.shared.ids.compactMap { SettingsCatalog.byID[$0] }
            .filter { model.showsIntelligence || $0.page != .intelligence }
    }

    private var recentItemsSection: some View {
        Section {
            ForEach(recentItems) { item in
                Button { model.openItem(item) } label: { SettingsSearchResultRow(item: item) }
                    .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text(SettingsStrings.text("Recently used"))
                Spacer()
                Button(SettingsStrings.text("Clear")) { SettingsSearchHistory.shared.clear() }
                    .textCase(nil)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let results = SettingsCatalog.search(model.search.query, showsIntelligence: model.showsIntelligence)
        if results.isEmpty {
            ContentUnavailableView.search(text: model.search.query)
        } else {
            ForEach(results) { item in
                Button { model.openItem(item) } label: { SettingsSearchResultRow(item: item) }
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 分区长列表(经典)

/// `SettingsRoot.classic`:每个分类一个分区,「关于」的几行排在最后。
private struct SettingsSectionedRootRows: View {
    let model: SettingsRootModel

    var body: some View {
        // 分组与顺序全部来自 SettingsCatalog。此前这里是一份手写的 Section
        // 列表，和 macOS 侧栏各持一套定义，改一边不会同步另一边 —— 页面加了
        // 却在某一端看不见，正是这么来的。
        ForEach(model.sections) { section in
            if section.category != .about, !section.pages.isEmpty {
                Section {
                    ForEach(section.pages) { page in
                        SettingsCatalogRow(page: page)
                    }
                    if section.category == .integrations {
                        AppleTVPushRow()
                    }
                } header: {
                    Text(LocalizedStringKey(section.category.titleKey))
                }
            }
        }

        SettingsAboutSection(showsHeader: true)
    }
}

// MARK: - 枢纽

/// `SettingsRoot.hub`:常用磁贴 + 分类入口,其余设置页收进分类里(分类页由 `SettingsView` 推入)。
private struct SettingsHubRootRows: View {
    let model: SettingsRootModel

    @Environment(\.skin) private var skin
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(SourcesStore.self) private var sourcesStore

    /// 常用入口。固定四项:没有音乐源就没有音乐;外观、播放与歌词是日常最常动的三处。
    private var favoritePages: [SettingsPage] {
        [SettingsPage.sources, .appearance, .playback, .lyrics].filter { $0.available }
    }

    private var categories: [SettingsRootModel.Section] {
        model.sections.filter { $0.category == .about || !$0.pages.isEmpty }
    }

    var body: some View {
        Section {
            // 不用 LazyVGrid:List 行里放惰性网格会让行高与网格互相触发重新布局。
            VStack(spacing: 10) {
                ForEach(favoriteRows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row) { page in
                            favoriteTile(page)
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("settings_hub_frequent")
        }

        Section {
            ForEach(categories) { section in
                NavigationLink(value: SettingsDestination.category(section.category, nil)) {
                    categoryLabel(section)
                }
                .listRowBackground(skin.color(.surface))
            }
        } header: {
            Text("settings_hub_all")
        }
    }

    private var favoriteRows: [[SettingsPage]] {
        let pages = favoritePages
        return stride(from: 0, to: pages.count, by: 2).map { index in
            Array(pages[index..<min(index + 2, pages.count)])
        }
    }

    private func favoriteTile(_ page: SettingsPage) -> some View {
        Button {
            model.openPage(page)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: page.icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(tint(for: page.category))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.skin(.textQuaternary))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(favoriteTitleKey(for: page)))
                        .font(skin.font(.bodyStrong))
                        .foregroundStyle(.skin(.textPrimary))
                        .lineLimit(1)
                    Text(favoriteSummary(for: page) ?? " ")
                        .font(skin.font(.meta))
                        .foregroundStyle(.skin(.textSecondary))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                skin.color(.surface),
                in: RoundedRectangle(cornerRadius: skin.rawMetric(.radiusLarge), style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: skin.rawMetric(.radiusLarge), style: .continuous)
                    .strokeBorder(skin.color(.surfaceBorder), lineWidth: skin.rawMetric(.borderWidth))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.hub.favorite.\(page.rawValue)")
    }

    /// 外观页在分类列表里按「改的是哪个界面」叫「设置页」;单独拎出来做常用入口时,
    /// 这个名字说明不了它管什么,换成它真正的内容。
    private func favoriteTitleKey(for page: SettingsPage) -> String {
        page == .appearance ? "settings_hub_appearance_title" : page.titleKey
    }

    /// 磁贴上的一句现状。取不到就留空,不编造。
    private func favoriteSummary(for page: SettingsPage) -> String? {
        let service = SettingsActionService(
            playback: playbackSettings,
            showsIntelligence: model.showsIntelligence
        )
        switch page {
        case .sources:
            return String(
                format: String(localized: "sources_count_format"),
                sourcesStore.sources.count
            )
        case .appearance:
            // 皮肤名在 PrimuseKit 的语言表里。
            return PMString(skin.skin.nameKey)
        case .playback:
            return service.status(for: "playback.outputMode").value
        case .lyrics:
            guard let value = service.status(for: "lyrics.translationEnabled").value else {
                return nil
            }
            return String(localized: "lyrics_translation_enabled") + " · " + value
        default:
            return nil
        }
    }

    private func categoryLabel(_ section: SettingsRootModel.Section) -> some View {
        let category = section.category
        let pages = section.pages
        let preview = pages
            .prefix(4)
            .map(\.title)
            .joined(separator: " · ")
        let tint = tint(for: category)

        return HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    tint.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(category.titleKey))
                    .font(skin.font(.bodyStrong))
                    .foregroundStyle(.skin(.textPrimary))
                if !preview.isEmpty {
                    Text(preview)
                        .font(skin.font(.meta))
                        .foregroundStyle(.skin(.textSecondary))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if !pages.isEmpty {
                Text("\(pages.count)")
                    .font(skin.font(.numeric))
                    .foregroundStyle(.skin(.textTertiary))
            }
        }
        .padding(.vertical, 4)
    }

    private func tint(for category: SettingsCategory) -> Color {
        switch category {
        case .library: return .blue
        case .playback: return .green
        case .appearance: return skin.color(.accent)
        case .sync: return .purple
        case .integrations: return .orange
        case .security, .about: return .gray
        }
    }
}

// MARK: - 共用的行

/// 单行设置入口。标题与图标由 SettingsCatalog 提供，这里只处理三处例外。
struct SettingsCatalogRow: View {
    let page: SettingsPage
    @Environment(MusicIntelligenceService.self) private var musicIntelligence

    var body: some View {
        switch page {
        case .intelligence:
            // 未开放远程配置的地区不显示这一项。
            if musicIntelligence.shouldExposeRemoteConfiguration {
                pageLink
            }
        case .domains:
            NavigationLink(value: SettingsDestination.page(page, nil)) {
                HStack {
                    Label(LocalizedStringKey(page.titleKey), systemImage: page.icon)
                    Spacer()
                    Text("\(SSLTrustStore.shared.trustedDomains.count + SSLTrustStore.shared.insecureHTTPDomains.count)")
                        .foregroundStyle(.secondary)
                }
            }
        default:
            pageLink
        }
    }

    private var pageLink: some View {
        NavigationLink(value: SettingsDestination.page(page, nil)) {
            Label(LocalizedStringKey(page.titleKey), systemImage: page.icon)
        }
    }
}

/// 「关于」:版本、检查更新、诊断、许可、评分与两条反馈链接。分区长列表里排在最后,枢纽里是「关于」分类页。
struct SettingsAboutSection: View {
    let showsHeader: Bool
    @Environment(\.openURL) private var openURL

    /// The issue form opens with this build's version, device and system
    /// already filled in. None of those fields are required by the form, so the
    /// user can edit or clear them before submitting.
    private func feedbackURL(for template: IssueFeedbackLink.Template) -> URL {
        IssueFeedbackLink.url(
            for: template,
            environment: RunningAppEnvironment.diagnosticEnvironment(),
            platform: RunningAppEnvironment.issuePlatform
        )
    }

    var body: some View {
        Section {
            HStack {
                Label("version", systemImage: "number")
                Spacer()
                Text("\(Bundle.main.appVersion) (\(Bundle.main.appBuildNumber))")
                    .foregroundStyle(.secondary)
            }
            .settingsAnchor("about.version")

            CheckForUpdateRow()

            NavigationLink(value: SettingsDestination.page(.diagnostics, nil)) {
                Label(String(localized: "diagnostics_title"), systemImage: "stethoscope")
            }

            NavigationLink(value: SettingsDestination.page(.licenses, nil)) {
                Label("licenses", systemImage: "doc.text")
            }

            Button {
                openURL(PrimuseAppStore.reviewURL)
            } label: {
                Label("rate_on_app_store", systemImage: "star.bubble")
            }
            .settingsAnchor("about.rate")

            Link(destination: feedbackURL(for: .bugReport)) {
                Label("github_bug_report", systemImage: "exclamationmark.bubble")
            }
            .settingsAnchor("about.bugReport")

            Link(destination: feedbackURL(for: .featureRequest)) {
                Label("github_feature_request", systemImage: "lightbulb")
            }
            .settingsAnchor("about.featureRequest")
        } header: {
            if showsHeader {
                Text("about")
            }
        }
        .settingsAnchor("page.about")
    }
}
