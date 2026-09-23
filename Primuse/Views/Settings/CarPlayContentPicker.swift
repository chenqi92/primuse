#if os(iOS)
import PrimuseKit
import SwiftUI

struct CarPlayContentPicker: View {
    let catalog: CarPlayEditorCatalog
    let add: (CarPlayLayoutItem) -> Bool
    let allowedKinds: [CarPlayLayoutItem.Kind]
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CarPlayLayoutItem.Kind
    @State private var query = ""
    @State private var results: [CarPlayLayoutItem] = []
    @State private var selected: Set<String> = []
    @State private var folderID: LibraryFolderNodeID?
    @State private var folders = CarPlayFolderLibrary.shared
    @State private var owner = UUID()

    init(catalog: CarPlayEditorCatalog, initialKind: CarPlayLayoutItem.Kind = .playlist, allowedKinds: [CarPlayLayoutItem.Kind] = CarPlayLayoutItem.Kind.allCases, add: @escaping (CarPlayLayoutItem) -> Bool) {
        self.catalog = catalog
        self.add = add
        self.allowedKinds = allowedKinds
        _kind = State(initialValue: allowedKinds.contains(initialKind) ? initialKind : (allowedKinds.first ?? initialKind))
    }

    private var isLoading: Bool { catalog.isLoading || (kind == .folder && folders.isLoading) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                List {
                    if kind == .folder, let folderID, let node = folders.index?.node(withID: folderID) {
                        Section {
                            Button {
                                self.folderID = node.parentID
                                query = ""
                            } label: {
                                Label("carplay_parent_folder", systemImage: "chevron.left")
                            }
                            Button {
                                append(CarPlayLayoutItem(id: HomeFolderPinStorage.encode([node.id]), kind: .folder,
                                    targetID: HomeFolderPinStorage.encode([node.id]), title: HomeDiscoveryText.folderTitle(node)))
                            } label: {
                                Label("carplay_add_this_folder", systemImage: "plus.circle")
                            }
                            .disabled(selected.contains(CarPlayLayoutItem.Kind.folder.rawValue + HomeFolderPinStorage.encode([node.id])))
                        } header: {
                            Text(verbatim: HomeDiscoveryText.folderTitle(node))
                        }
                    }
                    Section {
                        ForEach(results) { item in row(item) }
                        if results.isEmpty {
                            if isLoading {
                                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
                            } else {
                                Text("carplay_no_content")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 4)
            }
            .skinPageBackground(replacing: .canvasSunken)
            .navigationTitle("carplay_content_sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
        .task(id: requestID) { await search() }
        .onChange(of: kind) { query = ""; folderID = nil; updateFolderAccess() }
        .onAppear { updateFolderAccess() }
        .onDisappear { folders.release(owner) }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(CarPlayEditorTheme.muted)
                TextField("carplay_find_content", text: $query)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("carplay.contentSearch")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(CarPlayEditorTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("cancel")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            if allowedKinds.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(allowedKinds) { option in
                            Button { kind = option } label: {
                                Label(LocalizedStringKey(title(option)), systemImage: symbol(option))
                                    .font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(kind == option ? CarPlayEditorTheme.accentText : CarPlayEditorTheme.secondary)
                                    .background(kind == option ? CarPlayEditorTheme.accent.opacity(0.16) : CarPlayEditorTheme.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(kind == option ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("carplay.contentKinds")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var requestID: String {
        "\(kind.rawValue):\(query):\(folderID.map { HomeFolderPinStorage.encode([$0]) } ?? ""): \(catalog.revision):\(folders.revision)"
    }

    private func search() async {
        let source: [CarPlayLayoutItem]
        if kind == .folder {
            let nodes = folderID.map { folders.index?.children(of: $0) ?? [] } ?? folders.index?.sourceNodes ?? []
            source = nodes.map {
                .init(id: HomeFolderPinStorage.encode([$0.id]), kind: .folder,
                      targetID: HomeFolderPinStorage.encode([$0.id]), title: HomeDiscoveryText.folderTitle($0))
            }
        } else if kind == .nowPlaying {
            source = [.init(id: "nowPlaying", kind: .nowPlaying, targetID: "nowPlaying", title: String(localized: "carplay_now_playing"))]
        } else { source = catalog.snapshot.searchItems[kind] ?? [] }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        }
        let work = Task.detached(priority: .userInitiated) {
            source.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
        }
        let values = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard !Task.isCancelled else { return }
        results = values
    }

    private func row(_ item: CarPlayLayoutItem) -> some View {
        let added = selected.contains(item.kind.rawValue + item.targetID)
        return HStack(spacing: 12) {
            Button {
                if kind == .folder { folderID = item.folderID; query = "" }
                else { append(item) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol(item.kind))
                        .font(.system(size: 15))
                        .foregroundStyle(CarPlayEditorTheme.accentText)
                        .frame(width: 30, height: 30)
                        .background(CarPlayEditorTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text(item.title)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if kind == .folder {
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { append(item) } label: {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(CarPlayEditorTheme.accent)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(added)
            .accessibilityLabel("carplay_add_content")
        }
    }

    private func append(_ item: CarPlayLayoutItem) {
        let key = item.kind.rawValue + item.targetID
        guard !selected.contains(key), add(item) else { return }
        selected.insert(key)
    }

    private func updateFolderAccess() {
        if kind == .folder { folders.acquire(owner) } else { folders.release(owner) }
    }

    private func title(_ kind: CarPlayLayoutItem.Kind) -> String {
        switch kind {
        case .playlist: "playlists_title"
        case .folder: "library_browse_folder"
        case .album: "carplay_section_albums"
        case .song: "carplay_tab_songs"
        case .radio: "radio_title"
        case .nowPlaying: "carplay_now_playing"
        }
    }

    private func symbol(_ kind: CarPlayLayoutItem.Kind) -> String {
        switch kind {
        case .playlist: "music.note.list"
        case .folder: "folder"
        case .album: "square.stack"
        case .song: "music.note"
        case .radio: "radio"
        case .nowPlaying: "play.circle"
        }
    }
}
#endif
