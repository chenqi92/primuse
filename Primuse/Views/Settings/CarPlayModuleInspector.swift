#if os(iOS)
import PrimuseKit
import SwiftUI

struct CarPlayModuleInspector: View {
    let model: CarPlayEditorModel
    let block: CarPlayLayoutBlock
    let items: [CarPlayHomeItem]
    let add: () -> Void
    let preview: () -> Void
    @FocusState private var editingTitle: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: block.kind.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(CarPlayEditorTheme.accentText)
                        .frame(width: 30, height: 30)
                        .background(CarPlayEditorTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    TextField("carplay_module_name", text: binding(\.title), prompt: Text(LocalizedStringKey(block.kind.titleKey)))
                        .focused($editingTitle)
                        .submitLabel(.done)
                        .onSubmit { editingTitle = false }
                        .accessibilityLabel("carplay_module_name")
                }
                Toggle(isOn: binding(\.isVisible)) {
                    Label("carplay_show_module", systemImage: block.isVisible ? "eye" : "eye.slash")
                }
                .accessibilityValue(block.isVisible ? String(localized: "carplay_visible") : String(localized: "carplay_hidden"))
            }

            if block.kind == .siri {
                Section {
                    NavigationLink { SiriSettingsView().toolbar(.visible, for: .navigationBar) } label: {
                        Label("carplay_siri_suggestions", systemImage: "waveform")
                    }
                }
            } else {
                Section {
                    HStack(spacing: 8) {
                        layoutOption(.list, columns: 1, title: "carplay_style_list")
                        layoutOption(.covers, columns: 2, title: "carplay_grid_2")
                        layoutOption(.covers, columns: 3, title: "carplay_grid_3")
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    if block.style == .capsules || block.style == .cards || block.columns > 3 {
                        HStack {
                            Text(LocalizedStringKey(block.style.titleKey))
                            Spacer()
                            if block.style != .list {
                                Text(verbatim: "\(block.columns)×\(block.rowsPerPage)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("carplay_content_layout")
                } footer: {
                    if block.style != .list {
                        Text("carplay_layout_car_width_hint")
                    }
                }
                .settingsAnchor("carplay.style")

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("carplay_item_count")
                            Spacer()
                            Text(verbatim: "\(block.itemLimit) " + String(localized: "carplay_items_unit"))
                                .font(.body.weight(.semibold))
                                .monospacedDigit()
                        }
                        Slider(value: Binding(get: { Double(block.itemLimit) }, set: { value in model.update(block.id) { $0.itemLimit = Int(value) } }), in: 1...60, step: 1) { active in
                            model.continuousChange(active)
                        }
                        .tint(CarPlayEditorTheme.accent)
                        .accessibilityLabel("carplay_item_count")
                        .accessibilityIdentifier("carplay.itemLimit")
                    }
                    .padding(.vertical, 2)
                } footer: {
                    Text(String(format: String(localized: "carplay_pages_estimate"), pageEstimate))
                }

                Section("carplay_tap_action") {
                    CarPlaySegment(values: [(true, "carplay_action_play"), (false, "carplay_action_browse")], selection: binding(\.playsImmediately))
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                .settingsAnchor("carplay.directPlay")

                Section {
                    ForEach(items) { item in sourceRow(item) }
                        .onMove { offsets, destination in
                            var reordered = items
                            reordered.move(fromOffsets: offsets, toOffset: destination)
                            model.update(block.id) {
                                if !$0.usesCustomContent && $0.kind != .custom {
                                    $0.items = Array(items.compactMap(\.layoutItem).prefix(60))
                                }
                                // Preserve stored references even when their source is unavailable
                                // or the item limit excludes them from the current preview.
                                let stored = $0.items
                                let visibleIDs = Set(reordered.map(\.id))
                                $0.items = reordered.compactMap { item in stored.first { $0.id == item.id } }
                                    + stored.filter { !visibleIDs.contains($0.id) }
                                $0.usesCustomContent = true
                            }
                        }
                        .dropDestination(for: String.self) { values, index in
                            moveSources(values, before: items.indices.contains(index) ? items[index].id : nil)
                        }
                    Button(action: add) {
                        Label("carplay_add", systemImage: "plus")
                    }
                    .disabled(block.usesCustomContent && block.items.count >= 60)
                    .accessibilityIdentifier("carplay.addContent")
                } header: {
                    HStack {
                        Text("carplay_content_sources")
                        Spacer()
                        if !items.isEmpty {
                            Text(verbatim: "\(items.count)").monospacedDigit()
                        }
                    }
                } footer: {
                    if items.isEmpty { Text("carplay_drop_content") }
                }

                Section {
                    Toggle(isOn: binding(\.showsTitle)) {
                        Label("carplay_show_title", systemImage: "textformat")
                    }
                }
            }

            Section {
                Button(action: preview) {
                    Label("carplay_preview_in_car", systemImage: "eye")
                }
                Button { model.reset(block) } label: {
                    Label("carplay_reset_module", systemImage: "arrow.counterclockwise")
                }
                Button(role: .destructive) { model.remove(block.id) } label: {
                    Label("carplay_delete_module", systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4)
        .onChange(of: editingTitle) { _, value in model.continuousChange(value) }
        .accessibilityIdentifier("carplay.inspector")
    }

    private var pageEstimate: Int {
        let perPage = block.style == .list ? 5 : block.columns * block.rowsPerPage
        return max(1, Int(ceil(Double(block.itemLimit) / Double(max(1, perPage)))))
    }

    private func layoutOption(_ style: CarPlayBrowseStyle, columns: Int, title: String) -> some View {
        let selected = block.style == style && (style == .list || (block.columns == columns && block.rowsPerPage == columns))
        return Button {
            model.update(block.id) { $0.style = style; if columns > 1 { $0.columns = columns; $0.rowsPerPage = columns } }
        } label: {
            VStack(spacing: 7) {
                CarPlayLayoutGlyph(columns: columns, rows: columns == 2 ? 2 : 3, selected: selected).frame(height: 34)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? CarPlayEditorTheme.accentText : CarPlayEditorTheme.secondary)
            }
            .padding(9)
            .frame(maxWidth: .infinity)
            .background(selected ? CarPlayEditorTheme.accent.opacity(0.12) : CarPlayEditorTheme.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? CarPlayEditorTheme.accent : CarPlayEditorTheme.border, lineWidth: selected ? 1.5 : 1) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("carplay.layout.\(columns)")
    }

    private func sourceRow(_ item: CarPlayHomeItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(CarPlayEditorTheme.muted)
                .frame(width: 18, height: 34)
                .draggable("carplay-source:" + item.id)
                .accessibilityLabel("carplay_move_module")
                .accessibilityIdentifier("carplay.dragSource." + item.id)
            CarPlayPreviewArtwork(item: item, pixelSize: 88).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { model.removeContent(item, from: block.id, resolved: items) } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(CarPlayEditorTheme.muted)
                    .frame(width: 30, height: 34)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("carplay_remove_content")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("carplay.source." + item.id)
    }

    private func moveSources(_ values: [String], before destinationID: String?) {
        guard let value = values.first, value.hasPrefix("carplay-source:") else { return }
        let source = String(value.dropFirst("carplay-source:".count))
        guard source != destinationID, items.contains(where: { $0.id == source }) else { return }
        model.change { configuration in
            var blocks = configuration.blocks
            guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
            if !blocks[index].usesCustomContent && blocks[index].kind != .custom {
                blocks[index].items = Array(items.compactMap(\.layoutItem).prefix(60))
            }
            blocks[index].usesCustomContent = true
            configuration.blocks = blocks
            _ = configuration.moveItem(source, from: block.id, to: block.id, before: destinationID)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CarPlayLayoutBlock, Value>) -> Binding<Value> {
        Binding(get: { model.configuration.blocks.first { $0.id == block.id }?[keyPath: keyPath] ?? block[keyPath: keyPath] },
                set: { value in model.update(block.id) { $0[keyPath: keyPath] = value } })
    }
}
#endif
