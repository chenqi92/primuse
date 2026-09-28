#if os(tvOS)
import PrimuseKit
import SwiftUI

// Apple TV 的「刮削」设置页。
//
// 数据就是 iPhone 那份刮削设置(同一个 UserDefaults 键,经 iCloud 键值同步或扫码直传
// 到电视),在这里改了也照样推回 iCloud。电视上管开关、先后顺序,也能导入自定义刮削源
// (输入框可用 iPhone 键盘粘贴 JSON / 配置地址);歌词 API 服务地址、Cookie 仍在 iPhone 上填。
struct TVScraperSettingsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false

    private var settings: ScraperSettingsStore { store.scraperSettings }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    HStack(alignment: .top, spacing: 40) {
                        VStack(alignment: .leading, spacing: 0) {
                            optionsSection
                            sourcesSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        sideNotes
                            .frame(width: 440, alignment: .leading)
                            .focusSection()
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
            }
        }
        .foregroundStyle(TVColor.text)
        // 扫码直传可能刚写过同一个键:打开时从 UserDefaults 重读一遍再显示。
        .onAppear { settings.reloadFromDefaults() }
        .onExitCommand { dismiss() }
        .fullScreenCover(isPresented: $showImport) {
            TVScraperImportView().environment(store)
        }
        .onAppear {
            #if DEBUG
            // 截图:TV_SCREEN=settings 配 TV_SCRAPER_IMPORT=1 直接打开导入页。
            // 本页自己也是刚弹出来的全屏层,转场没结束时再弹一层会被系统吞掉,等一下再开。
            if ProcessInfo.processInfo.environment["TV_SCRAPER_IMPORT"] == "1" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    showImport = true
                }
            }
            #endif
        }
        .accessibilityIdentifier("tv.scraper.settings")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(String(localized: "metadata_scraping")).tvFont(.pageTitle)
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
        }
        .padding(.bottom, 28)
    }

    // MARK: - 选项

    private var optionsSection: some View {
        TVAISection(title: String(localized: "scraper_options")) {
            TVAIToggleRow(
                icon: "text.quote",
                title: String(localized: "auto_online_lyrics"),
                isOn: Binding(
                    get: { settings.autoFetchOnlineLyrics },
                    set: { settings.autoFetchOnlineLyrics = $0 }
                )
            )
            TVAIDivider()
            TVAIToggleRow(
                icon: "square.and.pencil",
                title: String(localized: "only_fill_missing"),
                isOn: Binding(
                    get: { settings.onlyFillMissingFields },
                    set: { settings.onlyFillMissingFields = $0 }
                )
            )
        }
    }

    // MARK: - 刮削源

    private var sourcesSection: some View {
        let sources = settings.sources
        return TVAISection(title: String(localized: "scraper_sources")) {
            ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                if index > 0 { TVAIDivider() }
                sourceRow(source, index: index, count: sources.count)
            }
            TVAIDivider()
            TVAIActionRow(
                icon: "plus.circle",
                title: String(localized: "import_scraper_source"),
                subtitle: String(localized: "scraper_import_auto_footer")
            ) { showImport = true }
        }
    }

    private func sourceRow(_ source: ScraperSourceConfig, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            TVFocusButton(radius: 14, scale: 1.0, lift: 0, action: { settings.toggleSource(id: source.id) }) { focused in
                HStack(spacing: 18) {
                    Circle()
                        .fill(source.type.themeColor)
                        .frame(width: 16, height: 16)
                        .frame(width: 40, height: 40)
                        .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: source.displayName)
                            .tvFont(.cardTitle, weight: focused ? .bold : .medium)
                            .lineLimit(1)
                        Text(verbatim: subtitle(for: source))
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 12)
                    ZStack(alignment: source.isEnabled ? .trailing : .leading) {
                        Capsule().fill(source.isEnabled ? AnyShapeStyle(TVColor.brand)
                                                        : AnyShapeStyle(TVColor.surfaceStrong))
                            .frame(width: 62, height: 34)
                        Circle().fill(.white).frame(width: 28, height: 28).padding(3)
                    }
                    .animation(.easeOut(duration: 0.18), value: source.isEnabled)
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(focused ? TVColor.surfaceStrong : .clear)
            }
            .accessibilityLabel(Text(verbatim: source.displayName))
            .accessibilityValue(Text(source.isEnabled
                ? PMString("ext.tv.sources.status.enabled")
                : PMString("ext.tv.sources.status.disabled")))

            moveButton(
                "chevron.up",
                label: String(localized: "home_edit_move_up"),
                isEnabled: index > 0
            ) { move(from: index, by: -1) }
            moveButton(
                "chevron.down",
                label: String(localized: "home_edit_move_down"),
                isEnabled: index < count - 1
            ) { move(from: index, by: 1) }
        }
        .padding(.trailing, 14)
    }

    private func moveButton(
        _ icon: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        TVFocusButton(radius: 12, scale: 1.06, lift: 2, action: action) { focused in
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(focused ? TVColor.onBrand : TVColor.textMuted)
                .frame(width: 56, height: 56)
                .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surface),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .accessibilityLabel(Text(label))
    }

    /// 与 iPhone 的拖动排序等价:列表顺序就是查询顺序。
    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard settings.sources.indices.contains(index),
              settings.sources.indices.contains(target) else { return }
        settings.reorderSources(
            fromOffsets: IndexSet(integer: index),
            toOffset: offset < 0 ? target : target + 1
        )
    }

    /// 能力标签;歌词 API 服务开着却一个地址都没填时,提醒去 iPhone 上填。
    private func subtitle(for source: ScraperSourceConfig) -> String {
        if source.type == .lyricsServer,
           LyricsAPIServerSettings.load().servers.isEmpty {
            return String(localized: "tv_scrape_lyrics_server_unset")
        }
        var capabilities: [String] = []
        if source.type.supportsMetadata { capabilities.append(String(localized: "metadata")) }
        if source.type.supportsCover { capabilities.append(String(localized: "cover")) }
        if source.type.supportsLyrics { capabilities.append(String(localized: "lyrics_word")) }
        return capabilities.joined(separator: " · ")
    }

    // MARK: - 右栏说明

    private var sideNotes: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TVColor.brand)
                    .frame(width: 60, height: 60)
                    .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "metadata_scraping")).tvFont(.cardTitle)
                    Text(verbatim: Self.summary(enabledCount: settings.enabledSources.count))
                        .tvFont(.meta).foregroundStyle(TVColor.textMuted)
                        .lineLimit(2)
                }
            }
            TVAIDivider()
            Text(String(localized: "tv_scrape_order_hint")).tvFont(.meta).foregroundStyle(TVColor.textFaint)
            Text(String(localized: "auto_online_lyrics_footer")).tvFont(.meta).foregroundStyle(TVColor.textFaint)
            Text(String(localized: "tv_scrape_local_only_note")).tvFont(.meta).foregroundStyle(TVColor.textFaint)
            Text(String(localized: "tv_scrape_phone_only_note")).tvFont(.meta).foregroundStyle(TVColor.textFaint)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvPanel(radius: 20)
    }

    /// 设置页入口行右侧的一句概况。
    static func summary(enabledCount: Int) -> String {
        String(format: String(localized: "tv_scrape_enabled_count_format"), enabledCount)
    }
}

// MARK: - 导入自定义刮削源

/// 电视上导入刮削源:和 iPhone 同一套规则(`ScraperConfigStore` 的识别、下载、预览与导入),
/// 先预览、确认后才添加。电视上打不了一整段 JSON,但输入框获得焦点时附近的 iPhone
/// 会弹出键盘通知,可以把手机剪贴板里的 JSON 或 HTTPS 配置地址直接粘贴过来。
/// 导入的配置照常经 iCloud 同步回 iPhone / Mac。
struct TVScraperImportView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var preview: ScraperImportSummary?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @FocusState private var fieldFocused: Bool

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(strength: 0.5)
            TVColor.bg.opacity(0.5).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    Text(preview == nil
                         ? String(localized: "import_scraper_source")
                         : String(localized: "scraper_review_header"))
                        .tvFont(.sectionTitle)
                    Spacer(minLength: 0)
                    if isLoading { ProgressView() }
                }
                if let preview {
                    reviewContent(preview)
                } else {
                    inputContent
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .tvFont(.caption, weight: .medium)
                        .foregroundStyle(TVColor.warn)
                        .lineLimit(4)
                }
                actions
            }
            .padding(48)
            .frame(maxWidth: 1300, alignment: .leading)
            .tvPanel(radius: 28)
            .padding(.horizontal, 100)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(TVColor.text)
        .onExitCommand {
            // 预览里按 Menu 回到输入,不丢掉已经粘贴的内容。
            if preview != nil { preview = nil } else { dismiss() }
        }
        .onChange(of: text) { _, _ in
            preview = nil
            errorMessage = nil
        }
        .onAppear {
            // 不主动把焦点塞给输入框:tvOS 上那会直接弹出全屏键盘,用户还没看到下面的说明。
            // 焦点自然落在输入框上,按一下才开键盘(iPhone 此时会收到键盘通知)。
            #if DEBUG
            // 截图:TV_SCRAPER_IMPORT_TEXT 预填输入并直接生成预览。
            if let prefill = ProcessInfo.processInfo.environment["TV_SCRAPER_IMPORT_TEXT"] {
                text = prefill
                Task { @MainActor in
                    // 等 onChange(of: text) 先把旧预览清掉,再生成这一份。
                    try? await Task.sleep(for: .milliseconds(500))
                    review()
                }
            }
            #endif
        }
    }

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "scraper_import_auto_footer"))
                .tvFont(.caption)
                .foregroundStyle(fieldFocused ? TVColor.text : TVColor.textMuted)
            TVTextFieldBox(mono: true) {
                TextField("", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text(String(localized: "import_scraper_source")))
                    .focused($fieldFocused)
                    .onSubmit { review() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Label(String(localized: "tv_scrape_import_keyboard_hint"), systemImage: "iphone")
                .tvFont(.meta)
                .foregroundStyle(TVColor.textMuted)
            Text(String(localized: "import_scraper_footer"))
                .tvFont(.meta)
                .foregroundStyle(TVColor.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reviewContent(_ summary: ScraperImportSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(String(localized: "scraper_review_banner"), systemImage: "eye.circle")
                .tvFont(.meta)
                .foregroundStyle(TVColor.textMuted)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    reviewRow(String(localized: "scraper_review_source"), summary.sourceDescription)
                    reviewRow(String(localized: "scraper_review_configs"),
                              summary.configs.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))
                    reviewRow(String(localized: "scraper_review_capabilities"),
                              summary.capabilities.isEmpty
                                ? String(localized: "scraper_review_unknown")
                                : summary.capabilities.joined(separator: ", "))
                    reviewRow(String(localized: "scraper_review_requests"),
                              String(format: String(localized: "scraper_review_endpoints_fmt"),
                                     summary.endpointCount, summary.methods.joined(separator: ", ")))
                    if !summary.domains.isEmpty {
                        reviewRow(String(localized: "scraper_review_network_domains"),
                                  summary.domains.joined(separator: "  "))
                    }
                    if !summary.sslTrustDomains.isEmpty {
                        reviewRow(String(localized: "scraper_review_tls_trust_domains"),
                                  summary.sslTrustDomains.joined(separator: "  "))
                    }
                    HStack(spacing: 12) {
                        permissionBadge(String(localized: "scraper_review_headers"), enabled: summary.includesHeaders)
                        permissionBadge(String(localized: "scraper_review_cookie"), enabled: summary.includesCookie)
                        permissionBadge(String(localized: "scraper_review_secrets"), enabled: summary.includesSecrets)
                        permissionBadge(String(localized: "scraper_review_javascript"),
                                        enabled: summary.scriptCharacterCount > 0)
                    }
                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.warn)
                    }
                    Text(String(localized: "scraper_review_footer"))
                        .tvFont(.meta)
                        .foregroundStyle(TVColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)
            // 只读的一段说明,要让焦点能停上去,遥控器才滚得动。
            .focusable()
        }
    }

    private func reviewRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                .frame(width: 180, alignment: .leading)
            Text(verbatim: value).tvFont(.caption).foregroundStyle(TVColor.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionBadge(_ title: String, enabled: Bool) -> some View {
        Label(title, systemImage: enabled ? "checkmark.circle.fill" : "minus.circle")
            .tvFont(.meta, weight: .medium)
            .foregroundStyle(enabled ? TVColor.warn : TVColor.textFaint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(TVColor.surface, in: Capsule())
    }

    private var actions: some View {
        HStack(spacing: 20) {
            if preview == nil {
                TVPillButton(title: String(localized: "scraper_review_action"), systemImage: "eye",
                             style: .solid) { review() }
                    .disabled(trimmedText.isEmpty || isLoading)
            } else {
                TVPillButton(title: String(localized: "scraper_confirm_import"),
                             systemImage: "checkmark", style: .solid) { confirmImport() }
                TVPillButton(title: String(localized: "edit"), systemImage: "pencil") {
                    preview = nil
                    fieldFocused = true
                }
            }
            TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") { dismiss() }
        }
        .focusSection()
    }

    /// 与 iPhone 设置页 `performImport` 的第一步相同:自动识别 JSON / 配置地址,生成预览。
    private func review() {
        let input = trimmedText
        guard !input.isEmpty, !isLoading else { return }
        errorMessage = nil
        let classified: ScraperImportInput
        do {
            classified = try ScraperConfigStore.shared.classifyImportInput(input)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        switch classified {
        case .json(let json):
            do {
                preview = try ScraperConfigStore.shared.previewImportFromJSON(json)
            } catch {
                plog("📥 TV scraper import preview failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        case .remoteURL(let url):
            isLoading = true
            Task {
                defer { isLoading = false }
                do {
                    let summary = try await ScraperConfigStore.shared.previewImportFromURL(url)
                    // 下载途中又改了输入:这份预览已经过期。
                    guard trimmedText == input else { return }
                    preview = summary
                } catch {
                    guard trimmedText == input else { return }
                    plog("📥 TV scraper import download failed: \(error.localizedDescription)")
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func confirmImport() {
        guard let preview else { return }
        do {
            let configs = try ScraperConfigStore.shared.importConfigs(preview.configs)
            plog("📥 TV scraper import confirmed: count=\(configs.count) ids=\(configs.map(\.id))")
            for config in configs { store.scraperSettings.addCustomSource(config) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
