#if os(macOS)
import SwiftUI
import AppKit
import CloudKit
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
            case .playback: return "播放"
            case .equalizer: return "均衡器"
            case .effects: return "音频效果"
            case .scrape: return "元数据刮削"
            case .lyrics: return "歌词翻译"
            case .appleMusic: return "Apple Music"
            case .widgets: return "桌面小组件"
            case .cloud: return "iCloud"
            case .theme: return "外观"
            case .deleted: return "最近删除"
            case .ssl: return "信任域名"
            case .about: return "关于"
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
        HStack(spacing: 10) {
            PMWindowTrafficLights()

            HStack(spacing: 4) {
                PMRoundBtn(icon: "chevron.left", size: 24, iconSize: 12, style: .plain,
                           help: "back") {}
                PMRoundBtn(icon: "chevron.right", size: 24, iconSize: 12, style: .plain,
                           help: "forward") {}
            }
            .padding(.leading, 6)

            Spacer()

            Text(verbatim: tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)

            Spacer()

            Color.clear.frame(width: 82, height: 1)
        }
        .padding(.horizontal, 14)
        .frame(height: PMSize.titlebar)
        .background {
            ZStack {
                NSVisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
                Rectangle().fill(PMColor.sidebarGlass)
            }
        }
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
            TextField("", text: $sidebarFilter, prompt: Text(verbatim: "搜索…"))
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
        return Button { tab = item } label: {
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

                Text(verbatim: item.spec)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(selected ? Color.white.opacity(0.62) : PMColor.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? PMColor.brand : .clear, in: .rect(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var contentPane: some View {
        MacSettingsScroll(title: tab.title, spec: tab.spec) {
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
    let spec: String
    private let content: Content

    init(title: String, spec: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spec = spec
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题区固定不滚 — 之前放在 ScrollView 里, 滚动条会贴到窗口最顶,
            // 跟 macOS 原生 Settings.app 的"内容滚, 标题/工具栏固定"行为不一致。
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(PMColor.text)
                Text(verbatim: spec)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 14)
            .background(PMColor.bg)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    content
                }
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 36)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(PMColor.bg)
        }
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
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(PMColor.textFaint)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, -2)
            }

            content

            if let hint {
                Text(verbatim: hint)
                    .font(.system(size: 10.5))
                    .lineSpacing(3)
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.horizontal, 14)
                    .padding(.top, -4)
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
            Text(verbatim: label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            if let hint {
                Text(verbatim: hint)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(2)
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
                .frame(width: 36, alignment: .trailing)
        }
        .frame(width: width)
    }
}

/// 静态显示版本 — 仅 label, 没有真 Picker 绑定。保留用于"无对应 Store 字段"的占位
/// 行 (例如某些纯展示信息)。需要真下拉时改用 MacSTPicker。
private struct MacSTSelect: View {
    let value: String
    var width: CGFloat = 200

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: value)
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
    }
}

/// 真实 Picker — Menu 下拉, 维持跟 MacSTSelect 同样的视觉, 但点击会弹真菜单。
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
        }
        .menuStyle(.borderlessButton)
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
        Text(verbatim: text)
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

        MacSTSection("播放速率与音质") {
            MacSTGroup {
                MacSTRow("播放速率", hint: "0.5x - 2.0x · 保持音调", divider: false) {
                    MacSTSlider(
                        value: Binding(
                            get: { Double(s.playbackRate * 100) },
                            set: { s.playbackRate = Float($0 / 100) }
                        ),
                        in: 50...200,
                        formatter: { String(format: "%.2fx", $0 / 100) }
                    )
                }
                MacSTRow("空间音频", hint: "Apple AirPods · 头部追踪") {
                    MacSTToggle(isOn: $s.spatialAudioEnabled)
                }
                MacSTRow("ReplayGain", hint: "自动音量平衡") {
                    MacSTToggle(isOn: $s.replayGainEnabled)
                }
                if s.replayGainEnabled {
                    MacSTRow("RG 模式", hint: "Track vs Album") {
                        MacSTPicker(
                            selection: $s.replayGainMode,
                            options: ReplayGainMode.allCases.map { ($0, $0.displayName) },
                            width: 160
                        )
                    }
                }
            }
        }

        MacSTSection("衔接与无缝") {
            MacSTGroup {
                MacSTRow("Gapless 无缝播放", hint: "P-16 · 默认开启", divider: false) {
                    MacSTToggle(isOn: $s.gaplessEnabled)
                }
                MacSTRow("Crossfade", hint: "跟 Gapless 互斥") {
                    MacSTToggle(isOn: $s.crossfadeEnabled)
                }
                if s.crossfadeEnabled {
                    MacSTRow("Crossfade 时长", hint: "1-12 秒") {
                        MacSTSlider(
                            value: $s.crossfadeDuration,
                            in: 1...12,
                            formatter: { "\(Int($0))s" }
                        )
                    }
                }
                MacSTRow("匹配硬件采样率", hint: "iOS 真机有效, 部分硬件忽略") {
                    MacSTToggle(isOn: $s.matchOutputSampleRate)
                }
            }
        }

        MacSTSection("缓存") {
            MacSTGroup {
                MacSTRow("启用音频缓存", hint: "AudioCacheManager · LRU", divider: false) {
                    MacSTToggle(isOn: $s.audioCacheEnabled)
                }
                if s.audioCacheEnabled {
                    MacSTRow("缓存上限 (MB)", hint: "默认 500 MB") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(s.audioCacheLimitBytes) / 1_048_576 },
                                set: { s.audioCacheLimitBytes = Int64($0 * 1_048_576) }
                            ),
                            in: 100...4000,
                            formatter: { "\(Int($0)) MB" }
                        )
                        MacSTButton(title: "立即清理") {
                            AudioCacheManager.shared.clearAll()
                        }
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

        MacSTSection("10 段均衡器") {
            MacSTGroup {
                MacSTRow("启用 EQ", hint: "FX-01", divider: false) {
                    MacSTToggle(isOn: $eq.isEnabled)
                }
                MacSTRow("当前预设") {
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
                MacSTRow("预设", hint: "点击切换 · 拖拽下方滑块即转为自定义", block: true) {
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
                        MacSTButton(title: "重置") { eq.reset() }
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
                    .frame(width: 18, height: 10)
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

    var body: some View {
        @Bindable var fx = fx

        // 设计稿"启用效果链"是总开关; 真 Store 里没有这个字段, 用 reverb || compressor
        // 任一启用作为总开关的"指示", 切到 off 时一次性关掉两个。
        MacSTSection("混响 (Reverb)") {
            MacSTGroup {
                MacSTRow("开关", hint: "FX-03", divider: false) {
                    MacSTToggle(isOn: $fx.reverbEnabled)
                }
                if fx.reverbEnabled {
                    MacSTRow("类型") {
                        MacSTPicker(
                            selection: $fx.reverbPreset,
                            options: ReverbPreset.allCases.map { ($0, $0.localizedName) },
                            width: 180
                        )
                    }
                    MacSTRow("Wet / Dry %", hint: "0 = 干声, 100 = 全湿") {
                        MacSTSlider(
                            value: Binding(
                                get: { Double(fx.reverbWetDryMix) },
                                set: { fx.reverbWetDryMix = Float($0) }
                            ),
                            in: 0...100
                        )
                    }
                }
            }
        }

        MacSTSection("压缩 / 限幅 (Compressor)") {
            MacSTGroup {
                MacSTRow("开关", hint: "FX-04", divider: false) {
                    MacSTToggle(isOn: $fx.compressorEnabled)
                }
                if fx.compressorEnabled {
                    MacSTRow("预设") {
                        MacSTPicker(
                            selection: Binding(
                                get: { fx.compressorPresetId ?? "" },
                                set: { id in
                                    if let p = CompressorPreset.allPresets.first(where: { $0.id == id }) {
                                        fx.applyCompressorPreset(p)
                                    }
                                }
                            ),
                            options: [("", "自定义")]
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
    }
}

// 设计稿里的"立体声增强"目前 PlaybackSettingsStore / AudioEffectsService 没对应字段,
// 暂时不渲染 — 等 audio engine 真接了 AVAudioUnitStereoMixer 再补 UI。
private struct MacSTEffectsViewLegacy_REMOVE: View {
    @State private var stereoEnabled = true
    @State private var width = 75.0
    var body: some View {
        MacSTSection("立体声增强") {
            MacSTGroup {
                MacSTRow("开关", hint: "FX-05", divider: false) {
                    MacSTToggle(isOn: $stereoEnabled)
                }
                MacSTRow("宽度") {
                    MacSTSlider(value: $width)
                }
            }
        }
    }
}

// MARK: - ST-04 Metadata Scraping

private struct MacSTScrapingView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @State private var showImportSheet = false
    @State private var importText = ""
    @State private var importError: String?
    @State private var importMode: ImportMode = .paste

    private enum ImportMode { case paste, url }

    var body: some View {
        MacSTSection("刮削源", hint: "META-01 · 拖拽排序 · 上面优先级高") {
            VStack(spacing: 4) {
                ForEach(Array(scraperSettings.sources.enumerated()), id: \.element.id) { index, source in
                    MacScraperSourceRow(
                        source: source,
                        index: index,
                        count: scraperSettings.sources.count,
                        isEnabled: sourceEnabledBinding(source),
                        moveUp: { moveSource(from: index, by: -1) },
                        moveDown: { moveSource(from: index, by: 1) },
                        remove: { scraperSettings.removeCustomSource(id: source.id) }
                    )
                }
            }

            MacSTGroup {
                MacSTRow("自定义源", hint: "META-03 · 粘贴 JSON 或从 URL 导入", divider: false) {
                    MacSTButton(title: "从 URL 导入…", systemImage: "link") {
                        beginImport(.url)
                    }
                    MacSTButton(title: "粘贴 JSON…", systemImage: "doc.on.clipboard") {
                        beginImport(.paste)
                    }
                }
            }
        }

        MacSTSection("匹配策略", hint: "META-04 · 只补缺失字段时不会覆盖你手动编辑过的资料") {
            MacSTGroup {
                MacSTRow("只补缺失字段", hint: "开启后保留现有标题、艺术家、专辑、封面", divider: false) {
                    MacSTToggle(isOn: Binding(
                        get: { scraperSettings.onlyFillMissingFields },
                        set: { scraperSettings.onlyFillMissingFields = $0 }
                    ))
                }
                MacSTRow("已启用源") {
                    MacSTInfoText(text: "\(scraperSettings.enabledSources.count) / \(scraperSettings.sources.count)")
                    MacSTButton(title: "恢复默认", destructive: true) {
                        scraperSettings.resetToDefaults()
                    }
                }
            }
        }

        MacSTSection("批量刮削") {
            MacSTGroup {
                MacSTRow("全库刮削", hint: "META-06", divider: false) {
                    if scraperService.isScraping {
                        VStack(alignment: .trailing, spacing: 5) {
                            ProgressView(value: scraperService.progress)
                                .tint(PMColor.brand)
                                .frame(width: 180)
                            Text(verbatim: "\(scraperService.processedCount)/\(scraperService.totalCount) · \(scraperService.updatedCount) 更新 · \(scraperService.failedCount) 失败")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(PMColor.textFaint)
                        }
                        MacSTButton(title: "取消", destructive: true) {
                            scraperService.cancel()
                        }
                    } else {
                        MacSTButton(title: "补齐缺失", systemImage: "sparkles", prominent: true) {
                            scraperService.scrapeMissingMetadata(in: library)
                        }
                        MacSTButton(title: "重新刮削", systemImage: "arrow.clockwise") {
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

    private func moveSource(from index: Int, by offset: Int) {
        var sources = scraperSettings.sources
        let target = min(max(index + offset, 0), sources.count - 1)
        guard target != index else { return }
        let moved = sources.remove(at: index)
        sources.insert(moved, at: target)
        for sourceIndex in sources.indices {
            sources[sourceIndex].priority = sourceIndex
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            scraperSettings.sources = sources
        }
    }

    private func beginImport(_ mode: ImportMode) {
        importMode = mode
        importText = ""
        importError = nil
        showImportSheet = true
    }

    private var importScraperSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 34, height: 34)
                    .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "导入刮削源")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "META-03 · 自定义源 JSON")
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $importMode) {
                    Text(verbatim: "粘贴配置").tag(ImportMode.paste)
                    Text(verbatim: "从 URL").tag(ImportMode.url)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if importMode == .paste {
                    TextEditor(text: $importText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 260)
                        .padding(8)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                } else {
                    TextField("https://example.com/scraper.json", text: $importText)
                        .textFieldStyle(.plain)
                        .font(PMFont.bodyS)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                }

                if let importError {
                    Text(verbatim: importError)
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)

            Spacer(minLength: 0)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            HStack {
                Spacer()
                MacSTButton(title: "取消") { showImportSheet = false }
                MacSTButton(title: "导入", prominent: true) { performImport() }
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 560, height: 500)
        .background(PMColor.bg)
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
}

private struct MacScraperSourceRow: View {
    let source: ScraperSourceConfig
    let index: Int
    let count: Int
    @Binding var isEnabled: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                PMRoundBtn(icon: "chevron.up", size: 18, iconSize: 9, style: .plain, action: moveUp)
                    .disabled(index == 0)
                PMRoundBtn(icon: "chevron.down", size: 18, iconSize: 9, style: .plain, action: moveDown)
                    .disabled(index == count - 1)
            }
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
                    Text(verbatim: "内置")
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
                MacSTButton(title: "删除", destructive: true, action: remove)
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
        if source.type.supportsMetadata { result.append("元数据") }
        if source.type.supportsCover { result.append("封面") }
        if source.type.supportsLyrics { result.append(source.type.supportsWordLevelLyrics ? "逐字歌词" : "歌词") }
        return result.isEmpty ? ["扩展"] : result
    }
}

// MARK: - ST-05 Lyrics Translation

private struct MacSTLyricsView: View {
    @State private var settings = LyricsTranslationSettingsStore.shared
    @AppStorage("lyricsFontScale") private var lyricsFontScale = 1.0

    private var targetLanguageName: String {
        let current = LyricsTranslationSettingsStore.availableTargetLanguages.first {
            $0.code == settings.targetLanguageCode
        }
        guard let current else { return "中文 (简体)" }
        return String(localized: String.LocalizationValue(current.displayKey))
    }

    var body: some View {
        // 删了"离线模型"/"翻译颜色"/"仅 NowPlaying 展开时显示翻译" 三行 —— 这些 mock
        // 控件没接到任何 Store, 之前是纯视觉占位, 真翻译走的是云端 API (LyricsTranslationSettingsStore)。
        MacSTSection("翻译歌词") {
            MacSTGroup {
                MacSTRow("启用翻译", hint: "L-08 · 双行展示", divider: false) {
                    MacSTToggle(isOn: Binding(
                        get: { settings.isEnabled },
                        set: { settings.isEnabled = $0 }
                    ))
                }
                MacSTRow("目标语言") {
                    Menu {
                        ForEach(LyricsTranslationSettingsStore.availableTargetLanguages, id: \.code) { language in
                            Button(String(localized: String.LocalizationValue(language.displayKey))) {
                                settings.targetLanguageCode = language.code
                            }
                        }
                    } label: {
                        MacSTSelect(value: targetLanguageName)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        MacSTSection("显示样式") {
            MacSTGroup {
                MacSTRow("字号 (lyricsFontScale)", hint: "iOS / macOS 共享 · CloudKVS 同步", divider: false) {
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

    var body: some View {
        MacSTSection("账号") {
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
                    MacSTButton(title: "去系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleAccount") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    MacSTButton(title: "授权", prominent: true) {
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
            MacSTSection("资料库同步") {
                MacSTGroup {
                    MacSTRow("同步状态", hint: "SRC-29 · 跨进程缓存", divider: false) {
                        MacSTInfoText(text: syncStateText,
                                      color: syncStateColor)
                    }
                    MacSTRow("上次同步") {
                        MacSTInfoText(text: lastSyncText)
                        MacSTButton(title: "重新同步", systemImage: "arrow.clockwise") {
                            library.sync()
                        }
                    }
                }
            }
        }

        if let err = appleMusic.lastPlaybackError {
            MacSTSection("最近播放错误") {
                MacSTGroup {
                    MacSTRow("错误信息", divider: false) {
                        MacSTInfoText(text: err, color: PMColor.bad)
                    }
                }
            }
        }
    }

    private var accountTitle: String {
        switch appleMusic.authState {
        case .notDetermined: return "Apple Music · 未授权"
        case .denied:        return "Apple Music · 已拒绝"
        case .restricted:    return "Apple Music · 受限制"
        case .authorized:    return "Apple Music · 已授权"
        }
    }

    private var accountSubtitle: String {
        switch appleMusic.authState {
        case .notDetermined: return "点击右侧授权以连接你的订阅"
        case .denied:        return "前往 系统设置 → 隐私 重新启用"
        case .restricted:    return "由屏幕使用时间或 MDM 限制"
        case .authorized:    return "MusicKit 已连接"
        }
    }

    private var syncStateText: String {
        switch library.state {
        case .idle:                 return "● 就绪"
        case .syncing:              return "● 正在同步…"
        case .done(let count, _):   return "● 已同步 · \(count) 首"
        case .failed(let msg):      return "● 失败: \(msg)"
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

private struct MacSTWidgetView: View {
    @Environment(AudioPlayerService.self) private var player
    @AppStorage("primuse.mac.widgetSyncEnabled") private var widgetSyncEnabled = false
    @State private var clickable = true

    private let widgets: [(name: String, sub: String, sizes: [String], on: Bool)] = [
        ("Now Playing", "正在播放 · 3 种尺寸", ["S", "M", "L"], true),
        ("歌词", "实时歌词跟随", ["M"], true),
        ("听歌统计", "过去 30 天 + Top", ["M"], true),
        ("最近播放", "4 张近期封面", ["S"], false),
        ("音乐源", "索引状态 · 在线 dot", ["S"], true),
        ("年度报告", "12 月专属 · STATS-05", ["M"], true),
    ]

    var body: some View {
        MacSTSection("跨进程数据共享",
                     hint: "主进程通过 App Group 容器把 NowPlaying 状态推给 WidgetKit Extension") {
            MacSTGroup {
                MacSTRow("向 Widget 推送 Now Playing", hint: "ST-07 · primuse.mac.widgetSyncEnabled", divider: false) {
                    MacSTToggle(isOn: $widgetSyncEnabled)
                }
                MacSTRow("刷新频率", hint: "电量优先 · 锁屏时降低至每 5 分钟") {
                    MacSTSelect(value: "自适应 (推荐)")
                }
                MacSTRow("共享数据范围", hint: "封面取自 MetadataAssetStore") {
                    MacSTSelect(value: "标题 + 艺术家 + 封面 + 进度 + 歌词")
                }
                MacSTRow("可点击交互", hint: "WidgetKit + AppIntents · macOS 14+") {
                    MacSTToggle(isOn: $clickable)
                    MacSTInfoText(text: "无需打开 app")
                }
                MacSTRow("立即刷新") {
                    MacSTButton(title: "推送状态", systemImage: "arrow.triangle.2.circlepath") {
                        player.publishWidgetStateForMacWidgetSync()
                    }
                }
            }
        }

        MacSTSection("可用 Widget", hint: "勾选启用 · 用户在系统通知中心 / Stage Manager 添加") {
            MacSTGroup {
                ForEach(Array(widgets.enumerated()), id: \.offset) { index, widget in
                    MacWidgetCatalogRow(widget: widget, divider: index != 0)
                }
            }
        }

        MacSTSection("Widget Gallery", hint: "Small 155×155 · Medium 342×155 · Large 342×342 · 与设计稿 ST-07 尺寸一致") {
            MacWidgetGalleryPreview()
        }
    }
}

private struct MacWidgetCatalogRow: View {
    let widget: (name: String, sub: String, sizes: [String], on: Bool)
    let divider: Bool

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(widget.on ? PMColor.brand : .clear)
                    .frame(width: 14, height: 14)
                    .overlay {
                        if widget.on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(PMColor.dividerStrong, lineWidth: 1.5)
                        }
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: widget.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: widget.sub)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                }

                Spacer()

                HStack(spacing: 4) {
                    ForEach(["S", "M", "L"], id: \.self) { size in
                        Text(verbatim: size)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(widget.sizes.contains(size) ? PMColor.brand : PMColor.textFaint)
                            .frame(width: 22, height: 22)
                            .background(widget.sizes.contains(size) ? PMColor.brand.opacity(0.16) : .clear,
                                        in: .rect(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                            }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

private struct MacWidgetGalleryPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                ForEach(["全部", "Now Playing", "Library", "Sources"], id: \.self) { chip in
                    Text(verbatim: chip)
                        .font(.system(size: 11.5, weight: chip == "全部" ? .semibold : .medium))
                        .foregroundStyle(chip == "全部" ? Color.white : PMColor.textMuted)
                        .frame(height: 26)
                        .padding(.horizontal, 12)
                        .background(chip == "全部" ? PMColor.brand : PMColor.glassBtn, in: .capsule)
                }
            }

            macWidgetSection("Now Playing · 正在播放", sub: "3 种尺寸 · Glanceable + Interactive") {
                MacWidgetTile(label: "Small 155") { MacWidgetNPSmallPreview() }
                MacWidgetTile(label: "Medium 342×155") { MacWidgetNPMediumPreview() }
                MacWidgetTile(label: "Large 342×342") { MacWidgetNPLargePreview() }
            }

            macWidgetSection("实时数据", sub: "歌词 / 统计 / 音乐源") {
                MacWidgetTile(label: "歌词 · Medium") { MacWidgetLyricsPreview() }
                MacWidgetTile(label: "听歌统计 · Medium") { MacWidgetStatsPreview() }
                MacWidgetTile(label: "音乐源 · Small") { MacWidgetSourcesPreview() }
            }

            macWidgetSection("侧边小组件", sub: "紧凑信息 · 适合堆叠在屏幕角落") {
                MacWidgetTile(label: "最近播放 · Small") { MacWidgetRecentPreview() }
                MacWidgetTile(label: "年度报告 · Medium") { MacWidgetWrappedPreview() }
                MacWidgetTile(label: "深色 · Medium") { MacWidgetNPMediumPreview(dark: true) }
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

        /// 实际 macOS widget 尺寸 (155 / 342) 在设置页里太大, 缩到 ~70% 给 preview
        /// 用。一行能放下 3 个 medium (≈ 240 × 3 + spacing ≈ 760pt), 不再横向溢出。
        var width: CGFloat {
            switch self {
            case .small: return 110
            case .medium, .large: return 240
            }
        }

        var height: CGFloat {
            switch self {
            case .small, .medium: return 110
            case .large: return 240
            }
        }
    }

    var size: Size
    var dark = false
    var padding: CGFloat = 14
    private let content: Content

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
    }
}

private struct MacWidgetNPSmallPreview: View {
    var body: some View {
        MacWidgetShell(size: .small, padding: 0) {
            ZStack(alignment: .bottomLeading) {
                MacWidgetCover(radius: 0, glyph: "猿")
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text("闯入听昔")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("虞兮叹")
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
                    Text("正在播放 · FLAC")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(faint)
                    Text("闯入听昔")
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(1)
                        .padding(.top, 4)
                    Text("虞兮叹")
                        .font(.system(size: 11.5))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                    Text("水调歌头")
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
                        Text("正在播放")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.50))
                        Text("闯入听昔")
                            .font(.system(size: 16, weight: .bold))
                            .lineLimit(1)
                        Text("虞兮叹")
                            .font(.system(size: 12))
                            .foregroundStyle(.black.opacity(0.65))
                        Text("水调歌头 · FLAC 988 kbps")
                            .font(.system(size: 10))
                            .foregroundStyle(.black.opacity(0.45))
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("明月几时有")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black.opacity(0.42))
                    Text("把酒问青天")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(PMColor.brand)
                    Text("不知天上宫阙")
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        MacWidgetCover(radius: 4, glyph: "猿")
                            .frame(width: 22, height: 22)
                        Text("闯入听昔")
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                        Text("· 虞兮叹")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.black.opacity(0.50))
                            .lineLimit(1)
                    }
                    Text("明月几时有")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black.opacity(0.45))
                    Text("把酒问青天")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(PMColor.brand)
                    Text("不知天上宫阙")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black.opacity(0.45))
                }
                .padding(.horizontal, 16)
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
                    Text("本月听歌")
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                    Text("过去 30 天")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.black.opacity(0.48))
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("246")
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(PMColor.brand)
                        Text("首播放")
                            .font(.system(size: 10))
                            .foregroundStyle(.black.opacity(0.52))
                        Text("17h")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .padding(.top, 8)
                        Text("总时长")
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
                        Text("本月最常听")
                            .font(.system(size: 10, weight: .semibold))
                        Text("1. 十年 · 陈奕迅")
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
        MacWidgetShell(size: .small) {
            VStack(alignment: .leading, spacing: 8) {
                Text("最近播放")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.black.opacity(0.58))
                LazyVGrid(columns: [GridItem(.fixed(56)), GridItem(.fixed(56))], spacing: 5) {
                    ForEach(0..<4, id: \.self) { idx in
                        MacWidgetCover(radius: 5, glyph: idx == 0 ? "猿" : "♪")
                            .frame(width: 56, height: 56)
                    }
                }
            }
        }
    }
}

private struct MacWidgetSourcesPreview: View {
    var body: some View {
        MacWidgetShell(size: .small) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("音乐源")
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
                Text("首已索引")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.black.opacity(0.56))
                    .padding(.bottom, 8)
                ForEach(["百度网盘", "Apple Music", "cqNas", "Synology"], id: \.self) { source in
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
                    Text("你的 2026\n已听 847 小时")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 6)
                    Spacer()
                    Label("查看年度报告", systemImage: "sparkles")
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
    var glyph: String

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
            Text(verbatim: glyph)
                .font(.system(size: glyph == "猿" ? 28 : 22, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
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
    @State private var isSyncingNow = false
    @State private var familyEnabled = CloudKitSyncService.familySharingEnabled
    @State private var familyBusy = false
    @State private var familyError: String?
    @State private var pendingShareURL: URL?

    var body: some View {
        MacSTSection("iCloud Sync") {
            MacSTGroup {
                MacSTRow("总开关", hint: "primuse.iCloudSyncEnabled · CloudKitSyncService", divider: false) {
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
                MacSTRow("同步状态") {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    MacSTInfoText(text: statusText, color: statusColor)
                    if let last = sync.lastSyncedAt {
                        MacSTInfoText(text: last.formatted(.relative(presentation: .named)))
                    }
                    if case .accountUnavailable(.noAccount) = sync.status {
                        MacSTButton(title: "打开系统设置", systemImage: "gear") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    MacSTButton(title: isSyncingNow ? "同步中…" : "立即同步",
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

        MacSTSection("同步频道", hint: "逐项控制哪些数据走 iCloud") {
            MacSTGroup {
                channelRow("歌单", spec: "C-01 · Playlist / SmartPlaylist", channel: .playlists, isOn: $syncPlaylists, divider: false)
                channelRow("源配置", spec: "C-01 · MusicSource", channel: .sources, isOn: $syncSources)
                channelRow("播放历史", spec: "C-01 · STATS-07", channel: .playbackHistory, isOn: $syncPlaybackHistory)
                channelRow("应用设置", spec: "C-02 · NSUbiquitousKeyValueStore", channel: .settings, isOn: $syncSettings)
                channelRow("Keychain 凭据", spec: "C-07 · 新写入凭据", channel: .credentials, isOn: $syncCredentials)
            }
        }

        MacSTSection("家庭共享 · CKShare (C-03)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: familyEnabled ? "person.2.badge.gearshape.fill" : "person.2.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(familyEnabled ? PMColor.ok : PMColor.brand)
                        .frame(width: 36, height: 36)
                        .background((familyEnabled ? PMColor.ok : PMColor.brand).opacity(0.14), in: .rect(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: familyEnabled ? "家庭共享已启用" : "创建家庭共享资料库")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Text(verbatim: familyEnabled ? "共享歌单、智能歌单与家庭音乐源" : "通过 CloudKit 分享可协作的资料库内容")
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textMuted)
                    }

                    Spacer()

                    if familyEnabled {
                        MacSTButton(title: familyBusy ? "处理中…" : "邀请…", systemImage: "square.and.arrow.up") {
                            Task { await inviteFamily() }
                        }
                        .disabled(familyBusy)
                        MacSTButton(title: "关闭", destructive: true) {
                            Task { await disableFamily() }
                        }
                        .disabled(familyBusy)
                    } else {
                        MacSTButton(title: familyBusy ? "创建中…" : "创建", systemImage: "person.2.badge.plus", prominent: true) {
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
    @State private var themeChoice = "system"
    @State private var ambientEnabled = true
    @State private var saturation = 70.0
    @State private var autoDetectMaterial = true

    private let swatches: [(hex: String, name: String, sub: String, color: Color)] = [
        ("#c96442", "赤陶 Terracotta", "默认 · 暖木听音室", PMColor.brand),
        ("#0a84ff", "macOS Blue", "系统标准 HIG accent", Color(red: 0.04, green: 0.52, blue: 1.0)),
        ("#1f8a5b", "Forest 森绿", "山林清幽", Color(red: 0.12, green: 0.54, blue: 0.36)),
        ("#5e6b87", "Slate 石板", "极简数据感", Color(red: 0.37, green: 0.42, blue: 0.53)),
        ("#a0522d", "Mahogany 红木", "复古黑胶", Color(red: 0.63, green: 0.32, blue: 0.18)),
    ]

    var body: some View {
        MacSTSection("外观", hint: "THEME-01") {
            MacSTGroup {
                MacSTRow("主题", divider: false, block: true) {
                    HStack(spacing: 8) {
                        MacThemeChoiceCard(title: "浅色", icon: "sun.max", selected: themeChoice == "light") {
                            themeChoice = "light"
                        }
                        MacThemeChoiceCard(title: "深色", icon: "moon", selected: themeChoice == "dark") {
                            themeChoice = "dark"
                        }
                        MacThemeChoiceCard(title: "跟随系统", icon: "desktopcomputer", selected: themeChoice == "system") {
                            themeChoice = "system"
                        }
                    }
                }
            }
        }

        MacSTSection("品牌色",
                     hint: "THEME-02 · 不强制 tint 系统控件 · 只影响自定义按钮、进度条、active 高亮、ambient fallback") {
            MacSTGroup {
                ForEach(Array(swatches.enumerated()), id: \.offset) { index, swatch in
                    MacBrandSwatchRow(swatch: swatch, selected: index == 0, divider: index != 0)
                }
            }
        }

        MacSTSection("封面取色") {
            MacSTGroup {
                MacSTRow("Ambient 强度",
                         hint: "THEME-03 · 控制 NowPlaying / Mini / 桌面歌词背景色斑浓度",
                         divider: false) {
                    MacSTSlider(
                        value: Binding(
                            get: { preferences.ambientStrength * 100 },
                            set: { preferences.ambientStrength = $0 / 100 }
                        ),
                        in: 0...100,
                        formatter: { String(format: "%.0f%%", $0) }
                    )
                }
                MacSTRow("歌词字号缩放") {
                    MacSTSlider(
                        value: Binding(
                            get: { Double(preferences.lyricsFontScale * 100) },
                            set: { preferences.lyricsFontScale = CGFloat($0 / 100) }
                        ),
                        in: 70...180,
                        formatter: { String(format: "%.0f%%", $0) }
                    )
                }
            }
        }

        MacSTSection("App Icon", hint: "THEME-04 · macOS 仅支持启动器图标缓存重建") {
            HStack(spacing: 12) {
                MacAppIconOption(title: "默认 · 猿", selected: true, style: .default)
                MacAppIconOption(title: "深色 · 猿", selected: false, style: .dark)
                MacAppIconOption(title: "玻璃 · 猿", selected: false, style: .glass)
                MacAppIconOption(title: "黑胶", selected: false, style: .vinyl)
            }
        }

        MacSTSection("材质") {
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
                MacSTRow("启动时自动检测 macOS 版本", hint: "if #available(macOS 26.0, *)", divider: false) {
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

    var body: some View {
        VStack(spacing: 0) {
            if divider {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }

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
        }
    }
}

private struct MacAppIconOption: View {
    enum IconStyle {
        case `default`, dark, glass, vinyl
    }

    let title: String
    let selected: Bool
    let style: IconStyle

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(background)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.16), radius: selected ? 8 : 4, y: 3)
                if style == .vinyl {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 4).frame(width: 34, height: 34)
                    Circle().fill(PMColor.brand).frame(width: 12, height: 12)
                } else {
                    Text(verbatim: "猿")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(PMColor.brand, lineWidth: 2)
                }
            }

            Text(verbatim: title)
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
        }
    }

    private var background: LinearGradient {
        switch style {
        case .default:
            return LinearGradient(colors: [PMColor.brand, Color(red: 0.37, green: 0.23, blue: 0.13)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .dark:
            return LinearGradient(colors: [Color(red: 0.16, green: 0.15, blue: 0.11), Color.black],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .glass:
            return LinearGradient(colors: [Color(red: 0.47, green: 0.55, blue: 0.70).opacity(0.75),
                                           Color(red: 0.24, green: 0.31, blue: 0.47).opacity(0.65)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .vinyl:
            return LinearGradient(colors: [Color.black, Color(red: 0.10, green: 0.10, blue: 0.10)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
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
                         hint: "ST-09 · 30 天内可恢复") {
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
                         hint: "ST-09 · 包含连接凭据") {
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
                         hint: "ST-09 · 元数据刮削自定义源") {
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
                MacSTButton(title: "恢复")
                MacSTButton(title: "永久删除", destructive: true)
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

    private var domains: [String] {
        _ = refreshTick
        return SSLTrustStore.shared.trustedDomains
    }

    var body: some View {
        MacSTSection("信任的自签证书",
                     hint: "ST-10 · 这些域名的 SSL 证书不在系统钥匙串里,你已手动信任") {
            MacSTGroup {
                if domains.isEmpty {
                    MacSTRow("暂无信任域名", hint: "遇到自签证书源时可在连接流程里加入信任列表", divider: false) {
                        MacSTButton(title: "添加…", systemImage: "plus") {
                            beginAdd()
                        }
                    }
                } else {
                    ForEach(Array(domains.enumerated()), id: \.offset) { index, domain in
                        MacSSLRow(domain: domain, divider: index != 0) {
                            SSLTrustStore.shared.untrust(domain: domain)
                            refreshTick &+= 1
                        }
                    }
                    MacSTRow("添加域名", hint: "host.example.com", divider: true) {
                        MacSTButton(title: "添加…", systemImage: "plus") {
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
                    Text(verbatim: "添加信任域名")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "ST-10 · 仅信任该域名的自签证书")
                        .font(PMFont.caption)
                        .foregroundStyle(PMColor.textMuted)
                }
                Spacer()
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "域名")
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
                Text(verbatim: "只填写 host，不需要包含 https:// 或路径。")
                    .font(PMFont.caption)
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(18)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Spacer()
                MacSTButton(title: "取消") {
                    showAddSheet = false
                    newDomain = ""
                }
                MacSTButton(title: "添加", prominent: true) {
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
    let domain: String
    let divider: Bool
    let remove: () -> Void

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
                    Text(verbatim: domain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(verbatim: "SHA256:手动信任 · 本机存储")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }

                Spacer()
                MacSTButton(title: "移除", destructive: true, action: remove)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - ST-11 About

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
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [PMColor.brand, PMColor.bgDeep],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
                .frame(width: 96, height: 96)
                .overlay {
                    Text(verbatim: "猿")
                        .font(.system(size: 50, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: PMColor.brand.opacity(0.32), radius: 24, y: 8)

            Text(verbatim: "猿音 Primuse")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(PMColor.text)
                .padding(.top, 14)

            Text(verbatim: "\(version) (build \(build)) · macOS 26.0+")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .padding(.top, 4)

            HStack(spacing: 12) {
                MacSTButton(title: "检查更新")
                MacSTButton(title: "开源许可证…") {
                    showLicenses = true
                }
                MacSTButton(title: "诊断日志…")
            }
            .padding(.top, 24)

            Text(verbatim: "Primuse 是一款面向 NAS / 媒体服务器烧友的原生 macOS 播放器,基于 SFBAudioEngine。本设计稿覆盖 200+ 功能点,A 套使用 macOS 26+ 的 .glassEffect(),B 套 fallback 到 .regularMaterial。\n\n© 2026 Primuse Project · Made for lossless lovers.")
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
            NavigationStack {
                LicensesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") { showLicenses = false }
                        }
                    }
            }
            .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 600)
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
