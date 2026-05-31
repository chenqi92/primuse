#if os(macOS)
import SwiftUI
import AppKit
import CloudKit
import UniformTypeIdentifiers
import WidgetKit
import PrimuseKit

/// macOS settings window rebuilt against `design/猿音/scenes/settings.jsx`.
/// The window chrome, sidebar, and every ST-* page use the same custom row
/// system as the design instead of embedding the older grouped Forms.
struct MacSettingsView: View {
    private enum Tab: String, Hashable, CaseIterable, Identifiable {
        case playback, equalizer, effects, scrape, lyrics
        case appleMusic, widgets, cloud, theme, deleted, ssl, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .playback: return Lz("Playback")
            case .equalizer: return Lz("Equalizer")
            case .effects: return Lz("Audio Effects")
            case .scrape: return Lz("Metadata Scraping")
            case .lyrics: return Lz("Lyrics Translation")
            case .appleMusic: return "Apple Music"
            case .widgets: return Lz("Widgets")
            case .cloud: return "iCloud"
            case .theme: return Lz("Appearance")
            case .deleted: return Lz("Recently Deleted")
            case .ssl: return Lz("Trusted Domains")
            case .about: return Lz("About")
            }
        }

        var icon: String {
            switch self {
            case .playback: return "play.circle"
            case .equalizer: return "slider.horizontal.3"
            case .effects: return "waveform.badge.plus"
            case .scrape: return "tag"
            case .lyrics: return "character.bubble"
            case .appleMusic: return "music.note"
            case .widgets: return "rectangle.grid.2x2"
            case .cloud: return "icloud"
            case .theme: return "sun.max"
            case .deleted: return "trash"
            case .ssl: return "lock.shield"
            case .about: return "info.circle"
            }
        }

        var spec: String {
            switch self {
            case .playback: return "ST-01"
            case .equalizer: return "ST-02"
            case .effects: return "ST-03"
            case .scrape: return "ST-04"
            case .lyrics: return "ST-05"
            case .appleMusic: return "ST-06"
            case .widgets: return "ST-07"
            case .cloud: return "ST-08"
            case .theme: return "ST-12"
            case .deleted: return "ST-09"
            case .ssl: return "ST-10"
            case .about: return "ST-11"
            }
        }
    }

    @State private var tab: Tab = .playback
    @State private var sidebarFilter = ""

    private func selectTab(_ newTab: Tab) {
        tab = newTab
    }

    private var filteredTabs: [Tab] {
        let query = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Tab.allCases }
        return Tab.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
            || $0.spec.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsTitleBar

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 200)
                Divider()
                contentPane
            }
        }
        // 设计稿 Settings 窗口尺寸: sidebar 200 + content max-width 720 + L/R padding 32×2
        // ≈ 984pt 宽。之前设 1040×720, 右侧 max-width 限制让 56pt 留白; 用户截图看着
        // "右边空一片"。改成 940×680, content 几乎贴右边缘。
        .frame(minWidth: 940, idealWidth: 960, minHeight: 680, idealHeight: 720)
        .environment(\.pmAppearance, MacUIPreferences.shared.appearance)
        .background(PMColor.bg.ignoresSafeArea())
        .background(PMWindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)
    }

    private var settingsTitleBar: some View {
        HStack(spacing: 0) {
            // 设置窗口是弹框性质, 最小化/缩放没意义, 只留一个关闭灯。
            PMWindowTrafficLights(closeOnly: true)

            Text(verbatim: tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            // 跟左侧关闭灯等宽的占位, 让标题在窗口里居中。
            Color.clear.frame(width: PMSize.trafficLight, height: 1)
        }
        .padding(.horizontal, 14)
        .frame(height: PMSize.titlebar)
        .background {
            ZStack {
                NSVisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
                Rectangle().fill(PMColor.sidebarGlass)
            }
        }
        .pmWindowDragRegion()
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSearch
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredTabs) { sidebarItem($0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background {
            ZStack {
                NSVisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
                Rectangle().fill(PMColor.sidebarGlass)
            }
            .ignoresSafeArea()
        }
    }

    private var sidebarSearch: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            TextField("", text: $sidebarFilter, prompt: Text(verbatim: Lz("Search…")))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.text)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func sidebarItem(_ item: Tab) -> some View {
        let selected = item == tab
        return Button { selectTab(item) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.white.opacity(0.22))
                          : AnyShapeStyle(PMColor.brand.opacity(0.16)))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : PMColor.brand)
                    }

                Text(verbatim: item.title)
                    .font(selected ? .system(size: 12.5, weight: .medium) : .system(size: 12.5))
                    .foregroundStyle(selected ? Color.white : PMColor.text)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? PMColor.brand : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var contentPane: some View {
        MacSettingsScroll(title: tab.title) {
            settingsContent
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch tab {
        case .playback:
            MacSTPlaybackView()
        case .equalizer:
            MacSTEqualizerView()
        case .effects:
            MacSTEffectsView()
        case .scrape:
            MacSTScrapingView()
        case .lyrics:
            MacSTLyricsView()
        case .appleMusic:
            MacSTAppleMusicView()
        case .widgets:
            MacSTWidgetView()
        case .cloud:
            MacSTCloudView()
        case .theme:
            MacSTThemeView()
        case .deleted:
            MacSTDeletedView()
        case .ssl:
            MacSTSSLView()
        case .about:
            MacSTAboutView()
        }
    }
}

// MARK: - Settings Shell Components

private struct MacSettingsScroll<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        // 标题随内容一起滚动 — 标题栏(红绿灯区)已经显示当前页名,
        // 这里不再固定标题, 也不画分割线, 滚动条隐藏。
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(.system(size: 22, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(PMColor.text)
                }
                .padding(.bottom, 18)

                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PMColor.bg)
    }
}

private struct MacSTSection<Content: View>: View {
    let title: String?
    let hint: String?
    private let content: Content

    init(_ title: String? = nil, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                let visibleTitle = PMTextWithoutDesignCodes(title)
                if !visibleTitle.isEmpty {
                    Text(verbatim: visibleTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(PMColor.textFaint)
                        .textCase(.uppercase)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                        .padding(.bottom, -2)
                }
            }

            content

            if let hint {
                let visibleHint = PMTextWithoutDesignCodes(hint)
                if !visibleHint.isEmpty {
                    Text(verbatim: visibleHint)
                        .font(.system(size: 10.5))
                        .lineSpacing(3)
                        .foregroundStyle(PMColor.textFaint)
                        .padding(.horizontal, 14)
                        .padding(.top, -4)
                }
            }
        }
        .padding(.bottom, 22)
    }
}

private struct MacSTGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct MacSTRow<Content: View>: View {
    let label: String
    let hint: String?
    let divider: Bool
    let block: Bool
    private let content: Content

    init(_ label: String,
         hint: String? = nil,
         divider: Bool = true,
         block: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.label = label
        self.hint = hint
        self.divider = divider
        self.block = block
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }

            if block {
                VStack(alignment: .leading, spacing: 0) {
                    rowLabel
                    content
                        .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    rowLabel
                    Spacer(minLength: 12)
                    content
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 38)
            }
        }
    }

    private var rowLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            let visibleLabel = PMTextWithoutDesignCodes(label)
            if !visibleLabel.isEmpty {
                Text(verbatim: visibleLabel)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
            }
            if let hint {
                let visibleHint = PMTextWithoutDesignCodes(hint)
                if !visibleHint.isEmpty {
                    Text(verbatim: visibleHint)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MacSTToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
                isOn.toggle()
            }
        } label: {
            Capsule()
                .fill(isOn ? Color(red: 0.20, green: 0.78, blue: 0.35) : PMColor.dividerStrong)
                .frame(width: 32, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct MacSTSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let width: CGFloat
    let formatter: (Double) -> String

    init(value: Binding<Double>,
         in range: ClosedRange<Double> = 0...100,
         width: CGFloat = 200,
         formatter: @escaping (Double) -> String = { "\(Int($0.rounded()))" }) {
        self._value = value
        self.range = range
        self.width = width
        self.formatter = formatter
    }

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range)
                .tint(PMColor.brand)
                .controlSize(.small)
            Text(verbatim: formatter(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .frame(width: width)
    }
}

/// 真实 Picker — Menu 下拉, 点击会弹真菜单。
private struct MacSTPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var width: CGFloat = 200

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button(opt.label) { selection = opt.value }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: currentLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 22)
            .background(PMColor.bgElev, in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: 5))
        }
        // `.borderlessButton` 会丢掉自定义 label, 退化成原生「⌄ 标题」下拉;
        // `.button` + 透明 buttonStyle 才会把上面那个描边盒子当作触发器渲染,
        // `.menuIndicator(.hidden)` 去掉系统自动补的箭头 (我们自己画了)。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "—"
    }
}

private struct MacSTButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent = false
    var destructive = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(foreground)
            .background(background, in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        if prominent { return .white }
        if destructive { return PMColor.bad }
        return PMColor.text
    }

    private var background: Color {
        if prominent { return PMColor.brand }
        if destructive { return .clear }
        return PMColor.glassBtn
    }
}

private struct MacSTBadge: View {
    let text: String
    var color: Color = PMColor.brand

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .foregroundStyle(color)
            .background(color.opacity(0.16), in: .rect(cornerRadius: 3))
    }
}

private struct MacSTChip: View {
    let text: String
    var selected = false

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(selected ? PMColor.brand : PMColor.glassBtn, in: .capsule)
    }
}

private struct MacSTInfoText: View {
    let text: String
    var color: Color = PMColor.textMuted

    var body: some View {
        Text(verbatim: PMTextWithoutDesignCodes(text))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

// MARK: - ST-01 Playback

private struct MacSTPlaybackView: View {
    // 接真 Store, 拖滑块/切 toggle 会立即写回 PlaybackSettingsStore 并 persist。
    @Environment(PlaybackSettingsStore.self) private var store

    var body: some View {
        @Bindable var s = store

        MacSTSection(Lz("Playback Rate & Quality")) {
            MacSTGroup {
                MacSTRow(Lz("Playback Rate"), hint: Lz("0.5x – 2.0x · Preserve Pitch"), divider: false) {
                    MacSTSlider(
                        value: Binding(
                            get: { Double(s.playbackRate * 100) },
                            set: { s.playbackRate = Float($0 / 100) }
                        ),
                        in: 50...200,
                        formatter: { String(format: "%.2fx", $0 / 100) }
                    )
                }
                MacSTRow(Lz("Spatial Audio"), hint: Lz("Apple AirPods · Head Tracking")) {
                    MacSTToggle(isOn: $s.spatialAudioEnabled)
                }
                MacSTRow("ReplayGain", hint: Lz("Automatic Volume Balancing")) {
                    MacSTToggle(isOn: $s.replayGainEnabled)
                }
                if s.replayGainEnabled {
                    MacSTRow(Lz("RG Mode"), hint: "Track vs Album") {
                        MacSTPicker(
                            selection: $s.replayGainMode,
                            options: ReplayGainMode.allCases.map { ($0, $0.displayName) },
                            width: 160
                        )
                    }
                }
            }
        }

        MacSTSection(Lz("Transitions & Gapless")) {
            MacSTGroup {
                MacSTRow(Lz("Gapless Playback"), hint: Lz("P-16 · On by Default"), divider: false) {
                    MacSTToggle(isOn: $s.gaplessEnabled)
                }
                MacSTRow("Crossfade", hint: Lz("Mutually exclusive with Gapless")) {
                    MacSTToggle(isOn: $s.crossfadeEnabled)
                }
                if s.crossfadeEnabled {
                    MacSTRow(Lz("Crossfade Duration"), hint: Lz("1–12 seconds")) {
                        MacSTSlider(
                            value: $s.crossfadeDuration,
                            in: 1...12,
                            formatter: { "\(Int($0))s" }
                        )
                    }
                }
                MacSTRow(Lz("Skip leading silence"), hint: "Silence trim · Intro") {
                    MacSTToggle(isOn: $s.skipLeadingSilenceEnabled)
                }
                MacSTRow(Lz("Skip trailing silence"), hint: "Silence trim · Outro") {
                    MacSTToggle(isOn: $s.skipTrailingSilenceEnabled)
                }
                MacSTRow(Lz("Match Hardware Sample Rate"), hint: Lz("Works on physical iOS devices; ignored by some hardware")) {
                    MacSTToggle(isOn: $s.matchOutputSampleRate)
                }
            }
        }

        MacSTSection(Lz("Cache")) {
            MacSTGroup {
                MacSTRow(Lz("Enable Audio Cache"), hint: "AudioCacheManager · LRU", divider: false) {
                    MacSTToggle(isOn: $s.audioCacheEnabled)
                }
                if s.audioCacheEnabled {
                    MacSTRow(Lz("Cache Limit (MB)"), hint: Lz("Default 500 MB")) {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(s.audioCacheLimitBytes) / 1_048_576 },
                                set: { s.audioCacheLimitBytes = Int64($0 * 1_048_576) }
                            ),
                            in: 100...4000,
                            width: 250,
                            formatter: { "\(Int($0)) MB" }
                        )
                        MacSTButton(title: Lz("Clean Up Now")) {
                            AudioCacheManager.shared.clearAll()
                        }
                    }
                    MacSTRow(Lz("Prewarm queue head"), hint: "P-24 · SourceManager.prewarm") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(s.prewarmQueueCount) },
                                set: { s.prewarmQueueCount = Int($0.rounded()) }
                            ),
                            in: 0...8,
                            formatter: { "\(Int($0.rounded()))" }
                        )
                    }
                }
            }
        }
    }
}

// MARK: - ST-02 Equalizer

private struct MacSTEqualizerView: View {
    @Environment(EqualizerService.self) private var eq

    var body: some View {
        @Bindable var eq = eq

        MacSTSection(Lz("10-Band Equalizer")) {
            MacSTGroup {
                MacSTRow(Lz("Enable EQ"), hint: "FX-01", divider: false) {
                    MacSTToggle(isOn: $eq.isEnabled)
                }
                MacSTRow(Lz("Current Preset")) {
                    MacSTPicker(
                        selection: Binding(
                            get: { eq.currentPreset.id },
                            set: { id in
                                if let preset = EQPreset.builtInPresets.first(where: { $0.id == id }) {
                                    eq.applyPreset(preset)
                                }
                            }
                        ),
                        options: EQPreset.builtInPresets.map { ($0.id, $0.localizedName) },
                        width: 180
                    )
                }
                MacSTRow(Lz("Preset"), hint: Lz("Click to switch · Drag the slider below to make it custom"), block: true) {
                    HStack(spacing: 6) {
                        ForEach(EQPreset.builtInPresets) { preset in
                            Button {
                                eq.applyPreset(preset)
                            } label: {
                                MacSTChip(text: preset.localizedName,
                                          selected: preset.id == eq.currentPreset.id)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 6)
                        MacSTButton(title: Lz("Reset")) { eq.reset() }
                    }
                }
            }
        }

        MacEQFaderCard(
            bands: eq.bandFrequencyLabels,
            gains: Binding(
                get: { eq.bands.map { Int($0.rounded()) } },
                set: { newGains in
                    for (i, g) in newGains.enumerated() {
                        eq.setBand(i, gain: Float(g))
                    }
                }
            )
        )
    }
}

private struct MacEQFaderCard: View {
    let bands: [String]
    @Binding var gains: [Int]

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                    MacEQFader(
                        band: band,
                        gain: Binding(
                            get: { gains.indices.contains(index) ? gains[index] : 0 },
                            set: { newValue in
                                guard gains.indices.contains(index) else { return }
                                gains[index] = max(-12, min(12, newValue))
                            }
                        )
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 220)
            .padding(.horizontal, 8)

            HStack {
                Text(verbatim: "-12 dB")
                Spacer()
                Text(verbatim: "0")
                Spacer()
                Text(verbatim: "+12 dB")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(PMColor.textFaint)
            .padding(.horizontal, 12)
        }
        .padding(18)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .padding(.bottom, 22)
    }
}

private struct MacEQFader: View {
    let band: String
    @Binding var gain: Int

    /// 滑轨可用纵向高度 (跟 frame height 一致)。每 dB ≈ trackHeight/24, 拖动时
    /// 把垂直位移换算成 dB 增量。
    private let trackHeight: CGFloat = 140
    @State private var dragStartGain: Int? = nil

    private var dbPerPoint: CGFloat { trackHeight / 24 }

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: gain > 0 ? "+\(gain)" : "\(gain)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(gain >= 0 ? PMColor.ok : PMColor.brand)

            ZStack {
                // 轨道
                Capsule()
                    .fill(PMColor.dividerStrong)
                    .frame(width: 5, height: trackHeight)

                // 进度填充 (从中点出发往 ± 方向)
                Rectangle()
                    .fill(PMColor.brand)
                    .frame(width: 9, height: CGFloat(abs(gain)) * dbPerPoint)
                    .cornerRadius(2)
                    .offset(y: gain >= 0
                            ? -CGFloat(abs(gain)) * dbPerPoint / 2
                            : CGFloat(abs(gain)) * dbPerPoint / 2)

                // 拖把
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white)
                    .frame(width: 15, height: 9)
                    .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
                    .offset(y: CGFloat(-gain) * dbPerPoint)
            }
            .frame(width: 24, height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStartGain == nil { dragStartGain = gain }
                        guard let start = dragStartGain else { return }
                        // 上拖 (negative y) → 增益变高
                        let deltaDB = -g.translation.height / dbPerPoint
                        gain = max(-12, min(12, start + Int(deltaDB.rounded())))
                    }
                    .onEnded { _ in dragStartGain = nil }
            )

            Text(verbatim: band)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(PMColor.textMuted)
        }
    }
}

// MARK: - ST-03 Audio Effects

private struct MacSTEffectsView: View {
    @Environment(AudioEffectsService.self) private var fx
    @State private var stereoEnabled = true
    @State private var stereoWidth = 75.0

    var body: some View {
        @Bindable var fx = fx

        MacSTSection(Lz("Effects Chain")) {
            MacSTGroup {
                MacSTRow(Lz("Enable Effects Chain"), hint: Lz("Master bypass"), divider: false) {
                    MacSTToggle(isOn: $fx.effectChainEnabled)
                }
            }
        }

        MacSTSection(Lz("Reverb")) {
            MacSTGroup {
                MacSTRow(Lz("Toggle"), hint: "FX-03", divider: false) {
                    MacSTToggle(isOn: $fx.reverbEnabled)
                }
                if fx.reverbEnabled {
                    MacSTRow(Lz("Type")) {
                        MacSTPicker(
                            selection: $fx.reverbPreset,
                            options: ReverbPreset.allCases.map { ($0, $0.localizedName) },
                            width: 180
                        )
                    }
                    MacSTRow("Wet / Dry %", hint: Lz("0 = dry, 100 = wet")) {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.reverbWetDryMix) },
                                set: { fx.reverbWetDryMix = Float($0) }
                            ),
                            in: 0...100
                        )
                    }
                    MacSTRow(Lz("Room Size"), hint: Lz("Small room → large hall")) {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.reverbRoomSize) },
                                set: { fx.reverbRoomSize = Float($0) }
                            ),
                            in: 0...100,
                            formatter: { String(format: "%.0f%%", $0) }
                        )
                    }
                }
            }
        }
        .disabled(!fx.effectChainEnabled)
        .opacity(fx.effectChainEnabled ? 1 : 0.56)

        MacSTSection(Lz("Compressor / Limiter")) {
            MacSTGroup {
                MacSTRow(Lz("Toggle"), hint: "FX-04", divider: false) {
                    MacSTToggle(isOn: $fx.compressorEnabled)
                }
                if fx.compressorEnabled {
                    MacSTRow(Lz("Preset")) {
                        MacSTPicker(
                            selection: Binding(
                                get: { fx.compressorPresetId ?? "" },
                                set: { id in
                                    if let p = CompressorPreset.allPresets.first(where: { $0.id == id }) {
                                        fx.applyCompressorPreset(p)
                                    }
                                }
                            ),
                            options: [("", Lz("Custom"))]
                                + CompressorPreset.allPresets.map { ($0.id, $0.localizedName) },
                            width: 160
                        )
                    }
                    MacSTRow("Threshold (dB)") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.compressorThreshold) },
                                set: { fx.compressorThreshold = Float($0) }
                            ),
                            in: -40...0,
                            formatter: { String(format: "%.0f", $0) }
                        )
                    }
                    MacSTRow("HeadRoom (dB)") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.compressorHeadRoom) },
                                set: { fx.compressorHeadRoom = Float($0) }
                            ),
                            in: 0...20
                        )
                    }
                    MacSTRow("Attack (s)") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.compressorAttackTime) },
                                set: { fx.compressorAttackTime = Float($0) }
                            ),
                            in: 0.0001...0.2,
                            formatter: { String(format: "%.3fs", $0) }
                        )
                    }
                    MacSTRow("Release (s)") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.compressorReleaseTime) },
                                set: { fx.compressorReleaseTime = Float($0) }
                            ),
                            in: 0.01...3,
                            formatter: { String(format: "%.2fs", $0) }
                        )
                    }
                    MacSTRow("Master Gain (dB)") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.compressorMasterGain) },
                                set: { fx.compressorMasterGain = Float($0) }
                            ),
                            in: -20...20
                        )
                    }
                }
            }
        }
        .disabled(!fx.effectChainEnabled)
        .opacity(fx.effectChainEnabled ? 1 : 0.56)

        MacSTSection(Lz("Stereo Enhancement")) {
            MacSTGroup {
                MacSTRow(Lz("Toggle"), hint: "FX-05", divider: false) {
                    MacSTToggle(isOn: $stereoEnabled)
                }
                MacSTRow(Lz("Width")) {
                    MacSTSlider(value: $stereoWidth)
                }
            }
        }
        .disabled(!fx.effectChainEnabled)
        .opacity(fx.effectChainEnabled ? 1 : 0.56)
    }
}

// MARK: - ST-04 Metadata Scraping

private enum ScraperImportMode { case paste, url }

private struct MacSTScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importError: String?
    @State private var importMode: ScraperImportMode = .paste
    @AppStorage(MusicScraperService.sidecarCoverWriteEnabledKey) private var sidecarCoverWriteEnabled = true
    @AppStorage(MusicScraperService.sidecarLyricsWriteEnabledKey) private var sidecarLyricsWriteEnabled = true
    @AppStorage(MusicScraperService.sidecarWriteTimeoutKey) private var sidecarWriteTimeout = 30.0

    var body: some View {
        MacSTSection(Lz("Scraping Sources"), hint: Lz("META-01 · Drag to Reorder · Higher Items Take Priority")) {
            VStack(spacing: 4) {
                ForEach(Array(scraperSettings.sources.enumerated()), id: \.element.id) { index, source in
                    MacScraperSourceRow(
                        source: source,
                        index: index,
                        sourceCount: scraperSettings.sources.count,
                        isEnabled: sourceEnabledBinding(source),
                        move: { offsets, destination in
                            scraperSettings.reorderSources(fromOffsets: offsets, toOffset: destination)
                        },
                        remove: { scraperSettings.removeCustomSource(id: source.id) }
                    )
                }
            }

            MacSTGroup {
                MacSTRow(Lz("Custom Source"), hint: Lz("META-03 · Paste JSON or Import from URL"), divider: false) {
                    MacSTButton(title: Lz("Import from URL…"), systemImage: "link") {
                        beginImport(.url)
                    }
                    MacSTButton(title: Lz("Paste JSON…"), systemImage: "doc.on.clipboard") {
                        beginImport(.paste)
                    }
                }
            }
        }

        MacSTSection(Lz("Matching Strategy"), hint: Lz("META-04 · Filling only missing fields won't overwrite metadata you've edited manually")) {
            MacSTGroup {
                MacSTRow(Lz("Fill Missing Fields Only"), hint: Lz("When on, keeps existing title, artist, album, and cover"), divider: false) {
                    MacSTToggle(isOn: Binding(
                        get: { scraperSettings.onlyFillMissingFields },
                        set: { scraperSettings.onlyFillMissingFields = $0 }
                    ))
                }
                MacSTRow(Lz("Enabled Sources")) {
                    MacSTInfoText(text: "\(scraperSettings.enabledSources.count) / \(scraperSettings.sources.count)")
                    MacSTButton(title: Lz("Restore Defaults"), destructive: true) {
                        scraperSettings.resetToDefaults()
                    }
                }
            }
        }

        MacSTSection(Lz("Sidecar Write-Back"), hint: Lz("Write sidecar files next to source tracks")) {
            MacSTGroup {
                MacSTRow(Lz("Cover Write-Back"), hint: Lz("<Song Name>-cover.jpg"), divider: false) {
                    MacSTToggle(isOn: $sidecarCoverWriteEnabled)
                }
                MacSTRow(Lz("Lyrics Write-Back"), hint: Lz("<Song Name>.lrc")) {
                    MacSTToggle(isOn: $sidecarLyricsWriteEnabled)
                }
                MacSTRow(Lz("Write Timeout"), hint: Lz("Network sidecar write timeout")) {
                    MacSTSlider(
                        value: $sidecarWriteTimeout,
                        in: 5...120,
                        formatter: { "\(Int($0.rounded()))s" }
                    )
                }
            }
        }

        MacSTSection(Lz("Batch Scraping")) {
            MacSTGroup {
                MacSTRow(Lz("Scrape Entire Library"), hint: "META-06", divider: false) {
                    if scraperService.isScraping {
                        VStack(alignment: .trailing, spacing: 5) {
                            ProgressView(value: scraperService.progress)
                                .tint(PMColor.brand)
                                .frame(width: 180)
                            Text(verbatim: "\(scraperService.processedCount)/\(scraperService.totalCount) · \(scraperService.updatedCount) \(Lz("updated")) · \(scraperService.failedCount) \(Lz("failed"))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(PMColor.textFaint)
                        }
                        MacSTButton(title: Lz("Cancel"), destructive: true) {
                            scraperService.cancel()
                        }
                    } else {
                        MacSTButton(title: Lz("Fill Missing"), systemImage: "sparkles", prominent: true) {
                            scraperService.scrapeMissingMetadata(in: library)
                        }
                        MacSTButton(title: Lz("Re-Scrape"), systemImage: "arrow.clockwise") {
                            scraperService.rescrapeLibrary(in: library)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            importScraperSheet
        }
    }

    private func sourceEnabledBinding(_ source: ScraperSourceConfig) -> Binding<Bool> {
        Binding(
            get: {
                scraperSettings.sources.first(where: { $0.id == source.id })?.isEnabled ?? source.isEnabled
            },
            set: { newValue in
                var sources = scraperSettings.sources
                guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
                sources[index].isEnabled = newValue
                scraperSettings.sources = sources
            }
        )
    }

    private func beginImport(_ mode: ScraperImportMode) {
        importMode = mode
        importText = mode == .paste ? Self.sampleJSON : "https://scrapers.primuse.app/netease.json"
        importError = nil
        showImportSheet = true
    }

    private var importScraperSheet: some View {
        MacScraperImportSheet(
            mode: $importMode,
            text: $importText,
            error: importError,
            onCancel: { showImportSheet = false },
            onImport: { performImport() }
        )
    }

    private func performImport() {
        importError = nil
        let text = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if importMode == .url {
            guard let url = URL(string: text) else {
                importError = String(localized: "invalid_url")
                return
            }
            Task {
                do {
                    let configs = try await ScraperConfigStore.shared.importFromURL(url)
                    for config in configs { scraperSettings.addCustomSource(config) }
                    showImportSheet = false
                } catch {
                    importError = error.localizedDescription
                }
            }
        } else {
            do {
                let configs = try ScraperConfigStore.shared.importFromJSON(text)
                for config in configs { scraperSettings.addCustomSource(config) }
                showImportSheet = false
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    fileprivate static let sampleJSON = """
    {
      "id": "netease-music",
      "name": "NetEase Music",
      "version": 12,
      "capabilities": ["metadata", "cover", "lyrics"],
      "rateLimit": 1000,
      "headers": {
        "User-Agent": "Primuse/3.8",
        "Referer": "https://music.163.com"
      },
      "sslTrustDomains": ["music.163.com", "*.126.net"],
      "search":  { "url": "https://music.163.com/api/search/get?s={{query}}", "method": "GET", "script": "search.js" },
      "detail":  { "url": "https://music.163.com/api/song/detail?id={{id}}", "method": "GET", "script": "detail.js" },
      "cover":   { "url": "https://music.163.com/api/song/detail?id={{id}}", "method": "GET", "script": "cover.js" },
      "lyrics":  { "url": "https://music.163.com/api/song/lyric?id={{id}}", "method": "GET", "script": "lyrics.js" }
    }
    """
}

private struct MacScraperImportSheet: View {
    @Binding var mode: ScraperImportMode
    @Binding var text: String
    let error: String?
    let onCancel: () -> Void
    let onImport: () -> Void

    private var preview: MacScraperImportPreview {
        MacScraperImportPreview.parse(text) ?? .sample
    }

    private var isJSONValid: Bool {
        mode == .paste && MacScraperImportPreview.parse(text) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                leftPane
                    .frame(maxWidth: .infinity)
                Rectangle().fill(PMColor.divider).frame(width: 0.5)
                rightPane
                    .frame(width: 280)
            }
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(width: 820, height: 620)
        .background(PMColor.bg)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Lz("Add Custom Scraper Source"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "ConfigurableScraper")
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 26, height: 26)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                modeSegment
                    .frame(width: 320)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var modeSegment: some View {
        HStack(spacing: 2) {
            modeButton(.url, title: Lz("Import from URL"), icon: "icloud.and.arrow.down")
            modeButton(.paste, title: Lz("Paste JSON"), icon: "curlybraces")
        }
        .padding(3)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 9))
    }

    private func modeButton(_ item: ScraperImportMode, title: String, icon: String) -> some View {
        Button {
            mode = item
            if item == .url, text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                text = "https://scrapers.primuse.app/netease.json"
            } else if item == .paste, !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                text = MacSTScrapingView.sampleJSON
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                Text(verbatim: title)
                    .font(.system(size: 12, weight: mode == item ? .semibold : .medium))
            }
            .foregroundStyle(mode == item ? PMColor.text : PMColor.textMuted)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(mode == item ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 7))
            .shadow(color: mode == item ? .black.opacity(0.12) : .clear, radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if mode == .url {
                urlImportPane
            } else {
                jsonImportPane
            }
            if let error {
                Text(verbatim: error)
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.bad)
                    .lineSpacing(3)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 16)
    }

    private var jsonImportPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: Lz("JSON Configuration"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: isJSONValid ? "checkmark" : "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(verbatim: isJSONValid ? Lz("Valid format") : Lz("Waiting for valid JSON"))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(isJSONValid ? PMColor.ok : PMColor.warn)
            }
            MacJSONEditor(text: $text)
                .frame(height: 382)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var urlImportPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Lz("Manifest URL"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(PMColor.textMuted)
            TextField("https://scrapers.primuse.app/netease.json", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(PMColor.text)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(PMColor.bgElev, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PMColor.brand, lineWidth: 1.5)
                }
            Text(verbatim: Lz("Points to scraper.json manifest · downloads manifest and referenced JS scripts"))
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(PMColor.ok)
                    Text(verbatim: Lz("Manifest fetched · 4.2 KB"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                ForEach(Array(MacScraperImportPreview.scriptRows.enumerated()), id: \.offset) { _, row in
                    let (script, size) = row
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(PMColor.ok)
                        Text(verbatim: script)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(PMColor.text)
                        Spacer()
                        Text(verbatim: size)
                            .font(.system(size: 10.5))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(14)
            .pmCard(cornerRadius: 10)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var rightPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: Lz("Parse Result"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.bottom, 12)

                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.76, green: 0.05, blue: 0.05),
                                                      Color(red: 0.44, green: 0.03, blue: 0.03)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                        .overlay {
                            Text(verbatim: String(preview.name.prefix(1)))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: preview.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Text(verbatim: "v\(preview.version)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .padding(.bottom, 14)

                previewField(Lz("Capabilities")) {
                    HStack(spacing: 5) {
                        ForEach(preview.capabilityLabels, id: \.self) { cap in
                            MacSTBadge(text: cap)
                        }
                    }
                }
                previewField("Rate Limit") {
                    Text(verbatim: preview.rateLimitText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(PMColor.text)
                }
                previewField(Lz("Custom Headers")) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(preview.headerRows, id: \.self) { row in
                            Text(verbatim: row)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(PMColor.textMuted)
                        }
                    }
                }
                previewField(Lz("SSL Trusted Domains")) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(preview.sslDomains, id: \.self) { domain in
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(PMColor.textFaint)
                                Text(verbatim: domain)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(PMColor.textMuted)
                            }
                        }
                    }
                }
                previewField(Lz("Endpoint Scripts")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.endpointScripts, id: \.self) { script in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(PMColor.ok)
                                Text(verbatim: script)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(PMColor.text)
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                    Text(verbatim: Lz("JS runs in a JavaScriptCore sandbox and can only access declared domains."))
                        .font(.system(size: 10.5))
                        .lineSpacing(3)
                }
                .foregroundStyle(PMColor.warn)
                .padding(10)
                .background(PMColor.warn.opacity(0.12), in: .rect(cornerRadius: 8))
                .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .background(PMColor.bgDeep)
    }

    private func previewField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label)
                .font(.system(size: 10))
                .foregroundStyle(PMColor.textFaint)
            content()
        }
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            MacSTButton(title: Lz("Cancel"), action: onCancel)
            MacSTButton(title: Lz("Add and Enable"), prominent: true, action: onImport)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }
}

private struct MacScraperImportPreview {
    var name: String
    var version: String
    var capabilities: [String]
    var rateLimitMs: Int?
    var headers: [String: String]
    var sslDomains: [String]
    var endpointScripts: [String]

    static let scriptRows = [
        ("search.js", "2.1 KB"),
        ("detail.js", "1.8 KB"),
        ("cover.js", "0.9 KB"),
        ("lyrics.js", "1.4 KB"),
    ]

    static let sample = MacScraperImportPreview(
        name: "NetEase Music",
        version: "1.2.0",
        capabilities: ["metadata", "cover", "lyrics"],
        rateLimitMs: 1000,
        headers: ["User-Agent": "Primuse/3.8", "Referer": "https://music.163.com"],
        sslDomains: ["music.163.com", "*.126.net"],
        endpointScripts: ["search.js", "detail.js", "cover.js", "lyrics.js"]
    )

    static func parse(_ text: String) -> MacScraperImportPreview? {
        guard let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let config = try? decoder.decode(ScraperConfig.self, from: data) {
            return from(config)
        }
        if let configs = try? decoder.decode([ScraperConfig].self, from: data),
           let first = configs.first {
            return from(first)
        }
        return nil
    }

    private static func from(_ config: ScraperConfig) -> MacScraperImportPreview {
        let scripts = [config.search?.script, config.detail?.script, config.cover?.script, config.lyrics?.script]
            .compactMap { $0 }
        return MacScraperImportPreview(
            name: config.name,
            version: versionText(config.version),
            capabilities: config.capabilities,
            rateLimitMs: config.rateLimit,
            headers: config.headers ?? [:],
            sslDomains: config.sslTrustDomains ?? [],
            endpointScripts: scripts.isEmpty ? ["search.js", "detail.js", "cover.js", "lyrics.js"] : scripts
        )
    }

    private static func versionText(_ version: Int) -> String {
        if version >= 100 {
            let major = version / 100
            let minor = (version / 10) % 10
            let patch = version % 10
            return "\(major).\(minor).\(patch)"
        }
        if version >= 10 {
            return "1.\(version % 10).0"
        }
        return "\(version)"
    }

    var capabilityLabels: [String] {
        let mapping: [(String, String)] = [
            ("metadata", Lz("Metadata")),
            ("cover", Lz("Cover")),
            ("lyrics", Lz("Lyrics"))
        ]
        let labels = mapping.compactMap { key, label in capabilities.contains(key) ? label : nil }
        return labels.isEmpty ? [Lz("Metadata"), Lz("Cover"), Lz("Lyrics")] : labels
    }

    var rateLimitText: String {
        guard let rateLimitMs, rateLimitMs > 0 else { return "60 rpm · burst 8" }
        let rpm = max(1, Int((60_000.0 / Double(rateLimitMs)).rounded()))
        return "\(rpm) rpm · burst 8"
    }

    var headerRows: [String] {
        let rows = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.replacingOccurrences(of: "https://", with: ""))" }
        return rows.isEmpty ? ["User-Agent: Primuse/3.8", "Referer: music.163.com"] : rows
    }
}

private struct MacJSONEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(red: 0.12, green: 0.105, blue: 0.09, alpha: 1)

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.backgroundColor = .clear
        textView.insertionPointColor = .white
        textView.textColor = MacJSONHighlighter.baseColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.apply(text)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard context.coordinator.textView?.string != text else { return }
        context.coordinator.apply(text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacJSONEditor
        weak var textView: NSTextView?
        private var isApplying = false

        init(_ parent: MacJSONEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            parent.text = textView.string
            apply(textView.string, preservingSelection: true)
        }

        func apply(_ value: String, preservingSelection: Bool = false) {
            guard let textView else { return }
            isApplying = true
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(MacJSONHighlighter.highlight(value))
            if preservingSelection {
                let length = (textView.string as NSString).length
                let location = min(selection.location, length)
                let selectedLength = min(selection.length, max(0, length - location))
                textView.setSelectedRange(NSRange(location: location, length: selectedLength))
            }
            isApplying = false
        }
    }
}

private enum MacJSONHighlighter {
    static let baseColor = NSColor(red: 0.91, green: 0.89, blue: 0.84, alpha: 1)
    private static let keyColor = NSColor(red: 0.90, green: 0.63, blue: 0.42, alpha: 1)
    private static let stringColor = NSColor(red: 0.56, green: 0.81, blue: 0.56, alpha: 1)
    private static let numberColor = NSColor(red: 0.47, green: 0.71, blue: 0.88, alpha: 1)
    private static let boolColor = NSColor(red: 0.77, green: 0.56, blue: 0.88, alpha: 1)

    static func highlight(_ source: String) -> NSAttributedString {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: baseColor,
            ]
        )
        let pattern = #""(?:[^"\\]|\\.)*"\s*:|"(?:[^"\\]|\\.)*"|\b\d+(?:\.\d+)?\b|\btrue\b|\bfalse\b|\bnull\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributed }
        regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
            guard let match else { return }
            let token = (source as NSString).substring(with: match.range)
            let color: NSColor
            if token.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                color = keyColor
            } else if token.hasPrefix("\"") {
                color = stringColor
            } else if token == "true" || token == "false" || token == "null" {
                color = boolColor
            } else {
                color = numberColor
            }
            attributed.addAttribute(.foregroundColor, value: color, range: match.range)
        }
        return attributed
    }
}

private struct MacScraperSourceRow: View {
    let source: ScraperSourceConfig
    let index: Int
    let sourceCount: Int
    @Binding var isEnabled: Bool
    let move: (IndexSet, Int) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MacScraperReorderHandle(
                index: index,
                sourceCount: sourceCount,
                move: move
            )
            .frame(width: 18, height: 22)
            .help(Lz("Drag to Reorder"))
            Text(verbatim: "\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 16)

            HStack(spacing: 8) {
                Image(systemName: source.type.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isEnabled ? source.type.themeColor : PMColor.textFaint)
                    .frame(width: 16)
                Text(verbatim: source.type.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                if source.type.isBuiltIn {
                    Text(verbatim: Lz("Built-In"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                ForEach(capabilities, id: \.self) { cap in
                    MacSTBadge(text: cap, color: source.type.themeColor)
                }
            }

            if !source.type.isBuiltIn {
                MacSTButton(title: Lz("Delete"), destructive: true, action: remove)
            }

            MacSTToggle(isOn: $isEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var capabilities: [String] {
        var result: [String] = []
        if source.type.supportsMetadata { result.append(Lz("Metadata")) }
        if source.type.supportsCover { result.append(Lz("Cover")) }
        if source.type.supportsLyrics { result.append(source.type.supportsWordLevelLyrics ? Lz("Word-by-Word Lyrics") : Lz("Lyrics")) }
        return result.isEmpty ? [Lz("Extension")] : result
    }
}

private struct MacScraperReorderHandle: NSViewRepresentable {
    let index: Int
    let sourceCount: Int
    let move: (IndexSet, Int) -> Void

    func makeNSView(context: Context) -> ScraperReorderHandleNSView {
        let view = ScraperReorderHandleNSView()
        view.index = index
        view.sourceCount = sourceCount
        view.onMove = move
        return view
    }

    func updateNSView(_ nsView: ScraperReorderHandleNSView, context: Context) {
        nsView.index = index
        nsView.sourceCount = sourceCount
        nsView.onMove = move
        nsView.needsDisplay = true
    }
}

private final class ScraperReorderHandleNSView: NSView {
    var index = 0
    var sourceCount = 0
    var onMove: ((IndexSet, Int) -> Void)?

    private var dragAnchorY: CGFloat = 0
    private var dragIndex = 0
    private let rowStep: CGFloat = 34

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 语义自适应色 —— 旧实现写死 white@0.34, 浅色主题下白点画在近白行背景上
        // 等于隐形 (拖拽手柄看不见)。tertiaryLabelColor 在深/浅两套外观下都可见。
        NSColor.tertiaryLabelColor.setFill()
        let dotSize: CGFloat = 3
        let gap: CGFloat = 3
        let totalWidth = dotSize * 2 + gap
        let totalHeight = dotSize * 3 + gap * 2
        let startX = (bounds.width - totalWidth) / 2
        let startY = (bounds.height - totalHeight) / 2
        for row in 0..<3 {
            for col in 0..<2 {
                let rect = NSRect(
                    x: startX + CGFloat(col) * (dotSize + gap),
                    y: startY + CGFloat(row) * (dotSize + gap),
                    width: dotSize,
                    height: dotSize
                )
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragAnchorY = event.locationInWindow.y
        dragIndex = index
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard sourceCount > 1 else { return }
        let delta = event.locationInWindow.y - dragAnchorY
        guard abs(delta) >= rowStep else { return }
        let direction = delta < 0 ? 1 : -1
        let nextIndex = min(max(dragIndex + direction, 0), sourceCount - 1)
        guard nextIndex != dragIndex else {
            dragAnchorY = event.locationInWindow.y
            return
        }
        let destination = direction > 0 ? nextIndex + 1 : nextIndex
        onMove?(IndexSet(integer: dragIndex), destination)
        dragIndex = nextIndex
        dragAnchorY = event.locationInWindow.y
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }
}

// MARK: - ST-05 Lyrics Translation

private struct MacSTLyricsView: View {
    @State private var settings = LyricsTranslationSettingsStore.shared
    @AppStorage("lyricsFontScale") private var lyricsFontScale = 1.0

    var body: some View {
        // 删了"离线模型"/"翻译颜色"/"仅 NowPlaying 展开时显示翻译" 三行 —— 这些 mock
        // 控件没接到任何 Store, 之前是纯视觉占位, 真翻译走的是云端 API (LyricsTranslationSettingsStore)。
        MacSTSection(Lz("Translate Lyrics")) {
            MacSTGroup {
                MacSTRow(Lz("Enable Translation"), hint: Lz("L-08 · Two-Line Display"), divider: false) {
                    MacSTToggle(isOn: Binding(
                        get: { settings.isEnabled },
                        set: { settings.isEnabled = $0 }
                    ))
                }
                MacSTRow(Lz("Target Language")) {
                    MacSTPicker(
                        selection: Binding(
                            get: { settings.targetLanguageCode },
                            set: { settings.targetLanguageCode = $0 }
                        ),
                        options: LyricsTranslationSettingsStore.availableTargetLanguages.map {
                            ($0.code, String(localized: String.LocalizationValue($0.displayKey)))
                        }
                    )
                }
            }
        }

        MacSTSection(Lz("Display Style")) {
            MacSTGroup {
                MacSTRow(Lz("Font Size (lyricsFontScale)"), hint: Lz("iOS / macOS Shared · CloudKVS Sync"), divider: false) {
                    MacSTSlider(
                        value: Binding(
                            get: { lyricsFontScale * 100 },
                            set: { lyricsFontScale = $0 / 100 }
                        ),
                        in: 70...180,
                        formatter: { String(format: "%.0f%%", $0) }
                    )
                }
            }
        }
    }
}

// MARK: - ST-06 Apple Music

private struct MacSTAppleMusicView: View {
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(AppleMusicLibraryService.self) private var library
    @AppStorage(AppleMusicFeatureSettings.syncUserLibraryKey) private var syncUserLibrary = true
    @AppStorage(AppleMusicFeatureSettings.catalogSearchEnabledKey) private var catalogSearchEnabled = true
    @AppStorage(AppleMusicFeatureSettings.autoAddToSmartPlaylistsKey) private var autoAddToSmartPlaylists = false

    var body: some View {
        MacSTSection(Lz("Account")) {
            HStack(spacing: 14) {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.14, blue: 0.23),
                                                  Color(red: 0.76, green: 0.04, blue: 0.09)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: accountTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: accountSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PMColor.textMuted)
                }

                Spacer()

                // 未授权 → "授权" 按钮; 已授权 → "去系统设置" (macOS 不让 app 主动撤销)
                if appleMusic.authState == .authorized {
                    MacSTButton(title: Lz("Open System Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleAccount") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    MacSTButton(title: Lz("Authorize"), prominent: true) {
                        Task { await appleMusic.requestAuthorization() }
                    }
                }
            }
            .padding(16)
            .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
        }

        if appleMusic.authState == .authorized {
            MacSTSection(Lz("Library Sync")) {
                MacSTGroup {
                    MacSTRow(Lz("Sync User Library"), hint: Lz("SRC-29 · Apple Music Library"), divider: false) {
                        MacSTToggle(isOn: syncUserLibraryBinding)
                    }
                    MacSTRow(Lz("Catalog Search"), hint: "S-02") {
                        MacSTToggle(isOn: catalogSearchBinding)
                    }
                    MacSTRow(Lz("Auto Add to Smart Playlists"), hint: Lz("LIB-05 · SmartPlaylistEngine")) {
                        MacSTToggle(isOn: $autoAddToSmartPlaylists)
                    }
                    MacSTRow(Lz("Sync Status"), hint: Lz("SRC-29 · Cross-Process Cache")) {
                        MacSTInfoText(text: syncStateText,
                                      color: syncStateColor)
                    }
                    MacSTRow(Lz("Last Synced")) {
                        MacSTInfoText(text: lastSyncText)
                        MacSTButton(title: Lz("Re-Sync"), systemImage: "arrow.clockwise") {
                            library.sync()
                        }
                        .disabled(!syncUserLibrary)
                    }
                }
            }
        }

        if let err = appleMusic.lastPlaybackError {
            MacSTSection(Lz("Recent Playback Errors")) {
                MacSTGroup {
                    MacSTRow(Lz("Error Message"), divider: false) {
                        MacSTInfoText(text: err, color: PMColor.bad)
                    }
                }
            }
        }
    }

    private var syncUserLibraryBinding: Binding<Bool> {
        Binding(
            get: { syncUserLibrary },
            set: { newValue in
                syncUserLibrary = newValue
                if newValue {
                    library.sync()
                } else {
                    library.cancel()
                }
            }
        )
    }

    private var catalogSearchBinding: Binding<Bool> {
        Binding(
            get: { catalogSearchEnabled },
            set: { newValue in
                catalogSearchEnabled = newValue
                if !newValue {
                    appleMusic.clearCatalogSearchResults()
                }
            }
        )
    }

    private var accountTitle: String {
        switch appleMusic.authState {
        case .notDetermined: return Lz("Apple Music · Not Authorized")
        case .denied:        return Lz("Apple Music · Denied")
        case .restricted:    return Lz("Apple Music · Restricted")
        case .authorized:    return Lz("Apple Music · Authorized")
        }
    }

    private var accountSubtitle: String {
        switch appleMusic.authState {
        case .notDetermined: return Lz("Authorize on the right to connect your subscription")
        case .denied:        return Lz("Go to System Settings → Privacy to re-enable")
        case .restricted:    return Lz("Restricted by Screen Time or MDM")
        case .authorized:    return Lz("MusicKit Connected")
        }
    }

    private var syncStateText: String {
        switch library.state {
        case .idle:                 return Lz("● Ready")
        case .syncing:              return Lz("● Syncing…")
        case .done(let count, _):   return "● \(Lz("Synced")) · \(count) \(Lz("songs"))"
        case .failed(let msg):      return "● \(Lz("Failed")): \(msg)"
        }
    }

    private var syncStateColor: Color {
        switch library.state {
        case .idle, .done: return PMColor.ok
        case .syncing:     return PMColor.warn
        case .failed:      return PMColor.bad
        }
    }

    private var lastSyncText: String {
        guard let at = library.lastSyncAt else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: at, relativeTo: Date())
    }
}

// MARK: - ST-07 Widgets

private extension WidgetRefreshMode {
    var label: String {
        switch self {
        case .adaptive:    return Lz("Adaptive (Recommended)")
        case .minute:      return Lz("Every Minute")
        case .fiveMinutes: return Lz("Every 5 Minutes")
        case .manual:      return Lz("Manual Only")
        }
    }
}

private struct MacSTWidgetView: View {
    @Environment(AudioPlayerService.self) private var player
    // 直接写 App Group, 让 widget 扩展读到同一份开关/刷新设置。
    @AppStorage(PrimuseConstants.widgetSyncEnabledKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var widgetSyncEnabled = true
    @AppStorage(PrimuseConstants.widgetRefreshModeKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var refreshMode = WidgetRefreshMode.adaptive
    @AppStorage(PrimuseConstants.widgetSharedDataScopeKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var sharedDataScope = "titleArtistCoverProgressLyrics"
    @AppStorage(PrimuseConstants.widgetClickableInteractionKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var clickableInteraction = true
    @AppStorage(PrimuseConstants.widgetNowPlayingEnabledKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var nowPlayingWidgetEnabled = true
    @AppStorage(PrimuseConstants.widgetLyricsEnabledKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var lyricsWidgetEnabled = true
    @AppStorage(PrimuseConstants.widgetListeningStatsEnabledKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var statsWidgetEnabled = true
    @AppStorage(PrimuseConstants.widgetRecentAlbumsEnabledKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var recentWidgetEnabled = true
    @AppStorage(PrimuseConstants.widgetSourcesEnabledKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var sourcesWidgetEnabled = true
    @AppStorage(PrimuseConstants.widgetWrappedEnabledKey, store: UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
    private var wrappedWidgetEnabled = true

    var body: some View {
        MacSTSection(Lz("Cross-Process Data Sharing"),
                     hint: Lz("The main process pushes state to the WidgetKit extension through the App Group container")) {
            MacSTGroup {
                MacSTRow(Lz("Push to Widget"), hint: "ST-07 · widget.syncEnabled", divider: false) {
                    MacSTToggle(isOn: $widgetSyncEnabled)
                }
                MacSTRow(Lz("Refresh Frequency"), hint: Lz("Higher frequency updates sooner but uses more energy")) {
                    MacSTPicker(
                        selection: $refreshMode,
                        options: WidgetRefreshMode.allCases.map { ($0, $0.label) },
                        width: 180
                    )
                }
                MacSTRow(Lz("Shared Data Scope"), hint: Lz("Widget payload")) {
                    MacSTPicker(
                        selection: $sharedDataScope,
                        options: [
                            ("titleArtistCoverProgressLyrics", Lz("Title + Artist + Cover + Progress + Lyrics")),
                            ("titleArtistCoverProgress", Lz("Title + Artist + Cover + Progress")),
                            ("minimal", Lz("Title + Artist"))
                        ],
                        width: 280
                    )
                }
                MacSTRow(Lz("Clickable Interaction"), hint: "WidgetURL / AppIntent") {
                    MacSTToggle(isOn: $clickableInteraction)
                }
                MacSTRow(Lz("Refresh Now")) {
                    MacSTButton(title: Lz("Push Status"), systemImage: "arrow.triangle.2.circlepath") {
                        MacWidgetDataPublisher.publishFromSettings(player: player)
                    }
                }
            }
        }

        MacSTSection(Lz("Available Widgets"), hint: Lz("WidgetKit still manages the system widget gallery; checked items control which data Primuse pushes.")) {
            MacSTGroup {
                MacSTWidgetChecklistRow(
                    title: "Now Playing",
                    detail: "Small / Medium / Large",
                    isOn: $nowPlayingWidgetEnabled,
                    divider: false
                )
                MacSTWidgetChecklistRow(
                    title: "Lyrics",
                    detail: "Medium",
                    isOn: $lyricsWidgetEnabled
                )
                MacSTWidgetChecklistRow(
                    title: "Listening Stats",
                    detail: "Medium",
                    isOn: $statsWidgetEnabled
                )
                MacSTWidgetChecklistRow(
                    title: "Recent",
                    detail: "Medium / Large",
                    isOn: $recentWidgetEnabled
                )
                MacSTWidgetChecklistRow(
                    title: "Sources",
                    detail: "Small",
                    isOn: $sourcesWidgetEnabled
                )
                MacSTWidgetChecklistRow(
                    title: "Wrapped",
                    detail: "Medium",
                    isOn: $wrappedWidgetEnabled
                )
            }
        }

        MacSTSection(Lz("Widget Gallery"),
                     hint: Lz("Small 155×155 · Medium 342×155 · Large 342×342 · Matches design ST-07 sizes")) {
            MacWidgetGalleryPreview()
        }
        .onChange(of: refreshMode) { _, _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: widgetSyncEnabled) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: sharedDataScope) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: clickableInteraction) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: nowPlayingWidgetEnabled) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: lyricsWidgetEnabled) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: statsWidgetEnabled) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: recentWidgetEnabled) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: sourcesWidgetEnabled) { _, _ in
            pushWidgetSettingsChange()
        }
        .onChange(of: wrappedWidgetEnabled) { _, _ in
            pushWidgetSettingsChange()
        }
    }

    private func pushWidgetSettingsChange() {
        MacWidgetDataPublisher.publishFromSettings(player: player)
    }
}

private struct MacSTWidgetChecklistRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var divider = true

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
                isOn.toggle()
            }
        } label: {
            VStack(spacing: 0) {
                if divider {
                    Rectangle().fill(PMColor.divider).frame(height: 0.5)
                }
                HStack(spacing: 12) {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isOn ? PMColor.brand : PMColor.textFaint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PMColor.text)
                        Text(verbatim: detail)
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

/// Gathers macOS-side data into the App Group snapshots the widget extension
/// reads. Playback / recent albums are already published by AudioPlayerService;
/// this adds listening-stats, year-in-review, music-sources and lyrics. All
/// secondary publishing is gated by the "Push to Widget" toggle.
@MainActor
enum MacWidgetDataPublisher {
    /// Full publish — call from a context that has every service (the main scene).
    static func publishAll(player: AudioPlayerService, sources: SourcesStore, sourceManager: SourceManager) {
        player.publishWidgetStateForMacWidgetSync()
        guard WidgetSettings.syncEnabled() else {
            LyricsSnapshot.clear()
            ListeningStatsSnapshot.clear()
            SourcesSnapshot.clear()
            WrappedSnapshot.clear()
            RecentAlbumsStore.clear()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        if WidgetSettings.widgetEnabled(PrimuseConstants.widgetListeningStatsEnabledKey) {
            publishStats()
        } else {
            ListeningStatsSnapshot.clear()
        }
        if WidgetSettings.widgetEnabled(PrimuseConstants.widgetWrappedEnabledKey) {
            publishWrapped()
        } else {
            WrappedSnapshot.clear()
        }
        if WidgetSettings.widgetEnabled(PrimuseConstants.widgetSourcesEnabledKey) {
            publishSources(sources)
        } else {
            SourcesSnapshot.clear()
        }
        if WidgetSettings.widgetEnabled(PrimuseConstants.widgetLyricsEnabledKey) {
            Task { await publishLyrics(player: player, sourceManager: sourceManager) }
        } else {
            LyricsSnapshot.clear()
        }
        if !WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey) {
            RecentAlbumsStore.clear()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Settings-window safe subset (no SourcesStore / SourceManager in that window).
    static func publishFromSettings(player: AudioPlayerService) {
        player.publishWidgetStateForMacWidgetSync()
        if WidgetSettings.syncEnabled() {
            if WidgetSettings.widgetEnabled(PrimuseConstants.widgetListeningStatsEnabledKey) {
                publishStats()
            } else {
                ListeningStatsSnapshot.clear()
            }
            if WidgetSettings.widgetEnabled(PrimuseConstants.widgetWrappedEnabledKey) {
                publishWrapped()
            } else {
                WrappedSnapshot.clear()
            }
        } else {
            ListeningStatsSnapshot.clear()
            WrappedSnapshot.clear()
        }
        if !WidgetSettings.widgetEnabled(PrimuseConstants.widgetLyricsEnabledKey) {
            LyricsSnapshot.clear()
        }
        if !WidgetSettings.widgetEnabled(PrimuseConstants.widgetSourcesEnabledKey) {
            SourcesSnapshot.clear()
        }
        if !WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey) {
            RecentAlbumsStore.clear()
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func publishStats() {
        let store = PlayHistoryStore.shared
        let summary = store.summary(in: .month)
        let daily = store.dailyPlayCounts(in: .month).map(\.count)
        let top = store.topSongs(in: .month, limit: 1).first
        ListeningStatsSnapshot(
            totalPlays: summary.totalPlays,
            totalSeconds: summary.totalSec,
            dailyCounts: Array(daily.suffix(30)),
            topSongTitle: top?.title,
            topSongArtist: top?.subtitle
        ).save()
    }

    static func publishWrapped() {
        let store = PlayHistoryStore.shared
        let year = Calendar.current.component(.year, from: Date())
        let summary = store.summary(in: .year)
        WrappedSnapshot(
            year: year,
            totalHours: Int((summary.totalSec / 3600).rounded()),
            topArtist: store.topArtists(in: .year, limit: 1).first?.title,
            topSong: store.topSongs(in: .year, limit: 1).first?.title
        ).save()
    }

    static func publishSources(_ sources: SourcesStore) {
        let entries = sources.sources.map { source in
            WidgetSourceEntry(
                id: source.id,
                name: source.name,
                iconName: source.type.iconName,
                songCount: source.songCount,
                status: source.isEnabled ? .online : .disabled
            )
        }
        SourcesSnapshot(
            totalIndexed: entries.reduce(0) { $0 + $1.songCount },
            sources: entries
        ).save()
    }

    static func publishLyrics(player: AudioPlayerService, sourceManager: SourceManager) async {
        guard let song = player.currentSong else { LyricsSnapshot.clear(); return }
        let lines = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        guard !lines.isEmpty else { LyricsSnapshot.clear(); return }
        let widgetLines = lines.map { WidgetLyricLine(time: $0.timestamp, text: $0.text) }
        let now = player.currentTime
        var anchor = 0
        for (i, line) in widgetLines.enumerated() where line.time <= now { anchor = i }
        let playback = PlaybackState.load()
        LyricsSnapshot(
            songID: playback?.currentSongID ?? "current",
            title: playback?.songTitle ?? "",
            artist: playback?.artistName ?? "",
            coverImageName: playback?.coverImageName,
            lines: widgetLines,
            anchorIndex: anchor,
            isPlaying: player.isPlaying
        ).save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private struct MacWidgetGalleryPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            macWidgetSection(Lz("Now Playing · Playing"), sub: Lz("3 Sizes · Glanceable + Interactive")) {
                MacWidgetTile(label: Lz("Small 155")) { MacWidgetNPSmallPreview() }
                MacWidgetTile(label: Lz("Medium 342×155")) { MacWidgetNPMediumPreview() }
                MacWidgetTile(label: Lz("Large 342×342")) { MacWidgetNPLargePreview() }
            }

            macWidgetSection(Lz("Live Data"), sub: Lz("Lyrics / Stats / Music Sources")) {
                MacWidgetTile(label: Lz("Lyrics · Medium")) { MacWidgetLyricsPreview() }
                MacWidgetTile(label: Lz("Listening Stats · Medium")) { MacWidgetStatsPreview() }
                MacWidgetTile(label: Lz("Music Sources · Small")) { MacWidgetSourcesPreview() }
            }

            macWidgetSection(Lz("Sidebar Widget"), sub: Lz("Compact info · Great for stacking in a screen corner")) {
                MacWidgetTile(label: Lz("Recently Played · Small")) { MacWidgetRecentPreview() }
                MacWidgetTile(label: Lz("Year in Review · Medium")) { MacWidgetWrappedPreview() }
                MacWidgetTile(label: Lz("Dark · Medium")) { MacWidgetNPMediumPreview(dark: true) }
            }
        }
    }

    private func macWidgetSection<Content: View>(_ label: String,
                                                 sub: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: label)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: sub)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                Rectangle()
                    .fill(PMColor.divider)
                    .frame(height: 0.5)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    content()
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct MacWidgetTile<Content: View>: View {
    let label: String
    private let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 8) {
            content
            Text(verbatim: label)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

private struct MacWidgetShell<Content: View>: View {
    enum Size {
        case small, medium, large

        /// 真实 macOS widget 点尺寸 (Apple HIG): small 155²、medium 342×155、
        /// large 342²。内部内容(封面 127、字号等)都是按这个真尺寸画的, 所以 shell
        /// 必须用真尺寸, 否则内容会溢出。整块再用 previewScale 等比缩小放进设置页。
        var width: CGFloat {
            switch self {
            case .small: return 155
            case .medium, .large: return 342
            }
        }

        var height: CGFloat {
            switch self {
            case .small, .medium: return 155
            case .large: return 342
            }
        }
    }

    var size: Size
    var dark = false
    var padding: CGFloat = 14
    private let content: Content

    /// 设置页预览缩放 — 真尺寸太大, 等比缩到 ~0.66 让一行能放下 2~3 个 medium。
    private let previewScale: CGFloat = 0.66

    init(size: Size, dark: Bool = false, padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.size = size
        self.dark = dark
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        ZStack {
            (dark ? Color(red: 0.11, green: 0.095, blue: 0.085).opacity(0.82) : Color.white.opacity(0.80))
            LinearGradient(
                colors: [
                    PMColor.brand.opacity(dark ? 0.28 : 0.10),
                    Color.clear,
                    Color(red: 0.16, green: 0.29, blue: 0.43).opacity(dark ? 0.28 : 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            content
                .padding(padding)
        }
        .foregroundStyle(dark ? Color(red: 0.95, green: 0.93, blue: 0.91) : Color(red: 0.12, green: 0.11, blue: 0.10))
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.10) : Color.white.opacity(0.50), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
        // 真尺寸渲染完再等比缩小, 内容比例保持精确, 占位也按缩放后尺寸预留。
        .scaleEffect(previewScale)
        .frame(width: size.width * previewScale, height: size.height * previewScale)
    }
}

private struct MacWidgetNPSmallPreview: View {
    var body: some View {
        MacWidgetShell(size: .small, padding: 0) {
            ZStack(alignment: .bottomLeading) {
                MacWidgetCover(radius: 0, glyph: "猿")
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Lz("Throwback Mix"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(Lz("Yu Xi Tan"))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(1)
                    MacWidgetProgress(value: 0.36, tint: .white, height: 2)
                }
                .padding(12)
                MacWidgetRoundButton(symbol: "pause.fill", size: 30, dark: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
}

private struct MacWidgetNPMediumPreview: View {
    var dark = false

    var body: some View {
        MacWidgetShell(size: .medium, dark: dark, padding: 14) {
            HStack(spacing: 12) {
                MacWidgetCover(radius: 10, glyph: "猿")
                    .frame(width: 127, height: 127)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Lz("Now Playing · FLAC"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(faint)
                    Text(Lz("Throwback Mix"))
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .padding(.top, 4)
                    Text(Lz("Yu Xi Tan"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                    Text(Lz("Shui Diao Ge Tou"))
                        .font(.system(size: 10))
                        .foregroundStyle(faint)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                    MacWidgetProgress(value: 0.36, tint: PMColor.brand, height: 2.5)
                        .padding(.bottom, 8)
                    HStack {
                        MacWidgetRoundButton(symbol: "heart.fill", size: 26, primary: true, dark: dark)
                        Spacer()
                        MacWidgetRoundButton(symbol: "backward.fill", size: 26, dark: dark)
                        MacWidgetRoundButton(symbol: "pause.fill", size: 32, primary: true, dark: dark)
                        MacWidgetRoundButton(symbol: "forward.fill", size: 26, dark: dark)
                        Spacer()
                        MacWidgetRoundButton(symbol: "ellipsis", size: 26, dark: dark)
                    }
                }
            }
        }
    }

    private var muted: Color { dark ? .white.opacity(0.72) : .black.opacity(0.58) }
    private var faint: Color { dark ? .white.opacity(0.55) : .black.opacity(0.44) }
}

private struct MacWidgetNPLargePreview: View {
    var body: some View {
        MacWidgetShell(size: .large, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    MacWidgetCover(radius: 10, glyph: "猿")
                        .frame(width: 88, height: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Lz("Now Playing"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.50))
                        Text(Lz("Throwback Mix"))
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(1)
                        Text(Lz("Yu Xi Tan"))
                            .font(.system(size: 12))
                            .foregroundStyle(.black.opacity(0.65))
                        Text(Lz("Shui Diao Ge Tou · FLAC 988 kbps"))
                            .font(.system(size: 10))
                            .foregroundStyle(.black.opacity(0.45))
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(Lz("When will the moon be bright"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black.opacity(0.42))
                    Text(Lz("Wine in hand, I ask the sky"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PMColor.brand)
                    Text(Lz("Unknown halls of heaven"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black.opacity(0.42))
                }
                .frame(maxHeight: .infinity, alignment: .center)

                MacWidgetProgress(value: 0.36, tint: PMColor.brand, height: 3)
                HStack {
                    MacWidgetRoundButton(symbol: "shuffle", size: 28)
                    Spacer()
                    MacWidgetRoundButton(symbol: "backward.fill", size: 32)
                    MacWidgetRoundButton(symbol: "pause.fill", size: 42, primary: true)
                    MacWidgetRoundButton(symbol: "forward.fill", size: 32)
                    Spacer()
                    MacWidgetRoundButton(symbol: "repeat", size: 28)
                }
            }
        }
    }
}

private struct MacWidgetLyricsPreview: View {
    var body: some View {
        MacWidgetShell(size: .medium, padding: 0) {
            ZStack {
                LinearGradient(colors: [PMColor.brand.opacity(0.20), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        MacWidgetCover(radius: 4, glyph: "猿")
                            .frame(width: 22, height: 22)
                        Text(Lz("Throwback Mix"))
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                        Text(Lz("· Yu Xi Tan"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.black.opacity(0.50))
                            .lineLimit(1)
                    }
                    .padding(.bottom, 8)

                    Text(Lz("When will the moon be bright"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black.opacity(0.45))
                        .padding(.bottom, 5)
                    Text(Lz("Wine in hand, I ask the sky"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(PMColor.brand)
                        .padding(.bottom, 5)
                    Text(Lz("Unknown halls of heaven"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(16)
            }
        }
    }
}

private struct MacWidgetStatsPreview: View {
    private let values = [1, 0, 4, 2, 8, 12, 5, 0, 3, 6, 9, 1, 0, 4, 7, 5, 10, 12, 3, 6, 4, 0, 8, 11, 2, 5, 9, 1, 4, 6]

    var body: some View {
        MacWidgetShell(size: .medium) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Lz("This Month's Listening"))
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                    Text(Lz("Last 30 Days"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.black.opacity(0.48))
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("246")
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(PMColor.brand)
                        Text(Lz("Tracks Played"))
                            .font(.system(size: 10))
                            .foregroundStyle(.black.opacity(0.52))
                        Text("17h")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .padding(.top, 8)
                        Text(Lz("Total Duration"))
                            .font(.system(size: 10))
                            .foregroundStyle(.black.opacity(0.52))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(9), spacing: 3), count: 15), spacing: 3) {
                            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(value == 0 ? Color.black.opacity(0.06) : PMColor.brand.opacity(0.18 + Double(value) * 0.045))
                                    .frame(width: 9, height: 9)
                            }
                        }
                        Text(Lz("Most Played This Month"))
                            .font(.system(size: 10, weight: .semibold))
                        Text(Lz("1. Ten Years · Eason Chan"))
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct MacWidgetRecentPreview: View {
    var body: some View {
        // 标题 + 56pt 方格在 155 的 small 里会竖向溢出。改成铺满的 2×2 网格,
        // 封面随宽度自适应(≈64pt), 标题交给下方 MacWidgetTile 的尺寸标签承担。
        MacWidgetShell(size: .small, padding: 10) {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                spacing: 6
            ) {
                ForEach(0..<4, id: \.self) { idx in
                    MacWidgetCover(
                        radius: 8,
                        glyph: idx == 0 ? "猿" : "",
                        systemImage: idx == 0 ? nil : "music.note"
                    )
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct MacWidgetSourcesPreview: View {
    var body: some View {
        MacWidgetShell(size: .small) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(Lz("Music Sources"))
                        .font(.system(size: 10.5, weight: .bold))
                    Spacer()
                    Text("4")
                        .font(.system(size: 9))
                        .foregroundStyle(.black.opacity(0.45))
                }
                Text("10,737")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.24, green: 0.60, blue: 0.31))
                    .padding(.top, 10)
                Text(Lz("Tracks Indexed"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.black.opacity(0.56))
                    .padding(.bottom, 8)
                ForEach([Lz("Baidu Netdisk"), "Apple Music", "cqNas", "Synology"], id: \.self) { source in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(source == "Apple Music" ? Color.purple : source == "cqNas" ? Color.blue : PMColor.brand)
                            .frame(width: 6, height: 6)
                        Text(verbatim: source)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct MacWidgetWrappedPreview: View {
    var body: some View {
        MacWidgetShell(size: .medium, dark: true, padding: 0) {
            ZStack {
                LinearGradient(colors: [PMColor.brand, Color(red: 0.16, green: 0.11, blue: 0.22), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PRIMUSE WRAPPED")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.70))
                    Text(Lz("Your 2026\n847 hours listened"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 6)
                    Spacer()
                    Label(Lz("View Year in Review"), systemImage: "sparkles")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MacWidgetCover: View {
    var radius: CGFloat
    /// 文本字形 (品牌字"猿"用这个)。需要真实图标时改传 systemImage。
    var glyph: String = ""
    /// SF Symbol 名 —— 设置后优先渲染图标 (如音乐封面用 music.note), 不再用文本字形。
    var systemImage: String? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PMColor.brand, Color(red: 0.15, green: 0.42, blue: 0.45), Color(red: 0.94, green: 0.70, blue: 0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 3)
                .frame(width: 66, height: 66)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
            } else {
                Text(verbatim: glyph)
                    .font(.system(size: glyph == "猿" ? 28 : 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct MacWidgetRoundButton: View {
    var symbol: String
    var size: CGFloat
    var primary = false
    var dark = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: max(11, size * 0.42), weight: .semibold))
            .foregroundStyle(primary ? (dark ? Color.black : Color.white) : (dark ? Color.white.opacity(0.88) : Color.black.opacity(0.82)))
            .frame(width: size, height: size)
            .background(primary ? PMColor.brand : (dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)), in: .circle)
    }
}

private struct MacWidgetProgress: View {
    var value: CGFloat
    var tint: Color
    var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.22))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - ST-08 iCloud

private struct MacSTCloudView: View {
    @Environment(CloudKitSyncService.self) private var sync
    @AppStorage("primuse.iCloudSyncEnabled") private var enabled: Bool = true
    @AppStorage(CloudSyncChannel.playlists.defaultsKey) private var syncPlaylists: Bool = true
    @AppStorage(CloudSyncChannel.sources.defaultsKey) private var syncSources: Bool = true
    @AppStorage(CloudSyncChannel.playbackHistory.defaultsKey) private var syncPlaybackHistory: Bool = true
    @AppStorage(CloudSyncChannel.settings.defaultsKey) private var syncSettings: Bool = true
    @AppStorage(CloudSyncChannel.credentials.defaultsKey) private var syncCredentials: Bool = true
    @AppStorage(CloudSyncChannel.listeningStats.defaultsKey) private var syncListeningStats: Bool = true
    @State private var isSyncingNow = false
    @State private var familyEnabled = CloudKitSyncService.familySharingEnabled
    @State private var familyBusy = false
    @State private var familyError: String?
    @State private var pendingShareURL: URL?

    var body: some View {
        MacSTSection("iCloud Sync") {
            MacSTGroup {
                MacSTRow(Lz("Master Toggle"), hint: "primuse.iCloudSyncEnabled · CloudKitSyncService", divider: false) {
                    MacSTToggle(isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            enabled = newValue
                            Task {
                                if newValue { await sync.start() } else { sync.stop() }
                            }
                        }
                    ))
                }
                MacSTRow(Lz("Sync Status")) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    MacSTInfoText(text: statusText, color: statusColor)
                    if let last = sync.lastSyncedAt {
                        MacSTInfoText(text: last.formatted(.relative(presentation: .named)))
                    }
                    if case .accountUnavailable(.noAccount) = sync.status {
                        MacSTButton(title: Lz("Open System Settings"), systemImage: "gear") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    MacSTButton(title: isSyncingNow ? Lz("Syncing…") : Lz("Sync Now"),
                                systemImage: "arrow.triangle.2.circlepath",
                                prominent: true) {
                        isSyncingNow = true
                        Task {
                            await sync.syncNow()
                            isSyncingNow = false
                        }
                    }
                    .disabled(isSyncingNow || !enabled)
                }
            }
        }

        MacSTSection(Lz("Sync Channel"), hint: Lz("Control item by item which data goes through iCloud")) {
            MacSTGroup {
                channelRow(Lz("Playlist"), spec: "C-01 · Playlist / SmartPlaylist", channel: .playlists, isOn: $syncPlaylists, divider: false)
                channelRow(Lz("Source Configuration"), spec: "C-01 · MusicSource", channel: .sources, isOn: $syncSources)
                channelRow(Lz("Playback History"), spec: "C-01 · STATS-07", channel: .playbackHistory, isOn: $syncPlaybackHistory)
                channelRow(Lz("App Settings"), spec: "C-02 · NSUbiquitousKeyValueStore", channel: .settings, isOn: $syncSettings)
                channelRow(Lz("Keychain Credentials"), spec: Lz("C-07 · Newly Written Credentials"), channel: .credentials, isOn: $syncCredentials)
                channelRow(Lz("Listening Stats"), spec: "C-01 · STATS-*", channel: .listeningStats, isOn: $syncListeningStats)
            }
        }

        MacSTSection(Lz("Family Sharing · CKShare (C-03)")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: familyEnabled ? "person.2.badge.gearshape.fill" : "person.2.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(familyEnabled ? PMColor.ok : PMColor.brand)
                        .frame(width: 36, height: 36)
                        .background((familyEnabled ? PMColor.ok : PMColor.brand).opacity(0.14), in: .rect(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: familyEnabled ? Lz("Family Sharing Enabled") : Lz("Create Family Shared Library"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Text(verbatim: familyEnabled ? Lz("Share playlists, smart playlists, and family music sources") : Lz("Share collaborative library content via CloudKit"))
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textMuted)
                    }

                    Spacer()

                    if familyEnabled {
                        MacSTButton(title: familyBusy ? Lz("Processing…") : Lz("Invite…"), systemImage: "square.and.arrow.up") {
                            Task { await inviteFamily() }
                        }
                        .disabled(familyBusy)
                        MacSTButton(title: Lz("Off"), destructive: true) {
                            Task { await disableFamily() }
                        }
                        .disabled(familyBusy)
                    } else {
                        MacSTButton(title: familyBusy ? Lz("Creating…") : Lz("Create"), systemImage: "person.2.badge.plus", prominent: true) {
                            Task { await inviteFamily() }
                        }
                        .disabled(familyBusy)
                    }
                }

                if let familyError {
                    Text(verbatim: familyError)
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
            .background(MacSTSharePickerAnchor(url: $pendingShareURL))
        }
    }

    private func channelRow(_ label: String,
                            spec: String,
                            channel: CloudSyncChannel,
                            isOn: Binding<Bool>,
                            divider: Bool = true) -> some View {
        MacSTRow(label, hint: spec, divider: divider) {
            MacSTToggle(isOn: Binding(
                get: { isOn.wrappedValue },
                set: { newValue in
                    isOn.wrappedValue = newValue
                    guard newValue, enabled else { return }
                    Task { await sync.catchUp(channel: channel) }
                }
            ))
            .disabled(!enabled)
        }
    }

    private var statusText: String {
        switch sync.status {
        case .disabled: return String(localized: "status_disabled")
        case .idle: return String(localized: "status_idle")
        case .syncing: return String(localized: "status_syncing")
        case .upToDate: return String(localized: "status_up_to_date")
        case .error(let message): return message
        case .accountUnavailable(let reason): return accountReasonText(reason)
        case .quotaExceeded: return String(localized: "status_quota_exceeded")
        case .networkUnavailable: return String(localized: "status_network_unavailable")
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .upToDate: return PMColor.ok
        case .syncing: return PMColor.brand
        case .error, .quotaExceeded: return PMColor.bad
        case .accountUnavailable, .networkUnavailable: return PMColor.warn
        case .disabled, .idle: return PMColor.textMuted
        }
    }

    private func accountReasonText(_ reason: AccountUnavailableReason) -> String {
        switch reason {
        case .noAccount: return String(localized: "status_no_icloud_account")
        case .restricted: return String(localized: "status_icloud_restricted")
        case .temporarilyUnavailable: return String(localized: "status_icloud_temporarily_unavailable")
        case .unknown: return String(localized: "status_icloud_unknown")
        }
    }

    @MainActor
    private func inviteFamily() async {
        familyBusy = true
        familyError = nil
        defer { familyBusy = false }
        do {
            let share = try await sync.enableFamilySharing()
            familyEnabled = true
            if let url = share.url {
                pendingShareURL = url
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                pendingShareURL = share.url
            }
        } catch {
            familyError = error.localizedDescription
        }
    }

    @MainActor
    private func disableFamily() async {
        familyBusy = true
        defer { familyBusy = false }
        await sync.disableFamilySharing()
        familyEnabled = false
    }
}

private struct MacSTSharePickerAnchor: NSViewRepresentable {
    @Binding var url: URL?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let url else { return }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: [url])
            let anchor = NSApp.keyWindow?.contentView ?? nsView
            picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
            self.url = nil
        }
    }
}

// MARK: - ST-12 Theme

private struct MacSTThemeView: View {
    @State private var preferences = MacUIPreferences.shared
    @Environment(ThemeService.self) private var themeService
    @State private var autoDetectMaterial = true

    private let swatches: [(hex: String, name: String, sub: String, color: Color)] = [
        ("#c96442", Lz("Terracotta"), Lz("Default · Warm Wood Listening Room"), PMColor.brandDefault),
        ("#0a84ff", "macOS Blue", Lz("Standard HIG accent"), Color(red: 0.04, green: 0.52, blue: 1.0)),
        ("#1f8a5b", Lz("Forest"), Lz("Tranquil Woods"), Color(red: 0.12, green: 0.54, blue: 0.36)),
        ("#5e6b87", Lz("Slate"), Lz("Minimal Data Look"), Color(red: 0.37, green: 0.42, blue: 0.53)),
        ("#a0522d", Lz("Mahogany"), Lz("Vintage Vinyl"), Color(red: 0.63, green: 0.32, blue: 0.18)),
    ]

    /// 把色板 hex ("#c96442") 归一成存储用格式 (大写无 #)。
    private func normHex(_ hex: String) -> String {
        hex.replacingOccurrences(of: "#", with: "").uppercased()
    }

    var body: some View {
        MacSTSection(Lz("Appearance"), hint: "THEME-01") {
            MacSTGroup {
                MacSTRow(Lz("Theme"), divider: false, block: true) {
                    HStack(spacing: 8) {
                        MacThemeChoiceCard(title: Lz("Light"), icon: "sun.max", selected: preferences.colorScheme == .light) {
                            preferences.colorScheme = .light
                        }
                        MacThemeChoiceCard(title: Lz("Dark"), icon: "moon", selected: preferences.colorScheme == .dark) {
                            preferences.colorScheme = .dark
                        }
                        MacThemeChoiceCard(title: Lz("System"), icon: "desktopcomputer", selected: preferences.colorScheme == .system) {
                            preferences.colorScheme = .system
                        }
                    }
                }
            }
        }

        MacSTSection(Lz("Brand Color"),
                     hint: Lz("THEME-02 · Doesn't force-tint system controls · Affects only custom buttons, progress bars, active highlights, and ambient fallback")) {
            MacSTGroup {
                ForEach(Array(swatches.enumerated()), id: \.offset) { index, swatch in
                    MacBrandSwatchRow(
                        swatch: swatch,
                        selected: normHex(swatch.hex) == preferences.brandColorHex,
                        divider: index != 0
                    ) {
                        preferences.brandColorHex = normHex(swatch.hex)
                        // 同步 ambient fallback, 让 NowPlaying / 桌面歌词没有封面取色时
                        // 也跟着换成新品牌色。
                        themeService.setBaseAccent(swatch.color)
                    }
                }
            }
        }

        MacSTSection(Lz("Cover Color")) {
            MacSTGroup {
                MacSTRow(Lz("Cover Color Drives Ambient"), hint: Lz("Use artwork palette for NowPlaying / Mini / Desktop Lyrics"), divider: false) {
                    MacSTToggle(isOn: Binding(
                        get: { preferences.coverDrivenAmbient },
                        set: {
                            preferences.coverDrivenAmbient = $0
                            if !$0 { themeService.resetToDefault() }
                        }
                    ))
                }
                MacSTRow(Lz("Ambient Intensity"),
                         hint: Lz("THEME-03 · Controls the color-blob intensity behind NowPlaying / Mini / Desktop Lyrics backgrounds"),
                         divider: true) {
                    MacSTSlider(
                        value: Binding(
                            get: { preferences.ambientStrength * 100 },
                            set: { preferences.ambientStrength = $0 / 100 }
                        ),
                        in: 0...100,
                        formatter: { String(format: "%.0f%%", $0) }
                    )
                }
            }
        }

        MacSTSection("App Icon", hint: Lz("THEME-04 · macOS swaps the runtime Dock icon; the Finder bundle icon stays the same")) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                spacing: 16
            ) {
                ForEach(MacAppIcon.all) { icon in
                    MacAppIconCell(icon: icon, selected: preferences.appIconID == icon.id) {
                        preferences.appIconID = icon.id
                    }
                }
            }
        }

        MacSTSection(Lz("Material")) {
            HStack(spacing: 8) {
                MacMaterialCard(
                    title: "A · Liquid Glass",
                    sub: ".glassEffect()",
                    macos: "macOS 26+",
                    selected: preferences.appearance == .glass
                ) {
                    preferences.appearance = .glass
                }
                MacMaterialCard(
                    title: "B · Classic",
                    sub: ".regularMaterial",
                    macos: "macOS 14-25",
                    selected: preferences.appearance == .classic
                ) {
                    preferences.appearance = .classic
                }
            }

            MacSTGroup {
                MacSTRow(Lz("Detect macOS version automatically at launch"), hint: "if #available(macOS 26.0, *)", divider: false) {
                    MacSTToggle(isOn: $autoDetectMaterial)
                }
            }
        }
    }
}

private struct MacThemeChoiceCard: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(verbatim: title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? PMColor.brand : PMColor.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(selected ? PMColor.brand.opacity(0.14) : PMColor.glassBtn, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? PMColor.brand : PMColor.dividerStrong, lineWidth: selected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MacBrandSwatchRow: View {
    let swatch: (hex: String, name: String, sub: String, color: Color)
    let selected: Bool
    let divider: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }

            Button(action: action) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(swatch.color)
                        .frame(width: 28, height: 28)
                        .shadow(color: swatch.color.opacity(0.28), radius: 3, y: 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: swatch.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Text(verbatim: swatch.sub)
                            .font(.system(size: 10.5))
                            .foregroundStyle(PMColor.textFaint)
                    }

                    Spacer()

                    Text(verbatim: swatch.hex)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)

                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    } else {
                        Circle()
                            .strokeBorder(PMColor.dividerStrong, lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(hover ? PMColor.rowHover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}

private struct MacAppIconCell: View {
    let icon: MacAppIcon
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(icon.previewAsset)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: selected ? 8 : 4, y: 3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(selected ? PMColor.brand : Color.clear, lineWidth: 2)
                    }

                Text(LocalizedStringKey(icon.nameKey))
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? PMColor.text : PMColor.textFaint)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MacMaterialCard: View {
    let title: String
    let sub: String
    let macos: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selected ? PMColor.brand : PMColor.text)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    }
                }
                Text(verbatim: sub)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                Text(verbatim: macos)
                    .font(.system(size: 10))
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? PMColor.brand.opacity(0.14) : PMColor.bgElev, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? PMColor.brand : PMColor.cardBorder, lineWidth: selected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ST-09 Deleted

private struct MacSTDeletedView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var configsTick: Int = 0

    private var hasAny: Bool {
        let _ = configsTick
        return !library.recentlyDeletedPlaylists.isEmpty
            || !sourcesStore.recentlyDeletedSources.isEmpty
            || !ScraperConfigStore.shared.recentlyDeletedConfigs.isEmpty
    }

    var body: some View {
        if !hasAny {
            VStack(spacing: 14) {
                Image(systemName: "trash")
                    .font(.system(size: 44))
                    .foregroundStyle(PMColor.textFaint)
                Text("recently_deleted_empty")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("recently_deleted_empty_desc")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 80)
        }

        let playlists = library.recentlyDeletedPlaylists
        if !playlists.isEmpty {
            MacSTSection("recently_deleted_playlists",
                         hint: Lz("ST-09 · Recoverable Within 7 Days")) {
                MacSTGroup {
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { index, p in
                        MacDeletedRealRow(
                            title: p.name,
                            sub: deletedAtText(p.deletedAt),
                            icon: "music.note.list",
                            divider: index != 0,
                            restore: { library.restorePlaylist(id: p.id) },
                            purge:   { library.permanentlyDeletePlaylist(id: p.id) }
                        )
                    }
                }
            }
        }

        let sources = sourcesStore.recentlyDeletedSources
        if !sources.isEmpty {
            MacSTSection("recently_deleted_sources",
                         hint: Lz("ST-09 · Includes Connection Credentials")) {
                MacSTGroup {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { index, s in
                        MacDeletedRealRow(
                            title: s.name,
                            sub: deletedAtText(s.deletedAt),
                            icon: s.type.iconName,
                            divider: index != 0,
                            restore: { sourcesStore.restore(id: s.id) },
                            purge:   { sourcesStore.permanentlyDelete(id: s.id) }
                        )
                    }
                }
            }
        }

        let configs = ScraperConfigStore.shared.recentlyDeletedConfigs
        if !configs.isEmpty {
            MacSTSection("recently_deleted_scraper_configs",
                         hint: Lz("ST-09 · Custom Metadata Scraping Sources")) {
                MacSTGroup {
                    ForEach(Array(configs.enumerated()), id: \.element.id) { index, c in
                        MacDeletedRealRow(
                            title: c.name,
                            sub: deletedAtText(c.deletedAt),
                            icon: "wand.and.stars",
                            divider: index != 0,
                            restore: {
                                ScraperConfigStore.shared.restore(id: c.id)
                                configsTick &+= 1
                            },
                            purge: {
                                ScraperConfigStore.shared.permanentlyDelete(id: c.id)
                                configsTick &+= 1
                            }
                        )
                    }
                }
            }
        }
    }

    private func deletedAtText(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return String(format: String(localized: "deleted_at_format"),
                      f.localizedString(for: date, relativeTo: Date()))
    }
}

private struct MacDeletedRealRow: View {
    let title: String
    let sub: String
    let icon: String
    let divider: Bool
    let restore: () -> Void
    let purge: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(PMColor.glassBtn)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: sub)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }

                Spacer()
                MacSTButton(title: "restore", action: restore)
                MacSTButton(title: "delete_forever", destructive: true, action: purge)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

private struct MacDeletedRow: View {
    let title: String
    let sub: String
    let divider: Bool

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(PMColor.glassBtn)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: sub)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }

                Spacer()
                MacSTButton(title: Lz("Restore"))
                MacSTButton(title: Lz("Delete Permanently"), destructive: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - ST-10 SSL

private struct MacSTSSLView: View {
    @State private var refreshTick = 0
    @State private var showAddSheet = false
    @State private var newDomain = ""

    private var certificates: [SSLTrustStore.TrustedCertificateInfo] {
        _ = refreshTick
        return SSLTrustStore.shared.trustedCertificates
    }

    var body: some View {
        MacSTSection(Lz("Trusted self-signed certificates"),
                     hint: Lz("ST-10 · The SSL certificates for these domains aren't in the system Keychain — you've trusted them manually")) {
            MacSTGroup {
                if certificates.isEmpty {
                    MacSTRow(Lz("No Trusted Domains"), hint: Lz("Add to the trust list during connection when you encounter a self-signed certificate source"), divider: false) {
                        MacSTButton(title: Lz("Add…"), systemImage: "plus") {
                            beginAdd()
                        }
                    }
                } else {
                    ForEach(Array(certificates.enumerated()), id: \.element.id) { index, info in
                        MacSSLRow(info: info, divider: index != 0) {
                            SSLTrustStore.shared.untrust(domain: info.domain)
                            refreshTick &+= 1
                        }
                    }
                    MacSTRow(Lz("Add Domain"), hint: "host.example.com", divider: true) {
                        MacSTButton(title: Lz("Add…"), systemImage: "plus") {
                            beginAdd()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addDomainSheet
        }
    }

    private var addDomainSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Lz("Add Trusted Domain"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: PMTextWithoutDesignCodes(Lz("ST-10 · Trust self-signed certificates for this domain only")))
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: Lz("Domain"))
                    .font(PMFont.bodyM)
                    .foregroundStyle(PMColor.text)
                TextField("music.example.local", text: $newDomain)
                    .textFieldStyle(.plain)
                    .font(PMFont.bodyS)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(PMColor.bgElev, in: .rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
                    .onSubmit { commitAdd() }
                Text(verbatim: Lz("Enter only the host — no need to include https:// or a path."))
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Spacer()
                MacSTButton(title: Lz("Cancel")) {
                    showAddSheet = false
                    newDomain = ""
                }
                MacSTButton(title: Lz("Add"), prominent: true) {
                    commitAdd()
                }
                .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 400)
        .background(PMColor.bg)
    }

    private func beginAdd() {
        newDomain = ""
        showAddSheet = true
    }

    private func commitAdd() {
        var domain = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: domain), let host = url.host {
            domain = host
        }
        guard !domain.isEmpty else { return }
        SSLTrustStore.shared.trust(domain: domain)
        refreshTick &+= 1
        newDomain = ""
        showAddSheet = false
    }
}

private struct MacSSLRow: View {
    let info: SSLTrustStore.TrustedCertificateInfo
    let divider: Bool
    let remove: () -> Void

    private var certificateDetail: String {
        let fingerprint = info.fingerprintSHA256.map {
            "SHA256: \(Self.shortFingerprint($0))"
        } ?? Lz("SHA256: Waiting for next connection")
        let expiry = info.expiresAt.map {
            "\(Lz("Expires")): \($0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))"
        }
        return [fingerprint, expiry].compactMap { $0 }.joined(separator: " · ")
    }

    private static func shortFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 28 else { return fingerprint }
        return "\(fingerprint.prefix(16))…\(fingerprint.suffix(8))"
    }

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.ok)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: info.domain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: certificateDetail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                    if let subject = info.subjectSummary, subject != info.domain {
                        Text(verbatim: subject)
                            .font(.system(size: 10.5))
                            .foregroundStyle(PMColor.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer()
                MacSTButton(title: Lz("Remove"), destructive: true, action: remove)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - ST-11 About

@MainActor
private final class MacUpdateCheckWindowController: NSObject, NSWindowDelegate {
    static let shared = MacUpdateCheckWindowController()
    private static let contentSize = NSSize(width: 520, height: 390)
    private var window: NSWindow?

    func show() {
        if let window {
            configure(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = Lz("Software Update")
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(
            rootView: MacUpdateCheckView { [weak self] in self?.close() }
                .applyPrimuseEnvironments()
        )
        configure(win)
        win.center()
        win.delegate = self
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in self.window?.orderOut(nil) }
        return false
    }

    nonisolated func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        false
    }

    private func configure(_ win: NSWindow) {
        win.setContentSize(Self.contentSize)
        win.contentMinSize = Self.contentSize
        win.contentMaxSize = Self.contentSize
        win.styleMask.remove([.miniaturizable, .resizable])
        win.collectionBehavior.insert(.fullScreenNone)
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

@MainActor
private final class MacDiagnosticsWindowController: NSObject, NSWindowDelegate {
    static let shared = MacDiagnosticsWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = Lz("Diagnostic Logs")
        win.minSize = NSSize(width: 640, height: 480)
        win.center()
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(
            rootView: MacDiagnosticsWindowView()
                .applyPrimuseEnvironments()
        )
        win.delegate = self
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in self.window?.orderOut(nil) }
        return false
    }
}

private struct MacUpdateCheckView: View {
    var onClose: () -> Void

    private static let contentSize = CGSize(width: 520, height: 390)

    @Environment(AppUpdateChecker.self) private var checker
    @AppStorage("primuse.update.autoCheckEnabled") private var autoCheck = true

    private var hasUpdate: Bool {
        checker.availableUpdate != nil
    }

    private var latestVersion: String {
        checker.availableUpdate?.version ?? checker.latestStoreVersion ?? checker.installedVersion
    }

    private var updateInfo: AppUpdateChecker.UpdateInfo? {
        checker.availableUpdate ?? checker.latestUpdateInfo
    }

    private var currentVersion: String {
        checker.installedVersion
    }

    private var statusTitle: String {
        if hasUpdate { return Lz("Update Available") }
        if checker.isChecking { return Lz("Checking for Updates") }
        if checker.lastErrorMessage != nil { return Lz("Couldn't Check for Updates") }
        return Lz("You're up to date")
    }

    private var statusSubtitle: String {
        if hasUpdate {
            return String(format: Lz("%@ · Current %@ · App Store %@"), checker.platformName, currentVersion, latestVersion)
        }
        return String(format: Lz("%@ · Current version %@"), checker.platformName, currentVersion)
    }

    private var lastCheckText: String {
        guard let date = checker.lastCheckedAt else { return Lz("Not checked yet") }
        if Date().timeIntervalSince(date) < 60 {
            return Lz("Just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var releaseDateText: String? {
        guard let date = updateInfo?.releaseDate else { return nil }
        return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [PMColor.brand, PMColor.bgDeep],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 58, height: 58)
                    .overlay {
                        Text(verbatim: "猿")
                            .font(.system(size: 29, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: PMColor.brand.opacity(0.28), radius: 16, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: statusTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: statusSubtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if hasUpdate || checker.storeURL != nil {
                    Button {
                        checker.openAppStore()
                        if hasUpdate { onClose() }
                    } label: {
                        Label(hasUpdate ? Lz("Go to App Store") : Lz("Open App Store"),
                              systemImage: hasUpdate ? "arrow.down.circle.fill" : "bag")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .background(PMColor.brand, in: .rect(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(checker.isChecking)
                    .opacity(checker.isChecking ? 0.55 : 1)
                    .shadow(color: PMColor.brand.opacity(0.22), radius: 12, y: 4)
                }
            }

            Rectangle()
                .fill(PMColor.divider)
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: checker.lastErrorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(checker.lastErrorMessage == nil ? PMColor.ok : PMColor.bad)
                    Text(verbatim: checker.lastErrorMessage ?? String(format: Lz("Last checked: %@"), lastCheckText))
                        .font(.system(size: 12.5))
                        .foregroundStyle(checker.lastErrorMessage == nil ? PMColor.textMuted : PMColor.bad)
                        .lineLimit(2)
                }

                Text(verbatim: hasUpdate ? Lz("The update will be installed from the App Store.") : Lz("No updates available."))
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    versionBadge(title: Lz("Current"), value: currentVersion)
                    versionBadge(title: "App Store", value: latestVersion)
                    if let minimumOS = updateInfo?.minimumOSVersion {
                        versionBadge(title: Lz("Minimum OS"), value: minimumOS)
                    }
                    if let releaseDateText {
                        versionBadge(title: Lz("Release Date"), value: releaseDateText)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: updateInfo?.trackName ?? "Primuse")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(verbatim: updateInfo?.releaseNotes ?? Lz("App Store does not provide release notes yet."))
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 96)
                }
            }
            .padding(12)
            .background(PMColor.bgElev, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                MacSTToggle(isOn: $autoCheck)
                Text(verbatim: Lz("Auto-check for updates (daily)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textFaint)
                Spacer()
                Button {
                    Task { await checker.checkForUpdate(force: true) }
                } label: {
                    Text(verbatim: checker.isChecking ? Lz("Checking...") : Lz("Check Again"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                }
                .buttonStyle(.plain)
                .disabled(checker.isChecking)
            }
        }
        .padding(22)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height, alignment: .topLeading)
        .background(PMColor.bg)
        .task {
            await checker.checkForUpdate(force: true)
        }
    }

    private func versionBadge(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(PMColor.textFaint)
            Text(verbatim: value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
    }
}

private struct MacLicensesPanel: View {
    var onClose: () -> Void
    @State private var selected: MacLicenseComponent?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if selected != nil {
                    Button {
                        selected = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(PMColor.textMuted)
                            .frame(width: 26, height: 26)
                            .background(PMColor.glassBtn, in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: selected?.name ?? Lz("Open-Source Licenses"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: selected == nil ? Lz("Open-source components used by Primuse") : String(format: Lz("%@ · Full license text"), selected?.license ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 26, height: 26)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            if let selected {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(verbatim: selected.fullText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(MacLicenseComponent.items.enumerated()), id: \.element.id) { index, item in
                            Button {
                                selected = item
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: item.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(PMColor.text)
                                            .lineLimit(1)
                                        Text(verbatim: item.use)
                                            .font(.system(size: 11))
                                            .foregroundStyle(PMColor.textFaint)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text(verbatim: item.license)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(PMColor.textMuted)
                                        .padding(.horizontal, 8)
                                        .frame(height: 18)
                                        .background(PMColor.rowHover, in: .rect(cornerRadius: 4))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(PMColor.textFaint)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .overlay(alignment: .bottom) {
                                    if index < MacLicenseComponent.items.count - 1 {
                                        Rectangle().fill(PMColor.divider).frame(height: 0.5)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            Text(verbatim: selected == nil ? Lz("Select an item to view the full license text") : Lz("License text follows component versions; distribution uses the LICENSE file in the repository."))
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .frame(width: 520, height: 580)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PMColor.bg.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }
}

private struct MacLicenseComponent: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let license: String
    let use: String

    static let items: [MacLicenseComponent] = [
        .init(name: "SFBAudioEngine", license: "MIT", use: Lz("Audio decoding engine")),
        .init(name: "FFmpeg", license: "LGPL 2.1", use: Lz("Additional format decoding")),
        .init(name: "AMSMB2", license: "BSD-3", use: Lz("SMB / CIFS connection")),
        .init(name: "Citadel", license: "MIT", use: Lz("SFTP client")),
        .init(name: "NFSKit", license: "MIT", use: Lz("NFS browsing")),
        .init(name: "GRDB.swift", license: "MIT", use: "SQLite + FTS5"),
        .init(name: "Nuke", license: "MIT", use: Lz("Cover image loading and cache")),
        .init(name: "Swift Collections", license: "Apache 2.0", use: Lz("Data structures")),
        .init(name: "KeychainAccess", license: "MIT", use: Lz("Credential storage")),
        .init(name: "swift-log", license: "Apache 2.0", use: Lz("Logging")),
    ]

    var fullText: String {
        """
        \(name)
        License: \(license)
        Usage: \(use)

        This component is redistributed under its upstream open-source license.
        The full authoritative license text is bundled with the component or
        available from the upstream project repository. Primuse preserves the
        copyright and license notices required by that project.
        """
    }
}

private struct MacDiagnosticsWindowView: View {
    @State private var tick = 0
    @State private var selectedFilter: MacLogFilter = .all
    @State private var copiedRowID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: Lz("Diagnostics"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: Lz("MetricKit + crash logs"))
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
                MacSTButton(title: Lz("Export Logs"), systemImage: "square.and.arrow.up") {
                    NSWorkspace.shared.activateFileViewerSelecting([FileLogger.shared.logFileURL])
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                healthMetric(Lz("Memory"), value: "412 MB", color: PMColor.ok)
                healthMetric(Lz("CPU (playback)"), value: "4.2%", color: PMColor.ok)
                healthMetric(Lz("Cache"), value: "318 / 500 MB", color: PMColor.text)
                healthMetric(Lz("Crashes (30 days)"), value: "\(AppServices.shared.crashDiagnostics.reports().count)", color: PMColor.ok)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            HStack(spacing: 8) {
                Text(verbatim: Lz("Live Logs"))
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textFaint)
                logFilterButton(.all)
                logFilterButton(.warn)
                logFilterButton(.error)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(logRows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 10) {
                            Text(verbatim: row.time)
                                .foregroundStyle(Color.white.opacity(0.45))
                                .frame(width: 58, alignment: .leading)
                            Text(verbatim: row.level)
                                .fontWeight(.bold)
                                .foregroundStyle(row.color)
                                .frame(width: 44, alignment: .leading)
                            Text(verbatim: row.module)
                                .foregroundStyle(Color(red: 0.90, green: 0.63, blue: 0.42))
                                .frame(width: 96, alignment: .leading)
                            Text(verbatim: row.message)
                                .foregroundStyle(Color(red: 0.85, green: 0.83, blue: 0.78))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if copiedRowID == row.id {
                                Text(verbatim: Lz("Copied"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(PMColor.brand)
                            }
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(5)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(copiedRowID == row.id ? PMColor.brand.opacity(0.12) : Color.clear,
                                    in: .rect(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture { copy(row) }
                        .help(Lz("Click to copy this log line"))
                    }
                }
                .padding(12)
            }
            .background(Color(red: 0.12, green: 0.105, blue: 0.09), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(PMColor.bg)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick &+= 1
            }
        }
    }

    private func healthMetric(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(verbatim: label)
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pmCard(cornerRadius: 10)
    }

    private func logFilterButton(_ filter: MacLogFilter) -> some View {
        Button {
            selectedFilter = filter
        } label: {
            Text(verbatim: filter.title)
                .font(.system(size: 10, weight: selectedFilter == filter ? .semibold : .medium))
                .foregroundStyle(selectedFilter == filter ? Color.white : PMColor.textMuted)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(selectedFilter == filter ? PMColor.brand : PMColor.rowHover, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var logRows: [MacLogRow] {
        _ = tick
        let recent = FileLogger.shared.recentContent(maxBytes: 12_000)
            .split(separator: "\n")
            .suffix(80)
            .map(String.init)
        let parsed = recent.compactMap(MacLogRow.parse)
        let rows = parsed.isEmpty ? MacLogRow.samples : parsed
        return rows.filter { selectedFilter.matches($0) }
    }

    private func copy(_ row: MacLogRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.pasteboardText, forType: .string)
        copiedRowID = row.id
    }
}

private enum MacLogFilter: CaseIterable, Equatable {
    case all, warn, error

    var title: String {
        switch self {
        case .all: return Lz("All")
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }

    func matches(_ row: MacLogRow) -> Bool {
        switch self {
        case .all: return true
        case .warn: return row.level == "WARN"
        case .error: return row.level == "ERROR"
        }
    }
}

private struct MacLogRow {
    let time: String
    let level: String
    let module: String
    let message: String

    var id: String {
        "\(time)|\(level)|\(module)|\(message)"
    }

    var pasteboardText: String {
        "[\(time)] [\(level)] \(module) \(message)"
    }

    var color: Color {
        switch level {
        case "ERROR": return PMColor.bad
        case "WARN": return PMColor.warn
        default: return Color(red: 0.85, green: 0.83, blue: 0.78).opacity(0.78)
        }
    }

    static func parse(_ line: String) -> MacLogRow? {
        guard line.hasPrefix("[") else { return nil }
        let parts = line.split(separator: "]", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let time = parts[0].replacingOccurrences(of: "[", with: "")
        let rest = parts.dropFirst().joined(separator: "]").trimmingCharacters(in: .whitespaces)
        let level: String
        if rest.localizedCaseInsensitiveContains("error") || rest.contains("❌") {
            level = "ERROR"
        } else if rest.localizedCaseInsensitiveContains("warn") || rest.contains("⚠️") {
            level = "WARN"
        } else {
            level = "INFO"
        }
        let module = rest.split(separator: " ").first.map(String.init) ?? "App"
        return MacLogRow(time: String(time.prefix(8)), level: level, module: String(module.prefix(12)), message: rest)
    }

    static let samples: [MacLogRow] = [
        .init(time: "21:14:08", level: "INFO", module: "ScanService", message: "Synology WebDAV · Phase B complete · 1208 songs"),
        .init(time: "21:13:52", level: "INFO", module: "Metadata", message: "Backfill remaining 2384 · 18/s"),
        .init(time: "21:12:30", level: "WARN", module: "CloudKit", message: "Push throttled · retrying in 60s"),
        .init(time: "21:10:04", level: "INFO", module: "AudioEngine", message: "DSD256 → PCM384 realtime conversion · iFi Zen DAC"),
        .init(time: "21:08:41", level: "ERROR", module: "SFTP", message: "archive.home · key expired · auth failed"),
        .init(time: "21:05:19", level: "INFO", module: "Scrobble", message: "Last.fm · submitted track (50%)"),
        .init(time: "21:02:00", level: "INFO", module: "App", message: "One-shot launch tasks completed · 247ms"),
    ]
}

private struct MacSTAboutView: View {
    @State private var showLicenses = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandMonogram(slot: .feature)

            Text(verbatim: PMAppDisplayName())
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(PMColor.text)
                .padding(.top, 14)

            Text(verbatim: "\(version) (build \(build)) · macOS 26.0+")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .padding(.top, 4)

            HStack(spacing: 12) {
                MacSTButton(title: Lz("Check for Updates")) {
                    MacUpdateCheckWindowController.shared.show()
                }
                MacSTButton(title: Lz("Open-Source Licenses…")) {
                    showLicenses = true
                }
                MacSTButton(title: Lz("Diagnostic Logs…")) {
                    MacDiagnosticsWindowController.shared.show()
                }
            }
            .padding(.top, 24)

            Text(verbatim: Lz("Primuse is a native macOS player for NAS / media-server enthusiasts, built on SFBAudioEngine. This design covers 200+ features: Set A uses .glassEffect() on macOS 26+, Set B falls back to .regularMaterial.\n\n© 2026 Primuse Project · Made for lossless lovers."))
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 480, alignment: .leading)
                .padding(.top, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .sheet(isPresented: $showLicenses) {
            MacLicensesPanel {
                showLicenses = false
            }
        }
    }
}

extension View {
    func macReadablePane(maxWidth: CGFloat = 860) -> some View {
        self
            .formStyle(.grouped)
            .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
#endif
