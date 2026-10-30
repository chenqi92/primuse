#if os(iOS)
import PrimuseKit
import SwiftUI

struct CarPlaySettingsView: View {
    @Environment(\.settingsFocusedAnchor) private var focusedAnchor
    @State private var model: CarPlayEditorModel
    @State private var catalog = CarPlayEditorCatalog.shared
    @State private var folders = CarPlayFolderLibrary.shared
    @State private var showingLibrary: Bool
    @State private var addingModule = false
    @State private var addingContent = false
    @State private var addingTabContent = false
    @State private var fullScreen = false
    @State private var playbackOptions = false
    @State private var editingSpokenWordButtons = false
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var owner = UUID()
    @State private var previewItem: CarPlayHomeItem?
    /// 浮动预览放在哪儿、多大(记在本机,下次进来还在原处)。
    @AppStorage(CarPlayPreviewWindow.positionKey) private var previewPosition = ""
    @AppStorage(CarPlayPreviewWindow.widthKey) private var previewWidth = 0.0

    init(settings: CarPlaySettingsStore = .shared, model: CarPlayEditorModel? = nil, showsLibrary: Bool = false) {
        _model = State(initialValue: model ?? CarPlayEditorModel(settings: settings))
        _showingLibrary = State(initialValue: showsLibrary)
    }

    private enum Panel { case menu, modules, inspector }

    private var panel: Panel {
        if model.inspectorVisible, model.selected != nil { return .inspector }
        return model.homeEditorVisible ? .modules : .menu
    }

    private var inspectedBlock: CarPlayLayoutBlock? {
        panel == .inspector ? model.selected : nil
    }

    private var nowPlaying: CarPlayHomeItem? {
        let player = AppServices.shared.playerService
        guard player.currentSong != nil || player.currentRadioStation != nil else { return nil }
        return CarPlayHomeItem(id: "nowPlaying", title: String(localized: "carplay_now_playing"),
            subtitle: player.currentSong?.title ?? player.currentRadioStation?.name, symbol: "play.circle.fill",
            artwork: player.currentSong.map(CarPlayContentArtwork.song), target: .nowPlaying)
    }

    private var blocks: [CarPlayHomeBlock] {
        catalog.snapshot.blocks(for: model.configuration, folders: folders.index, nowPlaying: nowPlaying)
    }

    private var navigationTitleText: Text {
        if showingLibrary { return Text("carplay_styles_title") }
        switch panel {
        case .menu: return Text("carplay_editor_title")
        case .modules: return Text("carplay_home_modules")
        case .inspector:
            guard let block = inspectedBlock else { return Text("carplay_home_modules") }
            return block.title.isEmpty ? Text(LocalizedStringKey(block.kind.titleKey)) : Text(verbatim: block.title)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if showingLibrary {
                    CarPlayPresetLibrary(model: model) { showingLibrary = false }
                } else {
                    // 预览和「播放页样式与按钮」一样浮在列表上:拖住下面那一排挪到哪儿停在哪儿,双指捏合调大小,
                    // 列表占满整页;预览停在下半屏时列表底下多留一截,最后几行能滚到它上面。
                    let window = FloatingPreviewWindowMetrics.frame(
                        position: previewPosition,
                        storedWidth: previewWidth,
                        shape: CarPlayPreviewWindow.shape,
                        in: geometry.size
                    )
                    editorPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentMargins(
                            .bottom,
                            FloatingPreviewWindowMetrics.bottomContentMargin(for: window, in: geometry.size),
                            for: .scrollContent
                        )
                        .overlay {
                            FloatingPreviewWindow(
                                area: geometry.size,
                                shape: CarPlayPreviewWindow.shape,
                                position: $previewPosition,
                                storedWidth: $previewWidth,
                                // 画布里能滚、能拖模块和标签,挪窗口只认下面那一排。
                                movesByStripOnly: true,
                                accessibilityTitle: "carplay_preview"
                            ) {
                                canvas
                            } strip: {
                                CarPlayPreviewStrip()
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CarPlayEditorTheme.background)
        }
        .foregroundStyle(CarPlayEditorTheme.text)
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(showingLibrary || panel != .menu)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { editorToolbar }
        .toolbar(.hidden, for: .tabBar)
        .preference(key: CarPlayEditorActivePreferenceKey.self, value: true)
        .sheet(isPresented: $addingModule) {
            CarPlayModulePicker(model: model) { addingModule = false }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $addingContent) {
            CarPlayContentPicker(catalog: catalog, initialKind: focusedAnchor == "carplay.folders" ? .folder : .playlist) { item in
                if model.selectedID == nil { model.add(.custom) }
                guard let id = model.selectedID else { return false }
                return model.addContent(item, to: id, resolved: blocks.first(where: { $0.id == id })?.items ?? [])
            }.presentationDetents([.large])
        }
        .sheet(isPresented: $addingTabContent) {
            CarPlayContentPicker(catalog: catalog, allowedKinds: [.playlist, .folder, .album]) { item in
                let added = model.addTab(.collection, content: item)
                if added { addingTabContent = false }
                return added
            }.presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $fullScreen) { expandedPreview }
        .sheet(isPresented: $playbackOptions) { playbackSettings }
        .alert("carplay_save_preset", isPresented: $savingPreset) {
            TextField("carplay_preset_name", text: $presetName)
            Button("cancel", role: .cancel) {}
            Button("save") {
                model.flush()
                let saved = CarPlaySavedLayout(name: presetName, configuration: model.configuration)
                if !saved.name.isEmpty { model.settings.savedLayouts.append(saved) }
            }.disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            catalog.acquire(owner)
            updateFolderAccess()
        }
        .onDisappear { model.continuousChange(false); model.flush(); catalog.release(owner); folders.release(owner) }
        .onChange(of: model.configuration.folderIDs) { updateFolderAccess() }
        .onChange(of: model.configuration.blocks) { updateFolderAccess() }
        .onChange(of: model.configuration.tabs) { updateFolderAccess() }
        .task(id: focusedAnchor) {
            if ["carplay.onConnect", "carplay.afterPlay", "carplay.minimal"].contains(focusedAnchor ?? "") {
                playbackOptions = true
            } else if focusedAnchor == "carplay.folders" || focusedAnchor == "carplay.playlists" {
                addingContent = true
            } else if focusedAnchor == "carplay.preset" {
                showingLibrary = true
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        if showingLibrary || panel != .menu {
            ToolbarItem(placement: .topBarLeading) {
                Button("back", systemImage: "chevron.backward", action: goBack)
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("carplay.back")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if showingLibrary {
                EmptyView()
            } else if panel == .inspector {
                Button("done") { model.inspectorVisible = false; model.continuousChange(false) }
            } else {
                Button("carplay_undo", systemImage: "arrow.uturn.backward", action: model.undo)
                    .labelStyle(.iconOnly)
                    .disabled(!model.history.canUndo)
                    .accessibilityIdentifier("carplay.undoButton")
                Button("carplay_redo", systemImage: "arrow.uturn.forward", action: model.redo)
                    .labelStyle(.iconOnly)
                    .disabled(!model.history.canRedo)
                    .accessibilityIdentifier("carplay.redoButton")
                Menu {
                    if panel == .modules {
                        Button("carplay_main_menu", systemImage: "rectangle.3.group", action: model.showMainMenu)
                    }
                    Button("carplay_now_playing", systemImage: "play.circle") { playbackOptions = true }
                        .accessibilityIdentifier("carplay.playbackSettings")
                    Section("carplay_layout_title") {
                        ForEach(CarPlayVisualStyle.allCases) { style in
                            Button { model.apply(style) } label: {
                                if model.configuration.visualStyle == style {
                                    Label(LocalizedStringKey(style.titleKey), systemImage: "checkmark")
                                } else {
                                    Text(LocalizedStringKey(style.titleKey))
                                }
                            }
                            .accessibilityIdentifier("carplay.style." + style.rawValue)
                        }
                        Button("carplay_styles_title", systemImage: "square.grid.2x2") { showingLibrary = true }
                            .accessibilityIdentifier("carplay.styles")
                    }
                    Section {
                        Button("carplay_save_preset_short", systemImage: "square.and.arrow.down") { presetName = ""; savingPreset = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("carplay.actions")
            }
        }
    }

    private func goBack() {
        if showingLibrary {
            showingLibrary = false
        } else if model.inspectorVisible {
            model.inspectorVisible = false
            model.continuousChange(false)
        } else {
            model.showMainMenu()
        }
    }

    // MARK: - Preview

    private var canvas: some View {
        CarPlayEditorCanvas(blocks: blocks, configuration: model.configuration, selectedID: model.selectedID,
            editing: model.homeEditorVisible, playerPage: false, wide: false, previewItem: previewItem ?? nowPlaying,
            select: model.select, activate: { previewItem = $0 },
            drop: { values, id, _ in model.drop(values, before: id) },
            addContent: { _ in addingModule = true }, catalog: catalog.snapshot,
            selectedTabID: model.selectedTabID, selectTab: model.selectTab,
            moveTab: { values, id in model.dropTab(values, before: id) }, editingMenu: true)
            .overlay(alignment: .topTrailing) {
                Button { fullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold)).frame(width: 32, height: 32)
                        .background(.regularMaterial, in: Circle())
                        .overlay { Circle().strokeBorder(CarPlayEditorTheme.border, lineWidth: 1) }
                }
                .buttonStyle(.plain).offset(x: 8, y: -14)
                .accessibilityLabel("carplay_expand_preview").accessibilityIdentifier("carplay.expand")
            }
            .settingsAnchor("carplay.sections")
    }

    // MARK: - Panels

    @ViewBuilder private var editorPanel: some View {
        switch panel {
        case .menu:
            CarPlayMainMenuEditor(model: model,
                addCollection: { addingTabContent = true },
                openPlayback: { playbackOptions = true },
                savePreset: { presetName = ""; savingPreset = true },
                openLibrary: { showingLibrary = true })
        case .modules:
            CarPlayModuleList(model: model) { addingModule = true }
        case .inspector:
            if let block = inspectedBlock {
                CarPlayModuleInspector(model: model, block: block,
                    items: blocks.first(where: { $0.id == block.id })?.items ?? [],
                    add: { addingContent = true }, preview: { fullScreen = true })
            }
        }
    }

    // MARK: - Now Playing options

    private var playbackSettings: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CarPlayEditorCanvas(blocks: [], configuration: model.configuration, selectedID: nil,
                    editing: false, playerPage: true, wide: false, previewItem: previewItem ?? nowPlaying,
                    select: { _ in }, activate: { _ in }, drop: { _, _, _ in false }, addContent: { _ in },
                    spokenWordPlaybackPreview: editingSpokenWordButtons)
                    .frame(maxWidth: 600)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                List {
                    Section {
                        Picker("carplay_player_style", selection: configurationBinding(\.minimalNowPlaying)) {
                            Text("carplay_player_standard").tag(false)
                            Text("carplay_preset_focus").tag(true)
                        }
                        .settingsAnchor("carplay.minimal")
                        Picker("carplay_connection_page", selection: configurationBinding(\.opensNowPlayingOnConnect)) {
                            Text("carplay_home_title").tag(false)
                            Text("carplay_now_playing").tag(true)
                        }
                        .settingsAnchor("carplay.onConnect")
                        Picker("carplay_after_selection", selection: configurationBinding(\.opensNowPlayingAfterSelection)) {
                            Text("carplay_stay_here").tag(false)
                            Text("carplay_now_playing").tag(true)
                        }
                        .settingsAnchor("carplay.afterPlay")
                    }
                    CarPlayNowPlayingButtonsEditor(model: model, isSpokenWord: $editingSpokenWordButtons)
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8)
                .accessibilityIdentifier("carplay.playbackOptions")
            }
            .background(CarPlayEditorTheme.background)
            .navigationTitle("carplay_now_playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { playbackOptions = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func configurationBinding(_ keyPath: WritableKeyPath<CarPlayLayoutConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { model.configuration[keyPath: keyPath] }, set: { value in model.change { $0[keyPath: keyPath] = value } })
    }

    // MARK: - Full-screen preview

    private var expandedPreview: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                CarPlayEditorTheme.canvas.ignoresSafeArea()
                CarPlayEditorCanvas(blocks: blocks, configuration: model.configuration, selectedID: nil,
                    editing: false, playerPage: false, wide: geometry.size.width > 700,
                    previewItem: previewItem ?? nowPlaying, select: { _ in }, activate: { previewItem = $0 },
                    drop: { _, _, _ in false }, addContent: { _ in }, catalog: catalog.snapshot,
                    selectedTabID: model.selectedTabID, selectTab: model.selectTab)
                    .frame(maxWidth: min(geometry.size.width, geometry.size.height * 16 / 9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 12) {
                    CarPlaySegment(values: CarPlayVisualStyle.allCases.map { ($0, $0.titleKey) },
                        selection: Binding(get: { model.configuration.visualStyle }, set: { model.apply($0) }))
                    Spacer()
                    Button { fullScreen = false } label: { Text("done").font(.system(size: 13, weight: .semibold)) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .accessibilityIdentifier("carplay.closePreview")
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(16)
            }
        }.foregroundStyle(CarPlayEditorTheme.text)
    }

    private func updateFolderAccess() {
        let needed = model.configuration.tabs.contains { $0.kind == .folders || $0.content?.kind == .folder } || !model.configuration.folderIDs.isEmpty || model.configuration.blocks.contains { $0.kind == .folders || $0.items.contains { $0.kind == .folder } }
        if needed { folders.acquire(owner) } else { folders.release(owner) }
    }
}

struct CarPlayNowPlayingButtonsEditor: View {
    let model: CarPlayEditorModel
    @Binding var isSpokenWord: Bool

    private var actions: [CarPlayNowPlayingAction] {
        model.configuration.nowPlayingButtons(isSpokenWord: isSpokenWord)
    }

    var body: some View {
        Section("player_controls_bar_title") {
            Picker("player_controls_title", selection: $isSpokenWord) {
                Text("listening_space_music").tag(false)
                Text("listening_space_spoken_word").tag(true)
            }
            .pickerStyle(.segmented)
            ForEach(actions) { action in
                Label(LocalizedStringKey(action.titleKey), systemImage: action.symbol)
                    .accessibilityIdentifier("carplay.button.\(action.rawValue)")
            }
            .onDelete { offsets in
                var updated = actions
                updated.remove(atOffsets: offsets)
                update(updated)
            }
            .onMove { offsets, destination in
                var updated = actions
                updated.move(fromOffsets: offsets, toOffset: destination)
                update(updated)
            }
            if actions.count < CarPlayLayoutConfiguration.maximumNowPlayingButtonCount {
                Menu {
                    ForEach(CarPlayNowPlayingAction.available(isSpokenWord: isSpokenWord).filter { !actions.contains($0) }) { action in
                        Button { update(actions + [action]) } label: {
                            Label(LocalizedStringKey(action.titleKey), systemImage: action.symbol)
                        }
                    }
                } label: {
                    Label("add", systemImage: "plus")
                }
                .accessibilityIdentifier("carplay.addButton")
            }
        }
        .disabled(model.configuration.minimalNowPlaying)
    }

    private func update(_ actions: [CarPlayNowPlayingAction]) {
        model.change { $0.setNowPlayingButtons(actions, isSpokenWord: isSpokenWord) }
    }
}
#endif

#if os(iOS)
/// CarPlay 布局页浮动预览的形状与记位置的键:车机屏 16:9,没调过时约屏宽七成。
enum CarPlayPreviewWindow {
    static let positionKey = "primuse.settings.carPlayPreviewPosition"
    static let widthKey = "primuse.settings.carPlayPreviewWidth"

    static var shape: FloatingPreviewShape {
        FloatingPreviewShape(
            aspect: 16 / 9,
            // 画布自己按 14 的圆角裁,垫底的阴影跟着它。
            cornerRadius: { _ in 14 },
            defaultWidth: { min($0.width * 0.7, 320) },
            maximumWidth: 720
        )
    }
}

/// 浮动预览下面那一排:按住它挪窗口(画布里自己能滚、能拖,不拿来挪窗口)。
private struct CarPlayPreviewStrip: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .bold))
            Text("carplay_preview")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Capsule())
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("carplay_preview_move_hint"))
    }
}
#endif

#if os(iOS) && DEBUG
struct CarPlayEditorTestHost: View {
    @State private var settings: CarPlaySettingsStore
    @State private var model: CarPlayEditorModel
    init() {
        let defaults = UserDefaults(suiteName: "CarPlayEditorUITests")!
        if ProcessInfo.processInfo.environment["PRIMUSE_CARPLAY_RESET"] == "1" {
            defaults.removePersistentDomain(forName: "CarPlayEditorUITests")
        }
        let settings = CarPlaySettingsStore(defaults: defaults)
        let model = CarPlayEditorModel(settings: settings)
        if ProcessInfo.processInfo.environment["PRIMUSE_CARPLAY_SOURCE_REORDER"] == "1" {
            if ProcessInfo.processInfo.environment["PRIMUSE_CARPLAY_RESET"] == "1" {
                var block = CarPlayLayoutBlock(id: "reorder", kind: .custom, style: .list)
                block.itemLimit = 3
                block.items = (1...4).map { index in
                    CarPlayLayoutItem(id: "source.\(index)", kind: .song,
                        targetID: "unavailable.\(index)", title: "Source \(index)")
                }
                model.change { $0.blocks = [block] }
                model.flush()
            }
            model.select("reorder")
        }
        _settings = State(initialValue: settings)
        _model = State(initialValue: model)
    }
    var body: some View {
        NavigationStack { CarPlaySettingsView(settings: settings, model: model) }
    }
}
#endif
