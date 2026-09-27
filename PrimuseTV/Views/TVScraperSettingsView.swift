#if os(tvOS)
import PrimuseKit
import SwiftUI

// Apple TV 的「刮削」设置页。
//
// 数据就是 iPhone 那份刮削设置(同一个 UserDefaults 键,经 iCloud 键值同步或扫码直传
// 到电视),在这里改了也照样推回 iCloud。要打字的部分 —— 导入自定义刮削源、填歌词
// API 服务地址、Cookie —— 只在 iPhone 上做;电视上管开关和先后顺序。
struct TVScraperSettingsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

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
            Text(String(localized: "tv_scrape_import_on_phone")).tvFont(.meta).foregroundStyle(TVColor.textFaint)
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
#endif
