#if os(iOS)
import PrimuseKit
import SwiftUI

/// CarPlay 编辑器的配色。经典样式下每一项都原样是系统色(界面测试钉着这套外观);
/// 自己画底色的样式下换成样式的色位。
///
/// 这里是 87 处调用共用的静态入口,读不到 SwiftUI 环境,所以当前样式由 `SkinRuntime`
/// 在换样式时写进来,与 `PMMotionSkin` 同一个做法。
enum CarPlayEditorTheme {
    nonisolated(unsafe) static var style = SkinStyle()

    private static func pick(_ classic: Color, _ token: SkinColorToken) -> Color {
        style.paintsPageBackground ? style.color(token) : classic
    }

    static var background: Color { pick(Color(uiColor: .systemGroupedBackground), .canvasSunken) }
    static var canvas: Color { pick(Color(uiColor: .systemBackground), .canvas) }
    static var sidebar: Color { pick(Color(uiColor: .secondarySystemBackground), .surface) }
    static var surface: Color { pick(Color(uiColor: .secondarySystemGroupedBackground), .surface) }
    static var sheet: Color { pick(Color(uiColor: .systemBackground), .canvasElevated) }
    static var row: Color { pick(Color(uiColor: .secondarySystemBackground), .surface) }
    static var border: Color { pick(Color(uiColor: .separator).opacity(0.3), .surfaceBorder) }
    static let accent = Color.accentColor
    static let accentText = Color.accentColor
    static var text: Color { pick(Color.primary, .textPrimary) }
    static var secondary: Color { pick(Color.secondary, .textSecondary) }
    static var muted: Color { pick(Color.secondary.opacity(0.7), .textTertiary) }
    static let artwork = LinearGradient(colors: [Color(uiColor: .tertiarySystemFill), Color(uiColor: .secondarySystemFill)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct CarPlayEditorActivePreferenceKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

// MARK: - Main menu

struct CarPlayMainMenuEditor: View {
    let model: CarPlayEditorModel
    let addCollection: () -> Void
    let openPlayback: () -> Void
    let savePreset: () -> Void
    let openLibrary: () -> Void
    @State private var renaming: CarPlayMainTab?
    @State private var name = ""

    private var visibleCount: Int { model.configuration.tabs.filter(\.isVisible).count }

    var body: some View {
        List {
            Section {
                ForEach(model.configuration.tabs) { tab in tabRow(tab) }
                    .onMove { offsets, destination in
                        model.change { $0.tabs.move(fromOffsets: offsets, toOffset: destination) }
                    }
                    .dropDestination(for: String.self) { values, index in
                        let tabs = model.configuration.tabs
                        _ = model.dropTab(values, before: tabs.indices.contains(index) ? tabs[index].id : nil)
                    }
                Menu {
                    ForEach(CarPlayMainTab.Kind.allCases.filter { $0 != .collection }, id: \.self) { kind in
                        if !model.configuration.tabs.contains(where: { $0.kind == kind }) {
                            Button(LocalizedStringKey(kind.titleKey), systemImage: kind.symbol) { model.addTab(kind) }
                        }
                    }
                    Divider()
                    Button("carplay_content_sources", systemImage: "folder.badge.plus", action: addCollection)
                } label: {
                    Label("carplay_add", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAddTab)
                .accessibilityIdentifier("carplay.addTab")
            } header: {
                HStack {
                    Text("carplay_main_menu")
                    Spacer()
                    Text(verbatim: "\(visibleCount)/\(model.maximumTabCount)").monospacedDigit()
                }
            }

            if model.configuration.showsSiri {
                Section {
                    Picker("Siri", selection: Binding(get: { model.configuration.siriPresentation }, set: { value in
                        model.change { $0.siriPresentation = value }
                    })) {
                        Text("carplay_siri_button").tag(CarPlaySiriPresentation.button)
                        Text("carplay_siri_row").tag(CarPlaySiriPresentation.row)
                    }
                }
            }

            Section {
                Button(action: openPlayback) {
                    HStack(spacing: 12) {
                        Label("carplay_now_playing", systemImage: "play.circle")
                        Spacer(minLength: 8)
                        Text(LocalizedStringKey(model.configuration.minimalNowPlaying ? "carplay_preset_focus" : "carplay_player_standard"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("carplay.playbackRow")
            }

            Section("carplay_layout_title") {
                Button(action: openLibrary) {
                    HStack(spacing: 12) {
                        Label("carplay_styles_title", systemImage: "square.grid.2x2")
                        Spacer(minLength: 8)
                        if !model.settings.savedLayouts.isEmpty {
                            Text(verbatim: "\(model.settings.savedLayouts.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("carplay.libraryRow")
                Button(action: savePreset) {
                    Label("carplay_save_preset", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("carplay.savePresetRow")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4)
        .alert("carplay_menu_name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("carplay_menu_name", text: $name)
            Button("cancel", role: .cancel) { renaming = nil }
            Button("save") {
                if let renaming { model.renameTab(renaming.id, title: name) }
                renaming = nil
            }
        }
    }

    private func tabRow(_ tab: CarPlayMainTab) -> some View {
        let canHide = model.visibleTabs.count > 1
        let canShow = visibleCount < model.maximumTabCount
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(CarPlayEditorTheme.muted)
                .frame(width: 18, height: 36)
                .draggable("carplay-tab:" + tab.id) {
                    Label(tab.displayTitle, systemImage: tab.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CarPlayEditorTheme.text)
                        .frame(width: 220, height: 48)
                        .background(CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("carplay_move_module")
                .accessibilityIdentifier("carplay.dragTab." + tab.id)
            Button { model.selectTab(tab.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: tab.symbol)
                        .foregroundStyle(CarPlayEditorTheme.accentText)
                        .frame(width: 24)
                    Text(tab.displayTitle)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if tab.kind == .home {
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("carplay.editTab." + tab.id)
            // A context menu on the row would capture the drag handle's long press.
            Menu {
                Button("carplay_menu_name", systemImage: "pencil") {
                    name = tab.displayTitle
                    renaming = tab
                }
                Button("carplay_move_up", systemImage: "arrow.up") { model.moveTab(tab.id, by: -1) }
                Button("carplay_move_down", systemImage: "arrow.down") { model.moveTab(tab.id, by: 1) }
                Button("delete", systemImage: "trash", role: .destructive) { model.removeTab(tab.id) }
                    .disabled(tab.isVisible && !canHide)
            } label: {
                Image(systemName: "pencil").frame(width: 28, height: 36)
            } primaryAction: {
                name = tab.displayTitle
                renaming = tab
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("carplay_menu_name")
            .accessibilityIdentifier("carplay.renameTab." + tab.id)
            Button { model.toggleTab(tab) } label: {
                Image(systemName: tab.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(tab.isVisible ? CarPlayEditorTheme.accent : CarPlayEditorTheme.muted)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(tab.isVisible ? !canHide : !canShow)
            .accessibilityLabel(LocalizedStringKey(tab.isVisible ? "carplay_hide_module" : "carplay_show_module"))
            .accessibilityIdentifier("carplay.tabVisibility." + tab.id)
        }
        .opacity(tab.isVisible ? 1 : 0.5)
        .listRowBackground(CarPlayEditorTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("carplay.menuRow." + tab.id)
        .accessibilityAction(named: Text("carplay_move_up")) { model.moveTab(tab.id, by: -1) }
        .accessibilityAction(named: Text("carplay_move_down")) { model.moveTab(tab.id, by: 1) }

    }
}

// MARK: - Home modules

struct CarPlayModuleList: View {
    let model: CarPlayEditorModel
    let addModule: () -> Void

    private var visibleCount: Int { model.configuration.blocks.filter(\.isVisible).count }

    var body: some View {
        List {
            Section {
                ForEach(model.configuration.blocks) { block in moduleRow(block) }
                    .onMove { offsets, destination in
                        model.change { $0.blocks.move(fromOffsets: offsets, toOffset: destination) }
                    }
                    .dropDestination(for: String.self) { values, index in
                        let blocks = model.configuration.blocks
                        _ = model.drop(values, before: blocks.indices.contains(index) ? blocks[index].id : nil)
                    }
                Button(action: addModule) {
                    Label("carplay_add_module", systemImage: "plus")
                }
                .disabled(model.configuration.blocks.count >= CarPlayLayoutConfiguration.maximumBlockCount)
                .accessibilityIdentifier("carplay.addModule")
            } header: {
                HStack {
                    Text("carplay_home_modules")
                    Spacer()
                    Text(verbatim: "\(visibleCount)/\(model.configuration.blocks.count)").monospacedDigit()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4)
    }

    private func moduleRow(_ block: CarPlayLayoutBlock) -> some View {
        let title = block.title.isEmpty ? NSLocalizedString(block.kind.titleKey, comment: "") : block.title
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(CarPlayEditorTheme.muted)
                .frame(width: 18, height: 40)
                .draggable("carplay-block:" + block.id) {
                    Label(title, systemImage: block.kind.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CarPlayEditorTheme.text)
                        .frame(width: 260, height: 54)
                        .background(CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("carplay_move_module")
                .accessibilityIdentifier("carplay.drag." + block.id)
            Button { model.select(block.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: block.kind.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(CarPlayEditorTheme.accentText)
                        .frame(width: 30, height: 30)
                        .background(CarPlayEditorTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(summary(block))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("carplay.module." + block.id)
            Button { model.update(block.id) { $0.isVisible.toggle() } } label: {
                Image(systemName: block.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(block.isVisible ? CarPlayEditorTheme.accent : CarPlayEditorTheme.muted)
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(LocalizedStringKey(block.isVisible ? "carplay_hide_module" : "carplay_show_module"))
            .accessibilityIdentifier("carplay.visibility." + block.id)
        }
        .opacity(block.isVisible ? 1 : 0.5)
        .listRowBackground(
            model.selectedID == block.id
                ? CarPlayEditorTheme.accent.opacity(0.12) : CarPlayEditorTheme.surface
        )
        .accessibilityAction(named: Text("carplay_move_up")) { model.move(block.id, by: -1) }
        .accessibilityAction(named: Text("carplay_move_down")) { model.move(block.id, by: 1) }

    }

    private func summary(_ block: CarPlayLayoutBlock) -> String {
        guard block.isVisible else { return String(localized: "carplay_module_hidden") }
        let style = block.style == .list || block.style == .capsules ? NSLocalizedString(block.style.titleKey, comment: "") : "\(block.columns)×\(block.rowsPerPage) " + String(localized: "carplay_style_covers")
        return style + " · \(block.itemLimit) " + String(localized: "carplay_items_unit") + " · " + String(localized: block.playsImmediately ? "carplay_action_play" : "carplay_action_browse")
    }
}

// MARK: - Shared controls

struct CarPlaySegment<Value: Hashable>: View {
    let values: [(Value, String)]
    @Binding var selection: Value
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(values.indices, id: \.self) { index in
                Text(LocalizedStringKey(values[index].1)).tag(values[index].0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minHeight: 32)
    }
}

struct CarPlayLayoutGlyph: View {
    var columns: Int
    var rows: Int
    var selected = false
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<columns, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2).fill(selected ? CarPlayEditorTheme.accent : CarPlayEditorTheme.border)
                    }
                }
            }
        }
    }
}

struct CarPlayStyleThumbnail: View {
    let style: CarPlayVisualStyle
    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 10) {
                Image(systemName: "music.note").foregroundStyle(.tint)
                Image(systemName: "map")
                Spacer(minLength: 0)
                Image(systemName: "square.grid.2x2")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 10).frame(width: 22)
            let columns = style == .wall ? 3 : style == .capsules ? 2 : 1
            let rows = style == .wall ? 2 : 3
            VStack(spacing: 6) {
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: 6) {
                        ForEach(0..<columns, id: \.self) { _ in
                            if style == .wall {
                                RoundedRectangle(cornerRadius: 6).fill(CarPlayEditorTheme.artwork)
                                    .overlay { Image(systemName: "music.note").font(.caption).foregroundStyle(.secondary) }
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "music.note").font(.system(size: 10)).foregroundStyle(.secondary)
                                    Capsule().fill(.tertiary).frame(height: 4)
                                }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: style == .capsules ? 14 : 6))
                            }
                        }
                    }
                }
            }
        }.padding(8).background(CarPlayEditorTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

// MARK: - Style library

struct CarPlayPresetLibrary: View {
    let model: CarPlayEditorModel
    let close: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("carplay_styles_subtitle")
                    .font(.footnote)
                    .foregroundStyle(CarPlayEditorTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                ForEach(CarPlayVisualStyle.allCases) { style in
                    card(title: style.titleKey, subtitle: style.subtitleKey, style: style, current: model.configuration.visualStyle == style) {
                        model.apply(style)
                    }
                }
                if !model.settings.savedLayouts.isEmpty {
                    Text("carplay_my_presets")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CarPlayEditorTheme.secondary)
                        .padding(.top, 8)
                        .padding(.horizontal, 4)
                    ForEach(model.settings.savedLayouts) { saved in
                        card(title: saved.name, subtitle: "carplay_saved_layout", style: saved.configuration.visualStyle,
                             current: model.configuration == saved.configuration) { model.apply(saved) }
                            .contextMenu {
                                Button("delete", systemImage: "trash", role: .destructive) {
                                    model.settings.savedLayouts.removeAll { $0.id == saved.id }
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .skinPageBackground(replacing: .canvasSunken)
        .foregroundStyle(CarPlayEditorTheme.text)
    }

    private func card(title: String, subtitle: String, style: CarPlayVisualStyle, current: Bool, apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            CarPlayStyleThumbnail(style: style).frame(height: 110)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .semibold))
                        if current {
                            Text("carplay_in_use").font(.system(size: 10, weight: .bold)).foregroundStyle(CarPlayEditorTheme.background)
                                .padding(.horizontal, 7).padding(.vertical, 1).background(CarPlayEditorTheme.accent, in: Capsule())
                        }
                    }
                    Text(LocalizedStringKey(subtitle)).font(.system(size: 12)).foregroundStyle(CarPlayEditorTheme.secondary)
                }
                Spacer()
                Button {
                    if current { close() } else { apply() }
                } label: {
                    if current { Label("carplay_fine_tune", systemImage: "pencil") }
                    else { Text("carplay_use") }
                }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).fixedSize()
                    .accessibilityIdentifier("carplay.preset." + style.rawValue)
            }
        }
        .padding(12)
        .background(current ? CarPlayEditorTheme.accent.opacity(0.10) : CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(current ? CarPlayEditorTheme.accent : CarPlayEditorTheme.border, lineWidth: current ? 1.5 : 1) }
    }
}

// MARK: - Module picker

struct CarPlayModulePicker: View {
    let model: CarPlayEditorModel
    let close: () -> Void
    @State private var query = ""

    private var playbackKinds: [CarPlayLayoutBlockKind] { [.shortcuts, .custom].filter(matches) }
    private var libraryKinds: [CarPlayLayoutBlockKind] { [.folders, .playlists, .albums, .ranking, .recentlyAdded, .radio, .siri].filter(matches) }
    private var atLimit: Bool { model.configuration.blocks.count >= CarPlayLayoutConfiguration.maximumBlockCount }

    var body: some View {
        NavigationStack {
            List {
                if !playbackKinds.isEmpty {
                    Section("carplay_play_entries") {
                        ForEach(playbackKinds) { kind in row(kind) }
                    }
                }
                if !libraryKinds.isEmpty {
                    Section("library_title") {
                        ForEach(libraryKinds) { kind in row(kind) }
                    }
                }
                if playbackKinds.isEmpty && libraryKinds.isEmpty {
                    Section {
                        Text("carplay_no_content")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "carplay_search_modules")
            .autocorrectionDisabled()
            .navigationTitle("carplay_add_module")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done", action: close)
                }
            }
        }
    }

    private func matches(_ kind: CarPlayLayoutBlockKind) -> Bool {
        query.isEmpty || NSLocalizedString(kind.titleKey, comment: "").localizedStandardContains(query)
    }

    private func added(_ kind: CarPlayLayoutBlockKind) -> Bool { model.configuration.blocks.contains { $0.kind == kind } }

    private func row(_ kind: CarPlayLayoutBlockKind) -> some View {
        Button { model.add(kind) } label: {
            HStack(spacing: 12) {
                moduleGlyph(kind)
                    .padding(6)
                    .frame(width: 44, height: 44)
                    .background(CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(kind == .custom ? "carplay_cover_wall" : kind.titleKey))
                        .font(.body.weight(.medium))
                    Text(LocalizedStringKey("carplay_module_" + kind.rawValue + "_detail"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: added(kind) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(CarPlayEditorTheme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(atLimit && (kind == .custom || !added(kind)))
        .accessibilityIdentifier("carplay.add." + kind.rawValue)
    }

    @ViewBuilder private func moduleGlyph(_ kind: CarPlayLayoutBlockKind) -> some View {
        switch kind {
        case .ranking:
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach([0.9, 0.65, 0.4], id: \.self) { fraction in
                        Capsule().fill(CarPlayEditorTheme.accent.opacity(fraction))
                            .frame(width: geometry.size.width * fraction, height: 5)
                    }
                }.frame(maxHeight: .infinity)
            }
        case .shortcuts, .playlists, .recentlyAdded:
            CarPlayLayoutGlyph(columns: 1, rows: 3)
        case .folders:
            CarPlayLayoutGlyph(columns: 3, rows: 1)
        case .albums:
            CarPlayLayoutGlyph(columns: 3, rows: 2)
        case .custom, .radio, .siri:
            CarPlayLayoutGlyph(columns: 2, rows: 2)
        }
    }
}
#endif
