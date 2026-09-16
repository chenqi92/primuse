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
    @State private var savingPreset = false
    @State private var presetName = ""
    @State private var owner = UUID()
    @State private var previewItem: CarPlayHomeItem?

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
                } else if geometry.size.width >= 700 {
                    HStack(alignment: .top, spacing: 0) {
                        previewColumn(width: min(geometry.size.width * 0.5, max(320, (geometry.size.height - 140) * 16 / 9)))
                            .padding(.leading, 20)
                            .padding(.trailing, 4)
                        editorPanel
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        previewColumn(width: min(geometry.size.width - 32, max(280, (geometry.size.height - 340) * 16 / 9)))
                            .frame(maxWidth: .infinity)
                        editorPanel
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

    private func previewColumn(width: CGFloat) -> some View {
        canvas
            .frame(width: width)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

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
                    select: { _ in }, activate: { _ in }, drop: { _, _, _ in false }, addContent: { _ in })
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
                }
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
